"use strict";
const { COLLECTION } = require("../shared/model-call-ledger");

/**
 * 状态筛选白名单。
 * 台账里真实出现的 status 是 succeeded / cached / pending / rejected / partial / not_dispatched / outcome_unknown，
 * 没有 "failed" 这个值——"失败"是这四种的集合，必须按集合查，不能写 status="failed"。
 */
const STATUS_FILTERS = {
  failed: ["rejected", "partial", "not_dispatched", "outcome_unknown"],
  rejected: ["rejected"],
  partial: ["partial"],
  not_dispatched: ["not_dispatched"],
  outcome_unknown: ["outcome_unknown"],
  succeeded: ["succeeded"],
  cached: ["cached"],
  pending: ["pending"],
};

function parseQuery(params, now = Date.now()) {
  const end = params.get("end") ? Date.parse(params.get("end")) : now;
  const start = params.get("start") ? Date.parse(params.get("start")) : end - 7 * 86400000;
  const page = Number(params.get("page") || 0), limit = Number(params.get("limit") || 50);
  const accountId = params.get("accountId") || "", orderId = params.get("orderId") || "";
  const statusKey = String(params.get("status") || "all").trim().toLowerCase();
  if (statusKey !== "all" && !STATUS_FILTERS[statusKey]) {
    const error = new Error("状态筛选只支持 all / failed / rejected / partial / not_dispatched / outcome_unknown / succeeded / cached / pending。");
    error.code = "BAD_QUERY";
    throw error;
  }
  if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start || end - start > 31 * 86400000
    || !Number.isInteger(page) || page < 0 || page > 100 || !Number.isInteger(limit) || limit < 1 || limit > 100
    || (accountId && !/^[\w-]{1,100}$/.test(accountId)) || (orderId && !/^ord_[a-f0-9]{32}$/.test(orderId))) {
    const error = new Error("调用明细查询条件不正确，请使用31天以内的时间范围。"); error.code = "BAD_QUERY"; throw error;
  }
  return { start, end, page, limit, accountId, orderId, statusKey, statuses: STATUS_FILTERS[statusKey] || null };
}

async function queryCalls(db, params) {
  const q = parseQuery(params);
  const filter = { startedAt: db.command.gte(new Date(q.start)).and(db.command.lt(new Date(q.end))) };
  if (q.accountId) filter.accountId = q.accountId;
  if (q.orderId) filter.orderId = q.orderId;
  if (q.statuses) filter.status = q.statuses.length === 1 ? q.statuses[0] : db.command.in(q.statuses);
  const result = await db.collection(COLLECTION).where(filter).orderBy("startedAt", "desc")
    .skip(q.page * q.limit).limit(q.limit + 1).get();
  const rows = result.data || [];
  return { ok: true, rows: rows.slice(0, q.limit), page: q.page, hasMore: rows.length > q.limit,
    status: q.statusKey,
    note: "supplierCostEstimateCny为估算成本，supplierBilledCny仅在官方账单核对后填写；空值表示未知。priceCny为本系统实际计入用户额度的金额。" };
}
module.exports = { parseQuery, queryCalls, STATUS_FILTERS };
