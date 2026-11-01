//! Time primitives (R7RS 6.14): `current-second`, `current-jiffy` and
//! `jiffies-per-second`.
//!
//! 時計はホストのもの(src/platform/clock.zig)を読む。jiffy はマイクロ秒で、ネイティブと
//! WASM で同じ値である(docs/plans/0019-phase5-ports-and-io.md の合意を求める点の2)。

const std = @import("std");
const value = @import("../value.zig");
const clock = @import("../platform/clock.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "current-second", .min_args = 0, .max_args = 0, .body = .{ .pure = &currentSecond } },
    .{ .name = "current-jiffy", .min_args = 0, .max_args = 0, .body = .{ .pure = &currentJiffy } },
    .{ .name = "jiffies-per-second", .min_args = 0, .max_args = 0, .body = .{ .pure = &jiffiesPerSecond } },
};

/// How many jiffies make a second: a jiffy is a microsecond.
pub const jiffies_per_second = 1_000_000;

/// TAI − UTC in seconds, which `current-second` adds to the UNIX time.
/// Why: R7RS 6.14 は `current-second` を TAI の秒とし、「UTC に適切な定数を足したもの」を
/// 許す。値は、2017-01-01 からの 37 秒である。IERS Bulletin C をもとにした tzdata 2026e の
/// `leap-seconds.list`(失効は 2027-06-28)で確かめた。IERS の頁そのものでは確かめていない
/// (取れなかった)。閏秒が入ったら、この値を変える。
pub const tai_minus_utc = 37;

/// `(current-second)`: the time of day as an inexact number of TAI seconds since
/// 1970-01-01T00:00:00Z.
fn currentSecond(_: *const Services, _: []const Value) Error!Value {
    return .fromFlonum(clock.unixSeconds() + tai_minus_utc);
}

/// `(current-jiffy)`: the jiffies since a point that stays the same while the
/// program runs, as an exact integer.
fn currentJiffy(_: *const Services, _: []const Value) Error!Value {
    return .fromFixnum(clock.monotonicMicroseconds());
}

/// `(jiffies-per-second)`: how many jiffies make a second, as an exact integer.
fn jiffiesPerSecond(_: *const Services, _: []const Value) Error!Value {
    return .fromFixnum(jiffies_per_second);
}

test {
    std.testing.refAllDecls(@This());
    _ = clock;
}
