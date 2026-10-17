//! sucheme: an R7RS-small Scheme interpreter.
//!
//! インタプリタの公開の入口である。各段階のスライスが、読んで評価できるものを
//! 増やしていく。スライスの進み具合は docs/roadmap.md の「現在地」が指す計画書に、
//! 育っていく先のモジュールは docs/design/architecture.md にある。

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// Implementation name reported by `(features)` and the `--version` output.
pub const name = build_options.name;

/// Project version.
///
/// build.zig.zon の `.version` が唯一の正であり、build.zig がビルドオプションとして
/// そのまま渡す。
pub const version = build_options.version;

/// The GC heap, and the options that bound it.
pub const heap = @import("heap.zig");

const reader = @import("reader.zig");

/// Whether `source` ends inside a datum that more input could finish.
///
/// REPL の継続行の判定である(ADR-0014)。定義は `reader.isIncomplete` にある。
pub const isIncomplete = reader.isIncomplete;

const expand = @import("syntax/expand.zig");
const library = @import("syntax/library.zig");
/// Opens the files of libraries.
pub const resolve = @import("resolve.zig");
const machine = @import("machine.zig");
const context = @import("context.zig");
const printer = @import("printer.zig");
const value = @import("value.zig");
const tier = @import("tier.zig");
const embedded_lib = @import("embedded_lib");

/// The files under `lib/`, which every interpreter searches before the files beneath
/// its roots (src/resolve.zig).
/// `build.zig` が作る `embedded_lib` の一覧を、リゾルバの型に写す。内容は実行ファイルの
/// 読み取り専用の領域にあり、インタプリタは複製しない。
const embedded_files = blk: {
    var out: [embedded_lib.files.len]resolve.EmbeddedFile = undefined;
    for (embedded_lib.files, 0..) |f, i| out[i] = .{ .path = f.path, .data = f.data };
    break :blk out;
};

/// The embedded files as the resolver takes them.
const embedded: resolve.Embedded = .{ .files = &embedded_files };

/// Every way `evalPrint` can fail.
///
/// `Raised` は Scheme のエラーで、送出された値はコンテキストにあり、`diagnostic` が
/// それを説明する。リーダのエラーとホストの失敗も `diagnostic` が説明する。
pub const Error = reader.Error || expand.Error || machine.Error || printer.Error;

/// One interpreter: what outlives a single line of input.
///
/// リーダが作るデータとプログラムが実行中に作るものは GC ヒープにあり、そのヒープは
/// `gpa` が供給し、オプションが上限を定める。シンボルテーブル、グローバル環境、
/// コードは、インタプリタ専用のアリーナにある。これは docs/design/architecture.md
/// が例外として記録している。コンテキストはアリーナの中を指すので、インタプリタは
/// その場で初期化し、あとでコピーしない。
pub const Interpreter = struct {
    arena: std.heap.ArenaAllocator,
    ctx: context.Context,
    /// Where the description of the error the last `evalPrint` returned is
    /// written.
    /// 呼び出しのアリーナとヒープの外(`gpa`)にあるので、アリーナの解放にも GC にも
    /// 左右されない。書くたびに中身を入れ替え、`deinit` で返す。
    diagnostic_buffer: std.ArrayList(u8),
    /// What `diagnostic` returns: the contents of `diagnostic_buffer`, or a fixed
    /// text when the buffer could not hold the description.
    diagnostic_text: []const u8,

    pub fn init(self: *Interpreter, gpa: std.mem.Allocator) error{OutOfMemory}!void {
        return self.initWithOptions(gpa, .{});
    }

    pub fn initWithOptions(self: *Interpreter, gpa: std.mem.Allocator, options: heap.Options) error{OutOfMemory}!void {
        return self.initWithFiles(gpa, options, null);
    }

    /// Initializes an interpreter that opens the files of libraries with `files`,
    /// or one that has no file system, when `files` is null.
    /// `files` の探索ルートの文字列は、インタプリタが解放されるまで、呼び出し側が持つ。
    pub fn initWithFiles(self: *Interpreter, gpa: std.mem.Allocator, options: heap.Options, files: ?resolve.Files) error{OutOfMemory}!void {
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        self.ctx = try .initWithOptions(self.arena.allocator(), gpa, options);
        self.ctx.files = files;
        self.ctx.embedded = embedded;
        self.diagnostic_buffer = .empty;
        self.diagnostic_text = "";
    }

    pub fn deinit(self: *Interpreter) void {
        self.diagnostic_buffer.deinit(self.arena.child_allocator);
        self.ctx.deinit();
        self.arena.deinit();
    }

    /// Reads every datum in `source`, evaluates each in turn, and writes each
    /// result followed by a newline to `out`.
    ///
    /// 最初のエラーで止まる。それより前に書いた結果は書かれたままで、エラーは
    /// `diagnostic` が説明する。この呼び出しが実行中にだけ要るものは `arena` から
    /// 取り、呼び出し側が丸ごと解放する。リーダが作るデータはヒープにあり、何かが
    /// 参照している間は生きる。シンボルとコードはインタプリタ専用のアリーナに確保し、
    /// `deinit` まで生きる。
    pub fn evalPrint(self: *Interpreter, arena: std.mem.Allocator, source: []const u8, out: *std.Io.Writer) Error!void {
        // 前の行が送出した値は、ここで手放す。この行の GC が回収する。
        self.ctx.clearDiagnostic();
        self.diagnostic_text = "";
        self.run(arena, source, out) catch |e| {
            self.keepDiagnostic(arena, e);
            return e;
        };
    }

    /// The message for the error the last `evalPrint` returned.
    ///
    /// 次の呼び出しまで有効である。
    pub fn diagnostic(self: *const Interpreter) []const u8 {
        return self.diagnostic_text;
    }

    /// Writes the description of `e` for `diagnostic`: the value raised if
    /// there is one, or what the failure is.
    /// 送出された値は、条件オブジェクトならメッセージと irritant を、それ以外は
    /// `write` の形で書く(docs/design/runtime.md の未処理例外)。リーダの失敗と
    /// ホストの失敗は、ヒープに条件を作らずに説明する。`scratch` はプリンタの作業領域である。
    fn keepDiagnostic(self: *Interpreter, scratch: std.mem.Allocator, e: Error) void {
        self.diagnostic_buffer.clearRetainingCapacity();
        var w: std.Io.Writer.Allocating = .fromArrayList(self.arena.child_allocator, &self.diagnostic_buffer);
        const written = if (self.ctx.raised) |v|
            describeRaised(&w.writer, scratch, &self.ctx.heap.symbols, v)
        else
            w.writer.writeAll(describe(e));
        self.diagnostic_buffer = w.toArrayList();
        self.diagnostic_text = if (written) |_| self.diagnostic_buffer.items else |_| "out of memory";
    }

    /// Whether `identifier` is bound: a global binding, or a special form.
    ///
    /// 準拠マトリクス(tools/coverage-report)が使う。名前を引くだけで、シンボルを
    /// インターンせず、セルも作らない。読まれただけの名前はシンボル表にあるが、束縛
    /// ではない。答えは REPL の最上位の束縛の表から出す(src/env.zig)。特殊形式は
    /// 最上位の構文の束縛で、変数はセルに値があるときだけ束縛済みである。
    pub fn isBound(self: *const Interpreter, identifier: []const u8) bool {
        const id = self.ctx.heap.symbols.lookup(identifier) orelse return false;
        return self.ctx.globals.isBound(id);
    }

    fn run(self: *Interpreter, arena: std.mem.Allocator, source: []const u8, out: *std.Io.Writer) Error!void {
        // Why: 文字列・文字・シンボル名は妥当な UTF-8 であり(ADR-0008)、プログラムの
        // バイト列が入ってくるのはここ1か所だけである。検査は標準ライブラリのものを
        // 使い、不正になりうる形を並べたりしない(docs/design/platform-and-web.md)。
        if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
        var r: reader.Reader = .init(source);
        // 読んだものはその行より長生きする。`quote` が定義に渡せるからである。
        const sink: reader.Sink = .{ .heap = &self.ctx.heap };
        while (true) {
            // 2つの形の間では、コンテキストが持つもの以外は何も保持していない。
            // このためここもセーフポイントである。エラーで終わった行のゴミも、
            // 次の行を読む前にここで回収される。
            if (self.ctx.heap.shouldCollect()) self.ctx.collectIdle();
            const form = try r.next(arena, sink) orelse break;
            // `import` と `define-library` は最上位の形式で、何も表示しない。
            if (library.topLevelForm(&self.ctx, form)) |kind| {
                switch (kind) {
                    .import => try library.importIntoRepl(&self.ctx, arena, form),
                    .define_library => try library.defineLibrary(&self.ctx, arena, form),
                }
                continue;
            }
            const node = try expand.expand(&self.ctx, arena, form);
            var m: machine.Machine = .init(&self.ctx, arena);
            const v = try m.run(node);
            // 最上位の REPL は、複数値を受け取る(docs/design/runtime.md の複数値の表)。
            // 値を1行に1つずつ書き、0個なら何も書かない。
            if (v.asMultipleValues()) |multiple| {
                for (multiple.items) |item| try self.printResult(out, arena, item);
            } else try self.printResult(out, arena, v);
        }
    }

    /// Writes `v`, a result of a form, and a newline, unless it is the
    /// unspecified value.
    /// 定義は何も出力しない。最上位の未規定値も表示しない。データの中の未規定値は、
    /// プリンタが `#<unspecified>` と書く。複数値の1つが未規定値のときも、1つの結果と
    /// して同じく表示しない。
    fn printResult(self: *const Interpreter, out: *std.Io.Writer, arena: std.mem.Allocator, v: value.Value) Error!void {
        if (v.kind() == .unspecified) return;
        try printer.write(out, arena, &self.ctx.heap.symbols, v);
        try out.writeByte('\n');
    }
};

/// The most bytes a description writes of the values it shows: the irritants
/// of a condition, or a value raised that is not a condition.
/// Why: プリミティブの失敗の irritant は呼び出しの引数なので、長いリストやベクタがそのまま
/// 診断に入りうる。WASM の境界は診断の一行を固定の大きさのバッファに書く(`src/wasm.zig` の
/// `sucheme_eval_begin`)。値の部分を切るのは、ふつうのメッセージの一行がそこに収まるためで
/// ある。診断そのものはメッセージを切らない。メッセージが長すぎて一行が収まらないときは、
/// 境界の側が一行を切る(`errorLine`)。
pub const shown_value_bytes = 128;

/// Writes `v`, a value raised, as `diagnostic` shows it.
/// 値の部分は `shown_value_bytes` までで切り、切ったら `...` を付ける。
fn describeRaised(out: *std.Io.Writer, scratch: std.mem.Allocator, symbols: *const @import("symbol.zig").Table, v: value.Value) printer.Error!void {
    var buf: [shown_value_bytes]u8 = undefined;
    var shown: std.Io.Writer = .fixed(&buf);
    const written = if (v.asCondition()) |c| blk: {
        // メッセージは文字列のはずだが、文字列でなくても panic せずに write の形で書く
        // (docs/design/runtime.md の未処理例外は、報告の経路で停止しないことを求める)。
        if (c.message.asString()) |text| try out.writeAll(text.bytes) else break :blk printer.write(&shown, scratch, symbols, c.message);
        break :blk writeIrritants(&shown, scratch, symbols, c.irritants);
    } else printer.write(&shown, scratch, symbols, v);
    written catch |e| switch (e) {
        error.WriteFailed => {
            try out.writeAll(wholeCharacters(shown.buffered()));
            return out.writeAll("...");
        },
        else => return e,
    };
    try out.writeAll(shown.buffered());
}

/// `bytes`, valid UTF-8 cut short at some byte, without the character the cut
/// fell in.
/// 診断は妥当な UTF-8 でなければならない(ADR-0008)。最後の先頭バイトから始まる列が、
/// その先頭バイトが示す長さに足りなければ、その列を落とす。
fn wholeCharacters(bytes: []const u8) []const u8 {
    var start = bytes.len;
    // 後続バイト(0b10xxxxxx)をさかのぼり、最後の文字の先頭を探す。文字は4バイトまでである。
    while (start > 0 and bytes.len - start < 4) {
        start -= 1;
        if (bytes[start] & 0xC0 != 0x80) break;
    }
    if (start == bytes.len) return bytes;
    const need = std.unicode.utf8ByteSequenceLength(bytes[start]) catch return bytes[0..start];
    return if (bytes.len - start < need) bytes[0..start] else bytes;
}

