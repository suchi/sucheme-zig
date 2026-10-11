//! Extracts the identifiers exported by each standard library from R7RS
//! Appendix A and writes them to tests/r7rs-required/<library>.txt.
//!
//! 既定の動作は比較である。各ファイルを読み、このプログラムが抽出するものと
//! 照らし合わせ、差があれば非ゼロで終了する。`zig build check-extract` がこれを
//! 走らせる。書き込みは `--write` で行う(`zig run
//! tools/extract-r7rs-required/main.zig -- --write` のように)。
//!
//! 比較を既定にしたのは、逆にすると1行で穴が開いたからである。build.zig から
//! `--check` 引数を消すと、検査が書き換えに変わり、比較が失敗しえなくなった。
//! いまは引数を落としても比較のままになる。入力の HTML はコミットしてある
//! (SOURCE.md を参照)。ビルド時には何も取得しないので、ビルドは再現可能で
//! オフラインのままである(ADR-0013)。
//!
//! この比較がなかったころ、生成した一覧を入力に結びつけていたのは、SOURCE.md に
//! 手で貼った SHA-256 だけだった。そのため、一覧を編集して新しいハッシュを貼ると、
//! 検証コマンドがすべて緑のまま、識別子が準拠の分母から黙って消えた。
//!
//! 手で書かず抽出するのは、設計段階で記憶から書いたときに、仕様からの引用の
//! 捏造が1件と、実在しない手続き名が1件出たからである。
//! docs/review/adversarial-review-baseline.md を参照。
//!
//! 付録Aの構造は次のとおりである。各ライブラリの本文は `(scheme X)</span>` として
//! そのライブラリを名指し、これがそのライブラリの節の始まりを示す。エクスポート
//! される識別子は、テキストがノーブレークスペースで始まる等幅の span として
//! 現れる。本文中のインラインコードは同じ span だが先頭にノーブレークスペースが
//! なく、これで両者を区別する。

const std = @import("std");

const html_path = "tools/extract-r7rs-required/appendix-a.html";
const out_dir_path = "tests/r7rs-required";
const source_url = "https://standards.scheme.org/corrected-r7rs/r7rs-Z-H-10.html";

/// The number of standard libraries R7RS appendix A defines.
///
/// 食い違いは、解析がずれたことを意味する。報告するだけでなく検査する。R7RS の
/// 新しい版で集合が変わったら、入力と一緒に更新する。SOURCE.md の再抽出の手順は
/// この定数を名指ししている。
const expected_library_count = 16;

/// Closes the block that holds the export lists.
///
/// 最後のライブラリの範囲の上限に使う。最後のライブラリには、止まる先となる
/// 次のライブラリの印がないからである。
///
/// 文書の冒頭にも同じ印があるが、上限は最後のライブラリの開始位置から探すので、
/// 見つかるのは末尾の印である。この印が消えた場合、上限は文書の末尾に戻る。
/// これは以前の挙動であり、フッタの span が識別子として読まれることは、その
/// ときライブラリごとの検査が捕まえる。
const list_end = "<div class=navigation>";

const lib_marker = "(scheme ";
const id_open = "<span style=\"font-family: monospace\">&#xa0;";

