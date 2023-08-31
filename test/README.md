# Testing

Included in this directory are some basic tests to help ensure that zigglgen generates valid Zig code and that things
like initialization, extension loading and command interception work. Testing isn't fully automated and requires some
manual input.

1. Run `npm run dev` to serve zigglgen locally, then visit it in a browser.
2. Select "OpenGL 4.6 (Core Profile)", select all extensions, leave "preserve original C naming convention" unchecked
   and download the result to this directory as `gl46.zig`.
3. Select "OpenGL 3.0", select all extensions, check "preserve original C naming convention" and download the result to
   this directory as `gl30.zig`.
4. Select "OpenGL 2.1", select all extensions, leave "preserve original C naming convention" unchecked and download the
   result to this directory as `gl21.zig`.
5. Select "OpenGL 1.0", select all extensions, check "preserve original C naming convention" and download the result to
   this directory as `gl10.zig`.
6. Select "OpenGL ES 3.0", don't select any extensions, leave "preserve original C naming convention" unchecked and
   download the result to this directory as `gles30.zig`.
7. Close the dev server, `cd` into this directory and run `zig build test`. If the command exits with a 0 exit code, all
   tests have passed.

This process should be repeated after making any changes that impact code generation.