/// The line `error: <message>` and a newline, written in `buf`; when it does
/// not fit, the message is cut short at a character and `...` is put after it.
/// WASM の境界は、診断の一行を固定の大きさのバッファに書く(`src/wasm.zig` の
/// `sucheme_eval_begin`)。収まらない一行も、メッセージを失わずに、読める先頭を残す。
/// `message` は妥当な UTF-8 で、`buf` は `error: ...` と改行が入る大きさでなければならない。
pub fn errorLine(buf: []u8, message: []const u8) []const u8 {
    const prefix = "error: ";
    const cut_suffix = "...\n";
    std.debug.assert(buf.len >= prefix.len + cut_suffix.len);
    if (std.fmt.bufPrint(buf, prefix ++ "{s}\n", .{message})) |line| return line else |_| {}
    const kept = wholeCharacters(message[0 .. buf.len - prefix.len - cut_suffix.len]);
    return std.fmt.bufPrint(buf, prefix ++ "{s}" ++ cut_suffix, .{kept}) catch unreachable;
}

/// Writes each of `irritants`, a list, after a space.
fn writeIrritants(out: *std.Io.Writer, scratch: std.mem.Allocator, symbols: *const @import("symbol.zig").Table, irritants: value.Value) printer.Error!void {
    var it = irritants;
    while (it.asPair()) |p| : (it = p.cdr) {
        try out.writeByte(' ');
        try printer.write(out, scratch, symbols, p.car);
    }
}

/// The message for an error that nothing described more closely.
fn describe(e: Error) []const u8 {
    return switch (e) {
        error.Incomplete,
        error.UnexpectedCloseParen,
        error.MissingDatum,
        error.UnexpectedDot,
        error.InvalidEscape,
        error.InvalidCharacter,
        error.InvalidUtf8,
        error.InvalidToken,
        error.IntegerOutOfRange,
        error.InvalidByte,
        => |syntax| reader.describe(syntax),
        error.OutOfMemory => "out of memory",
        // 予約も尽きて条件を作れなかったときも、上限に達したことを伝える。
        error.HeapLimit, error.ReserveExhausted => context.heap_limit_message,
        else => @errorName(e),
    };
}

test {
    std.testing.refAllDecls(@This());
}

fn evalPrinted(src: []const u8) ![]const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    var w: std.Io.Writer = .fixed(&S.buf);
    try interp.evalPrint(arena.allocator(), src, &w);
    return w.buffered();
}

test "isBound answers for the primitives, the special forms and nothing else" {
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    // プリミティブは大域環境の束縛、特殊形式は REPL の最上位の構文の束縛である。
    try std.testing.expect(interp.isBound("+"));
    try std.testing.expect(interp.isBound(">="));
    for ([_][]const u8{ "define", "quote", "if", "lambda", "begin", "set!", "define-syntax", "syntax-rules", "let-syntax", "letrec-syntax", "syntax-error", "parameterize", "else", "=>", "_", "...", "unquote", "unquote-splicing" }) |keyword| {
        try std.testing.expect(interp.isBound(keyword));
    }
    // Why: 未束縛の例は、どの段階でも束縛されない名前にする。R7RS の名前は、いつか束縛される
    // (`car` はスライス 1k で、`call/cc` は段階2で束縛される)ので、例に使うとそのたびに落ちる。
    try std.testing.expect(!interp.isBound("no-such-procedure"));
    try std.testing.expect(!interp.isBound("frobnicate"));
    try std.testing.expect(!interp.isBound(""));
    // 名前の綴りが完全に一致するものだけを束縛済みとする。
    try std.testing.expect(!interp.isBound("++"));
    try std.testing.expect(!interp.isBound("Define"));
}

test "isBound follows definitions, and a name that was only read is not bound" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // リーダはシンボルをインターンするが、インターンは束縛ではない。
    try interp.evalPrint(arena.allocator(), "'seen", &w);
    try std.testing.expect(!interp.isBound("seen"));
    // 仮引数は局所の束縛で、最上位の束縛ではない。
    try interp.evalPrint(arena.allocator(), "((lambda (zork) zork) 1)", &w);
    try std.testing.expect(!interp.isBound("zork"));
    try interp.evalPrint(arena.allocator(), "(define x 1)", &w);
    try std.testing.expect(interp.isBound("x"));
    // 失敗した行が定義しなかった名前は束縛されない。
    try std.testing.expectError(error.Raised, interp.evalPrint(arena.allocator(), "(define y nope)", &w));
    try std.testing.expect(!interp.isBound("y"));
}

test "a failed import binds nothing, and a successful one is kept for the next line" {
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    try expectLinePrints(&interp, "(define-syntax kar (syntax-rules () ((_) 'macro)))", "");
    try expectLineFails(&interp, "(import (rename (only (sucheme core) car) (car kar)) (only (sucheme core) nope))", "bad import: nope is not exported by the import set");
    // 先の集合は束縛されず、REPL のマクロはそのままである。
    try expectLinePrints(&interp, "(kar)", "macro\n");
    try expectLinePrints(&interp, "(import (rename (only (sucheme core) car) (car kar)))", "");
    try expectLinePrints(&interp, "(kar '(1 2))", "1\n");
}

test "a library whose definition fails leaves nothing behind, and the same definition can be tried again" {
    for ([_]bool{ false, true }) |stress| {
        var interp: Interpreter = undefined;
        try interp.initWithOptions(std.testing.allocator, .{ .stress = stress });
        defer interp.deinit();
        const definition = "(define-library (t a) (export f) (import (sucheme core)) (begin (define (f) 1) (define x (car 5))))";
        // 実行の誤り、展開の誤り、本体の終わりの未束縛の識別子のどれも、登録を残さない。
        try expectLineFails(&interp, definition, "wrong type of argument to car 5");
        try expectLineFails(&interp, "(import (t a))", "unknown library: (t a)");
        try expectLineFails(&interp, "(define-library (t a) (export f) (import (sucheme core)) (begin (if)))", "bad if: expected (if test consequent) or (if test consequent alternative)");
        try expectLineFails(&interp, "(import (t a))", "unknown library: (t a)");
        try expectLineFails(&interp, "(define-library (t a) (export f) (import (only (sucheme core) define)) (begin (define (f) (g))))", "unbound identifier in library (t a): g");
        try expectLineFails(&interp, "(import (t a))", "unknown library: (t a)");
        // REPL の最上位には、何も束縛されない。
        try expectLineFails(&interp, "f", "unbound variable: f");
        try std.testing.expectEqual(0, interp.ctx.libraries.list.items.len);
        // 失敗したライブラリのオブジェクトは、次の GC で回収される。
        interp.ctx.collectIdle();
        try std.testing.expectEqual(0, interp.ctx.heap.countOf(value.Library));
        try std.testing.expectEqual(0, interp.ctx.heap.countOf(value.Export));
        // 同じ名前で、正しい定義が通る。
        try expectLinePrints(&interp, "(define-library (t a) (export f) (import (sucheme core)) (begin (define (f) 1)))", "");
        try expectLinePrints(&interp, "(import (t a)) (f)", "1\n");
        try std.testing.expectEqual(1, interp.ctx.libraries.list.items.len);
        // 定義し直すことはできない。
        try expectLineFails(&interp, "(define-library (t a) (export) (import (sucheme core)))", "bad define-library: the library (t a) is already defined");
        try expectLinePrints(&interp, "(f)", "1\n");
    }
}

test "a closure that a failed library handed to a live library keeps reaching its cells" {
    for ([_]bool{ false, true }) |stress| {
        var interp: Interpreter = undefined;
        try interp.initWithOptions(std.testing.allocator, .{ .stress = stress });
        defer interp.deinit();
        // 生きているライブラリ (t a) が、ほかのライブラリのクロージャを状態に残せる。
        try expectLinePrints(&interp, "(define-library (t a) (export register! run-all) (import (sucheme core)) (begin (define handlers '()) (define (register! f) (set! handlers (cons f handlers))) (define (run-all) (if (null? handlers) 'none ((car handlers))))))", "");
        // (t b) は、自分のセル x を指すクロージャを (t a) に渡してから失敗する。
        try expectLineFails(&interp, "(define-library (t b) (export) (import (sucheme core) (t a)) (begin (define x (list 42)) (register! (lambda () (car x))) (car 5)))", "wrong type of argument to car 5");
        try expectLinePrints(&interp, "(import (t a))", "");
        // Why: 失敗した (t b) の表を手放すと、x のセルは、どこからも指されない。GC はコードを
        // たどらないので、回収されて、次の行が解放済みの値を読む。
        interp.ctx.collectIdle();
        interp.ctx.collectIdle();
        try expectLinePrints(&interp, "(run-all)", "42\n");
    }
}

test "the libraries, their exports and the macros they define survive the collections between lines, and a closure the library kept still reaches its cells" {
    for ([_]bool{ false, true }) |stress| {
        for ([_]usize{ 4096, 0 }) |capacity| {
            var interp: Interpreter = undefined;
            try interp.initWithOptions(std.testing.allocator, .{ .stress = stress, .work_capacity = capacity });
            defer interp.deinit();
            try expectLinePrints(&interp, "(define-library (t a) (export bump! get twice) (import (sucheme core)) (begin (define n (list 0)) (define (bump!) (set! n (list (+ (car n) 1)))) (define (get) (car n)) (define-syntax twice (syntax-rules () ((_ e) (begin e e))))))", "");
            try expectLinePrints(&interp, "(import (t a))", "");
            interp.ctx.collectIdle();
            try expectLinePrints(&interp, "(bump!) (twice (bump!)) (get)", "3\n");
            interp.ctx.collectIdle();
            try expectLinePrints(&interp, "(bump!) (get)", "4\n");
            // ライブラリと、書き出し(名前、意味、次)と、本体の環境が残っている。
            try std.testing.expectEqual(1, interp.ctx.heap.countOf(value.Library));
            try std.testing.expectEqual(3, interp.ctx.heap.countOf(value.Export));
            try std.testing.expectEqual(1, interp.ctx.libraries.list.items.len);
        }
    }
}

test "a library that imports another loads from the registry, and a library under a small heap limit ends with the heap's error" {
    var interp: Interpreter = undefined;
    try interp.initWithOptions(std.testing.allocator, .{ .limit = 256 * 1024, .min_threshold = 16 * 1024 });
    defer interp.deinit();
    try expectLinePrints(&interp, "(define-library (t a) (export f) (import (sucheme core)) (begin (define (f) 1)))", "");
    try expectLinePrints(&interp, "(define-library (t b) (export g) (import (sucheme core) (t a)) (begin (define (g) (+ (f) 1))))", "");
    try expectLinePrints(&interp, "(import (t b)) (g)", "2\n");
    // 本体が上限まで確保し続けると、その行だけが終わり、ライブラリは登録されない。
    try expectLineFails(&interp, "(define-library (t c) (export) (import (sucheme core)) (begin (define (grow acc) (grow (cons 1 acc))) (grow '())))", "heap limit exceeded");
    try expectLineFails(&interp, "(import (t c))", "unknown library: (t c)");
    try expectLinePrints(&interp, "(g)", "2\n");
}

/// Starts `interp` on the files beneath `tree`, the way the tests of the libraries
/// that are files do.
fn initOnTree(interp: *Interpreter, tree: *resolve.Tree, stress: bool) !void {
    try interp.initWithFiles(std.testing.allocator, .{ .stress = stress }, .{ .io = std.testing.io, .roots = &tree.roots });
}

test "a library that is not defined is read from the file of its name beneath a root" {
    for ([_]bool{ false, true }) |stress| {
        var tree: resolve.Tree = undefined;
        try tree.init(std.testing.allocator);
        defer tree.deinit(std.testing.allocator);
        try tree.write("foo/bar.sld", "(define-library (foo bar) (export f) (import (sucheme core)) (begin (define (f) 1)))");
        var interp: Interpreter = undefined;
        try initOnTree(&interp, &tree, stress);
        defer interp.deinit();
        try expectLinePrints(&interp, "(import (foo bar)) (f)", "1\n");
        try std.testing.expectEqual(1, interp.ctx.libraries.list.items.len);
    }
}

/// Writes the file of the library `name` beneath `tree`: a `define-library` form
/// that exports `export`, imports `(sucheme core)` and what `imports` lists, and
/// has `body`.
fn writeLibrary(tree: *resolve.Tree, comptime path: []const u8, comptime library_name: []const u8, comptime imports: []const u8, comptime body: []const u8) !void {
    try tree.write(path, "(define-library " ++ library_name ++ " (export) (import (sucheme core) " ++ imports ++ ") (begin " ++ body ++ "))");
}

