//! The external representation of a string (R7RS 6.7, 7.1.1): what the reader
//! reads between double quotes and what `write` writes.
//!
//! 読みと書きをここにまとめてあるので、エスケープの表は1つである。
//!
//! スライス1h(文字列)にあたる。リーダの `"` もプリンタも、このファイルを呼ぶ。

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const isScalarValue = value.isScalarValue;
const Heap = @import("heap.zig").Heap;
const Mode = @import("printer.zig").Mode;

pub const ReadError = error{
    OutOfMemory,
    /// The string does not fit in the heap.
    HeapLimit,
    /// The input ended before the closing quote.
    ///
    /// REPL はこれを受けて別の行を求められる(ADR-0014)。
    Incomplete,
    /// A backslash followed by something that is not an escape, or a `\x`
    /// escape whose value is not a scalar value.
    InvalidEscape,
    /// The bytes between the quotes are not valid UTF-8.
    ///
    /// 生のバイトは検査せずに集めるので、閉じる引用符まで読んでから確かめる。
    InvalidUtf8,
};

/// Reads the string literal that starts at `src[pos.*]`, which is the opening
/// `"`, and moves `pos` past the closing one.
///
/// 文字列は `heap` に作る。`scratch` は、バイトを集めている間それを保持する。
/// エラーのときは `pos` を元の位置のままにする。
///
/// 入力は、普通はインタプリタが全体を検査した妥当な UTF-8 である。それでも、この関数は
/// 入力に頼らず、集めたバイトが妥当でなければ `InvalidUtf8` を返す。ファズなどが
/// リーダに任意のバイトを直接渡しても、不正な文字列がヒープに入らないようにするためである。
/// エスケープでないバイトはそのままコピーする。生の改行、タブ、非 ASCII 文字のバイトは、
/// すべて文字列に含まれる。
pub fn read(src: []const u8, pos: *usize, scratch: std.mem.Allocator, heap: *Heap) ReadError!Value {
    std.debug.assert(src[pos.*] == '"');
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(scratch);
    var i = pos.* + 1;
    while (true) {
        if (i >= src.len) return error.Incomplete;
        const c = src[i];
        i += 1;
        switch (c) {
            '"' => break,
            '\\' => try readEscape(src, &i, scratch, &bytes),
            else => try bytes.append(scratch, c),
        }
    }
    // 他のエラー(閉じていない、エスケープの誤り)を先に返してから確かめる。REPL は
    // 閉じていない文字列に続きの行を求められる。
    if (!std.unicode.utf8ValidateSlice(bytes.items)) return error.InvalidUtf8;
    const s = try heap.createString(bytes.items);
    pos.* = i;
    return .fromString(s);
}

/// Reads the escape whose backslash has just been read, and appends what it
/// stands for to `bytes`.
///
/// `i` はバックスラッシュの次の添字である。
fn readEscape(src: []const u8, i: *usize, scratch: std.mem.Allocator, bytes: *std.ArrayList(u8)) ReadError!void {
    if (i.* >= src.len) return error.Incomplete;
    const c = src[i.*];
    i.* += 1;
    const byte: u8 = switch (c) {
        'a' => 7,
        'b' => 8,
        't' => '\t',
        'n' => '\n',
        'r' => '\r',
        '"', '\\', '|' => c,
        'x' => return readHexEscape(src, i, scratch, bytes),
        else => return error.InvalidEscape,
    };
    try bytes.append(scratch, byte);
}

/// Reads the rest of `\x<hex>;`, after the `x`, and appends the character's
/// UTF-8 encoding to `bytes`.
fn readHexEscape(src: []const u8, i: *usize, scratch: std.mem.Allocator, bytes: *std.ArrayList(u8)) ReadError!void {
    var code: u32 = 0;
    var digits: usize = 0;
    while (true) {
        if (i.* >= src.len) return error.Incomplete;
        const c = src[i.*];
        i.* += 1;
        if (c == ';') break;
        const digit = std.fmt.charToDigit(c, 16) catch return error.InvalidEscape;
        // 値が最後のスカラ値を超えたら、そこに留める。桁が長く続いても、あふれて
        // 巻き戻り、範囲内に戻ってしまうことがない。
        if (code <= max_scalar_value) code = code * 16 + digit;
        digits += 1;
    }
    if (digits == 0 or !isScalarValue(code)) return error.InvalidEscape;
    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(code), &encoded) catch unreachable;
    try bytes.appendSlice(scratch, encoded[0..len]);
}

const max_scalar_value = 0x10FFFF;

