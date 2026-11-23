"use strict";
// One server-owned generation choice. Legacy policy/accurate-copy remains the
// default until visual acceptance; the canary list is independent of old fonts.
function nativeCommercialEnabled(raw,owner){
 if(require('./native-copy-policy').enabled(raw,owner))return true;
 try{const p=typeof raw==="string"?JSON.parse(raw):raw;
  return p?.nativeCommercial===true&&typeof owner==="string"&&!!owner&&
   (!Array.isArray(p.nativeCommercialAccounts)||p.nativeCommercialAccounts.includes(owner));
 }catch{return false;}
}
const GUIDANCE="【商业原生设计执行】用户提供的广告/信息图是视觉参考，不是待复刻的文案。先辨别每张输入的用途（风格、真实产品界面、Logo原件、人物），按实际附件顺序选择source_indexes并写reference_roles；不能在prompt说用了原图却不选择原图。过去提供的素材先recall_history取得可用原图，再执行生图，不能把依赖它的生图与召回并行。风格参考只借视觉层级、字形气质、图文融合与信息密度，不能挪用参考里的日期、数字和能力。真实UI、Logo不能用文字描述代替。普通商业图由Seedream原生设计整幅图及文字；structured.text保存完整文案，不能因此把图片拆成统一的无字横幅加正文。除用户明确要求精确复制原文外，不填写无字artwork_prompt，不把版式限制成固定三列或大留白。先按用户资料形成可核对的信息，技术能力和承诺不可沿用助手先前的推测；栏目数字必须与实际条目一致。局部Logo编辑沿用preserve_assets本机原件流程，不同时让模型重画该Logo。";
function injectNativeCommercialGuidance(messages){return [...messages,{role:"system",content:GUIDANCE+
 "【本轮风格优先】最新明确风格/禁止项 > 本次明确选用的参考特征 > 历史偏好；最新局部改字/加Logo本身不等于换风格。用户换风格时重新设计美术与版式，真实产品、Logo和必要内容仍保留。旧广告不是永久模板，真实蓝色UI也不决定整幅配色。只借旧图的信息组织时，structured.style_reference.scope=information_structure，只填density；明确采用其视觉语言时才分析palette、typography、graphic_language、image_integration。没有风格参考就不填style_reference。模糊任务先结合本次产品、受众、用途、资料中的有效偏好选视觉方向；需要历史资料时先用现有recall_history检索。其他项目和助手旧建议不作已确认偏好。visual_approach写出选定的色彩/材质/字体气质/图文融合方式，不能只写高级好看；用户没指定时主动选择，不把行业绑成永远相同的蓝金、极简或卡片。"+
 "【内容与设计一起决策】未限定信息量的商业宣传，默认内容充实、表达多样：讲清为谁、解决什么、业务如何关联、如何行动。丰富靠有用信息和视觉叙事，不靠长篇段落、虚构卖点或满屏微字。已有能力可以解释其用途，但不得发明交付承诺、协议、数量和活动日期。用户明确极简、少字、纯场景等时按该范围做，不能为了丰富擅自加内容。用户明确要求约千字等篇幅且已提供足量资料时，保留具体用途、场景差异与责任解释，不把详细内容统一压成两行；通过画布和层级承载，不靠重复句或未确认事实凑字。"+
 "【资料不是整段印刷稿】上下文中的背景解释、分类纠错、缺失信息提醒和制图指令用于你理解，不自动变成画面正文。例如“它们不是五个步骤”应落实为并列能力，“四步不是交付保证”应落实为沟通建议的栏目语义，而不是把这些提醒逐句印上。只有用户明确要求上图的原文才逐字保留；其他资料先写成自然、准确的商业文案。合作双方的分工只画双方，不把应用场景再算成第三方。正文不要写成“以上为…不是…”的自我解释，不把本轮推理过程、校验注释或元数据印进成品。用户明确要求的合规说明仍保留。"+
 "在structured.design_brief里明确用途、受众、目标、本轮视觉方向和information_density；density_source注明current_user/context/default。visual_map把每个structured.text.key恰好分配一次：按内容选主视觉、关系图、流程图、场景群像、对比、清单、文字或行动入口，expression具体说明如何画出来。这是执行简报，不是让用户选方案；不强制固定栏数或版式。默认dense且多于3项文案时至少采用两种有意义的表达形式。真实场景、产品细节与视觉关系应承载信息，不能全部退回巨幅截图加三栏正文。"+
 "【信息的可视化含义】业务范围是并列关系时，不画成未经证实的先后流程；只有确有顺序的操作才画流程。能力说明应解释用途，避免“设备接入：支持设备接入”这种同义重复。面向合作伙伴的产品宣传，可把真实产品作为证据、伙伴与终端客户作为关系、园区/工厂/商业综合体作为有差异的真实场景，再明确合作行动；这是按信息含义选择表达的例子，不是强制的场景数、固定布局或风格。用户要内容丰富时，不能只用一幅巨型斜放截图、几条细线标注和业务名来代替这些信息；不要主动锁死为不许卡片、不许场景图、不许插画。选择适合内容的表现手段，不增加未经确认的能力或数字。设计简报描述读者要理解的信息及素材关系，不替制图模型预设每块位置、占比、微字标注和特效；用户明确指定的布局位置则准确传递。"+
 "【可读成品】真实2K画布须为完整正文、说明和电话留足可读面积；不指示极小标注、假英文或斜放长正文，不把图内原有细字抄成外围装饰。密集正文默认使用中文常规字重Regular、字腔开阔且笔画清晰的规整字体，避免整段加粗；不是极细Thin/Light。用户明确指定字体或字重时优先遵从。留开字距和行距，不叠金属纹理、发光描边或透视变形；艺术字效果可用于标题，不必把整幅风格变成普通文档。定稿文案只存structured.text，视觉prompt约中文300字内；按key对照标题数量、实际条目、角色、日期和电话。主视觉、图解和文字按visual_map融合，不能删字或缩到不可读来迁就画面。"+
 "【画布选择】用户指定比例或方向优先，局部编辑沿用原图画布。新海报没有固定比例时，结合完整可见文案、分组、阅读方向与渠道填写已有aspect_ratio；横向多组对比可用21:9，手机连续阅读可用9:16或9:21，少量信息可用常规比例，不把所有图片都做成长图。同像素档改变比例并不增加总像素，仍须确保正文可读；长文不能靠缩字或擅自拆页解决。"+
 "【版式决策】风格与布局分别选择，依据本轮要求、信息关系、真实素材和画布比例组织。一个清晰的视觉主张贯穿整张作品；业务并列、步骤先后、数据对比使用各自合适的表达。用字重、字号、色彩、间距建立阅读层级，正文行距和对比度先保证可读。装饰只在有助于主题时选用，不设装饰数量、固定字号倍数或留白比例；极简、对称、规则网格也可以是用户认可的设计。避免把所有内容机械装进同款卡片，或用大量光效掩盖内容；不为打破网格故意压字、裁字、遮住Logo或真实界面。完整文案排不下时保持正文可读并说明容量限制，不擅自删字、改成微字或增加页数。"}];}
module.exports={nativeCommercialEnabled,injectNativeCommercialGuidance,GUIDANCE};
