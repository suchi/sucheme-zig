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
//! What is checked is limited to facts about the code and the generated files:
//! that a verification cannot stop without saying so, that a generated file
//! still follows from its input, that a pinned version agrees everywhere, and
//! that a relative link resolves. The way prose is written is not checked. The
//! line, and the checks withdrawn to draw it, are in
//! docs/adr/0026-verify-facts-about-code-not-prose.md.
//!
//! Also not checked: whether prose declares a pinned Zig version.
//! "Declaration", "reference" and "record of a verification" cannot be told
//! apart by matching digits, and attempts produce both false positives (a
//! documentation URL containing the version) and false negatives (a bare
//! "0.17"). docs/design/zig-api-notes.md keeps that as a human step in the
//! version-bump procedure.

const std = @import("std");

/// Directories never walked when collecting files, beyond what `.gitignore`
/// already excludes. `.git` is git's own, and `node_modules` belongs to a
/// package manager; neither is named in `.gitignore`, and walking either would
/// check files this repository does not own. Everything else that should be
/// skipped is skipped because `.gitignore` names it, so this list does not
/// repeat `zig-out/`, `.zig-cache/` or `_work`.
const skipped_dirs = [_][]const u8{ ".git", "node_modules" };

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
    // The commands `build.zig` guarantees exist, each named after the step that
    // provides it. See the `--requires` list there for why the build has to be
    // the one naming them.
    var required: std.ArrayList([]const u8) = .empty;
    var bad_args = false;
    var stage: ?usize = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--stage")) {
            if (i + 1 >= argv.len or std.mem.startsWith(u8, argv[i + 1], "--")) {
                rep.fail("--stage needs a value", .{});
                bad_args = true;
                break;
            }
            i += 1;
            stage = std.fmt.parseInt(usize, argv[i], 10) catch {
                rep.fail("--stage {s} is not a number", .{argv[i]});
                bad_args = true;
                break;
            };
            continue;
        }
        const which: ?*std.ArrayList([]const u8) =
            if (std.mem.eql(u8, argv[i], "--root")) &roots else if (std.mem.eql(u8, argv[i], "--exclude")) &excluded else if (std.mem.eql(u8, argv[i], "--requires")) &required else null;
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
    if (stage == null and !bad_args) {
        rep.fail("build.zig passed no --stage", .{});
        bad_args = true;
    }
    if (required.items.len == 0 and !bad_args) {
        rep.fail("build.zig passed no --requires", .{});
        bad_args = true;
    }

    // A malformed command line makes the later checks report consequences
    // rather than causes, so stop here.
    if (!bad_args) {
        // Read once, here, so a missing .gitignore is one diagnostic rather
        // than one per check. An empty set means every entry is considered,
        // which is the strict direction.
        const ignore = read(gpa, io, cwd, &rep, ".gitignore") orelse "";

        try checkZigVersionAgreement(gpa, io, cwd, &rep, ignore);
        try checkCiRunsTheTable(gpa, io, cwd, &rep, ignore, stage.?, required.items);
        try checkVendoredHashes(gpa, io, cwd, &rep);
        try checkGeneratedHashes(gpa, io, cwd, &rep, ignore);
        try checkRecordedCounts(gpa, io, cwd, &rep, ignore);
        try checkSources(gpa, io, cwd, &rep, ignore, roots.items, excluded.items);
        try checkMarkdown(gpa, io, cwd, &rep, ignore);
        try checkAdrRules(gpa, io, cwd, &rep, ignore);
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
    ignore: []const u8,
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
    try collectFiles(gpa, io, cwd, ignore, ".github/workflows", ".yml", &workflows, .flat);
    try collectFiles(gpa, io, cwd, ignore, ".github/workflows", ".yaml", &workflows, .flat);
    if (workflows.items.len == 0) {
        rep.fail(".github/workflows has no workflow file; the CI copy of the Zig version cannot be checked", .{});
        return;
    }

    var setups_per_commit: usize = 0;
    for (workflows.items) |path| {
        const body = read(gpa, io, cwd, rep, path) orelse continue;
        var found: std.ArrayList(StepVersion) = .empty;
        try workflowZigVersions(gpa, body, &found);
        if (std.mem.eql(u8, path, per_commit_workflow)) setups_per_commit += found.items.len;
        // Every setup step is checked, not just the first: a second job could
        // otherwise install a different Zig. A workflow with no setup step is
        // fine -- not every workflow needs Zig.
        for (found.items) |step| {
            const version = step.version;
            if (version == null or step.extra) {
                rep.fail(
                    "{s}: a setup-zig step has no single readable version; write one `version:` on a line of its own under that step's `with:`",
                    .{path},
                );
                continue;
            }
            if (!std.mem.eql(u8, version.?, pinned))
                rep.fail("{s} sets up Zig {s}, .zigversion is {s}", .{ path, version.?, pinned });
        }
    }
    // Counted in the per-commit workflow, not across all of them. A total let
    // the setup step move to a workflow nothing triggers: the version stayed
    // checked while the commands that need Zig had none installed. The run
    // lines are held to the same workflow for the same reason.
    if (setups_per_commit == 0) rep.fail(
        "{s} has no setup-zig step, so the commands it runs have no pinned Zig",
        .{per_commit_workflow},
    );
}

// ---------------------------------------------------------------------------
// Every ADR has a row in the index and every row has a file.
//
// Only the pair's existence. What the row says about the ADR -- its status, its
// replacement, where its notes sit -- was compared here for several rounds, and
// doing that meant reading records out of Markdown prose. ADR-0026 withdrew
// that: a stale status in the index is an error a reader catches, and the
// special cases needed to catch it mechanically cost more than the error.
// ---------------------------------------------------------------------------

const adr_dir = "docs/adr";
const adr_index = "docs/adr/README.md";

fn checkAdrRules(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    ignore: []const u8,
) !void {
    var files: std.ArrayList([]const u8) = .empty;
    try collectFiles(gpa, io, cwd, ignore, adr_dir, ".md", &files, .flat);

    // Read as a reader sees it. Taking the raw file let the whole index be
    // wrapped in an HTML comment: every row vanished from the rendered page
    // while this check still found them all.
    const raw_index = read(gpa, io, cwd, rep, adr_index) orelse return;
    const index = try visibleMarkdown(gpa, rep, adr_index, raw_index);

    for (files.items) |path| {
        const name = std.fs.path.basename(path);
        // The index and the template are not decisions.
        if (std.mem.eql(u8, name, "README.md") or std.mem.startsWith(u8, name, "0000-")) continue;
        switch (adrRow(index, name)) {
            .one => {},
            .none => rep.fail("{s} has no row opening with a link to {s}", .{ adr_index, name }),
            .many => |n| rep.fail(
                "{s} has {d} rows for {s}; one ADR has one row",
                .{ adr_index, n, name },
            ),
        }
    }

    // A row whose file is gone.
    var lines = std.mem.splitScalar(u8, index, '\n');
    while (lines.next()) |raw| {
        const row = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (row.len == 0 or row[0] != '|') continue;
        const target = linkTargetInRow(row) orelse continue;
        const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ adr_dir, target });
        if (!pathIn(files.items, joined)) rep.fail(
            "{s} lists {s}, which does not exist",
            .{ adr_index, target },
        );
    }
}

/// The index row whose first cell links to `name`.
///
/// Counted, not found: the table says each ADR has one row, and an outdated row
/// left below the real one made the index show two answers for one ADR.
const IndexRow = union(enum) {
    one: []const u8,
    none,
    many: usize,
};

fn adrRow(index: []const u8, name: []const u8) IndexRow {
    var found: ?[]const u8 = null;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, index, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] != '|') continue;
        const first = cellAt(line, 0) orelse continue;
        const target = linkTargetInRow(first) orelse continue;
        if (!std.mem.eql(u8, target, name)) continue;
        count += 1;
        if (found == null) found = line;
    }
    if (count > 1) return .{ .many = count };
    return if (found) |line| .{ .one = line } else .none;
}

/// The first `](...)` target in a row, when it names a sibling Markdown file.
///
/// A leading `./` is dropped and a link title is dropped, because both name the
/// same file and neither was recognised: writing `[0017](./0017-x.md)` made a
/// duplicated index row invisible to the check that counts rows.
fn linkTargetInRow(row: []const u8) ?[]const u8 {
    const open = std.mem.indexOf(u8, row, "](") orelse return null;
    const rest = row[open + 2 ..];
    const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    var target = rest[0..close];

    // `[text](path "title")`
    if (std.mem.indexOfScalar(u8, target, ' ')) |space| target = target[0..space];
    // `[text](<path>)`
    if (target.len >= 2 and target[0] == '<' and target[target.len - 1] == '>')
        target = target[1 .. target.len - 1];
    if (std.mem.startsWith(u8, target, "./")) target = target[2..];

    if (!std.mem.endsWith(u8, target, ".md")) return null;
    if (std.mem.indexOfScalar(u8, target, '/') != null) return null;
    return target;
}

// ---------------------------------------------------------------------------
// The CI workflow runs the rows AGENTS.md marks for every commit.
//
// .github/workflows/ci.yml declares that table to be the source of truth for
// what it runs. Nothing compared the two, so deleting one `- run:` line left
// that verification silently stopped -- the state the workflow's own comment
// says it is written to avoid.
// ---------------------------------------------------------------------------

/// The workflow that runs on every commit.
///
/// Named, because "every commit" is a property of the trigger and this is the
/// only workflow whose trigger is a commit. A command the table marks 全コミット
/// has to run here, not merely somewhere: accepting a match in any workflow let
/// a command move to one driven by a schedule and stay green.
const per_commit_workflow = ".github/workflows/ci.yml";

/// A row of the verification command table, as this check reads it.
const CommandRow = struct {
    command: []const u8,
    /// The stage the command starts existing at, or null if the cell is not a
    /// number -- the setup row writes `-`.
    stage: ?usize,
    every_commit: bool,
};

