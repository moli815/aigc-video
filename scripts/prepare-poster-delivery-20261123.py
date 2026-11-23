"""Create only local candidates from the reviewed 11-23 production backups."""
from pathlib import Path
from zipfile import ZipFile
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'outputs/generation-pipeline-review-20261123'
SOURCE = ROOT / 'cloudfunctions'


def decoded(data):
    return data.decode('utf-8').replace('\r\n', '\n')


def reviewed_slice(source, start, end):
    left, tail = source.split(start, 1)
    middle, right = tail.split(end, 1)
    return left, start + middle, end + right


def api_index(online, local):
    for start, end in [
        ('    if (!REFERENCE_CONTRACT_CODES.has(code))', '    logSafe({ tag: "image_contract_recovered"'),
        ('      // 缓冲里是工具调用标签', '      streamCompleted = true;'),
    ]:
        left, _, right = reviewed_slice(online, start, end)
        _, reviewed, _ = reviewed_slice(local, start, end)
        online = left + reviewed + right
    if online != local:
        raise ValueError('Unexpected API index change outside reviewed branches')
    return online


def image_index(online, local):
    # Preserve all shipped sections outside the reviewed prompt compiler.
    start = '  const rawPrompt = String(cleanedPrompt.prompt || "").trim();'
    end = '  // 2026-11-22：客户端没给 aspect_ratio 时'
    left, online_slice = online.split(start, 1)
    local_left, local_slice = local.split(start, 1)
    _, right = online_slice.split(end, 1)
    local_slice, local_right = local_slice.split(end, 1)
    if left != local_left or right != local_right:
        raise ValueError('Unexpected image index changes outside prompt compilation')
    return left + start + local_slice + end + right


for function in ('bf-api', 'bf-image'):
    before = OUT / ('before-' + function + '.zip')
    candidate = OUT / ('candidate-' + function + '.zip')
    if candidate.exists():
        raise FileExistsError(candidate)
    with ZipFile(before) as shipped:
        def archived(name):
            return decoded(shipped.read(name))

        def local(name):
            return decoded((SOURCE / function / name).read_bytes())

        files = {'shared/poster-delivery.js': local('shared/poster-delivery.js')}
        if function == 'bf-api':
            files['intent-contract.js'] = local('intent-contract.js')
            files['tool-tag-parser.js'] = local('tool-tag-parser.js')
            files['index.js'] = api_index(archived('index.js'), local('index.js'))
            files['domains/foundation.js'] = local('domains/foundation.js')
            files['image-series-reference-guidance.js'] = local('image-series-reference-guidance.js')
            source = archived('shared/image-delivery.js')
            normalizer = local('shared/image-delivery.js')
            for anchor, next_line in (
                ('function normalizeVisibleCopy(value) {\n  if(Array.isArray(value)){\n', '    if(value.some'),
                ('  if (!value || Array.isArray(value) || typeof value !== "object") return value;\n', '  // Legacy LLMs'),
            ):
                assert source.count(anchor) == 1
                addition = normalizer.split(anchor, 1)[1].split(next_line, 1)[0]
                source = source.replace(anchor, anchor + addition, 1)
            files['shared/image-delivery.js'] = source
        else:
            files['index.js'] = image_index(archived('index.js'), local('index.js'))
            files['shared/poster-reformat.js'] = local('shared/poster-reformat.js')
    mapping = {}
    for name, content in files.items():
        dest = OUT / 'reviewed-changes' / function / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(content.encode('utf-8'))
        mapping[name] = str(dest)
    spec = OUT / ('changes-' + function + '.json')
    spec.write_text(json.dumps(mapping), encoding='utf-8')
    subprocess.run([sys.executable, str(ROOT / 'scripts/replace-function-zip-entries.py'), str(before), str(candidate), str(spec)], check=True, capture_output=True)
    subprocess.run([sys.executable, str(ROOT / 'scripts/check-function-artifact.py'), str(before), str(candidate), '--output', str(OUT / ('gate-' + function + '.json')),
                    *[item for name in mapping for item in ('--allow', name)]], check=True, capture_output=True)
    with ZipFile(candidate) as package:
        package.extractall(OUT / 'candidate-load' / function)
    print(function, sorted(files))
