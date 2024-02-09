const std = @import("std");
const builtin = @import("builtin");

const options = @import("generator_options.zig");
const registry = @import("api_registry.zig");

/// Usage: `generator <api>-<version>[-<profile>] [<extension> ...]`
pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    var arg_it = try std.process.argsWithAllocator(arena);
    _ = arg_it.skip();

    const raw_triple = arg_it.next() orelse return handleUserError(error.MissingQuery);
    const triple = ApiVersionProfile.parse(raw_triple) catch |err| return handleUserError(err);
    const api, const version, const profile = .{ triple.api, triple.version, triple.profile };

    var extensions: ResolvedExtensions = .{};
    while (arg_it.next()) |raw_extension| {
        const extension = parseExtension(raw_extension, api) catch |err| return handleUserError(err);
        extensions.put(extension, .{});
    }

    var types: ResolvedTypes = .{};
    var constants: ResolvedConstants = .{};
    var commands: ResolvedCommands = .{};
    resolveQuery(api, version, profile, &extensions, &types, &constants, &commands);

    var stdout_state = std.io.bufferedWriter(std.io.getStdOut().writer());
    defer stdout_state.flush() catch {};

    const stdout = stdout_state.writer();

    try renderCode(stdout, api, version, profile, &extensions, &types, &constants, &commands);
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
        if (raw_it.next() != null) return error.InvalidQuery;

        const version: [2]u8 = inline for (@typeInfo(options.Version).Enum.fields) |field| {
            if (std.mem.eql(u8, raw_version, field.name)) {
                const dot = std.mem.indexOfScalar(u8, raw_version, '.').?;
                break .{
                    std.fmt.parseUnsigned(u8, raw_version[0..dot], 10) catch unreachable,
                    std.fmt.parseUnsigned(u8, raw_version[(dot + 1)..], 10) catch unreachable,
                };
            }
        } else return error.InvalidVersion;

        const api: registry.Api.Name = switch (inline for (@typeInfo(options.Api).Enum.fields) |field| {
            if (std.mem.eql(u8, raw_api, field.name)) break @field(options.Api, field.name);
        } else return error.InvalidApi) {
            .gl => .gl,
            .gles => if (version[0] >= 2) .gles2 else .gles1,
            .glsc => .glsc2,
        };

        var maybe_profile: ?registry.ProfileName = if (maybe_raw_profile) |raw_profile|
            switch (inline for (@typeInfo(options.Profile).Enum.fields) |field| {
                if (std.mem.eql(u8, raw_profile, field.name)) break @field(options.Profile, field.name);
            } else return error.InvalidProfile) {
                .core => .core,
                .compatibility => .compatibility,
                .common => .common,
                .common_lite => .common_lite,
            }
        else
            null;

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
        InvalidQuery,
        InvalidApi,
        InvalidVersion,
        InvalidProfile,
        MissingVersion,
        UnsupportedVersion,
        UnsupportedProfile,
    };
};

