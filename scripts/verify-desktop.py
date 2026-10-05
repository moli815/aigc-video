from pathlib import Path
import sys,json,subprocess,hashlib,unittest,xml.etree.ElementTree as ET,urllib.parse,time,statistics,zipfile,io,zlib
root=Path(__file__).resolve().parent.parent
app=root;out=root/'TestArtifacts';out.mkdir(exist_ok=True)
results=[]
def log(module,name,kind,ok,detail=''):results.append(dict(module=module,test=name,type=kind,passed=bool(ok),detail=detail))
files=list(app.rglob('*.swift'));syntax=[]
for p in files:
    r=subprocess.run([sys.executable,str(root/'scripts/parse_one_swift.py'),str(p)],capture_output=True,text=True,timeout=15)
    if r.returncode:syntax.append({'file':p.relative_to(app).as_posix(),'error':'parser failed','code':r.returncode})
    else:
        parsed=json.loads(r.stdout)
        if parsed['has_error']:syntax.append({'file':p.relative_to(app).as_posix(),**parsed})
log('全源码','第三方Swift语法树扫描','source',not syntax,syntax)
def source(p):return (app/p).read_text(encoding='utf8')
vm=source('BossAI/ViewModels/ChatViewModel.swift');chat=source('BossAI/Services/ChatService.swift');search=source('BossAI/Services/WebSearchService.swift')
backup=source('BossAI/Services/BackupService.swift');zipcode=source('BossAI/Services/ZipArchive.swift')
checks=[
('联网搜索','时效工具schema与执行入口','"recency"' in chat and 'recency: recency' in vm),
('引用','统一注册编号且无前8条截断','citations.register' in vm and 'unique.prefix(8)' not in vm and 'sourceIDs:' in search),
('流式协议','SSE分帧器接入','sse.consume(line)' in chat and 'line.hasPrefix("data: ")' not in chat),
('流式协议','截断和中断错误保留缓冲','currentTextCommitted ? "" : assistantText' in vm and 'finishReason == "length"' in chat),
('联网搜索','请求体2MB边界及取消','2_097_152' in search and 'try Task.checkCancellation()' in search),
('联网搜索','网页空列保留','guard !value.isEmpty else { continue }' not in search),
('专家','白名单与资料检索完整接通',all('search_library' in source(p) for p in ['BossAI/ExpertCore/ExpertCapabilities.swift','BossAI/Services/ChatService.swift','BossAI/ViewModels/ChatViewModel.swift'])),
('专家','工作台调用可信专家而非自选ID','expertID: expert.id' in source('BossAI/Views/ExpertWorkbenchView.swift')),
('文件导入','共享si及列坐标解析接通','SpreadsheetXMLCore.sharedStrings(xml)' in source('BossAI/Services/FileImportService.swift')),
('文件导入','扫描PDF OCR接通','await extractPDFWithOCR' in source('BossAI/Services/FileImportService.swift')),
('ZIP','raw DEFLATE与CRC校验','-MAX_WBITS' in zipcode and 'Checksum.crc32(result) == entry.crc' in zipcode and 'Checksum.adler32(raw)' not in zipcode),
('备份','校验阶段在写库之前',backup.index('Preflight every referenced blob')<backup.index('transactionContext.insert(conv)')),
('备份','失败回滚新文件','transactionContext.rollback()' in backup and 'for path in createdPaths' in backup),
('备份','严格解码数组而非吞错','try c.decodeIfPresent([ConversationDTO].self' in backup),
('备份','记忆来源保存','source: memory.source' in backup and 'source: dto.source ?? ""' in backup),
('凭证','更新后新增而非先删除','SecItemUpdate' in source('BossAI/Config/KeychainHelper.swift') and 'SecItemDelete(query as CFDictionary)\n        var item' not in source('BossAI/Config/KeychainHelper.swift')),
('语音','启动互斥及独立tap清理','!isStarting, !isRecording' in source('BossAI/Services/SpeechService.swift') and 'if tapInstalled' in source('BossAI/Services/SpeechService.swift')),
('语音','保留草稿并在退出停止','speechDraft + newValue' in source('BossAI/Views/InputBar.swift') and '.onDisappear { speech.stop() }' in source('BossAI/Views/InputBar.swift')),
('主题','六套枚举和语义样式接通','case violet, coral, gold' in source('BossAI/Config/Theme.swift') and '.environment(\\.appTheme' in source('BossAI/BossAIApp.swift')),
('聊天体验','按底部跟随及250ms滚动限频','followOutput && now - lastScrollTime >= 0.25' in source('BossAI/Views/ChatView.swift')),
('预算','按请求记费并保留失败usage','var accounted = true' in vm and 'if !accounted' in vm and 'realPromptTokens' not in vm),
('测试环境','离线验收禁止种子凭证','--acceptance-fixture' in source('BossAI/Config/CredentialStore.swift')),
('编译配置','Swift语言版本合法', 'SWIFT_VERSION: "5.9"' not in source('project.yml') and 'SWIFT_VERSION: "5.0"' in source('project.yml')),
]
checks.extend([
('联网搜索','Tavily服务端时间过滤', 'body["time_range"] = recency.rawValue' in search and 'filter_by_published_date' in search),
('联网搜索','博查服务端freshness', '"freshness": freshness[recency]' in search),
('联网搜索','验证页识别', 'html.count < 20000' in search and 'captcha' in search),
('Markdown','表格可读且不丢额外列', 'case table([[String]])' in source('BossAI/Views/MarkdownView.swift') and 'prefix(columns)' not in source('BossAI/Views/MarkdownView.swift')),
('测试环境','离线内存数据库', 'inMemory: ProcessInfo.processInfo.arguments.contains("--performance-fixture")' in source('BossAI/BossAIApp.swift')),
('备份','隔离数据库上下文', 'ModelContext(context.container)' in backup and 'transactionContext.rollback()' in backup),
('渲染性能','有限Markdown缓存','cache.totalCostLimit = 2 * 1024 * 1024' in source('BossAI/Views/MarkdownView.swift')),
('长期记忆','查看来源','来源对话：' in source('BossAI/Views/IdentitySheet.swift')),
])
for module,name,ok in checks:log(module,name,'source',ok)

