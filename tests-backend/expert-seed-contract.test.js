// ============================================================================
// expert-seed-contract.test.js —— 云端专家种子（cloudfunctions/bf-api/experts.json）
//
// 为什么要测 JSON：专家目录有两个下发源 —— App 内置（Expert.swift）与云端种子。
// 登录后云端目录会**整体替换**内置目录，所以"只改了 App 没改种子"的结果是：
// 本地能跑、用户手机上却看不到新专家。这类问题只能靠契约测试挡。
//
// 这里断言的是种子自身的结构完整性（ID 唯一、starters 覆盖、字段齐全、emoji 不重复），
// 与 App 侧的 ShortVideoSkillTests（ID 集合一致）配合，两侧都不会漂。
// ============================================================================

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

const SEED = require(path.join(__dirname, "../cloudfunctions/bf-api/experts.json"));

const REQUIRED_FIELDS = ["id", "name", "subtitle", "symbol", "role", "framework", "steps", "deliverable", "tools", "checklist", "freshnessCue"];
const KNOWN_TOOLS = new Set(["search", "image", "word", "ppt", "excel", "pdf"]);
const KNOWN_DELIVERABLES = new Set(["word", "ppt", "excel", "pdf"]);

test("SEED-01 专家 ID 唯一且字段齐全", () => {
  const ids = SEED.experts.map((e) => e.id);
  assert.equal(new Set(ids).size, ids.length, "存在重复专家 ID");
  for (const e of SEED.experts) {
    for (const f of REQUIRED_FIELDS) {
      assert.ok(e[f] !== undefined && e[f] !== null, `专家 ${e.id} 缺少字段 ${f}`);
    }
    assert.ok(e.steps.length >= 3, `专家 ${e.id} 的工作流步骤太少（<3）`);
    assert.ok(e.checklist.length >= 2, `专家 ${e.id} 缺少自检清单`);
  }
});

test("SEED-02 工具与交付物必须在白名单内（否则 App 会静默忽略）", () => {
  for (const e of SEED.experts) {
    for (const t of e.tools) assert.ok(KNOWN_TOOLS.has(t), `专家 ${e.id} 用了未知工具 ${t}`);
    if (e.deliverable !== null) assert.ok(KNOWN_DELIVERABLES.has(e.deliverable), `专家 ${e.id} 交付物非法 ${e.deliverable}`);
  }
});

test("SEED-03 每个专家都有开场白，且不超过 4 条", () => {
  for (const e of SEED.experts) {
    const s = SEED.starters[e.id];
    assert.ok(Array.isArray(s) && s.length > 0, `专家 ${e.id} 没有开场白（用户点进去是空白页）`);
    assert.ok(s.length <= 4, `专家 ${e.id} 开场白过多（>4）`);
    for (const item of s) {
      assert.ok(item.label && item.content, `专家 ${e.id} 开场白缺少 label/content`);
    }
  }
  // 反向：不能有孤儿 starters（配了开场白但没有对应专家 = 无效配置）
  for (const key of Object.keys(SEED.starters)) {
    assert.ok(SEED.experts.some((e) => e.id === key), `starters 里有孤儿键 ${key}`);
  }
});

test("SEED-04 短视频脚本专家（short_video）必须存在且职责边界清楚", () => {
  const e = SEED.experts.find((x) => x.id === "short_video");
  assert.ok(e, "云端种子缺少 short_video —— 用户登录后会看不到这个专家");
  assert.equal(e.name, "短视频脚本");
  assert.deepEqual(e.tools, ["search", "image", "word"], "工具集被改动：默认只给搜索/生图/文档");
  assert.equal(e.deliverable, "word");
  assert.ok(/老板IP|老板 IP/.test(e.role), "缺少与老板IP的分工说明");
  assert.ok(e.role.includes("流量策划"), "缺少与流量策划的分工说明");
  assert.ok(e.role.includes("营销策划"), "缺少与营销策划的分工说明");
  assert.ok(e.role.includes("顶级演讲"), "缺少与演讲专家的分工说明");
  assert.ok(e.steps.some((s) => s.includes("3 个")), "缺少「3 个差异化角度/钩子」步骤");
  assert.ok(e.steps.some((s) => s.includes("speech_duration")), "缺少口播时长核算步骤");
  assert.ok(e.checklist.some((s) => s.includes("播放量")), "缺少「不承诺播放量」自检项");
});

test("SEED-05 内置版本号必须 >= 3（否则旧 DB 不会升级到含短视频的目录）", () => {
  const src = require("node:fs").readFileSync(path.join(__dirname, "../cloudfunctions/bf-api/index.js"), "utf8");
  const m = src.match(/const EXPERTS_SEED_VERSION = (\d+);/);
  assert.ok(m, "找不到 EXPERTS_SEED_VERSION（上一轮曾被误删成注释，导致整个目录不可用）");
  assert.ok(Number(m[1]) >= 3, "版本号仍 <3，线上 bf_config/experts 不会自动升级");
});
