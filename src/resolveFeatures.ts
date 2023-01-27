import type { Registry } from "./fetchRegistry.js"
import { compare } from "./utils.js"

// Type renaming algorithm (doesn't work for all identifiers):
//
//     typeKey.replace(
//       /^GL([a-z]|[A-Z]+PROC|[A-Z](?:[A-Z](?=[A-Z]|$))*)/,
//       (...x) => x[1][0].toUpperCase() + x[1].slice(1).toLowerCase(),
//     )
//

const TYPES: ReadonlyMap<string, {
  readonly key: string
  readonly name: string
  readonly type: string
  readonly typeDependency: string | null
  readonly ordinal: number
}> = new Map(([
  //["GLvoid", "Void", "anyopaque"], // Used in old C headers; not an actual OpenGL type.
  ["GLbyte", "Byte", "i8"],
  ["GLubyte", "Ubyte", "u8"],
  ["GLshort", "Short", "c_short"],
  ["GLushort", "Ushort", "c_ushort"],
  ["GLint", "Int", "c_int"],
  ["GLuint", "Uint", "c_uint"],
  ["GLint64", "Int64", "i64"],
  ["GLint64EXT", "Int64EXT", "i64"],
  ["GLuint64", "Uint64", "u64"],
  ["GLuint64EXT", "Uint64EXT", "u64"],
  ["GLintptr", "Intptr", "isize"],
  ["GLintptrARB", "IntptrARB", "isize"],
  ["GLhalf", "Half", "c_ushort"],
  ["GLhalfARB", "HalfARB", "c_ushort"],
  ["GLhalfNV", "HalfNV", "c_ushort"],
  ["GLfloat", "Float", "f32"],
  ["GLdouble", "Double", "f64"],
  ["GLfixed", "Fixed", "i32"],
  ["GLboolean", "Boolean", "u8"],
  ["GLchar", "Char", "u8"],
  ["GLcharARB", "CharARB", "u8"],
  ["GLbitfield", "Bitfield", "c_uint"],
  ["GLenum", "Enum", "c_uint"],
  ["GLsizei", "Sizei", "c_int"],
  ["GLsizeiptr", "Sizeiptr", "isize"],
  ["GLsizeiptrARB", "SizeiptrARB", "isize"],
  ["GLclampf", "Clampf", "f32"],
  ["GLclampd", "Clampd", "f64"],
  ["GLclampx", "Clampx", "i32"],
  ["GLsync", "Sync", "?*opaque {}"],
  ["GLDEBUGPROC", "Debugproc", '?*const fn (source: Enum, @"type": Enum, id: Uint, severity: Enum, length: Sizei, message: [*:0]const Char, userParam: ?*const anyopaque) callconv(.C) void'],
  ["GLDEBUGPROCARB", "DebugprocARB", '?*const fn (source: Enum, @"type": Enum, id: Uint, severity: Enum, length: Sizei, message: [*:0]const Char, userParam: ?*const anyopaque) callconv(.C) void'],
  ["GLDEBUGPROCKHR", "DebugprocKHR", '?*const fn (source: Enum, @"type": Enum, id: Uint, severity: Enum, length: Sizei, message: [*:0]const Char, userParam: ?*const anyopaque) callconv(.C) void'],
  ["GLDEBUGPROCAMD", "DebugprocAMD", "?*const fn (id: Uint, category: Enum, severity: Enum, length: Sizei, message: [*:0]const Char, userParam: ?*anyopaque) callconv(.C) void"],
  ["struct _cl_context", "ClContextARB", "opaque {}"],
  ["struct _cl_event", "ClEventARB", "opaque {}"],
  ["GLeglClientBufferEXT", "EglClientBufferEXT", "?*anyopaque"],
  ["GLeglImageOES", "EglImageOES", "?*anyopaque"],
  ["GLhandleARB", "HandleARB", 'if (@import("builtin").os.tag == .macos) ?*anyopaque else c_uint'],
  ["GLvdpauSurfaceNV", "VdpauSurfaceNV", "Intptr", "GLintptr"],
  ["GLVULKANPROCNV", "VulkanprocNV", "?*const fn () callconv(.C) void"],
] as const).map((x, i) => [x[0], { key: x[0], name: x[1], type: x[2], typeDependency: x[3] ?? null, ordinal: i }]))

const SPECIAL_NUMBERS: ReadonlyMap<string, {
  readonly ordinal: number
}> = new Map(([
  ["GL_ZERO"],
  ["GL_ONE"],
  ["GL_FALSE"],
  ["GL_TRUE"],
  ["GL_NONE"],
  ["GL_NONE_OES"],
  ["GL_NO_ERROR"],
  ["GL_INVALID_INDEX"],
  ["GL_ALL_PIXELS_AMD"],
  ["GL_TIMEOUT_IGNORED"],
  ["GL_TIMEOUT_IGNORED_APPLE"],
  //["GL_VERSION_ES_CL_1_0"], // These are C macros, not constants.
  //["GL_VERSION_ES_CM_1_1"],
  //["GL_VERSION_ES_CL_1_1"],
  ["GL_UUID_SIZE_EXT"],
  ["GL_LUID_SIZE_EXT"],
] as const).map((x, i) => [x[0], { ordinal: i }]))

