# 图片交付边界与 Flash 优先路由：服务端兼容修复

日期：2026-10-28。基线：本地 `a32288c`，含 DSH 多附件与品牌落位改动。

## 交付范围

仅修改云函数、管理端配置元数据、服务端测试与验证脚本。未修改 Swift、未触发 IPA 编译。
现有客户端仍发送原来的工具参数和图片请求；新增的可选策略信息放在已有 structured 容器中。

## 审查结论及修正

| 原问题 | 修正边界 |
|---|---|
| 客户端携带旧真实性铁律导致服务端跳过新交付边界 | 独立注入 `IMAGE_DELIVERY_V2`，不依赖 META_RULE 是否重复 |
| 仅过滤生图 prompt，手机随后仍能从 structured.text 叠回核对说明 | bf-api 在工具调用返回手机前处理完整参数；非流式与分片 SSE 共用同一逻辑 |
| 正则误删截止日期、免责声明、产品名称 | 只识别明确的核对说明标签；保留正常日期和免责声明；支持用户明确要求来源说明 |
| prompt 清理后 structured 兜底又补回说明，多行字段漏检 | prompt、typed text、多行内容、布局 key 一次处理，Provider 复用相同结果 |
| 用户附件顺序与底图优先发送顺序混淆 | 工具回程将原始附件指代转换成角色；Provider 明确槽位不是用户编号 |
| 多图重新设计同时收到保留构图和重做构图要求 | 多图语义按 reference/edit 分开，允许用户要求的外观修改 |
| auto 实际仍大量走 Pro | 服务端统一决定，默认 Flash，忽略旧客户端保守 high 推荐 |

DSH 的多图传输修复保留：`attached + source_indexes` 可以发送多个附件；`both` 仍是生成底图加上传素材。
客户端 BrandPlacementPlanner 与原素材合成保持原样，未宣称通过服务端修改了手机上的排版代码。

## 模块与边界

1. `cloudfunctions/shared/image-delivery.js`：交付规则、文案处理、工具回程及 SSE 参数组装。
2. `cloudfunctions/bf-image/image-routing.js`：纯路由策略及允许升级的失败判定。
3. `bf-api/index.js`：使用上述工具回程边界，保持聊天、文档等普通内容原样。
4. `bf-image/index.js`：调用统一文案处理与路由；原有授权、额度、幂等、保存和记账边界不另起一套。
5. `scripts/bundle-function-shared.js`：部署前从 shared 源打包到函数，避免手工维护副本。

SSE 只延后工具参数分片，普通聊天文字和活动信号继续即时传递。只有 JSON 完整后才发出可执行工具调用。
损坏或截断参数不拼凑执行；记录非敏感错误并提示重试。

## 线上调整

管理端「生图路由模式」保持 `auto`。「自动作图 · 升级策略 JSON」对应 `bf_config/runtime.data.IMAGE_AUTO_POLICY`。
两个函数沿用 30 秒配置缓存。无需修改客户端或重新部署即可改变以下策略：

```json
{
  "defaultTier": "fast",
  "honorClientHigh": false,
  "proTaskKinds": [],
  "proReasons": ["complex_edit", "identity_sensitive"],
  "minReferencesForPro": 3,
  "nativeTextCharsForPro": 180,
  "retryQualityToPro": true,
  "capabilityFallback": true,
  "fallbackCodes": ["ModelNotSupport", "ModelCapabilityNotSupported", "UnsupportedOperation"]
}
```

- 普通文生图、重设计、简单编辑、组图单张、一般双图合成：默认 Flash。海报、品牌、Logo、最终稿名称本身不强制 Pro。
- 复杂身份或动作编辑、多参考融合、原生密集文字：按配置升级；本地程序叠字不因文案密集额外升级。
- 用户明确指定 Pro，或对上次结果明确反馈质量不佳：可升 Pro。`retryQualityToPro=false` 可关闭质量反馈升级。
- `honorClientHigh=true` 可恢复旧客户端 high 强制升级；`proTaskKinds`、`proReasons` 可以逐项调整。
- Pro/Flash 运维强制模式保留。未知 JSON 失败回到安全默认，不执行任意代码。

自动失败升级只适用于明确返回、尚无产物的能力拒绝（限定 400/422 与允许的错误码），最多升级一次。
超时、5xx、429、取消、缺少产物但结果不明：不会另起一次 Pro；继续使用幂等/生成中状态，避免重复消费。
没有新增一个宣称能自动判断所有审美问题的视觉模型；质量升级依赖明确反馈、已有重试描述或场景判断。

## 验证与已知边界

- 后端 357 项测试通过，覆盖实际 Provider payload，而不只检查源码是否包含某句话。
- 真实聊天工具回程：非流式 54.543 秒、SSE 65.428 秒，携带旧客户端真实性规则仍收到新版本的文案边界。
- 真实普通生成：Flash 13.824 秒；显式 Pro 42.397 秒。两张 1536×1536 产物已下载并查看。
- 最终复测 Flash 11.354 秒；同 requestId 重放 0.564 秒、cached=true、cost=0、返回同一 URL；Flash 参考改色 14.413 秒。生成与编辑均为 1536×1536，已查看两张产物核对主体、画布及改色。实测记录见 `outputs/image-server-v2-verification.json`。
- 部署前保留了 bf-api 版本 6、bf-image 版本 7；仅为回退快照，没有把它们当成本轮新版本。
- 实测中发现本轮接线误读 `cleanedPrompt.text`，已修为 `.prompt`；新增无 structured 字段的纯自然语言回归。
- 云函数代码更新接口返回不代表实例更新完成；必须等状态 Active 再跑验证，避免命中旧实例。

服务端无法恢复旧 App 从未上传的图片，无法改变已安装二进制里的抠图或 Logo 像素合成算法。
已烙在源图中的核对文字、手机 OCR 强制恢复原图全部文字的情况，不能承诺仅靠字符串过滤彻底去除。
一次合成成功不等于所有人物编辑都能像素级保真；本轮也不以插画测试替代真人身份与客户真机交互验收。

## 维护与排查

执行 `node scripts/bundle-function-shared.js`，随后运行 `node --test tests-backend/*.test.js`。
有现有管理登录态时，可用 `node scripts/verify-image-server-v2.cjs` 做完整真实调用；`--images-only --flash-only --edit` 只复核 Flash 与编辑，减少重复测试。
脚本只创建带 `image-audit-v2-` 前缀的临时账号，凭据只在进程内存中使用，finally 删除该账号。
日志以 requestId、image_route、image_route_upgrade、image_upstream_rejected 定位，不输出密钥、用户 prompt 或图片内容。
