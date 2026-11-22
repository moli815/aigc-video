# 近两周对话复盘 · 专家 / Skill 全链路审计与优化台账

> 北京时间 2026-11-10 22:2x · 只读审计基线 `e73d5e2` + 当前未提交改动（线上为 21:52 已发布版本）
> **本轮状态：只完成审查与方案，未修改产品代码、未部署、未出包、未调用任何付费模型。**
> 本文按「位置 / 影响 / 原因 / 建议 / 优先级 / 验证方式 / 是否需 IPA」组织；第 8 节留作逐条实施结果回填。

---

## 0. 数据来源、口径与诚实边界

| 项 | 实际情况 |
|---|---|
| 云端历史会话检索 | `conversation_search` 三次检索（含 10-27～11-10 限定、无日期、短范围）**均返回 0 条**，其中一次 HTTP 400。服务端会话索引当前不可用，**没有拿到逐字对话全文**。 |
| 替代证据 | 本地工作区记忆日志：`2026-10-24/25/26/27/28.md`、`2026-11-03.md`、`2026-11-10.md`、`MEMORY.md`；这些是每日工作记录，覆盖近两周全部工作节点，但不是原始聊天记录。 |
| 代码证据 | 本地 HEAD `e73d5e2` + `git status` 的未提交改动；线上状态以 `outputs/release-20261110/release.json` 为准。本文所有关键断言均已用 `Grep` 逐条复核（见第 2/3 节行号）。 |
| 平台 Skill | `skill_management list` 返回**空**：当前账号没有用户自行安装且启用的 Skill。本会话可用 Skill 全部由 builtin / plugin 提供（如 weixinpay、tencent-docs、pptx、docx、sheetagent 等），不在本轮可改范围，也不存在「用户自装 Skill 调用异常」。 |
| **「Skill」口径** | 本项目里用户所说的 skill / 技能，**指 App 内 AI 助手可调用的工具**（`ToolRegistry` / `ToolManifest+Schema` / `ExpertSkills.json` / `ToolPipeline` / `ToolClaimGuard`，仓库另有 `docs/skill-system/` 六份设计文档），不是 WorkBuddy 平台 Skill。下文统一称「工具」。 |

**结论先行：专家模块是「部分优化、端到端未闭环」；工具调用仍存在 2 个会直接复现「skill 调不起来」的 P0。用户近两周反复发火的根因，至今没有被根治。**

---

## 1. 近两周对话复盘：反复出现的是同一类问题

| 日期 | 事件（用户视角） | 真正根因 | 现状 |
|---|---|---|---|
| 10-23/24 | 「当前专家配置里禁用了图片生成」、回复说已生成却没图 | 提示词写「必须调用工具」，运行时无对账 → 谎报 | `ToolClaimGuard` 已加，但**只覆盖图片，不覆盖 `create_document`** |
| 10-24 | `image_series availability:false` → 工具从不下发给模型，云端 prompt 却命令「一组多张→image_series」 | 能力开关与提示词两套语义 | **已修**（availability=true） |
| 10-27 | `pro_only` 无条件设 `optimize_prompt_options=standard`，改写掉编辑/参考图的「保持构图」硬约束 | 参数未按场景分派 | **已修**（有参考图一律删除该字段） |
| 10-28 | `both` schema 描述写「双图融合」，实现是「上次生成图＋一张附件」→ 静默丢人物照 | **schema 描述与实现语义不一致，且不报错** | **已修**（`source_indexes` / `reference_roles` / 强制 `source=attached`） |
| 11-03 | 断流错误把 `{code=...}` / `\UXXXX` 中文 dump 给用户 | `String(describing:)` 全量输出 + 上游帧原样转发 | 服务端已修并上线；**客户端解析代码已写但未提交、未出包** |
| 11-10 | 对话「豆包味」、专家强制三角度/三钩子/分镜、补编「展会三天」 | 模板刚性 + 无事实审查 + 验收只看关键词 | 云端 16 个模板已改；**iOS 硬编码包装未改，两个审查开关线上关闭** |

