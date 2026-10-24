# 管理端/员工端整改 · 测试报告

执行时间：2026-10-25 02:20（Asia/Shanghai）· 环境：Windows / Node 22.22.2

## 一、命令与结果

| # | 命令 | 退出码 | 通过 | 失败 | 跳过 |
|---|---|---|---|---|---|
| 1 | `node --test tests/admin-staff-security.test.js` | 0 | 14 | 0 | 0 |
| 2 | `node --test tests/*.test.js`（全量 18 个文件） | 0 | **188** | 0 | 0 |
| 3 | `node --check cloudfunctions/bf-api/index.js` | 0 | — | — | — |
| 4 | `node --check cloudfunctions/bf-api/cost-report.js` | 0 | — | — | — |
| 5 | `node --check cloudfunctions/bf-image/index.js` | 0 | — | — | — |
| 6 | 前端内嵌脚本语法（admin.html / staff.html） | 0 | 2 | 0 | 0 |

## 二、本轮新增用例（14 条，`tests/admin-staff-security.test.js`）

权限与会话
- AUTHZ-01 停用员工下次请求即被拒（回库校验 status）
- AUTHZ-02 角色以数据库为准（降权立即生效）
- AUTHZ-03 管理接口显式要求 admin（抽查 4 个高危入口 + 全局 ≥10 处校验点）
- AUTHZ-04 申请列表按 submittedBy 收口
- AUTHZ-05 发放列表按 staffId 收口
- AUTHZ-06 改备注/删除发放校验记录归属

状态机与幂等
- STATE-01 通过必须 CAS 抢 pending
- STATE-02 失败回滚 processing → pending
- STATE-03 **驳回必须 CAS（本轮修复点）**
- STATE-04 已处理申请不可重复审核

凭据与前端
- SEC-01 查看/重置密码必须审计，审计体不含密码
- SEC-02 管理员不可被重置/停用
- UI-01 动态文本必须 esc()
- UI-02 写操作失败不得提示成功

## 三、测试方式说明（避免误解为"全面覆盖"）

- 上述权限/状态机断言是**源码级契约**：这些 handler 依赖 CloudBase SDK，
  本地无法起真实数据库，因此逐条断言具体行为（CAS 条件、过滤字段、错误码），
  不是"文件里存在某函数"。
- 成本聚合（`cost-report.js`）是**真实单测**：喂数据跑聚合，11 条覆盖去重/半开区间/守恒/零值日期。

## 四、未执行（不得视为通过）

| 项 | 原因 |
|---|---|
| 真实数据库并发注入（两人同时审核、50 并发重放） | 本地无 CloudBase 实例；需在测试环境用两个管理员账号实测 |
| 浏览器端 XSS 实际执行 | 需起静态服务 + 真实会话 |
| 移动端浏览器布局/键盘遮挡 | 需真机或浏览器设备模拟 |
| `npm audit` 依赖漏洞扫描 | 需联网跑依赖清单 |
| iOS 构建与真机 | 本轮无 Swift 改动；改的是云函数与网页 |
