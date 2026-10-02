"""Graphify navigation snapshots: plan, local-only build, namespaced merge.

A build exports one identified commit with `git archive` into a temporary folder (the
shared checkout is never touched), removes excluded file classes, and runs the pinned
Graphify `update` command (code-only AST extraction, deterministic hub labels) inside a
macOS sandbox that denies all network access and every write outside the temporary
folder. If any of that cannot be verified, the build refuses to run.
"""
from __future__ import annotations

import fnmatch
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from collections import Counter
from pathlib import Path

import resolver

# Inspected version: `graphify update` runs watch._rebuild_code, which imports no LLM
# client and names communities by their highest-degree member. Re-inspect before bumping.
GRAPHIFY_VERSION = "0.9.11"
SCAN_CONFIG = {
    "graphify": {"package": "graphifyy", "version": GRAPHIFY_VERSION, "command": ["update", "<export>"]},
    "isolation": "git archive export; sandbox-exec denies network and writes outside the export",
    "exclude": {
        "credentials": ["*.p12", "*.pem", "*.key", "*.keystore", "*.jks", "*.mobileprovision", "*.provisionprofile",
                        ".env", ".env.*", "*.local.xcconfig", "google-services.json", "GoogleService-Info.plist",
                        ".local/*", "*.properties.local"],
        "build-products": ["build/*", ".build/*", "DerivedData/*", "node_modules/*", "dist/*", ".gradle/*",
                           "*.so", "*.a", "*.dylib", "*.apk", "*.aab", "*.ipa", "*.xcframework/*", "jniLibs/*"],
        "binary-captures": ["*.pcap", "*.pcapng", "*.mp4", "*.mov", "*.m4v", "*.h264", "*.h265", "*.hevc", "*.bin",
                            "*.raw", "*.dng", "*.jpg", "*.jpeg", "*.png", "*.heic", "*.cube", "*.wav", "*.zip"],
        "vendor-reference-copies": ["vendor/*", "Vendor/*", "reference/*", "ref/*", "third_party/*", "ThirdParty/*"],
    },
}
CODE_EXTS = {".swift", ".kt", ".kts", ".java", ".c", ".h", ".cpp", ".hpp", ".cc", ".m", ".mm", ".metal", ".py", ".js", ".ts", ".sh", ".rb", ".go", ".rs"}
MERGE_NOTE = ("Navigation view only. Graphify merge-graphs composes repo-prefixed nodes into one undirected graph; "
              "it does not discover cross-repo dependencies and drops edge direction. Use `atlas deps` and "
              "`atlas impact` for dependency facts.")


def graphify_python():
    exe = shutil.which("graphify")
    if not exe:
        return None
    first = Path(exe).read_bytes().split(b"\n", 1)[0].decode(errors="replace")
    return first[2:].strip().split()[0] if first.startswith("#!") else None


def installed_graphify_version():
    py = graphify_python()
    if not py:
        return None
    r = subprocess.run([py, "-c", "import importlib.metadata as m; print(m.version('graphifyy'))"], capture_output=True, text=True)
    return r.stdout.strip() or None


def sandbox_available():
    return sys.platform == "darwin" and shutil.which("sandbox-exec") is not None


def local_only_problems():
    problems = []
    version = installed_graphify_version()
    if version is None:
        problems.append("graphify is not installed")
    elif version != GRAPHIFY_VERSION:
        problems.append(f"installed graphify {version} is not the inspected {GRAPHIFY_VERSION}")
    if not sandbox_available():
        problems.append("sandbox-exec is unavailable, so no-network cannot be enforced")
    return problems


def excluded_class(rel):
    parts = rel.split("/")
    suffixes = ["/".join(parts[i:]) for i in range(len(parts))]
    for cls, patterns in SCAN_CONFIG["exclude"].items():
        if any(fnmatch.fnmatchcase(s, p) for p in patterns for s in suffixes):
            return cls
    return None


def select_targets(reg, specs):
    """[(repo_id, ref)] for 'repo' (every registered ref) or 'repo@name-or-sha-prefix'."""
    if not specs:
        return [(rid, ref) for rid, m in sorted(reg.items()) for ref in m["refs"]]
    out = []
    for spec in specs:
        rid, _, want = spec.partition("@")
        if rid not in reg:
            raise SystemExit(f"unknown repo {rid!r}")
        refs = [r for r in reg[rid]["refs"] if not want or r["name"] == want or (len(want) >= 7 and r["commit"].startswith(want))]
        if not refs:
            raise SystemExit(f"{spec}: no registered ref matches (register it in repos/{rid}/meta.json first)")
        out += [(rid, r) for r in refs]
    return out


