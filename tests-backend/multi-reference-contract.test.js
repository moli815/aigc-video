/**
 * 多附件合成契约（2026-10-28）
 *
 * 事故：用户上传「人物照 + 底图」要求把人物照里的人合成到底图上握手。
 * 结果底图完全正确，人却是个"有点像"的陌生人。
 *
 * 根因不是模型不会合成，是链路只把**一张**附件送进了生图请求：
 * ImageReferenceResolver.resolve 的 attached 分支历史上只返回单张，
 * 而工具 schema 里 both 的描述写着「双图融合（第一张为底图，第二张为叠加素材）」，
 * 与实现（上次生成图 + 一张附件）根本不是一回事 —— 文档骗了 Agent。
 *
 * 本文件锁四件事，任何一条被改回去都会红：
 * 1) schema 必须有 source_indexes / reference_roles，且 both 的描述不得再宣称两张上传图融合；
 * 2) 解析器必须支持多序号，且第一项是底图（顺序契约）；
 * 3) 参数校验必须拒绝 both + source_indexes、角色数量不匹配、重复序号；
 * 4) 服务端必须在多图时把编号与身份保留义务写进 prompt。
 */
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");

const schema = read("BossAI/Services/ToolManifest+Schema.swift");
const resolver = read("BossAI/Services/ImageReferenceResolver.swift");
const argumentsFile = read("BossAI/Services/ImageToolArguments.swift");
const stream = read("BossAI/ViewModels/ChatViewModel+Streaming.swift");
const compassService = read("BossAI/Services/ImageProviderRequestCompiler.swift");
const imageFunction = read("cloudfunctions/bf-image/index.js");

const editSchemaStart = schema.indexOf('"name": "image_edit"');
// image_generate 在文件里定义得更早，不能用它当结尾；按固定窗口截取 image_edit 的参数块。
const editSchema = editSchemaStart >= 0 ? schema.slice(editSchemaStart, editSchemaStart + 7000) : "";

test("image_edit exposes source_indexes and reference_roles", () => {
  assert.ok(editSchema, "找不到 image_edit 参数定义");
  assert.match(editSchema, /"source_indexes"/, "缺少 source_indexes：Agent 无法一次指定多张附件");
  assert.match(editSchema, /"reference_roles"/, "缺少 reference_roles：服务端无法标注哪张是人物");
  assert.match(editSchema, /"name": "image_generate"|source_indexes/);
  assert.match(schema, /"source_indexes"[\s\S]{0,600}第一项必须是底图|第一项必须是底图/,
    "source_indexes 没写清顺序契约（第一项＝底图）");
});

test("both no longer claims to merge two uploaded attachments", () => {
  const bothBlock = editSchema.slice(editSchema.indexOf('"source":'));
  assert.ok(bothBlock.length > 0, "找不到 source 参数");
  assert.doesNotMatch(bothBlock.slice(0, 600), /双图融合/,
    "both 仍宣称双图融合，但实现是「上次生成图 + 一张附件」——文档又一次骗 Agent");
  assert.match(bothBlock.slice(0, 600), /上次生成图|来源图/,
    "both 的语义必须写明是上次生成图 + 一张上传素材");
});

test("resolver supports multiple attachment indices with base first", () => {
  assert.match(resolver, /func resolve\(source: String,\s*attachmentIndices: \[Int\]/,
    "缺少多序号 resolve 入口");
  assert.match(resolver, /static let maxReferences = 6/, "缺少张数上限");
  const multi = resolver.slice(resolver.indexOf("attachmentIndices: [Int]"));
  assert.match(multi, /indices\.map \{ try attachedImage/, "attached 分支仍只取一张");
  assert.match(multi, /case "both":[\s\S]{0,400}\[image, try attachedImage\(at: primary/,
    "both 的旧契约（生成图+一张素材）被改动，Logo 替换流程会断");
});

test("argument validation rejects ambiguous multi-image requests", () => {
  assert.match(argumentsFile, /source_indexes 只能配 source=attached/,
    "缺少 source 与 source_indexes 的互斥校验");
  assert.match(argumentsFile, /source_index 与 source_indexes 只能二选一/,
    "允许单序号与多序号同时出现，会产生歧义");
  assert.match(argumentsFile, /reference_roles（需与 source_indexes 等长/,
    "缺少角色数量校验，服务端会错标人物");
});

test("client sends the ordered references and their roles", () => {
  assert.match(stream, /sourceIndices: \[Int\] = \{[\s\S]{0,300}source_indexes/,
    "客户端没有读取 source_indexes");
  assert.match(stream, /attachmentIndices: sourceIndices/, "仍然按单序号调用解析器");
  assert.match(stream, /referenceRoles: requestedRoles\.count == refs\.count \? requestedRoles : \[\]/,
    "角色张数对不上时应当不发，而不是错标");
});

test("request contract carries reference_roles to the server", () => {
  assert.match(compassService, /body\["reference_roles"\] = referenceRoles/,
    "hosted envelope 没有透出 reference_roles");
});

test("server annotates multi-image input before the user prompt", () => {
  assert.match(imageFunction, /function multiImageContract\(image, referenceRoles, taskKind\)/,
    "缺少多图编号契约");
  assert.match(imageFunction, /const finalPrompt = multiImageContract\(image, referenceRoles, taskKind\)/,
    "多图契约没有被拼进 finalPrompt");
  const contract = imageFunction.slice(imageFunction.indexOf("function multiImageContract"));
  assert.match(contract, /未被用户要求修改的人物身份、发型、服装、产品外观必须保留/,
    "没有禁止用相似但不同的人替代素材人物");
  assert.match(imageFunction, /referenceRoles: body\.reference_roles/,
    "入口没有把 reference_roles 传给 generate");
});
