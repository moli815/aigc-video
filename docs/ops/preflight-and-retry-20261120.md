# 发版前必跑 + 生图失败兜底（2026-11-20 16:35）

## 一、生图失败兜底（bf-image，已上线）

### 现状（近 14 天 870 笔）

| 类型 | 笔数 |
|---|---|
| image/rejected | 28（HTTP400×17、HTTP404×10、HTTP400 decompose×1）|
| BILLING_UNAVAILABLE | 11（今天那个，已消失）|
| chat/partial | 16 |
| CONSUMER_CANCELLED | 7 |
| outcome_unknown | 8 |

被拒的 28 笔 **全部未扣费**（chargeState=not_recorded），计费链路在失败路径上是干净的。

### 改动

在上游返回 400/404/413/422 时，先用**最保守参数**重试一次：标准档位 `2K`、提示词截断到 1200 字、去掉 `background` 与 `optimize_prompt_options`；仍失败再走原有的「能力升级到 Pro」，最后才回报。

失败原因翻成可读中文：

- 400 → 画面参数未被上游接受（尺寸或素材不合规），可换素材或改用常见比例重试
- 404 → 上游模型暂不可用，请稍后重试
- 413 → 素材体积过大，请压缩后再试
- 422 → 素材内容未通过合规检查，请更换素材

日志：`image_safe_retry`。

## 二、发版前必跑（preflight）

`scripts/preflight-20261120.cjs` 串起四件事：

1. 候选包逐文件门禁
2. 线上健康（/api/health、/img/ping）
3. 客户端路径回归（6 项）
4. 任一项失败 → 退出码 1，禁止发版

```bash
node scripts/preflight-20261120.cjs --base <基线zip> --candidate <候选zip>
node scripts/preflight-20261120.cjs --client-only
```

### 客户端路径回归（6/6 通过）

| # | 用例 | 结果 |
|---|---|---|
| A | 正常对话 | 200 |
| B | 用户额度耗尽（对话） | 429 + "本月额度已用完，续费后立即恢复" |
| C | 用户额度耗尽（生图） | 429 且扣费 0.0000 |
| D | 会员过期 | 403 |
| E | 同 requestId 连发两次生图 | 第二次 cached，不重复扣费 |
| F | 账务一致性 | 账号记录 = 台账合计 |

> 修正说明：B/C 最初误用「内部成本上限」而非「用户额度」，导致假失败；已改为按用户额度判定。

## 三、管理端「失败/被拒」筛选（未做，原因）

`web/admin.html` 的消费页调用 `/admin/requests`、`/admin/cost*`，但当前 bf-api 包里**不存在这些路由**——管理端后端不在此函数中。在没有对应后端的情况下加前端筛选只会得到一个永远空白的按钮，因此暂不实现，需先确认管理端后端所在仓库/函数。

## 回滚

- bf-image：`outputs/final-1118/before-bf-image.zip`
- bf-api：`outputs/final-1118/before-bf-api.zip`
