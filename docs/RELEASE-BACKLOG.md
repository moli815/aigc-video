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

### B-09 托管 token 混入 BYOK Provider 自检（架构 IOS-01，P0）
- **现象/根因**：`CredentialStore.reload()` 把会员 token 写入 chat/imageKey，`SetupView` 预填并触发 `ProviderDetector` 对第三方域名发 Bearer 探测；与 B-01/B-03 同源但外发路径是新发现。
- **涉及/修改**：`Config/CredentialStore.swift`、`Views/SetupView.swift`、`Services/ProviderProfiles.swift`；分离凭证类型，托管态不预填/不自检/不保存 token，BYOK 只接受明确自备 Key。
- **依赖/风险**：依赖 B-01 旧 Key 清除、B-03 `allowBYOK`；影响登录、登出、换号、掉登录和隐藏设置，错误隔离会阻断当前静默直连。
- **验收**：托管打开设置后第三方域名零请求；Keychain 无会员 token；旧包错误修复不回退。来源：架构文档 IOS-01 / A-01。

### B-10 用户身份全局存储跨账号串资料（架构 IOS-02，P0）
- **现象/根因**：`Models.swift` 固定 `bossai.user_identity`，`ChatViewModel`/`IdentitySheet`/定时任务都读全局值；登出未隔离。
- **涉及/修改**：`Models.swift`、`ChatViewModel.swift`、`IdentitySheet.swift`、`HostedAccount.swift`；按账号 scope 版本化，旧值需当前账号确认才迁移。
- **依赖/风险**：依赖统一 owner 生命周期和同步备份；影响记忆、定时任务与客户称呼。
- **验收**：A→B→A 不串姓名、公司、行业、角色；备份恢复不越账号。来源：IOS-02 / A-02。

### B-11 失效上下文返回空数组后本轮仍继续执行（架构 IOS-03，P0）
- **现象/根因**：`buildAPIMessages` 失败返回 `[]`，`runLoop` 仍用旧 userText 预检索/请求；Service 每次访问可能重新读取模式。
- **涉及/修改**：`ChatViewModel.swift`、`ChatViewModel+Streaming.swift`、发送/重试扩展；引入不可变 `ChatTurnContext`，构建失败 throws，每个 await 后校验 owner/session。
- **依赖/风险**：依赖 B-01/B-03/B-09/B-10；改变取消与错误状态机，影响所有工具与流式响应。
- **验收**：各 await 点切账号/删会话后后续网络调用为零，旧文本不进新账号。来源：IOS-03 / A-03。

### B-12 组图任意 start 错误都回退 legacy 并换幂等键（架构 IOS-04/A-04，P0）
- **现象/根因**：`ChatViewModel+Series.swift` 对任何异常进入 legacy，重新生成 requestId；取消类错误也被 legacy 重试；服务端 `IMAGE_MODEL_SERIES` 语义未闭环。
- **涉及/修改**：`ChatViewModel+Series.swift`、`ImageUseCase.swift`、统一错误目录；仅明确 404/`SERIES_V2_UNAVAILABLE` 回退，复用同一业务 ID，取消/额度/未知结果不回退。
- **依赖/风险**：依赖服务端能力码与错误目录；影响所有组图、重试和计费。
- **验收**：404/401/403/409/422/429/500/丢响应/取消矩阵下无重复付费、无换 ID、取消后零重试。来源：IOS-04 / A-04。

### B-13 组图落库失败仍宣称已保存到本地（架构 IOS-10，P1）
- **现象/根因**：`ChatViewModel+Series.swift` 多处 `try? persistSeriesImages`，只按上游成功数设置 outcome；与 `ArtifactRepository` 的 throws 契约冲突。
- **涉及/修改**：Series outcome 拆为生成成功、保存数、保存错误；失败只重试保存/下载，不重新生成。
- **依赖/风险**：依赖统一 ToolResult/ArtifactRepository；影响产物恢复入口与提示文案。
- **验收**：注入 SwiftData save 失败，不出现“已保存”、不重复出图、仍可恢复。来源：IOS-08 / A-10。

