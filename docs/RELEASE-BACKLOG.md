# 出包问题与修复台账（Release Backlog & Fix Log）

> 用途：把「必须发新版才能解决」的问题、以及已经解决过的 bug 的**根因与修法**留在这里，
> 避免同类问题反复踩、也避免下次交接时从头查。
>
> 维护规则：
> 1. 只有**改动落在 App 二进制内**（Swift / 资源 / Info.plist / 工具 schema）的才进「一、待出包」；
>    纯服务端、配置、管理台 HTML 的不进，写进「三、线上可修」。
> 2. 每条必须写清四件事：**现象 → 根因（到文件/函数级）→ 修法 → 验证方式**。
>    只写"已优化/已加固"的条目一律视为无效记录。
> 3. 修完发版后，把条目从「一」移到「二」，补上版本号与 commit。
> 4. 不确定是否属于客户端问题的，先在「四、可疑项」里挂着，别删。

---

## 一、待出包（Open）— 当前版本无法解决

### B-01 掉登录后静默回落「自带 Key」，用内置旧 Key 直连 DeepSeek，既不进账也不留记录
- **现象**：客户正常聊天，云端零记录、零计费；DeepSeek 官方账单每天 130~300 次请求。
  2026-11-06 审计确认：10-10~11-06 该 Key 累计 **¥24.11 / 1444 次请求**，全部无法归属。
- **根因**：
  - `ProviderProfiles.swift:114` `isHosted = isHostedActive && hasToken`，`hasToken` 是 UserDefaults 里的布尔；
    一旦为 false，`currentChat()` 返回 `chatCandidates.first`（`api.deepseek.com/v1`）。
  - `CredentialStore.seedBakedKeys()` 把包内 `bakedChatKey` 写进 Keychain，**只写不删**；升级不清除，
    `resetToBaked()` 还能一键恢复。所以跑过旧包的设备永久持有这把 Key。
  - 降级路径**无提示、无埋点、无上报**，用户和我们都察觉不到。
- **修法（待实现）**：
  1. 启动时比对 Keychain 中的 chat key 是否等于历史内置 Key，命中则删除；
  2. `isHosted` 为 false 且存在旧内置 Key 时，**不静默降级**，弹一次「请登录会员账号」；
  3. 降级时上报一次 `fallback_to_byok`（带 build、时间戳），管理台可见。
- **验证**：断网登出 → 重进 App，应出现登录引导而不是直接能聊天；管理台能看到 `fallback_to_byok` 事件。

### B-02 服务端看不到设备走哪条链路（缺 mode 心跳）
- **现象**：本次事故从云端怎么查都只能看到"没有请求"，看不到"为什么没有请求"。
- **根因**：链路选择是客户端私有状态，`/me` 心跳只报额度与会员状态，不报 `mode=hosted/byok`。
- **修法（待实现）**：`/me` 与同步请求带上 `clientMode` 字段，落 `bf_accounts.lastMode`；管理台账号详情展示。
- **验证**：在自备 Key 模式登录一次，管理台能看到该账号 `lastMode=byok`。

### B-03 服务端缺「禁止自带 Key」总开关
- **现象**：11-06 只能去控制台停 Key 止血，服务端没有任何手段命令客户端别用自带 Key。
- **根因**：没有可下发的策略字段。
- **修法（待实现）**：`/me` 下发 `allowBYOK`（默认 false）；为 false 时客户端隐藏自备 Key 入口并强制走托管。
- **验证**：管理台置 false → 客户端自备 Key 页显示"已停用"。
- 备注：这是**以后同类事故唯一能"在线关掉"的开关**，优先级最高。

### B-04 顶号提示文案复用「账号已在其他设备登录」
- **现象**：管理员主动踢下线时，用户看到"账号已在其他设备登录"，与事实不符。
- **根因**：`sv`（会话版本）只有一种 401 文案 `SESSION_REPLACED`。
- **修法（待实现）**：服务端新增 `FORCED_LOGOUT` 错误码，客户端文案改为"会话已过期，请重新登录"。

### B-05 流内错误帧把上游原始报文打上屏（代码已改，未发版）
- **现象（2026-11-03 真机）**：气泡下方出现
  `输出尚未完成（{ code = "UPSTREAM_ERROR"; message = "\U8fd9\U6b21..." }）`。
- **根因**：`ChatService.swift` 旧代码 `String(describing: failure)` 把整个 `{code,message}` 字典 dump 成字符串；
  `ChatViewModel.adopt()` 又直接用 `error.localizedDescription` 上屏，绕过了 `FriendlyError` 唯一出口。