def paths_for(root, rid, commit):
    return {
        "snapshot": root / "repos" / rid / "snapshots" / commit,
        "graph": root / "graphify-out" / f"{rid}@{commit[:12]}" / "graph",
    }


def plan(args, reg, root):
    problems = local_only_problems()
    config_hash = resolver.config_hash(SCAN_CONFIG)
    for rid, ref in select_targets(reg, args.targets):
        res = resolver.resolve(reg[rid], root)
        p = paths_for(root, rid, ref["commit"])
        snap = p["snapshot"] / "snapshot.json"
        cache = "none"
        if snap.is_file():
            cache = "current snapshot (build would replace it)" if json.loads(snap.read_text()).get("scan_config_hash") == config_hash else "outdated snapshot (scan config changed)"
        available = res["status"] == "ok" and resolver.rev(res["path"], ref["commit"])
        print(f"{rid}@{ref['name']} ({ref['role']})")
        print(f"  source: git archive {ref['commit']} from {'the resolved checkout' if available else 'UNAVAILABLE: ' + res['reason']}")
        print(f"  excluded classes: {', '.join(SCAN_CONFIG['exclude'])}")
        print(f"  writes (committed): {p['snapshot'].relative_to(root)}/{{snapshot.json,GRAPH_REPORT.md,graphify_labels.json}}")
        print(f"  writes (ignored):   {p['graph'].relative_to(root)}/{{graph.json,graph.html}}")
        print(f"  cache: {cache}")
    print(f"scan config hash: {config_hash}")
    if problems:
        print("model/network: build REFUSED, local-only mode not verifiable: " + "; ".join(problems))
    else:
        print(f"model/network: none. graphify {GRAPHIFY_VERSION} `update` (code-only) under sandbox-exec with network denied")
    return 0


def _export(checkout, commit, dest):
    """git archive into dest, skipping excluded classes. Returns (exported_paths, excluded Counter)."""
    exported, excluded = [], Counter()
    proc = subprocess.Popen(["git", "-C", str(checkout), "archive", "--format=tar", commit], stdout=subprocess.PIPE, env=resolver.GIT_ENV)
    with tarfile.open(fileobj=proc.stdout, mode="r|") as tar:
        for member in tar:
            if not member.isfile():
                continue
            cls = excluded_class(member.name)
            if cls:
                excluded[cls] += 1
                continue
            tar.extract(member, dest, filter="data")
            exported.append(member.name)
    if proc.wait():
        raise resolver.GitError(f"git archive {commit} failed")
    return exported, excluded


def _sandboxed(cmd, scratch):
    profile = (
        '(version 1)(allow default)(deny network*)(deny file-write*)'
        f'(allow file-write* (subpath "{scratch}") (literal "/dev/null") (literal "/dev/tty") (regex #"^/dev/fd/"))'
    )
    home = Path(scratch) / "home"
    home.mkdir(exist_ok=True)
    # cwd and GIT_CEILING_DIRECTORIES stop Graphify's `git rev-parse HEAD` from finding any
    # repository (it once stamped the atlas's own HEAD); the atlas stamps the real commit.
    env = {"PATH": "/usr/bin:/bin", "HOME": str(home), "TMPDIR": str(home), "GRAPHIFY_NO_TIPS": "1",
           "LANG": "en_US.UTF-8", "GIT_CEILING_DIRECTORIES": str(Path(scratch).parent)}
    return subprocess.run(["sandbox-exec", "-p", profile, *cmd], capture_output=True, text=True, env=env, cwd=home)


def _coverage(exported, graph_json, excluded):
    data = json.loads(graph_json.read_text())
    parsed = {n.get("source_file") for n in data.get("nodes", []) if n.get("source_file")}
    unparsed_code = Counter(Path(f).suffix for f in exported if Path(f).suffix in CODE_EXTS and f not in parsed)
    return {
        "exported_files": len(exported),
        "parsed": len(parsed),
        "skipped_non_code": sum(1 for f in exported if Path(f).suffix not in CODE_EXTS),
        "unsupported_or_empty_code": dict(sorted(unparsed_code.items())),
        "excluded": dict(sorted(excluded.items())),
        "failed": 0,
        "nodes": len(data.get("nodes", [])),
        "edges": len(data.get("links", data.get("edges", []))),
    }


