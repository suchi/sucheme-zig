const std = @import("std");
const builtin = @import("builtin");

/// The pinned Zig version. `.zigversion` is the single source of truth
/// (ADR-0001). `minimum_zig_version` in build.zig.zon is a copy that
/// tools/check-docs verifies; Zig itself does not enforce it.
const pinned_zig_version = @embedFile(".zigversion");

/// Repository-relative paths that must not become `addTest` targets. Full
/// paths, not base names: `wasm.zig` alone would also exclude
/// src/platform/wasm.zig.
///
/// Empty at stage 0. Stage 1 adds "src/wasm.zig": a wasm32-freestanding test
/// runner does not compile, because std's runner reaches posix declarations
/// absent on that target. tools/check-docs rejects an entry naming a file that
/// does not exist, so entries are added with the file, not ahead of it.
///
/// This is an escape hatch, and nothing checks that an entry deserves it:
/// adding a name here while dropping the same module from `targets` leaves that
/// file's tests unrun with every check green. So an entry carries the reason it
/// cannot be a test target, and the reason names what makes the test impossible
/// rather than inconvenient. Making the reason machine-checked is recorded as an
/// implementation-time question in docs/design/open-questions.md, to settle when
/// the first real entry arrives.
const test_excluded = [_][]const u8{};

/// The stage this repository has reached, as docs/roadmap.md numbers them.
///
/// Passed to tools/check-docs, which uses it to decide which rows of AGENTS.md's
/// verification command table the CI workflow must already run. Raising it makes
/// that check demand the new rows, so it fails until the workflow is updated.
const current_stage = 0;

/// A module whose tests `zig build test` runs.
///
/// The path is read back out of the module instead of being written beside it,
/// so no literal can name one file while the module was built from another, and
/// the `--root` argument check-docs receives names the file whose tests run.
/// Three separate edits have otherwise left a source file's tests silently
/// unrun while every check stayed green: dropping a module from the test loop,
/// repeating one module and losing the other, and pairing one file's path with
/// another file's module.
const TestTarget = struct {
    mod: *std.Build.Module,
    /// Read out of `mod` when the target was recorded.
    path: []const u8,
    /// The test binary built from `mod`, filled in when the test is added.
    /// Kept so the final check can look at how it was configured.
    unit: ?*std.Build.Step.Compile = null,

    fn of(b: *std.Build, mod: *std.Build.Module) TestTarget {
        return .{ .mod = mod, .path = sourcePath(b, mod) };
    }

    /// Fails the configure step when this target's tests would not all run.
    ///
    /// Counting run steps is not enough. `b.addTest(.{ ..., .filters = &.{"x"}
    /// })` is a one-field edit that leaves the run step in place and selects no
    /// test: `zig build test` then exits 0 with a deliberately failing test in
    /// src/sucheme.zig, all four commands stay green, and `--summary all` stops
    /// printing a test count, so even the log holds no trace. A custom
    /// `test_runner` can decide the same thing. Neither is needed here, so both
    /// are refused outright rather than inspected.
    fn checkRunsEveryTest(self: TestTarget) void {
        const unit = self.unit orelse {
            std.debug.print("[sucheme] test target {s} has no test binary\n", .{self.path});
            std.process.exit(1);
        };
        if (unit.filters.len != 0) {
            std.debug.print(
                "[sucheme] test target {s} has {d} test filter(s); a filter can select no test at all\n",
                .{ self.path, unit.filters.len },
            );
            std.process.exit(1);
        }
        if (unit.test_runner != null) {
            std.debug.print(
                "[sucheme] test target {s} has a custom test runner; it decides what runs\n",
                .{self.path},
            );
            std.process.exit(1);
        }
    }

    /// Fails the configure step when the module no longer reports the path its
    /// test and its `--root` argument were made from.
    ///
    /// `addTest` resolves its module's `root_source_file` when it compiles, so
    /// an edit after the test was added compiles a file other than the one
    /// check-docs was told about, and every command stays green while that
    /// file's tests never run. Calling this after every other edit in `build`
    /// closes the window, because no configure-time code follows it and no step
    /// mutates a module while the graph is made.
    fn recheck(self: TestTarget, b: *std.Build) void {
        // The module the test compiles, not the one recorded. `addTest` keeps
        // its module in a public mutable field of the Compile step, so
        // `unit.root_module = other` leaves `self.mod` untouched and compiles
        // another file. Reading it through the unit covers both that and an
        // assignment to the module's own `root_source_file`.
        const unit = self.unit orelse return; // checkRunsEveryTest reports this
        const now = sourcePath(b, unit.root_module);
        if (std.mem.eql(u8, now, self.path)) return;
        std.debug.print(
            "[sucheme] test target {s} was rebound to {s} after its test was added\n",
            .{ self.path, now },
        );
        std.process.exit(1);
    }
};