**共性根因（一句话）**：*提示词、能力清单、`tools[]` 用了三套互不校验的过滤器，系统里没有任何一道「提示词提到的工具必须真的可调用」的自动对账。* 每次都是用户先发现「说会做、实际没做」，我们才去打补丁。

用户同时反复强调的纪律：先说方案再改、不把 CI 全绿当业务验收、如实说明未做、不主动出包、不声称与 ChatGPT 6 对齐或视觉质量提升。

---

## 2. 专家模块：是否优化？—— **不能确认已优化**

| 链路 | 判定 | 位置（已复核） | 影响 / 原因 | 建议 | 优先级 | 是否需 IPA |
|---|---|---|---|---|---|---|
| 云端 16 专家模板 | **已优化** | `cloudfunctions/bf-api/experts.json`（`role/framework/steps/checklist` 四字段） | 已改为按本轮任务交付，去掉三角度/三钩子/固定分镜，加入反编造约束 | 保留 | — | 否 |
| 云端 starters / 少量自检项 | **部分** | 同文件 `:180,209,297,369,226,341,461,517,541,549,555,563,601,629,633,681,685` | 仍写「3 版文案 / 九要素 / 10 个问题 / 末尾必须注明…」，与「不硬套」自相矛盾 | 改成条件式、去掉固定数字 | P2 | 否 |
| 目录治理 | **已优化** | `cloudfunctions/bf-api/expert-catalog.js` | 种子/管理员修订分离、version+catalogRevision、快照、CAS 409、禁止增删 ID | 补 id 正则 / 字段类型 / 条数校验；`reset` 也应走校验 | P2 | 否 |
| 服务端注入 chat | **部分优化** | `cloudfunctions/bf-api/index.js:2820-2859`（只注入日期、`META_RULE`、`CHAT_RULES`、guidance）；全文件仅 `:2861-2878` 注入 Ultra 自定义专家知识 | **云端目录的 role/steps 根本不进系统提示词**；`tuneExpertCatalog`（`assistant-style-policy.js:29-41`）是死代码；`CHAT_STYLE_POLICY=false`、`CHAT_GROUNDED_REVIEW.enabled=false`（`:220-221`、release.json） | ① 让云端目录成为提示词单一事实源 ② 服务端对客户端 `system[]` 的刚性块做定向剥离/仲裁（可免 IPA）③ 真实模型 A/B 合格后再开审查开关 | **P0/P1** | **否** |
| iOS 提示词层 | **未优化（最严重）** | `BossAI/Models/Expert.swift:85` 「【必须遵循的工作流】」、`:372` 「给 3 个实质不同的创作角度」、`:130/134` 点名 `generate_image`；`BossAI/ExpertCore/ExpertCapabilities.swift:36-50` 注入「执行步骤 1..n／交付章节」；`BossAI/ExpertCore/Resources/ExpertSkills.json:560-576` short_video 仍写「3 个角度/3 个钩子/分镜脚本」 | **已发布 IPA 里这些硬编码仍在**，云端改模板改不掉它们 → 线上实际仍强制工作流 | 删除/条件化刚性包装，改为只注入「本轮交付约束」；`ExpertSkills.json` 与云端目录合并为单源 | **P0** | **是** |
| 远程目录拉取 | **部分** | `BossAI/Services/RemoteCatalogService.swift:109-146` 字段映射正确；`:43-48` 无 catalogRevision/CAS；`Expert.swift:616` 与 `RemoteCatalogService.swift:77-79` 离线回退旧内置目录 | 断网/新装时刚性模板复活；并发保存无冲突检测 | 支持 catalogRevision + 缓存版本号；离线兜底改为最小通用约束而非旧模板 | P1 | 是 |
| 管理端编辑器 | **部分** | `web/admin.html:888-1044`（多行开场白已修、CAS 已加、禁止增删 ID） | `:943-945` 交付物下拉与工具勾选**无 `deliverable∈tools` 前端校验**，要等服务端 400；`:899-905` 丢弃 catalogRevision | 前端即时校验 + 回显 revision | P1 | 否 |

