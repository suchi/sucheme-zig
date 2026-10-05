//! Machine checks over the repository's documentation and build settings.
//!
//! Run as `zig build check-docs`. build.zig passes the test roots and the
//! excluded source files, so the one source of truth for the test layout stays
//! in build.zig; hardcoding them here would let the two drift apart.
//!
//! Zig sources are tokenized and build.zig.zon is parsed as ZON, never
//! string-searched. A raw search would treat `// @import("orphan.zig")` in a
//! comment as a real import, and a commented-out `.version` would shadow the
//! real one.
//!
//! Every failure is reported before exiting non-zero: stopping at the first one
//! would mean fixing a single finding per run. One writer serves the whole run
//! — creating a `File.Writer` per diagnostic rewinds to offset 0 each time, so
//! `2> log` would keep only the last line.
//!
//! What is deliberately NOT checked: whether prose declares a pinned Zig
//! version. "Declaration", "reference" and "record of a verification" cannot be
//! told apart by matching digits, and attempts produce both false positives (a
//! documentation URL containing the version) and false negatives (a bare
//! "0.17"). docs/design/zig-api-notes.md keeps that as a human step in the
//! version-bump procedure.

const std = @import("std");

/// Directories never walked when collecting files. `_work` is the scratch
/// directory .gitignore reserves: notes left there must not fail the checks.
const skipped_dirs = [_][]const u8{ ".git", ".zig-cache", "zig-out", "node_modules", "_work" };

/// Collects diagnostics on one writer so a redirect keeps all of them.
const Reporter = struct {
    w: *std.Io.Writer,
    count: usize = 0,

    fn fail(self: *Reporter, comptime fmt: []const u8, args: anytype) void {
        self.count += 1;
        self.w.print("check-docs: " ++ fmt ++ "\n", args) catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var buf: [8192]u8 = undefined;
    var stderr = std.Io.File.Writer.init(.stderr(), io, &buf);
    var rep: Reporter = .{ .w = &stderr.interface };

    const argv = try init.minimal.args.toSlice(gpa);
    var roots: std.ArrayList([]const u8) = .empty;
    var excluded: std.ArrayList([]const u8) = .empty;
    var bad_args = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const which: ?*std.ArrayList([]const u8) =
            if (std.mem.eql(u8, argv[i], "--root")) &roots else if (std.mem.eql(u8, argv[i], "--exclude")) &excluded else null;
        if (which) |list| {
            if (i + 1 >= argv.len) {
                rep.fail("{s} needs a value", .{argv[i]});
                bad_args = true;
                break;
            }
            i += 1;
            try list.append(gpa, argv[i]);
        } else {
            rep.fail("unknown argument {s}", .{argv[i]});
            bad_args = true;
            break;
        }
    }
    if (roots.items.len == 0 and !bad_args) rep.fail("build.zig passed no --root", .{});

    // A malformed command line makes the later checks report consequences
    // rather than causes, so stop here.
    if (!bad_args) {
        try checkZigVersionAgreement(gpa, io, cwd, &rep);
        try checkSources(gpa, io, cwd, &rep, roots.items, excluded.items);
        try checkMarkdown(gpa, io, cwd, &rep);
    }

    if (rep.count == 0) {
        try rep.w.print("check-docs: all checks passed\n", .{});
    } else {
        try rep.w.print("check-docs: {d} problem(s) found\n", .{rep.count});
    }
    try stderr.interface.flush();
    if (rep.count != 0) std.process.exit(1);
}

fn read(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) ?[:0]u8 {
    return cwd.readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0) catch null;
}

// ---------------------------------------------------------------------------
// 1. The pinned Zig version agrees in all three machine-read places.
// ---------------------------------------------------------------------------

/// The one field of build.zig.zon this check reads.
const Manifest = struct { minimum_zig_version: []const u8 };

