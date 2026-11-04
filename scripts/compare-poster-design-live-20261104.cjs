"use strict";
// Same copy + same freshly generated artwork: isolate the rendering change.
const fs=require('fs'),path=require('path'),assert=require('assert/strict');
const root=path.resolve('outputs/poster-design-20261104'),run=process.argv.find(a=>a.startsWith('--run='))?.slice(6);
if(run)assert.match(run,/^live-\d+$/);
const folder=run?path.join(root,run):JSON.parse(fs.readFileSync(path.join(root,'latest-run.json'),'utf8')).folder;
const {compose}=require('../cloudfunctions/bf-image/commercial-composer');
const {loadEngines}=require('../cloudfunctions/bf-image/commercial-composition-runtime');
const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
(async()=>{const engines=await loadEngines(),fonts=[400,700].map(weight=>({name:'Noto CJK',weight,style:'normal',data:fs.readFileSync('outputs/commercial-text-repair-20261104/fonts/NotoSansCJKsc-'+(weight===400?'Regular':'Bold')+'.otf')}));
 const report=JSON.parse(fs.readFileSync(path.join(folder,'report.json'),'utf8'));report.comparisons=[];
 for(const row of report.cases){if(!row.artworkFile)continue;const req=JSON.parse(fs.readFileSync(path.join(folder,row.id+'-request.json'),'utf8')),bytes=fs.readFileSync(path.join(folder,row.artworkFile));const [width,height]=req.size.split('x').map(Number);
  const input={...engines,fonts,width,height,structured:req.structured,prompt:req.prompt,background:'data:image/'+(bytes[0]===137?'png':'jpeg')+';base64,'+bytes.toString('base64')};
  const before=await compose({...input,designEngine:'legacy'}),after=await compose({...input,designEngine:'poster'});assert.equal(before.manifest.copyHash,after.manifest.copyHash);assert.equal(after.manifest.itemCount,req.structured.text.length);
  fs.writeFileSync(path.join(folder,row.id+'-same-art-before.png'),before.png);fs.writeFileSync(path.join(folder,row.id+'-local-replay.png'),after.png);
  fs.writeFileSync(path.join(folder,row.id+'-manifest.json'),JSON.stringify(after.manifest,null,2));
  report.comparisons.push({id:row.id,sameCopy:true,sameArtwork:true,items:after.manifest.itemCount,copyChars:row.copyChars,copyHash:after.manifest.copyHash,baselineFont:before.manifest.fontSize,candidateFont:after.manifest.fontSize,design:after.manifest.design,artwork:after.manifest.artwork,visualReview:'尚待目视验收'});
 }
 fs.writeFileSync(path.join(folder,'comparison.json'),JSON.stringify(report.comparisons,null,2));
 const cards=report.cases.map(row=>{const c=report.comparisons.find(c=>c.id===row.id);return `<article><h2>${escape(row.name)}</h2><p>${escape(c?.copyChars)} 字 · ${escape(c?.items)} 条文案 · ${escape(c?.design?.styleId)} / ${escape(c?.design?.layoutId)}</p><div class="pair"><figure><figcaption>此前排版 · 同文案、同素材</figcaption><a href="${row.id}-same-art-before.png"><img src="${row.id}-same-art-before.png"></a></figure><figure><figcaption>候选成品 · 实际服务端产物</figcaption><a href="${row.imageFile}"><img src="${row.imageFile}"></a></figure></div><p>字号：${escape(c?.baselineFont)} → ${escape(c?.candidateFont)}px。文案指纹：${c?.sameCopy?'相同':'未通过'}；图片调用约${Math.round((row.imageMs||0)/1000)}秒。</p><p class="verdict">视觉结论见验收记录；生成成功、字形正确与商业美感分别判断。</p></article>`;}).join('');
 fs.writeFileSync(path.join(folder,'index.html'),`<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>商业海报设计 · 同条件对照</title><style>*{box-sizing:border-box}body{margin:0;background:#101722;color:#e8eef5;font:15px/1.7 'Microsoft YaHei',sans-serif}main{max-width:1540px;margin:auto;padding:30px}header,article{background:#1b2735;border:1px solid #34465b;border-radius:16px;padding:24px;margin-bottom:26px}h1{font-size:26px;margin:0}h2{font-size:21px;margin:0}p{color:#bdcddd}a{color:#83d3fa}.pair{display:grid;grid-template-columns:1fr 1fr;gap:22px}figure{margin:0;min-width:0}figcaption{padding:10px 0;color:#8edac8}img{width:100%;display:block;border-radius:8px} .verdict{border-left:3px solid #63c7b3;padding-left:12px}@media(max-width:800px){main{padding:12px}.pair{grid-template-columns:1fr}}</style><main><header><h1>海报设计改造 · 同条件对照</h1><p>保留全部定稿文案，用同一张本轮真实生成的素材比较两套排版。点击成图可看原尺寸。</p><p>三组为合成公司资料；前置模型真实参与设计规划，定稿文字由夹具锁定。这不代表客户端召回、自由文案创作或所有商业场景均通过。</p><p>新增结构：可验证设计计划 → 同计划的主视觉素材 → 精确文字与语义图形 → 私有产物。3套风格、6种结构已适配。</p></header>${cards}</main></html>`);
 console.log(JSON.stringify({folder,comparisons:report.comparisons}));
})().catch(e=>{console.error(e.code||e.message);process.exitCode=1;});
