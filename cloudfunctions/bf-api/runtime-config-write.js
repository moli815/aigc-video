"use strict";
const crypto=require('node:crypto'),{documentOf}=require('./shared/document-store');
function version(doc){if(!doc)return null;const data=doc.data||{},sorted=Object.fromEntries(Object.keys(data).sort().map(k=>[k,data[k]]));return JSON.stringify([String(doc.revision||''),doc.updatedAt?new Date(doc.updatedAt).getTime():null,crypto.createHash('sha256').update(JSON.stringify(sorted)).digest('hex')]);}
async function commit({db,collection,baseline,next}){
 return db.runTransaction(async tx=>{const ref=tx.collection(collection).doc('runtime'),current=documentOf(await ref.get());
  if(version(current)!==version(baseline))return{ok:false,conflict:true};
  if(current)await ref.update(next);else await ref.set(next);
  return{ok:true};
 });
}
module.exports={commit,version};
