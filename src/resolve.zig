//! Opens the source files that a program names (docs/design/frontend.md, the
//! search and the paths a name maps to).
//!
//! 処理系がソースとして読むファイルを開く経路は、ここ1か所に閉じる。ライブラリ名から
//! パスを組み立て、探索ルートの配下にあることを確かめ、リンクを辿らずに開く。名前は外部
//! 入力である(縦棒で囲んだ識別子は、任意の文字を含みうる)ので、検証を通らない名前は
//! ファイルに対応付けない。ライブラリ名の経路と、`include` の文字列のファイル名の経路を
//! 持つ。どちらも、実行ファイルに埋め込んだファイル(`Embedded`)を先に引き、なければ
//! 探索ルートの実ファイルを引く。WASM は埋め込みだけを引く。

const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("symbol.zig");
const Value = @import("value.zig").Value;
const Direction = @import("value.zig").Port.Direction;
const Dir = std.Io.Dir;
const File = std.Io.File;

/// What the interpreter may open files with: the means of input and output, and
/// the directories to search.
/// 探索ルートの相対パスは、プロセスの作業ディレクトリを基準にする。WASM は実ファイル
/// システムを持たないので、これを渡さない(`Context.files` が空になる)。
pub const Files = struct {
    io: std.Io,
    /// The directories that are searched, in order. The first has the file wins.
    roots: []const []const u8,
};

/// What follows the last component of a library name in the name of its file.
pub const library_extension = ".sld";

/// Why a library name does not name a file.
pub const NameError = error{
    /// The name has no components.
    NoComponents,
    /// A component is neither an identifier nor a non-negative integer.
    NotAComponent,
    /// A component has no characters.
    EmptyComponent,
    /// A component has a character other than `A-Z` `a-z` `0-9` `-` `_` `.`.
    BadCharacter,
    /// A component starts or ends with a dot.
    DotAtEdge,
    /// A component names a device on Windows.
    ReservedDeviceName,
};

/// Why a file that a name maps to could not be opened.
pub const OpenError = error{
    /// No root has it.
    NotFound,
    /// A link, or on Windows a reparse point, is in the way.
    LinkRefused,
    /// What is there is neither a directory nor a file where one is needed.
    NotRegularFile,
    /// The system refused to open it.
    Unreadable,
    OutOfMemory,
};

/// The text of what `e` says about a name, for an error message.
pub fn describeNameError(e: NameError) []const u8 {
    return switch (e) {
        error.NoComponents => "the name has no components",
        error.NotAComponent => "a component is neither an identifier nor a non-negative integer",
        error.EmptyComponent => "a component is empty",
        error.BadCharacter => "a component has a character other than A-Z a-z 0-9 - _ .",
        error.DotAtEdge => "a component starts or ends with a dot",
        error.ReservedDeviceName => "a component is the name of a device",
    };
}

/// Checks that `text`, a component of a library name, can be a part of a path.
/// Why: 許可する文字集合は、R7RS 5.6.1 が「ライブラリ名の識別子に含めるのが望ましくない」
/// と挙げる文字(`/` `\` `:` `+` `*` など)を含まない。`.` で始まる成分は `.` と `..` を
/// 排除し、`.` で終わる成分は、末尾の `.` を取り除いて解決する Windows で別の名前に当たる
/// のを防ぐ。デバイス名の判定は、ビルド対象の OS によらず常に行う。
pub fn checkComponent(text: []const u8) NameError!void {
    if (text.len == 0) return error.EmptyComponent;
    for (text) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return error.BadCharacter;
    }
    if (text[0] == '.' or text[text.len - 1] == '.') return error.DotAtEdge;
    if (isDeviceName(text)) return error.ReservedDeviceName;
}

/// Whether the part of `text` before its first dot is the name of a device on
/// Windows, in any case: `CON` `PRN` `AUX` `NUL` `COM1`..`COM9` `LPT1`..`LPT9`.
/// 拡張子を付けても、デバイスまたはその別名に解決されうる。
fn isDeviceName(text: []const u8) bool {
    const stem = text[0 .. std.mem.indexOfScalar(u8, text, '.') orelse text.len];
    for ([_][]const u8{ "con", "prn", "aux", "nul" }) |device| {
        if (std.ascii.eqlIgnoreCase(stem, device)) return true;
    }
    if (stem.len == 4 and stem[3] >= '1' and stem[3] <= '9') {
        for ([_][]const u8{ "com", "lpt" }) |device| {
            if (std.ascii.eqlIgnoreCase(stem[0..3], device)) return true;
        }
    }
    return false;
}

/// The components of the library name `name`, as the text of path parts: the
/// names of identifiers, and non-negative integers in decimal.
/// 検査はここで済ませる。通らない名前は、ファイルに対応付けない。
pub fn libraryParts(scratch: std.mem.Allocator, symbols: *const symbol.Table, name: Value) (NameError || error{OutOfMemory})![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var rest = name;
    while (rest.asPair()) |p| : (rest = p.cdr) {
        const text = if (p.car.asSymbol()) |id|
            symbols.nameOf(id)
        else if (p.car.asFixnum()) |n|
            (if (n >= 0) try std.fmt.allocPrint(scratch, "{d}", .{n}) else return error.NotAComponent)
        else
            return error.NotAComponent;
        try checkComponent(text);
        try parts.append(scratch, text);
    }
    if (rest.kind() != .empty_list) return error.NotAComponent;
    if (parts.items.len == 0) return error.NoComponents;
    return parts.items;
}

