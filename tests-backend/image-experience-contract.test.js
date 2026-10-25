// ============================================================================
// 图片体验契约（10-25）：内部文本不入 UI/库、等待态克制、编辑不裁切
//
// 这些断言锁的是「结构性修复」，不是文案：
//   · 图片轮次把模型正文挡在数据流上（不是最后覆盖）
//   · 等待态只有一个轻量组件、没有 Canvas/TimelineView、没有伪预估
//   · 编辑任务的比例只认用户原话，模型自带 aspect_ratio 不算授权
//   · 生成后必须做几何校验，坏比例不展示也不落库
// ============================================================================

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
// 去掉整行注释再断言：注释里讲解"旧实现有约 20 秒"不该被当成代码里还有这句文案
const strip = (src) => src.split("\n").filter((l) => !l.trim().startsWith("//")).join("\n");
const read = (p) => strip(fs.readFileSync(path.join(ROOT, p), "utf8"));

const STREAM = read("BossAI/ViewModels/ChatViewModel+Streaming.swift");
const VM = read("BossAI/ViewModels/ChatViewModel.swift");
const CHATVIEW = read("BossAI/Views/ChatView.swift");
const WAITROW = read("BossAI/Views/ImageWaitingRow.swift");
const STATUS = read("BossAI/Services/ImageTaskStatus.swift");
const GEOM = read("BossAI/Services/ImageGeometry.swift");
const PLANNER = read("BossAI/Services/ImageTaskPlanner.swift");
const SERVICE = read("BossAI/Services/ImageService.swift");
const PIPELINE = read("BossAI/Services/ToolPipeline.swift");

test("IMG-01 图片轮次在数据流上隔离：模型正文不渲染、不落库", () => {
  assert.match(STREAM, /var imageTurnIsolated = false/, "缺少 image-turn 隔离标记");
  // 流式渲染被隔离标记挡住
  assert.match(STREAM, /if !imageTurnIsolated,[\s\S]{0,160}streamingText = assistantText/,
    "隔离期间仍在把模型正文写进 streamingText（会渲染到气泡）");
  // 落库正文只在未隔离时使用 fullText
  assert.match(STREAM, /let visibleText = imageTurnIsolated \? \(imageTurnNote \?\? ""\) : fullText/,
    "落库正文没有被隔离标记控制（模型长文仍可能写进 Message.text）");
  assert.match(STREAM, /assistantMessage\.text = visibleText/);
  // 图片工具一开始就置位
  assert.match(STREAM, /imageTurnIsolated = true/, "图片工具起点未置位隔离");
});

test("IMG-02 旧占位与旧文案已清理（无 prompt 前缀、无施工进度表）", () => {
  assert.doesNotMatch(STREAM, /pendingImage\s*=/, "仍有 pendingImage 赋值");
  assert.doesNotMatch(STREAM, /pendingImageKind/, "仍有 pendingImageKind 分支");
  assert.doesNotMatch(STREAM, /String\(prompt\.prefix\(24\)\)/, "仍把 prompt 前缀当占位文案");
  assert.doesNotMatch(read("BossAI/ViewModels/ChatViewModel.swift"), /pendingImage/,
    "ChatViewModel 仍保留 pendingImage 属性");
  for (const bad of ["约 20 秒", "规划画面", "Pro 生成", "逐张生成"]) {
    assert.doesNotMatch(STREAM + VM + CHATVIEW + WAITROW, new RegExp(bad), `旧文案未清理：${bad}`);
  }
  assert.ok(!fs.existsSync(path.join(ROOT, "BossAI/Views/ImageGenWaitingCard.swift")),
    "旧粒子占位组件仍在仓库里");
});

test("IMG-03 等待态只有一个轻量组件，支持 Reduce Motion，无 Canvas/TimelineView", () => {
  assert.match(CHATVIEW, /ImageWaitingRow\(state: wait\)/, "ChatView 未使用统一的轻量等待组件");
  assert.match(WAITROW, /accessibilityReduceMotion/, "未处理 Reduce Motion");
  assert.match(WAITROW, /isLowPowerModeEnabled/, "未处理低电量模式");
  assert.doesNotMatch(WAITROW, /Canvas|TimelineView/, "等待组件里仍有画布/时间轴动画");
  assert.doesNotMatch(WAITROW, /repeatForever[\s\S]{0,40}TimelineView/);
  // 文案唯一来源
  assert.match(STATUS, /case \.generate:\s*return "正在生成图片"/);
  assert.match(STATUS, /case \.edit:\s*return "正在处理图片"/);
  assert.match(STATUS, /case \.textOverlay:\s*return "正在整理图片"/);
  assert.match(STATUS, /static let doneText = "图片已生成"/);
  assert.match(STATUS, /case \.generateFailed: return "图片生成失败，请重试"/);
  assert.match(STATUS, /case \.aspectMismatch: return "原图无法完整保留，请重新选择比例"/);
});

