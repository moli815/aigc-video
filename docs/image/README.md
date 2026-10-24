# 图片能力优化：实施状态

> 对应《BossAI 图片生成能力优化方案》（2026-10-24）十二个章节。
> 本文件只记录**代码里真实存在的状态**，没写的就是不存在的功能。

## 一、已完成（本轮）

| 方案要求 | 落点 | 说明 |
|---|---|---|
| §2.2 图片保存与作品库同步 | `Services/LibraryImageWriter.swift` + `ToolPipeline` 三个落点 | 生图/组图逐张/重试补图都会写 `StoredFile(category: .image)`，按内容哈希去重；写库失败不影响出图与计费 |
| §3 任务类型识别 | `Services/ImageTaskPlanner.swift` | 规则版规划器：文生图 / 编辑 / 参考图 / 海报 / 组图，输出结构化 `ImageTaskPlan` |
| §3.2 统一任务数据结构 | `ImageTaskPlan` | `taskType / intent / prompt / negativeConstraints / referenceCount / aspectRatio / qualityTier / outputCount / textPolicy / preserveOriginal / needsClarification` |
| §3.4 澄清机制 | `ImageTaskPlan.clarification` | 只在"说改图却没给图"或"内容过短"时问一句，其余直接执行 |
| §5 自然语言编辑约束 | `preserveOriginal` + `negativeConstraints` | 编辑任务自动加"不改人物面貌/服装/姿势、不改未指定区域" |
| §6 海报走程序排版 | `textPolicy == .programmatic` | 识别到海报/名片/价格/电话/二维码时，提示词明确禁止模型画字，并标记走排版层 |
| §7.1 基础质量检查 | `Services/ImageQualityChecker.swift` | 空数据/无法解码/尺寸过小/比例偏差/体积异常，返回问题列表而非抛错 |
| §4.1 配置是否真生效 | `GET /img/models`（bf-image） | 返回三档实际 model id、能力位、路由模式；密钥只回布尔 |
| §4.2 服务端自动路由 | 已有 `selectImageRoute` | 能力优先于快慢；series 无模型时明确拒绝，不发必然失败的请求 |

## 二、部分完成

| 项 | 现状 | 缺口 |
|---|---|---|
| §7.3 有限重试 | 已有 `retryOnTransient` + 视觉复检一次 | 未按"可重试/不可重试"细分错误码；保存失败不会触发重存 |
| §3.3 提示词构建 | 只追加**约束**（比例/张数/禁字/保留），不编造画面 | 未做"按任务类型补构图/光线/镜头"的结构化扩写（需要模型或模板库） |
| §5.3 版本管理 | 每次编辑生成新图并各自入库 | 未记录"原图 ID → 新图 ID"的版本链 |

## 三、未做（明确列出，避免误报）

- **`ImageTaskPlanner` 尚未接进聊天主链路**：目前是可选调用（`ImageService.generate(plan:)` 重载），
  聊天工具层仍按原参数调用。接入点在 `ChatViewModel+Streaming` 的 image 分支，属下一批。
- **海报排版引擎**：`HostedAccount.renderPoster` + `PosterComposer` 仍**零调用**；
  现有布局只支持"标题 + 副标题 + 6 条要点"，做不了名片/三栏报纸。需要扩布局模型。
- **局部合成（保真 P 图）**：未实现抠图与位置合成通道。
- **质量检查未接入生成流程**：`ImageQualityChecker` 已可用但尚未在保存前调用。
- **模型注册表**：没有 Swift 侧 `ModelRegistry`。服务端是唯一模型真相（`selectImageRoute`），
  App 只传 `task_kind` / `quality_tier`，避免两套配置打架。要看真实路由请请求 `/img/models`。

## 四、下一批建议顺序

1. 规划器接入聊天 image 分支（用 `plan.prompt` 与 `plan.aspectRatio/outputCount`）。
2. 保存前跑 `ImageQualityChecker`：`undecodable/tooSmall` → 重生成一次；`suspiciouslySmallPayload` → 重下载。
3. 海报：扩 `PosterLayout`（名片 / 三栏）并把 `renderPoster` 接成独立工具 `poster_layout`。
4. 编辑版本链：`StoredFile.parentId` + 编辑历史。
5. 局部合成：Vision 前景分割 + 位置合成，作为"保真 P 图"通道。

## 五、验证方式

- 纯函数单测：`ImageTaskPlannerTests`（12 条）、`ImageQualityCheckerTests`（7 条）、`LibraryImageWriterTests`（5 条）。
- 服务端：`node --test tests/image-models-endpoint.test.js`（3 条）。
- 真机验收：见《最终交付版·真机测试文档》E 组；新增 `/img/models` 自检可作为发布前 smoke。
