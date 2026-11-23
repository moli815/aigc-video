"use strict";
/**
 * 海报美术指导库 + 文字契约编译器。
 *
 * 解决的问题（2026-11-15 实测结论）：
 * 1) 版面描述里复述了文案块名，模型就把同一段印两遍 —— 同类错误占实测错误的大头；
 * 2) 文案交给 LLM 转写再进提示词，多一次搬运就多一次出错机会；
 * 3) 1.5K 画布排 500 字，单字像素不够，笔画多的字先崩；
 * 4) 只说"科技感"三个字，模型只能给纯色块 —— 这就是"像 HTML"的根源。
 *
 * 因此本模块的分工是：
 *   风格与装饰 -> 由本库给出可选视觉语言；不靠强制堆特效代替构图
 *   文案       -> 由调用方按块传入，本库原样加引号编号，绝不二次转写
 *   画布       -> 按字数自动选档，字数越多像素越大
 */

const FAMILY_KEYS = ["tech", "warm", "editorial", "luxury", "comic", "natural"];

// 每个风格族的候选视觉语言，不是必须逐项渲染的清单。
const FAMILIES = {
  tech: {
    label: "深空科技",
    bg: "深空蓝到近黑的纵向渐变；中上部一层青蓝色径向光晕，底部压暗；整体明度低但层次分明",
    layers: [
      "极细网格线覆满全图，透明度约 6%，间距约 40px，边缘渐隐",
      "一道横向扫描光带斜穿背景，透明度 10%",
      "右上角同心圆环刻度盘，半透明，作为装饰主体",
      "超大品牌徽标水印压在背景层，透明度 4%，裁切进画面",
    ],
    devices: [
      "斜切平行四边形色块，作为每个信息区的起点而非完整矩形",
      "电路连线与节点，把主视觉与两侧信息区连起来",
      "深色玻璃卡：底色半透明深蓝，1px 青色高光边，圆角 8px，顶部一条 2px 亮色短线",
      "数据条/迷你折线作为装饰层，不含任何未提供的数字",
      "发光细边框与内阴影做出悬浮感",
      "粒子光点散布在暗部，密度低",
      "分区之间用底色深浅交替 + 1px 发光分隔线，不用大面积空白",
    ],
    type: "标题用无衬线粗体、字重 800、字距略收紧；数字用等宽字形并加大字重；正文常规字重、行高 1.6",
    accent: "强调色只给数字、图标与当前层标记，总量不超过画面 12%",
    forbid: "不要纯色长方形堆叠，不要白底卡片，不要扁平无光效的色块",
  },
  warm: {
    label: "暖色手绘",
    bg: "米纸色或淡奶色纸底，带轻微纸张纤维纹理；四角略深，像被光晒过",
    layers: [
      "水彩晕染斑块，边缘不规则，压在文字后方",
      "手绘细线与叶蔓，从画面边缘伸入",
      "纸胶带/贴纸质感的小色块，斜贴在各区交界",
      "淡淡的铅笔草稿线留在背景，透明度 8%",
    ],
    devices: [
      "圆角厚边卡片，边框用手绘不规则线而不是直线",
      "插画式图标，线条粗细一致，带手涂填色",
      "手写体小标注与箭头，指向对应内容",
      "圆形/胶囊形标签，纸感底色",
      "分区靠纸色深浅与手绘边框区分，不靠硬线",
      "轻微投影与纸张卷边，做出实物感",
      "点状与短划线装饰，模拟手账",
    ],
    type: "标题用手写感或圆润无衬线，字重中等偏粗；正文用清晰黑体保证可读；数字可手写体",
    accent: "暖橙、赭红、草绿为主，饱和度中等，不要荧光色",
    forbid: "不要金属质感，不要冷蓝主色，不要锐利直角",
  },
  editorial: {
    label: "杂志编辑",
    bg: "纯白或极浅灰纸底，无渐变；靠黑白对比与留白建立张力",
    layers: [
      "一条贯穿全高的细竖线或细横线作为版心轴",
      "超大标题越过版心出血，制造版面张力",
      "页码、刊头、边注等编辑元素（不得含未提供的文字）",
      "局部反白块：黑底白字，只用于一个重点区",
    ],
    devices: [
      "严格网格与对齐，字号阶梯明显（大标题/中标题/正文三层）",
      "细分隔线替代卡片边框",
      "单色强调块，只用一种强调色",
      "留白作为主要构成元素，占比不低于 25%",
      "图片通栏或半栏出血",
      "小字号栏目标签，字距拉开",
      "数字做大号装饰，独立成块",
    ],
    type: "标题用衬线或高对比无衬线，字号极大；正文小字号、行高 1.7；标签全大写或字距拉开",
    accent: "只保留一个强调色，其余黑白灰",
    forbid: "不要渐变，不要发光，不要圆角卡片，不要装饰性插画",
  },
  luxury: {
    label: "高端克制",
    bg: "深墨绿/墨黑或米金底色，纯色或极缓渐变；大量留白",
    layers: [
      "一条极细金线或银线作为分割",
      "大面积负空间，产品/主体单独占据一侧",
      "细腻的材质底纹（石纹、丝纹），透明度极低",
      "边角极小的品牌标记（不得含未提供文字）",
    ],
    devices: [
      "细线框代替卡片，线宽 0.5–1px",
      "单张大幅实景或产品特写，不做拼贴",
      "极简图标，线性，单色",
      "字号对比强烈：主标题很大，其余极小",
      "文字块整体靠一侧或底部对齐",
      "留白占比 40% 以上",
      "价格/规格用细体大字独立呈现",
    ],
    type: "标题用细衬线或高对比衬线，字距拉开；正文极简，字重轻",
    accent: "金色或单一低饱和强调色，面积不超过 8%",
    forbid: "不要多个色块，不要密集小字，不要促销感的爆炸元素",
  },
  comic: {
    label: "波普漫画",
    bg: "高饱和黄橙或亮色渐变底，带大面积网点（halftone）纹理",
    layers: [
      "斜向放射线从一角发散",
      "半调网点覆盖背景，密度渐变",
      "爆炸形/锯齿形色块作为标题底板",
      "粗黑描边套色错位，制造印刷错版感",
    ],
    devices: [
      "卡片带 4–6px 纯黑粗描边，硬投影偏移 6px",
      "拟声块与对话框形状（不得含未提供文字）",
      "图标为粗线条或实心剪影，描边统一",
      "斜排或旋转的信息块，打破水平线",
      "高饱和大色块分区，对比强烈",
      "小圆点多点装饰",
      "数字用超大粗体，带描边和投影",
    ],
    type: "标题用超粗黑体或手写体，字号极大，可加描边；正文用清晰黑体",
    accent: "红/蓝/黄三原色系，饱和度拉满",
    forbid: "不要灰调，不要细线，不要留白过多",
  },
  natural: {
    label: "自然质感",
    bg: "柔和自然光下的实景底，或亚麻/木纹/石材材质底",
    layers: [
      "树叶投影或窗光斑，斜投在底面上",
      "材质纹理（麻布、木纹）作为分区底",
      "手写标签纸片，微微翘起",
      "自然的景深虚化层",
    ],
    devices: [
      "圆角纸质卡片，带轻微阴影",
      "线性或手绘图标，颜色取自材质",
      "胶片感的色彩分级，低对比",
      "植物/织物元素从边缘进入",
      "分区靠材质变化而非线条",
      "标签与印章质感小元素",
      "真实拍摄质感的产品/场景图",
    ],
    type: "标题用温和的衬线或圆润无衬线；正文清晰；避免过度加粗",
    accent: "取自场景的自然色（草木绿、陶土、米褐）",
    forbid: "不要霓虹色，不要金属高光，不要锐利几何",
  },
};

