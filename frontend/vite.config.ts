import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Built artifacts land in ../vendor/assets/dashboard at gem release time.
// See docs/idea/09-precompiled-assets.md.
export default defineConfig({
  plugins: [react()],
  base: "/wurk-assets/",
  build: {
    manifest: true,
    sourcemap: process.env.WURK_SOURCEMAPS === "1",
    outDir: "../vendor/assets/dashboard",
    emptyOutDir: true,
  },
  server: {
    port: 5173,
    strictPort: true,
  },
});
