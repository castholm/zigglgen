# zigglgen

Zig OpenGL binding generator that [runs in your browser](https://castholm.github.io/zigglgen/)

## Usage

Simply visit [the generator web app hosted online](https://castholm.github.io/zigglgen/), select your API, version,
profile and extensions and choose *Preview* or *Download* to generate your source file.

Functions, constants, types and extensions are stripped off their prefixes and have their capitalization changed
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

Much like how OpenGL operates on a thread-local *current context*, zigglgen-generated top-level functions operate on a
thread-local *current dispatch table* in the form of a pointer to an instance of the `DispatchTable` struct.

Before a dispatch table can be made current, it must first be initialized by calling `fn init(self: *DispatchTable,
loader: anytype) bool` while the calling thread has a current OpenGL context. If successful, this will populate the
dispatch table with OpenGL command function pointers and supported extensions from the current context.

`loader` is duck-typed and can be either a container or an instance, so long as it satisfies the following code:

```zig
const prefixed_command_name: [:0]const u8 = "glExample";
const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;
const fn_ptr_opt: ?AnyCFnPtr = loader.GetCommandFnPtr(prefixed_command_name);
_ = fn_ptr_opt;

// If the binding was generated with extensions:
const prefixed_extension_name: [:0]const u8 = "GL_EXT_example";
const supported: bool = loader.extensionSupported(prefixed_extension_name);
_ = supported;
```

Once initialized, you pass the dispatch table to `fn makeDispatchTableCurrent(dispatch_table: ?*const DispatchTable)
void` to make it current on the calling thread. The dispatch table is only valid for as long as the OpenGL context that
was current when `init()` was called remains current; if you change the current context or move it to a different thread
you must also change/move the current dispatch table in the same manner.

To illustrate, initialization usually looks something like this:

```zig
var gl_dispatch_table: gl.DispatchTable = undefined; // Container-level global variable.

const GlDispatchTableLoader = struct {
    const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;

    pub fn getCommandFnPtr(prefixed_command_name: [:0]const u8) ?AnyCFnPtr {
        return some_library.getProcAddress(prefixed_command_name);
    }

    pub fn extensionSupported(prefixed_extension_name: [:0]const u8) bool {
        return some_library.extensionSupported(prefixed_extension_name);
    }
};

pub fn main() !void {
    // ...

    some_library.makeContextCurrent(gl_context);
    defer some_library.makeContextCurrent(null);

    if (!gl_dispatch_table.init(GlDispatchTableLoader)) return error.GlInitFailed;

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
to test whether an extension is currently supported before attempting to use it.

### Intercepting Command Invocations

New in version 0.4 is the ability to intercept OpenGL command invocations. This can be useful for things like debugging,
logging, modifying arguments or automatically checking for OpenGL errors.

To enable interception of command invocations, declare a public container named `gl_options` in your root source file
and then declare a public function named `intercept()` with the signature `fn (dispatch_table: *const gl.DispatchTable,
comptime prefixed_command_name: [:0]const u8, args: anytype) gl.DispatchTable.ReturnType(prefixed_command_name)` in that
container.

Note that `intercept()` is not a mere callback but replaces all calls to all underlying command functions entirely, so
you still need to return a value. To help with invoking the original command from your interception code, the function
`fn invoke(self: *const DispatchTable, comptime prefixed_command_name: [:0]const u8, args: anytype)
ReturnType(prefixed_command_name)` is provided, which functions similar to the `@call()` builtin.

```zig
pub const gl_options = struct {
    pub fn intercept(
        dispatch_table: *const gl.DispatchTable,
        comptime prefixed_command_name: [:0]const u8,
        args: anytype,
    ) gl.DispatchTable.ReturnType(prefixed_command_name) {
        // Check for and log OpenGL errors after invoking commands:
        defer if (comptime !std.mem.eql(u8, prefixed_command_name, "glGetError")) {
            while (blk: {
                const gl_error = dispatch_table.invoke("glGetError", .{});
                break :blk if (gl_error != gl.NO_ERROR) gl_error else null;
            }) |gl_error| {
                std.debug.print("gl error: {s} (prefixed_command_name: {s}, args: {any})\n", .{
                    switch (gl_error) {
                        gl.INVALID_ENUM => "INVALID_ENUM",
                        // ...Omitted for brevity...
                        else => "(unknown error)",
                    },
                    prefixed_command_name,
                    args,
                });
                std.debug.dumpCurrentStackTrace(@returnAddress());
            }
        };

        // Override calls to 'clearColor()' with a magenta color (preserving the alpha value):
        if (comptime std.mem.eql(u8, prefixed_command_name, "glClearColor")) {
            return dispatch_table.invoke(prefixed_command_name, .{ 1, 0, 1, args.@"3" });
        }

        return dispatch_table.invoke(prefixed_command_name, args);
    }
};
```

## Examples

The below examples assume a binding generated with *OpenGL 3.3 (Core Profile)* and *NV_scissor_exclusive* selected:

### SDL2

Using [zsdl](https://github.com/michal-z/zig-gamedev/tree/main/libs/zsdl):

<details><summary>Click to expand/collapse</summary>

```zig
const sdl = @import("zsdl");
const gl = @import("gl.zig");

var gl_dispatch_table: gl.DispatchTable = undefined;

const GlDispatchTableLoader = struct {
    const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;

    pub fn getCommandFnPtr(prefixed_command_name: [:0]const u8) ?AnyCFnPtr {
        return @alignCast(sdl.gl.getProcAddress(prefixed_command_name));
    }

    pub fn extensionSupported(prefixed_extension_name: [:0]const u8) bool {
        return sdl.gl.isExtensionSupported(prefixed_extension_name);
    }
};

pub fn main() !void {
    try sdl.init(.{ .video = true });
    defer sdl.quit();

    try sdl.gl.setAttribute(.context_profile_mask, @intFromEnum(sdl.gl.Profile.core));
    try sdl.gl.setAttribute(.context_major_version, gl.about.api_version_major);
    try sdl.gl.setAttribute(.context_minor_version, gl.about.api_version_minor);
    try sdl.gl.setAttribute(.context_flags, @bitCast(sdl.gl.ContextFlags{ .forward_compatible = true }));
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

    if (!gl_dispatch_table.init(GlDispatchTableLoader)) return error.GlInitFailed;

    gl.makeDispatchTableCurrent(&gl_dispatch_table);
    defer gl.makeDispatchTableCurrent(null);

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
            if (magic >> @intCast(i) & 1 != 0) {
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

var gl_dispatch_table: gl.DispatchTable = undefined;

const GlDispatchTableLoader = struct {
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
        .context_version_major = gl.about.api_version_major,
        .context_version_minor = gl.about.api_version_minor,
        .opengl_profile = .opengl_core_profile,
        .opengl_forward_compat = true,
    }) orelse return error.GlfwInitFailed;
    defer window.destroy();

    glfw.makeContextCurrent(window);
    defer glfw.makeContextCurrent(null);

    if (!gl_dispatch_table.init(GlDispatchTableLoader)) return error.GlInitFailed;

    gl.makeDispatchTableCurrent(&gl_dispatch_table);
    defer gl.makeDispatchTableCurrent(null);

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
            if (magic >> @intCast(i) & 1 != 0) {
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

Initialization and state management is a bit awkward because OpenGL is also a bit awkward and we want zigglgen's output
to be able to be used in portable multi-threaded multi-context OpenGL programs.

Thread-local state is necessary due to how loading of command function pointers is specified in the OpenGL spec.
According to the spec, function pointers loaded when one OpenGL context is current are not guaranteed to still be valid
when a different context becomes current. This means that we can't just load pointers into a globally shared dispatch
table. Because current OpenGL contexts are thread-local, it makes sense to handle dispatch tables in a similar manner.

(It should be noted, however, that in practice, most platforms and OpenGL implementations will return
context-independent pointers that can be safely shared between multiple contexts, though we can't assume that this is
always the case if our goal is to write portable code.)

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
