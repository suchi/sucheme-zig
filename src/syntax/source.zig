//! Reads the text of a source file and the data in it, for the files that a library
//! is defined in and that an `include` names.
//!
//! ファイルの中身を読む経路は、ここ1か所に閉じる。ファイルを丸ごとメモリに読むので、大きさに
//! 上限を置き、UTF-8 として不正なものは拒否する。データはヒープに作られ、GC のルートには
//! まだ載っていない。読み手は、GC が走りうる点の前に、ルートに載せる。

const std = @import("std");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const context = @import("../context.zig");
const Context = context.Context;
const reader = @import("../reader.zig");
const resolve = @import("../resolve.zig");

pub const Error = context.Error;

/// The most bytes of a source file.
/// Why: ファイルを丸ごとメモリに読むので、探索ルートの下にある巨大なファイルや、無限に読める
/// ファイルで、ホストのメモリを使い切らないための上限である。リーダの作業領域は、ヒープの
/// 上限に計上されない。閉じていない `(` だけが続くファイルを、ライブラリのファイルとして
/// 読むと、実測で、ファイルの大きさの約 110 倍(1 MiB で約 127 MiB)の最大 RSS になった。
/// `include` は、データから節点を作るので、同じ大きさのファイルで、これより多い(実測で
/// 70 から 249 MiB)。節点と展開の作業領域は、`include` が読む時点から、ヒープの上限に数える。
/// 計上の外に残る分は、ADR-0031 の 2026-10-15 の追記が受け入れた制約として記録している。
pub const max_file_bytes = 1024 * 1024;

/// The most files that are being read at once: the files of libraries that import one
/// another, and the files that include one another.
pub const max_open_files = 64;

/// The text of `source`, which the caller frees with the allocator of the heap.
/// `subject` は、エラーの文面の「cannot ...」に続く、していたことである。
/// 埋め込みのファイルは、ビルド時に検証してあるが、実ファイルと同じ上限と検査を通す。
pub fn readText(ctx: *Context, files: ?resolve.Files, source: resolve.Source, subject: []const u8) Error![]u8 {
    switch (source) {
        .bytes => |bytes| {
            if (bytes.len > max_file_bytes) return ctx.raise("cannot {s}: its file is larger than {d} bytes", .{ subject, max_file_bytes });
            if (!std.unicode.utf8ValidateSlice(bytes)) return ctx.raise("cannot {s}: its file is not valid UTF-8", .{subject});
            return ctx.heap.backing.dupe(u8, bytes);
        },
        .file => |file| return readFileText(ctx, files.?, file, subject),
    }
}

/// The text of `file`, which the caller frees with the allocator of the heap.
fn readFileText(ctx: *Context, files: resolve.Files, file: std.Io.File, subject: []const u8) Error![]u8 {
    var buffer: [4096]u8 = undefined;
    var file_reader: std.Io.File.Reader = .init(file, files.io, &buffer);
    const source = file_reader.interface.allocRemaining(ctx.heap.backing, .limited(max_file_bytes)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return ctx.raise("cannot {s}: its file is larger than {d} bytes", .{ subject, max_file_bytes }),
        error.ReadFailed => return ctx.raise("cannot {s}: its file could not be read", .{subject}),
    };
    errdefer ctx.heap.backing.free(source);
    if (!std.unicode.utf8ValidateSlice(source)) return ctx.raise("cannot {s}: its file is not valid UTF-8", .{subject});
    return source;
}

/// The sink the reader makes the data of a file in.
pub fn sink(ctx: *Context) reader.Sink {
    return .{ .heap = &ctx.heap };
}

/// The sink the reader makes the data of the file `origin` names in, keeping the
/// positions of its lists in `ctx.positions` when there is a table.
pub fn sinkFrom(ctx: *Context, scratch: std.mem.Allocator, origin: resolve.Origin) Error!reader.Sink {
    var to = sink(ctx);
    if (ctx.positions) |table| to.positions = .{ .table = table, .file = try table.addFile(try displayName(scratch, origin)) };
    return to;
}

/// The next datum of the file `r` reads, or null at its end.
pub fn readDatum(ctx: *Context, r: *reader.Reader, scratch: std.mem.Allocator, subject: []const u8) Error!?Value {
    return readDatumTo(ctx, r, scratch, sink(ctx), subject);
}

/// The next datum of the file `r` reads into `to`, or null at its end.
pub fn readDatumTo(ctx: *Context, r: *reader.Reader, scratch: std.mem.Allocator, to: reader.Sink, subject: []const u8) Error!?Value {
    return r.next(scratch, to) catch |e| switch (e) {
        error.OutOfMemory, error.HeapLimit => |heap_error| ctx.heapFailure(heap_error),
        else => |syntax| ctx.raise("cannot {s}: {s}", .{ subject, reader.describe(syntax) }),
    };
}

/// Every datum of `source`, in order, and its file closed.
/// ファイルの内容は、データを読み終えた時点で手放す。データは内容を指さない。
/// `fold_case` が真なら、リーダは識別子と文字名を畳み込む(`include-ci`)。
pub fn readData(ctx: *Context, scratch: std.mem.Allocator, files: ?resolve.Files, source: resolve.Source, subject: []const u8, fold_case: bool) Error![]const Value {
    return readDataFrom(ctx, scratch, files, source, null, subject, fold_case);
}

