import type { ResolvedFeatures } from "./resolveFeatures.ts"

const GENERATOR_NAME = "zigglgen v0.3"
const GENERATOR_PROJECT_URL = "https://github.com/castholm/zigglgen/"

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
  sb.push("/// Static information about this source file and how it was generated.\n")
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
  sb.push("threadlocal var current_binding: ?*const Binding = null;\n")
  sb.push("\n")
  sb.push("/// Makes the specified binding current on the calling thread. This function must be called and\n")
  sb.push("/// passed a valid binding before calling `extensionSupported()` or any OpenGL command functions on\n")
  sb.push("/// that same thread.\n")
  sb.push("pub fn makeBindingCurrent(binding: ?*const Binding) void {\n")
  sb.push("    current_binding = binding;\n")
  sb.push("}\n")
  sb.push("\n")
  sb.push("/// Returns the binding that is current on the calling thread, or `null` if no binding is current.\n")
  sb.push("pub fn getCurrentBinding() ?*const Binding {\n")
  sb.push("    return current_binding;\n")
  sb.push("}\n")
  sb.push("\n")
  if (hasExtensions) {
    sb.push("/// Returns a boolean value indicating whether the specified extension is currently supported.\n")
    sb.push("pub fn extensionSupported(comptime extension: Extension) bool {\n")
    sb.push('    return @field(current_binding.?, "GL_" ++ @tagName(extension));\n')
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
    sb.push(`    return current_binding.?.${zigIdentifier(command.key)}`)
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
  sb.push("/// Holds dynamically loaded OpenGL features.\n")
  sb.push("///\n")
  sb.push("/// This struct is very large; avoid storing instances of it on the stack.\n")
  sb.push("pub const Binding = struct {\n")
  sb.push("    /// Initializes the specified binding. This function must be called before passing the binding\n")
  sb.push("    /// to `makeBindingCurrent()` or accessing any of its fields.\n")
  sb.push("    ///\n")
  sb.push("    /// `loader` is duck-typed and can be either a container or an instance, so long as it satisfies\n")
  sb.push("    /// the following code:\n")
  sb.push("    ///\n")
  sb.push("    /// ```\n")
  sb.push('    /// const command_name: [:0]const u8 = "glExample";\n')
  sb.push("    /// const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;\n")
  sb.push("    /// const fn_ptr: ?AnyCFnPtr = loader.GetCommandFnPtr(command_name);\n")
  sb.push("    /// _ = fn_ptr;\n")
  if (hasExtensions) {
    sb.push("    ///\n")
    sb.push('    /// const extension_name: [:0]const u8 = "GL_EXT_example";\n')
    sb.push("    /// const supported: bool = loader.extensionSupported(extension_name);\n")
    sb.push("    /// _ = supported;\n")
  }
  sb.push("    /// ```\n")
  sb.push("    ///\n")
  sb.push("    /// No references to `loader` are retained after this function returns. There is no\n")
  sb.push("    /// corresponding `deinit()` function.\n")
  sb.push("    pub fn init(self: *Binding, loader: anytype) void {\n")
  sb.push("        @setEvalBranchQuota(1_000_000);\n")
  sb.push("        inline for (std.meta.fields(Binding)) |field_info| {\n")
  sb.push("            const feature_name = comptime nullTerminate(field_info.name);\n")
  sb.push("            switch (@typeInfo(field_info.type)) {\n")
  if (hasExtensions) {
    sb.push("                .Bool => @field(self, feature_name) = false,\n")
    sb.push("                .Optional => |opt_info| switch (@typeInfo(opt_info.child)) {\n")
    sb.push("                    .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {\n")
    sb.push("                        .Fn => @field(self, feature_name) = null,\n")
    sb.push("                        else => comptime unreachable,\n")
    sb.push("                    },\n")
    sb.push("                    else => comptime unreachable,\n")
    sb.push("                },\n")
  }
  sb.push("                .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {\n")
  sb.push("                    .Fn => self.loadCommand(loader, feature_name),\n")
  sb.push("                    else => comptime unreachable,\n")
  sb.push("                },\n")
  sb.push("                else => comptime unreachable,\n")
  sb.push("            }\n")
  sb.push("        }\n")
  for (const extension of features.extensions.values()) {
    sb.push(`        if (loader.extensionSupported("${zigIdentifier(extension.key)}")) {\n`)
    for (const command of extension.commands.map(x => features.commands.get(x)!)) {
      sb.push(`            self.loadCommand(loader, "${zigIdentifier(command.key)}");\n`)
    }
    sb.push(`            self.${zigIdentifier(extension.key)} = true;\n`)
    sb.push(`        }\n`)
  }
  sb.push("    }\n")
  sb.push("\n")
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
  sb.push("    fn loadCommand(self: *Binding, loader: anytype, comptime name: [:0]const u8) void {\n")
  sb.push("        const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;\n")
  sb.push("        const fn_ptr: ?AnyCFnPtr = loader.getCommandFnPtr(name);\n")
  sb.push("        @field(self, name) = @ptrCast(@TypeOf(@field(self, name)), fn_ptr);\n")
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
