"""Check a CloudBase ZIP against its rollback ZIP without unpacking or deploying.

Allow each intended business file with --allow PATH. Dependency changes fail
closed unless their exact paths are also allowed. No credentials or source text
are emitted in the report.
"""
import argparse
import hashlib
import json
import posixpath
import re
from pathlib import Path, PurePosixPath
from zipfile import ZipFile, BadZipFile


def missing_local_modules(filename):
    """Resolve literal CommonJS relative imports in application JS, not vendors.

    This is a static package check, not a replacement for loading the entrypoint.
    Dynamic expressions and external packages still require the load smoke test.
    """
    missing = []
    with ZipFile(filename) as archive:
        names = set(archive.namelist())

        def resolves(name, seen=None):
            seen = set() if seen is None else seen
            if name in seen:
                return False
            seen.add(name)
            if any(p in names for p in (name, name + '.js', name + '.json', name + '.node')):
                return True
            package = name + '/package.json'
            if package in names:
                manifest = json.loads(archive.read(package))
                main = manifest.get('main')
                if isinstance(main, str) and resolves(posixpath.normpath(posixpath.join(name, main)), seen):
                    return True
            return any(name + '/index' + ext in names for ext in ('.js', '.json', '.node'))

        for filename in sorted(names):
            if not filename.endswith(('.js', '.cjs')) or filename.startswith('node_modules/'):
                continue
            source = archive.read(filename).decode('utf-8', errors='replace')
            for match in re.finditer(r'''\brequire\s*\(\s*(['"])(\.{1,2}/[^'"\r\n]+)\1\s*\)''', source):
                request = match.group(2)
                name = posixpath.normpath(posixpath.join(posixpath.dirname(filename), request))
                if not resolves(name):
                    missing.append({'from': filename, 'request': request})
    return missing


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


def compare(before, candidate, allowed, kind="http"):
    old, new = inventory(before), inventory(candidate)
    changed = sorted(name for name in old.keys() | new.keys() if old.get(name) != new.get(name))
    unexpected = [name for name in changed if name not in allowed]
    required = ("index.js", "package.json", "scf_bootstrap") if kind == "http" else ("index.js", "package.json")
    missing = [name for name in required if name not in new]
    local_modules = missing_local_modules(candidate)
    return {
        "ok": not unexpected and not missing and not local_modules,
        "beforeSha256": hashlib.sha256(Path(before).read_bytes()).hexdigest(),
        "candidateSha256": hashlib.sha256(Path(candidate).read_bytes()).hexdigest(),
        "changed": changed,
        "unexpected": unexpected,
        "missingRuntimeFiles": missing,
        "missingLocalModules": local_modules,
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
    parser.add_argument("--kind", choices=["http", "event"], default="http")
    args = parser.parse_args()
    try:
        report = compare(args.before, args.candidate, set(args.allow), args.kind)
    except (ValueError, OSError, BadZipFile) as error:
        report = {"ok": False, "error": type(error).__name__}
    result = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        Path(args.output).write_text(result + "\n", encoding="utf-8")
    print(result)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
