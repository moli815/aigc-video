# 对话行为与表达 V2：调研、候选及验收

本轮由“说话风格进行调教、思考方式参考 ChatGPT”触发。2026-11-11 凌晨开始，09:51 用户要求继续后接续；发布前线上仍为 11 月 10 日 23:56:08。当前文档初始状态为候选，未据研究或测试数宣称达到 ChatGPT 同等能力。

## 公开资料及可复用部分

- [OpenAI 推理实践](https://developers.openai.com/api/docs/guides/reasoning-best-practices)：明确任务与成功条件、简洁指令、区分输入区域；不通过要求输出思考独白来证明模型会推理。本项目参考可观察的任务处理规范，不获取或仿制 ChatGPT 私有思考链。
- [OpenAI 提示词指南](https://developers.openai.com/api/docs/guides/prompt-engineering)：用少量且一致的输入输出例子表达格式。这里用于“只返回修改片段”和“不能补编经历”的例子，不将例句当用户事实。
- [OpenAI 提示词优化示例](https://developers.openai.com/cookbook/examples/optimize_prompts)：先检查矛盾、格式和示例，再改写提示。这里采用消除旧模板冲突的做法，不只追加更强语气。
- [OpenAI 评测实践](https://developers.openai.com/api/docs/guides/evaluation-best-practices)、[Promptfoo 断言](https://www.promptfoo.dev/docs/configuration/expected-outputs/)：采用场景断言、人工校准、保留原始失败与未参与调优的新样例。没有把关键词得分当成真实性。
- [百炼深度思考](https://help.aliyun.com/zh/model-studio/deep-thinking)、[当前模型能力与价格](https://help.aliyun.com/zh/model-studio/deepseek-v4-1-flash)：当前 deepseek-v4.1-flash-1017 支持实际思考和 JSON Object。复杂商务审稿试验使用 enable_thinking=true，普通改稿仍关闭；思考 Token 是输出成本的一部分。

OpenAI Cookbook 与 Promptfoo 的官方仓库许可均为 MIT 类授权，已查实际 LICENSE。这里只复用方法，没有复制其运行时代码，不安装 Agents SDK、Promptfoo 或新的 Python/Node 依赖；生产仍使用当前固定 Nodejs18.15 和已有供应商接口。公开指南不是另一个模型能力或质量的保证。

## 源码根因与本轮结构

旧 App 传入远程专家步骤，还拼接“必须遵循的工作流”、本地“执行步骤/交付章节”和缺输入就先给框架。追加式仲裁没有消除这些冲突。本轮由独立 response-behavior.js 统一表达策略，CHAT_STYLE_POLICY.profile=task_v2 时：

1. 只把已识别的 system 包装改为内部方法/检查维度，保留专家知识、原步骤、能力、计算器、真实性和安全边界。
2. 不修改 user、assistant、tool 的资料、历史文本、工具回包和图片；账户未命中或配置非法时不启用，也不意外回退到旧失败风格。
3. 身份继续由 assistant-guidance.js 单独保持“中防AI专属智能助手”；任务目标、最新更正、所需交付和具体事实优先，写作不固定套分析/表格/三点/邀约。
4. 内部任务和 utility 明确跳过对话风格，保护摘要、标题、记忆提取等机器契约；普通聊天和工具传输保持原接口。
5. 复用 commercial-chat-review.js：明确的商务成稿独立核对事实和交付范围；可配置覆盖商务建议，并只在商务建议审稿时启用实际思考。原聊天模型、平台、图片路由均不换。

这不是训练模型权重，也不能强制 DeepSeek 的内部机制成为 ChatGPT。可配置的是行为、证据和交付链；供应商的 enable_thinking 也不是对 ChatGPT 的仿制。

## 已执行的候选验证与真实限制

- 多轮本地检查，当前最终回归 640/640。包括 16 专家与两种搜索/权限/仲裁的 128 组实际服务端处理器路径；另覆盖 V2 的 32 组账号选择、内部任务跳过、JSON/SSE 双调用记账及不泄露未经审定的 reasoning 字段。
- 新增实际本地 HTTP SSE 生命周期测试：正常 POST 请求体结束不能中断正在生成的回复；消费者断开会取消审稿；结束后不重复写帧。修正旧 req.close 监听，避免把请求生命周期与响应连接混淆。
- 真实模型首轮 12 组开/关，共24次；第二版12次；新增5组独立样例。复用了既有稿件做6次快审、2次实际思考审稿，没有反复付费生成同一底稿或图片。
- 保留失败：第一版会编“比预想多/几天下来”；修订版只改句子的范围正确，但与测试选定的逐字参考句不同。后续评分区分“只返回目标片段”和“必须逐字原文”；原始 exact=false 不覆盖，另设严格引号原文样例并通过。
- 人工复核发现快速审稿仍保留“1000元覆盖不了全部物料”的无依据报价判断；没有依据自动绿灯上线。实际思考审稿两例改为“没有报价，不能假设足够/不够”，保留实用建议，耗时约18.0秒和24.1秒。它不是所有场景零幻觉的证明。
- 图片/文件测试只验证工具选择，未实际执行生图或导出。未运行 ChatGPT API 对照、Xcode 或真机，不宣称与 ChatGPT 等质。

## 配置与发布门禁

CHAT_STYLE_POLICY 支持 enabled/profile/instructions/audience/accountIds；旧字段兼容。CHAT_GROUNDED_REVIEW 增加 includeBusinessAdvice、reasonBusinessAdvice 布尔值，预算与超时保持有界。两个配置均先限定临时账号，实际 HTTP/JSON/SSE、会员与额度门禁通过后才改 all。CHAT_DELIVERY_ARBITRATION 保持关闭，避免并存两套仲裁。

复杂商务审稿预计更慢，实际思考按返回用量分别记账；普通问答、机器 JSON、内部任务、图片工具均不因此增加第二次审稿。当前模型官方表按输入/输出及峰谷区分，不另列思考模式单价，实际成本仍以现有供应商价格目录与账单核验为准，不能把公开原价当客户实付。

本轮仅拟替换 bf-api 六个业务文件：index.js、settings-schema.js、assistant-guidance.js、assistant-style-policy.js、response-behavior.js、commercial-chat-review.js。从当前线上备份构建、固定依赖、相对依赖门禁、完整入口加载；官方 SCF InstallDependency FALSE 上传后重新下载逐文件核验。不得用 21:52 或晨间旧包覆盖新补丁；不改 App、员工端、图片函数或审批代码。

## 当前发布状态与回滚

候选阶段，尚未上线本轮 V2。证据位于 outputs/response-style-20261111，真实费用记录分别使用 response-style-eval-20261111 和 response-review-eval-20261111，合成资料、无客户额度修改。

线上只改两个策略键，事务核对原值，不覆盖整份 runtime；失败恢复这两个键。代码回滚用该目录 before-api.zip 和 scripts/release-tool-alignment-20261110.cjs --plan scripts/response-style-release-20261111.json --rollback；须确认当前仍为本轮候选，不能覆盖其他人的后续发布。关闭策略即可撤回行为变化，但不恢复代码文件；完整回滚两者都要做。
