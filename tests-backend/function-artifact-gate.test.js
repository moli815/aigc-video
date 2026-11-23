"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs"), os = require("node:os"), path = require("node:path"), cp = require("node:child_process");
const root = path.resolve(__dirname, "..");
function gate(t, files, kind) {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), "bossai-artifact-gate-"));
  t.after(() => {
    assert.equal(path.dirname(path.resolve(folder)), path.resolve(os.tmpdir()));
    assert.ok(path.basename(folder).startsWith("bossai-artifact-gate-"));
    fs.rmSync(folder, {recursive:true,force:true});
  });
  const zip = path.join(folder, "candidate.zip");
  cp.execFileSync("python", ["-c", "import json,sys,zipfile\nd=json.load(sys.stdin)\nwith zipfile.ZipFile(sys.argv[1],'w') as z:\n for n,v in d.items(): z.writestr(n,v)", zip],
    {input:JSON.stringify({"package.json":"{}","scf_bootstrap":"node index.js", ...files})});
  const result = cp.spawnSync("python", ["scripts/check-function-artifact.py",zip,zip,...(kind?['--kind',kind]:[])], {cwd:root,encoding:"utf8"});
  return {status:result.status, ...JSON.parse(result.stdout)};
}
test("artifact gate rejects an unshipped top-level runtime module even with identical inventories", t => {
  const result = gate(t, {"index.js":"require('./expert-delivery-arbitration');"});
  assert.equal(result.status,1);
  assert.equal(result.ok,false);
  assert.deepEqual(result.changed,[]);
  assert.deepEqual(result.missingLocalModules,[{from:"index.js",request:"./expert-delivery-arbitration"}]);
});
test('event artifact explicitly omits HTTP bootstrap while the default HTTP gate still rejects it',t=>{
 const files={'index.js':'exports.main=async()=>({ok:true});','scf_bootstrap':undefined};
 // JSON transport drops undefined; events use exports.main, no HTTP listener.
 assert.equal(gate(t,files,'event').ok,true);assert.equal(gate(t,files).ok,false);
});
test("artifact gate resolves nested relative files, JSON, package main and directory indexes", t => {
  const result = gate(t, {"index.js":"require('./lib'); require('./data.json'); require('./pkg');",
    "lib/index.js":"require('../rule');", "rule.js":"module.exports=1;", "data.json":"{}",
    "pkg/package.json":'{"main":"src/main.js"}',"pkg/src/main.js":"module.exports={};"});
  assert.equal(result.status,0);
  assert.deepEqual(result.missingLocalModules,[]);
});
test("artifact gate also rejects dependencies missing below the entrypoint", t => {
  const result = gate(t, {"index.js":"require('./rule');", "rule.js":"require('./missing');"});
  assert.equal(result.ok,false);
  assert.deepEqual(result.missingLocalModules,[{from:"rule.js",request:"./missing"}]);
});
