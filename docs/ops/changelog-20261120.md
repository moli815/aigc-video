# 2026-11-20 变更记录（当日全部改动与提交）

> 本文件补齐今天所有改动的文档与提交记录。时间均为北京时间。
> 线上 `bf-api` 是「11-17 23:54 native-copy 基线 + 意图层补丁」，与仓库 HEAD 不是同一条线，因此 `index.js` 的接线改动以白名单补丁形式发布，SHA 记录在案。

## 一、线上发布记录

| 时间 | 函数 | 内容 | 结果 |
|---|---|---|---|
| 11:29 / 11:33 | bf-api | 修「带图必失败」（计费准入把图片任务判成无法预估） | 已发布 |
| 11:52 | bf-api | 补推 `poster-canvas-calls.js`（`reviewAndAdaptPosterCalls` 缺失导致海报必崩） | 已发布 |
| 11:58 | bf-api | 回退到 11-17 13:00 已验证包 | 已发布 |
| 12:41:24 | bf-api | 按用户要求整体回退到 11-17 13:00（SHA `a219e5ed…`） | 已发布 |
| 12:41:38 | bf-image | 同上（SHA `0de9a0b1…`） | 已发布 |
| 13:14:35 | bf-image | 恢复 11-17 23:54 native-copy 版（SHA `ab9b2603…`，与当晚记录一致） | 已发布 |
| 13:14:51 | bf-api | 恢复 11-17 23:55 版（SHA `ae59dd10…`） | 已发布 |
| 13:22:46 | bf-api | 意图层 v1：比例锁定 + 热线补齐 + 补 `isHistoryPreview` 导出 | 已发布 |

## 二、代码改动清单

### 2.1 `cloudfunctions/bf-api/intent-contract.js`（新增，已上线）

前置意图契约。从「本轮原话 + 最近几轮 + 长期记忆」抽取硬约束（竖版/横版、显式比例、热线、公司全称），
在生图参数定稿前做确定性校正：比例方向冲突才改、热线缺失才补、占位文字清理。
自测：竖版/横版/9:16/记忆偏好/否定句（别横版）/举例跳过/热线提取 全部通过。

### 2.2 `cloudfunctions/bf-api/brand-memory.js`（新增，待部署）

品牌事实自动记忆。每轮扫描用户原文，确定性抽取公司全称、联系电话、Logo 长期要求，
通过 `domains/sync-v2` 的 push 写入长期记忆（客户端下次拉取可见）。
refId = hash(类别+值)，重复写不堆积；800ms 超时上限，失败静默。
自测：客户 11-07「400-7758-119」、11-10「以后都要加 logo」、自报公司名均可识别；「假设…测试有限公司」被跳过。

### 2.3 `cloudfunctions/bf-api/index.js`（白名单补丁，已上线）

- 注入 `loadMemoryTexts()`：读 `bf_sync_v2` 里 kind=memory 的记录（1.5s 超时）
- 注入 `intentContract.resolve/guidance/apply`
- 注入 `brandMemory.remember()`（每轮扫描品牌事实）
- 线上 SHA：`880cf7a5…`（13:22:46 版）

### 2.4 `cloudfunctions/bf-api/shared/image-delivery.js`（已上线）

补 `isHistoryPreview` 导出——`poster-reference-readiness.js` 与 `poster-canvas-calls.js` 都引用了它，
缺这个导出会在「召回历史素材且本轮无自有参考图」时抛 TypeError。

## 三、验证记录

| 项 | 方法 | 结果 |
|---|---|---|
| 包自洽 | `scripts/audit-live-bundle.cjs`（require 解析 + 导出符号） | 缺失文件 0 / 缺失导出 0 |
| 核心链路 | `scripts/live-smoke-20261120.cjs` 24 项 | 24/24 |
| 客户三轮原话重放 | `scripts/replay-intent-20261120.cjs` | 3/3 竖版、热线正确 |
| 意图层单测 | 9 条断言 | 全通过 |

## 四、待办（未上线）

- 品牌记忆部署（CloudBase 凭据过期，需 `tcb login`）
- 复盘文档中的 P0/P1 优化项（见 `docs/ops/app-review-20261120.md`）
