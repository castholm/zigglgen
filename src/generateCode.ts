import type { ResolvedFeatures } from "./resolveFeatures.ts"

const NOTICE = [
  "// NOTICE\n",
  "//\n",
  "// This work uses definitions from the OpenGL XML API Registry\n",
  "// <https://github.com/KhronosGroup/OpenGL-Registry>.\n",
  "// Copyright 2013-2020 The Khronos Group Inc.\n",
  "// Licensed under Apache-2.0.\n",
  "//\n",
  "// END OF NOTICE\n",
].join("")

const GENERATOR_NAME = "zigglgen v0.4.1"
const GENERATOR_URL = "https://castholm.github.io/zigglgen/"

export function generateCode(features: ResolvedFeatures, apiVersionProfile: string): string {
  const [, , versionMajor, versionMinor] =
    /^(.*)[ ]([0-9])\.([0-9])(?:[ ]\((.+)\))?$/.exec(apiVersionProfile)!
  const hasExtensions = !!features.extensions.size

  const sb: string[] = []
  sb.push(NOTICE)
  sb.push("\n")
  sb.push('const std = @import("std");\n')
  sb.push('const root = @import("root");\n')
  sb.push("\n")
  sb.push("/// Static information about this source file and when/how it was generated.\n")
  sb.push("pub const about = struct {\n")
  sb.push(`    pub const api_name = "${apiVersionProfile}";\n`)
  sb.push(`    pub const api_version_major = ${versionMajor};\n`)
  sb.push(`    pub const api_version_minor = ${versionMinor};\n`)
  sb.push("\n")
  sb.push(`    pub const generated_at = "${new Date().toISOString().slice(0, 19)}Z";\n`)
  sb.push("\n")
  sb.push(`    pub const generator_name = "${GENERATOR_NAME}";\n`)
  sb.push(`    pub const generator_url = "${GENERATOR_URL}";\n`)
  sb.push("};\n")
  sb.push("\n")
  sb.push("/// Makes the specified dispatch table current on the calling thread. This function must be called\n")
  sb.push("/// with a valid dispatch table before calling `extensionSupported()` or any OpenGL command\n")
  sb.push("/// functions on that same thread.\n")
  sb.push("pub fn makeDispatchTableCurrent(dispatch_table: ?*const DispatchTable) void {\n")
  sb.push("    DispatchTable.current = dispatch_table;\n")
  sb.push("}\n")
  sb.push("\n")
  sb.push("/// Returns the dispatch table that is current on the calling thread, or `null` if no dispatch table\n")
  sb.push("/// is current.\n")
  sb.push("pub fn getCurrentDispatchTable() ?*const DispatchTable {\n")
  sb.push("    return DispatchTable.current;\n")
  sb.push("}\n")
  sb.push("\n")
  if (hasExtensions) {
    sb.push("/// Returns a boolean value indicating whether the specified extension is currently supported.\n")
    sb.push("pub fn extensionSupported(comptime extension: Extension) bool {\n")
    sb.push('    return @field(DispatchTable.current.?, "GL_" ++ @tagName(extension));\n')
    sb.push("}\n")
    sb.push("\n")
    sb.push("pub const Extension = enum {\n")
    for (const extension of features.extensions.values()) {
      sb.push(`    ${zigIdentifier(extension.name)},\n`)
    }
    sb.push("};\n")
    sb.push("\n")
  }
  sb.push("//#region Types\n")
  for (const type of features.types.values()) {
    sb.push(`pub const ${type.name} = ${type.type};\n`)
  }
  sb.push("//#endregion Types\n")
  sb.push("\n")
  sb.push("//#region Constants\n")
  for (const constant of features.constants.values()) {
    sb.push(`pub const ${zigIdentifier(constant.name)} = ${constant.value};\n`)
  }
  sb.push("//#endregion Constants\n")
  sb.push("\n")
  sb.push("//#region Commands\n")
  for (const command of features.commands.values()) {
    sb.push(`pub fn ${zigIdentifier(command.name)}(`)
    sb.push(command.params.map(x => `${zigIdentifier(x.name)}: ${x.type}`).join(", "))
    sb.push(`) callconv(.C) ${command.type} {\n`)
    sb.push(`    return DispatchTable.current.?.invokeIntercepted("${command.key}", .{`)
    if (command.params.length > 1) {
      sb.push(" ");
    }
    sb.push(command.params.map(x => `${zigIdentifier(x.name)}`).join(", "))
    if (command.params.length > 1) {
      sb.push(" ");
    }
    sb.push("});\n")
    sb.push("}\n")
  }
  sb.push("//#endregion Commands\n")
  sb.push("\n")
  sb.push("/// Holds dynamically loaded OpenGL features.\n")
  sb.push("///\n")
  sb.push("/// This struct is very large; avoid storing instances of it on the stack.\n")
  sb.push("pub const DispatchTable = struct {\n")
  sb.push("    threadlocal var current: ?*const DispatchTable = null;\n")
  sb.push("\n")
  sb.push("    //#region Fields\n")
  for (const extension of features.extensions.values()) {
    sb.push(`    ${zigIdentifier(extension.key)}: bool,\n`)
  }
  for (const command of features.commands.values()) {
    sb.push(`    ${zigIdentifier(command.key)}: `)
    if (command.optional) {
      sb.push("?")
    }
    sb.push(`*const @TypeOf(${zigIdentifier(command.name)}),\n`)
  }
  sb.push("    //#endregion Fields\n")
  sb.push("\n")
  sb.push("    /// Initializes the specified dispatch table. Returns `true` if successful, `false` otherwise.\n")
  sb.push("    ///\n")
  sb.push("    /// This function must be called successfully before passing the dispatch table to\n")
  sb.push("    /// `makeDispatchTableCurrent()`, `invoke()`, `invokeIntercepted()` or accessing any of its\n")
  sb.push("    /// fields.\n")
  sb.push("    ///\n")
  sb.push("    /// `loader` is duck-typed and can be either a container or an instance, so long as it satisfies\n")
  sb.push("    /// the following code:\n")
  sb.push("    ///\n")
  sb.push("    /// ```\n")
  sb.push('    /// const prefixed_command_name: [:0]const u8 = "glExample";\n')
  sb.push("    /// const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;\n")
  sb.push("    /// const fn_ptr_opt: ?AnyCFnPtr = loader.GetCommandFnPtr(prefixed_command_name);\n")
  sb.push("    /// _ = fn_ptr_opt;\n")
  if (hasExtensions) {
    sb.push("    ///\n")
    sb.push('    /// const prefixed_extension_name: [:0]const u8 = "GL_EXT_example";\n')
    sb.push("    /// const supported: bool = loader.extensionSupported(prefixed_extension_name);\n")
    sb.push("    /// _ = supported;\n")
  }
  sb.push("    /// ```\n")
  sb.push("    ///\n")
  sb.push("    /// No references to `loader` are retained after this function returns. There is no\n")
  sb.push("    /// corresponding `deinit()` function.\n")
  sb.push("    pub fn init(self: *DispatchTable, loader: anytype) bool {\n")
  sb.push("        @setEvalBranchQuota(1_000_000);\n")
  sb.push("        var success: u1 = 1;\n")
  sb.push("        inline for (@typeInfo(DispatchTable).Struct.fields) |field_info| {\n")
  sb.push("            const prefixed_feature_name = comptime nullTerminate(field_info.name);\n")
  sb.push("            switch (@typeInfo(field_info.type)) {\n")
  sb.push("                .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {\n")
  sb.push("                    .Fn => success &= @intFromBool(self.load(loader, prefixed_feature_name)),\n")
  sb.push("                    else => comptime unreachable,\n")
  sb.push("                },\n")
  if (hasExtensions) {
    sb.push("                .Bool => @field(self, prefixed_feature_name) = false,\n")
    sb.push("                .Optional => |opt_info| switch (@typeInfo(opt_info.child)) {\n")
    sb.push("                    .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {\n")
    sb.push("                        .Fn => @field(self, prefixed_feature_name) = null,\n")
    sb.push("                        else => comptime unreachable,\n")
    sb.push("                    },\n")
    sb.push("                    else => comptime unreachable,\n")
    sb.push("                },\n")
  }
  sb.push("                else => comptime unreachable,\n")
  sb.push("            }\n")
  sb.push("        }\n")
  for (const extension of features.extensions.values()) {
    sb.push(`        if (loader.extensionSupported("${extension.key}")) {\n`)
    for (const command of extension.commands.map(x => features.commands.get(x)!)) {
      sb.push(`            _ = self.load(loader, "${command.key}");\n`)
    }
    sb.push(`            self.${zigIdentifier(extension.key)} = true;\n`)
    sb.push(`        }\n`)
  }
  sb.push("        return success != 0;\n")
  sb.push("    }\n")
  sb.push("\n")
  sb.push("    fn nullTerminate(comptime string: []const u8) [:0]const u8 {\n")
  sb.push("        comptime {\n")
  sb.push("            var buf: [string.len + 1]u8 = undefined;\n")
  sb.push("            std.mem.copy(u8, &buf, string);\n")
  sb.push("            buf[string.len] = 0;\n")
  sb.push("            return buf[0..string.len :0];\n")
  sb.push("        }\n")
  sb.push("    }\n")
  sb.push("\n")
  sb.push("    fn load(\n")
  sb.push("        self: *DispatchTable,\n")
  sb.push("        loader: anytype,\n")
  sb.push("        comptime prefixed_command_name: [:0]const u8,\n")
  sb.push("    ) bool {\n")
  sb.push("        const FieldType = @TypeOf(@field(self, prefixed_command_name));\n")
  sb.push("        const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;\n")
  sb.push("        const fn_ptr_opt: ?AnyCFnPtr = loader.getCommandFnPtr(prefixed_command_name);\n")
  sb.push("        if (fn_ptr_opt) |fn_ptr| {\n")
  sb.push("            @field(self, prefixed_command_name) = @ptrCast(fn_ptr);\n")
  sb.push("            return true;\n")
  sb.push("        } else {\n")
  sb.push("            return @typeInfo(FieldType) == .Optional;\n")
  sb.push("        }\n")
  sb.push("    }\n")
  sb.push("\n")
  sb.push("    /// Invokes the specified OpenGL command with the specified arguments. The invocation will not\n")
  sb.push("    /// be intercepted.\n")
  sb.push("    pub fn invoke(\n")
  sb.push("        self: *const DispatchTable,\n")
  sb.push("        comptime prefixed_command_name: [:0]const u8,\n")
  sb.push("        args: anytype,\n")
  sb.push("    ) ReturnType(prefixed_command_name) {\n")
  sb.push("        const FieldType = @TypeOf(@field(self, prefixed_command_name));\n")
  sb.push("        return if (@typeInfo(FieldType) == .Optional)\n")
  sb.push("            @call(.auto, @field(self, prefixed_command_name).?, args)\n")
  sb.push("        else\n")
  sb.push("            @call(.auto, @field(self, prefixed_command_name), args);\n")
  sb.push("    }\n")
  sb.push("\n")
  sb.push("    /// Invokes the specified OpenGL command with the specified arguments. The invocation will be\n")
  sb.push("    /// intercepted by `options.intercept()`.\n")
  sb.push("    pub fn invokeIntercepted(\n")
  sb.push("        self: *const DispatchTable,\n")
  sb.push("        comptime prefixed_command_name: [:0]const u8,\n")
  sb.push("        args: anytype,\n")
  sb.push("    ) ReturnType(prefixed_command_name) {\n")
  sb.push("        return options.intercept(self, prefixed_command_name, args);\n")
  sb.push("    }\n")
  sb.push("\n")
  sb.push("    pub fn ReturnType(comptime prefixed_command_name: [:0]const u8) type {\n")
  sb.push("        const FieldType = @TypeOf(@field(@as(DispatchTable, undefined), prefixed_command_name));\n")
  sb.push("        if (@hasField(DispatchTable, prefixed_command_name)) {\n")
  sb.push("            switch (@typeInfo(FieldType)) {\n")
  sb.push("                .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {\n")
  sb.push("                    .Fn => |fn_info| return fn_info.return_type.?,\n")
  sb.push("                    else => comptime unreachable,\n")
  sb.push("                },\n")
  sb.push("                .Bool => {},\n")
  sb.push("                .Optional => |opt_info| switch (@typeInfo(opt_info.child)) {\n")
  sb.push("                    .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {\n")
  sb.push("                        .Fn => |fn_info| return fn_info.return_type.?,\n")
  sb.push("                        else => comptime unreachable,\n")
  sb.push("                    },\n")
  sb.push("                    else => comptime unreachable,\n")
  sb.push("                },\n")
  sb.push("                else => comptime unreachable,\n")
  sb.push("            }\n")
  sb.push("        }\n")
  sb.push(`        @compileError("unknown command: '" ++ prefixed_command_name ++ "'");\n`)
  sb.push("    }\n")
  sb.push("};\n")
  sb.push("\n")
  sb.push("/// Options that can be overriden by publicly declaring a container named `gl_options` in the root\n")
  sb.push("/// source file.\n")
  sb.push("pub const options = struct {\n")
  sb.push("    /// Intercepts OpenGL command invocations.\n")
  sb.push("    pub const intercept: @TypeOf(struct {\n")
  sb.push("        fn intercept(\n")
  sb.push("            dispatch_table: *const DispatchTable,\n")
  sb.push("            comptime prefixed_command_name: [:0]const u8,\n")
  sb.push("            args: anytype,\n")
  sb.push("        ) DispatchTable.ReturnType(prefixed_command_name) {\n")
  sb.push("            _ = args;\n")
  sb.push("            _ = dispatch_table;\n")
  sb.push("            comptime unreachable;\n")
  sb.push("        }\n")
  sb.push('    }.intercept) = if (@hasDecl(options_overrides, "intercept"))\n')
  sb.push("        options_overrides.intercept\n")
  sb.push("    else\n")
  sb.push("        DispatchTable.invoke;\n")
  sb.push("};\n")
  sb.push("\n")
  sb.push('const options_overrides = if (@hasDecl(root, "gl_options")) root.gl_options else struct {};\n')
  sb.push("\n")
  sb.push("comptime {\n")
  sb.push("    for (@typeInfo(options_overrides).Struct.decls) |decl| {\n")
  sb.push(`        if (!@hasDecl(options, decl.name)) @compileError("unknown option: '" ++ decl.name ++ "'");\n`)
  sb.push("    }\n")
  sb.push("}\n")
  sb.push("\n")
  sb.push("test {\n")
  sb.push("    @setEvalBranchQuota(1_000_000);\n")
  sb.push("    std.testing.refAllDeclsRecursive(@This());\n")
  sb.push("}\n")

  return sb.join("")
}

