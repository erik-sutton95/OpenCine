"""Duplicated source across OpenCine and the apps (SHELL-00). Standard library only, offline.

Every code file of each repository is normalized (comments, blank lines, whitespace, import and
package lines dropped; app names replaced by one token) and hashed, and so is every function
block of at least MIN_BLOCK_LINES normalized lines. A hash present in two repositories is a
duplicate between them: whole files first, then function blocks outside those files. A file is
`exact` when the bytes are identical too.

Sources: OpenCine from its working tree (what you are about to commit, and what CI checks); each
app at the commit of the ref it builds OpenCine on (its registry edge), else its baseline, read
from Git objects. A missing checkout or commit is reported, never counted as zero.

`--app DIR` also measures an unregistered folder (an app `atlas new-app` just wrote) against every
repository; it never writes the baseline. `--candidate ID` reads each consumer of that
compat/candidates.json record at its recorded commit instead of the registry ref (the duplication
exit of a candidate before any pin or edge moves); it never writes the baseline either.

compat/dupes-baseline.json holds the numbers per pair. `--check` fails when a pair has more
duplicated lines than the baseline; `--write-baseline` records the current numbers (do it in the
change that explains why they moved, for example an extraction before the app drops its copy).
"""
from __future__ import annotations

import fnmatch
import hashlib
import json
import re
import subprocess
import sys
from collections import defaultdict
from itertools import combinations
from pathlib import Path

import atlas
import hub
import resolver

OK, FAIL = atlas.OK, atlas.FAIL
EXTS = {".swift", ".kt", ".java", ".c", ".h", ".cc", ".cpp", ".hpp", ".m", ".mm", ".metal", ".glsl", ".vert", ".frag", ".comp"}
MIN_FILE_LINES = 3
# Never measured: credentials, build products, binary captures and vendored reference copies.
EXCLUDE = {
    "credentials": ["*.p12", "*.pem", "*.key", "*.keystore", "*.jks", "*.mobileprovision", "*.provisionprofile",
                    ".env", ".env.*", "*.local.xcconfig", "google-services.json", "GoogleService-Info.plist",
                    ".local/*", "*.properties.local"],
    "build-products": ["build/*", ".build/*", "DerivedData/*", "node_modules/*", "dist/*", ".gradle/*",
                       "*.so", "*.a", "*.dylib", "*.apk", "*.aab", "*.ipa", "*.xcframework/*", "jniLibs/*"],
    "binary-captures": ["*.pcap", "*.pcapng", "*.mp4", "*.mov", "*.m4v", "*.h264", "*.h265", "*.hevc", "*.bin",
                        "*.raw", "*.dng", "*.jpg", "*.jpeg", "*.png", "*.heic", "*.cube", "*.wav", "*.zip"],
    "vendor-reference-copies": ["vendor/*", "Vendor/*", "reference/*", "ref/*", "third_party/*", "ThirdParty/*"],
}
MIN_BLOCK_LINES = 6
BASELINE = "compat/dupes-baseline.json"
COMMENTS = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)
DROP_LINE = re.compile(r"^\s*(?:@testable\s+)?(?:import|package)\b")
# Where a function body starts: Swift func/init, Kotlin fun, a C-family (and Java) definition at
# line start. Types are not blocks, so their methods are found one by one.
C_DEF = (r"^[ \t]*(?!(?:if|for|while|switch|return|else|do|catch|class|struct|enum|new)\b)"
         r"[A-Za-z_][\w \t\*&:<>,\[\]]*\b\w+[ \t]*\([^;{}]*\)[ \t]*(?:const[ \t]*)?(?:throws[^{;]*)?\{")
BLOCK_START = {".swift": re.compile(r"\b(?:func|init|deinit)\b[^{};]*\{"), ".kt": re.compile(r"\bfun\b[^{};]*\{")}
C_START = re.compile(C_DEF, re.M)


def normalize(text, app_names):
    lines = []
    for line in COMMENTS.sub("", text).splitlines():
        if DROP_LINE.match(line):
            continue
        line = " ".join(app_names.sub("APP", line).split())
        if line:
            lines.append(line)
    return lines


def blocks(text, suffix):
    """Function blocks (comment-stripped source) found by brace matching; nested ones are part of
    their outer block."""
    text, start = COMMENTS.sub("", text), BLOCK_START.get(suffix, C_START)
    out, pos = [], 0
    while (m := start.search(text, pos)):
        depth, i = 0, m.end() - 1
        while i < len(text):
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            if depth == 0:
                break
            i += 1
        out.append(text[m.start():i + 1])
        pos = i + 1
    return out


