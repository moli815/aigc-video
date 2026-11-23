"use strict";
// One execution contract; no provider calls, account lookups or client mutations.
const VERSION=2;
const INTENTS=["campaign","product_reference","redesign","local_edit","visual"];
const STYLES=["commercial_launch","photographic","illustrated","editorial","minimal"];
const LAYOUTS=["product_launch","product_spread","product_stage"];
function policyOf(raw){try{const p=typeof raw==="string"?JSON.parse(raw):raw;return p&&typeof p==="object"&&!Array.isArray(p)?p:{};}catch{return {};}}
function enabled(raw,owner){if(require('./native-copy-policy').enabled(raw,owner))return true;const p=policyOf(raw);return !!owner&&p.workflowVersion===VERSION&&(!Object.hasOwn(p,"workflowAccountIds")||(Array.isArray(p.workflowAccountIds)&&p.workflowAccountIds.length<=100&&p.workflowAccountIds.every(x=>typeof x==="string"&&x.length<=128)&&p.workflowAccountIds.includes(owner)));}
const fail=code=>{throw Object.assign(new Error(code),{code});};
function compile({structured,image,taskKind,textMode,policy,owner}){
 if(!enabled(policy,owner)||structured?.image_plan===undefined)return null;
 const p=structured.image_plan,allowed=["version","intent","typography","visual_style","layout","reference_count","protected_references"];
 if(!p||Array.isArray(p)||Object.keys(p).some(k=>!allowed.includes(k))||p.version!==VERSION||!INTENTS.includes(p.intent)||!["native","typeset"].includes(p.typography)||!STYLES.includes(p.visual_style))fail("IMAGE_PLAN_INVALID");
 if(p.layout!=null&&!LAYOUTS.includes(p.layout))fail("IMAGE_PLAN_INVALID");
 const refs=Array.isArray(image)?image:(image?[image]:[]);
 if(!Number.isInteger(p.reference_count)||p.reference_count<0||p.reference_count>6||p.reference_count!==refs.length)fail("IMAGE_PLAN_REFERENCE_MISMATCH");
 if(!Array.isArray(p.protected_references)||p.protected_references.length>refs.length)fail("IMAGE_PLAN_INVALID");
 const seen=new Set();for(const a of p.protected_references){
  if(!a||Object.keys(a).some(k=>!["index","role","crop","anchor"].includes(k))||!Number.isInteger(a.index)||a.index<1||a.index>refs.length||seen.has(a.index)||!["ui","logo","product","person"].includes(a.role))fail("IMAGE_PLAN_INVALID");
  if(a.crop!=null&&(!Array.isArray(a.crop)||a.crop.length!==4||a.crop.some(n=>!Number.isFinite(n))||a.crop[0]<0||a.crop[1]<0||a.crop[2]<=0||a.crop[3]<=0||a.crop[0]+a.crop[2]>1||a.crop[1]+a.crop[3]>1))fail("IMAGE_PLAN_INVALID");
  if(a.anchor!=null&&!["auto","top_left","top_right","bottom_left","bottom_right"].includes(a.anchor))fail("IMAGE_PLAN_INVALID");seen.add(a.index);
 }
 if(p.intent==="product_reference"&&!p.protected_references.length)fail("IMAGE_PLAN_REFERENCE_MISMATCH");
 if(p.intent==="local_edit"&&(!refs.length||taskKind!=="edit"))fail("IMAGE_PLAN_INVALID");
 // Existing client compositor owns these requests; never introduce a second pass.
 if(structured?.preserve_assets?.length)return null;
 if(textMode==="overlay"&&(p.typography==="native"||p.protected_references.some(r=>r.role==="ui")))fail("IMAGE_PLAN_TEXT_CONFLICT");
 if(p.intent==="local_edit"&&p.typography!=="native")fail("IMAGE_PLAN_INVALID");
 return Object.freeze({...p,protected_references:Object.freeze(p.protected_references.map(a=>Object.freeze({...a,...(a.crop?{crop:Object.freeze([...a.crop])}:{})}))),protectUI:p.protected_references.some(a=>a.role==="ui"),native:p.typography==="native"});
}
function providerInput(plan,image,referenceRoles,prompt){
 const refs=Array.isArray(image)?image:image?[image]:[],serverAssets=plan?.protected_references.filter(r=>r.role==="logo"||!plan.native&&plan.protectUI&&r.role==="ui")||[],excluded=new Set(serverAssets.map(r=>r.index)),slots=new Map();
 const selected=[];for(const [i,v]of refs.entries())if(!excluded.has(i+1)){selected.push(v);slots.set(i+1,selected.length);}
 const rebind=s=>typeof s==="string"?s.replace(/图([1-6])(?!\d)/g,(all,n)=>slots.has(+n)?"图"+slots.get(+n):excluded.has(+n)?"由服务器保管的"+(serverAssets.find(r=>r.index===+n).role==="logo"?"Logo":"UI")+"原件":all):s;
 return {image:selected.length?selected:undefined,referenceRoles:Array.isArray(referenceRoles)?referenceRoles.filter((_,i)=>!excluded.has(i+1)):undefined,prompt:rebind(prompt),slots,originalCount:refs.length,providerCount:selected.length,excludedLogos:serverAssets.filter(r=>r.role==="logo").map(r=>r.index),serverAssets:serverAssets.map(r=>({index:r.index,role:r.role}))};
}
function constraints(plan,input){if(!plan)return "";
 const protectedText=plan.protected_references.filter(a=>!(plan.native&&a.role==="logo")).map(a=>`图${input?.slots?.get(a.index)||a.index}=${a.role}真实素材，保留其身份、形状和已有信息，不以相似素材替代`).join("；");
 const intent=plan.intent==="visual"?"制作用户要求的纯照片、人物或视觉场景。这不是商业海报；不添加任何标题、姓名、职业、邮箱、电话、Logo、徽章或宣传模块。":plan.intent==="redesign"?"重做外围版式与用户要求的风格；受保护素材仍保持原身份。":plan.intent==="local_edit"?"只改用户指定部分，其余构图、文字和主体不变。":plan.intent==="product_reference"?"围绕真实产品素材创作海报或场景；外部空间可创作，产品界面不是可随意重画的风格参考。":"设计完整商业成品，主视觉、标题、信息图解和行动入口形成统一构图。";
 const style=plan.visual_style==="commercial_launch"?"商业发布广告：产品演示、主标题、关键数字与信息模块形成有主次的图文融合，不做普通文档分栏，不把所有配图压成顶部窄条；不照抄参考作品的品牌、日期、数字或宣传事实。":"按用户选定的"+plan.visual_style+"视觉语言实现，不机械套科技风。";
 return "\n【作图任务计划v2】"+intent+protectedText+"。"+style+(plan.protectUI?"真实UI由服务器原件合成：按参考界面宽高关系预留清楚、无遮挡的主屏，屏框、空间、灯光由你创作，屏内用均匀深色空屏，不画新地图、新数字或新UI；真实地图、导航、数据面板和已有文字稍后直接放回。":"")+(plan.protected_references.some(a=>a.role==="logo")?"Logo由服务器抠取原件贴回，你不绘制任何Logo、近似图标或Logo占位字；在指定或合理角落留出不挡字的空间，不把品牌名称另做徽标。":"");
}
const GUIDANCE=`【IMAGE_WORKFLOW_V2】先区分当前交付目标、已确认事实、真实素材与风格参考。内部比较两种适合用途的构图及取舍，选择一个执行，不向用户强制展示全套策划。不得把历史节日/旧目标带入新任务。
商业图默认让Pro设计完整成品，不强迫拆成独立摄影小图。structured.image_plan={version:2,intent:campaign/product_reference/redesign/local_edit/visual,typography:native/typeset,visual_style:commercial_launch/photographic/illustrated/editorial/minimal,reference_count:客户端实际将发送的图片数,protected_references:[{index:发送槽位从1起,role:ui/logo/product/person}]}。它是内部执行计划，不是画面文字。纯照片、人物或场景选择visual，structured.text=[]，不为了商业用途就擅自把照片改成海报，更不能编人名和联系方式。
严格按实际工具schema嵌套，image_plan必须放structured里面，不能把version/intent/typography摊到structured外层，也不混入旧design_plan。示例仅说明字段位置：structured={text:[],image_plan:{version:2,intent:"visual",typography:"native",visual_style:"photographic",reference_count:0,protected_references:[]}}。平台截图或数据大屏对应role="ui"，不是泛化product。两个当前附件用source="attached"及source_indexes；source="both"仅表示最近生成底图加一个当前附件，不能和source_indexes混用。
真实大屏/产品用于海报，选product_reference并保护对应素材；只有用户明确重设计才选redesign。保护UI与重新设计外部海报可同时成立。执行端必须真正取得原图；产品准确排版时UI和Logo保留在服务器图层，生成模型只画无字视觉层，不把这种明确分工说成漏图。找不到公司Logo时先用已开放的recall_history取真实原件ID，记忆文字不能代替图片，不编ID。
参考商业发布广告时借鉴主次、产品演示、关键数字、模块节奏和行动入口，不复制其公司/数据；视觉风格可换，不默认蓝金色。纯照片、人物和普通少字图可native；有真实UI和中文说明的产品海报优先typeset，以原图层、程序准确排字和完整视觉层组合，避免模型重写界面和中文。typeset产品布局layout可选product_launch/product_spread/product_stage，分别为产品发布、编辑展开、主视觉舞台；布局与visual_style独立选择。长篇公司介绍宜选product_spread和较高画布，不删文案或把字缩得不可读。无UI但需要逐字准确时沿用既有准确排字。准确文案逐项放structured.text；可选artwork_prompt只描述无字视觉层的材质、空间与光线，不含UI、Logo、正文、数字或文字框。电话/公司/产品字段只取已确认资料。
Logo原件在native计划中可由服务器抠图并避开文字贴回，anchor跟随用户指定角落；素材在另一张海报内部时，用crop明确原图归一化[x,y,width,height]裁出Logo范围，不能把整张海报当Logo。复杂背景采用保留原像素的最佳努力分割，不能承诺每个边缘都完美。
旧包精确Logo添加/替换仍遵循已安装客户端preserve_assets契约，不用新计划绕过校验，不让服务器与手机各贴一次；该分支不填写image_plan。检查手机最终吸附占位而不是仅检查估算小框；保留二维码留白。`;
function inject(messages,tools,policy,owner){
 if(!enabled(policy,owner)||!Array.isArray(tools)||!tools.some(t=>["image_generate","image_edit"].includes(t?.function?.name)))return messages;
 if(messages.some(m=>m?.role==="system"&&m.content===GUIDANCE))return messages;
 return [...messages,{role:"system",content:GUIDANCE}];
}
function injectNativeContract(messages){return [...messages,{role:'system',content:'【原生设计与原件保真统一执行】本轮保留完整原生商业设计，并填写工具已有的structured.image_plan={version:2,intent,typography:"native",visual_style,reference_count,protected_references}。真实大屏/界面选ui，Logo选logo，index按实际发送附件顺序。参考广告仅借风格，不能保护成产品。原件将在服务器准确合成，不能在prompt承诺用了原图却漏选素材。不要填写无字artwork_prompt或typeset，也不限定布局为三栏。design_brief/style_reference与image_plan共同传入structured，前者决定图文美术，后者落实原件保真。每个能力名与其解释保持关联；不要把不同能力虚构成步骤。局部编辑/preserve_assets仍沿用原契约，不双贴。'}];}
module.exports={VERSION,INTENTS,STYLES,LAYOUTS,enabled,compile,providerInput,constraints,GUIDANCE,inject,injectNativeContract};
