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
const test_excluded = [_][]const u8{};

/// The helper programs under tools/. Each is a single-file module.
const tool_names = [_][]const u8{ "check-docs", "extract-r7rs-required" };

/// A module whose tests `zig build test` runs, paired with the path that
/// created it.
///
/// One value feeds both the `addTest` call and the `--root` argument passed to
/// tools/check-docs, in the same loop. Keeping them apart has twice produced a
/// build where a source file's tests silently stopped running while every
/// check stayed green: first by dropping a module from the test loop, then by
/// repeating one module and losing the other.
const TestTarget = struct {
    path: []const u8,
    mod: *std.Build.Module,
};

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

    const lib_path = "src/sucheme.zig";
    const sucheme = b.addModule("sucheme", .{
        .root_source_file = b.path(lib_path),
        .target = target,
        .optimize = optimize,
    });
    sucheme.addOptions("build_options", options);

    const exe_path = "src/main.zig";
    const exe = b.addExecutable(.{
        .name = @tagName(manifest.name),
        .root_module = b.createModule(.{
            .root_source_file = b.path(exe_path),
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
    targets.append(b.allocator, .{ .path = lib_path, .mod = sucheme }) catch @panic("OOM");
    targets.append(b.allocator, .{ .path = exe_path, .mod = exe.root_module }) catch @panic("OOM");
    // The tools are verification code; without tests of their own in the test
    // step, a failing assertion in them would never run. They hold most of the
    // new logic at stage 0.
    for (tool_names) |name| {
        const t = tool(b, name);
        targets.append(b.allocator, .{
            .path = b.fmt("tools/{s}/main.zig", .{name}),
            .mod = t.root_module,
        }) catch @panic("OOM");
    }

    // One loop, one list: a module and the path check-docs is told about come
    // from the same value, so neither can be dropped or duplicated alone.
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
