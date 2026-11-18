//! The file side of the line editor's history (docs/plans/0021-stage7-8-early-parts.md, 7n).
//!
//! 保存先の決定、読み込み、1項目ずつの追記を持つ。形式(符号化と解析)は `history.zig` の
//! 純粋な部分にあり、ここは入出力だけである。読み書きの失敗は、REPL を止めないため、黙って
//! 無視する(履歴が保存されないだけで、編集は続く)。

const std = @import("std");
const builtin = @import("builtin");
const history = @import("history.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

/// 保存先を指す環境変数。あれば、ホームの下の既定より優先する。
pub const path_variable = "SUCHEME_HISTORY";

/// ホームの下の既定のファイル名。
pub const default_file_name = ".sucheme_history";

/// 読み込む量の上限(バイト)。ファイルは追記だけで縮まないので、これを超える分は、
/// 古い側(先頭)を読まない。
///
/// Why: 履歴の上限(`History.max_items`)で捨てるのは読み込みの後なので、上限を置かないと、
/// 長く使ったファイルの全体を起動のたびに読む。
pub const max_read_bytes: u64 = 256 * 1024;

/// Where the history file is, or null for no file (nothing is saved).
///
/// `SUCHEME_HISTORY` が空でなければそのパス。なければホーム(POSIX は `HOME`、Windows は
/// `USERPROFILE`)の下の `.sucheme_history`。どちらも無い(または空)なら、保存しない。
/// 返したパスは、`gpa` で確保したものを、呼び出し側が解放する。
pub fn resolvePath(gpa: Allocator, variables: ?*const std.process.Environ.Map) Allocator.Error!?[]u8 {
    const map = variables orelse return null;
    if (nonEmpty(map.get(path_variable))) |explicit| return try gpa.dupe(u8, explicit);
    const home_variable = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = nonEmpty(map.get(home_variable)) orelse return null;
    return try Dir.path.join(gpa, &.{ home, default_file_name });
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

/// Reads the file at `path` into `h`. Does nothing when the file cannot be read.
///
/// 上限 `max_read_bytes` を超えるファイルは、末尾の側だけを読み、先頭の切れた行を捨てる。
/// 確保の失敗だけを返す。
pub fn load(gpa: Allocator, io: std.Io, path: []const u8, h: *history.History) Allocator.Error!void {
    const file = Dir.cwd().openFile(io, path, .{ .allow_directory = false }) catch return;
    defer file.close(io);
    const size = file.length(io) catch return;
    const offset = size -| max_read_bytes;
    const buffer = try gpa.alloc(u8, @intCast(size - offset));
    defer gpa.free(buffer);
    const n = file.readPositionalAll(io, buffer, offset) catch return;
    var bytes = buffer[0..n];
    if (offset > 0) {
        // 読み始めが行の途中なら、最初の行は半端なので捨てる。
        bytes = if (std.mem.findScalar(u8, bytes, '\n')) |i| bytes[i + 1 ..] else &.{};
    }
    try h.loadBytes(bytes);
}

/// Appends one entry to the file at `path`, creating it with mode 0600 where the system has modes.
/// Does nothing when the file cannot be written.
///
/// Why: 標準ライブラリに追記モードが無いので、末尾の位置へ1回で書く。同時に動く複数の
/// セッションが、同じ位置へ書くと、片方の行が上書きされうる(既知の制限)。
pub fn append(gpa: Allocator, io: std.Io, path: []const u8, entry: []const u8) void {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    history.encodeEntry(&line.writer, entry) catch return;
    const file = Dir.cwd().createFile(io, path, .{ .truncate = false, .permissions = file_permissions }) catch return;
    defer file.close(io);
    const end = file.length(io) catch return;
    file.writePositionalAll(io, line.written(), end) catch return;
}

/// 新しく作るファイルの権限。履歴には、打った式が入るので、所有者だけが読み書きできるようにする。
const file_permissions: std.Io.File.Permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode"))
    .fromMode(0o600)
else
    .default_file;

// ---- tests ----

const testing = std.testing;

test {
    // 他のファイルを読み込むファイルは、自分の宣言のテストを走らせる(`check-docs` の規則)。
    std.testing.refAllDecls(@This());
}

fn vars(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var m: std.process.Environ.Map = .init(testing.allocator);
    errdefer m.deinit();
    for (pairs) |p| try m.put(p[0], p[1]);
    return m;
}

test "resolvePath prefers SUCHEME_HISTORY, then the file under the home" {
    const home_variable = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    var both = try vars(&.{ .{ "SUCHEME_HISTORY", "/tmp/h" }, .{ home_variable, "/home/u" } });
    defer both.deinit();
    const explicit = (try resolvePath(testing.allocator, &both)).?;
    defer testing.allocator.free(explicit);
    try testing.expectEqualStrings("/tmp/h", explicit);

    var only_home = try vars(&.{.{ home_variable, "/home/u" }});
    defer only_home.deinit();
    const under_home = (try resolvePath(testing.allocator, &only_home)).?;
    defer testing.allocator.free(under_home);
    const expected = try Dir.path.join(testing.allocator, &.{ "/home/u", ".sucheme_history" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, under_home);
}

test "resolvePath returns null when neither the variable nor the home is known" {
    try testing.expectEqual(@as(?[]u8, null), try resolvePath(testing.allocator, null));
    var none = try vars(&.{});
    defer none.deinit();
    try testing.expectEqual(@as(?[]u8, null), try resolvePath(testing.allocator, &none));
    // 空の値は、無いものとして扱う。
    const home_variable = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    var empty = try vars(&.{ .{ "SUCHEME_HISTORY", "" }, .{ home_variable, "" } });
    defer empty.deinit();
    try testing.expectEqual(@as(?[]u8, null), try resolvePath(testing.allocator, &empty));
}

test "resolvePath does not read the other OS's home variable" {
    const other = if (builtin.os.tag == .windows) "HOME" else "USERPROFILE";
    var m = try vars(&.{.{ other, "/home/u" }});
    defer m.deinit();
    try testing.expectEqual(@as(?[]u8, null), try resolvePath(testing.allocator, &m));
}

const Temp = struct {
    tmp: testing.TmpDir,
    path: []u8,

    fn init(file: []const u8) !Temp {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(dir);
        const path = try Dir.path.join(testing.allocator, &.{ dir, file });
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *Temp) void {
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    fn read(self: *Temp, file: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, file, testing.allocator, .limited(1 << 20));
    }
};

test "append creates the file and adds one line per entry, and load reads them back" {
    var t = try Temp.init("h");
    defer t.deinit();
    append(testing.allocator, testing.io, t.path, "(f 1)");
    append(testing.allocator, testing.io, t.path, "(define (g)\n  \"a\\b\")");
    const bytes = try t.read("h");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("(f 1)\n(define (g)\\n  \"a\\\\b\")\n", bytes);

    var h = history.History.init(testing.allocator, 10);
    defer h.deinit();
    try load(testing.allocator, testing.io, t.path, &h);
    try testing.expectEqual(@as(usize, 2), h.len());
    try testing.expectEqualStrings("(f 1)", h.get(0));
    try testing.expectEqualStrings("(define (g)\n  \"a\\b\")", h.get(1));
}

test "append keeps what the file already holds" {
    var t = try Temp.init("h");
    defer t.deinit();
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "h", .data = "old\n" });
    append(testing.allocator, testing.io, t.path, "new");
    const bytes = try t.read("h");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("old\nnew\n", bytes);
}

test "append creates the file readable by the owner only" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var t = try Temp.init("h");
    defer t.deinit();
    append(testing.allocator, testing.io, t.path, "x");
    const st = try t.tmp.dir.statFile(testing.io, "h", .{});
    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(st.permissions.toMode() & 0o077)));
    try testing.expect(st.permissions.toMode() & 0o600 == 0o600);
}