// 密度语法。dense 的核心是"分区有骨架"，不是"塞满小字"。
const DENSITY = {
  dense: {
    label: "高密度",
    zones: "按实际内容的主题与分组组织信息区，用层级、间距或底色区分，不为了填满版面新增信息区",
    grid: "多块并列时必须铺满整行：块数为偶数用 2×N 或 N×2；块数为奇数用「一大 + 其余小」的非等分组合，或单行横向铺满；禁止出现「2+2+1」这种最后一行只剩一块居中的孤立排布",
    balance: "完整文案和真实素材先得到清晰的展示面积，再安排视觉焦点，避免窄栏长段落和微字",
  },
  balanced: {
    label: "中等密度",
    zones: "按实际信息分组安排主次，允许留白，不强行凑分区数",
    grid: "并列块数保持对称拆分，避免孤立块",
    balance: "主视觉与文案互相呼应，比例由内容和画布决定",
  },
  minimal: {
    label: "极简",
    zones: "只表达用户要求的信息，留白与主题相称，不补充栏目或装饰",
    grid: "不使用多列网格，信息纵向堆叠且左对齐",
    balance: "用少量清晰的元素建立焦点，保留用户要求的完整文字",
  },
};

// 层级 -> 字号相对关系，帮助模型建立阶梯而不是"什么都一样大"
const LEVEL = {
  hero: "最大字号，占画面宽度 60% 以上，可跨行",
  title: "第二层级，明显小于主标但远大于正文",
  sub: "第三层级，约为标题的 45%–55%",
  body: "正文层级，保证可读，不得小于画面宽度的 1.6%",
  label: "标签层级，字距拉开，可与正文同大小但更轻",
  metric: "数字层级，用等宽或粗体，视觉重量接近标题",
};