# These tests exercise Python replicas, not the Swift implementations.
class SSE:
    def __init__(self):self.lines=[];self.size=0
    def feed(self,line):
        line=line.removesuffix('\r')
        if line=='':
            result='\n'.join(self.lines) if self.lines else None;self.lines=[];self.size=0;return result
        if line.startswith(':'):return None
        pieces=line.split(':',1)
        if pieces[0]!='data':return None
        value=pieces[1] if len(pieces)>1 else ''
        if value.startswith(' '):value=value[1:]
        self.size+=len(value.encode())
        if self.size>1048576:raise ValueError('limit')
        self.lines.append(value)
def canonical(url):
    s=urllib.parse.urlsplit(url)
    items=[x for x in urllib.parse.parse_qsl(s.query) if not x[0].lower().startswith('utm_') and x[0].lower() not in ['spm','fbclid']]
    return urllib.parse.urlunsplit((s.scheme,s.netloc.lower(),s.path,urllib.parse.urlencode(items),'')).rstrip('?')
def cells(line):
    values=[];value='';escape=False;code=False
    for ch in line:
        if escape:value+=ch;escape=False;continue
        if ch=='\\':escape=True;continue
        if ch=='`':code=not code;value+=ch;continue
        if ch=='|' and not code:values.append(value.strip());value=''
        else:value+=ch
    if escape:value+='\\'
    values.append(value.strip())
    if line.strip().startswith('|'):values=values[1:]
    if line.strip().endswith('|'):values=values[:-1]
    return values
def fixture(name,module,fn):
    try:fn();log(module,name,'Python逻辑复刻',True)
    except Exception as exc:log(module,name,'Python逻辑复刻',False,repr(exc))
def eq(a,b):
    if a!=b:raise AssertionError(f'{a!r} != {b!r}')
def raises(fn):
    try:fn()
    except Exception:return
    raise AssertionError('Expected rejection')
def sse_multiline():
    s=SSE();eq(s.feed(':ping'),None);eq(s.feed('data:{'),None);eq(s.feed('data:"a":1}'),None);eq(s.feed(''),'{\n"a":1}')
