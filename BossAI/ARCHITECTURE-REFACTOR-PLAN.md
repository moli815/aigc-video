# App 与 CloudBase 架构收敛方案

日期：2026-10-26  
范围：iOS App、Agent/工具层、图片生成链路、CloudBase HTTP Functions  
原则：先建立模块边界和可观测契约，再逐条迁移；不以复制 Hermes 项目或批量删文件代替架构治理。

## 目标

目前的问题不是单纯“文件行数太长”，而是同一业务规则在多个层重复表达，且上游与下游对任务语义理解不同。优化目标是让每项能力拥有一个明确入口、一份请求契约、一处路由决策和一个结果出口：

1. UI 只采集意图、展示进度和产物，不决定模型路由或图像引用。
2. Agent Runtime 负责一次会话轮次、工具调用循环和取消；不承载每个工具的具体业务流程。
3. Tool Manifest 是工具名称、schema、可用性、权限、超时和失败策略的唯一来源；Dispatcher 只分发，不重复定义能力规则。
4. 每项能力各有一个 use case（Image / Research / Document / Library），调用 Provider 或 CloudBase adapter，并通过统一 Artifact/Result contract 返回。
5. Cloud Functions 的 HTTP router 只做路径、鉴权和 envelope；业务域各自拥有 handler/use case/repository，不继续把新功能塞入 `index.js`。
6. 旧接口先变薄并记录使用情况；只有确认旧版本客户端和管理端不再调用，才删除。

## 当前架构审计（代码证据）

### iOS

- XcodeGen 的 App target 将 `BossAI/` 下全部 Swift 文件编入同一个 App target，当前没有 App 内模块边界。
- `ChatViewModel+Streaming.swift` 的 `runLoop` 同时编排搜索、模型流、工具权限、图片请求、文字合成、产物落库和重试；工具 switch 是主要耦合点。
- `ChatService.swift` 持有模型工具 JSON schema，`ToolRegistry.swift` 持有能力说明和限制，`EffectiveToolPolicy.swift` 再判权限，`ExpertCapabilities.swift` 还有一份能力约束，执行器又用字符串 switch；“ToolRegistry 是唯一来源”的注释与真实结构不一致。
- `ImageTaskPlanner`、`ImageRequestContext`、图片工具 schema、`ImageService` 与服务端 `bf-image` 都会解释图片任务或改写 prompt；目前没有一个可审计的最终 `ImageJob` 契约。
- 应保留已有的领域服务和 ViewModel extensions；它们并非全部坏代码。重构重点是消除职责重复和隐式数据来源，不是按文件大小删除。

### CloudBase

- `bf-api/index.js` 同时承载 auth/secrets、账号/会员、计费、对话代理、同步删除、后台/管理接口、搜索/视觉等多个域；扩展时容易污染公共状态与错误处理。
- `bf-image/index.js` 同时承载 HTTP 路由、鉴权、配置、模型路由、幂等/额度/账务、组图状态、prompt 拼装、上游调用和图像相似度策略。
- `bf-jobs/index.js` 相对独立，应继续只作为定时任务入口。
- `log-safe.js` 在三个函数中有重复副本，`error-catalog.js` 在两个函数中重复；目前靠人工保持一致，存在漂移风险。
- HTTP function 的启动约定、响应 envelope、鉴权、幂等、扣费与错误码均属于线上契约。拆文件时必须保留契约，不能顺手重命名或删除旧路由。

## 图片纵向链路：唯一业务契约

```text
本轮用户文字 + 按原顺序排列的图片附件
        ↓
Agent 选择 ImageJob 意图（generate / reference / edit / series）
        ↓
ImageReferenceResolver 选择明确的 source 与 1-based source_index
        ↓
ImageTaskPlanner 只负责比例/保留边界/质量/任务约束
        ↓
ImageRequestContext（当前的不可变请求载体；后续收敛为带类型校验的 ImageJob）
        ↓
ImageService 或 Hosted Image API adapter
        ↓
bf-image：校验 → 路由 → provider payload → 上游 → 幂等/账务 → 统一结果
        ↓
可选文字后处理（只读取 visibleCopy，不读取视觉指令）→ ArtifactRepository 落库
```

`reference` 与 `edit` 必须是不同语义：两者都可以把图片发给 Seedream；`reference` 是以源图为参考重新创作，不能追加“逐像素不变”约束，也不能触发“输出与原图相似度太低就自动重画”；`edit` 才是只改指定区域并保护其他区域。`generate` 不传图。组图独立编排，但仍复用相同的单图子任务契约。