function zigIdentifier(identifier: string): string {
  return ZIG_UNQUOTED_IDENTIFIER_REGEX.test(identifier) ? identifier : `@"${identifier}"`
}

const ZIG_UNQUOTED_IDENTIFIER_REGEX = RegExp(`^(?!(${[
  "_",

  // https://github.com/ziglang/zig/blob/fac120bc3ad58a10ab80952e42becd0084aec059/lib/std/zig/tokenizer.zig#L12-L62
  "addrspace",
  "align",
  "allowzero",
  "and",
  "anyframe",
  "anytype",
  "asm",
  "async",
  "await",
  "break",
  "callconv",
  "catch",
  "comptime",
  "const",
  "continue",
  "defer",
  "else",
  "enum",
  "errdefer",
  "error",
  "export",
  "extern",
  "fn",
  "for",
  "if",
  "inline",
  "linksection",
  "noalias",
  "noinline",
  "nosuspend",
  "opaque",
  "or",
  "orelse",
  "packed",
  "pub",
  "resume",
  "return",
  "struct",
  "suspend",
  "switch",
  "test",
  "threadlocal",
  "try",
  "union",
  "unreachable",
  "usingnamespace",
  "var",
  "volatile",
  "while",

  // https://github.com/ziglang/zig/blob/fac120bc3ad58a10ab80952e42becd0084aec059/lib/std/zig/primitives.zig#L5-L36
  "anyerror",
  "anyframe",
  "anyopaque",
  "bool",
  "c_char",
  "c_int",
  "c_long",
  "c_longdouble",
  "c_longlong",
  "c_short",
  "c_uint",
  "c_ulong",
  "c_ulonglong",
  "c_ushort",
  "comptime_float",
  "comptime_int",
  "f128",
  "f16",
  "f32",
  "f64",
  "f80",
  "false",
  "isize",
  "noreturn",
  "null",
  "true",
  "type",
  "undefined",
  "usize",
  "void",
  "([iu][0-9]+)",
].join("|")})$)[A-Z_a-z][0-9A-Z_a-z]*$`)
