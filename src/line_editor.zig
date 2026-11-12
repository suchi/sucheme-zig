//! The line editor of the REPL (docs/plans/0021-stage7-8-early-parts.md, ADR-0049).
//!
//! 行編集の部品を1つの名前空間にまとめる。`build.zig` は、このファイルをモジュール
//! `line_editor` の根にして、`zig build test` の対象に加える。部品のファイルを足したら、
//! ここに `pub const` で1行足す。足さないと、そのファイルのテストは走らない
//! (`pub const` の行を消して、部品のテストが走らなくなることを、実機で確かめた)。
//! 部品どうしは、相対パス(`@import("width.zig")`)で読み合ってよい。同じモジュールの中なので、
//! 「同じファイルが2つのモジュールに属する」誤りにならない。

pub const history = @import("line_editor/history.zig");
pub const width = @import("line_editor/width.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