HUB_LIMIT = 40


def compact_report(text, rid, ref, commit):
    """Committed report: drop the per-community listing and Graphify's freshness stamp, cap the
    hub list, and state the atlas provenance. The full report stays in the ignored graph."""
    title, *sections = text.split("\n## ")
    keep = []
    for sec in sections:
        name = sec.split("\n", 1)[0]
        if name.startswith(("Communities", "Graph Freshness")):
            continue
        if name.startswith("Community Hubs"):
            lines = sec.split("\n")
            hubs = [line for line in lines[1:] if line.startswith("- ")]
            if len(hubs) > HUB_LIMIT:
                sec = "\n".join([lines[0], *hubs[:HUB_LIMIT], f"- ... {len(hubs) - HUB_LIMIT} more in graphify_labels.json", ""])
        keep.append(sec)
    provenance = (f"Atlas provenance\n- Source: `{rid}@{commit}` (ref `{ref['name']}`, {ref['role']})\n"
                  "- Exact provenance, exclusions and coverage: `snapshot.json` beside this report.\n"
                  "- Navigation aid only. Dependency facts come from `atlas deps` and `atlas impact`.\n")
    return "\n## ".join([title.rstrip() + "\n", provenance, *keep]).rstrip() + "\n"


def build(args, reg, root):
    problems = local_only_problems()
    if problems:
        print("graph build refused: local-only mode is not verifiable: " + "; ".join(problems), file=sys.stderr)
        if args.all:
            print("Graphify is optional: `atlas impact <symbol|path>` works from manifests and source search alone.", file=sys.stderr)
        return 3 if args.all else 1
    if bool(args.all) == bool(args.target):
        print("name one repo@ref, or pass --all", file=sys.stderr)
        return 2
    if args.all:
        return build_all(reg, root)
    targets = select_targets(reg, [args.target])
    if len(targets) != 1:
        print(f"{args.target} names {len(targets)} refs; pick one with repo@ref", file=sys.stderr)
        return 2
    return build_one(reg, root, *targets[0])


def build_all(reg, root):
    """Each repository at its working ref (atlas impact uses the same refs), then merge only those."""
    import hub  # noqa: PLC0415
    pid = next((rid for rid, m in reg.items() if m.get("layers")), None)
    picked = [(rid, ref) for rid, m in sorted(reg.items()) if (ref := hub.primary_ref(m, pid))]
    codes = [build_one(reg, root, rid, ref) for rid, ref in picked]
    if any(c not in (0, 3) for c in codes) or codes.count(0) < 2:
        return max(codes or [3])
    code = merge(None, reg, root, only={(rid, ref["commit"]) for (rid, ref), c in zip(picked, codes) if c == 0})
    return code or (3 if 3 in codes else 0)


