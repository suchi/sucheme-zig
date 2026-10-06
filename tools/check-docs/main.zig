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
    // Streaming, not the default positional mode: a positional writer starts at
    // offset 0 and would overwrite the head of an appended or shared file, so
    // `zig build check-docs >> ci.log 2>&1` would eat earlier output.
    var stderr = std.Io.File.Writer.initStreaming(.stderr(), io, &buf);
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
            // The next argument must be a value, not another flag: `--root
            // --exclude x` would otherwise register "--exclude" as a root and
            // report the consequences instead of the cause.
            if (i + 1 >= argv.len or std.mem.startsWith(u8, argv[i + 1], "--")) {
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
    if (roots.items.len == 0 and !bad_args) {
        rep.fail("build.zig passed no --root", .{});
        bad_args = true;
    }

    // A malformed command line makes the later checks report consequences
    // rather than causes, so stop here.
    if (!bad_args) {
        try checkZigVersionAgreement(gpa, io, cwd, &rep);
        try checkVendoredHashes(gpa, io, cwd, &rep);
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

/// Reads a file, reporting rather than swallowing a failure: a file that cannot
/// be read drops out of every check, and silence there would be reported as
/// "all checks passed".
fn read(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, rep: *Reporter, path: []const u8) ?[:0]u8 {
    return cwd.readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0) catch |err| {
        rep.fail("{s} cannot be read ({t}), so it is unchecked", .{ path, err });
        return null;
    };
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
    // read reports the failure itself; adding a second message here turned one
    // cause into two problems.
    const pinned_raw = read(gpa, io, cwd, rep, ".zigversion") orelse return;
    const pinned = std.mem.trim(u8, pinned_raw, &std.ascii.whitespace);

    if (read(gpa, io, cwd, rep, "build.zig.zon")) |source| {
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
    }

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
        const body = read(gpa, io, cwd, rep, path) orelse continue;
        var found: std.ArrayList([]const u8) = .empty;
        const steps = try workflowZigVersions(gpa, body, &found);
        setups += steps;
        // Every setup step is checked, not just the first: a second job could
        // otherwise install a different Zig. A workflow with no setup step is
        // fine — not every workflow needs Zig.
        for (found.items) |version| {
            if (!std.mem.eql(u8, version, pinned))
                rep.fail("{s} sets up Zig {s}, .zigversion is {s}", .{ path, version, pinned });
        }
        // Counting steps separately from versions matters: a step whose
        // `version` this parser cannot see (keys reordered, or a flow mapping)
        // would otherwise be indistinguishable from no step at all, and could
        // install any Zig unchecked.
        if (steps != found.items.len)
            rep.fail(
                "{s}: {d} setup-zig step(s) but {d} readable version(s); write `version:` as its own line",
                .{ path, steps, found.items.len },
            );
    }
    if (setups == 0)
        rep.fail("no workflow sets up Zig, so the CI copy of the version is unchecked", .{});
}

/// Extracts a `version:` value written on the same line, as a flow mapping
/// does: `- { uses: ...setup-zig@x, with: { version: 0.17.0 } }`.
fn flowVersion(line: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, line, "version:") orelse return null;
    var rest = line[at + "version:".len ..];
    // Stop at whatever ends the scalar in a flow context.
    if (std.mem.indexOfAny(u8, rest, ",}#")) |end| rest = rest[0..end];
    const value = std.mem.trim(u8, std.mem.trim(u8, rest, &std.ascii.whitespace), "\"'");
    return if (value.len == 0) null else value;
}

