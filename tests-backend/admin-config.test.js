/**
 * 管理端配置页静态契约测试（node --test）
 *
 * 管理端是单文件静态页，没有前端构建/测试框架。这里用源码级断言锁住
 * 本次重构的关键行为，防止回退：
 *   · 不再在前端重复维护 CFG_GROUPS（分组由后端下发）
 *   · 保存只在当前分区容器内读取输入（旧版全页 querySelector 会读错分组的同名字段）
 *   · 密钥使用密码输入、不再回填掩码
 *   · 只提交变更 + 乐观并发 + 历史回滚
 */
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const html = fs.readFileSync(path.join(__dirname, "../web/admin.html"), "utf8");

test("前端不再声明 CFG_GROUPS，分组改由后端下发", () => {
  assert.ok(!/var\s+CFG_GROUPS\s*=/.test(html), "CFG_GROUPS 已废弃，分组必须来自 /admin/settings");
  assert.ok(/CFG_SECTIONS/.test(html), "缺少后端 sections 的消费逻辑");
});

test("保存只在当前分区容器内读取输入（P0 修复）", () => {
  assert.ok(
    !/document\.querySelector\(\s*['"]#tab4 input\[data-k/.test(html),
    "仍在使用全页面 querySelector 读取配置输入，会读错分组里的同名字段"
  );
  assert.ok(/closest\(\s*['"]details['"]\s*\)/.test(html), "collectSection 必须在当前分区 details 内查询");
});

test("密钥使用密码输入且不回填掩码", () => {
  assert.ok(/type="password"/.test(html), "密钥字段必须是 password 输入");
  assert.ok(/留空不修改/.test(html), "缺少『留空不修改』提示");
  assert.ok(!/value="'\+\s*esc\(s\.value\)[\s\S]{0,80}type="password"/.test(html), "密码框不应回填掩码值");
});

test("只提交变更字段 + 乐观并发", () => {
  assert.ok(/collectSection/.test(html));
  assert.ok(/baseUpdatedAt/.test(html), "缺少乐观并发版本号，可能静默覆盖他人修改");
  assert.ok(/Object\.keys\(patch\)\.length/.test(html), "缺少『无变更不提交』判断");
});

test("渲染分组说明、来源与高风险提示", () => {
  assert.ok(/sec\.desc/.test(html), "分组 desc 必须展示");
  assert.ok(/fmtSource/.test(html), "缺少生效来源展示");
  assert.ok(/高风险/.test(html), "高风险配置需要有提示");
});

test("提供配置历史与回滚", () => {
  assert.ok(/settings\/rollback/.test(html), "缺少回滚接口调用");
  assert.ok(/cfgHistory/.test(html), "缺少历史面板");
  assert.ok(/CFG_SNAPS/.test(html), "缺少快照状态");
});

test("控件按类型分流（number/enum/toggle/textarea/password）", () => {
  for (const w of ["toggle", "enum", "textarea", "password", "number"]) {
    assert.ok(new RegExp(`widget==='${w}'`).test(html), `缺少 ${w} 控件分支`);
  }
});
