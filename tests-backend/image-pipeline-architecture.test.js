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
const chatService = read("BossAI/Services/ChatService.swift");
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
  assert.match(chatService, /"required": \["prompt", "structured", "aspect_ratio"\]/);
});

test("text overlay background excludes visible copy while retaining visual structure", () => {
  assert.match(imageService, /forTextlessBackground\(items:/);
  assert.match(imageService, /visualFields\.removeValue\(forKey: "text"\)/);
  assert.match(stream, /structuredArgs\?\["text"\]/);
  assert.doesNotMatch(stream, /for \(key, value\) in st/);
});

test("only pixel edits receive edit boundaries; pixel similarity is diagnostic only", () => {
  assert.match(imageFunction, /const isPixelEdit = !!image && String\(taskKind \|\| ""\) === "edit"/);
  assert.match(imageFunction, /const finalPrompt = basePrompt \+ taskPolicy/);
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
