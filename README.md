# zigglgen

The only Zig OpenGL binding generator you need.

## Installation and usage

zigglgen officially supports the following versions of the Zig compiler:

- `0.12.0-dev.3180+83e578a18`/[`2024.3.0-mach`](https://machengine.org/about/nominated-zig/#202410-mach)
- `0.12.0`
- master (last tested with `0.13.0-dev.230+50a141945`)

Older or more recent versions of the compiler are not guaranteed to be compatible.

1\. Run `zig fetch` to add the zigglgen package to your `build.zig.zon` manifest:

```sh
zig fetch https://github.com/castholm/zigglgen/releases/download/v0.2.3/zigglgen.tar.gz --save
```

2\. Generate a set of OpenGL bindings in your `build.zig` build script:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(...);

    // Choose the OpenGL API, version, profile and extensions you want to generate bindings for.
    const gl_bindings = @import("zigglgen").generateBindingsModule(b, .{
        .api = .gl,
        .version = .@"4.1",
        .profile = .core,
        .extensions = &.{ .ARB_clip_control, .NV_scissor_exclusive },
    });

    // Import the generated module.
    exe.root_module.addImport("gl", gl_bindings);

    b.installArtifact(exe);
}
```

3\. Initialize OpenGL and start issuing commands:

```zig
const windowing = @import(...);
const gl = @import("gl");

// Procedure table that will hold OpenGL functions loaded at runtime.
var procs: gl.ProcTable = undefined;

pub fn main() !void {
    // Create an OpenGL context using a windowing system of your choice.
    const context = windowing.createContext(...);
    defer context.destroy();

    // Make the OpenGL context current on the calling thread.
    windowing.makeContextCurrent(context);
    defer windowing.makeContextCurrent(null);

    // Initialize the procedure table.
    if (!procs.init(windowing.getProcAddress)) return error.InitFailed;

    // Make the procedure table current on the calling thread.
    gl.makeProcTableCurrent(&procs);
    defer gl.makeProcTableCurrent(null);

    // Issue OpenGL commands to your heart's content!
    const alpha: gl.float = 1;
    gl.ClearColor(1, 1, 1, alpha);
    gl.Clear(gl.COLOR_BUFFER_BIT);
 }