/// Auxiliary syntax that (scheme base) must export.
///
/// 解析がずれると、真っ先に消えるのがこれらの項目である。また
/// docs/design/frontend.md は、これらが存在することを前提に、指示対象(denotation)の
/// 種類を定めている。
const base_must_have = [_][]const u8{ "...", "=>", "_", "else", "unquote", "unquote-splicing" };

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.Writer.initStreaming(.stdout(), io, &buf);
    const out = &stdout.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    var check_only = true;
    for (argv[1..]) |arg| {
        // `--check` は受け付け、既定と同じ意味にする。渡している呼び出し側が
        // そのまま動くようにするためである。
        if (std.mem.eql(u8, arg, "--check")) continue;
        if (std.mem.eql(u8, arg, "--write")) {
            check_only = false;
            continue;
        }
        // 無視せず報告する。綴りを間違えたフラグを無視すると、呼び出し側は、
        // 得られていないものを頼んだつもりになってしまう。
        try out.print("unknown argument {s}\n", .{arg});
        try out.print("usage: extract-r7rs-required [--check | --write]\n", .{});
        try out.flush();
        std.process.exit(2);
    }

    const html = cwd.readFileAlloc(io, html_path, gpa, .unlimited) catch |err| {
        try out.print("cannot read {s}: {t}\n", .{ html_path, err });
        try out.print("run this from the repository root\n", .{});
        try out.flush();
        std.process.exit(1);
    };

    var names: std.ArrayList([]const u8) = .empty;
    var starts: std.ArrayList(usize) = .empty;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, html, scan, lib_marker)) |at| {
        const after = at + lib_marker.len;
        const close = std.mem.indexOfScalarPos(u8, html, after, ')') orelse break;
        const tail = "</span>";
        if (std.mem.startsWith(u8, html[close + 1 ..], tail)) {
            const name = html[after..close];
            // 出力ファイル名は解析した HTML から来る。これは外部入力であり、細工された
            // 名前は出力ディレクトリの外に書き込みかねない。単純なライブラリ名でない
            // ものは拒否する。
            if (!isPlainLibraryName(name)) {
                try out.print("library name {s} is not a plain name\n", .{name});
                try out.flush();
                std.process.exit(1);
            }
            try names.append(gpa, name);
            try starts.append(gpa, at);
        }
        scan = after;
    }

    if (names.items.len != expected_library_count) {
        try out.print("expected {d} libraries, found {d}\n", .{ expected_library_count, names.items.len });
        try out.flush();
        std.process.exit(1);
    }

    var dir = try cwd.createDirPathOpen(io, out_dir_path, .{});
    defer dir.close(io);

    var total: usize = 0;
    var stale = false;
    for (names.items, 0..) |name, i| {
        const from = starts.items[i];
        // 最後のライブラリの範囲も、他と同じように上限を設ける。文書の末尾まで
        // 伸ばすと非対称になった。tex2page が末尾のナビゲーションやフッタに出す
        // 等幅の span が、そのライブラリの識別子として読まれ、ライブラリ数も
        // 補助構文の検査も気づかなかった。
        const to = if (i + 1 < starts.items.len)
            starts.items[i + 1]
        else
            std.mem.indexOfPos(u8, html, from, list_end) orelse html.len;

        var ids: std.ArrayList([]const u8) = .empty;
        var pos = from;
        while (std.mem.indexOfPos(u8, html, pos, id_open)) |at| {
            if (at >= to) break;
            const body_start = at + id_open.len;
            const body_end = std.mem.indexOfScalarPos(u8, html, body_start, '<') orelse break;
            pos = body_end;
            const text = try decode(gpa, html[body_start..body_end]);
            if (text.len != 0) try ids.append(gpa, text);
        }

        for (ids.items) |id| {
            if (std.mem.indexOfAny(u8, id, " \t\r\n") != null) {
                try out.print("{s}: identifier {s} contains whitespace\n", .{ name, id });
                try out.flush();
                std.process.exit(1);
            }
        }

        // 識別子が1つもないライブラリは、最も重大でありながら、誰も見ていなかった
        // 失敗である。R7RS がエクスポート一覧の1つのマークアップを変えても、
        // このプログラムは16ライブラリを報告して成功し、ファイルにはヘッダの
        // コメントしか残らない。準拠の表はこれらのファイルを分母にするので、その
        // ライブラリは、何も実装していないのに完全準拠と読めてしまう。
        if (ids.items.len == 0) {
            try out.print("(scheme {s}) yielded no identifier; the markup of its export list changed\n", .{name});
            try out.flush();
            std.process.exit(1);
        }

        // 重複は、1つの span を2回読んだか、2つの span が同じ名前にデコード
        // されたことを意味する。どちらでも数が間違っており、来歴の文書が
        // 記録しているのは数である。
        for (ids.items, 0..) |id, a| {
            for (ids.items[a + 1 ..]) |other| {
                if (!std.mem.eql(u8, id, other)) continue;
                try out.print("(scheme {s}) lists {s} twice\n", .{ name, id });
                try out.flush();
                std.process.exit(1);
            }
        }

        if (std.mem.eql(u8, name, "base")) {
            for (base_must_have) |want| {
                var found = false;
                for (ids.items) |id| if (std.mem.eql(u8, id, want)) {
                    found = true;
                };
                if (!found) {
                    try out.print("(scheme base) is missing the auxiliary syntax {s}\n", .{want});
                    try out.flush();
                    std.process.exit(1);
                }
            }
        }

        const file_name = try std.fmt.allocPrint(gpa, "{s}.txt", .{name});
        // 先にメモリ上で組み立てる。同じバイト列を書くことも比較することもできる。
        // 書いてからハッシュを取ると、ファイルを自分自身と比較することになる。
        var content: std.ArrayList(u8) = .empty;
        try content.appendSlice(gpa, try std.fmt.allocPrint(
            gpa,
            "; (scheme {s}) の必須識別子。R7RS 付録A から抽出した。\n" ++
                "; 出典: {s}\n" ++
                "; 取得日と許諾: tools/extract-r7rs-required/SOURCE.md\n" ++
                "; 抽出: zig run tools/extract-r7rs-required/main.zig -- --write\n" ++
                "; 手で編集しない。R7RS の版が上がったら再抽出する。\n",
            .{ name, source_url },
        ));
        for (ids.items) |id| {
            try content.appendSlice(gpa, id);
            try content.append(gpa, '\n');
        }

        if (check_only) {
            if (dir.readFileAlloc(io, file_name, gpa, .unlimited)) |existing| {
                if (!std.mem.eql(u8, existing, content.items)) {
                    try out.print("{s}/{s} is not what this program extracts\n", .{ out_dir_path, file_name });
                    stale = true;
                }
            } else |err| {
                try out.print("cannot read {s}/{s}: {t}\n", .{ out_dir_path, file_name, err });
                stale = true;
            }
        } else {
            var file = try dir.createFile(io, file_name, .{});
            defer file.close(io);
            var wbuf: [4096]u8 = undefined;
            var fw = file.writer(io, &wbuf);
            try fw.interface.writeAll(content.items);
            try fw.interface.flush();
        }

        total += ids.items.len;
        try out.print("{s: <18}{d: >4}\n", .{ name, ids.items.len });
    }

    try out.print("\n{d} libraries, {d} identifiers\n", .{ names.items.len, total });
    if (stale) {
        try out.print(
            "\n{s} is not what {s} extracts. Re-run `zig run tools/extract-r7rs-required/main.zig -- --write` and commit the result.\n",
            .{ out_dir_path, html_path },
        );
        try out.flush();
        std.process.exit(1);
    }
    try out.flush();
}