/// The repository-relative path a module was built from, spelled the way this
/// repository spells paths: with `/`.
///
/// `b.path` keeps the host separator, so on Windows a module reports
/// `src\main.zig`. Normalising here, where the path enters this script, is what
/// lets everything downstream compare and print one spelling: `test_excluded`,
/// the `--root` arguments and the documents all use `/`, and check-docs could
/// not open a root named with a backslash.
fn sourcePath(b: *std.Build, mod: *std.Build.Module) []const u8 {
    const lazy = mod.root_source_file orelse {
        std.debug.print("[sucheme] a test target module has no root source file\n", .{});
        std.process.exit(1);
    };
    switch (lazy) {
        .src_path => |sp| {
            const out = b.allocator.dupe(u8, sp.sub_path) catch @panic("OOM");
            // On a host whose separator is already `/` this does nothing.
            std.mem.replaceScalar(u8, out, std.fs.path.sep, '/');
            return out;
        },
        else => {
            std.debug.print("[sucheme] a test target module is not built from a repository path\n", .{});
            std.process.exit(1);
        },
    }
}

pub fn build(b: *std.Build) void {
    enforcePinnedZigVersion();

    // The manifest is parsed, not string-searched: a raw search would let a
    // commented-out `.version` shadow the real one.
    const manifest = parseManifest(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "name", @tagName(manifest.name));
    options.addOption([]const u8, "version", manifest.version);

    const sucheme = b.addModule("sucheme", .{
        .root_source_file = b.path("src/sucheme.zig"),
        .target = target,
        .optimize = optimize,
    });
    sucheme.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = @tagName(manifest.name),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sucheme", .module = sucheme }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "run the sucheme executable").dependOn(&run.step);

    // One Compile per tool, reused by every run step and by the test targets.
    // Calling tool() at each use made two Compile steps from the same file.
    const check_docs = tool(b, "check-docs");
    const extractor = tool(b, "extract-r7rs-required");
    const tools = [_]*std.Build.Step.Compile{ check_docs, extractor };

    const run_check_docs = b.addRunArtifact(check_docs);
    // Run steps inherit the directory `zig build` was started from, not the
    // build root, so a relative read would fail under --build-file.
    run_check_docs.setCwd(b.path("."));

    // The generated lists are compared with what the extractor produces from the
    // committed input. Comparing them only with a SHA-256 pasted into SOURCE.md
    // left the pair unanchored: editing a list and pasting the new hash kept
    // every verification command green with an identifier gone from the
    // conformance denominator.
    const run_check_extract = b.addRunArtifact(extractor);
    run_check_extract.setCwd(b.path("."));
    run_check_extract.addArg("--check");
    const check_extract_step = b.step("check-extract", "check the generated lists against the input");
    check_extract_step.dependOn(&run_check_extract.step);

    const test_step = b.step("test", "run the unit tests");

    var targets: std.ArrayList(TestTarget) = .empty;
    targets.append(b.allocator, .of(b, sucheme)) catch @panic("OOM");
    targets.append(b.allocator, .of(b, exe.root_module)) catch @panic("OOM");
    // The tools are verification code; without tests of their own in the test
    // step, a failing assertion in them would never run. They hold most of the
    // new logic at stage 0.
    for (tools) |t| {
        targets.append(b.allocator, .of(b, t.root_module)) catch @panic("OOM");
    }

    // One loop, one list: the test and the path check-docs is told about come
    // from the same module, so neither can be dropped or duplicated alone.
    for (targets.items) |*t| {
        const unit = b.addTest(.{ .root_module = t.mod });
        t.unit = unit;
        test_step.dependOn(&b.addRunArtifact(unit).step);
        run_check_docs.addArg("--root");
        run_check_docs.addArg(t.path);
    }
    for (test_excluded) |path| {
        run_check_docs.addArg("--exclude");
        run_check_docs.addArg(path);
    }
    run_check_docs.addArg("--stage");
    run_check_docs.addArg(b.fmt("{d}", .{current_stage}));

    // The commands that must appear both in AGENTS.md's table and in the
    // per-commit workflow, named by the steps that provide them.
    //
    // The table and the workflow were compared with each other and with nothing
    // else, so weakening both at once was green: deleting a row and its step
    // together removed the requirement, and three of the four commands could go
    // that way. This list is the third point. It is not another record to keep
    // in step by hand -- each entry is the step that runs it, so dropping a
    // requirement means dropping the step, and then the command itself stops
    // working. `zig fmt --check .` is not a build step, so it stays held by the
    // table and the workflow alone.
    const required_steps = [_]*std.Build.Step{
        b.getInstallStep(),
        test_step,
        check_extract_step,
    };
    for (required_steps) |s| {
        run_check_docs.addArg("--requires");
        // The install step is what plain `zig build` runs, and the table names
        // it that way.
        run_check_docs.addArg(if (s == b.getInstallStep())
            "zig build"
        else
            b.fmt("zig build {s}", .{s.name}));
    }
    const check_docs_step = b.step("check-docs", "check the docs and build settings");
    check_docs_step.dependOn(&run_check_docs.step);
    // Added after its own step exists, so the step this program runs in is held
    // to the same requirement as the others.
    run_check_docs.addArg("--requires");
    run_check_docs.addArg(b.fmt("zig build {s}", .{check_docs_step.name}));

    // Last in `build`, so nothing can rebind a module or reconfigure a test
    // after it was added. See TestTarget.recheck and checkRunsEveryTest.
    for (targets.items) |t| {
        t.recheck(b);
        t.checkRunsEveryTest();
    }
    checkTestsAreRun(test_step, targets.items);
}