```

See [`zigglgen-example/`](zigglgen-example/) for a complete example project that creates a window using
[mach-glfw](https://machengine.org/pkg/mach-glfw/) and draws a triangle to it.

## API

If you're curious what a generated set of bindings looks like, take a look at
[`zigglgen-example/gles3.zig`](zigglgen-example/gles3.zig).

### OpenGL symbols

zigglgen generates declarations for OpenGL functions, constants, types and extensions using the original names as
defined in the various OpenGL specifications (as opposed to the prefixed names used in C).

|           | C                     | Zig                |
|-----------|:----------------------|:-------------------|
| Command   | `glClearColor`        | `ClearColor`       |
| Constant  | `GL_TRIANGLES`        | `TRIANGLES`        |
| Type      | `GLfloat`             | `float`            |
| Extension | `GL_ARB_clip_control` | `ARB_clip_control` |

### `info`

```zig
pub const info = struct {};
```

Contains information about the generated set of OpenGL bindings, such as the OpenGL API, version and profile the
bindings were generated for.

### `ProcTable`

```zig
pub const ProcTable = struct {};
```

Holds pointers to OpenGL functions loaded at runtime.

This struct is very large, so you should avoid storing instances of it on the stack. Use global variables or allocate
them on the heap instead.

### `ProcTable.init`

```zig
pub fn init(procs: *ProcTable, loader: anytype) bool {}
```

Initializes the specified procedure table and returns `true` if successful, `false` otherwise.

A procedure table must be successfully initialized before passing it to `makeProcTableCurrent` or accessing any of
its fields.

`loader` is duck-typed. Given the prefixed name of an OpenGL command (e.g. `"glClear"`), it should return a pointer to
the corresponding function. It should be able to be used in one of the following two ways:

- `@as(?PROC, loader(@as([*:0]const u8, prefixed_name)))`
- `@as(?PROC, loader.getProcAddress(@as([*:0]const u8, prefixed_name)))`

If your windowing system has a "get procedure address" function, it is usually enough to simply pass that function as
the `loader` argument.

No references to `loader` are retained after this function returns.

There is no corresponding `deinit` function.

### `makeProcTableCurrent`

```zig
pub fn makeProcTableCurrent(procs: ?*const ProcTable) void {}
```

Makes the specified procedure table current on the calling thread.

A valid procedure table must be made current on a thread before issuing any OpenGL commands from that same thread.

### `getCurrentProcTable`

```zig
pub fn getCurrentProcTable() ?*const ProcTable {}
```

Returns the procedure table that is current on the calling thread.

### `extensionSupported`

(Only generated if at least one extension is specified.)

```zig
pub fn extensionSupported(comptime extension: Extension) bool {}
```

Returns `true` if the specified OpenGL extension is supported by the procedure table that is current on the calling
thread, `false` otherwise.

## FAQ

### Which OpenGL APIs are supported?

Any APIs, versions, profiles and extensions included in Khronos's [OpenGL XML API
Registry](https://github.com/KhronosGroup/OpenGL-Registry/tree/main/xml) are supported. These include:

- OpenGL 1.0 through 3.1
- OpenGL 3.2 through 4.6 (Compatibility/Core profile)
- OpenGL ES 1.1 (Common/Common-Lite profile)
- OpenGL ES 2.0 through 3.2
- OpenGL SC 2.0

The [`zigglgen/updateApiRegistry.ps1`](zigglgen/updateApiRegistry.ps1) PowerShell script is used to fetch the API
registry and convert it to a set of Zig source files that are committed to revision control and used by the generator.

### Why is a thread-local procedure table required?

Per the OpenGL spec, OpenGL function pointers loaded when one OpenGL context is current are not guaranteed to remain
valid when a different context becomes current. This means that it would be incorrect to load a single set of function
pointers to global memory just once at application startup and then have them be shared by all current and future
OpenGL contexts.

In order to support portable multi-threaded multi-context OpenGL applications, it must be possible to load multiple sets
of function pointers. Because OpenGL contexts are already thread-local, it makes a lot of sense to handle function
pointers in a similar manner.

### Why aren't OpenGL constants represented as Zig enums?

The short answer is that it's simply not possible to represent groups of OpenGL constants as Zig enums in a
satisfying manner:

- The API registry currently specifies some of these groups, but far from all of them, and the groups are not guaranteed
  to be complete. Groups can be extended by extensions, so Zig enums would need to be defined as non-exhaustive, and
  using constants not specified as part of a group would require casting.
- Some commands like *GetIntegerv* that can return constants will return them as plain integers. Comparing the returned
  values against Zig enum fields would require casting.
- Some constants in the same group are aliases for the same value, which makes them impossible to represent as
  Zig enums.

### Why did calling a supported extension function result in a null pointer dereference?

Certain OpenGL extension add features that are only conditionally available under certain OpenGL versions/profiles or
when certain other extensions are also supported; for example, the *VertexWeighthNV* command from the *NV_half_float*
extension is only available when the *EXT_vertex_weighting* extension is also supported. Unfortunately, the API registry
does not specify these interactions in a consistent manner, so it's not possible for zigglgen to generate code that
ensures that calls to supported extension functions are always safe.

If you use OpenGL extensions it is your responsibility to read the extension specifications carefully and understand
under which conditions their features are available.

## Contributing

If you have any issues or suggestions, please open an issue or a pull request.

### Help us define overrides for function parameters and return types!

Due to the nature of the API Registry being designed for C, zigglgen currently generates most pointers types as `[*c]`
pointers, which is less than ideal. A long-term goal for zigglgen is for every single pointer type to be correctly
annotated. There are approximately 3300 commands defined in the API registry and if we work together, we can achieve
that goal sooner. Even fixing up just a few commands would mean a lot!

Overriding parameters/return types is very easy; all you need to do is add additional entries to the
`paramOverride`/`returnTypeOverride` functions in [`zigglgen/generator.zig`](zigglgen/generator.zig), then open a pull
request with your changes (bonus points if you also reference relevant OpenGL references page or specifications in the
description of your pull request).

## License

zigglgen is licensed under the [MIT License](LICENSE.md).

See [`zigglgen/THIRD-PARTY-NOTICES.txt`](zigglgen/THIRD-PARTY-NOTICES.txt) for third-party license notices.