/// Resolves the character references Appendix A uses.
///
/// このページは `<` と `>` を数値参照 `&#x3c;` と `&#x3e;` で書く。名前付きの形
/// しか知らないデコーダは、`=>` と `char<=?` を黙って落とす。
///
/// U+200B は捨てる。tex2page は `?` や `<` の後にゼロ幅スペースを入れるので、
/// 残すと `binary-port?` や `char<?` がライブラリのエクスポート一覧と永久に
/// 一致しなくなる。U+00A0 は普通のスペースにする。後の空白の検査が拒否できる
/// ようにするためである。
///
/// 結果は呼び出し側が所有する。アキュムレータの中を指すトリム済みのスライスを
/// 返すと、呼び出し側が解放できないポインタを渡すことになる。
fn decode(gpa: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            try acc.append(gpa, raw[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse {
            try acc.append(gpa, raw[i]);
            i += 1;
            continue;
        };
        const entity = raw[i + 1 .. semi];
        i = semi + 1;
        if (codePointOf(entity)) |cp| {
            if (cp == 0x200b) continue;
            const scalar = if (cp == 0xa0) ' ' else cp;
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(scalar, &utf8) catch {
                try acc.append(gpa, '?');
                continue;
            };
            try acc.appendSlice(gpa, utf8[0..n]);
        } else {
            // 未知の参照はそのまま残す。空白と補助構文の検査が、黙って受け入れず
            // 気づけるようにするためである。
            try acc.append(gpa, '&');
            try acc.appendSlice(gpa, entity);
            try acc.append(gpa, ';');
        }
    }
    return gpa.dupe(u8, std.mem.trim(u8, acc.items, &std.ascii.whitespace));
}

/// Library names become output file names, so only lowercase letters, digits
/// and internal hyphens are allowed.
///
/// これにより、細工された入力や壊れた入力が、出力ディレクトリの外へ出るパスを
/// 作ることを防ぐ。
fn isPlainLibraryName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    if (name[0] == '-' or name[name.len - 1] == '-') return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Maps an entity body (the text between `&` and `;`) to a code point.
fn codePointOf(entity: []const u8) ?u21 {
    if (entity.len == 0) return null;
    if (entity[0] == '#') {
        const digits = entity[1..];
        if (digits.len == 0) return null;
        if (digits[0] == 'x' or digits[0] == 'X')
            return std.fmt.parseInt(u21, digits[1..], 16) catch null;
        return std.fmt.parseInt(u21, digits, 10) catch null;
    }
    const named = [_]struct { name: []const u8, cp: u21 }{
        .{ .name = "amp", .cp = '&' },
        .{ .name = "lt", .cp = '<' },
        .{ .name = "gt", .cp = '>' },
        .{ .name = "quot", .cp = '"' },
        .{ .name = "nbsp", .cp = 0xa0 },
    };
    for (named) |n| if (std.mem.eql(u8, entity, n.name)) return n.cp;
    return null;
}
// ---------------------------------------------------------------------------
// テスト
//
// 付録Aのマークアップには、識別子を黙って壊す罠が2つあり、出力ファイル名は
// 解析した HTML から来る。以下のテストはその両方を扱う。
// ---------------------------------------------------------------------------

test "decode resolves the numeric references appendix A actually uses" {
    const gpa = std.testing.allocator;
    // このページは < と > を、名前付きの形でなく &#x3c; と &#x3e; で書く。名前付きの
    // 形しか知らないデコーダは、=> と char<=? をまるごと落とした。
    const arrow = try decode(gpa, "=&#x3e;");
    defer gpa.free(arrow);
    try std.testing.expectEqualStrings("=>", arrow);

    const le = try decode(gpa, "char&#x3c;=?");
    defer gpa.free(le);
    try std.testing.expectEqualStrings("char<=?", le);
}

test "decode drops the zero-width spaces tex2page inserts" {
    const gpa = std.testing.allocator;
    // U+200B を残すと、binary-port? がエクスポート一覧と永久に一致せず、
    // いつまでも未実装と読まれる。
    const got = try decode(gpa, "binary-port?&#x200b; &#x200b;");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("binary-port?", got);
}

test "decode keeps an unknown reference verbatim" {
    const gpa = std.testing.allocator;
    // 黙って捨てると、解析の変化が気づかれずに通ってしまう。残せば、空白と
    // 補助構文の検査が気づける。
    const got = try decode(gpa, "a&weird;b");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("a&weird;b", got);
}

test "codePointOf handles hex, decimal and the named forms" {
    try std.testing.expectEqual(@as(?u21, '<'), codePointOf("#x3c"));
    try std.testing.expectEqual(@as(?u21, '<'), codePointOf("#X3C"));
    try std.testing.expectEqual(@as(?u21, 60), codePointOf("#60"));
    try std.testing.expectEqual(@as(?u21, '&'), codePointOf("amp"));
    try std.testing.expectEqual(@as(?u21, 0xa0), codePointOf("nbsp"));
    try std.testing.expectEqual(@as(?u21, null), codePointOf("weird"));
    try std.testing.expectEqual(@as(?u21, null), codePointOf(""));
}

test "isPlainLibraryName rejects anything that could escape the output directory" {
    try std.testing.expect(isPlainLibraryName("base"));
    try std.testing.expect(isPlainLibraryName("case-lambda"));
    try std.testing.expect(isPlainLibraryName("r5rs"));
    // 名前はファイル名になり、解析した HTML から来る。

    try std.testing.expect(!isPlainLibraryName("../etc"));
    try std.testing.expect(!isPlainLibraryName("CHAR"));
    try std.testing.expect(!isPlainLibraryName(""));
    try std.testing.expect(!isPlainLibraryName("-base"));
    try std.testing.expect(!isPlainLibraryName("base-"));
    try std.testing.expect(!isPlainLibraryName("a/b"));
    try std.testing.expect(!isPlainLibraryName("a.b"));
}