test("IMG-04 编辑任务比例只认用户原话，模型自带 aspect_ratio 不算授权", () => {
  assert.match(PLANNER, /userSaid: String\? = nil/, "规划器未接收用户原话");
  assert.match(PLANNER, /let userRatio = firstAspectToken\(in: userLowered\)/,
    "未从用户原话里解析比例");
  assert.match(PLANNER, /let modelRatio = normalizeAspect\(aspectRatio\)/, "未区分模型给的比例");
  assert.match(PLANNER, /if let userRatio \{[\s\S]{0,400}allowCrop = true/,
    "允许裁切的分支没有绑定到用户原话");
  // 编辑任务不能再落到 1:1 默认
  const editBranch = PLANNER.slice(PLANNER.indexOf("if editLike {"), PLANNER.indexOf("} else {", PLANNER.indexOf("if editLike {")));
  assert.ok(!/ratio = "1:1"/.test(editBranch), "编辑分支仍会把比例写死成 1:1");
  assert.match(editBranch, /targetSize = clamped/, "编辑分支未按原图像素要尺寸");
  assert.match(editBranch, /preserveAspect = true/, "编辑分支未声明保留原图比例");
});

test("IMG-05 显式尺寸一路透传到请求体，且优先于 aspect_ratio", () => {
  assert.match(SERVICE, /let targetSize: String\?/, "上下文缺少 targetSize");
  assert.match(SERVICE, /if !explicitSize\.isEmpty \{[\s\S]{0,80}body\["size"\] = explicitSize/,
    "请求体没有把显式尺寸写进 size");
  assert.match(SERVICE, /else if let aspectRatio, !aspectRatio\.isEmpty \{[\s\S]{0,60}body\["aspect_ratio"\]/,
    "有显式尺寸时仍会同时发 aspect_ratio（服务端会按预设比例重新构图）");
  assert.match(STREAM, /targetSize: plan\.targetSize/, "调用点未把 targetSize 带进上下文");
});

test("IMG-06 固定比例兜底：补边 + 生成后裁回原构图", () => {
  assert.match(GEOM, /static func composePaddedReference/, "缺少补边实现");
  assert.match(GEOM, /static func cropBack/, "缺少回映射实现");
  assert.match(GEOM, /static func nearestSupportedRatio/, "缺少最近支持比例");
  assert.match(STREAM, /paddingRect = padded\.contentRect/, "调用点未记录内容区");
  assert.match(STREAM, /ImageGeometry\.cropBack\(raw, contentRect: rect\)/, "生成后未裁回原构图");
  assert.doesNotMatch(GEOM + STREAM + PLANNER, /centerCrop|center_crop/, "仍存在中心裁切路径");
});

test("IMG-07 生成后几何校验：坏比例不展示、不落库、明确失败", () => {
  const idxCheck = STREAM.indexOf("ImageGeometry.isAspectBroken");
  const idxPersist = STREAM.indexOf("ToolPipeline.persistArtifact");
  assert.ok(idxCheck > 0 && idxPersist > idxCheck, "几何校验必须在落库之前");
  assert.match(STREAM, /imageTurnNote = ImageTaskStatus\.Failure\.aspectMismatch\.message/,
    "疑似裁切时未给出明确失败文案");
  assert.match(STREAM, /"paddingApplied":/);
  assert.match(STREAM, /"cropDetected":/);
  assert.match(STREAM, /"sourceAspect":/);
});

test("IMG-08 文字密集任务：底图禁字 + 只由程序排版一次 + 失败复用底图", () => {
  assert.match(STREAM, /画面内不得出现任何文字、字母、数字、标语或水印/, "底图约束缺失");
  assert.match(STREAM, /TextOverlayRenderer\.render/, "缺少程序排版");
  assert.match(STREAM, /cache\.retainAfterOverlayFailure\(conversationId:/, "排版失败未保留底图（会再调 Pro）");
  assert.match(STREAM, /imageData = png/, "排版成品未作为最终结果");
  assert.match(read("BossAI/Services/BaseImageCache.swift"), /conversationId: String, taskId: String/,
    "缓存未按会话+任务隔离");
});

test("IMG-09 工具回注不诱导模型长篇解释（不再需要模型转述失败原因）", () => {
  assert.match(PIPELINE, /禁止建议用户「去 Canva \/ 用 PPT/, "失败回注未禁止把任务推回给用户");
  assert.match(PIPELINE, /禁止向用户解释技术原因、字段名、模型名、比例参数、requestId/);
  assert.match(PIPELINE, /给用户的回复只允许一句话/);
});
