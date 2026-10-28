const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const imageFunction = read("cloudfunctions/bf-image/index.js");
const apiFunction = read("cloudfunctions/bf-api/index.js");
const stream = read("BossAI/ViewModels/ChatViewModel+Streaming.swift");
const chatViewModel = read("BossAI/ViewModels/ChatViewModel.swift");
const planner = read("BossAI/Services/ImageTaskPlanner.swift");
const resolver = read("BossAI/Services/ImageReferenceResolver.swift");
const chatService = read("BossAI/Services/ToolManifest+Schema.swift");
const imageService = read("BossAI/Services/ImageService.swift");
const baseImageCache = read("BossAI/Services/BaseImageCache.swift");
const mediaGuards = read("cloudfunctions/bf-image/media-guards.js");
const candidatesStart = chatViewModel.indexOf("func imageReferenceCandidates");
const candidatesEnd = chatViewModel.indexOf("func attachedImageData", candidatesStart);
const referenceCandidates = candidatesStart >= 0 && candidatesEnd > candidatesStart
  ? chatViewModel.slice(candidatesStart, candidatesEnd).replace(/^\s*\/\/.*$/gm, "")
  : "";
const structuredSchemaStart = chatService.indexOf("private static let imageStructuredSchema");
const structuredSchemaEnd = chatService.indexOf("/// ① 新作品生成", structuredSchemaStart);
const imageStructuredSchema = structuredSchemaStart >= 0 && structuredSchemaEnd > structuredSchemaStart
  ? chatService.slice(structuredSchemaStart, structuredSchemaEnd)
  : "";

