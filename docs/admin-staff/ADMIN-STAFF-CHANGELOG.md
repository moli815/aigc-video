# 变更说明（管理端/员工端整改）

## 变更文件

| 文件 | 修改点 | 对应问题 | 兼容性 |
|---|---|---|---|
| `cloudfunctions/bf-api/index.js` | `handleRejectRequest`：拒绝改为 `where({_id,status:"pending"}).update(...)`，以 `updated` 判定，失败返回 409 | AS-01 | 完全兼容：接口路径、请求体、成功响应不变；仅在"申请已被别人处理"时从"可能双写"变为稳定 409 |
| `tests/admin-staff-security.test.js` | 新增 14 条权限/状态机/凭据/XSS 用例 | — | 无 |

## 行为变化（对使用者可见的部分）

- 并发场景下第二个操作者可能收到 `409 ALREADY_REVIEWED`（文案："该申请已被其他操作处理，请刷新"）。
  这是**期望行为**：以前两边都会显示成功，实际只有一方生效。

## 回滚步骤

1. 代码：`git revert <本提交>`，或把 `handleRejectRequest` 恢复为原先的
   `db.collection(C.requests).doc(id).update({...})` 直接更新。
2. 数据：本次**无 schema 变更、无数据迁移**，回滚不需要动数据库。
3. 部署：重新部署 `bf-api`（`tcb fn deploy bf-api`）即回到旧逻辑。
4. 风险：回滚会恢复"驳回可与通过并发双写"的窗口，只在多管理员同时操作同一申请时触发。

## 未包含在本轮的改动

- 密码哈希化迁移（与 2026-10-24 业务决策冲突，需单独评估）
- 账务事件契约重构（`UsageLedger` / 对账 worker）
- iOS 侧任何改动
