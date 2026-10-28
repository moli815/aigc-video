"use strict";

// Missing/invalid dates must not create perpetual membership. Exact expiry denies.
function membershipExpired(value, now = Date.now()) {
  if (value == null || value === "" || typeof value === "boolean") return true;
  if (!(value instanceof Date) && typeof value !== "string" && typeof value !== "number") return true;
  const expiry = new Date(value).getTime();
  return !Number.isFinite(expiry) || !Number.isFinite(now) || expiry <= now;
}
module.exports = { membershipExpired };
