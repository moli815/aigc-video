# 2026-10-27 发布验证（北京时间，接续记录）

本记录取代 IMPLEMENTATION-STATE 中“尚未部署”的旧状态，不表示 A/B/C/D 全部架构阶段完成。

## 已部署及真实验证

- bf-api、bf-image、bf-jobs 已更新到本提交的源码，共享模块由 bundle-function-shared.js 统一打包。
- 更新前保留 bf-api v3、bf-image v3、bf-jobs v1，未覆盖现有密钥或用户数据；saas_fix 分支保持原样。
- 新资产/同步/事件集合为 PRIVATE，account_revision、account_created、archive_pending_ts 索引已建立。
- bf-jobs 增加 asset_archive_retry，每五分钟检查最多三条成功但未保存的图片；不会调用生成模型。真实恢复一条既有结果，ready=1，costCommitted 仍 true。
- 隔离临时账号实际生成 Seedream 5.0 Pro 中文海报一次，约 54 秒（含下载）；模型为 doubao-seedream-5-0-pro-260628。已人工查看标题、插画和底部信息分布。此单例不能代替完整审美/人脸/编辑素材矩阵。
- 对象存储 prepare、真实签名 PUT、commit、重放去重、重新签名下载均通过；下载 SHA-256 与原始图片一致。
- 实际同步测试通过：事务版本单调、重复提交不增加版本、固定水位分页、旧版本冲突返回、会话墓碑阻止迟到子消息复活。
- 事件重复提交有持久回执；查询测试记录确认 prompt/token/headers 未落入事件文档。错误响应使用稳定公共错误码及自然语言。

## 集成测试发现并修复

1. CloudBase 普通文档读取返回 data 数组，事务读取返回单对象/null。统一 documentOf 适配，并让模拟数据库复现真实两种形态。否则增量消息父会话检查、版本计数与归档租约均可能失效。
2. getTempFileURL 必须明确 COS_URL 才匹配当前私有存储下载契约。修复后复用原待提交文件完成 commit，无需重新生图。
3. 云存储/输入错误原先落入 INTERNAL；增加稳定公共错误目录，详细诊断仍仅入受控服务端日志。

## 编译关卡

- 后端 302/302 通过。
- 40530911004：Release App 与 Swift core 编译通过；iOS 测试中 CloudFoundationTests 六项数据容器测试发生进程退出，其他 270 项通过。因此该轮不发布正式 IPA。
- 修复测试夹具：保留 ModelContainer 生命周期，返回独立 ModelContext，关闭测试自动保存；正式 App 已由应用生命周期持有容器。下一轮 CI 必须验证这些测试实际通过，不能以“270 条通过”替代整体关卡。
- macOS ARM runner 长队列确认为平台容量；使用官方 macos-15-intel，保留相同 Xcode、测试和发布依赖。

## 仍未完成的范围

- 真机多账号升级/重新登录恢复、原始人像编辑与海报重设计的完整素材矩阵仍待验收。
- App 重启后单图未完成任务的完整认领恢复、ChatTurnRunner 进一步抽离、资产对账清理 dry-run 未完成。
- 图层能力与未来 Pro/Flash 混合路由未启用；维持 pro_only + standard。

最终 IPA、对应 commit/run、文件哈希以及测试结果在交付记录补充；禁止交付失败关卡的候选包冒充正式包。
