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

/// The helper programs under tools/. Each is a single-file module.
const tool_names = [_][]const u8{ "check-docs", "extract-r7rs-required" };

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

    fn of(b: *std.Build, mod: *std.Build.Module) TestTarget {
        return .{ .mod = mod, .path = sourcePath(b, mod) };
    }

    /// Fails the configure step when the module no longer reports the path its
    /// test and its `--root` argument were made from.
    ///
    /// `addTest` keeps the module by pointer and resolves `root_source_file`
    /// when it compiles, so assigning to `root_module.root_source_file` after
    /// the test was added compiles a file other than the one check-docs was
    /// told about. Reading the path once at record time does not catch that:
    /// with src/main.zig rebound after the loop, `zig build`, `zig build test`,
    /// `zig build check-docs` and `zig fmt --check .` all stayed green while
    /// main.zig's tests never ran. Calling this after every other edit in
    /// `build` closes the window, because no configure-time code follows it and
    /// no step mutates a module while the graph is made.
    fn recheck(self: TestTarget, b: *std.Build) void {
        const now = sourcePath(b, self.mod);
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

    const check_docs = tool(b, "check-docs");
    const run_check_docs = b.addRunArtifact(check_docs);
    // Run steps inherit the directory `zig build` was started from, not the
    // build root, so a relative read would fail under --build-file.
    run_check_docs.setCwd(b.path("."));

    const test_step = b.step("test", "run the unit tests");

    var targets: std.ArrayList(TestTarget) = .empty;
    targets.append(b.allocator, .of(b, sucheme)) catch @panic("OOM");
    targets.append(b.allocator, .of(b, exe.root_module)) catch @panic("OOM");
    // The tools are verification code; without tests of their own in the test
    // step, a failing assertion in them would never run. They hold most of the
    // new logic at stage 0.
    for (tool_names) |name| {
        targets.append(b.allocator, .of(b, tool(b, name).root_module)) catch @panic("OOM");
    }

    // One loop, one list: the test and the path check-docs is told about come
    // from the same module, so neither can be dropped or duplicated alone.
    for (targets.items) |t| {
        const unit = b.addTest(.{ .root_module = t.mod });
        test_step.dependOn(&b.addRunArtifact(unit).step);
        run_check_docs.addArg("--root");
        run_check_docs.addArg(t.path);
    }
    for (test_excluded) |path| {
        run_check_docs.addArg("--exclude");
        run_check_docs.addArg(path);
    }
    b.step("check-docs", "check the docs and build settings").dependOn(&run_check_docs.step);

    // Last in `build`, so nothing can rebind a module after its test was added.
    // See TestTarget.recheck.
    for (targets.items) |t| t.recheck(b);
    checkTestsAreRun(test_step, targets.items.len);
}

/// Fails the configure step unless the test step runs one test per target.
///
/// `TestTarget` guards which file each test is built from; it says nothing about
/// the test being executed. Writing `test_step.dependOn(&unit.step)` instead of
/// `test_step.dependOn(&b.addRunArtifact(unit).step)` is a one-token edit that
/// builds every test and runs none: `zig build test` then exits 0 with a
/// deliberately failing test in src/sucheme.zig, and `zig build`, `zig build
/// check-docs` and `zig fmt --check .` stay green too. check-docs cannot see it,
/// because it is told the paths and not whether anything ran.
fn checkTestsAreRun(test_step: *std.Build.Step, want: usize) void {
    var runs: usize = 0;
    for (test_step.dependencies.items) |dep| {
        if (dep.tag == .run) runs += 1;
    }
    if (runs == want) return;
    std.debug.print(
        "[sucheme] the test step runs {d} test(s) for {d} target(s); each test must be run, not only built\n",
        .{ runs, want },
    );
    std.process.exit(1);
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
