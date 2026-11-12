//! Key decoder for the line editor.
//!
//! 端末から読んだバイト列を、キーの事象に解読する純粋な関数 `decode` を提供する。
//! 入出力にも OS にも触れない。バイトを読む側(7h の生モードと 7j の組み込み)が、
//! 読んだバイトを溜めた配列の先頭に対して `decode` を呼び、`consumed` の分だけ
//! 先頭から捨てる。
//!
//! 契約:
//! - 入力が空なら `need_more` を返す。
//! - 事象の途中で切れた列(UTF-8 の途中、`ESC` だけ、`ESC [` の途中など)は
//!   `need_more` を返す。続きのバイトが届いたら、先頭から同じ列でもう一度呼ぶ。
//! - `key.consumed` と `invalid` は、1 以上で `bytes.len` 以下である。
//!   呼び出し側が、これを使って必ず前に進める。
//! - どんなバイト列でも止まらず、異常終了しない。

const std = @import("std");

/// The four arrow keys.
pub const Arrow = enum { up, down, left, right };

/// A decoded key event.
///
/// - `insert`: 印字できる文字の入力。符号位置は、UTF-8 として正しい範囲の値である。
///   `0x20` から `0x7E` の ASCII と、`0x80` 以上の正しい UTF-8 の文字が入る。
/// - `ctrl`: 制御バイトそのもの(`0x00` から `0x1F` と `0x7F`)。`Ctrl-A` は `0x01`、
///   `Tab` は `0x09`、`Enter` は `0x0D`(端末の設定によっては `0x0A`)、
///   `Backspace` は `0x7F`(古い端末では `0x08`)、`Ctrl-_` は `0x1F` である。
///   単独の `ESC`(`0x1B`)も、呼び出し側が時間切れと判断したときに、同じ形で扱える
///   (下の `decode` の注を参照)。
/// - `alt`: `ESC` に続く 1 文字。`Alt-B` は `alt = 'b'`、`Alt-Backspace` は `alt = 0x7F`。
///   続く文字は、印字できる文字のほか、制御バイトでもよい(`ESC` 自身を除く)。
/// - `arrow`、`home`、`end`、`delete`: 修飾キーのない CSI または SS3 の列。
/// - `paste_begin`、`paste_end`: 括弧つき貼り付け(`CSI 200 ~` と `CSI 201 ~`)の印。
///   貼り付けの中身は、普通のバイトとして届く。モードを切り替えるのは呼び出し側である。
/// - `unknown`: 形としては正しいが、このエディタが割り当てを持たない列。修飾キーつきの
///   矢印(`CSI 1;5 C` など)、`Insert`、`PageUp` などを含む。
pub const Key = union(enum) {
    insert: u21,
    ctrl: u8,
    alt: u21,
    arrow: Arrow,
    home,
    end,
    delete,
    paste_begin,
    paste_end,
    unknown,
};

/// The result of decoding the front of a byte buffer.
pub const Decoded = union(enum) {
    /// A complete event. `consumed` bytes were used (at least 1).
    key: struct { key: Key, consumed: usize },
    /// The bytes are the start of an event, but not all of it.
    need_more,
    /// The front is not a valid event. The caller discards this many bytes (at least 1).
    invalid: usize,
};

/// CSI の列の上限(`ESC [` を含む)。終端のバイトが来ないまま、この長さを超えたら
/// 不正とする。無限に溜め込まないためである。
pub const max_csi_len = 32;

const esc = 0x1B;

/// Decodes one event from the front of `bytes`.
///
/// 単独の `ESC` は、`Esc` キーか、`Alt` や矢印の列の始まりか、この関数からは
/// 決められないので、`need_more` を返す。呼び出し側は、続きのバイトを一定の時間
/// 待っても来なかったときに、`ESC` を `.ctrl = 0x1B` として自分で扱う。
/// 時間は純粋な関数の外のことなので、ここでは持たない。
pub fn decode(bytes: []const u8) Decoded {
    if (bytes.len == 0) return .need_more;
    const b0 = bytes[0];
    if (b0 == esc) return decodeEscape(bytes);
    if (b0 < 0x20 or b0 == 0x7F) return one(.{ .ctrl = b0 });
    return switch (decodeUtf8(bytes)) {
        .ok => |c| .{ .key = .{ .key = .{ .insert = c.cp }, .consumed = c.len } },
        .need_more => .need_more,
        .invalid => |n| .{ .invalid = n },
    };
}

