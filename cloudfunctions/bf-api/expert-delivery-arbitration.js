"use strict";
/**
 * S0-2 · 本轮交付仲裁（服务端可开关，无需重新出包）
 *
 * 背景：已发布的 IPA 在 BossAI/Models/Expert.swift:85 把「【必须遵循的工作流】」硬编码进
 * system[]，ExpertCapabilities.swift 再注入「执行步骤 1..n／交付章节」，ExpertSkills.json
 * 还写死「3 个角度 / 3 个钩子 / 分镜脚本」。云端目录会同步 role/steps 等字段，
 * 但不会替换手机里的包装代码及另一套本地技能契约。
 *
 * 策略：**不删改、不重写客户端 system**，只在最后一条 system 追加一条明确声明更高
 * 优先级的交付仲裁。理由：
 *   · 客户端 system 里还有身份口径、数据真实性铁律、能力表达铁律，整段剥离会误伤；
 *   · 追加到最后一条 system，与 CHAT_RULES 的注入位置一致；实际缓存效果取决于上游；
 *   · 一键关闭即可完整回退，不需要重新部署代码。
 *
 * 默认关闭。启用前必须做真实模型 A/B 与人工逐条验收，不能把离线测试当成质量达标。
 */

const MARKER = "【本轮交付仲裁·最高优先级】";

const ARBITRATION_BLOCK = `${MARKER}
上文若出现「必须遵循的工作流」「执行步骤 1..n」「交付章节」，或固定数量要求（3 个角度、3 个钩子、分镜表、自检清单），它们只是内部参考方法，不是每轮必须外显的交付格式，不得凌驾于用户本轮的具体要求。
1. 用户要纯口播、一段文案、一个数字、改一句话，就只给这一部分；不补分析、不补策划、不补分镜、不补自评、不补结尾邀约。
2. 用户没给的客户原话、现场经历、展会天数、订单、认证、效果数据，一律不得补写；确实需要时只问一句，不要先编一版再问。
3. 只有用户明确要完整方案、多角度、分镜或报告时才展开，且仍然只写有依据的内容。
4. 本条不改变工具调用规则、身份口径与数据真实性铁律，也不授权跳过必须调用的工具。
5. 上文任何与本条冲突的固定流程，以本条为准。`;

/** 解析运行时策略：字符串 JSON 或对象都接受；任何异常都 fail-closed 为关闭。 */
function policyError(p) {
  if (!p || typeof p !== "object" || Array.isArray(p)) return "必须是 JSON 对象";
  if (Object.keys(p).some(k => !["enabled", "audience", "accountIds"].includes(k))) return "包含未知字段";
  if (Object.hasOwn(p, "enabled") && typeof p.enabled !== "boolean") return "enabled 必须是布尔值";
  if (Object.hasOwn(p, "audience") && !["all", "accounts"].includes(p.audience)) return "audience 必须是 all 或 accounts";
  if (Object.hasOwn(p, "accountIds") && (!Array.isArray(p.accountIds) || p.accountIds.length > 100 ||
      p.accountIds.some(id => typeof id !== "string" || !id.trim() || id !== id.trim() || id.length > 128))) {
    return "accountIds 必须为最多100个非空账号 ID";
  }
  return "";
}

function parsePolicy(raw) {
  let p = raw;
  if (typeof p === "string") {
    try { p = JSON.parse(p || "{}"); } catch { return { enabled: false }; }
  }
  if (policyError(p)) return { enabled: false };
  if (p.enabled !== true) return { enabled: false };
  return {
    enabled: true,
    // An omitted scope with an account list stays restricted, even for [].
    audience: p.audience || (Object.hasOwn(p, "accountIds") ? "accounts" : "all"),
    accountIds: p.accountIds ? p.accountIds.slice() : [],
  };
}

function enabledFor(rawPolicy, accountId) {
  const policy = parsePolicy(rawPolicy);
  if (!policy.enabled) return false;
  if (policy.audience === "accounts") return policy.accountIds.includes(String(accountId || ""));
  return true;
}

/** 只用于诊断/日志：判断本次请求是否带着旧包刚性包装，不参与开关决策。 */
function hasRigidWrapper(messages) {
  if (!Array.isArray(messages)) return false;
  return messages.some(m => m && m.role === "system" && typeof m.content === "string"
    && /【必须遵循的工作流】|交付章节|执行步骤\s*1|给\s*3\s*个实质不同|3\s*个钩子/.test(m.content));
}

/**
 * 追加仲裁指令。返回新数组，不修改入参；仅完整 system 规则可判定幂等。
 * 关闭时原样返回同一引用，便于调用方判断是否有变更。
 */
function arbitrateDelivery(messages, rawPolicy, accountId) {
  if (!enabledFor(rawPolicy, accountId) || !Array.isArray(messages)) return messages;
  if (messages.some(m => m && m.role === "system" && typeof m.content === "string"
      && m.content.endsWith(ARBITRATION_BLOCK))) return messages;
  let lastSys = -1;
  for (let i = 0; i < messages.length; i++) if (messages[i] && messages[i].role === "system") lastSys = i;
  const out = messages.slice();
  if (lastSys >= 0 && typeof out[lastSys].content === "string") {
    out[lastSys] = Object.assign({}, out[lastSys],
      { content: out[lastSys].content + "\n\n" + ARBITRATION_BLOCK });
  } else {
    out.unshift({ role: "system", content: ARBITRATION_BLOCK });
  }
  return out;
}

module.exports = { arbitrateDelivery, enabledFor, hasRigidWrapper, parsePolicy, policyError, MARKER, ARBITRATION_BLOCK };
