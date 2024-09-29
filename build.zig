const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const generator = b.addExecutable(.{
        .name = "zigglgen-generator",
        .root_source_file = b_path(b, "generator.zig"),
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
    const zigglgen_dep = thisDependency(b, .{});
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

// TODO 2024.5.0-mach: Replace with 'b.dependencyFromBuildZig'.
fn thisDependency(b: *std.Build, args: anytype) *std.Build.Dependency {
    find_dep: {
        const all_pkgs = @import("root").dependencies.packages;
        const pkg_hash = inline for (@typeInfo(all_pkgs).@"struct".decls) |decl| {
            const pkg = @field(all_pkgs, decl.name);
            if (@hasDecl(pkg, "build_zig") and pkg.build_zig == @This()) break decl.name;
        } else break :find_dep;
        const dep_name = for (b.available_deps) |dep| {
            if (std.mem.eql(u8, dep[1], pkg_hash)) break dep[0];
        } else break :find_dep;
        return b.dependency(dep_name, args);
    }
    std.debug.panic("zigglgen is not a dependency in '{s}'", .{b.pathFromRoot("build.zig.zon")});
}

// TODO 2024.5.0-mach: Replace with 'b.path'.
fn b_path(b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
    return if (@hasDecl(std.Build, "path"))
        b.path(sub_path)
    else
        .{ .path = sub_path };
}
