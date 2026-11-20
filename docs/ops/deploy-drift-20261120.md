# 线上与本地漂移盘点（2026-11-20 11:55）

> 背景：11-17 中午一轮、11-17 晚至 11-18 中午一轮，均以「白名单逐文件发布」方式上线，
> 本地工作区大量文件从未发布。11-20 的海报崩溃就是「调用方上线、被调用模块没上线」造成的。
> 本文件记录当前漂移全貌，**禁止整包覆盖部署**，只能按需白名单 + 逐文件门禁。

## 一、本地有、线上没有（10 个）

- `poster-content-contract.js`
- `shared/image-provider-qwen.js`
- `shared/image-style-reference.js`
- `shared/manifest.json`
- `shared/poster-art-direction.js`
- `shared/poster-pipeline.js`
- `shared/poster-repair.js`
- `shared/poster-text-audit.js`
- `shared/review-reminders.js`
- `shared/series-reference-input.js`

## 二、两边都有但内容不同（19 个）

> 差异方向为「本地更新」。这些是尚未上线的工作，发布前必须逐个评估。

- `account-context.js`
- `approval-fulfillment.js`
- `commercial-copy-review.js`
- `commercial-image-guidance.js`
- `domains/foundation.js`
- `image-single-reference-guidance.js`
- `image-tool-repair.js`
- `image-tool-schema.js`
- `settings-schema.js`
- `shared/commercial-generation-mode.js`
- `shared/cost-budget-migration.js`
- `shared/error-catalog.js`
- `shared/image-delivery.js`
- `shared/image-job-claim.js`
- `shared/image-policy.js`
- `shared/image-workflow.js`
- `shared/model-call-ledger.js`
- `shared/native-copy-policy.js`
- `shared/quota-percent.js`
