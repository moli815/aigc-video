"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const seed = require("../cloudfunctions/bf-api/experts.json");
const { validateCatalog, shouldApplySeed, getExpertCatalog, saveExpertCatalog } = require("../cloudfunctions/bf-api/expert-catalog");

function fakeDb(initial) {
  const stores = { bf_config: structuredClone(initial ? { experts: initial } : {}), bf_config_revisions: {} };
  const tx = {
    collection(name) {
      return {
        doc(id) {
          return {
            async get() { return { data: stores[name][id] ? [stores[name][id]] : [] }; },
            async set(value) { stores[name][id] = structuredClone(value); },
            async update(patch) { Object.assign(stores[name][id], structuredClone(patch)); },
          };
        },
      };
    },
  };
  return {
    stores,
    collection(name) { return tx.collection(name); },
    runTransaction(work) { return work(tx); },
  };
}
const bodyFromSeed = () => ({ experts: structuredClone(seed.experts), starters: structuredClone(seed.starters), ui: seed.ui });

test("catalog validation blocks unknown/deleted IDs and mismatched deliverables, preserves multiline starters", () => {
  const body = bodyFromSeed();
  body.starters.general[0].content = "第一行\n第二行｜仍然属于内容";
  assert.equal(validateCatalog(body, seed.experts.map(expert => expert.id)), "");
  const added = bodyFromSeed();
  added.experts.push({ ...structuredClone(seed.experts[0]), id: "custom_new" });
  assert.match(validateCatalog(added, seed.experts.map(expert => expert.id)), /不支持新增专家/);
  const removed = bodyFromSeed();
  removed.experts.pop();
  assert.match(validateCatalog(removed, seed.experts.map(expert => expert.id)), /不能删除专家/);
  const mismatch = bodyFromSeed();
  mismatch.experts[0].tools = ["search"];
  assert.match(validateCatalog(mismatch, seed.experts.map(expert => expert.id)), /未包含在工具权限/);
});

test("seed upgrades never overwrite admin revisions or unknown legacy provenance", () => {
  assert.equal(shouldApplySeed({ origin: "admin", version: 2, experts: [{}] }, 4, "new"), false);
  assert.equal(shouldApplySeed({ version: 7, experts: [{}] }, 4, "new"), false);
  assert.equal(shouldApplySeed({ version: 2, experts: [{}] }, 4, "new"), false);
  assert.equal(shouldApplySeed({ origin: "seed", version: 3, seedHash: "old", experts: [{}] }, 4, "new"), true);
  assert.equal(shouldApplySeed({ origin: "seed", version: 4, seedHash: "new", experts: [{}] }, 4, "new"), false);
});

test("save enforces expectedRevision, stores snapshot and keeps admin origin", async () => {
  const previous = { ...bodyFromSeed(), version: 7, catalogRevision: 7, origin: "admin" };
  const db = fakeDb(previous);
  const stale = await saveExpertCatalog({ db, body: { ...bodyFromSeed(), expectedRevision: 6 }, seed, seedVersion: 4, seedHash: "hash", staff: { sub: "admin2" } });
  assert.equal(stale.status, 409);
  assert.equal(db.stores.bf_config.experts.version, 7);

  const body = bodyFromSeed();
  body.expectedRevision = 7;
  body.experts[0].role = "管理员新角色";
  body.starters.general[0].content = "多行\n内容";
  const saved = await saveExpertCatalog({ db, body, seed, seedVersion: 4, seedHash: "hash", staff: { sub: "admin2" } });
  assert.equal(saved.status, 200);
  assert.equal(saved.body.version, 8);
  assert.equal(db.stores.bf_config.experts.origin, "admin");
  assert.equal(db.stores.bf_config.experts.experts[0].role, "管理员新角色");
  assert.equal(db.stores.bf_config.experts.starters.general[0].content, "多行\n内容");
  assert.equal(db.stores.bf_config_revisions.experts_7.catalog.version, 7);
  const catalog = await getExpertCatalog({ db, seed, seedVersion: 5, seedHash: "new-hash" });
  assert.equal(catalog.experts[0].role, "管理员新角色");
});

test("reset restores exact seed and permits later explicit seed upgrades", async () => {
  const db = fakeDb({ version: 9, origin: "admin", experts: [{ id: "broken" }] });
  const result = await saveExpertCatalog({ db, body: { reset: true }, seed, seedVersion: 4, seedHash: "hash", staff: { sub: "admin" } });
  assert.equal(result.status, 200);
  assert.equal(db.stores.bf_config.experts.origin, "seed");
  assert.equal(db.stores.bf_config.experts.experts.length, 16);
  assert.equal(shouldApplySeed(db.stores.bf_config.experts, 5, "next"), true);
});