test "a library whose file imports other libraries loads them in order, each once" {
    for ([_]bool{ false, true }) |stress| {
        var tree: resolve.Tree = undefined;
        try tree.init(std.testing.allocator);
        defer tree.deinit(std.testing.allocator);
        // (t a) -> (t b) と (t c)、(t b) -> (t c)。(t c) は2経路から届く。
        try tree.write("t/c.sld", "(define-library (t c) (export count-c) (import (sucheme core)) (begin (define n 0) (set! n (+ n 1)) (define (count-c) n)))");
        try tree.write("t/b.sld", "(define-library (t b) (export (rename b-up up)) (import (sucheme core) (t c)) (begin (define (b-up) (+ 10 (count-c)))))");
        try tree.write("t/a.sld", "(define-library (t a) (export a-up) (import (sucheme core) (t b) (t c)) (begin (define (a-up) (+ (up) (count-c)))))");
        var interp: Interpreter = undefined;
        try initOnTree(&interp, &tree, stress);
        defer interp.deinit();
        try expectLinePrints(&interp, "(import (t a)) (a-up)", "12\n");
        try std.testing.expectEqual(3, interp.ctx.libraries.list.items.len);
        // 読み込んだライブラリは、登録表にある。ファイルが無くなっても、同じライブラリを使う。
        try tree.tmp.dir.deleteTree(std.testing.io, "t");
        try expectLinePrints(&interp, "(import (t b)) (up)", "11\n");
        // 本体は1回しか走らない。
        try expectLinePrints(&interp, "(import (t c)) (count-c)", "1\n");
        try std.testing.expectEqual(3, interp.ctx.libraries.list.items.len);
    }
}

test "a library defined at the REPL is not looked for in a file" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("t/a.sld", "(define-library (t a) (export f) (import (sucheme core)) (begin (define (f) 'file)))");
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    try expectLinePrints(&interp, "(define-library (t a) (export f) (import (sucheme core)) (begin (define (f) 'repl)))", "");
    try expectLinePrints(&interp, "(import (t a)) (f)", "repl\n");
}

test "a file that defines another library than the one asked for is refused, the case of a letter too" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("t/a.sld", "(define-library (t b) (export) (import (sucheme core)))");
    try tree.write("t/c.sld", "(define-library (t C) (export) (import (sucheme core)))");
    try tree.write("t/d.sld", "(define-library (t d))");
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    try expectLineFails(&interp, "(import (t a))", "bad import: the file of the library (t a) defines the library (t b)");
    try expectLineFails(&interp, "(import (t c))", "bad import: the file of the library (t c) defines the library (t C)");
    // 照合に失敗したファイルは、何も登録しない。
    try std.testing.expectEqual(0, interp.ctx.libraries.list.items.len);
    // 名前が合えば、ほかの宣言が無くてもよい。
    try expectLinePrints(&interp, "(import (t d))", "");
}

test "a file that is not exactly one define-library form is refused, and says why" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("t/empty.sld", "  ; nothing\n");
    try tree.write("t/plain.sld", "(define x 1)");
    try tree.write("t/two.sld", "(define-library (t two)) (define-library (t three))");
    try tree.write("t/open.sld", "(define-library (t open)");
    try tree.write("t/bad.sld", "(define-library (t bad) #z)");
    try tree.write("t/utf.sld", "(define-library (t utf)) \xff");
    try tree.write("t/dir.sld/inner", "x");
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    try expectLineFails(&interp, "(import (t empty))", "cannot load the library (t empty): its file is empty");
    try expectLineFails(&interp, "(import (t plain))", "cannot load the library (t plain): its file must hold one (define-library ...) form");
    try expectLineFails(&interp, "(import (t two))", "cannot load the library (t two): its file holds more than one form");
    try expectLineFails(&interp, "(import (t open))", "cannot load the library (t open): unexpected end of input");
    try expectLineFails(&interp, "(import (t bad))", "cannot load the library (t bad): unreadable token");
    try expectLineFails(&interp, "(import (t utf))", "cannot load the library (t utf): its file is not valid UTF-8");
    // ディレクトリは、ファイルではないので、見つからない。
    try expectLineFails(&interp, "(import (t dir))", "unknown library: (t dir)");
    try std.testing.expectEqual(0, interp.ctx.libraries.list.items.len);
}

test "an include at the REPL reads the file beneath the working directory, in order" {
    for ([_]bool{ false, true }) |stress| {
        var tree: resolve.Tree = undefined;
        try tree.init(std.testing.allocator);
        defer tree.deinit(std.testing.allocator);
        try tree.write("a.scm", "(define x 1)");
        try tree.write("b.scm", "(define y (+ x 10)) (define (twice n) (* n 2))");
        try tree.write("sub/c.scm", "(define z (twice y))");
        try tree.write("empty.scm", "; nothing\n");
        var interp: Interpreter = undefined;
        try initOnTree(&interp, &tree, stress);
        defer interp.deinit();
        try expectLinePrints(&interp, "(include \"a.scm\")", "");
        try expectLinePrints(&interp, "x", "1\n");
        // 複数のファイルは、書いた順に読まれ、後のものは前のものの定義を使える。
        try expectLinePrints(&interp, "(include \"b.scm\" \"sub/c.scm\") z", "22\n");
        // データの無いファイルは、何もしない。
        try expectLinePrints(&interp, "(include \"empty.scm\")", "");
        try expectLinePrints(&interp, "(begin (include \"a.scm\") x)", "1\n");
        // 式の位置でも、ファイルの式の値が、その位置の値になる。
        try tree.write("e.scm", "(+ n 1)");
        try expectLinePrints(&interp, "((lambda (n) (include \"e.scm\")) 5)", "6\n");
        // 読み込みの失敗は、その行を打ち切るだけで、次の行は読める。
        try expectLineFails(&interp, "(include \"missing.scm\")", "bad include: missing.scm: no such file");
        try expectLinePrints(&interp, "x", "1\n");
    }
}

test "a macro the included file defines is used by the forms after it" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("m.scm", "(define-syntax twice (syntax-rules () ((_ e) (* 2 e)))) (define v (twice 21))");
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    try expectLinePrints(&interp, "(include \"m.scm\") v", "42\n");
    try expectLinePrints(&interp, "(twice 4)", "8\n");
}

test "a file name of an include is relative to the file that includes it, in a library too" {
    for ([_]bool{ false, true }) |stress| {
        var tree: resolve.Tree = undefined;
        try tree.init(std.testing.allocator);
        defer tree.deinit(std.testing.allocator);
        try tree.write("p/q/lib.sld", "(define-library (p q lib) (export f g h) (import (sucheme core)) " ++
            "(include \"helper.scm\") (begin (include \"../up.scm\") (define (h) (+ (f) (g)))))");
        try tree.write("p/q/helper.scm", "(define (f) 1)");
        try tree.write("p/up.scm", "(define (g) 20)");
        // 同じ名前のファイルが作業ディレクトリにあっても、ライブラリのファイルのディレクトリが先である。
        try tree.write("helper.scm", "(define (f) 1000)");
        var interp: Interpreter = undefined;
        try initOnTree(&interp, &tree, stress);
        defer interp.deinit();
        try expectLinePrints(&interp, "(import (p q lib)) (h)", "21\n");
        // ライブラリの外では、作業ディレクトリが基準に戻る。
        try expectLinePrints(&interp, "(include \"helper.scm\") (f)", "1000\n");
    }
}

test "include-library-declarations reads the declarations of a library from files" {
    for ([_]bool{ false, true }) |stress| {
        var tree: resolve.Tree = undefined;
        try tree.init(std.testing.allocator);
        defer tree.deinit(std.testing.allocator);
        try tree.write("t/lib.sld", "(define-library (t lib) (include-library-declarations \"decls.scm\" \"more.scm\") (begin (define (g) (+ 1 (f)))))");
        try tree.write("t/decls.scm", "(export f g) (import (sucheme core))");
        // 宣言のファイルの中の `include` は、そのファイルのディレクトリが基準になる。
        try tree.write("t/more.scm", "(begin (define (f) (offset)))  (include \"sub/off.scm\")");
        try tree.write("t/sub/off.scm", "(define (offset) 41)");
        var interp: Interpreter = undefined;
        try initOnTree(&interp, &tree, stress);
        defer interp.deinit();
        try expectLinePrints(&interp, "(import (t lib)) (g)", "42\n");
    }
}

test "a name that only a pending export of an included declaration file holds survives the body of the library" {
    for ([_]bool{ false, true }) |stress| {
        var tree: resolve.Tree = undefined;
        try tree.init(std.testing.allocator);
        defer tree.deinit(std.testing.allocator);
        try tree.write("t/lib.sld", "(define-library (t lib) (include-library-declarations \"decls.scm\") (begin (define (f) 1)) (include \"body.scm\"))");
        // 外部名 `exported-name` は、この宣言のファイルのデータと、保留の一覧にしか無い。
        try tree.write("t/decls.scm", "(export (rename f exported-name)) (import (sucheme core))");
        // 本体のファイルが、新しい名前を作る。名前が回収されていれば、その ID を使う。
        try tree.write("t/body.scm", "(define y1 1) (define y2 2) (define y3 3) (define y4 4)");
        var interp: Interpreter = undefined;
        try initOnTree(&interp, &tree, stress);
        defer interp.deinit();
        try expectLinePrints(&interp, "(import (t lib)) (exported-name)", "1\n");
    }
}

test "the internal name of an export that nothing defines is still the name when the body ends" {
    for ([_]bool{ false, true }) |stress| {
        var tree: resolve.Tree = undefined;
        try tree.init(std.testing.allocator);
        defer tree.deinit(std.testing.allocator);
        try tree.write("t/lib.sld", "(define-library (t lib) (include-library-declarations \"decls.scm\") (begin (define (f) 1)) (include \"body.scm\"))");
        try tree.write("t/decls.scm", "(export f (rename undefined-internal other-external)) (import (sucheme core))");
        try tree.write("t/body.scm", "(define y1 1) (define y2 2) (define y3 3) (define y4 4)");
        var interp: Interpreter = undefined;
        try initOnTree(&interp, &tree, stress);
        defer interp.deinit();
        try expectLineFails(&interp, "(import (t lib))", "unbound identifier in library (t lib): undefined-internal");
    }
}

/// Collects, and then makes names that nothing refers to, so that the ids the
/// collection freed are taken by other names.
/// Why: 回収した ID は次に作る名前が使う。印の漏れで ID を誤って回収しても、別の名前が作られ
/// なければ、元の名前が残って見えるので、漏れが検出されない。
fn churnSymbols(interp: *Interpreter) !void {
    interp.ctx.collectIdle();
    var buf: [24]u8 = undefined;
    for (0..64) |i| _ = try interp.ctx.heap.intern(std.fmt.bufPrint(&buf, "churn-{d}", .{i}) catch unreachable);
}

test "the symbols a program holds survive the collections, whatever holds them" {
    for ([_]bool{ false, true }) |stress| {
        for ([_]usize{ 4096, 0 }) |capacity| {
            var interp: Interpreter = undefined;
            try interp.initWithOptions(std.testing.allocator, .{ .stress = stress, .work_capacity = capacity });
            defer interp.deinit();
            // 名前を持つものが、それぞれ1つずつ、別の名前を持つ。
            //   foo: 大域変数のセルの名前。
            //   m: マクロの束縛のキー。マクロ自身は名前を持たない。
            //   abc: コードの定数のシンボル。
            //   b: 局所変数を読む節点の名前。未初期化のメッセージが使う。
            //   point: レコード型の名前。
            try expectLinePrints(&interp, "(define foo 1) (define-syntax m (syntax-rules () ((_) 42))) (define (f) 'abc) (define (h) (define a b) (define b 1) a) (define t (%make-record-type 'point 2))", "");
            try churnSymbols(&interp);
            try expectLinePrints(&interp, "foo (m) (f) t", "1\n42\nabc\n#<record-type point>\n");
            try expectLineFails(&interp, "(h)", "variable used before its definition: b");
            try churnSymbols(&interp);
            try churnSymbols(&interp);
            // 起動時に登録した名前は、`Core` の表のキーでしかない。使われる前でも回収されない。
            try expectLinePrints(&interp, "(vector-ref (vector 5 6) 1)", "6\n");
            try expectLinePrints(&interp, "foo (m) (f) t", "1\n42\nabc\n#<record-type point>\n");
            try expectLineFails(&interp, "(h)", "variable used before its definition: b");
            // 名前はどれも、元の ID のまま引ける。
            for ([_][]const u8{ "foo", "m", "abc", "b", "point", "vector-ref" }) |spelling| {
                const id = interp.ctx.heap.symbols.lookup(spelling) orelse return error.TestUnexpectedResult;
                try std.testing.expectEqualStrings(spelling, interp.ctx.heap.symbols.nameOf(id));
            }
        }
    }
}

