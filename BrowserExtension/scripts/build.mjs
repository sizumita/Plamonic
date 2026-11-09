// Builds the extension for both browsers from the same sources:
//
//   dist/chrome/  load unpacked in Chrome (chrome://extensions)
//   dist/safari/  copied into the Safari web extension (.appex) by the Xcode build
//
// Usage: node scripts/build.mjs [--dev] [--watch]
//   --dev    adds sourcemaps and talks to the spike's native host (Tools/extension-spike), whose Chrome manifest
//            allows the spike's extension ID; the dev build uses the spike's key so it gets that ID.
//   --watch  rebuilds on change.
import * as esbuild from "esbuild";
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const args = new Set(process.argv.slice(2));
const dev = args.has("--dev");
const watch = args.has("--watch");
const pkg = JSON.parse(await readFile(join(root, "package.json"), "utf8"));

/** The spike's key: gives the dev build the extension ID its native host manifest allows. */
const SPIKE_KEY =
  "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0EogWWDRTAWsRWbtbWPDgPiGtcU0bS1F11g8EnI4p/IBR+hfz5xNwIjx46XYt9vaUcC3Y7fGtgaOVEJEd2wfeo+6iqFc8g2U9m+S0BDNN5KCBKGWPUWaWlsLl81GuwPpRf8EZp/T0X0Ron0bBJPr+1d495+Br8y3Usq8RMkdZJaO63ofNACM6XhoFHfVwF6cg3B5E6GlZKZWK0GSAuMW5th3iNKKp7HC7Xalzn/HmmtuEXyUaCOLICkdTvLp4pmm+bcZetWwY2NhgU5HAb7vhGPekhZwoL4ZI8VMgB1zrTvWTTPfYhJz5jK+YkQrDzZ/eZhrYUzGY7z5AwD6VbcYsQIDAQAB";
const NATIVE_HOST = dev ? "io.smdr.plamonic.spike" : "io.smdr.plamonic";

/** Sites the content script runs on. A feature for a new site adds its pattern here (and in features/index.ts). */
const CONTENT_MATCHES = ["https://www.youtube.com/*"];

function manifest(browser) {
  const icons = { 16: "icons/16.png", 32: "icons/32.png", 48: "icons/48.png", 128: "icons/128.png" };
  const base = {
    manifest_version: 3,
    name: "Plamonic",
    version: pkg.version,
    description: "YouTube の字幕などを、この Mac の Plamonic で翻訳します。",
    icons,
    action: { default_title: "Plamonic", default_icon: icons },
    permissions: ["nativeMessaging", "storage", "scripting"],
    host_permissions: CONTENT_MATCHES,
    background: { service_worker: "background.js" },
    content_scripts: [{ matches: CONTENT_MATCHES, js: ["content.js"], run_at: "document_start" }],
    web_accessible_resources: [
      // page-hook.js runs in the page's own world.
      { resources: ["page-hook.js"], matches: CONTENT_MATCHES },
    ],
  };
  if (browser === "chrome") {
    base.permissions.push("sidePanel");
    base.side_panel = { default_path: "sidebar.html" };
    if (dev) base.key = SPIKE_KEY;
  }
  return base;
}

async function build(browser) {
  const out = join(root, "dist", browser);
  await rm(out, { recursive: true, force: true });
  await mkdir(out, { recursive: true });
  const options = {
    entryPoints: {
      background: join(root, "src/background/index.ts"),
      content: join(root, "src/content/index.ts"),
      "page-hook": join(root, "src/features/youtube/page-hook.ts"),
      sidebar: join(root, "src/sidebar/index.ts"),
    },
    outdir: out,
    bundle: true,
    format: "iife",
    target: ["chrome120", "safari18"],
    loader: { ".css": "text" },
    sourcemap: dev ? "inline" : false,
    minify: !dev,
    define: {
      __BROWSER__: JSON.stringify(browser),
      __NATIVE_HOST__: JSON.stringify(NATIVE_HOST),
      __VERSION__: JSON.stringify(pkg.version),
    },
    logLevel: "warning",
  };
  await cp(join(root, "static"), out, { recursive: true });
  await writeFile(join(out, "manifest.json"), JSON.stringify(manifest(browser), null, 2) + "\n");
  if (watch) {
    const context = await esbuild.context(options);
    await context.watch();
  } else {
    await esbuild.build(options);
  }
  console.log(`built dist/${browser}${dev ? " (dev)" : ""}`);
}

await Promise.all([build("chrome"), build("safari")]);
