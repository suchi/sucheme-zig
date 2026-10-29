//! Character primitives (R7RS 6.6), including the ones of `(scheme char)`.
//!
//! 属性(`char-alphabetic?` など)、大文字小文字の写像(`char-upcase` など)、
//! 大文字小文字を区別しない比較(`char-ci=?` など)、`digit-value` は、Unicode の表
//! (`src/unicode/props.zig`)を引く。R7RS 6.6 は、写像に言語に依存しないものを求める。
//! 引くのは単純写像と単純な畳み込みで、文字数が変わる完全写像は文字列の手続き
//! (`string_case.zig`)が使う。

const std = @import("std");
const value = @import("../value.zig");
const props = @import("../unicode/props.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "char?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isChar } },
    .{ .name = "char->integer", .min_args = 1, .max_args = 1, .body = .{ .pure = &charToInteger } },
    .{ .name = "integer->char", .min_args = 1, .max_args = 1, .body = .{ .pure = &integerToChar } },
    .{ .name = "char=?", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.eq) } },
    .{ .name = "char<?", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.lt) } },
    .{ .name = "char>?", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.gt) } },
    .{ .name = "char<=?", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.lte) } },
    .{ .name = "char>=?", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.gte) } },
    // 以下は `(scheme char)` の手続きである。
    .{ .name = "char-alphabetic?", .min_args = 1, .max_args = 1, .body = .{ .pure = hasProperty(.alphabetic) } },
    .{ .name = "char-numeric?", .min_args = 1, .max_args = 1, .body = .{ .pure = hasProperty(.numeric) } },
    .{ .name = "char-whitespace?", .min_args = 1, .max_args = 1, .body = .{ .pure = hasProperty(.white_space) } },
    .{ .name = "char-upper-case?", .min_args = 1, .max_args = 1, .body = .{ .pure = hasProperty(.uppercase) } },
    .{ .name = "char-lower-case?", .min_args = 1, .max_args = 1, .body = .{ .pure = hasProperty(.lowercase) } },
    .{ .name = "digit-value", .min_args = 1, .max_args = 1, .body = .{ .pure = &digitValue } },
    .{ .name = "char-upcase", .min_args = 1, .max_args = 1, .body = .{ .pure = mapping(props.simpleUpcase) } },
    .{ .name = "char-downcase", .min_args = 1, .max_args = 1, .body = .{ .pure = mapping(props.simpleDowncase) } },
    .{ .name = "char-foldcase", .min_args = 1, .max_args = 1, .body = .{ .pure = mapping(props.simpleFoldcase) } },
    .{ .name = "char-ci=?", .min_args = 1, .max_args = null, .body = .{ .pure = foldedComparison(.eq) } },
    .{ .name = "char-ci<?", .min_args = 1, .max_args = null, .body = .{ .pure = foldedComparison(.lt) } },
    .{ .name = "char-ci>?", .min_args = 1, .max_args = null, .body = .{ .pure = foldedComparison(.gt) } },
    .{ .name = "char-ci<=?", .min_args = 1, .max_args = null, .body = .{ .pure = foldedComparison(.lte) } },
    .{ .name = "char-ci>=?", .min_args = 1, .max_args = null, .body = .{ .pure = foldedComparison(.gte) } },
};

/// `(char? obj)`.
fn isChar(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].asCharacter() != null);
}

/// `(char->integer char)`: the code point of the character (R7RS 6.6).
fn charToInteger(_: *const Services, args: []const Value) Error!Value {
    const c = args[0].asCharacter() orelse return error.WrongType;
    return .fromFixnum(c);
}