test "a symbol made from a string stays the symbol of its name at every work list capacity" {
    for ([_]bool{ false, true }) |stress| {
        for ([_]usize{ 4096, 1, 0 }) |capacity| {
            var interp: Interpreter = undefined;
            try interp.initWithOptions(std.testing.allocator, .{ .stress = stress, .work_capacity = capacity });
            defer interp.deinit();
            try expectLinePrints(&interp, "(eq? 'abc (string->symbol \"abc\"))", "#t\n");
            // 名前から作ったシンボルだけが持つ名前は、値が持つ間は残る。
            try expectLinePrints(&interp, "(define z (string->symbol \"only-by-string\")) (define v (vector z))", "");
            try churnSymbols(&interp);
            try churnSymbols(&interp);
            try expectLinePrints(&interp, "(eq? 'abc (string->symbol \"abc\")) (symbol->string z) (eq? z (vector-ref v 0))", "#t\n\"only-by-string\"\n#t\n");
            try expectLinePrints(&interp, "(eq? z (string->symbol \"only-by-string\")) (eq? z 'only-by-string)", "#t\n#t\n");
            // 値を手放しても、コードの定数 `'only-by-string` が名前を持つので、残る。
            try expectLinePrints(&interp, "(set! z #f) (set! v #f)", "");
            interp.ctx.collectIdle();
            try std.testing.expect(interp.ctx.heap.symbols.lookup("only-by-string") != null);
        }
    }
}

test "a symbol that is not held is reclaimed, with the memory its name took" {
    var interp: Interpreter = undefined;
    try interp.initWithOptions(std.testing.allocator, .{});
    defer interp.deinit();
    const before = interp.ctx.heap.held();
    try expectLinePrints(&interp, "(quote some-name-nothing-keeps)", "some-name-nothing-keeps\n");
    try std.testing.expect(interp.ctx.heap.held() > before);
    // 定数は、コードを作った行のあとも、コンテキストが持つ(`code_roots`)。
    interp.ctx.collectIdle();
    try std.testing.expect(interp.ctx.heap.symbols.lookup("some-name-nothing-keeps") != null);
    // 読まれただけで、何にも使われない名前は、回収される。展開に失敗した形式の名前が、その例である。
    try expectLineFails(&interp, "(if read-only-name)", "bad if: expected (if test consequent) or (if test consequent alternative)");
    try std.testing.expect(interp.ctx.heap.symbols.lookup("read-only-name") != null);
    interp.ctx.collectIdle();
    try std.testing.expect(interp.ctx.heap.symbols.lookup("read-only-name") == null);
}

test "a file that includes itself, or is included by a file it includes, is refused" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("self.scm", "(include \"self.scm\")");
    try tree.write("a.scm", "(define a 1) (include \"b.scm\")");
    try tree.write("b.scm", "(define b 2) (include \"./a.scm\")");
    try tree.write("t/lib.sld", "(define-library (t lib) (export) (import (sucheme core)) (include \"lib.sld\"))");
    try tree.write("t/via.sld", "(define-library (t via) (export) (import (sucheme core)) (begin (include \"loop.scm\")))");
    try tree.write("t/loop.scm", "(include \"../t/via.sld\")");
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    try expectLineFails(&interp, "(include \"self.scm\")", "bad include: self.scm includes itself, directly or through other files");
    try expectLineFails(&interp, "(include \"a.scm\")", "bad include: ./a.scm includes itself, directly or through other files");
    // ライブラリのファイル自身を含むことも、同じ鎖である。
    try expectLineFails(&interp, "(import (t lib))", "bad include: lib.sld includes itself, directly or through other files");
    try expectLineFails(&interp, "(import (t via))", "bad include: ../t/via.sld includes itself, directly or through other files");
    // 失敗のあとは、読んでいる最中のファイルが空に戻り、同じ名前をもう一度含める。
    try std.testing.expectEqual(0, interp.ctx.sources.items.len);
    try tree.write("self.scm", "(define fixed 1)");
    try expectLinePrints(&interp, "(include \"self.scm\") fixed", "1\n");
}

test "the same file may be included twice, one after the other, but a chain of files is bounded" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("once.scm", "(define n (if (eq? 'n 'n) 1 2))");
    // 長さ 64 の鎖(最初のファイルを入れて 64 個)は読めて、もう 1 つ長いと実装制限になる。
    const max = source_limit();
    var name_buf: [32]u8 = undefined;
    for (0..max + 1) |i| {
        const file_name = try std.fmt.bufPrint(&name_buf, "c{d}.scm", .{i});
        var body_buf: [64]u8 = undefined;
        const body = if (i < max)
            try std.fmt.bufPrint(&body_buf, "(include \"c{d}.scm\")", .{i + 1})
        else
            "(define end 1)";
        try tree.write(file_name, body);
    }
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    try expectLinePrints(&interp, "(include \"once.scm\" \"once.scm\") n", "1\n");
    var expected: [128]u8 = undefined;
    try expectLineFails(&interp, "(include \"c0.scm\")", try std.fmt.bufPrint(&expected, "implementation restriction: files include one another more than {d} deep, at c{d}.scm", .{ max, max }));
    // 1つ短い鎖は読める。
    try tree.write(try std.fmt.bufPrint(&name_buf, "c{d}.scm", .{max - 1}), "(define end 1)");
    try expectLinePrints(&interp, "(include \"c0.scm\") end", "1\n");
}

fn source_limit() usize {
    return @import("syntax/source.zig").max_open_files;
}

test "a macro the first of two included files defines is used by the second, in the order they are named" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("m.scm", "(define-syntax twice (syntax-rules () ((_ e) (* 2 e))))");
    try tree.write("use.scm", "(define v (twice 21))");
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    try expectLinePrints(&interp, "(include \"m.scm\" \"use.scm\") v", "42\n");
    // 逆の順に書くと、マクロはまだ定義されていない(別のインタプリタで確かめる。マクロは残る)。
    var reversed: Interpreter = undefined;
    try initOnTree(&reversed, &tree, false);
    defer reversed.deinit();
    try expectLineFails(&reversed, "(include \"use.scm\" \"m.scm\") v", "unbound variable: twice");
}

test "a macro that expands to an include reads the file, and the include is the special form it was written as" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("a.scm", "(define x 7)");
    try tree.write("e.scm", "(+ 1 2)");
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    try expectLinePrints(&interp, "(define-syntax inc (syntax-rules () ((_ f) (include f))))", "");
    try expectLinePrints(&interp, "(inc \"a.scm\") x", "7\n");
    // 利用者が `include` を別の束縛で隠しても、マクロが導入した `include` は特殊形式のままである。
    try expectLinePrints(&interp, "(define (use include) (inc \"e.scm\") include) (use 3)", "3\n");
}

test "the search goes through the roots in order, and an include is read beneath the root that has the library" {
    for ([_]bool{ false, true }) |stress| {
        var tree: resolve.Tree = undefined;
        try tree.init(std.testing.allocator);
        defer tree.deinit(std.testing.allocator);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        // 第2のルートだけが、ライブラリを持つ。同じ名前の `h.scm` が、第1のルートにもある。
        try tree.write("one/lib/h.scm", "(define (h) 'from-the-first-root)");
        try tree.write("two/lib/x.sld", "(define-library (lib x) (export g) (import (sucheme core)) " ++
            "(include \"h.scm\") (begin (define (g) (h))))");
        // 読んだファイルの中の `include` も、そのファイルのあるルートを基準にする。
        try tree.write("one/lib/h2.scm", "(define (h2) 'from-the-first-root)");
        try tree.write("two/lib/h.scm", "(include \"h2.scm\") (define (h) (h2))");
        try tree.write("two/lib/h2.scm", "(define (h2) 'from-the-second-root)");
        const roots = [_][]const u8{ try tree.at(arena.allocator(), "one"), try tree.at(arena.allocator(), "two") };
        var interp: Interpreter = undefined;
        try interp.initWithFiles(std.testing.allocator, .{ .stress = stress }, .{ .io = std.testing.io, .roots = &roots });
        defer interp.deinit();
        try expectLinePrints(&interp, "(import (lib x)) (g)", "from-the-second-root\n");
        // REPL の `include` は、第1のルートを基準にする。
        try expectLinePrints(&interp, "(include \"lib/h.scm\") (h)", "from-the-first-root\n");
    }
}

test "the data of an include are held to the limit of the heap, from the first file on" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    // 100 KB の式の並びは、約 50000 個の節点になる。
    const ones = try std.testing.allocator.alloc(u8, 100 * 1024);
    defer std.testing.allocator.free(ones);
    for (ones, 0..) |*b, i| b.* = if (i % 2 == 0) '1' else ' ';
    try tree.write("ones.scm", ones);
    var small: Interpreter = undefined;
    try small.initWithFiles(std.testing.allocator, .{ .limit = 512 * 1024 }, .{ .io = std.testing.io, .roots = &tree.roots });
    defer small.deinit();
    // 小さい上限では、マクロの適用が無くても、ヒープの上限のエラーで終わり、次の行は読める。
    try expectLineFails(&small, "(include \"ones.scm\")", "heap limit exceeded");
    try expectLinePrints(&small, "(+ 1 2)", "3\n");
    // 既定の上限では、通る。名前を並べても、合計が上限を超えれば、同じエラーになる。
    var normal: Interpreter = undefined;
    try initOnTree(&normal, &tree, false);
    defer normal.deinit();
    try expectLinePrints(&normal, "(include \"ones.scm\") 5", "1\n5\n");
}

test "a file name of an include that leaves the root, is absolute, or cannot be a file is refused" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("sub/in.scm", "(define x 1)");
    try tree.write("outside.scm", "(define leaked 1)");
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    // ルートは、作業ディレクトリに当たる木の根である。その外へは出られない。
    try expectLineFails(&interp, "(include \"../outside.scm\")", "bad include: ../outside.scm: the file name goes up out of the directory the files are searched in");
    try expectLineFails(&interp, "(include \"/etc/passwd\")", "bad include: /etc/passwd: the file name must not be an absolute path");
    try expectLineFails(&interp, "(include \"\")", "bad include: : the file name is empty");
    try expectLineFails(&interp, "(include \"sub/\")", "bad include: sub/: the file name names a directory, not a file");
    try expectLineFails(&interp, "(include \"sub\")", "bad include: sub: no such file");
    try expectLineFails(&interp, "(include \"a\\\\b.scm\")", "bad include: a\\b.scm: a component of the file name has a character that is not allowed");
    try expectLineFails(&interp, "(include \"con.scm\")", "bad include: con.scm: a component of the file name is the name of a device");
    // 内側から `..` で戻る名前は、ルートの中なら読める。
    try expectLinePrints(&interp, "(include \"sub/../outside.scm\") leaked", "1\n");
}

test "an include does not follow a link, and reads nothing where there is no file system" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("real/a.scm", "(define x 1)");
    try tree.link("real", "alias", true);
    try tree.link("real/a.scm", "linked.scm", false);
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    try expectLineFails(&interp, "(include \"alias/a.scm\")", "bad include: alias/a.scm: the file, or a directory on the way to it, is a link");
    try expectLineFails(&interp, "(include \"linked.scm\")", "bad include: linked.scm: the file, or a directory on the way to it, is a link");
    var bare: Interpreter = undefined;
    try bare.init(std.testing.allocator);
    defer bare.deinit();
    try expectLineFails(&bare, "(include \"real/a.scm\")", "bad include: this interpreter has no files to read: real/a.scm");
}

test "an included file that is not valid text or does not read is refused with the name of the include" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("bad.scm", "(define x \xff)");
    try tree.write("open.scm", "(define x");
    try tree.write("hash.scm", "(define x #z)");
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    try expectLineFails(&interp, "(include \"bad.scm\")", "cannot include bad.scm: its file is not valid UTF-8");
    try expectLineFails(&interp, "(include \"open.scm\")", "cannot include open.scm: unexpected end of input");
    try expectLineFails(&interp, "(include \"hash.scm\")", "cannot include hash.scm: unreadable token");
    // 失敗した読み込みは、何も定義しない。
    try expectLineFails(&interp, "x", "unbound variable: x");
}

