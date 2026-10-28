# 多附件合成修复（人物照 + 底图）

2026-10-28 · 对应源码 `BossAI/Services/ImageReferenceResolver.swift`、`ImageToolArguments.swift`、`cloudfunctions/bf-image/index.js`

## 现象

两起真实投诉，看起来是模型不会 P 图，实际是两个不同的缺口：

1. **「在我给的原图左边 P 一个马云」→ 出来一个毫不相干的人。**
   只有底图，没有马云的照片。Seedream 没有真人肖像库，纯文字点名只能按"中年男性/瘦削/西装"的先验画一个人。
   我们没有任何拦截，直接发出请求并把结果当成功交付。
2. **「第一张照片上的人 P 到第二张底图上，两人握手」→ 底图完全正确，人"只是有点像"。**
   视觉层（聊天模型）确实拿到了两张图（`ChatViewModel.swift:448`，最多 6 张 `image_url`），
   但**生图请求只送了一张**：`ImageReferenceResolver.resolve` 的 `attached` 分支历史上只返回单张，
   `both` 分支是「上次生成图 + 一张附件」。人物照从未离开设备。

## 已核实的根因（代码级）

| # | 事实 | 位置 |
|---|---|---|
| 1 | `attached` 只返回 `[attachedImage(at: index)]`，多附件不可能同时上行 | `ImageReferenceResolver.swift`（改前） |
| 2 | `both` 的实现是「上次生成图 + 一张附件」，但 schema 描述写成「双图融合（第一张为底图，第二张为叠加素材）」 | `ToolManifest+Schema.swift` |
| 3 | 全仓没有图序角色标注（搜不到「第一张」「图1」），两张图同时到达模型也会被搞混 | `ImageTaskPlanner` / `bf-image` |
| 4 | 服务端 `payload.image = image` 本来就支持数组，瓶颈只在客户端组装 | `bf-image/index.js` |

第 2 条是最恶劣的：**文档骗了 Agent**。Agent 按「both=两张上传图融合」去调，实现按另一套取，
结果是静默丢图，还不会报错。

## 本轮改动

### 1. 客户端来源解析（`ImageReferenceResolver`）

- 新增 `resolve(source:attachmentIndices:attachedImages:lastGeneratedImage:)`，`attached` 分支按给定顺序返回多张。
- **顺序契约**：`indices.first` 是底图，其余是素材。这一条同时被三处依赖——`ImageGeometry` 只读 `refs.first`
  做比例保护、`ImageTaskPlanner` 只读 `refs.first` 取像素尺寸、服务端按同一顺序标注"图1=底图"。
- 去重保序、上限 6 张、越界 fail-closed（不允许"少一张也照发"）。
- `both` 语义**原样保留**（生成图 + 一张素材），Logo/二维码原样替换依赖它，不动。

### 2. 工具契约（`ToolManifest+Schema`）

- 新增 `source_indexes`（1~6 整数数组，第一项是底图）与 `reference_roles`（与序号一一对应的角色短语）。
- 修正 `both` 的描述，写明它是「上次生成图作底图 + 一张上传素材」；
  要两张**上传**图互合成，必须用 `attached + source_indexes`。
- 顶层 description 直接给出示例：`source=attached, source_indexes=[2,1]`。

### 3. 计费前校验（`ImageToolArguments`）

参数不对就回注修正，而不是发出一张注定错的请求：

- `source_indexes` 只能配 `source=attached`（混 `both` 会静默丢图）；
- 与 `source_index` 二选一，禁止同时出现；
- 序号不重复、1~6、最多 6 项；图层拆分只接受一张；
- `reference_roles` 必须与序号等长，每项 ≤24 字且不含换行。

### 4. 请求贯通（`ImageRequestContext` → `ImageService` → `ImageProviderRequestCompiler`）

- 上下文新增 `referenceRoles: [String]`（不可变，随 `appendingPrompt` / `retrying` / `forTextlessBackground` 原样继承）。
- `hosted` envelope 增加 `reference_roles`，仅在 `references.count > 1` 时下发。
- 客户端在**张数对不上时不发角色**（脏数据宁可不发，也不能错标"哪张是人物"）。

### 5. 服务端多图契约（`bf-image`）

`multiImageContract(image, referenceRoles)` 在用户 prompt **最前面**插入：

- 按发送顺序编号「图1=底图；图2=人物照片」（角色由客户端给，缺省第一张底图）；
- 用户说"第几张/这张图里的人"一律按此编号理解；
- 输出画布以底图为准，不裁切、不改未指定区域；
- 素材人物必须原样使用其面部/发型/体型/服装/外观，**禁止用相似但不同的人替代**；
- 只做用户要求的合成，不重绘整张；接触处必须有合理阴影。

单图请求不会触发这段（`list.length < 2` 直接返回空串）。

### 6. Agent 指引（`ImageDesignGuidance`）

- 规则 11：双图合成必须 `source=attached + source_indexes + reference_roles`，并在 prompt 点名"图几"；只传一张等于把素材丢了。
- 规则 12：要某人的长相就必须有他的照片；只给名字时先索取照片，**不得凭名字臆造肖像**，也不得把陌生人当本人交付。

## 验证

- 后端 329 条契约测试全绿（新增 `tests-backend/multi-reference-contract.test.js` 7 条）。
- 新增契约锁：schema 必须有 `source_indexes`/`reference_roles`；`both` 不得再宣称双图融合；
  解析器必须支持多序号且第一项为底图；参数校验必须拒绝歧义组合；服务端必须注入多图契约。
- Swift 单测新增 7 条（解析器 5 + 参数校验 2）：顺序、去重、越界、超限、旧 `both` 不回归、
  合法成对输入、错误组合被拒。
- 最终编译与实机以本次提交的 CI 为准，不在本地宣称通过。

## 仍然不能保证的

- **送对图 ≠ 100% 同一个人。** Seedream 的多图是"参考"，不是锁脸。身份一致性会明显提升，
  但同一宽高比内的细微差异（脸型、年龄感）仍需人眼验收。要做到接近确定，需要
  `input_image_mask` 局部重绘或 `input_fidelity: high`（均为其他 provider 的能力）。
- **组图仍是串行**，两张图合成不加时间，但多图请求本身会比单图慢（上游要读两张）。
- **点名真人**：现在会先要照片，但"是否像"依然由模型决定，代码只保证不拿陌生人冒充。
- 本轮只改源码，bf-image 需重新部署才对线上生效；不做部署就等于没修。
