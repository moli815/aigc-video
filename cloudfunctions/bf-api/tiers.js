// ============================================================================
// tiers.js —— 档位配置的纯合并函数（无 IO、无全局状态）
//
// 抽出来的目的：
//   1. bf-api/index.js 有 tcb.init 等顶层副作用，测试不能直接 require；
//   2. "A 覆盖 → B 覆盖 → 删除覆盖 → 恢复默认" 这条序列必须有真实测试，
//      而它本质是纯数据变换，不需要数据库。
// ============================================================================

/**
 * 从不可变基线重建档位，再叠加一层覆盖。
 *
 * 设计要点：
 *  - 每次都从 base 深拷贝，绝不修改 base，也绝不读取上一次的结果；
 *  - features 单独深拷贝，避免与 base 共享引用；
 *  - 覆盖值为非法/空时"忽略该字段"，而不是写入空值 ——
 *    这样"删掉某个覆盖项"就等于回到默认；
 *  - 不在 override 里出现的字段一律用默认值（不是上一次的值）。
 *
 * @param {object} base    不可变基线（DEFAULT_TIERS 的深拷贝来源）
 * @param {object} override DB 里的 TIERS_OVERRIDE（可能是 null / 非法对象）
 * @param {string[]} order 档位键顺序
 * @returns {object} 新对象，键为档位 key
 */
function computeTiers(base, override, order) {
  const keys = Array.isArray(order) && order.length ? order : Object.keys(base || {});
  const ov = (override && typeof override === "object") ? override : {};
  const out = {};
  for (const k of keys) {
    const d = base && base[k];
    if (!d) continue;
    const t = {
      key: d.key,
      name: d.name,
      priceCny: d.priceCny,
      poolCapCny: d.poolCapCny,
      qrFile: d.qrFile,
      visible: d.visible,
      // 深拷贝：不共享 base.features 的引用
      features: Object.assign({}, d.features),
    };
    const o = ov[k];
    if (o && typeof o === "object") {
      if (Number.isFinite(Number(o.priceCny)) && Number(o.priceCny) > 0) t.priceCny = Number(o.priceCny);
      if (Number.isFinite(Number(o.poolCapCny)) && Number(o.poolCapCny) > 0) t.poolCapCny = Number(o.poolCapCny);
      if (typeof o.visible === "boolean") t.visible = o.visible;
      if (typeof o.qrFile === "string" && /^[\w\-./:]{1,200}$/.test(o.qrFile)) t.qrFile = o.qrFile;
      if (o.features && typeof o.features === "object") t.features = Object.assign({}, t.features, o.features);
    }
    out[k] = t;
  }
  return out;
}

/** 把计算好的档位写回目标对象（原地，保持引用稳定，避免各处引用失效） */
function applyTiersInto(target, next, order) {
  const keys = Array.isArray(order) && order.length ? order : Object.keys(next || {});
  for (const k of keys) {
    if (!next || !next[k] || !target || !target[k]) continue;
    const t = target[k];
    const n = next[k];
    t.key = n.key;
    t.name = n.name;
    t.priceCny = n.priceCny;
    t.poolCapCny = n.poolCapCny;
    t.qrFile = n.qrFile;
    t.visible = n.visible;
    t.features = Object.assign({}, n.features);
  }
}

module.exports = { computeTiers, applyTiersInto };
