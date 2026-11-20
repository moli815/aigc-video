# 批次补丁 2：画面守卫 + 多轮一致 + 草稿档位（2026-11-20 14:45）

> 状态：**已构建、已过门禁、未部署**。
> 基线：`bf-image` = 11-17 23:54 native-copy 版；`bf-api` = 线上 13:22 版。

## 解决的问题与依据

### 1. 画布比例被构图引擎覆盖（对应「方形被拉成长方形 / 0.29 超长条」）

**根因**（`bf-image/index.js` 原第 1593 行）：

```js
payload.size = resolveImageSize(tier, composition.manifest.artwork?.aspectRatio || "3:1");
```

构图引擎按内容量自己算出一个比例（默认 `3:1`），把客户端请求的 `2:3` / `3:4` **直接覆盖**。于是出现 1104×3792 这类长条，模型只能把方形素材拉长。

**改法**：用户给了明确比例就以用户为准；构图引擎只决定像素档位。没有明确比例时，把引擎比例**收敛到白名单**（1:1 / 4:5 / 3:4 / 2:3 / 9:16 / 16:9 / 4:3 / 3:2 / 5:4），超出 0.25–4 一律回落 3:4。

**日志**：`composition_canvas_guard`（记录 requested / compRatio / finalRatio / from / to）。

### 2. 多轮编辑一致性（对应「再改一次越改越差」）

官方《Seedream 5.5 教程》明确：多轮编辑建议用 RGB 图并设 `background: opaque`，才有一致的非编辑区保持。

**改法**：`taskKind === "edit" | "reference"` 且非透明输出时，自动 `payload.background = "opaque"`。

**日志**：`multi_round_opaque`。

### 3. 草稿/定稿分层（降本，默认关闭）

官方 5.5 支持 1K/1.5K/2K 档位，价格随像素档上升。

**改法**：配置 `IMAGE_DRAFT_MODE=on` 且本轮**无参考图**时，首轮降为 1.5K；定稿（带参考图或 `draft:false`）仍走 2K。**默认不开启**，不改变现有出图质量与成本。

**日志**：`draft_tier_applied`。

## 变更文件

| 包 | 文件 | 变更 |
|---|---|---|
| bf-image | `index.js` | 3 处（比例守卫、opaque、草稿档） |
| bf-api | `index.js` | 1 处（交付要求注入） |
| bf-api | `intent-contract.js` | 1 处（enforce 接入） |
| bf-api | `requirement-guard.js` | 新增 |

## 验证

| 项 | 结果 |
|---|---|
| bf-image 逐文件门禁 | ok，仅 `index.js` 变化，缺失 0 |
| bf-api 逐文件门禁 | ok，3 文件变化，缺失 0 |
| 语法检查 | 两个 `index.js` 均通过 |
| 行为侧 | 14:34 用手工 8 条要求验证过：比例回到 3:4、Logo 无白底、无占位、无重复、不拉伸 |

## 尚未做的验证

- 三项改动都**未在真实生成链路跑过**（未部署）。部署后须用「旧海报重绘 + 三附件」场景复测：
  - 比例是否稳定在请求值（3:4）
  - 多轮是否不再重画全图
  - 草稿档位默认关闭时成本与现网一致

## 回滚

- `bf-api`：`outputs/rollback-p01-20261120/after-bf-api.zip`（现网）
- `bf-image`：`outputs/deploy-nativecopy-20261120/before-bf-image.zip`（现网）
