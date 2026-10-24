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
//! 通った・落ちたの単位はテストで、ほかは最上位の形式である。ただし連鎖は、同じ外側の節(入れ子の
//! 節を含む)に評価しなかったか誤りで終わった形式があるときにテストの中で上がった未束縛の誤りを、
//! テストの単位で含む。単位が違うので足さない。

const std = @import("std");
const sucheme = @import("sucheme");
const split = @import("split.zig");

/// Where the vendored suite is, from the repository root.
pub const suite_path = "tests/vendor/r7rs-tests.scm";

/// The SHA-256 of the vendored suite, the one the runner trusts.
/// 値の正はここである(tests/vendor/README.md の「ハッシュ」)。実行器(main.zig)と準拠マトリクスの
/// 生成器(tools/coverage-report)の両方が、これと照らしてからスイートを走らせる。取り込んだ
/// ファイルを更新するときは、README の取得の記録と同じコミットで変える。
pub const suite_sha256 = "004d215a38f990bbf2bfaa8b4a395aa59ef98d155096f8e31cc361b7812f7d6a";

/// Whether `digest` is the digest of the vendored suite.
fn isVendored(digest: []const u8) bool {
    return std.mem.eql(u8, digest, suite_sha256);
}

/// The lowercase hex of the SHA-256 of `text`.
pub fn hexDigest(text: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

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

/// The prefix of the bindings the runner imports for itself, which the suite does not redefine.
const runner_prefix = "%conformance-run:";

/// The most steps of the machine one top-level form of the suite may take.
/// Why: 止まらない形式を、CI のジョブの時間切れでなく、どの形式かが分かる誤りで止めるためである
/// (ADR-0044)。値は、取り込んだスイートの形式1つあたりの歩数の最大値の約 100 倍で、測った値と
/// 止まるまでの時間は計画書 0024 の「測定」にある。ほかのレーンが手続きを足して、今は評価されない
/// 形式が評価されるようになっても、正当な形式が当たらない余裕を取る。正当な形式が当たったら、その
/// 歩数を測って上げる。当たった形式は誤りに数えられるので、`check-report` が赤になり、黙って見逃されない。
const step_limit = 250_000;

/// Runs `text` with `runSuite` if it is the vendored suite, or returns `error.NotVendored`.
/// 実行器と準拠マトリクスの生成器は、どちらもこの関数を通してスイートを走らせる。照合を
/// 呼び出し元ごとに書くと、片方で照合が外れても、テストが見つけないためである。
pub fn runVendored(gpa: std.mem.Allocator, text: []const u8, required: []const []const u8) (RunError || error{NotVendored})!SuiteResult {
    const digest = hexDigest(text);
    if (!isVendored(&digest)) return error.NotVendored;
    return runSuite(gpa, text, required);
}

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
    try header.appendSlice(gpa, " " ++ results_library ++ " (prefix (only (scheme base) vector-ref) " ++ runner_prefix ++ "))");

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
    /// その節に、評価しなかったか誤りで終わった形式が1つでもあるか。マクロが作る定義のように、
    /// 名前を静的に取り出せない定義の連鎖を見るために使う。
    any_broken: bool = false,
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
        self.any_broken = false;
        // スイートの `import` は、ここで1回だけ評価する。解決できるライブラリだけに絞ってある。
        if (try evalQuietly(interp, self.header) == null) return error.QueryFailed;
        // 上限は見出しのあとに置く。見出しの `import` が上限に当たると、実行器の誤りとして止まるためである。
        interp.setStepLimit(step_limit);
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
        try freeSymbols(self.gpa, form, .code, &symbols);
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
                // 上限で打ち切った形式も、最上位の形式そのものの誤りに数える(計画書 0024)。
                error.StepLimit => break :blk try self.gpa.dupe(u8, interp.diagnostic()),
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
    /// 記録は `(sucheme test-results)` の手続きと、接頭辞を付けて読み込んだ `vector-ref` だけで読む。
    /// スイートが `length` や `vector-ref` を再定義しても、記録が黙って数えられなくならないためである。
    /// 記録は `#(節の名前 テストの式 判定 期待した値 得た値)` である。
    fn readRecords(self: *State, c: split.Chunk) RunError!void {
        const interp = self.interp.?;
        const total = std.fmt.parseInt(usize, try query(self.gpa, interp, "(test-results-count)"), 10) catch return error.QueryFailed;
        while (self.records < total) : (self.records += 1) {
            const i = self.records;
            const group_text = try query(self.gpa, interp, try std.fmt.allocPrint(self.gpa, "(" ++ runner_prefix ++ "vector-ref (test-results-ref {d}) 0)", .{i}));
            const group = if (group_text.len >= 2 and group_text[0] == '"') group_text[1 .. group_text.len - 1] else self.current();
            // 記録の節の名前は、実行器が開いた節の名前のどれかでなければならない。
            const name = self.known(group) orelse return error.QueryFailed;
            const status = try query(self.gpa, interp, try std.fmt.allocPrint(self.gpa, "(" ++ runner_prefix ++ "vector-ref (test-results-ref {d}) 2)", .{i}));
            if (std.mem.eql(u8, status, "pass")) {
                self.countsOf(name).passed += 1;
                continue;
            }
            const record = try query(self.gpa, interp, try std.fmt.allocPrint(self.gpa, "(test-results-ref {d})", .{i}));
            if (std.mem.eql(u8, status, "error")) {
                const actual = try query(self.gpa, interp, try std.fmt.allocPrint(self.gpa, "(" ++ runner_prefix ++ "vector-ref (test-results-ref {d}) 4)", .{i}));
                try self.checkCrossSection(actual);
                // 同じ節に壊れた定義があるとき、テストの中の未束縛の誤りは、その連鎖として数える。
                // 定義は、マクロの展開の中にあると、名前を静的に取り出せないためである。
                if (self.any_broken and std.mem.indexOf(u8, actual, unbound_marker) != null) {
                    self.countsOf(name).cascaded += 1;
                    try self.failures.append(self.gpa, .{ .section = name, .line = c.line, .kind = .cascaded, .detail = record });
                    continue;
                }
            } else if (!std.mem.eql(u8, status, "fail")) return error.QueryFailed;
            self.countsOf(name).failed += 1;
            try self.failures.append(self.gpa, .{ .section = name, .line = c.line, .kind = .failed, .detail = record });
        }
    }

    fn known(self: *State, name: []const u8) ?[]const u8 {
        for (self.sections.items) |s| if (std.mem.eql(u8, s.name, name)) return s.name;
        return null;
    }

    fn markBroken(self: *State, form: []const u8) RunError!void {
        self.any_broken = true;
        for (try definedNames(self.gpa, form)) |name| try self.broken.put(self.gpa, name, {});
    }

    /// Fails when an error names, as unbound, something an earlier section defined.
    /// 前の節の名前のほうから照らす。名前には `>` や空白(縦棒の識別子)が入りうるので、
    /// 説明の文字列から名前を切り出すと、切り方を誤って見逃す。名前の後ろは、説明の終わりか、
    /// 条件の文字列を閉じる `"` でなければならない。
    fn checkCrossSection(self: *State, message: []const u8) RunError!void {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, message, pos, unbound_marker)) |at| {
            const rest = message[at + unbound_marker.len ..];
            var it = self.defined_before.keyIterator();
            while (it.next()) |k| {
                const name = k.*;
                if (!std.mem.startsWith(u8, rest, name)) continue;
                if (rest.len != name.len and rest[name.len] != '"') continue;
                return error.CrossSectionReference;
            }
            pos = at + unbound_marker.len;
        }
    }
};

