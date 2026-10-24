# C2.1 测试报告

2026-10-25 03:10 · Windows / Node 22.22.2

| # | 命令 | 退出码 | 通过 | 失败 |
|---|---|---|---|---|
| 1 | `node --test tests/notify-retry.test.js` | 0 | 15 | 0 |
| 2 | `node --test tests/*.test.js`（20 文件） | 0 | **209** | 0 |
| 3 | `node --check cloudfunctions/bf-api/index.js` | 0 | — | — |
| 4 | admin.html 内嵌脚本语法 | 0 | — | — |

新增 5 条边界用例（BND-01..05）：nextAt 参与筛选、重复键按已投递、attempts 不虚耗、
补发接口管理员+审计且不碰开通、管理端三态呈现与待审核分离。

**仍未执行（不能算通过）**：真实数据库故障注入、浏览器交互、bf-jobs 定时补发、iOS。