function normalizeDensity(v) {
  return DENSITY[String(v || "").toLowerCase()] ? String(v).toLowerCase() : "dense";
}
function normalizeFamily(v) {
  const k = String(v || "").toLowerCase();
  return FAMILIES[k] ? k : "tech";
}

function charCount(s) {
  return [...String(s ?? "").replace(/\s+/g, "")].length;
}

/**
 * 按字数与参考图决定画布档位。
 * 实测：1.5K(1344×1792，241 万像素) 只够排 120 字以内；
 * 超过就换 2K(1776×2368，420 万像素)，单张只贵 0.10 元，
 * 但比"错一版重出一张 0.13 元 + 客户看到错字"划算得多。
 */
function planCanvas({ totalChars = 0, hasPhoto = false } = {}) {
  const dense = totalChars > 120;
  const size = dense || hasPhoto ? "2K" : "1.5K";
  return {
    size,
    reason: dense ? `画面文字 ${totalChars} 字，需要更大单字像素` : "文字量小，1.5K 足够",
    pixels: size === "2K" ? "1776×2368" : "1344×1792",
    outputTierCny: size === "2K" ? 0.23 : 0.13,
  };
}

/** 美术指导段：只描述"怎么画"，绝不出现任何一句文案原文。 */
function composeArtDirection({ styleFamily, density, palette, layoutNotes, hasPhoto, hasLogo, hasReference }) {
  const f = FAMILIES[normalizeFamily(styleFamily)];
  const d = DENSITY[normalizeDensity(density)];
  const p = Array.isArray(palette) && palette.length ? palette.slice(0, 3).join(" / ") : "按风格族默认配色";
  const lines = [];
  lines.push(`【美术指导】风格：${f.label}。配色：${p}。`);
  lines.push(`背景：${f.bg}`);
  if (normalizeDensity(density) !== "minimal") {
    lines.push(`可选的视觉语言（只选适合本轮主题的手段，不需全部采用）：${f.layers.slice(0, 2).join("；")}；${f.devices.slice(0, 2).join("；")}。`);
  }
  lines.push(`字体气质：${f.type}。强调色用法：${f.accent}。`);
  lines.push(`版面密度：${d.label}。分区：${d.zones}。并列排布：${d.grid}。比例：${d.balance}。`);
  // 极端的尺度对比是"大胆"的来源，不是加更多装饰。社区结论：一个大元素对比邻居 4–8 倍。
  lines.push("【文字层级】主标题、分区标题、正文各有清晰主次；字号与字重按标题长度、完整正文和实际画布调整，不固定倍数。正文行距舒展、底色对比清晰，不压缩字形、不在高频纹理上铺小字。");
  // 打破网格：中规中矩=所有东西都规规矩矩蹲在格子里。
  lines.push("【构图节奏】依据内容关系建立视觉焦点与阅读顺序；网格、对称、非对称都可选，不强制斜切或叠压。用真实素材、图解与字体气质表达主题，避免全图同款卡片。留白服从可读性与本轮风格，不固定比例；不得遮挡文字或品牌原件。");
  if (Array.isArray(layoutNotes) && layoutNotes.length) {
    lines.push(`版面节奏（只描述区域和顺序，不得复述任何文案）：${layoutNotes.slice(0, 5).join("；")}。`);
  }
  if (hasPhoto) lines.push("参考图里的实景照片是客户提供的真实素材，必须原样放进画面，等比缩放、不得裁掉主体。禁止重绘、禁止替换成相似的场景或示意画面、禁止改动其中的界面内容与数字。它优先于一切装饰：为它让出位置，而不是让装饰挤掉它。");
  if (hasLogo) lines.push("参考图里的 Logo 是客户原件：透明直接叠加，禁止白色方块底、禁止描边、禁止重绘、禁止变形、禁止替换为相似标志。");
  // 实测：给一张本身文字很多的参考图，模型会把参考图里的句子搬进成品（"消防与安防核链接入同一平台…"）。
  // 参考图的文字一律不许复刻，否则既串文案又占文字预算。
  if (hasPhoto || hasLogo || hasReference) {
    lines.push("【参考图文字隔离】仅风格参考里的文字不能搬成新增正文；真实产品界面、实景照片和Logo内部原有文字属于原件，应随原件保留，不擦除、不重写。新设计的印刷文案只认本契约。");
  }
  lines.push(`风格禁区：${f.forbid}。`);
  return lines.join("\n");
}