/// Where a file that is being read came from: the root that has it, and its path
/// beneath the root.
/// `include` は、含むファイルのディレクトリを基準にし、同じルートの配下を引く。
pub const Origin = struct {
    root: []const u8,
    /// The components of the path of the file, the last being the file itself.
    path: []const []const u8,

    /// The components of the path of the directory the file is in.
    pub fn directory(self: Origin) []const []const u8 {
        return if (self.path.len == 0) self.path else self.path[0 .. self.path.len - 1];
    }

    /// Whether `a` and `b` are the same file: the same root and the same path.
    pub fn same(a: Origin, b: Origin) bool {
        if (!std.mem.eql(u8, a.root, b.root) or a.path.len != b.path.len) return false;
        for (a.path, b.path) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }
};

/// One source file that the executable carries.
/// `build.zig` が `lib/` の下を走査して作る。
pub const EmbeddedFile = struct {
    /// The path beneath `lib/`, with `/` between the components.
    path: []const u8,
    data: []const u8,
};

/// The source files the executable carries (docs/design/frontend.md, 埋め込み).
/// ネイティブも WASM も同じものを持つ。WASM は、これだけを引く。
pub const Embedded = struct {
    files: []const EmbeddedFile,

    /// The data of the file at `path`, the components beneath the root, or null.
    pub fn find(self: Embedded, path: []const []const u8) ?[]const u8 {
        for (self.files) |f| {
            if (pathIs(f.path, path)) return f.data;
        }
        return null;
    }
};

/// Whether `joined`, a path with `/` between its components, is the path whose
/// components are `parts`.
fn pathIs(joined: []const u8, parts: []const []const u8) bool {
    var rest = joined;
    for (parts, 0..) |part, i| {
        if (!std.mem.startsWith(u8, rest, part)) return false;
        rest = rest[part.len..];
        if (i + 1 == parts.len) break;
        if (rest.len == 0 or rest[0] != '/') return false;
        rest = rest[1..];
    }
    return rest.len == 0 and parts.len > 0;
}

/// The root of a file that is one of the embedded ones.
/// Why: 埋め込みのファイルの `include` は、同じ埋め込みの中から引く。実ファイルの
/// ルートと区別するため、文字列の中身ではなく、この定数の同一性で見分ける(利用者が
/// `-I` で同じ綴りのディレクトリを渡しても、実ファイルとして扱う)。
pub const embedded_root: []const u8 = "<embedded>";

/// Whether `root` is `embedded_root` itself.
pub fn isEmbeddedRoot(root: []const u8) bool {
    return root.ptr == embedded_root.ptr and root.len == embedded_root.len;
}

/// What a source file is read from: a file that is open, or the bytes of an
/// embedded one.
pub const Source = union(enum) {
    file: File,
    bytes: []const u8,
};

/// A source that is open, and where it came from.
pub const Opened = struct { source: Source, origin: Origin };

/// Opens the file of the library named `name`: `foo/bar.sld` for `(foo bar)`.
/// The embedded files come first, and then the first root that has it. The caller
/// closes the file of a `Source.file`.
/// Why: 戻り値をパスの文字列にしない。確かめたあとに対象が差し替わる余地を残さない
/// ためである。ルートのハンドルから成分を1つずつ、リンクを辿らずに開き、開いたハンドルの
/// 種別を確かめる(docs/design/zig-api-notes.md)。`resolve_beneath` は Linux で効かない。
/// 埋め込みを先に引くのは、標準ライブラリを、作業ディレクトリのファイルが差し替えられない
/// ようにするためである(docs/design/frontend.md)。
pub fn openLibrary(files: ?Files, embedded: ?Embedded, scratch: std.mem.Allocator, symbols: *const symbol.Table, name: Value) (NameError || OpenError)!Opened {
    const parts = try libraryParts(scratch, symbols, name);
    const directories = parts[0 .. parts.len - 1];
    const file_name = try std.mem.concat(scratch, u8, &.{ parts[parts.len - 1], library_extension });
    const path = try scratch.alloc([]const u8, parts.len);
    @memcpy(path[0..directories.len], directories);
    path[directories.len] = file_name;
    if (embedded) |e| {
        if (e.find(path)) |data|
            return .{ .source = .{ .bytes = data }, .origin = .{ .root = embedded_root, .path = path } };
    }
    const real = files orelse return error.NotFound;
    // Why: WASM(`freestanding`)は実ファイルシステムを持たない。`Dir.cwd()` はその
    // ターゲットではコンパイルできないので、ここで打ち切り、以降を解析させない。
    if (comptime builtin.os.tag == .freestanding) return error.NotFound;
    for (real.roots) |root| {
        if (try openBeneath(real.io, root, directories, file_name)) |file|
            return .{ .source = .{ .file = file }, .origin = .{ .root = root, .path = path } };
    }
    return error.NotFound;
}

/// Why a file name that an `include` gives does not name a file.
pub const IncludeNameError = error{
    /// The name has no characters.
    EmptyName,
    /// The name starts with a slash.
    AbsolutePath,
    /// A component has a character that a path cannot hold on every system.
    BadCharacter,
    /// A component ends with a dot or a space.
    EndsWithDotOrSpace,
    /// A component names a device on Windows.
    ReservedDeviceName,
    /// The path goes up out of the root.
    EscapesRoot,
    /// The path names a directory, or nothing.
    NamesNoFile,
    OutOfMemory,
};

