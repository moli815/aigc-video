"""Render recorded evaluation evidence. Never invokes models or cloud services."""
import argparse
import html
import json
import pathlib
import statistics

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = ROOT / 'outputs/complex-image-eval-20261104'
REVIEWS = ROOT / 'tests-fixtures/complex-image-review-20261104.json'
OUTPUT = ROOT / 'outputs/BossAI-复杂场景与长上下文生图验收-20261104.html'


def h(value):
    return html.escape(str(value))


def link(folder, file):
    # Only local files produced by this evaluation may enter the report.
    target = (folder / file).resolve()
    target.relative_to(BASE.resolve())
    assert target.is_file(), target
    return h(target.relative_to(OUTPUT.parent).as_posix())


def render():
    reviews = json.loads(REVIEWS.read_text(encoding='utf-8'))['cases']
    runs = []
    for folder in sorted(BASE.glob('run-*')):
        data = json.loads((folder / 'report.json').read_text(encoding='utf-8'))
        assert data['status'] != 'running', f'Wait for {folder.name} to complete'
        runs.append((folder, data))
    assert runs
    attempts = {}
    ledger = []
    for folder, data in runs:
        ledger.extend(data.get('ledger', []))
        for row in data['cases']:
            attempts.setdefault(row['id'], []).append((folder, row))
    images = [(p, c) for p, r in runs for c in r['cases'] if c.get('imageFile')]
    times = [r['imageMs'] / 1000 for _, r in images]
    supplier_estimate = sum(r.get('supplierCostEstimateCny') or 0 for r in ledger)
    cards, rows, aggregate = [], [], []
    for ident in sorted(attempts):
        history = attempts[ident]
        folder, first = history[0]
        review = reviews[ident]
        image_attempts = [(p, r) for p, r in history if r.get('imageFile')]
        p, latest = image_attempts[-1] if image_attempts else history[-1]
        result = '负对照通过' if ident.startswith('G-') else '未通过商业交付'
        rows.append(f'<tr><td><a href="#{h(ident)}">{h(first["name"])}</a></td>'
                    f'<td>{first["sourceMessages"]} → {first["retainedMessages"]}</td>'
                    f'<td>{first["sourceTextChars"]:,} / {first["sentTextChars"]:,}</td>'
                    f'<td>{"人工摘要夹具" if first["memoryInjected"] else "无摘要夹具"}</td>'
                    f'<td>{latest.get("copyChars", "—")}</td><td>{h(result)}</td></tr>')
        media = (f'<a href="{link(p,latest["imageFile"])}" target="_blank"><img loading="lazy" '
                 f'src="{link(p,latest["imageFile"])}" alt="{h(first["name"])}，点击看原尺寸"></a>') if image_attempts else ''
        findings = ''.join(f'<li>{h(s)}</li>' for s in review['findings'])
        attempts_html = ''
        for i, (fp, item) in enumerate(history, 1):
            diagnostic = '；新增格式提示的诊断轮' if item.get('contractDiagnostic') else ''
            evidence = f'<a href="{link(fp,item["inputFile"])}">对话输入</a>'
            for suffix, label in [('-plan.json', '定稿参数'), ('-ocr.json', '本机OCR')]:
                filename = ident + suffix
                if (fp / filename).is_file():
                    evidence += f' · <a href="{link(fp,filename)}">{label}</a>'
            attempts_html += f'<p>第{i}轮{diagnostic}：{h(item["status"])} · {evidence}</p>'
            if item.get('error'):
                attempts_html += f'<p class="warn">{h(item["error"])}</p>'
        image_time = f'{latest["imageMs"]/1000:.1f}秒' if latest.get('imageMs') else '未进入生图或无产物'
        cards.append(f'<article id="{h(ident)}" data-category="{h(review["category"])}">'
                     f'<div class="eyebrow">{h(ident)} · {h(review["category"])} · {h(result)}</div>'
                     f'<h2>{h(first["name"])}</h2><p class="verdict">{h(review["conclusion"])}</p>{media}'
                     f'<ul>{findings}</ul><p class="muted">图像请求耗时 {image_time}；{len(history)}轮记录。'
                     f'每轮规划和产物分别保存，未覆盖失败。</p><details><summary>证据与完整定稿</summary>{attempts_html}'
                     f'<pre>{h(latest.get("copy") or latest.get("responseText") or "未获得有效定稿")}</pre>'
                     f'<p>实际模型：{h(latest.get("imageModel", "未生图"))}；路由：{h(latest.get("route", "—"))}</p>'
                     '</details></article>')
        aggregate.append({'id': ident, 'review': review, 'attempts': [
            {'folder': fp.relative_to(OUTPUT.parent).as_posix(), **item} for fp, item in history]})
    summary = {
        'status': 'manually_reviewed_not_accepted_for_commercial_delivery',
        'scope': runs[0][1]['scope'], 'imageCount': len(images),
        'imageLatencySeconds': {'min': min(times), 'max': max(times), 'median': statistics.median(times)},
        'supplierCostEstimateCny': supplier_estimate,
        'estimateIsNotInvoice': True, 'cases': aggregate,
        'allTemporaryAccountsAndAssetsDeleted': all(r.get('temporaryAccountAndAssetsDeleted') for _, r in runs)
    }
    json_path = OUTPUT.with_suffix('.json')
    json_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    template = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>BossAI 复杂商业生图与长上下文验收</title><style>
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:#111720;color:#e5eaf1;font:15px/1.8 "Microsoft YaHei",sans-serif}main{max-width:1560px;margin:auto;padding:28px}header,.panel,article{background:#1a2431;border:1px solid #344458;border-radius:14px;padding:24px;margin-bottom:22px}header{border-top:3px solid #72baff}h1{font-size:27px;margin:0 0 10px}h2{font-size:20px;margin:7px 0 12px}h3{font-size:17px}p{margin:10px 0}a{color:#92cbff}.muted,.eyebrow{color:#b0c0d3}.verdict{color:#ffdc9b}.warn{color:#ffb5a9}ul{padding-left:22px}li{margin:10px 0}table{width:100%;border-collapse:collapse;text-align:left;font-size:14px}td,th{padding:13px 12px;border-bottom:1px solid #344458;vertical-align:top}th{color:#b0c0d3}.table-scroll{overflow-x:auto}.metrics{display:flex;flex-wrap:wrap;gap:14px;margin:18px 0}.metric{min-width:180px;background:#111b28;padding:14px 18px;border-radius:10px}.metric strong{display:block;font-size:22px;color:#b9dcff}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:22px}article{margin:0;min-width:0;scroll-margin-top:20px}img{display:block;width:100%;height:560px;object-fit:contain;background:#0c121a;border-radius:8px;margin:18px 0}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#111a26;padding:16px;font:13px/1.9 "Microsoft YaHei",sans-serif;max-height:700px;overflow:auto}summary{cursor:pointer;color:#b9dcff}.filters{display:flex;flex-wrap:wrap;gap:10px;margin:20px 0}button{padding:9px 18px;background:#202f42;border:1px solid #48617f;color:#e9f0f8;border-radius:8px;font:inherit;cursor:pointer}button[aria-pressed=true]{background:#305678;border-color:#86b7df}.note{border-left:3px solid #dfaf69;padding-left:16px}footer{padding:22px;color:#b0c0d3}@media(max-width:900px){main{padding:14px}.grid{grid-template-columns:1fr}header,.panel,article{padding:18px}img{height:500px}h1{font-size:23px}}
</style><main><header><div class="eyebrow">2026-11-04 · 真实已部署服务 · 合成业务资料</div><h1>复杂商业生图与长上下文：压力测试验收</h1>
<p class="verdict">信息量加上去了，但这些成品仍不能按商业交付验收。主要缺口分别在历史裁剪、前置文案、工具参数和原生文字成图。</p>
<div class="metrics"><div class="metric"><strong>6类复杂场景</strong>另加1类缺记忆负对照</div><div class="metric"><strong>__IMAGES__张真实成图</strong>均为Seedream 5.0 Pro</div><div class="metric"><strong>最长67条原始消息</strong>旧App策略裁为最近40条</div><div class="metric"><strong>最长53,391字符</strong>原始业务与干扰上下文</div></div>
<p>重放旧App的最近40条 / 正文48,000字符选择；再加入实际客户端设计指导与线上服务端规则。六种场景要求约650–1200字符、多个实质信息区，规划稿实际852–1397字符。资料含价格更正、风格改口、其他客户干扰、早期字段、引用指令与带错字的参考图。</p>
<p class="note">这是接口组件联调，不是iOS真机验收。B/D的早期资料来自人工摘要夹具；G的空检索也是固定夹具；不代表真实长期记忆已通过。工具集是用于本轮的精简重放，不是完整App系统提示/全部工具。原生文字路径未覆盖UIKit排字；F使用完整参考图，而不是旧App的压缩预览。</p>
</header><section class="panel"><h2>覆盖与结果</h2><p class="muted">“原始 / 发送字符”后者含设计系统提示与摘要，不能当作正文同一预算；消息数只统计正文历史。</p><div class="table-scroll"><table><thead><tr><th>场景</th><th>原始→保留消息</th><th>原始 / 发送字符</th><th>早期信息</th><th>规划字符</th><th>人工验收</th></tr></thead><tbody>__ROWS__</tbody></table></div></section>
<section class="panel"><h2>这次证据说明什么</h2><ul>
<li><b>上下文丢失确实存在。</b>B的产品名/指定标题在裁剪之前存在，发送时已丢失；摘要保住价格却没有保住身份字段。摘要需要按任务保留不可替换的确认事实，不能只保留大意。</li>
<li><b>并非全是记忆问题。</b>A/C/F的规划稿里有正确字段，最终像素却写错热线、术语或责任人。增强前置提示不能单独解决原生中文文字可靠性。</li>
<li><b>复杂内容不能只靠多写字。</b>生成稿出现超预算、无依据部署选项、引用图文字污染，以及不自然业务表达。几何合规和关键字存在都不等于内容正确。</li>
<li><b>参数失败尚未解决。</b>D原条件连续两次502，第三轮只加强JSON格式后出图，诊断单列保留；成图的产品名与kWh单位仍有错误。现有日志不足以识别具体拒绝字段，不能假装已经找到唯一根因。</li>
<li><b>缺资料时表现较好。</b>G先检索、查不到再询问，没有猜早期客户和授权码；但这是负对照，不是记忆召回率。</li>
</ul></section><section class="panel"><h2>下一步修复优先级（本轮未上线）</h2><div class="table-scroll"><table><thead><tr><th>优先级</th><th>模块边界与动作</th><th>如何验收 / 限制</th></tr></thead><tbody>
<tr><td>P0</td><td>工具边界记录安全错误分类/字段路径，区分供应商完成与客户端可交付；在拒绝完整性后有限次数重新编译参数。</td><td>不记录客户原文/密钥；畸形JSON、嵌套文案、缺字段和断流分别回归；不能反复付费作图或放过错误结构。</td></tr>
<tr><td>P0</td><td>设计简报层保留已确认公司/产品/标题/电话/报价/规格/责任人，注明版本与资料出处；拿不到就召回或询问。</td><td>B同套历史需恢复产品与标题；D不混其他客户；只能恢复已经同步的资料，服务端不能凭空找回旧App未发送的内容。</td></tr>
<tr><td>P0</td><td>成品校验层识别电话、型号、价格和表格对应；精确文字任务可适配服务端确定性文字层与安全留白底图。</td><td>A/F电话逐字一致、C术语/责任映射一致；OCR仅作候选差异，人审复核误报。排字需要独立渲染与视觉回归，不能覆盖旧海报文字。</td></tr>
<tr><td>P1</td><td>文案校验区分用户事实、建议设计、引用图字样与其他项目笔记；控制重复及单页信息预算。</td><td>不臆造套餐能力，不沿用参考图错字；不靠删除用户必要信息掩盖文字问题。</td></tr>
</tbody></table></div></section>
<div class="filters" aria-label="样例筛选"><button data-filter="全部" aria-pressed="true">全部样例</button><button data-filter="文字" aria-pressed="false">文字成图</button><button data-filter="上下文" aria-pressed="false">上下文与内容</button><button data-filter="接口" aria-pressed="false">接口失败</button><button data-filter="对照" aria-pressed="false">负对照</button></div><section class="grid">__CARDS__</section>
<section class="panel" style="margin-top:22px"><h2>耗时、账目与证据边界</h2><p>图像接口返回耗时__TIMES__；包含服务端处理与上游等待，不是纯模型推理耗时。规划耗时和每次请求编号保存在详细JSON。</p><p>本轮全部台账记录供应商成本估算合计约¥__COST__，包含规划/内部辅助调用/图片与失败规划；不是平台实结账单。上下文token与图片计量不混加为“文本token”。本轮全部使用显式Pro，没有比较Flash或固定seed。</p><p>先前提出补4K对照，核对官方后撤回：当前Seedream 5.0 Pro支持1K/1.5K/2K，不能虚构同模型4K结果。本轮已用2K。参见<a href="https://docs.volcengine.com/docs/ark/image-generation-tutorial?lang=zh">火山官方能力与分辨率对比表</a>（2026-11-04核对）。</p><p>没有修改或部署生产逻辑、客户额度、提示配置、员工端或App包。__CLEANUP__。不能由这组单次样例推导总体故障率，也不声称达到ChatGPT同等质量。</p><p><a href="__JSON__">下载完整汇总JSON</a> · 每个样例可展开原始/实际发送对话、规划与本机OCR证据。OCR的序列匹配值受阅读顺序/识别错误影响，本报告不把它当作文字准确率。</p></section><footer>保留失败，分开评价意图、资料、参数、成图和交付；生成成功不等于验收成功。</footer></main><script>document.querySelectorAll('[data-filter]').forEach(b=>b.addEventListener('click',()=>{document.querySelectorAll('[data-filter]').forEach(x=>x.setAttribute('aria-pressed',String(x===b)));document.querySelectorAll('article[data-category]').forEach(a=>a.hidden=b.dataset.filter!=='全部'&&a.dataset.category!==b.dataset.filter)}));</script></html>'''
    replacements = {'__IMAGES__': str(len(images)), '__ROWS__': ''.join(rows), '__CARDS__': ''.join(cards),
                    '__TIMES__': f'{min(times):.1f}–{max(times):.1f}秒，中位数{statistics.median(times):.1f}秒',
                    '__COST__': f'{supplier_estimate:.4f}', '__JSON__': h(json_path.name),
                    '__CLEANUP__': '临时测试账号和云端素材已删除，台账审计保留' if summary['allTemporaryAccountsAndAssetsDeleted'] else '存在尚未完成的临时资源清理，需检查原始报告'}
    for key, value in replacements.items():
        template = template.replace(key, value)
    OUTPUT.write_text(template, encoding='utf-8')
    print(json.dumps({'file': str(OUTPUT), 'images': len(images), 'supplierCostEstimateCny': supplier_estimate}, ensure_ascii=False))


if __name__ == '__main__':
    argparse.ArgumentParser(description=__doc__).parse_args()
    render()