/// Reports disagreement between the table and the workflow that runs per commit.
///
/// Both directions. The table requires a command that the workflow does not run,
/// and the workflow runs a command the table does not mark for this stage. One
/// direction alone needed the table to be read exactly: hiding a row, or writing
/// `全コミット` with a zero-width space in it, removed the requirement and nothing
/// noticed. With both, a row the check cannot see leaves the workflow's step
/// unaccounted for, so the spelling of the cell stops mattering.
fn checkCiRunsTheTable(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    ignore: []const u8,
    stage: usize,
    required_commands: []const []const u8,
) !void {
    const raw_table = read(gpa, io, cwd, rep, "AGENTS.md") orelse return;
    const table = try visibleMarkdown(gpa, rep, "AGENTS.md", raw_table);

    var workflows: std.ArrayList([]const u8) = .empty;
    try collectFiles(gpa, io, cwd, ignore, ".github/workflows", ".yml", &workflows, .flat);
    try collectFiles(gpa, io, cwd, ignore, ".github/workflows", ".yaml", &workflows, .flat);

    // The keys are checked in every workflow, because an unreadable key anywhere
    // makes this check's reading of that file untrustworthy. The commands are
    // collected only from the one that runs per commit.
    var run_lines: std.ArrayList([]const u8) = .empty;
    // The keys and values the per-commit workflow actually carries, so the ones
    // that decide whether it runs at all can be held to a closed set.
    var seen: std.ArrayList(struct { key: []const u8, value: []const u8 }) = .empty;
    for (workflows.items) |path| {
        const per_commit = std.mem.eql(u8, path, per_commit_workflow);
        const body = read(gpa, io, cwd, rep, path) orelse continue;
        // The column a step's own keys sit at, from the most recent list item.
        var step_keys_at: ?usize = null;
        var lines = std.mem.splitScalar(u8, body, '\n');
        var lineno: usize = 0;
        while (lines.next()) |raw| {
            lineno += 1;
            var line = std.mem.trim(u8, raw, &std.ascii.whitespace);
            line = std.mem.trim(u8, stripComment(line), &std.ascii.whitespace);
            if (line.len == 0) continue;

            const is_item = std.mem.startsWith(u8, line, "- ");
            const key_column = if (is_item) indentOf(raw) + 2 else indentOf(raw);
            if (is_item) {
                step_keys_at = key_column;
                line = std.mem.trim(u8, line[2..], &std.ascii.whitespace);
            }

            const key = yamlKey(line) orelse {
                // A line this check cannot read as `key: value` is reported, not
                // skipped. Skipping let a quoted key and a space before the
                // colon through, and both are spellings Actions treats as the
                // bare one: `'if': false` on the job skipped every step while
                // every command stayed green.
                //
                // Reported whether or not it carries a colon. Requiring one let
                // a multi-line plain scalar through, because its continuation
                // lines have none: `- run: zig fmt --check .` followed by an
                // indented `--help` read here as the bare command, while YAML
                // folds the two into `zig fmt --check . --help`, which checks
                // nothing and exits zero.
                rep.fail(
                    "{s}:{d}: `{s}` is not a key this check can read; write every line as a bare `key: value`, with no quotes, no space before the colon and no continuation line",
                    .{ path, lineno, line },
                );
                continue;
            };
            if (!keyIsAllowed(key)) {
                rep.fail(
                    "{s}:{d}: `{s}` is not a key this check knows; add it to allowed_workflow_keys after deciding what it means for the verification",
                    .{ path, lineno, key },
                );
                continue;
            }
            if (per_commit) try seen.append(gpa, .{
                .key = key,
                .value = std.mem.trim(u8, line[key.len + 1 ..], &std.ascii.whitespace),
            });
            if (!std.mem.eql(u8, key, "run")) continue;

            // Only a step's own `run` runs anything. Put under `with:` it is an
            // action input, which Actions warns about and ignores, and counting
            // it let a command leave CI while the check reported it as run.
            if (step_keys_at == null or key_column != step_keys_at.?) {
                rep.fail(
                    "{s}:{d}: this `run:` is not a step's own key, so it runs nothing",
                    .{ path, lineno },
                );
                continue;
            }

            var value = std.mem.trim(u8, line[key.len + 1 ..], &std.ascii.whitespace);
            if (value.len == 0) {
                // `defaults:` opens a mapping whose `run:` holds settings, not
                // a command. Saying "write the command on this line" names the
                // wrong cause.
                rep.fail(
                    "{s}:{d}: this `run:` opens a mapping. A command belongs on the `run:` line itself",
                    .{ path, lineno },
                );
                continue;
            }
            if (value[0] == '|' or value[0] == '>') {
                rep.fail(
                    "{s}:{d}: write the command on the `run:` line. A block scalar's lines are not keys, so nothing here can tell them from a neighbouring value",
                    .{ path, lineno },
                );
                continue;
            }
            // A quoted scalar is the same command. Leaving the quotes on made a
            // correct workflow read as running nothing.
            if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and
                value[value.len - 1] == value[0])
            {
                value = value[1 .. value.len - 1];
            }
            if (per_commit) try run_lines.append(gpa, value);
        }
    }

    // The keys that decide whether the per-commit workflow runs at all, and the
    // values it may give them.
    //
    // Closing the key set said nothing about the values. Deleting the `on:`
    // block, writing `os: []` so the matrix expands to no jobs, or naming a
    // runner that does not exist each left every `run:` line in place and every
    // verification command green while CI ran nothing. The values this
    // repository chooses are as finite as the keys, so they are enumerated too.
    for ([_]struct { key: []const u8, value: ?[]const u8 }{
        .{ .key = "on", .value = "" },
        .{ .key = "push", .value = "" },
        .{ .key = "branches", .value = "[main]" },
        .{ .key = "pull_request", .value = "" },
        .{ .key = "steps", .value = "" },
        .{ .key = "runs-on", .value = "${{ matrix.os }}" },
        .{ .key = "strategy", .value = "" },
        .{ .key = "matrix", .value = "" },
        .{ .key = "os", .value = "[ubuntu-latest, windows-latest]" },
    }) |want| {
        var found = false;
        for (seen.items) |got| {
            if (!std.mem.eql(u8, got.key, want.key)) continue;
            found = true;
            const expected = want.value orelse continue;
            if (!std.mem.eql(u8, got.value, expected)) rep.fail(
                "{s}: `{s}:` is `{s}`, and this check only knows `{s}`; decide what the new value means for the verification before changing it",
                .{ per_commit_workflow, want.key, got.value, expected },
            );
        }
        if (!found) rep.fail(
            "{s} has no `{s}:`, so the workflow does not run what the table requires",
            .{ per_commit_workflow, want.key },
        );
    }

    // Every line that reads as a row of the table. The other tables of AGENTS.md
    // have fewer cells or no command in backticks, so they fall out here.
    var table_rows: std.ArrayList(CommandRow) = .empty;
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |raw| {
        const row = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (row.len == 0 or row[0] != '|') continue;
        if (cellCount(row) < 4) continue;
        const command = backtickedSpan(cellAt(row, 1).?) orelse continue;
        const stage_cell = std.mem.trim(u8, cellAt(row, 2).?, &std.ascii.whitespace);
        const ci_cell = std.mem.trim(u8, cellAt(row, 3).?, &std.ascii.whitespace);
        try table_rows.append(gpa, .{
            .command = command,
            .stage = std.fmt.parseInt(usize, stage_cell, 10) catch null,
            .every_commit = std.mem.eql(u8, ci_cell, "全コミット"),
        });
    }

    // The build provides it, so the table requires it and the workflow runs it.
    //
    // This is the third point. The table and the workflow were compared with
    // each other and with nothing else, so weakening both at once was green:
    // deleting a row together with its step removed the requirement, and three
    // of the four commands could go that way. `build.zig` names these after the
    // steps that provide them, so dropping one means dropping the step.
    for (required_commands) |command| {
        var in_table = false;
        for (table_rows.items) |row| {
            if (!std.mem.eql(u8, row.command, command)) continue;
            if (!row.every_commit) continue;
            const needed_at = row.stage orelse continue;
            if (needed_at > stage) continue;
            in_table = true;
        }
        if (!in_table) rep.fail(
            "build.zig provides `{s}`, and no row of AGENTS.md's table marks it 全コミット at stage {d} or below",
            .{ command, stage },
        );
        var ran = false;
        for (run_lines.items) |line| {
            if (runsCommand(line, command)) ran = true;
        }
        if (!ran) rep.fail(
            "build.zig provides `{s}`, and {s} does not run it",
            .{ command, per_commit_workflow },
        );
    }

    // The table requires it, so the workflow runs it.
    var required: usize = 0;
    for (table_rows.items) |row| {
        if (!row.every_commit) continue;
        const needed_at = row.stage orelse continue;
        if (needed_at > stage) continue;
        required += 1;
        var ran = false;
        for (run_lines.items) |line| {
            if (runsCommand(line, row.command)) ran = true;
        }
        if (!ran) rep.fail(
            "AGENTS.md requires `{s}` on every commit at stage {d}, and {s} does not run it",
            .{ row.command, stage, per_commit_workflow },
        );
    }
    if (required == 0) rep.fail(
        "AGENTS.md has no command marked for every commit at stage {d}; the table was not read",
        .{stage},
    );

    // The workflow runs it, so the table requires it. This is the direction that
    // makes the first one hold without reading the cells exactly: a row this
    // check cannot see is a step with nothing behind it.
    for (run_lines.items) |line| {
        var accounted = false;
        for (table_rows.items) |row| {
            if (!runsCommand(line, row.command)) continue;
            if (!row.every_commit) continue;
            const needed_at = row.stage orelse continue;
            if (needed_at > stage) continue;
            accounted = true;
        }
        if (!accounted) rep.fail(
            "{s} runs `{s}`, and no row of AGENTS.md's table marks it 全コミット at stage {d} or below",
            .{ per_commit_workflow, line, stage },
        );
    }
}

/// The first text between backticks, which is where the table puts the command.
/// A cell may carry a note after it, as the type-check row does.
fn backtickedSpan(cell: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, cell, '`') orelse return null;
    const rest = cell[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, '`') orelse return null;
    return if (close == 0) null else rest[0..close];
}

