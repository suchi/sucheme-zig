const std = @import("std");
const builtin = @import("builtin");

/// The pinned Zig version. `.zigversion` is the single source of truth
/// (ADR-0001). `minimum_zig_version` in build.zig.zon is a copy that
/// tools/check-docs verifies; Zig itself does not enforce it.
const pinned_zig_version = @embedFile(".zigversion");

/// Root source files of the modules whose tests `zig build test` runs.
///
/// These strings create the modules below, so the paths and the modules cannot
/// disagree. `test_modules` is typed with this array's length, so dropping a
/// module from the test loop is a compile error rather than a silently skipped
/// test file. tools/check-docs receives the same strings.
const test_roots = [_][]const u8{ "src/sucheme.zig", "src/main.zig" };

/// Repository-relative paths under src/ that must not become `addTest`
/// targets. Full paths, not base names: `wasm.zig` alone would also exclude
/// src/platform/wasm.zig.
///
/// Empty at stage 0. Stage 1 adds "src/wasm.zig": a wasm32-freestanding test
/// runner does not compile, because std's runner reaches posix declarations
/// absent on that target. tools/check-docs rejects an entry naming a file that
/// does not exist, so entries are added with the file, not ahead of it.
const test_excluded = [_][]const u8{};

/// The helper programs under tools/.
const tool_names = [_][]const u8{ "check-docs", "extract-r7rs-required" };

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
        .root_source_file = b.path(test_roots[0]),
        .target = target,
        .optimize = optimize,
    });
    sucheme.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = @tagName(manifest.name),
        .root_module = b.createModule(.{
            .root_source_file = b.path(test_roots[1]),
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

    // One addTest per module: a test binary covers a single module. The array
    // length is tied to test_roots, so the two lists cannot drift apart.
    const test_modules: [test_roots.len]*std.Build.Module = .{ sucheme, exe.root_module };
    const test_step = b.step("test", "run the unit tests");
    for (test_modules) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Every tool compiles as part of `zig build test`, which AGENTS.md's
    // command table treats as the type check. extract-r7rs-required is run by
    // hand, so without this it could rot unnoticed until the next extraction.
    for (tool_names) |name| test_step.dependOn(&tool(b, name).step);

    const run_check_docs = b.addRunArtifact(tool(b, "check-docs"));
    // Run steps inherit the directory `zig build` was started from, not the
    // build root, so a relative read would fail under --build-file.
    run_check_docs.setCwd(b.path("."));
    for (test_roots) |path| {
        run_check_docs.addArg("--root");
        run_check_docs.addArg(path);
    }
    for (test_excluded) |path| {
        run_check_docs.addArg("--exclude");
        run_check_docs.addArg(path);
    }
    b.step("check-docs", "check the docs and build settings").dependOn(&run_check_docs.step);
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
