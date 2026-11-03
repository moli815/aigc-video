"""Check a CloudBase ZIP against its rollback ZIP without unpacking or deploying.

Allow each intended business file with --allow PATH. Dependency changes fail
closed unless their exact paths are also allowed. No credentials or source text
are emitted in the report.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
from zipfile import ZipFile, BadZipFile


def inventory(filename):
    result = {}
    with ZipFile(filename) as archive:
        for entry in archive.infolist():
            name = entry.orig_filename
            path = PurePosixPath(name)
            if "\\" in name or path.is_absolute() or ".." in path.parts or ":" in name:
                raise ValueError("unsafe_archive_path")
            if entry.is_dir():
                continue
            if name in result:
                raise ValueError("duplicate_archive_entry")
            result[name] = hashlib.sha256(archive.read(entry)).hexdigest()
    return result


def compare(before, candidate, allowed):
    old, new = inventory(before), inventory(candidate)
    changed = sorted(name for name in old.keys() | new.keys() if old.get(name) != new.get(name))
    unexpected = [name for name in changed if name not in allowed]
    missing = [name for name in ("index.js", "package.json", "scf_bootstrap") if name not in new]
    return {
        "ok": not unexpected and not missing,
        "beforeSha256": hashlib.sha256(Path(before).read_bytes()).hexdigest(),
        "candidateSha256": hashlib.sha256(Path(candidate).read_bytes()).hexdigest(),
        "changed": changed,
        "unexpected": unexpected,
        "missingRuntimeFiles": missing,
        "dependencyChanges": [name for name in changed if name.startswith("node_modules/")],
        "beforeFileCount": len(old),
        "candidateFileCount": len(new),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before")
    parser.add_argument("candidate")
    parser.add_argument("--allow", action="append", default=[])
    parser.add_argument("--output")
    args = parser.parse_args()
    try:
        report = compare(args.before, args.candidate, set(args.allow))
    except (ValueError, OSError, BadZipFile) as error:
        report = {"ok": False, "error": type(error).__name__}
    result = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        Path(args.output).write_text(result + "\n", encoding="utf-8")
    print(result)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
