//! What the expander and the machine share between the lines of a session: where
//! what outlives a line is allocated, the symbols, the global bindings, and the
//! message of the most recent error.

const std = @import("std");
const symbol = @import("symbol.zig");
const env = @import("env.zig");
const arith = @import("prim/arith.zig");

/// What the interpreter carries between lines: where what outlives a line is
/// allocated, the symbols and global bindings, and the message for the most
/// recent error.
///
/// A Zig error carries no payload, so the message that names the offending
/// identifier lives here, and the caller reads it with `diagnostic` after an
/// error. Slice 1f replaces the message with condition objects.
pub const Context = struct {
    /// Where the data the reader builds, the symbols, the global bindings, the
    /// closures and the frames of calls are allocated. Nothing in it is freed
    /// until slice 1g replaces it with the GC heap, so a program that makes many
    /// calls grows it by a frame and its arguments each.
    persist: std.mem.Allocator,
    symbols: symbol.Table = .{},
    globals: env.Global = .{},
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,

    /// A context whose global environment binds each primitive to its name.
    pub fn init(persist: std.mem.Allocator) error{OutOfMemory}!Context {
        var ctx: Context = .{ .persist = persist };
        for (&arith.primitives) |*p| {
            const id = try ctx.symbols.intern(persist, p.name);
            try ctx.globals.define(persist, id, .fromPrimitive(p));
        }
        return ctx;
    }

    /// The message for the most recent error, or empty when none was set.
    /// Valid until the next call that fails or `clearDiagnostic`.
    pub fn diagnostic(self: *const Context) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    pub fn clearDiagnostic(self: *Context) void {
        self.message_len = 0;
    }

    pub fn setDiagnostic(self: *Context, message: []const u8) void {
        const n = @min(message.len, self.message_buf.len);
        @memcpy(self.message_buf[0..n], message[0..n]);
        self.message_len = n;
    }

    /// Records the message and returns `err`, so a call site reads
    /// `return ctx.fail(error.X, "...", .{})`. A message longer than the buffer
    /// is cut, not dropped: an identifier can be as long as the REPL's line.
    pub fn fail(self: *Context, err: anytype, comptime fmt: []const u8, args: anytype) @TypeOf(err) {
        var w: std.Io.Writer = .fixed(&self.message_buf);
        w.print(fmt, args) catch {};
        self.message_len = w.buffered().len;
        return err;
    }
};

test {
    std.testing.refAllDecls(@This());
}