- **修法（已改，未提交/未发版）**：
  - `APIErrorEnvelope.streamFailure()` 结构化解析流内帧（对象 / 旧码串 / 中文短句三种形态）；
  - `ChatError.incomplete` 文案固定为一句，真实原因走 `diagnostic` 只进日志；
  - 新增 `UserFacingError` 协议，`adopt()` 与流式 catch 统一走 `FriendlyError`；
  - `FriendlyError.copy(forCode:)` 收敛为唯一错误码表，`HostedError` 改为查表。
- **服务端同步已上线**：错误帧 `error` 改性为中文短句 + `errorCode`，老客户端 toString 也可读；
  上游 error 帧在服务端拦截，不再透传。
- **验证**：`Tests/BossAIiOSTests/ChatErrorDisplayTests.swift` 8 条 + `tests-backend/stream-error-frame.test.js` 4 条。

### B-06 本地存储失败把 SwiftData 英文报错上屏
- **现象**：保存会话/消息失败时，界面出现 `The operation couldn't be completed...` 类英文。
- **修法（已改，未发版）**：`ChatViewModel+Sending.swift` 四处改为固定中文文案，细节只进日志。

### B-07 专家工作流与本轮格式混在同一强制模板（2026-11-10）
- **根因**：`BossAI/Models/Expert.swift` 的 `ExpertSkill.promptBlock` 使用“必须遵循的工作流”，遇到“只要口播”仍可能输出全套选题/分镜。
- **服务端已上线（18:03）**：定向调整云端专家，取消固定三角度/三钩子/强制分镜；取消默认固定开场收尾。较大的交付与表达提示因事实验收失败，保持关闭，不能视为整项解决。
- **下次出包**：把内部方法、用户交付格式、可用工具拆清，覆盖离线默认模板与目录未刷新情形。本轮未修改 Swift。
- **验收**：同一专家切换纯口播/完整策划/局部修改/只补资料，格式不串；作图/导出仍实际执行。

### B-08 对话反馈缺少可关联的请求与策略版本（2026-11-10）
- **根因**：当前云端消息只有正文和时间，缺少本轮风格/模型路由/调用订单的可关联字段，排查常须靠时间推断。
- **下次出包**：增加非敏感的请求 ID 与策略版本回报，不能上传 API Key 或全部系统提示。本轮只记录。
- **验收**：一次反馈可关联具体请求、策略和错误，且不会跨账号查到记录。

---

## 二、已修复（Shipped）— 附根因与修法

### S-01 双附件合成只送一张图，人物对不上（2026-10-28，`04cd082`）
- **现象**：传「人物照 + 底图」要求合成，出来的人"有点像但不是"。
- **根因**：`ImageReferenceResolver.resolve()` 的 `attached` 分支只返回一张（`[attachedImage(at:)]`），
  人物照从未离开设备；同时工具 schema 里 `both` 的文案写的却是"双图融合"，与实现不符，误导 Agent。
- **修法**：新增 `source_indexes`（1~6，第一项=底图）+ `reference_roles`；resolver 支持多序号、去重保序、
  越界 fail-closed；计费前校验参数组合；bf-image 增加 `multiImageContract()` 在 prompt 前编号并禁止用相似人替代。
- **验证**：反先验人物（圆框眼镜+红针织衫）合成后身份保持；后端契约 7 条。

### S-02 Logo 处"生硬覆盖"，不跟随版面（2026-10-28，`04cd082`）
- **现象**：漫画风报纸加 logo，被拉伸铺满、紧贴边缘，像贴纸。
- **根因**：`PreservedAssetWorkflow.compose()` 把模型估的归一化 `box` 当**最终位置+尺寸**，缩放到填满。
- **修法**：新增 `BrandPlacementPlanner`（宽度=短边 16%、边距=5.5%、锁真实宽高比、四角吸附、"大一点/小一点"）；
  `Placement` 拆 `box`（最终落位）与 `cleanBox`（要清理的旧区域）；合成加极轻接触阴影。
- **边界**：这是"落位与融合"，不是"重排版"；让标题挪位必须走参考图重设计。

### S-03 海报"重新设计"≈原图 + 底图出现乱码小字（2026-10-26，`d2be2d9`）
- **根因**：① `REFERENCE_CONSTRAINTS` 只写"允许重新安排"，模型最省力的解就是照抄版式；
  ② 服务端 `missingCopy` 把 `structured.text` 追加回**底图** prompt，而客户端要求底图无字 → 模型画一遍、排版层再叠一遍。
- **修法**：约束改为硬要求（必须重做版式/新风格优先/禁复刻/否定项不得出现）；
  新增 `text_mode=overlay`，服务端见到即不追加文案并强制无字；`.reference` 档位 auto→high。

### S-04 单图编辑被误判成组图，多扣费 + 丢画布约束（2026-10-26，`b62a91e`）
- **根因**：`classify()` 用 `parseCount>=2 && contains("张")` 判组图，
  "把**这张**照片里加一个人（**两个**人握手）"同时命中"张"和数量 2 → 判成 `.series`。
