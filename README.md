# zigglgen

Zig OpenGL binding generator that [runs in your browser](https://castholm.github.io/zigglgen/)

## Usage

Simply visit [the generator web app hosted online](https://castholm.github.io/zigglgen/), select your API, version,
profile and extensions and choose *Preview* or *Download* to generate a Zig source file containing your binding.

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

Before the binding can be used, it must be initialized by calling `fn init(loader: anytype) void` while the calling
thread has a current OpenGL context.

`loader` is duck-typed and can be either a container or an instance, so long as it satisfies the following code:

```zig
const command_name: [:0]const u8 = "glExample";
const AnyCommandFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;
const fn_ptr: ?AnyCommandFnPtr = loader.GetCommandFnPtr(command_name);
_ = fn_ptr;

// If the binding was generated with extensions:
const extension_name: [:0]const u8 = "GL_EXT_example";
const supported: bool = loader.extensionSupported(extension_name);
_ = supported;
```

In other words, you usually call `init()` like this:

```zig
const Loader = struct {
    const AnyCommandFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;

    pub fn getCommandFnPtr(command_name: [:0]const u8) ?AnyCommandFnPtr {
        return some_library.getProcAddress(command_name);
    }

    pub fn extensionSupported(extension_name: [:0]const u8) bool {
        return some_library.isExtensionSupported(extension_name);
    }
}

gl.init(Loader);
```

No references to `loader` are retained by the binding after `init()` returns.

### Extensions

Extension-specific functions, constants and types are made available as top-level declarations like any other. If the
binding was generated with extensions, you can call `fn extensionSupported(comptime extension: Extension) bool` to test
whether an extension is supported by the current OpenGL context before attempting to use it.

## Examples

The below examples use a binding generated with *OpenGL 3.3 (Core Profile)* and *NV_scissor_exclusive* selected:

### SDL2

Using [zsdl](https://github.com/michal-z/zig-gamedev/tree/main/libs/zsdl):

<details><summary>Click to expand/collapse</summary>

```zig
const sdl = @import("zsdl");
const gl = @import("gl.zig");

pub fn main() !void {
    try sdl.init(.{ .video = true });
    defer sdl.quit();

    try sdl.gl.setAttribute(.context_profile_mask, @enumToInt(sdl.gl.Profile.core));
    try sdl.gl.setAttribute(.context_major_version, gl.info.api_version_major);
    try sdl.gl.setAttribute(.context_minor_version, gl.info.api_version_minor);
    const context_flags = sdl.gl.ContextFlags{ .forward_compatible = true };
    try sdl.gl.setAttribute(.context_flags, @bitCast(i32, context_flags));
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

    try sdl.gl.setSwapInterval(1);

    gl.init(struct {
        const alignment = @alignOf(fn () callconv(.C) void);
        const AnyCommandFnPtr = *align(alignment) const anyopaque;
        pub fn getCommandFnPtr(command_name: [:0]const u8) ?AnyCommandFnPtr {
            return @alignCast(alignment, sdl.gl.getProcAddress(command_name));
        }
        pub fn extensionSupported(extension_name: [:0]const u8) bool {
            return sdl.gl.isExtensionSupported(extension_name);
        }
    });

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

    glfw.swapInterval(1);

    gl.init(struct {
        pub fn getCommandFnPtr(command_name: [:0]const u8) ?glfw.GLProc {
            return glfw.getProcAddress(command_name);
        }
        pub fn extensionSupported(extension_name: [:0]const u8) bool {
            return glfw.extensionSupported(extension_name);
        }
    });

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

### Do bindings generated by zigglgen support multiple OpenGL contexts?

Yes, but it's complicated.

On paper, function pointers loaded when one OpenGL context was current are not guaranteed to be valid when a different
context is current. When you call `init()`, loaded command function pointers are copied to a shared global instance of
the `Features` struct. All top-level functions forward their calls to this shared instance, which makes it unsafe to
call top-level functions when the current context is different from the one that was current when `init()` was called.

In practice, most platforms and OpenGL implementations will return context-independent pointers that can be safely
shared between multiple contexts, but you should not depend on this behavior unless you are absolutely certain that this
will always be the case for all of your target platforms.

To work with multiple contexts in a way that is guaranteed to be safe, you can initialize independent instances of the
`Features` struct and call their function pointers directly:

```zig
const gl = @import("gl.zig");
var f: gl.Features = undefined;

// After an OpenGL context has been created:
f.init(loader);
f.glClearBufferfv(gl.COLOR, 0, &[_]gl.Float{ 1, 1, 1, 1 });
if (f.GL_ARB_clip_control) {
    f.glClipControl.?(gl.UPPER_LEFT, gl.ZERO_TO_ONE);
}
```

Do note that the `Features` struct is enormous, so storing instances of it on the stack will likely lead to a stack
overflow.

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
