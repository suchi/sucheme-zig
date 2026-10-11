//! Which tier a test runs in (docs/plans/0007-test-tiers.md).
//!
//! `zig build test` は全コミットで走る段であり、速いままでなければならない。
//! 規模を確かめるテスト(10万段の再帰、100万回のループなど)は、入力の大きさに
//! 伴って増える欠陥を見つける。小さな入力で見つからない論理上の欠陥は、ほとんど
//! 見つけない。そのため `zig build test -Dslow=true` まで待たせる。そうしたテスト
//! には、同じ論理を走らせる小さな双子を、速い段に残す。
//!
//! スキップしたテストはそのことを示す。実行の要約がスキップ数を数えるので、
//! 速い実行でも残りの存在が隠れることはない。

const build_options = @import("build_options");

/// Skips the test that calls it, unless the slow tier was asked for.
pub fn slow() error{SkipZigTest}!void {
    if (!build_options.slow) return error.SkipZigTest;
}

/// Whether the slow tier was asked for.
pub const slow_enabled = build_options.slow;

test {
    @import("std").testing.refAllDecls(@This());
}
