//! sucheme: an R7RS-small Scheme interpreter.
//!
//! インタプリタの公開の入口である。段階1の各スライスが、読んで評価できるものを
//! 増やしていく。各スライスが何を足すかは docs/plans/0003-phase1-minimal-slice.md に、
//! 育っていく先のモジュールは docs/design/architecture.md にある。

const std = @import("std");
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
const machine = @import("machine.zig");
const context = @import("context.zig");
const printer = @import("printer.zig");
const value = @import("value.zig");
const tier = @import("tier.zig");

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
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        self.ctx = try .initWithOptions(self.arena.allocator(), gpa, options);
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
            describeRaised(&w.writer, scratch, &self.ctx.symbols, v)
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
        const id = self.ctx.symbols.index.get(identifier) orelse return false;
        return self.ctx.globals.isBound(id);
    }

    fn run(self: *Interpreter, arena: std.mem.Allocator, source: []const u8, out: *std.Io.Writer) Error!void {
        // Why: 文字列・文字・シンボル名は妥当な UTF-8 であり(ADR-0008)、プログラムの
        // バイト列が入ってくるのはここ1か所だけである。検査は標準ライブラリのものを
        // 使い、不正になりうる形を並べたりしない(docs/design/platform-and-web.md)。
        if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
        var r: reader.Reader = .init(source);
        // 読んだものはその行より長生きする。`quote` が定義に渡せるからである。
        const sink: reader.Sink = .{ .alloc = self.ctx.persist, .heap = &self.ctx.heap, .symbols = &self.ctx.symbols };
        while (true) {
            // 2つの形の間では、コンテキストが持つもの以外は何も保持していない。
            // このためここもセーフポイントである。エラーで終わった行のゴミも、
            // 次の行を読む前にここで回収される。
            if (self.ctx.heap.shouldCollect()) self.ctx.collectIdle();
            const form = try r.next(arena, sink) orelse break;
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
        try printer.write(out, arena, &self.ctx.symbols, v);
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
        error.Incomplete => "unexpected end of input",
        error.UnexpectedCloseParen => "unexpected )",
        error.MissingDatum => "quote needs a datum",
        error.UnexpectedDot => "unexpected .",
        error.InvalidEscape => "invalid escape in string",
        error.InvalidCharacter => "invalid character",
        error.InvalidUtf8 => "invalid UTF-8 input",
        error.InvalidToken => "unreadable token",
        error.IntegerOutOfRange => "integer out of range",
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
    for ([_][]const u8{ "define", "quote", "if", "lambda", "begin", "set!", "define-syntax", "syntax-rules", "let-syntax", "letrec-syntax", "syntax-error" }) |keyword| {
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