/// Keys a workflow may use. Anything else is reported.
///
/// Four rounds of review each found a different YAML spelling that this check
/// read wrongly: `if:` written as a step's first key, a key named `run` under
/// `env:`, a block scalar whose content was really a sibling's value, a step
/// whose keys came in another order. Each was closed and the next appeared,
/// because matching strings against arbitrary YAML has no end of spellings to
/// lose to.
///
/// So the set is closed instead. An unknown key is a diagnostic, not a hole,
/// and adding one means deciding what it does to the verification. `if:` and
/// `continue-on-error:` are absent on purpose: the workflow's own comment
/// forbids them, because a verification that is skipped or forgiven has stopped
/// running.
const allowed_workflow_keys = [_][]const u8{
    // Workflow level.
    "name",               "on",           "permissions", "concurrency", "jobs",
    "push",               "pull_request", "branches",    "contents",    "group",
    "cancel-in-progress",
    // Job level.
    "runs-on",      "strategy",    "fail-fast",   "matrix",
    "steps",              "os",
    // Step level.
              "uses",        "with",        "version",
    "run",
};

/// Whether `key` is one of the allowed keys, or a job name.
///
/// A job's name is chosen by this repository, so it cannot be listed. A key at
/// the indentation of a job under `jobs:` is accepted when the workflow has
/// nothing else at that depth to confuse it with; `test` is the only one today.
fn keyIsAllowed(key: []const u8) bool {
    for (allowed_workflow_keys) |allowed| {
        if (std.mem.eql(u8, key, allowed)) return true;
    }
    for (allowed_job_names) |job| {
        if (std.mem.eql(u8, key, job)) return true;
    }
    return false;
}

/// The job names this repository's workflows define.
const allowed_job_names = [_][]const u8{"test"};

/// The key a mapping line declares, or null when the line is not `key: ...`.
///
/// Only a bare key counts, with no quotes and no space before the colon. The
/// caller reports anything else that looks like a mapping, because a quoted key
/// is the same key to Actions: returning null and letting the caller skip was
/// how `"continue-on-error": true` and `continue-on-error : true` both passed.
fn yamlKey(line: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    if (colon == 0) return null;
    const key = line[0..colon];
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return null;
    }
    return key;
}

/// Suffixes a workflow may add to a command from the table.
///
/// A list, not a shape. Accepting anything that looked like a flag accepted the
/// flags that cancel the command: `zig build test --help` exits 0 without
/// running a test, and all four commands spelled that way left a repository
/// whose source does not parse reporting every row as run. A suffix that
/// changes what the command does has to be added here deliberately.
const allowed_run_suffixes = [_][]const u8{"--summary all"};

/// Whether a workflow's `run:` value runs `command`.
fn runsCommand(line: []const u8, command: []const u8) bool {
    if (std.mem.eql(u8, line, command)) return true;
    if (!std.mem.startsWith(u8, line, command)) return false;
    if (line.len == command.len or line[command.len] != ' ') return false;
    const rest = std.mem.trimStart(u8, line[command.len..], " ");
    for (allowed_run_suffixes) |suffix| {
        if (std.mem.eql(u8, rest, suffix)) return true;
    }
    return false;
}

/// How deeply a line is indented, in columns.
///
/// `indentRun` holds what counts as indentation and why. Restating it here let
/// the two drift: this comment went on saying a tab does not count after the
/// implementation started counting one, so the file described one function's
/// behaviour two ways at once.
fn indentOf(raw: []const u8) usize {
    return indentRun(raw).cols;
}

/// The run of leading whitespace: how many columns a reader sees, and how many
/// bytes it occupies.
///
/// Both are needed. The column count decides what the indentation means, and the
/// byte count is where the line's content begins.
///
/// A space and a tab, and nothing else. YAML allows only the space in
/// indentation, and the other characters a reader might take for one were here
/// to serve checks ADR-0026 withdrew.
fn indentRun(raw: []const u8) struct { cols: usize, bytes: usize } {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == ' ') {
            cols += 1;
            continue;
        }
        // A tab advances to the next four-column stop, as CommonMark defines it.
        if (raw[i] == '\t') {
            cols += 4 - cols % 4;
            continue;
        }
        break;
    }
    return .{ .cols = cols, .bytes = i };
}

/// Removes a trailing YAML comment. A `#` opens a comment at the start of the
/// line or after whitespace, and not inside a quoted scalar.
///
/// Every line is stripped before anything is parsed out of it. A `version:`
/// written in a comment on the `uses:` line otherwise supplied the version that
/// got checked, and the real one on the next line was never read: a step
/// spelled `uses: ...setup-zig@v2  # version: 0.17.0` with `version: 0.18.1`
/// under it passed while CI installed 0.18.1.
///
/// An unbalanced quote ahead of the `#` leaves the comment in place, which only
/// restores the behaviour this replaces. Such a line is also invalid YAML, so
/// Actions rejects the workflow before the version it installs matters.
///
/// The whitespace that preceded the `#` stays in the result; the caller trims.
fn stripComment(line: []const u8) []const u8 {
    var quote: ?u8 = null;
    for (line, 0..) |c, i| {
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '#' => if (i == 0 or std.ascii.isWhitespace(line[i - 1])) return line[0..i],
            else => {},
        }
    }
    return line;
}

/// Counts non-overlapping occurrences of `needle` in `haystack`.
fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var found: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, from, needle)) |at| {
        found += 1;
        from = at + needle.len;
    }
    return found;
}

/// What one setup-zig step installs.
const StepVersion = struct {
    /// Null when this parser could not read a version for the step.
    version: ?[]const u8 = null,
    /// Another `version:` appeared under the same `with:`. The step is then
    /// treated as unreadable: which one the action takes is not this parser's
    /// to guess.
    extra: bool = false,
};

/// Collects what each setup-zig step installs, one entry per step in document
/// order.
///
/// A step is recognised by a `setup-zig@` reference anywhere on the line, so
/// that any YAML spelling of the step is seen: an item-level flow mapping and a
/// quoted `uses:` key both install a Zig that a `uses:`-prefixed match misses.
/// The `@` is what keeps a step merely *named* "prepare for setup-zig" from
/// supplying the version that gets checked.
///
/// A version counts only on a line of its own directly under the step's own
/// `with:`. Two weaker rules were tried first and both let a decoy through: any
/// `version:` on the step's line, then any `version:` indented deeper than the
/// step. The second admitted `env:` and every other key a step may carry. A
/// version is also attached to the step it was read under, rather than being
/// counted: with two steps, one step's version satisfied a count of two while
/// the other installed anything.
fn workflowZigVersions(
    gpa: std.mem.Allocator,
    body: []const u8,
    out: *std.ArrayList(StepVersion),
) !void {
    // The indentation of the item holding the step whose version is being
    // looked for, of that step's `with:`, and of that mapping's own keys. Null
    // when outside one.
    var step_indent: ?usize = null;
    var with_indent: ?usize = null;
    var input_indent: ?usize = null;
    // The indentation of the list item being read, which is the step's own.
    var item_indent: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const indent = indentOf(raw);
        var line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        line = std.mem.trim(u8, stripComment(line), &std.ascii.whitespace);
        if (line.len == 0) continue;

        const is_item = std.mem.startsWith(u8, line, "- ");
        const body_of_item = if (is_item) std.mem.trim(u8, line[2..], &std.ascii.whitespace) else line;
        // A step is the list item, and its keys may come in any order. Taking
        // the indentation of the line that carries `setup-zig@` made the step
        // end at its own `with:` whenever `name:` was written first, which is
        // the ordinary spelling: the version then read as unreadable and a
        // correct workflow was told to move a `version:` already in place.
        if (is_item) item_indent = indent;

        // A line indented no deeper than the step's own item is outside it,
        // and one no deeper than the `with:` is outside that mapping.
        if (step_indent) |si| if (indent <= si) {
            step_indent = null;
            with_indent = null;
            input_indent = null;
        };
        if (with_indent) |wi| if (indent <= wi) {
            with_indent = null;
            input_indent = null;
        };
        // A step counts whenever the line carries a setup-zig reference,
        // whatever YAML spelling holds it. Requiring the line to begin with
        // `uses:` missed an item-level flow mapping and a quoted key, either of
        // which installs a Zig this parser never sees.
        //
        // Every occurrence on the line counts, not just the first. A flow
        // sequence holding two setup-zig steps on one line read as one step,
        // and the second step's version went unchecked; counted in full, the
        // caller's step-versus-version comparison rejects the line instead.
        //
        // No version is read from this line, whatever it holds. Reading one was
        // the carrier for every decoy found so far: a `version:` in a comment,
        // then one in a `name:` value ahead of the real one, then one in a
        // `name:` value with no real one at all. Each was closed and the next
        // appeared, because the line that names the action is also the line
        // that can carry arbitrary text. So the only accepted spelling is a
        // `version:` on a line of its own below the step, and every flow
        // mapping now fails the caller's comparison with the diagnostic that
        // says exactly that.
        const refs = countOccurrences(line, "setup-zig@");
        if (refs != 0) {
            for (0..refs) |_| try out.append(gpa, .{});
            step_indent = item_indent;
            with_indent = null;
            input_indent = null;
            continue;
        }
        // Another `uses:` is another step, even nested deeper than this one.
        if (std.mem.startsWith(u8, body_of_item, "uses:")) {
            step_indent = null;
            with_indent = null;
            input_indent = null;
            continue;
        }
        if (step_indent == null) continue;
        if (std.mem.eql(u8, body_of_item, "with:")) {
            with_indent = indent;
            input_indent = null;
            continue;
        }
        if (with_indent == null) continue;
        // The inputs are the keys directly under `with:`, which is where the
        // action reads `version`. Taking any line indented deeper let a key
        // nested under an input supply the version while the action's own
        // `version` input stayed unset.
        if (input_indent == null) input_indent = indent;
        if (indent != input_indent.?) continue;
        if (std.mem.startsWith(u8, body_of_item, "version:")) {
            const scalar = std.mem.trim(u8, body_of_item["version:".len..], &std.ascii.whitespace);
            const value = std.mem.trim(u8, scalar, "\"'");
            if (value.len == 0) continue;
            const step = &out.items[out.items.len - 1];
            if (step.version == null) step.version = value else step.extra = true;
        }
    }
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
const vendored = [_]Record{
    .{
        .path = "tools/extract-r7rs-required/appendix-a.html",
        .provenance = "tools/extract-r7rs-required/SOURCE.md",
        .label = "入力の SHA-256",
    },
};

