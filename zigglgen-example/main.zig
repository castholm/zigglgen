const std = @import("std");
const glfw = @import("glfw");
const gl = @import("gl");

var gl_procs: gl.ProcTable = undefined;

pub fn main() !void {
    if (!glfw.init(.{})) return error.InitFailed;
    defer glfw.terminate();

    const window = glfw.Window.create(640, 480, "OpenGL is a art", null, null, .{
        .context_version_major = gl.info.version_major,
        .context_version_minor = gl.info.version_minor,
        .opengl_profile = .opengl_core_profile,
        .opengl_forward_compat = true,
    }) orelse return error.InitFailed;
    defer window.destroy();

    glfw.makeContextCurrent(window);
    defer glfw.makeContextCurrent(null);

    if (!gl_procs.init(glfw.getProcAddress)) return error.InitFailed;

    gl.makeProcTableCurrent(&gl_procs);
    defer gl.makeProcTableCurrent(null);

    glfw.swapInterval(1);

    main_loop: while (true) {
        glfw.pollEvents();
        if (window.shouldClose()) break :main_loop;

        gl.Disable(gl.SCISSOR_TEST);
        if (gl.extensionSupported(.NV_scissor_exclusive)) {
            gl.Disable(gl.SCISSOR_TEST_EXCLUSIVE_NV);
            gl.ClearColor(1, 0.8, 0.2, 1);
            gl.Clear(gl.COLOR_BUFFER_BIT);
            gl.Enable(gl.SCISSOR_TEST_EXCLUSIVE_NV);
            gl.ScissorExclusiveNV(72, 56, 8, 8);
        }
        gl.ClearColor(1, 1, 1, 1);
        gl.Clear(gl.COLOR_BUFFER_BIT);
        gl.Enable(gl.SCISSOR_TEST);
        const magic: u256 = 0x1FF8200446024F3A8071E321B0EDAC0A9BFA56AA4BFA26AA13F20802060401F8;
        var i: gl.int = 0;
        while (i < 256) : (i += 1) {
            if (magic >> @intCast(i) & 1 != 0) {
                gl.Scissor(@rem(i, 16) * 8 + 8, @divTrunc(i, 16) * 8 + 8, 8, 8);
                gl.ClearColor(0, 0, 0, 1);
                gl.Clear(gl.COLOR_BUFFER_BIT);
            }
        }

        window.swapBuffers();
    }
}