文字后处理仅消费明确的 `structured.text`（后续可演进为 `visibleCopy[]`），`subject/setting/composition/lighting/material/negative/layout` 都是视觉指令/布局元数据，绝不允许流入可见文案。底图请求必须从 prompt 和 structured payload 中去掉精确文案，并只保留视觉方向与“无字底图”约束。

编辑默认继承源图画布比例；只有用户明确要求改变比例或裁切时才允许改比例。输出宽高比校验只证明画布几何相符，不能证明主体或边缘内容未丢；要通过固定参考素材的视觉回归验证语义保留。

### 本轮源码审计确认的根因与已收敛项

- `bf-api` 的历史系统提示曾与工具 schema 冲突：它要求所有图片修改走 `image_edit`、把所有 prompt 固定成六段且 80–150 字、把准确文字写进 prompt，并要求模型必须臆造 `<bbox>` 坐标；这会把整图重设计误分到局部编辑、让文案同时进入视觉 prompt 与排版字段，并诱发假坐标。现已统一成按意图选择工具、`structured.text` 独立承载准确文字、没有明确坐标来源就不伪造坐标。
- App 侧 `ImageTaskPlanner` 不再重写 Agent prompt；`bf-image` 不再暗中调用第二个聊天模型“增强”prompt。服务端只补 provider/task 必需约束，不再重新组织视觉描述。
- 参考图选择改成明确的 `source` + 一起对齐的 1-based `source_index`；缺失附件直接失败，不再静默退化成纯文生图。
- `reference` 与局部 `edit` 采用不同策略；编辑图像的全局像素相似度降为诊断数据，不再因背景变化而自动再调一次昂贵模型。
- 可见文案改为按 title/subtitle/body/label/contact/footer 的 typed items；无字底图会剔除这些原文，再只合成一次。
- 等待视图当前是轻量状态行与呼吸点，不再保留 30fps 粒子 Canvas；它不是这轮新增的动画框架。

### 明确未声称解决的边界

- 比例相同不等于内容完整：当前几何校验不能识别模型在同宽高比内重构、移动或裁掉主体。Seedream 官方接口虽支持参考图输入与尺寸参数，但不能仅靠请求参数保证语义级像素保真；局部编辑需以固定素材做视觉回归，必要时增加用户框选/蒙版作为独立能力。
- 极端尺寸如果无法在 Provider 像素预算内表达，现在明确要求用户换图或授权改比例；不再使用“补边再裁回”兼容路径，避免后处理再次裁掉用户原图边缘。
- 当前请求载体 `ImageRequestContext` 仍有字符串 taskKind 与多个可选几何字段，`ToolRegistry`、`ChatService`、权限策略和流式执行器也仍保留重复工具描述/分发。图片链路已减少语义冲突，但全 App 尚未完成 Hermes 式 Manifest/Dispatcher 模块化。
- 本轮没有把 `bf-api`、`bf-image` 拆成新文件，也没有线上部署；大文件拆分应在行为契约固定后逐域迁移，避免边拆边改业务行为。

### 本轮已完成的图片链路范围

这是第一条纵向切片，不是“全仓架构重写完成”：图片请求来源解析、任务语义/几何规划、不可变请求上下文、精确文案结构、底图缓存指纹、Seedream 请求策略及后端相似度行为已有源码改动和契约测试；Node 后端全套测试通过后，仍需 GitHub iOS 构建、真机参考图视觉回归与独立的后续模块迁移。

## Hermes 的借鉴边界

Hermes 值得借鉴的是运行时边界，而不是把 Python agent 移植进 Swift：中心化 Agent loop、单一工具注册/分发、集中 Provider 解析、工具结果与错误边界、会话状态持久化。Hermes 的图片工具也用一个清晰的图片能力契约处理生成和带参考图编辑；Provider 侧再映射到各自 API。

本项目应按 iOS/CloudBase 技术栈实现相同原则：`AgentRuntime` + `ToolManifest/Dispatcher` + 垂直 Use Cases + Provider adapters。Seedream API 本身已经支持 prompt 与一个或多个参考图；App 侧不应把同一参考图请求重新解释成“无图文生图”或“像素级局部编辑”。

参考：