/// What the interpreter's message for an unbound variable starts with.
const unbound_marker = "unbound variable: ";

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
    if (form.len < 2) return null;
    const closed = (form[0] == '(' and form[form.len - 1] == ')') or (form[0] == '[' and form[form.len - 1] == ']');
    if (!closed) return null;
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
    var out: std.ArrayList([]const u8) = .empty;
    try appendDefinedNames(gpa, form, &out);
    return try out.toOwnedSlice(gpa);
}

fn appendDefinedNames(gpa: std.mem.Allocator, form: []const u8, out: *std.ArrayList([]const u8)) RunError!void {
    const elements = try listElements(gpa, form) orelse return;
    if (elements.len < 2) return;
    const head = elements[0];
    // 最上位の `begin` の中の定義は、最上位の定義である(R7RS 5.6.1)。
    if (std.mem.eql(u8, head, "begin")) {
        for (elements[1..]) |e| try appendDefinedNames(gpa, e, out);
    } else if (std.mem.eql(u8, head, "define") or std.mem.eql(u8, head, "define-syntax")) {
        // `(define (f . args) ...)` と、カリー化した `(define ((f a) b) ...)` は、いちばん内側の
        // 先頭の名前を束縛する。
        var target = elements[1];
        while (try listElements(gpa, target)) |inner| {
            if (inner.len == 0) break;
            target = inner[0];
        }
        try out.append(gpa, target);
    } else if (std.mem.eql(u8, head, "define-values")) {
        try atomsIn(gpa, elements[1], out);
    } else if (std.mem.eql(u8, head, "define-record-type")) {
        // 型の名前、構築子、述語、各フィールドの参照子と変更子。フィールドの名前そのものは束縛しないが、
        // 余分に含めても連鎖が広がるだけで、数え落としにはならない。
        for (elements[1..]) |e| try atomsIn(gpa, e, out);
    }
}

