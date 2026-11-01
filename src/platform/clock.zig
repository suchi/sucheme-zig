//! The host's clocks, which differ between the executable and WebAssembly: the time
//! of day and a monotonic time (R7RS 6.14, docs/plans/0019-phase5-ports-and-io.md).
//!
//! ネイティブは Zig の `std.Io.Clock` から読む。`.real` は UNIX 時刻(閏秒を数えない)で、
//! `.awake` は単調な時間である(Linux では `CLOCK_MONOTONIC`)。`Io` は、プリミティブに配線せず、
//! 標準ライブラリの大域の `std.Io.Threaded.global_single_threaded` から取る。時計を読むだけで、
//! 入出力の状態を持たないからである。
//! WASM は、ホストが渡す2つの import から読む(計画書 0019 の合意を求める点の2)。
//! `env.host_now_ms` は絶対時刻(UNIX 時刻のミリ秒。ブラウザの `Date.now()`)、
//! `env.host_monotonic_ms` は単調な時間(ブラウザの `performance.now()`)である。

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch.isWasm();

/// The time of day as a UNIX time in milliseconds, from the host (WASM).
extern "env" fn host_now_ms() f64;
/// A monotonic time in milliseconds from an unspecified point, from the host (WASM).
extern "env" fn host_monotonic_ms() f64;

/// The time of day as seconds since 1970-01-01T00:00:00Z, not counting leap
/// seconds (UNIX time).
pub fn unixSeconds() f64 {
    if (is_wasm) return host_now_ms() / 1000.0;
    const ts = std.Io.Clock.real.now(io());
    return @as(f64, @floatFromInt(ts.nanoseconds)) / std.time.ns_per_s;
}

/// A monotonic time in microseconds from a point that stays the same while the
/// program runs.
/// ホストが返した値が負か大きすぎるときは、範囲に収める(WASM の import は浮動小数点数で、
/// ホストの実装を信じきらない)。
pub fn monotonicMicroseconds() i64 {
    if (is_wasm) return clampMicroseconds(host_monotonic_ms() * 1000.0);
    const ts = std.Io.Clock.awake.now(io());
    return std.math.cast(i64, @divFloor(ts.nanoseconds, std.time.ns_per_us)) orelse std.math.maxInt(i64);
}

/// `us` rounded down into the range of microseconds that `current-jiffy` gives:
/// 0 to the largest `i64`, with NaN as 0.
pub fn clampMicroseconds(us: f64) i64 {
    if (!(us > 0)) return 0;
    if (us >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return std.math.maxInt(i64);
    return @intFromFloat(@floor(us));
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "the clocks give a time after 2017, and a monotonic time that does not go back" {
    try std.testing.expect(unixSeconds() > 1_483_228_800);
    const a = monotonicMicroseconds();
    const b = monotonicMicroseconds();
    try std.testing.expect(a > 0);
    try std.testing.expect(b >= a);
}

test "clampMicroseconds keeps what the host gives in range" {
    try std.testing.expectEqual(@as(i64, 0), clampMicroseconds(-5));
    try std.testing.expectEqual(@as(i64, 0), clampMicroseconds(std.math.nan(f64)));
    try std.testing.expectEqual(@as(i64, 1234), clampMicroseconds(1234.9));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), clampMicroseconds(std.math.inf(f64)));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), clampMicroseconds(1e30));
}