/// The text of what `e` says about a file name, for an error message.
pub fn describeIncludeNameError(e: IncludeNameError) []const u8 {
    return switch (e) {
        error.EmptyName => "the file name is empty",
        error.AbsolutePath => "the file name must not be an absolute path",
        error.BadCharacter => "a component of the file name has a character that is not allowed",
        error.EndsWithDotOrSpace => "a component of the file name ends with a dot or a space",
        error.ReservedDeviceName => "a component of the file name is the name of a device",
        error.EscapesRoot => "the file name goes up out of the directory the files are searched in",
        error.NamesNoFile => "the file name names a directory, not a file",
        error.OutOfMemory => "out of memory",
    };
}

/// The path of the file that `name`, a file name an `include` gives, means when it
/// is read from a file in `directory`: the components beneath the root, the last
/// being the file.
/// Why: 名前は `/` で区切り、`.` と `..` を字句的に解決する。`..` でルートの外に出る名前は
/// 拒否する(docs/design/frontend.md)。リンクは辿らないので、字句的な解決が実ファイルの
/// 解決と食い違うことはない。絶対パスと、システムによって意味が変わる文字は拒否する。
pub fn includePath(scratch: std.mem.Allocator, directory: []const []const u8, name: []const u8) IncludeNameError![]const []const u8 {
    if (name.len == 0) return error.EmptyName;
    if (name[0] == '/') return error.AbsolutePath;
    var path: std.ArrayList([]const u8) = .empty;
    try path.appendSlice(scratch, directory);
    var names_directory = false;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |component| {
        names_directory = true;
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (path.items.len == 0) return error.EscapesRoot;
            path.items.len -= 1;
            continue;
        }
        try checkFileComponent(component);
        try path.append(scratch, component);
        names_directory = false;
    }
    if (names_directory or path.items.len == 0) return error.NamesNoFile;
    return path.items;
}

/// Checks that `text`, a component of the file name an `include` gives, can be a
/// part of a path on every system.
fn checkFileComponent(text: []const u8) IncludeNameError!void {
    for (text) |c| {
        if (c < 0x20 or c == 0x7f or std.mem.indexOfScalar(u8, "\\:*?\"<>|", c) != null) return error.BadCharacter;
    }
    if (text[text.len - 1] == '.' or text[text.len - 1] == ' ') return error.EndsWithDotOrSpace;
    if (isDeviceName(text)) return error.ReservedDeviceName;
}

/// Opens the file at `path` beneath `root`, where `path` is what `includePath`
/// returned. The caller closes the file of a `Source.file`.
/// `root` が埋め込みのルートなら、埋め込みのファイルから引く。
pub fn openIncluded(files: ?Files, embedded: ?Embedded, root: []const u8, path: []const []const u8) OpenError!Source {
    if (isEmbeddedRoot(root)) {
        const e = embedded orelse return error.NotFound;
        return .{ .bytes = e.find(path) orelse return error.NotFound };
    }
    if (comptime builtin.os.tag == .freestanding) return error.NotFound;
    const real = files orelse return error.NotFound;
    const file = (try openBeneath(real.io, root, path[0 .. path.len - 1], path[path.len - 1])) orelse return error.NotFound;
    return .{ .file = file };
}

/// The file `file_name` in the directories `directories` beneath `root`, or null
/// when `root` does not have it.
/// 開けない根は、何も持たないものとして読み飛ばす。ルートの指定は利用者のもので、
/// リンクを禁止する対象ではない(ルート自身がリンクでもよい)。
fn openBeneath(io: std.Io, root: []const u8, directories: []const []const u8, file_name: []const u8) OpenError!?File {
    var current = Dir.cwd().openDir(io, root, .{}) catch return null;
    defer current.close(io);
    for (directories) |name| {
        const next = (try openChildDir(io, current, name)) orelse return null;
        current.close(io);
        current = next;
    }
    return openChildFile(io, current, file_name);
}

/// What `name` in `parent` is, without following a link; null when there is
/// nothing by that name.
fn kindOf(io: std.Io, parent: Dir, name: []const u8) OpenError!?File.Kind {
    const stat = parent.statFile(io, name, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return null,
        else => return error.Unreadable,
    };
    return stat.kind;
}

/// Whether `kind` is what a link, or a reparse point of another kind, is
/// reported as.
fn isLink(kind: File.Kind) bool {
    return kind == .sym_link or kind == .unknown;
}

/// The directory `name` in `parent`, or null when there is none.
fn openChildDir(io: std.Io, parent: Dir, name: []const u8) OpenError!?Dir {
    const kind = (try kindOf(io, parent, name)) orelse return null;
    if (isLink(kind)) return error.LinkRefused;
    if (kind != .directory) return null;
    const child = parent.openDir(io, name, .{ .follow_symlinks = false }) catch |e| switch (e) {
        // 確かめたあとに、リンクに差し替えられた。
        error.NotDir, error.SymLinkLoop => return error.LinkRefused,
        error.FileNotFound => return null,
        else => return error.Unreadable,
    };
    // Windows は、再解析点を辿らず、それ自身を開く。開いたハンドルの種別で拒否する。
    const stat = child.stat(io) catch {
        child.close(io);
        return error.Unreadable;
    };
    if (stat.kind != .directory) {
        child.close(io);
        return if (isLink(stat.kind)) error.LinkRefused else error.NotRegularFile;
    }
    return child;
}