fn one(key: Key) Decoded {
    return .{ .key = .{ .key = key, .consumed = 1 } };
}

fn decodeEscape(bytes: []const u8) Decoded {
    if (bytes.len == 1) return .need_more;
    return switch (bytes[1]) {
        '[' => decodeCsi(bytes),
        'O' => decodeSs3(bytes),
        // ESC ESC: 最初の ESC は単独の Esc として扱い、2つ目は次の呼び出しで解読する。
        esc => .{ .key = .{ .key = .{ .ctrl = esc }, .consumed = 1 } },
        else => switch (decodeUtf8Or(bytes[1..])) {
            .ok => |c| .{ .key = .{ .key = .{ .alt = c.cp }, .consumed = 1 + c.len } },
            .need_more => .need_more,
            .invalid => |n| .{ .invalid = 1 + n },
        },
    };
}

/// `ESC O x`(アプリケーションモードの矢印、Home、End)。
fn decodeSs3(bytes: []const u8) Decoded {
    if (bytes.len < 3) return .need_more;
    const key: Key = switch (bytes[2]) {
        'A' => .{ .arrow = .up },
        'B' => .{ .arrow = .down },
        'C' => .{ .arrow = .right },
        'D' => .{ .arrow = .left },
        'H' => .home,
        'F' => .end,
        else => .unknown,
    };
    // 終端が制御バイトや 0x80 以上のときも、3バイトを1つの不明な列として捨てる。
    return .{ .key = .{ .key = key, .consumed = 3 } };
}

/// `ESC [ <param bytes 0x30-0x3F>* <intermediate bytes 0x20-0x2F>* <final 0x40-0x7E>`。
fn decodeCsi(bytes: []const u8) Decoded {
    var i: usize = 2;
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        if (b >= 0x40 and b <= 0x7E) {
            const params = bytes[2..i];
            return .{ .key = .{ .key = csiKey(params, b), .consumed = i + 1 } };
        }
        // 中間のバイトとパラメータのバイトだけが、終端の前に来てよい。
        if (b < 0x20 or b > 0x3F) return .{ .invalid = i };
        if (i + 1 >= max_csi_len) return .{ .invalid = i + 1 };
    }
    return .need_more;
}

fn csiKey(params: []const u8, final: u8) Key {
    // 割り当てがあるのは、パラメータが空の列と、数字だけの決まった列である。中間のバイト
    // (0x20-0x2F)を含む列は、どの比較にも一致しないので、`.unknown` になる。
    switch (final) {
        'A' => return if (params.len == 0) .{ .arrow = .up } else .unknown,
        'B' => return if (params.len == 0) .{ .arrow = .down } else .unknown,
        'C' => return if (params.len == 0) .{ .arrow = .right } else .unknown,
        'D' => return if (params.len == 0) .{ .arrow = .left } else .unknown,
        'H' => return if (params.len == 0) .home else .unknown,
        'F' => return if (params.len == 0) .end else .unknown,
        '~' => {
            if (std.mem.eql(u8, params, "1") or std.mem.eql(u8, params, "7")) return .home;
            if (std.mem.eql(u8, params, "4") or std.mem.eql(u8, params, "8")) return .end;
            if (std.mem.eql(u8, params, "3")) return .delete;
            if (std.mem.eql(u8, params, "200")) return .paste_begin;
            if (std.mem.eql(u8, params, "201")) return .paste_end;
            return .unknown;
        },
        else => return .unknown,
    }
}

const Utf8 = union(enum) {
    ok: struct { cp: u21, len: usize },
    need_more,
    /// 先頭から捨てるバイト数(1 以上)。正しく始まっていたところまでを捨てる。
    invalid: usize,
};

/// ESC の直後の1文字。制御バイトと 0x7F は、そのまま符号位置として返す。
fn decodeUtf8Or(bytes: []const u8) Utf8 {
    if (bytes[0] < 0x80) return .{ .ok = .{ .cp = bytes[0], .len = 1 } };
    return decodeUtf8(bytes);
}

