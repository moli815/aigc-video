# 横图改竖图事故与窄范围发布 · 2026-11-17

## 现象与云端证据

客户11:57:49通过会员登录，在会话ACD766E9-C206-4832-B2F5-8C83659ED49A发送横向3200×1334展会背景，要求“根据这张背景图的内容生成竖版宣传海报”。本轮只在授权事故账号内检索消息、同步文件、任务和模型调用，没有借用其他账号素材。同步消息没有工具参数，不假称恢复了完整原始工具调用。

请求43EFC8D4-4D01-424F-9C14-5EB3E5623132确实传入1张参考图，调用doubao-seedream-5-5-261028，23.603秒成功。最终1584×2816已经是竖版，但素材归档中的background为2368×1776；原品牌、软件大屏和业务素材被新的通用场景图取代，随后套成标题、配图与正文分栏。并非仍在调用5.0，也不是只需更换ratio参数。

证据在outputs/portrait-incident-20261117：cloud-evidence、case、assets、original.jpg、delivered.png及generated-background.png。原图包含业务与联系人资料，输出目录不推送为公开素材。

## 源码根因

bf-image/index.js先选择5.5，再在structured.text达到minChars420时调用commercial-composer.prepare。composition用commercial-artwork替换视觉描述、添加禁止文字和仅生成素材层的指令，把实际模型画布改为素材比例，再由旧poster排字器重建成品。这适用于部分新海报拼装，但不适用于完整已有海报改版。启用5.5并不代表每个请求都让5.5直接制作完整成品。

## 本轮修复范围

新增shared/poster-reformat.js，在真实最新用户回合明确要求“这张/原图/背景图改为横竖版”等时，透过旧包已传递的structured.poster_reformat标记目标画布。API的JSON/SSE共用sanitizeToolCall，客户端无需改动。image入口在领取幂等任务前规范目标画布与reference任务；直接请求的明确原图改版也能识别。

这类请求保留实际原图和所有输入槽，绕开旧配图/文档排字及相互矛盾的无字、固定原画布约束，用简洁的完整重排指令直接调用5.5、PNG及目标比例。60×90保持2:3，3:4保持3:4；无明确比例的竖版才默认9:16。服务端不写死蓝金配色、业务数量、栏目布局；用户要求更换风格仍优先。

API跳过该原图改版的额外文案改写，避免把模型推测的转录稿再次润色为新事实。缺原图返回422且不调用供应商；原有会员、归属校验、输入读取、幂等、费用与unknown-outcome逻辑沿用。mockup、client overlay、图层、组图、preserve_assets、只扩图/裁切、只参考风格、只贴Logo保持原路径。

未全局启用nativeCommercial/nativeCopy、OpenCV或新依赖，未改runtime、App、员工端，不出IPA。旧pro_only/IMAGE_MODEL_PRO只是历史配置名称；线上两模型值实际均为5.5，不能对用户称“5.5 Pro”。

## 验证与边界

- Node18全量912/912，新增7项改版回归；两条旧静态源码断言更新为支持独立改版分支。
- 精确候选ZIP旧HTTP夹具：401、会员过期403、额度429均在供应商调用前；大段structured文案仍完整传原图给5.5，实际1584×2816/PNG，没有旧配图/无字指令；缓存重放只有一次调用、一次扣费；缺原图422；60×90为2:3；普通生成保持横版。
- 一次直接5.5对照25.240秒，另一次精确候选包/生产策略/真实会员旧HTTP32.577秒，1584×2816。两次都用本事故原图，不增加用户修图专业提示词。第二次的工具标记来自已打包API sanitizer，未再付费重复跑聊天规划。故不冒称是完整真实聊天端到端测试。
- 最终成品目视：Logo和400-7758-119保留，8项能力、5项业务、5类场景均可见，平台大屏、手机及指挥中心回到画面，避免原失败的无关照片+文档分栏。源图内同样存在的重复文案不能用OCR误差或模型输出反推为新增事实。
- 原生成重排仍不等于像素级原件保真；屏幕极小字、产品细节及所有新编约500字文本逐字无错均未获认证。500字自由新文案、完整自动字体修复继续独立待办，不能用此次可用改版冒充全部完成。不承诺100%无错或与ChatGPT90%相似。
- 真图请求测试账号扣¥0.56、缓存¥0，按当前配置供应商估价¥0.28；客户扣费0。直接对照估价约¥0.28，两次图片合计估价约¥0.56，不是平台已结算账单。临时账号删除，财务流水保留；后续检查清理孤立测试任务，不删客户数据。

## 官方资料与成熟方案

- [火山图片生成API](https://docs.volcengine.com/docs/ark/image-generation-api?lang=zh&redirect=1)：image真实输入、目标尺寸、PNG及5.5契约；不是依赖未公开“满血”参数。
- [Seedream5.5说明](https://docs.volcengine.com/docs/ark/seedream-5-5?lang=zh)、[官方提示词指南](https://docs.volcengine.com/docs/ark/seedream-4-0-5-0-prompt-guide?lang=zh)：明确编辑目标、准确文字加双引号、避免互相冲突的冗余约束。简洁建议不是截断客户长文的理由，图层/OCR能力不是生成零错字的保证。
- [Adobe Generative Recompose](https://helpx.adobe.com/photoshop/desktop/crop-resize-transform/transform-manipulate-reshape/recompose-images-with-generative-recompose.html)：以目标画布重新组织构图，借鉴其“重构”与简单裁切/补边的区别；闭源产品流程参考，未引入其代码或服务。
- [ComfyUI-KJNodes源码](https://github.com/kijai/ComfyUI-KJNodes/blob/main/nodes/image_nodes.py)：阅读ResizeAndPadImage等成熟预处理，确认padding不能承担业务语义重排。GPL项目、Python/ComfyUI运行时，不复制进本项目Node18生产包；无新增依赖或许可证负担。

## 发布与回滚

发布目录outputs/release-poster-reformat-20261117。新鲜备份基线API11-16 13:12:23、image11-17 11:41:39；各SHA见before.json。相对最新线上，image只改index.js并新增shared/poster-reformat.js；API只改shared/image-delivery.js、commercial-copy-review.js并新增同模块。依赖零变更。必须官方SCF UpdateFunctionCode InstallDependency FALSE，先image后API，下载逐文件校验，不使用整个脏工作区部署。

脚本scripts/release-poster-reformat-20261117.cjs：deploy-image、deploy-api、verify、rollback-api、rollback-image。回滚先API后image；只用本目录before包，脚本校验线上仍是本轮产物才允许回滚，防止覆盖后来他人补丁。最终时间、Active、哈希、门禁及上线状态见目录deployed-*.json、exact-*.json、verification.json与post-release-gates.json。本文不能用候选状态冒充部署已完成。