test "a cond-expand declaration of a library is chosen by the same requirements, and nests" {
    for ([_]bool{ false, true }) |stress| {
        var interp: Interpreter = undefined;
        try interp.initWithFiles(std.testing.allocator, .{ .stress = stress }, null);
        defer interp.deinit();
        try expectLinePrints(&interp, "(define-library (t a) (export x y z) (import (sucheme core)) " ++
            "(cond-expand ((and r7rs (not no-such-feature)) (begin (define x 1)) " ++
            "(cond-expand (sucheme (begin (define y 5))) (else (begin (define y 6))))) " ++
            "(else (begin (define x 2) (define y 3)))) " ++
            "(cond-expand (no-such-feature (begin (define z 'no))) (else (begin (define z 'yes)))))", "");
        try expectLinePrints(&interp, "(import (t a)) (list x y z)", "(1 5 yes)\n");
        // どの節も当てはまらず `else` も無い宣言は、何も足さない。
        try expectLinePrints(&interp, "(define-library (t b) (export) (import (sucheme core)) (cond-expand (no-such-feature (begin (define q 1)))))", "");
        try expectLinePrints(&interp, "(import (t b))", "");
    }
}

test "a cond-expand that is malformed is refused, whichever part of the requirement would have decided" {
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    const clause = "bad cond-expand: a clause is (<feature requirement> <body> ...) or (else <body> ...)";
    const requirement = "bad cond-expand: a feature requirement is an identifier or a list that starts with library, and, or or not";
    try expectLineFails(&interp, "(cond-expand r7rs)", clause);
    try expectLineFails(&interp, "(cond-expand ())", clause);
    try expectLineFails(&interp, "(cond-expand (else 1) (r7rs 2))", "bad cond-expand: the else clause must be the last");
    try expectLineFails(&interp, "(cond-expand (5 1))", requirement);
    try expectLineFails(&interp, "(cond-expand ((frob a) 1))", requirement);
    try expectLineFails(&interp, "(cond-expand (() 1))", requirement);
    try expectLineFails(&interp, "(cond-expand ((not) 1))", "bad cond-expand: expected (not <feature requirement>)");
    try expectLineFails(&interp, "(cond-expand ((not a b) 1))", "bad cond-expand: expected (not <feature requirement>)");
    try expectLineFails(&interp, "(cond-expand ((library) 1))", "bad cond-expand: expected (library <library name>)");
    try expectLineFails(&interp, "(cond-expand ((library (a) (b)) 1))", "bad cond-expand: expected (library <library name>)");
    try expectLineFails(&interp, "(cond-expand ((library 5) 1))", "bad library name: a name is a non-empty list of identifiers and non-negative integers");
    try expectLineFails(&interp, "(cond-expand ((and r7rs . x) 1))", "bad cond-expand: a feature requirement must be a proper list");
    // 部分の要求は、短絡せずにすべて調べる。前の部分が決めていても、後ろの誤りは見逃さない。
    try expectLineFails(&interp, "(cond-expand ((or r7rs (frob)) 1))", requirement);
    try expectLineFails(&interp, "(cond-expand ((and no-such-feature (frob)) 1))", requirement);
    // 当てはまる節の本体が、その位置で誤りなら、その誤りが出る。
    try expectLineFails(&interp, "(cond-expand (r7rs (frob)))", "unbound variable: frob");
    // 要求は、当てはまる節より後ろの節まで調べない。
    try expectLinePrints(&interp, "(cond-expand (r7rs 1) ((frob) 2))", "1\n");
    // 当てはまる節の本体が不正なリストなら、式の位置でも最上位でも宣言でも誤りである。
    const improper = "bad syntax: a form must be a proper list";
    try expectLineFails(&interp, "(cond-expand (r7rs 1 . 2))", improper);
    try expectLineFails(&interp, "(cond-expand (no-such-feature 1) (else 1 . 2))", improper);
    try expectLineFails(&interp, "(define-library (t improper) (export) (import (sucheme core)) (cond-expand (r7rs (export) . x)))", "bad cond-expand: expected a proper list");
}

test "the nesting of a feature requirement is bounded, and a chain at the bound is read" {
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    const max = @import("syntax/cond_expand.zig").max_depth;
    var buffer: [1024]u8 = undefined;
    for ([_]usize{ max, max + 1 }) |depth| {
        var w: std.Io.Writer = .fixed(&buffer);
        try w.writeAll("(cond-expand (");
        for (0..depth) |_| try w.writeAll("(not ");
        try w.writeAll("r7rs");
        for (0..depth) |_| try w.writeAll(")");
        try w.writeAll(" 'yes) (else 'no))");
        if (depth <= max) {
            // `not` を偶数回で、元の真偽に戻る。
            try expectLinePrints(&interp, w.buffered(), if (depth % 2 == 0) "yes\n" else "no\n");
        } else {
            var expected: [128]u8 = undefined;
            try expectLineFails(&interp, w.buffered(), try std.fmt.bufPrint(&expected, "implementation restriction: feature requirements are nested more than {d} deep", .{max}));
        }
    }
}

test "a library is available to a requirement when its file can be opened, and the file is not read" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    // 読み込めば、本体が誤りになる。要求が読み込むなら、先頭の行が誤りで終わる。
    try tree.write("foo/bar.sld", "(define-library (foo bar) (export) (import (sucheme core)) (begin (car 5)))");
    try tree.write("foo/dir.sld/inner", "x");
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    try expectLinePrints(&interp, "(cond-expand ((library (foo bar)) 'yes) (else 'no))", "yes\n");
    try expectLinePrints(&interp, "(cond-expand ((library (foo baz)) 'yes) (else 'no))", "no\n");
    try expectLinePrints(&interp, "(cond-expand ((library (foo dir)) 'yes) (else 'no))", "no\n");
    // 名前がファイルの名前にならなければ、偽である。誤りにはしない。
    try expectLinePrints(&interp, "(cond-expand ((library (con)) 'yes) (else 'no))", "no\n");
    try std.testing.expectEqual(0, interp.ctx.libraries.list.items.len);
    // 読み込みは、インポートがする。
    try expectLineFails(&interp, "(import (foo bar))", "wrong type of argument to car 5");
}

test "asking whether a library is available does not leave its file open" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("foo/bar.sld", "(define-library (foo bar) (export) (import (sucheme core)))");
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    // 開いたままにすると、記述子が尽きて開けなくなり、要求は偽になる。上限を低くして、繰り返す。
    const original = try std.posix.getrlimit(.NOFILE);
    try std.posix.setrlimit(.NOFILE, .{ .cur = @min(64, original.max), .max = original.max });
    defer std.posix.setrlimit(.NOFILE, original) catch {};
    for (0..300) |_| try expectLinePrints(&interp, "(cond-expand ((library (foo bar)) 'yes) (else 'no))", "yes\n");
}

test "a macro can expand to a cond-expand, and the names inside it are read as they were written" {
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    try expectLinePrints(&interp, "(define-syntax pick (syntax-rules () ((_ a b) (cond-expand ((and r7rs (not no-such-feature)) a) (else b)))))", "");
    try expectLinePrints(&interp, "(pick 1 2)", "1\n");
    // 利用者が、`and` や `else` と同じ綴りの変数を持っていても、要求の綴りには関係しない。
    try expectLinePrints(&interp, "((lambda (and else r7rs) (pick 1 2)) 7 8 9)", "1\n");
    // 特殊形式の名前は予約語ではない。
    try expectLinePrints(&interp, "((lambda (cond-expand) cond-expand) 5)", "5\n");
}

test "include-ci reads the file with identifiers and character names folded, and an include does not" {
    for ([_]bool{ false, true }) |stress| {
        var tree: resolve.Tree = undefined;
        try tree.init(std.testing.allocator);
        defer tree.deinit(std.testing.allocator);
        try tree.write("b.scm", "(DEFINE (F X) X)");
        try tree.write("lits.scm", "(Define c1 #\\A) (DEFINE C2 #\\NEWLINE) (define s \"MiXed\") (define C3 #\\X41)");
        var interp: Interpreter = undefined;
        try initOnTree(&interp, &tree, stress);
        defer interp.deinit();
        // 最初の失敗するテスト。
        try expectLinePrints(&interp, "(include-ci \"b.scm\") (f 1)", "1\n");
        // 同じファイルを `include` で読むと、畳み込まれず、`DEFINE` は未束縛である。
        try expectLineFails(&interp, "(include \"b.scm\")", "unbound variable: DEFINE");
        // 文字リテラルと文字列は畳み込まない。文字名と16進の `x` は畳み込む。
        try expectLinePrints(&interp, "(include-ci \"lits.scm\") (list c1 c2 s c3)", "(#\\A #\\newline \"MiXed\" #\\A)\n");
        // 複数のファイルは、どれも畳み込んで読み、後のものは前のものの定義を使える。
        try tree.write("m1.scm", "(DEFINE M1 1)");
        try tree.write("m2.scm", "(DEFINE M2 (+ M1 1))");
        try expectLinePrints(&interp, "(include-ci \"m1.scm\" \"m2.scm\") m2", "2\n");
        // 式の位置でも、同じである。
        try tree.write("e.scm", "(IF #T 1 2)");
        try expectLineFails(&interp, "(include-ci \"e.scm\")", "cannot include-ci e.scm: unreadable token");
        try tree.write("e2.scm", "(IF #t (QUOTE Abc) 2)");
        try expectLinePrints(&interp, "((lambda (n) (include-ci \"e2.scm\")) 5)", "abc\n");
        // 畳み込みは、読むファイルだけに効く。
        try expectLinePrints(&interp, "(quote Abc)", "Abc\n");
    }
}

test "the file that an include-ci file includes is read as an include reads it, and an include-ci there folds" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("outer.scm", "(INCLUDE \"plain.scm\") (Include-CI \"folded.scm\")");
    try tree.write("plain.scm", "(define Plain-Name 'p)");
    try tree.write("folded.scm", "(DEFINE Folded-Name 'f)");
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    // `outer.scm` の `INCLUDE` は畳み込まれて `include` になる。`plain.scm` は畳み込まずに読む。
    // 畳み込んだ読み手の `Include-CI` は `include-ci` で、`folded.scm` の名前は小文字になる。
    try expectLinePrints(&interp, "(include-ci \"outer.scm\") (list Plain-Name folded-name)", "(p f)\n");
    try expectLineFails(&interp, "plain-name", "unbound variable: plain-name");
    try expectLineFails(&interp, "Folded-Name", "unbound variable: Folded-Name");
}

test "an include-ci declaration of a library folds the file, and a library keeps its own names" {
    for ([_]bool{ false, true }) |stress| {
        var tree: resolve.Tree = undefined;
        try tree.init(std.testing.allocator);
        defer tree.deinit(std.testing.allocator);
        try tree.write("t/ci.sld", "(define-library (t ci) (export f g) (import (sucheme core)) (include-ci \"ci-body.scm\") (begin (define (g) (f))))");
        try tree.write("t/ci-body.scm", "(DEFINE (F) 7)");
        try tree.write("t/decls.scm", "(EXPORT h) (Import (sucheme core)) (BEGIN (define (h) 3))");
        try tree.write("t/decl.sld", "(define-library (t decl) (include-library-declarations \"decls.scm\"))");
        var interp: Interpreter = undefined;
        try initOnTree(&interp, &tree, stress);
        defer interp.deinit();
        try expectLinePrints(&interp, "(import (t ci)) (list (f) (g))", "(7 7)\n");
        // 名前が複数あっても、どのファイルも畳み込んで読む。
        try tree.write("t/ci2.sld", "(define-library (t ci2) (export u v) (import (sucheme core)) (include-ci \"u.scm\" \"v.scm\"))");
        try tree.write("t/u.scm", "(DEFINE (U) 1)");
        try tree.write("t/v.scm", "(DEFINE (V) (+ (U) 1))");
        try expectLinePrints(&interp, "(import (t ci2)) (v)", "2\n");
        // 宣言の綴りは畳み込まない。`include-library-declarations` は、畳み込む版を持たない。
        try expectLineFails(&interp, "(import (t decl))", "bad define-library: EXPORT is not a library declaration");
    }
}