**一句话**：`git status` 显示 Swift/资源零改动，`release.json` 明确 `ipaBuildTriggered:false`。所以「21:52 上线」只换了服务端与静态页，**用户在手机上感受到的专家行为基本没变**。这是本轮最需要向用户如实说明的一点。

验证方式（不需出包）：`GET /api/experts` 比对 16 条与种子；抓一次真实 chat 的 `system[]`，确认是否仍出现「【必须遵循的工作流】」与新装断网场景的旧模板；`node --test tests-backend/expert-seed-contract.test.js tests-backend/expert-catalog.test.js`。

---

## 3. 所有 Skill（工具）是否正常调用？—— **12 个工具里 5 个异常 / 待验证**

服务端 `index.js:2900-2915` **没有自己的 `tools[]`**，只是把客户端 `body.tools` 原样透传；工具集由 `BossAI/Services/ToolManifest+Schema.swift:366-391` 生成。因此「工具是否能调」完全由 IPA 决定，服务端只能改提示词。

| 工具 | 声明 / 实现 | 判定 | 证据（已复核） |
|---|---|---|---|
| `image_decompose` | `ToolRegistry.swift:144` / `Streaming.swift:627` | **异常** | `availability:false` → 不进 `tools[]`；但 `cloudfunctions/bf-api/index.js:241` 的 `CHAT_RULES` 仍命令模型调用它 |
| `generate_image` | `ToolRegistry.swift:163`、`ToolManifest+Schema.swift:95` | **异常（幽灵工具）** | `ToolManifest+Schema.swift:368` 显式排除其 schema；`Expert.swift:130/134`、`ToolManifest+Schema.swift:59`、`ToolRegistry.swift:163-184`、`Streaming.swift:435/517/848/862` 仍点名；`permits()` 却放行执行 |
| `render_chart` | `ToolManifest+Schema.swift:57-59` | **异常** | 描述写「示意性/装饰性图像请改用 `generate_image`」——指向一个不在工具集里的名字 |
| 能力清单 vs `tools[]` | `ToolRegistry.swift:250-275` / `ChatViewModel.swift:663-690` | **异常（P0 根因）** | `capabilityManifest` 只看 `availability`，`definitions()` 还要求 `policy.permits()`（canSearch/canImage/docFormats）；`:266` 更无条件宣称「文生图/图片编辑/Word·PPT·Excel·PDF 导出**全部正常可用**」。清单说有，`tools[]` 没有 → 模型被要求调调不到的工具 |
| `capabilityOverrides` / `capabilityExtra` | `HostedAccount.swift:779/782` 解析 | **异常（死开关）** | `Grep` 全仓：云端 `cloudfunctions/` **零匹配**，`/me` 响应不下发这两个键 → `disabledToolIDs` 恒空，云端能力开关永远不生效 |
| `web_search` | `ChatService.swift:463-467` | 待验证 | 原生搜索开启时不在 `tools[]`，但 `ChatViewModel.swift:666` 仍要求调用 |
| `image_series` | `ToolRegistry.swift:144` | **正常（已修复）** | availability=true；`image-series-reference-guidance.js` 可激活 |
| `recall`、`search_library` → `recall_history` / `search_library` / `create_document` / `expert_skill` / `image_generate` / `image_edit` | `Streaming.swift:402-961` 全覆盖 | 基本正常 | dispatcher 与错误回注齐全；`create_document` 的 availability 与 `:266` 宣称矛盾 |
| `/api/tools/search` | `index.js:4804,5072` | 待验证 | 无限流、无用量记账 |
| `/api/tools/fetch` | `index.js:4805,5100` | **死代码** | 全仓无调用方 |

**档位权益实装核对**（用户长期关注）：