/**
 * 信息逻辑：把"一堆并列条目"变成"分组 + 主次"。
 *
 * 依据（社区一致口径）：数据页最忌讳五六个数字抢着当主角；
 * 应该「主题—分组—细项」三级结构，一个主数字放大 3–5 倍，其余退为辅助。
 * 8 个等大等距的矩形之所以没逻辑，是因为它们本来就不是同一类东西。
 */
/** 奇数条目不能靠模型自由发挥，给固定范式（社区：奇数法则 + 1-3-3 金字塔 / 左三右二）。 */
const LAYOUT_PATTERN = {
  2: "左大右小，或上下两段",
  3: "三块等分；若其中一块更重要则一大两小（1 主 + 2 辅）",
  4: "2×2，或一行四等分",
  5: "左三右二（左列三块略大、右列两块略小），或 1 主 + 4 辅",
  6: "3×2 或 2×3，行列对齐",
  7: "1-3-3 金字塔：顶部一块主项通栏，下面两行各三块",
  8: "1 主 + 7 辅（主块占宽度一半），或 4×2",
  9: "3×3",
  10: "1 主 + 3+3+3 三段",
};
function layoutPatternFor(n) {
  if (LAYOUT_PATTERN[n]) return LAYOUT_PATTERN[n];
  return n % 2 ? "1 主 + " + (n - 1) + " 辅均分" : "均分为两行，每行 " + n / 2 + " 块";
}

