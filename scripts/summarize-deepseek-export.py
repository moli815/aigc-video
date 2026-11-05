"""Validate a single-key DeepSeek export; never emit raw keys or provider user IDs."""
import argparse
import csv
from decimal import Decimal
import hashlib
import io
import json
from pathlib import Path
from zipfile import ZipFile


def summarize(filename):
    blob = Path(filename).read_bytes()
    with ZipFile(io.BytesIO(blob)) as archive:
        names = archive.namelist()
        def rows(prefix):
            matching = [n for n in names if Path(n).name.startswith(prefix) and n.endswith('.csv')]
            if len(matching) != 1:
                raise ValueError('Expected exactly one cost CSV and one amount CSV')
            return list(csv.DictReader(io.StringIO(archive.read(matching[0]).decode('utf-8-sig'))))
        costs, amounts = rows('cost-'), rows('amount-')
    keys = {(r['api_key_name'], r['api_key']) for r in amounts}
    if len(keys) != 1 or not costs or not amounts:
        raise ValueError('Only single-key exports are supported')
    alias, masked = next(iter(keys))
    if alias != 'boss AI' or not (masked.startswith('sk-340ea') and masked.endswith('9e2a')):
        raise ValueError('Export does not match the requested key')
    buckets = {}
    def bucket(r):
        key = (r['start_time_iso'], r['end_time_iso'], r['model'])
        return buckets.setdefault(key, {'start': key[0], 'end': key[1], 'model': key[2],
            'costUnits': 0, 'calculatedUnits': Decimal(0), 'requestCount': 0,
            'inputTokens': 0, 'cachedInputTokens': 0, 'outputTokens': 0})
    for r in costs:
        if r['currency'] != 'CNY' or r['wallet_type'] != 'Paid':
            raise ValueError('Unsupported currency or wallet type')
        value = Decimal(r['cost']) * 100000000
        if value != value.to_integral_value() or value < 0:
            raise ValueError('Invalid cost precision')
        bucket(r)['costUnits'] += int(value)
    for r in amounts:
        b = bucket(r)
        amount = Decimal(r['amount'])
        if amount < 0 or amount != amount.to_integral_value():
            raise ValueError('Invalid usage quantity')
        amount = int(amount)
        field = {'request_count': 'requestCount', 'input_cache_miss_tokens': 'inputTokens',
                 'input_cache_hit_tokens': 'cachedInputTokens', 'output_tokens': 'outputTokens'}.get(r['type'])
        if not field:
            raise ValueError('Unrecognized usage metric')
        b[field] += amount
        if r['price']:
            b['calculatedUnits'] += Decimal(r['price']) * amount * 100000000
    result = []
    for b in sorted(buckets.values(), key=lambda b: (b['start'], b['model'])):
        if b.pop('calculatedUnits') != b['costUnits']:
            raise ValueError('Cost and metered usage do not reconcile')
        b['inputTokens'] += b['cachedInputTokens']
        result.append(b)
    return {'schemaVersion': 1, 'provider': 'deepseek', 'keyAlias': alias,
        'keyMasked': 'sk-340ea…9e2a', 'sourceDigest': hashlib.sha256(blob).hexdigest(),
        'sourceFile': Path(filename).name, 'granularity': 'vendor_key_daily', 'rows': result}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('archive')
    parser.add_argument('output')
    args = parser.parse_args()
    report = summarize(args.archive)
    Path(args.output).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'days': len({r['start'][:10] for r in report['rows']}), 'rows': len(report['rows']),
        'costCny': str(Decimal(sum(r['costUnits'] for r in report['rows'])) / 100000000),
        'requests': sum(r['requestCount'] for r in report['rows']),
        'tokens': sum(r['inputTokens'] + r['outputTokens'] for r in report['rows'])}))
