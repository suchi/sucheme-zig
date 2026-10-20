//! Runs the conformance suite section by section and classifies what happened.
//!
//! 計画は docs/plans/0020-conformance-harness-early.md の「実行器の設計」にある。取り込んだ
//! ファイルは改変しない。走査器(split.zig)で最上位の形式に切り出し、形式を1つずつ
//! `sucheme.Interpreter.evalPrint` に渡す。結果は `(sucheme test-results)` の記録を、
//! `evalPrint` が書いた文字列として読む(src/ に値を返す API を足さないため)。
//!
//! 外側の `"R7RS"` の直下の節ごとに、新しいインタプリタを作る。入れ子の節は親の節の
//! インタプリタを共有し、記録は入れ子の節の名前で数える。
//!
//! 最上位の形式は、評価する前に次の順で見る。
//! - 未実装: `tests/r7rs-required/` に挙がっていて、その節のインタプリタで束縛されていない
//!   識別子が、形式の中にシンボルとして現れる。評価しない。テストの式が自分で誤りを捕まえると、
//!   未実装による誤りが「落ちた」に見えるからである。
//! - 連鎖: 同じ節で、評価しなかったか誤りで終わった定義の名前が、形式の中に現れる。評価しない。
//! 評価したあとは、次のように分ける。
//! - 読めない: リーダが読めなかった(`Raised` でもメモリ不足でもない誤り)。
//! - 誤り: 最上位の形式そのものが条件を上げた(期待した値の式の誤り、定義の誤りなど)。
//! - それ以外は、形式の中で `(chibi test)` が記録したテストを、通った・落ちたに数える。
//!   落ちたは、値の不一致(fail)と、テストの中で上がった誤り(error)の両方である。
//!
//! 通った・落ちたの単位はテストで、ほかは最上位の形式である。単位が違うので足さない。

const std = @import("std");
const sucheme = @import("sucheme");
const split = @import("split.zig");

/// What happened in one section.
pub const Counts = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    errored: u32 = 0,
    unreadable: u32 = 0,
    unimplemented: u32 = 0,
    cascaded: u32 = 0,
};

pub const Kind = enum { failed, errored, unreadable, unimplemented, cascaded };

/// One test that did not pass, or one top-level form that was not run or failed.
pub const Failure = struct {
    section: []const u8,
    /// 最上位の形式の先頭の行の番号(1から)。
    line: u32,
    kind: Kind,
    /// 記録の全体、誤りの説明、未束縛の識別子、または連鎖のもとの名前。表示のための文字列。
    detail: []const u8,
};

pub const SectionResult = struct {
    name: []const u8,
    counts: Counts = .{},
};

pub const SuiteResult = struct {
    sections: []const SectionResult,
    failures: []const Failure,
    /// 先頭の `import` のうち、解決できなかったライブラリ。
    missing_libraries: []const []const u8,
};

/// Why the runner itself cannot be trusted, as opposed to the interpreter failing a test.
pub const RunError = error{
    OutOfMemory,
    /// 最初の形式が `import` でない。
    NoImport,
    /// `test-begin` と `test-end` が対にならない。
    UnbalancedSections,
    /// 外側の群の直下に、節に属さない形式がある。
    FormOutsideSection,
    /// 実行器が記録を読むための式が失敗した。
    QueryFailed,
    /// 前の節で定義された名前が、後の節で未束縛として報告された。節ごとにインタプリタを分ける
    /// 前提が崩れている。
    CrossSectionReference,
} || split.SplitError;

/// The library the runner reads the records from. The suite does not import it.
const results_library = "(sucheme test-results)";

