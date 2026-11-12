#!/usr/bin/env node
// Release-train consistency check — runs on the CURRENT repo (single package):
//   package.json.version === CHANGELOG.md newest section === README badge versions
// Exits 1 with a fix list on any mismatch. Meant to be wired into CI (see
// .github/workflows/ci.yml) so a version bump can never land half-applied.
//
// Readme Harness is distributed Git-first / npm-never, so there is no npm
// publish guard here — only the source-of-truth version-train check.
import { readFileSync, existsSync } from "node:fs";

const fail = [];

const read = (f) => {
  try {
    return readFileSync(f, "utf8");
  } catch {
    fail.push(`missing file: ${f}`);
    return "";
  }
};

// ---- 1. package.json ----------------------------------------------------
const pkgPath = "package.json";
if (!existsSync(pkgPath)) {
  fail.push("missing file: package.json");
  process.exit(1);
}
let pkg;
try {
  pkg = JSON.parse(read(pkgPath));
} catch {
  fail.push(`package.json is not valid JSON`);
  pkg = {};
}
const version = pkg.version;
if (!/^\d+\.\d+\.\d+$/.test(version ?? "")) {
  fail.push(`package.json version "${version}" is not x.y.z`);
}

// ---- 2. CHANGELOG newest section ----------------------------------------
const cl = read("CHANGELOG.md");
const clMatch = cl.match(/^## \[(.+?)\]/m);
const clVersion = clMatch && clMatch[1];
if (!clVersion) fail.push("CHANGELOG.md has no `## [x.y.z]` section");
else if (clVersion !== version) {
  fail.push(`CHANGELOG newest section is [${clVersion}], package.json is ${version}`);
}

// ---- 3. README language pages: Version badges ----------------------------
// Each page's Version badge must carry the same version. English, zh-CN,
// ja (if present).
const pages = ["README.md", "README.zh-CN.md", "README.ja.md"];
for (const f of pages) {
  if (!existsSync(f)) continue;
  const s = read(f);
  const m = s.match(/img\.shields\.io\/badge\/(?:Version|\u7248\u672c|\u30d0\u30fc\u30b8\u30e7\u30f3)-([0-9.]+)-/);
  if (!m) {
    fail.push(`${f}: no Version badge found`);
    continue;
  }
  const [label, got] = m;
  if (got !== version) fail.push(`${f}: Version badge is ${got}, package.json is ${version}`);
  void label;
}

if (fail.length) {
  console.error(`Version consistency check FAILED (expected ${version ?? "?"}):`);
  for (const f of fail) console.error(` - ${f}`);
  console.error("\nFix: bump every surface together (package.json, CHANGELOG.md, README badges).");
  process.exit(1);
}
console.log(`version ${version}: package.json = CHANGELOG = README badges ✓`);