/// Appends every atom of `datum`, at any depth of its lists.
fn atomsIn(gpa: std.mem.Allocator, datum: []const u8, out: *std.ArrayList([]const u8)) RunError!void {
    if (try listElements(gpa, datum)) |elements| {
        for (elements) |e| try atomsIn(gpa, e, out);
    } else if (datum.len > 0 and datum[0] != '"' and datum[0] != '#') {
        try out.append(gpa, datum);
    }
}

/// Whether a datum is read as code or as the template of a quasiquote.
const Reading = enum { code, quasi };

/// Appends the symbols of `datum` that may be evaluated as variables.
/// 引用されたデータの中のシンボルは、変数として評価されないので数えない。`'x`、`(quote x)`、
/// ベクタ、文字列、文字は飛ばす。準引用の中は、`,` と `,@`(`unquote` と `unquote-splicing`)の
/// 中だけを数える。準引用の入れ子の深さは数えない(スイートには無い)。字句は走査器に任せるので、
/// コメントや縦棒の識別子を独自に読まない。数や真偽値も出てくるが、必須の識別子にも定義の
/// 名前にもならないので、害は無い。
fn freeSymbols(gpa: std.mem.Allocator, datum: []const u8, reading: Reading, out: *std.ArrayList([]const u8)) RunError!void {
    if (datum.len == 0) return;
    switch (datum[0]) {
        '\'' => if (reading == .quasi) try freeSymbols(gpa, try prefixed(datum, 1), .quasi, out),
        '`' => try freeSymbols(gpa, try prefixed(datum, 1), .quasi, out),
        ',' => {
            const skip: usize = if (std.mem.startsWith(u8, datum, ",@")) 2 else 1;
            try freeSymbols(gpa, try prefixed(datum, skip), .code, out);
        },
        '(', '[' => {
            const elements = try listElements(gpa, datum) orelse return;
            if (elements.len == 0) return;
            const head = elements[0];
            if (reading == .code and std.mem.eql(u8, head, "quote")) return;
            if (reading == .code and std.mem.eql(u8, head, "quasiquote")) {
                for (elements[1..]) |e| try freeSymbols(gpa, e, .quasi, out);
                return;
            }
            if (reading == .quasi and (std.mem.eql(u8, head, "unquote") or std.mem.eql(u8, head, "unquote-splicing"))) {
                for (elements[1..]) |e| try freeSymbols(gpa, e, .code, out);
                return;
            }
            for (elements) |e| try freeSymbols(gpa, e, reading, out);
        },
        // ベクタは自己評価的なデータである。準引用の中のベクタだけは、`,` を含みうる。
        '#' => if (reading == .quasi and std.mem.startsWith(u8, datum, "#(")) {
            for ((try listElements(gpa, datum[1..])) orelse return) |e| try freeSymbols(gpa, e, .quasi, out);
        },
        '"', '|' => {},
        else => if (reading == .code) try out.append(gpa, datum),
    }
}