/// Runs `text`, the whole suite. `required` is every identifier R7RS requires of a
/// standard library. Everything returned is in `gpa`.
pub fn runSuite(gpa: std.mem.Allocator, text: []const u8, required: []const []const u8) RunError!SuiteResult {
    var forms: std.ArrayList(split.Chunk) = .empty;
    var pos: usize = 0;
    while (try split.next(text, pos)) |c| {
        try forms.append(gpa, c);
        pos = c.end;
    }
    if (forms.items.len == 0) return error.NoImport;
    const import_form = text[forms.items[0].start..forms.items[0].end];
    const libraries = try importedLibraries(gpa, import_form);

    var available: std.ArrayList([]const u8) = .empty;
    var missing: std.ArrayList([]const u8) = .empty;
    {
        var probe: sucheme.Interpreter = undefined;
        try probe.initBare(std.heap.smp_allocator, .{});
        defer probe.deinit();
        for (libraries) |lib| {
            const request = try std.fmt.allocPrint(gpa, "(import {s})", .{lib});
            if (try evalQuietly(&probe, request)) |_| {
                try available.append(gpa, lib);
            } else {
                try missing.append(gpa, lib);
            }
        }
    }
    var header: std.ArrayList(u8) = .empty;
    try header.appendSlice(gpa, "(import");
    for (available.items) |lib| {
        try header.append(gpa, ' ');
        try header.appendSlice(gpa, lib);
    }
    try header.appendSlice(gpa, " " ++ results_library ++ ")");

    var state: State = .{
        .gpa = gpa,
        .text = text,
        .required = required,
        .header = header.items,
    };
    defer state.closeSection();

    var depth: usize = 0;
    for (forms.items[1..]) |c| {
        const form = text[c.start..c.end];
        if (sectionName(form)) |name| {
            depth += 1;
            // 外側の群は数えない。その直下の節ごとに、インタプリタを作り直す。
            if (depth == 2) try state.openSection();
            if (depth >= 2) {
                try state.pushName(name);
                try state.evaluate(c, form);
            }
            continue;
        }
        if (isSectionEnd(form)) {
            if (depth == 0) return error.UnbalancedSections;
            if (depth >= 2) {
                try state.evaluate(c, form);
                state.popName();
            }
            if (depth == 2) state.closeSection();
            depth -= 1;
            continue;
        }
        if (depth < 2) return error.FormOutsideSection;
        try state.evaluate(c, form);
    }
    if (depth != 0) return error.UnbalancedSections;

    return .{
        .sections = try state.sections.toOwnedSlice(gpa),
        .failures = try state.failures.toOwnedSlice(gpa),
        .missing_libraries = try missing.toOwnedSlice(gpa),
    };
}