### B-14 V1/V2 同步与删除队列冲突规则不一致（架构 IOS-11，P1）
- **现象/根因**：V1 跳过本地已有记忆，V2 覆盖；bootstrap 用随机副本 ID；V2 pending deletion 与 legacy outbox 双写，400/403 只清一处。
- **涉及/修改**：`SyncService.swift`、`SyncV2Engine.swift`、`ConversationDeletionService.swift`；V2 唯一运行时所有者，V1 只读迁移，确定性冲突 ID，单一 outbox/terminalFailed。
- **依赖/风险**：依赖 B-10/B-11；涉及多设备、离线删除和数据迁移，需存量回放。
- **验收**：本地未同步编辑不丢、中断重放不重复、删除不复活、400/403 不伪报成功。来源：IOS-09 / A-11。

### B-15 超时名义值与实际资源上限不一致；双 Key 写入非原子（架构 IOS-12，P1）
- **现象/根因**：`BoundedHTTPClient` 图片 300s/聊天 180s，但管理端允许 900/600s；`CredentialStore.save` 顺序写两个 Key，失败后可能半新半旧。
- **涉及/修改**：统一 HTTPPolicy 派生 request/session/gateway/upstream 超时；保存前读旧值、失败回滚或标记不可用；服务端按 build 限制旧包上限。
- **依赖/风险**：影响长图、长文、网关超时和 BYOK 配置；服务端先行不改二进制行为。
- **验收**：315/600/900 配置名义与实际一致；第二把 Key 失败不留可用半状态。来源：IOS-10 / A-12。

### B-16 工具、专家目录、错误与遥测仍是多套决策者（架构 IOS-05～09/12，P1）
- **现象/根因**：`runLoop` 同时管轮次/工具/落库；ToolManifest、ExpertCapability、EffectiveToolPolicy、预检索、执行器各自决策；远程新专家无法执行；缓存无版本/账号；本地错误原文仍多处上屏；请求缺 turn/mode/build/catalog/policy 关联。
- **涉及/修改**：`ChatTurnRunner/Finalizer`、`ToolDispatcher`、通用最小权限 capability、`ExpertCatalogStore`、按任务启用文档模板、`FriendlyError/UserFacingError`、非敏感 turn 元数据；保留已寄出 App 的旧接口兼容。
- **依赖/风险**：依赖 B-09～B-11、服务端目录 schema 和 `allowBYOK`；属于一次较大的架构迁移，须分小步灰度并回放旧客户端契约。
- **验收**：工具权限矩阵一致；关闭搜索零调用；纯口播无旧模板；未知专家 fail-closed；旧 errorEnvelope 不跨轮次；一条反馈可关联完整轮次且无 prompt/key。来源：IOS-05～08、IOS-12、A-05～08、A-13～15。

> B-09～B-16 均**只登记、不实施、不出包**。下次获准构建时按 B-01～B-03 → B-09～B-11 → B-12～B-16 的依赖顺序合并执行，并保留当前工作区的 Swift 错误修复候选。详见 `docs/ops/architecture-optimization-20261110.md` 第 7 节。

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
| 主生图总开关 | `bf-image` 读取 `CAP_IMAGE_ENABLED`；四个付费入口共用门禁 | 30s |
| 商业成稿事实审查 | `CHAT_GROUNDED_REVIEW`；默认关闭，需真实验收后才灰度 | 30s |
| 专家目录发布 | `bf_config/experts` 的 `catalogRevision/origin` + 事务快照；旧客户端不支持新增/删除 ID | 下次登录拉取 |

**明确做不到的**：改工具 schema、改几何/排版逻辑、改等待动画、改链路选择策略——这些都在二进制里。

---

## 四、可疑项（未定性，先挂着）

