const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // This example gives you the option between OpenGL 4.1 bindings or
    // OpenGL ES 3.0 bindings, both generated at build time.
    // The default is OpenGL 4.1.
    const use_gles = b.option(
        bool,
        "gles",
        "Target OpenGL ES 3.0 instead of OpenGL 4.1",
    ) orelse false;

    const exe = b.addExecutable(.{
        .name = "zigglgen-example",
        .root_source_file = b.path("main.zig"),
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
        exe.root_module.addImport("gl", @import("zigglgen").generateBindingsModule(b, .{
            .api = .gles,
            .version = .@"3.0",
            .profile = null,
            .extensions = &.{ .ARB_clip_control, .NV_scissor_exclusive },
        }));
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
}
