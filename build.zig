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
    run_zigglgen.addArgs(b.args orelse &.{});
    run_zigglgen.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run zigglgen");
    run_step.dependOn(&run_zigglgen.step);

    const zigglgen_tests = b.addTest(.{
        .root_source_file = generate_everything: {
            const r = b.addRunArtifact(zigglgen_exe);
            r.addArgs(&.{ "gl-4.6-core", "ZIGGLGEN_everything" });
            const output = r.captureStdOut();
            r.captured_stdout.?.basename = "gl.zig";
            break :generate_everything output;
        },
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(zigglgen_tests);

    const test_step = b.step("test", "Sanity check zigglgen output");
    test_step.dependOn(&run_tests.step);
}

pub const GeneratorOptions = @import("GeneratorOptions.zig");

pub fn generateBindingsModule(b: *std.Build, options: GeneratorOptions) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = generateBindingsSourceFile(b, options),
    });
}

pub fn generateBindingsSourceFile(b: *std.Build, options: GeneratorOptions) std.Build.LazyPath {
    const zigglgen_dep = b.dependencyFromBuildZig(@This(), .{
        .target = b.graph.host,
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
    const output = run_zigglgen.captureStdOut();
    run_zigglgen.captured_stdout.?.basename = "gl.zig";
    return output;
}
