# 成本看板修复 + 定价改为"成本 × 2"（2026-10-29）

## 一、成本看板为什么全是 0

**不是没花钱，是查不到。**

- 写入：`bf_usage_logs.ts = new Date()`（BSON 日期）
- 查询：`where({ ts: db.command.gte(startMs) })`，`startMs` 是**数字毫秒**

Mongo/CloudBase 的范围比较按 BSON 类型分桶，数字范围匹配不到日期值。唯一能命中
的是"语义缓存"那条 —— 它写的是 `ts: nowMs()`（数字），于是看板精确显示成
「1 次调用 / ¥0 / 按模型 semantic-cache / 按档位 modeStandard」。会员管理里的已用金额是对的，
因为它读账号计数器（`chatUsedCny + imageUsedCny`），不读流水。

修法：
1. 缓存行改写 `ts: new Date()`；
2. 查询改成 `db.command.or([{ts: gte(new Date(startMs))}, {ts: gte(startMs)}])`，兼容历史数字行。

验证（部署后实测 `/api/admin/cost-report?days=7`）：
`ledgerEvents 186 / 成本 ¥27.85 / 图片 46 张 / byKind {chat:2.05, image:25.8}`。

## 二、第二个更隐蔽的错：流水把"售价"当成本

旧 `addImageCost(accountId, costCny)` 一个参数同时做两件事：扣用户额度、写成本流水。
所以成本看板（哪怕查得到）显示的是售价，毛利永远算不出来。

现在账实分离：
- 账户扣减 `imageUsedCny/day/week = 售价`
- 流水 `costCny = 上游成本`、`priceCny = 售价`、`marginCny = 毛利`
- 任务单额外存 `upstreamCostCny`，flush 落账时透传

## 三、定价：售价 = 成本 × 倍数（默认 2）

上游官方单价（火山方舟 2026-10 核实，写进代码常量，可在后台改）：

| 模型 | 官方成本 |
|---|---|
| Pro ≤261 万像素（单图） | ¥0.30/张 |
| Pro >261 万像素 | ¥0.60/张 |
| Pro 图层拆分 | ¥0.15 / ¥0.30 |
| Pro 多图输入 | 首张免费，第 2 张起 ¥0.02/张 |
| Flash | ¥0.12/张（不分尺寸，输入免费） |
| Lite / 4.5 / 4.0 | ¥0.22 / ¥0.25 / ¥0.20 |

售价由 `customerPriceOf(cost) = cost × IMAGE_PRICE_MULTIPLIER`（默认 2，四舍五入到分，且不低于成本）推导。

### 顺带修掉三个旧定价错误

| 场景 | 旧收费 | 旧成本 | 旧毛利 | 新收费 |
|---|---|---|---|---|
| Flash 出 2K | ¥0.80 | ¥0.12 | **6.7 倍（暴赚）** | ¥0.24 |
| Pro 出 2K | ¥0.80 | ¥0.60 | 1.33 倍（薄） | ¥1.20 |
| Pro 出 1.5K | ¥0.45 | ¥0.30 | 1.5 倍 | ¥0.60 |

还有一个隐藏错误：像素分界写的是 236 万，官方是 **261 万**。
1.5K 3:4 = 1344×1792 = 241 万，被错判成大图，每张多记 0.30 成本。

### 实测（部署后真实调用）

- `Pro 2K 3:4` → 模型 `doubao-seedream-5-0-pro-260628`，收费 **¥1.20**，流水 `cost 0.60 / price 1.20 / margin 0.60`
- `Flash 2K 3:4` → 收费 **¥0.24**，流水 `cost 0.12 / price 0.24`

## 四、发现但没动的事（需要拍板）

1. **现在几乎全部走 Flash。** 服务端 `image-routing.js` 的 `DEFAULT_POLICY` 是
   `defaultTier: "fast"`、`honorClientHigh: false`，而且线上没配 `IMAGE_AUTO_POLICY`。
   结果客户端传 `quality_tier=high` 被忽略，普通编辑/海报也走 Flash。
   也就是说"Pro 质量"事实上没在用。要不要让编辑/文字密集默认走 Pro，是一条 JSON 配置就能改的事。
2. **对话单价没动。** 0.8 / 2.7 元每百万 token 看起来是"售价"口径，缺 DeepSeek 实际结算价，
   无法按 2 倍重算。要统一口径，需要成本基准。
3. **档位池线上 136 / 1100，仓库里是 135 / 1190。** 下次从仓库部署 bf-api 会把额度改掉。