/// Directories whose generated contents are fixed as a whole by one recorded
/// hash, with the file extension that selects them.
///
/// Hashing the input alone left the output unprotected. Deleting `dynamic-wind`
/// and `call-with-current-continuation` from `base.txt` and adding a made-up
/// name kept every check green, with the input's hash untouched: the files say
/// they are generated and must not be edited by hand, and nothing enforced it.
/// They are the denominator of the stage 6 conformance matrix.
///
/// One hash covers the whole directory, so regenerating updates one value
/// instead of one per file. Each name is hashed along with its content, and
/// both are length-prefixed, which makes the encoding injective: a file added,
/// removed, renamed, or with bytes moved across a file boundary changes the
/// value.
///
/// Without the length prefixes it did not. The bytes were
/// `name "\n" body name "\n" body ...`, with no delimiter after a body, so
/// appending `lazy.txt`'s own name and content to the end of `inexact.txt` and
/// deleting `lazy.txt` left the hash untouched: every check passed with 15
/// files instead of 16 and `(scheme lazy)`'s five identifiers reassigned to
/// `(scheme inexact)`. Folding all 16 into `base.txt` passed too.
const generated = [_]struct {
    dir: []const u8,
    extension: []const u8,
    provenance: []const u8,
    label: []const u8,
    /// The row label in `provenance` carrying the total of the per-file counts.
    total_label: []const u8,
    /// The row label carrying how many files there should be. Without it, the
    /// file count and the recorded rows only had to agree with each other, so
    /// removing a file and its row together passed.
    count_label: []const u8,
}{
    .{
        .dir = "tests/r7rs-required",
        .extension = ".txt",
        .provenance = "tools/extract-r7rs-required/SOURCE.md",
        .label = "抽出結果の SHA-256",
        .total_label = "| 合計 |",
        .count_label = "| ライブラリ数 |",
    },
};

/// One hash record: what is hashed, which document records it, and the table
/// label that carries the value.
const Record = struct {
    path: []const u8,
    provenance: []const u8,
    /// Looked up verbatim, so it is spelled as the document spells it. Two
    /// records in one document need labels that are not substrings of one
    /// another, or each would find the other's value as well.
    label: []const u8,
};

fn checkVendoredHashes(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
) !void {
    for (vendored) |v| {
        const body = read(gpa, io, cwd, rep, v.path) orelse continue;
        const raw_doc = read(gpa, io, cwd, rep, v.provenance) orelse continue;
        const doc = try visibleMarkdown(gpa, rep, v.provenance, raw_doc);

        const recorded = switch (sha256InMarkdown(doc, v.label)) {
            .one => |h| h,
            .ambiguous => {
                rep.fail(
                    "{s}: the {s} row holds more than one hash; leave exactly one",
                    .{ v.provenance, v.label },
                );
                continue;
            },
            .none => {
                rep.fail("{s} records no {s} for {s}", .{ v.provenance, v.label, v.path });
                continue;
            },
        };

        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
        var hex: [digest.len * 2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;

        // Case is not part of the hash, so a record written in upper case is
        // not a modified input.
        if (!std.ascii.eqlIgnoreCase(&hex, recorded))
            rep.fail(
                "{s} is {s} but {s} records {s}",
                .{ v.path, hex[0..16], v.provenance, recorded[0..@min(16, recorded.len)] },
            );
    }
}

/// Blanks out what a reader of the rendered document does not see: HTML
/// comments and fenced code blocks.
///
/// Every reader of a table this program reads goes through the result: the hash
/// rows, the count tables, the verification command table and the ADR index. A
/// record is a thing a person is told to keep up to date, so one that only
/// exists where nobody can see it is not a record: wrapping the identifier count
/// table in `<!--` and `-->` left the rendered page without a table while every
/// check stayed green, and so did wrapping the ADR index. Blanking rather than
/// deleting keeps line and byte offsets, so diagnostics still point at the right
/// place.
///
/// An unclosed opener blanks the rest of the document, so every row below it
/// would read as absent with no check saying why; `rep` is given so that is
/// reported instead.
///
/// The opener counts wherever it appears on a line, not only at the start of
/// one. CommonMark emits an inline raw HTML comment as it stands and a browser
/// hides it exactly as it hides a block one, so a row carrying a commented value
/// before a visible one showed the visible one to a reader and handed the hidden
/// one to a check. Deciding instead whether the marker sits
/// inside a code span needs an inline parser this program does not have: two
/// attempts failed, one letting a single unpaired backtick hide a comment and the
/// other reading a double-backtick span as an empty span plus an opener. So there
/// is no exception for code spans, and the cost is that Markdown prose in this
/// repository cannot carry the literal marker -- an unclosed one is reported, so
/// the cost is paid in a diagnostic rather than in silence.
fn visibleMarkdown(
    gpa: std.mem.Allocator,
    rep: *Reporter,
    path: []const u8,
    doc: []const u8,
) ![]u8 {
    const out = try gpa.dupe(u8, doc);
    var fence: ?struct { ch: u8, len: usize, indent: usize } = null;
    var i: usize = 0;
    while (i < out.len) {
        // A line at a time, so a fence is recognised where it opens.
        const end = std.mem.indexOfScalarPos(u8, out, i, '\n') orelse out.len;
        const line = out[i..end];
        const run = indentRun(line);

        var blank_line = false;
        if (fenceRun(line[run.bytes..])) |f| {
            if (fence) |open| {
                if (f.bare and f.ch == open.ch and f.len >= open.len) fence = null;
            } else {
                fence = .{ .ch = f.ch, .len = f.len, .indent = run.cols };
            }
            blank_line = true;
        } else if (fence) |open| {
            // Inside the fence only while indented at least as far as it. An
            // indented code block that shows a fence is not a fence, so a row at
            // column zero between two such lines is content a reader sees, and
            // blanking it hid a count table from the check that reads it.
            blank_line = run.cols >= open.indent;
        }
        if (blank_line) blankExceptNewlines(line);
        i = end + 1;
    }

    // HTML comments span lines, so they are blanked over the whole document.
    // Before the indented lines are blanked, not after: blanking first turned an
    // opener indented one to three spaces into spaces, so it was never found and
    // the table it hid from the reader was read as present.
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, out, from, "<!--")) |open| {
        const close = std.mem.indexOfPos(u8, out, open, "-->") orelse {
            rep.fail(
                "{s}:{d}: this HTML comment is never closed, which would hide every record below it",
                .{ path, lineOf(out, open) },
            );
            // Past this opener rather than out of the loop. Stopping left every
            // later comment unblanked, so one unclosed marker turned the records
            // a closed comment hides back into records that are read.
            from = open + 4;
            continue;
        };
        blankExceptNewlines(out[open .. close + 3]);
        from = close + 3;
    }

    blankIndentedCode(out);
    return out;
}

/// The 1-based line number of `offset`.
fn lineOf(doc: []const u8, offset: usize) usize {
    var n: usize = 1;
    for (doc[0..@min(offset, doc.len)]) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// The number of cells a table row declares, counting an escaped pipe as text.
///
/// GFM makes the pipes that open and close a row optional, so they are stripped
/// before the rest are counted as separators. Counting the pipes and subtracting
/// one instead was right only for a row that had both. The count decides whether
/// a row of AGENTS.md's table carries the four cells this program reads.
///
/// `line` is expected trimmed, so a closing pipe is the last byte.
fn cellCount(line: []const u8) usize {
    var body = line;
    if (body.len != 0 and body[0] == '|') body = body[1..];

    var cells: usize = 1;
    var closed = false;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\') {
            i += 1; // the escaped character, pipe or not
            closed = false;
            continue;
        }
        if (body[i] != '|') {
            closed = false;
            continue;
        }
        cells += 1;
        closed = i + 1 == body.len;
    }
    return if (closed) cells - 1 else cells;
}

/// The cell at `index` of a table row, counting from zero, untrimmed.
///
/// The split follows `cellCount`: the opening and closing pipes are optional and
/// an escaped pipe is text, so reading cells by `splitScalar(u8, row, '|')` gave
/// a different answer from the count on the same row.
fn cellAt(row: []const u8, index: usize) ?[]const u8 {
    var body = row;
    if (body.len != 0 and body[0] == '|') body = body[1..];

    var at: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\') {
            i += 1; // the escaped character, pipe or not
            continue;
        }
        if (body[i] != '|') continue;
        if (at == index) return body[start..i];
        at += 1;
        start = i + 1;
        // A pipe at the end closes the row, so there is no cell after it.
        if (i + 1 == body.len) return null;
    }
    return if (at == index) body[start..] else null;
}

test "cellCount: the pipes that open and close a row are optional" {
    try std.testing.expectEqual(@as(usize, 2), cellCount("| a | b |"));
    try std.testing.expectEqual(@as(usize, 2), cellCount("| a | b"));
    try std.testing.expectEqual(@as(usize, 2), cellCount("a | b"));
    try std.testing.expectEqual(@as(usize, 1), cellCount("| a |"));
    // The defect this pins: a row that drops its closing pipe has as many cells
    // as one that keeps it, so the count cannot be read off the pipes alone.
    try std.testing.expectEqual(@as(usize, 3), cellCount("| a | b | c"));
    // An escaped pipe is the cell's text.
    try std.testing.expectEqual(@as(usize, 1), cellCount("| a \\| b |"));
}

test "cellAt: reads the same cells cellCount counts" {
    try std.testing.expectEqualStrings(" a ", cellAt("| a | b |", 0).?);
    try std.testing.expectEqualStrings(" b ", cellAt("| a | b |", 1).?);
    try std.testing.expectEqual(@as(?[]const u8, null), cellAt("| a | b |", 2));
    // The opening and closing pipes are optional, as in cellCount.
    try std.testing.expectEqualStrings("a ", cellAt("a | b", 0).?);
    try std.testing.expectEqualStrings(" b", cellAt("a | b", 1).?);
    try std.testing.expectEqualStrings(" b", cellAt("| a | b", 1).?);
    // An escaped pipe stays inside its cell.
    try std.testing.expectEqualStrings(" a \\| b ", cellAt("| a \\| b |", 0).?);
}