test "include-ci refuses a file name and a file as include does, and says its own name" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("open.scm", "(define x");
    try tree.write("hash.scm", "(define x #z)");
    try tree.write("greek.scm", "(define \xce\xbb 1)");
    try tree.write("self.scm", "(include-ci \"self.scm\")");
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    try expectLineFails(&interp, "(include-ci)", "bad include-ci: expected (include-ci <file name> ...)");
    try expectLineFails(&interp, "(include-ci 1)", "bad include-ci: a file name must be a string");
    try expectLineFails(&interp, "(include-ci \"missing.scm\")", "bad include-ci: missing.scm: no such file");
    try expectLineFails(&interp, "(include-ci \"../x.scm\")", "bad include-ci: ../x.scm: the file name goes up out of the directory the files are searched in");
    try expectLineFails(&interp, "(include-ci \"open.scm\")", "cannot include-ci open.scm: unexpected end of input");
    try expectLineFails(&interp, "(include-ci \"hash.scm\")", "cannot include-ci hash.scm: unreadable token");
    try expectLineFails(&interp, "(include-ci \"self.scm\")", "bad include-ci: self.scm includes itself, directly or through other files");
    // ASCII でない文字の識別子は、畳み込む読み手も畳み込まない読み手も、まだ読めない。
    try expectLineFails(&interp, "(include-ci \"greek.scm\")", "cannot include-ci greek.scm: unreadable token");
    try expectLineFails(&interp, "(include \"greek.scm\")", "cannot include greek.scm: unreadable token");
    var bare: Interpreter = undefined;
    try bare.init(std.testing.allocator);
    defer bare.deinit();
    try expectLineFails(&bare, "(include-ci \"a.scm\")", "bad include-ci: this interpreter has no files to read: a.scm");
}

test "the clause of a cond-expand that applies may include a file, in an expression and in a library" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("native.scm", "(define where 'native)");
    try tree.write("other.scm", "(define where 'other)");
    try tree.write("t/lib.sld", "(define-library (t lib) (export w) (import (sucheme core)) " ++
        "(cond-expand (no-such-feature (include \"missing.scm\")) (else (include \"w.scm\"))))");
    try tree.write("t/w.scm", "(define w 'from-the-clause)");
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    try expectLinePrints(&interp, "(cond-expand ((and r7rs (not wasm)) (include \"native.scm\")) (else (include \"other.scm\"))) where", "native\n");
    try expectLinePrints(&interp, "(import (t lib)) w", "from-the-clause\n");
}

test "features returns the identifiers of the build in the order of its list, as a new list each time" {
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const joined = try std.mem.join(a, " ", @import("features.zig").names);
    const expected = try std.fmt.allocPrint(a, "({s})\n", .{joined});
    try expectLinePrints(&interp, "(features)", expected);
    try expectLinePrints(&interp, "(car (features))", "r7rs\n");
}

test "the nesting of the cond-expand declarations of a library is bounded, and a chain at the bound is read" {
    const max = library.max_declaration_depth;
    var buffer: [2048]u8 = undefined;
    for ([_]usize{ max - 1, max }) |depth| {
        var interp: Interpreter = undefined;
        try interp.init(std.testing.allocator);
        defer interp.deinit();
        var w: std.Io.Writer = .fixed(&buffer);
        try w.writeAll("(define-library (t deep) (export) (import (sucheme core)) ");
        for (0..depth) |_| try w.writeAll("(cond-expand (r7rs ");
        try w.writeAll("(export)");
        for (0..depth) |_| try w.writeAll("))");
        try w.writeAll(")");
        if (depth < max) {
            try expectLinePrints(&interp, w.buffered(), "");
        } else {
            var expected: [128]u8 = undefined;
            try expectLineFails(&interp, w.buffered(), try std.fmt.bufPrint(&expected, "implementation restriction: library declarations are nested more than {d} deep", .{max}));
        }
    }
}

test "a file of the largest size is read, and one byte more is refused before it is read" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    const blank = try std.testing.allocator.alloc(u8, library.max_file_bytes + 1);
    defer std.testing.allocator.free(blank);
    @memset(blank, ' ');
    try tree.write("t/fits.sld", blank[0..library.max_file_bytes]);
    try tree.write("t/over.sld", blank);
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    // 空白だけのファイルは、読まれて、空だと言われる。大きさの上限の手前で拒否されない。
    try expectLineFails(&interp, "(import (t fits))", "cannot load the library (t fits): its file is empty");
    var expected: [128]u8 = undefined;
    try expectLineFails(&interp, "(import (t over))", try std.fmt.bufPrint(&expected, "cannot load the library (t over): its file is larger than {d} bytes", .{library.max_file_bytes}));
    try std.testing.expectEqual(0, interp.ctx.libraries.list.items.len);
}

test "a library that cannot be loaded leaves nothing behind, and an error inside its body reaches the importer" {
    for ([_]bool{ false, true }) |stress| {
        var tree: resolve.Tree = undefined;
        try tree.init(std.testing.allocator);
        defer tree.deinit(std.testing.allocator);
        try tree.write("t/good.sld", "(define-library (t good) (export g) (import (sucheme core)) (begin (define (g) 1)))");
        try tree.write("t/bad.sld", "(define-library (t bad) (export) (import (sucheme core) (t good)) (begin (car 5)))");
        try tree.write("t/outer.sld", "(define-library (t outer) (export) (import (sucheme core) (t bad)))");
        var interp: Interpreter = undefined;
        try initOnTree(&interp, &tree, stress);
        defer interp.deinit();
        try expectLineFails(&interp, "(import (t outer))", "wrong type of argument to car 5");
        // 成功した依存は残り、失敗した2つは残らない。
        try std.testing.expectEqual(1, interp.ctx.libraries.list.items.len);
        try expectLinePrints(&interp, "(import (t good)) (g)", "1\n");
        // 直したファイルは、もう一度読まれる。
        try tree.write("t/bad.sld", "(define-library (t bad) (export) (import (sucheme core) (t good)) (begin (g)))");
        try expectLinePrints(&interp, "(import (t outer))", "");
        try std.testing.expectEqual(3, interp.ctx.libraries.list.items.len);
    }
}

test "libraries that import each other through files are a circular import" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try writeLibrary(&tree, "t/a.sld", "(t a)", "(t b)", "");
    try writeLibrary(&tree, "t/b.sld", "(t b)", "(t a)", "");
    try writeLibrary(&tree, "t/self.sld", "(t self)", "(t self)", "");
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    try expectLineFails(&interp, "(import (t a))", "bad import: circular import of the library (t a)");
    try expectLineFails(&interp, "(import (t self))", "bad import: circular import of the library (t self)");
    try std.testing.expectEqual(0, interp.ctx.libraries.list.items.len);
}

test "a chain of files that import one another is loaded to a depth, and refused beyond it" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    // 深さの上限 `max_load_depth` のうち、REPL の `import` が1つ使う。
    const fits = library.max_load_depth - 1;
    var path_buf: [32]u8 = undefined;
    var next_buf: [32]u8 = undefined;
    var text_buf: [160]u8 = undefined;
    for (0..fits + 1) |i| {
        const path = try std.fmt.bufPrint(&path_buf, "chain/l{d}.sld", .{i});
        const next = if (i == fits) "" else try std.fmt.bufPrint(&next_buf, "(chain l{d})", .{i + 1});
        const text = try std.fmt.bufPrint(&text_buf, "(define-library (chain l{d}) (export up{d}) (import (sucheme core) {s}) (begin (define (up{d}) {d})))", .{ i, i, next, i, i });
        try tree.write(path, text);
    }
    var interp: Interpreter = undefined;
    try initOnTree(&interp, &tree, false);
    defer interp.deinit();
    // 末尾(l{fits})は上限の外で、その1つ前までが入る。
    var expected_fail: [128]u8 = undefined;
    try expectLineFails(&interp, "(import (chain l0))", try std.fmt.bufPrint(&expected_fail, "implementation restriction: libraries import one another more than {d} deep, at (chain l{d})", .{ library.max_load_depth, fits }));
    try std.testing.expectEqual(0, interp.ctx.libraries.list.items.len);
    // 末尾を、何も import しない形にすれば、鎖の全体が入る。
    const last = try std.fmt.bufPrint(&path_buf, "chain/l{d}.sld", .{fits - 1});
    const text = try std.fmt.bufPrint(&text_buf, "(define-library (chain l{d}) (export up{d}) (import (sucheme core)) (begin (define (up{d}) {d})))", .{ fits - 1, fits - 1, fits - 1, fits - 1 });
    try tree.write(last, text);
    try expectLinePrints(&interp, "(import (chain l0)) (up0)", "0\n");
    try std.testing.expectEqual(fits, interp.ctx.libraries.list.items.len);
}

test "a link where a library file should be is refused, and the libraries of other roots stay reachable" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("outside/t/evil.sld", "(define-library (t evil) (export) (import (sucheme core)))");
    try tree.write("root/t/ok.sld", "(define-library (t ok) (export) (import (sucheme core)))");
    try tree.link("../../outside/t/evil.sld", "root/t/evil.sld", false);
    try tree.link("../outside/t", "root/t2", true);
    const root = try tree.at(std.testing.allocator, "root");
    defer std.testing.allocator.free(root);
    var interp: Interpreter = undefined;
    try interp.initWithFiles(std.testing.allocator, .{}, .{ .io = std.testing.io, .roots = &.{root} });
    defer interp.deinit();
    try expectLineFails(&interp, "(import (t evil))", "cannot load the library (t evil): its file, or a directory on the way to it, is a link");
    try expectLineFails(&interp, "(import (t2 evil))", "cannot load the library (t2 evil): its file, or a directory on the way to it, is a link");
    try expectLinePrints(&interp, "(import (t ok))", "");
}

test "a name that cannot be a file is refused with the reason, with a file system and without" {
    var tree: resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    var with: Interpreter = undefined;
    try initOnTree(&with, &tree, false);
    defer with.deinit();
    var without: Interpreter = undefined;
    try without.init(std.testing.allocator);
    defer without.deinit();
    for ([_]*Interpreter{ &with, &without }) |interp| {
        try expectLineFails(interp, "(import (CON))", "unknown library: (CON): a library with that name cannot be a file, because a component is the name of a device");
        try expectLineFails(interp, "(import (foo con.scm))", "unknown library: (foo con.scm): a library with that name cannot be a file, because a component is the name of a device");
        try expectLineFails(interp, "(import (a -1))", "bad library name: a name is a non-empty list of identifiers and non-negative integers");
        // 縦棒で囲んだ識別子は、リーダが段階5まで読めない。ここでは、読める綴りだけを確かめる。
        try expectLineFails(interp, "(import (foo bar.))", "unknown library: (foo bar.): a library with that name cannot be a file, because a component starts or ends with a dot");
        try expectLineFails(interp, "(import (foo +))", "unknown library: (foo +): a library with that name cannot be a file, because a component has a character other than A-Z a-z 0-9 - _ .");
    }
    // 検証を通る名前は、ファイルシステムが無ければ見つからないだけで、あっても無ければ同じである。
    try expectLineFails(&with, "(import (foo bar))", "unknown library: (foo bar)");
    try expectLineFails(&without, "(import (foo bar))", "unknown library: (foo bar)");
}

test "evalPrint writes each result on its own line" {
    try std.testing.expectEqualStrings("3\n", try evalPrinted("(+ 1 2)"));
    try std.testing.expectEqualStrings("1\n-2\n", try evalPrinted("1 -2"));
    try std.testing.expectEqualStrings("", try evalPrinted("  "));
}

test "evalPrint writes the values of a form one to a line, and nothing for no values" {
    try std.testing.expectEqualStrings("1\n2\n", try evalPrinted("(values 1 2)"));
    try std.testing.expectEqualStrings("", try evalPrinted("(values)"));
    try std.testing.expectEqualStrings("5\n", try evalPrinted("(values 5)"));
    // 複数値の1つが未規定値なら、最上位の未規定値と同じく書かない。
    try std.testing.expectEqualStrings("1\n", try evalPrinted("(values (if #f #f) 1)"));
    // 続く形式は、複数値のあとも続く。
    try std.testing.expectEqualStrings("1\n2\n3\n", try evalPrinted("(values 1 2) 3"));
}

test "multiple values that reach a continuation taking one value are reported, and the next line runs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // 1個を要求する継続に届いた複数値は、誤りとして報告され、次の行は影響を受けない。
    try std.testing.expectError(error.Raised, interp.evalPrint(arena.allocator(), "(+ 1 (values 1 2))", &w));
    try std.testing.expectEqualStrings("wrong number of values: expected 1, got 2", interp.diagnostic());
    try interp.evalPrint(arena.allocator(), "(+ 1 2)", &w);
    try std.testing.expectEqualStrings("3\n", w.buffered());
}