/// The file `name` in `parent`, or null when there is none.
fn openChildFile(io: std.Io, parent: Dir, name: []const u8) OpenError!?File {
    const kind = (try kindOf(io, parent, name)) orelse return null;
    if (isLink(kind)) return error.LinkRefused;
    // Why: 開く前に種別を見るのは、FIFO を開いて書き手を待ち続けないためである。
    if (kind == .directory) return null;
    if (kind != .file) return error.NotRegularFile;
    const file = parent.openFile(io, name, .{ .follow_symlinks = false, .allow_directory = false }) catch |e| switch (e) {
        error.SymLinkLoop => return error.LinkRefused,
        error.FileNotFound, error.IsDir => return null,
        else => return error.Unreadable,
    };
    const stat = file.stat(io) catch {
        file.close(io);
        return error.Unreadable;
    };
    if (stat.kind != .file) {
        file.close(io);
        return if (isLink(stat.kind)) error.LinkRefused else error.NotRegularFile;
    }
    return file;
}

/// Why a file a program names could not be opened (docs/design/frontend.md, the
/// second class of the ways files are opened).
pub const UserFileError = error{
    /// The system has no descriptor left for the process, or for any process.
    /// 記述子が尽きたことは、ほかの失敗と分ける。回収で閉じられるポートがあれば、開き直せる
    /// (docs/plans/0019-phase5-ports-and-io.md の合意を求める点の4)。
    Exhausted,
    /// The system refused for any other reason: the file is not there, is a
    /// directory, cannot be read or written, or its name cannot be a path.
    Refused,
};

/// The file `path`, opened for reading when `direction` is `.input`, or created,
/// or emptied when it is there, for writing otherwise (R7RS 6.13.1).
/// 第2類の入口である。探索ルートの制約をかけず、パスは作業ディレクトリを基準にし、リンクを
/// 辿る(frontend.md)。プログラムが名前を選んだファイルを読み書きするのは、R7RS 6.13.1 と
/// 6.14 が定める手続きの働きそのものだからである。ディレクトリは開かない。
pub fn openUserFile(io: std.Io, path: []const u8, direction: Direction) UserFileError!File {
    const opened = switch (direction) {
        .input => Dir.cwd().openFile(io, path, .{ .allow_directory = false }),
        .output => Dir.cwd().createFile(io, path, .{}),
    };
    return opened catch |e| switch (e) {
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => error.Exhausted,
        else => error.Refused,
    };
}

/// Deletes the file `path` (R7RS 6.14 `delete-file`).
/// ファイルが無いときも、消せないときと同じく断る(R7RS 6.14 は、どちらも `file-error?` が
/// 真になる誤りとする)。
pub fn deleteUserFile(io: std.Io, path: []const u8) error{Refused}!void {
    Dir.cwd().deleteFile(io, path) catch return error.Refused;
}

/// Whether the file `path` is there (R7RS 6.14 `file-exists?`).
/// 調べられないとき(名前がパスにならない、途中のディレクトリを読めないなど)は、無いと答える。
/// R7RS 6.14 は、この手続きの誤りを定めていない(frontend.md)。
pub fn userFileExists(io: std.Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;
const context = @import("context.zig");

/// A part of a library name that a test builds: the reader cannot read every
/// name that this file must refuse, such as `|..|`.
const Part = union(enum) { id: []const u8, int: i64 };

fn buildName(ctx: *context.Context, parts: []const Part) !Value {
    var list: Value = .empty_list_value;
    var i = parts.len;
    while (i > 0) {
        i -= 1;
        const car: Value = switch (parts[i]) {
            .id => |text| .fromSymbol(try ctx.intern(text)),
            .int => |n| .fromFixnum(n),
        };
        list = try ctx.heap.cons(car, list);
    }
    return list;
}

fn expectParts(parts: []const Part, expected: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = try context.Context.init(arena.allocator(), testing.allocator);
    defer ctx.deinit();
    const name = try buildName(&ctx, parts);
    const got = try libraryParts(arena.allocator(), &ctx.heap.symbols, name);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, have| try testing.expectEqualStrings(want, have);
}

fn expectRefused(parts: []const Part, expected: NameError) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = try context.Context.init(arena.allocator(), testing.allocator);
    defer ctx.deinit();
    const name = try buildName(&ctx, parts);
    try testing.expectError(expected, libraryParts(arena.allocator(), &ctx.heap.symbols, name));
}

test "a name of identifiers and integers is the parts of a path" {
    try expectParts(&.{ .{ .id = "foo" }, .{ .id = "bar" } }, &.{ "foo", "bar" });
    try expectParts(&.{.{ .id = "foo" }}, &.{"foo"});
    try expectParts(&.{ .{ .id = "srfi" }, .{ .int = 1 } }, &.{ "srfi", "1" });
    try expectParts(&.{ .{ .id = "v" }, .{ .int = 0 }, .{ .int = 120 } }, &.{ "v", "0", "120" });
    // 許可する文字は、すべて通る。大文字と小文字は区別する。
    try expectParts(&.{ .{ .id = "Foo-bar_2.x" }, .{ .id = "a..b" } }, &.{ "Foo-bar_2.x", "a..b" });
}

