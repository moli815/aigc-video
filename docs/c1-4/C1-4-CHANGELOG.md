# C1.4 变更说明

## 变更文件

| 文件 | 变更 | 兼容性 |
|---|---|---|
| `cloudfunctions/bf-api/notify-retry.js` | 新增：通知 ID、退避、上限、补发编排（纯函数） | 独立模块，无副作用 |
| `cloudfunctions/bf-api/index.js` | 新增 `markNotify` / `ensureNotified` / `buildNoticeFromRequest` / `sweepNotifications`；approve/reject 成功后做通知落地检测；`GET /admin/requests` 顺带补发一轮 | 接口路径与响应结构不变；请求文档新增若干字段（读时缺失即视为旧数据） |
| `tests/notify-retry.test.js` | 新增 10 条 | — |

## 行为变化

- 审核成功后若通知未落库，申请文档会带 `notifyState=pending`，管理员打开列表时自动补发。
- 补发最多 5 次，之后 `notifyState=failed` + `notifyLastError`，不再自动重试（避免无界重试）。
- 补发**不会**重跑开通/续费；同一申请的通知 `_id` 恒定，重复执行不会出现两条。

## 回滚

1. 代码：`git revert <本提交>`；或删掉 `ensureNotified` / `sweepNotifications` 调用点。
2. 数据：新增字段对旧代码无影响（旧逻辑不读它们）；如需清理，可批量 `update({notifyState: _.remove()})`，非必须。
3. 部署：重新部署 `bf-api`。
4. 风险：回滚后通知失败重新变成"无记录"，仅日志可见。
