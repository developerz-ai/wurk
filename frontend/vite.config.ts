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
