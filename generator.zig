const std = @import("std");
const builtin = @import("builtin");

const options = @import("generator_options.zig");
const registry = @import("api_registry.zig");

/// Usage: `zigglen-generator <api>-<version>[-<profile>] [<extension> ...]`
pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    var arg_it = try std.process.argsWithAllocator(arena);

    const exe_name = arg_it.next() orelse "zigglen-generator";

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

    var stdout_state = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdout = stdout_state.writer();

    try renderCode(stdout, api, version, profile, &extensions, &types, &constants, &commands);

    try stdout_state.flush();
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

        var api: registry.Api.Name = switch (inline for (@typeInfo(options.Api).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw_api, field.name)) break @field(options.Api, field.name);
        } else return error.InvalidApi) {
            .gl => .gl,
            .gles => .gles2,
            .glsc => .glsc2,
        };

        const version: [2]u8 = inline for (@typeInfo(options.Version).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw_version, field.name)) {
                const dot = std.mem.indexOfScalar(u8, raw_version, '.').?;
                break .{
                    std.fmt.parseUnsigned(u8, raw_version[0..dot], 10) catch unreachable,
                    std.fmt.parseUnsigned(u8, raw_version[(dot + 1)..], 10) catch unreachable,
                };
            }
        } else return error.InvalidVersion;

        var maybe_profile: ?registry.ProfileName = if (maybe_raw_profile) |raw_profile|
            switch (inline for (@typeInfo(options.Profile).@"enum".fields) |field| {
                if (std.mem.eql(u8, raw_profile, field.name)) break @field(options.Profile, field.name);
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
    // Statically assert that 'generator_options.zig' and 'api_registry.zig' are in sync.
    comptime {
        @setEvalBranchQuota(100_000);
        for (@typeInfo(options.Extension).@"enum".fields, @typeInfo(registry.Extension.Name).@"enum".fields) |a, b| {
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
    // Add API features
    for (registry.apis) |reg_api| {
        if (reg_api.name != api) continue;
        if (reg_api.version[0] > version[0] or reg_api.version[0] == version[0] and reg_api.version[1] > version[1]) continue;
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

    // Remove API features
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

    try writer.print(
        \\//! Bindings for {[api_pretty]s} {[version_major]d}.{[version_minor]d}{[sp_profile_pretty]s} generated by zigglgen.
        \\
        \\// OpenGL XML API Registry revision: {[registry_revision]s}
        \\// zigglgen version: 0.2.3
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
        \\    pub const api = {[api]s};
        \\    pub const version_major = {[version_major]d};
        \\    pub const version_minor = {[version_minor]d};
        \\    pub const profile = {[profile]s};
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
                \\    {},
                \\
            , .{fmtId(@tagName(extension.key))});
        }
        try writer.writeAll(
            \\};
            \\
        );
    }
    try writer.writeAll(
        \\
        \\pub const APIENTRY: std.builtin.CallingConvention = if (builtin.os.tag == .windows and builtin.cpu.arch == .x86) .Stdcall else .C;
        \\pub const PROC = *align(@alignOf(fn () callconv(APIENTRY) void)) const anyopaque;
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
            \\pub const {} = {s};
            \\
        , .{ fmtDeclId(@tagName(@"type".key)), getTypeValue(@"type".key) });
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
            \\pub const {} = {s}0x{X};
            \\
        , .{ fmtDeclId(@tagName(constant.key)), if (constant.value.value < 0) "-" else "", @abs(constant.value.value) });
    }
    try writer.writeAll(
        \\//#endregion Constants
        \\
        \\//#region Commands
        \\
    );
    var command_it = commands.iterator();
    while (command_it.next()) |command| {
        try writer.print("pub fn {}(", .{fmtDeclId(@tagName(command.key))});
        try renderParams(writer, command, false);
        try writer.writeAll(") ");
        try renderReturnType(writer, command);
        try writer.print(" {{\n    return ProcTable.current.?.{}", .{fmtDeclId(@tagName(command.key))});
        if (!command.value.required) try writer.writeAll(".?");
        try writer.writeByte('(');
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
                \\    {}: bool,
                \\
            , .{fmtId(@tagName(extension.key))});
        }
    }
    command_it = commands.iterator();
    while (command_it.next()) |command| {
        try writer.print("    {}: ", .{fmtDeclId(@tagName(command.key))});
        if (!command.value.required) try writer.writeByte('?');
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
        \\        inline for (@typeInfo(ProcTable).Struct.fields) |field_info| {
        \\            switch (@typeInfo(field_info.type)) {
        \\                .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
        \\                    .Fn => {
        \\                        success &= @intFromBool(procs.initCommand(loader, field_info.name));
        \\                    },
        \\                    else => comptime unreachable,
        \\                },
        \\
    );
    if (any_extensions) {
        try writer.writeAll(
            \\                .Optional => |opt_info| switch (@typeInfo(opt_info.child)) {
            \\                    .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
            \\                        .Fn => {
            \\                            @field(procs, field_info.name) = null;
            \\                        },
            \\                        else => comptime unreachable,
            \\                    },
            \\                    else => comptime unreachable,
            \\                },
            \\                .Bool => {
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
        \\            return @typeInfo(@TypeOf(@field(procs, name))) == .Optional;
        \\        }
        \\    }
        \\
        \\    fn getProcAddress(loader: anytype, prefixed_name: [:0]const u8) ?PROC {
        \\        const loader_info = @typeInfo(@TypeOf(loader));
        \\        const loader_is_fn =
        \\            loader_info == .Fn or
        \\            loader_info == .Pointer and @typeInfo(loader_info.Pointer.child) == .Fn;
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
        \\// THIRD-PARTY NOTICES
        \\//
        \\
    );
    var notices_lines_it = std.mem.splitScalar(u8, @embedFile("THIRD-PARTY-NOTICES.txt"), '\n');
    while (notices_lines_it.next()) |line| {
        if (line.len != 0) {
            try writer.print(
                \\// {s}
                \\
            , .{line});
        } else {
            try writer.writeAll(
                \\//
                \\
            );
        }
    }
    try writer.writeAll(
        \\// END OF THIRD-PARTY NOTICES
        \\
    );
}

