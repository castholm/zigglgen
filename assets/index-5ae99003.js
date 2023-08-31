function m(o,u){return o<u?-1:o>u?1:0}async function P(o){const u=await new Promise((h,i)=>{let c=new XMLHttpRequest;c.open("GET",o),c.responseType="document",c.overrideMimeType("text/xml"),c.onloadend=()=>{c.status>=200&&c.status<300&&c.responseXML&&h(c.responseXML.documentElement),i(new Error("Failed to fetch registry."))},c.send()});return{$root:u,apis:new Map(["gl","gles1","gles2","glsc2"].map(h=>[h,{key:h,versions:[...new Set([...u.querySelectorAll(`:scope > feature[api=${h}]`)].map(i=>i.getAttribute("number")))].sort(m),profiles:[...new Set([...u.querySelectorAll(`:scope > feature[api=${h}] > *[profile]`)].map(i=>i.getAttribute("profile")))].sort(m),extensions:[...new Set([...u.querySelectorAll(":scope > extensions > extension")].filter(i=>i.getAttribute("supported").split("|").includes(h)).map(i=>i.getAttribute("name")))].sort(m)}]))}}const B=[`// NOTICE
`,`//
`,`// This work uses definitions from the OpenGL XML API Registry
`,`// <https://github.com/KhronosGroup/OpenGL-Registry>.
`,`// Copyright 2013-2020 The Khronos Group Inc.
`,`// Licensed under Apache-2.0.
`,`//
`,`// END OF NOTICE
`].join(""),z="zigglgen v0.5",U="https://castholm.github.io/zigglgen/";function M(o,u,h,i){const[c,g]=h.split("."),d=!!o.extensions.size,e=[];if(e.push(B),e.push(`
`),e.push(`//! OpenGL binding.
`),e.push(`
`),e.push(`const std = @import("std");
`),e.push(`const root = @import("root");
`),e.push(`
`),e.push(`/// Static information about the OpenGL binding and when/how it was generated.
`),e.push(`pub const about = struct {
`),e.push(`    pub const api_name = "${u}";
`),e.push(`    pub const api_version_major = ${c};
`),e.push(`    pub const api_version_minor = ${g};
`),e.push(`
`),e.push(`    pub const generated_at = "${new Date().toISOString().slice(0,19)}Z";
`),e.push(`
`),e.push(`    pub const generator_name = "${z}";
`),e.push(`    pub const generator_url = "${U}";
`),e.push(`};
`),e.push(`
`),e.push(`/// Makes the specified dispatch table current on the calling thread.
`),e.push(`///
`),e.push("/// This function must be called with a valid dispatch table before calling `extensionSupported` or\n"),e.push(`/// issuing any OpenGL commands from that same thread.
`),e.push(`pub fn makeDispatchTableCurrent(dispatch_table: ?*const DispatchTable) void {
`),e.push(`    DispatchTable.current = dispatch_table;
`),e.push(`}
`),e.push(`
`),e.push("/// Returns the dispatch table that is current on the calling thread, or `null` if no dispatch table\n"),e.push(`/// is current.
`),e.push(`pub fn getCurrentDispatchTable() ?*const DispatchTable {
`),e.push(`    return DispatchTable.current;
`),e.push(`}
`),e.push(`
`),d){e.push("/// Returns `true` if the specified OpenGL extension is supported, `false` otherwise.\n"),e.push(`pub fn extensionSupported(comptime extension: Extension) bool {
`),e.push("    return @field(DispatchTable.current.?, "),i||e.push('"GL_" ++ '),e.push(`@tagName(extension));
`),e.push(`}
`),e.push(`
`),e.push(`/// OpenGL extension.
`),e.push(`pub const Extension = enum {
`);for(const s of o.extensions.values())e.push(`    ${_(s.name)},
`);e.push(`};
`),e.push(`
`)}e.push(`//#region Types
`);for(const s of o.types.values())e.push(`pub const ${_(s.name)} = ${s.type};
`);e.push(`//#endregion Types
`),e.push(`
`),e.push(`//#region Constants
`);for(const s of o.constants.values())e.push(`pub const ${_(s.name)} = ${s.value};
`);e.push(`//#endregion Constants
`),e.push(`
`),e.push(`//#region Commands
`);for(const s of o.commands.values())e.push(`pub fn ${_(s.name)}(`),e.push(s.params.map(b=>`${_(b.name)}: ${b.type}`).join(", ")),e.push(`) callconv(.C) ${s.type} {
`),e.push(`    return issueCommand("${s.key}", .{`),s.params.length>1&&e.push(" "),e.push(s.params.map(b=>`${_(b.name)}`).join(", ")),s.params.length>1&&e.push(" "),e.push(`});
`),e.push(`}
`);e.push(`//#endregion Commands
`),e.push(`
`),e.push(`/// Holds dynamically loaded OpenGL features.
`),e.push(`///
`),e.push(`/// This struct is very large; avoid storing instances of it on the stack.
`),e.push(`pub const DispatchTable = struct {
`),e.push(`    threadlocal var current: ?*const DispatchTable = null;
`),e.push(`
`),e.push(`    /// An opaque pointer to an external function.
`),e.push(`    pub const Proc = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;
`),e.push(`
`),e.push(`    //#region Fields
`);for(const s of o.extensions.values())e.push(`    ${_(s.key)}: bool,
`);for(const s of o.commands.values())e.push(`    ${_(s.key)}: `),s.optional&&e.push("?"),e.push(`*const @TypeOf(${_(s.name)}),
`);if(e.push(`    //#endregion Fields
`),e.push(`
`),e.push("    /// Initializes the specified dispatch table. Returns `true` if successful, `false` otherwise.\n"),e.push(`    ///
`),e.push(`    /// This function must be called successfully before passing the dispatch table to
`),e.push("    /// `makeDispatchTableCurrent` or accessing any of fields.\n"),e.push(`    ///
`),e.push('    /// `loader` is a duck-typed "callable" that takes the prefixed name of an OpenGL command (e.g.\n'),e.push(`    /// *glClear*) and returns a pointer to the corresponding function. It should be able to be
`),e.push(`    /// called in one of the following two ways:
`),e.push(`    ///
`),e.push("    /// - `@as(?DispatchTable.Proc, loader(@as([*:0]const u8, prefixed_name)))`\n"),e.push("    /// - `@as(?DispatchTable.Proc, loader.getProcAddress(@as([*:0]const u8, prefixed_name)))`\n"),e.push(`    ///
`),e.push("    /// No references to `loader` are retained after this function returns.\n"),e.push(`    ///
`),e.push("    /// There is no corresponding `deinit` function.\n"),e.push(`    pub fn init(self: *DispatchTable, loader: anytype) bool {
`),e.push(`        @setEvalBranchQuota(1_000_000);
`),e.push(`        var success: u1 = 1;
`),e.push(`        inline for (@typeInfo(DispatchTable).Struct.fields) |field_info| {
`),e.push(`            switch (@typeInfo(field_info.type)) {
`),e.push(`                .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
`),e.push(`                    .Fn => {
`),e.push(`                        success &= @intFromBool(self.initCommand(field_info.name ++ "", loader));
`),e.push(`                    },
`),e.push(`                    else => comptime unreachable,
`),e.push(`                },
`),d&&(e.push(`                .Bool => {
`),e.push(`                    @field(self, field_info.name) = false;
`),e.push(`                },
`),e.push(`                .Optional => |opt_info| switch (@typeInfo(opt_info.child)) {
`),e.push(`                    .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
`),e.push(`                        .Fn => {
`),e.push(`                            @field(self, field_info.name) = null;
`),e.push(`                        },
`),e.push(`                        else => comptime unreachable,
`),e.push(`                    },
`),e.push(`                    else => comptime unreachable,
`),e.push(`                },
`)),e.push(`                else => comptime unreachable,
`),e.push(`            }
`),e.push(`        }
`),d){e.push(`        if (success == 0) return false;
`);for(const s of o.extensions.values())if(s.commands.length){e.push(`        if (self.initExtension("${s.key}")) {
`);for(const b of s.commands.map(G=>o.commands.get(G)))e.push(`            _ = self.initCommand("${b.key}", loader);
`);e.push(`        }
`)}else e.push(`        _ = self.initExtension("${s.key}");
`);e.push(`        return true;
`)}else e.push(`        return success != 0;
`);return e.push(`    }
`),e.push(`
`),e.push(`    fn initCommand(
`),e.push(`        self: *DispatchTable,
`),e.push(`        comptime prefixed_name: [:0]const u8,
`),e.push(`        loader: anytype,
`),e.push(`    ) bool {
`),e.push(`        const loader_info = @typeInfo(@TypeOf(loader));
`),e.push(`        const loader_is_fn =
`),e.push(`            loader_info == .Fn or
`),e.push(`            loader_info == .Pointer and @typeInfo(loader_info.Pointer.child) == .Fn;
`),e.push(`        const proc_opt: ?DispatchTable.Proc = if (loader_is_fn)
`),e.push(`            loader(prefixed_name)
`),e.push(`        else
`),e.push(`            loader.getProcAddress(prefixed_name);
`),e.push(`        if (proc_opt) |proc| {
`),e.push(`            @field(self, prefixed_name) = @ptrCast(proc);
`),e.push(`            return true;
`),e.push(`        } else {
`),e.push(`            return @typeInfo(@TypeOf(@field(self, prefixed_name))) == .Optional;
`),e.push(`        }
`),e.push(`    }
`),d&&(e.push(`
`),e.push(`    fn initExtension(
`),e.push(`        self: *DispatchTable,
`),e.push(`        comptime prefixed_name: [:0]const u8,
`),e.push(`    ) bool {
`),+c>=3?(e.push(`        var count: ${i?"GLint":"Int"} = 0;
`),e.push(`        self.glGetIntegerv(${i?"GL_":""}NUM_EXTENSIONS, &count);
`),e.push(`        for (0..@intCast(count)) |i| {
`),e.push(`            if (self.glGetStringi(${i?"GL_":""}EXTENSIONS, @intCast(i))) |name| {
`),e.push(`                if (std.mem.orderZ(u8, prefixed_name, name) == .eq) {
`),e.push(`                    @field(self, prefixed_name) = true;
`),e.push(`                    return true;
`),e.push(`                }
`),e.push(`            }
`),e.push(`        }
`),e.push(`        return false;
`)):(e.push(`        var names = std.mem.tokenizeScalar(u8, std.mem.span(self.glGetString(${i?"GL_":""}EXTENSIONS)), ' ');
`),e.push(`        while (names.next()) |name| {
`),e.push(`            if (std.mem.eql(u8, prefixed_name, name)) {
`),e.push(`                @field(self, prefixed_name) = true;
`),e.push(`                return true;
`),e.push(`            }
`),e.push(`        }
`),e.push(`        return false;
`)),e.push(`    }
`)),e.push(`};
`),e.push(`
`),e.push(`/// Issues the specified OpenGL command.
`),e.push(`///
`),e.push(`/// This function is called internally by the OpenGL binding. Its implementation can be overridden
`),e.push("/// by publicly declaring a function named `gl_issueCommand` with a compatible signature in the root\n"),e.push(`/// source file.
`),e.push(`pub fn issueCommand(
`),e.push(`    comptime prefixed_name: [:0]const u8,
`),e.push(`    args: anytype,
`),e.push(`) ReturnTypeOfCommand(prefixed_name) {
`),e.push(`    return if (@hasDecl(root, "gl_issueCommand"))
`),e.push(`        root.gl_issueCommand(prefixed_name, args)
`),e.push(`    else
`),e.push(`        defaultIssueCommand(prefixed_name, args);
`),e.push(`}
`),e.push(`
`),e.push("/// The default implementation of `issueCommand`.\n"),e.push(`///
`),e.push(`/// Overriding implementations can call this function to fall back to the default behavior.
`),e.push(`pub fn defaultIssueCommand(
`),e.push(`    comptime prefixed_name: [:0]const u8,
`),e.push(`    args: anytype,
`),e.push(`) ReturnTypeOfCommand(prefixed_name) {
`),e.push(`    return if (@typeInfo(@TypeOf(@field(@as(DispatchTable, undefined), prefixed_name))) == .Optional)
`),e.push(`        @call(.auto, @field(DispatchTable.current.?, prefixed_name).?, args)
`),e.push(`    else
`),e.push(`        @call(.auto, @field(DispatchTable.current.?, prefixed_name), args);
`),e.push(`}
`),e.push(`
`),e.push(`/// The return type of the specified OpenGL command.
`),e.push(`pub fn ReturnTypeOfCommand(comptime prefixed_name: [:0]const u8) type {
`),e.push(`    if (@hasField(DispatchTable, prefixed_name)) {
`),e.push(`        return switch (@typeInfo(@TypeOf(@field(@as(DispatchTable, undefined), prefixed_name)))) {
`),e.push(`            .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
`),e.push(`                .Fn => |fn_info| fn_info.return_type.?,
`),e.push(`                else => comptime unreachable,
`),e.push(`            },
`),e.push(`            .Bool => {},
`),e.push(`            .Optional => |opt_info| switch (@typeInfo(opt_info.child)) {
`),e.push(`                .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
`),e.push(`                    .Fn => |fn_info| fn_info.return_type.?,
`),e.push(`                    else => comptime unreachable,
`),e.push(`                },
`),e.push(`                else => comptime unreachable,
`),e.push(`            },
`),e.push(`            else => comptime unreachable,
`),e.push(`        };
`),e.push(`    }
`),e.push(`    @compileError("unknown OpenGL command: '" ++ prefixed_name ++ "'");
`),e.push(`}
`),e.join("")}function _(o){return V.test(o)?o:`@"${o}"`}const V=RegExp(`^(?!(${["_","addrspace","align","allowzero","and","anyframe","anytype","asm","async","await","break","callconv","catch","comptime","const","continue","defer","else","enum","errdefer","error","export","extern","fn","for","if","inline","linksection","noalias","noinline","nosuspend","opaque","or","orelse","packed","pub","resume","return","struct","suspend","switch","test","threadlocal","try","union","unreachable","usingnamespace","var","volatile","while","anyerror","anyframe","anyopaque","bool","c_char","c_int","c_long","c_longdouble","c_longlong","c_short","c_uint","c_ulong","c_ulonglong","c_ushort","comptime_float","comptime_int","f128","f16","f32","f64","f80","false","isize","noreturn","null","true","type","undefined","usize","void","([iu][0-9]+)"].join("|")})$)[A-Z_a-z][0-9A-Z_a-z]*$`),$=new Map([["GLbyte","Byte","i8"],["GLubyte","Ubyte","u8"],["GLshort","Short","c_short"],["GLushort","Ushort","c_ushort"],["GLint","Int","c_int"],["GLuint","Uint","c_uint"],["GLint64","Int64","i64"],["GLint64EXT","Int64EXT","i64"],["GLuint64","Uint64","u64"],["GLuint64EXT","Uint64EXT","u64"],["GLintptr","Intptr","isize"],["GLintptrARB","IntptrARB","isize"],["GLhalf","Half","c_ushort"],["GLhalfARB","HalfARB","c_ushort"],["GLhalfNV","HalfNV","c_ushort"],["GLfloat","Float","f32"],["GLdouble","Double","f64"],["GLfixed","Fixed","i32"],["GLboolean","Boolean","u8"],["GLchar","Char","u8"],["GLcharARB","CharARB","u8"],["GLbitfield","Bitfield","c_uint"],["GLenum","Enum","c_uint"],["GLsizei","Sizei","c_int"],["GLsizeiptr","Sizeiptr","isize"],["GLsizeiptrARB","SizeiptrARB","isize"],["GLclampf","Clampf","f32"],["GLclampd","Clampd","f64"],["GLclampx","Clampx","i32"],["GLsync","Sync","?*opaque {}"],["GLDEBUGPROC","DebugProc",'?*const fn (source: GLenum, @"type": GLenum, id: GLuint, severity: GLenum, length: GLsizei, message: [*:0]const GLchar, userParam: ?*const anyopaque) callconv(.C) void','?*const fn (source: Enum, @"type": Enum, id: Uint, severity: Enum, length: Sizei, message: [*:0]const Char, userParam: ?*const anyopaque) callconv(.C) void'],["GLDEBUGPROCARB","DebugProcARB",'?*const fn (source: GLenum, @"type": GLenum, id: GLuint, severity: GLenum, length: GLsizei, message: [*:0]const GLchar, userParam: ?*const anyopaque) callconv(.C) void','?*const fn (source: Enum, @"type": Enum, id: Uint, severity: Enum, length: Sizei, message: [*:0]const Char, userParam: ?*const anyopaque) callconv(.C) void'],["GLDEBUGPROCKHR","DebugProcKHR",'?*const fn (source: GLenum, @"type": GLenum, id: GLuint, severity: GLenum, length: GLsizei, message: [*:0]const GLchar, userParam: ?*const anyopaque) callconv(.C) void','?*const fn (source: Enum, @"type": Enum, id: Uint, severity: Enum, length: Sizei, message: [*:0]const Char, userParam: ?*const anyopaque) callconv(.C) void'],["GLDEBUGPROCAMD","DebugProcAMD","?*const fn (id: GLuint, category: GLenum, severity: GLenum, length: GLsizei, message: [*:0]const GLchar, userParam: ?*anyopaque) callconv(.C) void","?*const fn (id: Uint, category: Enum, severity: Enum, length: Sizei, message: [*:0]const Char, userParam: ?*anyopaque) callconv(.C) void"],["struct _cl_context","ClContextARB","opaque {}"],["struct _cl_event","ClEventARB","opaque {}"],["GLeglClientBufferEXT","EglClientBufferEXT","?*anyopaque"],["GLeglImageOES","EglImageOES","?*anyopaque"],["GLhandleARB","HandleARB",'if (@import("builtin").os.tag == .macos) ?*anyopaque else c_uint'],["GLvdpauSurfaceNV","VdpauSurfaceNV","GLintptr","Intptr"],["GLVULKANPROCNV","VulkanProcNV","?*const fn () callconv(.C) void"]].map((o,u)=>[o[0],{nameOld:o[0].replace(" ","_"),nameNew:o[1],typeOld:o[2],typeNew:o[3]??o[2],ordinal:u}])),F=new Map([["GL_ZERO"],["GL_ONE"],["GL_FALSE"],["GL_TRUE"],["GL_NONE"],["GL_NONE_OES"],["GL_NO_ERROR"],["GL_INVALID_INDEX"],["GL_ALL_PIXELS_AMD"],["GL_TIMEOUT_IGNORED"],["GL_TIMEOUT_IGNORED_APPLE"],["GL_UUID_SIZE_EXT"],["GL_LUID_SIZE_EXT"]].map((o,u)=>[o[0],{ordinal:u}]));function X(o,u,h,i,c,g){const d=new Set,e=new Set,s=new Set,b=new Set(c),G=[],k=[],E=[],w=[],A=o.$root;{const n=[...A.querySelectorAll(`:scope > feature[api=${u}]`)].map(a=>[a,a.getAttribute("number")]).filter(a=>a[1]<=h).sort((a,p)=>m(a[1],p[1])).map(a=>a[0]),t=":scope > require:not([profile]) > *"+(i?`, :scope > require[profile=${i}] > *`:""),r=":scope > remove:not([profile]) > *"+(i?`, :scope > remove[profile=${i}] > *`:"");for(const a of n){for(const p of a.querySelectorAll(t)){const l=p.getAttribute("name");switch(p.tagName){case"type":d.add(l);break;case"enum":e.add(l);break;case"command":s.add(l);break}}for(const p of a.querySelectorAll(r)){const l=p.getAttribute("name");switch(p.tagName){case"type":d.delete(l);break;case"enum":e.delete(l);break;case"command":s.delete(l);break}}}}{const n=(i?[":scope > require:not([api]):not([profile]) > *",`:scope > require:not([api])[profile=${i}] > *`,`:scope > require[api=${u}]:not([profile]) > *`,`:scope > require[api=${u}][profile=${i}] > *`]:[":scope > require:not([api]) > *",`:scope > require[api=${u}] > *`]).join(", ");for(const t of A.querySelectorAll(":scope > extensions > extension")){const r=t.getAttribute("name");if(!b.has(r)||!t.getAttribute("supported").split("|").includes(u))continue;const a=new Set;for(const p of t.querySelectorAll(n)){const l=p.getAttribute("name");switch(p.tagName){case"type":d.add(l);break;case"enum":e.add(l);break;case"command":s.has(l)||a.add(l);break}}w.push({key:r,name:g?r:r.replace(/^GL_/,""),commands:[...a].sort(m)})}w.sort((t,r)=>m(t.name,r.name))}{const n=new Set(w.flatMap(r=>r.commands));for(const r of A.querySelectorAll(":scope > commands > command")){let a=function(y){const L=g?"nameOld":"nameNew",f=y.match(/(struct\s+)?[^\s*]+|\*/g);if(f[0]==="const"&&([f[0],f[1]]=[f[1],f[0]]),!f.includes("*"))return f[0]==="void"?"void":$.get(f[0])[L];let[x,I]=f[0]==="void"?["anyopaque","?*"]:f[0].startsWith("struct _cl_")?[$.get(f[0])[L],"?*"]:[$.get(f[0])[L],"[*c]"];for(let q=1;q<f.length-1;q++)switch(f[q]){case"const":x="const "+x;break;case"*":x=I+x,I="[*c]";break}return x};const p=r.querySelector(":scope > proto > name").textContent,l=s.has(p);if(!l&&!n.has(p))continue;const v=r.querySelector(":scope > proto"),C=v.querySelector(":scope > ptype")?.textContent;C&&d.add(C),E.push({key:p,name:g?p:p.replace(/^gl([A-Z](?:[A-Z](?=[A-Z]|$))*)/,(...y)=>y[1].toLowerCase()),params:[...r.querySelectorAll(":scope > param")].map(y=>{const L=y.querySelector(":scope > ptype")?.textContent;return L&&d.add(L),{name:y.querySelector(":scope > name").textContent,type:a(y.textContent)}}),type:a(v.textContent),optional:!l})}E.sort((r,a)=>m(r.name,a.name));const t=new Set(["std","root","about","makeDispatchTableCurrent","getCurrentDispatchTable","extensionSupported","Extension","DispatchTable","Proc","issueCommand","issueCommandDefault","ReturnTypeOfCommand",...E.map(r=>r.name)]);for(const r of E)for(const a of r.params)for(;t.has(a.name);)a.name+="_"}{for(const n of A.querySelectorAll(":scope > enums")){const t=n.getAttribute("group"),r=t==="SpecialNumbers"?"special-number":n.getAttribute("type")==="bitmask"?"bitmask":n.hasAttribute("start")?"enum":"other";for(const a of n.querySelectorAll(":scope > enum")){const p=a.getAttribute("name");if(!e.has(p))continue;const l=a.getAttribute("api");if(l&&l!==u)continue;let v=-1;if(r==="special-number"){const y=F.get(p)?.ordinal;if(y===void 0)continue;v=y}const C=BigInt(a.getAttribute("value"));k.push({key:p,name:g?p:p.replace(/^GL_/,""),value:C.toString(16).toUpperCase().replace(/[0-9A-F]+$/,y=>"0x"+y),numericValue:C,kind:r,group:t,specialNumberOrdinal:v})}}k.sort((n,t)=>n.kind==="special-number"?t.kind==="special-number"?n.specialNumberOrdinal-t.specialNumberOrdinal:-1:t.kind==="special-number"?1:n.kind==="bitmask"?t.kind==="bitmask"?m(n.group,t.group)||m(n.numericValue,t.numericValue)||m(n.name,t.name):-1:t.kind==="bitmask"?1:n.kind==="enum"?t.kind==="enum"?m(n.numericValue,t.numericValue)||m(n.name,t.name):-1:t.kind==="enum"?1:m(n.group,t.group)||m(n.numericValue,t.numericValue)||m(n.name,t.name))}{for(const n of d){const t=$.get(n);t&&(n==="GLvdpauSurfaceNV"&&d.add("GLintptr"),G.push({key:t.nameOld,name:g?t.nameOld:t.nameNew,type:g?t.typeOld:t.typeNew,ordinal:t.ordinal}))}G.sort((n,t)=>n.ordinal-t.ordinal)}return{types:new Map(G.map(n=>[n.key,n])),constants:new Map(k.map(n=>[n.key,n])),commands:new Map(E.map(n=>[n.key,n])),extensions:new Map(w.map(n=>[n.key,n]))}}const R=await P(new URL("/zigglgen/assets/gl-b61fddab.xml",self.location)),Z=document.getElementById("loading"),O=document.getElementById("form"),S=O.querySelector("[name=api_version_profile]"),T=O.querySelector("[name=extension]"),j=O.querySelector("[name=preserve_names]"),N=document.getElementById("preview"),H=N.querySelector("code");let D=null;S.addEventListener("change",()=>{const[o]=S.value.split(",");if(o===D)return;D=o??null;const u=R.apis.get(o).extensions;for(;T.firstChild;)T.removeChild(T.lastChild);for(const h of u){const i=h.replace(/^GL_/,""),c=document.createElement("option");c.value=h,c.textContent=i,T.appendChild(c)}});S.dispatchEvent(new Event("change"));O.addEventListener("submit",o=>{o.preventDefault();const[u,h,i]=S.value.split(","),c=[...T.selectedOptions].map(s=>s.value),g=j.checked,d=X(R,u,h,i??null,c,g),e=M(d,S.selectedOptions.item(0).textContent,h,g);switch(o.submitter.value){case"Preview":N.hidden=!1,H.textContent=e;break;case"Download":const s=document.createElement("a");s.href=URL.createObjectURL(new Blob([e],{type:"text/plain"})),s.download="gl.zig",s.click();break}});Z.hidden=!0;O.hidden=!1;