def build_one(reg, root, rid, ref):
    res = resolver.resolve(reg[rid], root)
    if res["status"] != "ok" or not resolver.rev(res["path"], ref["commit"]):
        print(f"{rid}@{ref['name']}: source unavailable ({res['reason']}); nothing built", file=sys.stderr)
        return 3
    commit = ref["commit"]
    out = paths_for(root, rid, commit)
    py = graphify_python()
    with tempfile.TemporaryDirectory(prefix="atlas-graph-") as tmp:
        scratch = Path(tmp).resolve()
        src = scratch / f"{rid}@{commit[:12]}"
        src.mkdir()
        exported, excluded = _export(res["path"], commit, src)
        # Rebuilding the same commit: seed the previous graph so Graphify remaps communities to
        # their old IDs, and the committed labels (including hand edits) stay on them.
        seeds = {out["snapshot"] / "graphify_labels.json": ".graphify_labels.json",
                 out["graph"] / "graph.json": "graph.json", out["graph"] / "GRAPH_REPORT.full.md": "GRAPH_REPORT.md"}
        for seed, name in seeds.items():
            if seed.is_file():
                (src / "graphify-out").mkdir(exist_ok=True)
                shutil.copy(seed, src / "graphify-out" / name)
        # --force: the export is always a complete commit, so a smaller graph is real, not partial.
        run = _sandboxed([py, "-m", "graphify", "update", "--force", str(src)], scratch)
        gout = src / "graphify-out"
        if run.returncode or not (gout / "graph.json").is_file():
            print(f"graph build FAILED for {rid}@{ref['name']} (exit {run.returncode}); nothing written", file=sys.stderr)
            print((run.stdout + run.stderr)[-2000:], file=sys.stderr)
            return 1
        prov = resolver.snapshot_provenance(rid, res["path"], commit, SCAN_CONFIG,
                                            {"atlas": resolver.ATLAS_VERSION, "graphify": GRAPHIFY_VERSION}, scope=ref["role"])
        prov.update(ref_label=ref["name"], excluded_classes=list(SCAN_CONFIG["exclude"]),
                    coverage=_coverage(exported, gout / "graph.json", excluded))
        out["graph"].mkdir(parents=True, exist_ok=True)
        full = json.loads((gout / "graph.json").read_text())
        full["built_at_commit"] = commit
        (out["graph"] / "graph.json").write_text(json.dumps(full))
        if (gout / "graph.html").is_file():
            shutil.copy(gout / "graph.html", out["graph"] / "graph.html")
        shutil.copy(gout / "GRAPH_REPORT.md", out["graph"] / "GRAPH_REPORT.full.md")
        staged = scratch / "snapshot"
        staged.mkdir()
        # Committed text follows the atlas style rule: no em dash, even when quoted from source.
        report = compact_report((gout / "GRAPH_REPORT.md").read_text(), rid, ref, commit)
        (staged / "GRAPH_REPORT.md").write_text(report.replace("\u2014", "-"))
        if (gout / ".graphify_labels.json").is_file():
            labels = (gout / ".graphify_labels.json").read_text().replace("\u2014", "-")
            (staged / "graphify_labels.json").write_text(labels)
        (staged / "snapshot.json").write_text(json.dumps(prov, indent=2, sort_keys=True) + "\n")
        replaced = out["snapshot"].exists()
        if replaced:
            shutil.rmtree(out["snapshot"])
        out["snapshot"].parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(staged, out["snapshot"])
    c = prov["coverage"]
    print(f"built {rid}@{ref['name']} {commit}: {c['nodes']} nodes, {c['edges']} edges, {c['parsed']} files parsed, "
          f"excluded {c['excluded']}{' (replaced the snapshot for this commit)' if replaced else ''}")
    return 0


def merge(args, reg, root, only=None):
    """Merge built graphs; `only` limits it to {(repo, commit)} (build --all)."""
    problems = local_only_problems()
    if problems:
        print("graph merge refused: " + "; ".join(problems), file=sys.stderr)
        return 1
    inputs = []
    for snap in sorted((root / "repos").glob("*/snapshots/*/snapshot.json")):
        s = json.loads(snap.read_text())
        if only is not None and (s["repository_id"], s["source_commit"]) not in only:
            continue
        g = paths_for(root, s["repository_id"], s["source_commit"])["graph"] / "graph.json"
        inputs.append({"snapshot": f"{s['repository_id']}@{s['source_commit']}", "ref": s.get("ref_label"),
                       "scope": s.get("scope"), "graph": str(g.relative_to(root)), "available": g.is_file()})
    usable = [i for i in inputs if i["available"]]
    if len(usable) < 2:
        print(f"need at least two locally built graphs; have {len(usable)} (run graph build first)", file=sys.stderr)
        return 3
    dest = root / "graphify-out"
    with tempfile.TemporaryDirectory(prefix="atlas-merge-") as tmp:
        scratch = Path(tmp).resolve()
        run = _sandboxed([graphify_python(), "-m", "graphify", "merge-graphs", *[str(root / i["graph"]) for i in usable],
                          "--out", str(scratch / "merged-graph.json")], scratch)
        if run.returncode:
            print(run.stdout + run.stderr, file=sys.stderr)
            return 1
        shutil.move(scratch / "merged-graph.json", dest / "merged-graph.json")
    disclosure = {"note": MERGE_NOTE, "graphify": GRAPHIFY_VERSION, "inputs": inputs}
    (dest / "merged-inputs.json").write_text(json.dumps(disclosure, indent=2) + "\n")
    print(MERGE_NOTE)
    for i in inputs:
        print(f"  {'merged ' if i['available'] else 'MISSING'} {i['snapshot']} ({i['ref']}, {i['scope']})")
    print(run.stdout.strip().splitlines()[-2] if run.stdout.strip() else "")
    print(f"navigation: `atlas impact <symbol>` reads it; or graphify query|explain|affected \"<X>\" --graph {(dest / 'merged-graph.json').relative_to(root.parent)}")
    return 0 if len(usable) == len(inputs) else 3


def run(args, reg, root):
    return {"plan": plan, "build": build, "merge": merge}[args.gcmd](args, reg, root)
