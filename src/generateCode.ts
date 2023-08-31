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

const GENERATOR_NAME = "zigglgen v0.5"
const GENERATOR_URL = "https://castholm.github.io/zigglgen/"

export function generateCode(
  features: ResolvedFeatures,
  apiName: string,
  apiVersion: string,
  preserveNames: boolean,
): string {
  const [versionMajor, versionMinor] = apiVersion.split(".")
  const hasExtensions = !!features.extensions.size

  const sb: string[] = []
  sb.push(NOTICE)
  sb.push("\n")
  sb.push("//! OpenGL binding.\n")
  sb.push("\n")
  sb.push('const std = @import("std");\n')
  sb.push('const root = @import("root");\n')
  sb.push("\n")
  sb.push("/// Static information about the OpenGL binding and when/how it was generated.\n")
  sb.push("pub const about = struct {\n")
  sb.push(`    pub const api_name = "${apiName}";\n`)
  sb.push(`    pub const api_version_major = ${versionMajor!};\n`)
  sb.push(`    pub const api_version_minor = ${versionMinor!};\n`)
  sb.push("\n")
  sb.push(`    pub const generated_at = "${new Date().toISOString().slice(0, 19)}Z";\n`)
  sb.push("\n")
  sb.push(`    pub const generator_name = "${GENERATOR_NAME}";\n`)
  sb.push(`    pub const generator_url = "${GENERATOR_URL}";\n`)
  sb.push("};\n")
  sb.push("\n")
  sb.push("/// Makes the specified dispatch table current on the calling thread.\n")
  sb.push("///\n")
  sb.push("/// This function must be called with a valid dispatch table before calling `extensionSupported` or\n")
  sb.push("/// issuing any OpenGL commands from that same thread.\n")
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
    sb.push("/// Returns `true` if the specified OpenGL extension is supported, `false` otherwise.\n")
    sb.push("pub fn extensionSupported(comptime extension: Extension) bool {\n")
    sb.push("    return @field(DispatchTable.current.?, ")
    if (!preserveNames) {
      sb.push('"GL_" ++ ')
    }
    sb.push("@tagName(extension));\n")
    sb.push("}\n")
    sb.push("\n")
    sb.push("/// OpenGL extension.\n")
    sb.push("pub const Extension = enum {\n")
    for (const extension of features.extensions.values()) {
      sb.push(`    ${zigIdentifier(extension.name)},\n`)
    }
    sb.push("};\n")
    sb.push("\n")
  }
  sb.push("//#region Types\n")
  for (const type of features.types.values()) {
    sb.push(`pub const ${zigIdentifier(type.name)} = ${type.type};\n`)
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
    sb.push(`    return issueCommand("${command.key}", .{`)
    if (command.params.length > 1) {
      sb.push(" ")
    }
    sb.push(command.params.map(x => `${zigIdentifier(x.name)}`).join(", "))
    if (command.params.length > 1) {
      sb.push(" ")
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
  sb.push("    /// An opaque pointer to an external function.\n")
  sb.push("    pub const Proc = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;\n")
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
  sb.push("    /// `makeDispatchTableCurrent` or accessing any of fields.\n")
  sb.push("    ///\n")
  sb.push('    /// `loader` is a duck-typed "callable" that takes the prefixed name of an OpenGL command (e.g.\n')
  sb.push("    /// *glClear*) and returns a pointer to the corresponding function. It should be able to be\n")
  sb.push("    /// called in one of the following two ways:\n")
  sb.push("    ///\n")
  sb.push("    /// - `@as(?DispatchTable.Proc, loader(@as([*:0]const u8, prefixed_name)))`\n")
  sb.push("    /// - `@as(?DispatchTable.Proc, loader.getProcAddress(@as([*:0]const u8, prefixed_name)))`\n")
  sb.push("    ///\n")
  sb.push("    /// No references to `loader` are retained after this function returns.\n")
  sb.push("    ///\n")
  sb.push("    /// There is no corresponding `deinit` function.\n")
  sb.push("    pub fn init(self: *DispatchTable, loader: anytype) bool {\n")
  sb.push("        @setEvalBranchQuota(1_000_000);\n")
  sb.push("        var success: u1 = 1;\n")
  sb.push("        inline for (@typeInfo(DispatchTable).Struct.fields) |field_info| {\n")
  sb.push("            switch (@typeInfo(field_info.type)) {\n")
  sb.push("                .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {\n")
  sb.push("                    .Fn => {\n")
  sb.push('                        success &= @intFromBool(self.initCommand(field_info.name ++ "", loader));\n')
  sb.push("                    },\n")
  sb.push("                    else => comptime unreachable,\n")
  sb.push("                },\n")
  if (hasExtensions) {
    sb.push("                .Bool => {\n")
    sb.push("                    @field(self, field_info.name) = false;\n")
    sb.push("                },\n")
    sb.push("                .Optional => |opt_info| switch (@typeInfo(opt_info.child)) {\n")
    sb.push("                    .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {\n")
    sb.push("                        .Fn => {\n")
    sb.push("                            @field(self, field_info.name) = null;\n")
    sb.push("                        },\n")
    sb.push("                        else => comptime unreachable,\n")
    sb.push("                    },\n")
    sb.push("                    else => comptime unreachable,\n")
    sb.push("                },\n")
  }
  sb.push("                else => comptime unreachable,\n")
  sb.push("            }\n")
  sb.push("        }\n")
  if (hasExtensions) {
    sb.push("        if (success == 0) return false;\n")
    for (const extension of features.extensions.values()) {
      if (extension.commands.length) {
        sb.push(`        if (self.initExtension("${extension.key}")) {\n`)
        for (const command of extension.commands.map(x => features.commands.get(x)!)) {
          sb.push(`            _ = self.initCommand("${command.key}", loader);\n`)
        }
        sb.push(`        }\n`)
      } else {
        sb.push(`        _ = self.initExtension("${extension.key}");\n`)
      }
    }
    sb.push("        return true;\n")
  } else {
    sb.push("        return success != 0;\n")
  }
  sb.push("    }\n")
  sb.push("\n")
  sb.push("    fn initCommand(\n")
  sb.push("        self: *DispatchTable,\n")
  sb.push("        comptime prefixed_name: [:0]const u8,\n")
  sb.push("        loader: anytype,\n")
  sb.push("    ) bool {\n")
  sb.push("        const loader_info = @typeInfo(@TypeOf(loader));\n")
  sb.push("        const loader_is_fn =\n")
  sb.push("            loader_info == .Fn or\n")
  sb.push("            loader_info == .Pointer and @typeInfo(loader_info.Pointer.child) == .Fn;\n")
  sb.push("        const proc_opt: ?DispatchTable.Proc = if (loader_is_fn)\n")
  sb.push("            loader(prefixed_name)\n")
  sb.push("        else\n")
  sb.push("            loader.getProcAddress(prefixed_name);\n")
  sb.push("        if (proc_opt) |proc| {\n")
  sb.push("            @field(self, prefixed_name) = @ptrCast(proc);\n")
  sb.push("            return true;\n")
  sb.push("        } else {\n")
  sb.push("            return @typeInfo(@TypeOf(@field(self, prefixed_name))) == .Optional;\n")
  sb.push("        }\n")
  sb.push("    }\n")
  if (hasExtensions) {
    sb.push("\n")
    sb.push("    fn initExtension(\n")
    sb.push("        self: *DispatchTable,\n")
    sb.push("        comptime prefixed_name: [:0]const u8,\n")
    sb.push("    ) bool {\n")
    if (+versionMajor! >= 3) {
      sb.push(`        var count: ${preserveNames ? "GLint" : "Int"} = 0;\n`)
      sb.push(`        self.glGetIntegerv(${preserveNames ? "GL_" : ""}NUM_EXTENSIONS, &count);\n`)
      sb.push("        for (0..@intCast(count)) |i| {\n")
      sb.push(`            if (self.glGetStringi(${preserveNames ? "GL_" : ""}EXTENSIONS, @intCast(i))) |name| {\n`)
      sb.push("                if (std.mem.orderZ(u8, prefixed_name, name) == .eq) {\n")
      sb.push("                    @field(self, prefixed_name) = true;\n")
      sb.push("                    return true;\n")
      sb.push("                }\n")
      sb.push("            }\n")
      sb.push("        }\n")
      sb.push("        return false;\n")
    } else {
      sb.push(`        var names = std.mem.tokenizeScalar(u8, std.mem.span(self.glGetString(${preserveNames ? "GL_" : ""}EXTENSIONS)), ' ');\n`)
      sb.push("        while (names.next()) |name| {\n")
      sb.push("            if (std.mem.eql(u8, prefixed_name, name)) {\n")
      sb.push("                @field(self, prefixed_name) = true;\n")
      sb.push("                return true;\n")
      sb.push("            }\n")
      sb.push("        }\n")
      sb.push("        return false;\n")
    }
    sb.push("    }\n")
  }
  sb.push("};\n")
  sb.push("\n")
  sb.push("/// Issues the specified OpenGL command.\n")
  sb.push("///\n")
  sb.push("/// This function is called internally by the OpenGL binding. Its implementation can be overridden\n")
  sb.push("/// by publicly declaring a function named `gl_issueCommand` with a compatible signature in the root\n")
  sb.push("/// source file.\n")
  sb.push("pub fn issueCommand(\n")
  sb.push("    comptime prefixed_name: [:0]const u8,\n")
  sb.push("    args: anytype,\n")
  sb.push(") ReturnTypeOfCommand(prefixed_name) {\n")
  sb.push('    return if (@hasDecl(root, "gl_issueCommand"))\n')
  sb.push("        root.gl_issueCommand(prefixed_name, args)\n")
  sb.push("    else\n")
  sb.push("        defaultIssueCommand(prefixed_name, args);\n")
  sb.push("}\n")
  sb.push("\n")
  sb.push("/// The default implementation of `issueCommand`.\n")
  sb.push("///\n")
  sb.push("/// Overriding implementations can call this function to fall back to the default behavior.\n")
  sb.push("pub fn defaultIssueCommand(\n")
  sb.push("    comptime prefixed_name: [:0]const u8,\n")
  sb.push("    args: anytype,\n")
  sb.push(") ReturnTypeOfCommand(prefixed_name) {\n")
  sb.push("    return if (@typeInfo(@TypeOf(@field(@as(DispatchTable, undefined), prefixed_name))) == .Optional)\n")
  sb.push("        @call(.auto, @field(DispatchTable.current.?, prefixed_name).?, args)\n")
  sb.push("    else\n")
  sb.push("        @call(.auto, @field(DispatchTable.current.?, prefixed_name), args);\n")
  sb.push("}\n")
  sb.push("\n")
  sb.push("/// The return type of the specified OpenGL command.\n")
  sb.push("pub fn ReturnTypeOfCommand(comptime prefixed_name: [:0]const u8) type {\n")
  sb.push("    if (@hasField(DispatchTable, prefixed_name)) {\n")
  sb.push("        return switch (@typeInfo(@TypeOf(@field(@as(DispatchTable, undefined), prefixed_name)))) {\n")
  sb.push("            .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {\n")
  sb.push("                .Fn => |fn_info| fn_info.return_type.?,\n")
  sb.push("                else => comptime unreachable,\n")
  sb.push("            },\n")
  sb.push("            .Bool => {},\n")
  sb.push("            .Optional => |opt_info| switch (@typeInfo(opt_info.child)) {\n")
  sb.push("                .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {\n")
  sb.push("                    .Fn => |fn_info| fn_info.return_type.?,\n")
  sb.push("                    else => comptime unreachable,\n")
  sb.push("                },\n")
  sb.push("                else => comptime unreachable,\n")
  sb.push("            },\n")
  sb.push("            else => comptime unreachable,\n")
  sb.push("        };\n")
  sb.push("    }\n")
  sb.push(`    @compileError("unknown OpenGL command: '" ++ prefixed_name ++ "'");\n`)
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
