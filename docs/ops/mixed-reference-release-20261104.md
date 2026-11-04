# 旧包单图混合原图：接线与发布验收

本次承接reference-append-preparation-20261104，不修改App、员工端或DSH审批/错误体验改动。研究依据沿用CloudBase对象ID/临时链接分离与OWASP逐对象归属校验，没有引入第三方依赖、密钥、数据库集合或新公开入口。

## 实际实现

1. API只允许已配对recall返回并确认属于当前账号、原图ready的历史ID。单图任务有真实当前来源时，通过旧包已透传的structured.image_references编译append，并移除会覆盖当前图的顶层library_refs。原source/source_indexes不换槽位，历史-only和精确Logo本地合成保留旧流程。
2. image-reference-merge把实际收到的本账号COS图片链接定位为私有asset；原始URL不下载、不当授权，也不持久化。复核账号、ID、ready、摘要、MIME、cloudPath/fileID后，用现有reference-store验证全部当前与历史原图，当前在前、有序追加，最多4张。
3. `claimImageJob`在同一原子事务绑定新任务指纹，再判断processing/failed/done。指纹包含真实资产选择/角色、文案与画布/风格元数据等不可变请求，排除临时签名；重放换素材、prompt或移除绑定均409，不能借缓存返回其他任务。旧的未绑定任务仍按原语义运行。
4. 拿到执行权后再次校验并重签全部原图，按最终实际输入张数做最坏额度检查和实际费用台账。生成完成或明确失败都保留引用绑定；未知上游结果仍不授予重复调用权。缺图/跨账号/额度不足不启动模型，临时存储故障返回自然的503提示与安全诊断码。
5. 历史原图采用“历史原图1/2/3”的稳定槽位称呼，具体编辑语义写prompt。模型把机柜误标成“人物素材”的首轮证据被保留；最终API将唯一的素材别名同步绑定到中性槽位，不把模型分类猜测当作已验证的画面内容。

## 验证证据

- 563项本地后端回归通过。新增真实HTTP handler行为覆盖单图双源/三源顺序、实际inputImages计费、签名轮换免费重放、换角色/任务409、并发一次执行、失败后仅同选择可重试、删除/跨账号/缺图/额度不足/关闭策略、旧文生图与既有历史组图保持原行为。
- 使用真实SSE规划与两个临时账号：当前原图为此前生成的蓝白展馆场景，历史原图为此前生成的深青储能柜；都是合成资料。历史原图私有归档后写真实同步文件记录。服务器实际把两份原图送入Pro，账单调用inputImages=2，约72.8秒，供应商估算0.62元、客户扣费1.24元，orderId见outputs/reference-append-release-20261104/live-verification.json；不是平台最终已结算账单。
- 成图目视同时出现当前展馆与原储能柜，柜体颜色、通风栅格、浅色侧板及厚重比例被使用，图像无新文字。证明该例两份原图实际参与，不代表人物身份或Logo像素精确度全面验收。
- 重签后重放cached true/cost0；换角色或prompt409；跨账号/缺底图422。累计仅1次成功的真实生图。会员到期me200/chat403/image403；额度耗尽chat429/image429；临时账号/测试云资产已清理，真实费用审计保留。
- 第一次验证脚本误将probeImageSize的w/h当成width/height，触发尺寸422，未调用图片供应商；live-verification-first.json保留失败，不混入通过。修正后才运行上述真实单例。
- 最终只改API槽位命名后再做SSE规划校验，不再重复付费生图；其记录在live-plan-verification.json。不是客户真机UIKit验收。

## 发布契约与回滚

`IMAGE_MIXED_REFERENCES_POLICY`默认关闭；支持`{"enabled":true,"accountIds":["..."]}`隔离验证，全员启用分两步：先`{"enabled":true,"audience":"all","planningEnabled":false}`让执行端就绪，等待32秒缓存屏障，再改为`{"enabled":true,"audience":"all"}`允许前置规划，避免函数缓存不同步导致瞬时422。服务端管理员settings-schema同步展示该字段，不修改员工页面。测试仅切此键，不替换runtime、不修改设计/计费/会员配置。

本轮outputs/reference-append-release-20261104/rollback保存上线前的21:17设计版，候选从实际线上ZIP构造。API允许index/settings-schema/新规划模块/shared合并模块；image允许index/shared合并/shared原子claim。依赖执行文件、版本与锁文件零变化。使用SCF官方UpdateFunctionCode InstallDependency FALSE，先image后API，下载逐文件核验。图片函数22:16:35、API最终22:34:22 Active。全员开关和最后验证时间以同目录rollout.json为准。

优先回滚方式：先在当前策略中设planningEnabled=false，停止新混合规划并保留执行端，使已缓存任务仍可完成；必要时再改为`{}`关闭执行，客户端会得到明确暂不支持提示，不会静默丢图重新生成。保留新函数以维持已绑定任务的原子指纹检查。不要关闭准确文字enabled或设计引擎，不裸用11月3日/晨间包覆盖引用与字体修复。源码回滚前先备份最新变更，使用本轮rollback并确认所有新增引用仍会被拒绝，不删除客户任务。

## 明确保留的边界

- 这是**当前底图+历史原图的单图编辑/参考重设计**，不是所有source=both问题都消失。当前输入必须确实已上传且可按账号恢复；没有同步的历史原图、任意外链和inline像素不会被猜测替代。
- 精确Logo的preserve_assets依赖手机本地索引，继续走已验证的本地抠图/原像素合成流程，不将它改为模型重绘。
- 旧image_series没有本轮图片发送槽位；现有历史replace组图保持正常，当前附件与历史混合组图尚未获得完整的源ID映射，不能声称已支持。
- 稳定槽位命名防止错误类别标签，不等于前置模型已经看过每张历史图片。语义、人物身份、商业美感仍须分别验收，不能凭测试数承诺全App无问题。
