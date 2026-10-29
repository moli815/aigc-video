# 质量优先的 Flash / Pro 混合路由

## 核验结果

2026-10-29 查到线上 `IMAGE_AUTO_POLICY` 已存在，内容是此前的 Flash-first 策略，并不是没有配置。13:05 的真实日志中已有 `auto:dense-native-text` 的 Pro 请求；12:51 也有 `auto:explicit-pro`。不能把“客户端 high 被忽略”推导成“Pro 完全没用”。

问题在于区分意图不足：旧客户端编辑/参考图和无法判断时都会传 high，直接打开 honorClientHigh 会把大量普通任务升成 Pro；但此前没有独立尊重用户说“高质量、专业级、精美”的信号，复杂文字布局的 reason 又被参考图条件限制。

## 修改边界

只改云函数与运行时策略；没有修改 Swift、工具名、接口路径、会员、额度、价格、超时或媒体返回结构，不触发 IPA 编译。保留 DSH 的成本/售价分离与成本看板修复。

- `shared/image-quality-intent.js`：纯函数，从用户本轮原话识别质量要求；不把 Agent 自动加的形容词当用户要求。处理常见否定句和指定模型的否定。
- `shared/image-delivery.js`：普通 JSON 和完整 SSE 工具参数共同增加 `structured.routing.user_quality=high/auto`；旧包已经透传 structured，无需新增客户端行为。
- `bf-image/image-routing.js`：按开关识别用户质量；没有新标记的旧请求可用配置的字面关键词兜底；复杂排版 reason 不再要求必须有参考图。原 high 仍可由 honorClientHigh 决定是否采纳。
- 仅写入 `bf_config/runtime.data.IMAGE_AUTO_POLICY`，事务比对原值，保存回执；不覆盖其他配置。配置刷新约 30 秒。

## 线上策略

完整版本见 `config/image-auto-quality-balanced.json`。

| 条件 | 模型 |
|---|---|
| 明确指定 Pro | Pro |
| 用户要求高质量、专业级、精美、印刷级 | Pro |
| Agent 判定复杂编辑、身份保持、复杂排版 | Pro |
| 至少 3 张参考图 | Pro |
| 图像模型直接绘制的可见文案至少 100 字 | Pro |
| Flash 质量失败的下一次请求 | Pro |
| 普通配图、简单海报、草稿、改色、简单双图融合 | Flash |
| 用户明确指定 Flash | Flash（保留用户指定模型的优先权） |

程序叠字不计入上游文字复杂度；“名片/海报/Logo/最终稿”这些品类名称本身不强制升级。明确能力不支持时才允许一次 Pro 兜底；超时/429/5xx 等结果不确定时不盲目重画。

三七分是观察方向，不是随机采样、配额或降档门槛。10 个固定代表案例得到 7 Flash / 3 Pro，只证明场景分流；另测 10 个全部高质量要求全部走 Pro。不能拿该样本声称真实线上流量已达到 30%。

## 部署与回退

部署前备份：bf-image 版本 8、bf-api 版本 9。两函数均 HTTP / Nodejs18.15 / 300s，既有网关和权限不变。

- bf-image 更新请求：`a9a295c6-7d41-4932-9526-76d10960f280`，13:14:50 Active。
- bf-api 更新请求：`acd0b950-0346-4b0b-ac9f-4753dc616605`，13:14:53 Active。
- 新配置 13:15:19 写入并读回确认，revision `1793250919263`。
- 回执：`outputs/image-auto-quality-policy-rollout.json`（只含非敏感路由配置）。
- 如需恢复原策略：`node scripts/set-image-auto-quality-policy.cjs --rollback`。脚本先比对当前值，不覆盖其他操作者后续更改；保留回执后再操作。恢复配置不需要重新部署或出包。

## 验证

407 项后端测试通过。包括纯意图判断、普通 JSON / 分片 SSE 一致、保持多图顺序、否定句、配置异常、真实 Provider 请求编译、无参考图复杂排版、简单编辑、能力拒绝和不确定失败不重画。

线上验证脚本：`scripts/verify-image-balanced-routing.cjs`。只创建并删除随机临时会员，使用自造消防车素材，不上传客户照片、不修改客户账号。验证登录、会员信息、JSON/SSE 用户质量信号、普通 Flash 出图、高质量 Pro 出图、简单 Flash 编辑、复杂 Pro 编辑、同 requestId 零重复计费。

详细实测模型、耗时、收费与问题编号见 `outputs/image-balanced-routing-verification.json`。图像留在 `outputs/balanced-route-0.image` 至 `-3.image`。上述收费是会员额度扣除口径，不是供应商结算成本。

线上四次真实调用全部 HTTP 200：普通插画 Flash 10.928s；高质量海报底图 Pro 65.693s；简单改色 Flash 15.328s；复杂参考图编辑 Pro 79.187s。同 requestId 回放 0.538s、cached=true、cost=0；临时账号已删除。已查看四张产物：简单改色保持消防车和画布的总体结构，复杂编辑改变了材质细节；这不等于针对客户全部素材的审美验收。

## 实际边界

这次保证路由规则可执行、可配置且旧包传输兼容，不保证任何一张生成作品的审美或人脸一致性。复杂度仍部分依赖前置模型给出的 reason；自然语言规则覆盖常见表达，不等于完整语义理解。Pro 本来会比 Flash 慢，不能把正常 Pro 耗时当路由回归。未直接操作寄出的 iPad，服务端兼容验证不能替代该设备完整视觉验收。

查问题时以 `image_route` 的实际 model/reason 和 requestId 为准，而不是只看客户端 high 或模型配置名称。真实流量比例应按完成任务去重统计，不能把一次任务的两条路由日志当两张图。