/// Blanks every indented line, so that only column zero carries a record.
///
/// What four spaces mean depends on the block that contains them. At the top
/// level they open a code block; inside a list item they continue the item, or
/// open a nested list, and render as text. CommonMark: "The position of the
/// text after the list marker determines how much indentation is needed in
/// subsequent blocks in the list item." Two attempts to tell the cases apart
/// both failed in one direction or the other -- blanking all of them hid a
/// visible note, blanking only those after a blank line read a nested decoy as
/// a status.
///
/// So indentation is not interpreted at all. A record is a thing a person is
/// told to keep up to date, and every one this repository keeps -- the hash
/// rows, the count tables, the command table, an ADR's metadata and index row
/// -- sits at column zero. A line that does not is not read, whatever it would
/// render as. The cost is that a record cannot be nested inside a list.
fn blankIndentedCode(out: []u8) void {
    var line_start: usize = 0;
    while (line_start < out.len) {
        const line_end = std.mem.indexOfScalarPos(u8, out, line_start, '\n') orelse out.len;
        const line = out[line_start..line_end];
        if (indentOf(line) != 0 and std.mem.trim(u8, line, &std.ascii.whitespace).len != 0)
            blankExceptNewlines(line);
        line_start = line_end + 1;
    }
}

fn blankExceptNewlines(span: []u8) void {
    for (span) |*c| {
        if (c.* != '\n' and c.* != '\r') c.* = ' ';
    }
}

/// What a Markdown document records as the SHA-256 of a vendored input.
const RecordedHash = union(enum) {
    /// One value appears on the lines naming SHA-256.
    one: []const u8,
    none,
    /// Several differing values appear, so which one is the record cannot be
    /// decided from the document.
    ambiguous,
};

/// Finds the SHA-256 a Markdown document records under `label`.
///
/// Every line holding `label` is scanned, and every 64-hex run on each one is
/// collected, rather than returning the first run on the first such line.
/// Returning the first let a decoy supply the value. Putting a second 64-hex
/// run inside an HTML comment, ahead of the real one on the same table row,
/// left the rendered table showing the real hash while this function returned
/// the hidden one: a swapped input compared green, and the substitution was
/// invisible to anyone reading the document. A second row naming an older hash
/// did the same.
fn sha256InMarkdown(doc: []const u8, label: []const u8) RecordedHash {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, label) == null) continue;
        var i: usize = 0;
        while (i + 64 <= line.len) : (i += 1) {
            const candidate = line[i .. i + 64];
            var all_hex = true;
            for (candidate) |c| {
                if (!std.ascii.isHex(c)) all_hex = false;
            }
            if (!all_hex) continue;
            if (found) |first| {
                if (!std.ascii.eqlIgnoreCase(first, candidate)) return .ambiguous;
            } else found = candidate;
        }
    }
    return if (found) |h| .{ .one = h } else .none;
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

/// Checks one hash over all the generated files in a directory.
///
/// The diagnostic prints the whole computed hash, not a prefix: regenerating the
/// files means pasting that value into the provenance document, and a prefix
/// would send the reader to compute it again by hand.
fn checkGeneratedHashes(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    ignore: []const u8,
) !void {
    for (generated) |g| {
        try checkNothingElseInDir(io, cwd, rep, ignore, g.dir, g.extension);
        var files: std.ArrayList([]const u8) = .empty;
        try collectFiles(gpa, io, cwd, ignore, g.dir, g.extension, &files, .flat);
        if (files.items.len == 0) {
            rep.fail("{s} holds no {s} file, so the generated lists are unchecked", .{ g.dir, g.extension });
            continue;
        }
        // Directory order is whatever the filesystem returns, so it is sorted:
        // the same contents must give the same hash on every host.
        std.mem.sort([]const u8, files.items, {}, lessThanPath);

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var unread = false;
        for (files.items) |path| {
            const body = read(gpa, io, cwd, rep, path) orelse {
                unread = true;
                continue;
            };
            hashLengthPrefixed(&hasher, path);
            hashLengthPrefixed(&hasher, body);
        }
        // A file this program could not read is already reported; comparing a
        // hash computed over the rest would add a second, misleading problem.
        if (unread) continue;

        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        hasher.final(&digest);
        var hex: [digest.len * 2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;

        const raw_doc = read(gpa, io, cwd, rep, g.provenance) orelse continue;
        const doc = try visibleMarkdown(gpa, rep, g.provenance, raw_doc);
        switch (sha256InMarkdown(doc, g.label)) {
            .one => |recorded| if (!std.ascii.eqlIgnoreCase(&hex, recorded)) rep.fail(
                "{s}/*{s} hashes to {s} but {s} records {s}",
                .{ g.dir, g.extension, &hex, g.provenance, recorded },
            ),
            .ambiguous => rep.fail(
                "{s}: the {s} row holds more than one hash; leave exactly one",
                .{ g.provenance, g.label },
            ),
            .none => rep.fail(
                "{s} records no {s}; {s}/*{s} hashes to {s}",
                .{ g.provenance, g.label, g.dir, g.extension, &hex },
            ),
        }
    }
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Feeds `bytes` to `hasher` behind its length, so that a sequence of such
/// calls has exactly one reading. Concatenation alone does not: moving the
/// boundary between two pieces leaves the same bytes.
fn hashLengthPrefixed(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    hasher.update(&len);
    hasher.update(bytes);
}

/// Whether the source declares at least one `test` block at container level.
///
/// Lexed, not searched: the word "test" appears in paths, comments and strings
/// all over this repository, and a raw search would accept a file that declares
/// none.
fn hasTestBlock(source: [:0]const u8) bool {
    var tok = std.zig.Tokenizer.init(source);
    var depth: usize = 0;
    while (true) {
        const t = tok.next();
        switch (t.tag) {
            .eof => return false,
            .l_brace => depth += 1,
            .r_brace => if (depth > 0) {
                depth -= 1;
            },
            .keyword_test => if (depth == 0) return true,
            else => {},
        }
    }
}

/// Checks the identifier counts a provenance document records against the
/// generated files.
///
/// The hash says the files changed; it does not say the numbers written beside
/// them still hold. Those numbers are updated by hand -- step 5 of the
/// re-extraction procedure -- and nothing compared them, so a library whose
/// export list stopped parsing could read as 1 identifier in the document and 0
/// in the file. The stage 6 conformance matrix takes these files as its
/// denominator, where that gap reads as full conformance.
fn checkRecordedCounts(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    ignore: []const u8,
) !void {
    for (generated) |g| {
        const raw_doc = read(gpa, io, cwd, rep, g.provenance) orelse continue;
        const doc = try visibleMarkdown(gpa, rep, g.provenance, raw_doc);
        var files: std.ArrayList([]const u8) = .empty;
        try collectFiles(gpa, io, cwd, ignore, g.dir, g.extension, &files, .flat);

        var total: usize = 0;
        for (files.items) |path| {
            const body = read(gpa, io, cwd, rep, path) orelse continue;
            const count = identifierCount(body);
            total += count;

            const stem = std.fs.path.stem(path);
            const label = try std.fmt.allocPrint(gpa, "`(scheme {s})`", .{stem});
            switch (integerAfter(doc, label)) {
                .one => |recorded| if (recorded != count) rep.fail(
                    "{s} holds {d} identifier(s) but {s} records {d}",
                    .{ path, count, g.provenance, recorded },
                ),
                .none => rep.fail(
                    "{s} records no identifier count for {s}",
                    .{ g.provenance, label },
                ),
                .ambiguous => rep.fail(
                    "{s} records more than one count for {s}; leave exactly one",
                    .{ g.provenance, label },
                ),
            }
        }

        // The other direction. Walking the files alone left a recorded row
        // with no file behind it unexamined: deleting `lazy.txt`, pasting the
        // hash the diagnostic reports and correcting the total passed every
        // check, with the row still in the table, the prose still saying 16
        // files, and 15 on disk. The stage 6 matrix takes this directory as its
        // denominator, so that library's identifiers leave the denominator
        // instead of appearing as unimplemented.
        var rows: usize = 0;
        var lines = std.mem.splitScalar(u8, doc, '\n');
        while (lines.next()) |raw| {
            const row = std.mem.trim(u8, raw, &std.ascii.whitespace);
            if (row.len == 0 or row[0] != '|') continue;
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, row, from, "`(scheme ")) |at| {
                const name_start = at + "`(scheme ".len;
                const close = std.mem.indexOfPos(u8, row, name_start, ")`") orelse break;
                from = close + 2;
                const name = row[name_start..close];
                rows += 1;
                const want = try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ g.dir, name, g.extension });
                if (!pathIn(files.items, want)) rep.fail(
                    "{s} records `(scheme {s})` but {s} does not exist",
                    .{ g.provenance, name, want },
                );
            }
        }
        switch (integerAfter(doc, g.count_label)) {
            .one => |recorded| if (recorded != files.items.len) rep.fail(
                "{s} records {d} librar(ies) but {s} holds {d} *{s} file(s)",
                .{ g.provenance, recorded, g.dir, files.items.len, g.extension },
            ),
            .none => rep.fail("{s} records no {s}", .{ g.provenance, g.count_label }),
            .ambiguous => rep.fail(
                "{s} records more than one {s}; leave exactly one",
                .{ g.provenance, g.count_label },
            ),
        }
        if (rows != files.items.len) rep.fail(
            "{s} records {d} librar(ies) but {s} holds {d} *{s} file(s)",
            .{ g.provenance, rows, g.dir, files.items.len, g.extension },
        );

        switch (integerAfter(doc, g.total_label)) {
            .one => |recorded| if (recorded != total) rep.fail(
                "{s}/*{s} hold {d} identifier(s) in all but {s} records {d}",
                .{ g.dir, g.extension, total, g.provenance, recorded },
            ),
            .none => rep.fail("{s} records no {s}", .{ g.provenance, g.total_label }),
            .ambiguous => rep.fail(
                "{s} records more than one {s}; leave exactly one",
                .{ g.provenance, g.total_label },
            ),
        }
    }
}

