const std = @import("std");
const builtin = @import("builtin");

/// The pinned Zig version. `.zigversion` is the single source of truth
/// (ADR-0001); `minimum_zig_version` in build.zig.zon is a copy that
/// tools/check-docs verifies, and Zig itself does not enforce it.
const pinned_zig_version = @embedFile(".zigversion");

/// Modules whose `test` blocks `zig build test` runs. tools/check-docs is
/// given these so that one list governs both the build and the check.
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

pub fn build(b: *std.Build) void {
    enforcePinnedZigVersion();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", versionFromManifest(b));

    const sucheme = b.addModule("sucheme", .{
        .root_source_file = b.path("src/sucheme.zig"),
        .target = target,
        .optimize = optimize,
    });
    sucheme.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "sucheme",
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

    // One addTest per module: a test binary covers a single module.
    const test_step = b.step("test", "run the unit tests");
    for ([_]*std.Build.Module{ sucheme, exe.root_module }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    const check_docs = b.addExecutable(.{
        .name = "check-docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check-docs/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_check_docs = b.addRunArtifact(check_docs);
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

fn enforcePinnedZigVersion() void {
    const text = std.mem.trim(u8, pinned_zig_version, &std.ascii.whitespace);
    const want = std.SemanticVersion.parse(text) catch
        @panic(".zigversion is not a semantic version");
    const have = builtin.zig_version;
    if (want.major == have.major and want.minor == have.minor and want.patch == have.patch) return;
    std.debug.print("\n[sucheme] .zigversion pins Zig {f} but {f} is in use.\n", .{ want, have });
    std.debug.print("          Install the pinned version; see docs/adr/0001-zig-version-pinning.md\n\n", .{});
    std.process.exit(1);
}

/// Reads `.version` out of build.zig.zon so the manifest stays the single
/// source of truth for the project version.
fn versionFromManifest(b: *std.Build) []const u8 {
    const manifest = @embedFile("build.zig.zon");
    const key = ".version = \"";
    const start = (std.mem.indexOf(u8, manifest, key) orelse
        @panic("build.zig.zon has no .version")) + key.len;
    const end = std.mem.indexOfScalarPos(u8, manifest, start, '"') orelse
        @panic("build.zig.zon .version is unterminated");
    return b.dupe(manifest[start..end]);
}
