const std = @import("std");
const gl = @import("gl");
const zglfw = @import("zglfw");

// Need to patch the zglfw.getProcAddress function
// see: https://github.com/zig-gamedev/zig-gamedev/pull/646
fn getProcAddress(prefixed_name: [*:0]const u8) ?gl.PROC {
    return @alignCast(zglfw.getProcAddress(std.mem.span(prefixed_name)));
}

pub fn main() !void {
    var procs: gl.ProcTable = undefined;

    try zglfw.init();
    defer zglfw.terminate();

    const gl_major = 4;
    const gl_minor = 0;
    zglfw.windowHintTyped(.context_version_major, gl_major);
    zglfw.windowHintTyped(.context_version_minor, gl_minor);
    zglfw.windowHintTyped(.opengl_profile, .opengl_core_profile);

    const window = try zglfw.Window.create(800, 800, "zigglgen + zglfw", null);
    defer window.destroy();

    zglfw.makeContextCurrent(window);

    if (!procs.init(getProcAddress)) return error.InitFailed;
    gl.makeProcTableCurrent(&procs);
    defer gl.makeProcTableCurrent(null);

    while (!window.shouldClose()) {
        gl.ClearBufferfv(gl.COLOR, 0, &[4]f32{ 0.9, 0.2, 0.7, 1.0 });

        zglfw.pollEvents();
        window.swapBuffers();
    }
}
