import { defineConfig } from "vite";
import solid from "vite-plugin-solid";
import tailwindcss from "@tailwindcss/vite";
import { readdirSync, readFileSync, writeFileSync } from "fs";
import { join, resolve } from "path";
import { brotliCompressSync, constants as zlib, gzipSync } from "zlib";

// Built artifacts land in ../vendor/assets/dashboard at gem release time.
// See docs/idea/09-precompiled-assets.md.
//
// Dev-server port comes from VITE_PORT (exported by bin/dev) so the logged port
// and the real server never disagree; defaults to 5173.
const devPort = Number(process.env.VITE_PORT) || 5173;

// Text the engine's asset mount can answer pre-compressed. Fonts and images
// are already compressed formats; a .gz of a .woff2 only costs gem bytes.
const COMPRESSIBLE = /\.(js|css|svg|json)$/;

export default defineConfig({
  plugins: [
    solid(),
    tailwindcss(),
    {
      name: "wurk-manifest-generator",
      apply: "build",
      writeBundle() {
        // lib/wurk/version.rb is the single source of truth for the gem
        // version. Match either quote style: the literal's quotes are whatever
        // rubocop's Style/StringLiterals currently enforces, and a `"` -> `'`
        // autocorrect once slipped past a double-quote-only regex. That miss
        // used to fall back to a hardcoded "0.0.1" and ship a manifest
        // disagreeing with the gem, so an unparseable version now fails the
        // build instead of silently stamping a wrong one.
        const versionFilePath = resolve(__dirname, "../lib/wurk/version.rb");
        const versionContent = readFileSync(versionFilePath, "utf-8");
        const versionMatch = versionContent.match(/VERSION\s*=\s*['"]([^'"]+)['"]/);
        if (!versionMatch) {
          throw new Error(`wurk-manifest-generator: no VERSION literal in ${versionFilePath}`);
        }
        const version = versionMatch[1];

        // Create wurk-manifest.json with version for boot-time validation
        const manifestPath = resolve(__dirname, "../vendor/assets/dashboard/wurk-manifest.json");
        const manifest = {
          version,
          timestamp: new Date().toISOString(),
        };

        writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
      },
    },
    {
      // Writes a .gz and a .br next to every fingerprinted text asset, so the
      // engine serves the compressed bytes straight off disk instead of making
      // each host add a deflater (or ship the dashboard uncompressed). A
      // variant that would not be smaller is skipped; the engine then serves
      // the original.
      name: "wurk-precompress",
      apply: "build",
      writeBundle(options) {
        const assetsDir = join(options.dir!, "assets");
        for (const name of readdirSync(assetsDir)) {
          if (!COMPRESSIBLE.test(name)) continue;
          const path = join(assetsDir, name);
          const raw = readFileSync(path);
          const variants: [string, Buffer][] = [
            [".gz", gzipSync(raw, { level: 9 })],
            [
              ".br",
              brotliCompressSync(raw, {
                params: {
                  [zlib.BROTLI_PARAM_QUALITY]: zlib.BROTLI_MAX_QUALITY,
                  [zlib.BROTLI_PARAM_SIZE_HINT]: raw.length,
                },
              }),
            ],
          ];
          for (const [ext, bytes] of variants) {
            if (bytes.length < raw.length) writeFileSync(path + ext, bytes);
          }
        }
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
    port: devPort,
    strictPort: true,
    // HMR dev: the Rails dummy serves the page at :3000/wurk and fetches the
    // shell from this server (WURK_VITE_DEV=1). `origin` makes Vite emit
    // absolute asset/HMR URLs (http://localhost:<devPort>/wurk-assets/…) so the
    // browser loads modules + the HMR client straight from Vite instead of
    // hitting :3000/wurk-assets (which the engine only serves from the built
    // bundle). `cors` lets that cross-origin fetch through. See issue #181.
    origin: `http://localhost:${devPort}`,
    cors: true,
  },
});
