const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_tls = b.step("test", "Run tests");

    const gl_files = [_][]const u8{
        "gl46.zig",
        "gl30.zig",
        "gl21.zig",
        "gl10.zig",
        "gles30.zig",
    };
    for (gl_files) |gl_file| {
        const exe = b.addExecutable(.{
            .name = b.fmt("test_{s}", .{std.mem.sliceTo(gl_file, '.')}),
            .root_source_file = .{ .path = "test.zig" },
            .target = target,
            .optimize = optimize,
        });
        exe.addAnonymousModule("gl", .{ .source_file = .{ .path = gl_file } });

        const run_exe = b.addRunArtifact(exe);
        test_tls.dependOn(&run_exe.step);
    }
}
