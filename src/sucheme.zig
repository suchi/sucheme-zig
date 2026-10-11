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
const expand = @import("syntax/expand.zig");
const machine = @import("machine.zig");
const context = @import("context.zig");
const printer = @import("printer.zig");

/// Every way `evalPrint` can fail.
///
/// `Raised` は Scheme のエラーで、その条件オブジェクトはコンテキストにあり、
/// `diagnostic` がそれを説明する。リーダのエラーも同じ形で説明する。
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

    pub fn init(self: *Interpreter, gpa: std.mem.Allocator) error{OutOfMemory}!void {
        return self.initWithOptions(gpa, .{});
    }

    pub fn initWithOptions(self: *Interpreter, gpa: std.mem.Allocator, options: heap.Options) error{OutOfMemory}!void {
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        self.ctx = try .initWithOptions(self.arena.allocator(), gpa, options);
    }

    pub fn deinit(self: *Interpreter) void {
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
        self.ctx.clearDiagnostic();
        self.run(arena, source, out) catch |e| {
            if (self.ctx.diagnostic().len == 0) self.ctx.raise("{s}", .{describe(e)}) catch {};
            return e;
        };
    }

    /// The message for the error the last `evalPrint` returned.
    ///
    /// 次の呼び出しまで有効である。
    pub fn diagnostic(self: *const Interpreter) []const u8 {
        return self.ctx.diagnostic();
    }

    /// Whether `identifier` is bound: a global binding, or a special form.
    ///
    /// 準拠マトリクス(tools/coverage-report)が使う。名前を引くだけで、シンボルを
    /// インターンしない。読まれただけの名前はシンボル表にあるが、束縛ではない。
    /// 特殊形式は大域環境に束縛を持たず、展開器のキーワードである。キーワードは
    /// 隠すことも再定義することもできないので、どのインタプリタでも束縛済みである。
    pub fn isBound(self: *const Interpreter, identifier: []const u8) bool {
        if (expand.isKeyword(identifier)) return true;
        const id = self.ctx.symbols.index.get(identifier) orelse return false;
        return self.ctx.globals.lookup(id) != null;
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
            // 定義は何も出力しない。REPL が表示するのは値であり、これには
            // 外部表現がない。
            if (v.kind() == .unspecified) continue;
            try printer.write(out, arena, &self.ctx.symbols, v);
            try out.writeByte('\n');
        }
    }
};

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
        error.HeapLimit => context.heap_limit_message,
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
    // プリミティブは大域環境の束縛、特殊形式は展開器のキーワードである。
    try std.testing.expect(interp.isBound("+"));
    try std.testing.expect(interp.isBound(">="));
    for ([_][]const u8{ "define", "quote", "if", "lambda", "begin", "set!" }) |keyword| {
        try std.testing.expect(interp.isBound(keyword));
    }
    // Why: 未束縛の例は、プリミティブが増えても束縛されない名前にする。`call/cc` は
    // 段階2で入る(`car` はスライス 1k で束縛された)。
    try std.testing.expect(!interp.isBound("call/cc"));
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
