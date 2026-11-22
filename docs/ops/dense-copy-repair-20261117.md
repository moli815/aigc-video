# 11月17日22点续修：密集文字候选

状态：候选，未部署；不改App/员工端/管理端/生产runtime。既有线上API18:36:05、image12:57:46是本轮开始时基线；下一次发布需重新备份并核验。

## 事实与根因

1. 前轮605字符实验包含6项能力，但规划的自由提示词写了5项。实验脚本还把规划4:5强设成9:16。不能将这些不一致全归咎于5.5，更不能把直接供应商实验称为完整App HTTP验收。
2. 新的一次官方拆层复用原followup.png，返回1536×2731，原图1584×2816。约3%均匀量化被旧1%尺寸门槛拒绝。实际ORB/RANSAC有166匹配/139内点，6格分布，误差0.198px，归一化角点误差0.298px；证据支持可靠的等比例映射。
3. 单个定稿字段的五步流程分列显示，旧匹配器只接受一个连续列。没有缺字，却被误判缺失。新适配只接受原文逐行显式连续编号，逐个完整匹配；保留数字/标点，不借其他栏目补步骤。
4. 旧原生文字重绘按OCR高度×0.75估字号，实际正文从约30px变24px，造成字偏小。新增可选真实字形路径，按测得字高及锁定字体实际metrics增大；不低于既有验证字号下限，不增加字、不改文案。

## 修复与实测

修改native-layer-registration.js、native-copy-transcription.js、native-copy-refinement.js、surface-typography.js。量化适配仍必须过原有分布/内点/误差/角点门禁；纵横形变、裁切位移、空白同纵横比都拒绝。原图不被重采样；仅把底图/透明层/行坐标映射回原图。

复用已有图和本次2个拆层输出，Node18本地回放：20原始字段→26空间片段→55行/605非空白字符，全部用定稿真实字体重绘。首版8.734秒/567MB，字形版12.803秒/731MB；仅本地单实例，不是SCF压测。字形版原有24px正文多数恢复约28–32px。不是通用500字零错或全图审美已达标。

已新增逐像素保护：实际批准surface并集外变化0像素，保存于replay-3/manifest.json；照片内部此前已生成的AC编号/日期不是本次印刷文字范围，不能说已消除；大空白、原生宋体换为现有Noto无衬线的风格损失仍待改进。不能删文案或缩字替代。

原始记录outputs/dense-text-continuation-20261117。仅一次拆层，64.378秒，2输出；配置价估¥0.51非实付账单，已入独立测试台账，客户0扣费。无额外主图，无重复未知请求。

## 官方与成熟实现依据

- 火山5.5 https://docs.volcengine.com/docs/ark/seedream-5-5?lang=zh 与API https://docs.volcengine.com/docs/ark/image-generation-api?lang=zh ：拆层auto/规整文字OCR是几何与近似样式信息，不是定稿真值，不保证500字零错。本轮直接下载并读取官方页面；浏览搜索工具连接失败，不伪称搜索结果成功。
- https://github.com/vercel/satori ：锁定现有Satori/OpenType路径；HTML/CSS到SVG、嵌入真实字体。Satori MPL2，现有OpenType MIT；未复制新代码或增加包。
- https://github.com/linebender/resvg ：实际字形路径栅格化，现有resvg/WASM；上游MIT/Apache2。不是通过生成式锐化猜笔画。
- OpenCV既有ORB/RANSAC的几何验证，现有Apache2运行时；不以相同比例推测同图。不新增OCR服务/IAM/永久密钥。

## 发布门槛

完成多风格/新素材/复杂长上下文的真实旧HTTP路径、费用/幂等/会员门禁、逐字与视觉验收；固定依赖并保存当前线上回滚包，SCF InstallDependency FALSE及下载逐文件核验。当前未部署，无本轮生产回滚；不能拿18点旧ZIP覆盖后续DSH修复。


## 22:55续验结论与接续

- 最终Node18后端941/941通过，0失败；首次937、后续940均记录，不把重复测试计成新增用例。独立旧两段正文HTTP fixture-11与605字HTTP第4/5轮通过；第5轮18.863秒为本地录制供应商/内存DB验证，不是云端性能。所有HTTP复验新增供应商调用0。
- 新增字形worker上限160行，与surface渲染器一致，仍8千总字、320MB worker堆、12秒预算；65行真实字形回归及161行拒绝通过。确定性缺字/溢出/不支持字形转终止质量拒绝；只有worker中断等保留本地重试，不重复主图/拆层。
- IMAGE_TEXT_REVIEW_REQUIRED归类input/不可原样重试；预检字体/服务未准备好独立为IMAGE_TEXT_REVIEW_UNAVAILABLE，可重试。错误error仍字符串，errorDetail是增量字段，不改旧包契约。
- 自身模型相同prompt两次连接失败，未得到对照图；无90%评分，不推断失败调用费用为0。停止继续重复付费尝试，已有图全部离线复用。
- 本地前3轮HTTP失败均已保留：fixture漏取response.usage；随后将供应商已编译prompt误当App prompt触发逐字保护。改用保存的实际tool args.prompt后成功，不把测试适配错误编造成产品新缺陷。
- 下载最新线上bf-image核实：12:57:46 Active/FALSE，SHA256 0de9a0b1d7a6e942e136bce3dd47dce0a4304dc3b8b19754ced7e5fb84b49be1；其中没有native-copy路由或native-*模块，不能把本地HTTP成功称线上完成。生产ZIP也没有shared/manifest.json，不能假设所有历史部署均带构建manifest。
- 打包前门禁正确停止，未构建可发布ZIP、未部署、未改runtime。outputs/dense-text-continuation-20261117/package保存新鲜线上ZIP、生产index、before.json、prepared.json（pass:false，NATIVE_ROUTE_NOT_PRESENT_IN_PRODUCTION）。不要将其误当已经通过产物验收。prepare脚本只有下载/候选操作，没有发布能力。
- 下一步接入必须以这个届时最新线上包为基底，逐hunk审查index新增nativeCopyRuntimeOf、预算预留、claim恢复、一次结算、逐模型费用、copy等待/终止状态；同时纳入native-copy-budget、native-copy-policy、claim及billing持久化支持。commercial-composition-runtime要补nativeResources/renderNative/nativeSerial，不能连同未经验证的product_v2等其他候选盲目覆盖。审查后生成固定依赖ZIP，精确产物用旧HTTP测试，而非只测工作区。
- 质量仍未过全量发布：仅605字一个保存的真实样例，全字形与区域外保护通过；字体家族/局部强调、原生大留白、照片内部标牌及负面内部文案仍有不足；旧31字段复杂样例未全覆盖。需多风格/新素材/长上下文、完整API到image、压力与延迟验证，再在临时账号真实供应商请求下验收。不得先向客户启用再补门禁。
- 报告：outputs/dense-text-continuation-20261117/report.html；机器汇总verification.json；原始成本和55行拆层在layers/report.json。无本轮上线、无本轮生产回滚动作。未更动App、员工端、管理端、DSH审批提醒或凭据。