function composeInfoLogic(blocks) {
  const rows = (Array.isArray(blocks) ? blocks : []).filter(b => b && typeof b.text === "string" && b.text.trim() && !b.synthetic);
  if (!rows.length) return "";
  const groups = new Map();
  rows.forEach((b, i) => {
    const key = `${b.zone || ""}|${b.group || ""}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(i + 1);
  });
  return "【信息逻辑（内部编号，不印在画面）】\n" +
    [...groups.values()].map((indices, i) => `第${i + 1}组关联原文序号 ${indices.join("、")}，保持标题与其说明相邻，不调换说明的归属。`).join("\n") +
    "\n并列业务不擅自改为先后流程，数字只对应其原有标签。只有原文明确标注的顺序或优先级才做排序；不为了构图任取一项当重点，也不新增业务分类。";
}

const ROLE_LABEL = {
  brand: "品牌名", hotline: "热线", hero: "主标题", title: "标题", sub: "副标题",
  lead: "导语", body: "正文", label: "标签", metric: "数据", footer: "页脚",
  cert: "资质", partner: "合作说明",
};

/**
 * 文字契约：把文案按区编号、逐条加引号，并给出"只印一次"的硬约束。
 * blocks: [{ zone, role, level, text }]
 */
function composeTextContract(blocks) {
  const rows = (Array.isArray(blocks) ? blocks : []).filter(b => b && typeof b.text === "string" && b.text.trim());
  if (!rows.length) return { text: "", totalChars: 0, count: 0 };
  const total = rows.reduce((s, b) => s + charCount(b.text), 0);

  // 按 zone → group 分组，让模型拿到"哪几条是一组"的结构，而不是一长串并列
  const order = [];
  const groups = new Map();
  rows.forEach((b, i) => {
    const z = String(b.zone || "正文");
    const g = String(b.group || "");
    const key = g ? `${z}｜${g}` : z;
    if (!groups.has(key)) { groups.set(key, []); order.push(key); }
    groups.get(key).push({ ...b, index: i + 1 });
  });

  const body = order.map((key, oi) => {
    const g = groups.get(key);
    // 组名只用于代码内部排序，不写进提示词——实测模型会把提示词里的组名当成正文印出来
    const shown = `内部区域${oi + 1}，不印此标记`;
    const items = g.map(b => {
      const lvl = LEVEL[b.level] ? `｜${b.level}` : "";
      const w = b.weight === "hero" ? "｜主数字" : "";
      // 官方写法：引号 + 位置 + 出现几次。逐条写次数，比结尾笼统说一句有效得多。
      const occ = b.duplicable ? "｜出现 2 次（页眉、页脚各一次）" : "｜出现 1 次";
      return `[${b.index}] ${ROLE_LABEL[b.role] || "文字"}${lvl}${w}｜${JSON.stringify(b.text)}｜${charCount(b.text)}字${occ}`;
    });
    // 同一区内的并列条目必须全数出现。实测模型会为了"排整齐"悄悄删掉两条凑成 3×2，
    // 这一句是防这个的，比笼统说"不得遗漏"有效。
    const need = g.length >= 3 ? `（本组共 ${g.length} 项，必须 ${g.length} 项全部出现，一项都不能少；保持正文可读，不用微字或删减迁就版面）` : "";
    return `【${shown}】${need}\n${items.join("\n")}`;
  }).join("\n");

  // 品牌名与热线在页眉、页脚各出现一次是行业惯例。实测禁止它反而让模型在别处找补。
  const dup = rows.filter(b => b.duplicable).map(b => JSON.stringify(b.text));
  const hard = [
    `画面中只允许出现上面这 ${rows.length} 段文字，合计 ${total} 字；除此之外任何位置都不得出现任何字符，包括装饰性小字、伪英文、角标、页码、水印。`,
    dup.length
      ? `${dup.join("、")} 允许在页眉与页脚各出现一次（共两次）；其余各段只印一次，不得重复。`
      : "每段只印一次，不得重复。",
    "版面描述里不出现任何文案，所以不得因为某处提到过某个栏目，就再印一遍它的名字。",
    "区块标题只能用契约里列出的那些；契约没给标题的区块，直接由内容开始，不要自己起名字。",
    "逐字照搬：不得改字、不得漏字、不得多字、不得替换近义字；括号、间隔号、连字符必须保留。",
    "数字与号码逐位一致，不得增位、少位或改写。",
    "数字只作为对应数据的组成部分出现，不得单独作为装饰大字重复出现在画面别处。",
    "每段文字只能占据一个位置：分区标题做成一条色带或一行大字，只在区块起始处出现一次，不要在角落再加一行小字；不要把主数字再做一份半透明的背景副本。",
    "数据块只印数字和它的标签，不得为数据补充解释句、用途说明或形容词；上面没写的字一个都不要加。",
  ].join("\n");

  return {
    text: `【画面文字契约】\n${body}\n【硬约束】\n${hard}`,
    totalChars: total,
    count: rows.length,
  };
}

/** 完整提示词：信息逻辑 + 美术指导 + 文字契约 + 尺寸收尾。 */
function composePosterPrompt({ styleFamily, density, palette, layoutNotes, blocks, hasPhoto, hasLogo, hasReference, aspectRatio, orientation }) {
  const contract = composeTextContract(blocks);
  const canvas = require("./poster-canvas").planPosterCanvas({ blocks, hasPhoto, aspectRatio, orientation });
  const art = composeArtDirection({ styleFamily, density, palette, layoutNotes, hasPhoto, hasLogo, hasReference });
  const logic = composeInfoLogic(blocks);
  const prompt = [
    `商业广告海报，宽高比 ${canvas.aspectRatio}，${canvas.pixels} 画布，成品级制作标准，不是示意图也不是 PPT。`,
    logic,
    art,
    contract.text,
    "整幅图由你完成构图、配色、装饰与文字排布；文字必须按上面的契约逐条落位，主次由层级决定。",
  ].filter(Boolean).join("\n\n");
  return { prompt, canvas, contract };
}

function estimateCost({ inputImages = 0, canvas }) {
  const out = canvas && canvas.outputTierCny ? canvas.outputTierCny : 0.23;
  return Number((inputImages * 0.05 + out).toFixed(4));
}

/**
 * 版面容量决策。
 *
 * 实测（2026-11-16）：887 字压进一张 2K 海报，50 段里只有 29 段逐字正确、
 * 13 段缺失、5 段重复、37 处多出。这不是提示词能救的——海报本来就不是文档。
 * 社区口径一致：一屏一主题，同层最多 3–5 个指标。
 * 所以超过容量就换形态，不硬塞。
 */
const FORMAT = {
  // 实测容量（2026-11-16，2K 画布）：
  //   15 段 / 299 字 → 14 段逐字正确，1 处漏字
  //   20 段 / 235 字 → 20 段全对
  //   26 段 / 327 字 → 整段崩塌：13 段重复，流程区与场景区各印两遍
  //   50 段 / 887 字 → 整段崩塌：仅 29 段正确
  // 结论：真正卡住的不是字数，是**条目数**。20 段是可靠上限，字数顺带压到 300。
  poster: { max: 300, maxBlocks: 20, label: "单张海报", advice: "一张图讲清一件事" },
  longform: { max: 800, maxBlocks: 28, label: "分段长图", advice: "竖向分段，每段一个主题，段间用底色切换断开" },
  series: { max: Infinity, maxBlocks: Infinity, label: "系列海报", advice: "拆成多张，每张一个主题，封面 + 内页" },
};

function planFormat(totalChars, totalBlocks) {
  const n = Number(totalChars) || 0;
  const b = Number(totalBlocks) || 0;
  const over = n > FORMAT.poster.max || b > FORMAT.poster.maxBlocks;
  if (!over) return { mode: "poster", pages: 1, maxPerPage: FORMAT.poster.max, maxBlocksPerPage: FORMAT.poster.maxBlocks, label: FORMAT.poster.label, advice: FORMAT.poster.advice, fits: true };
  const pages = Math.max(Math.ceil(n / FORMAT.poster.max), Math.ceil(b / FORMAT.poster.maxBlocks));
  if (n <= FORMAT.longform.max && b <= FORMAT.longform.maxBlocks) {
    return { mode: "longform", pages: 1, maxPerPage: FORMAT.longform.max, maxBlocksPerPage: FORMAT.longform.maxBlocks, label: FORMAT.longform.label, advice: FORMAT.longform.advice, fits: true };
  }
  return {
    mode: "series", pages, maxPerPage: FORMAT.poster.max, maxBlocksPerPage: FORMAT.poster.maxBlocks,
    label: FORMAT.series.label, advice: FORMAT.series.advice, fits: false,
  };
}

/**
 * 按 zone→group 的整体顺序切页：同一组不拆开，一页不超过 maxPerPage 字。
 * 封面页（顶栏 + 主张）永远单独成页，保证第一张有主标题。
 */
function splitIntoSeries(blocks, maxPerPage = 300, maxBlocks = 20) {
  const rows = (Array.isArray(blocks) ? blocks : []).filter(b => b && typeof b.text === "string" && b.text.trim());
  if (!rows.length) return [];
  const cost = b => [...b.text.replace(/\s+/g, "")].length;

  // 先按 zone+group 归块，保持原始顺序
  const chunks = [];
  let curKey = null;
  for (const b of rows) {
    const key = `${b.zone || ""}|${b.group || ""}`;
    if (key !== curKey) { chunks.push({ key, zone: b.zone || "", items: [] }); curKey = key; }
    chunks[chunks.length - 1].items.push(b);
  }

  // 宁可让一页略超，也不要在段落中间切开：切在中间会让续页把一条普通条目当成大标题。
  const softLimit = Math.round(maxPerPage * 1.15);
  const pages = [];
  let page = { blocks: [], chars: 0 };
  for (const ch of chunks) {
    const c = ch.items.reduce((s, b) => s + cost(b), 0);
    const wouldBlocks = page.blocks.length + ch.items.length;
    if (page.chars && (page.chars + c > softLimit || wouldBlocks > maxBlocks)) { pages.push(page); page = { blocks: [], chars: 0 }; }
    page.blocks.push(...ch.items);
    page.chars += c;
  }
  if (page.blocks.length) pages.push(page);

  return pages.map((p, i) => {
    const first = p.blocks[0] || {};
    // 首条不是标题/主标，说明这页从某一段中间续下来
    const startsMidSection = !["title", "hero", "label"].includes(first.role) || (first.weight !== "hero" && first.level === "body");
    return { ...p, index: i + 1, total: pages.length, startsMidSection };
  });
}

/** 取分区名做可见小标题：「C 六大业务」→「六大业务」。 */
function sectionLabelOf(zone) {
  const z = String(zone || "").replace(/^[A-Za-z]\s*[、.．:：]?\s*/, "").trim();
  return z && z.length <= 12 ? z : "";
}

/** 一次出整套：返回每页的 prompt 与画布决策。 */
function composeSeries({ blocks, maxPerPage = 300, ...rest }) {
  const fmt = planFormat((Array.isArray(blocks) ? blocks : []).reduce((s, b) => s + charCount(b && b.text), 0), (Array.isArray(blocks) ? blocks : []).length);
  const pages = splitIntoSeries(blocks, fmt.mode === "poster" ? Math.max(maxPerPage, fmt.maxPerPage) : fmt.maxPerPage, fmt.maxBlocksPerPage);
  return pages.map(p => {
    // Internal zone names are not approved marketing copy. Never promote
    // them into visible labels (the previous output literally printed 契约).
    const withLabels = p.blocks;
    const built = composePosterPrompt({ ...rest, blocks: withLabels });
    const header = fmt.mode === "series"
      ? `这是系列海报第 ${p.index} 张，共 ${p.total} 张。每张独立完整，不要把其他页的内容塞进这一张。\n` +
        (p.startsMidSection ? "本页是续页：不要从里面挑一条当成大标题放大，用分区标题或留白做视觉锚点。\n" : "")
      : (fmt.mode === "longform" ? `纵向分段长图：每段一个主题，段与段之间用底色切换或大留白断开。\n` : "");
    return { ...built, prompt: header + built.prompt, blocks: withLabels, page: p.index, pages: p.total, chars: p.chars, format: fmt };
  });
}

module.exports = {
  FAMILIES, DENSITY, LEVEL, FAMILY_KEYS, FORMAT,
  normalizeFamily, normalizeDensity, charCount,
  planCanvas, planFormat, splitIntoSeries, composeSeries, layoutPatternFor,
  composeArtDirection, composeInfoLogic, composeTextContract, composePosterPrompt, estimateCost,
};
