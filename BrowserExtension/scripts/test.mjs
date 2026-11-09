// Bundles test/*.test.ts for Node and runs them with Node's test runner.
import * as esbuild from "esbuild";
import { spawnSync } from "node:child_process";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const tests = (await readdir(join(root, "test"))).filter((name) => name.endsWith(".test.ts"));
const out = await mkdtemp(join(tmpdir(), "plamonic-extension-tests-"));
try {
  await esbuild.build({
    entryPoints: tests.map((name) => join(root, "test", name)),
    outdir: out,
    outExtension: { ".js": ".mjs" },
    bundle: true,
    format: "esm",
    platform: "node",
    packages: "external",
    loader: { ".css": "text" },
    define: { __BROWSER__: '"chrome"', __NATIVE_HOST__: '"test"', __VERSION__: '"0.0.0"' },
    logLevel: "warning",
  });
  const files = tests.map((name) => join(out, name.replace(/\.ts$/, ".mjs")));
  const result = spawnSync(process.execPath, ["--test", ...files], { stdio: "inherit" });
  process.exitCode = result.status ?? 1;
} finally {
  await rm(out, { recursive: true, force: true });
}
