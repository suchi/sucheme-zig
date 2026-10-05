//! Machine checks over the repository's documentation and build settings.
//!
//! Run as `zig build check-docs`. build.zig passes the test roots and the
//! excluded source files, so the one source of truth for the test layout stays
//! in build.zig; hardcoding them here would let the two drift apart.
//!
//! Zig sources are tokenized rather than text-searched. A raw search would
//! treat `// @import("orphan.zig")` in a comment as a real import, which would
//! mark an unreferenced file as reachable and let its tests stay silently
//! unrun.
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

/// Directories never walked when collecting files.
const skipped_dirs = [_][]const u8{ ".git", ".zig-cache", "zig-out", "node_modules" };

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const argv = try init.minimal.args.toSlice(gpa);
    var roots: std.ArrayList([]const u8) = .empty;
    var excluded: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--root") and i + 1 < argv.len) {
            i += 1;
            try roots.append(gpa, argv[i]);
        } else if (std.mem.eql(u8, argv[i], "--exclude") and i + 1 < argv.len) {
            i += 1;
            try excluded.append(gpa, argv[i]);
        } else {
            fail(io, "unknown argument {s}", .{argv[i]});
        }
    }
    if (roots.items.len == 0) fail(io, "build.zig passed no --root", .{});

    try checkZigVersionAgreement(gpa, io, cwd);
    try checkSources(gpa, io, cwd, roots.items, excluded.items);
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

fn read(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) ?[:0]u8 {
    return cwd.readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0) catch null;
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

    var workflows: std.ArrayList([]const u8) = .empty;
    try collectFiles(gpa, io, cwd, ".github/workflows", ".yml", &workflows);
    try collectFiles(gpa, io, cwd, ".github/workflows", ".yaml", &workflows);
    if (workflows.items.len == 0) {
        fail(io, ".github/workflows has no workflow file; the CI copy of the Zig version cannot be checked", .{});
        return;
    }

    for (workflows.items) |path| {
        const body = read(gpa, io, cwd, path) orelse continue;
        // Compare the `version:` value of the setup step, not any occurrence in
        // the file: a stale version left in a comment would otherwise satisfy
        // the check while CI installs something else.
        const found = workflowZigVersion(body) orelse {
            fail(io, "{s} has no `version:` under a setup-zig step", .{path});
            continue;
        };
        if (!std.mem.eql(u8, found, pinned))
            fail(io, "{s} sets up Zig {s}, .zigversion is {s}", .{ path, found, pinned });
    }
}

/// Finds the `version:` value belonging to a `setup-zig` step, ignoring
/// comments.
fn workflowZigVersion(body: []const u8) ?[]const u8 {
    var in_setup = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOf(u8, line, "setup-zig") != null) {
            in_setup = true;
            continue;
        }
        if (!in_setup) continue;
        if (std.mem.startsWith(u8, line, "version:")) {
            var value = std.mem.trim(u8, line["version:".len..], &std.ascii.whitespace);
            if (std.mem.indexOfScalar(u8, value, '#')) |hash|
                value = std.mem.trim(u8, value[0..hash], &std.ascii.whitespace);
            value = std.mem.trim(u8, value, "\"'");
            if (value.len != 0) return value;
        }
        // A new list item starts, so the setup step's block is over.
        if (std.mem.startsWith(u8, line, "- ")) in_setup = false;
    }
    return null;
}

fn valueAfter(haystack: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, haystack, key) orelse return null;
    const start = at + key.len;
    const end = std.mem.indexOfScalarPos(u8, haystack, start, '"') orelse return null;
    return haystack[start..end];
}

// ---------------------------------------------------------------------------
// 2 and 3. Every src/ file is reachable from a test root, and every file that
// imports siblings re-establishes the reference with refAllDecls.
//
// Zig only analyses a file's `test` blocks when the file is reached from the
// test root, so an unreferenced file's tests are silently skipped. refAllDecls
// descends one level and refAllDeclsRecursive does not exist in Zig 0.17.0, so
// the reference has to be re-established at each level.
// ---------------------------------------------------------------------------