- **组图 `IMAGE_MODEL_SERIES` 为空**：任何组图请求会被 422 `series-unsupported` 拒绝，能力等于关闭。
- **Pro 档实际仍走 Flash**：配置里 Pro 也指向 flash 模型，需核价 + 流式工具调用 + 视觉兼容后再切。
- **搜索仍走 DeepSeek 官方**（另一把 Key，¥0.005/次）：百炼 `bailian_web_search` 已实测可用，
  但 WebParser 抓取未开通，抓取不通前不能删搜索 Key。
- **`hasToken`（UserDefaults）与 Keychain token 可能不同步**：删装/清数据都可能造成
  "同步正常、聊天走 BYOK"的混合状态，本次事故即是（见 B-01）。

---

## 五、2026-11-10 服务端与管理端上线记录（**已部署，无 IPA**）

> 2026-11-10 21:52 北京时间上线：先备份当前线上 `bf-api`/`bf-image` 代码 ZIP、专家目录、运行时开关与两个静态页，再以线上 ZIP 为基座构建候选；只替换 6 个 `bf-api` 业务文件、3 个 `bf-image` 业务文件，`node_modules` 零变化。两函数 Active / `InstallDependency FALSE`，下载后逐文件 inventory 与候选一致。专家目录 `version=8 / catalogRevision=8`，16 个专家全部迁移；`CHAT_GROUNDED_REVIEW` 默认关闭，`CHAT_STYLE_POLICY` 仍关闭；`admin.html`、`staff.html` 线上 SHA256 与候选一致。真实 HTTP 9 项通过，含健康 200、img ping 200、匿名 401、登录 200、16 专家目录 200、SSE JSON 帧与 `[DONE]`、到期 403、额度 429；仅 1 次 24-token 聊天验证，生图 0、客户额度变化 0、临时账号已删除。发布证据 `outputs/release-20261110/release.json`。回滚使用同目录 `before-*.zip`、`config-before.json` 和 `before-*.html`，或 `scripts/release-architecture-20261110.cjs` 的回滚路径。详细根因、影响面和依赖见 `docs/ops/architecture-optimization-20261110.md`。

### C-01 付费生图入口门禁不统一
- **现象**：`/series/step` 可绕过实时会员/额度，`CAP_IMAGE_ENABLED` 不覆盖 `bf-image`，组图 start/step 不按实际张数限流。
- **根因**：四个付费路由各自复制鉴权/额度判断；`quotaExhausted()` 未被 step 调用，预留失败按 0 处理。
- **修法**：`image-execution-gate.js` 单一决策；四入口共用；组图每张在 `runSeriesChild` 计数；预留读取失败返回 null 使额度检查 fail-closed，写入失败把任务标为 failed 并返回 503。
- **验证**：`image-execution-integrity.test.js` 4 项 + `auth-denied-contract.test.js` 5 项；全量 607 通过。真实 DB 并发未跑。

### C-02 账务唯一事件却可并发重复扣额度
- **现象**：新建 event 直接获得 CAS 标记，已有 event 又可能抢到同一标记；账户累计与流水不一致。
- **根因**：`addImageCost()` 给 `isNew` 特例，账户、usage、event 状态不在同一事务。
- **修法**：`image-billing.js` 用 `db.runTransaction` 原子提交账户快照、usage 和 committed；兼容旧 `accountApplied=true` 事件，价格冲突直接拒绝。
- **验证**：并发双调用、旧事件、价格冲突、事件重放均通过；`billing-series-contract`、`security-contract` 旧断言已迁移。

### C-03 审批失败留下永久 pending 或错误凭据
- **现象**：续费生效但通知失败会把申请退回 pending；建号重试重新生成随机密码，delivery 与真实账号可能不匹配。
- **根因**：账号、发放、申请状态和通知是多次非原子写入；`addedAccount.id` 可能不存在。
- **修法**：`approval-fulfillment.js` 单事务，确定性账号/发放/通知 ID；旧凭据不一致时一并重置 hash 与 cipher；已生效续费仍补齐状态，不重复顺延。
- **验证**：`approval-fulfillment.test.js` 3 项故障注入；旧 FUL-01～06、BIZ-01 断言迁移。