/// Fails the configure step unless the test step runs each target's test
/// binary.
///
/// `TestTarget` guards which file each test is built from; it says nothing about
/// the test being executed. Writing `test_step.dependOn(&unit.step)` instead of
/// `test_step.dependOn(&b.addRunArtifact(unit).step)` is a one-token edit that
/// builds every test and runs none: `zig build test` then exits 0 with a
/// deliberately failing test in src/sucheme.zig, and `zig build`, `zig build
/// check-docs` and `zig fmt --check .` stay green too. check-docs cannot see it,
/// because it is told the paths and not whether anything ran.
///
/// Each target is looked for by name among the run steps' producers, rather
/// than the run steps being counted. A count is not a correspondence: pointing
/// one target's run step at some other artifact kept the count the same, and
/// that target's tests were never compiled while all four commands stayed
/// green. A count also breaks for an honest reason, as soon as anything but a
/// target's test is attached to this step.
///
/// What a run step then selects is `TestTarget.checkRunsEveryTest`'s business,
/// and that every root has a test to select at all is check-docs' business.
fn checkTestsAreRun(test_step: *std.Build.Step, targets: []const TestTarget) void {
    for (targets) |t| {
        const unit = t.unit orelse continue; // checkRunsEveryTest reports this
        var ran = false;
        for (test_step.dependencies.items) |dep| {
            const run = dep.cast(std.Build.Step.Run) orelse continue;
            const producer = run.producer orelse continue;
            if (producer == unit) ran = true;
        }
        if (ran) continue;
        std.debug.print(
            "[sucheme] the test step does not run the test built from {s}\n",
            .{t.path},
        );
        std.process.exit(1);
    }
}

/// Builds one of the helper programs under tools/.
fn tool(b: *std.Build, name: []const u8) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tools/{s}/main.zig", .{name})),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
}

fn enforcePinnedZigVersion() void {
    const text = std.mem.trim(u8, pinned_zig_version, &std.ascii.whitespace);
    const want = std.SemanticVersion.parse(text) catch
        @panic(".zigversion is not a semantic version");
    const have = builtin.zig_version;
    // Exact equality, including prerelease and build metadata: a 0.17.0-dev
    // master build is not the 0.17.0 release, and ADR-0001 pins the release.
    //
    // This only runs once build.zig itself compiles. A Zig whose std differs
    // enough fails earlier, in the configure compile, with a std error rather
    // than this diagnostic. docs/design/zig-api-notes.md records that limit.
    if (want.order(have) == .eq and
        optionalStringsEqual(want.pre, have.pre) and
        optionalStringsEqual(want.build, have.build)) return;
    std.debug.print("\n[sucheme] .zigversion pins Zig {f} but {f} is in use.\n", .{ want, have });
    std.debug.print("          Install the pinned version; see docs/adr/0001-zig-version-pinning.md\n\n", .{});
    std.process.exit(1);
}

fn optionalStringsEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// The fields of build.zig.zon this build script reads.
const Manifest = struct {
    name: enum { sucheme },
    version: []const u8,
};

fn parseManifest(b: *std.Build) Manifest {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(Manifest, .{
        .gpa = b.allocator,
        .arena = b.allocator,
        .source = @embedFile("build.zig.zon"),
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch {
        diagnostics.log("build.zig.zon");
        std.process.exit(1);
    };
}