/// The datum after a prefix such as `'` or `,@` that is `skip` bytes long.
fn prefixed(datum: []const u8, skip: usize) RunError![]const u8 {
    const c = try split.next(datum, skip) orelse return "";
    return datum[c.start..c.end];
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

test {
    std.testing.refAllDecls(@This());
}

test "only the vendored digest is accepted" {
    try std.testing.expect(isVendored(suite_sha256));
    const other = hexDigest("(test 1 1)");
    try std.testing.expect(!isVendored(&other));
    try std.testing.expect(!isVendored(suite_sha256[0..63]));
}

test "the digest is the lowercase hex of SHA-256" {
    const d = hexDigest("abc");
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &d);
}

const fake_required = [_][]const u8{ "car", "open-input-string", "string-upcase", "+", "define" };

fn runFake(arena: std.mem.Allocator, text: []const u8) !SuiteResult {
    return runSuite(arena, text, &fake_required);
}

test "a suite that is not the vendored one is not run" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // runSuite なら走るスイートでも、ハッシュが違えば走らせない。
    const text =
        \\(import (scheme base) (chibi test))
        \\(test-begin "all")
        \\(test-begin "a")
        \\(test 1 1)
        \\(test-end)
        \\(test-end)
    ;
    _ = try runFake(arena.allocator(), text);
    try std.testing.expectError(error.NotVendored, runVendored(arena.allocator(), text, &fake_required));
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
        \\(test 1 (open-input-string 4))
        \\(define (f) (open-input-string 4))
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
    try expectNames(a, "(define-record-type <pt> (mk x) pt? (x px set-px!))", &.{ "<pt>", "mk", "x", "pt?", "x", "px", "set-px!" });
    try expectNames(a, "(begin (define a 1) (begin (define-syntax b c)) 2)", &.{ "a", "b" });
    try expectNames(a, "(test 1 1)", &.{});
    try expectNames(a, "x", &.{});
}

