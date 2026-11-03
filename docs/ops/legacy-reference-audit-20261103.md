# 旧包参考图与部署产物：20:21续跑审查

当前发布基线为poster-incident-20261103（远端e2b7e4d），不是晨间版本。本轮没有修改生产函数、没有重新出包、没有付费作图。保留DSH的App和审批提醒改动。

## 已确认的参考图缺口

- 旧App的image_series工具没有完整的素材来源参数。startSeries会传structured，却不传原图；客户端自行拆成image_generate也不安全，任务规划器会按原始组图意图再次识别成series。
- 服务端/series/start目前只记hasImage，executeSeriesStep缺少完整来源恢复；旧/series/retry明确传image:undefined。即使接口第一次收到图片，重试也可能丢失。
- source=both在旧客户端表示“最近生成图+一个上传素材”。仅调整云端prompt不能让这个客户端突然发送第二个未上传的附件。
- 素材库ID与私有asset-store的资产ID不能混用；不能把一个ID仅因长度相似当成已授权资源，更不能用别的客户或最近一次请求的图片兜底。

## 可兼容实现的边界及下一步

优先使用已经透传的structured承载版本化引用，不增添旧包不会执行的新工具：

1. 在账号素材检索结果中提供可校验的私有资产ID及角色；对旧记忆图片ID先做账号内显式映射。没有完整原图就不能承诺原样保真。
2. 用shared模块统一验证账号归属、ready状态、数量、顺序与角色，再由asset-store.sign按需生成短期URL。客户端/请求提供的任意URL不能当作授权凭据。
3. 任务里只存资产ID和角色，子图及重试均重新按任务accountId解析；不持久保存签名URL，不把base64塞进任务文档。
4. claim幂等任务后、预留额度/调用模型前，验证所需素材已齐备；缺图不能退化成文生图后伪称完成。校验失败不应产生供应商调用。
5. 固定合成素材验收底图、人物、Logo均实际到达上游；同时验跨账号拒绝、过期URL重签、重试及删除后素材不可读。仅看prompt中写了“保持人物”不算通过。

以上尚未接线或部署，不能写成“旧包组图丢图已修复”。必须先打通ID映射和真实旧请求回放，再动生产入口，避免半条新链路使当前组图失效。

## 已完成的部署产物检查工具

scripts/check-function-artifact.py可在本地比较上线前ZIP和候选/下载的线上ZIP：

- 精确列出新增、修改、删除文件；未逐项允许的变化一律失败。
- node_modules变化单列，不能被业务代码白名单默认放过。
- 检查index.js、package.json、scf_bootstrap存在；拒绝危险/重复ZIP路径；不展开ZIP，不显示源码或凭据。
- scripts/test-function-artifact.py六项离线回归通过。

对18点线上包与上线前备份的实测差异：五个业务源码文件加node_modules/.package-lock.json；没有依赖执行源码变化、没有额外缺失文件。锁文件变化在这次审查中明确允许，不代表未来可以自动放行任何依赖变化。

例子（从仓库根目录运行）：

```powershell
python scripts/check-function-artifact.py BEFORE.zip AFTER.zip --allow index.js --allow shared/text-scene.js
```

这只是产物门禁，不能替代云函数状态轮询、线上源码核对和业务验收；也尚未关闭云平台自动安装依赖。不要为获得相同ZIP哈希反复部署生产函数。
