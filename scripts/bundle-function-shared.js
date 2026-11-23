"use strict";
// Deterministic build-time packaging, not cross-function runtime imports.
// The canonical files stay in cloudfunctions/shared. Function-local copies are
// generated artifacts; --check makes stale/missing copies a release blocker.
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const FUNCTIONS = Object.freeze(["bf-api", "bf-image", "bf-jobs", "bf-billing", "bf-review-reminders"]);

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function canonicalFiles(root) {
  const source = path.join(root, "shared");
  return fs.readdirSync(source).filter(file => file.endsWith(".js") && fs.statSync(path.join(source, file)).isFile()).sort();
}

function manifestFor(root, files) {
  return Object.fromEntries(files.map(file => [file, sha256(path.join(root, "shared", file))]));
}

function inspectFunction(root, name, expected) {
  const destination = path.join(root, name, "shared");
  const actual = fs.existsSync(destination)
    ? fs.readdirSync(destination).filter(file => file.endsWith(".js") && fs.statSync(path.join(destination, file)).isFile()).sort()
    : [];
  const expectedNames = Object.keys(expected).sort();
  const missing = expectedNames.filter(file => !actual.includes(file));
  const extra = actual.filter(file => !expectedNames.includes(file));
  const drifted = expectedNames.filter(file => actual.includes(file) && sha256(path.join(destination, file)) !== expected[file]);
  return { destination, actual, missing, extra, drifted };
}

function bundleShared({ root, check = false }) {
  const files = canonicalFiles(root);
  const expected = manifestFor(root, files);
  const reports = [];
  for (const name of FUNCTIONS) {
    // A function declared in the build must exist. An optional future function
    // should be removed from this list, not silently skipped during release.
    if (!fs.existsSync(path.join(root, name))) throw new Error("FUNCTION_DIRECTORY_MISSING:" + name);
    const before = inspectFunction(root, name, expected);
    if (check) {
      reports.push({ function: name, missing: before.missing, extra: before.extra, drifted: before.drifted });
      continue;
    }
    fs.mkdirSync(before.destination, { recursive: true });
    // shared/ is a generated directory (see .gitignore). Remove only stale JS
    // artifacts, never source files outside this generated destination.
    for (const file of before.extra) fs.unlinkSync(path.join(before.destination, file));
    for (const file of files) fs.copyFileSync(path.join(root, "shared", file), path.join(before.destination, file));
    const manifestPath = path.join(before.destination, "manifest.json");
    fs.writeFileSync(manifestPath, JSON.stringify({ source: "cloudfunctions/shared", files: expected }, null, 2) + "\n");
    const after = inspectFunction(root, name, expected);
    if (after.missing.length || after.extra.length || after.drifted.length) throw new Error("SHARED_BUILD_VERIFY_FAILED:" + name);
    reports.push({ function: name, files: files.length, missing: [], extra: [], drifted: [] });
  }
  return reports;
}

function main() {
  const check = process.argv.includes("--check");
  const root = path.resolve(__dirname, "../cloudfunctions");
  const reports = bundleShared({ root, check });
  for (const report of reports) console.log(JSON.stringify(report));
  if (check && reports.some(report => report.missing.length || report.extra.length || report.drifted.length)) {
    process.exitCode = 1;
  }
}

if (require.main === module) main();
module.exports = { FUNCTIONS, bundleShared, inspectFunction, manifestFor };
