# 批次补丁：交付要求守卫（2026-11-20 14:40）

> 状态：**已构建、已过门禁、未部署**（按要求等确认）。
> 基线：线上 13:22 版本（SHA `880cf7a5`，即 11-17 23:54 native-copy + 意图层）。

## 一次解决四类问题

| 你指出的问题 | 本批次怎么解 |
|---|---|
| Logo 留白底 / 被重绘 | 自动判定哪张附件是 Logo，要求「用原图形、不得加白底或方框」 |
| 公司名缺失、右下「品牌名称」占位 | 从长期记忆取公司全称，占位块就地替换；没有真值就删除 |
| 功能卡文字上下各一份 | 明确「同一段文字只能出现一次」；服务端另做去重（同文本块只留第一次） |
| 方形被拉成长方形 / 超长条 | 明确「素材保持原始宽高比」「画布比例必须与 aspect_ratio 一致」；另提供 `ratioMismatch()` 供出图后校验（偏差 >8% 判不合格） |

## 实现（3 个文件）

### `requirement-guard.js`（新增）

- `imageSize()`：只解析 PNG IHDR / JPEG SOF 头，不解整图
- `collectImages()`：按出现顺序收集本轮内联图
- `classify(images, userText)`：面积最小且扁平 → Logo；用户提到「旧稿/上一版/改版/重绘」时面积最大者 → 旧稿，否则 → 素材照片
- `buildRequirements()`：产出「交付要求」系统消息（只写约束，不写具体文案）
- `enforce(blocks, {company, contact})`：占位替换/删除、重复块去重、缺公司名/热线自动补
- `ratioMismatch(requested, w, h)`：比例偏差 >8% 判不合格

### `index.js`（改动 1 处）

在意图解析之后注入：

```js
const roles = rg.classify(rg.collectImages(messages), imageUserText || "");
const reqNote = rg.buildRequirements({ roles, company: intent.company, contact: intent.contact });
if (reqNote) messages = messages.concat([{ role: "system", content: reqNote }]);
intent.enforceSpec = { company: intent.company, contact: intent.contact };
```

### `intent-contract.js`（改动 1 处）

在拿到 `structured.text` 后调用 `requirement-guard.enforce()`，修补后再走原有的术语修复与占位清理。

## 验证

| 项 | 方法 | 结果 |
|---|---|---|
| 图片尺寸解析 | 真实 PNG(360×131) / JPEG(1400×1800) | 均正确 |
| 角色判定 | 2 图无旧稿语义 → logo+photo；有「上一版/改版」→ logo+poster | 两种都正确 |
| 要求文本 | 公司名/热线存在时才追加对应条目 | 正确 |
| 硬校验 | 输入「品牌名称/高清画质×2/待补充」 | 占位替换、重复删除、热线补入，4 项 issue 全部命中 |
| 比例校验 | 3:4 vs 1776×2368 → pass；2:3 vs 1104×3792 → fail | 正确 |
| 逐文件门禁 | 基线 + 3 文件 | ok，缺失文件 0、缺失导出 0 |

**行为侧证据**：14:34 那次手工把这 8 条要求写进请求，成品从「白底 Logo / 占位 / 文字重复 / 拉伸」变成「干净可交付」。本批次就是把那 8 条固化。

## 未包含（下一批）

- P1-1「再改一次」走 Seedream 5.5 多轮编辑（像素级保持）
- P1-3 把生成后质检接进主链路（现为独立脚本 `scripts/p0-2-qc-20261120.cjs`）
- P2-1 草稿/定稿分层降本

## 发布方式（待确认）

```bash
node scripts/deploy-function-zip.cjs --fn bf-api \
  --zip outputs/batch-20261120/candidate-bf-api.zip \
  --out outputs/batch-20261120
```

回滚包：`outputs/rollback-p01-20261120/after-bf-api.zip`（= 当前线上）。
