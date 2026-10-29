"use strict";
const crypto = require("node:crypto");
const COLLECTION = "bf_vendor_bills";
const num = x => x != null && x !== "" && Number.isFinite(Number(x)) ? Number(x) : null;
const text = x => String(x || "").slice(0, 500);
function datesOf(now) {
  return [0,1,2].map(n => new Date(now + 8*3600000 - n*86400000).toISOString().slice(0,10));
}
function normalize(provider, row) {
  if (provider === "aliyun-bailian") return {
    instanceId: text(row.instanceID), product: text(row.productCode), modelDescriptor: text(row.instanceSpec),
    item: text(row.billingItemCode), usage: num(row.usage), usageUnit: text(row.usageUnit), currency: text(row.currency),
    payableAmount: num(row.pretaxAmount), cashPaidAmount: num(row.cashAmount),
    resourcePackageDeduction: num(row.deductedByResourcePackage), couponDeduction: num(row.deductedByCashCoupons),
  };
  return {
    instanceId: text(row.InstanceNo || row.InstanceID), product: text(row.Product), item: text(row.BillingItem),
    usage: num(row.Usage), usageUnit: text(row.UsageUnit), currency: text(row.Currency),
    // No guessed monetary field names: preserve the official row for inspection.
    officialFields: Object.fromEntries(Object.entries(row).filter(([key,value]) =>
      /(amount|price|usage|quantity|count|unit|currency|bill|instance|product|model|apikey|resourcepackage|deduct|discount|coupon|split)/i.test(key)
      && ["string","number","boolean"].includes(typeof value))),
  };
}
function createReaders(env) {
  const readers = {};
  if (env.ALIYUN_BILLING_ACCESS_KEY_ID && env.ALIYUN_BILLING_ACCESS_KEY_SECRET) {
    const sdk = require("@alicloud/bssopenapi20171214"), { Config } = require("@alicloud/openapi-client");
    const client = new sdk.default(new Config({ accessKeyId: env.ALIYUN_BILLING_ACCESS_KEY_ID,
      accessKeySecret: env.ALIYUN_BILLING_ACCESS_KEY_SECRET, securityToken: env.ALIYUN_BILLING_SECURITY_TOKEN || undefined,
      endpoint: "business.aliyuncs.com", connectTimeout: 10000, readTimeout: 20000 }));
    readers["aliyun-bailian"] = async (day, cursor) => {
      const r = await client.describeInstanceBill(new sdk.DescribeInstanceBillRequest({ billingCycle: day.slice(0,7), billingDate: day,
        granularity: "DAILY", isBillingItem: true, maxResults: 100, nextToken: cursor || undefined,
        productCode: env.ALIYUN_BILLING_PRODUCT_CODE || undefined }));
      if (r.body?.code !== "Success") { const error = new Error("Bill read rejected"); error.code = r.body?.code || "INVALID_RESPONSE"; throw error; }
      const data = r.body?.data;
      if (!data || !Array.isArray(data.items)) throw Object.assign(new Error("Missing billing rows"),{code:"INVALID_RESPONSE"});
      return { rows: data.items, next: data.nextToken || null, requestId: r.body.requestId || "" };
    };
  }
  if (env.VOLC_BILLING_ACCESS_KEY_ID && env.VOLC_BILLING_ACCESS_KEY_SECRET) {
    const { Service } = require("@volcengine/openapi");
    const service = new Service({ serviceName: "billing", region: "cn-north-1", protocol: "https", host: "open.volcengineapi.com",
      defaultVersion: "2022-01-01", accessKeyId: env.VOLC_BILLING_ACCESS_KEY_ID,
      secretKey: env.VOLC_BILLING_ACCESS_KEY_SECRET, sessionToken: env.VOLC_BILLING_SECURITY_TOKEN || undefined });
    const query = service.createJSONAPI("ListBillDetail");
    readers.volcengine = async (day, cursor) => {
      const offset = Number(cursor || 0), r = await query({ BillPeriod: day.slice(0,7), ExpenseDate: day,
        Limit: 100, Offset: offset, NeedRecordNum: 1, IgnoreZero: 0 }, { timeout: 20000 });
      if (r.ResponseMetadata?.Error) throw Object.assign(new Error("Bill read rejected"),{code:r.ResponseMetadata.Error.Code || "ACCESS_ERROR"});
      if (!Array.isArray(r.Result?.List)) throw Object.assign(new Error("Missing billing rows"),{code:"INVALID_RESPONSE"});
      const rows = r.Result.List;
      return { rows, next: rows.length === 100 ? offset+100 : null, requestId: r.ResponseMetadata.RequestId || "" };
    };
  }
  return readers;
}
async function collect({ db, env = process.env, now = Date.now(), readers = createReaders(env), log = () => {} }) {
  const deadline = Date.now() + 150000;
  const run = { startedAt: new Date(now), providers: {}, billingLagExpected: true, mutatesMemberBalances: false };
  for (const provider of ["volcengine","aliyun-bailian"]) {
    const reader = readers[provider];
    if (!reader) { run.providers[provider] = { status: "awaiting_credentials", rows: 0 }; continue; }
    let imported = 0;
    try {
      for (const day of datesOf(now)) {
        let cursor = null, rows = [], page = 0, requestId = "";
        do {
          if (Date.now() > deadline) throw Object.assign(new Error("Bill import budget exceeded"),{code:"IMPORT_BUDGET_LIMIT"});
          const result = await reader(day, cursor); cursor = result.next; requestId = text(result.requestId);
          rows.push(...result.rows.map(row => normalize(provider,row))); page++;
          if (page >= 10 && cursor != null) throw Object.assign(new Error("Bill pagination incomplete"),{code:"PAGINATION_LIMIT"});
        } while (cursor != null);
        const snapshot = { provider, day, granularity: "vendor_aggregate", rows, rowCount: rows.length, complete: true,
          importedAt: new Date(), importStartedAt: new Date(now), vendorRequestId: requestId,
          finalSettlement: false, reconciliationState: "aggregate_only_not_per_user" };
        if (Buffer.byteLength(JSON.stringify(snapshot)) > 800000) throw Object.assign(new Error("Bill snapshot too large"),{code:"SNAPSHOT_SIZE_LIMIT"});
        const id = crypto.createHash("sha256").update(provider+"\0"+day).digest("hex");
        // A complete new snapshot replaces the same day's previous provisional bill, never adds it twice.
        await db.runTransaction(async tx => {
          const ref = tx.collection(COLLECTION).doc(id), result = await ref.get();
          const previous = Array.isArray(result.data) ? result.data[0] : result.data;
          if (!previous || new Date(previous.importStartedAt).getTime() <= now) await ref.set(snapshot);
        }); imported += rows.length;
      }
      run.providers[provider] = { status: "read_verified", rows: imported };
    } catch (error) {
      const code = String(error.code || error.name || "BILL_READ_FAILED").replace(/[^a-zA-Z0-9_.:-]/g, "").slice(0,100);
      run.providers[provider] = { status: "read_failed", code, rows: imported };
      log({tag:"supplier_bill_import_failed",provider,code});
    }
  }
  run.endedAt = new Date();
  await db.collection("bf_config").doc("billing_import_status").set(run);
  return run;
}
module.exports = { collect, createReaders, normalize, datesOf, COLLECTION };
