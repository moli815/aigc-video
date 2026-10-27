# 实施检查点

2026-10-27，分支 `codex/app-foundation-20261027`，起点 `c662714`。
用户已授权全线实施、验证、部署和 IPA；额度接近只剩 5% 时保存检查点并建立当前线程续跑，不得绕过限额。

## 已写代码，待候选 CI / 线上验证

- CloudSession 固定 owner/token 跨 await，DiagnosticQueue 有界、持久化、按账号隔离、服务端确认后出队。
- bf-api domains/events.js 事件幂等接收与字段白名单；旧 tool-event 不再吞写库失败，保留 requestId/errorCode。
- canonical `cloudfunctions/shared/asset-store.js`：账号内哈希去重、prepare/commit/签名、完整性验证与有界下载；部署前 `node scripts/bundle-function-shared.js` 打包到各函数，不手工复制。
- CloudAssetStore / CloudAssetRef 与消息、StoredFile 引用，原图＋缩略图、私有缓存、按需下载与恢复界面。
- SyncV2Engine：消息级记录、本地 outbox、服务端事务提交 revision、固定分页水位、账号隔离、旧数据导入、冲突保留；旧 JSON 不再截断。
- 当前 App 仍保留原始图片本地字段作迁移双读，不做破坏性本地数据清理。
- 同步触发改成登录/前台/文件或回合完成后合并触发，不只依赖每日 03:00。
- 输出尺寸与解码预算分离，支持 9:1/1:9 等官方比例；3% 几何验证继续保留，不声称证明内容无裁切。
- 后端 295 项通过；Swift 新增恢复/版本/资产/比例测试，尚未本机编译（Windows 无 Xcode）。

## 云端准备（当前环境 xmy-test-d5g8c0xcifcefcfd5）

已创建空集合 bf_assets、bf_sync_v2、bf_tool_events；未更改账号、密钥、安全规则或部署业务代码。
需要建立 bf_sync_v2(accountId, revision) 等查询索引，检查新集合权限只允许服务端访问。

## 追加检查点：本地第二批（2026-10-27，尚未推送/编译/部署）

用户最新要求：全部任务与本地检查完成后，才统一推送和编译。此前候选 `4f9e271` 已在 codex/ 分支，CI `40512584068` 已请求取消；生产 saas_fix 未动。不要再次中途推送。

- 第二批本地后端回归 **300/300** 通过；包括 UUID 规范化、事务内父子记录、附属图片归属、归档租约并发与失败恢复。
- SyncV2：云端冲突消息保存确定性 ID 的本地副本，不再无限卡住 outbox；保存远端会话墓碑，防旧子消息另起空会话；一个文件上传失败不再阻止其他文字和文件同步。
- ConversationDeletion：删除前写 V2 持久化墓碑，离线 8 次失败不再丢弃删除意图；旧 300 条队列裁剪仍有 V2 保护。固定 session 跨 await，防切账号后改错队列。
- CloudAssetHydrator：选中的云端附件先恢复，再供聊天看图和编辑引用；最近生成图的云端引用可下载继续编辑。图片 URL 压缩缓存 key 增加账号和资产信息。
- 统一 ToolManifest：原 ToolRegistry 为兼容别名，schema 在 ToolManifest+Schema.swift；工具注册与执行权限共用策略；ToolDispatcher 在并行搜索前和实际执行前校验，修复先搜索后鉴权的问题。
- ImageUseCase / ResearchUseCase / DocumentUseCase / ChartUseCase / ArtifactRepository 已抽离，旧 VM/ToolPipeline 留薄适配。聊天大循环仍未完全抽成 ChatTurnRunner，不宣称全 App 重构完成。
- 图表严格逐项校验，防 compactMap 标签/数值错配；图表成功后设置真实产物标记。文档/文件写入期间切账号会取消，不用新账号落旧内容。
- 图片 requestId 属于不可变 context；同请求网络重试复用，新 prompt 派生新任务 ID。直连上游未证实幂等，不对未知付费结果自动重发。hosted 参考上传改用云资产去重并固定 session，返回后校验登录态。
- 原生优先：取消“字数多就强制叠字”，普通设计交 Seedream standard。structured 对自然语言生成不再是必填；精确文案才后处理。设计指导仅在图像请求时注入。
- ExactTextWorkflow（新）：明确要求原文不变时本地 Vision 提取（尊重 EXIF、保留置信度），疑似数字/小字不清时提示补充；避免把视觉 prompt 画成文案。仅是代码接线，未验收真实素材，不得宣称 OCR 正确率 100%。
- Canonical cloudfunctions/shared/image-policy.js 明确 standard；删除“省略 optimize_prompt_options 就等于关闭优化”的未经证实做法；直连 Pro 也显式 standard。
- Canonical shared/log-safe.js、error-catalog.js；旧函数路径为薄适配器，由 bundle-function-shared.js 打包，避免手工维护副本。bf-api/domains/foundation.js 抽出数据/资产路由。
- shared/image-archive.js + bf-jobs 特定 timer 分支写好：只处理已成功结果，无模型 API；租约避免并发归档。**触发器/索引尚未配置，也未部署**。清理规则保留 pending/needs_attention 归档及未入账记录。
- 新增 Swift 执行边界/云恢复/并发冲突/墓碑测试，**尚未 Xcode 编译**。本地第三方语法扫描 145 个文件，新增代码无语法错误；三个原有文件是解析器基线报错（WebSearchService、PosterContextRegressionTests、StreamActivityTests），不是 Xcode 结果。MemoryService 的 CRLF 误报已用规范化换行排除。

