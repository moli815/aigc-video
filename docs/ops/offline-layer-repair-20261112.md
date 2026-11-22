# Logo与字体层离线修复（2026-11-12 19:53，北京时间；候选未上线）

## 本轮范围与真实结果

用户要求减少额度消耗，继续实际修复。只重放已有Logo和本地反例；0次聊天模型、0次图片模型、无云端配置/部署/客户额度变更。不是又做一批提示词样例，不声称整个商业海报链路已修好。

## 三个源码根因与已落地修复

1. **纯色Logo白边**：`protected-asset-compositor.uniformCutout()`过去只把连通背景的alpha清零，边界JPEG混合像素仍是含白背景的不透明颜色。现在按I=alpha×F+(1-alpha)×B，在已确认的连通背景窄边界内，用邻近可靠实色恢复软alpha和边缘前景色；颜色模型残差大、低对比或没有可靠前景时不强改。主体实色与内部白色细节保留，不改变输入Buffer。未知复杂背景仍沿既有GrabCut最佳努力，不宣称精确分割。
2. **字体图层硬边**：`surface-typography.render()`将每个有字像素alpha强行写255，并把原背景当成不透明，导致透明图层合成出现硬边或暗边。现在用Porter–Duff source-over保留目标alpha，用resvg的字形覆盖率配真实指定墨色，避免低alpha PNG RGB反解的量化偏色。仍保留原文、真实字体、2倍栅格与越界/溢出拒绝；没有靠删字、缩字或模板列数通过。
3. **遮挡漏判**：`image-protection-runtime.copyOcclusions()`只检查四角与中心包含，细长屏幕区域横穿文字但角/中心均在外时误判无遮挡。改为凸四边形与文字矩形的分离轴检测，边缘接触不算覆盖。它只处理已有合法定位结果，不能证明上游视觉模型定位可靠。

三个反例都先在旧实现实际失败，再修改运行代码通过；不是只新增与实现镜像的断言。修前文本保留在`outputs/commercial-readability-20261112/{logo-soft-edge-before,font-alpha-before,occlusion-before}.txt`。字体中间版揭示PNG低alpha RGB量化偏色，采用真实已知墨色修正后通过，未通过放宽像素误差掩盖问题。

## 真实Logo零成本回放

`scripts/experiments/offline-matte-20261112.cjs`不加载云SDK、凭据或联网接口，直接读取此前已授权归属核验的本地Logo原件。before从本次去底补丁前代码重建，是阈值算法对照，不是旧手机实机输出。

- 原件SHA256：cd17b47c2bc463f619e3ef2e9bc2e30ca6024e2451d31842456da53e3d57a55f（精确值以report.json为准；不拿哈希代替视觉验收）。
- 两版裁出尺寸均1642×328、透明像素均340858；旧版半透明像素0，新版16794。输入RGBA均未修改。
- 旧版约28.6ms，新版约99.1ms；为本机单例，不是云端P95或全背景质量保证。
- 透明PNG和HTML在`outputs/offline-layer-repair-20261112`；独立原始report保留sourceHash、耗时与像素计数。

## 旧App不能被忽略的边界

已逐段检查实际Swift源码，未改任何Swift：

- `ImageToolArguments.decode()`对用户“替换原Logo”强制image_edit与preserve_assets，普通image_generate会被手机拒绝；不能用新schema假装旧包绕得过去。
- `PreservedAssetWorkflow.prepare()`在发出底图请求前删preserve_assets/preserve_outside并剔除Logo输入；`generate()`先在手机执行BrandAssetCutout，再发底图清理请求；`compose()`最后在手机贴回。服务器收到的清理请求通常没有Logo原件。
- 所以**部署服务端去底模块不会热更新手机算法**。对该分支再服务端贴Logo会产生重复合成。BrandPlacementPlanner还会在手机按方位吸附，不能只验模型原始小框就说避让通过。
- 本轮修复直接用于服务器拥有原件的候选保护/字体链路。旧包精确替换继续保留原合同；本机算法更新登记B-17待下次统一出包。服务端替代入口必须先证明旧包参数验证、原件归属、ID发放与最终输出兼容，不能靠改工具名或伪造library_refs上线。

## 研究依据与未解决项

先查真实源码与失败反例，再查[OpenCV alpha matting](https://docs.opencv.org/5.0/extra_modules/alphamat.html)、[Satori布局/字体契约](https://github.com/vercel/satori/blob/main/README.md)。本轮独立实现边缘颜色解混和凸多边形分离轴，未复制外部项目代码，未安装alphamat或新模型。实际仍用现有Node18、pngjs、resvg/Satori与OpenCV WASM依赖。

本轮没有独立OCR，也没有新增权限请求。复杂中文字的自动可靠定位、完全去除原有错字、字体与完整原生构图融合、所有Logo背景的切割、旧手机最终避让、UI透视/遮挡仍须验收。这三处底层修复不能被描述成“整体文字乱码与Logo问题已解决”。

## 状态和接续

候选未部署，无本轮生产回滚。现有回滚ZIP仍是此前只读备份；发布前须重新核对当时线上版本、不能覆盖DSH。只有明确实现变化和离线反例通过后才做少量真实HTTP验收，不重复生成既有基准；本轮不出IPA、不改员工端。先解决可靠的文本/原件定位与旧手机合成边界，再接最终交付链。


### 最终离线检查与几何回放
后端749/749通过，Node18专项19/19通过，shared打包哈希检查通过。CloudBase语义审查：未新增HTTP/鉴权/云端读写路径，不回显headers/env/凭据；这三模块仍是候选，未发布。报告已由独立headless Edge渲染并目视。
此外复用3张既有图，用现有OpenCV ORB+AKAZE做800/1200/1600多尺度匹配，保持原阈值，9次全部拒绝；即使单个探测器有很多匹配也未强贴。详细geometry-replay.json保留。参考OpenCV官方Features+Homography/RANSAC示例，只增加实验sourceMaxSide参数，不接生产、不降低门槛。
已有几何控制4项行为测试通过（已知透视、非相关图、无特征图、原先真实失败），第5项历史源码冻结断言失败，因为本轮有意修改compositor、前轮有意修改index；保存原始输出geometry-controls.txt，不篡改历史hash，不能写成5/5通过。它不是本轮客户接口报错。
剩余自动定位/旧手机本机算法/最终全图文字问题仍未完成；没有新增付费请求和客户费用。本轮没有生产部署，也未运行新的真实生图，后续只有离线可验证修复与明确验收目标才做有限实测。