test "a component that could leave the root or name something else is refused" {
    // 親へ出る成分と、現在のディレクトリ。
    try expectRefused(&.{ .{ .id = ".." }, .{ .id = "passwd" } }, error.DotAtEdge);
    try expectRefused(&.{ .{ .id = "foo" }, .{ .id = ".." } }, error.DotAtEdge);
    try expectRefused(&.{ .{ .id = "." }, .{ .id = "foo" } }, error.DotAtEdge);
    // `.` で始まる成分と、`.` で終わる成分。
    try expectRefused(&.{.{ .id = ".hidden" }}, error.DotAtEdge);
    try expectRefused(&.{ .{ .id = "foo" }, .{ .id = "bar." } }, error.DotAtEdge);
    // 区切りを含む成分。縦棒で囲んだ識別子は、どんな文字でも含みうる。
    try expectRefused(&.{.{ .id = "../../etc" }}, error.BadCharacter);
    try expectRefused(&.{.{ .id = "a/b" }}, error.BadCharacter);
    try expectRefused(&.{.{ .id = "a\\b" }}, error.BadCharacter);
    try expectRefused(&.{.{ .id = "/etc" }}, error.BadCharacter);
    try expectRefused(&.{.{ .id = "c:" }}, error.BadCharacter);
    try expectRefused(&.{.{ .id = "a b" }}, error.BadCharacter);
    try expectRefused(&.{.{ .id = "a+b" }}, error.BadCharacter);
    try expectRefused(&.{.{ .id = "a\x00b" }}, error.BadCharacter);
    try expectRefused(&.{.{ .id = "café" }}, error.BadCharacter);
    // 空の成分は、パスの結合で取り除かれ、別の名前と同じファイルを指す。
    try expectRefused(&.{ .{ .id = "" }, .{ .id = "base" } }, error.EmptyComponent);
    try expectRefused(&.{ .{ .id = "foo" }, .{ .id = "" } }, error.EmptyComponent);
    // 成分が1つもない名前は、ルート自身を指す。
    try expectRefused(&.{}, error.NoComponents);
    // 負の整数は、名前の成分ではない。
    try expectRefused(&.{ .{ .id = "foo" }, .{ .int = -1 } }, error.NotAComponent);
}

test "the name of a device is refused in any case, with an extension or without" {
    for ([_][]const u8{ "CON", "con", "Con", "PRN", "AUX", "NUL", "nul", "COM1", "com9", "Lpt1", "LPT9", "CON.scm", "con.x.y", "aux.txt", "COM3.sld" }) |name| {
        try expectRefused(&.{.{ .id = name }}, error.ReservedDeviceName);
        try expectRefused(&.{ .{ .id = "foo" }, .{ .id = name } }, error.ReservedDeviceName);
        // どの位置の成分でも拒否する(途中のディレクトリの名前でも)。
        try expectRefused(&.{ .{ .id = name }, .{ .id = "foo" } }, error.ReservedDeviceName);
    }
    // 似ているだけの名前は通る。
    for ([_][]const u8{ "console", "conx", "com", "com0", "com10", "lpt0", "lpt", "auxiliary", "nulls", "pr", "prnx", "xcon", "con-1" }) |name| {
        try expectParts(&.{.{ .id = name }}, &.{name});
    }
    // 整数の成分は、10進の数字だけで、デバイス名にならない。
    try expectParts(&.{.{ .int = 1 }}, &.{"1"});
}

/// A directory tree that the file tests build, and the path of its root.
pub const Tree = struct {
    tmp: testing.TmpDir,
    /// The absolute path of the temporary directory.
    path: [:0]const u8,
    /// `path` as the list of the one root, for `Files`.
    /// 木を動かさない限り、`Files.roots` が指してよい。
    roots: [1][]const u8,

    pub fn init(self: *Tree, allocator: std.mem.Allocator) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.path = try self.tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
        self.roots = .{self.path};
    }

    pub fn deinit(self: *Tree, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.tmp.cleanup();
    }

    pub fn write(self: *Tree, sub_path: []const u8, data: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, Dir.path.dirname(sub_path) orelse ".");
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    /// Makes a link, or skips the test where the system does not let it.
    pub fn link(self: *Tree, target: []const u8, sub_path: []const u8, is_directory: bool) !void {
        try self.tmp.dir.createDirPath(testing.io, Dir.path.dirname(sub_path) orelse ".");
        self.tmp.dir.symLink(testing.io, target, sub_path, .{ .is_directory = is_directory }) catch |e| switch (e) {
            // Windows は、権限が無いとリンクを作れない。
            error.AccessDenied, error.PermissionDenied, error.Unexpected => return error.SkipZigTest,
            else => return e,
        };
    }

    /// The path of `sub_path` in the tree.
    pub fn at(self: *Tree, allocator: std.mem.Allocator, sub_path: []const u8) ![]const u8 {
        return Dir.path.join(allocator, &.{ self.path, sub_path });
    }
};

/// Opens the library `name` (identifiers only) beneath `roots`, and returns what
/// the file holds.
fn readLibrary(allocator: std.mem.Allocator, roots: []const []const u8, names: []const []const u8) ![]u8 {
    var ctx = try context.Context.init(allocator, testing.allocator);
    defer ctx.deinit();
    var parts: std.ArrayList(Part) = .empty;
    for (names) |n| try parts.append(allocator, .{ .id = n });
    const name = try buildName(&ctx, parts.items);
    const opened = try openLibrary(.{ .io = testing.io, .roots = roots }, null, allocator, &ctx.heap.symbols, name);
    const file = opened.source.file;
    defer file.close(testing.io);
    var buf: [256]u8 = undefined;
    var reader: File.Reader = .init(file, testing.io, &buf);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

fn expectOpenFails(roots: []const []const u8, names: []const []const u8, expected: anyerror) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(expected, readLibrary(arena.allocator(), roots, names));
}

