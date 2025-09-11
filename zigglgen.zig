// © 2024 Carl Åstholm
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

const Options = @import("GeneratorOptions.zig");
const registry = @import("api_registry.zig");

const post_writergate = @hasDecl(std, "Io"); // TODO: Remove after 0.15 (also audit std.Io.Writer code)

/// Usage: `zigglen <api>-<version>[-<profile>] [<extension> ...]`
pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    var arg_it = try std.process.argsWithAllocator(arena);

    const exe_name = arg_it.next() orelse "zigglen";

    const raw_triple = arg_it.next() orelse printUsageAndExit(exe_name);
    const triple = ApiVersionProfile.parse(raw_triple) catch |err|
        return handleApiVersionProfileUserErrorAndExit(err, raw_triple);
    const api, const version, const profile = .{ triple.api, triple.version, triple.profile };

    var extensions: ResolvedExtensions = .{};
    var resolve_everything = false;
    while (arg_it.next()) |raw_extension| {
        if (std.mem.eql(u8, raw_extension, "ZIGGLGEN_everything")) { // For internal testing.
            resolve_everything = true;
            continue;
        }
        const extension = parseExtension(raw_extension, api) catch |err|
            return handleExtensionUserErrorAndExit(err, raw_extension, api, version, profile);
        extensions.put(extension, .{});
    }

    var types: ResolvedTypes = .{};
    var constants: ResolvedConstants = .{};
    var commands: ResolvedCommands = .{};
    if (resolve_everything)
        resolveEverything(&extensions, &types, &constants, &commands)
    else
        resolveQuery(api, version, profile, &extensions, &types, &constants, &commands);

    if (post_writergate) {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        try renderCode(stdout, api, version, profile, &extensions, &types, &constants, &commands);
        try stdout.flush();
    } else {
        var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
        const stdout = bw.writer();
        try renderCode(stdout, api, version, profile, &extensions, &types, &constants, &commands);
        try bw.flush();
    }
}

const ApiVersionProfile = struct {
    api: registry.Api.Name,
    version: [2]u8,
    profile: ?registry.ProfileName,

    fn parse(raw: []const u8) ParseError!ApiVersionProfile {
        var raw_it = std.mem.splitScalar(u8, raw, '-');
        const raw_api = raw_it.next().?;
        const raw_version = raw_it.next() orelse return error.MissingVersion;
        const maybe_raw_profile = raw_it.next();
        if (raw_it.next() != null) return error.UnknownExtraField;

        var api: registry.Api.Name = switch (inline for (@typeInfo(Options.Api).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw_api, field.name)) break @field(Options.Api, field.name);
        } else return error.InvalidApi) {
            .gl => .gl,
            .gles => .gles2,
            .glsc => .glsc2,
        };

        const version: [2]u8 = inline for (@typeInfo(Options.Version).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw_version, field.name)) {
                const dot = std.mem.indexOfScalar(u8, raw_version, '.').?;
                break .{
                    std.fmt.parseUnsigned(u8, raw_version[0..dot], 10) catch unreachable,
                    std.fmt.parseUnsigned(u8, raw_version[(dot + 1)..], 10) catch unreachable,
                };
            }
        } else return error.InvalidVersion;

        var maybe_profile: ?registry.ProfileName = if (maybe_raw_profile) |raw_profile|
            switch (inline for (@typeInfo(Options.Profile).@"enum".fields) |field| {
                if (std.mem.eql(u8, raw_profile, field.name)) break @field(Options.Profile, field.name);
            } else return error.InvalidProfile) {
                .core => .core,
                .compatibility => .compatibility,
                .common => .common,
                .common_lite => .common_lite,
            }
        else
            null;

        // Fix up API
        if (api == .gles2 and version[0] < 2) {
            api = .gles1;
        }

        // Validate version
        if (api == .gles1) {
            // GL ES 1.0/1.1 is an odd special case; the API Registry defines the feature set under
            // 1.0, but it includes features added in 1.1. Therefore, we only accept 1.1, even
            // though it's 1.0 in the registry.
            if (version[0] != 1 or version[1] != 1) return error.UnsupportedVersion;
        } else for (registry.apis) |reg_api| {
            if (reg_api.name == api and reg_api.version[0] == version[0] and reg_api.version[1] == version[1]) break;
        } else return error.UnsupportedVersion;

        // Validate/fix up profile
        switch (api) {
            .gl => {
                // The Core/Compatibility profiles were introduced in GL 3.2.
                if (version[0] < 3 or version[0] == 3 and version[1] < 2) {
                    if (maybe_profile != null) return error.UnsupportedProfile;
                } else if (maybe_profile) |profile| switch (profile) {
                    .core, .compatibility => {},
                    else => return error.UnsupportedProfile,
                } else {
                    maybe_profile = .core;
                }
            },
            .gles1 => {
                // The Common/Common-Lite profiles were introduced in GL ES 1.0.
                if (maybe_profile) |profile| switch (profile) {
                    .common, .common_lite => {},
                    else => return error.UnsupportedProfile,
                } else {
                    maybe_profile = .common;
                }
            },
            // The Common/Common-Lite profiles were dropped in GL ES 2.0 (and GL SC never had any).
            else => if (maybe_profile != null) return error.UnsupportedProfile,
        }

        return .{ .api = api, .version = version, .profile = maybe_profile };
    }

    const ParseError = error{
        InvalidApi,
        MissingVersion,
        InvalidVersion,
        UnsupportedVersion,
        InvalidProfile,
        UnsupportedProfile,
        UnknownExtraField,
    };
};

fn parseExtension(raw: []const u8, api: registry.Api.Name) ParseExtensionError!registry.Extension.Name {
    // Statically assert that 'api_registry.zig' and 'GeneratorOptions.zig' are in sync.
    comptime {
        @setEvalBranchQuota(100_000);
        for (@typeInfo(registry.Extension.Name).@"enum".fields, @typeInfo(Options.Extension).@"enum".fields) |a, b| {
            std.debug.assert(std.mem.eql(u8, a.name, b.name));
        }
    }

    const extension: registry.Extension.Name = inline for (@typeInfo(registry.Extension.Name).@"enum".fields) |field| {
        if (std.mem.eql(u8, raw, field.name)) break @field(registry.Extension.Name, field.name);
    } else return error.InvalidExtension;

    // Validate extension
    const reg_extension = for (registry.extensions) |reg_extension| {
        if (reg_extension.name == extension) break reg_extension;
    } else return error.UnsupportedExtension;
    if (std.mem.indexOfScalar(registry.Api.Name, reg_extension.apis, api) == null) return error.UnsupportedExtension;

    return extension;
}

const ParseExtensionError = error{
    InvalidExtension,
    UnsupportedExtension,
};

fn printUsageAndExit(exe_name: []const u8) noreturn {
    std.debug.print("Usage: {s} <api>-<version>[-<profile>] [<extension> ...]", .{std.fs.path.basename(exe_name)});
    std.process.exit(1);
}

fn handleApiVersionProfileUserErrorAndExit(
    err: ApiVersionProfile.ParseError,
    raw_triple: []const u8,
) noreturn {
    var raw_it = std.mem.splitScalar(u8, raw_triple, '-');
    const raw_api = raw_it.next().?;
    const raw_version = raw_it.next();
    const raw_profile = raw_it.next();
    const raw_extra = raw_it.next();
    switch (err) {
        error.InvalidApi,
        => std.log.err("API '{s}' is not a supported API", .{raw_api}),
        error.MissingVersion,
        => std.log.err("missing version field after API field", .{}),
        error.InvalidVersion,
        error.UnsupportedVersion,
        => std.log.err("version '{s}' is not a supported version of '{s}'", .{ raw_version.?, raw_api }),
        error.InvalidProfile,
        error.UnsupportedProfile,
        => std.log.err("profile '{s}' is not a supported profile of '{s}-{s}'", .{ raw_profile.?, raw_api, raw_version.? }),
        error.UnknownExtraField,
        => std.log.err("unknown extra value '{s}' after profile field", .{raw_extra.?}),
    }
    std.process.exit(1);
}

fn handleExtensionUserErrorAndExit(
    err: ParseExtensionError,
    raw_extension: []const u8,
    api: registry.Api.Name,
    version: [2]u8,
    profile: ?registry.ProfileName,
) noreturn {
    switch (err) {
        error.InvalidExtension,
        error.UnsupportedExtension,
        => std.log.err("extension '{s}' is not a supported extension of '{s}-{}.{}{s}{s}'", .{
            raw_extension,
            @tagName(api),
            version[0],
            version[1],
            if (profile != null) "-" else "",
            if (profile) |x| @tagName(x) else "",
        }),
    }
    std.process.exit(1);
}

comptime {
    @setEvalBranchQuota(100_000);
    _ = std.enums.EnumIndexer(registry.Extension.Name);
    _ = std.enums.EnumIndexer(registry.Type.Name);
    _ = std.enums.EnumIndexer(registry.Constant.Name);
    _ = std.enums.EnumIndexer(registry.Command.Name);
}

const ResolvedExtensions = std.EnumMap(registry.Extension.Name, struct {
    commands: std.EnumSet(registry.Command.Name) = .{},
});

const ResolvedTypes = std.EnumMap(registry.Type.Name, struct {
    requires: ?registry.Type.Name = null,
});

const ResolvedConstants = std.EnumMap(registry.Constant.Name, struct {
    value: i128,
});

const ResolvedCommands = std.EnumMap(registry.Command.Name, struct {
    params: []const registry.Command.Param,
    return_type_expr: []const registry.Command.Token,
    required: bool = false,
});

fn resolveQuery(
    api: registry.Api.Name,
    version: [2]u8,
    profile: ?registry.ProfileName,
    extensions: *ResolvedExtensions,
    types: *ResolvedTypes,
    constants: *ResolvedConstants,
    commands: *ResolvedCommands,
) void {
    // Add/remove API features
    for (registry.apis) |reg_api| {
        if (reg_api.name != api) continue;
        if (reg_api.version[0] > version[0] or reg_api.version[0] == version[0] and reg_api.version[1] > version[1]) continue;
        for (reg_api.remove) |feature| {
            std.debug.assert(feature.api == null);
            if (feature.profile != null and feature.profile != profile) continue;
            switch (feature.name) {
                .type => |name| types.remove(name),
                .constant => |name| constants.remove(name),
                .command => |name| commands.remove(name),
            }
        }
        for (reg_api.add) |feature| {
            std.debug.assert(feature.api == null);
            if (feature.profile != null and feature.profile != profile) continue;
            switch (feature.name) {
                .type => |name| _ = tryPutType(types, name),
                .constant => |name| _ = tryPutConstant(constants, name, api),
                .command => |name| _ = tryPutCommand(commands, name, true),
            }
        }
    }

    // Add extension features
    var extension_it = extensions.iterator();
    while (extension_it.next()) |extension| {
        for (registry.extensions) |reg_extension| {
            if (reg_extension.name != extension.key) continue;
            std.debug.assert(std.mem.indexOfScalar(registry.Api.Name, reg_extension.apis, api) != null);
            for (reg_extension.add) |feature| {
                if (feature.api != null and feature.api != api) continue;
                if (feature.profile != null and feature.profile != profile) continue;
                switch (feature.name) {
                    .type => |name| _ = tryPutType(types, name),
                    .constant => |name| _ = tryPutConstant(constants, name, api),
                    .command => |name| {
                        _ = tryPutCommand(commands, name, false);
                        extension.value.commands.insert(name);
                    },
                }
            }
            break;
        }
    }

    // Add command type dependencies
    var command_it = commands.iterator();
    while (command_it.next()) |command| {
        for (command.value.params) |param| for (param.type_expr) |token| switch (token) {
            .type => |name| _ = tryPutType(types, name),
            else => {},
        };
        for (command.value.return_type_expr) |token| switch (token) {
            .type => |name| _ = tryPutType(types, name),
            else => {},
        };
    }

    // Add type type dependencies
    while (true) {
        var mutated = false;
        var type_it = types.iterator();
        while (type_it.next()) |@"type"| {
            if (@"type".value.requires) |requires| if (tryPutType(types, requires)) {
                mutated = true;
            };
        }
        if (!mutated) break;
    }
}

fn tryPutType(types: *ResolvedTypes, name: registry.Type.Name) bool {
    if (types.contains(name)) return false;
    for (registry.types) |reg_type| {
        if (reg_type.name != name) continue;
        types.put(name, .{ .requires = reg_type.requires });
        return true;
    }
    unreachable;
}

fn tryPutConstant(constants: *ResolvedConstants, name: registry.Constant.Name, api: registry.Api.Name) bool {
    if (constants.contains(name)) return false;
    for (registry.constants) |reg_constant| {
        if (reg_constant.name != name) continue;
        if (reg_constant.api != null and reg_constant.api != api) continue;
        constants.put(name, .{ .value = reg_constant.value });
        return true;
    }
    unreachable;
}

fn tryPutCommand(commands: *ResolvedCommands, name: registry.Command.Name, required: bool) bool {
    if (commands.contains(name)) return false;
    for (registry.commands) |reg_command| {
        if (reg_command.name != name) continue;
        commands.put(name, .{
            .params = reg_command.params,
            .return_type_expr = reg_command.return_type_expr,
            .required = required,
        });
        return true;
    }
    unreachable;
}

fn resolveEverything(
    extensions: *ResolvedExtensions,
    types: *ResolvedTypes,
    constants: *ResolvedConstants,
    commands: *ResolvedCommands,
) void {
    @setEvalBranchQuota(100_000);
    for (std.enums.values(registry.Extension.Name)) |name| extensions.put(name, .{});
    for (std.enums.values(registry.Type.Name)) |name| _ = tryPutType(types, name);
    for (std.enums.values(registry.Constant.Name)) |name| _ = tryPutConstant(constants, name, .gl);
    for (std.enums.values(registry.Command.Name)) |name| _ = tryPutCommand(commands, name, false);
}

