# 工具与专家候选修复、测试及发布记录

本轮从 2026-11-10 23:30 左右开始，北京时间；用户已明确授权“自测几遍，优化之后上线”。只修改兼容旧 App 的服务端，不出包，不修改员工端。前置复核见 expert-skill-review-20261110.md；本记录区分候选、已测试和线上状态。

## 已修复的源码问题

| 编号 | 根因 | 修法 | 回归 |
|---|---|---|---|
| R1 | 发布列表遗漏顶层 require 的新模块，旧检查仅对文件清单与哈希 | 原列表补模块；新增 API-only 三文件发布器；ZIP 检查静态相对 require 依赖，再解包加载真实入口及依赖、请求 OPTIONS | 缺入口依赖/缺二级依赖会失败；目录 index、JSON、package main 能解析；完整候选实际启动通过 |
| R2 | JSON null 通过 typeof object 检查后被 Object.keys/entries 使用 | 通用对象校验先排除 null | 四个 JSON 配置的 null、数组、原始值均返回字段错误，空对象兼容 |
| R3 | 全部消息内的一个标记被视为已注入规则 | 只在 system 消息末尾存在完整规则时判幂等 | user/assistant/tool 中同名标记或完整文字不能抑制规则；不完整 system 标记也不能抑制 |
| R4 | 非 accounts 的任意 audience 退成 all | 保存端与消费端复用严格校验；未知字段/范围/坏账号列表关闭；省略 audience 但带账号列表时限定该列表 | 错拼范围、null、空白 ID、超限列表、额外字段不扩大灰度；不修改输入数组 |

DSH S0 候选保留：默认工具提示纠正、/me 能力配置字段、Ultra 白标门控及默认关闭的交付仲裁模块。没有重部署 21:52 的图片/审批/管理页面重构；这些线上后续补丁由当前 ZIP 原样保留。

## 发布前自测（已测试）

- 两轮完整后端回归：均 627/627，通过，0 失败，约 2.60 秒和 2.81 秒。新增 10 项测试，其中一个测试循环执行 128 组服务端处理器组合；128 不是额外的 128 个独立测试数。
- 组合覆盖：16 个专家 × 两种搜索工具形态 × 两种输入工具权限集合 × 仲裁开/关。通过实际 handleChat 及其提示词/工具编译链，伪造认证及供应商返回、使用内存数据库；断言工具名不增不丢、用户正文保持、规则开关正确。它不等于 Windows 上执行了 Swift 的工具装配代码，也不证明 BYOK 直连受服务端控制。
- 实际 /me 处理器覆盖三档白标与能力字段；不是只做正则匹配。
- 五个函数的 shared --check 均无缺失/额外/漂移；本轮不重建或上传这些依赖。
- 当前线上 bf-api ZIP 已下载备份，基线修改时间 2026-11-10 21:51:33，Nodejs18.15、Active、InstallDependency FALSE。候选仅替换 index.js、settings-schema.js、新增 expert-delivery-arbitration.js；5617 个文件，node_modules 零变化。
- 候选 ZIP 静态依赖检查通过；解包后使用真实依赖加载完整入口，通过 OPTIONS 204。预检进程没有生产凭据或供应商/数据库写入。

## 真实模型质量门禁（已测试，未获准全员启用）

当前百炼对话模型执行 7 组开/关对照，共 14 次真实请求：纯口播、局部改句、短计算、JSON、图片工具选择、文件工具选择、长上下文（完整请求约 2.1 万字符、约 1.3 万输入 token）。含已发布本地专家契约及模拟 expert_skill 计划回包；只观察工具调用，不实际生图或生成文档。

- 算术、JSON 与图片/文件工具选择保持正常。
- **局部改句失败**：开/关两组都把三句原稿整段返回，而用户只要改后的第二句。仲裁未显示可靠改善。
- 长上下文的自动“编造”正则误报：命中用户已给出的“不承诺保险自动赔付”这一否定表述，人工复核没有将它判成虚构的正向承诺。保留原始失败标记及人工解释，不事后改为全绿。
- 一般营销表述仍可能扩展到用户没有逐项证实的能力或邀约；不能宣称真实性已全部解决。
- **决策：仲裁 CHAT_DELIVERY_ARBITRATION 继续关闭；CHAT_STYLE_POLICY、CHAT_GROUNDED_REVIEW 也保持关闭。本轮上线不改变三个策略的配置。**
- 14 次评测使用合成资料，按独立 source=tool-alignment-eval-20261110 记录供应商调用台账；不使用客户账号，不扣客户额度。公开模型费用不等于已核对供应商账单金额。

## 线上发布状态

**已上线：2026-11-10 23:56:08，北京时间。** bf-api 为 Active / Nodejs18.15 / InstallDependency FALSE。官方 SCF 更新成功后重新下载 ZIP，5617 个文件与候选逐文件一致；相对依赖无缺失、node_modules 零变化。没有修改 runtime、专家目录、图片函数或网页。

23:56–23:57 临时会员线上复验通过 12 项：健康 200、未变图片函数 ping 200、匿名目录 401、三种候选策略仍关闭、临时会员登录 200、三档 /me 能力字段与白标、16 专家目录 v8、旧非流式 JSON 200、旧 SSE JSON 帧及 DONE 200、到期 403、额度耗尽 429、拒绝后上游调用数量不增加。JSON 和 SSE 样例分别约 3.61 秒及 3.45 秒；这是两个小样例的单次端到端耗时，不是普遍延迟或并发容量结论。

本次线上复验产生 2 次聊天调用，生图 0；这两个调用归属唯一的临时会员账号，已验证记账，账号已删除。没有向客户账号发送测试请求或修改客户额度。

另核对 14 次真实 A/B 的服务端台账：14 条均 succeeded，accountId 均为空（公司评测），均有成本估算；估算合计 0.0333402 元，尚无供应商核账金额，不能称为实际账单费用。详见 evaluation-ledger-verification.json。

## 产物与回滚

证据目录 outputs/tool-alignment-20261110：before-api.zip、baseline.json、config-before.json（仅选定非密钥策略）、candidate-api.zip、artifact-gate.json、prepared.json、load-smoke.json、round-1.tap、round-2.tap、real-model-evaluation.json、manual-model-gate.json、online-api.zip、online-check.json、release.json、http-verification.json、evaluation-ledger-verification.json。目录已被 Git 忽略，含 ZIP 的本地备份不提交。

发布：node scripts/release-tool-alignment-20261110.cjs --apply。上传前重新核对线上 ModTime 和逐文件清单；只通过官方 SCF UpdateFunctionCode、InstallDependency FALSE 上传。完成后再下载逐文件检查和健康验证。失败时仅在能确认当前代码仍属于本轮候选时恢复 before-api.zip，不覆盖别人后续版本。

回滚：同一脚本 --rollback；仅恢复 API 代码，不改运行时配置、专家目录、图片函数、页面或客户数据。原配置本轮未写，无需覆盖整份 runtime。模块加载故障不能只关仲裁开关解决。

尚未解决的客户端与语义质量事项保留原待办：局部改稿严格输出范围；本地技能契约与远程模板统一；非托管直连不受服务端约束；真实 iOS 装配与真机验收。没有用记录待办冒充已修复。