fn parseExtension(raw: []const u8, api: registry.Api.Name) ParseExtensionError!registry.Extension.Name {
    // Statically assert that 'generator_options.zig' and 'api_registry.zig' are in sync.
    comptime {
        @setEvalBranchQuota(100_000);
        for (@typeInfo(options.Extension).Enum.fields, @typeInfo(registry.Extension.Name).Enum.fields) |a, b| {
            std.debug.assert(std.mem.eql(u8, a.name, b.name));
        }
    }

    const extension: registry.Extension.Name = inline for (@typeInfo(registry.Extension.Name).Enum.fields) |field| {
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

const UserError = error{MissingQuery} || ApiVersionProfile.ParseError || ParseExtensionError;

fn handleUserError(err: UserError) noreturn {
    std.log.err("{s}", .{@errorName(err)});
    std.process.exit(1);
}

const ResolvedExtensions = with_quota: {
    @setEvalBranchQuota(100_000);
    break :with_quota std.EnumMap(registry.Extension.Name, struct {
        commands: with_quota: {
            @setEvalBranchQuota(100_000);
            break :with_quota std.EnumSet(registry.Command.Name);
        } = .{},
    });
};
const ResolvedTypes = with_quota: {
    @setEvalBranchQuota(100_000);
    break :with_quota std.EnumMap(registry.Type.Name, struct {
        requires: ?registry.Type.Name = null,
    });
};
const ResolvedConstants = with_quota: {
    @setEvalBranchQuota(100_000);
    break :with_quota std.EnumMap(registry.Constant.Name, struct {
        value: i128,
    });
};
const ResolvedCommands = with_quota: {
    @setEvalBranchQuota(100_000);
    break :with_quota std.EnumMap(registry.Command.Name, struct {
        params: []const registry.Command.Param,
        return_type_expr: []const registry.Command.Token,
        required: bool = false,
    });
};

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
        \\//!
        \\//! Example usage:
        \\//!
        \\//! ```
        \\//! const windowing = @import(...);
        \\//! const gl = @import("gl");
        \\//!
        \\//! // Procedure table that will hold OpenGL functions loaded at runtime.
        \\//! var procs: gl.ProcTable = undefined;
        \\//!
        \\//! pub fn main() !void {{
        \\//!     // Create an OpenGL context using a windowing system of your choice.
        \\//!     var context = windowing.createContext(...);
        \\//!     defer context.destroy();
        \\//!
        \\//!     // Make the OpenGL context current on the calling thread.
        \\//!     windowing.makeContextCurrent(context);
        \\//!     defer windowing.makeContextCurrent(null);
        \\//!
        \\//!     // Initialize the procedure table.
        \\//!     if (!procs.init(windowing.getProcAddress)) return error.InitFailed;
        \\//!
        \\//!     // Make the procedure table current on the calling thread.
        \\//!     gl.makeProcTableCurrent(&procs);
        \\//!     defer gl.makeProcTableCurrent(null);
        \\//!
        \\//!     // Issue OpenGL commands to your heart's content!
        \\//!     const alpha: gl.{[real_type]s} = 1;
        \\//!     gl.{[clear_color_fn]s}(1, 1, 1, alpha);
        \\//!     gl.Clear(gl.COLOR_BUFFER_BIT);
        \\//! }}
        \\//! ```
        \\
        \\// OpenGL XML API Registry revision: {[registry_revision]s}
        \\// zigglgen version: 0.1.0
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
        .real_type = if (profile == .common_lite) "fixed" else "float",
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
            \\pub const {} = 0x{X};
            \\
        , .{ fmtDeclId(@tagName(constant.key)), constant.value.value });
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
        \\    /// `locator` is duck-typed. Given the prefixed name of an OpenGL command (e.g. `"glClear"`), it
        \\    /// should return a pointer to the corresponding function. It should be able to be used in one
        \\    /// of the following two ways:
        \\    ///
        \\    /// - `@as(?PROC, locator(@as([*:0]const u8, prefixed_name)))`
        \\    /// - `@as(?PROC, locator.getProcAddress(@as([*:0]const u8, prefixed_name)))`
        \\    ///
        \\    /// If your windowing system has a "get procedure address" function, it is usually enough to
        \\    /// simply pass that function as the `locator` argument.
        \\    ///
        \\    /// No references to `locator` are retained after this function returns.
        \\    ///
        \\    /// There is no corresponding `deinit` function.
        \\    pub fn init(procs: *ProcTable, locator: anytype) bool {
        \\        @setEvalBranchQuota(1_000_000);
        \\        var success: u1 = 1;
        \\        inline for (@typeInfo(ProcTable).Struct.fields) |field_info| {
        \\            switch (@typeInfo(field_info.type)) {
        \\                .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
        \\                    .Fn => {
        // TODO 2024.3.0-mach: remove '++ ""'
        \\                        success &= @intFromBool(procs.initCommand(locator, field_info.name ++ ""));
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
                        \\            _ = procs.initCommand(locator, "{s}");
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
        \\    fn initCommand(procs: *ProcTable, locator: anytype, comptime name: [:0]const u8) bool {
        \\        if (getProcAddress(locator, "gl" ++ name)) |proc| {
        \\            @field(procs, name) = @ptrCast(proc);
        \\            return true;
        \\        } else {
        \\            return @typeInfo(@TypeOf(@field(procs, name))) == .Optional;
        \\        }
        \\    }
        \\
        \\    fn getProcAddress(locator: anytype, prefixed_name: [:0]const u8) ?PROC {
        \\        const locator_info = @typeInfo(@TypeOf(locator));
        \\        const locator_is_fn =
        \\            locator_info == .Fn or
        \\            locator_info == .Pointer and @typeInfo(locator_info.Pointer.child) == .Fn;
        \\        if (locator_is_fn) {
        \\            return @as(?PROC, locator(@as([*:0]const u8, prefixed_name)));
        \\        } else {
        \\            return @as(?PROC, locator.getProcAddress(@as([*:0]const u8, prefixed_name)));
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
                \\        var count: int = 0;
                // TODO 2024.3.0-mach: replace with '(&count)[0..1]'
                \\        procs.GetIntegerv(NUM_EXTENSIONS, @ptrCast(&count));
                \\        if (count < 0) return false;
                \\        var i: uint = 0;
                \\        while (i < @as(uint, @intCast(count))) : (i += 1) {
                \\            const prefixed_name = procs.GetStringi(EXTENSIONS, i) orelse return false;
                \\            if (std.mem.orderZ(ubyte, prefixed_name, "GL_" ++ name) == .eq) {
                \\
            );
        } else {
            try writer.writeAll(
                \\        const prefixed_names = procs.GetString(EXTENSIONS) orelse return false;
                \\        var it = std.mem.tokenizeScalar(ubyte, std.mem.span(prefixed_names), ' ');
                \\        while (it.next()) |prefixed_name| {
                \\            if (std.mem.eql(ubyte, prefixed_name, "GL_" ++ name)) {
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

const fmtId = std.zig.fmt.fmtId;

fn fmtDeclId(bytes: []const u8) std.fmt.Formatter(formatDeclId) {
    return .{ .data = bytes };
}

fn formatDeclId(
    bytes: []const u8,
    comptime _: []const u8,
    format_options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    if (std.zig.fmt.isValidId(bytes) and !std.zig.primitives.isPrimitive(bytes)) {
        return writer.writeAll(bytes);
    }
    try writer.writeAll("@\"");
    try std.zig.fmt.stringEscape(bytes, "", format_options, writer);
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
        .DEBUGPROC, .DEBUGPROCARB, .DEBUGPROCKHR => "*const fn (source: @\"enum\", @\"type\": @\"enum\", id: uint, severity: @\"enum\", length: sizei, message: [*:0]const char, userParam: ?*const anyopaque) callconv(APIENTRY) void",
        .DEBUGPROCAMD => "*const fn (id: uint, category: @\"enum\", severity: @\"enum\", length: sizei, message: [*:0]const char, userParam: ?*anyopaque) callconv(APIENTRY) void",
        .VULKANPROCNV => "*const fn () callconv(APIENTRY) void",
        .bitfield, .@"enum", .uint => "c_uint",
        .boolean, .char, .charARB, .ubyte => "u8",
        .byte => "i8",
        .cl_context, .cl_event, .eglClientBufferEXT, .eglImageOES, .sync => "*opaque {}",
        .clampd, .double => "f64",
        .clampf, .float => "f32",
        .clampx, .fixed => "i32",
        .half, .halfARB, .ushort => "u16",
        .halfNV => "c_ushort",
        .handleARB => "if (builtin.os.tag.isDarwin()) *allowzero anyopaque else u32",
        .int, .sizei => "c_int",
        .int64, .int64EXT => "i64",
        .intptr, .intptrARB, .sizeiptr, .sizeiptrARB => "isize",
        .short => "i16",
        .uint64, .uint64EXT => "u64",
        .vdpauSurfaceNV => "intptr",
        .khrplatform, .void => unreachable,
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
        .BufferStorageExternalEXT,
        .NamedBufferStorageExternalEXT,
        => switch (param_index) {
            3 => .{ .name = "clientBuffer", .type_expr = "eglClientBufferEXT" },
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
        .CreateSyncFromCLeventARB => switch (param_index) {
            0 => .{ .name = "context", .type_expr = "cl_context" },
            1 => .{ .name = "event", .type_expr = "cl_event" },
            else => null,
        },
        .DebugMessageCallback => switch (param_index) {
            0 => .{ .name = "callback", .type_expr = "?DEBUGPROC" },
            else => null,
        },
        .DebugMessageCallbackAMD => switch (param_index) {
            0 => .{ .name = "callback", .type_expr = "?DEBUGPROCAMD" },
            else => null,
        },
        .DebugMessageCallbackARB => switch (param_index) {
            0 => .{ .name = "callback", .type_expr = "?DEBUGPROCARB" },
            else => null,
        },
        .DebugMessageCallbackKHR => switch (param_index) {
            0 => .{ .name = "callback", .type_expr = "?DEBUGPROCKHR" },
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
        .EGLImageTargetRenderbufferStorageOES,
        .EGLImageTargetTexStorageEXT,
        .EGLImageTargetTexture2DOES,
        .EGLImageTargetTextureStorageEXT,
        => switch (param_index) {
            0 => .{ .name = "image", .type_expr = "eglImageOES" },
            else => null,
        },
        .GetBooleani_v => switch (param_index) {
            2 => .{ .name = "data", .type_expr = "[*]boolean" },
            else => null,
        },
        .GetBooleanv => switch (param_index) {
            1 => .{ .name = "data", .type_expr = "[*]boolean" },
            else => null,
        },
        .GetDoublei_v => switch (param_index) {
            2 => .{ .name = "data", .type_expr = "[*]double" },
            else => null,
        },
        .GetDoublev => switch (param_index) {
            1 => .{ .name = "data", .type_expr = "[*]double" },
            else => null,
        },
        .GetFloati_v => switch (param_index) {
            2 => .{ .name = "data", .type_expr = "[*]float" },
            else => null,
        },
        .GetFloatv => switch (param_index) {
            1 => .{ .name = "data", .type_expr = "[*]float" },
            else => null,
        },
        .GetInteger64i_v => switch (param_index) {
            2 => .{ .name = "data", .type_expr = "[*]int64" },
            else => null,
        },
        .GetInteger64v => switch (param_index) {
            1 => .{ .name = "data", .type_expr = "[*]int64" },
            else => null,
        },
        .GetIntegeri_v => switch (param_index) {
            2 => .{ .name = "data", .type_expr = "[*]int" },
            else => null,
        },
        .GetIntegerv => switch (param_index) {
            1 => .{ .name = "data", .type_expr = "[*]int" },
            else => null,
        },
        .GetVkProcAddrNV => switch (param_index) {
            0 => .{ .name = "name", .type_expr = "[*:0]const char" },
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
        .GetVkProcAddrNV => .{ .type_expr = "?VULKANPROCNV" },
        else => null,
    };
}