fn renderCode(
    writer: anytype,
    api: registry.Api.Name,
    version: [2]u8,
    profile: ?registry.ProfileName,
    extensions: *ResolvedExtensions,
    types: *ResolvedTypes,
    constants: *ResolvedConstants,
    commands: *ResolvedCommands,
) !void {
    const any_extensions = extensions.count() != 0;

    try writer.print("" ++
        // REUSE-IgnoreStart
        \\// © 2013-2025 The Khronos Group Inc.
        \\// © 2024 Carl Åstholm
        \\// SPDX-License-Identifier: Apache-2.0 AND MIT
        // REUSE-IgnoreEnd
        \\
        \\//! Bindings for {[api_pretty]s} {[version_major]d}.{[version_minor]d}{[sp_profile_pretty]s} generated by zigglgen.
        \\
        \\// OpenGL XML API Registry revision: {[registry_revision]s}
        \\// zigglgen version: 0.4.0
        \\
        \\// Example usage:
        \\//
        \\//     const windowing = @import(...);
        \\//     const gl = @import("gl");
        \\//
        \\//     // Procedure table that will hold OpenGL functions loaded at runtime.
        \\//     var procs: gl.ProcTable = undefined;
        \\//
        \\//     pub fn main() !void {{
        \\//         // Create an OpenGL context using a windowing system of your choice.
        \\//         const context = windowing.createContext(...);
        \\//         defer context.destroy();
        \\//
        \\//         // Make the OpenGL context current on the calling thread.
        \\//         windowing.makeContextCurrent(context);
        \\//         defer windowing.makeContextCurrent(null);
        \\//
        \\//         // Initialize the procedure table.
        \\//         if (!procs.init(windowing.getProcAddress)) return error.InitFailed;
        \\//
        \\//         // Make the procedure table current on the calling thread.
        \\//         gl.makeProcTableCurrent(&procs);
        \\//         defer gl.makeProcTableCurrent(null);
        \\//
        \\//         // Issue OpenGL commands to your heart's content!
        \\//         const alpha: gl.{[clear_color_type]s} = 1;
        \\//         gl.{[clear_color_fn]s}(1, 1, 1, alpha);
        \\//         gl.Clear(gl.COLOR_BUFFER_BIT);
        \\//     }}
        \\//
        \\
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\
        \\/// Information about this set of OpenGL bindings.
        \\pub const info = struct {{
        \\    pub const api: Api = {[api]s};
        \\    pub const version_major = {[version_major]d};
        \\    pub const version_minor = {[version_minor]d};
        \\    pub const profile: ?Profile = {[profile]s};
        \\
        \\    pub const Api = enum {{ gl, gles, glsc }};
        \\    pub const Profile = enum {{ core, compatibility, common, common_lite }};
        \\}};
        \\
    , .{
        .registry_revision = registry.revision,
        .api_pretty = switch (api) {
            .gl => "OpenGL",
            .gles1, .gles2 => "OpenGL ES",
            .glsc2 => "OpenGL SC",
        },
        .api = switch (api) {
            .gl => ".gl",
            .gles1, .gles2 => ".gles",
            .glsc2 => ".glsc",
        },
        .version_major = version[0],
        .version_minor = version[1],
        .sp_profile_pretty = if (profile) |x| switch (x) {
            .core => " (Core profile)",
            .compatibility => " (Compatibility profile)",
            .common => " (Common profile)",
            .common_lite => " (Common-Lite profile)",
        } else "",
        .profile = if (profile) |x| switch (x) {
            .core => ".core",
            .compatibility => ".compatibility",
            .common => ".common",
            .common_lite => ".common_lite",
        } else "null",
        .clear_color_type = if (profile == .common_lite) "fixed" else "float",
        .clear_color_fn = if (profile == .common_lite) "ClearColorx" else "ClearColor",
    });
    try writer.writeAll(
        \\
        \\/// Makes the specified procedure table current on the calling thread.
        \\///
        \\/// A valid procedure table must be made current on a thread before issuing any OpenGL commands from
        \\/// that same thread.
        \\pub fn makeProcTableCurrent(procs: ?*const ProcTable) void {
        \\    ProcTable.current = procs;
        \\}
        \\
        \\/// Returns the procedure table that is current on the calling thread.
        \\pub fn getCurrentProcTable() ?*const ProcTable {
        \\    return ProcTable.current;
        \\}
        \\
    );
    if (any_extensions) {
        try writer.writeAll(
            \\
            \\/// Returns `true` if the specified OpenGL extension is supported by the procedure table that is
            \\/// current on the calling thread, `false` otherwise.
            \\pub fn extensionSupported(comptime extension: Extension) bool {
            \\    return @field(ProcTable.current orelse return false, @tagName(extension));
            \\}
            \\
            \\/// OpenGL extension.
            \\pub const Extension = enum {
            \\
        );
        var extension_it = extensions.iterator();
        while (extension_it.next()) |extension| {
            try writer.print(
                \\    {f},
                \\
            , .{fmtIdFlags(@tagName(extension.key), .{ .allow_primitive = true })});
        }
        try writer.writeAll(
            \\};
            \\
        );
    }
    try writer.writeAll(
        \\
        \\pub const APIENTRY: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;
        \\pub const PROC = *align(@alignOf(fn () callconv(APIENTRY) void)) const anyopaque;
        \\
    );
    if (commands.contains(.DrawArraysIndirect) or
        commands.contains(.MultiDrawArraysIndirect) or
        commands.contains(.MultiDrawArraysIndirectCount))
    {
        try writer.writeAll(
            \\pub const DrawArraysIndirectCommand = extern struct { count: uint, instanceCount: uint, first: uint, baseInstance: uint };
            \\
        );
    }
    if (commands.contains(.DrawElementsIndirect) or
        commands.contains(.MultiDrawElementsIndirect) or
        commands.contains(.MultiDrawElementsIndirectCount))
    {
        try writer.writeAll(
            \\pub const DrawElementsIndirectCommand = extern struct { count: uint, instanceCount: uint, firstIndex: uint, baseVertex: int, baseInstance: uint };
            \\
        );
    }
    try writer.writeAll(
        \\
        \\//#region Types
        \\
    );
    var type_it = types.iterator();
    while (type_it.next()) |@"type"| {
        switch (@"type".key) {
            .khrplatform, .void => continue,
            else => {},
        }
        try writer.print(
            \\pub const {f} = {s};
            \\
        , .{ fmtIdFlags(@tagName(@"type".key), .{}), getTypeString(@"type".key) });
    }
    try writer.writeAll(
        \\//#endregion Types
        \\
        \\//#region Constants
        \\
    );
    var constant_it = constants.iterator();
    while (constant_it.next()) |constant| {
        try writer.print(
            \\pub const {f} = {s}0x{X};
            \\
        , .{ fmtIdFlags(@tagName(constant.key), .{}), if (constant.value.value < 0) "-" else "", @abs(constant.value.value) });
    }
    try writer.writeAll(
        \\//#endregion Constants
        \\
        \\//#region Commands
        \\
    );
    var command_it = commands.iterator();
    while (command_it.next()) |command| {
        try writer.print("pub fn {f}(", .{fmtIdFlags(@tagName(command.key), .{})});
        try renderParams(writer, command, false);
        try writer.writeAll(") callconv(APIENTRY) ");
        try renderReturnType(writer, command);
        try writer.print(" {{\n    return ProcTable.current.?.{f}", .{fmtIdFlags(@tagName(command.key), .{ .allow_primitive = true, .allow_underscore = true })});
        if (!command.value.required) try writer.writeAll(".?");
        try writer.writeAll("(");
        try renderParams(writer, command, true);
        try writer.writeAll(");\n}\n");
    }
    try writer.writeAll(
        \\//#endregion Commands
        \\
        \\/// Holds OpenGL features loaded at runtime.
        \\///
        \\/// This struct is very large; avoid storing instances of it on the stack.
        \\pub const ProcTable = struct {
        \\    threadlocal var current: ?*const ProcTable = null;
        \\
        \\    //#region Fields
        \\
    );
    if (any_extensions) {
        var extension_it = extensions.iterator();
        while (extension_it.next()) |extension| {
            try writer.print(
                \\    {f}: bool,
                \\
            , .{fmtIdFlags(@tagName(extension.key), .{ .allow_primitive = true, .allow_underscore = true })});
        }
    }
    command_it = commands.iterator();
    while (command_it.next()) |command| {
        try writer.print("    {f}: ", .{fmtIdFlags(@tagName(command.key), .{ .allow_primitive = true, .allow_underscore = true })});
        if (!command.value.required) try writer.writeAll("?");
        try writer.writeAll("*const fn (");
        try renderParams(writer, command, false);
        try writer.writeAll(") callconv(APIENTRY) ");
        try renderReturnType(writer, command);
        try writer.writeAll(",\n");
    }
    try writer.writeAll(
        \\    //#endregion Fields
        \\
        \\    /// Initializes the specified procedure table and returns `true` if successful,
        \\    /// `false` otherwise.
        \\    ///
        \\    /// A procedure table must be successfully initialized before passing it to
        \\    /// `makeProcTableCurrent` or accessing any of its fields.
        \\    ///
        \\    /// `loader` is duck-typed. Given the prefixed name of an OpenGL command (e.g. `"glClear"`), it
        \\    /// should return a pointer to the corresponding function. It should be able to be used in one
        \\    /// of the following two ways:
        \\    ///
        \\    /// - `@as(?PROC, loader(@as([*:0]const u8, prefixed_name)))`
        \\    /// - `@as(?PROC, loader.getProcAddress(@as([*:0]const u8, prefixed_name)))`
        \\    ///
        \\    /// If your windowing system has a "get procedure address" function, it is usually enough to
        \\    /// simply pass that function as the `loader` argument.
        \\    ///
        \\    /// No references to `loader` are retained after this function returns.
        \\    ///
        \\    /// There is no corresponding `deinit` function.
        \\    pub fn init(procs: *ProcTable, loader: anytype) bool {
        \\        @setEvalBranchQuota(1_000_000);
        \\        var success: u1 = 1;
        \\        inline for (@typeInfo(ProcTable).@"struct".fields) |field_info| {
        \\            switch (@typeInfo(field_info.type)) {
        \\                .pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
        \\                    .@"fn" => {
        \\                        success &= @intFromBool(procs.initCommand(loader, field_info.name));
        \\                    },
        \\                    else => comptime unreachable,
        \\                },
        \\
    );
    if (any_extensions) {
        try writer.writeAll(
            \\                .optional => |opt_info| switch (@typeInfo(opt_info.child)) {
            \\                    .pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
            \\                        .@"fn" => {
            \\                            @field(procs, field_info.name) = null;
            \\                        },
            \\                        else => comptime unreachable,
            \\                    },
            \\                    else => comptime unreachable,
            \\                },
            \\                .bool => {
            \\                    @field(procs, field_info.name) = false;
            \\                },
            \\
        );
    }
    try writer.writeAll(
        \\                else => comptime unreachable,
        \\            }
        \\        }
        \\
    );
    if (any_extensions) {
        try writer.writeAll(
            \\        if (success == 0) return false;
            \\
        );
        var extension_it = extensions.iterator();
        while (extension_it.next()) |extension| {
            if (extension.value.commands.count() != 0) {
                try writer.print(
                    \\        if (procs.initExtension("{s}")) {{
                    \\
                , .{@tagName(extension.key)});
                var extension_command_it = extension.value.commands.iterator();
                while (extension_command_it.next()) |extension_command| {
                    try writer.print(
                        \\            _ = procs.initCommand(loader, "{s}");
                        \\
                    , .{@tagName(extension_command)});
                }
                try writer.writeAll(
                    \\        }
                    \\
                );
            } else {
                try writer.print(
                    \\        _ = procs.initExtension("{s}");
                    \\
                , .{@tagName(extension.key)});
            }
        }
        try writer.writeAll(
            \\        return true;
            \\
        );
    } else {
        try writer.writeAll(
            \\        return success != 0;
            \\
        );
    }
    try writer.writeAll(
        \\    }
        \\
        \\    fn initCommand(procs: *ProcTable, loader: anytype, comptime name: [:0]const u8) bool {
        \\        if (getProcAddress(loader, "gl" ++ name)) |proc| {
        \\            @field(procs, name) = @ptrCast(proc);
        \\            return true;
        \\        } else {
        \\            return @typeInfo(@TypeOf(@field(procs, name))) == .optional;
        \\        }
        \\    }
        \\
        \\    fn getProcAddress(loader: anytype, prefixed_name: [:0]const u8) ?PROC {
        \\        const loader_info = @typeInfo(@TypeOf(loader));
        \\        const loader_is_fn =
        \\            loader_info == .@"fn" or
        \\            loader_info == .pointer and @typeInfo(loader_info.pointer.child) == .@"fn";
        \\        if (loader_is_fn) {
        \\            return @as(?PROC, loader(@as([*:0]const u8, prefixed_name)));
        \\        } else {
        \\            return @as(?PROC, loader.getProcAddress(@as([*:0]const u8, prefixed_name)));
        \\        }
        \\    }
        \\
    );
    if (any_extensions) {
        try writer.writeAll(
            \\
            \\    fn initExtension(procs: *ProcTable, comptime name: [:0]const u8) bool {
            \\
        );
        if (version[0] >= 3) {
            // GL 3.0 and GL ES 3.0 both introduced querying extensions by index via 'GetStringi'.
            // Starting with GL 3.2, querying extensions via 'GetString' is no longer supported
            // under the Core profile.
            try writer.writeAll(
                \\        var count: c_int = 0;
                \\        procs.GetIntegerv(NUM_EXTENSIONS, (&count)[0..1]);
                \\        if (count < 0) return false;
                \\        var i: c_uint = 0;
                \\        while (i < @as(c_uint, @intCast(count))) : (i += 1) {
                \\            const prefixed_name = procs.GetStringi(EXTENSIONS, i) orelse return false;
                \\            if (std.mem.orderZ(u8, prefixed_name, "GL_" ++ name) == .eq) {
                \\
            );
        } else {
            try writer.writeAll(
                \\        const prefixed_names = procs.GetString(EXTENSIONS) orelse return false;
                \\        var it = std.mem.tokenizeScalar(u8, std.mem.span(prefixed_names), ' ');
                \\        while (it.next()) |prefixed_name| {
                \\            if (std.mem.eql(u8, prefixed_name, "GL_" ++ name)) {
                \\
            );
        }
        try writer.writeAll(
            \\                @field(procs, name) = true;
            \\                return true;
            \\            }
            \\        }
            \\        return false;
            \\    }
            \\
        );
    }
    try writer.writeAll(
        \\};
        \\
        \\test {
        \\    @setEvalBranchQuota(1_000_000);
        \\    std.testing.refAllDeclsRecursive(@This());
        \\}
        \\
    );
}

const fmtIdFlags = if (post_writergate) std.zig.fmtIdFlags else fmtIdFlagsPreWritergate;

fn fmtIdFlagsPreWritergate(bytes: []const u8, flags: FormatIdFlags) std.fmt.Formatter(formatIdFlagsPreWritergate) {
    return .{ .data = .{ .bytes = bytes, .flags = flags } };
}

const FormatIdFlags = struct {
    allow_primitive: bool = false,
    allow_underscore: bool = false,
};

fn formatIdFlagsPreWritergate(
    ctx: struct {
        bytes: []const u8,
        flags: FormatIdFlags,
    },
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    const bytes = ctx.bytes;
    if (std.zig.isValidId(bytes) and
        (ctx.flags.allow_primitive or !std.zig.isPrimitive(bytes)) and
        (ctx.flags.allow_underscore or !std.zig.isUnderscore(bytes)))
    {
        return writer.writeAll(bytes);
    }
    try writer.writeAll("@\"");
    try std.zig.stringEscape(bytes, "", .{}, writer);
    try writer.writeByte('"');
}

const fmtTypeExpr = if (post_writergate) fmtTypeExprPostWritergate else fmtTypeExprPreWritergate;

fn fmtTypeExprPostWritergate(type_expr: []const registry.Command.Token) std.fmt.Alt([]const registry.Command.Token, formatTypeExprPostWritergate) {
    return .{ .data = type_expr };
}

fn formatTypeExprPostWritergate(
    type_expr: []const registry.Command.Token,
    writer: *std.Io.Writer,
) !void {
    if (type_expr.len == 1 and type_expr[0] == .void) {
        return writer.writeAll("void");
    }
    for (type_expr, 0..) |token, token_index| switch (token) {
        .void => try writer.writeAll("anyopaque"),
        .@"*" => {
            try writer.writeAll(
                if (type_expr[type_expr.len - 1] == .void and for (type_expr[(token_index + 1)..]) |future_token| {
                    if (future_token == .@"*") break false;
                } else true)
                    "?*"
                else
                    "[*c]",
            );
        },
        .@"const" => try writer.writeAll("const "),
        .type => |@"type"| try writer.print("{f}", .{std.zig.fmtId(@tagName(@"type"))}),
    };
}

fn fmtTypeExprPreWritergate(type_expr: []const registry.Command.Token) std.fmt.Formatter(formatTypeExprPreWritergate) {
    return .{ .data = type_expr };
}

fn formatTypeExprPreWritergate(
    type_expr: []const registry.Command.Token,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    if (type_expr.len == 1 and type_expr[0] == .void) {
        return writer.writeAll("void");
    }
    for (type_expr, 0..) |token, token_index| switch (token) {
        .void => try writer.writeAll("anyopaque"),
        .@"*" => {
            try writer.writeAll(
                if (type_expr[type_expr.len - 1] == .void and for (type_expr[(token_index + 1)..]) |future_token| {
                    if (future_token == .@"*") break false;
                } else true)
                    "?*"
                else
                    "[*c]",
            );
        },
        .@"const" => try writer.writeAll("const "),
        .type => |@"type"| try writer.print("{}", .{std.zig.fmtId(@tagName(@"type"))}),
    };
}

fn getTypeString(@"type": registry.Type.Name) []const u8 {
    return switch (@"type") {
        .DEBUGPROC,
        .DEBUGPROCARB,
        .DEBUGPROCKHR,
        => "*const fn (source: @\"enum\", @\"type\": @\"enum\", id: uint, severity: @\"enum\", length: sizei, message: [*:0]const char, userParam: ?*const anyopaque) callconv(APIENTRY) void",
        .DEBUGPROCAMD,
        => "*const fn (id: uint, category: @\"enum\", severity: @\"enum\", length: sizei, message: [*:0]const char, userParam: ?*anyopaque) callconv(APIENTRY) void",
        .VULKANPROCNV,
        => "*const fn () callconv(APIENTRY) void",
        .bitfield,
        => "c_uint",
        .boolean,
        => "u8",
        .byte,
        => "i8",
        .char,
        .charARB,
        => "u8",
        .cl_context,
        .cl_event,
        => "opaque {}",
        .clampd,
        => "f64",
        .clampf,
        => "f32",
        .clampx,
        => "i32",
        .double,
        => "f64",
        .eglClientBufferEXT,
        .eglImageOES,
        => "opaque {}",
        .@"enum",
        => "c_uint",
        .fixed,
        => "i32",
        .float,
        => "f32",
        .half,
        .halfARB,
        => "u16",
        .halfNV,
        => "c_ushort",
        .handleARB,
        => "if (builtin.os.tag.isDarwin()) usize else u32",
        .int,
        => "c_int",
        .int64,
        .int64EXT,
        => "i64",
        .intptr,
        .intptrARB,
        => "isize",
        .khrplatform,
        => unreachable,
        .short,
        => "i16",
        .sizei,
        => "c_int",
        .sizeiptr,
        .sizeiptrARB,
        => "isize",
        .sync,
        => "opaque {}",
        .ubyte,
        => "u8",
        .uint,
        => "c_uint",
        .uint64,
        .uint64EXT,
        => "u64",
        .ushort,
        => "u16",
        .vdpauSurfaceNV,
        => "intptr",
        .void,
        => unreachable,
    };
}

fn renderParams(writer: anytype, command: ResolvedCommands.Entry, comptime name_only: bool) !void {
    for (command.value.params, 0..) |param, param_index| {
        if (param_index != 0) try writer.writeAll(", ");
        if (paramOverride(command.key, param_index)) |override| {
            const override_name, const override_type_string = override;
            try writer.print("{f}", .{fmtIdFlags(override_name, .{})});
            if (!name_only) {
                try writer.print(": {s}", .{override_type_string});
            }
        } else {
            try writer.print("{f}", .{fmtIdFlags(param.name, .{})});
            if (!name_only) {
                try writer.print(": {f}", .{fmtTypeExpr(param.type_expr)});
            }
        }
    }
}

fn paramOverride(command: registry.Command.Name, param_index: usize) ?struct { []const u8, []const u8 } {
    return switch (command) {
        .AreTexturesResident,
        => switch (param_index) {
            1 => .{ "textures", "[*]const uint" },
            2 => .{ "residences", "[*]boolean" },
            else => null,
        },
        .BindAttribLocation,
        => switch (param_index) {
            2 => .{ "name", "[*:0]const char" },
            else => null,
        },
        .BindAttribLocationARB,
        => switch (param_index) {
            2 => .{ "name", "[*:0]const charARB" },
            else => null,
        },
        .BindBuffersBase,
        => switch (param_index) {
            3 => .{ "buffers", "?[*]const uint" },
            else => null,
        },
        .BindBuffersRange,
        => switch (param_index) {
            3 => .{ "buffers", "?[*]const uint" },
            4 => .{ "offsets", "?[*]const intptr" },
            5 => .{ "sizes", "?[*]const sizeiptr" },
            else => null,
        },
        .BindFragDataLocation,
        => switch (param_index) {
            1 => .{ "colorNumber", "uint" },
            2 => .{ "name", "[*:0]const char" },
            else => null,
        },
        .BindFragDataLocationIndexed,
        => switch (param_index) {
            3 => .{ "name", "[*:0]const char" },
            else => null,
        },
        .BindImageTextures,
        => switch (param_index) {
            2 => .{ "textures", "?[*]const uint" },
            else => null,
        },
        .BindSamplers,
        => switch (param_index) {
            2 => .{ "samplers", "?[*]const uint" },
            else => null,
        },
        .BindTextures,
        => switch (param_index) {
            2 => .{ "textures", "?[*]const uint" },
            else => null,
        },
        .BindVertexBuffers,
        => switch (param_index) {
            2 => .{ "buffers", "?[*]const uint" },
            3 => .{ "offsets", "?[*]const intptr" },
            4 => .{ "strides", "?[*]const sizei" },
            else => null,
        },
        .Bitmap,
        => switch (param_index) {
            0 => .{ "w", "sizei" },
            1 => .{ "h", "sizei" },
            2 => .{ "xbo", "float" },
            3 => .{ "ybo", "float" },
            4 => .{ "xbi", "float" },
            5 => .{ "ybi", "float" },
            6 => .{ "data", "[*]const ubyte" },
            else => null,
        },
        .BlendFunc,
        => switch (param_index) {
            0 => .{ "src", "@\"enum\"" },
            1 => .{ "dst", "@\"enum\"" },
            else => null,
        },
        .BlendFuncSeparate,
        => switch (param_index) {
            0 => .{ "srcRGB", "@\"enum\"" },
            1 => .{ "dstRGB", "@\"enum\"" },
            2 => .{ "srcAlpha", "@\"enum\"" },
            3 => .{ "dstAlpha", "@\"enum\"" },
            else => null,
        },
        .BufferData,
        .BufferDataARB,
        => switch (param_index) {
            2 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .BufferStorage,
        => switch (param_index) {
            2 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .BufferSubData,
        => switch (param_index) {
            3 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .BufferStorageExternalEXT,
        => switch (param_index) {
            3 => .{ "clientBuffer", "*eglClientBufferEXT" },
            else => null,
        },
        .CallList,
        => switch (param_index) {
            0 => .{ "n", "uint" },
            else => null,
        },
        .CallLists,
        => switch (param_index) {
            2 => .{ "lists", "*const anyopaque" },
            else => null,
        },
        .Clear,
        => switch (param_index) {
            0 => .{ "buf", "bitfield" },
            else => null,
        },
        .ClearAccum,
        => switch (param_index) {
            0 => .{ "r", "float" },
            1 => .{ "g", "float" },
            2 => .{ "b", "float" },
            3 => .{ "a", "float" },
            else => null,
        },
        .ClearBufferiv,
        => switch (param_index) {
            2 => .{ "value", "[*]const int" },
            else => null,
        },
        .ClearBufferfv,
        => switch (param_index) {
            2 => .{ "value", "[*]const float" },
            else => null,
        },
        .ClearBufferuiv,
        => switch (param_index) {
            2 => .{ "value", "[*]const uint" },
            else => null,
        },
        .ClearBufferData,
        => switch (param_index) {
            4 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .ClearBufferSubData,
        => switch (param_index) {
            6 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .ClearColor,
        => switch (param_index) {
            0 => .{ "r", "float" },
            1 => .{ "g", "float" },
            2 => .{ "b", "float" },
            3 => .{ "a", "float" },
            else => null,
        },
        .ClearColorx,
        => switch (param_index) {
            0 => .{ "r", "fixed" },
            1 => .{ "g", "fixed" },
            2 => .{ "b", "fixed" },
            3 => .{ "a", "fixed" },
            else => null,
        },
        .ClearDepth,
        => switch (param_index) {
            0 => .{ "d", "double" },
            else => null,
        },
        .ClearDepthx,
        => switch (param_index) {
            0 => .{ "d", "fixed" },
            else => null,
        },
        .ClearDepthf,
        => switch (param_index) {
            0 => .{ "d", "float" },
            else => null,
        },
        .ClearIndex,
        => switch (param_index) {
            0 => .{ "c", "float" },
            else => null,
        },
        .ClearNamedBufferData,
        => switch (param_index) {
            4 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .ClearNamedBufferSubData,
        => switch (param_index) {
            6 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .ClearNamedFramebufferiv,
        => switch (param_index) {
            3 => .{ "value", "[*]const int" },
            else => null,
        },
        .ClearNamedFramebufferfv,
        => switch (param_index) {
            3 => .{ "value", "[*]const float" },
            else => null,
        },
        .ClearNamedFramebufferuiv,
        => switch (param_index) {
            3 => .{ "value", "[*]const uint" },
            else => null,
        },
        .ClearTexImage,
        => switch (param_index) {
            4 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .ClearTexSubImage,
        => switch (param_index) {
            10 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .ClientWaitSync,
        .ClientWaitSyncAPPLE,
        => switch (param_index) {
            0 => .{ "sync_", "*sync" },
            else => null,
        },
        .ClipPlane,
        => switch (param_index) {
            0 => .{ "p", "@\"enum\"" },
            1 => .{ "eqn", "*const [4]double" },
            else => null,
        },
        .ClipPlanex,
        => switch (param_index) {
            0 => .{ "p", "@\"enum\"" },
            1 => .{ "eqn", "*const [4]fixed" },
            else => null,
        },
        .ClipPlanef,
        => switch (param_index) {
            0 => .{ "p", "@\"enum\"" },
            1 => .{ "eqn", "*const [4]float" },
            else => null,
        },
        .Color3b,
        => switch (param_index) {
            0 => .{ "r", "byte" },
            1 => .{ "g", "byte" },
            2 => .{ "b", "byte" },
            else => null,
        },
        .Color3bv,
        => switch (param_index) {
            0 => .{ "components", "*const [3]byte" },
            else => null,
        },
        .Color3s,
        => switch (param_index) {
            0 => .{ "r", "short" },
            1 => .{ "g", "short" },
            2 => .{ "b", "short" },
            else => null,
        },
        .Color3sv,
        => switch (param_index) {
            0 => .{ "components", "*const [3]short" },
            else => null,
        },
        .Color3i,
        => switch (param_index) {
            0 => .{ "r", "int" },
            1 => .{ "g", "int" },
            2 => .{ "b", "int" },
            else => null,
        },
        .Color3iv,
        => switch (param_index) {
            0 => .{ "components", "*const [3]int" },
            else => null,
        },
        .Color3f,
        => switch (param_index) {
            0 => .{ "r", "float" },
            1 => .{ "g", "float" },
            2 => .{ "b", "float" },
            else => null,
        },
        .Color3fv,
        => switch (param_index) {
            0 => .{ "components", "*const [3]float" },
            else => null,
        },
        .Color3d,
        => switch (param_index) {
            0 => .{ "r", "double" },
            1 => .{ "g", "double" },
            2 => .{ "b", "double" },
            else => null,
        },
        .Color3dv,
        => switch (param_index) {
            0 => .{ "components", "*const [3]double" },
            else => null,
        },
        .Color3ub,
        => switch (param_index) {
            0 => .{ "r", "ubyte" },
            1 => .{ "g", "ubyte" },
            2 => .{ "b", "ubyte" },
            else => null,
        },
        .Color3ubv,
        => switch (param_index) {
            0 => .{ "components", "*const [3]ubyte" },
            else => null,
        },
        .Color3us,
        => switch (param_index) {
            0 => .{ "r", "ushort" },
            1 => .{ "g", "ushort" },
            2 => .{ "b", "ushort" },
            else => null,
        },
        .Color3usv,
        => switch (param_index) {
            0 => .{ "components", "*const [3]ushort" },
            else => null,
        },
        .Color3ui,
        => switch (param_index) {
            0 => .{ "r", "uint" },
            1 => .{ "g", "uint" },
            2 => .{ "b", "uint" },
            else => null,
        },
        .Color3uiv,
        => switch (param_index) {
            0 => .{ "components", "*const [3]uint" },
            else => null,
        },
        .Color4b,
        => switch (param_index) {
            0 => .{ "r", "byte" },
            1 => .{ "g", "byte" },
            2 => .{ "b", "byte" },
            3 => .{ "a", "byte" },
            else => null,
        },
        .Color4bv,
        => switch (param_index) {
            0 => .{ "components", "*const [4]byte" },
            else => null,
        },
        .Color4s,
        => switch (param_index) {
            0 => .{ "r", "short" },
            1 => .{ "g", "short" },
            2 => .{ "b", "short" },
            3 => .{ "a", "short" },
            else => null,
        },
        .Color4sv,
        => switch (param_index) {
            0 => .{ "components", "*const [4]short" },
            else => null,
        },
        .Color4i,
        => switch (param_index) {
            0 => .{ "r", "int" },
            1 => .{ "g", "int" },
            2 => .{ "b", "int" },
            3 => .{ "a", "int" },
            else => null,
        },
        .Color4iv,
        => switch (param_index) {
            0 => .{ "components", "*const [4]int" },
            else => null,
        },
        .Color4x,
        => switch (param_index) {
            0 => .{ "r", "fixed" },
            1 => .{ "g", "fixed" },
            2 => .{ "b", "fixed" },
            3 => .{ "a", "fixed" },
            else => null,
        },
        .Color4f,
        => switch (param_index) {
            0 => .{ "r", "float" },
            1 => .{ "g", "float" },
            2 => .{ "b", "float" },
            3 => .{ "a", "float" },
            else => null,
        },
        .Color4fv,
        => switch (param_index) {
            0 => .{ "components", "*const [4]float" },
            else => null,
        },
        .Color4d,
        => switch (param_index) {
            0 => .{ "r", "double" },
            1 => .{ "g", "double" },
            2 => .{ "b", "double" },
            3 => .{ "a", "double" },
            else => null,
        },
        .Color4dv,
        => switch (param_index) {
            0 => .{ "components", "*const [4]double" },
            else => null,
        },
        .Color4ub,
        => switch (param_index) {
            0 => .{ "r", "ubyte" },
            1 => .{ "g", "ubyte" },
            2 => .{ "b", "ubyte" },
            3 => .{ "a", "ubyte" },
            else => null,
        },
        .Color4ubv,
        => switch (param_index) {
            0 => .{ "components", "*const [4]ubyte" },
            else => null,
        },
        .Color4us,
        => switch (param_index) {
            0 => .{ "r", "ushort" },
            1 => .{ "g", "ushort" },
            2 => .{ "b", "ushort" },
            3 => .{ "a", "ushort" },
            else => null,
        },
        .Color4usv,
        => switch (param_index) {
            0 => .{ "components", "*const [4]ushort" },
            else => null,
        },
        .Color4ui,
        => switch (param_index) {
            0 => .{ "r", "uint" },
            1 => .{ "g", "uint" },
            2 => .{ "b", "uint" },
            3 => .{ "a", "uint" },
            else => null,
        },
        .Color4uiv,
        => switch (param_index) {
            0 => .{ "components", "*const [4]uint" },
            else => null,
        },
        .ColorMask,
        => switch (param_index) {
            0 => .{ "r", "boolean" },
            1 => .{ "g", "boolean" },
            2 => .{ "b", "boolean" },
            3 => .{ "a", "boolean" },
            else => null,
        },
        .ColorMaski,
        => switch (param_index) {
            0 => .{ "buf", "uint" },
            1 => .{ "r", "boolean" },
            2 => .{ "g", "boolean" },
            3 => .{ "b", "boolean" },
            4 => .{ "a", "boolean" },
            else => null,
        },
        .ColorP3ui,
        => switch (param_index) {
            1 => .{ "coords", "uint" },
            else => null,
        },
        .ColorP3uiv,
        => switch (param_index) {
            1 => .{ "coords", "*const uint" },
            else => null,
        },
        .ColorP4ui,
        => switch (param_index) {
            1 => .{ "coords", "uint" },
            else => null,
        },
        .ColorP4uiv,
        => switch (param_index) {
            1 => .{ "coords", "*const uint" },
            else => null,
        },
        .ColorPointer,
        => switch (param_index) {
            3 => .{ "pointer", "usize" },
            else => null,
        },
        .ColorSubTable,
        .ColorSubTableEXT,
        => switch (param_index) {
            5 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .ColorTable,
        .ColorTableEXT,
        => switch (param_index) {
            5 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .ColorTableSGI,
        => switch (param_index) {
            5 => .{ "table", "?*const anyopaque" },
            else => null,
        },
        .ColorTableParameteriv,
        => switch (param_index) {
            2 => .{ "params", "*const [4]int" },
            else => null,
        },
        .ColorTableParameterfv,
        => switch (param_index) {
            2 => .{ "params", "*const [4]float" },
            else => null,
        },
        .CompressedTexImage1D,
        => switch (param_index) {
            6 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .CompressedTexImage2D,
        => switch (param_index) {
            7 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .CompressedTexImage3D,
        => switch (param_index) {
            8 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .CompressedTexSubImage1D,
        => switch (param_index) {
            6 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .CompressedTexSubImage2D,
        => switch (param_index) {
            8 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .CompressedTexSubImage3D,
        => switch (param_index) {
            10 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .CompressedTextureSubImage1D,
        => switch (param_index) {
            6 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .CompressedTextureSubImage2D,
        => switch (param_index) {
            8 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .CompressedTextureSubImage3D,
        => switch (param_index) {
            10 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .ConvolutionFilter1D,
        => switch (param_index) {
            5 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .ConvolutionFilter2D,
        => switch (param_index) {
            6 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .ConvolutionParameteri,
        => switch (param_index) {
            2 => .{ "param", "int" },
            else => null,
        },
        .ConvolutionParameteriv,
        => switch (param_index) {
            2 => .{ "params", "*const [4]int" },
            else => null,
        },
        .ConvolutionParameterf,
        => switch (param_index) {
            2 => .{ "param", "float" },
            else => null,
        },
        .ConvolutionParameterfv,
        => switch (param_index) {
            2 => .{ "params", "*const [4]float" },
            else => null,
        },
        .CopyColorSubTable,
        => switch (param_index) {
            4 => .{ "count", "sizei" },
            else => null,
        },
        .CreateBuffers,
        => switch (param_index) {
            1 => .{ "buffers", "[*]uint" },
            else => null,
        },
        .CreateFramebuffers,
        => switch (param_index) {
            1 => .{ "framebuffers", "[*]uint" },
            else => null,
        },
        .CreateProgramPipelines,
        => switch (param_index) {
            1 => .{ "pipelines", "[*]uint" },
            else => null,
        },
        .CreateQueries,
        => switch (param_index) {
            2 => .{ "ids", "[*]uint" },
            else => null,
        },
        .CreateRenderbuffers,
        => switch (param_index) {
            1 => .{ "renderbuffers", "[*]uint" },
            else => null,
        },
        .CreateSamplers,
        => switch (param_index) {
            1 => .{ "samplers", "[*]uint" },
            else => null,
        },
        .CreateShaderProgramv,
        => switch (param_index) {
            2 => .{ "strings", "[*]const [*:0]const char" },
            else => null,
        },
        .CreateSyncFromCLeventARB,
        => switch (param_index) {
            0 => .{ "context", "*cl_context" },
            1 => .{ "event", "*cl_event" },
            else => null,
        },
        .CreateTextures,
        => switch (param_index) {
            2 => .{ "textures", "[*]uint" },
            else => null,
        },
        .CreateVertexArrays,
        => switch (param_index) {
            2 => .{ "arrays", "[*]uint" },
            else => null,
        },
        .DebugMessageCallback,
        => switch (param_index) {
            0 => .{ "callback", "?DEBUGPROC" },
            1 => .{ "userParam", "?*const anyopaque" },
            else => null,
        },
        .DebugMessageCallbackARB,
        => switch (param_index) {
            0 => .{ "callback", "?DEBUGPROCARB" },
            1 => .{ "userParam", "?*const anyopaque" },
            else => null,
        },
        .DebugMessageCallbackKHR,
        => switch (param_index) {
            0 => .{ "callback", "?DEBUGPROCKHR" },
            1 => .{ "userParam", "?*const anyopaque" },
            else => null,
        },
        .DebugMessageCallbackAMD,
        => switch (param_index) {
            0 => .{ "callback", "?DEBUGPROCAMD" },
            1 => .{ "userParam", "?*anyopaque" },
            else => null,
        },
        .DebugMessageControl,
        .DebugMessageControlARB,
        .DebugMessageControlKHR,
        => switch (param_index) {
            4 => .{ "ids", "?[*]const uint" },
            else => null,
        },
        .DebugMessageEnableAMD,
        => switch (param_index) {
            3 => .{ "ids", "?[*]const uint" },
            else => null,
        },
        .DebugMessageInsert,
        .DebugMessageInsertARB,
        .DebugMessageInsertKHR,
        => switch (param_index) {
            5 => .{ "buf", "[*]const char" },
            else => null,
        },
        .DebugMessageInsertAMD,
        => switch (param_index) {
            4 => .{ "buf", "[*]const char" },
            else => null,
        },
        .DeleteBuffers,
        .DeleteBuffersARB,
        => switch (param_index) {
            1 => .{ "buffers", "[*]const uint" },
            else => null,
        },
        .DeleteFramebuffers,
        .DeleteFramebuffersEXT,
        .DeleteFramebuffersOES,
        => switch (param_index) {
            1 => .{ "framebuffers", "[*]const uint" },
            else => null,
        },
        .DeleteProgramPipelines,
        .DeleteProgramPipelinesEXT,
        => switch (param_index) {
            1 => .{ "pipelines", "[*]const uint" },
            else => null,
        },
        .DeleteProgramsARB,
        => switch (param_index) {
            1 => .{ "programs", "[*]const uint" },
            else => null,
        },
        .DeleteProgramsNV,
        .DeleteQueries,
        .DeleteQueriesARB,
        .DeleteQueriesEXT,
        => switch (param_index) {
            1 => .{ "ids", "[*]const uint" },
            else => null,
        },
        .DeleteRenderbuffers,
        .DeleteRenderbuffersEXT,
        .DeleteRenderbuffersOES,
        => switch (param_index) {
            1 => .{ "renderbuffers", "[*]const uint" },
            else => null,
        },
        .DeleteSamplers,
        => switch (param_index) {
            1 => .{ "samplers", "[*]const uint" },
            else => null,
        },
        .DeleteSync,
        .DeleteSyncAPPLE,
        => switch (param_index) {
            0 => .{ "sync_", "?*sync" },
            else => null,
        },
        .DeleteTextures,
        .DeleteTexturesEXT,
        => switch (param_index) {
            1 => .{ "textures", "[*]const uint" },
            else => null,
        },
        .DeleteTransformFeedbacks,
        .DeleteTransformFeedbacksNV,
        => switch (param_index) {
            1 => .{ "ids", "[*]const uint" },
            else => null,
        },
        .DeleteVertexArrays,
        .DeleteVertexArraysAPPLE,
        .DeleteVertexArraysOES,
        => switch (param_index) {
            1 => .{ "arrays", "[*]const uint" },
            else => null,
        },
        .DepthRangeArrayv,
        => switch (param_index) {
            2 => .{ "v", "[*]const [2]double" },
            else => null,
        },
        .Disable,
        => switch (param_index) {
            0 => .{ "target", "@\"enum\"" },
            else => null,
        },
        .DrawArraysIndirect,
        => switch (param_index) {
            1 => .{ "indirect", "usize" },
            else => null,
        },
        .DrawBuffers,
        .DrawBuffersARB,
        .DrawBuffersEXT,
        .DrawBuffersATI,
        .DrawBuffersNV,
        => switch (param_index) {
            1 => .{ "bufs", "[*]const @\"enum\"" },
            else => null,
        },
        .DrawElements,
        .DrawElementsBaseVertex,
        .DrawElementsBaseVertexEXT,
        .DrawElementsBaseVertexOES,
        => switch (param_index) {
            3 => .{ "indices", "usize" },
            else => null,
        },
        .DrawElementsIndirect,
        => switch (param_index) {
            2 => .{ "indirect", "usize" },
            else => null,
        },
        .DrawElementsInstanced,
        .DrawElementsInstancedARB,
        .DrawElementsInstancedEXT,
        .DrawElementsInstancedANGLE,
        .DrawElementsInstancedNV,
        .DrawElementsInstancedBaseInstance,
        .DrawElementsInstancedBaseInstanceEXT,
        .DrawElementsInstancedBaseVertex,
        .DrawElementsInstancedBaseVertexEXT,
        .DrawElementsInstancedBaseVertexBaseInstance,
        .DrawElementsInstancedBaseVertexBaseInstanceEXT,
        => switch (param_index) {
            3 => .{ "indices", "usize" },
            else => null,
        },
        .DrawPixels,
        => switch (param_index) {
            4 => .{ "pixels", "?*const anyopaque" },
            else => null,
        },
        .DrawRangeElements,
        .DrawRangeElementsEXT,
        .DrawRangeElementsBaseVertex,
        .DrawRangeElementsBaseVertexEXT,
        .DrawRangeElementsBaseVertexOES,
        => switch (param_index) {
            5 => .{ "indices", "usize" },
            else => null,
        },
        .EGLImageTargetRenderbufferStorageOES,
        => switch (param_index) {
            1 => .{ "image", "*eglImageOES" },
            else => null,
        },
        .EGLImageTargetTexStorageEXT,
        => switch (param_index) {
            1 => .{ "image", "*eglImageOES" },
            2 => .{ "attrib_list", "?[*:NONE]const int" },
            else => null,
        },
        .EGLImageTargetTexture2DOES,
        => switch (param_index) {
            1 => .{ "image", "*eglImageOES" },
            else => null,
        },
        .EGLImageTargetTextureStorageEXT,
        => switch (param_index) {
            1 => .{ "image", "*eglImageOES" },
            2 => .{ "attrib_list", "?[*:NONE]const int" },
            else => null,
        },
        .EdgeFlagPointer,
        => switch (param_index) {
            1 => .{ "pointer", "usize" },
            else => null,
        },
        .Enable,
        => switch (param_index) {
            0 => .{ "target", "@\"enum\"" },
            else => null,
        },
        .EvalCoord1fv,
        => switch (param_index) {
            0 => .{ "arg", "*const float" },
            else => null,
        },
        .EvalCoord1dv,
        => switch (param_index) {
            0 => .{ "arg", "*const double" },
            else => null,
        },
        .EvalCoord2fv,
        => switch (param_index) {
            0 => .{ "arg", "*const [2]float" },
            else => null,
        },
        .EvalCoord2dv,
        => switch (param_index) {
            0 => .{ "arg", "*const [2]double" },
            else => null,
        },
        .FeedbackBuffer,
        => switch (param_index) {
            0 => .{ "n", "sizei" },
            2 => .{ "buffer", "[*]float" },
            else => null,
        },
        .Fogiv,
        => switch (param_index) {
            1 => .{ "params", "[*]const int" },
            else => null,
        },
        .Fogxv,
        => switch (param_index) {
            1 => .{ "params", "[*]const fixed" },
            else => null,
        },
        .Fogfv,
        => switch (param_index) {
            1 => .{ "params", "[*]const float" },
            else => null,
        },
        .FogCoordfv,
        => switch (param_index) {
            0 => .{ "coord", "*const float" },
            else => null,
        },
        .FogCoorddv,
        => switch (param_index) {
            0 => .{ "coord", "*const double" },
            else => null,
        },
        .FogCoordPointer,
        => switch (param_index) {
            2 => .{ "pointer", "usize" },
            else => null,
        },
        .FramebufferTexture3D,
        => switch (param_index) {
            5 => .{ "layer", "int" },
            else => null,
        },
        .FrontFace,
        => switch (param_index) {
            0 => .{ "dir", "@\"enum\"" },
            else => null,
        },
        .Frustum,
        => switch (param_index) {
            0 => .{ "l", "double" },
            1 => .{ "r", "double" },
            2 => .{ "b", "double" },
            3 => .{ "t", "double" },
            4 => .{ "n", "double" },
            5 => .{ "f", "double" },
            else => null,
        },
        .GenBuffers,
        .GenBuffersARB,
        => switch (param_index) {
            1 => .{ "buffers", "[*]uint" },
            else => null,
        },
        .GenFramebuffers,
        .GenFramebuffersEXT,
        .GenFramebuffersOES,
        => switch (param_index) {
            1 => .{ "framebuffers", "[*]uint" },
            else => null,
        },
        .GenLists,
        => switch (param_index) {
            0 => .{ "s", "sizei" },
            else => null,
        },
        .GenProgramPipelines,
        .GenProgramPipelinesEXT,
        => switch (param_index) {
            1 => .{ "pipelines", "[*]uint" },
            else => null,
        },
        .GenProgramsARB,
        => switch (param_index) {
            1 => .{ "programs", "[*]uint" },
            else => null,
        },
        .GenProgramsNV,
        .GenQueries,
        .GenQueriesARB,
        .GenQueriesEXT,
        => switch (param_index) {
            1 => .{ "ids", "[*]uint" },
            else => null,
        },
        .GenRenderbuffers,
        .GenRenderbuffersEXT,
        .GenRenderbuffersOES,
        => switch (param_index) {
            1 => .{ "renderbuffers", "[*]uint" },
            else => null,
        },
        .GenSamplers,
        => switch (param_index) {
            1 => .{ "samplers", "[*]uint" },
            else => null,
        },
        .GenTextures,
        .GenTexturesEXT,
        => switch (param_index) {
            1 => .{ "textures", "[*]uint" },
            else => null,
        },
        .GenTransformFeedbacks,
        .GenTransformFeedbacksNV,
        => switch (param_index) {
            1 => .{ "ids", "[*]uint" },
            else => null,
        },
        .GenVertexArrays,
        .GenVertexArraysAPPLE,
        .GenVertexArraysOES,
        => switch (param_index) {
            1 => .{ "arrays", "[*]uint" },
            else => null,
        },
        .GetActiveAtomicCounterBufferiv,
        => switch (param_index) {
            3 => .{ "params", "[*]int" },
            else => null,
        },
        .GetActiveAttrib,
        => switch (param_index) {
            3 => .{ "length", "?*sizei" },
            4 => .{ "size", "*int" },
            5 => .{ "type", "*@\"enum\"" },
            6 => .{ "name", "[*]char" },
            else => null,
        },
        .GetActiveAttribARB,
        => switch (param_index) {
            3 => .{ "length", "?*sizei" },
            4 => .{ "size", "*int" },
            5 => .{ "type", "*@\"enum\"" },
            6 => .{ "name", "[*]charARB" },
            else => null,
        },
        .GetActiveSubroutineName,
        => switch (param_index) {
            3 => .{ "count", "sizei" },
            4 => .{ "length", "?*sizei" },
            5 => .{ "name", "[*]char" },
            else => null,
        },
        .GetActiveSubroutineUniformiv,
        => switch (param_index) {
            4 => .{ "values", "[*]int" },
            else => null,
        },
        .GetActiveSubroutineUniformName,
        => switch (param_index) {
            3 => .{ "count", "sizei" },
            4 => .{ "length", "?*sizei" },
            5 => .{ "name", "[*]char" },
            else => null,
        },
        .GetActiveUniform,
        => switch (param_index) {
            3 => .{ "length", "?*sizei" },
            4 => .{ "size", "*int" },
            5 => .{ "type", "*@\"enum\"" },
            6 => .{ "name", "[*]char" },
            else => null,
        },
        .GetActiveUniformARB,
        => switch (param_index) {
            3 => .{ "length", "?*sizei" },
            4 => .{ "size", "*int" },
            5 => .{ "type", "*@\"enum\"" },
            6 => .{ "name", "[*]charARB" },
            else => null,
        },
        .GetActiveUniformBlockiv,
        => switch (param_index) {
            3 => .{ "params", "[*]int" },
            else => null,
        },
        .GetActiveUniformBlockName,
        => switch (param_index) {
            3 => .{ "length", "?*sizei" },
            4 => .{ "uniformBlockName", "[*]char" },
            else => null,
        },
        .GetActiveUniformName,
        => switch (param_index) {
            3 => .{ "length", "?*sizei" },
            4 => .{ "uniformName", "[*]char" },
            else => null,
        },
        .GetActiveUniformsiv,
        => switch (param_index) {
            2 => .{ "uniformIndices", "[*]const uint" },
            4 => .{ "params", "[*]int" },
            else => null,
        },
        .GetAttachedShaders,
        => switch (param_index) {
            2 => .{ "count", "?*sizei" },
            3 => .{ "shaders", "[*]uint" },
            else => null,
        },
        .GetAttribLocation,
        => switch (param_index) {
            1 => .{ "name", "[*:0]const char" },
            else => null,
        },
        .GetAttribLocationARB,
        => switch (param_index) {
            1 => .{ "name", "[*:0]const charARB" },
            else => null,
        },
        .GetBooleanv,
        => switch (param_index) {
            1 => .{ "data", "[*]boolean" },
            else => null,
        },
        .GetBooleani_v,
        .GetBooleanIndexedvEXT,
        => switch (param_index) {
            2 => .{ "data", "[*]boolean" },
            else => null,
        },
        .GetBufferParameteriv,
        => switch (param_index) {
            2 => .{ "data", "[*]int" },
            else => null,
        },
        .GetBufferParameterivARB,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetBufferParameteri64v,
        => switch (param_index) {
            2 => .{ "data", "[*]int64" },
            else => null,
        },
        .GetBufferParameterui64vNV,
        => switch (param_index) {
            2 => .{ "params", "[*]uint64EXT" },
            else => null,
        },
        .GetBufferPointerv,
        .GetBufferPointervARB,
        .GetBufferPointervOES,
        => switch (param_index) {
            2 => .{ "params", "*?*anyopaque" },
            else => null,
        },
        .GetBufferSubData,
        .GetBufferSubDataARB,
        => switch (param_index) {
            3 => .{ "data", "*anyopaque" },
            else => null,
        },
        .GetClipPlane,
        => switch (param_index) {
            1 => .{ "eqn", "*[4]double" },
            else => null,
        },
        .GetClipPlanex,
        => switch (param_index) {
            1 => .{ "eqn", "*[4]fixed" },
            else => null,
        },
        .GetClipPlanef,
        => switch (param_index) {
            1 => .{ "eqn", "*[4]float" },
            else => null,
        },
        .GetColorTable,
        => switch (param_index) {
            3 => .{ "table", "?*anyopaque" },
            else => null,
        },
        .GetColorTableParameteriv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetColorTableParameterfv,
        => switch (param_index) {
            2 => .{ "params", "[*]float" },
            else => null,
        },
        .GetCompressedTexImage,
        => switch (param_index) {
            2 => .{ "pixels", "?*anyopaque" },
            else => null,
        },
        .GetCompressedTextureImage,
        => switch (param_index) {
            3 => .{ "pixels", "?*anyopaque" },
            else => null,
        },
        .GetCompressedTextureSubImage,
        => switch (param_index) {
            9 => .{ "pixels", "?*anyopaque" },
            else => null,
        },
        .GetConvolutionFilter,
        => switch (param_index) {
            3 => .{ "image", "?*anyopaque" },
            else => null,
        },
        .GetConvolutionParameteriv,
        => switch (param_index) {
            2 => .{ "params", "*[4]int" },
            else => null,
        },
        .GetConvolutionParameterfv,
        => switch (param_index) {
            2 => .{ "params", "*[4]float" },
            else => null,
        },
        .GetDebugMessageLog,
        .GetDebugMessageLogARB,
        .GetDebugMessageLogKHR,
        => switch (param_index) {
            2 => .{ "sources", "?[*]@\"enum\"" },
            3 => .{ "types", "?[*]@\"enum\"" },
            4 => .{ "ids", "?[*]uint" },
            5 => .{ "severities", "?[*]@\"enum\"" },
            6 => .{ "lengths", "?[*]sizei" },
            7 => .{ "messageLog", "?[*]char" },
            else => null,
        },
        .GetDebugMessageLogAMD,
        => switch (param_index) {
            1 => .{ "logSize", "sizei" },
            2 => .{ "categories", "?[*]@\"enum\"" },
            3 => .{ "severities", "?[*]@\"enum\"" },
            4 => .{ "ids", "?[*]uint" },
            5 => .{ "lengths", "?[*]sizei" },
            6 => .{ "messageLog", "?[*]char" },
            else => null,
        },
        .GetDoublev,
        => switch (param_index) {
            1 => .{ "data", "[*]double" },
            else => null,
        },
        .GetDoublei_v,
        => switch (param_index) {
            2 => .{ "data", "[*]double" },
            else => null,
        },
        .GetDoublei_vEXT,
        => switch (param_index) {
            0 => .{ "target", "@\"enum\"" },
            2 => .{ "data", "[*]double" },
            else => null,
        },
        .GetDoubleIndexedvEXT,
        => switch (param_index) {
            2 => .{ "data", "[*]double" },
            else => null,
        },
        .GetFixedv,
        => switch (param_index) {
            1 => .{ "data", "[*]fixed" },
            else => null,
        },
        .GetFloatv,
        => switch (param_index) {
            1 => .{ "data", "[*]float" },
            else => null,
        },
        .GetFloati_v,
        => switch (param_index) {
            2 => .{ "data", "[*]float" },
            else => null,
        },
        .GetFloati_vEXT,
        => switch (param_index) {
            0 => .{ "target", "@\"enum\"" },
            2 => .{ "data", "[*]float" },
            else => null,
        },
        .GetFloati_vNV,
        .GetFloati_vOES,
        .GetFloatIndexedvEXT,
        => switch (param_index) {
            2 => .{ "data", "[*]float" },
            else => null,
        },
        .GetFragDataIndex,
        .GetFragDataIndexEXT,
        .GetFragDataLocation,
        .GetFragDataLocationEXT,
        => switch (param_index) {
            1 => .{ "name", "[*:0]const char" },
            else => null,
        },
        .GetFramebufferAttachmentParameteriv,
        => switch (param_index) {
            3 => .{ "params", "[*]int" },
            else => null,
        },
        .GetFramebufferParameteriv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetHistogram,
        => switch (param_index) {
            4 => .{ "values", "?*anyopaque" },
            else => null,
        },
        .GetHistogramParameteriv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetHistogramParameterfv,
        => switch (param_index) {
            2 => .{ "params", "[*]float" },
            else => null,
        },
        .GetIntegerv,
        => switch (param_index) {
            1 => .{ "data", "[*]int" },
            else => null,
        },
        .GetIntegeri_v,
        .GetIntegeri_vEXT,
        => switch (param_index) {
            2 => .{ "data", "[*]int" },
            else => null,
        },
        .GetInteger64v,
        .GetInteger64vEXT,
        => switch (param_index) {
            1 => .{ "data", "[*]int64" },
            else => null,
        },
        .GetInteger64vAPPLE,
        => switch (param_index) {
            1 => .{ "params", "[*]int64" },
            else => null,
        },
        .GetInteger64i_v,
        => switch (param_index) {
            2 => .{ "data", "[*]int64" },
            else => null,
        },
        .GetIntegerIndexedvEXT,
        => switch (param_index) {
            2 => .{ "data", "[*]int" },
            else => null,
        },
        .GetIntegerui64vNV,
        => switch (param_index) {
            0 => .{ "value", "@\"enum\"" },
            1 => .{ "result", "[*]uint64EXT" },
            else => null,
        },
        .GetIntegerui64i_vNV,
        => switch (param_index) {
            0 => .{ "value", "@\"enum\"" },
            2 => .{ "data", "[*]uint64EXT" },
            else => null,
        },
        .GetInternalformativ,
        => switch (param_index) {
            4 => .{ "params", "[*]int" },
            else => null,
        },
        .GetInternalformati64v,
        => switch (param_index) {
            4 => .{ "params", "[*]int64" },
            else => null,
        },
        .GetLightiv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetLightxv,
        => switch (param_index) {
            2 => .{ "params", "[*]fixed" },
            else => null,
        },
        .GetLightfv,
        => switch (param_index) {
            2 => .{ "params", "[*]float" },
            else => null,
        },
        .GetMapiv,
        => switch (param_index) {
            2 => .{ "data", "[*]int" },
            else => null,
        },
        .GetMapfv,
        => switch (param_index) {
            2 => .{ "data", "[*]float" },
            else => null,
        },
        .GetMapdv,
        => switch (param_index) {
            2 => .{ "data", "[*]double" },
            else => null,
        },
        .GetMaterialiv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetMaterialxv,
        => switch (param_index) {
            2 => .{ "params", "[*]fixed" },
            else => null,
        },
        .GetMaterialfv,
        => switch (param_index) {
            2 => .{ "params", "[*]float" },
            else => null,
        },
        .GetMinmax,
        => switch (param_index) {
            4 => .{ "values", "?*anyopaque" },
            else => null,
        },
        .GetMinmaxParameteriv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetMinmaxParameterfv,
        => switch (param_index) {
            2 => .{ "params", "[*]float" },
            else => null,
        },
        .GetMultisamplefv,
        => switch (param_index) {
            2 => .{ "val", "*[2]float" },
            else => null,
        },
        .GetNamedBufferParameteriv,
        => switch (param_index) {
            2 => .{ "data", "[*]int" },
            else => null,
        },
        .GetNamedBufferParameteri64v,
        => switch (param_index) {
            2 => .{ "data", "[*]int64" },
            else => null,
        },
        .GetNamedBufferPointerv,
        => switch (param_index) {
            2 => .{ "params", "*?*anyopaque" },
            else => null,
        },
        .GetNamedBufferSubData,
        => switch (param_index) {
            3 => .{ "data", "*anyopaque" },
            else => null,
        },
        .GetNamedFramebufferAttachmentParameteriv,
        => switch (param_index) {
            3 => .{ "params", "[*]int" },
            else => null,
        },
        .GetNamedFramebufferParameteriv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetNamedRenderbufferParameteriv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetObjectLabel,
        => switch (param_index) {
            3 => .{ "length", "?*sizei" },
            4 => .{ "label", "[*]char" },
            else => null,
        },
        .GetObjectPtrLabel,
        => switch (param_index) {
            0 => .{ "ptr", "*anyopaque" },
            2 => .{ "length", "?*sizei" },
            3 => .{ "label", "[*]char" },
            else => null,
        },
        .GetPixelMapxv,
        => switch (param_index) {
            1 => .{ "data", "?[*]fixed" },
            else => null,
        },
        .GetPixelMapfv,
        => switch (param_index) {
            1 => .{ "data", "?[*]float" },
            else => null,
        },
        .GetPixelMapusv,
        => switch (param_index) {
            1 => .{ "data", "?[*]ushort" },
            else => null,
        },
        .GetPixelMapuiv,
        => switch (param_index) {
            1 => .{ "data", "?[*]uint" },
            else => null,
        },
        .GetPointerv,
        => switch (param_index) {
            2 => .{ "params", "*?*anyopaque" },
            else => null,
        },
        .GetPolygonStipple,
        => switch (param_index) {
            0 => .{ "pattern", "?*[128]ubyte" },
            else => null,
        },
        .GetProgramiv,
        .GetProgramivARB,
        .GetProgramivNV,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetProgramBinary,
        => switch (param_index) {
            2 => .{ "length", "?*sizei" },
            3 => .{ "binaryFormat", "*@\"enum\"" },
            4 => .{ "binary", "*anyopaque" },
            else => null,
        },
        .GetProgramInfoLog,
        => switch (param_index) {
            2 => .{ "length", "?*sizei" },
            3 => .{ "infoLog", "[*]char" },
            else => null,
        },
        .GetProgramInterfaceiv,
        => switch (param_index) {
            3 => .{ "params", "[*]int" },
            else => null,
        },
        .GetProgramPipelineiv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetProgramPipelineInfoLog,
        => switch (param_index) {
            2 => .{ "length", "?*sizei" },
            3 => .{ "infoLog", "[*]char" },
            else => null,
        },
        .GetProgramResourceiv,
        => switch (param_index) {
            4 => .{ "props", "[*]const @\"enum\"" },
            6 => .{ "length", "?*sizei" },
            7 => .{ "params", "[*]int" },
            else => null,
        },
        .GetProgramResourceIndex,
        .GetProgramResourceLocation,
        .GetProgramResourceLocationIndex,
        => switch (param_index) {
            2 => .{ "name", "[*:0]const char" },
            else => null,
        },
        .GetProgramResourceName,
        => switch (param_index) {
            4 => .{ "length", "?*sizei" },
            5 => .{ "name", "[*]char" },
            else => null,
        },
        .GetProgramStageiv,
        => switch (param_index) {
            3 => .{ "values", "[*]int" },
            else => null,
        },
        .GetQueryiv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetQueryIndexediv,
        => switch (param_index) {
            3 => .{ "params", "[*]int" },
            else => null,
        },
        .GetQueryObjectiv,
        => switch (param_index) {
            2 => .{ "params", "?[*]int" },
            else => null,
        },
        .GetQueryObjecti64v,
        => switch (param_index) {
            2 => .{ "params", "?[*]int64" },
            else => null,
        },
        .GetQueryObjectuiv,
        => switch (param_index) {
            2 => .{ "params", "?[*]uint" },
            else => null,
        },
        .GetQueryObjectui64v,
        => switch (param_index) {
            2 => .{ "params", "?[*]uint64" },
            else => null,
        },
        .GetRenderbufferParameteriv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetSamplerParameteriv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetSamplerParameterfv,
        => switch (param_index) {
            2 => .{ "params", "[*]float" },
            else => null,
        },
        .GetSamplerParameterIiv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetSamplerParameterIuiv,
        => switch (param_index) {
            2 => .{ "params", "[*]uint" },
            else => null,
        },
        .GetSeparableFilter,
        => switch (param_index) {
            3 => .{ "row", "?*anyopaque" },
            4 => .{ "column", "?*anyopaque" },
            5 => .{ "span", "?*anyopaque" },
            else => null,
        },
        .GetShaderiv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetShaderInfoLog,
        => switch (param_index) {
            2 => .{ "length", "?*sizei" },
            3 => .{ "infoLog", "[*]char" },
            else => null,
        },
        .GetShaderPrecisionFormat,
        => switch (param_index) {
            2 => .{ "range", "*[2]int" },
            3 => .{ "precision", "*int" },
            else => null,
        },
        .GetShaderSource,
        => switch (param_index) {
            2 => .{ "length", "?*sizei" },
            3 => .{ "source", "[*]char" },
            else => null,
        },
        .GetShaderSourceARB,
        => switch (param_index) {
            2 => .{ "length", "?*sizei" },
            3 => .{ "source", "[*]charARB" },
            else => null,
        },
        .GetSubroutineIndex,
        .GetSubroutineUniformLocation,
        => switch (param_index) {
            2 => .{ "name", "[*:0]const char" },
            else => null,
        },
        .GetSynciv,
        => switch (param_index) {
            0 => .{ "sync_", "*sync" },
            3 => .{ "length", "?*sizei" },
            4 => .{ "values", "[*]int" },
            else => null,
        },
        .GetSyncivAPPLE,
        => switch (param_index) {
            0 => .{ "sync_", "*sync" },
            2 => .{ "bufSize", "sizei" },
            3 => .{ "length", "?*sizei" },
            4 => .{ "values", "[*]int" },
            else => null,
        },
        .GetTexEnviv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetTexEnvxv,
        => switch (param_index) {
            2 => .{ "params", "[*]fixed" },
            else => null,
        },
        .GetTexEnvfv,
        => switch (param_index) {
            2 => .{ "params", "[*]float" },
            else => null,
        },
        .GetTexGeniv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetTexGenfv,
        => switch (param_index) {
            2 => .{ "params", "[*]float" },
            else => null,
        },
        .GetTexGendv,
        => switch (param_index) {
            2 => .{ "params", "[*]double" },
            else => null,
        },
        .GetTexImage,
        => switch (param_index) {
            4 => .{ "pixels", "?*anyopaque" },
            else => null,
        },
        .GetTexLevelParameteriv,
        => switch (param_index) {
            3 => .{ "params", "[*]int" },
            else => null,
        },
        .GetTexLevelParameterfv,
        => switch (param_index) {
            3 => .{ "params", "[*]float" },
            else => null,
        },
        .GetTexParameteriv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetTexParameterxv,
        => switch (param_index) {
            2 => .{ "params", "[*]fixed" },
            else => null,
        },
        .GetTexParameterfv,
        => switch (param_index) {
            2 => .{ "params", "[*]float" },
            else => null,
        },
        .GetTexParameterIiv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetTexParameterIuiv,
        => switch (param_index) {
            2 => .{ "params", "[*]uint" },
            else => null,
        },
        .GetTextureImage,
        => switch (param_index) {
            5 => .{ "pixels", "?*anyopaque" },
            else => null,
        },
        .GetTextureLevelParameteriv,
        => switch (param_index) {
            3 => .{ "params", "[*]int" },
            else => null,
        },
        .GetTextureLevelParameterfv,
        => switch (param_index) {
            3 => .{ "params", "[*]float" },
            else => null,
        },
        .GetTextureParameteriv,
        => switch (param_index) {
            2 => .{ "data", "[*]int" },
            else => null,
        },
        .GetTextureParameterfv,
        => switch (param_index) {
            2 => .{ "data", "[*]float" },
            else => null,
        },
        .GetTextureParameterIiv,
        => switch (param_index) {
            2 => .{ "data", "[*]int" },
            else => null,
        },
        .GetTextureParameterIuiv,
        => switch (param_index) {
            2 => .{ "data", "[*]uint" },
            else => null,
        },
        .GetTextureSubImage,
        => switch (param_index) {
            11 => .{ "pixels", "*anyopaque" },
            else => null,
        },
        .GetTransformFeedbackiv,
        => switch (param_index) {
            2 => .{ "param", "*int" },
            else => null,
        },
        .GetTransformFeedbacki_v,
        => switch (param_index) {
            3 => .{ "param", "*int" },
            else => null,
        },
        .GetTransformFeedbacki64_v,
        => switch (param_index) {
            3 => .{ "param", "*int64" },
            else => null,
        },
        .GetTransformFeedbackVarying,
        => switch (param_index) {
            3 => .{ "length", "?*sizei" },
            4 => .{ "size", "*int" },
            5 => .{ "type", "*@\"enum\"" },
            6 => .{ "name", "[*]char" },
            else => null,
        },
        .GetUniformiv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetUniformfv,
        => switch (param_index) {
            2 => .{ "params", "[*]float" },
            else => null,
        },
        .GetUniformdv,
        => switch (param_index) {
            2 => .{ "params", "[*]double" },
            else => null,
        },
        .GetUniformuiv,
        => switch (param_index) {
            2 => .{ "params", "[*]uint" },
            else => null,
        },
        .GetUniformBlockIndex,
        => switch (param_index) {
            1 => .{ "uniformBlockName", "[*:0]const char" },
            else => null,
        },
        .GetUniformIndices,
        => switch (param_index) {
            2 => .{ "uniformNames", "[*]const [*:0]const char" },
            3 => .{ "uniformIndices", "[*]uint" },
            else => null,
        },
        .GetUniformLocation,
        => switch (param_index) {
            1 => .{ "name", "[*:0]const char" },
            else => null,
        },
        .GetUniformLocationARB,
        => switch (param_index) {
            1 => .{ "name", "[*:0]const charARB" },
            else => null,
        },
        .GetUniformSubroutineuiv,
        => switch (param_index) {
            2 => .{ "params", "[*]uint" },
            else => null,
        },
        .GetVertexArrayiv,
        => switch (param_index) {
            2 => .{ "param", "*int" },
            else => null,
        },
        .GetVertexArrayIndexediv,
        => switch (param_index) {
            3 => .{ "param", "*int" },
            else => null,
        },
        .GetVertexArrayIndexed64iv,
        => switch (param_index) {
            3 => .{ "param", "*int64" },
            else => null,
        },
        .GetVertexAttribiv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetVertexAttribfv,
        => switch (param_index) {
            2 => .{ "params", "[*]float" },
            else => null,
        },
        .GetVertexAttribdv,
        => switch (param_index) {
            2 => .{ "params", "[*]double" },
            else => null,
        },
        .GetVertexAttribIiv,
        => switch (param_index) {
            2 => .{ "params", "[*]int" },
            else => null,
        },
        .GetVertexAttribIuiv,
        => switch (param_index) {
            2 => .{ "params", "[*]uint" },
            else => null,
        },
        .GetVertexAttribLdv,
        => switch (param_index) {
            2 => .{ "params", "[*]double" },
            else => null,
        },
        .GetVertexAttribPointerv,
        => switch (param_index) {
            2 => .{ "pointer", "*usize" },
            else => null,
        },
        .GetVkProcAddrNV,
        => switch (param_index) {
            0 => .{ "name", "[*:0]const char" },
            else => null,
        },
        .GetnColorTable,
        => switch (param_index) {
            4 => .{ "table", "?*anyopaque" },
            else => null,
        },
        .GetnCompressedTexImage,
        => switch (param_index) {
            1 => .{ "level", "int" },
            3 => .{ "pixels", "?*anyopaque" },
            else => null,
        },
        .GetnConvolutionFilter,
        => switch (param_index) {
            4 => .{ "image", "?*anyopaque" },
            else => null,
        },
        .GetnHistogram,
        => switch (param_index) {
            5 => .{ "values", "?*anyopaque" },
            else => null,
        },
        .GetnMapiv,
        => switch (param_index) {
            0 => .{ "map", "@\"enum\"" },
            1 => .{ "value", "@\"enum\"" },
            3 => .{ "data", "[*]int" },
            else => null,
        },
        .GetnMapfv,
        => switch (param_index) {
            0 => .{ "map", "@\"enum\"" },
            1 => .{ "value", "@\"enum\"" },
            3 => .{ "data", "[*]float" },
            else => null,
        },
        .GetnMapdv,
        => switch (param_index) {
            0 => .{ "map", "@\"enum\"" },
            1 => .{ "value", "@\"enum\"" },
            3 => .{ "data", "[*]double" },
            else => null,
        },
        .GetnMinmax,
        => switch (param_index) {
            5 => .{ "values", "?*anyopaque" },
            else => null,
        },
        .GetnPixelMapfv,
        => switch (param_index) {
            2 => .{ "data", "?[*]float" },
            else => null,
        },
        .GetnPixelMapusv,
        => switch (param_index) {
            2 => .{ "data", "?[*]ushort" },
            else => null,
        },
        .GetnPixelMapuiv,
        => switch (param_index) {
            2 => .{ "data", "?[*]uint" },
            else => null,
        },
        .GetnPolygonStipple,
        => switch (param_index) {
            1 => .{ "pattern", "?[*]ubyte" },
            else => null,
        },
        .GetnSeparableFilter,
        => switch (param_index) {
            4 => .{ "row", "?*anyopaque" },
            6 => .{ "column", "?*anyopaque" },
            7 => .{ "span", "?*anyopaque" },
            else => null,
        },
        .GetnTexImage,
        => switch (param_index) {
            5 => .{ "pixels", "?*anyopaque" },
            else => null,
        },
        .GetnUniformiv,
        => switch (param_index) {
            3 => .{ "params", "[*]int" },
            else => null,
        },
        .GetnUniformfv,
        => switch (param_index) {
            3 => .{ "params", "[*]float" },
            else => null,
        },
        .GetnUniformdv,
        => switch (param_index) {
            3 => .{ "params", "[*]double" },
            else => null,
        },
        .GetnUniformuiv,
        => switch (param_index) {
            3 => .{ "params", "[*]uint" },
            else => null,
        },
        .Hint,
        => switch (param_index) {
            1 => .{ "mode", "@\"enum\"" },
            else => null,
        },
        .Indexs,
        => switch (param_index) {
            0 => .{ "index", "short" },
            else => null,
        },
        .Indexsv,
        => switch (param_index) {
            0 => .{ "index", "*const short" },
            else => null,
        },
        .Indexi,
        => switch (param_index) {
            0 => .{ "index", "int" },
            else => null,
        },
        .Indexiv,
        => switch (param_index) {
            0 => .{ "index", "*const int" },
            else => null,
        },
        .Indexf,
        => switch (param_index) {
            0 => .{ "index", "float" },
            else => null,
        },
        .Indexfv,
        => switch (param_index) {
            0 => .{ "index", "*const float" },
            else => null,
        },
        .Indexd,
        => switch (param_index) {
            0 => .{ "index", "double" },
            else => null,
        },
        .Indexdv,
        => switch (param_index) {
            0 => .{ "index", "*const double" },
            else => null,
        },
        .Indexub,
        => switch (param_index) {
            0 => .{ "index", "ubyte" },
            else => null,
        },
        .Indexubv,
        => switch (param_index) {
            0 => .{ "index", "*const ubyte" },
            else => null,
        },
        .IndexPointer,
        => switch (param_index) {
            2 => .{ "pointer", "usize" },
            else => null,
        },
        .InterleavedArrays,
        => switch (param_index) {
            2 => .{ "pointer", "usize" },
            else => null,
        },
        .InvalidateFramebuffer,
        .InvalidateNamedFramebufferData,
        .InvalidateNamedFramebufferSubData,
        .InvalidateSubFramebuffer,
        => switch (param_index) {
            2 => .{ "attachments", "[*]const @\"enum\"" },
            else => null,
        },
        .IsSync,
        .IsSyncAPPLE,
        => switch (param_index) {
            0 => .{ "sync_", "?*sync" },
            else => null,
        },
        .Lightiv,
        => switch (param_index) {
            2 => .{ "params", "[*]const int" },
            else => null,
        },
        .Lightxv,
        => switch (param_index) {
            2 => .{ "params", "[*]const fixed" },
            else => null,
        },
        .Lightfv,
        => switch (param_index) {
            2 => .{ "params", "[*]const float" },
            else => null,
        },
        .LightModeliv,
        => switch (param_index) {
            1 => .{ "params", "[*]const int" },
            else => null,
        },
        .LightModelxv,
        => switch (param_index) {
            1 => .{ "params", "[*]const fixed" },
            else => null,
        },
        .LightModelfv,
        => switch (param_index) {
            1 => .{ "params", "[*]const float" },
            else => null,
        },
        .LoadMatrixx,
        => switch (param_index) {
            0 => .{ "m", "*const [16]fixed" },
            else => null,
        },
        .LoadMatrixf,
        => switch (param_index) {
            0 => .{ "m", "*const [16]float" },
            else => null,
        },
        .LoadMatrixd,
        => switch (param_index) {
            0 => .{ "m", "*const [16]double" },
            else => null,
        },
        .LoadTransposeMatrixf,
        => switch (param_index) {
            0 => .{ "m", "*const [16]float" },
            else => null,
        },
        .LoadTransposeMatrixd,
        => switch (param_index) {
            0 => .{ "m", "*const [16]double" },
            else => null,
        },
        .LogicOp,
        => switch (param_index) {
            0 => .{ "opcode", "@\"enum\"" },
            else => null,
        },
        .Map1f,
        => switch (param_index) {
            5 => .{ "points", "[*]const float" },
            else => null,
        },
        .Map1d,
        => switch (param_index) {
            5 => .{ "points", "[*]const double" },
            else => null,
        },
        .Map2f,
        => switch (param_index) {
            9 => .{ "points", "[*]const float" },
            else => null,
        },
        .Map2d,
        => switch (param_index) {
            9 => .{ "points", "[*]const double" },
            else => null,
        },
        .MapGrid1f,
        => switch (param_index) {
            0 => .{ "n", "int" },
            else => null,
        },
        .MapGrid1d,
        => switch (param_index) {
            0 => .{ "n", "int" },
            else => null,
        },
        .Materialiv,
        => switch (param_index) {
            2 => .{ "params", "[*]const int" },
            else => null,
        },
        .Materialxv,
        => switch (param_index) {
            2 => .{ "params", "[*]const fixed" },
            else => null,
        },
        .Materialfv,
        => switch (param_index) {
            2 => .{ "params", "[*]const float" },
            else => null,
        },
        .MultMatrixx,
        => switch (param_index) {
            0 => .{ "m", "*const [16]fixed" },
            else => null,
        },
        .MultMatrixf,
        => switch (param_index) {
            0 => .{ "m", "*const [16]float" },
            else => null,
        },
        .MultMatrixd,
        => switch (param_index) {
            0 => .{ "m", "*const [16]double" },
            else => null,
        },
        .MultTransposeMatrixf,
        => switch (param_index) {
            0 => .{ "m", "*const [16]float" },
            else => null,
        },
        .MultTransposeMatrixd,
        => switch (param_index) {
            0 => .{ "m", "*const [16]double" },
            else => null,
        },
        .MultiDrawArrays,
        => switch (param_index) {
            1 => .{ "first", "[*]const int" },
            2 => .{ "count", "[*]const sizei" },
            else => null,
        },
        .MultiDrawArraysIndirect,
        .MultiDrawArraysIndirectCount,
        => switch (param_index) {
            1 => .{ "indirect", "usize" },
            else => null,
        },
        .MultiDrawElements,
        => switch (param_index) {
            1 => .{ "count", "[*]const sizei" },
            3 => .{ "indices", "[*]const usize" },
            else => null,
        },
        .MultiDrawElementsBaseVertex,
        => switch (param_index) {
            1 => .{ "count", "[*]const sizei" },
            3 => .{ "indices", "[*]const usize" },
            5 => .{ "basevertex", "[*]const int" },
            else => null,
        },
        .MultiDrawElementsIndirect,
        .MultiDrawElementsIndirectCount,
        => switch (param_index) {
            2 => .{ "indirect", "usize" },
            else => null,
        },
        .MultiTexCoord1s,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            else => null,
        },
        .MultiTexCoord1sv,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            1 => .{ "coords", "*const short" },
            else => null,
        },
        .MultiTexCoord1i,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            else => null,
        },
        .MultiTexCoord1iv,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            1 => .{ "coords", "*const int" },
            else => null,
        },
        .MultiTexCoord1f,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            else => null,
        },
        .MultiTexCoord1fv,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            1 => .{ "coords", "*const float" },
            else => null,
        },
        .MultiTexCoord1d,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            else => null,
        },
        .MultiTexCoord1dv,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            1 => .{ "coords", "*const double" },
            else => null,
        },
        .MultiTexCoord2s,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            else => null,
        },
        .MultiTexCoord2sv,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            1 => .{ "coords", "*const [2]short" },
            else => null,
        },
        .MultiTexCoord2i,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            else => null,
        },
        .MultiTexCoord2iv,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            1 => .{ "coords", "*const [2]int" },
            else => null,
        },
        .MultiTexCoord2f,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            else => null,
        },
        .MultiTexCoord2fv,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            1 => .{ "coords", "*const [2]float" },
            else => null,
        },
        .MultiTexCoord2d,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            else => null,
        },
        .MultiTexCoord2dv,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            1 => .{ "coords", "*const [2]double" },
            else => null,
        },
        .MultiTexCoord3s,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            else => null,
        },
        .MultiTexCoord3sv,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            1 => .{ "coords", "*const [3]short" },
            else => null,
        },
        .MultiTexCoord3i,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            else => null,
        },
        .MultiTexCoord3iv,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            1 => .{ "coords", "*const [3]int" },
            else => null,
        },
        .MultiTexCoord3f,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            else => null,
        },
        .MultiTexCoord3fv,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            1 => .{ "coords", "*const [3]float" },
            else => null,
        },
        .MultiTexCoord3d,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            else => null,
        },
        .MultiTexCoord3dv,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            1 => .{ "coords", "*const [3]double" },
            else => null,
        },
        .MultiTexCoord4s,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            else => null,
        },
        .MultiTexCoord4sv,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            1 => .{ "coords", "*const [4]short" },
            else => null,
        },
        .MultiTexCoord4i,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            else => null,
        },
        .MultiTexCoord4iv,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            1 => .{ "coords", "*const [4]int" },
            else => null,
        },
        .MultiTexCoord4f,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            else => null,
        },
        .MultiTexCoord4fv,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            1 => .{ "coords", "*const [4]float" },
            else => null,
        },
        .MultiTexCoord4d,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            else => null,
        },
        .MultiTexCoord4dv,
        => switch (param_index) {
            0 => .{ "texture", "@\"enum\"" },
            1 => .{ "coords", "*const [4]double" },
            else => null,
        },
        .MultiTexCoordP1uiv,
        .MultiTexCoordP2uiv,
        .MultiTexCoordP3uiv,
        .MultiTexCoordP4uiv,
        => switch (param_index) {
            2 => .{ "coords", "*const uint" },
            else => null,
        },
        .NamedBufferData,
        .NamedBufferStorage,
        => switch (param_index) {
            2 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .NamedBufferStorageExternalEXT,
        => switch (param_index) {
            3 => .{ "clientBuffer", "*eglClientBufferEXT" },
            else => null,
        },
        .NamedBufferSubData,
        => switch (param_index) {
            3 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .NamedFramebufferDrawBuffers,
        => switch (param_index) {
            2 => .{ "bufs", "[*]const @\"enum\"" },
            else => null,
        },
        .NewList,
        => switch (param_index) {
            0 => .{ "n", "uint" },
            else => null,
        },
        .Normal3bv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]byte" },
            else => null,
        },
        .Normal3sv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]short" },
            else => null,
        },
        .Normal3iv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]int" },
            else => null,
        },
        .Normal3fv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]float" },
            else => null,
        },
        .Normal3dv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]double" },
            else => null,
        },
        .NormalP3uiv,
        => switch (param_index) {
            1 => .{ "coords", "*const uint" },
            else => null,
        },
        .NormalPointer,
        => switch (param_index) {
            2 => .{ "pointer", "usize" },
            else => null,
        },
        .ObjectLabel,
        => switch (param_index) {
            3 => .{ "label", "[*]char" },
            else => null,
        },
        .ObjectPtrLabel,
        => switch (param_index) {
            0 => .{ "ptr", "*anyopaque" },
            2 => .{ "label", "[*]char" },
            else => null,
        },
        .Ortho,
        => switch (param_index) {
            0 => .{ "l", "double" },
            1 => .{ "r", "double" },
            2 => .{ "b", "double" },
            3 => .{ "t", "double" },
            4 => .{ "n", "double" },
            5 => .{ "f", "double" },
            else => null,
        },
        .PatchParameterfv,
        => switch (param_index) {
            1 => .{ "values", "[*]const float" },
            else => null,
        },
        .PixelMapx, // PixelMapxv
        => switch (param_index) {
            2 => .{ "values", "[*]const fixed" },
            else => null,
        },
        .PixelMapfv,
        => switch (param_index) {
            1 => .{ "size", "sizei" },
            2 => .{ "values", "[*]const float" },
            else => null,
        },
        .PixelMapusv,
        => switch (param_index) {
            1 => .{ "size", "sizei" },
            2 => .{ "values", "[*]const ushort" },
            else => null,
        },
        .PixelMapuiv,
        => switch (param_index) {
            1 => .{ "size", "sizei" },
            2 => .{ "values", "[*]const uint" },
            else => null,
        },
        .PixelTransferi,
        => switch (param_index) {
            1 => .{ "param", "@\"enum\"" },
            2 => .{ "value", "int" },
            else => null,
        },
        .PixelTransferf,
        => switch (param_index) {
            1 => .{ "param", "@\"enum\"" },
            2 => .{ "value", "float" },
            else => null,
        },
        .PixelZoom,
        => switch (param_index) {
            0 => .{ "zx", "float" },
            1 => .{ "zy", "float" },
            else => null,
        },
        .PointParameteriv,
        => switch (param_index) {
            1 => .{ "params", "[*]const int" },
            else => null,
        },
        .PointParameterxv,
        => switch (param_index) {
            1 => .{ "params", "[*]const fixed" },
            else => null,
        },
        .PointParameterfv,
        => switch (param_index) {
            1 => .{ "params", "[*]const float" },
            else => null,
        },
        .PolygonStipple,
        => switch (param_index) {
            0 => .{ "pattern", "?*const [128]ubyte" },
            else => null,
        },
        .PrioritizeTextures,
        => switch (param_index) {
            1 => .{ "textures", "[*]const uint" },
            2 => .{ "priorities", "[*]const float" },
            else => null,
        },
        .ProgramBinary,
        => switch (param_index) {
            2 => .{ "binary", "*anyopaque" },
            else => null,
        },
        .ProgramUniform1iv,
        => switch (param_index) {
            3 => .{ "value", "[*]const int" },
            else => null,
        },
        .ProgramUniform1fv,
        => switch (param_index) {
            3 => .{ "value", "[*]const float" },
            else => null,
        },
        .ProgramUniform1dv,
        => switch (param_index) {
            3 => .{ "value", "[*]const double" },
            else => null,
        },
        .ProgramUniform1uiv,
        => switch (param_index) {
            3 => .{ "value", "[*]const uint" },
            else => null,
        },
        .ProgramUniform2iv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [2]int" },
            else => null,
        },
        .ProgramUniform2fv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [2]float" },
            else => null,
        },
        .ProgramUniform2dv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [2]double" },
            else => null,
        },
        .ProgramUniform2uiv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [2]uint" },
            else => null,
        },
        .ProgramUniform3iv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [3]int" },
            else => null,
        },
        .ProgramUniform3fv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [3]float" },
            else => null,
        },
        .ProgramUniform3dv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [3]double" },
            else => null,
        },
        .ProgramUniform3uiv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [3]uint" },
            else => null,
        },
        .ProgramUniform4iv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [4]int" },
            else => null,
        },
        .ProgramUniform4fv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [4]float" },
            else => null,
        },
        .ProgramUniform4dv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [4]double" },
            else => null,
        },
        .ProgramUniform4uiv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [4]uint" },
            else => null,
        },
        .ProgramUniformMatrix2fv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [4]float" },
            else => null,
        },
        .ProgramUniformMatrix2dv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [4]double" },
            else => null,
        },
        .ProgramUniformMatrix3fv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [9]float" },
            else => null,
        },
        .ProgramUniformMatrix3dv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [9]double" },
            else => null,
        },
        .ProgramUniformMatrix4fv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [16]float" },
            else => null,
        },
        .ProgramUniformMatrix4dv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [16]double" },
            else => null,
        },
        .ProgramUniformMatrix2x3fv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [6]float" },
            else => null,
        },
        .ProgramUniformMatrix2x3dv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [6]double" },
            else => null,
        },
        .ProgramUniformMatrix3x2fv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [6]float" },
            else => null,
        },
        .ProgramUniformMatrix3x2dv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [6]double" },
            else => null,
        },
        .ProgramUniformMatrix2x4fv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [8]float" },
            else => null,
        },
        .ProgramUniformMatrix2x4dv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [8]double" },
            else => null,
        },
        .ProgramUniformMatrix4x2fv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [8]float" },
            else => null,
        },
        .ProgramUniformMatrix4x2dv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [8]double" },
            else => null,
        },
        .ProgramUniformMatrix3x4fv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [12]float" },
            else => null,
        },
        .ProgramUniformMatrix3x4dv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [12]double" },
            else => null,
        },
        .ProgramUniformMatrix4x3fv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [12]float" },
            else => null,
        },
        .ProgramUniformMatrix4x3dv,
        => switch (param_index) {
            4 => .{ "value", "[*]const [12]double" },
            else => null,
        },
        .ProvokingVertex,
        => switch (param_index) {
            0 => .{ "provokeMode", "@\"enum\"" },
            else => null,
        },
        .PushDebugGroup,
        => switch (param_index) {
            3 => .{ "message", "[*]const char" },
            else => null,
        },
        .RasterPos2sv,
        => switch (param_index) {
            0 => .{ "coords", "*const [2]short" },
            else => null,
        },
        .RasterPos2iv,
        => switch (param_index) {
            0 => .{ "coords", "*const [2]int" },
            else => null,
        },
        .RasterPos2fv,
        => switch (param_index) {
            0 => .{ "coords", "*const [2]float" },
            else => null,
        },
        .RasterPos2dv,
        => switch (param_index) {
            0 => .{ "coords", "*const [2]double" },
            else => null,
        },
        .RasterPos3sv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]short" },
            else => null,
        },
        .RasterPos3iv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]int" },
            else => null,
        },
        .RasterPos3fv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]float" },
            else => null,
        },
        .RasterPos3dv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]double" },
            else => null,
        },
        .RasterPos4sv,
        => switch (param_index) {
            0 => .{ "coords", "*const [4]short" },
            else => null,
        },
        .RasterPos4iv,
        => switch (param_index) {
            0 => .{ "coords", "*const [4]int" },
            else => null,
        },
        .RasterPos4fv,
        => switch (param_index) {
            0 => .{ "coords", "*const [4]float" },
            else => null,
        },
        .RasterPos4dv,
        => switch (param_index) {
            0 => .{ "coords", "*const [4]double" },
            else => null,
        },
        .ReadPixels,
        => switch (param_index) {
            6 => .{ "data", "?*anyopaque" },
            else => null,
        },
        .ReadnPixels,
        => switch (param_index) {
            7 => .{ "data", "?*anyopaque" },
            else => null,
        },
        .Rectsv,
        => switch (param_index) {
            0 => .{ "v1", "*const [2]short" },
            1 => .{ "v2", "*const [2]short" },
            else => null,
        },
        .Rectiv,
        => switch (param_index) {
            0 => .{ "v1", "*const [2]int" },
            1 => .{ "v2", "*const [2]int" },
            else => null,
        },
        .Rectfv,
        => switch (param_index) {
            0 => .{ "v1", "*const [2]float" },
            1 => .{ "v2", "*const [2]float" },
            else => null,
        },
        .Rectdv,
        => switch (param_index) {
            0 => .{ "v1", "*const [2]double" },
            1 => .{ "v2", "*const [2]double" },
            else => null,
        },
        .Rotatex,
        => switch (param_index) {
            0 => .{ "theta", "fixed" },
            else => null,
        },
        .Rotatef,
        => switch (param_index) {
            0 => .{ "theta", "float" },
            else => null,
        },
        .Rotated,
        => switch (param_index) {
            0 => .{ "theta", "double" },
            else => null,
        },
        .SampleCoveragex,
        => switch (param_index) {
            0 => .{ "value", "fixed" },
            else => null,
        },
        .SamplerParameteriv,
        => switch (param_index) {
            2 => .{ "param", "[*]const int" },
            else => null,
        },
        .SamplerParameterfv,
        => switch (param_index) {
            2 => .{ "param", "[*]const float" },
            else => null,
        },
        .SamplerParameterIiv,
        => switch (param_index) {
            2 => .{ "params", "[*]const int" },
            else => null,
        },
        .SamplerParameterIuiv,
        => switch (param_index) {
            2 => .{ "params", "[*]const uint" },
            else => null,
        },
        .Scissor,
        => switch (param_index) {
            0 => .{ "left", "int" },
            1 => .{ "bottom", "int" },
            else => null,
        },
        .ScissorArrayv,
        => switch (param_index) {
            2 => .{ "v", "[*]const [4]int" },
            else => null,
        },
        .ScissorIndexedv,
        => switch (param_index) {
            1 => .{ "v", "*const [4]int" },
            else => null,
        },
        .SecondaryColor3b,
        => switch (param_index) {
            0 => .{ "r", "byte" },
            1 => .{ "g", "byte" },
            2 => .{ "b", "byte" },
            else => null,
        },
        .SecondaryColor3bv,
        => switch (param_index) {
            0 => .{ "components", "*const [3]byte" },
            else => null,
        },
        .SecondaryColor3s,
        => switch (param_index) {
            0 => .{ "r", "short" },
            1 => .{ "g", "short" },
            2 => .{ "b", "short" },
            else => null,
        },
        .SecondaryColor3sv,
        => switch (param_index) {
            0 => .{ "components", "*const [3]short" },
            else => null,
        },
        .SecondaryColor3i,
        => switch (param_index) {
            0 => .{ "r", "int" },
            1 => .{ "g", "int" },
            2 => .{ "b", "int" },
            else => null,
        },
        .SecondaryColor3iv,
        => switch (param_index) {
            0 => .{ "components", "*const [3]int" },
            else => null,
        },
        .SecondaryColor3f,
        => switch (param_index) {
            0 => .{ "r", "float" },
            1 => .{ "g", "float" },
            2 => .{ "b", "float" },
            else => null,
        },
        .SecondaryColor3fv,
        => switch (param_index) {
            0 => .{ "components", "*const [3]float" },
            else => null,
        },
        .SecondaryColor3d,
        => switch (param_index) {
            0 => .{ "r", "double" },
            1 => .{ "g", "double" },
            2 => .{ "b", "double" },
            else => null,
        },
        .SecondaryColor3dv,
        => switch (param_index) {
            0 => .{ "components", "*const [3]double" },
            else => null,
        },
        .SecondaryColor3ub,
        => switch (param_index) {
            0 => .{ "r", "ubyte" },
            1 => .{ "g", "ubyte" },
            2 => .{ "b", "ubyte" },
            else => null,
        },
        .SecondaryColor3ubv,
        => switch (param_index) {
            0 => .{ "components", "*const [3]ubyte" },
            else => null,
        },
        .SecondaryColor3us,
        => switch (param_index) {
            0 => .{ "r", "ushort" },
            1 => .{ "g", "ushort" },
            2 => .{ "b", "ushort" },
            else => null,
        },
        .SecondaryColor3usv,
        => switch (param_index) {
            0 => .{ "components", "*const [3]ushort" },
            else => null,
        },
        .SecondaryColor3ui,
        => switch (param_index) {
            0 => .{ "r", "uint" },
            1 => .{ "g", "uint" },
            2 => .{ "b", "uint" },
            else => null,
        },
        .SecondaryColor3uiv,
        => switch (param_index) {
            0 => .{ "components", "*const [3]uint" },
            else => null,
        },
        .SecondaryColorP3ui,
        => switch (param_index) {
            1 => .{ "coords", "uint" },
            else => null,
        },
        .SecondaryColorP3uiv,
        => switch (param_index) {
            1 => .{ "coords", "*const uint" },
            else => null,
        },
        .SecondaryColorPointer,
        => switch (param_index) {
            3 => .{ "pointer", "usize" },
            else => null,
        },
        .SelectBuffer,
        => switch (param_index) {
            0 => .{ "n", "sizei" },
            1 => .{ "buffer", "[*]uint" },
            else => null,
        },
        .SeparableFilter2D,
        => switch (param_index) {
            6 => .{ "row", "?*const anyopaque" },
            7 => .{ "column", "?*const anyopaque" },
            else => null,
        },
        .ShaderBinary,
        => switch (param_index) {
            1 => .{ "shaders", "[*]const uint" },
            2 => .{ "binaryformat", "@\"enum\"" },
            3 => .{ "binary", "*const anyopaque" },
            else => null,
        },
        .ShaderSource,
        => switch (param_index) {
            2 => .{ "string", "[*]const [*]const char" },
            3 => .{ "lengths", "?[*]const int" },
            else => null,
        },
        .ShaderSourceARB,
        => switch (param_index) {
            2 => .{ "string", "[*]const [*]const charARB" },
            3 => .{ "lengths", "?[*]const int" },
            else => null,
        },
        .SpecializeShader,
        => switch (param_index) {
            1 => .{ "pEntryPoint", "[*:0]const char" },
            3 => .{ "pConstantIndex", "[*]const uint" },
            4 => .{ "pConstantValue", "[*]const uint" },
            else => null,
        },
        .StencilOp,
        => switch (param_index) {
            0 => .{ "sfail", "@\"enum\"" },
            1 => .{ "dpfail", "@\"enum\"" },
            2 => .{ "dppass", "@\"enum\"" },
            else => null,
        },
        .TexCoord1sv,
        => switch (param_index) {
            0 => .{ "coords", "*const short" },
            else => null,
        },
        .TexCoord1iv,
        => switch (param_index) {
            0 => .{ "coords", "*const int" },
            else => null,
        },
        .TexCoord1fv,
        => switch (param_index) {
            0 => .{ "coords", "*const float" },
            else => null,
        },
        .TexCoord1dv,
        => switch (param_index) {
            0 => .{ "coords", "*const double" },
            else => null,
        },
        .TexCoord2sv,
        => switch (param_index) {
            0 => .{ "coords", "*const [2]short" },
            else => null,
        },
        .TexCoord2iv,
        => switch (param_index) {
            0 => .{ "coords", "*const [2]int" },
            else => null,
        },
        .TexCoord2fv,
        => switch (param_index) {
            0 => .{ "coords", "*const [2]float" },
            else => null,
        },
        .TexCoord2dv,
        => switch (param_index) {
            0 => .{ "coords", "*const [2]double" },
            else => null,
        },
        .TexCoord3sv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]short" },
            else => null,
        },
        .TexCoord3iv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]int" },
            else => null,
        },
        .TexCoord3fv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]float" },
            else => null,
        },
        .TexCoord3dv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]double" },
            else => null,
        },
        .TexCoord4sv,
        => switch (param_index) {
            0 => .{ "coords", "*const [4]short" },
            else => null,
        },
        .TexCoord4iv,
        => switch (param_index) {
            0 => .{ "coords", "*const [4]int" },
            else => null,
        },
        .TexCoord4fv,
        => switch (param_index) {
            0 => .{ "coords", "*const [4]float" },
            else => null,
        },
        .TexCoord4dv,
        => switch (param_index) {
            0 => .{ "coords", "*const [4]double" },
            else => null,
        },
        .TexCoordP1uiv,
        .TexCoordP2uiv,
        .TexCoordP3uiv,
        .TexCoordP4uiv,
        => switch (param_index) {
            1 => .{ "coords", "*const uint" },
            else => null,
        },
        .TexCoordPointer,
        => switch (param_index) {
            3 => .{ "pointer", "usize" },
            else => null,
        },
        .TexEnviv,
        => switch (param_index) {
            2 => .{ "params", "[*]const int" },
            else => null,
        },
        .TexEnvxv,
        => switch (param_index) {
            2 => .{ "params", "[*]const fixed" },
            else => null,
        },
        .TexEnvfv,
        => switch (param_index) {
            2 => .{ "params", "[*]const float" },
            else => null,
        },
        .TexGeniv,
        => switch (param_index) {
            2 => .{ "params", "[*]const int" },
            else => null,
        },
        .TexGenfv,
        => switch (param_index) {
            2 => .{ "params", "[*]const float" },
            else => null,
        },
        .TexGendv,
        => switch (param_index) {
            2 => .{ "params", "[*]const double" },
            else => null,
        },
        .TexImage1D,
        => switch (param_index) {
            7 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .TexImage2D,
        => switch (param_index) {
            8 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .TexImage3D,
        => switch (param_index) {
            9 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .TexParameteriv,
        => switch (param_index) {
            2 => .{ "params", "[*]const int" },
            else => null,
        },
        .TexParameterxv,
        => switch (param_index) {
            2 => .{ "params", "[*]const fixed" },
            else => null,
        },
        .TexParameterfv,
        => switch (param_index) {
            2 => .{ "params", "[*]const float" },
            else => null,
        },
        .TexParameterIiv,
        => switch (param_index) {
            2 => .{ "params", "[*]const int" },
            else => null,
        },
        .TexParameterIuiv,
        => switch (param_index) {
            2 => .{ "params", "[*]const uint" },
            else => null,
        },
        .TexSubImage1D,
        => switch (param_index) {
            6 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .TexSubImage2D,
        => switch (param_index) {
            8 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .TexSubImage3D,
        => switch (param_index) {
            10 => .{ "data", "?*const anyopaque" },
            else => null,
        },
        .TextureParameteriv,
        => switch (param_index) {
            2 => .{ "params", "[*]const int" },
            else => null,
        },
        .TextureParameterfv,
        => switch (param_index) {
            2 => .{ "params", "[*]const float" },
            else => null,
        },
        .TextureParameterIiv,
        => switch (param_index) {
            2 => .{ "params", "[*]const int" },
            else => null,
        },
        .TextureParameterIuiv,
        => switch (param_index) {
            2 => .{ "params", "[*]const uint" },
            else => null,
        },
        .TextureSubImage1D,
        => switch (param_index) {
            6 => .{ "pixels", "?*const anyopaque" },
            else => null,
        },
        .TextureSubImage2D,
        => switch (param_index) {
            8 => .{ "pixels", "?*const anyopaque" },
            else => null,
        },
        .TextureSubImage3D,
        => switch (param_index) {
            10 => .{ "pixels", "?*const anyopaque" },
            else => null,
        },
        .TransformFeedbackVaryings,
        => switch (param_index) {
            2 => .{ "varyings", "[*]const [*:0]const char" },
            else => null,
        },
        .Translatex,
        => switch (param_index) {
            2 => .{ "varyings", "[*]const [*:0]const char" },
            else => null,
        },
        .Uniform1iv,
        => switch (param_index) {
            2 => .{ "value", "[*]const int" },
            else => null,
        },
        .Uniform1fv,
        => switch (param_index) {
            2 => .{ "value", "[*]const float" },
            else => null,
        },
        .Uniform1d,
        => switch (param_index) {
            1 => .{ "v0", "double" },
            else => null,
        },
        .Uniform1dv,
        => switch (param_index) {
            2 => .{ "value", "[*]const double" },
            else => null,
        },
        .Uniform1uiv,
        => switch (param_index) {
            2 => .{ "value", "[*]const uint" },
            else => null,
        },
        .Uniform2iv,
        => switch (param_index) {
            2 => .{ "value", "[*]const [2]int" },
            else => null,
        },
        .Uniform2fv,
        => switch (param_index) {
            2 => .{ "value", "[*]const [2]float" },
            else => null,
        },
        .Uniform2d,
        => switch (param_index) {
            1 => .{ "v0", "double" },
            2 => .{ "v1", "double" },
            else => null,
        },
        .Uniform2dv,
        => switch (param_index) {
            2 => .{ "value", "[*]const [2]double" },
            else => null,
        },
        .Uniform2uiv,
        => switch (param_index) {
            2 => .{ "value", "[*]const [2]uint" },
            else => null,
        },
        .Uniform3iv,
        => switch (param_index) {
            2 => .{ "value", "[*]const [3]int" },
            else => null,
        },
        .Uniform3fv,
        => switch (param_index) {
            2 => .{ "value", "[*]const [3]float" },
            else => null,
        },
        .Uniform3d,
        => switch (param_index) {
            1 => .{ "v0", "double" },
            2 => .{ "v1", "double" },
            3 => .{ "v2", "double" },
            else => null,
        },
        .Uniform3dv,
        => switch (param_index) {
            2 => .{ "value", "[*]const [3]double" },
            else => null,
        },
        .Uniform3uiv,
        => switch (param_index) {
            2 => .{ "value", "[*]const [3]uint" },
            else => null,
        },
        .Uniform4iv,
        => switch (param_index) {
            2 => .{ "value", "[*]const [4]int" },
            else => null,
        },
        .Uniform4fv,
        => switch (param_index) {
            2 => .{ "value", "[*]const [4]float" },
            else => null,
        },
        .Uniform4d,
        => switch (param_index) {
            1 => .{ "v0", "double" },
            2 => .{ "v1", "double" },
            3 => .{ "v2", "double" },
            4 => .{ "v3", "double" },
            else => null,
        },
        .Uniform4dv,
        => switch (param_index) {
            2 => .{ "value", "[*]const [4]double" },
            else => null,
        },
        .Uniform4uiv,
        => switch (param_index) {
            2 => .{ "value", "[*]const [4]uint" },
            else => null,
        },
        .UniformMatrix2fv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [4]float" },
            else => null,
        },
        .UniformMatrix2dv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [4]double" },
            else => null,
        },
        .UniformMatrix3fv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [9]float" },
            else => null,
        },
        .UniformMatrix3dv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [9]double" },
            else => null,
        },
        .UniformMatrix4fv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [16]float" },
            else => null,
        },
        .UniformMatrix4dv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [16]double" },
            else => null,
        },
        .UniformMatrix2x3fv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [6]float" },
            else => null,
        },
        .UniformMatrix2x3dv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [6]double" },
            else => null,
        },
        .UniformMatrix3x2fv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [6]float" },
            else => null,
        },
        .UniformMatrix3x2dv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [6]double" },
            else => null,
        },
        .UniformMatrix2x4fv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [8]float" },
            else => null,
        },
        .UniformMatrix2x4dv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [8]double" },
            else => null,
        },
        .UniformMatrix4x2fv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [8]float" },
            else => null,
        },
        .UniformMatrix4x2dv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [8]double" },
            else => null,
        },
        .UniformMatrix3x4fv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [12]float" },
            else => null,
        },
        .UniformMatrix3x4dv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [12]double" },
            else => null,
        },
        .UniformMatrix4x3fv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [12]float" },
            else => null,
        },
        .UniformMatrix4x3dv,
        => switch (param_index) {
            3 => .{ "value", "[*]const [12]double" },
            else => null,
        },
        .UniformSubroutinesuiv,
        => switch (param_index) {
            2 => .{ "indices", "[*]const uint" },
            else => null,
        },
        .Vertex2sv,
        => switch (param_index) {
            0 => .{ "coords", "*const [2]short" },
            else => null,
        },
        .Vertex2iv,
        => switch (param_index) {
            0 => .{ "coords", "*const [2]int" },
            else => null,
        },
        .Vertex2fv,
        => switch (param_index) {
            0 => .{ "coords", "*const [2]float" },
            else => null,
        },
        .Vertex2dv,
        => switch (param_index) {
            0 => .{ "coords", "*const [2]double" },
            else => null,
        },
        .Vertex3sv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]short" },
            else => null,
        },
        .Vertex3iv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]int" },
            else => null,
        },
        .Vertex3fv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]float" },
            else => null,
        },
        .Vertex3dv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]double" },
            else => null,
        },
        .Vertex4sv,
        => switch (param_index) {
            0 => .{ "coords", "*const [4]short" },
            else => null,
        },
        .Vertex4iv,
        => switch (param_index) {
            0 => .{ "coords", "*const [4]int" },
            else => null,
        },
        .Vertex4fv,
        => switch (param_index) {
            0 => .{ "coords", "*const [4]float" },
            else => null,
        },
        .Vertex4dv,
        => switch (param_index) {
            0 => .{ "coords", "*const [4]double" },
            else => null,
        },
        .VertexArrayVertexBuffers,
        => switch (param_index) {
            3 => .{ "buffers", "?[*]const uint" },
            4 => .{ "offsets", "?[*]const intptr" },
            5 => .{ "strides", "?[*]const sizei" },
            else => null,
        },
        .VertexAttrib1sv,
        => switch (param_index) {
            1 => .{ "values", "*const short" },
            else => null,
        },
        .VertexAttrib1fv,
        => switch (param_index) {
            1 => .{ "values", "*const float" },
            else => null,
        },
        .VertexAttrib1dv,
        => switch (param_index) {
            1 => .{ "values", "*const double" },
            else => null,
        },
        .VertexAttrib2sv,
        => switch (param_index) {
            1 => .{ "values", "*const [2]short" },
            else => null,
        },
        .VertexAttrib2fv,
        => switch (param_index) {
            1 => .{ "values", "*const [2]float" },
            else => null,
        },
        .VertexAttrib2dv,
        => switch (param_index) {
            1 => .{ "values", "*const [2]double" },
            else => null,
        },
        .VertexAttrib3sv,
        => switch (param_index) {
            1 => .{ "values", "*const [3]short" },
            else => null,
        },
        .VertexAttrib3fv,
        => switch (param_index) {
            1 => .{ "values", "*const [3]float" },
            else => null,
        },
        .VertexAttrib3dv,
        => switch (param_index) {
            1 => .{ "values", "*const [3]double" },
            else => null,
        },
        .VertexAttrib4bv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]byte" },
            else => null,
        },
        .VertexAttrib4sv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]short" },
            else => null,
        },
        .VertexAttrib4iv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]int" },
            else => null,
        },
        .VertexAttrib4fv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]float" },
            else => null,
        },
        .VertexAttrib4dv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]double" },
            else => null,
        },
        .VertexAttrib4ubv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]ubyte" },
            else => null,
        },
        .VertexAttrib4usv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]ushort" },
            else => null,
        },
        .VertexAttrib4uiv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]uint" },
            else => null,
        },
        .VertexAttrib4Nbv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]byte" },
            else => null,
        },
        .VertexAttrib4Nsv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]short" },
            else => null,
        },
        .VertexAttrib4Niv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]int" },
            else => null,
        },
        .VertexAttrib4Nubv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]ubyte" },
            else => null,
        },
        .VertexAttrib4Nusv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]ushort" },
            else => null,
        },
        .VertexAttrib4Nuiv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]uint" },
            else => null,
        },
        .VertexAttribI1iv,
        => switch (param_index) {
            1 => .{ "values", "*const int" },
            else => null,
        },
        .VertexAttribI1uiv,
        => switch (param_index) {
            1 => .{ "values", "*const uint" },
            else => null,
        },
        .VertexAttribI2iv,
        => switch (param_index) {
            1 => .{ "values", "*const [2]int" },
            else => null,
        },
        .VertexAttribI2uiv,
        => switch (param_index) {
            1 => .{ "values", "*const [2]uint" },
            else => null,
        },
        .VertexAttribI3iv,
        => switch (param_index) {
            1 => .{ "values", "*const [3]int" },
            else => null,
        },
        .VertexAttribI3uiv,
        => switch (param_index) {
            1 => .{ "values", "*const [3]uint" },
            else => null,
        },
        .VertexAttribI4bv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]byte" },
            else => null,
        },
        .VertexAttribI4sv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]short" },
            else => null,
        },
        .VertexAttribI4iv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]int" },
            else => null,
        },
        .VertexAttribI4ubv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]ubyte" },
            else => null,
        },
        .VertexAttribI4usv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]ushort" },
            else => null,
        },
        .VertexAttribI4uiv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]uint" },
            else => null,
        },
        .VertexAttribIPointer,
        .VertexAttribIPointerEXT,
        => switch (param_index) {
            4 => .{ "pointer", "usize" },
            else => null,
        },
        .VertexAttribL1dv,
        => switch (param_index) {
            1 => .{ "values", "*const double" },
            else => null,
        },
        .VertexAttribL2dv,
        => switch (param_index) {
            1 => .{ "values", "*const [2]double" },
            else => null,
        },
        .VertexAttribL3dv,
        => switch (param_index) {
            1 => .{ "values", "*const [3]double" },
            else => null,
        },
        .VertexAttribL4dv,
        => switch (param_index) {
            1 => .{ "values", "*const [4]double" },
            else => null,
        },
        .VertexAttribLPointer,
        .VertexAttribLPointerEXT,
        => switch (param_index) {
            4 => .{ "pointer", "usize" },
            else => null,
        },
        .VertexAttribP1uiv,
        .VertexAttribP2uiv,
        .VertexAttribP3uiv,
        .VertexAttribP4uiv,
        => switch (param_index) {
            3 => .{ "value", "*const usize" },
            else => null,
        },
        .VertexAttribPointer,
        .VertexAttribPointerARB,
        => switch (param_index) {
            5 => .{ "pointer", "usize" },
            else => null,
        },
        .VertexAttribPointerNV,
        => switch (param_index) {
            1 => .{ "size", "int" },
            4 => .{ "pointer", "usize" },
            else => null,
        },
        .VertexP2ui,
        => switch (param_index) {
            1 => .{ "coords", "uint" },
            else => null,
        },
        .VertexP2uiv,
        => switch (param_index) {
            1 => .{ "coords", "*const uint" },
            else => null,
        },
        .VertexP3ui,
        => switch (param_index) {
            1 => .{ "coords", "uint" },
            else => null,
        },
        .VertexP3uiv,
        => switch (param_index) {
            1 => .{ "coords", "*const uint" },
            else => null,
        },
        .VertexP4ui,
        => switch (param_index) {
            1 => .{ "coords", "uint" },
            else => null,
        },
        .VertexP4uiv,
        => switch (param_index) {
            1 => .{ "coords", "*const uint" },
            else => null,
        },
        .VertexPointer,
        => switch (param_index) {
            3 => .{ "pointer", "usize" },
            else => null,
        },
        .Viewport,
        => switch (param_index) {
            2 => .{ "w", "sizei" },
            3 => .{ "h", "sizei" },
            else => null,
        },
        .ViewportArrayv,
        => switch (param_index) {
            2 => .{ "v", "[*]const [4]float" },
            else => null,
        },
        .ViewportIndexedfv,
        => switch (param_index) {
            1 => .{ "v", "*const [4]float" },
            else => null,
        },
        .WaitSync,
        .WaitSyncAPPLE,
        => switch (param_index) {
            0 => .{ "sync_", "*sync" },
            else => null,
        },
        .WindowPos2sv,
        => switch (param_index) {
            0 => .{ "coords", "*const [2]short" },
            else => null,
        },
        .WindowPos2iv,
        => switch (param_index) {
            0 => .{ "coords", "*const [2]int" },
            else => null,
        },
        .WindowPos2fv,
        => switch (param_index) {
            0 => .{ "coords", "*const [2]float" },
            else => null,
        },
        .WindowPos2dv,
        => switch (param_index) {
            0 => .{ "coords", "*const [2]double" },
            else => null,
        },
        .WindowPos3sv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]short" },
            else => null,
        },
        .WindowPos3iv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]int" },
            else => null,
        },
        .WindowPos3fv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]float" },
            else => null,
        },
        .WindowPos3dv,
        => switch (param_index) {
            0 => .{ "coords", "*const [3]double" },
            else => null,
        },
        else => null,
    };
}

fn renderReturnType(writer: anytype, command: ResolvedCommands.Entry) !void {
    if (returnTypeOverride(command.key)) |override_type_string| {
        try writer.writeAll(override_type_string);
    } else {
        try writer.print("{f}", .{fmtTypeExpr(command.value.return_type_expr)});
    }
}

fn returnTypeOverride(command: registry.Command.Name) ?[]const u8 {
    return switch (command) {
        .CreateSyncFromCLeventARB,
        => "?*sync",
        .FenceSync,
        .FenceSyncAPPLE,
        => "?*sync",
        .ImportSyncEXT,
        => "?*sync",
        .GetString,
        .GetStringi,
        => "?[*:0]const ubyte",
        .GetVkProcAddrNV,
        => "?VULKANPROCNV",
        .MapBuffer,
        .MapBufferRange,
        .MapNamedBuffer,
        .MapNamedBufferRange,
        => "?*anyopaque",
        else => null,
    };
}
