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

const reader = @import("reader.zig");
const eval = @import("eval.zig");
const printer = @import("printer.zig");

/// Every way `evalPrint` can fail. Until slice 1f reports Scheme errors as
/// conditions, a Scheme error is one of these too.
pub const Error = reader.Error || eval.Error || printer.Error;

/// One interpreter: what outlives a single line of input, which is the data the
/// reader builds, the symbol table and the global environment.
///
/// Those live in an arena of its own until the GC heap arrives in slice 1g;
/// docs/design/architecture.md records the exception. The context points into
/// the arena, so an interpreter is initialised in place and not copied after.
pub const Interpreter = struct {
    arena: std.heap.ArenaAllocator,
    ctx: eval.Context,

    pub fn init(self: *Interpreter, gpa: std.mem.Allocator) void {
        self.arena = .init(gpa);
        self.ctx = .init(self.arena.allocator());
    }

    pub fn deinit(self: *Interpreter) void {
        self.arena.deinit();
    }

    /// Reads every datum in `source`, evaluates each in turn, and writes each
    /// result followed by a newline to `out`.
    ///
    /// Stops at the first error. The results written before it stay written,
    /// and `diagnostic` describes the error. What this call needs only while it
    /// runs comes from `arena`, which the caller frees as a whole. The data the
    /// reader builds, the symbols and what a definition keeps are allocated in
    /// the interpreter's own arena and live until `deinit`.
    pub fn evalPrint(self: *Interpreter, arena: std.mem.Allocator, source: []const u8, out: *std.Io.Writer) Error!void {
        self.ctx.clearDiagnostic();
        self.run(arena, source, out) catch |e| {
            if (self.ctx.diagnostic().len == 0) self.ctx.setDiagnostic(describe(e));
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
        const sink: reader.Sink = .{ .alloc = self.ctx.persist, .symbols = &self.ctx.symbols };
        while (try r.next(arena, sink)) |form| {
            const v = try eval.eval(&self.ctx, arena, form);
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
        error.InvalidToken => "unreadable token",
        error.IntegerOutOfRange => "integer out of range",
        error.OutOfMemory => "out of memory",
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
    interp.init(std.testing.allocator);
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
    interp.init(std.testing.allocator);
    defer interp.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.UnboundVariable, interp.evalPrint(arena.allocator(), "1 (foo) 2", &w));
    try std.testing.expectEqualStrings("1\n", w.buffered());
    try std.testing.expectEqualStrings("unbound variable: foo", interp.diagnostic());
}

test "evalPrint describes a reader error, and a later success clears the message" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = undefined;
    interp.init(std.testing.allocator);
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
    interp.init(std.testing.allocator);
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
    interp.init(std.testing.allocator);
    defer interp.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.UnboundVariable, interp.evalPrint(arena.allocator(), "(define a 1) (define b nope)", &w));
    try interp.evalPrint(arena.allocator(), "a", &w);
    try std.testing.expectEqualStrings("1\n", w.buffered());
    try std.testing.expectError(error.UnboundVariable, interp.evalPrint(arena.allocator(), "b", &w));
    try std.testing.expectEqualStrings("unbound variable: b", interp.diagnostic());
}

test "two interpreters do not share definitions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var one: Interpreter = undefined;
    one.init(std.testing.allocator);
    defer one.deinit();
    var two: Interpreter = undefined;
    two.init(std.testing.allocator);
    defer two.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try one.evalPrint(arena.allocator(), "(define x 1)", &w);
    try std.testing.expectError(error.UnboundVariable, two.evalPrint(arena.allocator(), "x", &w));
}
