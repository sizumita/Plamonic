// Builds the extension for both browsers from the same sources:
//
//   dist/chrome/  load unpacked in Chrome (chrome://extensions)
//   dist/safari/  copied into the Safari web extension (.appex) by the Xcode build
//
// Usage: node scripts/build.mjs [--dev] [--watch]
//   --dev    adds sourcemaps and gives the Chrome build a fixed key, so it gets the extension ID that Plamonic's
//            native host allows (ChromeNativeHostInstaller.extensionIDs).
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

/** Gives the dev build the extension ID bdoanndchiakcnoejbbjabpenbgbkfcb, which Plamonic's native host allows. */
const DEV_KEY =
  "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0EogWWDRTAWsRWbtbWPDgPiGtcU0bS1F11g8EnI4p/IBR+hfz5xNwIjx46XYt9vaUcC3Y7fGtgaOVEJEd2wfeo+6iqFc8g2U9m+S0BDNN5KCBKGWPUWaWlsLl81GuwPpRf8EZp/T0X0Ron0bBJPr+1d495+Br8y3Usq8RMkdZJaO63ofNACM6XhoFHfVwF6cg3B5E6GlZKZWK0GSAuMW5th3iNKKp7HC7Xalzn/HmmtuEXyUaCOLICkdTvLp4pmm+bcZetWwY2NhgU5HAb7vhGPekhZwoL4ZI8VMgB1zrTvWTTPfYhJz5jK+YkQrDzZ/eZhrYUzGY7z5AwD6VbcYsQIDAQAB";
/** Plamonic's native host (Contents/Helpers/plamonic-chrome-host, registered by the app at launch). */
const NATIVE_HOST = "io.smdr.plamonic";

/** Sites the content script runs on. A feature for a new site adds its pattern here (and in features/index.ts). */
const CONTENT_MATCHES = ["https://www.youtube.com/*"];

function manifest(browser) {
  const icons = { 16: "icons/16.png", 32: "icons/32.png", 48: "icons/48.png", 128: "icons/128.png" };
  const base = {
    manifest_version: 3,
    name: "Plamonic",
    version: pkg.version,
    description: "Web ページを、この Mac の Plamonic で翻訳します。翻訳は Mac の中で行い、文章を外に送りません。",
    icons,
    action: { default_title: "Plamonic", default_icon: icons, default_popup: "popup.html" },
    // activeTab: the toolbar menu injects the content script into the page it was opened on (page translation),
    // so the extension needs no access to every site.
    permissions: ["nativeMessaging", "storage", "scripting", "activeTab"],
    // Sites set to translate by themselves in the app (Settings › Webサイト): asked for one site at a time, from
    // the toolbar menu, never for all sites.
    optional_host_permissions: ["*://*/*"],
    host_permissions: CONTENT_MATCHES,
    background: { service_worker: "background.js" },
    content_scripts: [{ matches: CONTENT_MATCHES, js: ["content.js"], run_at: "document_start" }],
    web_accessible_resources: [
      // page-hook.js runs in the page's own world.
      { resources: ["page-hook.js"], matches: CONTENT_MATCHES },
    ],
  };
  if (browser === "chrome") {
    // Chrome loads the YouTube hook into the page's own world before the player starts. (Safari has no
    // "world": "MAIN" content scripts: the content script inserts it, features/youtube/index.ts.)
    base.content_scripts.unshift({
      matches: CONTENT_MATCHES, js: ["page-hook.js"], run_at: "document_start", world: "MAIN",
    });
    base.permissions.push("sidePanel");
    base.side_panel = { default_path: "sidebar.html" };
    if (dev) base.key = DEV_KEY;
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
      popup: join(root, "src/popup/index.ts"),
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
