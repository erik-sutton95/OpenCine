#!/usr/bin/env python3
"""opencapture-atlas CLI. Standard library only.

Read-only commands: doctor, locate, deps, impact, stale, check, graph plan, compat plan.
`compat run` writes only compat/candidates.json, compat/results/ and ignored .local/.
Exit codes: 0 ok, 1 failed check, 2 unusable input, 3 incomplete (something requested
could not be obtained or parsed; never reported as success).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import manifests  # noqa: E402
import resolver  # noqa: E402

ATLAS_VERSION = resolver.ATLAS_VERSION
LAYERS = {"app", "ui", "core", "multicam", "vendor", "atlas"}
BUILD_KINDS = {"library", "contract", "generates"}
PROPAGATING = BUILD_KINDS | {"source-copy"}
KINDS = PROPAGATING | {"runtime", "documents", "tests"}
# Plan section 3.4: consumer layer -> layers it must never build against. Nothing builds
# against the atlas (checked separately).
FORBIDDEN = {
    "core": {"ui", "vendor", "multicam", "app"},
    "vendor": {"ui", "app"},
    "multicam": {"vendor", "ui", "app"},
    "ui": {"vendor", "app"},
}
ACTIONS = {
    "library": "rebuild and test against the changed product",
    "contract": "update the implementation to the contract, then rebuild",
    "generates": "regenerate checked-in output, then rebuild",
    "source-copy": "re-sync the copied paths from the donor, review, rebuild",
    "runtime": "verify at runtime; no rebuild",
    "tests": "re-run its validation",
    "documents": "update documentation",
}
OK, FAIL, USAGE, INCOMPLETE = 0, 1, 2, 3
PRIVATE_PATH_RE = resolver.PRIVATE_PATH_RE


def atlas_root():
    return Path(os.environ.get("OPENCAPTURE_ATLAS_ROOT") or Path(__file__).resolve().parent.parent)


# ---------------------------------------------------------------- registry

def load_registry(root):
    reg, errors = {}, []
    for meta_path in sorted((root / "repos").glob("*/meta.json")):
        try:
            reg[meta_path.parent.name] = json.loads(meta_path.read_text())
        except ValueError as exc:
            errors.append(f"{meta_path.relative_to(root)}: invalid JSON ({exc})")
    return reg, errors


def _is_sha(v):
    return isinstance(v, str) and bool(resolver.SHA_RE.match(v))


def validate_registry(reg):
    errors = []
    for rid, m in reg.items():
        where = f"repos/{rid}/meta.json"
        missing = [k for k in ("schema_version", "id", "display_name", "status", "layer", "repository", "local_dir", "refs", "products", "edges") if k not in m]
        if missing:
            errors.append(f"{where}: missing {', '.join(missing)}")
            continue
        if m["schema_version"] != 1:
            errors.append(f"{where}: unsupported schema_version")
        if m["id"] != rid:
            errors.append(f"{where}: id {m['id']!r} does not match its folder")
        if m["status"] not in {"active", "candidate", "archived"}:
            errors.append(f"{where}: status must be active, candidate or archived")
        if m["layer"] not in LAYERS:
            errors.append(f"{where}: unknown layer {m['layer']!r}")
        repo = m["repository"]
        if not isinstance(repo, dict) or not isinstance(repo.get("default_branch"), str) or not (repo.get("url") is None or isinstance(repo.get("url"), str)):
            errors.append(f"{where}: repository needs url (string or null) and default_branch")
        roles = [r.get("role") for r in m["refs"]]
        for r in m["refs"]:
            if not r.get("name") or not _is_sha(r.get("commit")) or r.get("role") not in {"baseline", "candidate"}:
                errors.append(f"{where}: each ref needs name, full 40-hex commit and role baseline|candidate")
        if roles.count("baseline") > 1:
            errors.append(f"{where}: more than one baseline ref")
        review = m.get("summary_review")
        if review is not None and not (_is_sha(review.get("source_commit")) and re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", review.get("reviewed_at", ""))):
            errors.append(f"{where}: summary_review needs a full source_commit and UTC reviewed_at")
        ref_names = {r.get("name") for r in m["refs"]}
        for i, e in enumerate(m["edges"]):
            errors += [f"{where}: edges[{i}]: {msg}" for msg in _edge_errors(rid, m, e, reg, ref_names)]
    return errors


def _edge_errors(rid, m, e, reg, ref_names):
    errs = []
    to = e.get("to")
    if to not in reg or to == rid:
        return [f"target {to!r} is not another registered repo"]
    if e.get("kind") not in KINDS:
        errs.append(f"kind must be one of {sorted(KINDS)}")
    if e.get("status") not in {"live", "candidate"}:
        errs.append("status must be live or candidate")
    if e.get("confidence") not in {"confirmed", "inferred"}:
        errs.append("confidence must be confirmed or inferred")
    if e.get("confidence") == "confirmed":
        ev = e.get("evidence") or {}
        if not ev.get("path") or not _is_sha(ev.get("source_commit")):
            errs.append("confirmed edges need evidence.path and a full evidence.source_commit")
    if e.get("kind") == "source-copy":
        if not e.get("scope") or not e.get("mechanism") or "donor_revision" not in e:
            errs.append("source-copy edges need scope, mechanism and donor_revision (null when unknown)")
        elif e["donor_revision"] is not None and not _is_sha(e["donor_revision"]):
            errs.append("donor_revision must be a full SHA or null")
    if e.get("status") == "live" and (m["status"] == "candidate" or reg[to]["status"] == "candidate"):
        errs.append("a candidate repository cannot have or be the target of a live edge")
    if e.get("ref") is not None and e["ref"] not in ref_names:
        errs.append(f"ref {e['ref']!r} is not one of this repo's registered refs")
    errs += _direction_errors(m["layer"], reg[to]["layer"], e.get("kind"))
    return errs


def _direction_errors(from_layer, to_layer, kind):
    if kind not in BUILD_KINDS:
        return []
    if to_layer == "atlas":
        return ["forbidden: nothing may build against the atlas"]
    if to_layer in FORBIDDEN.get(from_layer, ()):
        return [f"forbidden: {from_layer} must not depend on {to_layer} ({kind})"]
    return []


def authored_edges(reg):
    return [dict(e, frm=rid, origin="authored") for rid, m in reg.items() for e in m["edges"]]


def build_cycles(edges):
    graph = defaultdict(set)
    for e in edges:
        if e["kind"] in BUILD_KINDS:
            graph[e["frm"]].add(e["to"])
    cycles, state = [], {}

    def visit(node, stack):
        state[node] = 1
        for nxt in sorted(graph[node]):
            if state.get(nxt) == 1:
                cycles.append(stack[stack.index(nxt):] + [nxt])
            elif not state.get(nxt):
                visit(nxt, stack + [nxt])
        state[node] = 2

    for node in sorted(graph):
        if not state.get(node):
            visit(node, [node])
    return cycles


# ---------------------------------------------------------------- sources

def resolve_all(reg, root):
    config = resolver.load_local_config(root)
    return {rid: resolver.resolve(m, root, config=config) for rid, m in reg.items()}


def _map_dep(dep, manifest_path, reg, self_id):
    """Registered repo id a dependency points at, or None (internal or external)."""
    if dep["type"] == "url":
        want = resolver.normalize_url(dep["value"])
        return next((rid for rid, m in reg.items() if resolver.normalize_url((m.get("repository") or {}).get("url")) == want and rid != self_id), None)
    if dep["type"] == "path":
        name = manifests.outside_dir(manifest_path, dep["value"])
        return next((rid for rid, m in reg.items() if name and m["local_dir"].lower() == name.lower() and rid != self_id), None)
    if dep["type"] == "coordinates":
        return next((rid for rid, m in reg.items() for p in m["products"] if p.get("coordinates") == dep["value"] and rid != self_id), None)
    return None


def scan_manifests(rid, reg, path, commit):
    """Read every manifest at a commit through Git objects. Returns (results, derived_edges)."""
    names = resolver.git(path, "ls-tree", "-r", "--name-only", commit).splitlines()
    results, derived = [], []
    for name in filter(manifests.is_manifest, names):
        text = resolver.git(path, "show", f"{commit}:{name}", binary=True).decode("utf-8", "replace")
        res = manifests.read(name, text)
        res["external"] = []
        for dep in res["deps"]:
            target = _map_dep(dep, name, reg, rid)
            if target:
                derived.append({
                    "frm": rid, "to": target, "kind": "library", "origin": "manifest", "confidence": "confirmed",
                    "platforms": ["android"] if "gradle" in res["kind"] else ["apple"],
                    "evidence": {"path": name, "line": dep.get("line"), "source_commit": commit, "value": dep["value"]},
                })
            elif dep["type"] != "path" or manifests.outside_dir(name, dep["value"]):
                res["external"].append(dep["value"])
        results.append(res)
    return results, derived


def gather(reg, root, ids):
    """Scan manifests for the given repos at every registered ref.

    Returns (scans, derived_edges, incomplete, skipped). A repo with refs but no usable
    checkout, or with an unknown manifest, is incomplete. A repo with no registered ref is
    skipped (nothing is pinned for it yet), and reported as such.
    """
    resolved = resolve_all(reg, root)
    scans, derived, incomplete, skipped = {}, [], {}, {}
    for rid in ids:
        m = reg[rid]
        if not m["refs"]:
            skipped[rid] = "no registered ref"
            continue
        res = resolved[rid]
        if res["status"] != "ok":
            incomplete[rid] = f"checkout {res['status']}: {res['reason']}"
            continue
        for ref in m["refs"]:
            if not resolver.rev(res["path"], ref["commit"]):
                incomplete[rid] = f"commit {ref['commit']} ({ref['name']}) not in the local object database"
                continue
            results, edges = scan_manifests(rid, reg, res["path"], ref["commit"])
            status = "live" if ref["role"] == "baseline" else "candidate"
            for e in edges:
                e.update(status=status, ref=ref["name"])
            derived += edges
            scans[f"{rid}@{ref['name']}"] = {"commit": ref["commit"], "manifests": results}
            unknown = [r["path"] for r in results if r["status"] != "parsed"]
            if unknown:
                incomplete[rid] = "unknown manifests: " + ", ".join(unknown)
    return scans, derived, incomplete, skipped


# ---------------------------------------------------------------- commands

def _print(obj, as_json):
    if as_json:
        print(json.dumps(obj, indent=2, sort_keys=True))
        return True
    return False


def cmd_locate(args, reg, root):
    if args.repo not in reg:
        print(f"unknown repo {args.repo!r}; registered: {', '.join(sorted(reg))}", file=sys.stderr)
        return USAGE
    res = resolver.resolve(reg[args.repo], root)
    if res["status"] != "ok":
        if not _print(res, args.json):
            print(f"{args.repo}: {res['status']}: {res['reason']}", file=sys.stderr)
            for c in res["candidates"]:
                print(f"  candidate: {c}", file=sys.stderr)
        return USAGE
    info = resolver.inspect(res["path"])
    info["resolved_by"] = res["reason"]
    info["registered_refs"] = []
    for ref in reg[args.repo]["refs"]:
        tip = resolver.rev(res["path"], f"origin/{ref['name']}") or resolver.rev(res["path"], ref["name"])
        info["registered_refs"].append(dict(ref, current_tip=tip))
    if _print(info, args.json):
        return OK
    print(f"{args.repo}: {info['path']}  ({info['resolved_by']})")
    print(f"  branch {info['branch'] or '(detached)'}  commit {info['commit']}  {'DIRTY' if info['dirty'] else 'clean'}")
    for r in info["registered_refs"]:
        moved = "" if r["current_tip"] == r["commit"] else f"  (tip now {r['current_tip'] or 'missing'})"
        print(f"  registered {r['role']} {r['name']} {r['commit']}{moved}")
    for w in info["worktrees"]:
        flags = " ".join(k for k in ("detached", "prunable", "locked") if w.get(k))
        print(f"  worktree {w['path']}  [{w.get('branch') or 'detached'}] {w.get('commit', '')[:12]} {flags}".rstrip())
    return OK


def _edge_line(e):
    bits = [e["kind"], e["status"], e.get("confidence", "")]
    if e.get("ref"):
        bits.append(f"ref {e['ref']}")
    if e.get("platforms"):
        bits.append("[" + ",".join(e["platforms"]) + "]")
    ev = e.get("evidence") or {}
    if ev.get("path"):
        loc = ev["path"] + (f":{ev['line']}" if ev.get("line") else "")
        bits.append(f"evidence {loc}@{(ev.get('source_commit') or '')[:12]}")
    if e.get("kind") == "source-copy":
        bits.append(f"donor {e.get('donor_revision') or 'unknown'}")
    return "  ".join(b for b in bits if b)


def cmd_deps(args, reg, root):
    if args.repo not in reg:
        print(f"unknown repo {args.repo!r}", file=sys.stderr)
        return USAGE
    authored = authored_edges(reg)
    out = {
        "repo": args.repo,
        "outgoing": [e for e in authored if e["frm"] == args.repo],
        "incoming": [e for e in authored if e["to"] == args.repo],
    }
    code = OK
    if not args.registry_only:
        scans, derived, incomplete, skipped = gather(reg, root, [args.repo])
        out.update(manifest_scans=scans, manifest_edges=[e for e in derived if e["frm"] == args.repo],
                   incomplete=incomplete, skipped=skipped)
        violations = [f"{e['frm']} -> {e['to']}: {msg}" for e in derived for msg in _direction_errors(reg[e["frm"]]["layer"], reg[e["to"]]["layer"], e["kind"])]
        out["violations"] = violations
        code = FAIL if violations else INCOMPLETE if incomplete else OK
    if _print(out, args.json):
        return code
    m = reg[args.repo]
    print(f"{args.repo} ({m['status']}, layer {m['layer']})")
    for label, key, arrow, other in (("outgoing", "outgoing", "->", "to"), ("incoming", "incoming", "<-", "frm")):
        print(f"Authored edges, {label}:" + ("" if out[key] else " none"))
        for e in out[key]:
            print(f"  {arrow} {e[other]}  {_edge_line(e)}")
    if args.registry_only:
        print("Manifests: not checked (--registry-only)")
        return code
    for name, scan in out["manifest_scans"].items():
        print(f"Manifests at {name} {scan['commit']}:")
        for r in scan["manifests"]:
            ext = f"  external: {', '.join(sorted(set(r['external'])))}" if r["external"] else ""
            print(f"  {r['status']:8} {r['path']}{ext}")
            for p in r["problems"]:
                print(f"           ! {p}")
    print("Manifest-derived registered dependencies:" + ("" if out["manifest_edges"] else " none"))
    for e in out["manifest_edges"]:
        print(f"  -> {e['to']}  {_edge_line(e)}")
    for rid, why in out["skipped"].items():
        print(f"Skipped {rid}: {why}")
    for rid, why in out["incomplete"].items():
        print(f"INCOMPLETE {rid}: {why}")
    for v in out["violations"]:
        print(f"FORBIDDEN {v}")
    return code


def _sccs(nodes, succ):
    """Tarjan: strongly connected components, each emitted after the components it reaches."""
    index, low, on, stack, out = {}, {}, set(), [], []

    def visit(v):
        index[v] = low[v] = len(index)
        stack.append(v)
        on.add(v)
        for w in sorted(succ(v)):
            if w not in index:
                visit(w)
                low[v] = min(low[v], low[w])
            elif w in on:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = set()
            while True:
                w = stack.pop()
                on.discard(w)
                comp.add(w)
                if w == v:
                    break
            out.append(comp)

    for v in sorted(nodes):
        if v not in index:
            visit(v)
    return out


def impact_waves(target, edges):
    """Consumer waves for a change in `target`. Returns (waves, verify_only, cycles).

    Copy edges may legitimately form cycles; repos in one cycle share a wave and the cycle is
    reported, because their relative order cannot be derived."""
    prop = [e for e in edges if e["kind"] in PROPAGATING]
    users, deps = defaultdict(set), defaultdict(set)
    for e in prop:
        users[e["to"]].add(e["frm"])
        deps[e["frm"]].add(e["to"])
    affected, todo = set(), [target]
    while todo:
        for c in users[todo.pop()] - affected - {target}:
            affected.add(c)
            todo.append(c)
    nodes = affected | {target}
    level, cycles = {}, []
    for comp in _sccs(nodes, lambda n: deps[n] & nodes):
        if len(comp) > 1:
            cycles.append(sorted(comp))
        if target in comp:
            level.update({n: 0 if n == target else 1 for n in comp})
            continue
        lv = 1 + max((level[d] for n in comp for d in deps[n] & nodes if d not in comp), default=0)
        level.update(dict.fromkeys(comp, lv))
    waves = defaultdict(list)
    for node in sorted(affected):
        via = [e for e in prop if e["frm"] == node and e["to"] in nodes]
        waves[level[node]].append({"repo": node, "via": via})
    verify = [e for e in edges if e["kind"] not in PROPAGATING and e["to"] in nodes and e["frm"] not in nodes]
    return [waves[k] for k in sorted(waves)], verify, cycles


def cmd_impact(args, reg, root):
    if args.repo not in reg:
        print(f"unknown repo {args.repo!r}", file=sys.stderr)
        return USAGE
    edges = authored_edges(reg)
    incomplete, skipped = {}, {}
    if not args.registry_only:
        _, derived, incomplete, skipped = gather(reg, root, sorted(reg))
        edges += derived
    if not args.include_candidates:
        edges = [e for e in edges if e["status"] == "live"]
    waves, verify, cycles = impact_waves(args.repo, edges)
    code = INCOMPLETE if incomplete else OK
    out = {"repo": args.repo, "waves": waves, "verify_only": verify, "copy_cycles": cycles, "incomplete": incomplete, "skipped": skipped,
           "manifests": "not checked" if args.registry_only else "scanned",
           "edge_statuses": ["live", "candidate"] if args.include_candidates else ["live"]}
    if _print(out, args.json):
        return code
    print(f"Impact of a change in {args.repo}  (edges: {', '.join(out['edge_statuses'])}; manifests: {out['manifests']})")
    if not waves:
        print("  No registered consumers.")
    for i, wave in enumerate(waves, 1):
        print(f"Wave {i}:")
        for item in wave:
            seen = set()
            for e in item["via"]:
                ref = f"@{e['ref']}" if e.get("ref") else ""
                plat = f" [{','.join(e['platforms'])}]" if e.get("platforms") else ""
                line = f"  {item['repo']}{ref}{plat}  via {e['kind']} to {e['to']} ({e['status']}, {e.get('origin')}) -> {ACTIONS[e['kind']]}"
                if line not in seen:
                    seen.add(line)
                    print(line)
    for c in cycles:
        print(f"Copy cycle (order inside it is not derivable): {' <-> '.join(c)}")
    for e in verify:
        print(f"Verify only: {e['frm']} {e['kind']} -> {ACTIONS[e['kind']]}")
    for rid, why in skipped.items():
        print(f"Skipped {rid}: {why}")
    for rid, why in incomplete.items():
        print(f"INCOMPLETE {rid}: {why}")
    if incomplete:
        print("Result: incomplete. A consumer that could not be read may be missing from the waves.")
    return code


def snapshot_dirs(root):
    return sorted((root / "repos").glob("*/snapshots/*/snapshot.json"))


def cmd_stale(args, reg, root):
    import graph  # noqa: PLC0415
    resolved = resolve_all(reg, root)
    rows = []
    for rid, m in sorted(reg.items()):
        res = resolved[rid]
        for ref in m["refs"]:
            row = {"repo": rid, "ref": ref["name"], "pinned": ref["commit"], "source": "not checked", "snapshot": "missing"}
            snap = root / "repos" / rid / "snapshots" / ref["commit"] / "snapshot.json"
            if snap.is_file():
                s = json.loads(snap.read_text())
                same_cfg = s.get("scan_config_hash") == resolver.config_hash(graph.SCAN_CONFIG)
                same_tool = (s.get("tool_versions") or {}).get("graphify") == graph.GRAPHIFY_VERSION
                row["snapshot"] = "current" if same_cfg and same_tool else "outdated (scan config or tool version changed)"
            if res["status"] == "ok":
                tip = resolver.rev(res["path"], f"origin/{ref['name']}") or resolver.rev(res["path"], ref["name"])
                if not tip:
                    row["source"] = "ref missing locally"
                elif tip == ref["commit"]:
                    row["source"] = "current"
                else:
                    ahead = resolver.git(res["path"], "rev-list", "--count", f"{ref['commit']}..{tip}", check=False) or "?"
                    row["source"] = f"outdated: tip {tip[:12]} is {ahead} commits past the pin"
                if resolver.inspect(res["path"])["dirty"]:
                    row["checkout"] = "dirty (uncommitted work is never indexed)"
            else:
                row["source"] = f"not checked ({res['status']})"
            rows.append(row)
    if _print(rows, args.json):
        return OK
    for r in rows:
        extra = f"  checkout {r['checkout']}" if r.get("checkout") else ""
        print(f"{r['repo']}@{r['ref']} {r['pinned'][:12]}  source: {r['source']}  snapshot: {r['snapshot']}{extra}")
    return OK


def tracked_files(root):
    try:
        out = subprocess.run(["git", "-C", str(root), "ls-files", "-co", "--exclude-standard", "-z"], capture_output=True, check=True, env=resolver.GIT_ENV).stdout
        return [root / p for p in out.decode().split("\0") if p]
    except (subprocess.CalledProcessError, FileNotFoundError):
        skip = {".git", ".local", "graphify-out", "__pycache__"}
        return [p for p in root.rglob("*") if p.is_file() and not skip & set(p.relative_to(root).parts)]


def private_path_errors(root):
    errors = []
    for f in tracked_files(root):
        if not f.is_file():
            continue
        try:
            text = f.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        for no, line in enumerate(text.splitlines(), 1):
            if PRIVATE_PATH_RE.search(line):
                errors.append(f"{f.relative_to(root)}:{no}: private machine path")
            if "\u2014" in line:
                errors.append(f"{f.relative_to(root)}:{no}: em dash (atlas style forbids it)")
    return errors


def snapshot_errors(root, reg):
    errors = []
    for p in snapshot_dirs(root):
        rid, sha = p.parts[-4], p.parts[-2]
        where = p.relative_to(root)
        try:
            s = json.loads(p.read_text())
        except ValueError:
            errors.append(f"{where}: invalid JSON")
            continue
        if rid not in reg or s.get("repository_id") != rid:
            errors.append(f"{where}: repository_id does not match its folder")
        if s.get("source_commit") != sha or not _is_sha(sha):
            errors.append(f"{where}: folder must be the full source_commit")
        if s.get("dirty") is not False or s.get("scope") == "local-overlay":
            errors.append(f"{where}: committed snapshots must come from a clean commit, never an overlay")
        if not _is_sha(s.get("source_tree")) or not re.match(r"^[0-9a-f]{64}$", s.get("scan_config_hash") or ""):
            errors.append(f"{where}: needs source_tree and scan_config_hash")
        if not (s.get("tool_versions") or {}).get("graphify") or not s.get("built_at"):
            errors.append(f"{where}: needs tool_versions.graphify and built_at")
    return errors


def evidence_errors(reg, root):
    """Verify authored evidence against real sources. Returns (errors, incomplete)."""
    resolved = resolve_all(reg, root)
    errors, incomplete = [], {}
    for e in authored_edges(reg):
        ev = e.get("evidence") or {}
        if e.get("confidence") != "confirmed":
            continue
        res = resolved[e["frm"]]
        if res["status"] != "ok":
            incomplete[e["frm"]] = f"checkout {res['status']}"
            continue
        sha = ev["source_commit"]
        if not resolver.rev(res["path"], sha):
            incomplete[e["frm"]] = f"commit {sha} not available locally"
            continue
        if resolver.git(res["path"], "cat-file", "-t", f"{sha}:{ev['path']}", check=False) not in ("blob", "tree"):
            errors.append(f"{e['frm']} -> {e['to']}: evidence {ev['path']} does not exist at {sha[:12]}")
            continue
        if e["kind"] in BUILD_KINDS and manifests.is_manifest(ev["path"]):
            text = resolver.git(res["path"], "show", f"{sha}:{ev['path']}")
            parsed = manifests.read(ev["path"], text)
            if not any(_map_dep(d, ev["path"], reg, e["frm"]) == e["to"] for d in parsed["deps"]):
                errors.append(f"{e['frm']} -> {e['to']}: {ev['path']} at {sha[:12]} declares no such dependency")
    for rid, m in reg.items():
        if not m["refs"] or not m["products"] or resolved[rid]["status"] != "ok":
            continue
        base = next((r for r in m["refs"] if r["role"] == "baseline"), m["refs"][0])
        scans, _ = scan_manifests(rid, reg, resolved[rid]["path"], base["commit"])
        found = {(r["path"], p) for r in scans for p in r["products"]}
        for p in m["products"]:
            if (p["manifest"], p["name"]) not in found:
                errors.append(f"{rid}: product {p['name']} not found in {p['manifest']} at {base['commit'][:12]}")
    return errors, incomplete


CHECK_STATUSES = {"passed", "failed", "not-run", "not-applicable", "unavailable"}


def candidate_errors(root, reg):
    """compat/candidates.json: registered repos, full SHAs, known statuses, and no `passed`
    check without the exact package and consumer commits it ran against."""
    p = root / "compat" / "candidates.json"
    if not p.is_file():
        return []
    try:
        data = json.loads(p.read_text())
    except ValueError as exc:
        return [f"compat/candidates.json: invalid JSON ({exc})"]
    errors = []
    for c in data.get("candidates", []):
        where = f"compat/candidates.json: {c.get('id')}"
        pkg = c.get("package") or {}
        if pkg.get("repo") not in reg or not (pkg.get("commit") is None or _is_sha(pkg.get("commit"))):
            errors.append(f"{where}: package needs a registered repo and a full commit (or null)")
        for con in c.get("consumers", []):
            if con.get("repo") not in reg or not _is_sha(con.get("commit")):
                errors.append(f"{where}: consumer needs a registered repo and a full commit")
            for chk in con.get("checks", []):
                if chk.get("status") not in CHECK_STATUSES:
                    errors.append(f"{where}: {con.get('repo')} check status must be one of {sorted(CHECK_STATUSES)}")
                elif chk["status"] == "passed" and not pkg.get("commit"):
                    errors.append(f"{where}: a passed check needs the exact package commit")
                elif chk["status"] == "not-applicable" and not chk.get("reason"):
                    errors.append(f"{where}: {con.get('repo')} not-applicable check needs a reason")
    import compat  # noqa: PLC0415
    return errors + compat.result_errors(root, reg)


def cmd_check(args, reg, root, load_errors):
    errors = load_errors + validate_registry(reg)
    edges = authored_edges(reg)
    incomplete = {}
    if args.sources:
        ev_errors, incomplete = evidence_errors(reg, root)
        errors += ev_errors
        _, derived, scan_incomplete, _ = gather(reg, root, sorted(reg))
        incomplete.update(scan_incomplete)
        edges += derived
        errors += [f"{e['frm']} -> {e['to']} ({e['evidence']['path']}): {msg}" for e in derived
                   for msg in _direction_errors(reg[e["frm"]]["layer"], reg[e["to"]]["layer"], e["kind"])]
    errors += [f"build cycle: {' -> '.join(c)}" for c in build_cycles(edges)]
    errors += snapshot_errors(root, reg)
    errors += candidate_errors(root, reg)
    errors += private_path_errors(root)
    for err in errors:
        print(f"ERROR {err}")
    for rid, why in incomplete.items():
        print(f"INCOMPLETE {rid}: {why}")
    if not args.sources:
        print("Evidence against sources: not checked (run with --sources)")
    if errors:
        print(f"check failed: {len(errors)} error(s)")
        return FAIL
    if incomplete:
        print("check incomplete")
        return INCOMPLETE
    print(f"check passed: {len(reg)} repos, {len(authored_edges(reg))} authored edges")
    return OK


def cmd_doctor(args, reg, root, load_errors):
    import graph  # noqa: PLC0415
    problems = load_errors + validate_registry(reg)
    print(f"atlas {ATLAS_VERSION}, python {sys.version.split()[0]}, {resolver.git(root, '--version', check=False) or 'git unavailable'}")
    print(f"registry: {len(reg)} repos, {len(problems)} problem(s)")
    cfg = root / ".local" / "checkouts.json"
    print(f"local config: {'present' if cfg.is_file() else 'absent (workspace discovery only)'}")
    for rid, res in resolve_all(reg, root).items():
        print(f"  {rid:18} {res['status']:9} {res['path'] or res['reason']}")
    gv = graph.installed_graphify_version()
    pin = "matches pin" if gv == graph.GRAPHIFY_VERSION else f"pin is {graph.GRAPHIFY_VERSION}"
    print(f"graphify: {gv or 'not installed'} ({pin}); sandbox-exec: {'available' if graph.sandbox_available() else 'unavailable'}")
    print(f"snapshots: {len(snapshot_dirs(root))} committed")
    for p in problems:
        print(f"  problem: {p}")
    return FAIL if problems else OK


def main(argv=None):
    ap = argparse.ArgumentParser(prog="atlas", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("doctor", help="read-only health report")
    p = sub.add_parser("locate", help="verified checkout path, branch, commit, dirty state, worktrees")
    p.add_argument("repo")
    p.add_argument("--json", action="store_true")
    for name in ("deps", "impact"):
        p = sub.add_parser(name)
        p.add_argument("repo")
        p.add_argument("--json", action="store_true")
        p.add_argument("--registry-only", action="store_true", help="skip manifest scanning (reported as not checked)")
        if name == "impact":
            p.add_argument("--include-candidates", action="store_true", help="include candidate branches and repos")
    p = sub.add_parser("stale", help="pinned refs and snapshots versus current sources")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("check", help="registry, direction, cycles, snapshots, private paths")
    p.add_argument("--sources", action="store_true", help="also verify evidence and manifests against local checkouts")
    gp = sub.add_parser("graph", help="Graphify navigation snapshots").add_subparsers(dest="gcmd", required=True)
    p = gp.add_parser("plan", help="read-only: what a build would read, exclude and write")
    p.add_argument("targets", nargs="*", help="repo or repo@ref; default every registered ref")
    p = gp.add_parser("build", help="code-only build from an exported commit")
    p.add_argument("target", help="repo or repo@ref")
    p.add_argument("--local-only", action="store_true", required=True, help="required: no model or network calls")
    p = gp.add_parser("merge", help="namespaced local navigation view of built snapshots")
    cp = sub.add_parser("compat", help="candidate package versus recorded consumers (OPS-01)").add_subparsers(dest="ccmd", required=True)
    p = cp.add_parser("plan", help="read-only: workspace layout and what each check would do")
    p.add_argument("candidate", nargs="?")
    p.add_argument("--json", action="store_true")
    p = cp.add_parser("run", help="build consumers against the candidate in disposable workspaces")
    p.add_argument("candidate")
    p.add_argument("--consumer", help="only this consumer repo id")
    p.add_argument("--inject-break", metavar="PATCH", help="apply PATCH to the package inside the workspace only; results go to <candidate>.inject-break.json")
    p.add_argument("--timeout", type=int, default=5400, help="seconds per check (default 5400)")
    args = ap.parse_args(argv)

    root = atlas_root()
    reg, load_errors = load_registry(root)
    if args.cmd == "check":
        return cmd_check(args, reg, root, load_errors)
    if args.cmd == "doctor":
        return cmd_doctor(args, reg, root, load_errors)
    if load_errors:
        print("\n".join(load_errors), file=sys.stderr)
        return USAGE
    if args.cmd == "graph":
        import graph  # noqa: PLC0415
        return graph.run(args, reg, root)
    if args.cmd == "compat":
        import compat  # noqa: PLC0415
        return compat.run(args, reg, root)
    return {"locate": cmd_locate, "deps": cmd_deps, "impact": cmd_impact, "stale": cmd_stale}[args.cmd](args, reg, root)


if __name__ == "__main__":
    sys.exit(main())
