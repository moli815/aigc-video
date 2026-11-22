# 图片链路开关与执行权清单

北京时间2026-11-11；仅本地候选盘点，未发布。客户端按现有仓库代码核查，最终须绑定已寄出包版本；不改Swift/员工端。

| 决策 | 实际消费位置 | 在线可改 / 保留边界 |
|---|---|---|
| 托管/自备Key | ProviderProfiles、CredentialStore、HostedAccount | 旧包本地选择，服务端不能控制绕开服务器的请求；B-01/B-03待出包 |
| 能否调用图像工具 | EffectiveToolPolicy/ToolRegistry + 服务端会员/能力门禁 | 服务端可缩权限，不能凭配置让旧包增加未实现工具；不能删除安全门禁 |
| 本轮/最近/历史素材 | ImageReferenceResolver + ImageMemory + image-reference-store/merge | 服务端只能恢复实际同步且当前账号拥有的原件；本地索引硬限制待出包 |
| 任务类别、比例 | ImageTaskPlanner + bf-image尺寸编译 | 比例/几何由真实请求决定；不能为了新风格忽略既有画布 |
| Pro/Flash | bf-image selectImageRoute，IMAGE_ROUTING_MODE/AUTO_POLICY | 在线可改；全Pro只修改routing_mode，不批量覆写runtime |
| standard/fast提示词优化 | shared/image-policy + bf-api.callImageUpstream | 与模型档位是两件事；Pro_only固定standard |
| 图片预览清晰度 | /me.uiConfig -> HostedAccount -> ImageCompressor | IMAGE_MAX_EDGE/QUALITY在线可调，影响前置预览；不是Seedream原件输入的统一压缩器；有总请求体积/缓存限制 |
| 手机准确文字 | ExactTextWorkflow/TextIntentDecider/TextOverlayRenderer | 旧包本地判断；新服务端不能强行令同一请求同时native和overlay |
| 服务器准确文字 | IMAGE_COMPOSITION_POLICY -> commercial-composer | 与手机排字互斥；不要为释放审美一刀切关闭准确文字 |
| Logo原件与抠图 | ImageToolArguments/PreservedAssetWorkflow/BrandAssetCutout | 手机处理会移除Logo后再贴，服务端不可再贴一次；真实最终落位不全由服务器控制 |
| Logo大小/位置 | BrandPlacementPlanner | 短边比例/边距/方位吸附是旧二进制逻辑；在线指导可改善估算，不能宣称改掉算法 |
| 生成图视觉检查 | HostedAccount.cachedImageVerify -> 图像检查请求 | 开关存在不等于严格验收；当前存在跳过/诊断分支，不能以“检查OK”证明Logo/事实正确 |
| 底图缓存 | BaseImageCache、ImageTaskFingerprint | 指纹包含非text结构字段和参考图hash；新image_plan会进入指纹，不能随意复用旧计划缓存 |
| 等待粒子/超时/重试 | /me行为配置 + ImageUseCase | 是体验/可靠性参数，不参与审美；幂等与未知结果重试边界保留 |
| V2任务计划 | shared/image-workflow，复用COMPOSITION_POLICY.workflowVersion=2 | 候选统一语义入口，默认未启用；账号灰度沿用现有accountIds，不增加隐藏手机开关 |

## 执行权收敛

长期方向是“一个计划，两种渲染适配器”：原生完整设计 / 准确图层排版；来源、画布、品牌事实只解析一次。安全/会员/费用属于执行门禁，不合并成审美偏好开关。旧包兼容适配器单独维护，不删掉其仍在消费的字段。

V2当前只接通计划校验与原生/旧排版分流。UI精确合成、复杂Logo分割与避让、品牌原件自动绑定、完整视觉事实验收尚未完成，不能把中央计划的存在当作这些能力已经实现。

## 第一轮实际测试记录

- 完整后端656/656通过，含10条V2测试；实际generate函数隔离执行证明UI原件输入未被删、原生路径不进入固定排字、不再叠加重设计/无字冲突。非真实网络E2E。
- 两个旧源码正则门禁因新增计划参数失败，已更新到新函数签名；没有删除原有素材顺序/人像身份约束。新generate测试初次缺少测试桩normalizeTier，补齐后通过。
- 一次Pro整幅商业广告真实生成成功，47.4秒。目视：文字总体可读，但构图仍偏普通页面，出现未给定的96%/128等界面数字，样例还把“不编造手机号”等内部说明错误放入可见文案。**未通过商业/事实验收**；后者属于测试简报也需修正，不能推给模型。
- 一次真实账号已核属UI输入请求被供应商返回400/InputTextSensitiveContentDetected。原图1920×1080 JPEG，输入hash已核；没有自动重试或尝试绕过审核。失败不证明模型UI保真失败，也不算通过。
- 原图为本账号唯一匹配“网格管理统计+报警统计”的已同步文件，校验owner/ready/private与字节SHA256；不拿随机历史图代替。临时签名URL不落盘。模型调用有独立账本来源image-workflow-v2-eval-20261111，不扣客户额度。
- 只检验了新编译约束及两次供应商调用；尚未验证前置真实长上下文选图、旧包最终Logo叠加和商业同文案A/B。
- 输出：outputs/image-workflow-v2-20261111/visual-evaluation.json及原图/生成图；不上传公开仓库。

## 后续必须做完的门禁

1. 明确已确认事实与可见文案，内部禁止项不进入copy，真实数据必须有来源；补独立视觉字段检查，不仅OCR。
2. 用受保护资产做实际图层合成/透视与遮挡，先证明不会与旧手机Logo工作流重复；不能靠prompt保真承诺上线。
3. 同一份已批准文案按参考图的视觉节奏做真正可执行设计，不以重生更多相似模板充数。
4. 品牌原件与长期偏好建立账号内可撤销关联，长上下文与跨项目回归；仅查到记忆文字不等于取回图片。
5. 完成真实旧HTTP/SSE、权限/幂等/账务、当前+历史素材组合，以及最新线上备份/ZIP依赖核验后再发布。

本轮没有修改线上开关或部署新候选；不出IPA。后续从这些失败证据接续，不重复付费跑已经记录的相同输入。