/// Counts the identifier lines of a generated list: the lines that are neither
/// blank nor a `;` comment.
fn identifierCount(body: []const u8) usize {
    var found: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == ';') continue;
        found += 1;
    }
    return found;
}

/// What a document records as a count under `label`.
const RecordedCount = union(enum) {
    one: usize,
    none,
    /// The label appears in several rows with differing values.
    ambiguous,
};

/// The integer recorded beside `label` in a Markdown table row.
///
/// Only lines that open a table row are considered. Searching the whole
/// document found the label in prose first and read whatever number happened
/// to follow it: the sentence explaining the hash encoding names two
/// libraries, and one of them is followed by its own count in words. Every
/// matching row is read and the values must agree, for the same reason
/// `sha256InMarkdown` refuses to pick one of several.
fn integerAfter(doc: []const u8, label: []const u8) RecordedCount {
    var found: ?usize = null;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] != '|') continue;
        const at = std.mem.indexOf(u8, line, label) orelse continue;

        var i = at + label.len;
        while (i < line.len and !std.ascii.isDigit(line[i])) : (i += 1) {}
        const digits_at = i;
        while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
        if (i == digits_at) continue;
        // Parsed rather than accumulated by hand: accumulating overflowed on a
        // long run of digits and panicked, losing every diagnostic gathered so
        // far. A value that does not parse is not skipped either, or a record
        // too large to be a count would read as no record at all.
        const value = std.fmt.parseInt(usize, line[digits_at..i], 10) catch return .ambiguous;

        if (found) |first| {
            if (first != value) return .ambiguous;
        } else found = value;
    }
    return if (found) |v| .{ .one = v } else .none;
}

/// Reports anything in `dir` that the recorded hash does not cover.
///
/// `collectFiles` in flat mode returns the directory's own files with the right
/// extension, so a subdirectory or another extension would sit beside the
/// generated lists uncovered. The provenance document claims the record fixes
/// the directory, so the directory holds nothing else.
///
/// Nothing else that is part of the repository, that is. An entry `.gitignore`
/// ignores is left out, because a correct repository should not go red when
/// macOS writes a `.DS_Store` or an editor leaves a `base.txt~`.
///
/// The ignore test comes before the extension test, not after. Applying it only
/// to entries whose extension did not match left `._base.txt` -- what macOS
/// writes beside a tracked file, and what `.gitignore` names -- passing as a
/// generated list: it entered the hash and the identifier counts, and a correct
/// repository reported three problems. The same order is why `collectFiles`
/// takes the ignore set too, so the file this check accepts and the files the
/// hash covers are the same set.
fn checkNothingElseInDir(
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    ignore: []const u8,
    path: []const u8,
    extension: []const u8,
) !void {
    var dir = cwd.openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (isIgnored(ignore, entry.name, entry.kind == .directory)) continue;
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, extension)) continue;
        rep.fail(
            "{s}/{s} is not a generated *{s} file, so the recorded hash does not cover it",
            .{ path, entry.name, extension },
        );
    }
}

/// Whether `.gitignore` ignores an entry of this name.
///
/// Only the pattern shapes this repository writes are understood: an exact
/// name, a trailing `/` for a directory, and a single leading or trailing `*`.
/// A shape outside that set never matches, so an unrecognised pattern leaves
/// the check as strict as it was. Erring that way means a new pattern shape
/// shows up as a check failure to be looked at, not as a silent hole in what
/// the recorded hash covers.
///
/// A pattern that would match every name is one of the shapes left out. A bare
/// `*` turned every check that consults this function off at once, which is a
/// larger hole than any single name could open.
///
/// Negations are among the shapes left out: a `!` line is skipped, which keeps
/// a pattern it re-includes ignored. The only negation here re-includes
/// `.env.example`, which belongs in no generated directory.
fn isIgnored(gitignore: []const u8, name: []const u8, is_dir: bool) bool {
    var lines = std.mem.splitScalar(u8, gitignore, '\n');
    while (lines.next()) |raw| {
        var pattern = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (pattern.len == 0 or pattern[0] == '#' or pattern[0] == '!') continue;

        // A trailing slash restricts the pattern to directories.
        if (pattern[pattern.len - 1] == '/') {
            if (!is_dir) continue;
            pattern = pattern[0 .. pattern.len - 1];
            if (pattern.len == 0) continue;
        }

        // A path-shaped pattern is anchored, and this compares one entry name.
        if (std.mem.indexOfScalar(u8, pattern, '/') != null) continue;

        const stars = countOccurrences(pattern, "*");
        if (stars == 0) {
            if (std.mem.eql(u8, pattern, name)) return true;
        } else if (stars == 1 and pattern[0] == '*') {
            const suffix = pattern[1..];
            if (suffix.len != 0 and std.mem.endsWith(u8, name, suffix)) return true;
        } else if (stars == 1 and pattern[pattern.len - 1] == '*') {
            const prefix = pattern[0 .. pattern.len - 1];
            if (prefix.len != 0 and std.mem.startsWith(u8, name, prefix)) return true;
        }
    }
    return false;
}