fn checkSources(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    roots: []const []const u8,
    excluded: []const []const u8,
) !void {
    var files: std.ArrayList([]const u8) = .empty;
    try collectFiles(gpa, io, cwd, "src", ".zig", &files);

    var reachable: std.StringHashMapUnmanaged(void) = .empty;
    for (roots) |r| {
        if (!pathIn(files.items, r)) fail(io, "test root {s} does not exist", .{r});
        try reachable.put(gpa, r, {});
    }
    for (excluded) |e| {
        if (!pathIn(files.items, e)) fail(io, "excluded file {s} does not exist", .{e});
    }

    // Repeat until nothing new is reached: imports form a DAG of unknown depth.
    var changed = true;
    while (changed) {
        changed = false;
        for (files.items) |path| {
            if (!reachable.contains(path)) continue;
            const body = read(gpa, io, cwd, path) orelse continue;
            const dir = std.fs.path.dirnamePosix(path) orelse "src";
            var imports: std.ArrayList([]const u8) = .empty;
            try zigImports(gpa, body, &imports);
            for (imports.items) |name| {
                const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
                if (!reachable.contains(joined)) {
                    try reachable.put(gpa, joined, {});
                    changed = true;
                }
            }
        }
    }

    for (files.items) |path| {
        // Exclusions are full repository-relative paths: matching on the base
        // name alone would also exclude src/platform/wasm.zig.
        if (pathIn(excluded, path)) continue;

        if (!reachable.contains(path))
            fail(io, "{s} is not reached from any test root; its tests would be skipped", .{path});

        const body = read(gpa, io, cwd, path) orelse continue;
        var imports: std.ArrayList([]const u8) = .empty;
        try zigImports(gpa, body, &imports);
        if (imports.items.len == 0) continue;
        if (!callsRefAllDecls(body))
            fail(io, "{s} imports other source files but has no refAllDecls(@This()) call", .{path});
    }
}

fn pathIn(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

/// Collects the `*.zig` paths named by real `@import` expressions. Tokenizing
/// keeps commented-out and string-embedded occurrences out of the result.
fn zigImports(gpa: std.mem.Allocator, source: [:0]const u8, out: *std.ArrayList([]const u8)) !void {
    var tok = std.zig.Tokenizer.init(source);
    var state: enum { idle, saw_import, saw_paren } = .idle;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        const text = source[t.loc.start..t.loc.end];
        switch (state) {
            .idle => if (t.tag == .builtin and std.mem.eql(u8, text, "@import")) {
                state = .saw_import;
            },
            .saw_import => state = if (t.tag == .l_paren) .saw_paren else .idle,
            .saw_paren => {
                state = .idle;
                if (t.tag != .string_literal or text.len < 2) continue;
                const name = text[1 .. text.len - 1];
                if (std.mem.endsWith(u8, name, ".zig")) try out.append(gpa, name);
            },
        }
    }
}

/// True when the source really calls `refAllDecls`, not merely mentions it in a
/// comment or a string.
fn callsRefAllDecls(source: [:0]const u8) bool {
    var tok = std.zig.Tokenizer.init(source);
    var prev_was_name = false;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) return false;
        const text = source[t.loc.start..t.loc.end];
        if (prev_was_name and t.tag == .l_paren) return true;
        prev_was_name = t.tag == .identifier and std.mem.eql(u8, text, "refAllDecls");
    }
}

// ---------------------------------------------------------------------------
// 4 and 5. Markdown: relative links resolve, headings are unique.
//
// Links inside fenced code blocks are skipped: docs/adr/README.md shows a
// deprecation template whose links are placeholders by design.
// ---------------------------------------------------------------------------

fn checkMarkdown(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) !void {
    // Walk the whole repository: a fixed directory list left .agents/,
    // .claude/ and .github/ unchecked, which is a quarter of the Markdown.
    var files: std.ArrayList([]const u8) = .empty;
    try collectFiles(gpa, io, cwd, ".", ".md", &files);

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
                // Match the URI scheme, not a bare "http" prefix: a relative
                // path such as http-guide.md would otherwise skip the check.
                if (std.mem.startsWith(u8, target, "http://")) continue;
                if (std.mem.startsWith(u8, target, "https://")) continue;
                if (std.mem.startsWith(u8, target, "mailto:")) continue;
                if (target[0] == '#') continue;
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

// ---------------------------------------------------------------------------

/// Recursively collects paths under `root` whose name ends with `suffix`.
/// Paths are repository-relative and use `/` on every platform.
fn collectFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    root: []const u8,
    suffix: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = cwd.openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const path = if (std.mem.eql(u8, root, "."))
            try gpa.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, entry.name });
        switch (entry.kind) {
            .file => if (std.mem.endsWith(u8, entry.name, suffix)) try out.append(gpa, path),
            .directory => {
                var skip = false;
                for (skipped_dirs) |s| if (std.mem.eql(u8, entry.name, s)) {
                    skip = true;
                };
                if (!skip) try collectFiles(gpa, io, cwd, path, suffix, out);
            },
            else => {},
        }
    }
}
