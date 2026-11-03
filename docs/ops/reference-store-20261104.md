# 历史图片账号归属桥：离线准备阶段

当前生产仍为11月3日晚 `cad6487` / 本地 `ec7b224` 的设计与文字层级版本。本次只新增独立模块与离线回归，**没有接入 HTTP 入口，没有部署、没有生成新图片、没有出 IPA**，不能写成客户的组图丢素材已经修复。

## 已核对的真实来源

- `ImageMemory.description` 返回的是 StoredFile 的 UUID，`library_refs` 也是这些 UUID。它不是40位私有 asset ID。
- `SyncV2Engine` 将文件保存为 kind=file 的同步记录，payload.asset 才是已上传原图的私有资源描述。服务端同步键采用 `sync-v2.key(accountId, "file", UUID大写)`。不能查全局 UUID 或按字符串长度猜映射。
- 当前 `ImageMemory.selected` 已检查账号、检索已发编号、数量和顺序；但 Streaming 的 `if !memoryFiles.isEmpty` 会直接以历史素材替代所有 refs，不会继续合并当前附件或最近底图。仅鼓励模型同时传 library_refs 和 source=both，可能仍丢掉底图。
- `/series/start` 透传 structured，却只保留 hasImage；executeSeriesStep 实际 image=undefined，旧重试路径同样丢图。必须同时修子任务与重试，不能只修 start。

## 本次已完成的边界模块

`shared/image-reference-store.js` 是独立账号归属桥，接收现有同步存储的 readFile 适配器及私有 asset-store，不引入数据库、SDK或模型依赖。

- 请求契约明确 version=1、mode=append/replace、1至4条有序素材。每项明确 kind=library 或 asset 和素材角色，不以格式猜类型。
- library 只能经本账号的有效 file 同步记录取得原图描述，校验删除状态、payload ID、image 分类和 MIME。asset 直接引用也必须带完整资源描述，经 asset-store 复核账号、ready状态及摘要/类型/字节数。
- 同一 UUID 大小写去重、同一资源不同入口重复引用均拒绝；完整验证完才签 URL，缺素材不能回落到无图生成。
- prepare 输出可持久化 manifest，只含来源编号、角色及资源摘要元数据，没有 URL、base64或图片像素。重复 prepare 结果稳定，但这不是计费任务 claim 的替代品。
- 每次 sign（包括重试）重新核验归属/删除状态/原图版本并生成短期 URL；记忆图被删除或改成另一张时拒绝，不能静默换人。顺序与角色原样保留。

9项新增离线行为回归包含真实 sync-v2 写入后的映射、错误适配器返回他人行、删除/损坏记录、非图片资源、大小写/资源重复、非ready资源、重试重签与角色顺序、记忆删除/替换、URL不能冒充授权。全部后端回归490项通过。

## 下一步接线，尚未完成

1. 从 API 当前账号的 recall_history 已发图片编号建立同步 lookup，按现有 key 算法读取 file，而不是扫描最近客户请求。向模型提供已校验、明确角色的引用契约；保留旧工具和 library_refs 语义。
2. 针对旧包确实透传 structured 的入口编译新引用。append 必须保留实际收到的当前底图，replace 必须已有完整底图与素材清单；不得仅因拿到一张历史 Logo 就覆盖底图。服务器没有完整原图或没有同步记录时明确失败，不能猜测补图。
3. 在任务 claim 及账号校验之后、预留额度和供应商调用之前 prepare；将 manifest 存在组图任务。子图与重试统一 sign，不持久化短期链接。兼容没有新契约的旧请求，避免把全部旧组图挡住。
4. 对请求槽位+manifest做幂等指纹，重放不能换一组素材，成功子图不重复出图；取消和删除不得绕过归属校验。
5. 完整行为测试必须验证 start→step→retry：两张不同素材按顺序实际抵达上游、缺图零供应商调用/零扣费、跨账号拒绝、签名过期重签、素材删除后不再使用，以及不带新字段的旧请求保持原行为。
6. 通过后从**最新线上ZIP**构造候选，使用产物门禁逐项允许差异，再依授权部署、核对 Active/源码、隔离验证及回滚。不要用18点或晨间包覆盖设计v5、原生文字层级和DSH流式修复。

本模块尚未在生产使用。不得将离线测试数或源代码合并当作完整旧客户端链路已修好的证据。
