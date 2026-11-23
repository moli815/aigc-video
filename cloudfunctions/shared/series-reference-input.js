"use strict";
const crypto=require("crypto"),{contractOf}=require("./image-reference-store");
function referenceRequestFingerprint(raw) {
  if(raw==null)return "";
  const normalized=contractOf(raw);
  if(normalized.mode!=="replace")throw Error("IMAGE_REFERENCE_MODE_UNSUPPORTED");
  return crypto.createHash("sha256").update(JSON.stringify(normalized)).digest("hex");
}
async function prepareSeriesReferenceInput({store,owner,structured,image}) {
  const raw=structured?.image_references,fingerprint=referenceRequestFingerprint(raw);
  if(!fingerprint)return {referenceManifest:null,referenceFingerprint:""};
  // An explicit complete historical list cannot silently discard a raw base.
  // Mixed current/history references require a separately verified append path.
  if(image)throw Error("IMAGE_REFERENCE_MODE_UNSUPPORTED");
  return {referenceManifest:await store.prepare(owner,raw),referenceFingerprint:fingerprint};
}
async function resolveSeriesReferenceInput({store,owner,manifest,image}) {
  if(!manifest)return {image,referenceRoles:undefined};
  if(manifest.mode!=="replace"||image)throw Error("IMAGE_REFERENCE_MODE_UNSUPPORTED");
  const signed=await store.sign(owner,manifest);
  return {image:signed.map(i=>i.url),referenceRoles:signed.map(i=>i.role)};
}
module.exports={referenceRequestFingerprint,prepareSeriesReferenceInput,resolveSeriesReferenceInput};
