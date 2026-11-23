"use strict";
// ============================================================================
// stream-error-frame.test.js —— 11-03 新增
//
// 来源：真机截图。对话中途失败后，气泡下方出现
//   输出尚未完成（{ code = "UPSTREAM_ERROR"; message = "\U8fd9\U6b21..." }）。
// 这是客户端把流内错误对象整个 toString 的结果；而根源之一在服务端：
//   1. 上游在流中途下发的 error 帧被**原样转发**给了 App（App 只能照着 dump）；
//   2. 审计循环 try/catch 吞掉一切，日志里只剩一个固定 code，线上分不清原因。
//
// 本文件锁三件事：
//   A. 对外错误帧的 `error` 必须是**中文短句**（老客户端直接 toString 也能读）；
//     机器码挪到 `errorCode`，新客户端仍可分支。
//   B. 上游 error 帧必须在服务端被拦截，不得透传。
//   C. 失败原因必须进日志（code + detail），不允许再记固定常量。
// ============================================================================

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const API = fs.readFileSync(path.join(__dirname, "../cloudfunctions/bf-api/index.js"), "utf8").replace(/\r\n/g,"\n");

test("stream error frame carries human copy, not a code object", () => {
  const start = API.indexOf("function streamErrorFrame(");
  assert.ok(start > 0, "缺少 streamErrorFrame");
  const body = API.slice(start, API.indexOf("\n}\n", start) + 3);
  // error 必须是中文短句：老 App 会把它 toString 上屏
  assert.match(body, /return \{ error: copy, errorCode: "UPSTREAM_ERROR", message: copy \};/,
    "错误帧的 error 必须是人话（copy），不能是 { code, message } 对象");
  assert.match(body, /TOOL_ARGUMENTS_INCOMPLETE/, "工具参数写一半断开要有单独文案");
  assert.match(body, /TOOL_ARGUMENTS_TOO_LARGE/, "参数超限要有单独文案");
  assert.match(body, /UPSTREAM_STREAM_ERROR/, "上游错误帧要有单独文案");
});

// 直接执行源码里的 streamErrorFrame（不是测试里另抄一份文案），确保"线上跑的就是这句"
test("streamErrorFrame returns readable copy for every known reason", () => {
  const start = API.indexOf("function streamErrorFrame(");
  const end = API.indexOf("\n}\n", start) + 3;
  const src = API.slice(start, end);
  const fn = new Function(src + "; return streamErrorFrame;")();
  const cases = {
    BRAND_PLAN_CONFLICT: "标识编辑方案有冲突",
    TOOL_ARGUMENTS_INCOMPLETE: "写到一半断开",
    TOOL_ARGUMENTS_TOO_LARGE: "内容太多",
    UPSTREAM_STREAM_ERROR: "没有响应完整",
    SOMETHING_ELSE: "没有接收完整",
  };
  for (const [reason, fragment] of Object.entries(cases)) {
    const frame = fn(reason);
    assert.equal(typeof frame.error, "string", `${reason} 的 error 必须是字符串（老客户端会直接 toString）`);
    assert.ok(frame.error.includes(fragment), `${reason} 文案不对：${frame.error}`);
    assert.equal(frame.errorCode, "UPSTREAM_ERROR");
    assert.equal(frame.message, frame.error, "message 与 error 保持一致，供新客户端读取");
    assert.ok(!frame.error.includes(String.fromCharCode(92)), "文案里不能出现反斜杠转义");
  }
});

test("upstream error frames are intercepted instead of relayed", () => {
  assert.ok(API.includes('tag: "upstream_stream_error"'), "缺少上游错误帧日志");
  const start = API.indexOf('tag: "upstream_stream_error"');
  const around = API.slice(Math.max(0, start - 900), start + 400);
  assert.match(around, /if \(!peek \|\| !peek\.error\) continue;/, "没有识别上游 error 帧");
  assert.match(around, /reader\.cancel\(\)/, "识别到上游错误后应中断读取，避免继续把脏帧推给 App");
  assert.match(around, /throw Object\.assign\(new Error\("UPSTREAM_STREAM_ERROR"\)/,
    "拦截后必须转成我们自己的错误，而不是原样转发");
});

test("stream failure keeps the real reason in logs", () => {
  const start = API.indexOf('tag: "chat_stream_incomplete"');
  assert.ok(start > 0, "缺少 chat_stream_incomplete 日志");
  // reason 在 logSafe 之前先算出来，所以窗口要往前多看一点
  const around = API.slice(Math.max(0, start - 320), start + 420);
  assert.match(around, /const reason = String\(\(e && \(e\.code \|\| e\.message\)\)/,
    "日志仍写固定 code，线上无法定位原因");
  assert.match(around, /detail:/, "缺少上游详情字段");
  assert.doesNotMatch(around, /code: "STREAM_OR_TOOL_ARGUMENTS_INCOMPLETE"/,
    "旧的固定 code 仍在，会把真实原因盖掉");
});