fn expectNames(a: std.mem.Allocator, form: []const u8, want: []const []const u8) !void {
    const got = try definedNames(a, form);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

fn expectFree(form: []const u8, want: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try freeSymbols(arena.allocator(), form, .code, &out);
    try std.testing.expectEqual(want.len, out.items.len);
    for (want, out.items) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "free symbols skip strings, characters, vectors and comments" {
    try expectFree("(f \"h i\" #\\j ; k\n #| l #| m |# n |# #(o) [p] #;(q) r)", &.{ "f", "p", "r" });
    try expectFree("(f |a\"b| g)", &.{ "f", "g" });
    try expectFree("(f #\\\" g |a b| h)", &.{ "f", "g", "h" });
}

test "free symbols skip quoted data, and in a quasiquote count only what is unquoted" {
    try expectFree("(f 'g (quote h) `(i ,j ,@(k l) #(m ,n)) (quasiquote (o (unquote p))))", &.{ "f", "j", "k", "l", "n", "p" });
    try expectFree("'x", &.{});
    try expectFree("x", &.{"x"});
}

test "a quoted name of an unimplemented procedure does not make the form unimplemented" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try runFake(arena.allocator(),
        \\(import (scheme base) (chibi test))
        \\(test-begin "all")
        \\(test-begin "a")
        \\(define f (open-input-string 4))
        \\(test #t (symbol? 'open-input-string))
        \\(test '(a `(b ,f) f) '(a `(b ,f) f))
        \\(test-end)
        \\(test-end)
    );
    try std.testing.expectEqual(Counts{ .passed = 2, .unimplemented = 1 }, try findSection(r, "a"));
}

test "a definition inside a top-level begin, or made by a macro, cascades" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try runFake(arena.allocator(),
        \\(import (scheme base) (chibi test))
        \\(test-begin "all")
        \\(test-begin "a")
        \\(begin (define z (open-input-string 4)) (define w 1))
        \\(test 2 z)
        \\(test 1 w)
        \\(test-end)
        \\(test-begin "b")
        \\(define-syntax def (syntax-rules () ((_ n v) (define n v))))
        \\(def y (open-input-string 4))
        \\(test 2 y)
        \\(test 3 (car 5))
        \\(test-end)
        \\(test-end)
    );
    try std.testing.expectEqual(Counts{ .unimplemented = 1, .cascaded = 2 }, try findSection(r, "a"));
    // `y` は静的には取り出せないので、テストの中の未束縛の誤りとして、連鎖に数える。未束縛でない誤りは落ちた。
    try std.testing.expectEqual(Counts{ .failed = 1, .unimplemented = 1, .cascaded = 1 }, try findSection(r, "b"));
}

test "a form that does not stop is an error at the step limit, and the section goes on" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try runFake(arena.allocator(),
        \\(import (scheme base) (chibi test))
        \\(test-begin "all")
        \\(test-begin "a")
        \\(define (spin) (spin))
        \\(test 1 (spin))
        \\(define x (let loop () (loop)))
        \\(test 1 x)
        \\(test 2 (+ 1 1))
        \\(test-end)
        \\(test-begin "b")
        \\(test 1 (let loop () (loop)))
        \\(test-end)
        \\(test-end)
    );
    // 止まらない式は誤りに数え、止まらない定義は連鎖のもとにする。後続のテストは走る。
    try std.testing.expectEqual(Counts{ .passed = 1, .errored = 2, .cascaded = 1 }, try findSection(r, "a"));
    // 上限は、節ごとに作るインタプリタのどれにも置く。
    try std.testing.expectEqual(Counts{ .errored = 1 }, try findSection(r, "b"));
    var limits: usize = 0;
    for (r.failures) |f| {
        if (f.kind == .errored) {
            try std.testing.expectEqualStrings("step limit exceeded", f.detail);
            limits += 1;
        }
    }
    try std.testing.expectEqual(3, limits);
}

test "an unbound error in a test cascades after an errored form, and across nested sections" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try runFake(arena.allocator(),
        \\(import (scheme base) (chibi test))
        \\(test-begin "all")
        \\(test-begin "a")
        \\(car 5)
        \\(test 1 nowhere-defined)
        \\(test-end)
        \\(test-begin "p")
        \\(define q (open-input-string 4))
        \\(test-begin "n")
        \\(test 1 nowhere-else)
        \\(test-end)
        \\(test-end)
        \\(test-end)
    );
    // 誤りで終わった形式も、テストの中の未束縛の誤りを連鎖にする。
    try std.testing.expectEqual(Counts{ .errored = 1, .cascaded = 1 }, try findSection(r, "a"));
    // 判定は外側の節ごとなので、親の節の未実装が、入れ子の節の行の連鎖になる。
    try std.testing.expectEqual(Counts{ .unimplemented = 1 }, try findSection(r, "p"));
    try std.testing.expectEqual(Counts{ .cascaded = 1 }, try findSection(r, "n"));
}

test "a name with > or bars defined in an earlier section is caught when a later one uses it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.CrossSectionReference, runFake(a,
        \\(import (scheme base) (chibi test))
        \\(test-begin "all")
        \\(test-begin "a")
        \\(define a->b 1)
        \\(test-end)
        \\(test-begin "b")
        \\(test 1 a->b)
        \\(test-end)
        \\(test-end)
    ));
    // 値として未束縛の文字列を含むだけの不一致は、節をまたぐ参照ではない。
    const r = try runFake(a,
        \\(import (scheme base) (chibi test))
        \\(test-begin "all")
        \\(test-begin "a")
        \\(define x 1)
        \\(test-end)
        \\(test-begin "b")
        \\(test "unbound variable: x" "no")
        \\(test-end)
        \\(test-end)
    );
    try std.testing.expectEqual(Counts{ .failed = 1 }, try findSection(r, "b"));
}

test "a top-level form that uses a name only an earlier section defined stops the run" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // テストの中でなく、最上位の形式の誤りの経路を通る。
    try std.testing.expectError(error.CrossSectionReference, runFake(a,
        \\(import (scheme base) (chibi test))
        \\(test-begin "all")
        \\(test-begin "a")
        \\(define y 1)
        \\(test-end)
        \\(test-begin "b")
        \\(define z y)
        \\(test-end)
        \\(test-end)
    ));
    // 同じ名前を定義する形式の中で前の値を使うのも、前の節に頼っている。
    try std.testing.expectError(error.CrossSectionReference, runFake(a,
        \\(import (scheme base) (chibi test))
        \\(test-begin "all")
        \\(test-begin "a")
        \\(define y 1)
        \\(test-end)
        \\(test-begin "b")
        \\(define y (+ y 1))
        \\(test-end)
        \\(test-end)
    ));
    // 前の節で定義していない名前の未束縛は、ふつうの誤りである。同じ節で先に定義し直した名前は、
    // 未束縛にならない。
    const r = try runFake(a,
        \\(import (scheme base) (chibi test))
        \\(test-begin "all")
        \\(test-begin "a")
        \\(define y 1)
        \\(test-end)
        \\(test-begin "b")
        \\(define z never-defined)
        \\(define y 2)
        \\(test 2 y)
        \\(test-end)
        \\(test-end)
    );
    try std.testing.expectEqual(Counts{ .passed = 1, .errored = 1 }, try findSection(r, "b"));
}

test "a definition that is unreadable, raises, or cascades makes its users cascade" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // 節ごとに壊れた形式は1つだけにする。連鎖の判定が、その形式の名前だけで決まるようにするためである。
    const r = try runFake(arena.allocator(),
        \\(import (scheme base) (chibi test))
        \\(test-begin "all")
        \\(test-begin "unreadable")
        \\(define u '#u8(1 #e))
        \\(test 1 u)
        \\(test-end)
        \\(test-begin "raises")
        \\(define e (car 5))
        \\(test 1 e)
        \\(test-end)
        \\(test-begin "cascades")
        \\(define f (open-input-string 4))
        \\(define g f)
        \\(define h g)
        \\(test 1 h)
        \\(test-end)
        \\(test-end)
    );
    try std.testing.expectEqual(Counts{ .unreadable = 1, .cascaded = 1 }, try findSection(r, "unreadable"));
    try std.testing.expectEqual(Counts{ .errored = 1, .cascaded = 1 }, try findSection(r, "raises"));
    // `h` の定義はテストの外なので、`g` が連鎖のもとにならなければ、誤りとして数えられる。
    try std.testing.expectEqual(Counts{ .unimplemented = 1, .cascaded = 3 }, try findSection(r, "cascades"));
}

test "a record of a group the runner did not open stops the run, and a repeated name adds up" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.QueryFailed, runFake(a,
        \\(import (scheme base) (chibi test))
        \\(test-begin "all")
        \\(test-begin "a")
        \\(test-begin  "z")
        \\(test 1 1)
        \\(test-end)
        \\(test-end)
    ));
    const r = try runFake(a,
        \\(import (scheme base) (chibi test))
        \\(test-begin "all")
        \\(test-begin "a")
        \\(test 1 1)
        \\(test-end)
        \\(test-begin "a")
        \\(test 2 2)
        \\(test-end)
        \\(test-end)
    );
    try std.testing.expectEqual(@as(usize, 1), r.sections.len);
    try std.testing.expectEqual(Counts{ .passed = 2 }, try findSection(r, "a"));
}

test "redefining length or vector-ref in the suite does not hide records" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try runFake(arena.allocator(),
        \\(import (scheme base) (chibi test))
        \\(test-begin "all")
        \\(test-begin "a")
        \\(define (length x) 0)
        \\(define (vector-ref v i) 'no)
        \\(define (list-ref l i) 'no)
        \\(test 1 1)
        \\(test 2 3)
        \\(test-end)
        \\(test-end)
    );
    try std.testing.expectEqual(Counts{ .passed = 1, .failed = 1 }, try findSection(r, "a"));
}