def digest(lines):
    return hashlib.sha1("\n".join(lines).encode()).hexdigest()


def index(files, app_names):
    """{"files": {hash: (lines, raw hash, path)}, "blocks": {hash: (lines, path)}} for one repo."""
    out = {"files": {}, "blocks": {}}
    for path, text in files:
        norm = normalize(text, app_names)
        if len(norm) < MIN_FILE_LINES:
            continue
        out["files"].setdefault(digest(norm), (len(norm), hashlib.sha1(text.encode()).hexdigest(), path))
        for b in blocks(text, Path(path).suffix):
            bn = normalize(b, app_names)
            if len(bn) >= MIN_BLOCK_LINES:
                out["blocks"].setdefault(digest(bn), (len(bn), path))
    return out


def excluded_class(rel):
    """The EXCLUDE class a repository-relative path falls in, matched at any depth, or None."""
    parts = rel.split("/")
    suffixes = ["/".join(parts[i:]) for i in range(len(parts))]
    for cls, patterns in EXCLUDE.items():
        if any(fnmatch.fnmatchcase(s, p) for p in patterns for s in suffixes):
            return cls
    return None


def code_path(rel):
    return Path(rel).suffix in EXTS and not excluded_class(rel)


def working_tree_files(top):
    names = resolver.git(top, "ls-files", "-co", "--exclude-standard").splitlines()
    return [(n, (top / n).read_text(errors="replace")) for n in names if code_path(n) and (top / n).is_file()]


def commit_files(path, commit):
    names = [n for n in resolver.git(path, "ls-tree", "-r", "--name-only", commit).splitlines() if code_path(n)]
    proc = subprocess.run(["git", "-C", str(path), "cat-file", "--batch"], input="".join(f"{commit}:{n}\n" for n in names).encode(),
                          capture_output=True, env=resolver.GIT_ENV, check=True)
    data, out, pos = proc.stdout, [], 0
    for n in names:
        header_end = data.index(b"\n", pos)
        size = int(data[pos:header_end].split()[2])
        out.append((n, data[header_end + 1:header_end + 1 + size].decode(errors="replace")))
        pos = header_end + 1 + size + 1
    return out


def gather(reg, root, refs=None):
    """{repo: (source label, files)} and {repo: reason} for what could not be read. `refs`
    ({repo: ref}) replaces a repository's registry ref."""
    pid, top = atlas.enclosing_platform(root, reg)
    sources, missing = {}, {}
    for rid, m in sorted(reg.items()):
        if rid == pid:
            sources[rid] = (f"working tree at {resolver.git(top, 'rev-parse', 'HEAD')}", working_tree_files(top))
            continue
        ref = (refs or {}).get(rid) or hub.primary_ref(m, pid)
        res = resolver.resolve(m, root)
        if not ref:
            missing[rid] = "no registered ref"
        elif res["status"] != "ok":
            missing[rid] = f"checkout {res['status']}"
        elif not resolver.rev(res["path"], ref["commit"]):
            missing[rid] = f"{ref['name']} {ref['commit'][:12]} not in the local object database"
        else:
            sources[rid] = (f"{ref['name']} {ref['commit']}", commit_files(res["path"], ref["commit"]))
    return sources, missing


def directory_files(top):
    """Code files of a folder that need not be a Git checkout (a freshly generated app)."""
    return [(str(f.relative_to(top)), f.read_text(errors="replace")) for f in sorted(Path(top).rglob("*"))
            if f.is_file() and code_path(str(f.relative_to(top)))]


def candidate_refs(root, cid):
    """{consumer repo: ref at its recorded commit} of a compat/candidates.json record, or None."""
    import compat  # noqa: PLC0415
    cand = next((c for c in compat.load(root)["candidates"] if c.get("id") == cid), None)
    return cand and {c["repo"]: {"name": f"candidate {cid} {c.get('ref')}", "commit": c["commit"]} for c in cand.get("consumers", [])}


