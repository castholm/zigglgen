const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // This example gives you the option between OpenGL 4.1 bindings generated at build time or
    // vendored OpenGL ES 3.0 bindings generated in advance. The default is OpenGL 4.1.
    const use_gles = b.option(
        bool,
        "gles",
        "Target GL ES 3.0 instead of GL 4.1",
    ) orelse false;

    const exe = b.addExecutable(.{
        .name = "zigglgen-example",
        .root_source_file = b_path(b, "main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mach_glfw_dep = b.dependency("mach-glfw", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("glfw", mach_glfw_dep.module("mach-glfw"));

    if (use_gles) {
        // Use the vendored OpenGL ES 3.0 bindings.
        exe.root_module.addAnonymousImport("gl", .{
            .root_source_file = b_path(b, "gles3.zig"),
        });
    } else {
        // Generate OpenGL 4.1 bindings at build time.
        exe.root_module.addImport("gl", @import("zigglgen").generateBindingsModule(b, .{
            .api = .gl,
            .version = .@"4.1",
            .profile = .core,
            .extensions = &.{ .ARB_clip_control, .NV_scissor_exclusive },
        }));
    }

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_exe.step);

    // Set up a maintenance task step for updating the OpenGL ES 3.0 bindings.
    const copy_gles = b.addWriteFiles();
    copy_gles.addCopyFileToSource(@import("zigglgen").generateBindingsSourceFile(b, .{
        .api = .gles,
        .version = .@"3.0",
        .extensions = &.{ .EXT_clip_control, .NV_scissor_exclusive },
    }), "gles3.zig");

    const update_gles = b.step("update-gles-bindings", "Update 'gles3.zig'");
    update_gles.dependOn(&copy_gles.step);
}

// TODO 2024.5.0-mach: Replace with 'b.path'.
fn b_path(b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
    return if (@hasDecl(std.Build, "path"))
        b.path(sub_path)
    else
        .{ .path = sub_path };
}