- **修法**：新增 `imageCountHint()`，只认「数词+张/幅/组」并排除 这张/那张/几张；
  非组图任务张数只由 Agent 显式指定，默认 1。

### S-05 交付物图片里印着"数据来源 / 未核实项"（2026-10-28，`a32288c`）
- **根因**：`META_RULE` 的数据真实性规则没有作用域，被模型一并执行到了图片上，
  出处与"未核实"写进了 image prompt 与 `structured.text`。
- **修法**：`META_RULE` 新增【交付物边界】；`bf-image` 新增 `stripMetaCopy()` 按行剔除并记
  `meta_copy_stripped` 日志（只按行首匹配，不误删正文里的"来源"二字）。

### S-06 会话删除接口返回 400 却被映射成"可重试"（2026-10-25，`85baaf0`）
- **根因**：`BAD_ID` 未进错误目录 → 400 被映射为 `INTERNAL / retryable=true`，客户端会无限重试必失败请求。
- **修法**：补 `BAD_ID`（input / 不重试），bf-api 与 bf-image 两份目录同步补齐。

### S-07 底图缓存只支持"单任务"，并发会互相覆盖（2026-10-25，`85baaf0`）
- **根因**：缓存以单条 entry 存，切会话时旧任务协作式取消仍可能写入。
- **修法**：改为 `storage["convId|taskId"]` + NSLock，容量 4 条按时间淘汰；命中缓存不再累加生图额度。

### S-08 服务端提示词优化把编辑约束改写掉（2026-10-27）
- **根因**：`pro_only` 分支无条件 `optimize_prompt_options.mode=standard`，绕过了"编辑场景别开"的既有结论。
- **修法**：`wantsPromptOpt = 不带参考图 && 未自带配置`；带参考图一律 `delete optimize_prompt_options`。

### S-09 CI 上 `pixelSize` / `thumbnailSimilarity` 恒返回 nil（2026-10-26）
- **根因**：① `CGImageSourceCopyPropertiesAtIndex` 桥接写成 `as? [CFString: Any]` 运行时必然失败；
  ② `CGContext(data: &swiftArray...)` 在测试宿主读回全零。
- **修法**：改 `[String: Any]` + `kCGImageProperty* as String`；像素回读改 RGBA + 自持缓冲；
  只进日志的相似度断言改为契约式（nil 或高相关都接受，不允许返回错误低值）。

### S-10 成本看板全是 0；流水把售价当成本（2026-10-29）
- **根因**：① 流水 `ts` 写 `new Date()`，查询用数字毫秒比较，范围查询按类型分桶 → 一条都查不到，
  唯一命中的是 `ts: nowMs()` 的语义缓存行（¥0 / model=semantic-cache）；
  ② `addImageCost(accountId, costCny)` 一个参数既扣额度又记成本，毛利永远为 0。
- **修法**：缓存行改写 Date + 查询 `or([gte(Date), gte(number)])` 兼容历史；
  账实分离（账户扣售价、流水记 cost/price/margin）；定价改 `成本 × 2`，修正 Flash 2K 误收 0.80（成本 0.12）等问题。

---

## 三、线上可修（不发版）— 出事优先用这些止血

| 能力 | 位置 | 生效 |
|---|---|---|
| 模型 / 尺寸 / 重试 / 超时 / 限流 | `bf_config.runtime`（30s TTL） | 秒级 |
| 系统提示词全文 | `CHAT_RULES` / `META_RULE` | 30s |
| 工具开关与配额 | `capabilityOverrides`、云端专家 tools | 立即 |
| 新增 `APP_*` 参数 | `appBehavior` 自动下发 | 30s |
| 强制更新 / 版本门禁 | `MIN_APP_VERSION` | 立即 |
| 会话踢下线 | `bf_accounts.sv` 自增 → 旧 token 401 | 下次请求 |
| 云函数回滚 | 保留版本号，SCF 控制台回退 | 分钟级 |

**明确做不到的**：改工具 schema、改几何/排版逻辑、改等待动画、改链路选择策略——这些都在二进制里。

---

## 四、可疑项（未定性，先挂着）

- **组图 `IMAGE_MODEL_SERIES` 为空**：任何组图请求会被 422 `series-unsupported` 拒绝，能力等于关闭。
- **Pro 档实际仍走 Flash**：配置里 Pro 也指向 flash 模型，需核价 + 流式工具调用 + 视觉兼容后再切。
- **搜索仍走 DeepSeek 官方**（另一把 Key，¥0.005/次）：百炼 `bailian_web_search` 已实测可用，
  但 WebParser 抓取未开通，抓取不通前不能删搜索 Key。
- **`hasToken`（UserDefaults）与 Keychain token 可能不同步**：删装/清数据都可能造成
  "同步正常、聊天走 BYOK"的混合状态，本次事故即是（见 B-01）。