/// Writes the string `bytes` as `write` (in quotes, with escapes) or as
/// `display` (the bytes as they are) would.
///
/// `write` は、リーダが別のものと取り違えるものをエスケープする。`"` と `\\`、
/// および制御文字で、R7RS のエスケープがあるものはそれを使い、ないものは
/// `\x<hex>;` とする。それ以外は非 ASCII 文字も含め、バイトのまま書く。リーダは
/// それを読み戻せる。
pub fn write(out: *std.Io.Writer, mode: Mode, bytes: []const u8) std.Io.Writer.Error!void {
    if (mode == .display) return out.writeAll(bytes);
    try out.writeByte('"');
    // エスケープが要らないバイトは、連続した塊でまとめて書く。
    var run_start: usize = 0;
    for (bytes, 0..) |c, i| {
        if (!needsEscape(c)) continue;
        try out.writeAll(bytes[run_start..i]);
        run_start = i + 1;
        switch (c) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            7 => try out.writeAll("\\a"),
            8 => try out.writeAll("\\b"),
            '\t' => try out.writeAll("\\t"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            else => try out.print("\\x{x};", .{c}),
        }
    }
    try out.writeAll(bytes[run_start..]);
    try out.writeByte('"');
}

/// Whether `write` escapes the byte: `"`, `\\`, the C0 controls and DEL.
///
/// マルチバイト文字のバイトは、どれも 0x80 以上なので、これらに当たることはない。
fn needsEscape(c: u8) bool {
    return c == '"' or c == '\\' or c < 0x20 or c == 0x7f;
}

test {
    std.testing.refAllDecls(@This());
}

/// Reads the literal at the start of `src` into `heap` and returns its bytes.
fn readBytes(heap: *Heap, src: []const u8) ReadError![]const u8 {
    var pos: usize = 0;
    const v = try read(src, &pos, std.testing.allocator, heap);
    return v.asString().?.bytes;
}

fn expectRead(expected: []const u8, src: []const u8) !void {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    try std.testing.expectEqualStrings(expected, try readBytes(&heap, src));
}

fn expectReadError(expected: ReadError, src: []const u8) !void {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    var pos: usize = 0;
    try std.testing.expectError(expected, read(src, &pos, std.testing.allocator, &heap));
    try std.testing.expectEqual(0, pos);
}

test "read: an empty string and a plain one" {
    try expectRead("", "\"\"");
    try expectRead("abc", "\"abc\"");
    try expectRead("hello world", "\"hello world\"");
}

test "read: every escape of R7RS" {
    try expectRead("\x07", "\"\\a\"");
    try expectRead("\x08", "\"\\b\"");
    try expectRead("\t", "\"\\t\"");
    try expectRead("\n", "\"\\n\"");
    try expectRead("\r", "\"\\r\"");
    try expectRead("\"", "\"\\\"\"");
    try expectRead("\\", "\"\\\\\"");
    try expectRead("|", "\"\\|\"");
    try expectRead("a\tb\"c\\d", "\"a\\tb\\\"c\\\\d\"");
}

test "read: a hex escape is the character with that code, in either case" {
    try expectRead("A", "\"\\x41;\"");
    try expectRead("\u{3bb}", "\"\\x3bb;\"");
    try expectRead("\u{3bb}", "\"\\x3BB;\"");
    try expectRead("a\u{3bb}b", "\"a\\x3Bb;b\"");
    try expectRead("\x00", "\"\\x0;\"");
    try expectRead("\u{10FFFF}", "\"\\x10ffff;\"");
    try expectRead("\u{7ff}\u{800}", "\"\\x7ff;\\x800;\"");
    // 先頭の 0 も他の桁と同じ桁であり、いくつ続いても構わない。
    try expectRead("A", "\"\\x0000000000000000000000041;\"");
}

test "read: a hex escape that is not a scalar value, or not an escape, is invalid" {
    try expectReadError(error.InvalidEscape, "\"\\x41\"");
    try expectReadError(error.InvalidEscape, "\"\\x41 \"");
    try expectReadError(error.InvalidEscape, "\"\\xD800;\"");
    try expectReadError(error.InvalidEscape, "\"\\xDFFF;\"");
    try expectReadError(error.InvalidEscape, "\"\\x110000;\"");
    try expectReadError(error.InvalidEscape, "\"\\x;\"");
    try expectReadError(error.InvalidEscape, "\"\\xg;\"");
    // 桁が多すぎて、32ビットの値なら巻き戻って範囲内に戻ってしまう。
    try expectReadError(error.InvalidEscape, "\"\\x100000041;\"");
    try expectReadError(error.InvalidEscape, "\"\\x1000000000000000041;\"");
    // 最後のスカラ値の後ろに桁が続けば、値は範囲外になる。最後のスカラ値は
    // それ自体が有効な値だが、そこに留まることはない。
    try expectReadError(error.InvalidEscape, "\"\\x10ffff0;\"");
    try expectReadError(error.InvalidEscape, "\"\\x10fffff;\"");
    try expectReadError(error.InvalidEscape, "\"\\x10ffff00000000;\"");
}