test("reference redesign has a distinct semantic task and retains the selected source", () => {
  assert.match(stream, /ImageReferenceResolver\.resolve\([\s\S]{0,350}attachedImages: attachedCandidates/);
  assert.match(stream, /return ImageService\.taskKind\(for: plan\.taskType\)/);
  assert.match(planner, /userLowered \+ "\\n" \+ lowered/);
  assert.match(planner, /重新设计/);
  assert.match(imageService, /case \.reference: return "reference"/);
});

test("reference-based generation tool can explicitly select an attached image", () => {
  assert.match(chatService, /name": "image_generate"/);
  assert.match(chatService, /source_index/);
  assert.match(resolver, /images\[oneBasedIndex - 1\]/);
  assert.match(resolver, /Invalid model output fails closed/);
  assert.match(resolver, /sourceOverride/);
  assert.match(stream, /resolvedToolSource/);
  assert.match(referenceCandidates, /currentFiles\.map \{ file in[\s\S]{0,260}\?\? Data\(\)/);
  assert.doesNotMatch(referenceCandidates, /compactMap/);
  assert.match(chatService, /"required": \["prompt"\]/);
});

test("text overlay background excludes visible copy while retaining visual structure", () => {
  assert.match(imageService, /forTextlessBackground\(items:/);
  assert.match(imageService, /visualFields\.removeValue\(forKey: "text"\)/);
  assert.match(stream, /structuredArgs\?\["text"\]/);
  assert.doesNotMatch(stream, /for \(key, value\) in st/);
});

test("only pixel edits receive edit boundaries; pixel similarity is diagnostic only", () => {
  assert.match(imageFunction, /const isPixelEdit = !!image && String\(taskKind \|\| ""\) === "edit"/);
  // 10-26：finalPrompt 多了"底图无字"这一层；10-28 又在最前面加了多图编号契约。
  // 三段拼接顺序固定：多图编号 → 用户 prompt → 无字约束 → 任务边界。EDIT_CONSTRAINTS 仍只给像素编辑。
  assert.match(imageFunction, /const finalPrompt = multiImageContract\(image, referenceRoles, taskKind\)\s*\n\s*\+ basePrompt \+ \(needsNoText \? NO_TEXT_CONSTRAINTS : ""\) \+ taskPolicy/);
  assert.match(imageFunction, /const taskPolicy = isPixelEdit[\s\S]{0,160}EDIT_CONSTRAINTS/);
  assert.match(imageFunction, /if \(out\.ok && body\.image && taskKind === "edit"\)[\s\S]{0,400}decision: "diagnostic_only"/);
  assert.doesNotMatch(imageFunction, /edit_over_redraw_retry/);
  assert.doesNotMatch(imageFunction, /逐像素保持一致，禁止整体重绘/);
  assert.match(imageFunction, /const REFERENCE_CONSTRAINTS =/);
  assert.doesNotMatch(imageFunction, /原图的构图、人物、背景、色调、光线和所有文字必须完全不变/);
  assert.match(imageFunction, /若用户要求更换背景、色调或光线，则允许对应部分发生变化/);
});

test("the Agent prompt is the only visual prompt source; the backend does not rewrite it", () => {
  assert.match(planner, /prompt: text/);
  assert.doesNotMatch(planner, /buildPrompt\(/);
  assert.doesNotMatch(imageFunction, /enhancePrompt\(/);
  assert.match(chatService, /唯一完整的视觉指令/);
});

test("business-card wording does not create a hidden image task, ratio, render, or quality branch", () => {
  assert.doesNotMatch(planner, /posterWords|case \.poster/);
  assert.doesNotMatch(imageFunction, /inferRenderIntent/);
  assert.doesNotMatch(mediaGuards, /PRINT_INTENT_RE\s*=\s*\/[^\n]*名片/);
  assert.match(chatService, /不要根据固定素材类别套用档位/);
});

test("bf-api image instructions agree with the image tool contract", () => {
  assert.match(apiFunction, /重新设计整张作品时，用 image_generate/);
  assert.match(apiFunction, /明确局部改动时用 image_edit/);
  assert.match(apiFunction, /需逐字准确显示的文字只放 structured\.text/);
  assert.match(apiFunction, /不得根据“左侧\/中间”等自然语言臆造坐标/);
  assert.doesNotMatch(apiFunction, /必须先调用 image_edit 工具/);
  assert.doesNotMatch(apiFunction, /必须按 6 段写|80-150 字/);
  assert.doesNotMatch(apiFunction, /必须换算成归一化坐标用 bbox 圈出/);
});

test("exact visible copy is typed instead of flattened into one body paragraph", () => {
  assert.notEqual(imageStructuredSchema, "", "image schema section must exist");
  assert.match(imageStructuredSchema, /"text": \[[\s\S]{0,180}"type": "array"/);
  assert.match(imageStructuredSchema, /按标题\/副标题\/正文\/标签\/联系方式\/页脚拆成多项/);
  assert.match(stream, /TextItem\.parse\(structuredArgs\?\["text"\]\)/);
  assert.match(baseImageCache, /TextItem\.values\(from: context\.structured\?\["text"\]\)/);
  assert.match(imageFunction, /visibleCopyValues\(structured && structured\.text\)/);
  assert.match(imageFunction, /画面中必须准确呈现以下文字/);
});

// ── 2026-10-26：海报/重设计质量事故（截图：重设计结果≈原图 + 乱码小字）────────────
test("reference redesign forbids replicating the source layout/colors", () => {
  const start = imageFunction.indexOf("const REFERENCE_CONSTRAINTS");
  const end = imageFunction.indexOf("function readBody", start);
  const block = imageFunction.slice(start, end);
  assert.ok(start > 0, "缺少 REFERENCE_CONSTRAINTS");
  assert.match(block, /必须重新设计整张作品/, "没要求重做整张");
  assert.match(block, /不复刻参考图的布局/, "没禁止复刻版式");
  assert.match(block, /用户要求的新风格优先级最高/, "没把用户的新风格设为最高优先");
  assert.match(block, /不得出现/, "没处理用户明确否定的风格");
});

test("base image is wordless in overlay mode and never gets copy appended back", () => {
  const start = imageFunction.indexOf("const overlayMode");
  const end = imageFunction.indexOf("const resolvedSize", start);
  const block = imageFunction.slice(start, end);
  assert.ok(start > 0, "缺少 overlayMode 判定");
  assert.match(imageFunction, /const NO_TEXT_CONSTRAINTS/, "缺少无字约束常量");
  assert.match(block, /if \(rawPrompt && !overlayMode\)/, "overlay 模式仍会把精确文案追加回底图 prompt");
  assert.match(block, /needsNoText/, "缺少无字判定");
  assert.match(block, /NO_TEXT_CONSTRAINTS/, "无字约束没有被拼进 finalPrompt");
});

test("client sends text_mode=overlay so the server can strip copy", () => {
  const compiler = read("BossAI/Services/ImageProviderRequestCompiler.swift");
  assert.match(compiler, /body\["text_mode"\] = textMode/, "hosted envelope 没有透出 text_mode");
  assert.match(imageService, /textMode: textMode/, "ImageService 没有把 textMode 传给编译器");
  assert.match(imageService, /textMode: \.overlay/, "无字底图没有声明 overlay");
  assert.match(read("BossAI/Services/ImageUseCase.swift"), /textMode: context\.textMode == \.overlay \? "overlay" : nil/,
    "重试入口必须从同一上下文读取文字模式");
});

test("reference redesign uses the high quality tier", () => {
  assert.match(planner, /case \.reference: return "high"/, "参考图重设计仍走低档，细节会明显掉");
});