const State = struct {
    gpa: std.mem.Allocator,
    text: []const u8,
    required: []const []const u8,
    header: []const u8,

    sections: std.ArrayList(SectionResult) = .empty,
    failures: std.ArrayList(Failure) = .empty,
    /// 入れ子の節の名前。先頭が外側の群の直下の節である。
    names: std.ArrayList([]const u8) = .empty,

    interp: ?*sucheme.Interpreter = null,
    /// その節で読み終えた記録の数。
    records: usize = 0,
    /// その節で、評価しなかったか誤りで終わった定義の名前。
    broken: std.StringHashMapUnmanaged(void) = .empty,
    /// その節で定義された名前と、前の節までに定義された名前。
    defined_here: std.StringHashMapUnmanaged(void) = .empty,
    defined_before: std.StringHashMapUnmanaged(void) = .empty,

    fn openSection(self: *State) RunError!void {
        self.closeSection();
        const interp = try self.gpa.create(sucheme.Interpreter);
        try interp.initBare(std.heap.smp_allocator, .{});
        self.interp = interp;
        self.records = 0;
        self.broken = .empty;
        // スイートの `import` は、ここで1回だけ評価する。解決できるライブラリだけに絞ってある。
        if (try evalQuietly(interp, self.header) == null) return error.QueryFailed;
    }

    fn closeSection(self: *State) void {
        const interp = self.interp orelse return;
        interp.deinit();
        self.gpa.destroy(interp);
        self.interp = null;
        var it = self.defined_here.keyIterator();
        while (it.next()) |k| self.defined_before.put(self.gpa, k.*, {}) catch {};
        self.defined_here = .empty;
    }

    fn pushName(self: *State, name: []const u8) RunError!void {
        try self.names.append(self.gpa, name);
        for (self.sections.items) |s| if (std.mem.eql(u8, s.name, name)) return;
        try self.sections.append(self.gpa, .{ .name = name });
    }

    fn popName(self: *State) void {
        _ = self.names.pop();
    }

    fn current(self: *State) []const u8 {
        return self.names.items[self.names.items.len - 1];
    }

    fn countsOf(self: *State, name: []const u8) *Counts {
        for (self.sections.items) |*s| if (std.mem.eql(u8, s.name, name)) return &s.counts;
        unreachable; // pushName が先に足している。
    }

    fn fail(self: *State, c: split.Chunk, kind: Kind, detail: []const u8) RunError!void {
        const counts = self.countsOf(self.current());
        switch (kind) {
            .failed => counts.failed += 1,
            .errored => counts.errored += 1,
            .unreadable => counts.unreadable += 1,
            .unimplemented => counts.unimplemented += 1,
            .cascaded => counts.cascaded += 1,
        }
        try self.failures.append(self.gpa, .{ .section = self.current(), .line = c.line, .kind = kind, .detail = detail });
    }

    /// Classifies one top-level form of the current section, evaluating it unless it is
    /// unimplemented or cascades.
    fn evaluate(self: *State, c: split.Chunk, form: []const u8) RunError!void {
        const interp = self.interp.?;
        var symbols: std.ArrayList([]const u8) = .empty;
        try symbolsIn(self.gpa, form, &symbols);
        for (symbols.items) |s| {
            if (contains(self.required, s) and !interp.isBound(s)) {
                try self.markBroken(form);
                return self.fail(c, .unimplemented, s);
            }
        }
        for (symbols.items) |s| {
            if (self.broken.contains(s)) {
                try self.markBroken(form);
                return self.fail(c, .cascaded, s);
            }
        }

        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var discard: std.Io.Writer.Discarding = .init(&.{});
        const failed: ?[]const u8 = blk: {
            interp.evalPrint(arena.allocator(), form, &discard.writer) catch |e| switch (e) {
                error.Raised => break :blk try self.gpa.dupe(u8, interp.diagnostic()),
                error.OutOfMemory, error.HeapLimit, error.ReserveExhausted, error.WriteFailed => break :blk try self.gpa.dupe(u8, interp.diagnostic()),
                else => {
                    // `Raised` でも資源の誤りでもないものは、リーダの誤りである(展開器の誤りは
                    // 条件として上がる)。何も評価されていない。
                    try self.markBroken(form);
                    return self.fail(c, .unreadable, try self.gpa.dupe(u8, interp.diagnostic()));
                },
            };
            break :blk null;
        };
        for (try definedNames(self.gpa, form)) |name| try self.defined_here.put(self.gpa, name, {});
        try self.readRecords(c);
        if (failed) |diag| {
            try self.checkCrossSection(diag);
            try self.markBroken(form);
            try self.fail(c, .errored, diag);
        }
    }

    /// Counts the records the last form added.
    fn readRecords(self: *State, c: split.Chunk) RunError!void {
        const interp = self.interp.?;
        const total = std.fmt.parseInt(usize, try query(self.gpa, interp, "(length (test-results))"), 10) catch return error.QueryFailed;
        while (self.records < total) : (self.records += 1) {
            const i = self.records;
            const status = try query(self.gpa, interp, try std.fmt.allocPrint(self.gpa, "(vector-ref (list-ref (test-results) {d}) 2)", .{i}));
            const group_text = try query(self.gpa, interp, try std.fmt.allocPrint(self.gpa, "(vector-ref (list-ref (test-results) {d}) 0)", .{i}));
            const group = if (group_text.len >= 2 and group_text[0] == '"') group_text[1 .. group_text.len - 1] else self.current();
            // 記録の節の名前は、実行器が開いた節の名前のどれかでなければならない。
            const name = self.known(group) orelse return error.QueryFailed;
            if (std.mem.eql(u8, status, "pass")) {
                self.countsOf(name).passed += 1;
                continue;
            }
            const detail = try query(self.gpa, interp, try std.fmt.allocPrint(self.gpa, "(list-ref (test-results) {d})", .{i}));
            try self.checkCrossSection(detail);
            self.countsOf(name).failed += 1;
            try self.failures.append(self.gpa, .{ .section = name, .line = c.line, .kind = .failed, .detail = detail });
        }
    }

    fn known(self: *State, name: []const u8) ?[]const u8 {
        for (self.sections.items) |s| if (std.mem.eql(u8, s.name, name)) return s.name;
        return null;
    }

    fn markBroken(self: *State, form: []const u8) RunError!void {
        for (try definedNames(self.gpa, form)) |name| try self.broken.put(self.gpa, name, {});
    }

    /// Fails when an error names, as unbound, something an earlier section defined.
    fn checkCrossSection(self: *State, message: []const u8) RunError!void {
        const marker = "unbound variable: ";
        const at = std.mem.indexOf(u8, message, marker) orelse return;
        const rest = message[at + marker.len ..];
        const end = std.mem.indexOfAny(u8, rest, "\" )>") orelse rest.len;
        const name = rest[0..end];
        if (self.defined_before.contains(name) and !self.defined_here.contains(name)) return error.CrossSectionReference;
    }
};

/// Evaluates `source` and discards what it prints. Returns null when it fails.
fn evalQuietly(interp: *sucheme.Interpreter, source: []const u8) error{OutOfMemory}!?void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    interp.evalPrint(arena.allocator(), source, &discard.writer) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