| 权益 | 判定 | 证据 |
|---|---|---|
| 定时任务 Pro 3 / Ultra 10 | **stub** | `index.js:2107-2170` 只有 CRUD，`:2141-2144` 同类型去重导致实际最多 2 个；`bf-jobs` 不读 `bf_schedules`、无执行器；`HostedAccount.swift:381-385` 读 `schedules` 键，而 `persistInfo`（`:486-521`）从不写入 → `cachedSchedulesEnabled` 恒 false |
| 白标（仅 Ultra） | **缺失门控** | `index.js:2563` /me 下发、`:3982` 建号写 `brandName` 均无档位校验，仅 `MembershipView.swift:68` 展示 |
| 自定义专家 RAG（仅 Ultra） | 实现 | `index.js:2322` 门控 + `:2232-2290` embedding/余弦 |
| 完整导出 / 深度研究（Pro+） | 实现 | `HostedAccount.swift:373-375`、`ResearchCore.swift:200` 预算 8/24000 vs 5/16000；但被 `:266` 硬编码矛盾抵消 |

**重复实现 / 死代码**：三套策略（`ChatService.swift:456` 不传 overrides、`Streaming.swift:396` 传 overrides、`ToolRegistry.swift:250` 只看 availability）；`ExpertSkillRuntime.permits`（`ExpertCapabilities.swift:126-151`）生产零调用、仅测试用，但 `docs/skill-system/04-routing-policy.md:38` 却称其参与路由；`coreToolIDs` / `imageToolPlugins` / `isVisible` / `producesArtifact` / `requiresEnv` 全仓无读取；`outputs/` 下 6 份过期 `image-tool-schema.js` 副本；`index.js:3403` 旧生图死路径。

---

## 4. 优化方案（按「免出包优先」排序；每项含影响 / 风险 / 验证）

### S0：服务端可改、无需 IPA、可线上生效

| ID | 位置 | 改动 / 影响 | 风险 | 验证 | 优先级 |
|---|---|---|---|---|---|
| S0-1 | `index.js:241,242,245`；`:1216` | 从 `CHAT_RULES` 删除 `image_decompose`；`META_RULE_BUILTIN` 海报配图改指 `image_generate`。**直接消灭「命令模型调一个永远拿不到的工具」** | 极低，仅改提示词 | 离线断言提示词源文件 `grep image_decompose` = 0；真实 chat 抓 `system[]` 复核 | **P0** |
| S0-2 | `index.js` `handleChat` 注入处 | 新增可开关的「刚性包装剥离/仲裁」：识别客户端 `system[]` 中的「必须遵循的工作流 / 交付章节 / 三个角度」并按本轮交付约束改写。**这是免 IPA 根治专家 P0 的唯一路径** | 中：改动系统提示词，需灰度 + 真实对话 A/B；默认关闭 | 开关 off/on 对照，人工逐条看是否仍强制策划、是否编事实 | **P0** |
| S0-3 | `index.js:2560-2625` /me | 补 `capabilityOverrides` / `capabilityExtra` 下发，让云端能力开关真正生效 | 低，但要与客户端解析格式对齐 | 构造 fixture 断言 `disabledToolIDs` 非空 | P1 |
| S0-4 | `index.js:2563,3982` | 给 `whiteLabel` / `brandName` 加 Ultra 档位校验 | 低，可能影响已有误配账号 → 先只读盘点再改 | 三档账号分别请求 /me 与建号 | P1 |
| S0-5 | `index.js:4804-5100` | `/api/tools/search` 限流 + 用量记账；`/api/tools/fetch` 登记为待删 | 低 | 契约测试 | P2 |
| S0-6 | `tests-backend/` 新增 | **「提示词 ↔ 工具集」离线对账测试**：遍历所有提示词源，断言出现的工具名 ∈ 实际 `tools[]`；断言 16 专家 × 托管/非托管 × 原生搜索开关下三套过滤器集合一致。**这是防止第 1 节问题复发的根因级修复** | 零（纯离线） | `node --test`，应能立刻检出当前 4 个异常 | **P0** |
| S0-7 | `CHAT_GROUNDED_REVIEW` | 保持关闭，直到完成真实模型 A/B + 人工逐条事实审查 | — | 合成场景逐条核对断言有无证据 | 待批准 |

### S1：必须出包，**集中登记、本轮不实施**（沿用上一轮约定）