test "the library (foo bar) is the file foo/bar.sld beneath a root" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tree: Tree = undefined;
    try tree.init(testing.allocator);
    defer tree.deinit(testing.allocator);
    try tree.write("foo/bar.sld", "(define-library (foo bar))");
    try tree.write("solo.sld", "alone");
    try tree.write("foo/bar/deep.sld", "deep");
    try testing.expectEqualStrings("(define-library (foo bar))", try readLibrary(arena.allocator(), &.{tree.path}, &.{ "foo", "bar" }));
    try testing.expectEqualStrings("alone", try readLibrary(arena.allocator(), &.{tree.path}, &.{"solo"}));
    try testing.expectEqualStrings("deep", try readLibrary(arena.allocator(), &.{tree.path}, &.{ "foo", "bar", "deep" }));
    // 別の名前のファイルは、別の名前のライブラリである。
    try expectOpenFails(&.{tree.path}, &.{ "foo", "baz" }, error.NotFound);
    // Why: 大文字と小文字だけが違う名前は、区別するファイルシステムでは別のファイルだが、区別しない
    // もの(Windows の既定)では同じファイルを開く。後者でファイルの定義が名前と合わないことは、
    // 読み込み側が名前を照合して拒否する(`src/sucheme.zig` のテスト)。
    if (comptime builtin.os.tag == .linux) try expectOpenFails(&.{tree.path}, &.{ "Foo", "bar" }, error.NotFound);
    try expectOpenFails(&.{tree.path}, &.{ "foo", "bar", "deeper" }, error.NotFound);
    // 拡張子が違うファイルは、ライブラリのファイルではない。
    try tree.write("other.scm", "x");
    try expectOpenFails(&.{tree.path}, &.{"other"}, error.NotFound);
}

test "pathIs matches the components, not a prefix of them" {
    try testing.expect(pathIs("foo/bar.sld", &.{ "foo", "bar.sld" }));
    try testing.expect(pathIs("solo.sld", &.{"solo.sld"}));
    try testing.expect(!pathIs("foo/bar.sld", &.{"foo"}));
    try testing.expect(!pathIs("foo/bar.sld", &.{ "foo", "bar" }));
    try testing.expect(!pathIs("foo/bar.sld", &.{ "foo", "bar.sld", "x" }));
    try testing.expect(!pathIs("foobar.sld", &.{ "foo", "bar.sld" }));
    // 成分の間にあるのが `/` でなければ、別のパスである。
    try testing.expect(!pathIs("fooXbar.sld", &.{ "foo", "bar.sld" }));
    try testing.expect(!pathIs("foo/bar.sld", &.{}));
    try testing.expect(!pathIs("", &.{}));
}

test "an embedded library is found before a root, and its includes stay among the embedded files" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = try context.Context.init(allocator, testing.allocator);
    defer ctx.deinit();
    const name = try buildName(&ctx, &.{ .{ .id = "foo" }, .{ .id = "bar" } });
    const embedded: Embedded = .{ .files = &.{
        .{ .path = "foo/bar.sld", .data = "embedded" },
        .{ .path = "foo/helper.scm", .data = "helper" },
    } };
    var tree: Tree = undefined;
    try tree.init(testing.allocator);
    defer tree.deinit(testing.allocator);
    try tree.write("foo/bar.sld", "on disk");
    const files: Files = .{ .io = testing.io, .roots = &.{tree.path} };

    // 埋め込みが先である。実ファイルシステムの同じ名前のファイルは見えない。
    const found = try openLibrary(files, embedded, allocator, &ctx.heap.symbols, name);
    try testing.expectEqualStrings("embedded", found.source.bytes);
    try testing.expect(isEmbeddedRoot(found.origin.root));
    try testing.expectEqualStrings("bar.sld", found.origin.path[1]);
    // ファイルシステムが無くても見つかる(WASM)。
    const without_files = try openLibrary(null, embedded, allocator, &ctx.heap.symbols, name);
    try testing.expectEqualStrings("embedded", without_files.source.bytes);
    // 埋め込みに無い名前は、実ファイルを引く。どちらにも無ければ NotFound である。
    const other = try buildName(&ctx, &.{ .{ .id = "foo" }, .{ .id = "baz" } });
    try testing.expectError(error.NotFound, openLibrary(files, embedded, allocator, &ctx.heap.symbols, other));
    try testing.expectError(error.NotFound, openLibrary(null, null, allocator, &ctx.heap.symbols, name));
    const on_disk = try openLibrary(files, null, allocator, &ctx.heap.symbols, name);
    defer on_disk.source.file.close(testing.io);

    // 埋め込みのルートからの `include` は、埋め込みの中を引く。
    const included = try openIncluded(null, embedded, embedded_root, &.{ "foo", "helper.scm" });
    try testing.expectEqualStrings("helper", included.bytes);
    try testing.expectError(error.NotFound, openIncluded(null, embedded, embedded_root, &.{ "foo", "nope.scm" }));
    try testing.expectError(error.NotFound, openIncluded(files, null, embedded_root, &.{ "foo", "helper.scm" }));
    // 利用者が同じ綴りのルートを渡しても、それは埋め込みのルートではない。
    const copy = try allocator.dupe(u8, embedded_root);
    try testing.expect(!isEmbeddedRoot(copy));
}