test "read: a backslash that begins no escape is invalid" {
    try expectReadError(error.InvalidEscape, "\"\\q\"");
    try expectReadError(error.InvalidEscape, "\"a\\zb\"");
    try expectReadError(error.InvalidEscape, "\"\\X41;\"");
    // 行継続はまだ読まない(スライス1h)。
    try expectReadError(error.InvalidEscape, "\"a\\\nb\"");
}

test "read: a string that does not close is incomplete" {
    try expectReadError(error.Incomplete, "\"");
    try expectReadError(error.Incomplete, "\"abc");
    try expectReadError(error.Incomplete, "\"a\\\"");
    try expectReadError(error.Incomplete, "\"a\\");
    try expectReadError(error.Incomplete, "\"\\x");
    try expectReadError(error.Incomplete, "\"\\x4");
    try expectReadError(error.Incomplete, "\"\\x41");
}

test "read: a raw newline, a tab and non-ASCII bytes belong to the string" {
    try expectRead("a\nb", "\"a\nb\"");
    try expectRead("\t\r", "\"\t\r\"");
    try expectRead("\u{3053}\u{3093}\u{306b}\u{3061}\u{306f}", "\"\u{3053}\u{3093}\u{306b}\u{3061}\u{306f}\"");
    try expectRead("a \u{3bb} \u{1F600}", "\"a \u{3bb} \u{1F600}\"");
}

test "read: bytes that are not valid UTF-8 are an error, not a string" {
    // 生のバイトは検査せずにコピーするが、文字列にする前に妥当性を確かめる。
    // 妥当でないまま `createString` に渡すと、その前提が壊れる。
    try expectReadError(error.InvalidUtf8, "\"\xff\"");
    // 過長符号化、途中で切れた列、サロゲートの符号化、継続バイトの単独出現。
    try expectReadError(error.InvalidUtf8, "\"\xc0\x80\"");
    try expectReadError(error.InvalidUtf8, "\"\xe3\x81\"");
    try expectReadError(error.InvalidUtf8, "\"\xed\xa0\x80\"");
    try expectReadError(error.InvalidUtf8, "\"a\x80b\"");
    // 閉じる引用符の直前で切れた列も、引用符を飲み込まずに拒否する。
    try expectReadError(error.InvalidUtf8, "\"\xe3\"");
}

test "read: the other errors of a literal come before the UTF-8 check" {
    // 閉じていない文字列は、REPL が続きを求められるように Incomplete のままにする。
    try expectReadError(error.Incomplete, "\"\xff");
    try expectReadError(error.InvalidEscape, "\"\xff\\q\"");
}

test "read: a hex escape never makes invalid UTF-8, so it is not an UTF-8 error" {
    try expectRead("\u{10FFFF}\u{3bb}\x00", "\"\\x10ffff;\\x3bb;\\x0;\"");
}

test "read: the position is left after the closing quote, and what follows is not read" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const src = "(\"ab\" \"cd\")";
    var pos: usize = 1;
    const first = try read(src, &pos, std.testing.allocator, &heap);
    try std.testing.expectEqualStrings("ab", first.asString().?.bytes);
    try std.testing.expectEqual(5, pos);
    pos = 6;
    const second = try read(src, &pos, std.testing.allocator, &heap);
    try std.testing.expectEqualStrings("cd", second.asString().?.bytes);
    try std.testing.expectEqual(10, pos);
    // エスケープされた引用符は、文字列を閉じない。
    pos = 0;
    const third = try read("\"a\\\"\" b", &pos, std.testing.allocator, &heap);
    try std.testing.expectEqualStrings("a\"", third.asString().?.bytes);
    try std.testing.expectEqual(5, pos);
}

test "read: a string that does not fit under the limit gives the accounting back" {
    // 2バイトの文字列の計上量を、専用のヒープから取る。
    var probe: Heap = .init(std.testing.allocator, .{});
    defer probe.deinit();
    _ = try probe.createString("ok");
    var heap: Heap = .init(std.testing.allocator, .{ .limit = probe.accounted });
    defer heap.deinit();
    try expectReadErrorIn(&heap, error.HeapLimit, "\"a long string\"");
    try std.testing.expectEqual(0, heap.accounted);
    // 小さいものはまだ収まる。失敗してもヒープは使えるままだった。
    try std.testing.expectEqualStrings("ok", try readBytes(&heap, "\"ok\""));
}