/// 先頭の1文字を UTF-8 として解読する。`bytes` は空でない。
/// 過長な符号化、サロゲート、U+10FFFF を超える値は不正である。
fn decodeUtf8(bytes: []const u8) Utf8 {
    const b0 = bytes[0];
    if (b0 < 0x80) return .{ .ok = .{ .cp = b0, .len = 1 } };
    const len: usize, const first_mask: u8 = switch (b0) {
        0xC2...0xDF => .{ 2, 0x1F },
        0xE0...0xEF => .{ 3, 0x0F },
        0xF0...0xF4 => .{ 4, 0x07 },
        else => return .{ .invalid = 1 },
    };
    var cp: u32 = b0 & first_mask;
    var i: usize = 1;
    while (i < len) : (i += 1) {
        if (i >= bytes.len) return .need_more;
        const b = bytes[i];
        // 2バイト目だけ、先頭のバイトによって範囲が狭まる(過長、サロゲート、範囲外の除外)。
        const lo: u8, const hi: u8 = if (i == 1) switch (b0) {
            0xE0 => .{ 0xA0, 0xBF },
            0xED => .{ 0x80, 0x9F },
            0xF0 => .{ 0x90, 0xBF },
            0xF4 => .{ 0x80, 0x8F },
            else => .{ 0x80, 0xBF },
        } else .{ 0x80, 0xBF };
        if (b < lo or b > hi) return .{ .invalid = i };
        cp = (cp << 6) | (b & 0x3F);
    }
    return .{ .ok = .{ .cp = @intCast(cp), .len = len } };
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectKey(expected: Key, consumed: usize, bytes: []const u8) !void {
    const d = decode(bytes);
    switch (d) {
        .key => |k| {
            try testing.expectEqualDeep(expected, k.key);
            try testing.expectEqual(consumed, k.consumed);
        },
        else => {
            std.debug.print("expected a key for {any}, got {any}\n", .{ bytes, d });
            return error.TestExpectedEqual;
        },
    }
}

fn expectNeedMore(bytes: []const u8) !void {
    const d = decode(bytes);
    if (d != .need_more) {
        std.debug.print("expected need_more for {any}, got {any}\n", .{ bytes, d });
        return error.TestExpectedEqual;
    }
}

fn expectInvalid(n: usize, bytes: []const u8) !void {
    const d = decode(bytes);
    switch (d) {
        .invalid => |m| try testing.expectEqual(n, m),
        else => {
            std.debug.print("expected invalid for {any}, got {any}\n", .{ bytes, d });
            return error.TestExpectedEqual;
        },
    }
}

test "empty input needs more" {
    try expectNeedMore("");
}

test "printable ASCII is an insert" {
    try expectKey(.{ .insert = 'a' }, 1, "a");
    try expectKey(.{ .insert = ' ' }, 1, " ");
    try expectKey(.{ .insert = '~' }, 1, "~");
    try expectKey(.{ .insert = '(' }, 1, "(abc");
}

test "control bytes are ctrl, including Enter, Tab and Backspace" {
    try expectKey(.{ .ctrl = 0x01 }, 1, "\x01");
    try expectKey(.{ .ctrl = 0x00 }, 1, "\x00");
    try expectKey(.{ .ctrl = 0x09 }, 1, "\t");
    try expectKey(.{ .ctrl = 0x0D }, 1, "\r");
    try expectKey(.{ .ctrl = 0x0A }, 1, "\n");
    try expectKey(.{ .ctrl = 0x1F }, 1, "\x1F");
    try expectKey(.{ .ctrl = 0x7F }, 1, "\x7F");
    try expectKey(.{ .ctrl = 0x08 }, 1, "\x08");
}

test "multi-byte UTF-8 is an insert of the code point" {
    try expectKey(.{ .insert = 0xE9 }, 2, "\xC3\xA9"); // é
    try expectKey(.{ .insert = 0x3042 }, 3, "あ");
    try expectKey(.{ .insert = 0x1F600 }, 4, "\xF0\x9F\x98\x80");
    try expectKey(.{ .insert = 0x80 }, 2, "\xC2\x80");
    try expectKey(.{ .insert = 0x7FF }, 2, "\xDF\xBF");
    try expectKey(.{ .insert = 0x800 }, 3, "\xE0\xA0\x80");
    try expectKey(.{ .insert = 0xD7FF }, 3, "\xED\x9F\xBF");
    try expectKey(.{ .insert = 0xE000 }, 3, "\xEE\x80\x80");
    try expectKey(.{ .insert = 0xFFFF }, 3, "\xEF\xBF\xBF");
    try expectKey(.{ .insert = 0x10000 }, 4, "\xF0\x90\x80\x80");
    try expectKey(.{ .insert = 0x10FFFF }, 4, "\xF4\x8F\xBF\xBF");
    // 後ろに別のバイトが続いても、1文字ぶんだけを使う。
    try expectKey(.{ .insert = 0x3042 }, 3, "あx");
}

test "a UTF-8 sequence cut short needs more, at every length" {
    try expectNeedMore("\xC3");
    try expectNeedMore("\xE3");
    try expectNeedMore("\xE3\x81");
    try expectNeedMore("\xF0");
    try expectNeedMore("\xF0\x9F");
    try expectNeedMore("\xF0\x9F\x98");
    // 2バイト目が、先頭のバイトの許す範囲の端のとき。
    try expectNeedMore("\xE0\xA0");
    try expectNeedMore("\xED\x9F");
    try expectNeedMore("\xF0\x90");
    try expectNeedMore("\xF4\x8F");
}

test "invalid UTF-8 is discarded up to the valid part" {
    try expectInvalid(1, "\x80"); // 継続バイトだけ
    try expectInvalid(1, "\xBF");
    try expectInvalid(1, "\xC0\x80"); // 過長な2バイト
    try expectInvalid(1, "\xC1\xBF");
    try expectInvalid(1, "\xF5\x80\x80\x80"); // U+10FFFF を超える
    try expectInvalid(1, "\xFF");
    try expectInvalid(1, "\xFE");
    try expectInvalid(1, "\xE0\x80\x80"); // 過長な3バイト
    try expectInvalid(1, "\xED\xA0\x80"); // サロゲート
    try expectInvalid(1, "\xF0\x80\x80\x80"); // 過長な4バイト
    try expectInvalid(1, "\xF4\x90\x80\x80"); // U+10FFFF を超える
    try expectInvalid(1, "\xC3("); // 継続バイトでない
    try expectInvalid(2, "\xE3\x81("); // 2バイトまでは正しかった
    try expectInvalid(3, "\xF0\x9F\x98("); // 3バイトまでは正しかった
    // 途中で切れていても、すでに不正と分かるものは need_more にしない。
    try expectInvalid(1, "\xE0\x80");
    try expectInvalid(1, "\xED\xA0");
    try expectInvalid(1, "\xF4\x90");
}

test "ESC alone needs more" {
    try expectNeedMore("\x1B");
}

test "ESC followed by a character is Alt" {
    try expectKey(.{ .alt = 'b' }, 2, "\x1Bb");
    try expectKey(.{ .alt = 'F' }, 2, "\x1BF");
    try expectKey(.{ .alt = 'd' }, 2, "\x1Bdx");
    try expectKey(.{ .alt = 0x7F }, 2, "\x1B\x7F");
    try expectKey(.{ .alt = 0x0D }, 2, "\x1B\r");
    try expectKey(.{ .alt = 0x3042 }, 4, "\x1Bあ");
}

test "Alt with a multi-byte character waits for the rest" {
    try expectNeedMore("\x1B\xE3");
    try expectNeedMore("\x1B\xE3\x81");
}

test "Alt with invalid UTF-8 discards the ESC and the bad part" {
    try expectInvalid(2, "\x1B\x80");
    try expectInvalid(2, "\x1B\xE3(");
    try expectInvalid(3, "\x1B\xE3\x81(");
}

test "ESC ESC is a lone Esc followed by whatever comes next" {
    try expectKey(.{ .ctrl = 0x1B }, 1, "\x1B\x1B");
    try expectKey(.{ .ctrl = 0x1B }, 1, "\x1B\x1B[A");
}

test "CSI arrows, Home, End and Delete" {
    try expectKey(.{ .arrow = .up }, 3, "\x1B[A");
    try expectKey(.{ .arrow = .down }, 3, "\x1B[B");
    try expectKey(.{ .arrow = .right }, 3, "\x1B[C");
    try expectKey(.{ .arrow = .left }, 3, "\x1B[D");
    try expectKey(.home, 3, "\x1B[H");
    try expectKey(.end, 3, "\x1B[F");
    try expectKey(.home, 4, "\x1B[1~");
    try expectKey(.home, 4, "\x1B[7~");
    try expectKey(.end, 4, "\x1B[4~");
    try expectKey(.end, 4, "\x1B[8~");
    try expectKey(.delete, 4, "\x1B[3~");
    try expectKey(.{ .arrow = .up }, 3, "\x1B[Axyz");
}

test "SS3 arrows, Home and End" {
    try expectKey(.{ .arrow = .up }, 3, "\x1BOA");
    try expectKey(.{ .arrow = .down }, 3, "\x1BOB");
    try expectKey(.{ .arrow = .right }, 3, "\x1BOC");
    try expectKey(.{ .arrow = .left }, 3, "\x1BOD");
    try expectKey(.home, 3, "\x1BOH");
    try expectKey(.end, 3, "\x1BOF");
    try expectKey(.unknown, 3, "\x1BOP"); // F1
    // ESC O は Alt-Shift-O ではなく SS3 の始まりとして扱う。
    try expectNeedMore("\x1BO");
}

test "bracketed paste markers" {
    try expectKey(.paste_begin, 6, "\x1B[200~");
    try expectKey(.paste_end, 6, "\x1B[201~");
    try expectKey(.paste_begin, 6, "\x1B[200~abc");
}

test "CSI with modifiers or other parameters is unknown but consumed whole" {
    try expectKey(.unknown, 6, "\x1B[1;5C"); // Ctrl-Right
    try expectKey(.unknown, 6, "\x1B[1;3D"); // Alt-Left
    try expectKey(.unknown, 6, "\x1B[3;5~"); // Ctrl-Delete
    try expectKey(.unknown, 4, "\x1B[2~"); // Insert
    try expectKey(.unknown, 4, "\x1B[5~"); // PageUp
    try expectKey(.unknown, 4, "\x1B[6~"); // PageDown
    try expectKey(.unknown, 5, "\x1B[15~"); // F5
    // パラメータつきの矢印、Home、End は、修飾キーつきの列として扱い、割り当てない。
    inline for (.{ 'A', 'B', 'C', 'D', 'H', 'F' }) |f| {
        try expectKey(.unknown, 4, std.fmt.comptimePrint("\x1B[1{c}", .{f}));
        try expectKey(.unknown, 4, std.fmt.comptimePrint("\x1B[ {c}", .{f})); // 中間のバイト
    }
    try expectKey(.unknown, 3, "\x1B[Z"); // Shift-Tab
    try expectKey(.unknown, 4, "\x1B[ q"); // 中間のバイトを含む
    try expectKey(.unknown, 7, "\x1B[2000~"); // 200 と 2000 を取り違えない
    try expectKey(.unknown, 5, "\x1B[20~");
    try expectKey(.unknown, 5, "\x1B[30~"); // 3 と 30 を取り違えない
    try expectKey(.unknown, 5, "\x1B[14~");
    try expectKey(.unknown, 5, "\x1B[17~");
}

test "a CSI sequence cut short needs more, at every length" {
    const seqs = [_][]const u8{ "\x1B[A", "\x1B[1;5C", "\x1B[200~", "\x1B[201~", "\x1B[3~", "\x1BOA" };
    for (seqs) |s| {
        var n: usize = 1;
        while (n < s.len) : (n += 1) try expectNeedMore(s[0..n]);
        try testing.expect(decode(s) == .key);
    }
}

test "a malformed CSI is discarded up to the offending byte" {
    try expectInvalid(2, "\x1B[\x01"); // 制御バイト
    try expectInvalid(3, "\x1B[1\x7F");
    try expectInvalid(3, "\x1B[1\xC3");
    try expectInvalid(2, "\x1B[\x1B[A");
    // 中間のバイトのあとのパラメータのバイトは、ECMA-48 の文法には合わないが、受理して
    // `.unknown` にする(厳密に弾くと、捨てる範囲の判断が増えるだけで、利点が無い)。
    try expectKey(.unknown, 5, "\x1B[ 1A");
}

test "bytes after the first event are never consumed" {
    try expectKey(.{ .arrow = .up }, 3, "\x1BOAx");
    try expectKey(.{ .ctrl = 0x01 }, 1, "\x01a");
    try expectKey(.{ .alt = 'b' }, 2, "\x1Bbc");
    try expectKey(.unknown, 3, "\x1BOPx");
    try expectKey(.delete, 4, "\x1B[3~a");
}

test "CSI byte class boundaries" {
    try expectKey(.unknown, 3, "\x1B[@"); // 終端の下限
    try expectKey(.unknown, 3, "\x1B[~"); // 終端の上限
    try expectInvalid(2, "\x1B[\x1F"); // 制御バイトの上限
    try expectKey(.unknown, 6, "\x1B[?25h"); // 0x3F はパラメータのバイト
    try expectKey(.unknown, 9, "\x1B[<0;1;1M"); // 0x3C
    try expectKey(.unknown, 10, "\x1B[1;2;3;4~"); // max_csi_len より十分短い列
    try expectInvalid(2, "\x1B[\x7F"); // 0x7F は終端でもパラメータでもない
}

test "UTF-8 second-byte ranges accept both ends" {
    try expectKey(.{ .insert = 0xD000 }, 3, "\xED\x80\x80");
    try expectKey(.{ .insert = 0x100000 }, 4, "\xF4\x80\x80\x80");
    try expectKey(.{ .insert = 0x0FFF }, 3, "\xE0\xBF\xBF");
    try expectKey(.{ .insert = 0x3FFFF }, 4, "\xF0\xBF\xBF\xBF");
}

test "an unterminated CSI does not grow without bound" {
    var buf: [max_csi_len + 8]u8 = undefined;
    @memset(&buf, '1');
    buf[0] = esc;
    buf[1] = '[';
    // 上限の手前までは、続きを待つ。
    try expectNeedMore(buf[0 .. max_csi_len - 1]);
    // 上限に達したら、見えているぶんをすべて捨てる。
    try expectInvalid(max_csi_len, buf[0..max_csi_len]);
    try expectInvalid(max_csi_len, buf[0 .. max_csi_len + 5]);
    // 上限のちょうど最後のバイトが終端なら、解読できる。
    buf[max_csi_len - 1] = '~';
    try testing.expect(decode(buf[0..max_csi_len]) == .key);
}

test "decode always makes progress, on every byte string of length 1 to 3" {
    var buf: [3]u8 = undefined;
    // 先頭に ESC と代表的なバイトを置いて、全探索に近い形で確かめる。
    const alphabet = [_]u8{ 0x00, 0x09, 0x1B, 0x20, '1', ';', '~', '[', 'A', 'O', 'a', 0x7E, 0x7F, 0x80, 0xBF, 0xC2, 0xC3, 0xE0, 0xE3, 0xED, 0xF0, 0xF4, 0xFF };
    for (alphabet) |a| {
        buf[0] = a;
        try checkProgress(buf[0..1]);
        for (alphabet) |b| {
            buf[1] = b;
            try checkProgress(buf[0..2]);
            for (alphabet) |c| {
                buf[2] = c;
                try checkProgress(buf[0..3]);
            }
        }
    }
}

test "decode always makes progress on random bytes" {
    var prng: std.Random.DefaultPrng = .init(0x7a);
    const random = prng.random();
    var buf: [48]u8 = undefined;
    for (0..4000) |_| {
        const n = random.intRangeAtMost(usize, 1, buf.len);
        random.bytes(buf[0..n]);
        // ESC と CSI の列を多く混ぜる。
        if (random.boolean()) buf[0] = esc;
        if (n > 1 and random.boolean()) buf[1] = '[';
        try checkProgress(buf[0..n]);
    }
}

fn checkProgress(bytes: []const u8) !void {
    switch (decode(bytes)) {
        .key => |k| {
            try testing.expect(k.consumed >= 1 and k.consumed <= bytes.len);
            // 返した文字は、UTF-8 として符号化できる範囲にある。
            switch (k.key) {
                .insert, .alt => |cp| {
                    var tmp: [4]u8 = undefined;
                    _ = std.unicode.utf8Encode(cp, &tmp) catch return error.TestUnexpectedResult;
                },
                else => {},
            }
        },
        .invalid => |n| try testing.expect(n >= 1 and n <= bytes.len),
        .need_more => {},
    }
}