### C-04 非幂等请求结果未知仍自动重试
- **现象**：chat/Dashscope image POST 对 5xx/超时最多再发三次，可能重复产生供应商成本。
- **根因**：传输层把 HTTP 可重试状态当成业务可重试结果。
- **修法**：主聊天与 Dashscope 图片生成改单次 `fetchWithTimeout`，台账保留 `outcome_unknown`；通用重试只留给可证明无副作用的调用。
- **验证**：`seedream-official-contract.test.js` 源码契约；未做真实上游故障注入。

### C-05 专家目录覆盖管理员编辑 / 新增专家不可执行 / 多行开场白丢失
- **现象**：种子升级可能覆盖管理员目录；后台可新增旧 App 不支持的 ID；可视化编辑按换行切 `starters`，多行内容只剩第一行。
- **根因**：`version` 同时承担种子和修订语义；前端把对象数组压成一行；本地能力注册表不支持任意 ID。
- **修法**：`expert-catalog.js` 分离 `seedVersion/catalogRevision/origin`，事务保存快照和 expectedRevision，禁止未知/删除 ID；`web/admin.html` 改为结构化 label+textarea 编辑；16 个云端专家改成按需交付。
- **验证**：`expert-catalog.test.js` 4 项、`expert-seed-contract.test.js` 6 项、`web-contract.test.js` 4 项。未覆盖线上管理员目录。

### C-06 员工端错误状态与密码关联
- **现象**：待审核显示立即开通；任何通知都打开 `deliveries[0]`；部分动态姓名仍进 inline onclick。
- **根因**：前端忽略 `instant`、`refDeliveryId`，并用字符串拼 HTML/JS。
- **修法**：按 `j.instant/status` 渲染；通知按 `_id→refDeliveryId` 找对应 delivery，续费/驳回/无关联通知 fail-closed；动态按钮改 `data-*` + 事件委托。
- **验证**：`web-contract.test.js` 通知关联、非账号通知、无关联通知与动态事件断言；`security-contract.test.js` 旧 XSS 断言通过。浏览器端到端未跑。

### C-07 Seedream payload 与官方能力表漂移
- **现象**：带参考图仍发 `optimize_prompt_options`；原生组图用顶层 `max_images`；4.0 原生组图能力被误标 false；236 万旧注释。
- **根因**：历史 S-08 原则只覆盖部分路径；provider 参数与能力表各改一处。
- **修法**：参考图不优化；改 `sequential_image_generation_options.max_images`；补 4.5/4.0 能力；成本注释改 261 万；`/models` 系列探针用真实 series task。
- **验证**：`seedream-official-contract.test.js` 4 项 + 全量回归；未做付费生图和固定素材视觉回归，视觉质量不声称提升。

### C-08 商业成稿独立事实审查
- **现象**：DeepSeek Flash 在有模板冲突和事实缺口时仍会编造现场经历、客户原话与效果承诺。
- **根因**：旧链路只有一次生成，无独立断言—证据核对；`CHAT_STYLE_POLICY` 大段候选未过事实门禁且默认关闭。
- **修法**：`commercial-chat-review.js` 仅选择商业成稿，整理用户证据，生成后独立审查/安全修订；两次上游调用分别计费，断连 Abort，审稿前只发空 SSE 活动帧；`CHAT_GROUNDED_REVIEW` 默认关闭。
- **验证**：`commercial-chat-review.test.js` 5 项 + 配置校验；未做真实模型 A/B，不得启用为全量策略。

### C-09 函数产物可能不是审计源码
- **现象**：`cloudfunctions/*/shared` 是 ignored 生成副本，旧打包脚本全量复制、不清理、不校验，fresh clone 可能缺新模块。
- **根因**：构建步骤靠人工记忆，部署声明与实际函数不一致。
- **修法**：`bundle-function-shared.js` 从 canonical 生成、清旧 JS、写 manifest、逐文件 SHA-256，并提供 `--check` 门禁。
- **验证**：`function-shared-bundle.test.js`；本仓重建后 5 个函数各 22 个共享文件一致。完整 ZIP 上传/下载核验留待生产发布时执行。