test "evalPrint stops at the first error and describes it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.Raised, interp.evalPrint(arena.allocator(), "1 (foo) 2", &w));
    try std.testing.expectEqualStrings("1\n", w.buffered());
    try std.testing.expectEqualStrings("unbound variable: foo", interp.diagnostic());
}

test "evalPrint describes a reader error, and a later success clears the message" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.Incomplete, interp.evalPrint(arena.allocator(), "(+ 1", &w));
    try std.testing.expectEqualStrings("unexpected end of input", interp.diagnostic());
    try interp.evalPrint(arena.allocator(), "1", &w);
    try std.testing.expectEqualStrings("", interp.diagnostic());
}

test "a definition survives into the next call, and prints nothing itself" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try interp.evalPrint(arena.allocator(), "(define x 41)", &w);
    try std.testing.expectEqualStrings("", w.buffered());
    try interp.evalPrint(arena.allocator(), "(+ x 1)", &w);
    try std.testing.expectEqualStrings("42\n", w.buffered());
}

test "a failed line keeps the definitions made before it and not the one that failed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.Raised, interp.evalPrint(arena.allocator(), "(define a 1) (define b nope)", &w));
    try interp.evalPrint(arena.allocator(), "a", &w);
    try std.testing.expectEqualStrings("1\n", w.buffered());
    try std.testing.expectError(error.Raised, interp.evalPrint(arena.allocator(), "b", &w));
    try std.testing.expectEqualStrings("unbound variable: b", interp.diagnostic());
}

test "two interpreters do not share definitions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var one: Interpreter = undefined;
    try one.init(std.testing.allocator);
    defer one.deinit();
    var two: Interpreter = undefined;
    try two.init(std.testing.allocator);
    defer two.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try one.evalPrint(arena.allocator(), "(define x 1)", &w);
    try std.testing.expectError(error.Raised, two.evalPrint(arena.allocator(), "x", &w));
}

test "a closure keeps its frame after the line that made it is gone" {
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    {
        // 最初の行のアリーナは、クロージャを呼ぶ前に解放される。
        var first: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer first.deinit();
        try interp.evalPrint(first.allocator(), "(define make (lambda (n) (lambda () (set! n (+ n 1)) n))) (define next (make 40))", &w);
    }
    var second: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer second.deinit();
    try interp.evalPrint(second.allocator(), "(next) (next)", &w);
    try std.testing.expectEqualStrings("41\n42\n", w.buffered());
}

test "a continuation captured on an earlier line runs the rest of the form it was captured in, and no line after it" {
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const lines = [_][]const u8{
        "(define k #f) (define log '()) (define (note x) (set! log (cons x log)))",
        // 捕捉した行の式は、定義と、その後ろの式である。
        "(define r (+ 1 (dynamic-wind (lambda () (note 'in)) (lambda () (call/cc (lambda (c) (set! k c) 0))) (lambda () (note 'out))))) (note 'after-the-define)",
        "r",
        // 後の行で起動すると、捕捉した式(定義)の残りだけが走る。wind 点へ再入するので
        // `before` が、出るときに `after` が呼ばれる。捕捉した行の後ろの式と、起動した行の
        // 後ろの式は走らない。起動した式の値は、捕捉した式の値(定義なので何も出ない)になる。
        "(begin (k 10) (note 'not-reached))",
        "r log",
    };
    for (lines) |line| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        try interp.evalPrint(arena.allocator(), line, &w);
    }
    try std.testing.expectEqualStrings("1\n11\n(out in after-the-define out in)\n", w.buffered());
}

test "a line that ends at the limit of the heap does not end the session" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = undefined;
    try interp.initWithOptions(std.testing.allocator, .{ .limit = 256 * 1024, .min_threshold = 16 * 1024 });
    defer interp.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try interp.evalPrint(arena.allocator(), "(define (forever n) (+ 1 (forever n))) (define keep 42)", &w);
    try std.testing.expectError(error.Raised, interp.evalPrint(arena.allocator(), "(forever 0)", &w));
    try std.testing.expectEqualStrings("heap limit exceeded", interp.diagnostic());
    // 失敗した行がヒープに残したものはゴミであり、次の行は読む前にそれを
    // 回収することから始まる。
    try interp.evalPrint(arena.allocator(), "(+ 1 2) keep", &w);
    try std.testing.expectEqualStrings("3\n42\n", w.buffered());
    try std.testing.expectEqualStrings("", interp.diagnostic());
    // もう一度。
    try std.testing.expectError(error.Raised, interp.evalPrint(arena.allocator(), "(forever 0)", &w));
    try interp.evalPrint(arena.allocator(), "(+ 20 22)", &w);
    try std.testing.expectEqualStrings("3\n42\n42\n", w.buffered());
}

test "a datum too large for the heap is refused with the same message" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = undefined;
    try interp.initWithOptions(std.testing.allocator, .{ .limit = 1024, .min_threshold = 512 });
    defer interp.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.HeapLimit, interp.evalPrint(arena.allocator(), "'(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30)", &w));
    try std.testing.expectEqualStrings("heap limit exceeded", interp.diagnostic());
    // 収まらなかったデータはゴミであり、小さいものなら収まる。
    try interp.evalPrint(arena.allocator(), "'(1 2)", &w);
    try std.testing.expectEqualStrings("(1 2)\n", w.buffered());
}

test "the data of a quoted list survives the collections between the lines that use it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = undefined;
    try interp.initWithOptions(std.testing.allocator, .{ .stress = true });
    defer interp.deinit();
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try interp.evalPrint(arena.allocator(), "(define xs '(1 2 3)) (define (get) '(4 5 6))", &w);
    try interp.evalPrint(arena.allocator(), "xs (get)", &w);
    try std.testing.expectEqualStrings("(1 2 3)\n(4 5 6)\n", w.buffered());
}

test "input that is not valid UTF-8 is refused whole, and the next line is read" {
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // これらは、それぞれ違う理由で不正である。単独の継続バイト、冗長な
    // エンコード、サロゲート(WTF-8 が対にならない UTF-16 サロゲートに使う
    // もの)、どの列も始まらないバイト、途中で切れた列。

    for ([_][]const u8{ "1 \x80", "\xC0\x80", "\xED\xA0\x80", "\xFF", "\xE3\x81" }) |src| {
        try std.testing.expectError(error.InvalidUtf8, interp.evalPrint(arena.allocator(), src, &w));
        try std.testing.expectEqualStrings("", w.buffered());
        try std.testing.expectEqualStrings("invalid UTF-8 input", interp.diagnostic());
    }
    try interp.evalPrint(arena.allocator(), "(+ 1 2)", &w);
    try std.testing.expectEqualStrings("3\n", w.buffered());
}

/// Evaluates `line` on `interp` and expects it to fail with `message`.
fn expectLineFails(interp: *Interpreter, line: []const u8, message: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.Raised, interp.evalPrint(arena.allocator(), line, &w));
    try std.testing.expectEqualStrings(message, interp.diagnostic());
}

/// Evaluates `line` on `interp` and expects it to write `output`.
fn expectLinePrints(interp: *Interpreter, line: []const u8, output: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try interp.evalPrint(arena.allocator(), line, &w);
    try std.testing.expectEqualStrings(output, w.buffered());
}

test "every primitive reports a wrong argument count, and the next line is read" {
    // 行ごとの列は REPL の読み取りと同じ形である(tests/scheme/ は1ケース1行で、
    // この続行を書けない)。表から数えるので、足したプリミティブは自動で含まれる。
    const table = @import("prim/table.zig");
    for ([_]bool{ false, true }) |stress| {
        var interp: Interpreter = undefined;
        try interp.initWithOptions(std.testing.allocator, .{ .stress = stress });
        defer interp.deinit();
        try expectLinePrints(&interp, "(define keep (list 1 \"あ\" #(2)))", "");
        var checked: usize = 0;
        for (table.all) |p| {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(std.testing.allocator);
            try line.print(std.testing.allocator, "({s}", .{p.name});
            if (p.min_args > 0) {
                // 下限に1つ足りない。
                for (0..p.min_args - 1) |_| try line.appendSlice(std.testing.allocator, " 1");
            } else if (p.max_args) |max| {
                // 上限を1つ超える。
                for (0..@as(usize, max) + 1) |_| try line.appendSlice(std.testing.allocator, " 1");
            } else continue; // 何個でも取る(`+` `*` `list` `vector`)。
            try line.append(std.testing.allocator, ')');
            var expected: std.ArrayList(u8) = .empty;
            defer expected.deinit(std.testing.allocator);
            try expected.print(std.testing.allocator, "wrong number of arguments to {s}", .{p.name});
            // irritant は、呼び出しに渡した引数である。
            for (0..std.mem.count(u8, line.items, " 1")) |_| try expected.appendSlice(std.testing.allocator, " 1");
            try expectLineFails(&interp, line.items, expected.items);
            // エラーのあとも、定義と評価が続く。
            try expectLinePrints(&interp, "(+ 1 2)", "3\n");
            checked += 1;
        }
        try std.testing.expect(checked > 0);
        try expectLinePrints(&interp, "keep", "(1 \"あ\" #(2))\n");
    }
}

test "an error of each kind leaves the interpreter and its definitions usable" {
    for ([_]bool{ false, true }) |stress| {
        var interp: Interpreter = undefined;
        try interp.initWithOptions(std.testing.allocator, .{ .stress = stress });
        defer interp.deinit();
        try expectLinePrints(&interp, "(define xs (list 1 2 3)) (define (len l) (if (null? l) 0 (+ 1 (len (cdr l)))))", "");
        const failures = [_]struct { line: []const u8, message: []const u8 }{
            .{ .line = "(car 1)", .message = "wrong type of argument to car 1" },
            .{ .line = "(vector-ref (vector 1) 1)", .message = "argument out of range in vector-ref #(1) 1" },
            .{ .line = "(string-ref \"あ\" 1)", .message = "argument out of range in string-ref \"あ\" 1" },
            .{ .line = "(integer->char 55296)", .message = "argument out of range in integer->char 55296" },
            .{ .line = "(quotient 1 0)", .message = "division by zero in quotient 1 0" },
            .{ .line = "(modulo 1 0)", .message = "division by zero in modulo 1 0" },
            .{ .line = "(quotient -9223372036854775808 -1)", .message = "integer overflow in quotient -9223372036854775808 -1" },
            .{ .line = "(* 9223372036854775807 2)", .message = "integer overflow in * 9223372036854775807 2" },
            .{ .line = "(length (cons 1 2))", .message = "wrong type of argument to length (1 . 2)" },
            .{ .line = "(len 5)", .message = "wrong type of argument to cdr 5" },
            .{ .line = "(vector-ref (vector 1) 4294967296)", .message = "argument out of range in vector-ref #(1) 4294967296" },
        };
        for (failures) |f| {
            try expectLineFails(&interp, f.line, f.message);
            // 失敗した行のデータはゴミになり、次の行の前に回収される。定義したものは残る。
            try expectLinePrints(&interp, "(len xs) xs", "3\n(1 2 3)\n");
        }
        // 1行の中のエラーは、その行の残りを評価しない。前の結果は残る。
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try std.testing.expectError(error.Raised, interp.evalPrint(arena.allocator(), "(len xs) (car 1) (len xs)", &w));
        try std.testing.expectEqualStrings("3\n", w.buffered());
    }
}

test "a primitive that runs the heap out of room ends only its line" {
    var interp: Interpreter = undefined;
    try interp.initWithOptions(std.testing.allocator, .{ .limit = 256 * 1024, .min_threshold = 16 * 1024 });
    defer interp.deinit();
    try expectLinePrints(&interp, "(define (grow-cons n acc) (grow-cons (+ n 1) (cons n acc))) (define (grow-list acc) (grow-list (list acc acc))) (define (grow-vector acc) (grow-vector (vector acc 1 2))) (define keep 42)", "");
    for ([_][]const u8{ "(grow-cons 0 '())", "(grow-list '())", "(grow-vector '())" }) |line| {
        try expectLineFails(&interp, line, "heap limit exceeded");
        try expectLinePrints(&interp, "(+ keep 1)", "43\n");
    }
}

test "a reader error is described without making a condition in the heap" {
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.Incomplete, interp.evalPrint(arena.allocator(), "(+ 1", &w));
    try std.testing.expectEqualStrings("unexpected end of input", interp.diagnostic());
    // 送出された値は無く、ヒープに条件は作られていない。
    try std.testing.expect(interp.ctx.raised == null);
    try std.testing.expectEqual(0, interp.ctx.heap.countOf(@import("value.zig").Condition));
}

