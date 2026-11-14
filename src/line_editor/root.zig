//! Line editor components.
//!
//! 行編集の部品をまとめるテストの根(ADR-0049)。`zig build test` は、ここから到達できる
//! ファイルのテストだけを走らせる。新しい部品のファイルは、ここに `pub const` で足す。
//! 7j が REPL に組み込むと、`src/main.zig` からも到達できる。

const std = @import("std");

pub const keys = @import("keys.zig");
pub const buffer = @import("buffer.zig");
pub const term_posix = @import("term_posix.zig");
pub const kill_ring = @import("kill_ring.zig");
pub const undo = @import("undo.zig");
pub const history = @import("history.zig");
pub const width = @import("width.zig");
pub const render = @import("render.zig");
pub const line_reader = @import("line_reader.zig");

test {
    std.testing.refAllDecls(@This());
}