/// Collects the `version:` value of every setup-zig step, and returns how many
/// such steps were seen.
///
/// The step is recognised by its `uses:` line, not by the text "setup-zig"
/// appearing anywhere: a step merely *named* "prepare for setup-zig" would
/// otherwise supply the version that gets checked.
fn workflowZigVersions(
    gpa: std.mem.Allocator,
    body: []const u8,
    out: *std.ArrayList([]const u8),
) !usize {
    var steps: usize = 0;
    var in_setup = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;

        const is_item = std.mem.startsWith(u8, line, "- ");
        const body_of_item = if (is_item) std.mem.trim(u8, line[2..], &std.ascii.whitespace) else line;

        if (is_item) in_setup = false;
        // A step counts whenever the line carries a setup-zig reference,
        // whatever YAML spelling holds it. Requiring the line to begin with
        // `uses:` missed an item-level flow mapping and a quoted key, either of
        // which installs a Zig this parser never sees.
        if (std.mem.indexOf(u8, line, "setup-zig@") != null) {
            steps += 1;
            in_setup = true;
            // A flow mapping carries the version on the same line.
            if (flowVersion(line)) |v| {
                try out.append(gpa, v);
                in_setup = false;
            }
            continue;
        }
        if (std.mem.startsWith(u8, body_of_item, "uses:")) {
            in_setup = false;
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
    return steps;
}

// ---------------------------------------------------------------------------
// 2. Vendored inputs match the hash their provenance file records.
//
// SOURCE.md calls the hash the means of verifying ADR-0013's "do not modify the
// imported file". Recording it in a table nothing compares leaves the claim
// without a mechanism: editing the HTML and re-extracting kept every check
// green.
// ---------------------------------------------------------------------------

/// Files whose content is fixed by a recorded hash, with the document that
/// records it. The hash is read from that document, so there is one copy.
const vendored = [_]struct { path: []const u8, provenance: []const u8 }{
    .{
        .path = "tools/extract-r7rs-required/appendix-a.html",
        .provenance = "tools/extract-r7rs-required/SOURCE.md",
    },
};

fn checkVendoredHashes(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
) !void {
    for (vendored) |v| {
        const body = read(gpa, io, cwd, rep, v.path) orelse continue;
        const doc = read(gpa, io, cwd, rep, v.provenance) orelse continue;

        const recorded = sha256InMarkdown(doc) orelse {
            rep.fail("{s} records no SHA-256 for {s}", .{ v.provenance, v.path });
            continue;
        };

        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
        var hex: [digest.len * 2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;

        if (!std.mem.eql(u8, &hex, recorded))
            rep.fail(
                "{s} is {s} but {s} records {s}",
                .{ v.path, hex[0..16], v.provenance, recorded[0..@min(16, recorded.len)] },
            );
    }
}

/// Finds the 64 hex digits of a SHA-256 in a Markdown table row that names it.
fn sha256InMarkdown(doc: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "SHA-256") == null) continue;
        var i: usize = 0;
        while (i + 64 <= line.len) : (i += 1) {
            const candidate = line[i .. i + 64];
            var all_hex = true;
            for (candidate) |c| if (!std.ascii.isHex(c)) {
                all_hex = false;
            };
            if (all_hex) return candidate;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// 3 and 4. Every src/ file is reachable from a test root, and every file that
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
    // tools/ holds most of stage 0's logic and is verification code itself, so
    // it is subject to the same reachability and refAllDecls rules as src/.
    for ([_][]const u8{ "src", "tools" }) |root|
        try collectFiles(gpa, io, cwd, root, ".zig", &files, .recursive);

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
            const body = read(gpa, io, cwd, rep, path) orelse continue;
            const dir = std.fs.path.dirnamePosix(path) orelse "src";
            var imports: std.ArrayList([]const u8) = .empty;
            try zigImports(gpa, body, &imports);
            for (imports.items) |name| {
                const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
                // Normalise: an import written as "../other.zig" would
                // otherwise produce src/sub/../other.zig and never match the
                // collected src/other.zig, reporting a file whose tests do run
                // as unreachable.
                const key = try normalizePath(gpa, joined);
                if (!reachable.contains(key)) {
                    try reachable.put(gpa, key, {});
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

        const body = read(gpa, io, cwd, rep, path) orelse continue;
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

/// Resolves `.` and `..` segments so two spellings of one path compare equal.
/// Separators are normalised to `/`.
fn normalizePath(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len != 0) {
                _ = parts.pop();
                continue;
            }
        }
        try parts.append(gpa, seg);
    }
    return std.mem.join(gpa, "/", parts.items);
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
/// The call must also be qualified: a local `fn refAllDecls` shadowing the std
/// one passes a bare-name check while referencing nothing.
///
/// This cannot prove the call is reached. `comptime { if (false) ... }` inside a
/// test block passes the check and has no effect. Nor can it prove the
/// qualifier resolves to std.testing. Both are recorded as implementation-time
/// questions in docs/design/open-questions.md.
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
            // `.refAllDecls` after a period: the call has to be qualified, so a
            // locally defined function of the same name does not satisfy it.
            0 => if (t.tag == .period) 1 else 0,
            1 => if (t.tag == .identifier and std.mem.eql(u8, text, "refAllDecls")) 2 else 0,
            2 => if (t.tag == .l_paren) 3 else 0,
            3 => if (t.tag == .builtin and std.mem.eql(u8, text, "@This")) 4 else 0,
            4 => if (t.tag == .l_paren) 5 else 0,
            5 => if (t.tag == .r_paren) 6 else 0,
            else => 6,
        };
        if (seen == 6) return true;
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
        const body = read(gpa, io, cwd, rep, path) orelse continue;
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
            // Fences keep an unlimited indentation allowance. CommonMark
            // measures indentation relative to the containing block, so a
            // fence inside a list item can sit four or more spaces in;
            // docs/adr/README.md relies on that. The cost is that an indented
            // code block demonstrating a fence is read as one.
            const trimmed = std.mem.trimStart(u8, line, " ");

            if (fenceRun(trimmed)) |run| {
                if (fence) |open| {
                    // Only a bare run of the same character, at least as long,
                    // closes the block. Anything else is content.
                    if (run.bare and run.ch == open.ch and run.len >= open.len) {
                        fence = null;
                        continue;
                    }
                } else {
                    fence = .{ .ch = run.ch, .len = run.len };
                    fence_line = lineno;
                    continue;
                }
            }
            if (fence != null) continue;

            // Up to three spaces of indentation are allowed before the `#`
            // run, so the heading scan uses the same trimmed line as the fence
            // scan. GitHub renders both as headings with the same anchor.
            // Headings do take the three-space limit: four or more spaces
            // make an indented code block, and a shell comment inside one was
            // being counted as a heading.
            if (atxHeadingText(trimIndent(line))) |text| {
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

/// Extracts the text of an ATX heading, or null when the line is not one.
///
/// CommonMark requires whitespace between the opening `#` run and the text, so
/// `#5 bolt` is a paragraph, not a heading. A closing `#` run only counts when
/// whitespace precedes it: trimming `#` unconditionally would make `## C#` and
/// `## C` the same heading.
fn atxHeadingText(trimmed: []const u8) ?[]const u8 {
    if (trimmed.len == 0 or trimmed[0] != '#') return null;
    var hashes: usize = 0;
    while (hashes < trimmed.len and trimmed[hashes] == '#') hashes += 1;
    if (hashes > 6) return null;
    const rest = trimmed[hashes..];
    if (rest.len != 0 and rest[0] != ' ' and rest[0] != '\t') return null;

    var text = std.mem.trim(u8, rest, " \t");
    if (text.len == 0) return text;
    var end = text.len;
    while (end > 0 and text[end - 1] == '#') end -= 1;
    const had_run = end < text.len;
    const preceded_by_space = end > 0 and (text[end - 1] == ' ' or text[end - 1] == '\t');
    if (had_run and (end == 0 or preceded_by_space))
        text = std.mem.trimEnd(u8, text[0..end], " \t");
    return text;
}

/// Strips up to three spaces of indentation, the most CommonMark allows before
/// an ATX heading at the top level. A line indented four or more spaces is an
/// indented code block, and is returned unchanged so it matches nothing.
fn trimIndent(line: []const u8) []const u8 {
    var n: usize = 0;
    while (n < line.len and n < 4 and line[n] == ' ') n += 1;
    if (n == 4) return line;
    return line[n..];
}

/// Recognises a fence line: a run of at least three backticks or tildes, plus
/// whether anything other than whitespace follows it.
fn fenceRun(trimmed: []const u8) ?struct { ch: u8, len: usize, bare: bool } {
    if (trimmed.len < 3) return null;
    const ch = trimmed[0];
    if (ch != '`' and ch != '~') return null;
    var n: usize = 0;
    while (n < trimmed.len and trimmed[n] == ch) n += 1;
    if (n < 3) return null;
    // CommonMark: "The closing code fence ... may be followed only by spaces or
    // tabs". A line like ```zig opens a block; treating it as a close turns one
    // valid document into two false positives.
    const rest = std.mem.trim(u8, trimmed[n..], " \t");
    return .{ .ch = ch, .len = n, .bare = rest.len == 0 };
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
    // Backtick parity within the line. A code span that spans lines is not
    // tracked, so a link-looking fragment inside one is reported. CommonMark
    // allows multi-line spans; no file here uses one.
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
    // Strip a title. Backslash escapes are not handled: a destination such as
    // `a\ b.md` is reported under the truncated name. No file in this
    // repository needs one, and handling them means implementing CommonMark's
    // escape rules.
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
// ---------------------------------------------------------------------------
// Tests
//
// These cover the pure decision functions: the parts whose mistakes show up as
// a check that quietly stops catching things. Every case below is one that an
// adversarial review actually produced against an earlier version of this
// file, so a regression reintroduces a known hole rather than a hypothetical.
// ---------------------------------------------------------------------------

test "fenceRun: an info string means the line opens, never closes" {
    // ```zig must not be read as a closing fence; doing so made one valid
    // document report a stray link plus an unclosed fence.
    const open = fenceRun("```zig").?;
    try std.testing.expect(!open.bare);
    const close = fenceRun("```").?;
    try std.testing.expect(close.bare);
    try std.testing.expectEqual(@as(usize, 3), close.len);
    try std.testing.expectEqual(@as(u8, '`'), close.ch);
}

test "fenceRun: tildes and longer runs" {
    try std.testing.expectEqual(@as(u8, '~'), fenceRun("~~~").?.ch);
    try std.testing.expectEqual(@as(usize, 4), fenceRun("````").?.len);
    try std.testing.expect(fenceRun("``") == null);
    try std.testing.expect(fenceRun("not a fence") == null);
    // Trailing whitespace still closes.
    try std.testing.expect(fenceRun("```   ").?.bare);
}

test "atxHeadingText: whitespace is required after the hashes" {
    // #5 bolt is a paragraph in CommonMark; treating it as a heading made
    // "#2 の指摘" style prose collide with a real heading.
    try std.testing.expect(atxHeadingText("##A") == null);
    try std.testing.expectEqualStrings("A", atxHeadingText("## A").?);
    try std.testing.expectEqualStrings("A", atxHeadingText("#\tA").?);
}

test "atxHeadingText: a closing run needs whitespace before it" {
    // ## C# and ## C are different headings.
    try std.testing.expectEqualStrings("C#", atxHeadingText("## C#").?);
    try std.testing.expectEqualStrings("A", atxHeadingText("## A ##").?);
    try std.testing.expectEqualStrings("", atxHeadingText("## ##").?);
}

test "atxHeadingText: more than six hashes is not a heading" {
    try std.testing.expect(atxHeadingText("####### x") == null);
    try std.testing.expectEqualStrings("x", atxHeadingText("###### x").?);
}

test "hasUriScheme: a scheme needs a colon, and matching is case-insensitive" {
    try std.testing.expect(hasUriScheme("https://example.com"));
    try std.testing.expect(hasUriScheme("HTTPS://example.com"));
    try std.testing.expect(hasUriScheme("ftp://example.com"));
    try std.testing.expect(hasUriScheme("mailto:a@b"));
    // A bare "http" prefix must not swallow a relative path.
    try std.testing.expect(!hasUriScheme("http-guide.md"));
    try std.testing.expect(!hasUriScheme("docs/x.md"));
    try std.testing.expect(!hasUriScheme(""));
}

test "linkDestination: a title is not part of the destination" {
    // A titled link is standard CommonMark; passing the title through to the
    // file system crashed on Windows.
    try std.testing.expectEqualStrings("README.md", linkDestination("README.md \"The readme\")").?.target);
    try std.testing.expectEqualStrings("README.md", linkDestination("README.md 'x')").?.target);
    try std.testing.expectEqualStrings("README.md", linkDestination("<README.md>)").?.target);
    try std.testing.expectEqualStrings("a.md", linkDestination("a.md)").?.target);
    try std.testing.expect(linkDestination("no-close") == null);
}

test "zigImports: only real import expressions count" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(gpa);
    // A commented-out import once made an unreferenced file look reachable.
    try zigImports(gpa,
        \\const a = @import("real.zig");
        \\// @import("commented.zig")
        \\const s = "@import(\"instring.zig\")";
        \\const std = @import("std");
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("real.zig", out.items[0]);
}

test "hasRefAllDeclsTest: the argument must be @This()" {
    // Passing another container compiles and reads like the convention but
    // references the wrong declarations.
    try std.testing.expect(hasRefAllDeclsTest("test { std.testing.refAllDecls(@This()); }"));
    try std.testing.expect(!hasRefAllDeclsTest("test { std.testing.refAllDecls(std.ascii); }"));
    try std.testing.expect(!hasRefAllDeclsTest("// refAllDecls(@This())"));
    try std.testing.expect(!hasRefAllDeclsTest("comptime { refAllDecls(@This()); }"));
}

test "workflowZigVersions: every setup-zig step is counted" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(gpa);
    const steps = try workflowZigVersions(gpa,
        \\jobs:
        \\  a:
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc
        \\        with:
        \\          version: 0.17.0
        \\  b:
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc
        \\        with:
        \\          version: 0.18.0
    , &out);
    try std.testing.expectEqual(@as(usize, 2), steps);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("0.17.0", out.items[0]);
    try std.testing.expectEqualStrings("0.18.0", out.items[1]);
}

test "workflowZigVersions: a step whose version cannot be read still counts" {
    // Counting steps and versions separately is what makes an unreadable
    // version distinguishable from no step at all.
    const gpa = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(gpa);
    const steps = try workflowZigVersions(gpa,
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc
        \\        with: { version: 0.18.0 }
    , &out);
    try std.testing.expectEqual(@as(usize, 1), steps);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "workflowZigVersions: a step merely named after setup-zig supplies nothing" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(gpa);
    const steps = try workflowZigVersions(gpa,
        \\    steps:
        \\      - name: prepare for setup-zig
        \\        uses: actions/checkout@abc
        \\        with:
        \\          version: 0.18.0
    , &out);
    try std.testing.expectEqual(@as(usize, 0), steps);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "workflowZigVersions: comments do not supply a version" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(gpa);
    const steps = try workflowZigVersions(gpa,
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc
        \\        with:
        \\          # version: 0.17.0
        \\          version: 0.18.0
    , &out);
    try std.testing.expectEqual(@as(usize, 1), steps);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("0.18.0", out.items[0]);
}

test "pathIn compares whole paths" {
    const haystack = [_][]const u8{ "src/wasm.zig", "src/main.zig" };
    try std.testing.expect(pathIn(&haystack, "src/wasm.zig"));
    // A base-name match would also exclude src/platform/wasm.zig.
    try std.testing.expect(!pathIn(&haystack, "src/platform/wasm.zig"));
    try std.testing.expect(!pathIn(&haystack, "wasm.zig"));
}

test "normalizePath resolves . and .. so an import chain matches" {
    const gpa = std.testing.allocator;
    const a = try normalizePath(gpa, "src/sub/../other.zig");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("src/other.zig", a);
    const b = try normalizePath(gpa, "src/./x.zig");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("src/x.zig", b);
}
