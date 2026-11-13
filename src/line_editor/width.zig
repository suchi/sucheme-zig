//! Display width of a code point, for the line editor (docs/plans/0021-stage7-8-early-parts.md, 7f).
//!
//! 再描画(7g)は、文字の表示幅を、この `width` 経由でしか求めない。表を引く実装への
//! 差し替えは、このファイルの中で閉じる。

const std = @import("std");

/// Returns the number of terminal columns a code point takes: 0, 1 or 2.
///
/// Why: これは仮の実装である。2026-11-12 の時点で、`src/unicode/` に幅の表(東アジアの文字幅と、
/// 結合文字などの幅0)は無い。そのため、ASCII の印字可能文字を1、制御文字(C0、DEL、C1)を0、
/// それ以外をすべて1とする。全角の文字(2であるべき)と結合文字(0であるべき)を含む行では、
/// カーソルの位置が実際の画面とずれる。L4 の Unicode の表に幅の情報が入ったら、表を引く
/// 実装に差し替える(計画書 0021 の「文字幅と L4 の依存」)。署名は、差し替えで変えない。
pub fn width(cp: u21) u2 {
    if (cp < 0x20) return 0; // C0 の制御文字
    if (cp >= 0x7f and cp < 0xa0) return 0; // DEL と C1 の制御文字
    return 1;
}

test "ASCII printable characters take one column, from the space to the tilde" {
    var cp: u21 = 0x20;
    while (cp <= 0x7e) : (cp += 1) {
        try std.testing.expectEqual(@as(u2, 1), width(cp));
    }
}

test "control characters take no column: C0, DEL and C1" {
    var cp: u21 = 0;
    while (cp < 0x20) : (cp += 1) try std.testing.expectEqual(@as(u2, 0), width(cp));
    try std.testing.expectEqual(@as(u2, 0), width(0x7f));
    cp = 0x80;
    while (cp < 0xa0) : (cp += 1) try std.testing.expectEqual(@as(u2, 0), width(cp));
}

test "the code points on either side of the control ranges take one column" {
    try std.testing.expectEqual(@as(u2, 1), width(0x20));
    try std.testing.expectEqual(@as(u2, 1), width(0x7e));
    try std.testing.expectEqual(@as(u2, 1), width(0xa0));
}

test "every other code point takes one column for now, including the ones that are really wide or combining" {
    // 仮の実装の振る舞いを固定する。表に差し替えるときは、この期待を直す。
    try std.testing.expectEqual(@as(u2, 1), width(0x3042)); // ひらがな「あ」(本来は2)
    try std.testing.expectEqual(@as(u2, 1), width(0x0301)); // 結合アクセント(本来は0)
    try std.testing.expectEqual(@as(u2, 1), width(0x1f600)); // 絵文字
    try std.testing.expectEqual(@as(u2, 1), width(0x10ffff));
}
