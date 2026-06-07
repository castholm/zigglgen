// © 2024 Carl Åstholm
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigglgen_exe = b.addExecutable(.{
        .name = "zigglgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zigglgen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(zigglgen_exe);

    const run_zigglgen = b.addRunArtifact(zigglgen_exe);
    if (@hasDecl(std.Build.Step.Run, "addPassthruArgs")) {
        run_zigglgen.addPassthruArgs();
    } else { // TODO: Remove after 0.17
        run_zigglgen.addArgs(b.args orelse &.{});
    }
    run_zigglgen.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run zigglgen");
    run_step.dependOn(&run_zigglgen.step);

    const zigglgen_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = generate_everything: {
                const r = b.addRunArtifact(zigglgen_exe);
                r.addArgs(&.{ "gl-4.6-core", "ZIGGLGEN_everything" });
                break :generate_everything r.captureStdOut(.{ .basename = "gl.zig" });
            },
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(zigglgen_tests);

    const test_step = b.step("test", "Sanity check zigglgen output");
    test_step.dependOn(&run_tests.step);

    if (@FieldType(std.Build.Step.Fmt.Options, "paths") == []const std.Build.LazyPath) {
        test_step.dependOn(&b.addFmt(.{
            .check = true,
            // Slicing a single-item pointer circumvents <https://codeberg.org/ziglang/zig/issues/35658>
            .paths = (&zigglgen_tests.root_module.root_source_file.?)[0..1],
        }).step);
    } else {
        // TODO: Remove after 0.17
    }
}

pub const GeneratorOptions = @import("GeneratorOptions.zig");

pub fn generateModule(b: *std.Build, options: GeneratorOptions) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = generateSourceFile(b, options),
    });
}

pub fn generateSourceFile(b: *std.Build, options: GeneratorOptions) std.Build.LazyPath {
    const zigglgen_dep = b.dependencyFromBuildZig(@This(), .{
        .optimize = std.builtin.OptimizeMode.Debug,
    });
    const zigglgen_exe = zigglgen_dep.artifact("zigglgen");
    const run_zigglgen = b.addRunArtifact(zigglgen_exe);
    run_zigglgen.addArg(b.fmt("{s}-{s}{s}{s}", .{
        @tagName(options.api),
        @tagName(options.version),
        if (options.profile != null) "-" else "",
        if (options.profile) |profile| @tagName(profile) else "",
    }));
    for (options.extensions) |extension| {
        run_zigglgen.addArg(@tagName(extension));
    }
    return run_zigglgen.captureStdOut(.{ .basename = "gl.zig" });
}

/// Deprecated: Use `generateModule` instead.
pub const generateBindingsModule = generateModule;

/// Deprecated: Use `generateSourceFile` instead.
pub const generateBindingsSourceFile = generateSourceFile;