test "load and append ignore a file that cannot be used" {
    var t = try Temp.init("missing/h");
    defer t.deinit();
    var h = history.History.init(testing.allocator, 10);
    defer h.deinit();
    // 無いファイルと、親のディレクトリが無い場所への追記は、何も起こさない。
    try load(testing.allocator, testing.io, t.path, &h);
    append(testing.allocator, testing.io, t.path, "x");
    try testing.expectEqual(@as(usize, 0), h.len());
    // ディレクトリを指していても、止まらない。
    try t.tmp.dir.createDirPath(testing.io, "dir");
    const dir_path = Dir.path.dirname(t.path).?;
    const as_file = try Dir.path.join(testing.allocator, &.{ dir_path, "dir" });
    defer testing.allocator.free(as_file);
    try load(testing.allocator, testing.io, as_file, &h);
    append(testing.allocator, testing.io, as_file, "x");
    try testing.expectEqual(@as(usize, 0), h.len());
}

test "load reads only the tail of a file over the limit, and drops the cut first line" {
    var t = try Temp.init("h");
    defer t.deinit();
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(testing.allocator);
    // 1行 10 バイト("entry-NNNN\n" は 11 バイト)の行を、上限を超えるまで並べる。
    var i: usize = 0;
    while (content.items.len <= max_read_bytes + 100) : (i += 1) {
        try content.print(testing.allocator, "entry-{d:0>4}\n", .{i % 10000});
    }
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "h", .data = content.items });
    var h = history.History.init(testing.allocator, 1_000_000);
    defer h.deinit();
    try load(testing.allocator, testing.io, t.path, &h);
    try testing.expect(h.len() > 0);
    try testing.expect(h.len() < i);
    // 最後の行は残り、先頭の切れた行(`entry-` の途中から始まる)は入らない。
    var last: [16]u8 = undefined;
    const want = try std.fmt.bufPrint(&last, "entry-{d:0>4}", .{(i - 1) % 10000});
    try testing.expectEqualStrings(want, h.get(h.len() - 1));
    for (0..h.len()) |k| try testing.expect(std.mem.startsWith(u8, h.get(k), "entry-"));
}
