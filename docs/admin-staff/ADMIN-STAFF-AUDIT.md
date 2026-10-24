# 管理端/员工端权限与状态机审计

基线：`saas_fix`（本轮起点 commit `6e90927`，本轮提交见 CHANGELOG）· 审计日期 2026-10-25

## 一、结论摘要

| 项 | 结论 |
|---|---|
| 停用员工旧会话 | **本来就正确**：`requireStaff` 每次回库查 `status`，非 active 直接 403 |
| 角色降权 | **本来就正确**：以数据库 `role` 为准，不用 token 里的旧角色 |
| 员工数据范围 | **本来就正确**：查询层强制 `submittedBy/staffId` 过滤（admin 才放开） |
| 审核通过并发 | **本来就正确**：`pending → processing` CAS 领取，失败回滚 |
| 审核驳回并发 | **本轮修复**：原来只读 status 再 update，可与通过并发双写 |
| 密码展示 | **按业务决策保留**（2026-10-24 用户明确：必须可回查），已加审计与止损开关 |
| XSS | **已覆盖**：admin 87 处 / staff 28 处 `esc()`，抽查无未转义的用户输入 |

## 二、逐模块发现

### 2.1 会话与鉴权（`bf-api/index.js:895-918`）

`requireStaff(req,res,needAdmin)` 做了四件事，顺序正确：
1. 验 token 签名与类型（`t === "staff"`）
2. **回库查员工**（不是只看 token）：不存在 → 401；`status !== "active"` → 403 `STAFF_DISABLED`
3. 角色取**数据库**值（`liveRole`），`needAdmin` 时校验 admin
4. 库不可用 → 503 `AUTH_UNAVAILABLE`（fail-closed，不放行）

→ 验收项「被禁用员工的旧会话不能继续访问」**已满足**，本轮加测试锁定。

### 2.2 数据范围（`handleListRequests` / `handleListDeliveries` / 改备注 / 删除）

| 入口 | 过滤 |
|---|---|
| 申请列表 `:3226` | admin → `{}`；员工 → `{ submittedBy: staff.sub }` |
| 发放列表 `:3944` | admin → `{}`；员工 → `{ staffId: staff.sub }` |
| 改备注 `:3980` | `role !== admin && d.staffId !== staff.sub` → 403 |
| 删除发放 `:4011` | `role !== admin && doc.staffId !== staff.sub` → 403 |

→ 验收项「员工不能读取或修改其他员工的客户数据」**已满足**（查询层收口，非前端隐藏）。

### 2.3 审核状态机（`:3233` 驳回、`:3264` 通过）

通过：`where({_id, status:"pending"}).update({status:"processing"})` → `claim.updated` 为假即 409；
业务失败回滚 `processing → pending`（避免卡死）。

驳回（**修复前**）：
```js
if (reqDoc.status !== "pending") return 409;   // 用的是先前读到的快照
await db.collection(C.requests).doc(id).update({ status: "rejected", ... });
```
并发场景：A 通过已把状态置 `processing`，B 驳回仍按旧快照判断为 `pending` → 覆盖成 `rejected`，
结果「账号已开通 + 申请显示已驳回」，且驳回通知已发出。**这是真实的状态机漏洞**。

修复：驳回改为同一把 CAS（`where({_id, status:"pending"})`），以 `updated` 计数判定。
影响面：仅多一次条件更新；语义从"先读后写"变成"原子领取"。

### 2.4 凭据（密码）

- 查看：`handleStaffPassword` 解密返回明文 + `auditLog("staff.password.view")`
- 重置：`handleResetStaffPassword` 写 `passwordHash` + `passwordCipher` + `auditLog("staff.password.reset")`
- 管理员账号不可被重置/停用（403）
- 审计体**不含** password 字段（有测试反向断言）
- 发放存档回显受 `REVEAL_DELIVERY_PASSWORD` 开关控制（默认 1，按业务决策）

→ 与审计建议的"只存哈希"**冲突**，这是**已接受的产品决策**（见 `docs/security/password-reveal-decision.md`），
本轮不擅自改动；残余风险与泄露处置已在该文档登记。

### 2.5 前端 XSS 与失败态

- `esc()` 覆盖：admin 87 处、staff 28 处；抽查 `d.username`、备注、客户名均转义后插入
- 两处 `innerHTML` 拼接经人工核对为常量或服务端自增版本号，无用户输入
- 写操作均判 `j.ok` 后再提示成功；无"失败分支出现成功文案"

## 三、优先级与状态

| 编号 | 问题 | 优先级 | 状态 |
|---|---|---|---|
| AS-01 | 驳回与通过并发可双写状态 | P0 | 已修复 |
| AS-02 | 停用员工会话（审计预期要改） | — | 无需修复，已加测试锁定 |
| AS-03 | 密码可解密回显 | P1（风险接受） | 按业务决策保留，审计+开关已就位 |
| AS-04 | 审核/发放缺"响应丢失后重放"的前端幂等提示 | P2 | 未做（见未执行项） |

## 四、未执行项（明确列出）

- 真实 CloudBase 数据库的并发注入（本地无库，只能做源码级契约 + 纯函数单测）
- 浏览器端 XSS 实机执行（需起静态服务与真实会话）
- 员工端移动端浏览器布局/键盘遮挡
- `npm audit`（当前环境未跑，需联网依赖清单）
