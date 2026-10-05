//! Machine checks over the repository's documentation and build settings.
//!
//! Run as `zig build check-docs`. build.zig passes the names of src/ files
//! that are excluded from the `test` step (see test_excluded there).
//!
//! Every failure is reported before exiting non-zero: stopping at the first
//! one would mean fixing a single finding per run.
//!
//! What is deliberately NOT checked: whether prose declares a pinned Zig
//! version. "Declaration", "reference" and "record of a verification" cannot
//! be told apart by matching digits, and attempts produce both false
//! positives (a documentation URL containing the version) and false
//! negatives (a bare "0.17"). docs/design/zig-api-notes.md keeps that as a
//! human step in the version-bump procedure.

const std = @import("std");

var failures: usize = 0;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const args = try init.minimal.args.toSlice(gpa);
    const excluded = args[1..];

    try checkZigVersionAgreement(gpa, io, cwd);
    try checkTestReachability(gpa, io, cwd, excluded);
    try checkRefAllDecls(gpa, io, cwd);
    try checkMarkdown(gpa, io, cwd);

    var buf: [256]u8 = undefined;
    var out = std.Io.File.Writer.init(.stdout(), io, &buf);
    if (failures == 0) {
        try out.interface.print("check-docs: all checks passed\n", .{});
    } else {
        try out.interface.print("check-docs: {d} problem(s) found\n", .{failures});
    }
    try out.interface.flush();
    if (failures != 0) std.process.exit(1);
}

fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    failures += 1;
    var buf: [1024]u8 = undefined;
    var err = std.Io.File.Writer.init(.stderr(), io, &buf);
    err.interface.print("check-docs: " ++ fmt ++ "\n", args) catch return;
    err.interface.flush() catch return;
}

fn read(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) ?[]u8 {
    return cwd.readFileAlloc(io, path, gpa, .unlimited) catch null;
}

// ---------------------------------------------------------------------------
// 1. The pinned Zig version agrees in all three machine-read places.
// ---------------------------------------------------------------------------

fn checkZigVersionAgreement(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) !void {
    const pinned_raw = read(gpa, io, cwd, ".zigversion") orelse {
        fail(io, ".zigversion is missing", .{});
        return;
    };
    const pinned = std.mem.trim(u8, pinned_raw, &std.ascii.whitespace);

    if (read(gpa, io, cwd, "build.zig.zon")) |manifest| {
        if (valueAfter(manifest, ".minimum_zig_version = \"")) |found| {
            if (!std.mem.eql(u8, found, pinned))
                fail(io, "build.zig.zon minimum_zig_version is {s}, .zigversion is {s}", .{ found, pinned });
        } else fail(io, "build.zig.zon has no minimum_zig_version", .{});
    } else fail(io, "build.zig.zon is missing", .{});

    var workflows = cwd.openDir(io, ".github/workflows", .{ .iterate = true }) catch {
        fail(io, ".github/workflows is missing; the CI copy of the Zig version cannot be checked", .{});
        return;
    };
    defer workflows.close(io);

    var seen: usize = 0;
    var it = workflows.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yml") and !std.mem.endsWith(u8, entry.name, ".yaml")) continue;
        seen += 1;
        const path = try std.fmt.allocPrint(gpa, ".github/workflows/{s}", .{entry.name});
        const body = read(gpa, io, cwd, path) orelse continue;
        if (std.mem.indexOf(u8, body, pinned) == null)
            fail(io, "{s} does not mention the pinned Zig version {s}", .{ path, pinned });
    }
    if (seen == 0) fail(io, ".github/workflows has no workflow file", .{});
}

fn valueAfter(haystack: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, haystack, key) orelse return null;
    const start = at + key.len;
    const end = std.mem.indexOfScalarPos(u8, haystack, start, '"') orelse return null;
    return haystack[start..end];
}

// ---------------------------------------------------------------------------
// 2. Every src/ file is reachable by @import from a module root.
//
// Zig only analyses a file's `test` blocks when the file is reached from the
// test root, so an unreferenced file's tests are silently skipped.
// ---------------------------------------------------------------------------

