# 2026-11-27 海报素材与文字保真回归

## 调研与取舍

ComfyUI 的 Seedream 集成按顺序传入参考图，模型版本各自声明容量。借鉴其将参考素材、画布和提示词分别传输的方式。本项目继续用既有 Node.js 服务，未引入 ComfyUI 的 Python 运行时或 GPL-3.0 代码。随后核对火山方舟的 Seedream 5.5 图像 API，单次可传最多 10 张参考图。完整留存 13 张产品图用客户端已有图册和服务端原素材合成。[ComfyUI 集成](https://github.com/Comfy-Org/ComfyUI/blob/master/comfy_api_nodes/nodes_bytedance.py) · [许可证](https://github.com/Comfy-Org/ComfyUI/blob/master/LICENSE) · [火山方舟 API](https://docs.volcengine.com/docs/ark/image-generation-api?lang=zh) · [5.5 使用指南](https://docs.volcengine.com/docs/ark/seedream-5-5?lang=zh)

排印沿用仓库固定的 Satori 0.63.2 与 resvg-wasm 2.6.2。两者使用 MPL-2.0，已在 Node.js 内通过 Wasm 使用。素材与字体在后端可核验。普通画面和用户要求原样直传的提示词沿用各自流程。[Satori](https://github.com/vercel/satori) · [resvg-js](https://github.com/thx/resvg-js)

## 根因与实现

1. 2026112702 的 `ImageToolArguments` 只接受 1–6 的选择参数。它通过 `ImageCompressor.referenceSheets` 按附件顺序生成 768px 宽的图册，每格 384×310，每页最多 8 格。
2. `intent-contract` 只在原件图册场景、用户明示最后一张是 Logo 时携带该位置，清掉可能错误或越界的模型选择。普通请求与原样直传各按已有契约。未经授权的模型字段由 `image-delivery` 过滤。
3. `catalog-print` 在后端校验归属及格子数量后，从最后一格提取 Logo，复用现有抠底。产品图片由既有合成器按顺序上版，编号用真字体。客户已单传 Logo 时优先用单传素材。
4. 首批范围为已明确指定末张 Logo 的原件图册。由图册提取的 Logo 受客户端 JPEG 缩放限制。客户端按文件名另选某张图为 Logo 时，旧请求缺少原始序号以识别文件名冲突。若重现需保留该请求并单独处理。

## 回归与上线状态

| 场景 | 证据 | 结果 |
| --- | --- | --- |
| 13 张产品与末张 Logo | 候选图片 HTTP 入口，模拟旧版图册字段与规格 | 13 个位置逐一核对，编号 01–13，Logo 一处。随意更换同请求素材被拒，原请求重放零费。 |
| 原样直传 | 冻结版的整合文字输入，候选意图契约，隔离供应商请求 | 提示逐字一致，三份附件顺序一致。 |
| 616 字工业园区海报 | 复用已生成底图，候选真字体成图 | 17 个字段的文字摘要、坐标与成品核对通过。主视觉有实景，信息区仍偏平，需要美学专项对比。 |
| 服务端自动测试 | `node --test tests-backend/*.test.js` | 1047 通过，0 失败。 |
| 会员包 | 本地复核发行产物 SHA-256 | 2026112702 校验一致，未编译新包。 |

离线证据保存在 `outputs/print-fidelity-20261127`，未新增 Seedream 付费调用。设计成品仍需实图验收，优先看短标题字形、长文信息区视觉层次及多素材重绘。代码为候选，生产待发布，GitHub 回滚父提交为 `9334b0ac76a6cd7facffa065bd8405f29c0c9fe6`。线上回滚依据沿用上轮已回读的 bf-api 与 bf-image 包，当前候选发布前需重新比较生产版本与文件清单。