fixture('无空格多行SSE','流式协议',sse_multiline)
fixture('SSE事件上限','流式协议',lambda:raises(lambda:SSE().feed('data:'+'x'*1048577)))
fixture('URL跟踪参数去重','引用',lambda:eq(canonical('https://example.com/a?utm_source=q#x'),canonical('https://example.com/a')))
fixture('转义管道/代码/空列','办公文档',lambda:eq(cells(r'| A\|B | | `x|y` |'),['A|B','','`x|y`']))
fixture('查询参数特殊字符不注入','联网搜索',lambda:eq(urllib.parse.parse_qs('q='+urllib.parse.quote('A&B + C#政策?',safe='')),{'q':['A&B + C#政策?']}))
fixture('稀疏列夹具结构','文件导入',lambda:eq([e.attrib['r'] for e in ET.fromstring('<row><c r="A1"/><c r="C1"/></row>')],['A1','C1']))
fixture('共享字符串富文本夹具','文件导入',lambda:eq([''.join(e.itertext()) for e in ET.fromstring('<sst><si><r><t>第一</t></r><r><t>条</t></r></si><si><t>第二</t></si></sst>')],['第一条','第二']))
fixture('raw DEFLATE真实Python压缩/解压','ZIP',lambda:eq(zlib.decompress(zlib.compress(b'fixture'*100)[2:-4],-15),b'fixture'*100))
fixture('损坏压缩流拒绝','ZIP',lambda:raises(lambda:zlib.decompress(b'bad',-15)))
fixture('公式单位经济确定样本','专家',lambda:eq((100-60)*50-1000,1000))
fixture('营销漏斗期望订单','专家',lambda:eq(100000*.01*.1,100.0))
fixture('增发股权比例','专家',lambda:eq(20/(100+25),.16))
fixture('现金续航','专家',lambda:eq(1000/(100-20),12.5))
fixture('提成报酬','专家',lambda:eq(5000+10000*.1,6000))
fixture('演讲预计时长','专家',lambda:eq(1200/200+60/60,7))

# Verify form field sets exactly match the actual Swift calculator contract.
workbench=source('BossAI/Views/ExpertWorkbenchView.swift')
import re
contracts={
'unit_economics':{'unit_price','unit_variable_cost','period_fixed_cost','period_quantity'},
'marketing_funnel':{'impressions','click_rate','order_rate','average_order_value','ad_spend','contribution_per_order'},
'equity_dilution':{'existing_total_shares','owner_shares','new_shares'},
'cash_runway':{'available_cash','monthly_cash_inflow','monthly_cash_outflow'},
'commission':{'base_pay','eligible_revenue','commission_rate'},
'speech_duration':{'character_count','characters_per_minute','pause_seconds'}}
for name,expected in contracts.items():
    match=re.search(r'case "'+name+r'": return \[(.*?)\]',workbench)
    actual=set(re.findall(r'\("([^"]+)"',match.group(1))) if match else set()
    log('专家工作台','表单字段与计算器契约一致：'+name,'source',actual==expected,{'actual':sorted(actual),'expected':sorted(expected)})

# Desktop performance is measured only for the replica, never labeled as iOS.
timings=[]
for _ in range(30):
    start=time.perf_counter_ns();s=SSE()
    for _ in range(10000):s.feed('data: {"choices":[]}');s.feed('')
    timings.append((time.perf_counter_ns()-start)/1e6)
perf={'scope':'Windows/Python SSE逻辑复刻10000事件，非Swift性能/非iOS性能',
      'samples':30,'median_ms':statistics.median(timings),'p95_ms':sorted(timings)[28],'max_ms':max(timings)}
native_tests=sum(len(re.findall(r'func test\w+\(',p.read_text(encoding='utf8'))) for p in (app/'Tests').rglob('*.swift'))
report={'source_tree':app.name,'swift_files':len(files),'native_test_cases_written':native_tests,'native_test_execution':'未执行；Windows无Swift SDK与Xcode，当前没有可连接macOS环境',
        'syntax_errors':syntax,'checks':results,'desktop_replica_benchmark':perf,'passed':sum(x['passed'] for x in results),'total':len(results)}
(out/'BossAI-本轮修复-验证记录.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps({k:report[k] for k in ['swift_files','native_test_cases_written','syntax_errors','passed','total','desktop_replica_benchmark']},ensure_ascii=False))
if not all(x['passed'] for x in results):raise SystemExit(1)