def measure(reg, root, app=None, refs=None):
    """`app`: also measure this unregistered folder (`--app`) against every repository."""
    sources, missing = gather(reg, root, refs) if refs else gather(reg, root)
    if app:
        sources[f"app:{Path(app).name}"] = (f"folder {Path(app).name}", directory_files(app))
    names = sorted({n for m in reg.values() for n in (m["display_name"], m["local_dir"])}, key=len, reverse=True)
    app_names = re.compile("|".join(re.escape(n) for n in names), re.I)
    idx = {rid: index(files, app_names) for rid, (_, files) in sources.items()}
    pairs = {}
    for a, b in combinations(sorted(idx), 2):
        shared = idx[a]["files"].keys() & idx[b]["files"].keys()
        shared_paths = {rid: {idx[rid]["files"][h][2] for h in shared} for rid in (a, b)}
        in_files = {h for rid in (a, b) for h, (_, path) in idx[rid]["blocks"].items() if path in shared_paths[rid]}
        blks = (idx[a]["blocks"].keys() & idx[b]["blocks"].keys()) - in_files
        file_lines = sum(idx[a]["files"][h][0] for h in shared)
        block_lines = sum(idx[a]["blocks"][h][0] for h in blks)
        top = sorted(((idx[a]["files"][h][0], idx[a]["files"][h][2], idx[b]["files"][h][2]) for h in shared), reverse=True)
        pairs[f"{a}|{b}"] = {
            "files": len(shared), "exact_files": sum(idx[a]["files"][h][1] == idx[b]["files"][h][1] for h in shared),
            "file_lines": file_lines, "blocks": len(blks), "block_lines": block_lines, "lines": file_lines + block_lines,
            "_top": top}
    totals = {rid: sum(n for n, _, _ in i["files"].values()) for rid, i in idx.items()}
    return {"sources": {rid: label for rid, (label, _) in sources.items()}, "missing": missing,
            "code_lines": totals, "pairs": pairs}


def run(args, reg, root):
    import time  # noqa: PLC0415
    started = time.monotonic()
    candidate = getattr(args, "candidate", None)  # callers that build their own Namespace predate it
    if (args.app or candidate) and args.write_baseline:
        print("--app and --candidate measure outside the registry refs; they never write the baseline", file=sys.stderr)
        return FAIL
    refs = candidate and candidate_refs(root, candidate)
    if candidate and not refs:
        print(f"no candidate {candidate!r} with consumers in compat/candidates.json", file=sys.stderr)
        return FAIL
    cur = measure(reg, root, args.app, refs)
    path = root / BASELINE
    base = json.loads(path.read_text()) if path.is_file() else None
    grew = []
    print(f"duplicated code between repositories (normalized lines; {BASELINE} {'loaded' if base else 'absent'})")
    for rid, label in cur["sources"].items():
        print(f"  {rid}: {label}, {cur['code_lines'][rid]} code lines")
    for rid, why in cur["missing"].items():
        print(f"  {rid}: NOT CHECKED ({why})")
    print(f"  {'pair':32} {'lines':>7} {'files':>6} {'exact':>6} {'blocks':>7} {'vs baseline':>12}")
    for key, p in cur["pairs"].items():
        was = ((base or {}).get("pairs") or {}).get(key)
        delta = "new" if was is None else f"{p['lines'] - was['lines']:+d}"
        if was is not None and p["lines"] > was["lines"]:
            grew.append(key)
        print(f"  {key.replace('|', ' / '):32} {p['lines']:>7} {p['files']:>6} {p['exact_files']:>6} {p['blocks']:>7} {delta:>12}")
        for lines, fa, fb in p["_top"][:args.top]:
            print(f"      {lines:>5}  {fa}" + ("" if fa == fb else f"  =  {fb}"))
    for key in sorted(set(((base or {}).get("pairs") or {})) - set(cur["pairs"])):
        print(f"  {key.replace('|', ' / '):32} not checked (a repository is unavailable)")
    print(f"({time.monotonic() - started:.1f} s)")
    if args.write_baseline:
        if cur["missing"]:
            print("refusing to write a baseline while a repository is unavailable", file=sys.stderr)
            return FAIL
        record = {"schema_version": 1, "note": "Written by `atlas dupes --write-baseline`; see tools/dupes.py for the metric.",
                  "sources": cur["sources"], "code_lines": cur["code_lines"],
                  "pairs": {k: {f: v for f, v in p.items() if not f.startswith("_")} for k, p in cur["pairs"].items()}}
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
        print(f"wrote {BASELINE}")
    if args.check and grew:
        print(f"duplication grew in {', '.join(grew)}: remove the copy, or record why with --write-baseline", file=sys.stderr)
        return FAIL
    return OK
