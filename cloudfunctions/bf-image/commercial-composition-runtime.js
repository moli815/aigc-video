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
    async nativeResources(rawPolicy){
      return exclusive(async()=>{const p=policyOf(rawPolicy);if(!p.enabled)throw error('COMPOSITION_NOT_ENABLED');await getFonts(p);await engines();return{fontRevision:hash(Buffer.from(JSON.stringify(p.fonts.map(f=>({sha256:f.sha256,weight:f.weight})))))};});
    },
    async renderNative(input,rawPolicy){
      return exclusive(async()=>{
        const p=policyOf(rawPolicy),fonts=await getFonts(p),loaded=await engines();
        const prepared=typeof input.load==='function'?await input.load():input;
        return require('./native-copy-refinement').refine({...prepared,fonts,...loaded});
      });
    },
    async nativeSerial(work){return exclusive(work);},
    async prepareProduct(input,rawPolicy,protectedSources){
      const policy=policyOf(rawPolicy),dims=String(input.resolvedSize).match(/^(\d+)x(\d+)$/);if(!dims)throw error("COMPOSITION_CANVAS_INVALID");
      if(!policy.enabled)throw error("COMPOSITION_NOT_ENABLED");
      const width=Number(dims[1]),height=Number(dims[2]);
      return exclusive(async()=>{
        const fonts=await getFonts(policy),{satori,resvg}=await engines();
        const assets=protectedSources.selected.filter(p=>["ui","logo","catalog"].includes(p.role)).map(p=>({index:p.index,role:p.role,sha256:p.sha256,aspect:p.aspect,src:"data:image/png;base64,"+require("pngjs").PNG.sync.write(p.preparedRaster).toString("base64")}));
        // Measured fit and source count validation happen before a paid image.
        const fallback=await compose({structured:input.structured,prompt:input.prompt,width,height,fonts,satori,resvg,designEngine:"product_v2",assets});
        return {input,width,height,fonts,assets,designEngine:"product_v2",manifest:fallback.manifest,fallback:fallback.png};
      });
    },
    async finishProduct(prepared,url,owner){
      return exclusive(async()=>{
        const bytes=await boundedBytes(url,24*1024*1024,fetcher),size=probeImageSize(bytes);if(!size||!decodedSizeAllowed(size))throw error("COMPOSITION_BACKGROUND_INVALID");
        const mime=bytes[0]===137?"image/png":"image/jpeg",{satori,resvg}=await engines();
        const rendered=await compose({structured:prepared.input.structured,prompt:prepared.input.prompt,width:prepared.width,height:prepared.height,fonts:prepared.fonts,satori,resvg,assets:prepared.assets,designEngine:"product_v2",background:"data:"+mime+";base64,"+bytes.toString("base64")});
        if(rendered.manifest.copyHash!==prepared.manifest.copyHash)throw error("COMPOSITION_COPY_CHANGED");
        const background=await assetStore.archive(owner,bytes,mime),asset=await assetStore.archive(owner,rendered.png,"image/png"),signed=await assetStore.sign(owner,[asset.id]);if(!signed?.[0]?.url)throw error("COMPOSITION_ARCHIVE_UNAVAILABLE");
        log({event:"product_composed",copyHash:rendered.manifest.copyHash,design:rendered.manifest.design,assets:rendered.manifest.assets.length,fontSize:rendered.manifest.fontSize});
        return {url:signed[0].url,asset:{...asset,variants:{background}},composition:rendered.manifest};
      });
    },
    async prepare(input,rawPolicy){
      // 真字体文字层：版式先定、Seedream 照草图出无字底图、文字服务端叠。
      // 判定与配色在 overlay-pipeline，此处只负责调引擎与产出草图。
      if(require("./overlay-pipeline").eligible(rawPolicy,input.accountId,input)){
        const dims=String(input.resolvedSize||"").match(/^(\d+)x(\d+)$/);
        const width=dims?Number(dims[1]):2048,height=dims?Number(dims[2]):2048;
        return exclusive(async()=>{
          const policy=policyOf(rawPolicy),fonts=await getFonts(policy),{satori,resvg}=await engines();
          const pipe=require("./overlay-pipeline"),edge=require("./poster-overlay");
          const layout=pipe.inferLayout(input.structured,input.prompt,width,height);
          const svg=await satori(edge.sketchTree(layout,width,height),{width,height,fonts});
          const sketchPng=Buffer.from(new resvg.Resvg(svg,{fitTo:{mode:"width",value:width}}).render().asPng());
          log({event:"overlay_prepared",cols:layout.grid.cols,rows:layout.grid.rows,sketchBytes:sketchPng.length,header:layout.header,footer:layout.footer});
          return {engine:"overlay",input,width,height,fonts,layout,blocks:input.structured.text,
            sketch:"data:image/png;base64,"+sketchPng.toString("base64"),
            prompt:pipe.baseImagePrompt(layout,input.structured,input.prompt)};
        });
      }
      const policy=policyOf(rawPolicy);if(!eligible({...input,generationPolicy:rawPolicy},policy))return null;
      const dimensions=String(input.resolvedSize).match(/^(\d+)x(\d+)$/);
      const designEngine=require("./commercial-design-plan").designEnabled(policy,input.accountId)?"poster":"legacy";
      const width=dimensions?Number(dimensions[1]):2048,height=dimensions?Number(dimensions[2]):2048;
      return exclusive(async()=>{
        const fonts=await getFonts(policy);
        const {satori,resvg}=await engines();
        let actualEngine=designEngine,rendering;
        try{rendering=await compose({structured:input.structured,prompt:input.prompt,width,height,fonts,background:EMPTY,satori,resvg,designEngine:actualEngine});}
        catch(e){if(actualEngine!=="poster"||e?.code!=="COMPOSITION_CONTENT_OVERFLOW")throw e;
          actualEngine="legacy";log({event:"design_fallback",reason:"POSTER_CAPACITY_EXCEEDED"});
          rendering=await compose({structured:input.structured,prompt:input.prompt,width,height,fonts,background:EMPTY,satori,resvg,designEngine:actualEngine});}

        const fallback=await compose({structured:input.structured,prompt:input.prompt,width,height,fonts,satori,resvg,designEngine:actualEngine});
        log({event:"prepared",design:rendering.manifest.design,engine:actualEngine,itemCount:rendering.manifest.itemCount,fontSize:rendering.manifest.fontSize,copyHash:rendering.manifest.copyHash});
        return {input,width,height,fonts,designEngine:actualEngine,fallback:fallback.png,fallbackManifest:fallback.manifest,manifest:rendering.manifest};
      });
    },
    async finish(prepared,url,owner){
      if(prepared&&prepared.engine==="overlay")return exclusive(async()=>{
        const bytes=await boundedBytes(url,24*1024*1024,fetcher);
        const size=probeImageSize(bytes);if(!size)throw error("COMPOSITION_BACKGROUND_INVALID");
        const {satori,resvg}=await engines(),PNG=require("pngjs").PNG,edge=require("./poster-overlay");
        const bg=size.width===prepared.width&&size.height===prepared.height?bytes:await edge.fitToCanvas(bytes,prepared.width,prepared.height,{resvg});
        const png=await edge.composeOnBackground({layout:prepared.layout,width:prepared.width,height:prepared.height,
          blocks:prepared.blocks,satori,resvg,fonts:prepared.fonts,backgroundPng:bg,PNG});
        let backgroundAsset=null;
        try{backgroundAsset=await assetStore.archive(owner,bg,bytes[0]===137?"image/png":"image/jpeg");}catch{log({event:"overlay_background_archive_unavailable"});}
        let asset,lastError;
        for(let i=0;i<2;i++)try{asset=await assetStore.archive(owner,png,"image/png");break;}catch(e){lastError=e;}
        if(!asset)throw error("COMPOSITION_ARCHIVE_UNAVAILABLE");
        if(backgroundAsset)asset={...asset,variants:{background:backgroundAsset}};
        const signed=await assetStore.sign(owner,[asset.id]);if(!signed?.[0]?.url)throw error("COMPOSITION_ARCHIVE_UNAVAILABLE");
        log({event:"overlay_completed",cards:edge.splitBlocks(prepared.blocks).cards.length,rescaled:bg!==bytes,bytes:png.length});
        return {url:signed[0].url,asset,composition:{version:"poster-overlay-v1",engine:"overlay",rescaled:bg!==bytes}};
      });
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
          const rendered=await compose({structured:prepared.input.structured,prompt:prepared.input.prompt,width:prepared.width,height:prepared.height,fonts:prepared.fonts,designEngine:prepared.designEngine,
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
        log({event:"completed",design:manifest.design,engine:prepared.designEngine,itemCount:manifest.itemCount,fontSize:manifest.fontSize,copyHash:manifest.copyHash,fallback});
        return {url:signed[0].url,asset,composition:{version:manifest.version,copyHash:manifest.copyHash,typographyFallback:fallback}};
      });
    }
  };
}
module.exports={createCommercialComposition,loadEngines,EMPTY};
