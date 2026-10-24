# Skill / Workflow / Tool 调度现状盘点

> 盘点日期：2026-10-24 · 依据：当前工作树（非 ZIP 快照）· 只记录代码里能指到行的事实，推测一律标注「待核验」。
> 本文回答审计文档 §11.2 的 8 个问题，是后续所有改动的起点。

## 1. 一次对话请求的完整链路

```
ChatView（输入）
  → ChatViewModel+Streaming.send()                        ViewModels/ChatViewModel+Streaming.swift
  → ChatService.stream(messages:enableTools:)             Services/ChatService.swift
      · 拼 system prompt = Expert.role + ExpertSkill.promptBlock + ExpertCapability.instruction + metaRule
      · 组装 tools[] 与 tool_choice（只放"有效工具"）
  → POST /api/chat（SSE）                                  cloudfunctions/bf-api/index.js
      → 上游模型（DeepSeek/豆包…）
      → 文本增量原样透传；用量记账
  ← 工具调用请求（tool_calls）
  → ToolPipeline 执行本地工具                              Services/ToolPipeline.swift
      · 失败 → failureNote + reportFailure(/api/tool-event)
      · 成功 → successNote，产物走 persistArtifact
  → 结果回注模型 → 下一轮（循环上限 AppConfig.maxToolIterations = 16）
```

关键事实：

| 事实 | 位置 |
|---|---|
| 工具调用循环上限 16，且二次 `min(16, max(1, maxToolIterations))` 夹紧 | `Config/AppConfig.swift:85`、`ViewModels/ChatViewModel+Streaming.swift:136` |
| 工具全部在**客户端**执行（搜索/生图/文档/图表/资料库/技能），服务端只做对话与记账 | `Services/ToolPipeline.swift`、`ViewModels/ChatViewModel+Streaming.swift` |
| 生图走独立云函数 `/img/*`（`/api/image` 已 503 要求升级） | `cloudfunctions/bf-image/index.js`、`bf-api/index.js` handleImage |

## 2. 工具注册与权限在哪

| 层 | 实现 | 位置 |
|---|---|---|
| 注册表 | `ToolRegistry.plugins`，10 个工具：`web_search` `image_generate` `image_edit` `image_decompose` `image_series` `generate_image` `create_document` `render_chart` `search_library` `expert_skill` | `Services/ToolRegistry.swift:80-215` |
| 可用性开关 | 每个插件带 `availability` 闭包；`image_decompose` 为 `{ false }`（未开放的完整链路） | `ToolRegistry.swift:127`（`availability: { false }`） |
| 有效工具策略 | `EffectiveToolPolicy.forExpert / forExpertID / permits / isVisible`，把「专家声明的工具」与「云端覆盖」求交 | `Services/EffectiveToolPolicy.swift:32-86` |
| 技能级许可 | `ExpertSkillRuntime.permits(name:profile:allowedTools:disabledTools:)`，未知工具 `default: false` | `ExpertCore/ExpertCapabilities.swift:126-151` |
| 云端裁剪 | 云端 `tools[]` 是单一数据源，云端没开的工具不挂（有回归测试） | `Tests/BossAIiOSTests/ToolPermissionTests.swift` |

## 3. 专家与 Skill 的形态

- 专家 = `Expert`（角色 + `ExpertSkill`）+ `ExpertCapability`（能力档案）。
- `ExpertSkill`：`framework / steps / deliverable / tools / checklist / freshnessCue`，渲染成 `promptBlock`。
- `ExpertCapability`：`requiredInputs / workflow / documentSections / documentFormats / calculators / allowSearch / allowImages / knowledge / boundaries`，来自 `ExpertSkills.json`（`version: 1`，当前 **16** 份）。
- 加载即校验：版本必须为 1、ID 非空且唯一、计算器与文件格式必须在白名单内 → 坏配置直接抛错（`ExpertCapabilityCatalog.decode`）。
- 云端目录会**整体替换**内置目录：`RemoteCatalogService.apply` → `ExpertCatalog.applyRemote`。
  ⚠️ 这决定了新增专家必须**同时**改 `ExpertSkills.json`、`Expert.swift`、`bf-api/experts.json` 三处（本轮已按此执行）。

## 4. 现有「智能调度」到什么程度

| 能力 | 现状 | 证据 |
|---|---|---|
| 意图分类 | 无独立分类器，靠专家 system prompt + 元规则约束 | `Expert.metaRule` |
| 任务规划 | 无结构化 plan 对象；`ExpertSkill.steps` 是**提示词级**流程 | `Expert.swift:82-98` |
| 工具选择 | 模型自主 function calling + 权限层过滤 | `ToolPipeline` / `EffectiveToolPolicy` |
| 结果校验 | 仅文档结构校验 `validateDocument`（标题齐全 + 正文 ≥40 字），不判断事实 | `ExpertCapabilities.swift:155` |
| 失败重试 | 插件级 `retryOnTransient`（如生图关、搜索开），其余不重试 | `ToolRegistry.swift` 各插件 |
| 预算控制 | 迭代次数上限 + 服务端额度/预留（`bf_quota_reservations`） | `AppConfig`、`bf-image` |
| 执行日志 | requestId 贯穿客户端 → 服务端（`X-Request-Id` + body `requestId`）；工具失败上报带 requestId/errorCode | `ToolPipeline.swift:143-160` |

## 5. 只读 vs 有副作用

| 类型 | 工具 | 副作用 |
|---|---|---|
| 只读 | `web_search` `search_library` `expert_skill` `render_chart`（本地渲染） | 无外部写入 |
| 计费 | `image_generate` `image_edit` `image_series` | 每次成功调用扣额度（服务端唯一账务事件） |
| 写本地 | `create_document` | 写 App 沙盒文件 + 资料库索引 |
| 未开放 | `image_decompose` | — |

**没有任何工具能发送消息、发布内容、发起支付或写外部系统**——这是当前架构的安全底座，新增 Skill 不得突破。

## 6. 已知风险（本轮不修，如实记录）

1. 没有独立意图分类器：相近意图（"帮我做老板 IP 规划" vs "帮我写条视频脚本"）依赖模型自行选专家，缺可量化兜底。
2. `validateDocument` 只查结构，不能证明事实正确；不得对外宣称"已校验事实"。
3. 云端目录整体替换：若云端种子落后于 App 版本，新专家会"消失"（本轮已同步种子并加契约测试挡）。
4. 视频类能力（下载/ASR/抽帧/剪辑）当前**完全没有执行链**，任何"能分析视频链接"的说法都是假的。

## 7. 测试现状

- Swift：`Tests/BossAIiOSTests`（含 `ToolPermissionTests`、`ShortVideoSkillTests`）+ `Tests/BossAIExpertCoreTests`。
- 后端：`bf-backend/tests` / `tests-backend`，138+ 条，含 `expert-seed-contract`（种子结构）、`log-privacy`、`jobs-cleanup`。
- 缺口：没有真实模型参与的**路由准确率**评测（只有规则/结构测试），见 `04-routing-policy.md` 的评测集设计。
