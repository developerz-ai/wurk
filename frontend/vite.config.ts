import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { readFileSync, writeFileSync } from "fs";
import { resolve } from "path";

// Built artifacts land in ../vendor/assets/dashboard at gem release time.
// See docs/idea/09-precompiled-assets.md.
export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    {
      name: "wurk-manifest-generator",
      apply: "build",
      writeBundle() {
        // Read gem version from lib/wurk/version.rb
        const versionFilePath = resolve(__dirname, "../lib/wurk/version.rb");
        const versionContent = readFileSync(versionFilePath, "utf-8");
        const versionMatch = versionContent.match(/VERSION = "([^"]+)"/);
        const version = versionMatch ? versionMatch[1] : "0.0.1";

        // Create wurk-manifest.json with version for boot-time validation
        const manifestPath = resolve(__dirname, "../vendor/assets/dashboard/wurk-manifest.json");
        const manifest = {
          version,
          timestamp: new Date().toISOString(),
        };

        writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
      },
    },
  ],
  // Must match Wurk::Engine::AssetMount::PREFIX (lib/wurk/engine.rb): the engine
  // serves the built bundle under this path and the dev controller fetches the
  // HMR shell from <vite>/wurk-assets/.
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
    // HMR dev: the Rails dummy serves the page at :3000/wurk and fetches the
    // shell from this server (WURK_VITE_DEV=1). `origin` makes Vite emit
    // absolute asset/HMR URLs (http://localhost:5173/wurk-assets/…) so the
    // browser loads modules + the HMR client straight from Vite instead of
    // hitting :3000/wurk-assets (which the engine only serves from the built
    // bundle). `cors` lets that cross-origin fetch through. See issue #181.
    origin: "http://localhost:5173",
    cors: true,
  },
});