| ID | 位置 | 改动 | 依赖 / 风险 | 验证 |
|---|---|---|---|---|
| S1-1 | `ToolRegistry.swift:250-275`、`:266`、`ChatService.swift:456`、`ToolManifest+Schema.swift:366-391` | 统一为单一策略对象；删「全部正常可用」硬编码；`applyTools` 传 overrides | 需 IPA；改动工具集会影响所有专家 | 16 专家 × 3 场景集合一致性断言 |
| S1-2 | `Expert.swift:85,130,134,372`、`ExpertCapabilities.swift:36-50`、`ExpertSkills.json` | 去刚性包装、清幽灵 `generate_image`、本地档案与云端目录单源 | 需 IPA；与 S0-2 二选一或叠加 | 新装断网抓 `system[0]` |
| S1-3 | `RemoteCatalogService.swift:43-48`、`Expert.swift:616` | 支持 catalogRevision/CAS；离线兜底改最小通用约束 | 需 IPA | 缓存版本冲突用例 |
| S1-4 | `ToolClaimGuard.swift:19`、`Streaming.swift:318,1034` | 谎报闸门扩到 `create_document`；裸「图」改词组 | 需 IPA | 单元测试 |
| S1-5 | `HostedAccount.swift:486-521` | `persistInfo` 写 `schedules` 键，让 `cachedSchedulesEnabled` 生效 | 需 IPA + S0-3 | fixture 断言 |
| S1-6 | 11-03 已有未提交代码：`APIError.swift`、`FriendlyError.swift`、`ChatService.swift`、`Tests/.../ChatErrorDisplayTests.swift` | 断流错误中文解析出包 | 需与 ChatGPT 另一路改动决定「一起提交还是等对方先落」 | 8 条单测 + 真机截图 |
| S1-7 | `render_chart` 描述、`image_series.producesArtifact` 等 | 描述与实现对齐 | 需 IPA | 契约测试 |

### S2：治理（低优先，不改行为）
清死代码、`outputs/` 过期副本、ExpertSkills 与 experts.json 单源、`reset` 走校验、starters 去固定数字、`docs/skill-system/` 与实现对齐。

---

## 5. 历史遗留、需要用户拍板的未决项（不擅自决定）

1. 海报是否允许模型自己写整套中文文案（10-27 提出，未决）。
2. `reference` 重设计是否强制 `NO_TEXT` / 无字（10-27 提出，未决）。
3. 11-03 客户端错误改动与 ChatGPT 另一路服务端改动：一起提交还是等对方先落。
4. C1/C2、D1/D2 架构路线选择；Lite / 5.5 / 2K 质量成本评估。
5. 是否批准一次 IPA 构建（S1 全部项需攒批统一出包）。

---

## 6. 验证方式汇总（离线优先，不烧额度）

```
node --test tests-backend/*.test.js                     # 现有基线 607/607（21:25 已跑，本轮代码未变）
node --test tests-backend/expert-seed-contract.test.js tests-backend/expert-catalog.test.js \
             tests-backend/web-contract.test.js tests-backend/commercial-chat-review.test.js
grep -R "image_decompose\|generate_image" cloudfunctions/bf-api/index.js BossAI/*提示词源   # S0-1 / S0-6 依据
node --check cloudfunctions/bf-api/index.js && git diff --check
```
仍需但**尚未做**：真实模型事实门禁 A/B、固定素材视觉回归、真实 CloudBase 并发故障注入、浏览器端到端、Xcode/真机、完整生产回滚演练。

---

## 7. 本轮如实清单