// TODO 2024.5.0-mach: Remove 'formatDeclId' and audit uses of 'fmtId'.
const fmtId = std.zig.fmtId;

fn fmtDeclId(bytes: []const u8) std.fmt.Formatter(formatDeclId) {
    return .{ .data = bytes };
}

const stringEscape = if (@hasDecl(std.zig, "stringEscape")) std.zig.stringEscape else std.zig.fmt.stringEscape;

fn formatDeclId(
    bytes: []const u8,
    comptime _: []const u8,
    format_options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    if (std.zig.isValidId(bytes) and !std.zig.primitives.isPrimitive(bytes)) {
        return writer.writeAll(bytes);
    }
    try writer.writeAll("@\"");
    try stringEscape(bytes, "", format_options, writer);
    try writer.writeByte('"');
}

fn fmtTypeExpr(type_expr: []const registry.Command.Token) std.fmt.Formatter(formatTypeExpr) {
    return .{ .data = type_expr };
}

fn formatTypeExpr(
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
        .type => |@"type"| try formatDeclId(@tagName(@"type"), "", .{}, writer),
    };
}

fn getTypeValue(@"type": registry.Type.Name) []const u8 {
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
        .@"enum",
        .uint,
        => "c_uint",
        .boolean,
        .char,
        .charARB,
        .ubyte,
        => "u8",
        .byte,
        => "i8",
        .cl_context,
        .cl_event,
        .eglClientBufferEXT,
        .eglImageOES,
        .sync,
        => "*opaque {}",
        .clampd,
        .double,
        => "f64",
        .clampf,
        .float,
        => "f32",
        .clampx,
        .fixed,
        => "i32",
        .half,
        .halfARB,
        .ushort,
        => "u16",
        .halfNV,
        => "c_ushort",
        .handleARB,
        => "if (builtin.os.tag.isDarwin()) *allowzero anyopaque else u32",
        .int,
        .sizei,
        => "c_int",
        .int64,
        .int64EXT,
        => "i64",
        .intptr,
        .intptrARB,
        .sizeiptr,
        .sizeiptrARB,
        => "isize",
        .short,
        => "i16",
        .uint64,
        .uint64EXT,
        => "u64",
        .vdpauSurfaceNV,
        => "intptr",
        .khrplatform,
        .void,
        => unreachable,
    };
}

