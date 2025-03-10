# © 2024 Carl Åstholm
# SPDX-License-Identifier: MIT

#Requires -Version 7.4

[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

function main {
    $null = New-Item -ItemType Directory _OpenGL-Registry
    Push-Location _OpenGL-Registry
    try {
        try {
            git init
            git fetch https://github.com/KhronosGroup/OpenGL-Registry.git main
            git checkout FETCH_HEAD
            $registry = Select-Xml '/*' xml/gl.xml | Select-Object -ExpandProperty Node
            $rev = git rev-parse HEAD
        } finally {
            Pop-Location
        }

        # REUSE-IgnoreStart
        if ($registry.comment -notmatch '(?m)^Copyright 2013-2020 The Khronos Group Inc\.\r?\nSPDX-License-Identifier: Apache-2\.0$') {
            throw "The OpenGL XML API Registry license notice has changed."
        }
        # REUSE-IgnoreEnd

        processApiRegistry $registry $rev | zig fmt --stdin | Set-Content api_registry.zig
        zig test api_registry.zig

        processGeneratorOptions $registry $rev | zig fmt --stdin | Set-Content GeneratorOptions.zig
        zig test GeneratorOptions.zig
    } finally {
        Remove-Item _OpenGL-Registry -Recurse -Force
    }
}

function processApiRegistry ([System.Xml.XmlElement] $registry, [string] $rev) {
    # REUSE-IgnoreStart
    '// © 2013-2020 The Khronos Group Inc.'
    '// © 2024 Carl Åstholm'
    '// SPDX-License-Identifier: Apache-2.0 AND MIT'
    # REUSE-IgnoreEnd
    ''
    "// This file was generated by '$scriptName'."
    "// OpenGL XML API Registry revision: $rev"
    ''
    "pub const revision = `"$rev`";"
    ''
    'pub const Type = struct {'
    '    name: Name,'
    '    requires: ?Name = null,'
    ''
    '    pub const Name = enum {'
    $registry
    | Select-Xml 'types/type'
    | Select-Object -ExpandProperty Node
    | Select-Object -ExpandProperty name
    | ForEach-Object { stripPrefix $_ }
    | Sort-Object { typeSortKey $_ }
    | ForEach-Object { "@`"$_`"," }
    '    };'
    '};'
    ''
    'pub const Constant = struct {'
    '    name: Name,'
    '    value: i128,'
    '    api: ?Api.Name = null,'
    ''
    '    pub const Name = enum {'
    $registry
    | Select-Xml 'enums/enum'
    | Select-Object -ExpandProperty Node
    | Select-Object -ExpandProperty name -Unique
    | ForEach-Object { stripPrefix $_ }
    | Sort-Object { constantSortKey $_ }
    | ForEach-Object { "@`"$_`"," }
    '    };'
    '};'
    ''
    'pub const Command = struct {'
    '    name: Name,'
    '    params: []const Param,'
    '    return_type_expr: []const Token,'
    ''
    '    pub const Name = enum {'
    $registry
    | Select-Xml 'commands/command/proto'
    | Select-Object -ExpandProperty Node
    | Select-Object -ExpandProperty name
    | ForEach-Object { stripPrefix $_ }
    | Sort-Object { commandSortKey $_ }
    | ForEach-Object { "@`"$_`"," }
    '    };'
    ''
    '    pub const Param = struct {'
    '        name: []const u8,'
    '        type_expr: []const Token,'
    '    };'
    ''
    '    pub const Token = union(enum) {'
    '        void,'
    '        @"*",'
    '        @"const",'
    '        type: Type.Name,'
    '    };'
    '};'
    ''
    'pub const Api = struct {'
    '    name: Name,'
    '    version: [2]u8,'
    '    add: []const Feature,'
    '    remove: []const Feature,'
    ''
    '    pub const Name = enum { gl, gles1, gles2, glsc2 };'
    '};'
    ''
    'pub const ProfileName = enum { core, compatibility, common, common_lite };'
    ''
    'pub const Extension = struct {'
    '    name: Name,'
    '    apis: []const Api.Name,'
    '    add: []const Feature,'
    ''
    '    pub const Name = enum {'
    $registry
    | Select-Xml 'extensions/extension'
    | Select-Object -ExpandProperty Node
    | Select-Object -ExpandProperty name
    | ForEach-Object { stripPrefix $_ }
    | Sort-Object { extensionSortKey $_ }
    | ForEach-Object { "@`"$_`"," }
    '    };'
    '};'
    ''
    'pub const Feature = struct {'
    '    name: Name,'
    '    api: ?Api.Name = null,'
    '    profile: ?ProfileName = null,'
    ''
    '    pub const Name = union(enum) {'
    '        type: Type.Name,'
    '        constant: Constant.Name,'
    '        command: Command.Name,'
    '    };'
    '};'
    ''
    'pub const types = [_]Type{'
    $registry
    | Select-Xml 'types/type'
    | Select-Object -ExpandProperty Node
    | Sort-Object { typeSortKey (stripPrefix $_.name) }
    | ForEach-Object {
        '.{'
        ".name = .@`"$(stripPrefix $_.name)`""
        if ($_.requires) { ", .requires = .@`"$(stripPrefix $_.requires)`"" }
        '},'
    }
    '};'
    ''
    'pub const constants = [_]Constant{'
    $registry
    | Select-Xml 'enums/enum'
    | Select-Object -ExpandProperty Node
    | Sort-Object { constantSortKey (stripPrefix $_.name) }, api
    | ForEach-Object {
        '.{'
        ".name = .@`"$(stripPrefix $_.name)`","
        ".value = $(+"$($_.value -replace '\A0x', '0x0')n")"
        if ($_.api) { ", .api = .$($_.api)" }
        '},'
    }
    '};'
    ''
    'pub const commands = [_]Command{'
    $registry
    | Select-Xml 'commands/command'
    | Select-Object -ExpandProperty Node
    | Sort-Object { commandSortKey (stripPrefix $_.proto.name) }
    | ForEach-Object {
        '.{'
        ".name = .@`"$(stripPrefix $_.proto.name)`","
        '.params = &.{'
        $_
        | Select-Xml 'param'
        | Select-Object -ExpandProperty Node
        | ForEach-Object {
            '.{'
            ".name = `"$($_.name)`","
            ".type_expr = &.{ $((parseDecl $_.InnerText) -join ', ') }"
            '},'
        }
        '},'
        ".return_type_expr = &.{ $((parseDecl $_.proto.InnerText) -join ', ') },"
        '},'
    }
    '};'
    ''
    'pub const apis = [_]Api{'
    $registry
    | Select-Xml 'feature'
    | Select-Object -ExpandProperty Node
    | Sort-Object api, number
    | ForEach-Object {
        '.{'
        ".name = .$($_.api),"
        ".version = .{ $($_.number -split '\.' -join ', ') },"
        '.add = &.{'
        $_
        | Select-Xml "require/*"
        | Select-Object -ExpandProperty Node
        | Sort-Object {
            switch ($_.LocalName) {
                'type' { 0; break }
                'enum' { 1; break }
                'command' { 2; break }
            }
        }, {
            switch ($_.LocalName) {
                'type' { typeSortKey (stripPrefix $_.name); break }
                'enum' { constantSortKey (stripPrefix $_.name); break }
                'command' { commandSortKey (stripPrefix $_.name); break }
            }
        }
        | ForEach-Object {
            '.{'
            ".name = .{ $(
                switch ($_.LocalName) {
                    'type' { '.type'; break }
                    'enum' { '.constant'; break }
                    'command' { '.command'; break }
                }
            ) = .@`"$(stripPrefix $_.name)`" }"
            if ($_.ParentNode.profile) { ", .profile = .$($_.ParentNode.profile -replace '-', '_')" }
            '},'
        }
        '},'
        '.remove = &.{'
        $_
        | Select-Xml "remove/*"
        | Select-Object -ExpandProperty Node
        | Sort-Object {
            switch ($_.LocalName) {
                'type' { 0; break }
                'enum' { 1; break }
                'command' { 2; break }
            }
        }, {
            switch ($_.LocalName) {
                'type' { typeSortKey (stripPrefix $_.name); break }
                'enum' { constantSortKey (stripPrefix $_.name); break }
                'command' { commandSortKey (stripPrefix $_.name); break }
            }
        }
        | ForEach-Object {
            '.{'
            ".name = .{ $(
                switch ($_.LocalName) {
                    'type' { '.type'; break }
                    'enum' { '.constant'; break }
                    'command' { '.command'; break }
                }
            ) = .@`"$(stripPrefix $_.name)`" }"
            if ($_.ParentNode.profile) { ", .profile = .$($_.ParentNode.profile -replace '-', '_')" }
            '},'
        }
        '},'
        '},'
    }
    '};'
    ''
    'pub const extensions = [_]Extension{'
    $registry
    | Select-Xml 'extensions/extension'
    | Select-Object -ExpandProperty Node
    | Sort-Object { extensionSortKey (stripPrefix $_.name) }
    | ForEach-Object {
        '.{'
        ".name = .@`"$(stripPrefix $_.name)`","
        ".apis = &.{ $(($_.supported -split '\|' -match '\Agl(es[12]|sc2)?\z' -replace '\A.*\z', '.$&' -join ', ') | Sort-Object) },"
        '.add = &.{'
        $_
        | Select-Xml "require/*"
        | Select-Object -ExpandProperty Node
        | Sort-Object {
            switch ($_.LocalName) {
                'type' { 0; break }
                'enum' { 1; break }
                'command' { 2; break }
            }
        }, {
            switch ($_.LocalName) {
                'type' { typeSortKey (stripPrefix $_.name); break }
                'enum' { constantSortKey (stripPrefix $_.name); break }
                'command' { commandSortKey (stripPrefix $_.name); break }
            }
        }
        | ForEach-Object {
            '.{'
            ".name = .{ $(
                switch ($_.LocalName) {
                    'type' { '.type'; break }
                    'enum' { '.constant'; break }
                    'command' { '.command'; break }
                }
            ) = .@`"$(stripPrefix $_.name)`" }"
            if ($_.ParentNode.api) { ", .api = .$($_.ParentNode.api)" }
            if ($_.ParentNode.profile) { ", .profile = .$($_.ParentNode.profile -replace '-', '_')" }
            '},'
        }
        '},'
        '},'
    }
    '};'
    ''
    'test {'
    '    @import("std").testing.refAllDeclsRecursive(@This());'
    '}'
}

