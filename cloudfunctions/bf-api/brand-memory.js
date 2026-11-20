"use strict";

/**
 * 品牌事实记忆（Brand Memory）
 *
 * 背景：原有 memory-extraction 只认「电话统一用…」「公司全称是…」这类固定句式，
 * 用户在自然对话里说的「把我们公司的全国服务热线 400-7758-119 加上去」
 * 会被整句丢掉。结果是：客户说过三次公司名和热线，系统一次都没记住。
 *
 * 这里做的是**确定性抽取**（不靠模型判断）：
 *   - 公司全称：…有限公司 / 有限责任公司 / 股份有限公司
 *   - 联系电话：400/800 热线、固话、手机号
 *   - Logo 要求：出现 logo/标志 且带「以后/每次/都要/必须/记住/固定」这类长期语气
 * 扫到就通过同步服务写入长期记忆（kind=memory），客户端下次拉取就能看到。
 *
 * 原则：
 *   - 只扫用户自己说的话，不扫助手的话（避免把模型编的东西记成事实）
 *   - 同一个值只记一次：refId 由「类别+值」哈希得到，重复写会被同步服务判为同一记录
 *   - 整个动作有 800ms 上限，超时就放弃；记忆是增强，不能拖慢对话
 */

const crypto = require("crypto");

const COMPANY = /[\u4e00-\u9fa5（）()·]{2,28}?(?:有限责任公司|股份有限公司|有限公司)/g;
const PHONE = /(?:400|800)[-\s]?\d{3,4}[-\s]?\d{3,4}|0\d{2,3}[-\s]?\d{7,8}|1[3-9]\d{9}/g;
const LOGO_WORD = /(logo|LOGO|Logo|标志|标识)/;
const LOGO_DURABLE = /(以后|今后|每次|每次都要|都要|必须|记住|固定|统一|一律|始终)/;
// 明显是在举例/假设的句子不记
const NOT_A_FACT = /(假设|假如|比如|例如|举例|演示|举个例子|仅供参考|如果.*就)/;

function textOf(message) {
  const c = message && message.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return c.filter(p => p && p.type === "text").map(p => p.text || "").join("\n");
  return "";
}

function sentences(text) {
  return String(text || "").split(/[。！!；;\n]/).map(s => s.trim()).filter(Boolean);
}

/**
 * 从本轮用户消息里抽品牌事实。
 * @returns {{company?:string, phone?:string, logo?:boolean}}
 */
function scan(messages) {
  const userText = (Array.isArray(messages) ? messages : [])
    .filter(m => m && m.role === "user")
    .slice(-6)
    .map(textOf)
    .join("\n");
  if (!userText) return {};

  const facts = {};
  // 举例/假设的句子整句跳过，避免把「测试有限公司」记成客户公司
  const clean = sentences(userText).filter(s => !NOT_A_FACT.test(s)).join("\n");

  const companies = clean.match(COMPANY) || [];
  if (companies.length) {
    // 取最长的一个，再去掉「我们公司全称是」这类前缀
    const longest = companies.sort((a, b) => b.length - a.length)[0].trim();
    facts.company = longest.replace(/^.*?(?:全称|名称|名字|公司名)?\s*(?:是|为|叫|：|:)\s*/, "").trim() || longest;
  }

  const phones = clean.match(PHONE) || [];
  if (phones.length) {
    // 同一轮出现多个号码时取最后一个（用户通常在纠正/补充）
    facts.phone = phones[phones.length - 1].replace(/\s+/g, "");
  }

  for (const s of sentences(clean)) {
    if (LOGO_WORD.test(s) && LOGO_DURABLE.test(s)) { facts.logo = true; break; }
  }

  return facts;
}

/** 事实 → 记忆文本（保持和现有记忆同一种叙述风格） */
function toMemories(facts) {
  const out = [];
  if (facts.company) out.push({ key: "company", text: `公司全称：${facts.company}（用户在对话中确认过，凡涉及公司署名一律用这个全称）` });
  if (facts.phone) out.push({ key: "phone", text: `公司联系方式：全国服务热线 ${facts.phone}（用户在对话中提供过，宣传物料需要印联系方式时用这个号码）` });
  if (facts.logo) out.push({ key: "logo", text: "Logo 要求：任何海报、宣传物料都必须使用用户提供的公司 Logo，不得遗漏，也不要画一个近似的替代图形。" });
  return out;
}

const refIdOf = (key, value) =>
  crypto.createHash("sha256").update(`brand|${key}|${value}`).digest("hex").slice(0, 32)
    .replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, "$1-$2-$3-$4-$5");

/**
 * 把本轮扫到的品牌事实写进长期记忆。失败一律静默，不影响对话。
 */
async function remember({ db, owner, messages, timeoutMs = 800 }) {
  if (!db || !owner) return { saved: 0 };
  const facts = scan(messages);
  const items = toMemories(facts);
  if (!items.length) return { saved: 0, facts };

  const work = (async () => {
    const { createSyncService } = require("./domains/sync-v2");
    const svc = createSyncService({ db });
    let saved = 0;
    for (const item of items) {
      const refId = refIdOf(item.key, item.text);
      try {
        const res = await svc.push(owner, [{
          kind: "memory", refId, updatedAt: Date.now(), baseVersion: 0,
          payload: { id: refId, text: item.text, source: "brand-memory" },
        }]);
        if (res && (res.acknowledged || []).length) saved++;
      } catch (e) { /* 单条失败不影响其他 */ }
    }
    return { saved, facts };
  })();

  return Promise.race([
    work,
    new Promise(resolve => setTimeout(() => resolve({ saved: 0, facts, timeout: true }), timeoutMs)),
  ]);
}

module.exports = { scan, toMemories, remember, refIdOf };