test "the roots are searched in order, and a root that cannot be opened has nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tree: Tree = undefined;
    try tree.init(testing.allocator);
    defer tree.deinit(testing.allocator);
    try tree.write("one/a.sld", "first");
    try tree.write("one/b.sld", "only in one");
    try tree.write("two/a.sld", "second");
    try tree.write("two/c.sld", "only in two");
    const one = try tree.at(arena.allocator(), "one");
    const two = try tree.at(arena.allocator(), "two");
    const missing = try tree.at(arena.allocator(), "missing");
    const roots = [_][]const u8{ missing, one, two };
    try testing.expectEqualStrings("first", try readLibrary(arena.allocator(), &roots, &.{"a"}));
    try testing.expectEqualStrings("only in one", try readLibrary(arena.allocator(), &roots, &.{"b"}));
    try testing.expectEqualStrings("only in two", try readLibrary(arena.allocator(), &roots, &.{"c"}));
    try expectOpenFails(&roots, &.{"d"}, error.NotFound);
    // ルートが1つもなければ、何も見つからない。
    try expectOpenFails(&.{}, &.{"a"}, error.NotFound);
    // ルートが指す名前が、ファイルのときも。
    try testing.expectEqualStrings("second", try readLibrary(arena.allocator(), &.{ try tree.at(arena.allocator(), "one/b.sld"), two }, &.{"a"}));
}

test "a link on the way, or at the end, is refused, even when it stays inside the root" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tree: Tree = undefined;
    try tree.init(testing.allocator);
    defer tree.deinit(testing.allocator);
    try tree.write("outside/secret.sld", "SECRET");
    try tree.write("root/real/ok.sld", "ok");
    try tree.write("root/other/inner.sld", "inner");
    const root = try tree.at(arena.allocator(), "root");
    // 対照: リンクでない通常のファイルは通る。
    try testing.expectEqualStrings("ok", try readLibrary(arena.allocator(), &.{root}, &.{ "real", "ok" }));
    // 途中の成分が、ルートの外のディレクトリへのリンク。
    try tree.link("../outside", "root/linkdir", true);
    try expectOpenFails(&.{root}, &.{ "linkdir", "secret" }, error.LinkRefused);
    // 最後の成分が、ルートの外のファイルへのリンク。
    try tree.link("../../outside/secret.sld", "root/real/linkfile.sld", false);
    try expectOpenFails(&.{root}, &.{ "real", "linkfile" }, error.LinkRefused);
    // ルートの中を指すリンクも、辿らない。
    try tree.link("other", "root/alias", true);
    try expectOpenFails(&.{root}, &.{ "alias", "inner" }, error.LinkRefused);
    try tree.link("../other/inner.sld", "root/real/inside.sld", false);
    try expectOpenFails(&.{root}, &.{ "real", "inside" }, error.LinkRefused);
    // 前のルートのリンクは、あとのルートに同じものがあっても、黙って通り過ぎない。
    try tree.write("later/linkdir/secret.sld", "later");
    const later = try tree.at(arena.allocator(), "later");
    try expectOpenFails(&.{ root, later }, &.{ "linkdir", "secret" }, error.LinkRefused);
    // 名前の位置にあるファイルがディレクトリや通常のファイルのときは、見つからないだけである。
    try tree.write("root/plain", "a file where a directory is needed");
    try expectOpenFails(&.{root}, &.{ "plain", "x" }, error.NotFound);
    try tree.write("root/dir.sld/inner", "x");
    try expectOpenFails(&.{root}, &.{"dir"}, error.NotFound);
}

test "a FIFO where the file should be is refused, not opened" {
    // Why: FIFO を開くと、書き手が現れるまで戻らない。開く前の種別の確認が外れると、この
    // テストは失敗でなく止まるので、`ci.yml` の `--test-timeout` が失敗にする。
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tree: Tree = undefined;
    try tree.init(testing.allocator);
    defer tree.deinit(testing.allocator);
    try tree.tmp.dir.createDirPath(testing.io, "fifo");
    const rc = std.os.linux.mknodat(tree.tmp.dir.handle, "fifo/p.sld", std.os.linux.S.IFIFO | 0o600, 0);
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
    try expectOpenFails(&.{tree.path}, &.{ "fifo", "p" }, error.NotRegularFile);
}

test "the root itself may be a link, and a name that is refused opens nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tree: Tree = undefined;
    try tree.init(testing.allocator);
    defer tree.deinit(testing.allocator);
    try tree.write("real/a.sld", "through the root link");
    try tree.link("real", "rootlink", true);
    try testing.expectEqualStrings("through the root link", try readLibrary(arena.allocator(), &.{try tree.at(arena.allocator(), "rootlink")}, &.{"a"}));
    // 検証を通らない名前は、ファイルがあっても開かない。
    try tree.write("real/con.sld", "x");
    try tree.write("real/.hidden.sld", "x");
    try expectOpenFails(&.{try tree.at(arena.allocator(), "real")}, &.{"con"}, error.ReservedDeviceName);
    try expectOpenFails(&.{try tree.at(arena.allocator(), "real")}, &.{".hidden"}, error.DotAtEdge);
    try expectOpenFails(&.{try tree.at(arena.allocator(), "real")}, &.{ "..", "real", "a" }, error.DotAtEdge);
}