/// `(integer->char n)`: the character with code point `n` (R7RS 6.6).
///
/// Why: R7RS 6.6 は、`integer->char` が受け付ける整数を、0 から #xD7FF、または #xE000
/// から #x10FFFF までとしている。サロゲートと #x10FFFF を超える整数は文字にならない。
/// 引数は 64 ビットの整数なので、`u32` に収まるかを先に調べる。`wasm32` でも幅が同じで、
/// 切り捨てて範囲内に戻ってしまうことがない。
fn integerToChar(_: *const Services, args: []const Value) Error!Value {
    const n = args[0].asFixnum() orelse return error.WrongType;
    const code_point = std.math.cast(u32, n) orelse return error.OutOfRange;
    if (!value.isScalarValue(code_point)) return error.OutOfRange;
    return .fromCharacter(@intCast(code_point));
}

/// `(char=? char1 char2 char3 ...)` and the other four comparisons (R7RS 6.6): whether
/// every neighboring pair of the arguments is in the order, by code point.
///
/// 整数の比較(`src/prim/arith.zig` の `comparison`)と同じ形である。引数が1つなら真、
/// なしならエラー(機械が表の下限で報告する)。最初に成り立たなかった組より後のものも含め、
/// すべての引数が文字であることを検査する。エラーが値に左右されないようにするためである。
/// 順序は、`char->integer` の結果の順序である(R7RS 6.6 がそう定めている。原文は取得できて
/// いない)。
fn comparison(comptime op: std.math.CompareOperator) Primitive.Fn {
    return &struct {
        fn call(_: *const Services, args: []const Value) Error!Value {
            for (args) |a| _ = a.asCharacter() orelse return error.WrongType;
            var holds = true;
            for (args[0 .. args.len - 1], args[1..]) |a, b| {
                if (!std.math.compare(a.asCharacter().?, op, b.asCharacter().?)) holds = false;
            }
            return .fromBool(holds);
        }
    }.call;
}

/// `(char-alphabetic? char)` and the other four predicates (R7RS 6.6): whether the character has
/// the Unicode property Alphabetic, Numeric_Type=Decimal, White_Space, Uppercase or Lowercase.
///
/// R7RS 6.6 は、この5つの性質で答えを定めている。`char-upper-case?` は Uppercase を持つ文字
/// に真を返し、大文字と小文字のどちらでもない文字(Lt の二重字など)には偽を返す。
fn hasProperty(comptime p: props.Property) Primitive.Fn {
    return &struct {
        fn call(_: *const Services, args: []const Value) Error!Value {
            const c = args[0].asCharacter() orelse return error.WrongType;
            return .fromBool(props.has(c, p));
        }
    }.call;
}

/// `(digit-value char)`: the value 0 to 9 of a decimal digit, or `#f` (R7RS 6.6).
fn digitValue(_: *const Services, args: []const Value) Error!Value {
    const c = args[0].asCharacter() orelse return error.WrongType;
    const d = props.digitValue(c) orelse return .fromBool(false);
    return .fromFixnum(d);
}

/// `(char-upcase char)`, `(char-downcase char)` and `(char-foldcase char)` (R7RS 6.6): the
/// simple mapping of the character, or the character itself when it has none.
fn mapping(comptime f: fn (u21) u21) Primitive.Fn {
    return &struct {
        fn call(_: *const Services, args: []const Value) Error!Value {
            const c = args[0].asCharacter() orelse return error.WrongType;
            return .fromCharacter(f(c));
        }
    }.call;
}

