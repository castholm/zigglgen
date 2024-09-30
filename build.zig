const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const generator = b.addExecutable(.{
        .name = "zigglgen-generator",
        .root_source_file = b.path("generator.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(generator);
}

pub const GeneratorOptions = struct {
    api: Api,
    version: Version,
    profile: ?Profile = null,
    extensions: []const Extension = &.{},

    pub const Api = @import("generator_options.zig").Api;
    pub const Version = @import("generator_options.zig").Version;
    pub const Profile = @import("generator_options.zig").Profile;
    pub const Extension = @import("generator_options.zig").Extension;
};

pub fn generateBindingsModule(b: *std.Build, options: GeneratorOptions) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = generateBindingsSourceFile(b, options),
    });
}

pub fn generateBindingsSourceFile(b: *std.Build, options: GeneratorOptions) std.Build.LazyPath {
    const zigglgen_dep = b.dependencyFromBuildZig(@This(), .{});
    const generator = zigglgen_dep.artifact("zigglgen-generator");
    const run_generator = b.addRunArtifact(generator);
    run_generator.addArg(b.fmt("{s}-{s}{s}{s}", .{
        @tagName(options.api),
        @tagName(options.version),
        if (options.profile != null) "-" else "",
        if (options.profile) |profile| @tagName(profile) else "",
    }));
    for (options.extensions) |extension| run_generator.addArg(@tagName(extension));
    const output = run_generator.captureStdOut();
    run_generator.captured_stdout.?.basename = "gl.zig";
    return output;
}