fn expectIncludePath(directory: []const []const u8, name: []const u8, expected: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try includePath(arena.allocator(), directory, name);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, have| try testing.expectEqualStrings(want, have);
}

fn expectIncludeRefused(directory: []const []const u8, name: []const u8, expected: IncludeNameError) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(expected, includePath(arena.allocator(), directory, name));
}

test "a file name of an include is read from the directory of the file that includes it" {
    try expectIncludePath(&.{}, "a.scm", &.{"a.scm"});
    try expectIncludePath(&.{ "lib", "sub" }, "a.scm", &.{ "lib", "sub", "a.scm" });
    try expectIncludePath(&.{ "lib", "sub" }, "x/y.scm", &.{ "lib", "sub", "x", "y.scm" });
    // `.` と空の成分は何も変えない。
    try expectIncludePath(&.{"lib"}, "./a//b.scm", &.{ "lib", "a", "b.scm" });
    // `..` は、ルートに着くまで上がれる。
    try expectIncludePath(&.{ "lib", "sub" }, "../a.scm", &.{ "lib", "a.scm" });
    try expectIncludePath(&.{ "lib", "sub" }, "../../a.scm", &.{"a.scm"});
    try expectIncludePath(&.{"lib"}, "x/../a.scm", &.{ "lib", "a.scm" });
    // 空白と非 ASCII は、成分の文字として通る。
    try expectIncludePath(&.{}, "my file.scm", &.{"my file.scm"});
    try expectIncludePath(&.{}, "\u{3042}.scm", &.{"\u{3042}.scm"});
}

test "a file name of an include that is absolute, leaves the root or cannot be a file is refused" {
    try expectIncludeRefused(&.{}, "", error.EmptyName);
    try expectIncludeRefused(&.{ "lib", "sub" }, "/etc/passwd", error.AbsolutePath);
    // ルートの外へ出る。字句的に出てから戻る名前も、出た時点で拒否する。
    try expectIncludeRefused(&.{ "lib", "sub" }, "../../../a.scm", error.EscapesRoot);
    try expectIncludeRefused(&.{}, "../a.scm", error.EscapesRoot);
    try expectIncludeRefused(&.{"lib"}, "../../lib/a.scm", error.EscapesRoot);
    // ディレクトリか、何も指さない名前。
    try expectIncludeRefused(&.{}, "a/", error.NamesNoFile);
    try expectIncludeRefused(&.{}, ".", error.NamesNoFile);
    try expectIncludeRefused(&.{"lib"}, "..", error.NamesNoFile);
    try expectIncludeRefused(&.{}, "a/..", error.NamesNoFile);
    // システムによって意味が変わる文字と、Windows のデバイス名。
    try expectIncludeRefused(&.{}, "a\\b.scm", error.BadCharacter);
    try expectIncludeRefused(&.{}, "c:a.scm", error.BadCharacter);
    try expectIncludeRefused(&.{}, "a\x00b.scm", error.BadCharacter);
    try expectIncludeRefused(&.{}, "a\nb.scm", error.BadCharacter);
    try expectIncludeRefused(&.{}, "a*.scm", error.BadCharacter);
    try expectIncludeRefused(&.{}, "a.", error.EndsWithDotOrSpace);
    try expectIncludeRefused(&.{}, "a ", error.EndsWithDotOrSpace);
    try expectIncludeRefused(&.{}, "x/con.scm", error.ReservedDeviceName);
    try expectIncludeRefused(&.{}, "NUL", error.ReservedDeviceName);
}

test "the origin of a file says where its directory is, and which files are the same" {
    const a: Origin = .{ .root = ".", .path = &.{ "lib", "a.sld" } };
    try testing.expectEqual(1, a.directory().len);
    try testing.expectEqualStrings("lib", a.directory()[0]);
    const repl: Origin = .{ .root = ".", .path = &.{} };
    try testing.expectEqual(0, repl.directory().len);
    try testing.expect(a.same(.{ .root = ".", .path = &.{ "lib", "a.sld" } }));
    try testing.expect(!a.same(.{ .root = "other", .path = &.{ "lib", "a.sld" } }));
    try testing.expect(!a.same(.{ .root = ".", .path = &.{ "lib", "b.sld" } }));
    try testing.expect(!a.same(.{ .root = ".", .path = &.{"a.sld"} }));
}

test "the characters that a file name of an include is refused for are each refused" {
    for ([_][]const u8{ "a\x7fb.scm", "a?b.scm", "a\"b.scm", "a<b.scm", "a>b.scm", "a|b.scm", "a*b.scm", "a:b.scm", "a\\b.scm", "a\tb.scm" }) |name| {
        try expectIncludeRefused(&.{}, name, error.BadCharacter);
    }
    // 通る文字との境目。
    try expectIncludePath(&.{}, "a-b_c.d~e!f.scm", &.{"a-b_c.d~e!f.scm"});
}

test "files with the same name in different directories are not the same file" {
    const a: Origin = .{ .root = ".", .path = &.{ "lib", "x.scm" } };
    try testing.expect(!a.same(.{ .root = ".", .path = &.{ "other", "x.scm" } }));
    try testing.expect(!a.same(.{ .root = ".", .path = &.{ "x.scm", "lib" } }));
}