function processGeneratorOptions ([System.Xml.XmlElement] $registry, [string] $rev) {
    # REUSE-IgnoreStart
    '// © 2013-2020 The Khronos Group Inc.'
    '// © 2024 Carl Åstholm'
    '// SPDX-License-Identifier: Apache-2.0 AND MIT'
    # REUSE-IgnoreEnd
    ''
    "// This file was generated by '$scriptName'."
    "// OpenGL XML API Registry revision: $rev"
    ''
    'api: Api,'
    'version: Version,'
    'profile: ?Profile = null,'
    'extensions: []const Extension = &.{},'
    ''
    'pub const Api = enum { gl, gles, glsc };'
    ''
    'pub const Version = enum {'
    $registry
    | Select-Xml 'feature'
    | Select-Object -ExpandProperty Node
    | Select-Object -ExpandProperty number -Unique
    | Sort-Object
    | ForEach-Object { "@`"$_`"," }
    '};'
    ''
    'pub const Profile = enum { core, compatibility, common, common_lite };'
    ''
    'pub const Extension = enum {'
    $registry
    | Select-Xml 'extensions/extension'
    | Select-Object -ExpandProperty Node
    | Select-Object -ExpandProperty name
    | ForEach-Object { stripPrefix $_ }
    | Sort-Object { extensionSortKey $_ }
    | ForEach-Object { "@`"$_`"," }
    '};'
    ''
    'test {'
    '    @import("std").testing.refAllDeclsRecursive(@This());'
    '}'
}

$scriptName = $PSCommandPath | Split-Path -Leaf

function stripPrefix([string] $str) {
    $str -creplace '\A(GL_?|gl|struct\s+_*)', ''
}

function typeSortKey([string] $str) {
    $null = $str -cmatch @"
(?x)
\A
(?<base>.+?)
(?<extension>3DFX|AMD|ANDROID|ANGLE|APPLE|ARB|ARM|ATI|DMP|EXT|FJ|GREMEDY|HP|IBM|IMG|INGR|INTEL|KHR|MESA|MESAX|NV|NVX|OES|OML|OVR|PGI|QCOM|REND|S3|SGI|SGIS|SGIX|SUN|SUNX|VIV|WIN)?
\z
"@
    (
        (
            [regex]::Replace($Matches.base, '[0-9]+', { param ($m) $m.Value.PadLeft(5, '0') }) -csplit '(?<=[a-z])(?=[A-Z0-9])|(?<=[A-Z0-9])(?=[A-Z][a-z])'
            | ForEach-Object { basicSortKey $_ }
        ) -join '001'
    ) + "000$(basicSortKey $Matches.extension)"
}

function constantSortKey([string] $str) {
    $null = $str -cmatch @"
(?x)
\A
(?<base>.+?)
(?:_(?<extension>3DFX|AMD|ANDROID|ANGLE|APPLE|ARB|ARM|ATI|DMP|EXT|FJ|GREMEDY|HP|IBM|IMG|INGR|INTEL|KHR|MESA|MESAX|NV|NVX|OES|OML|OVR|PGI|QCOM|REND|S3|SGI|SGIS|SGIX|SUN|SUNX|VIV|WIN))?
\z
"@
    (
        (
            [regex]::Replace($Matches.base, '[0-9]+', { param ($m) $m.Value.PadLeft(5, '0') }) -split '_'
            | ForEach-Object { basicSortKey $_ }
        ) -join '001'
    ) + "000$(basicSortKey $Matches.extension)"
}

function commandSortKey ([string] $str) {
    $null = $str -cmatch @"
(?x)
\A
(?<base>.+?)
(?<type>
    b(?<!Attrib)|
    s(?<!Access|Address|Arrays|Bias|Bindless|Bounds|Buffers|Commands|Controls|Coords|Cores|Counters|Elements|Feedbacks|Fences|Framebuffers|Glyphs|Groups|Indices|Instruments|Layers|Levels|Lists|Maps|Markers|Metrics|Monitors|Names|Objects|Ops|Parameters|Paths|Pipelines|Pixels|Points|Programs|Queries|Rates|Rectangles|Regions|Renderbuffers|Samplers|Samples|Segments|Semaphores|Shaders|Stages|States|Status|Surfaces|Symbols|Tasks|Textures|Threads|Triangles|Values|Varyings)|
    i(?<!Bufferfi|Disablei|Enablei|Equationi|Fini|Framebufferfi|Funci|Maski|Separatei|Statei|Stringi)|
    i64|
    ub|
    us(?<!Status)|
    ui|
    ui64|
    x(?<!Box|Index|Matrix|Tex|Vertex)|
    h(?<!Depth|Finish|Flush|Length|Path|Push|Through|Width)|
    f|
    fi|
    d(?<!Advanced|Blend|Coord|Enabled|End|Fixed|Indexed|Keyed)
)?
(?<array>
    i(?<!Bufferfi|Fini|Framebufferfi)|
    v|
    i_v
)?
(?<extension>3DFX|AMD|ANDROID|ANGLE|APPLE|ARB|ARM|ATI|DMP|EXT|FJ|GREMEDY|HP|IBM|IMG|INGR|INTEL|KHR|MESA|MESAX|NV|NVX|OES|OML|OVR|PGI|QCOM|REND|S3|SGI|SGIS|SGIX|SUN|SUNX|VIV|WIN)?
\z
"@
    (
        (
            [regex]::Replace($Matches.base, '[0-9]+', { param ($m) $m.Value.PadLeft(5, '0') }) -split '_'
            | ForEach-Object {
                (
                    $_ -csplit '(?<=[a-z])(?=[A-Z0-9])|(?<=[A-Z0-9])(?=[A-Z][a-z])'
                    | ForEach-Object { basicSortKey $_ }
                ) -join '004'
            }
        ) -join '003'
    ) + "000$(basicSortKey $Matches.type)001$(basicSortKey $Matches.array)002$(basicSortKey $Matches.extension)"
}

function extensionSortKey([string] $str) {
    (
        [regex]::Replace($str, '[0-9]+', { param ($m) $m.Value.PadLeft(5, '0') }) -split '_'
        | ForEach-Object { basicSortKey $_ }
    ) -join '000'
}

function basicSortKey([string] $str) {
    (($str ?? '').GetEnumerator() | ForEach-Object { '{0:000}' -f ([ushort]$_ + 744) }) -join ''
}

function parseDecl ([string] $decl) {
    $tokens =
        $decl
        | Select-String '(struct\s+)?[^\s*]+|\*' -AllMatches
        | Select-Object -ExpandProperty Matches
        | Select-Object -ExpandProperty Value
    if ($tokens[0] -eq 'const') {
        $tokens[0], $tokens[1] = $tokens[1], $tokens[0]
    }
    $tokens[($tokens.Length - 2)..0] | ForEach-Object {
        if ($_ -in @('void'; '*'; 'const')) {
            ".@`"$_`""
        } else {
            ".{ .type = .@`"$(stripPrefix $_)`" }"
        }
    }
}

Push-Location $PSScriptRoot
try { main } finally { Pop-Location }
