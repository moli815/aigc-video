# 当前底图与历史原图混合：离线准备检查点

后续接线/发布记录见[mixed-reference-release-20261104.md](mixed-reference-release-20261104.md)。以下保留为当时准备阶段记录，不能据此回退最新线上版本。

2026-11-04 22点接续。线上仍是21:17全员启用的商业设计版本；本节新增模块**未接入HTTP入口、未打包部署、未新增付费出图**，不能写成source=both已经全面修复。DSH App/员工/审批提醒改动保留。

## 已核对的实际旧包路径

- `ChatViewModel+Streaming.swift` 487附近：只要library_refs选到历史文件，refs立即被历史图片替换，source=last/attached/both的当前输入不再解析。只加prompt不能让旧代码自动合并。
- `ImageService.swift` 376附近：hosted请求会先将实际refs上传为本账号私有asset，经`/api/assets/urls`签名，再把URL放body.image。服务器可以把**确实已收到的私有图片链接**恢复为资产引用，不必持久化URL或下载任意外链。
- `bf-image/index.js` 当前单图入口明确拒绝structured.image_references；现有分步组图只接历史replace。`series-reference-input`主动拒绝append，尚未承诺支持。
- 旧image_series执行分支没有像image_edit那样解析本轮refs，故不能仅给series加source=both就声称当前附件到达服务器。没有当前输入或可验证同步映射时，只能明确缺图，不能挑“该账号最近一张图”代替。

## 成熟方案依据与边界

- CloudBase官方[SDK文件管理](https://docs.cloudbase.net/en/storage/sdk)：以fileID标识对象、按需要获取临时访问链接。借鉴对象身份与临时传输地址分离；不把签名URL当成永久原图ID。使用当前classic存储与已有SDK，不能误套PG RLS代码。
- OWASP官方[IDOR防护](https://cheatsheetseries.owasp.org/cheatsheets/Insecure_Direct_Object_Reference_Prevention_Cheat_Sheet.html)：每次访问必须校验当前用户对对象的权限，难猜的标识不能替代授权。借鉴逐对象归属验证、最小范围lookup。没有复制第三方实现或引入新包，Node18已有URL/crypto即可运行。

## 新增的独立准备模块

`shared/image-reference-merge.js`，目前不被生产入口require，亦未复制进bf-api/shared或bf-image/shared：

1. 缺少新引用契约时原样保留旧请求行为，不读取/改写旧image字段。
2. append必须确实收到当前图片。只识别当前旧包使用的HTTPS COS账号私有路径`user/<owner摘要>/assets/<像素摘要>.<类型>`；不支持任意外链或inline像素的自动持久化。
3. URL仅提供定位信息，不下载它、不把签名当授权。按当前账号和摘要计算asset ID后，复查数据库行的账号、ID、ready状态、摘要、MIME/扩展名、字节数、cloudPath与fileID对应关系。即使lookup适配器返回他人的行，也拒绝。
4. 当前输入排在前，历史原图保持原选择顺序追加。复用image-reference-store完成所有原图/重复/归属检查，才生成仅含源ID、角色、摘要的manifest；不签发链接、不持久化URL/base64。
5. 输入限制总计4张；角色数量不匹配、当前底图缺失、跨账号、替换模式丢弃当前底图、资源重复均拒绝。未知角色用“当前底图/当前素材N”，不猜测有人物、Logo或某设备。
6. 幂等指纹绑定当前资产、历史选择/顺序/角色，不受URL过期或签名轮换影响。后续重签仍走原图删除/版本检查。

新增8项真实模块行为回归：顺序/角色/无URL持久化、签名轮换身份、跨账号和错误lookup、恶意URL、缺当前图、replace冲突、数量/角色/重复，以及重试前删除/替换。使用现有真实reference-store与内存数据库夹具；不是供应商或真实App端到端验收。

## 下次接线必须一起完成，不能只去掉拒绝条件

1. **API工具编译**：仅对已配对recall发放并验证的历史ID启用混合元数据。单图混合时将历史library_refs转入structured并从顶层移除，让旧客户端继续发送真实当前refs；保留它的source/source_index(s)及当前角色选择。不可把所有检索结果自动塞入任务。
2. **品牌像素保护冲突**：旧客户端preserve_assets依赖本地reference_index。移走顶层library_refs后，历史Logo不会自动进入本地合成器，索引可能错配。没有兼容的服务端像素合成方案前不得为这类请求开启混合分支，不得把它改为模型重绘Logo来伪称精确保真。
3. **当前组图缺槽位**：旧series未发送本轮图时，必须先证明聊天/同步记录中有本次明确选定的原图ID与账号映射；没有证据不能用全局或账号最近文件补齐。append helper本身不能解决客户端未上传素材。
4. **单图幂等**：当前claimIdem(done)会直接回缓存。新引用任务必须在首次执行保存不可变指纹，重放更换素材或角色应409；并发claim失败不能留下可免费重复执行的任务。不能只在调用模型前检查一次。
5. **分步与重试**：原图检查在供应商调用/预留之前；manifest存入真实任务，step/retry按当前accountId重签，不能依赖旧URL。不要修改现有历史replace任务的指纹算法或让旧taskId失效；新混合任务使用清晰版本边界。
6. **真实成本**：输入图片数量按最终合并结果记账和预估，最坏额度预留、成功计费与model_calls.inputImages一致。
7. **验收**：用实际旧式工具请求跑API→单图/series→step→retry的handler回归，证明底图、人物/Logo全部实际抵达上游；缺图/跨账号/删除/并发/换素材拒绝均零供应商调用。之后才做最少量合成素材隔离在线验证。
8. **上线**：备份当时最新设计函数与配置，只打包已验证业务文件，不运行会覆盖DSH改动的全量shared bundler。官方SCF InstallDependency FALSE、逐文件下载核验，保留准确文字和设计开关、既有引用任务。回滚不能裸用早期ZIP忽略新任务。

下一阶段只读描述/预览还需单独解决“unknown素材被猜成人物”；本模块没有给前置模型新增图片传输，也没有声称已经识别了画面。
