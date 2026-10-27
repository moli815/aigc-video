"use strict";
// Omission is not a documented 'disable optimization' switch. Keep provider mode
// separate from our own prompt preparation and never claim constraints are immutable.
function providerPromptOptions(model, routingMode, fastMode) {
  if (routingMode === "pro_only") return { mode: "standard" };
  const supportsFast = /seedream-(5-0-pro|4-0)-/.test(String(model));
  return { mode: supportsFast && String(fastMode) === "1" ? "fast" : "standard" };
}
module.exports = { providerPromptOptions };