test "the description outlives the arena of the call and the collections after it" {
    var interp: Interpreter = undefined;
    try interp.initWithOptions(std.testing.allocator, .{ .stress = true });
    defer interp.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.Raised, interp.evalPrint(arena.allocator(), "(car 5)", &w));
    }
    interp.ctx.clearDiagnostic();
    interp.ctx.collectIdle();
    try std.testing.expectEqualStrings("wrong type of argument to car 5", interp.diagnostic());
}

test "a condition kept as the value raised survives the collections until the next line clears it" {
    const Condition = @import("value.zig").Condition;
    for ([_]bool{ false, true }) |stress| {
        for ([_]usize{ 4096, 0 }) |capacity| {
            var interp: Interpreter = undefined;
            try interp.initWithOptions(std.testing.allocator, .{ .stress = stress, .work_capacity = capacity });
            defer interp.deinit();
            try expectLinePrints(&interp, "(define keep (list 1 2))", "");
            // ストレスモードが毎回 GC する範囲(短い実行)に収まるよう、行は短くしてある。
            try expectLineFails(&interp, "(define (f n) (if (= n 0) (car 5) (f (- n 1)))) (f 30)", "wrong type of argument to car 5");
            // 回収されずに残る経路: 失敗した行のあとの GC は、送出された値を残す。
            try std.testing.expectEqual(1, interp.ctx.heap.countOf(Condition));
            interp.ctx.collectIdle();
            try std.testing.expectEqual(1, interp.ctx.heap.countOf(Condition));
            try std.testing.expectEqualStrings("wrong type of argument to car", interp.ctx.diagnostic());
            // 回収される経路: 次の行は送出された値を空にしてから読む。ストレスモードでは、
            // その行の最初の GC が条件を回収する。
            try expectLinePrints(&interp, "keep", "(1 2)\n");
            if (!stress) interp.ctx.collectIdle();
            try std.testing.expectEqual(0, interp.ctx.heap.countOf(Condition));
            try std.testing.expect(interp.ctx.raised == null);
        }
    }
}

test "the value raised is described: a condition by its message and irritants, anything else as write shows it" {
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = &interp.ctx;
    const text = try ctx.heap.createString("a\"b");
    const irritants = try ctx.heap.cons(.fromFixnum(42), try ctx.heap.cons(.fromString(text), .empty_list_value));
    ctx.raised = try ctx.makeCondition(.@"error", "bad {s}", .{"thing"}, irritants);
    interp.keepDiagnostic(arena.allocator(), error.Raised);
    try std.testing.expectEqualStrings("bad thing 42 \"a\\\"b\"", interp.diagnostic());
    // メッセージが文字列でない条件も、停止せずに書く。
    ctx.raised = .fromCondition(try ctx.heap.create(@import("value.zig").Condition, .{ .kind = .@"error", .message = .fromFixnum(7), .irritants = .empty_list_value }));
    interp.keepDiagnostic(arena.allocator(), error.Raised);
    try std.testing.expectEqualStrings("7", interp.diagnostic());
    // 条件でない値は、write の形で書く。
    ctx.raised = .fromFixnum(42);
    interp.keepDiagnostic(arena.allocator(), error.Raised);
    try std.testing.expectEqualStrings("42", interp.diagnostic());
    ctx.raised = irritants;
    interp.keepDiagnostic(arena.allocator(), error.Raised);
    try std.testing.expectEqualStrings("(42 \"a\\\"b\")", interp.diagnostic());
    // 何も送出されていなければ、失敗そのものを説明する。
    ctx.raised = null;
    interp.keepDiagnostic(arena.allocator(), error.ReserveExhausted);
    try std.testing.expectEqualStrings("heap limit exceeded", interp.diagnostic());
    interp.keepDiagnostic(arena.allocator(), error.Incomplete);
    try std.testing.expectEqualStrings("unexpected end of input", interp.diagnostic());
}

test "when the description cannot be allocated, the diagnostic says out of memory" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    var interp: Interpreter = undefined;
    try interp.init(failing.allocator());
    defer interp.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = &interp.ctx;
    ctx.raised = try ctx.makeCondition(.@"error", "bad {s}", .{"thing"}, .empty_list_value);
    // ここから先の確保はすべて失敗する。説明のバッファはまだ確保されていない。
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    interp.keepDiagnostic(arena.allocator(), error.Raised);
    try std.testing.expectEqualStrings("out of memory", interp.diagnostic());
    // 確保できるようになれば、送出された値の説明に戻る。
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    interp.keepDiagnostic(arena.allocator(), error.Raised);
    try std.testing.expectEqualStrings("bad thing", interp.diagnostic());
}

test "the values a description shows are cut after a bound, and the message is kept whole" {
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try interp.evalPrint(arena.allocator(), "(define (build n acc) (if (= n 0) acc (build (- n 1) (cons n acc))))", &w);
    // 長い引数の irritant は、上限で切って `...` を付ける。メッセージは切らない。
    try std.testing.expectError(error.Raised, interp.evalPrint(arena.allocator(), "(length (build 1000 0))", &w));
    const d = interp.diagnostic();
    try std.testing.expect(std.mem.startsWith(u8, d, "wrong type of argument to length (1 2 3 4 5 "));
    try std.testing.expect(std.mem.endsWith(u8, d, "..."));
    try std.testing.expectEqual("wrong type of argument to length".len + shown_value_bytes + "...".len, d.len);
    // 条件でない値も同じである。
    try std.testing.expectError(error.Raised, interp.evalPrint(arena.allocator(), "(raise (build 1000 '()))", &w));
    try std.testing.expectEqual(shown_value_bytes + "...".len, interp.diagnostic().len);
    // 上限にちょうど収まる値は切らない。
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(std.testing.allocator);
    try line.appendSlice(std.testing.allocator, "(raise '");
    try line.appendNTimes(std.testing.allocator, 'x', shown_value_bytes);
    try line.append(std.testing.allocator, ')');
    try std.testing.expectError(error.Raised, interp.evalPrint(arena.allocator(), line.items, &w));
    try std.testing.expectEqual(shown_value_bytes, interp.diagnostic().len);
    // 長いメッセージは切らない。
    try std.testing.expectError(error.Raised, interp.evalPrint(arena.allocator(), "a-rather-long-name-that-is-not-bound-to-anything-at-all-in-this-interpreter-and-goes-on-for-a-long-while-longer-than-the-bound-on-values", &w));
    try std.testing.expectEqualStrings("unbound variable: a-rather-long-name-that-is-not-bound-to-anything-at-all-in-this-interpreter-and-goes-on-for-a-long-while-longer-than-the-bound-on-values", interp.diagnostic());
}

test "a description cut in the middle of a character is cut before the character" {
    var interp: Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // 値の部分は ` "` で始まるので、3バイトの文字が上限をまたぐ位置は、前に置く ASCII の
    // 文字の数で決まる。0 から 2 個で、文字のどのバイトでも切れる場合を通す。
    for (0..3) |pad| {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(std.testing.allocator);
        try line.appendSlice(std.testing.allocator, "(car \"");
        try line.appendNTimes(std.testing.allocator, 'a', pad);
        for (0..60) |_| try line.appendSlice(std.testing.allocator, "あ");
        try line.appendSlice(std.testing.allocator, "\")");
        try std.testing.expectError(error.Raised, interp.evalPrint(arena.allocator(), line.items, &w));
        const d = interp.diagnostic();
        try std.testing.expect(std.unicode.utf8ValidateSlice(d));
        try std.testing.expect(std.mem.endsWith(u8, d, "あ..."));
        // 落とすのは、切れた文字の書けた分(2バイトまで)だけである。
        try std.testing.expect(d.len + 2 >= "wrong type of argument to car".len + shown_value_bytes + "...".len);
    }
}

test "an error line that fits is written whole, and one that does not is cut short with ..." {
    var buf: [32]u8 = undefined;
    const xs: [330]u8 = @splat('x');
    // `error: ` と改行を足して 32 バイトに収まるのは、24 バイトのメッセージまでである。
    try std.testing.expectEqualStrings("error: short\n", errorLine(&buf, "short"));
    try std.testing.expectEqualStrings("error: xxxxxxxxxxxxxxxxxxxxxxxx\n", errorLine(&buf, xs[0..24]));
    // 1バイト溢れると、切って `...` を付ける。一行はバッファにちょうど収まる。
    try std.testing.expectEqualStrings("error: xxxxxxxxxxxxxxxxxxxxx...\n", errorLine(&buf, xs[0..25]));
    try std.testing.expectEqualStrings("error: xxxxxxxxxxxxxxxxxxxxx...\n", errorLine(&buf, &xs));
    try std.testing.expectEqualStrings("error: \n", errorLine(&buf, ""));
}

test "an error line cut in the middle of a character is cut before the character" {
    var buf: [32]u8 = undefined;
    // メッセージは 21 バイトまで残る。3バイトの文字が切れ目をまたぐ位置は、前に置く ASCII の
    // 文字の数で決まる。0 から 2 個で、文字のどのバイトでも切れる場合を通す。
    for (0..3) |pad| {
        var message: std.ArrayList(u8) = .empty;
        defer message.deinit(std.testing.allocator);
        try message.appendNTimes(std.testing.allocator, 'a', pad);
        for (0..20) |_| try message.appendSlice(std.testing.allocator, "あ");
        const line = errorLine(&buf, message.items);
        try std.testing.expect(std.unicode.utf8ValidateSlice(line));
        try std.testing.expect(std.mem.endsWith(u8, line, "あ...\n"));
        try std.testing.expect(line.len <= buf.len);
        // 落とすのは、切れた文字の書けた分(2バイトまで)だけである。
        try std.testing.expect(line.len + 2 >= buf.len);
    }
}

/// The bytes `a` has given out and not been given back.
fn held(a: *const std.testing.FailingAllocator) usize {
    return a.allocated_bytes - a.freed_bytes;
}

/// Evaluates the application of a macro that never stops, in an interpreter
/// whose heap is held to `limit`, and checks that the line ends at the limit and
/// that the memory behind the interpreter and the scratch arena stays near the
/// limit.
/// 計上しないときは、同じ上限で数倍から10倍のメモリを使う。計上すると、上限の1割ほどの
/// 余りで済む(アリーナの区切りと、節点のアロケータの切り上げ)。
fn expectBoundedExpansion(definition: []const u8, use: []const u8, limit: usize) !void {
    var gpa: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    var scratch_gpa: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    var arena: std.heap.ArenaAllocator = .init(scratch_gpa.allocator());
    defer arena.deinit();
    var interp: Interpreter = undefined;
    try interp.initWithOptions(gpa.allocator(), .{ .limit = limit, .min_threshold = @min(limit / 4, 1024 * 1024) });
    defer interp.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try interp.evalPrint(arena.allocator(), definition, &w);
    try std.testing.expectError(error.Raised, interp.evalPrint(arena.allocator(), use, &w));
    try std.testing.expectEqualStrings("heap limit exceeded", interp.diagnostic());
    const total = held(&gpa) + held(&scratch_gpa);
    if (total > limit + limit / 4) {
        std.debug.print("held {d} bytes against a limit of {d}\n", .{ total, limit });
        return error.TestUnexpectedResult;
    }
    // 展開の作業領域の計上は、行が終わったら戻る。次の行は、普通に評価される。
    try std.testing.expectEqual(0, interp.ctx.heap.external);
    try interp.evalPrint(arena.allocator(), "(+ 1 2)", &w);
    try std.testing.expectEqualStrings("3\n", w.buffered());
}

test "a macro that never stops ends at the limit of the heap, with the memory of the expansion counted" {
    try expectBoundedExpansion("(define-syntax f (syntax-rules () ((_) (f))))", "(f)", 1024 * 1024);
}

test "a macro that grows what it expands to ends at the limit of the heap" {
    try expectBoundedExpansion("(define-syntax f (syntax-rules () ((_ x ...) (f x ... x ...))))", "(f 1)", 1024 * 1024);
}

test "a macro that nests what it expands to ends at the limit of the heap" {
    try expectBoundedExpansion("(define-syntax f (syntax-rules () ((_ x) (f (g x)))))", "(f 1)", 1024 * 1024);
}

test "slow: a macro that never stops ends at the limit of the default heap" {
    try tier.slow();
    try expectBoundedExpansion("(define-syntax f (syntax-rules () ((_) (f))))", "(f)", heap.default_limit);
}
