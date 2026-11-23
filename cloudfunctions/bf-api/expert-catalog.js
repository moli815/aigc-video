"use strict";

const KNOWN_TOOLS = new Set(["search", "image", "word", "ppt", "excel", "pdf"]);
const KNOWN_DELIVERABLES = new Set(["word", "ppt", "excel", "pdf"]);
const one = result => Array.isArray(result?.data) ? result.data[0] : result?.data;

function validateCatalog(body, supportedIds) {
  const experts = body?.experts;
  if (!Array.isArray(experts) || !experts.length || experts.length > 60) return "experts 必须为 1~60 个的非空数组";
  const supported = new Set(supportedIds);
  const ids = new Set();
  for (const expert of experts) {
    if (!expert || typeof expert !== "object") return "存在非法专家项";
    for (const field of ["id", "name", "subtitle", "symbol", "role"]) {
      if (!String(expert[field] || "").trim()) return `专家缺少字段 ${field}`;
    }
    if (ids.has(expert.id)) return `专家 id 重复：${expert.id}`;
    if (!supported.has(expert.id)) return `当前客户端尚不支持新增专家 ${expert.id}，请先使用既有专家`;
    ids.add(expert.id);
    const tools = Array.isArray(expert.tools) ? expert.tools : [];
    if (tools.some(tool => !KNOWN_TOOLS.has(tool))) return `${expert.id} 含未知工具`;
    const deliverable = String(expert.deliverable || "word");
    if (!KNOWN_DELIVERABLES.has(deliverable)) return `${expert.id} 交付物不受支持`;
    if (!tools.includes(deliverable)) return `${expert.id} 默认交付物 ${deliverable} 未包含在工具权限中`;
    if (!Array.isArray(expert.steps) || !expert.steps.length || expert.steps.some(step => typeof step !== "string" || !step.trim())) {
      return `${expert.id} 的 steps 必须为非空字符串数组`;
    }
    const starters = body.starters?.[expert.id] || [];
    if (!Array.isArray(starters) || starters.some(item => !item || typeof item.label !== "string" || typeof item.content !== "string")) {
      return `${expert.id} 的开场白格式不正确`;
    }
  }
  // Old shipped apps have a fixed local capability registry. Removing an ID
  // silently maps old conversations to general, so it is blocked until the new
  // catalog/capability contract is shipped.
  for (const id of supported) if (!ids.has(id)) return `当前版本不能删除专家 ${id}，可先调整其展示与职责`;
  return "";
}

function shouldApplySeed(doc, seedVersion, seedHash) {
  if (!doc || !Array.isArray(doc.experts) || !doc.experts.length) return true;
  if (doc.origin === "admin") return false;
  if (doc.origin === "seed") return Number(doc.seedVersion || doc.version || 0) < seedVersion || doc.seedHash !== seedHash;
  // Legacy admin revisions used version > seed. Preserve them and any legacy
  // document without provenance; automatic upgrade is only for known seeds.
  if (!doc.origin && Number(doc.version || 0) > seedVersion) return false;
  if (!doc.seedHash) return false;
  return Number(doc.version || 0) < seedVersion || doc.seedHash !== seedHash;
}

function publicCatalog(doc, seed) {
  return {
    version: doc?.version || doc?.catalogRevision || 1,
    catalogRevision: doc?.catalogRevision || doc?.version || 1,
    experts: doc?.experts || seed.experts,
    starters: doc?.starters || seed.starters,
    ui: doc?.ui || seed.ui || null,
  };
}

async function getExpertCatalog({ db, seed, seedVersion, seedHash }) {
  const config = db.collection("bf_config").doc("experts");
  let doc = one(await config.get());
  if (!shouldApplySeed(doc, seedVersion, seedHash)) return publicCatalog(doc, seed);
  return db.runTransaction(async tx => {
    const ref = tx.collection("bf_config").doc("experts");
    const latest = one(await ref.get());
    if (!shouldApplySeed(latest, seedVersion, seedHash)) return publicCatalog(latest, seed);
    const revision = Number(latest?.catalogRevision || latest?.version || 0) + 1;
    const payload = {
      version: revision, catalogRevision: revision, seedVersion, seedHash, baseSeedHash: seedHash,
      origin: "seed", experts: seed.experts, starters: seed.starters, ui: seed.ui || null, updatedAt: new Date(),
    };
    if (latest) await ref.update(payload);
    else await ref.set({ _id: "experts", ...payload });
    return publicCatalog(payload, seed);
  });
}

async function saveExpertCatalog({ db, body, seed, seedVersion, seedHash, staff }) {
  if (body?.reset !== true) {
    const error = validateCatalog(body, seed.experts.map(expert => expert.id));
    if (error) return { status: 400, body: { ok: false, error: "BAD_EXPERTS", message: error } };
  }
  try {
    const result = await db.runTransaction(async tx => {
      const ref = tx.collection("bf_config").doc("experts");
      const previous = one(await ref.get());
      const previousRevision = Number(previous?.catalogRevision || previous?.version || 0);
      if (body.expectedRevision != null && Number(body.expectedRevision) !== previousRevision) {
        return { conflict: true, currentRevision: previousRevision };
      }
      const revision = previousRevision + 1;
      if (previous) {
        await tx.collection("bf_config_revisions").doc(`experts_${previousRevision}`).set({
          catalog: previous, archivedAt: new Date(), archivedBy: staff?.sub || "admin",
        });
      }
      const common = {
        version: revision, catalogRevision: revision, seedVersion, baseSeedHash: seedHash,
        updatedAt: new Date(), updatedBy: staff?.sub || "admin",
      };
      const payload = body.reset === true ? {
        ...common, origin: "seed", seedHash, experts: seed.experts, starters: seed.starters, ui: seed.ui || null,
      } : {
        ...common, origin: "admin", seedHash: previous?.seedHash || "",
        experts: body.experts, starters: body.starters || {}, ui: body.ui || null,
      };
      if (previous) await ref.update(payload);
      else await ref.set({ _id: "experts", ...payload });
      return { conflict: false, payload };
    });
    if (result.conflict) return { status: 409, body: { ok: false, error: "EXPERTS_CONFLICT", message: "专家目录已被其他人更新，请刷新后重试", currentRevision: result.currentRevision } };
    return { status: 200, body: { ok: true, version: result.payload.version, catalogRevision: result.payload.catalogRevision, reset: body.reset === true } };
  } catch (error) {
    const code = String(error?.code || error?.message || error);
    if (/conflict/i.test(code)) return { status: 409, body: { ok: false, error: "EXPERTS_CONFLICT", message: "专家目录保存冲突，请刷新后重试" } };
    throw error;
  }
}

module.exports = { validateCatalog, shouldApplySeed, publicCatalog, getExpertCatalog, saveExpertCatalog };
