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

## 必须接续，不得冒称全部完成

1. 候选 CI Swift 编译与 iOS 测试，修复实际失败；新功能仍需运行时集成验证。
2. 后端生成结果归档：把 bf-image/组图已付费结果保存到自有对象存储，记录归档状态并从定时任务恢复；归档失败不能重新生图或改写生成成功。
3. SyncV2 账号/删除/冲突/首次恢复交叉审计：特别防 await 期间新增 outbox 被旧检查点覆盖、父会话删除后孤儿消息复活、记录更新时间和提交游标混用。
4. 文件同步和上传协议实际验证（沿用已有 SDK、现有凭据）；不创建永久密钥，不把签名链接入库。
5. 按计划继续工具 Manifest/Dispatcher 与领域 use cases、后端分域、精确能力和成本生命周期；质量验收前保持 Pro，不自行切 auto。
6. 最终全套测试、部署、版本对账、下载对应 IPA。未测真机与真实素材如实标明。

现有 GitHub Git 推送有网络限制；`scripts/publish-committed-head.mjs` 用官方 Git Data API 推已提交精确字节、校验完整 tree/commit、不强推，密钥只读用户现有凭据文件。使用它前必须干净提交，且 commit 作者/提交者日期为 UTC；发布的是 codex/ 分支候选，不自动覆盖 saas_fix。
