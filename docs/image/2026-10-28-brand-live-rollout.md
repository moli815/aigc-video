# 现有用户 Logo 规划：直接线上启用

## 当前实际状态

按用户要求，在现有唯一环境直接启用，而非继续保持测试账号白名单。

- `bf_config/runtime.data.IMAGE_LEGACY_BRAND_POLICY`：`{"enabled":true,"audience":"all"}`。
- 写入并回读确认时间：2026-10-28T13:02:28Z（北京时间21:02:28）。只修改该键、配置更新时间/版本及编辑记录，没有覆盖其他配置。
- bf-api：更新请求 `62015b81-5dc6-4a48-88ad-f57e443e2871`，已确认 Active，更新时间20:59:12；更新前备份版本8。
- 没有更新App、没有构建IPA、没有部署bf-image。保持现有自动Flash优先路由和鉴权/会员/额度/存储协议。

全员开启仍先看当前手机实际声明的工具契约，不给不支持该协议的手机注入执行指令。新规则针对当前明确的Logo/标识编辑任务，不影响普通聊天和无关作图。

## 这次真正上线的能力

1. 服务端指导前置模型区分海报、Logo、人物素材，使用旧包已有的来源和原素材合成字段；保留原版式时不重复叠文字。
2. 位置规划考虑旧包实际16%短边、5.5%边距和吸附规则，要求避让标题、正文、二维码、人脸等。这里是前置视觉规划，不冒称新增了独立OCR碰撞检测器。
3. 已有手机去底使用background=auto；精确Logo继续贴原素材，不让Seedream临摹。
4. 相同编辑调用只输出一次；不同方案冲突则在图像生成前返回旧包认识的UPSTREAM_ERROR与自然语言解释。不能把这个边界说成“绝不会重复扣费”：跨请求仍依赖既有requestId幂等，模型改变参数的新请求不属于同一次重放。
5. 明确要求分别给多张海报添加标识的请求保留多任务，不能把“两张输入图”误判成“两张交付图”。

## 防重复边界

- 相关请求设置parallel_tool_calls=false。参数有[官方文档](https://www.alibabacloud.com/help/en/model-studio/qwen-function-calling)支持，但仍不能只依赖供应商遵守。
- JSON非流式和SSE分片参数共用guardBrandCalls；只合并工具名称及完整执行参数一致的调用（对象键顺序可不同）。不同来源、坐标或prompt不能静默合并或随意选一个。
- SSE完整参数在发给手机前处理，发生冲突时不先泄漏第一条可执行图像调用。
- 日志image_brand_planning包含planning_enabled、brand_duplicate_calls_removed、brand_plan_conflict及请求编号，不写图片或完整prompt。

## 已完成验证

- 全部后端390条通过，0失败；包含全员开关、错误配置、旧工具兼容、重复调用、冲突调用、JSON/SSE、显式多作品保留。
- 真实线上临时会员登录、/me、普通聊天通过；Flash优先路由未变。
- 未在探测请求中手动塞入新指引，直接发旧包风格工具与合成Logo/海报预览：服务端真实注入后，JSON与SSE都返回一个image_edit，source=both、source_index=1、preserve_assets.reference_index=2、preserve_outside=true、text=[]。
- 最新探测JSON约1.995秒、SSE约3.067秒；临时账号已删除，未调用付费图像模型。本次验证是前置工具参数验收，不是寄出设备上的完整合成视觉验收。
- 已从云端日志查到planning_enabled与请求编号，例如73c7bb6b-98a7-4241-92f5-29ad9493ad5e。
- 启用初次严格探测仍出现过一次2≠1断言，复测通过，未能确定首次具体字段；已增加素材序号、素材框、数量的逐字段摘要。不能据此宣称所有场景已经无错误。

回执：outputs/legacy-brand-rollout.json、outputs/legacy-image-compat-verification.json。

## 未新增的能力不能混算

本次没有上线独立复杂背景分割模型、从海报精确裁取目标Logo的Worker、网上官方Logo下载合成工具或服务网页；也没有改变旧包硬编码的合成算法。这些能力不能靠启用规划规则就宣称完成。两上传图精确Logo路径的本地校验冲突仍需使用真实历史原件引用或后续兼容入口，不能伪装both借用错误底图。

## 用户反馈与快速处理

用户提供问题编号、发生时间和截图即可按bf-api/bf-image日志关联，先看是否planning_enabled、素材角色/序号、模型路由、幂等与错误阶段。不要让用户重新装包排查服务端问题。

必要时仅关闭新规划：管理端将该键设为 `{"enabled":false}`；或使用已有管理登录执行 `node scripts/set-legacy-brand-rollout.cjs --disable`。约30秒停止后续请求注入，不撤回已经执行的上游请求。用户正常聊天、已有作图接口继续保留。

若发生函数代码级故障，再核对别名后回退本次bf-api备份版本8；不要回滚会员守卫、bf-image、客户素材或其他管理员配置。