/// Evaluates `source` and returns what it prints, without the last newline, in `gpa`.
fn query(gpa: std.mem.Allocator, interp: *sucheme.Interpreter, source: []const u8) RunError![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    interp.evalPrint(arena.allocator(), source, &out.writer) catch return error.QueryFailed;
    return std.mem.trimEnd(u8, out.written(), "\n");
}

/// The name of a `(test-begin "<name>")` form, or null for any other form.
fn sectionName(form: []const u8) ?[]const u8 {
    const prefix = "(test-begin \"";
    if (!std.mem.startsWith(u8, form, prefix) or !std.mem.endsWith(u8, form, "\")")) return null;
    const name = form[prefix.len .. form.len - 2];
    if (std.mem.indexOfScalar(u8, name, '"') != null) return null;
    return name;
}

fn isSectionEnd(form: []const u8) bool {
    return std.mem.eql(u8, form, "(test-end)");
}

/// The libraries an `(import ...)` form names, as their source text.
fn importedLibraries(gpa: std.mem.Allocator, form: []const u8) RunError![]const []const u8 {
    const elements = try listElements(gpa, form) orelse return error.NoImport;
    if (elements.len == 0 or !std.mem.eql(u8, elements[0], "import")) return error.NoImport;
    return elements[1..];
}

/// The elements of the list `form`, as their source text, or null when it is not a list.
fn listElements(gpa: std.mem.Allocator, form: []const u8) RunError!?[]const []const u8 {
    if (form.len < 2 or form[0] != '(' or form[form.len - 1] != ')') return null;
    const inner = form[1 .. form.len - 1];
    var out: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;
    while (try split.next(inner, pos)) |c| {
        try out.append(gpa, inner[c.start..c.end]);
        pos = c.end;
    }
    return try out.toOwnedSlice(gpa);
}

/// The names a top-level definition binds: `define`, `define-syntax`, `define-values`
/// and `define-record-type`. Other forms bind nothing here.
fn definedNames(gpa: std.mem.Allocator, form: []const u8) RunError![]const []const u8 {
    const elements = try listElements(gpa, form) orelse return &.{};
    if (elements.len < 2) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    const head = elements[0];
    if (std.mem.eql(u8, head, "define") or std.mem.eql(u8, head, "define-syntax")) {
        // `(define (f . args) ...)` と、カリー化した `(define ((f a) b) ...)` は、いちばん内側の
        // 先頭の名前を束縛する。
        var target = elements[1];
        while (try listElements(gpa, target)) |inner| {
            if (inner.len == 0) break;
            target = inner[0];
        }
        try out.append(gpa, target);
    } else if (std.mem.eql(u8, head, "define-values")) {
        try symbolsIn(gpa, elements[1], &out);
    } else if (std.mem.eql(u8, head, "define-record-type")) {
        // 型の名前、構築子、述語、各フィールドの参照子と変更子。フィールドの名前そのものは束縛しないが、
        // 余分に含めても連鎖が広がるだけで、数え落としにはならない。
        for (elements[1..]) |e| try symbolsIn(gpa, e, &out);
    }
    return try out.toOwnedSlice(gpa);
}

/// Appends every symbol-looking token of `text`, skipping strings, characters and
/// comments. Numbers and booleans also come out, which is harmless here: they are
/// never required identifiers or definition names.
fn symbolsIn(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayList([]const u8)) RunError!void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"') {
            i += 1;
            while (i < text.len and text[i] != '"') : (i += 1) {
                if (text[i] == '\\') i += 1;
            }
            i += 1;
        } else if (c == ';') {
            i = std.mem.indexOfAnyPos(u8, text, i, "\r\n") orelse text.len;
        } else if (std.mem.startsWith(u8, text[i..], "#|")) {
            i = (std.mem.indexOfPos(u8, text, i + 2, "|#") orelse text.len - 2) + 2;
        } else if (std.mem.startsWith(u8, text[i..], "#\\")) {
            i += 3;
            while (i < text.len and !isDelimiter(text[i])) i += 1;
        } else if (isDelimiter(c) or c == '\'' or c == '`' or c == ',' or c == '@') {
            i += 1;
        } else {
            const start = i;
            while (i < text.len and !isDelimiter(text[i])) i += 1;
            try out.append(gpa, text[start..i]);
        }
    }
}

