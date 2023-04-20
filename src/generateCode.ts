import type { ResolvedFeatures } from "./resolveFeatures.ts"

const GENERATOR_NAME = "zigglgen 0.2"
const GENERATOR_PROJECT_URL = "https://github.com/castholm/zigglgen"

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

export function generateCode(features: ResolvedFeatures, apiVersionProfile: string): string {
  const [, , versionMajor, versionMinor] =
    /^(.*)[ ]([0-9])\.([0-9])(?:[ ]\((.+)\))?$/.exec(apiVersionProfile)!
  const hasExtensions = !!features.extensions.size

  const sb: string[] = []
  sb.push(NOTICE)
  sb.push("\n")
  sb.push('const std = @import("std");\n')
  sb.push("\n")
  sb.push("/// Static information about this OpenGL binding.\n")
  sb.push("pub const info = struct {\n")
  sb.push(`    pub const api_name = "${apiVersionProfile}";\n`)
  sb.push(`    pub const api_version_major = ${versionMajor};\n`)
  sb.push(`    pub const api_version_minor = ${versionMinor};\n`)
  sb.push("\n")
  sb.push(`    pub const generator_name = "${GENERATOR_NAME}";\n`)
  sb.push(`    pub const generator_project_url = "${GENERATOR_PROJECT_URL}";\n`)
  sb.push(`    pub const generated_at = "${new Date().toISOString().slice(0, 19)}Z";\n`)
  sb.push("};\n")
  sb.push("\n")
  sb.push("/// Initializes the OpenGL binding. This function must be called before calling any other function\n")
  sb.push("/// declared by the OpenGL binding.\n")
  sb.push("///\n")
  sb.push("/// `loader` is duck-typed and can be either a container or an instance, so long as it satisfies the\n")
  sb.push("/// following code:\n")
  sb.push("///\n")
  sb.push("/// ```\n")
  sb.push("/// const AnyFnPtr = *align(@alignOf(fn () void)) const anyopaque;\n")
  sb.push('/// _ = @as(?AnyFnPtr, loader.getCommandFnPtr(@as([:0]const u8, "glExample")));\n')
  if (hasExtensions) {
    sb.push('/// _ = @as(bool, loader.extensionSupported(@as([:0]const u8, "GL_EXT_example")));\n')
  }
  sb.push("/// ```\n")
  sb.push("///\n")
  sb.push("/// No references to `loader` are retained by the OpenGL binding after this function returns.\n")
  sb.push("pub fn init(loader: anytype) void {\n")
  sb.push("    state.init(loader);\n")
  sb.push("}\n")
  sb.push("\n")
  if (hasExtensions) {
    sb.push("/// Gets a boolean value indicating whether the specified extension is supported.\n")
    sb.push("pub inline fn extensionSupported(extension: Extension) bool {\n")
    sb.push('    return @field(state.extensions, "GL_" ++ @tagName(extension));\n')
    sb.push("}\n")
    sb.push("\n")
    sb.push("/// Extensions available to the OpenGL binding.\n")
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
    sb.push(`    return state.commands.${zigIdentifier(command.key)}`)
    if (command.optional) {
      sb.push(".?")
    }
    sb.push(`(`)
    sb.push(command.params.map(x => `${zigIdentifier(x.name)}`).join(", "))
    sb.push(");\n")
    sb.push("}\n")
  }
  sb.push("//#endregion Commands\n")
  sb.push("\n")
  sb.push("/// The current state of the OpenGL binding.\n")
  sb.push("pub var state: State = undefined;\n")
  sb.push("\n")
  sb.push("/// OpenGL binding state.\n")
  sb.push("pub const State = struct {\n")
  sb.push("    commands: Commands,\n")
  if (hasExtensions) {
    sb.push("    extensions: Extensions = .{},\n")
  }
  sb.push("\n")
  sb.push("    pub fn init(s: *State, loader: anytype) void {\n")
  sb.push("        @setEvalBranchQuota(1_000_000);\n")
  sb.push("        inline for (std.meta.fields(Commands)) |member_info| {\n")
  sb.push("            switch (@typeInfo(member_info.type)) {\n")
  sb.push("                .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {\n")
  sb.push("                    .Fn => s.loadCommand(loader, nullTerminate(member_info.name)),\n")
  sb.push("                    else => comptime unreachable,\n")
  sb.push("                },\n")
  sb.push("                .Optional => |opt_info| switch (@typeInfo(opt_info.child)) {\n")
  sb.push("                    .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {\n")
  sb.push("                        .Fn => {},\n")
  sb.push("                        else => comptime unreachable,\n")
  sb.push("                    },\n")
  sb.push("                    else => comptime unreachable,\n")
  sb.push("                },\n")
  sb.push("                else => comptime unreachable,\n")
  sb.push("            }\n")
  sb.push("        }\n")
  for (const extension of features.extensions.values()) {
    sb.push(`        if (loader.extensionSupported("${zigIdentifier(extension.key)}")) {\n`)
    for (const command of extension.commands.map(x => features.commands.get(x)!)) {
      sb.push(`            s.loadCommand(loader, "${zigIdentifier(command.key)}");\n`)
    }
    sb.push(`            s.extensions.${zigIdentifier(extension.key)} = true;\n`)
    sb.push(`        }\n`)
  }
  sb.push("    }\n")
  sb.push("\n")
  sb.push("    pub const Commands = struct {\n")
  for (const command of features.commands.values()) {
    sb.push(`        ${zigIdentifier(command.key)}: `)
    if (command.optional) {
      sb.push("?")
    }
    sb.push(`*const @TypeOf(${zigIdentifier(command.name)})`)
    if (command.optional) {
      sb.push(" = null")
    }
    sb.push(",\n")
  }
  sb.push("    };\n")
  sb.push("\n")
  if (hasExtensions) {
    sb.push("    pub const Extensions = struct {\n")
    for (const extension of features.extensions.values()) {
      sb.push(`        ${zigIdentifier(extension.key)}: bool = false,\n`)
    }
    sb.push("    };\n")
    sb.push("\n")
  }
  sb.push("    fn nullTerminate(comptime name: []const u8) [:0]const u8 {\n")
  sb.push("        var buf: [name.len + 1]u8 = undefined;\n")
  sb.push("        std.mem.copy(u8, &buf, name);\n")
  sb.push("        buf[name.len] = 0;\n")
  sb.push("        return buf[0..name.len :0];\n")
  sb.push("    }\n")
  sb.push("\n")
  sb.push("    fn loadCommand(s: *State, loader: anytype, comptime name: [:0]const u8) void {\n")
  sb.push("        const AnyFnPtr = *align(@alignOf(fn () void)) const anyopaque;\n")
  sb.push("        const fn_ptr: ?AnyFnPtr = loader.getCommandFnPtr(name);\n")
  sb.push("        @field(s.commands, name) = @ptrCast(@TypeOf(@field(s.commands, name)), fn_ptr);\n")
  sb.push("    }\n")
  sb.push("};\n")
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
