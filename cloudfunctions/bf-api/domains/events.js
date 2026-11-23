"use strict";
const crypto = require("crypto");
const FIELD_LIMITS = Object.freeze({ traceId: 100, requestId: 100, jobId: 100, turnId: 100,
  appBuild: 40, domain: 40, stage: 60, errorCode: 80, model: 100, ratio: 30,
  billingState: 40, archiveState: 40, platform: 30 });
function normalizeEvent(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Error("INVALID_EVENT");
  const eventId = String(raw.eventId || "");
  if (!/^[a-zA-Z0-9_-]{12,100}$/.test(eventId)) throw new Error("INVALID_EVENT_ID");
  const out = { eventId };
  for (const [key, limit] of Object.entries(FIELD_LIMITS)) {
    if (typeof raw[key] === "string") out[key] = raw[key].replace(/[^a-zA-Z0-9_.:/ -]/g, "").slice(0, limit);
  }
  for (const key of ["attempt", "sourceCount", "durationMs"]) {
    const value = typeof raw[key] === "string" && /^\d+(\.\d+)?$/.test(raw[key]) ? Number(raw[key]) : raw[key];
    if (Number.isFinite(value) && value >= 0) out[key] = Math.min(value, 1e9);
  }
  if (typeof raw.retryable === "boolean") out.retryable = raw.retryable;
  return out;
}
function createEventService({ db, collection = "bf_tool_events" }) {
  return {
    async receive(accountId, rawEvents) {
      if (!Array.isArray(rawEvents) || rawEvents.length > 25) throw new Error("INVALID_EVENT_BATCH");
      const events = rawEvents.map(normalizeEvent);
      const accepted = [];
      for (const event of events) {
        const id = crypto.createHash("sha256").update(accountId + ":" + event.eventId).digest("hex").slice(0, 40);
        const ref = db.collection(collection).doc(id);
        const existing = await ref.get();
        if (!(existing.data || []).length) {
          try { await db.collection(collection).add({ _id: id, accountId, ...event,
            tool: event.domain || "app", reason: event.errorCode || "event", ts: Date.now() }); }
          catch (error) {
            const confirmed = await ref.get();
            if (!(confirmed.data || []).length) throw error;
          }
        }
        accepted.push(event.eventId);
      }
      return accepted;
    },
  };
}
module.exports = { normalizeEvent, createEventService };