fn renderParams(writer: anytype, command: ResolvedCommands.Entry, comptime name_only: bool) !void {
    for (command.value.params, 0..) |param, param_index| {
        if (param_index != 0) try writer.writeAll(", ");
        if (paramOverride(command.key, param_index)) |override| {
            if (name_only) {
                try writer.print("{}", .{fmtDeclId(override.name)});
            } else {
                try writer.print("{}: {s}", .{ fmtDeclId(override.name), override.type_expr });
            }
        } else {
            if (name_only) {
                try writer.print("{}", .{fmtDeclId(param.name)});
            } else {
                try writer.print("{}: {}", .{ fmtDeclId(param.name), fmtTypeExpr(param.type_expr) });
            }
        }
    }
}

fn paramOverride(command: registry.Command.Name, param_index: usize) ?struct {
    name: []const u8,
    type_expr: []const u8,
} {
    return switch (command) {
        .BufferData,
        .BufferDataARB,
        => switch (param_index) {
            2 => .{ .name = "data", .type_expr = "?*const anyopaque" },
            else => null,
        },
        .BufferStorageExternalEXT,
        .NamedBufferStorageExternalEXT,
        => switch (param_index) {
            3 => .{ .name = "clientBuffer", .type_expr = "eglClientBufferEXT" },
            else => null,
        },
        inline .ClearBufferfv,
        .ClearBufferiv,
        .ClearBufferuiv,
        => |tag| switch (param_index) {
            2 => .{
                .name = "values",
                .type_expr = "[*]const " ++ switch (tag) {
                    .ClearBufferfv => "float",
                    .ClearBufferiv => "int",
                    .ClearBufferuiv => "uint",
                    else => comptime unreachable,
                },
            },
            else => null,
        },
        inline .ClearNamedFramebufferfv,
        .ClearNamedFramebufferiv,
        .ClearNamedFramebufferuiv,
        => |tag| switch (param_index) {
            3 => .{
                .name = "values",
                .type_expr = "[*]const " ++ switch (tag) {
                    .ClearNamedFramebufferfv => "float",
                    .ClearNamedFramebufferiv => "int",
                    .ClearNamedFramebufferuiv => "uint",
                    else => comptime unreachable,
                },
            },
            else => null,
        },
        .ClientWaitSync,
        .ClientWaitSyncAPPLE,
        .GetSynciv,
        .GetSyncivAPPLE,
        .WaitSync,
        .WaitSyncAPPLE,
        => switch (param_index) {
            0 => .{ .name = "sync_", .type_expr = "sync" },
            else => null,
        },
        .CreateSyncFromCLeventARB,
        => switch (param_index) {
            0 => .{ .name = "context", .type_expr = "cl_context" },
            1 => .{ .name = "event", .type_expr = "cl_event" },
            else => null,
        },
        inline .DebugMessageCallback,
        .DebugMessageCallbackAMD,
        .DebugMessageCallbackARB,
        .DebugMessageCallbackKHR,
        => |tag| switch (param_index) {
            0 => .{
                .name = "callback",
                .type_expr = "?" ++ switch (tag) {
                    .DebugMessageCallbackAMD => "DEBUGPROCAMD",
                    .DebugMessageCallbackARB => "DEBUGPROCARB",
                    .DebugMessageCallbackKHR => "DEBUGPROCKHR",
                    else => "DEBUGPROC",
                },
            },
            else => null,
        },
        .DeleteBuffers,
        .DeleteBuffersARB,
        .GenBuffers,
        .GenBuffersARB,
        => switch (param_index) {
            1 => .{ .name = "buffers", .type_expr = "[*]uint" },
            else => null,
        },
        .DeleteFramebuffers,
        .DeleteFramebuffersEXT,
        .DeleteFramebuffersOES,
        .GenFramebuffers,
        .GenFramebuffersEXT,
        .GenFramebuffersOES,
        => switch (param_index) {
            1 => .{ .name = "framebuffers", .type_expr = "[*]uint" },
            else => null,
        },
        .DeleteProgramPipelines,
        .DeleteProgramPipelinesEXT,
        .GenProgramPipelines,
        .GenProgramPipelinesEXT,
        => switch (param_index) {
            1 => .{ .name = "pipelines", .type_expr = "[*]uint" },
            else => null,
        },
        .DeleteProgramsARB,
        .DeleteProgramsNV,
        => switch (param_index) {
            1 => .{ .name = "programs", .type_expr = "[*]uint" },
            else => null,
        },
        .DeleteQueries,
        .DeleteQueriesARB,
        .DeleteQueriesEXT,
        .DeleteTransformFeedbacks,
        .DeleteTransformFeedbacksNV,
        .GenQueries,
        .GenQueriesARB,
        .GenQueriesEXT,
        .GenTransformFeedbacks,
        .GenTransformFeedbacksNV,
        => switch (param_index) {
            1 => .{ .name = "ids", .type_expr = "[*]uint" },
            else => null,
        },
        .DeleteRenderbuffers,
        .DeleteRenderbuffersEXT,
        .DeleteRenderbuffersOES,
        .GenRenderbuffers,
        .GenRenderbuffersEXT,
        .GenRenderbuffersOES,
        => switch (param_index) {
            1 => .{ .name = "renderbuffers", .type_expr = "[*]uint" },
            else => null,
        },
        .DeleteSamplers,
        .GenSamplers,
        => switch (param_index) {
            1 => .{ .name = "samplers", .type_expr = "[*]uint" },
            else => null,
        },
        .DeleteSync,
        .DeleteSyncAPPLE,
        .IsSync,
        .IsSyncAPPLE,
        => switch (param_index) {
            0 => .{ .name = "sync_", .type_expr = "?sync" },
            else => null,
        },
        .DeleteTextures,
        .DeleteTexturesEXT,
        .GenTextures,
        .GenTexturesEXT,
        => switch (param_index) {
            1 => .{ .name = "textures", .type_expr = "[*]uint" },
            else => null,
        },
        .DeleteVertexArrays,
        .DeleteVertexArraysAPPLE,
        .DeleteVertexArraysOES,
        .GenVertexArrays,
        .GenVertexArraysAPPLE,
        .GenVertexArraysOES,
        => switch (param_index) {
            1 => .{ .name = "arrays", .type_expr = "[*]uint" },
            else => null,
        },
        .DrawElements,
        => switch (param_index) {
            3 => .{ .name = "indices", .type_expr = "usize" },
            else => null,
        },
        .EGLImageTargetRenderbufferStorageOES,
        .EGLImageTargetTexStorageEXT,
        .EGLImageTargetTexture2DOES,
        .EGLImageTargetTextureStorageEXT,
        => switch (param_index) {
            1 => .{ .name = "image", .type_expr = "eglImageOES" },
            else => null,
        },
        inline .GetAttribLocation,
        .GetAttribLocationARB,
        .GetUniformLocation,
        .GetUniformLocationARB,
        => |tag| switch (param_index) {
            1 => .{
                .name = "name",
                .type_expr = "[*:0]const " ++ switch (tag) {
                    .GetAttribLocationARB, .GetUniformLocationARB => "charARB",
                    else => "char",
                },
            },
            else => null,
        },
        .GetBooleani_v,
        .GetBooleanIndexedvEXT,
        => switch (param_index) {
            2 => .{ .name = "data", .type_expr = "[*]boolean" },
            else => null,
        },
        .GetBooleanv,
        => switch (param_index) {
            1 => .{ .name = "data", .type_expr = "[*]boolean" },
            else => null,
        },
        .GetDoublei_v,
        .GetDoublei_vEXT,
        .GetDoubleIndexedvEXT,
        => switch (param_index) {
            2 => .{
                .name = switch (command) {
                    .GetDoublei_vEXT => "params",
                    else => "data",
                },
                .type_expr = "[*]double",
            },
            else => null,
        },
        .GetDoublev,
        => switch (param_index) {
            1 => .{ .name = "data", .type_expr = "[*]double" },
            else => null,
        },
        .GetFloati_v,
        .GetFloati_vEXT,
        .GetFloati_vNV,
        .GetFloati_vOES,
        .GetFloatIndexedvEXT,
        => switch (param_index) {
            2 => .{
                .name = switch (command) {
                    .GetFloati_vEXT => "params",
                    else => "data",
                },
                .type_expr = "[*]float",
            },
            else => null,
        },
        .GetFloatv,
        => switch (param_index) {
            1 => .{ .name = "data", .type_expr = "[*]float" },
            else => null,
        },
        .GetInteger64i_v,
        => switch (param_index) {
            2 => .{ .name = "data", .type_expr = "[*]int64" },
            else => null,
        },
        .GetInteger64v,
        .GetInteger64vAPPLE,
        .GetInteger64vEXT,
        => switch (param_index) {
            1 => .{
                .name = switch (command) {
                    .GetInteger64vAPPLE => "params",
                    else => "data",
                },
                .type_expr = "[*]int64",
            },
            else => null,
        },
        .GetIntegeri_v,
        .GetIntegeri_vEXT,
        .GetIntegerIndexedvEXT,
        => switch (param_index) {
            2 => .{ .name = "data", .type_expr = "[*]int" },
            else => null,
        },
        .GetIntegerv,
        => switch (param_index) {
            1 => .{ .name = "data", .type_expr = "[*]int" },
            else => null,
        },
        .GetProgramInfoLog,
        .GetShaderInfoLog,
        => switch (param_index) {
            2 => .{ .name = "length", .type_expr = "?*sizei" },
            3 => .{ .name = "infoLog", .type_expr = "[*]char" },
            else => null,
        },
        .GetProgramiv,
        .GetShaderiv,
        => switch (param_index) {
            2 => .{ .name = "param", .type_expr = "*int" },
            else => null,
        },
        .GetShaderPrecisionFormat,
        => switch (param_index) {
            2 => .{ .name = "range", .type_expr = "*int" },
            3 => .{ .name = "precision", .type_expr = "*int" },
            else => null,
        },
        inline .GetShaderSource,
        .GetShaderSourceARB,
        => |tag| switch (param_index) {
            2 => .{ .name = "length", .type_expr = "?*sizei" },
            3 => .{
                .name = "source",
                .type_expr = "[*]" ++ switch (tag) {
                    .GetShaderSourceARB => "charARB",
                    else => "char",
                },
            },
            else => null,
        },
        .GetVkProcAddrNV,
        => switch (param_index) {
            0 => .{ .name = "name", .type_expr = "[*:0]const char" },
            else => null,
        },
        inline .ShaderSource,
        .ShaderSourceARB,
        => |tag| switch (param_index) {
            2 => .{
                .name = "strings",
                .type_expr = "[*]const [*]const " ++ switch (tag) {
                    .GetShaderSourceARB => "charARB",
                    else => "char",
                },
            },
            3 => .{ .name = "lengths", .type_expr = "?[*]const int" },
            else => null,
        },
        .VertexAttribIPointer,
        .VertexAttribIPointerEXT,
        .VertexAttribLPointer,
        .VertexAttribLPointerEXT,
        .VertexAttribPointerNV,
        => switch (param_index) {
            4 => .{ .name = "pointer", .type_expr = "usize" },
            else => null,
        },
        .VertexAttribPointer,
        .VertexAttribPointerARB,
        => switch (param_index) {
            5 => .{ .name = "pointer", .type_expr = "usize" },
            else => null,
        },
        else => null,
    };
}

fn renderReturnType(writer: anytype, command: ResolvedCommands.Entry) !void {
    if (returnTypeOverride(command.key)) |override| {
        try writer.writeAll(override.type_expr);
    } else {
        try formatTypeExpr(command.value.return_type_expr, "", .{}, writer);
    }
}

fn returnTypeOverride(command: registry.Command.Name) ?struct {
    type_expr: []const u8,
} {
    return switch (command) {
        .CreateSyncFromCLeventARB,
        .FenceSync,
        .FenceSyncAPPLE,
        .ImportSyncEXT,
        => .{ .type_expr = "?sync" },
        .GetString,
        .GetStringi,
        => .{ .type_expr = "?[*:0]const ubyte" },
        .GetVkProcAddrNV,
        => .{ .type_expr = "?VULKANPROCNV" },
        else => null,
    };
}