### 下一步按优先级接续，不重复已经完成的代码

1. 先读本文件与 Git 状态，保留所有本地新增文件。跑共享打包、后端全套、变更 Swift 语法；审计新增 Swift 类型/访问控制/跨 await（Windows 无 Xcode）。不能拿语法扫描当编译通过。
2. 补单图持久化任务恢复闭环：context 已有稳定 requestId，但 App 重启/手动“再试一次”仍可能建新 ID；成功模型结果归档后还需 owner-scoped 查询与客户端认领/保存，不能重复生成。ImageUseCase 还未存任务到磁盘。
3. bf-jobs 归档 timer 的时长、并发、索引和线上 SDK 接口实际核验；准备资产引用对账 dry-run，不自动删除用户作品。对象存储上传/commit/签名需真实集成测试；不创建永久密钥。
4. ExactTextWorkflow 接线需补置信度与原文覆盖测试、文字为空时不误走原生生成；图片编辑缓存/批次下载结束后再次校验 session。当前 OCR 仍有两个入口实现可统一（FileImportService 已委托新 recognize）。
5. SyncV2：旧类型迁移策略、资产未上传的占位说明、删除旧 outbox 的永久失败状态 UI、长单条消息超限策略、文件/记忆冲突保留策略；首次恢复不要覆盖本地照片。对照 tests-backend/foundation-behavior.test.js 与 CloudFoundationTests。
6. 完成任务清单对应可交付范围和视觉回归，核查 CloudBase 权限与索引（已建空集合 bf_assets/bf_sync_v2/bf_tool_events，已有 account_revision/account_created 索引）；核验 pro_only 不变。P2 图层仍禁用、混合路由必须晚于质量验收。
7. 全部本地工作就绪后才推送，CI 失败必须修复重跑；再部署/真实调用/对账/下载精确版本 IPA。最终要报告未测项，不能称零 bug。

### 环境、验证工具与 Git 发布注意

- Root：C:\Users\24072\WorkBuddy\2026-10-08-11-01-51\aigc-video。当前 codex/app-foundation-20261027；远端 saas_fix=736a8bbc，与旧本地 c662714 相同树，不要再次对齐/reset。备份分支 codex/foundation-pre-alignment-20261027 保留原始历史。
- backend tests 日志：TEMP/bossai-foundation-backend.log；本轮未动任何在线业务部署。
- Swift 第三方 parser 安装于 TEMP/bossai-swift-parser；Python=C:\Users\24072\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe；PYTHONPATH 指向该临时目录，文件需批准环境读取。规范化 CRLF 后和 Git 基线比较。不能把 parser 依赖打进 App。
- 新建根目录/打包 shared/写 Git 需要原生工具 require_escalated；已获用户实施授权，不重复问。现有 PAT 路径 C:\Users\24072\.workbuddy\gh-pat-aigc-video.txt 只可私下读，不输出。publisher 当前只发布一个父提交已存在远端的 commit，多本地提交时需补祖先上传或使用正常非强推，不丢弃本地历史。
- 用户要求接近剩余 5% 时创建本线程五小时续跑。当前尚有额度；续跑保持安静，只通知实质进展/失败/交付/用户必需操作，不新建独立任务，不绕过配额。

## 必须接续，不得冒称全部完成（第一批原始记录，以上追加优先）

1. 候选 CI Swift 编译与 iOS 测试，修复实际失败；新功能仍需运行时集成验证。
2. 后端生成结果归档：把 bf-image/组图已付费结果保存到自有对象存储，记录归档状态并从定时任务恢复；归档失败不能重新生图或改写生成成功。
3. SyncV2 账号/删除/冲突/首次恢复交叉审计：特别防 await 期间新增 outbox 被旧检查点覆盖、父会话删除后孤儿消息复活、记录更新时间和提交游标混用。
4. 文件同步和上传协议实际验证（沿用已有 SDK、现有凭据）；不创建永久密钥，不把签名链接入库。
5. 按计划继续工具 Manifest/Dispatcher 与领域 use cases、后端分域、精确能力和成本生命周期；质量验收前保持 Pro，不自行切 auto。
6. 最终全套测试、部署、版本对账、下载对应 IPA。未测真机与真实素材如实标明。

现有 GitHub Git 推送有网络限制；`scripts/publish-committed-head.mjs` 用官方 Git Data API 推已提交精确字节、校验完整 tree/commit、不强推，密钥只读用户现有凭据文件。使用它前必须干净提交，且 commit 作者/提交者日期为 UTC；发布的是 codex/ 分支候选，不自动覆盖 saas_fix。
