const std = @import("std");
const glfw = @import("glfw");
const gl = @import("gl");

var gl_procs: gl.ProcTable = undefined;

pub fn main() !void {
    if (!glfw.init(.{})) return error.InitFailed;
    defer glfw.terminate();

    const window = glfw.Window.create(640, 480, "Triangle!", null, null, .{
        .context_version_major = gl.info.version_major,
        .context_version_minor = gl.info.version_minor,
        // This example supports both OpenGL (Core profile) and OpenGL ES.
        // (Toggled by building with '-Dgles')
        .opengl_profile = switch (gl.info.api) {
            .gl => .opengl_core_profile,
            .gles => .opengl_any_profile,
            else => comptime unreachable,
        },
        // The forward compat hint should only be true when using regular OpenGL.
        .opengl_forward_compat = gl.info.api == .gl,
    }) orelse return error.InitFailed;
    defer window.destroy();

    glfw.makeContextCurrent(window);
    defer glfw.makeContextCurrent(null);

    if (!gl_procs.init(glfw.getProcAddress)) return error.InitFailed;

    gl.makeProcTableCurrent(&gl_procs);
    defer gl.makeProcTableCurrent(null);

    const shader_source_preamble = switch (gl.info.api) {
        .gl => (
            \\#version 410 core
            \\
        ),
        .gles => (
            \\#version 300 es
            \\precision highp float;
            \\
        ),
        else => comptime unreachable,
    };
    const vertex_shader_source =
        \\in vec4 a_Position;
        \\in vec4 a_Color;
        \\out vec4 v_Color;
        \\
        \\void main() {
        \\    gl_Position = a_Position;
        \\    v_Color = a_Color;
        \\}
        \\
    ;
    const fragment_shader_source =
        \\in vec4 v_Color;
        \\out vec4 f_Color;
        \\
        \\void main() {
        \\    f_Color = v_Color;
        \\}
        \\
    ;

    // For the sake of conciseness, this example doesn't check for shader compilation/linking
    // errors. A more robust program would use 'GetShaderiv'/'GetProgramiv' to check for errors.
    const program = create_program: {
        const vertex_shader = gl.CreateShader(gl.VERTEX_SHADER);
        defer gl.DeleteShader(vertex_shader);

        gl.ShaderSource(
            vertex_shader,
            2,
            &[2][*]const u8{ shader_source_preamble, vertex_shader_source },
            &[2]c_int{ @intCast(shader_source_preamble.len), @intCast(vertex_shader_source.len) },
        );
        gl.CompileShader(vertex_shader);

        const fragment_shader = gl.CreateShader(gl.FRAGMENT_SHADER);
        defer gl.DeleteShader(fragment_shader);

        gl.ShaderSource(
            fragment_shader,
            2,
            &[2][*]const u8{ shader_source_preamble, fragment_shader_source },
            &[2]c_int{ @intCast(shader_source_preamble.len), @intCast(fragment_shader_source.len) },
        );
        gl.CompileShader(fragment_shader);

        const program = gl.CreateProgram();

        gl.AttachShader(program, vertex_shader);
        gl.AttachShader(program, fragment_shader);
        gl.LinkProgram(program);

        break :create_program program;
    };
    defer gl.DeleteProgram(program);

    gl.UseProgram(program);
    defer gl.UseProgram(0);

    var vao: c_uint = undefined;
    gl.GenVertexArrays(1, @ptrCast(&vao));
    defer gl.DeleteVertexArrays(1, @ptrCast(&vao));

    gl.BindVertexArray(vao);
    defer gl.BindVertexArray(0);

    var vbo: c_uint = undefined;
    gl.GenBuffers(1, @ptrCast(&vbo));
    defer gl.DeleteBuffers(1, @ptrCast(&vbo));

    gl.BindBuffer(gl.ARRAY_BUFFER, vbo);
    defer gl.BindBuffer(gl.ARRAY_BUFFER, 0);

    const Vertex = extern struct { position: [2]f32, color: [3]f32 };
    // zig fmt: off
    const vertices = [_]Vertex{
        .{ .position = .{ -0.866,  0.75 }, .color = .{ 0, 1, 1 } },
        .{ .position = .{  0    , -0.75 }, .color = .{ 1, 1, 0 } },
        .{ .position = .{  0.866,  0.75 }, .color = .{ 1, 0, 1 } },
    };
    // zig fmt: on

    gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, gl.STATIC_DRAW);

    const position_attrib: c_uint = @intCast(gl.GetAttribLocation(program, "a_Position"));
    gl.EnableVertexAttribArray(position_attrib);
    gl.VertexAttribPointer(
        position_attrib,
        @typeInfo(@TypeOf(@as(Vertex, undefined).position)).Array.len,
        gl.FLOAT,
        gl.FALSE,
        @sizeOf(Vertex),
        @offsetOf(Vertex, "position"),
    );

    const color_attrib: c_uint = @intCast(gl.GetAttribLocation(program, "a_Color"));
    gl.EnableVertexAttribArray(color_attrib);
    gl.VertexAttribPointer(
        color_attrib,
        @typeInfo(@TypeOf(@as(Vertex, undefined).color)).Array.len,
        gl.FLOAT,
        gl.FALSE,
        @sizeOf(Vertex),
        @offsetOf(Vertex, "color"),
    );

    main_loop: while (true) {
        glfw.waitEvents();
        if (window.shouldClose()) break :main_loop;

        // Update the viewport to reflect any changes to the window's size.
        const fb_size = window.getFramebufferSize();
        gl.Viewport(0, 0, @intCast(fb_size.width), @intCast(fb_size.height));

        // Clear the window.
        gl.ClearBufferfv(gl.COLOR, 0, &[4]f32{ 1, 1, 1, 1 });

        // Draw the vertices.
        gl.DrawArrays(gl.TRIANGLES, 0, vertices.len);

        // Perform some wizardry that prints a nice little message in the center :)
        gl.Enable(gl.SCISSOR_TEST);
        const magic: u154 = 0x3bb924a43ddc000170220543b8006ef4c68ad77;
        const left = @divTrunc(@as(gl.int, @intCast(fb_size.width)) - 11 * 8, 2);
        const bottom = @divTrunc((@as(gl.int, @intCast(fb_size.height)) - 14 * 8) * 2, 3);
        var i: gl.int = 0;
        while (i < 154) : (i += 1) {
            if (magic >> @intCast(i) & 1 != 0) {
                gl.Scissor(left + @rem(i, 11) * 8, bottom + @divTrunc(i, 11) * 8, 8, 8);
                gl.ClearBufferfv(gl.COLOR, 0, &[4]f32{ 0, 0, 0, 1 });
            }
        }
        gl.Disable(gl.SCISSOR_TEST);

        window.swapBuffers();
    }
}
