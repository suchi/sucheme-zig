//! The check that the procedures which write to an object share (R7RS 3.4, 4.1.2).
//!
//! リテラルのデータと `symbol->string` の結果は不変である。その場所に書き込む手続き
//! (R7RS 第6章の `!` 付き手続き)は、引数のオブジェクトを書き換える前に `requireMutable`
//! を呼ぶ。不変の印は、オブジェクトのヘッダにある(`heap.isImmutable`)。印を立てるのは、
//! リテラルを定数にする展開器(`freeze.zig`)と `symbol->string` である。
//! docs/design/runtime.md の「リテラルの不変性」を参照。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const heap = @import("../heap.zig");

/// Refuses `target`, the object a procedure is about to write to, when it is a constant.
///
/// `target` は、型の検査が済んだペア、文字列、ベクタ(3e からはバイトベクタ)である。
/// 検査の順序は、型、不変、範囲の順である。範囲が空でも(`(string-fill! "" #\a)` など)、
/// 不変のオブジェクトへの書き込みは拒む。何も書かない呼び出しでも、定数に書き込む手続きを
/// 呼んでいることに変わりがなく、書き込める範囲が空かどうかで誤りの有無が決まるのは、
/// 検査の規則として不自然だからである。
pub fn requireMutable(target: Value) error{Immutable}!void {
    if (heap.isImmutable(target)) return error.Immutable;
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");

test "a constant is refused, and an object that is not a constant is let through" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const pair = try f.heap.cons(.fromFixnum(1), .empty_list_value);
    const string: Value = .fromString(try f.heap.createString("abc"));
    const vector: Value = .fromVector(try f.heap.createVector(&.{}));
    for ([_]Value{ pair, string, vector }) |v| {
        try requireMutable(v);
        heap.makeImmutable(v);
        try std.testing.expectError(error.Immutable, requireMutable(v));
    }
}