fn checkZigVersionAgreement(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
) !void {
    const pinned_raw = read(gpa, io, cwd, ".zigversion") orelse {
        rep.fail(".zigversion is missing", .{});
        return;
    };
    const pinned = std.mem.trim(u8, pinned_raw, &std.ascii.whitespace);

    if (read(gpa, io, cwd, "build.zig.zon")) |source| {
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        if (std.zon.parse.fromSlice(Manifest, .{
            .gpa = gpa,
            .arena = gpa,
            .source = source,
            .diagnostics = &diagnostics,
            .ignore_unknown_fields = true,
        })) |m| {
            if (!std.mem.eql(u8, m.minimum_zig_version, pinned))
                rep.fail(
                    "build.zig.zon minimum_zig_version is {s}, .zigversion is {s}",
                    .{ m.minimum_zig_version, pinned },
                );
        } else |_| rep.fail("build.zig.zon could not be parsed as ZON", .{});
    } else rep.fail("build.zig.zon is missing", .{});

    // Only workflows at the top of .github/workflows run; a file in a
    // subdirectory is inert, so checking its version would fail on nothing.
    var workflows: std.ArrayList([]const u8) = .empty;
    try collectFiles(gpa, io, cwd, ".github/workflows", ".yml", &workflows, .flat);
    try collectFiles(gpa, io, cwd, ".github/workflows", ".yaml", &workflows, .flat);
    if (workflows.items.len == 0) {
        rep.fail(".github/workflows has no workflow file; the CI copy of the Zig version cannot be checked", .{});
        return;
    }

    var setups: usize = 0;
    for (workflows.items) |path| {
        const body = read(gpa, io, cwd, path) orelse continue;
        var found: std.ArrayList([]const u8) = .empty;
        try workflowZigVersions(gpa, body, &found);
        setups += found.items.len;
        // Every setup step is checked, not just the first: a second job could
        // otherwise install a different Zig. A workflow with no setup step is
        // fine — not every workflow needs Zig.
        for (found.items) |version| {
            if (!std.mem.eql(u8, version, pinned))
                rep.fail("{s} sets up Zig {s}, .zigversion is {s}", .{ path, version, pinned });
        }
    }
    if (setups == 0)
        rep.fail("no workflow sets up Zig, so the CI copy of the version is unchecked", .{});
}

/// Collects the `version:` value of every `uses: .../setup-zig@...` step.
///
/// The step is recognised by its `uses:` line, not by the text "setup-zig"
/// appearing anywhere: a step merely *named* "prepare for setup-zig" would
/// otherwise supply the version that gets checked.
fn workflowZigVersions(
    gpa: std.mem.Allocator,
    body: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var in_setup = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;

        const is_item = std.mem.startsWith(u8, line, "- ");
        const body_of_item = if (is_item) std.mem.trim(u8, line[2..], &std.ascii.whitespace) else line;

        if (is_item) in_setup = false;
        if (std.mem.startsWith(u8, body_of_item, "uses:")) {
            const value = std.mem.trim(u8, body_of_item["uses:".len..], &std.ascii.whitespace);
            in_setup = std.mem.indexOf(u8, value, "setup-zig@") != null;
            continue;
        }
        if (!in_setup) continue;
        if (std.mem.startsWith(u8, body_of_item, "version:")) {
            var value = std.mem.trim(u8, body_of_item["version:".len..], &std.ascii.whitespace);
            if (std.mem.indexOfScalar(u8, value, '#')) |hash|
                value = std.mem.trim(u8, value[0..hash], &std.ascii.whitespace);
            value = std.mem.trim(u8, value, "\"'");
            if (value.len != 0) try out.append(gpa, value);
        }
    }
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
    rep: *Reporter,
    roots: []const []const u8,
    excluded: []const []const u8,
) !void {
    var files: std.ArrayList([]const u8) = .empty;
    try collectFiles(gpa, io, cwd, "src", ".zig", &files, .recursive);

    var reachable: std.StringHashMapUnmanaged(void) = .empty;
    for (roots) |r| {
        if (!pathIn(files.items, r)) rep.fail("test root {s} does not exist", .{r});
        try reachable.put(gpa, r, {});
    }
    for (excluded) |e| {
        if (!pathIn(files.items, e)) rep.fail("excluded file {s} does not exist", .{e});
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
            rep.fail("{s} is not reached from any test root; its tests would be skipped", .{path});

        const body = read(gpa, io, cwd, path) orelse continue;
        var imports: std.ArrayList([]const u8) = .empty;
        try zigImports(gpa, body, &imports);
        if (imports.items.len == 0) continue;
        if (!hasRefAllDeclsTest(body))
            rep.fail(
                "{s} imports other source files but has no top-level `test` calling refAllDecls(@This())",
                .{path},
            );
    }
}