fn isDelimiter(c: u8) bool {
    return std.ascii.isWhitespace(c) or switch (c) {
        '(', ')', '[', ']', '"', ';', '|' => true,
        else => false,
    };
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

test {
    std.testing.refAllDecls(@This());
}

const fake_required = [_][]const u8{ "car", "exact-integer-sqrt", "string-upcase", "+", "define" };

fn runFake(arena: std.mem.Allocator, text: []const u8) !SuiteResult {
    return runSuite(arena, text, &fake_required);
}

fn findSection(r: SuiteResult, name: []const u8) !Counts {
    for (r.sections) |s| if (std.mem.eql(u8, s.name, name)) return s.counts;
    return error.TestUnexpectedResult;
}

test "each kind of outcome is counted in its section" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try runFake(arena.allocator(),
        \\(import (scheme base) (chibi test) (no such-library))
        \\(test-begin "all")
        \\(test-begin "a")
        \\(test 3 (+ 1 2))
        \\(test 4 (+ 1 2))
        \\(test 1 (car 5))
        \\(test 1 (exact-integer-sqrt 4))
        \\(define (f) (exact-integer-sqrt 4))
        \\(test 2 (f))
        \\(test #u8(1 #e) 1)
        \\(test (car 5) 1)
        \\(test-end)
        \\(test-begin "b")
        \\(test 1 1)
        \\(test-end)
        \\(test-end)
    );
    try std.testing.expectEqual(@as(usize, 1), r.missing_libraries.len);
    try std.testing.expectEqualStrings("(no such-library)", r.missing_libraries[0]);
    try std.testing.expectEqual(Counts{ .passed = 1, .failed = 2, .errored = 1, .unreadable = 1, .unimplemented = 2, .cascaded = 1 }, try findSection(r, "a"));
    try std.testing.expectEqual(Counts{ .passed = 1 }, try findSection(r, "b"));
}

test "a nested section is counted under its own name, in its parent's interpreter" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try runFake(arena.allocator(),
        \\(import (scheme base) (chibi test))
        \\(test-begin "all")
        \\(test-begin "outer")
        \\(define x 5)
        \\(test 5 x)
        \\(test-begin "inner")
        \\(test 6 (+ x 1))
        \\(test 0 x)
        \\(test-end)
        \\(test-end)
        \\(test-end)
    );
    try std.testing.expectEqual(Counts{ .passed = 1 }, try findSection(r, "outer"));
    try std.testing.expectEqual(Counts{ .passed = 1, .failed = 1 }, try findSection(r, "inner"));
    try std.testing.expectEqual(@as(usize, 1), r.failures.len);
    try std.testing.expectEqualStrings("inner", r.failures[0].section);
    try std.testing.expectEqual(@as(u32, 8), r.failures[0].line);
}

test "each section gets a fresh interpreter" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = runFake(arena.allocator(),
        \\(import (scheme base) (chibi test))
        \\(test-begin "all")
        \\(test-begin "a")
        \\(define y 1)
        \\(test-end)
        \\(test-begin "b")
        \\(test 1 y)
        \\(test-end)
        \\(test-end)
    );
    try std.testing.expectError(error.CrossSectionReference, r);
}

test "a suite the runner does not understand is an error, not a result" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.NoImport, runFake(a, "(test-begin \"all\")"));
    try std.testing.expectError(error.NoImport, runFake(a, ""));
    try std.testing.expectError(error.UnbalancedSections, runFake(a, "(import (scheme base))\n(test-end)"));
    try std.testing.expectError(error.UnbalancedSections, runFake(a, "(import (scheme base) (chibi test))\n(test-begin \"all\")"));
    try std.testing.expectError(error.FormOutsideSection, runFake(a, "(import (scheme base) (chibi test))\n(test-begin \"all\")\n(test 1 1)\n(test-end)"));
    try std.testing.expectError(error.Unbalanced, runFake(a, "(import (scheme base)"));
}

test "the names a definition binds" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectNames(a, "(define x 1)", &.{"x"});
    try expectNames(a, "(define (f a . b) a)", &.{"f"});
    try expectNames(a, "(define ((curried a) b) a)", &.{"curried"});
    try expectNames(a, "(define-syntax m (syntax-rules ()))", &.{"m"});
    try expectNames(a, "(define-values (p q . r) (values 1 2))", &.{ "p", "q", ".", "r" });
    try expectNames(a, "(test 1 1)", &.{});
    try expectNames(a, "x", &.{});
}

fn expectNames(a: std.mem.Allocator, form: []const u8, want: []const []const u8) !void {
    const got = try definedNames(a, form);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "symbols skip strings, characters and comments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try symbolsIn(arena.allocator(), "(f 'g \"h i\" #\\j ; k\n #| l |# `(m ,n ,@o))", &out);
    const want = [_][]const u8{ "f", "g", "m", "n", "o" };
    try std.testing.expectEqual(want.len, out.items.len);
    for (want, out.items) |w, g| try std.testing.expectEqualStrings(w, g);
}
