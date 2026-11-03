"use strict";
const crypto=require("crypto");
// Sync v2 record identity. Caller supplies the protocol-normalized UUID.
function syncRecordKey(owner,kind,id) {
  return crypto.createHash("sha256").update(owner+"|"+kind+"|"+id).digest("hex").slice(0,40);
}
module.exports={syncRecordKey};