fn pathIn(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

/// Collects the `*.zig` paths named by real `@import` expressions. Tokenizing
/// keeps commented-out and string-embedded occurrences out of the result.
/// Zig requires a string literal as the operand, so there is no way to hide an
/// import behind a constant.
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

/// True when a top-level `test` block contains the call `refAllDecls(@This())`.
///
/// The argument must be `@This()`: passing another container compiles and reads
/// like the convention but references the wrong declarations, so the imported
/// file's tests still never run.
///
/// This cannot prove the call is reached. `comptime { if (false) ... }` inside a
/// test block passes the check and has no effect. Proving reachability needs
/// semantic analysis, which is recorded as an implementation-time question in
/// docs/design/open-questions.md.
fn hasRefAllDeclsTest(source: [:0]const u8) bool {
    var tok = std.zig.Tokenizer.init(source);
    var depth: usize = 0;
    var test_depth: ?usize = null;
    // The call is five tokens: refAllDecls ( @This ( ) — the closing paren of
    // refAllDecls follows.
    var seen: usize = 0;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) return false;
        const text = source[t.loc.start..t.loc.end];

        switch (t.tag) {
            .l_brace => depth += 1,
            .r_brace => {
                if (depth > 0) depth -= 1;
                if (test_depth) |d| if (depth <= d) {
                    test_depth = null;
                };
            },
            .keyword_test => if (depth == 0) {
                test_depth = depth;
            },
            else => {},
        }
        if (test_depth == null) {
            seen = 0;
            continue;
        }

        seen = switch (seen) {
            0 => if (t.tag == .identifier and std.mem.eql(u8, text, "refAllDecls")) 1 else 0,
            1 => if (t.tag == .l_paren) 2 else 0,
            2 => if (t.tag == .builtin and std.mem.eql(u8, text, "@This")) 3 else 0,
            3 => if (t.tag == .l_paren) 4 else 0,
            4 => if (t.tag == .r_paren) 5 else 0,
            else => 5,
        };
        if (seen == 5) return true;
    }
}

// ---------------------------------------------------------------------------
// 4 and 5. Markdown: relative links resolve, headings are unique.
//
// Links inside fenced code blocks are skipped: docs/adr/README.md shows a
// deprecation template whose links are placeholders by design.
// ---------------------------------------------------------------------------

fn checkMarkdown(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, rep: *Reporter) !void {
    // Walk the whole repository: a fixed directory list left .agents/,
    // .claude/ and .github/ unchecked, which is a quarter of the Markdown.
    var files: std.ArrayList([]const u8) = .empty;
    try collectFiles(gpa, io, cwd, ".", ".md", &files, .recursive);

    for (files.items) |path| {
        const body = read(gpa, io, cwd, path) orelse continue;
        const dir = std.fs.path.dirnamePosix(path) orelse ".";

        var headings: std.StringHashMapUnmanaged(void) = .empty;
        // A fence is closed by a run of the same character at least as long as
        // the opener, so ``` inside a ```` block does not end it.
        var fence: ?struct { ch: u8, len: usize } = null;
        var fence_line: usize = 0;
        var lines = std.mem.splitScalar(u8, body, '\n');
        var lineno: usize = 0;
        while (lines.next()) |raw| {
            lineno += 1;
            const line = std.mem.trimEnd(u8, raw, "\r");
            const trimmed = std.mem.trimStart(u8, line, " ");

            if (fenceRun(trimmed)) |run| {
                if (fence) |open| {
                    if (run.ch == open.ch and run.len >= open.len) fence = null;
                } else {
                    fence = .{ .ch = run.ch, .len = run.len };
                    fence_line = lineno;
                }
                continue;
            }
            if (fence != null) continue;

            if (std.mem.startsWith(u8, line, "#")) {
                const text = atxHeadingText(line);
                if (text.len != 0) {
                    if (headings.contains(text))
                        rep.fail("{s}:{d}: duplicate heading \"{s}\"", .{ path, lineno, text })
                    else
                        try headings.put(gpa, text, {});
                }
            }

            try checkLinksOnLine(gpa, io, cwd, rep, path, lineno, dir, line);
        }
        if (fence) |open|
            rep.fail("{s}:{d}: code fence opened with {d} '{c}' is never closed", .{ path, fence_line, open.len, open.ch });
    }
}

/// Extracts the text of an ATX heading.
///
/// A closing `#` run only counts when whitespace precedes it, per CommonMark.
/// Trimming `#` unconditionally would make `## C#` and `## C` the same heading.
fn atxHeadingText(line: []const u8) []const u8 {
    const after_hashes = std.mem.trimStart(u8, line, "#");
    var text = std.mem.trim(u8, after_hashes, " ");
    if (text.len == 0) return text;
    var end = text.len;
    while (end > 0 and text[end - 1] == '#') end -= 1;
    const had_run = end < text.len;
    const preceded_by_space = end > 0 and (text[end - 1] == ' ' or text[end - 1] == '\t');
    if (had_run and (end == 0 or preceded_by_space))
        text = std.mem.trimEnd(u8, text[0..end], " \t");
    return text;
}

