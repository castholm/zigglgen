const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigglgen_exe = b.addExecutable(.{
        .name = "zigglgen",
        .root_source_file = b.path("zigglgen.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(zigglgen_exe);
}

pub const ZigglgenOptions = struct {
    api: Api,
    version: Version,
    profile: ?Profile = null,
    extensions: []const Extension = &.{},

    pub const Api = @import("zigglgen_options.zig").Api;
    pub const Version = @import("zigglgen_options.zig").Version;
    pub const Profile = @import("zigglgen_options.zig").Profile;
    pub const Extension = @import("zigglgen_options.zig").Extension;
};

pub fn generateBindingsModule(b: *std.Build, options: ZigglgenOptions) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = generateBindingsSourceFile(b, options),
    });
}

pub fn generateBindingsSourceFile(b: *std.Build, options: ZigglgenOptions) std.Build.LazyPath {
    const zigglgen_dep = b.dependencyFromBuildZig(@This(), .{});
    const zigglgen_exe = zigglgen_dep.artifact("zigglgen");
    const run_zigglgen = b.addRunArtifact(zigglgen_exe);
    run_zigglgen.addArg(b.fmt("{s}-{s}{s}{s}", .{
        @tagName(options.api),
        @tagName(options.version),
        if (options.profile != null) "-" else "",
        if (options.profile) |profile| @tagName(profile) else "",
    }));
    for (options.extensions) |extension| run_zigglgen.addArg(@tagName(extension));
    const output = run_zigglgen.captureStdOut();
    run_zigglgen.captured_stdout.?.basename = "gl.zig";
    return output;
}
