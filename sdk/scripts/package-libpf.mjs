#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const repoRoot = resolve(scriptDir, "../..");
const outputDir = resolve(process.argv[2] || resolve(repoRoot, "sdk/dist/libpf"));
const requestedNativeAddons = process.argv.slice(3).map((path) => resolve(path));
const defaultNativeAddon = resolve(repoRoot, "zig-out/lib/libpf.node");
const nativeAddons = requestedNativeAddons.length ? requestedNativeAddons : [defaultNativeAddon];
const requiredNativeNames = new Set([
  "libpf.linux-x64.node",
  "libpf.linux-arm64.node",
  "libpf.darwin-x64.node",
  "libpf.darwin-arm64.node",
]);
const localNativeName = {
  "linux-x64": "libpf.linux-x64.node",
  "linux-arm64": "libpf.linux-arm64.node",
  "darwin-x64": "libpf.darwin-x64.node",
  "darwin-arm64": "libpf.darwin-arm64.node",
}[`${process.platform}-${process.arch}`];
const files = [
  ["sdk/package.json", "package.json"],
  ["sdk/README.md", "README.md"],
  ["LICENSE", "LICENSE"],
  ["sdk/browser.js", "browser.js"],
  ["sdk/node.js", "node.js"],
  ["sdk/pf-sdk.js", "pf-sdk.js"],
  ["sdk/wasm-module.js", "wasm-module.js"],
  ["sdk/core-output.js", "core-output.js"],
  ["sdk/mcp.js", "mcp.js"],
  ["sdk/skills.js", "skills.js"],
  ["sdk/skills-node.js", "skills-node.js"],
  ["zig-out/bin/pf-core.wasm", "pf-core.wasm"],
  ["zig-out/bin/pf-term.wasm", "pf-term.wasm"],
];

if (requestedNativeAddons.length) {
  const names = nativeAddons.map((addon) => basename(addon));
  const duplicates = names.filter((name, index) => names.indexOf(name) !== index);
  const missing = [...requiredNativeNames].filter((name) => !names.includes(name));
  const unexpected = names.filter((name) => !requiredNativeNames.has(name));
  if (duplicates.length || missing.length || unexpected.length) {
    throw new Error([
      "publishable package requires exactly one addon for every supported platform",
      duplicates.length ? `duplicates: ${duplicates.join(", ")}` : null,
      missing.length ? `missing: ${missing.join(", ")}` : null,
      unexpected.length ? `unexpected: ${unexpected.join(", ")}` : null,
    ].filter(Boolean).join("; "));
  }
}
if (!requestedNativeAddons.length && !localNativeName) {
  throw new Error(`local native packaging is unsupported on ${process.platform}-${process.arch}`);
}

await rm(outputDir, { recursive: true, force: true });
await mkdir(outputDir, { recursive: true });
const cjsBuild = spawnSync(process.execPath, [
  resolve(repoRoot, "sdk/scripts/build-node-cjs.mjs"),
  resolve(outputDir, "node.cjs"),
], { cwd: repoRoot, stdio: "inherit" });
if (cjsBuild.error) throw cjsBuild.error;
if (cjsBuild.status !== 0) process.exit(cjsBuild.status ?? 1);
for (const [source, destination] of files) {
  await cp(resolve(repoRoot, source), resolve(outputDir, destination));
}
for (const addon of nativeAddons) {
  if (!addon.endsWith(".node")) throw new Error(`native addon must end in .node: ${addon}`);
  const destination = requestedNativeAddons.length ? basename(addon) : localNativeName;
  await cp(addon, resolve(outputDir, destination));
}

const manifest = JSON.parse(await readFile(resolve(outputDir, "package.json"), "utf8"));
manifest.files = undefined;
await writeFile(resolve(outputDir, "package.json"), `${JSON.stringify(manifest, null, 2)}\n`);

console.log(`packaged ${manifest.name} in ${outputDir}`);
console.log("  node.cjs");
for (const [, destination] of files) console.log(`  ${destination}`);
for (const addon of nativeAddons) {
  console.log(`  ${requestedNativeAddons.length ? basename(addon) : localNativeName}`);
}