- [Hermes Agent architecture](https://hermes-agent.nousresearch.com/docs/developer-guide/architecture)
- [Hermes agent loop](https://hermes-agent.nousresearch.com/docs/developer-guide/agent-loop)
- [Hermes tools runtime](https://hermes-agent.nousresearch.com/docs/developer-guide/tools-runtime)
- [Hermes image generation](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/image-generation.md)
- [Hermes image-generation provider plugins](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/image-gen-provider-plugin.md)
- [ByteDance Seedream sample](https://github.com/bytedance/agentkit-samples/blob/main/skills/byted-seedream-image-generate/SKILL.md)
- [Volcengine Ark image generation API](https://docs.volcengine.com/docs/ark/image-generation-api?lang=zh&redirect=1)

## 分阶段迁移（每阶段都能独立回滚）

### A. 图片请求契约（当前优先）

- 明确 `generate/reference/edit/series` 语义；reference 和 edit 不能共享服务端像素相似度策略。
- 图片源索引与多模态上下文使用同一附件顺序；禁止隐式选“最近三条历史消息里的第一张”。
- `structured.text` 与视觉结构字段隔离；无字底图请求移除文案，不重复暴露给生成模型。
- 给 Planner、Resolver、请求体编译器及服务端 `generate` 增加单测和契约测试。
- 为每个请求记录脱敏的 requestId、taskKind、sourceCount、ratio、provider/model、阶段耗时、retry reason 和扣费状态；不记录图片、prompt 正文、token 或原始请求头。

### B. Agent/工具架构

- 建 `ToolManifest` 数据结构，从同一份声明生成 provider schema、权限过滤、系统能力摘要、超时和错误处理策略。
- 将 `runLoop` 拆成 `ChatTurnRunner`（loop/取消/持久化协调）和 `ToolDispatcher`；每个领域工具迁入 `ImageUseCase`、`ResearchUseCase`、`DocumentUseCase` 等。
- 结果采用统一 `ToolResult`，产物统一经过 `ArtifactRepository` 保存；失败/重试/取消语义由结果类型表达，避免不同分支手工拼字串。
- 分离 ViewModel UI state 与执行状态，避免 `runLoop` 直接承担进度展示策略。

### C. CloudBase 分域

- `bf-api` 保留轻量 router/bootstrap，把 account/auth/billing/chat/sync/admin/search 分域迁移到独立模块；每次只迁一个域，旧路由作为 adapter 调用新 use case。
- `bf-image` 拆为 `http/router`、`application/generate-image`、`domain/routing-capabilities`、`domain/idempotency-billing`、`providers/seedream`、`observability`；优先拆文件，不先改变行为。
- 公共 logger/error catalog 用可重复构建的本地 shared package 或部署前打包步骤生成，避免线上函数依赖跨目录运行时路径。
- `bf-jobs` 只保留 scheduler adapter 与独立 job use cases。
- 分域后先跑 contract tests，再部署 staging/canary；本次工作不直接部署生产云函数。

### D. 移除修复绷带与遗留模块

候选项只有在源码调用图、Xcode target、CloudBase 路由、旧版 App 支持期限、管理端调用和线上日志均证明无消费者后才删除。包括旧 poster renderer、旧 image route、legacy tool name、重复错误处理与未使用 UI。不能因为搜索某一个文件里“零命中”就断言全系统死代码。

## 验收标准

- 结构：图片执行器不再拥有引用图历史搜索、文字提取和服务端策略分叉；工具契约唯一；新增图片任务只需新增一个明确的任务策略/Provider capability。
- 正确性：至少覆盖 text-to-image、reference redesign、局部 edit、两张附件选择、附件不存在 fail-closed、文字底图不含文案、reference 不触发 pixel-edit retry、比例保持/显式裁切、409 幂等、额度与取消。
- 可靠性：Swift 单测、后端单测、CloudBase contract tests、iOS Release build 全绿；CI 产出的 IPA commit 与审计 commit 一致。
- 线上：先只部署 staging 并用真实请求 ID 核对日志；生产部署需单独确认。

## 本轮变更边界

本轮先修复已由源码确认的断链：图片来源契约、reference/edit 语义、可见文案边界；同时保持现有路由、账号、计费与同步契约不变。云函数只做源码改造与测试，不做在线部署。若没有测试素材或 CI 运行权限，明确标注未验证，不把静态检查写成验收通过。
