import { defineConfig } from "vite"

export default defineConfig({
  root: "src/",
  publicDir: false,
  build: {
    target: "esnext",
    modulePreload: false,
    outDir: "../dst/",
    emptyOutDir: true,
  },
})