export type ResolvedFeatures = {
  readonly types: ReadonlyMap<string, ResolvedType>
  readonly constants: ReadonlyMap<string, ResolvedConstant>
  readonly commands: ReadonlyMap<string, ResolvedCommand>
  readonly extensions: ReadonlyMap<string, ResolvedExtension>
}

export type ResolvedType = {
  readonly key: string
  readonly name: string
  readonly type: string
}

export type ResolvedConstant = {
  readonly key: string
  readonly name: string
  readonly value: string
  readonly kind: "special-number" | "bitmask" | "enum" | "other"
}

export type ResolvedCommand = {
  readonly key: string
  readonly name: string
  readonly params: readonly {
    readonly name: string
    readonly type: string
  }[]
  readonly type: string
  readonly optional: boolean
}

export type ResolvedExtension = {
  readonly key: string
  readonly name: string
  readonly commands: readonly string[]
}

export function resolveFeatures(
  registry: Registry,
  api: string,
  version: string,
  profile: string | null,
  extensions: string[],
): ResolvedFeatures {
  const requiredTypes = new Set<string>()
  const requiredConstants = new Set<string>()
  const requiredCommands = new Set<string>()
  const requiredExtensions = new Set(extensions)

  const resolvedTypes: (ResolvedType & {
    readonly ordinal: number
  })[] = []
  const resolvedConstants: (ResolvedConstant & {
    readonly numericValue: bigint
    readonly group: string | null
    readonly specialNumberOrdinal: number
  })[] = []
  const resolvedCommands: (ResolvedCommand & {
    readonly params: readonly {
      // Mutable in order to rename parameters that shadow other declarations after all commands have been resolved.
      name: string
      readonly type: string
    }[]
  })[] = []
  const resolvedExtensions: ResolvedExtension[] = []

  const $root = registry.$root

  { // Process feature elements
    const $features = [...$root.querySelectorAll(`:scope > feature[api=${api}`)]
      .map($ => [$, $.getAttribute("number")!] as const)
      .filter(x => x[1] <= version)
      .sort((a, b) => compare(a[1], b[1]))
      .map(x => x[0])
    const requireSelectors = ":scope > require:not([profile]) > *" + (
      profile ? `, :scope > require[profile=${profile}] > *` : ""
    )
    const removeSelectors = ":scope > remove:not([profile]) > *" + (
      profile ? `, :scope > remove[profile=${profile}] > *` : ""
    )
    for (const $feature of $features) {
      for (const $require of $feature.querySelectorAll(requireSelectors)) {
        const key = $require.getAttribute("name")!
        switch ($require.tagName) {
        case "type":
          requiredTypes.add(key)
          break
        case "enum":
          requiredConstants.add(key)
          break
        case "command":
          requiredCommands.add(key)
          break
        }
      }
      for (const $remove of $feature.querySelectorAll(removeSelectors)) {
        const key = $remove.getAttribute("name")!
        switch ($remove.tagName) {
        case "type":
          requiredTypes.delete(key)
          break
        case "enum":
          requiredConstants.delete(key)
          break
        case "command":
          requiredCommands.delete(key)
          break
        }
      }
    }
  }

  { // Resolve extensions
    const requireSelectors = (profile ? [
      ":scope > require:not([api]):not([profile]) > *",
      `:scope > require:not([api])[profile=${profile}] > *`,
      `:scope > require[api=${api}]:not([profile]) > *`,
      `:scope > require[api=${api}][profile=${profile}] > *`,
    ] : [
      ":scope > require:not([api]) > *",
      `:scope > require[api=${api}] > *`,
    ]).join(", ")
    for (const $extension of $root.querySelectorAll(":scope > extensions > extension")) {
      const extensionKey = $extension.getAttribute("name")!
      if (!requiredExtensions.has(extensionKey)) {
        continue
      }
      if (!$extension.getAttribute("supported")!.split("|").includes(api)) {
        continue
      }
      const optionalCommands = new Set<string>()
      for (const $require of $extension.querySelectorAll(requireSelectors)) {
        const key = $require.getAttribute("name")!
        switch ($require.tagName) {
        case "type":
          requiredTypes.add(key)
          break
        case "enum":
          requiredConstants.add(key)
          break
        case "command":
          if (!requiredCommands.has(key)) {
            optionalCommands.add(key)
          }
          break
        }
      }
      resolvedExtensions.push({
        key: extensionKey,
        name: extensionKey.replace(/^GL_/, ""),
        commands: [...optionalCommands].sort(compare),
      })
    }
    resolvedExtensions.sort((a, b) => compare(a.name, b.name))
  }

  { // Resolve commands
    const optionalCommands = new Set(resolvedExtensions.flatMap(x => x.commands))
    for (const $command of $root.querySelectorAll(":scope > commands > command")) {
      const key = $command.querySelector(":scope > proto > name")!.textContent!
      const required = requiredCommands.has(key)
      if (!required && !optionalCommands.has(key)) {
        continue
      }
      const $proto = $command.querySelector(":scope > proto")!
      const typeDependency = $proto.querySelector(":scope > ptype")?.textContent
      if (typeDependency) {
        requiredTypes.add(typeDependency)
      }

      function parseType(expression: string): string {
        const tokens = expression.match(/(struct\s+)?[^\s*]+|\*/g)!
        if (tokens[0] === "const") {
          [tokens[0], tokens[1]] = [tokens[1]!, tokens[0]]
        }
        if (!tokens.includes("*")) {
          return tokens[0] === "void" ? "void" : TYPES.get(tokens[0])!.name
        }
        let [type, pointer] = tokens[0] === "void"
          ? ["anyopaque", "?*"]
          : tokens[0].startsWith("struct _cl_")
          ? [TYPES.get(tokens[0])!.name, "?*"]
          : [TYPES.get(tokens[0])!.name, "[*c]"]
        for (let i = 1; i < tokens.length - 1; i++) {
          switch (tokens[i]!) {
          case "const":
            type = "const " + type
            break
          case "*":
            type = pointer + type
            pointer = "[*c]"
            break
          }
        }
        return type
      }

      resolvedCommands.push({
        key,
        name: key.replace(/^gl([A-Z](?:[A-Z](?=[A-Z]|$))*)/, (...x) => x[1].toLowerCase()),
        params: [...$command.querySelectorAll(":scope > param")].map($ => {
          const typeDependency = $.querySelector(":scope > ptype")?.textContent
          if (typeDependency) {
            requiredTypes.add(typeDependency)
          }
          return {
            name: $.querySelector(":scope > name")!.textContent!,
            type: parseType($.textContent!),
          }
        }),
        type: parseType($proto.textContent!),
        optional: !required,
      })
    }
    resolvedCommands.sort((a, b) => compare(a.name, b.name))

    // Rename parameters that shadow other declarations.
    const declaredNames = new Set(["init", "extensionSupported", "state", ...resolvedCommands.map(x => x.name)])
    for (const command of resolvedCommands) {
      for (const param of command.params) {
        while (declaredNames.has(param.name)) {
          param.name += "_"
        }
      }
    }
  }

  { // Resolve constants
    for (const $enums of $root.querySelectorAll(":scope > enums")) {
      const group = $enums.getAttribute("group")
      const kind = group === "SpecialNumbers"
        ? "special-number"
        : $enums.getAttribute("type") === "bitmask"
        ? "bitmask"
        : $enums.hasAttribute("start")
        ? "enum"
        : "other"
      for (const $enum of $enums.querySelectorAll(":scope > enum")) {
        const key = $enum.getAttribute("name")!
        if (!requiredConstants.has(key)) {
          continue
        }
        const constantApi = $enum.getAttribute("api")
        if (constantApi && constantApi !== api) {
          continue
        }
        let specialNumberOrdinal = -1
        if (kind === "special-number") {
          const foundOrdinal = SPECIAL_NUMBERS.get(key)?.ordinal
          if (foundOrdinal === undefined) {
            continue
          }
          specialNumberOrdinal = foundOrdinal
        }
        const numericValue = BigInt($enum.getAttribute("value")!)
        resolvedConstants.push({
          key,
          name: key.replace(/^GL_/, ""),
          value: numericValue.toString(16).toUpperCase().replace(/[0-9A-F]+$/, x => "0x" + x),
          numericValue: numericValue,
          kind,
          group,
          specialNumberOrdinal,
        })
      }
    }
      resolvedConstants.sort((a, b) => {
      if (a.kind === "special-number") {
        if (b.kind === "special-number") {
          return a.specialNumberOrdinal - b.specialNumberOrdinal
        }
        return -1
      }
      if (b.kind === "special-number") {
        return 1
      }
      if (a.kind === "bitmask") {
        if (b.kind === "bitmask") {
          return compare(a.group!, b.group!) || compare(a.numericValue, b.numericValue) || compare(a.name, b.name)
        }
        return -1
      }
      if (b.kind === "bitmask") {
        return 1
      }
      if (a.kind === "enum") {
        if (b.kind === "enum") {
          return compare(a.numericValue, b.numericValue) || compare(a.name, b.name)
        }
        return -1
      }
      if (b.kind === "enum") {
        return 1
      }
      return compare(a.group!, b.group!) || compare(a.numericValue, b.numericValue) || compare(a.name, b.name)
    })
  }

  { // Resolve types
    for (const key of requiredTypes) {
      const type = TYPES.get(key)
      if (!type) {
        continue
      }
      if (type.typeDependency) {
        requiredTypes.add(type.typeDependency)
      }
      resolvedTypes.push(type)
    }
    resolvedTypes.sort((a, b) => a.ordinal - b.ordinal)
  }

  return {
    types: new Map(resolvedTypes.map(x => [x.key, x])),
    constants: new Map(resolvedConstants.map(x => [x.key, x])),
    commands: new Map(resolvedCommands.map(x => [x.key, x])),
    extensions: new Map(resolvedExtensions.map(x => [x.key, x])),
  }
}
