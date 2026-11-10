"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { FUNCTIONS, bundleShared, inspectFunction, manifestFor } = require("../scripts/bundle-function-shared.js");

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "bossai-shared-"));
  fs.mkdirSync(path.join(root, "shared"));
  for (const name of FUNCTIONS) fs.mkdirSync(path.join(root, name));
  fs.writeFileSync(path.join(root, "shared", "a.js"), "module.exports = 1;\n");
  fs.writeFileSync(path.join(root, "shared", "b.js"), "module.exports = 2;\n");
  return root;
}

test("shared bundle is deterministic and check detects missing, stale and extra artifacts", () => {
  const root = fixture();
  const first = bundleShared({ root });
  assert.equal(first.every(row => row.files === 2), true);
  const expected = manifestFor(root, ["a.js", "b.js"]);
  for (const name of FUNCTIONS) {
    const report = inspectFunction(root, name, expected);
    assert.deepEqual([report.missing, report.extra, report.drifted], [[], [], []]);
    assert.equal(fs.existsSync(path.join(root, name, "shared", "manifest.json")), true);
  }
  assert.deepEqual(bundleShared({ root, check: true }).every(row => !row.missing.length && !row.extra.length && !row.drifted.length), true);

  fs.writeFileSync(path.join(root, "bf-api", "shared", "a.js"), "stale\n");
  fs.writeFileSync(path.join(root, "bf-api", "shared", "orphan.js"), "stale\n");
  fs.unlinkSync(path.join(root, "bf-image", "shared", "b.js"));
  const drift = bundleShared({ root, check: true });
  assert.deepEqual(drift[0].drifted, ["a.js"]);
  assert.deepEqual(drift[0].extra, ["orphan.js"]);
  assert.deepEqual(drift[1].missing, ["b.js"]);

  bundleShared({ root });
  assert.equal(fs.readFileSync(path.join(root, "bf-api", "shared", "a.js"), "utf8"), "module.exports = 1;\n");
  assert.equal(fs.existsSync(path.join(root, "bf-api", "shared", "orphan.js")), false);
  assert.equal(fs.existsSync(path.join(root, "bf-image", "shared", "b.js")), true);
});