/// `(char-ci=? char1 char2 char3 ...)` and the other four comparisons (R7RS 6.6): the same as
/// `char=?` and the others, after `char-foldcase` is applied to the arguments.
///
/// `comparison` と同じ形である。すべての引数が文字であることを、最初に成り立たなかった組より
/// 後のものも含めて検査する。
fn foldedComparison(comptime op: std.math.CompareOperator) Primitive.Fn {
    return &struct {
        fn call(_: *const Services, args: []const Value) Error!Value {
            for (args) |a| _ = a.asCharacter() orelse return error.WrongType;
            var holds = true;
            for (args[0 .. args.len - 1], args[1..]) |a, b| {
                const x = props.simpleFoldcase(a.asCharacter().?);
                const y = props.simpleFoldcase(b.asCharacter().?);
                if (!std.math.compare(x, op, y)) holds = false;
            }
            return .fromBool(holds);
        }
    }.call;
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");

fn call(name: []const u8, args: []const Value) Error!Value {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    return f.call(&primitives, name, args);
}

test "the primitives take the numbers of arguments the language gives them" {
    const Arity = struct { name: []const u8, min: u8, max: ?u8 };
    const expected = [_]Arity{
        .{ .name = "char?", .min = 1, .max = 1 },
        .{ .name = "char->integer", .min = 1, .max = 1 },
        .{ .name = "integer->char", .min = 1, .max = 1 },
        .{ .name = "char=?", .min = 1, .max = null },
        .{ .name = "char<?", .min = 1, .max = null },
        .{ .name = "char>?", .min = 1, .max = null },
        .{ .name = "char<=?", .min = 1, .max = null },
        .{ .name = "char>=?", .min = 1, .max = null },
        .{ .name = "char-alphabetic?", .min = 1, .max = 1 },
        .{ .name = "char-numeric?", .min = 1, .max = 1 },
        .{ .name = "char-whitespace?", .min = 1, .max = 1 },
        .{ .name = "char-upper-case?", .min = 1, .max = 1 },
        .{ .name = "char-lower-case?", .min = 1, .max = 1 },
        .{ .name = "digit-value", .min = 1, .max = 1 },
        .{ .name = "char-upcase", .min = 1, .max = 1 },
        .{ .name = "char-downcase", .min = 1, .max = 1 },
        .{ .name = "char-foldcase", .min = 1, .max = 1 },
        .{ .name = "char-ci=?", .min = 1, .max = null },
        .{ .name = "char-ci<?", .min = 1, .max = null },
        .{ .name = "char-ci>?", .min = 1, .max = null },
        .{ .name = "char-ci<=?", .min = 1, .max = null },
        .{ .name = "char-ci>=?", .min = 1, .max = null },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, primitives) |e, p| {
        try std.testing.expectEqualStrings(e.name, p.name);
        try std.testing.expectEqual(e.min, p.min_args);
        try std.testing.expectEqual(e.max, p.max_args);
    }
}

test "char? is true of a character and of nothing else" {
    try std.testing.expect((try call("char?", &.{.fromCharacter('a')})).isTrue());
    try std.testing.expect((try call("char?", &.{.fromCharacter(0)})).isTrue());
    try std.testing.expect((try call("char?", &.{.fromCharacter(0x10FFFF)})).isTrue());
    for ([_]Value{ .fromFixnum(97), .fromBool(true), .empty_list_value, .unspecified_value }) |v| {
        const r = try call("char?", &.{v});
        try std.testing.expectEqual(value.Kind.boolean, r.kind());
        try std.testing.expect(!r.isTrue());
    }
}

test "char->integer gives the code point" {
    for ([_]u21{ 0, 'a', 0x7F, 0x80, 0x3BB, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF }) |c| {
        try std.testing.expectEqual(c, (try call("char->integer", &.{.fromCharacter(c)})).asFixnum().?);
    }
}

test "char->integer reports an argument that is not a character" {
    try std.testing.expectError(error.WrongType, call("char->integer", &.{.fromFixnum(97)}));
    try std.testing.expectError(error.WrongType, call("char->integer", &.{.fromBool(false)}));
    try std.testing.expectError(error.WrongType, call("char->integer", &.{.empty_list_value}));
}

test "integer->char makes the character with the code point" {
    for ([_]u21{ 0, 'a', 0x7F, 0x80, 0x3BB, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF }) |c| {
        const r = try call("integer->char", &.{.fromFixnum(c)});
        try std.testing.expectEqual(value.Kind.character, r.kind());
        try std.testing.expectEqual(c, r.asCharacter().?);
    }
}

test "integer->char refuses the surrogates and what is past the range" {
    const out_of_range = [_]i64{
        0xD800,
        0xDBFF,
        0xDC00,
        0xDFFF,
        0x110000,
        // 32 ビットに切り捨てると範囲内に戻る値。
        0x1_0000_0041,
        std.math.maxInt(u32),
        std.math.maxInt(u32) + 1,
        std.math.maxInt(i64),
        -1,
        std.math.minInt(i32),
        std.math.minInt(i64),
    };
    for (out_of_range) |n| {
        try std.testing.expectError(error.OutOfRange, call("integer->char", &.{.fromFixnum(n)}));
    }
}

test "integer->char reports an argument that is not an integer, before it looks at the range" {
    try std.testing.expectError(error.WrongType, call("integer->char", &.{.fromCharacter('a')}));
    try std.testing.expectError(error.WrongType, call("integer->char", &.{.fromBool(true)}));
    try std.testing.expectError(error.WrongType, call("integer->char", &.{.empty_list_value}));
}

/// Calls the comparison `name` on the characters with the code points `points`.
fn compareCodePoints(name: []const u8, points: []const u21) !bool {
    var args: [8]Value = undefined;
    for (points, 0..) |c, i| args[i] = .fromCharacter(c);
    const r = try call(name, args[0..points.len]);
    try std.testing.expectEqual(value.Kind.boolean, r.kind());
    return r.isTrue();
}

test "the comparisons of two characters follow their code points" {
    // 小さい、等しい、大きい、の3通りに対する5つの比較の答え。
    const Row = struct { name: []const u8, less: bool, equal: bool, greater: bool };
    const rows = [_]Row{
        .{ .name = "char=?", .less = false, .equal = true, .greater = false },
        .{ .name = "char<?", .less = true, .equal = false, .greater = false },
        .{ .name = "char>?", .less = false, .equal = false, .greater = true },
        .{ .name = "char<=?", .less = true, .equal = true, .greater = false },
        .{ .name = "char>=?", .less = false, .equal = true, .greater = true },
    };
    for (rows) |r| {
        try std.testing.expectEqual(r.less, try compareCodePoints(r.name, &.{ 'a', 'b' }));
        try std.testing.expectEqual(r.equal, try compareCodePoints(r.name, &.{ 'a', 'a' }));
        try std.testing.expectEqual(r.greater, try compareCodePoints(r.name, &.{ 'b', 'a' }));
        // 大文字は小文字より前にある。大文字小文字は区別される。
        try std.testing.expectEqual(r.less, try compareCodePoints(r.name, &.{ 'Z', 'a' }));
        // ASCII の外も、コードポイントの順である。UTF-8 のバイト列の順とは別の根拠で、
        // 最大の文字と、サロゲートの前後の文字を含む。
        try std.testing.expectEqual(r.less, try compareCodePoints(r.name, &.{ 0xD7FF, 0xE000 }));
        try std.testing.expectEqual(r.greater, try compareCodePoints(r.name, &.{ 0x10FFFF, 0xFFFF }));
        try std.testing.expectEqual(r.less, try compareCodePoints(r.name, &.{ 0, 1 }));
        try std.testing.expectEqual(r.equal, try compareCodePoints(r.name, &.{ 0x10FFFF, 0x10FFFF }));
    }
}

test "the comparisons take any number of characters, and hold when every neighboring pair does" {
    try std.testing.expect(try compareCodePoints("char=?", &.{ 'a', 'a', 'a', 'a' }));
    try std.testing.expect(!try compareCodePoints("char=?", &.{ 'a', 'a', 'b' }));
    try std.testing.expect(!try compareCodePoints("char=?", &.{ 'b', 'a', 'a' }));
    try std.testing.expect(try compareCodePoints("char<?", &.{ 'a', 'b', 'c', 'd' }));
    try std.testing.expect(!try compareCodePoints("char<?", &.{ 'a', 'b', 'b' }));
    try std.testing.expect(!try compareCodePoints("char<?", &.{ 'a', 'c', 'b' }));
    try std.testing.expect(try compareCodePoints("char>?", &.{ 'd', 'c', 'b' }));
    try std.testing.expect(!try compareCodePoints("char>?", &.{ 'd', 'b', 'c' }));
    try std.testing.expect(try compareCodePoints("char<=?", &.{ 'a', 'a', 'b', 'b' }));
    try std.testing.expect(!try compareCodePoints("char<=?", &.{ 'a', 'b', 'a' }));
    try std.testing.expect(try compareCodePoints("char>=?", &.{ 'c', 'c', 'b', 'a' }));
    try std.testing.expect(!try compareCodePoints("char>=?", &.{ 'c', 'b', 'c' }));
    // 1つの引数は、比べる相手が無いので真である(`=` と同じ)。
    for ([_][]const u8{ "char=?", "char<?", "char>?", "char<=?", "char>=?" }) |name| {
        try std.testing.expect(try compareCodePoints(name, &.{'a'}));
    }
}

test "the comparisons check every argument for being a character, after the first pair that fails too" {
    for ([_][]const u8{ "char=?", "char<?", "char>?", "char<=?", "char>=?" }) |name| {
        try std.testing.expectError(error.WrongType, call(name, &.{ .fromCharacter('a'), .fromFixnum(97) }));
        try std.testing.expectError(error.WrongType, call(name, &.{ .fromFixnum(97), .fromCharacter('a') }));
        try std.testing.expectError(error.WrongType, call(name, &.{.fromFixnum(97)}));
        try std.testing.expectError(error.WrongType, call(name, &.{.empty_list_value}));
        // 最初の組が成り立たなくても、3つ目の誤りが報告される。エラーは値に左右されない。
        try std.testing.expectError(error.WrongType, call(name, &.{ .fromCharacter('b'), .fromCharacter('a'), .fromCharacter('a'), .fromBool(true) }));
        try std.testing.expectError(error.WrongType, call(name, &.{ .fromCharacter('a'), .fromCharacter('b'), .fromBool(false) }));
    }
}

/// Whether the predicate `name` is true of the character `c`.
fn isTrueOf(name: []const u8, c: u21) !bool {
    const r = try call(name, &.{.fromCharacter(c)});
    try std.testing.expectEqual(value.Kind.boolean, r.kind());
    return r.isTrue();
}

test "the predicates follow the Unicode properties R7RS 6.6 names" {
    const Row = struct { c: u21, alphabetic: bool, numeric: bool, white_space: bool, upper: bool, lower: bool };
    const rows = [_]Row{
        .{ .c = 'A', .alphabetic = true, .numeric = false, .white_space = false, .upper = true, .lower = false },
        .{ .c = 'a', .alphabetic = true, .numeric = false, .white_space = false, .upper = false, .lower = true },
        .{ .c = '3', .alphabetic = false, .numeric = true, .white_space = false, .upper = false, .lower = false },
        .{ .c = ' ', .alphabetic = false, .numeric = false, .white_space = true, .upper = false, .lower = false },
        .{ .c = '\n', .alphabetic = false, .numeric = false, .white_space = true, .upper = false, .lower = false },
        // R7RS 6.6 の例: ギリシャ文字のアルファは Alphabetic で、小文字である。
        .{ .c = 0x03B1, .alphabetic = true, .numeric = false, .white_space = false, .upper = false, .lower = true },
        // アラビア・インドの数字は Numeric_Type=Decimal である。
        .{ .c = 0x0664, .alphabetic = false, .numeric = true, .white_space = false, .upper = false, .lower = false },
        // 分数は Nd ではない。
        .{ .c = 0x00BD, .alphabetic = false, .numeric = false, .white_space = false, .upper = false, .lower = false },
        // Alphabetic だが、大文字でも小文字でもない文字(「多くの文字は文字だが大文字でも小文字でもない」)。
        .{ .c = 0x3042, .alphabetic = true, .numeric = false, .white_space = false, .upper = false, .lower = false },
        .{ .c = 0x01C5, .alphabetic = true, .numeric = false, .white_space = false, .upper = false, .lower = false },
        .{ .c = 0x00A0, .alphabetic = false, .numeric = false, .white_space = true, .upper = false, .lower = false },
        .{ .c = '!', .alphabetic = false, .numeric = false, .white_space = false, .upper = false, .lower = false },
    };
    for (rows) |r| {
        errdefer std.debug.print("U+{X:0>4}\n", .{r.c});
        try std.testing.expectEqual(r.alphabetic, try isTrueOf("char-alphabetic?", r.c));
        try std.testing.expectEqual(r.numeric, try isTrueOf("char-numeric?", r.c));
        try std.testing.expectEqual(r.white_space, try isTrueOf("char-whitespace?", r.c));
        try std.testing.expectEqual(r.upper, try isTrueOf("char-upper-case?", r.c));
        try std.testing.expectEqual(r.lower, try isTrueOf("char-lower-case?", r.c));
    }
}

test "the predicates and the mappings report an argument that is not a character" {
    const names = [_][]const u8{
        "char-alphabetic?", "char-numeric?", "char-whitespace?", "char-upper-case?", "char-lower-case?",
        "digit-value",      "char-upcase",   "char-downcase",    "char-foldcase",
    };
    for (names) |name| {
        try std.testing.expectError(error.WrongType, call(name, &.{.fromFixnum(97)}));
        try std.testing.expectError(error.WrongType, call(name, &.{.empty_list_value}));
        try std.testing.expectError(error.WrongType, call(name, &.{.fromBool(false)}));
    }
}

test "digit-value gives the value of a decimal digit and false for any other character" {
    // R7RS 6.6 の例。
    try std.testing.expectEqual(@as(i64, 3), (try call("digit-value", &.{.fromCharacter('3')})).asFixnum().?);
    try std.testing.expectEqual(@as(i64, 4), (try call("digit-value", &.{.fromCharacter(0x0664)})).asFixnum().?);
    try std.testing.expectEqual(@as(i64, 0), (try call("digit-value", &.{.fromCharacter(0x0AE6)})).asFixnum().?);
    const lao = try call("digit-value", &.{.fromCharacter(0x0EA6)});
    try std.testing.expectEqual(value.Kind.boolean, lao.kind());
    try std.testing.expect(!lao.isTrue());
    // 最後の桁は 9 で、数字の隣の文字は数字ではない。
    try std.testing.expectEqual(@as(i64, 9), (try call("digit-value", &.{.fromCharacter(0x1FBF9)})).asFixnum().?);
    for ([_]u21{ '/', ':', 'a', 0x00B2, 0x2160 }) |c| {
        const r = try call("digit-value", &.{.fromCharacter(c)});
        try std.testing.expectEqual(value.Kind.boolean, r.kind());
        try std.testing.expect(!r.isTrue());
    }
}

/// The character the one-argument primitive `name` returns for `c`.
fn mapped(name: []const u8, c: u21) !u21 {
    const r = try call(name, &.{.fromCharacter(c)});
    try std.testing.expectEqual(value.Kind.character, r.kind());
    return r.asCharacter().?;
}

test "char-upcase, char-downcase and char-foldcase apply the simple mappings" {
    try std.testing.expectEqual(@as(u21, 'A'), try mapped("char-upcase", 'a'));
    try std.testing.expectEqual(@as(u21, 'A'), try mapped("char-upcase", 'A'));
    try std.testing.expectEqual(@as(u21, 'a'), try mapped("char-downcase", 'A'));
    try std.testing.expectEqual(@as(u21, 'a'), try mapped("char-foldcase", 'A'));
    // 写像を持たない文字は、そのまま返る。
    try std.testing.expectEqual(@as(u21, '1'), try mapped("char-upcase", '1'));
    try std.testing.expectEqual(@as(u21, 0x3042), try mapped("char-downcase", 0x3042));
    // ギリシャ文字、キリル文字。
    try std.testing.expectEqual(@as(u21, 0x0391), try mapped("char-upcase", 0x03B1));
    try std.testing.expectEqual(@as(u21, 0x03B1), try mapped("char-downcase", 0x0391));
    try std.testing.expectEqual(@as(u21, 0x0416), try mapped("char-upcase", 0x0436));
    // ß に単純な大文字は無い。完全写像の SS は文字列の手続きの仕事である。
    try std.testing.expectEqual(@as(u21, 0x00DF), try mapped("char-upcase", 0x00DF));
    try std.testing.expectEqual(@as(u21, 0x00DF), try mapped("char-foldcase", 0x1E9E));
    // 語末のシグマは、大文字と畳み込みで、ふつうのシグマと同じになる。
    try std.testing.expectEqual(@as(u21, 0x03A3), try mapped("char-upcase", 0x03C2));
    try std.testing.expectEqual(@as(u21, 0x03C3), try mapped("char-foldcase", 0x03C2));
    try std.testing.expectEqual(@as(u21, 0x03C2), try mapped("char-downcase", 0x03C2));
    // İ の小文字は i で、畳み込みは自分自身である。
    try std.testing.expectEqual(@as(u21, 'i'), try mapped("char-downcase", 0x0130));
    try std.testing.expectEqual(@as(u21, 0x0130), try mapped("char-foldcase", 0x0130));
    // 範囲の端。
    try std.testing.expectEqual(@as(u21, 0), try mapped("char-upcase", 0));
    try std.testing.expectEqual(@as(u21, 0x10FFFF), try mapped("char-foldcase", 0x10FFFF));
}

test "the case-insensitive comparisons compare the folded characters" {
    // 大文字小文字を区別しない。R7RS 6.6 の例: (char-ci=? #\A #\a) は真。
    try std.testing.expect(try compareCodePoints("char-ci=?", &.{ 'A', 'a' }));
    try std.testing.expect(!try compareCodePoints("char=?", &.{ 'A', 'a' }));
    try std.testing.expect(try compareCodePoints("char-ci=?", &.{ 0x03A3, 0x03C3, 0x03C2 }));
    try std.testing.expect(!try compareCodePoints("char-ci=?", &.{ 'a', 'b' }));
    // 順序は、畳み込んだ文字のコードポイントの順である。'Z' は畳み込むと 'z' で、'a' より後になる。
    try std.testing.expect(try compareCodePoints("char-ci>?", &.{ 'Z', 'a' }));
    try std.testing.expect(!try compareCodePoints("char-ci<?", &.{ 'Z', 'a' }));
    try std.testing.expect(try compareCodePoints("char<?", &.{ 'Z', 'a' }));
    // '_' (0x5F) は、'A' と 'a' の間にある。畳み込むと、'A' は 'a' (0x61) になり、'_' より後になる。
    try std.testing.expect(try compareCodePoints("char-ci>?", &.{ 'A', '_' }));
    try std.testing.expect(try compareCodePoints("char-ci<?", &.{ '_', 'A' }));
    try std.testing.expect(try compareCodePoints("char-ci<=?", &.{ 'a', 'A', 'b', 'C' }));
    try std.testing.expect(!try compareCodePoints("char-ci<=?", &.{ 'a', 'C', 'b' }));
    try std.testing.expect(try compareCodePoints("char-ci>=?", &.{ 'C', 'b', 'B', 'a' }));
    // 1つの引数は真である。
    for ([_][]const u8{ "char-ci=?", "char-ci<?", "char-ci>?", "char-ci<=?", "char-ci>=?" }) |name| {
        try std.testing.expect(try compareCodePoints(name, &.{'a'}));
    }
}

test "the case-insensitive comparisons check every argument for being a character" {
    for ([_][]const u8{ "char-ci=?", "char-ci<?", "char-ci>?", "char-ci<=?", "char-ci>=?" }) |name| {
        try std.testing.expectError(error.WrongType, call(name, &.{ .fromCharacter('a'), .fromFixnum(97) }));
        try std.testing.expectError(error.WrongType, call(name, &.{.fromFixnum(97)}));
        try std.testing.expectError(error.WrongType, call(name, &.{ .fromCharacter('b'), .fromCharacter('a'), .fromCharacter('a'), .fromBool(true) }));
    }
}