fn checkSources(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    ignore: []const u8,
    roots: []const []const u8,
    excluded: []const []const u8,
) !void {
    var files: std.ArrayList([]const u8) = .empty;
    // tools/ holds most of stage 0's logic and is verification code itself, so
    // it is subject to the same reachability and refAllDecls rules as src/.
    for ([_][]const u8{ "src", "tools" }) |root|
        try collectFiles(gpa, io, cwd, ignore, root, ".zig", &files, .recursive);

    var reachable: std.StringHashMapUnmanaged(void) = .empty;
    for (roots) |r| {
        if (!pathIn(files.items, r)) rep.fail("test root {s} does not exist", .{r});
        try reachable.put(gpa, r, {});
    }
    // A root with no test block of its own still contributes a run step, so
    // build.zig's count of run steps would be satisfied while that module runs
    // nothing. The count says a test was launched; this says there was a test
    // to launch.
    for (roots) |r| {
        const body = read(gpa, io, cwd, rep, r) orelse continue;
        if (!hasTestBlock(body))
            rep.fail("test root {s} declares no test, so its run step executes nothing", .{r});
    }
    for (excluded) |e| {
        if (!pathIn(files.items, e)) rep.fail("excluded file {s} does not exist", .{e});
    }

    // Every file is read once, before either loop below. Reading inside the
    // fixpoint loop reported one unreadable file as several problems, because
    // that loop revisits every reachable path on each pass. An exclusion keeps
    // a file from being a test target; it does not make the file unreadable, so
    // a read failure is reported whether or not the path is excluded.
    // The sentinel is what lets zigImports hand a body to std.zig.Tokenizer.
    var bodies: std.StringHashMapUnmanaged([:0]const u8) = .empty;
    for (files.items) |path| {
        if (read(gpa, io, cwd, rep, path)) |body| try bodies.put(gpa, path, body);
    }

    // Repeat until nothing new is reached: imports form a DAG of unknown depth.
    var changed = true;
    while (changed) {
        changed = false;
        for (files.items) |path| {
            if (!reachable.contains(path)) continue;
            const body = bodies.get(path) orelse continue;
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

        const body = bodies.get(path) orelse continue;
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
/// test block passes the check and has no effect. Nor can it prove the qualifier
/// resolves to std.testing: a local `const fake = struct { fn refAllDecls(_:
/// type) void {} };` referenced as `fake.refAllDecls(@This())` passes. Both
/// limits are recorded as implementation-time questions in
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
// 4. Markdown: relative links resolve.
//
// Links inside fenced code blocks are skipped: docs/adr/README.md shows a
// deprecation template whose links are placeholders by design. An unclosed
// fence would take the rest of the file with them, so it is reported.
// ---------------------------------------------------------------------------

fn checkMarkdown(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    ignore: []const u8,
) !void {
    // Walk the whole repository: a fixed directory list left .agents/,
    // .claude/ and .github/ unchecked, which is a quarter of the Markdown.
    var files: std.ArrayList([]const u8) = .empty;
    try collectFiles(gpa, io, cwd, ignore, ".", ".md", &files, .recursive);

    for (files.items) |path| {
        const body = read(gpa, io, cwd, rep, path) orelse continue;
        const dir = std.fs.path.dirnamePosix(path) orelse ".";

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
            const trimmed = line[indentRun(line).bytes..];

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

            if (referenceDefinition(trimmed)) |target|
                try checkLinkTarget(gpa, io, cwd, rep, path, lineno, dir, target);
            try checkLinksOnLine(gpa, io, cwd, rep, path, lineno, dir, line);
        }
        // Reported because the link check stops at an open fence. ADR-0026 keeps
        // the reachability of relative links; leaving a fence unclosed took the
        // rest of the file out of that check and said nothing, which is the one
        // thing the first of its three facts forbids.
        if (fence) |open| rep.fail(
            "{s}:{d}: this code fence of {d} '{c}' is never closed, so the links below it are not checked",
            .{ path, fence_line, open.len, open.ch },
        );
    }
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
        try checkLinkTarget(gpa, io, cwd, rep, path, lineno, dir, dest.target);
    }
}

/// The destination of a reference link definition, `[label]: dest`.
///
/// `checkLinksOnLine` looks for `](`, which a definition does not carry, so a
/// link written in the reference form had its destination read by nobody: the
/// rendered page pointed at a file that is not there and nothing said so.
fn referenceDefinition(line: []const u8) ?[]const u8 {
    if (line.len == 0 or line[0] != '[') return null;
    const close = std.mem.indexOf(u8, line, "]:") orelse return null;
    var rest = std.mem.trimStart(u8, line[close + 2 ..], " \t");
    // A title may follow the destination on the same line.
    if (std.mem.indexOfAny(u8, rest, " \t")) |space| rest = rest[0..space];
    if (rest.len >= 2 and rest[0] == '<' and rest[rest.len - 1] == '>')
        rest = rest[1 .. rest.len - 1];
    return if (rest.len == 0) null else rest;
}

/// Reports a relative link whose target is not a file in the repository.
fn checkLinkTarget(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    path: []const u8,
    lineno: usize,
    dir: []const u8,
    target: []const u8,
) !void {
    if (target.len == 0) return;
    // Any URI scheme, matched case-insensitively: RFC 3986 makes schemes
    // case-insensitive, and a bare "http" prefix would also skip the
    // relative path http-guide.md.
    if (hasUriScheme(target)) return;
    if (target[0] == '#') return;
    const file_part = std.mem.sliceTo(target, '#');
    if (file_part.len == 0) return;
    // Reject characters a path cannot hold before touching the file system:
    // std.Io.Dir.access panics on Windows for an invalid name rather than
    // returning an error, which would turn one bad link into a crash that
    // loses every other diagnostic.
    if (std.mem.indexOfAny(u8, file_part, "<>:\"|?*") != null or
        std.mem.indexOfScalar(u8, file_part, 0) != null)
    {
        rep.fail("{s}:{d}: link target {s} is not a usable path", .{ path, lineno, target });
        return;
    }
    const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, file_part });
    cwd.access(io, joined, .{}) catch {
        rep.fail("{s}:{d}: link target {s} does not exist", .{ path, lineno, target });
    };
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
/// Collects the files under `root` whose name ends in `suffix`.
///
/// Entries `.gitignore` names are left out, files and directories alike. They
/// are not tracked, so they are not what the checks are about: a scratch note
/// under an ignored directory was failing the Markdown checks, and an
/// AppleDouble file macOS writes beside a tracked one was entering the
/// generated lists' hash. Reading the ignore set here keeps the set of files
/// every check sees the same, and keeps `.gitignore` the one place that
/// declares it.
fn collectFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    ignore: []const u8,
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
        if (isIgnored(ignore, entry.name, entry.kind == .directory)) continue;
        switch (entry.kind) {
            .file => if (std.mem.endsWith(u8, entry.name, suffix)) try out.append(gpa, path),
            .directory => {
                if (walk == .flat) continue;
                var skip = false;
                for (skipped_dirs) |s| if (std.mem.eql(u8, entry.name, s)) {
                    skip = true;
                };
                if (!skip) try collectFiles(gpa, io, cwd, ignore, path, suffix, out, walk);
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

test "workflowZigVersions: every setup-zig step gets its own entry" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(StepVersion) = .empty;
    defer out.deinit(gpa);
    try workflowZigVersions(gpa,
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
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("0.17.0", out.items[0].version.?);
    try std.testing.expectEqualStrings("0.18.0", out.items[1].version.?);
}

test "workflowZigVersions: only a version under the step's own with: counts" {
    // The defect this pins: any line indented deeper than the step was
    // accepted, so `env:` and every other key a step carries could supply
    // the version that got checked.
    const gpa = std.testing.allocator;
    var out: std.ArrayList(StepVersion) = .empty;
    defer out.deinit(gpa);
    try workflowZigVersions(gpa,
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc
        \\        with: { version: 0.18.1 }
        \\        env:
        \\          version: 0.17.0
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(out.items[0].version == null);
}

test "workflowZigVersions: each step keeps its own version" {
    // The defect this pins: versions were collected into one flat list and
    // compared by count, so one step could supply the entry that satisfied
    // the other while installing anything.
    const gpa = std.testing.allocator;
    var out: std.ArrayList(StepVersion) = .empty;
    defer out.deinit(gpa);
    try workflowZigVersions(gpa,
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc
        \\        with: { version: 0.18.1 }
        \\      - uses: mlugg/setup-zig@abc
        \\        with:
        \\          version: 0.17.0
    , &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(out.items[0].version == null);
    try std.testing.expectEqualStrings("0.17.0", out.items[1].version.?);
}

test "workflowZigVersions: two versions under one with: make the step unreadable" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(StepVersion) = .empty;
    defer out.deinit(gpa);
    try workflowZigVersions(gpa,
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc
        \\        with:
        \\          version: 0.17.0
        \\          version: 0.18.1
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(out.items[0].extra);
}

test "workflowZigVersions: a step merely named after setup-zig supplies nothing" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(StepVersion) = .empty;
    defer out.deinit(gpa);
    try workflowZigVersions(gpa,
        \\    steps:
        \\      - name: prepare for setup-zig
        \\        uses: actions/checkout@abc
        \\        with:
        \\          version: 0.18.0
    , &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "workflowZigVersions: comments and decoys on the step line supply nothing" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(StepVersion) = .empty;
    defer out.deinit(gpa);
    // A comment carrying a version, and the real one below it.
    try workflowZigVersions(gpa,
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc  # version: 0.17.0
        \\        with:
        \\          version: 0.18.0
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("0.18.0", out.items[0].version.?);

    // A flow mapping, which keeps the version off a line of its own.
    out.clearRetainingCapacity();
    try workflowZigVersions(gpa,
        \\    steps:
        \\      - { uses: "mlugg/setup-zig@abc", name: "pin version: 0.17.0" }
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(out.items[0].version == null);
}

test "workflowZigVersions: a version outside the step is not the step's" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(StepVersion) = .empty;
    defer out.deinit(gpa);
    try workflowZigVersions(gpa,
        \\jobs:
        \\  fuzz:
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc
        \\        with: { version: 0.18.1 }
        \\  matrix-job:
        \\    strategy:
        \\      matrix:
        \\        version: 0.17.0
        \\    steps:
        \\      - run: echo hi
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(out.items[0].version == null);
}

test "workflowZigVersions: a name holding version: does not shadow the real one" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(StepVersion) = .empty;
    defer out.deinit(gpa);
    try workflowZigVersions(gpa,
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc
        \\        name: "install the pinned version: see .zigversion"
        \\        with:
        \\          version: 0.17.0
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("0.17.0", out.items[0].version.?);
}

test "visibleMarkdown: a record hidden from the reader is not a record" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var rep: Reporter = .{ .w = &sink.writer };
    const doc =
        \\| 合計 | 557 |
        \\<!-- | 合計 | 99 | -->
        \\```
        \\| 合計 | 42 |
        \\```
        \\    | 合計 | 7 |
    ;
    const seen = try visibleMarkdown(gpa, &rep, "t.md", doc);
    defer gpa.free(seen);
    // The visible row survives; the commented, fenced and indented ones do not.
    switch (integerAfter(seen, "| 合計 |")) {
        .one => |v| try std.testing.expectEqual(@as(usize, 557), v),
        else => return error.TestExpectedOne,
    }
    // Line structure is kept so diagnostics still line up.
    try std.testing.expectEqual(doc.len, seen.len);
    try std.testing.expectEqual(@as(usize, 0), rep.count);
}

test "visibleMarkdown: a comment in a code span is reported, not obeyed" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var rep: Reporter = .{ .w = &sink.writer };
    // There is no exception for code spans, so prose carrying the marker is an
    // unclosed comment. Reporting it is what tells the author to write the
    // sentence another way, instead of the rest of the document going quiet.
    const doc =
        \\HTML コメントは `<!--` で開く。
        \\| 合計 | 557 |
    ;
    const seen = try visibleMarkdown(gpa, &rep, "t.md", doc);
    defer gpa.free(seen);
    try std.testing.expectEqual(@as(usize, 1), rep.count);
    switch (integerAfter(seen, "| 合計 |")) {
        .one => |v| try std.testing.expectEqual(@as(usize, 557), v),
        else => return error.TestExpectedOne,
    }
}

test "visibleMarkdown: a comment part way along a line hides what it wraps" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var rep: Reporter = .{ .w = &sink.writer };
    // A browser hides an inline comment as it hides a block one, so a reader
    // sees 99 here. Reading 16 took a value nobody could see as the record.
    const doc = "| 合計 | <!--16--> 99 |";
    const seen = try visibleMarkdown(gpa, &rep, "t.md", doc);
    defer gpa.free(seen);
    switch (integerAfter(seen, "| 合計 |")) {
        .one => |v| try std.testing.expectEqual(@as(usize, 99), v),
        else => return error.TestExpectedOne,
    }
    try std.testing.expectEqual(@as(usize, 0), rep.count);
}

test "visibleMarkdown: an opener indented under four spaces still opens" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var rep: Reporter = .{ .w = &sink.writer };
    // Blanking the indented lines first turned this opener into spaces, so the
    // row it hides from the reader was read as present.
    const doc =
        \\  <!--
        \\| 合計 | 557 |
        \\-->
    ;
    const seen = try visibleMarkdown(gpa, &rep, "t.md", doc);
    defer gpa.free(seen);
    try std.testing.expectEqual(RecordedCount.none, integerAfter(seen, "| 合計 |"));
    try std.testing.expectEqual(@as(usize, 0), rep.count);
}

test "visibleMarkdown: a record shallower than an indented fence is kept" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var rep: Reporter = .{ .w = &sink.writer };
    // The fence is an indented code block's content rather than a fence, so the
    // row between the two renders as a row. Blanking it here left nobody
    // reading a table the page shows.
    const doc =
        \\    ```
        \\| 合計 | 557 |
        \\    ```
    ;
    const seen = try visibleMarkdown(gpa, &rep, "t.md", doc);
    defer gpa.free(seen);
    switch (integerAfter(seen, "| 合計 |")) {
        .one => |v| try std.testing.expectEqual(@as(usize, 557), v),
        else => return error.TestExpectedOne,
    }
    try std.testing.expectEqual(@as(usize, 0), rep.count);
}

test "visibleMarkdown: an unclosed comment is reported, not obeyed" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var rep: Reporter = .{ .w = &sink.writer };
    const doc =
        \\<!-- opened and never closed
        \\| 合計 | 557 |
    ;
    const seen = try visibleMarkdown(gpa, &rep, "t.md", doc);
    defer gpa.free(seen);
    try std.testing.expectEqual(@as(usize, 1), rep.count);
    // The rest of the document is left readable, so the records below are still
    // compared rather than silently absent.
    switch (integerAfter(seen, "| 合計 |")) {
        .one => |v| try std.testing.expectEqual(@as(usize, 557), v),
        else => return error.TestExpectedOne,
    }
}

