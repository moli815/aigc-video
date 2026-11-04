"use strict";
const fs=require("node:fs"),path=require("node:path"),crypto=require("node:crypto");
const {policyOf,eligible,compose}=require("./commercial-composer");
const {boundedBytes}=require("./shared/asset-store");
const {probeImageSize,decodedSizeAllowed}=require("./media-guards");
const EMPTY="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==";
function hash(bytes){return crypto.createHash("sha256").update(bytes).digest("hex");}
function error(code){return Object.assign(new Error(code),{code});}
let enginesPromise;
async function loadEngines(){
  if(!enginesPromise)enginesPromise=(async()=>{
    const satori=require("satori").default,resvg=require("@resvg/resvg-wasm");
    await resvg.initWasm(fs.readFileSync(path.join(path.dirname(require.resolve("@resvg/resvg-wasm")),"index_bg.wasm")));
    return {satori,resvg};
  })().catch(e=>{enginesPromise=null;throw e;});
  return enginesPromise;
}
function createCommercialComposition({app,assetStore,fetcher=fetch,log=()=>{},engines=loadEngines}){
  let fontCache=null,queue=Promise.resolve();
  const exclusive=fn=>{const next=queue.then(fn,fn);queue=next.then(()=>{},()=>{});return next;};
  async function getFonts(policy){
    const key=policy.fonts.map(f=>f.sha256+":"+f.weight).join("|");
    if(fontCache?.key===key)return fontCache.fonts;
    if(policy.fonts.length!==2||!policy.fonts.some(f=>f.weight===400)||!policy.fonts.some(f=>f.weight===700))throw error("COMPOSITION_FONTS_NOT_READY");
    const fonts=[];
    for(const spec of policy.fonts){
      const signed=await app.getTempFileURL({fileList:[{fileID:spec.fileId,maxAge:60,urlType:"COS_URL"}]});
      const url=signed?.fileList?.[0]?.tempFileURL;
      if(!url)throw error("COMPOSITION_FONT_UNAVAILABLE");
      const data=await boundedBytes(url,20*1024*1024,fetcher);
      if(hash(data)!==spec.sha256)throw error("COMPOSITION_FONT_HASH_MISMATCH");
      fonts.push({name:"Noto CJK",weight:spec.weight,style:"normal",data});
    }
    fontCache={key,fonts};return fonts;
  }
  return {
    async prepare(input,rawPolicy){
      const policy=policyOf(rawPolicy);if(!eligible(input,policy))return null;
      const dimensions=String(input.resolvedSize).match(/^(\d+)x(\d+)$/);
      const width=dimensions?Number(dimensions[1]):2048,height=dimensions?Number(dimensions[2]):2048;
      return exclusive(async()=>{
        const fonts=await getFonts(policy);
        const {satori,resvg}=await engines();
        const rendering=await compose({structured:input.structured,prompt:input.prompt,width,height,fonts,background:EMPTY,satori,resvg});
        const fallback=await compose({structured:input.structured,prompt:input.prompt,width,height,fonts,satori,resvg});
        log({event:"prepared",itemCount:rendering.manifest.itemCount,fontSize:rendering.manifest.fontSize,copyHash:rendering.manifest.copyHash});
        return {input,width,height,fonts,fallback:fallback.png,fallbackManifest:fallback.manifest,manifest:rendering.manifest};
      });
    },
    async finish(prepared,url,owner){
      return exclusive(async()=>{
        let png=prepared.fallback,manifest=prepared.fallbackManifest,fallback=false,backgroundAsset;
        let artworkStage="download";
        try{
          const bytes=await boundedBytes(url,24*1024*1024,fetcher);
          artworkStage="decode";
          const size=probeImageSize(bytes);if(!size||!decodedSizeAllowed(size))throw error("COMPOSITION_BACKGROUND_INVALID");
          const mime=bytes[0]===137?"image/png":"image/jpeg";
          if(mime==="image/jpeg"&&!(bytes[0]===255&&bytes[1]===216))throw error("COMPOSITION_BACKGROUND_INVALID");
          try{backgroundAsset=await assetStore.archive(owner,bytes,mime);}catch{log({event:"background_archive_unavailable"});}
          artworkStage="render";
          const {satori,resvg}=await engines();
          const rendered=await compose({structured:prepared.input.structured,prompt:prepared.input.prompt,width:prepared.width,height:prepared.height,fonts:prepared.fonts,
            background:"data:"+mime+";base64,"+bytes.toString("base64"),satori,resvg});
          if(rendered.manifest.copyHash!==prepared.manifest.copyHash)throw error("COMPOSITION_COPY_CHANGED");
          png=rendered.png;manifest=rendered.manifest;
        }catch{fallback=true;log({event:"artwork_fallback",reason:"BACKGROUND_OR_RENDER_UNAVAILABLE",artworkStage,copyHash:manifest.copyHash});}
        // Archiving is content-addressed and account-scoped; retry storage only,
        // never call the image provider again for a rendering/upload problem.
        let asset,lastError;
        for(let i=0;i<2;i++)try{asset=await assetStore.archive(owner,png,"image/png");break;}catch(e){lastError=e;}
        if(!asset)throw error("COMPOSITION_ARCHIVE_UNAVAILABLE");
        if(backgroundAsset)asset={...asset,variants:{background:backgroundAsset}};
        const signed=await assetStore.sign(owner,[asset.id]);if(!signed?.[0]?.url)throw error("COMPOSITION_ARCHIVE_UNAVAILABLE");
        log({event:"completed",itemCount:manifest.itemCount,fontSize:manifest.fontSize,copyHash:manifest.copyHash,fallback});
        return {url:signed[0].url,asset,composition:{version:manifest.version,copyHash:manifest.copyHash,typographyFallback:fallback}};
      });
    }
  };
}
module.exports={createCommercialComposition,loadEngines,EMPTY};