- **22:2x 审计阶段（只读）**：近两周工作日志复盘、专家/iOS/服务端/管理端全链路审计、12 个工具逐项核对、平台 Skill 清单核对、关键断言 Grep 复核、本文交付。此阶段未改任何代码。
- **22:3x 实施阶段（用户选定「免出包修复+对账测试」）**：改 `cloudfunctions/bf-api/index.js`、`settings-schema.js`，新增 `expert-delivery-arbitration.js` 与 `tests-backend/tool-prompt-alignment.test.js`；S0-1/2/3/4/6 已落地，全套 **617/617 通过**，`node --check`、shared `--check`、`git diff --check` 全通过。
- 仍未做：**没有部署、没有出包、没有触发 CI、没有提交远端分支、没有调用付费模型或生图、没有改动客户额度**。新增 3 个配置键均为默认值（两个策略开关关闭、能力开关空对象），未部署时零行为变化。
- 不能声称：专家已优化完成、所有 skill 正常、与 ChatGPT 6 对齐、视觉质量提升。
- 服务端会话检索不可用，因此「看完全部原始对话」这一条**没有完全做到**，以本地日志替代，已在第 0 节说明。
- 详细测试报告：`outputs/expert-skill-alignment-20261110-test-report.html`；回归证据：`outputs/align-20261110-full.tap`。

---

## 8. 逐条实施结果（待用户确认执行范围后回填）

用户 22:2x 选定「免出包修复 + 对账测试（暂不部署）」。以下为逐条实施结果，均在本地候选，未上线。

| ID | 状态 | 改动文件 | 实施与验证结果 | 上线 / 出包 | 回滚点 |
|---|---|---|---|---|---|
| **S0-1** | **已实施** | `cloudfunctions/bf-api/index.js`（CHAT_RULES 15/16④/17、META_RULE_BUILTIN） | 删除 `image_decompose` 点名；海报/配图/概念示意改指 `image_generate`；`both` 语义改为 `source=attached + source_indexes + reference_roles` 并明确禁用 `both`。ALIGN-02/03 通过；`Grep` 复核 bf-api 提示词源 0 命中 | 否 / 否 | 还原 5 处字符串即可 |
| **S0-2** | **已实施（默认关闭）** | 新增 `cloudfunctions/bf-api/expert-delivery-arbitration.js`；`index.js` require + chat 注入链；`settings-schema.js` | 追加式仲裁，不删改客户端 system、幂等、fail-closed、支持 audience/accountIds；`CHAT_DELIVERY_ARBITRATION` 默认 `{"enabled":false}`。ALIGN-06/07/07b/09 通过 | 否 / 否 | 开关置 false 即完整回退；删模块亦不影响其他链路 |
| **S0-3** | **已实施** | `index.js` RUNTIME_SPECS + `/me`；`settings-schema.js` | 补 `capabilityExtra`(String) 与 `capabilityOverrides`(Object) 下发，解析失败回退 `{}`；配置键加分区、元数据与字段白名单（≤30 项、只接受 enabled/limits）。ALIGN-05/08 通过 | 否 / 否 | 删除 `/me` 两个字段；默认空值零影响 |
| **S0-4** | **已实施** | `index.js` `/me` appName、建号 brandName | 读写两侧均加 `features.whiteLabel` 门控。ALIGN-05 通过 | 否 / 否 | 还原两处三元表达式 |
| S0-5 | 未实施（P2） | — | `/api/tools/search` 限流记账、`/api/tools/fetch` 死代码清理，排入 S2 | — | — |
| **S0-6** | **已实施** | 新增 `tests-backend/tool-prompt-alignment.test.js` | 10 条对账用例；**首次运行即抓到审查漏掉的 `BossAI/Services/ImageService.swift` 注释残留**，已登记。全套 617/617 通过 | 否 / 否 | 删测试文件即可 |
| S0-7 | 保持关闭 | — | `CHAT_GROUNDED_REVIEW` 未启用，等真实模型 A/B + 人工事实审查 | — | — |
| S1-1 ~ S1-7 | 登记待出包 | — | 未实施；另补登记 ALIGN-04 新发现：`ImageService.swift:41` 的 `image_decompose` 注释残留 | 需 IPA | 统一出包时处理 |
| S2 | 待排期 | — | 未实施 | — | — |

**门禁汇总**：`node --test tests-backend/*.test.js` → 617/617、0 失败、3.70s；3 个核心 JS `node --check`；`bundle-function-shared.js --check`；`git diff --check`（仅 CRLF 提示，非错误）。付费模型 0、生图 0、部署 0、IPA 0。
