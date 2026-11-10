# BossAI 修改与上线记录

所有时间使用北京时间。先查本文件及 [出包问题与修复台账](RELEASE-BACKLOG.md)，再开始修改。详细分析放对应 ops 文档，本文件保留索引和真实发布状态。

## 2026-11-10 21:52：全架构审查后的服务端与管理端上线（已部署，无 IPA）

- **时间 / 状态**：2026-11-10 21:52，北京时间；用户明确授权「自测之后直接上线」；**服务端、配置与两个静态页面已部署，未出包**。
- **问题与影响**：组图续步可绕过实时额度/能力开关；账务并发可能重复扣额度；审批重试可能发错凭据；员工通知会显示另一客户密码；管理端编辑会截断多行开场白；16 个专家把内部方法强行外显；Seedream 原生组图参数与参考图优化策略有偏差；对话成稿仍可能编造现场细节。
- **真实根因**：付费入口各自重复鉴权；事件唯一性与账户副作用未在同一事务；审批履约由多个外部可见写组成；前端把结构化数据压成行文本；专家目录/权限/模板分三处维护；官方 provider 能力表与 payload 编译未统一；写作链路只有生成、没有独立事实审查。
- **改动与方式**：新增 `image-execution-gate.js`、`image-billing.js`、`approval-fulfillment.js`、`expert-catalog.js`、`commercial-chat-review.js`；收敛 `bf-api/index.js`、`bf-image/index.js`；修正 Seedream payload 与能力表；16 个云端专家改为按本轮任务交付；修 `web/admin.html`/`web/staff.html`；实现确定性 shared 打包；新增 `CHAT_GROUNDED_REVIEW`，默认 `enabled:false`。
- **涉及文件及配置**：`cloudfunctions/bf-api/{index.js,experts.json,settings-schema.js,*.js 新模块}`、`cloudfunctions/bf-image/{index.js,*.js 新模块}`、`scripts/bundle-function-shared.js`、`web/{admin,staff}.html`、11 个新增/迁移测试、发布脚本/证据、架构文档、本文件及 `RELEASE-BACKLOG.md`。未修改 Swift/资源/Info.plist；保留所有原有未提交改动。
- **测试与实际效果**：`node --check` 与后端全量 `node --test` **607/607，0 失败**；上线前当前线上 ZIP 为基线，候选 ZIP 仅替换 6+3 个业务文件、node_modules 零变化；上传/下载逐文件 inventory 完全一致。真实 HTTP 9 项通过：health 200、img ping 200、匿名 401、临时登录 200、16 专家目录 200、真实 SSE JSON 帧与 `[DONE]`、到期 403、额度 429、两个候选开关关闭。为验 SSE 发生 **1 次 24-token 聊天调用**；生图 0、客户额度变化 0、临时账号已删除、IPA 0。
- **未解决限制**：`CHAT_GROUNDED_REVIEW` 未做真实模型 A/B，保持关闭；Seedream 未做固定素材视觉回归；真实 CloudBase 并发故障注入、浏览器端到端、Xcode/真机、O4 和全部客户端待办仍未完成；详见架构文档第 10/12 节及 BACKLOG。
- **上线时间与版本**：21:51:33 `bf-api` Active / `InstallDependency FALSE`；21:52:05 `bf-image` Active / `InstallDependency FALSE`；专家目录 `version=8 / catalogRevision=8`，16 个专家全部迁移；`CHAT_GROUNDED_REVIEW={"enabled":false,"audience":"all"}`；`CHAT_STYLE_POLICY` 保持 false；管理端 `admin.html`/`staff.html` 线上 SHA256 与候选一致。发布结果见 `outputs/release-20261110/release.json`。
- **回滚方式**：先备份当前线上版本和后续补丁；用 `outputs/release-20261110/before-bf-api.zip`、`before-bf-image.zip` 以 `InstallDependency=FALSE` 回传，恢复 `config-before.json` 的专家目录与运行时开关，重新上传 `before-admin.html`、`before-staff.html`。`scripts/release-architecture-20261110.cjs` 内含自动回滚路径；仅关闭审查开关不等于完整回滚。
- **是否需要出包**：**不需要**。所有本轮上线均为服务端/管理端/文档/测试；客户端问题只登记，等待下次授权后统一出包。
- **详记**：[架构优化与实施台账](ops/architecture-optimization-20261110.md)、[上线测试报告](architecture-optimization-20261110-test-report.html)。

## 2026-11-10：对话风格与用户交付意图

- **现象**：用户要求纯口播，却收到选题表、展板讲解、多版本和额外建议；被批评后还产生没有依据的客户问答场景。
- **已核实**：线上 `bf-api` 基线为 2026-11-06 00:10:22；当前聊天是百炼 DeepSeek V4.1 Flash，不是豆包。客户云端已有 262 条消息，最新到 11 月 10 日，不能沿用 11 月 6 日“最后同步在 11 月 4 日”的旧结论。
- **根因与修改**：专家强制工作流外显；默认规则允许泛化开场/收尾；商业图片指导仅凭展会/展板词命中。增加独立交付与表达策略，在服务端仲裁用户本轮格式；修正图片指导触发，保留图片工具功能；定向更新通用、短视频专家，不覆盖其他专家设置。
- **验收分级**：581 项后端回归通过。真实评估发现大段风格提示和直接换 Pro 都不能稳定消除虚构现场细节；该候选未通过事实门禁，默认关闭。仅发布取消强制模板、固定开场收尾与背景误触发生图的修复；上线状态与真实 HTTP 复验结果见 ops 文档最终追加节。
- **已上线**：18:03:53，API Active / InstallDependency FALSE；专家目录版本 6，只改 general/short_video，其他专家校验不变。18:06 实际 HTTP 验证通过：登录后目录、非流式 JSON、SSE JSON 帧与 DONE、到期403、额度429；临时账号已清理，未扣客户额度。没有出包。
- **18:09:56 默认目录补齐**：同步两个默认专家模板，避免“恢复默认”带回旧模板；保留不承诺播放量/涨粉/转化的自检。最终目录版本 7，产物再次逐文件核对，依赖无变化；18:11 登录目录及会员/额度门禁复验通过，未重复付费模型测试。
- **详记**：[对话风格审查与发布](ops/assistant-style-20261110.md)。需要新包的限制单列 B-07/B-08，本轮不出包。

## 已有 DSH 记录

- 2026-11-06 06:32，`bee8361`：新增 `RELEASE-BACKLOG.md`，记录旧密钥回落、模式心跳、错误显示等待出包问题；保留其原条目。
- 2026-11-06 00:21，`52a25e2`：平台导出账单按客户归属展示。补录为支出归属，不自动追扣会员额度。

## 后续每次必须填写

时间 / 问题与影响 / 真实根因 / 改了什么与为什么 / 涉及文件及配置 / 测试与实际效果 / 未解决限制 / 上线时间与版本 / 回滚方式 / 是否需要出包。