test "adrRow: the row is found by the link that opens it" {
    const index =
        \\| [0005](0005-old.md) | ... | 非推奨([0019](0019-new.md)に置き換え) | 2026-10-04 |
        \\| [0019](0019-new.md) | ... | 採用 | 2026-10-05 |
    ;
    // A 非推奨 row also links to its replacement, so matching any link on
    // the row would find two rows for 0019.
    const row = adrRow(index, "0019-new.md").one;
    try std.testing.expect(std.mem.indexOf(u8, row, "採用") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "非推奨") == null);
    try std.testing.expect(adrRow(index, "0021-absent.md") == .none);
}

test "adrRow: a stale row left below the real one is reported" {
    // The defect this pins: the first match won, so an outdated row showed
    // a second status for the same ADR and nothing read it.
    const index =
        \\| [0017](0017-a.md) | ... | 非推奨([0023](0023-b.md)に置き換え) | 2026-10-04 |
        \\| [0017](0017-a.md) | 古い行 | 採用 | 2026-10-04 |
    ;
    switch (adrRow(index, "0017-a.md")) {
        .many => |n| try std.testing.expectEqual(@as(usize, 2), n),
        else => return error.TestExpectedMany,
    }
}

test "runsCommand: extra text is accepted only as a flag" {
    try std.testing.expect(runsCommand("zig build", "zig build"));
    try std.testing.expect(runsCommand("zig build test --summary all", "zig build test"));
    // The test line must not stand in for the plain build row.
    try std.testing.expect(!runsCommand("zig build test --summary all", "zig build"));
    try std.testing.expect(!runsCommand("zig build check-docs", "zig build check"));
    try std.testing.expect(runsCommand("zig fmt --check .", "zig fmt --check ."));
}

test "backtickedSpan: the command, not the note beside it" {
    try std.testing.expectEqualStrings(
        "zig build test",
        backtickedSpan(" `zig build test`(コンパイルに含まれる) ").?,
    );
    try std.testing.expect(backtickedSpan(" no backticks ") == null);
    try std.testing.expect(backtickedSpan(" `` ") == null);
}

test "stripComment: a hash opens a comment only at the start or after whitespace" {
    try std.testing.expectEqualStrings("", stripComment("# all of it"));
    try std.testing.expectEqualStrings("a: ", stripComment("a: # b"));
    try std.testing.expectEqualStrings("a: b", stripComment("a: b"));
    // Not whitespace before it, so it belongs to the scalar.
    try std.testing.expectEqualStrings("- name: step#3", stripComment("- name: step#3"));
}

test "stripComment: a hash inside a quoted scalar is not a comment" {
    try std.testing.expectEqualStrings("- name: \"a # b\"", stripComment("- name: \"a # b\""));
    try std.testing.expectEqualStrings("- name: 'a # b'", stripComment("- name: 'a # b'"));
    // The quote closes, so the next hash does open a comment.
    try std.testing.expectEqualStrings("- name: \"a\" ", stripComment("- name: \"a\" # b"));
}

test "hashLengthPrefixed: moving a boundary changes the digest" {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var a = Sha256.init(.{});
    hashLengthPrefixed(&a, "x");
    hashLengthPrefixed(&a, "yz");
    var b = Sha256.init(.{});
    hashLengthPrefixed(&b, "xy");
    hashLengthPrefixed(&b, "z");
    var da: [Sha256.digest_length]u8 = undefined;
    var db: [Sha256.digest_length]u8 = undefined;
    a.final(&da);
    b.final(&db);
    // Plain concatenation gives these two the same bytes, which is how one
    // file's content moved into the file before it with the record unchanged.
    try std.testing.expect(!std.mem.eql(u8, &da, &db));
}

test "isIgnored: the shapes this repository writes" {
    const patterns =
        \\# a comment
        \\_work
        \\.env.*
        \\!.env.example
        \\zig-out/
        \\.DS_Store
        \\._*
        \\*~
    ;
    try std.testing.expect(isIgnored(patterns, ".DS_Store", false));
    try std.testing.expect(isIgnored(patterns, "._base.txt", false));
    try std.testing.expect(isIgnored(patterns, "base.txt~", false));
    try std.testing.expect(isIgnored(patterns, "_work", false));
    // A trailing slash matches a directory and nothing else.
    try std.testing.expect(isIgnored(patterns, "zig-out", true));
    try std.testing.expect(!isIgnored(patterns, "zig-out", false));
    // What the record must keep covering.
    try std.testing.expect(!isIgnored(patterns, "base.txt", false));
    try std.testing.expect(!isIgnored(patterns, "notes.md", false));
    try std.testing.expect(!isIgnored(patterns, "sub", true));
    // A comment is not a pattern.
    try std.testing.expect(!isIgnored(patterns, "# a comment", false));
    // A `!` line is skipped, so what it re-includes stays ignored. This is the
    // recorded limit, pinned so a later fix flips it visibly. `.env.example`
    // belongs in no generated directory, which is why the limit is acceptable.
    try std.testing.expect(isIgnored(patterns, ".env.example", false));
}

test "isIgnored: an unrecognised shape leaves the check strict" {
    // A pattern with a star in the middle, or more than one, is not understood.
    // It must not match, or the record would stop covering what it names.
    try std.testing.expect(!isIgnored("ba*.txt", "base.txt", false));
    try std.testing.expect(!isIgnored("*ase*", "base.txt", false));
    try std.testing.expect(!isIgnored("tests/*.txt", "base.txt", false));
}

test "countOccurrences: every non-overlapping match counts" {
    try std.testing.expectEqual(@as(usize, 0), countOccurrences("abc", "x"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences("abc", "b"));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences("abab", "ab"));
    // Non-overlapping: "aaa" holds one "aa", not two.
    try std.testing.expectEqual(@as(usize, 1), countOccurrences("aaa", "aa"));
}

test "hasRefAllDeclsTest: the call must be qualified" {
    // Loosening the period requirement left all other tests green, so the
    // reason the doc comment gives for it was unpinned: a local fn of the same
    // name satisfies a bare-name check while referencing nothing.
    try std.testing.expect(!hasRefAllDeclsTest(
        \\test {
        \\    refAllDecls(@This());
        \\}
    ));
}

test "hasRefAllDeclsTest: a container expression is not @This()" {
    // The existing negative example falls at the token sequence rather than at
    // the @This check, so loosening step 3 to accept any identifier left every
    // test green. This one fails only while @This is required.
    try std.testing.expect(!hasRefAllDeclsTest(
        \\test {
        \\    std.testing.refAllDecls(Container());
        \\}
    ));
    try std.testing.expect(hasRefAllDeclsTest(
        \\test {
        \\    std.testing.refAllDecls(@This());
        \\}
    ));
}

test "hasRefAllDeclsTest: a local qualifier passes, which is the recorded limit" {
    // Lexing cannot tell what `fake` resolves to. The check is satisfied while
    // nothing is referenced. This is one of the two limits open-questions.md
    // records; the test is here so a later fix flips it visibly.
    try std.testing.expect(hasRefAllDeclsTest(
        \\const fake = struct {
        \\    fn refAllDecls(_: type) void {}
        \\};
        \\test {
        \\    fake.refAllDecls(@This());
        \\}
    ));
}

test "sha256InMarkdown: the recorded hash is the one the row shows" {
    const recorded = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    switch (sha256InMarkdown("| 入力の SHA-256 | `" ++ recorded ++ "` |", "入力の SHA-256")) {
        .one => |h| try std.testing.expectEqualStrings(recorded, h),
        else => return error.TestExpectedOne,
    }
}

test "sha256InMarkdown: nothing to record" {
    try std.testing.expect(sha256InMarkdown("| size | 67552 |", "入力の SHA-256") == .none);
    // Names the record but shows no hash.
    try std.testing.expect(sha256InMarkdown("| 入力の SHA-256 | pending |", "入力の SHA-256") == .none);
}

test "sha256InMarkdown: a decoy makes the record ambiguous, not silently wrong" {
    const real = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const decoy = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    // Hidden ahead of the real one on the same row, where the rendered table
    // still shows the real hash.
    try std.testing.expect(sha256InMarkdown(
        "| 入力の SHA-256 | <!-- " ++ decoy ++ " --> `" ++ real ++ "` |",
        "入力の SHA-256",
    ) == .ambiguous);
    // A second row carrying the same label with an older hash.
    const two_rows = "| 入力の SHA-256 | `" ++ decoy ++ "` |\n| 入力の SHA-256 | `" ++ real ++ "` |";
    try std.testing.expect(sha256InMarkdown(two_rows, "入力の SHA-256") == .ambiguous);
}

test "sha256InMarkdown: each label finds its own record" {
    // One document holds two hashes. Looking a row up by the word SHA-256
    // alone would find both and call every document ambiguous.
    const input = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const output = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const doc = "| 入力の SHA-256 | `" ++ input ++ "` |\n| 抽出結果の SHA-256 | `" ++ output ++ "` |";
    switch (sha256InMarkdown(doc, "入力の SHA-256")) {
        .one => |h| try std.testing.expectEqualStrings(input, h),
        else => return error.TestExpectedOne,
    }
    switch (sha256InMarkdown(doc, "抽出結果の SHA-256")) {
        .one => |h| try std.testing.expectEqualStrings(output, h),
        else => return error.TestExpectedOne,
    }
}

test "sha256InMarkdown: case is not part of the record" {
    const lower = "abcdef01abcdef01abcdef01abcdef01abcdef01abcdef01abcdef01abcdef01";
    const upper = "ABCDEF01ABCDEF01ABCDEF01ABCDEF01ABCDEF01ABCDEF01ABCDEF01ABCDEF01";
    // One hash written twice in different case is one record, not two.
    switch (sha256InMarkdown("| 入力の SHA-256 | `" ++ lower ++ "` and `" ++ upper ++ "` |", "入力の SHA-256")) {
        .one => {},
        else => return error.TestExpectedOne,
    }
}

test "fenceRun: a run of two is not a fence" {
    // Reached only when the line is long enough but the run is not, which the
    // length guard alone does not cover.
    try std.testing.expect(fenceRun("``x") == null);
    try std.testing.expect(fenceRun("~~x") == null);
    try std.testing.expect(fenceRun("```") != null);
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