fn checkTestReachability(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    excluded: []const []const u8,
) !void {
    var files: std.ArrayList([]const u8) = .empty;
    try collectZig(gpa, io, cwd, "src", &files);

    // Roots are the modules build.zig gives to addTest.
    const roots = [_][]const u8{ "src/sucheme.zig", "src/main.zig" };

    var reachable: std.StringHashMapUnmanaged(void) = .empty;
    for (roots) |r| try reachable.put(gpa, r, {});

    // Repeat until nothing new is reached: imports form a DAG of unknown depth.
    var changed = true;
    while (changed) {
        changed = false;
        for (files.items) |path| {
            if (!reachable.contains(path)) continue;
            const body = read(gpa, io, cwd, path) orelse continue;
            const dir = std.fs.path.dirnamePosix(path) orelse "src";
            var rest = body;
            while (std.mem.indexOf(u8, rest, "@import(\"")) |at| {
                rest = rest[at + 9 ..];
                const close = std.mem.indexOfScalar(u8, rest, '"') orelse break;
                const name = rest[0..close];
                rest = rest[close..];
                if (!std.mem.endsWith(u8, name, ".zig")) continue;
                const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
                if (!reachable.contains(joined)) {
                    try reachable.put(gpa, joined, {});
                    changed = true;
                }
            }
        }
    }

    for (files.items) |path| {
        const base = std.fs.path.basenamePosix(path);
        var skip = false;
        for (excluded) |ex| if (std.mem.eql(u8, base, ex)) {
            skip = true;
        };
        if (skip) continue;
        if (!reachable.contains(path))
            fail(io, "{s} is not reached from any test root; its tests would be skipped", .{path});
    }
}

// ---------------------------------------------------------------------------
// 3. Files that import siblings carry refAllDecls.
//
// refAllDecls only descends one level and refAllDeclsRecursive does not exist
// in Zig 0.17.0, so the reference has to be re-established at each level.
// ---------------------------------------------------------------------------

fn checkRefAllDecls(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) !void {
    var files: std.ArrayList([]const u8) = .empty;
    try collectZig(gpa, io, cwd, "src", &files);

    for (files.items) |path| {
        const body = read(gpa, io, cwd, path) orelse continue;
        if (!importsAZigFile(body)) continue;
        if (std.mem.indexOf(u8, body, "refAllDecls(@This())") == null)
            fail(io, "{s} imports other source files but has no refAllDecls(@This()) test", .{path});
    }
}

fn importsAZigFile(body: []const u8) bool {
    var rest = body;
    while (std.mem.indexOf(u8, rest, "@import(\"")) |at| {
        rest = rest[at + 9 ..];
        const close = std.mem.indexOfScalar(u8, rest, '"') orelse return false;
        if (std.mem.endsWith(u8, rest[0..close], ".zig")) return true;
        rest = rest[close..];
    }
    return false;
}

fn collectZig(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    root: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = cwd.openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, entry.name });
        switch (entry.kind) {
            .file => if (std.mem.endsWith(u8, entry.name, ".zig")) try out.append(gpa, path),
            .directory => try collectZig(gpa, io, cwd, path, out),
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// 4 and 5. Markdown: relative links resolve, headings are unique.
//
// Links inside fenced code blocks are skipped: docs/adr/README.md shows a
// deprecation template whose links are placeholders by design.
// ---------------------------------------------------------------------------

fn checkMarkdown(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) !void {
    var files: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ ".", "docs", "docs/adr", "docs/design", "docs/plans", "docs/review", "docs/status" }) |d| {
        var dir = cwd.openDir(io, d, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
            const path = if (std.mem.eql(u8, d, "."))
                try gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ d, entry.name });
            try files.append(gpa, path);
        }
    }

    for (files.items) |path| {
        const body = read(gpa, io, cwd, path) orelse continue;
        const dir = std.fs.path.dirnamePosix(path) orelse ".";

        var headings: std.StringHashMapUnmanaged(void) = .empty;
        var in_fence = false;
        var lines = std.mem.splitScalar(u8, body, '\n');
        var lineno: usize = 0;
        while (lines.next()) |raw| {
            lineno += 1;
            const line = std.mem.trimEnd(u8, raw, "\r");

            if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) {
                in_fence = !in_fence;
                continue;
            }
            if (in_fence) continue;

            if (std.mem.startsWith(u8, line, "#")) {
                const text = std.mem.trim(u8, line, "# ");
                if (text.len != 0) {
                    if (headings.contains(text))
                        fail(io, "{s}:{d}: duplicate heading \"{s}\"", .{ path, lineno, text })
                    else
                        try headings.put(gpa, text, {});
                }
            }

            var rest = line;
            while (std.mem.indexOf(u8, rest, "](")) |at| {
                rest = rest[at + 2 ..];
                const close = std.mem.indexOfScalar(u8, rest, ')') orelse break;
                const target = rest[0..close];
                rest = rest[close..];
                if (target.len == 0) continue;
                if (std.mem.startsWith(u8, target, "http") or target[0] == '#') continue;
                const file_part = std.mem.sliceTo(target, '#');
                if (file_part.len == 0) continue;
                const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, file_part });
                cwd.access(io, joined, .{}) catch {
                    fail(io, "{s}:{d}: link target {s} does not exist", .{ path, lineno, target });
                };
            }
        }
    }
}
