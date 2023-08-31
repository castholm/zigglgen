const std = @import("std");
const expect = std.testing.expect;
const gl = @import("gl");

const has_extensions = @hasDecl(gl, "Extension");
const uses_c_naming_convention = @hasDecl(gl, "GLenum");

comptime {
    if (std.mem.startsWith(u8, gl.about.api_name, "OpenGL ES")) {
        std.debug.assert(!has_extensions and !uses_c_naming_convention);
    } else {
        switch (gl.about.api_version_major) {
            4 => std.debug.assert(has_extensions and !uses_c_naming_convention),
            3 => std.debug.assert(has_extensions and uses_c_naming_convention),
            2 => std.debug.assert(has_extensions and !uses_c_naming_convention),
            1 => std.debug.assert(has_extensions and uses_c_naming_convention),
            else => unreachable,
        }
    }
}

var gl_dispatch_table: gl.DispatchTable = undefined;

pub fn main() !void {
    @setEvalBranchQuota(1_000_000);

    try expect(gl.getCurrentDispatchTable() == null);

    // function
    try expect(!gl_dispatch_table.init(getProcAddressNull));
    // function pointer
    try expect(!gl_dispatch_table.init(&getProcAddressNull));
    // type
    try expect(!gl_dispatch_table.init(struct {
        pub const getProcAddress = getProcAddressNull;
    }));
    // mutable pointer to instance
    var loader = struct {
        invoked: bool = false,
        pub fn getProcAddress(self: *@This(), _: [*:0]const u8) ?gl.DispatchTable.Proc {
            self.invoked = true;
            return null;
        }
    }{};
    try expect(!gl_dispatch_table.init(&loader));
    try expect(loader.invoked);

    try expect(gl_dispatch_table.init(getProcAddress));

    try expect(get_integerv_invoked == (has_extensions and gl.about.api_version_major >= 3));
    try expect(get_stringi_invoked == (has_extensions and gl.about.api_version_major >= 3));
    try expect(get_string_invoked == (has_extensions and gl.about.api_version_major < 3));

    gl.makeDispatchTableCurrent(&gl_dispatch_table);
    try expect(gl.getCurrentDispatchTable() == &gl_dispatch_table);

    if (has_extensions) {
        inline for (comptime std.enums.values(gl.Extension)) |extension| {
            const expected = if (uses_c_naming_convention)
                extension == .GL_ARB_clip_control or extension == .GL_KHR_debug
            else
                extension == .ARB_clip_control or extension == .KHR_debug;
            try expect(gl.extensionSupported(extension) == expected);
        }
    }

    if (uses_c_naming_convention) {
        gl.glClearColor(0.0625, 0.125, 0.25, 0.5);
    } else {
        gl.clearColor(0.0625, 0.125, 0.25, 0.5);
    }
    try expect(clear_color[0] == 1); // from gl_issueCommand override
    try expect(clear_color[1] == 0.125);
    try expect(clear_color[2] == 0.25);
    try expect(clear_color[3] == 0.5);

    if (uses_c_naming_convention) {
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    } else {
        gl.clear(gl.COLOR_BUFFER_BIT);
    }
    try expect(clear_mask == GL_COLOR_BUFFER_BIT);

    gl.makeDispatchTableCurrent(null);
    try expect(gl.getCurrentDispatchTable() == null);
}

fn getProcAddressNull(_: [*:0]const u8) ?gl.DispatchTable.Proc {
    return null;
}

fn getProcAddress(proc_name: [*:0]const u8) ?gl.DispatchTable.Proc {
    if (std.mem.orderZ(u8, "glGetIntegerv", proc_name) == .eq) {
        return &glGetIntegerv;
    }
    if (std.mem.orderZ(u8, "glGetStringi", proc_name) == .eq) {
        return &glGetStringi;
    }
    if (std.mem.orderZ(u8, "glGetString", proc_name) == .eq) {
        return &glGetString;
    }
    if (std.mem.orderZ(u8, "glClearColor", proc_name) == .eq) {
        return &glClearColor;
    }
    if (std.mem.orderZ(u8, "glClear", proc_name) == .eq) {
        return &glClear;
    }
    return &glDummy;
}

const GL_NUM_EXTENSIONS = 0x821D;
const GL_EXTENSIONS = 0x1F03;

const num_extensions = 2;
const extensions_array: [num_extensions][:0]const u8 = .{ "GL_ARB_clip_control", "GL_KHR_debug" };
const extensions_string: [:0]const u8 = "GL_ARB_clip_control GL_KHR_debug";

var get_integerv_invoked = false;

fn glGetIntegerv(pname: c_uint, data: [*c]c_int) callconv(.C) void {
    get_integerv_invoked = true;
    if (pname == GL_NUM_EXTENSIONS) {
        data[0] = extensions_array.len;
        return;
    }
    unreachable;
}

var get_stringi_invoked = false;

fn glGetStringi(name: c_uint, index: c_uint) callconv(.C) [*c]const u8 {
    get_stringi_invoked = true;
    if (name == GL_EXTENSIONS) {
        return extensions_array[index];
    }
    unreachable;
}

var get_string_invoked = false;

fn glGetString(name: c_uint) callconv(.C) [*c]const u8 {
    get_string_invoked = true;
    if (name == GL_EXTENSIONS) {
        return extensions_string;
    }
    unreachable;
}

const GL_COLOR_BUFFER_BIT = 0x4000;

var clear_color: [4]f32 = .{ 0, 0, 0, 0 };
var clear_mask: c_uint = 0;

fn glClearColor(red: f32, green: f32, blue: f32, alpha: f32) callconv(.C) void {
    clear_color = .{ red, green, blue, alpha };
}

fn glClear(mask: c_uint) callconv(.C) void {
    clear_mask = mask;
}

fn glDummy() callconv(.C) void {
    unreachable;
}

pub fn gl_issueCommand(
    comptime prefixed_name: [:0]const u8,
    args: anytype,
) gl.ReturnTypeOfCommand(prefixed_name) {
    if (comptime std.mem.eql(u8, "glClearColor", prefixed_name)) {
        return gl.defaultIssueCommand(prefixed_name, .{ 1, args[1], args[2], args[3] });
    }
    return gl.defaultIssueCommand(prefixed_name, args);
}

fn refAllDeclsRecursive(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Union, .Opaque, .Enum => {
                    refAllDeclsRecursive(@field(T, decl.name));
                },
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}

comptime {
    @setEvalBranchQuota(1_000_000);
    refAllDeclsRecursive(gl);
}
