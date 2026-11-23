"use strict";
// CloudBase normal DocumentReference.get returns data: [doc], whereas a
// transaction document read returns data: doc. Keep that SDK boundary in one place.
function documentOf(result) {
  const data = result && result.data;
  if (Array.isArray(data)) return data[0] || null;
  return data && typeof data === "object" ? data : null;
}
module.exports = { documentOf };