fn expectReadErrorIn(heap: *Heap, expected: ReadError, src: []const u8) !void {
    var pos: usize = 0;
    try std.testing.expectError(expected, read(src, &pos, std.testing.allocator, heap));
    try std.testing.expectEqual(0, pos);
}

test "read: a scratch allocation that fails is an out of memory, and nothing leaks" {
    // 最初の確保はバイトのリスト、2番目は文字列のコピーである。ヒープは自前の
    // アロケータを持つので、失敗させるのはリストだけである。
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var pos: usize = 0;
    try std.testing.expectError(error.OutOfMemory, read("\"abc\"", &pos, failing.allocator(), &heap));
    try std.testing.expectEqual(0, pos);
    try std.testing.expectEqual(0, heap.accounted);
    // もっと後の失敗、つまりリストが育つ途中の失敗では、リストが持っていたものを
    // 解放する。(リストの最初の確保は128バイトなので、文字列はそれより長くする。)
    var long: [302]u8 = undefined;
    @memset(&long, 'x');
    long[0] = '"';
    long[301] = '"';
    // その場での拡張は拒否されるので、2回目の確保が要り、それが失敗する。
    var later: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, read(&long, &pos, later.allocator(), &heap));
    try std.testing.expectEqual(1, later.allocations);
    try std.testing.expectEqual(later.allocated_bytes, later.freed_bytes);
    // 成功したときも、スクラッチは返される。
    var ok: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    _ = try read("\"abc\"", &pos, ok.allocator(), &heap);
    try std.testing.expectEqual(ok.allocated_bytes, ok.freed_bytes);
}

fn expectWritten(expected: []const u8, mode: Mode, bytes: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, mode, bytes);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "write: quotes, and an empty or plain string" {
    try expectWritten("\"\"", .write, "");
    try expectWritten("\"abc\"", .write, "abc");
    try expectWritten("\"hello world\"", .write, "hello world");
}

test "write: a quote and a backslash are escaped" {
    try expectWritten("\"\\\"\"", .write, "\"");
    try expectWritten("\"\\\\\"", .write, "\\");
    try expectWritten("\"say \\\"hi\\\" a\\\\b\"", .write, "say \"hi\" a\\b");
}

test "write: the controls that have an escape are written with it" {
    try expectWritten("\"\\a\\b\\t\\n\\r\"", .write, "\x07\x08\x09\x0a\x0d");
    try expectWritten("\"a\\nb\"", .write, "a\nb");
}

test "write: the other controls and DEL are written as lowercase hex with no padding" {
    try expectWritten("\"\\x0;\"", .write, "\x00");
    try expectWritten("\"\\x1;\"", .write, "\x01");
    try expectWritten("\"\\xb;\\xc;\"", .write, "\x0b\x0c");
    try expectWritten("\"\\x10;\"", .write, "\x10");
    try expectWritten("\"\\x1f;\"", .write, "\x1f");
    try expectWritten("\"\\x7f;\"", .write, "\x7f");
    // エスケープの次のバイトは、その桁とは取られない。`;` がエスケープを終わらせる。

    try expectWritten("\"\\x1;a\"", .write, "\x01a");
}

test "write: a character that is not ASCII is written as it is" {
    try expectWritten("\"\u{3053}\u{3093}\u{306b}\u{3061}\u{306f}\"", .write, "\u{3053}\u{3093}\u{306b}\u{3061}\u{306f}");
    try expectWritten("\"a \u{3bb} \u{1F600}\"", .write, "a \u{3bb} \u{1F600}");
    try expectWritten("\"\u{80}\u{7ff}\"", .write, "\u{80}\u{7ff}");
}

test "write: display writes the bytes as they are" {
    try expectWritten("", .display, "");
    try expectWritten("abc", .display, "abc");
    try expectWritten("say \"hi\" a\\b\n\t\x00\x7f", .display, "say \"hi\" a\\b\n\t\x00\x7f");
    try expectWritten("a \u{3bb}", .display, "a \u{3bb}");
}

test "write then read then write gives the same text, for every ASCII byte and some others" {
    var all: [128 + 9]u8 = undefined;
    for (0..128) |i| all[i] = @intCast(i);
    @memcpy(all[128..], "\u{3bb}\u{3053}\u{1F600}");
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    try write(&first.writer, .write, &all);
    var pos: usize = 0;
    const s = try read(first.written(), &pos, std.testing.allocator, &heap);
    try std.testing.expectEqual(first.written().len, pos);
    try std.testing.expectEqualSlices(u8, &all, s.asString().?.bytes);
    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    try write(&second.writer, .write, s.asString().?.bytes);
    try std.testing.expectEqualStrings(first.written(), second.written());
}
