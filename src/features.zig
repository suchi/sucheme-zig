//! The feature identifiers that this build has (R7RS 4.2.1 and Appendix B,
//! docs/design/frontend.md, the feature identifiers that are provided).
//!
//! `cond-expand` と `features` が同じ一覧を見る。一覧はビルド対象で決まるので、実行時に
//! 何も調べず、コンパイル時に組み立てる。支える実装が入ったものだけを挙げる。数の
//! `exact-closed` `exact-complex` `ratios` `ieee-float` は段階4のスライス 4j で入った。
//! `full-unicode` は、Unicode の表が入る段階4の後半で足す。

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// Every feature identifier, in the order `features` returns them.
pub const names: []const []const u8 = blk: {
    const base = [_][]const u8{ "r7rs", "sucheme", "sucheme-" ++ majorMinor(build_options.version), "exact-closed", "exact-complex", "ratios", "ieee-float" };
    const os = osFeatures();
    const endian = switch (builtin.cpu.arch.endian()) {
        .little => "little-endian",
        .big => "big-endian",
    };
    var out: [base.len + os.len + 1][]const u8 = undefined;
    for (base, 0..) |n, i| out[i] = n;
    for (os, 0..) |n, i| out[base.len + i] = n;
    out[out.len - 1] = endian;
    const final = out;
    break :blk &final;
};

/// Whether `name` is a feature identifier of this build.
pub fn has(name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The identifiers of the system the build runs on: the names of Appendix B for
/// the operating system, and `wasm` for the WASM build.
/// Why: `linux` と `macos` は付録Bにない独自の名前で、`gnu-linux` と `darwin` の別名である。
/// WASM はオペレーティングシステムを持たないので、`wasm` だけである。
fn osFeatures() []const []const u8 {
    if (builtin.cpu.arch.isWasm()) return &.{"wasm"};
    return switch (builtin.os.tag) {
        .linux => &.{ "unix", "posix", "gnu-linux", "linux" },
        .macos => &.{ "unix", "posix", "darwin", "macos" },
        .windows => &.{"windows"},
        else => &.{ "unix", "posix" },
    };
}

/// The version up to its second dot: `0.2` of `0.2.0`.
fn majorMinor(comptime version: []const u8) []const u8 {
    var dots: usize = 0;
    for (version, 0..) |c, i| {
        if (c != '.') continue;
        dots += 1;
        if (dots == 2) return version[0..i];
    }
    return version;
}

test {
    std.testing.refAllDecls(@This());
}

test "the version feature is the major and minor numbers of the version" {
    try std.testing.expectEqualStrings("0.2", majorMinor("0.2.0"));
    try std.testing.expectEqualStrings("1.10", majorMinor("1.10.3-dev"));
    try std.testing.expectEqualStrings("3", majorMinor("3"));
    try std.testing.expectEqualStrings("3.1", majorMinor("3.1"));
}

test "a build has r7rs, sucheme, its version, its endianness and its system, each once" {
    try std.testing.expect(has("r7rs"));
    try std.testing.expect(has("sucheme"));
    try std.testing.expect(has(comptime "sucheme-" ++ majorMinor(build_options.version)));
    try std.testing.expectEqual(builtin.cpu.arch.endian() == .little, has("little-endian"));
    try std.testing.expectEqual(builtin.cpu.arch.endian() == .big, has("big-endian"));
    try std.testing.expect(!has("no-such-feature"));
    // 数のフィーチャは4つとも真である(正確な整数・有理数・複素数と IEEE 754 の flonum がある)。
    for ([_][]const u8{ "exact-closed", "exact-complex", "ratios", "ieee-float" }) |n| try std.testing.expect(has(n));
    try std.testing.expect(!has("full-unicode"));
    for (names, 0..) |a, i| {
        for (names[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a, b));
    }
    // 実行しているシステムの名前が、1つ以上ある。
    try std.testing.expect(has("wasm") or has("unix") or has("windows"));
    try std.testing.expectEqual(builtin.os.tag == .linux, has("linux"));
    try std.testing.expectEqual(builtin.os.tag == .windows, has("windows"));
    // Windows と WASM 以外は POSIX 系で、付録Bの `unix` と `posix` を持つ。
    const posix = builtin.os.tag != .windows and !builtin.cpu.arch.isWasm();
    try std.testing.expectEqual(posix, has("unix"));
    try std.testing.expectEqual(posix, has("posix"));
    try std.testing.expectEqual(builtin.cpu.arch.isWasm(), has("wasm"));
}
