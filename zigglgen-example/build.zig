const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zigglgen-example",
        .root_source_file = .{ .path = "main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.subsystem = .Windows;

    const mach_glfw_dep = b.dependency("mach-glfw", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("glfw", mach_glfw_dep.module("mach-glfw"));

    const gl_bindings = @import("zigglgen").generateBindingsModule(b, .{
        .api = .gl,
        .version = .@"4.1",
        .profile = .core,
        .extensions = &.{ .ARB_clip_control, .NV_scissor_exclusive },
    });
    exe.root_module.addImport("gl", gl_bindings);

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_exe.step);

    // If you prefer you can also generate bindings in advance and commit them to revision control.
    const write_gles = b.addWriteFiles();
    write_gles.addCopyFileToSource(@import("zigglgen").generateBindingsSourceFile(b, .{
        .api = .gles,
        .version = .@"3.0",
        .extensions = &.{ .EXT_clip_control, .NV_scissor_exclusive },
    }), "gles3.zig");

    const update_gles = b.step("update-gles3", "Update 'gles3.zig'");
    update_gles.dependOn(&write_gles.step);
}
