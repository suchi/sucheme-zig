//! sucheme: an R7RS-small Scheme interpreter.
//!
//! The public entry to the interpreter. Each slice of stage 1 adds to what it
//! reads and evaluates; docs/plans/0003-phase1-minimal-slice.md lists what each
//! slice adds, and docs/design/architecture.md the modules it grows into.

const std = @import("std");
const build_options = @import("build_options");

/// Implementation name reported by `(features)` and the `--version` output.
pub const name = build_options.name;

/// Project version. build.zig.zon's `.version` is the single source of truth;
/// build.zig passes it through as a build option.
pub const version = build_options.version;

/// The GC heap, and the options that bound it.
pub const heap = @import("heap.zig");

const reader = @import("reader.zig");
const expand = @import("syntax/expand.zig");
const machine = @import("machine.zig");
const context = @import("context.zig");
const printer = @import("printer.zig");

/// Every way `evalPrint` can fail. `Raised` is a Scheme error, with its condition
/// in the context; `diagnostic` describes it. The reader's errors are described
/// the same way.
pub const Error = reader.Error || expand.Error || machine.Error || printer.Error;

/// One interpreter: what outlives a single line of input. The data the reader
/// builds and what a program makes while it runs are in the GC heap, which
/// `gpa` supplies and the options bound; the symbol table, the global
/// environment and the code are in an arena of the interpreter's own, which
/// docs/design/architecture.md records as the exception. The context points
/// into the arena, so an interpreter is initialised in place and not copied
/// after.
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
    /// Stops at the first error. The results written before it stay written,
    /// and `diagnostic` describes the error. What this call needs only while it
    /// runs comes from `arena`, which the caller frees as a whole. The data the
    /// reader builds are in the heap and live for as long as something refers
    /// to them; the symbols and the code are allocated in the interpreter's own
    /// arena and live until `deinit`.
    pub fn evalPrint(self: *Interpreter, arena: std.mem.Allocator, source: []const u8, out: *std.Io.Writer) Error!void {
        self.ctx.clearDiagnostic();
        self.run(arena, source, out) catch |e| {
            if (self.ctx.diagnostic().len == 0) self.ctx.raise("{s}", .{describe(e)}) catch {};
            return e;
        };
    }

    /// The message for the error the last `evalPrint` returned. Valid until the
    /// next call.
    pub fn diagnostic(self: *const Interpreter) []const u8 {
        return self.ctx.diagnostic();
    }

    fn run(self: *Interpreter, arena: std.mem.Allocator, source: []const u8, out: *std.Io.Writer) Error!void {
        var r: reader.Reader = .init(source);
        // What is read outlives the line: `quote` can hand it to a definition.
        const sink: reader.Sink = .{ .alloc = self.ctx.persist, .heap = &self.ctx.heap, .symbols = &self.ctx.symbols };
        while (true) {
            // Between two forms nothing is held but what the context holds, so
            // this is a safe point too. It is also where the garbage of a line
            // that ended in an error is collected, before the next line reads.
            if (self.ctx.heap.shouldCollect()) self.ctx.collectIdle();
            const form = try r.next(arena, sink) orelse break;
            const node = try expand.expand(&self.ctx, arena, form);
            var m: machine.Machine = .init(&self.ctx, arena);
            const v = try m.run(node);
            // A definition prints nothing. The REPL shows a value, and this one
            // has no external form.
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
        // The arena of the first line is freed before the closure is called.
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
    // What the failed line left in the heap is garbage, and the next line starts
    // by collecting it before it reads.
    try interp.evalPrint(arena.allocator(), "(+ 1 2) keep", &w);
    try std.testing.expectEqualStrings("3\n42\n", w.buffered());
    try std.testing.expectEqualStrings("", interp.diagnostic());
    // And again.
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
    // The datum that did not fit is garbage, and a small one does.
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
