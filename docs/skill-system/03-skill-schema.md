# BossAI Skill 定义格式（现状契约 + 最小扩展）

> 结论先行：**不引入新的 Skill 框架**。现有两套结构已经够用——
> `ExpertSkill`（提示词级工作法）+ `ExpertCapability`（可校验的能力契约）。
> 本文只把它们的关系、字段约束和扩展规则写清楚，避免以后各改一份造成漂移。

## 1. 两层结构

| 层 | 载体 | 作用 | 是否可校验 |
|---|---|---|---|
| 工作法层 | `ExpertSkill`（写在 `Models/Expert.swift`，云端镜像在 `bf-api/experts.json`） | 告诉模型"按什么步骤干、交付前自检什么" | 否（进 system prompt） |
| 能力契约层 | `ExpertCapability`（`ExpertCore/Resources/ExpertSkills.json`） | 限定"必须有什么输入、能用什么计算器/文档格式/工具" | **是**（加载即校验 + 运行时裁决） |

一次请求的 system prompt 由四段拼成：

```
Expert.role（人设与职责边界）
+ ExpertSkill.promptBlock（框架 / 步骤 / 自检 / 时效性 / 产出物）
+ ExpertCapability.instruction（必要输入 / 执行步骤 / 计算器 / 章节 / 知识卡 / 边界）
+ ExpertCatalog.metaRule（全局铁律：数据真实性、工具使用、多实体收集规范）
```

## 2. `ExpertSkills.json` 字段规范（version = 1）

| 字段 | 类型 | 约束（加载时校验） | 说明 |
|---|---|---|---|
| `id` | string | 非空、全局唯一 | 必须与 `Expert.id` 一致 |
| `name` | string | 非空 | 展示名 |
| `requiredInputs` | string[] | 可空 | 缺项时模型必须列为"待补充"，不得编造 |
| `workflow` | string[] | 建议 ≥3 步 | 渲染成有序步骤 |
| `documentSections` | string[] | 可空 | 导出文档的必需章节（`validateDocument` 用） |
| `documentFormats` | string[] | ⊆ `word/ppt/excel/pdf` | 越界直接抛配置错误 |
| `calculators` | string[] | ⊆ `BusinessCalculators.names` | 越界直接抛配置错误 |
| `allowSearch` | bool | — | 与云端 `tools[]` 求交生效 |
| `allowImages` | bool | — | 同上 |
| `knowledge` | {title, rules[]}[] | 可空 | 注入 prompt 的口径卡片 |
| `boundaries` | string[] | 建议非空 | 能力边界，必须包含"不承诺结果"类声明 |

`BusinessCalculators.names` 现有 12 个：`weighted_decision` `unit_economics` `marketing_funnel` `equity_dilution` `cash_runway` `commission` `speech_duration` `content_roi` `risk_exposure` `coverage_need` `loss_prevention_roi` `protection_budget`。

## 3. `Expert` / `ExpertSkill` 字段规范（Swift）

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` `name` `subtitle` `symbol` `role` | String | `role` 里必须写清**与相邻专家的职责边界**（越界要交接） |
| `framework` | String | 方法论名称，一行 |
| `steps` | [String] | 有序工作流，写进 prompt |
| `deliverable` | `DocumentFormat?` | 用户要文件时的默认格式 |
| `tools` | [ExpertTool] | `search/image/word/ppt/excel/pdf`；实际生效还要过云端裁剪 |
| `checklist` | [String] | 交付前自检项 |
| `freshnessCue` | String | 什么情况下必须联网；空串表示不强制 |
| `emoji` | String? | 云端可覆盖的图标 |

## 4. 新增一个专家的三处同步（硬性）

1. `BossAI/Models/Expert.swift`：新增 `Expert(...)`，并放进 `experts` 数组（注意 `reorderedExperts` 取 `suffix(4)`，插错位置会改动首页顺序）。
2. `BossAI/ExpertCore/Resources/ExpertSkills.json`：新增同 id 的 profile。
3. `cloudfunctions/bf-api/experts.json`：新增同 id 条目 + `starters`，并把 `EXPERTS_SEED_VERSION` +1。
   ⚠️ 少这一步的后果：**本地正常、用户登录后新专家消失**（云端目录整体替换内置目录）。

拦截手段：
- `Tests/BossAIiOSTests/ShortVideoSkillTests.swift`：本地目录 ID 集合 == 能力档案 ID 集合。
- `bf-backend/tests/expert-seed-contract.test.js`：云端种子结构完整、ID 唯一、starters 全覆盖、版本号 ≥3。

## 5. 「JSON 自称结构化」不算结构化

若某个 Skill 要求模型输出 JSON：

- 必须在代码侧用 `Codable` 解码 + 字段校验，失败要回注错误让模型重试**一次**；
- 不得只靠提示词写「请输出 JSON」就宣称具备结构化能力；
- 现有 `validateDocument` 只做标题结构校验，**不判断事实正确性**，对外表述必须如此。

## 6. 扩展规则（防止框架膨胀）

- 需要新的**计算器** → 加到 `BusinessCalculators` 并进 `names` 白名单（有测试兜底）。
- 需要新的**文档格式** → 同时改 `ExpertCapabilityCatalog.decode` 的白名单与导出链路。
- 需要新的**工具** → 走 `ToolRegistry` 注册 + `ExpertSkillRuntime.permits` 分支 + `EffectiveToolPolicy`，**不要**在 Skill JSON 里写工具名绕过权限层。
- **不允许**为了某个 Skill 单独引入第二套运行时、第二套工具白名单或第二套日志系统。