/// Recognises a fence line and returns its character and length.
fn fenceRun(trimmed: []const u8) ?struct { ch: u8, len: usize } {
    if (trimmed.len < 3) return null;
    const ch = trimmed[0];
    if (ch != '`' and ch != '~') return null;
    var n: usize = 0;
    while (n < trimmed.len and trimmed[n] == ch) n += 1;
    if (n < 3) return null;
    return .{ .ch = ch, .len = n };
}

fn checkLinksOnLine(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    path: []const u8,
    lineno: usize,
    dir: []const u8,
    line: []const u8,
) !void {
    var i: usize = 0;
    var in_code_span = false;
    while (i < line.len) {
        // An inline code span may contain `](dest)` as an example; it is not a
        // link.
        if (line[i] == '`') {
            in_code_span = !in_code_span;
            i += 1;
            continue;
        }
        if (in_code_span or i + 1 >= line.len or line[i] != ']' or line[i + 1] != '(') {
            i += 1;
            continue;
        }
        i += 2;
        const dest = linkDestination(line[i..]) orelse continue;
        i += dest.consumed;
        const target = dest.target;
        if (target.len == 0) continue;
        // Any URI scheme, matched case-insensitively: RFC 3986 makes schemes
        // case-insensitive, and a bare "http" prefix would also skip the
        // relative path http-guide.md.
        if (hasUriScheme(target)) continue;
        if (target[0] == '#') continue;
        const file_part = std.mem.sliceTo(target, '#');
        if (file_part.len == 0) continue;
        // Reject characters a path cannot hold before touching the file system:
        // std.Io.Dir.access panics on Windows for an invalid name rather than
        // returning an error, which would turn one bad link into a crash that
        // loses every other diagnostic.
        if (std.mem.indexOfAny(u8, file_part, "<>:\"|?*") != null or
            std.mem.indexOfScalar(u8, file_part, 0) != null)
        {
            rep.fail("{s}:{d}: link target {s} is not a usable path", .{ path, lineno, target });
            continue;
        }
        const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, file_part });
        cwd.access(io, joined, .{}) catch {
            rep.fail("{s}:{d}: link target {s} does not exist", .{ path, lineno, target });
        };
    }
}

/// Splits a CommonMark inline link destination from its optional title.
/// Handles `<dest>`, `dest`, `dest "title"`, `dest 'title'` and `dest (title)`.
fn linkDestination(rest: []const u8) ?struct { target: []const u8, consumed: usize } {
    if (rest.len == 0) return null;
    if (rest[0] == '<') {
        const close = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
        const end = std.mem.indexOfScalarPos(u8, rest, close, ')') orelse return null;
        return .{ .target = rest[1..close], .consumed = end };
    }
    const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    var target = std.mem.trim(u8, rest[0..close], " \t");
    // Strip a title: the destination ends at the first unescaped space.
    if (std.mem.indexOfAny(u8, target, " \t")) |space|
        target = std.mem.trimEnd(u8, target[0..space], " \t");
    return .{ .target = target, .consumed = close };
}

/// True when the text starts with a URI scheme (`scheme:`), per RFC 3986:
/// ALPHA followed by ALPHA / DIGIT / "+" / "-" / "." and then a colon.
fn hasUriScheme(text: []const u8) bool {
    if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return false;
    for (text[1..], 1..) |c, idx| {
        if (c == ':') return idx >= 1;
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return false;
}

// ---------------------------------------------------------------------------

const Walk = enum { flat, recursive };

/// Collects paths under `root` whose name ends with `suffix`. Paths are
/// repository-relative and use `/` on every platform.
fn collectFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    root: []const u8,
    suffix: []const u8,
    out: *std.ArrayList([]const u8),
    walk: Walk,
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
                if (walk == .flat) continue;
                var skip = false;
                for (skipped_dirs) |s| if (std.mem.eql(u8, entry.name, s)) {
                    skip = true;
                };
                if (!skip) try collectFiles(gpa, io, cwd, path, suffix, out, walk);
            },
            else => {},
        }
    }
}
