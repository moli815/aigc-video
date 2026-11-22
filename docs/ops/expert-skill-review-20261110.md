# 专家与工具对齐候选：独立复核

复核时间：2026-11-10 23:16，北京时间。范围：DSH 新审计文档、S0 候选代码、发布文件清单，以及旧 App 的专家目录与提示词调用链。

状态：**审查完成，候选仍需修复；没有部署，没有修改 App，没有出包，没有付费模型调用。** 本次仅新增复核文档与变更记录，保留 DSH 及其他工作区改动。没有重新检索客户聊天或声称已经验证真实回复效果。

## 1. 阻断发布的问题

### R1 / P1：发布清单遗漏新增模块，候选 ZIP 无法加载

- 源码：cloudfunctions/bf-api/index.js:61 在模块顶层 require 新增的 expert-delivery-arbitration。
- 发布脚本：scripts/release-architecture-20261110.cjs:39–42 的 bf-api REPLACEMENTS 仍只有原来的六个文件，没有 expert-delivery-arbitration.js。
- 复现：以已有 outputs/release-20261110/online-bf-api.zip 为底包，严格使用脚本的六文件清单及 replace-function-zip-entries.py，离线构建候选。check-function-artifact.py 返回 0，但候选 index.js 引用了不存在的 ./expert-delivery-arbitration。
- 影响：若按审计文档所推荐的原发布脚本部署本轮源码，Node 加载入口时会发生 MODULE_NOT_FOUND；关闭仲裁开关不能避免顶层 require。当前线上旧 ZIP 不引用该模块，不能把候选问题说成线上已故障。
- 应修：补入新增文件，同时增加候选 ZIP 的本地依赖闭包或隔离加载检查；不能只核对允许变更文件和上传/下载哈希。重新准备时备份当时最新线上版本，不重用旧发布包覆盖后续修改。
- 官方依据：[Node.js CommonJS 模块解析](https://nodejs.org/api/modules.html)。本项没有引入外部代码或依赖，无额外许可证/运行时变化。

## 2. 候选中的行为缺口

### R2 / P2：两个新增配置传 JSON null 会抛异常

- 源码：settings-schema.js:287 只检查 typeof 和 Array.isArray；typeof null 是 object。后面的 CHAT_DELIVERY_ARBITRATION 分支调用 Object.keys(parsed)，CAPABILITY_OVERRIDES 分支调用 Object.entries(parsed)。
- 复现：分别调用 validateValue(key, 'null', {type:'json',label:key})，两次均抛 TypeError: Cannot convert undefined or null to object，而非返回校验失败。
- 影响：管理员粘贴或清空为合法 JSON null 时，设置保存进入异常路径，不能得到正常字段错误反馈。
- 应修：通用 JSON 对象检查增加 null 拒绝；针对 null、数组、原始值及合法空对象补参数化行为测试。现有通用校验存在相同空值缺口，本轮新分支继续暴露了它。

### R3 / P2：用户引用标记就能阻止仲裁注入

- 源码：expert-delivery-arbitration.js:66 在全部消息中查找 MARKER，不检查角色，也不检查完整规则。
- 复现：system 保留旧工作流；user 询问“请解释【本轮交付仲裁·最高优先级】是什么意思”；enabled=true。函数原样返回，没有在 system 中注入仲裁规则。
- 影响：引用、粘贴或历史助手文字会被误判成“服务端规则已注入”。这影响格式仲裁，不等于会员或工具权限被绕过。开关当前默认关闭，尚非已启用的客户行为。
- 应修：以服务端注入的完整规则及可信来源判幂等，不把 user/assistant/tool 的相同文本当作完成注入；补各角色同名标记和不完整 system 标记用例。

### R4 / P2：运行时解析器不完全符合 fail-closed 声明

- 源码：expert-delivery-arbitration.js:39 将任何非 accounts 的 audience 都解释为 all。
- 复现：enabled=true、audience='account'、accountIds=['u1'] 时，u2 也会启用。
- 边界：管理员设置接口的 validateValue 已拒绝该拼写；问题发生于环境变量、DB 直接配置或其他绕过该校验的写入路径。不是正常管理端保存一定会全员启用。
- 应修：运行时消费边界也校验枚举和字段；显式非法值关闭，不将其扩大成全员。明确缺省 audience 的规则，避免灰度对象与全员对象混用。

## 3. 审计报告需要纠正的结论

1. **不能从“Swift 未改、没有 IPA”推出“手机端专家行为基本没变”。** MainView.swift:87 调用 RemoteCatalogService.refreshIfPossible；RemoteCatalogService.swift:127–146 将服务端 role、framework、steps、tools、checklist 映射为 Expert；ExpertCatalog.applyRemote 保存远端目录；ChatViewModel.swift:369 使用 expert.systemPrompt。云端模板确实有通往旧 App 提示词的链路。
2. **残留冲突仍然真实。** Expert.swift 的工作流包装、ExpertCapabilities.swift 的本地技能契约及 expert_skill 返回的内置方法仍会进入同一对话。ChatViewModel 持有创建时的 Expert，已打开的会话不会因后台目录变化自动替换该值；离线、缓存或刷新失败也会回退。应说“远程模板已生效路径存在，但仍与本地契约并存”，真实回答改善程度需要抓实际请求和模型验收。
3. **tuneExpertCatalog 不是完全没有调用的死代码。** scripts/release-assistant-style-20261110.cjs:10/16 和 eval-assistant-style-20261110.cjs:58 都调用它。它不是每轮聊天的运行时注入器，而是发布迁移及评测辅助函数，不能把两者混为一谈。
4. **对账测试没有实现报告承诺的完整矩阵。** tool-prompt-alignment.test.js:28–79 静态提取本地工具 ID、排除项及恒关闭项；并没有构造 16 专家 × 托管/非托管 × 原生搜索开关的实际请求。mentionedTools 还先与已知 ID 求交，完全未知的新工具拼写会被过滤；它能防止已知幽灵工具扩散，不能保证所有提示词所指工具都真实下发。ALIGN-04 的按文件白名单也不是白名单内新增引用的数量门禁。

## 4. 本次实际验证与边界

| 检查 | 结果 | 能证明什么 |
|---|---|---|
| 本地 Git | HEAD e73d5e2；DSH 本轮模块及文档仍为未跟踪/未提交改动 | 已检查工作区，不能说本轮已有新提交或已推远端 |
| 全套后端回归 | 617/617 通过，0 失败，约 2.27 秒 | 当前已有回归可通过，不覆盖上述反例或商业质量 |
| 六文件离线 ZIP 重建 | 既有产物门禁返回 0，新增模块缺失 | 可重复的发布清单缺陷；未上传候选 |
| 新配置 null 反例 | 两项均 TypeError | 对象空值校验缺口 |
| 用户消息含仲裁标记 | enabled=true，但 system 没有仲裁规则 | 幂等误判 |
| 非法 audience 反例 | 其他账号也启用 | 消费端并非严格 fail-closed |
| 产品侧操作 | 部署 0、IPA 0、付费调用 0、客户额度变更 0 | 本次复核未改变客户使用状态 |

本次没有重新读取线上运行时、没有做真实 HTTP/SSE、CloudBase 并发故障注入或真实模型 A/B。21:52 线上状态仅来自已有发布证据；没有把它说成 23:16 的重新线上核验。审批、图片计费及其他工作区大范围重构不属于本次完整二次审计的结论范围。

## 5. 后续执行与回滚约束

先修 R1–R4 并增加可失败的回归，再补实际工具集合矩阵和专家提示词拼装样例。重新构建时验证完整候选可加载，之后才进入隔离 HTTP/SSE 与真实模型对照。保持仲裁默认关闭，真实验收后按明确账号名单灰度。未获得新的发布执行要求前，本次不部署。

本次仅增加文档，无产品代码回滚需求；不撤销或覆盖 DSH 原记录，以上为补充复核与纠正。部署时须另保存当时最新线上包及配置，仅关闭仲裁不能恢复缺失模块导致的入口加载故障。

## 6. 后续修复与上线补记（2026-11-10 23:57）

用户随后明确授权多轮自测后上线。R1–R4 已在服务端修复，新增行为与产物门禁、两轮 627 项回归、128 组实际服务端处理器组合及完整候选入口加载通过；23:56:08 仅发布 bf-api 三个业务文件，线上 Active / InstallDependency FALSE、逐文件核验一致，临时会员 HTTP/SSE 与权限检查通过。以上第 1–5 节保留为修复前的审查记录，不再代表当前候选状态。

真实模型 14 次开关对照仍未通过局部改稿门禁，交付仲裁和另外两个候选策略继续关闭，不能称为风格质量全部修好。详见 [修复与发布记录](tool-alignment-rollout-20261110.md)。没有出 IPA，也没有修改员工端。