/// Every datum of `source`, as `readData` reads them, with the positions of their
/// lists kept in `ctx.positions` when `origin` names the file and there is a table.
pub fn readDataFrom(ctx: *Context, scratch: std.mem.Allocator, files: ?resolve.Files, source: resolve.Source, origin: ?resolve.Origin, subject: []const u8, fold_case: bool) Error![]const Value {
    defer closeSource(files, source);
    const text = try readText(ctx, files, source, subject);
    defer ctx.heap.backing.free(text);
    var r: reader.Reader = .init(text);
    r.fold_case = fold_case;
    const to = if (origin) |o| try sinkFrom(ctx, scratch, o) else sink(ctx);
    var data: std.ArrayList(Value) = .empty;
    while (try readDatumTo(ctx, &r, scratch, to, subject)) |datum| try data.append(scratch, datum);
    return data.items;
}

/// The name of the file `origin` names, as the messages of errors show it: the
/// components of its path after its root, unless the root is the working directory.
/// 埋め込みのファイルの根は `<embedded>` である。
fn displayName(scratch: std.mem.Allocator, origin: resolve.Origin) error{OutOfMemory}![]const u8 {
    var name: std.ArrayList(u8) = .empty;
    // ルートの末尾の `/`(`-I lib/`)は落とし、区切りを1つにする。
    const root = std.mem.trimEnd(u8, origin.root, "/");
    if (!std.mem.eql(u8, root, ".")) {
        try name.appendSlice(scratch, root);
        try name.append(scratch, '/');
    }
    for (origin.path, 0..) |component, i| {
        if (i != 0) try name.append(scratch, '/');
        try name.appendSlice(scratch, component);
    }
    return name.items;
}

/// Closes the file of `source`, if it has one.
pub fn closeSource(files: ?resolve.Files, source: resolve.Source) void {
    switch (source) {
        .file => |file| file.close(files.?.io),
        .bytes => {},
    }
}

/// What a file a name means is opened as: the source, and where it came from.
pub const Included = struct { source: resolve.Source, origin: resolve.Origin };

/// Where the file that is being read came from, which a file name of an `include`
/// is relative to: the innermost file being read, or the working directory at the
/// REPL, whose first root it is.
pub fn currentOrigin(ctx: *const Context, files: ?resolve.Files) resolve.Origin {
    if (ctx.sources.items.len > 0) return ctx.sources.items[ctx.sources.items.len - 1];
    const roots = if (files) |f| f.roots else &[_][]const u8{};
    return .{ .root = if (roots.len > 0) roots[0] else ".", .path = &.{} };
}

/// Opens the file that `name`, a file name an `include` gives, means, and checks
/// that it is not a file that is being read already.
/// `what` は、`include` と `include-ci` と `include-library-declarations` のいずれかである。
pub fn openIncluded(ctx: *Context, scratch: std.mem.Allocator, name: []const u8, what: []const u8) Error!Included {
    const base = currentOrigin(ctx, ctx.files);
    // 実ファイルを読むには、ファイルを開く手段が要る。埋め込みのファイルの中の `include` は、
    // 手段が無くても(WASM)、同じ埋め込みの中から引ける。
    if (ctx.files == null and !resolve.isEmbeddedRoot(base.root))
        return ctx.raise("bad {s}: this interpreter has no files to read: {s}", .{ what, name });
    const path = resolve.includePath(scratch, base.directory(), name) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |refused| return ctx.raise("bad {s}: {s}: {s}", .{ what, name, resolve.describeIncludeNameError(refused) }),
    };
    const origin: resolve.Origin = .{ .root = base.root, .path = path };
    for (ctx.sources.items) |reading| {
        if (reading.same(origin)) return ctx.raise("bad {s}: {s} includes itself, directly or through other files", .{ what, name });
    }
    if (ctx.sources.items.len >= max_open_files)
        return ctx.raise("implementation restriction: files include one another more than {d} deep, at {s}", .{ max_open_files, name });
    const source = resolve.openIncluded(ctx.files, ctx.embedded, base.root, path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotFound => return ctx.raise("bad {s}: {s}: no such file", .{ what, name }),
        error.LinkRefused => return ctx.raise("bad {s}: {s}: the file, or a directory on the way to it, is a link", .{ what, name }),
        error.NotRegularFile => return ctx.raise("bad {s}: {s}: not a regular file", .{ what, name }),
        error.Unreadable => return ctx.raise("bad {s}: {s}: the system refused to open the file", .{ what, name }),
    };
    return .{ .source = source, .origin = origin };
}

test {
    std.testing.refAllDecls(@This());
}

test "the name of a file for a message is its root and its path, without the working directory" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { root: []const u8, name: []const u8 }{
        .{ .root = ".", .name = "sub/x.scm" },
        .{ .root = "lib", .name = "lib/sub/x.scm" },
        .{ .root = "lib/", .name = "lib/sub/x.scm" },
        .{ .root = "/abs//", .name = "/abs/sub/x.scm" },
        .{ .root = resolve.embedded_root, .name = "<embedded>/sub/x.scm" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c.name, try displayName(a, .{ .root = c.root, .path = &.{ "sub", "x.scm" } }));
}
