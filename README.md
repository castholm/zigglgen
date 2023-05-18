# zigglgen

Zig OpenGL binding generator that [runs in your browser](https://castholm.github.io/zigglgen/)

## Usage

Simply visit [the generator web app hosted online](https://castholm.github.io/zigglgen/), select your API, version,
profile and extensions and choose *Preview* or *Download* to generate your source file.

Functions, constants, types and extensions are stripped off their prefixes and have their capitalization altered
slightly but are otherwise identical to their original C/C++ definitions:

| Original C/C++        | Generated Zig       |
|-----------------------|---------------------|
| `glClearColor()`      | `clearColor()`      |
| `GL_TRIANGLES`        | `TRIANGLES`         |
| `GLfloat`             | `Float`             |
| `GL_ARB_clip_control` | `.ARB_clip_control` |

Please note that zigglgen currently only officially supports the nightly 0.11.0-dev builds of Zig. Generated code is not
guaranteed to work with earlier versions of the compiler.

### Initialization

Much like how OpenGL operates on a thread-local *current context*, generated top-level functions operate on a
thread-local *current binding* in the form of an instance of the `Binding` struct.

Before a binding can be used, it must first be initialized by calling `fn init(self: *Binding, loader: anytype) void`
while the calling thread has a current OpenGL context. This will populate the binding with OpenGL command function
pointers and supported extensions from the current context.

`loader` is duck-typed and can be either a container or an instance, so long as it satisfies the following code:

```zig
const command_name: [:0]const u8 = "glExample";
const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;
const fn_ptr: ?AnyCFnPtr = loader.GetCommandFnPtr(command_name);
_ = fn_ptr;

// If the source file was generated with extensions:
const extension_name: [:0]const u8 = "GL_EXT_example";
const supported: bool = loader.extensionSupported(extension_name);
_ = supported;
```

Once initialized, you pass the binding to `fn makeBindingCurrent(binding: ?*const Binding) void` to make it current on
the calling thread. The binding is only valid for as long as the OpenGL context that was current when `init()` was
called is current; if you change the current context or move it to a different thread you must also change/move the
current binding in the same manner.

To illustrate, initialization generally looks something like this:

```zig
// Container-level global variable:
var gl_binding: gl.Binding = undefined;

const GlBindingLoader = struct {
    const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;

    pub fn getCommandFnPtr(command_name: [:0]const u8) ?AnyCFnPtr {
        return some_library.getProcAddress(command_name);
    }

    pub fn extensionSupported(extension_name: [:0]const u8) bool {
        return some_library.extensionSupported(extension_name);
    }
};

pub fn main() void {
    // ...

    some_library.makeContextCurrent(gl_context);
    defer some_library.makeContextCurrent(null);

    gl_binding.init(GlBindingLoader);

    gl.makeBindingCurrent(&gl_binding);
    defer gl.makeBindingCurrent(null);

    // ...
}
```

`Binding` is a very large struct, so you should avoid storing instances of it on the stack. Use global variables or
allocate them on the heap instead.

### Extensions

Extension-specific functions, constants and types are made available as top-level declarations just like regular ones.
If the source file was generated with extensions, you can call `fn extensionSupported(comptime extension: Extension)
bool` to test whether an extension is supported by the current binding before attempting to use it.

## Examples

The below examples assume a source file generated with *OpenGL 3.3 (Core Profile)* and *NV_scissor_exclusive* selected:

### SDL2

Using [zsdl](https://github.com/michal-z/zig-gamedev/tree/main/libs/zsdl):

<details><summary>Click to expand/collapse</summary>

```zig
const sdl = @import("zsdl");
const gl = @import("gl.zig");

var gl_binding: gl.Binding = undefined;

const GlBindingLoader = struct {
    const c_fn_alignment = @alignOf(fn () callconv(.C) void);
    const AnyCFnPtr = *align(c_fn_alignment) const anyopaque;

    pub fn getCommandFnPtr(command_name: [:0]const u8) ?AnyCFnPtr {
        return @alignCast(c_fn_alignment, sdl.gl.getProcAddress(command_name));
    }

    pub fn extensionSupported(extension_name: [:0]const u8) bool {
        return sdl.gl.isExtensionSupported(extension_name);
    }
};

pub fn main() !void {
    try sdl.init(.{ .video = true });
    defer sdl.quit();

    try sdl.gl.setAttribute(.context_profile_mask, @enumToInt(sdl.gl.Profile.core));
    try sdl.gl.setAttribute(.context_major_version, gl.info.api_version_major);
    try sdl.gl.setAttribute(.context_minor_version, gl.info.api_version_minor);
    const gl_context_flags = sdl.gl.ContextFlags{ .forward_compatible = true };
    try sdl.gl.setAttribute(.context_flags, @bitCast(i32, gl_context_flags));
    const window = try sdl.Window.create(
        "OpenGL is a art",
        sdl.Window.pos_undefined,
        sdl.Window.pos_undefined,
        640,
        480,
        .{ .opengl = true },
    );
    defer window.destroy();

    const gl_context = try sdl.gl.createContext(window);
    defer sdl.gl.deleteContext(gl_context);

    gl_binding.init(GlBindingLoader);

    gl.makeBindingCurrent(&gl_binding);
    defer gl.makeBindingCurrent(null);

    try sdl.gl.setSwapInterval(1);

    main_loop: while (true) {
        var event: sdl.Event = undefined;
        while (sdl.pollEvent(&event)) {
            if (event.type == .quit) break :main_loop;
        }

        gl.disable(gl.SCISSOR_TEST);
        if (gl.extensionSupported(.NV_scissor_exclusive)) {
            gl.disable(gl.SCISSOR_TEST_EXCLUSIVE_NV);
            gl.clearBufferfv(gl.COLOR, 0, &[_]gl.Float{ 1, 0.8, 0.2, 1 });
            gl.enable(gl.SCISSOR_TEST_EXCLUSIVE_NV);
            gl.scissorExclusiveNV(72, 56, 8, 8);
        }
        gl.clearBufferfv(gl.COLOR, 0, &[_]gl.Float{ 1, 1, 1, 1 });
        gl.enable(gl.SCISSOR_TEST);
        const magic: u256 = 0x1FF8200446024F3A8071E321B0EDAC0A9BFA56AA4BFA26AA13F20802060401F8;
        var i: gl.Int = 0;
        while (i < 256) : (i += 1) {
            if (magic >> @intCast(u8, i) & 1 != 0) {
                gl.scissor(@rem(i, 16) * 8 + 8, @divTrunc(i, 16) * 8 + 8, 8, 8);
                gl.clearBufferfv(gl.COLOR, 0, &[_]gl.Float{ 0, 0, 0, 1 });
            }
        }

        sdl.gl.swapWindow(window);
    }
}
```

</details>

### GLFW

Using [mach/glfw](https://github.com/hexops/mach-glfw):

<details><summary>Click to expand/collapse</summary>

```zig
const glfw = @import("glfw");
const gl = @import("gl.zig");

var gl_binding: gl.Binding = undefined;

const GlBindingLoader = struct {
    pub fn getCommandFnPtr(command_name: [:0]const u8) ?glfw.GLProc {
        return glfw.getProcAddress(command_name);
    }

    pub fn extensionSupported(extension_name: [:0]const u8) bool {
        return glfw.extensionSupported(extension_name);
    }
};

pub fn main() !void {
    if (!glfw.init(.{})) return error.GlfwInitFailed;
    defer glfw.terminate();

    const window = glfw.Window.create(640, 480, "OpenGL is a art", null, null, .{
        .context_version_major = gl.info.api_version_major,
        .context_version_minor = gl.info.api_version_minor,
        .opengl_profile = .opengl_core_profile,
        .opengl_forward_compat = true,
    }) orelse return error.GlfwInitFailed;
    defer window.destroy();

    glfw.makeContextCurrent(window);
    defer glfw.makeContextCurrent(null);

    gl_binding.init(GlBindingLoader);

    gl.makeBindingCurrent(&gl_binding);
    defer gl.makeBindingCurrent(null);

    glfw.swapInterval(1);

    main_loop: while (true) {
        glfw.pollEvents();
        if (window.shouldClose()) break :main_loop;

        gl.disable(gl.SCISSOR_TEST);
        if (gl.extensionSupported(.NV_scissor_exclusive)) {
            gl.disable(gl.SCISSOR_TEST_EXCLUSIVE_NV);
            gl.clearBufferfv(gl.COLOR, 0, &[_]gl.Float{ 1, 0.8, 0.2, 1 });
            gl.enable(gl.SCISSOR_TEST_EXCLUSIVE_NV);
            gl.scissorExclusiveNV(72, 56, 8, 8);
        }
        gl.clearBufferfv(gl.COLOR, 0, &[_]gl.Float{ 1, 1, 1, 1 });
        gl.enable(gl.SCISSOR_TEST);
        const magic: u256 = 0x1FF8200446024F3A8071E321B0EDAC0A9BFA56AA4BFA26AA13F20802060401F8;
        var i: gl.Int = 0;
        while (i < 256) : (i += 1) {
            if (magic >> @intCast(u8, i) & 1 != 0) {
                gl.scissor(@rem(i, 16) * 8 + 8, @divTrunc(i, 16) * 8 + 8, 8, 8);
                gl.clearBufferfv(gl.COLOR, 0, &[_]gl.Float{ 0, 0, 0, 1 });
            }
        }

        window.swapBuffers();
    }
}
```

</details>

## FAQ

### Why is initialization so awkward? Why so much thread-local state?

Initialization and state management is awkward because OpenGL is awkward and we want zigglgen's output to be able to be
used in portable multi-threaded, multi-context OpenGL programs.

On paper, function pointers loaded when one OpenGL context was current are not guaranteed to be valid when a different
context is current. In practice, most platforms and OpenGL implementations will return context-independent pointers that
can be safely shared between multiple contexts, but we can't assume that this is always the case if we want to write
portable code.

### Why did calling a function belonging to a supported extension result in a null pointer dereference?

Some OpenGL extensions add features that are only conditionally supported under certain OpenGL versions/profiles or when
certain other extensions are also supported. For example, the command *VertexWeighthNV* added by the extension
*NV_half_float* is only supported when the extension *EXT_vertex_weighting* is also supported.

This means that we can't assume that all command function pointers associated with a supported extension are non-null
after loading is complete. The definitions that zigglgen derives its output from also do not encode these interactions
in a consistent and structured manner, so we can't generate code that validates the non-nullness of conditional command
function pointers if their conditions are met (because we don't know what those conditions are).

If your code uses OpenGL extensions it is your responsibility to read the extension specifications and learn under which
conditions added features are supported.

### How do I run zigglgen locally?

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
