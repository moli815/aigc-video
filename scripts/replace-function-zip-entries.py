"""Build a candidate SCF ZIP from the current online ZIP, replacing only declared files.

The online package remains the base so dependencies and any later live patches
are preserved. Replacement paths must be relative POSIX paths without escapes.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
from zipfile import ZipFile, ZipInfo


def safe(name):
    path = PurePosixPath(name)
    if "\\" in name or path.is_absolute() or ".." in path.parts or ":" in name:
        raise ValueError("unsafe_archive_path")
    return name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before")
    parser.add_argument("candidate")
    parser.add_argument("replacements", help="JSON object: ZIP path -> local file path")
    args = parser.parse_args()
    mapping = {safe(k): Path(v) for k, v in json.loads(Path(args.replacements).read_text(encoding="utf-8")).items()}
    seen = set()
    with ZipFile(args.before) as source, ZipFile(args.candidate, "w") as output:
        for old in source.infolist():
            name = safe(old.filename)
            if name in seen:
                raise ValueError("duplicate_archive_entry")
            seen.add(name)
            data = mapping[name].read_bytes() if name in mapping else source.read(old.filename)
            info = ZipInfo(name, date_time=old.date_time)
            info.compress_type = old.compress_type
            info.external_attr = old.external_attr
            info.internal_attr = old.internal_attr
            info.create_system = old.create_system
            info.comment = old.comment
            output.writestr(info, data)
        for name, local in mapping.items():
            if name in seen:
                continue
            info = ZipInfo(name, date_time=(2026, 11, 10, 21, 0, 0))
            info.compress_type = 8
            info.external_attr = 0o644 << 16
            output.writestr(info, local.read_bytes())
    digest = hashlib.sha256(Path(args.candidate).read_bytes()).hexdigest()
    print(json.dumps({"candidate": args.candidate, "sha256": digest,
                      "changed": sorted(mapping), "new": sorted(set(mapping) - seen)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
