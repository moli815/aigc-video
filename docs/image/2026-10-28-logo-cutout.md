# Logo先抠透明底，再原样合成

目标：非透明Logo不要带着白色或有色矩形贴到海报上；图形和文字来自原素材，不能交给生成模型重画。

## 复用系统能力，保持边界

独立 `BrandAssetCutout` 接在 `PreservedAssetWorkflow.generate` 的付费底图请求之前，本机完成透明处理。原有预览定位、原图几何、请求编译、auto路由、文字和产物保存不改协议。

- 已透明的素材直接保留原始字节；用户要求保留底色可选 `background=keep`。
- Logo默认auto：纯色背景按边缘一致性检测，只移除连通外部的底色，保护标识内部的白色图案；裁去无用透明边距后等比贴回。
- 复杂背景复用iOS17+的Vision主体提取，原像素通过透明蒙版输出，不重绘。按用户最新要求，默认自动采用可用最佳结果，不因置信度或复杂程度让用户反复确认；严格校验可在线打开。解码失败、完全空蒙版等没有有效输出的技术失败仍如实报告。
- 二维码保护扫码留白；模型标注kind=qr，另以本机条码识别防误去底。去除二维码底色的冲突要求会明确拒绝。
- 处理工作图最多2048长边，在后台执行；失败和取消发生在底图调用之前，不因抠图失败重调Seedream。
- 该轮覆盖“替换Logo链路的去底”，不宣称已有独立抠图编辑器、任意照片完美抠图或任意复杂背景100%保真。复杂背景仍需实机验证。

## 在线调节与API替换边界

沿用已有 `/me.appBehavior` 通用通道和管理端运行时配置，不添加第二套配置系统。APP_LOGO_CUTOUT、APP_LOGO_CUTOUT_BEST_EFFORT、APP_LOGO_CUTOUT_TOLERANCE、APP_LOGO_CUTOUT_MAX_EDGE、APP_GENERATED_PREVIEW_ENABLED、APP_GENERATED_PREVIEW_EDGE 可在线修改；App对处理尺寸和预览隐私上限保留硬安全界限。

模型/API接入沿用稳定的hosted请求信封（任务、参考图、几何、质量）和统一产物/错误信封。兼容API可改服务端地址、模型、凭据与路由；不同协议通过服务端适配和能力表转换，不让App业务层依赖厂商字段。新增原生能力或超出已发布客户端契约仍需更新App，不能承诺任意新接口都免发包。配置不得下发执行代码或永久服务端密钥。

官方参考：[Apple Vision 前景提取](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest)、[原像素透明蒙版输出](https://developer.apple.com/documentation/vision/vninstancemaskobservation/generatemaskedimage(ofinstances:from:croppedtoinstancesextent:))。
