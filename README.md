# zigglgen

Zig OpenGL binding generator that [runs in your browser](https://castholm.github.io/zigglgen/)

## Disclaimer

Please note that zigglgen currently only officially supports [the nightly master builds of
Zig](https://ziglang.org/download/#release-master). Generated code is not guaranteed to work with earlier versions of
the compiler.

## Usage

Simply visit [the generator web app hosted online](https://castholm.github.io/zigglgen/), select your API, version,
profile and extensions and click *Preview* or *Download* to generate your source file.

Functions, constants, types and extensions are stripped off their prefixes and have their capitalization changed
slightly but are otherwise unchanged from their original C definitions:

| Original C            | Generated Zig      |
|-----------------------|--------------------|
| `glClearColor`        | `clearColor`       |
| `GL_TRIANGLES`        | `TRIANGLES`        |
| `GLfloat`             | `Float`            |
| `GL_ARB_clip_control` | `ARB_clip_control` |

If you prefer, you also have the option of leaving the original C naming convention intact.

### Initialization

Similar to how OpenGL operates on a thread-local *current context*, the generated binding operates on a thread-local
*current dispatch table* in the form of a pointer to an instance of the `DispatchTable` struct.

Before a dispatch table can be made current, it must first be initialized by calling `fn init(self: *DispatchTable,
loader: anytype) bool` while the calling thread has a current OpenGL context. If successful, this will populate the
dispatch table with function pointers and supported extensions from the current context.

The `loader` parameter is a duck-typed "callable" that takes the prefixed name of an OpenGL command (e.g. *glClear*) and
returns a pointer to the corresponding function. It should be able to be called in one of the following two ways:

- `@as(?DispatchTable.Proc, loader(@as([*:0]const u8, prefixed_name)))`
- `@as(?DispatchTable.Proc, loader.getProcAddress(@as([*:0]const u8, prefixed_name)))`

In practice, this most often means simply passing your OpenGL context managing library's "get proc address" function to
the `init` method, i.e. `gl_dispatch_table.init(xyz.getProcAddress)`.

Once initialized, you pass the dispatch table to `fn makeDispatchTableCurrent(dispatch_table: ?*const DispatchTable)
void` to make it current on the calling thread. The dispatch table is only valid for as long as the OpenGL context that
was current when `init` was called remains current; if you change the current context or move it to a different thread
you must also change/move the current dispatch table in the same manner.

In summary, initialization usually looks something like this:

```zig
var gl_dispatch_table: gl.DispatchTable = undefined; // Container-level global variable.

pub fn main() !void {
    // ...

    xyz.makeContextCurrent(gl_context);
    defer xyz.makeContextCurrent(null);

    if (!gl_dispatch_table.init(xyz.getProcAddress)) return error.GlInitFailed;

    gl.makeDispatchTableCurrent(&gl_dispatch_table);
    defer gl.makeDispatchTableCurrent(null);

    // ...
}
```

`DispatchTable` is a very large struct, so you should avoid storing instances of it on the stack. Use global variables
or allocate them on the heap instead.

### Extensions

Extension-specific functions, constants and types are made available as top-level declarations just like standard ones.
If the binding was generated with extensions, you can call `fn extensionSupported(comptime extension: Extension) bool`
to test whether an extension is supported before attempting to use it.

The status for all extensions is loaded in advance when you `init` your dispatch table, so calls to `extensionSupported`
are extremely cheap and compile down to simply testing the value of a boolean field.

### Intercepting Commands

Internally, the binding uses the function `fn issueCommand(comptime prefixed_name: [:0]const u8, args: anytype)
ReturnTypeOfCommand(prefixed_name)` to issue OpenGL commands. The implementation of this function can be overridden,
which can be useful for things like logging, modifying arguments or automatically checking for OpenGL errors.

To override `issueCommand`, simply publicly declare a function named `gl_issueCommand` with a compatible signature in
the root source file. From within this overriding function, you can use `fn defaultIssueCommand(comptime prefixed_name:
[:0]const u8, args: anytype) ReturnTypeOfCommand(prefixed_name)` to issue commands per the default behavior.

```zig
pub fn gl_issueCommand(
    comptime prefixed_name: [:0]const u8,
    args: anytype,
) gl.ReturnTypeOfCommand(prefixed_name) {
    // Check for and log OpenGL errors after invoking commands:
    defer if (comptime !std.mem.eql(u8, "glGetError", prefixed_name)) {
        while (blk: {
            const gl_error = gl.defaultIssueCommand("glGetError", .{});
            break :blk if (gl_error != gl.NO_ERROR) gl_error else null;
        }) |gl_error| {
            std.debug.print("gl error: 0x{X} {s} {any}\n", .{ gl_error, prefixed_name, args });
            std.debug.dumpCurrentStackTrace(@returnAddress());
        }
    };
    // Override the red channel of the clear color:
    if (comptime std.mem.eql(u8, "glClearColor", prefixed_name)) {
        return gl.defaultIssueCommand("glClearColor", .{ 0.5, args[1], args[2], args[3] });
    }
    // Fall back to the default behavior:
    return gl.defaultIssueCommand(prefixed_name, args);
}
```

## Example

Using [mach/glfw](https://github.com/hexops/mach-glfw) and a binding generated with *OpenGL 3.3 (Core Profile)* and the
*NV_scissor_exclusive* extension selected:

<details><summary>Click to expand/collapse</summary>

```zig
const std = @import("std");
const glfw = @import("glfw");
const gl = @import("gl.latest.zig");

var gl_dispatch_table: gl.DispatchTable = undefined;

pub fn main() !void {
    if (!glfw.init(.{})) return error.GlfwInitFailed;
    defer glfw.terminate();

    const window = glfw.Window.create(640, 480, "OpenGL is a art", null, null, .{
        .context_version_major = gl.about.api_version_major,
        .context_version_minor = gl.about.api_version_minor,
        .opengl_profile = .opengl_core_profile,
        .opengl_forward_compat = true,
    }) orelse return error.GlfwInitFailed;
    defer window.destroy();

    glfw.makeContextCurrent(window);
    defer glfw.makeContextCurrent(null);

    if (!gl_dispatch_table.init(glfw.getProcAddress)) return error.GlInitFailed;

    gl.makeDispatchTableCurrent(&gl_dispatch_table);
    defer gl.makeDispatchTableCurrent(null);

    glfw.swapInterval(1);

    main_loop: while (true) {
        glfw.pollEvents();
        if (window.shouldClose()) break :main_loop;

        gl.disable(gl.SCISSOR_TEST);
        if (gl.extensionSupported(.NV_scissor_exclusive)) {
            gl.disable(gl.SCISSOR_TEST_EXCLUSIVE_NV);
            gl.clearColor(1, 0.8, 0.2, 1);
            gl.clear(gl.COLOR_BUFFER_BIT);
            gl.enable(gl.SCISSOR_TEST_EXCLUSIVE_NV);
            gl.scissorExclusiveNV(72, 56, 8, 8);
        }
        gl.clearColor(1, 1, 1, 1);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.enable(gl.SCISSOR_TEST);
        const magic: u256 = 0x1FF8200446024F3A8071E321B0EDAC0A9BFA56AA4BFA26AA13F20802060401F8;
        var i: gl.Int = 0;
        while (i < 256) : (i += 1) {
            if (magic >> @intCast(i) & 1 != 0) {
                gl.scissor(@rem(i, 16) * 8 + 8, @divTrunc(i, 16) * 8 + 8, 8, 8);
                gl.clearColor(0, 0, 0, 1);
                gl.clear(gl.COLOR_BUFFER_BIT);
            }
        }

        window.swapBuffers();
    }
}
```

</details>

## FAQ

### Why is initialization so awkward? Why so much thread-local state?

Initialization and state management is a bit awkward because OpenGL is also a bit awkward and we want generated bindings
to be able to be used in portable multi-threaded multi-context OpenGL programs.

Thread-local state is necessary due to how the loading of command function pointers is specified in the OpenGL spec.
According to the spec, function pointers loaded when one OpenGL context is current are not guaranteed to still be valid
when a different context becomes current. This means that we can't just load pointers into a globally shared dispatch
table. Because current contexts are thread-local, it makes sense to handle dispatch tables in a similar manner.

(It should be noted, however, that in practice, most platforms and OpenGL implementations will return
context-independent pointers that can be safely shared between multiple contexts, though we can't assume that this is
always the case if our goal is maximum portability.)

### Why did calling a function belonging to a supported extension result in a null pointer dereference?

Some OpenGL extensions add features that are only conditionally supported under certain OpenGL versions/profiles or when
certain other extensions are also supported (for example, the command *VertexWeighthNV* added by the extension
*NV_half_float* is only supported when the extension *EXT_vertex_weighting* is also supported). This means that we can't
just assume that all command function pointers associated with a supported extension are non-null after loading is
complete. The definitions that zigglgen derives its output from also do not encode these interactions in a consistent
and structured manner, so we can't generate code that validates the non-nullness of conditional command function
pointers if their conditions are met either (because we don't know what those conditions are).

If your code uses OpenGL extensions it is your responsibility to read the extension specifications carefully and
understand under which conditions added features are supported.

### How do I develop and run zigglgen locally?

```sh
git clone https://github.com/castholm/zigglgen.git
cd zigglgen
npm install
# Debug
npm run dev
# Release
npm run build
npm run preview
```

You can also test your generated bindings; see [`test/README.md`](test/README.md) for more details.

## Licence

zigglgen is licensed under [MIT](LICENSE.md). Dependencies in [`package.json`](package.json) and the [`deps`](deps)
directory may be licensed under different terms.

zigglgen itself does not impose any restrictions on generated code, but because it derives its output from definitions
from the [OpenGL XML API Registry](deps/gl.xml), **generated code is subject to
[Apache-2.0](deps/LICENSE-Apache-2.0.txt)**. If you intend to distribute any work that uses code generated by zigglgen,
you may be required to include

- a copy of Apache-2.0 and
- a copy of the NOTICE text that is included as a comment header in the generated code

with its distribution.

## Acknowledgments and Prior Works

- [KhronosGroup/OpenGL-Registry](https://github.com/KhronosGroup/OpenGL-Registry)
- [Dav1dde/glad](https://github.com/Dav1dde/glad)
- [MasterQ32/zig-opengl](https://github.com/MasterQ32/zig-opengl)
- [linkpy/zig-gl-loader](https://github.com/linkpy/zig-gl-loader)
