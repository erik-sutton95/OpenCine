"""Hub commands: work on every app from the OpenCine checkout (HUB-01). Standard library only.

  ensure      resolve or clone each registered checkout next to OpenCine (--check writes nothing)
  impact      for a symbol or path: the owning target or module, the apps that link it (from
              their manifests) and where they use it (source search)
  issues      open issues across every registered GitHub repository (gh; offline-safe)
  task start  one task folder with a worktree per repository and a TASK.md brief; never commits
              or pushes
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

import atlas
import manifests
import resolver
import linked_issues

OK, FAIL, USAGE, INCOMPLETE = atlas.OK, atlas.FAIL, atlas.USAGE, atlas.INCOMPLETE
CODE_GLOBS = ["*.swift", "*.kt", "*.java", "*.c", "*.h", "*.cc", "*.cpp", "*.hpp", "*.m", "*.mm",
              "*.metal", "*.glsl", "*.vert", "*.frag", "*.comp"]
DECL_KEYWORDS = r"class|struct|enum|protocol|actor|extension|typealias|func|var|let|case|interface|object|fun|val"
# Top-level types a file exports (column 0, not private, fileprivate or internal): the names an app can use.
TYPE_DECL = re.compile(r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|open|final|data|sealed|abstract|enum|annotation|inline|value|"
                       r"indirect|nonisolated)\s+)*(?:class|struct|enum|protocol|actor|interface|object|typealias)\s+([A-Z]\w*)", re.M)
OFFLINE = re.compile(r"error connecting|dial tcp|no such host|could not resolve host|network is unreachable|timed? ?out|connection refused", re.I)
GITHUB = re.compile(r"^https://github\.com/([^/]+/[^/]+?)(?:\.git)?/?$")


# ---------------------------------------------------------------- shared helpers

def platform(reg, root):
    """(id, checkout path or None). The platform is the one registry entry with `layers`."""
    pid, top = atlas.enclosing_platform(root, reg)
    if pid:
        return pid, top
    pid = next((rid for rid, m in reg.items() if m.get("layers")), None)
    if not pid:
        return None, None
    res = resolver.resolve(reg[pid], root)
    return pid, Path(res["path"]) if res["status"] == "ok" else None


def workspace(root, reg):
    """Folder that holds the sibling checkouts: local config, environment, else next to OpenCine."""
    cfg = resolver.load_local_config(root)
    for w in (cfg.get("workspace"), os.environ.get("OPENCAPTURE_WORKSPACE")):
        if w and not w.startswith("<"):
            return Path(w).expanduser()
    _, top = atlas.enclosing_platform(root, reg)
    return (top or Path(root).resolve()).parent


def primary_ref(m, pid):
    """The ref a repo is worked on: the one its build edge to the platform names, else its baseline."""
    named = next((e.get("ref") for e in m["edges"] if e["to"] == pid and e["kind"] in atlas.BUILD_KINDS and e.get("ref")), None)
    refs = m["refs"]
    return (next((r for r in refs if r["name"] == named), None) or next((r for r in refs if r["role"] == "baseline"), None)
            or (refs[0] if refs else None))


def ref_tip(path, ref):
    """Current ref tip, without rewinding a registered revision to a stale local branch."""
    recorded = resolver.rev(path, ref.get("commit")) if ref.get("commit") else None
    for cand in (f"refs/heads/{ref['name']}", f"refs/remotes/origin/{ref['name']}", ref.get("commit")):
        sha = cand and resolver.rev(path, cand)
        if sha:
            if recorded and sha != recorded and resolver.git(path, "merge-base", sha, recorded, check=False) == sha:
                continue
            return sha
    return recorded


def github_repo(m):
    found = GITHUB.match((m.get("repository") or {}).get("url") or "")
    return found.group(1) if found else None


def gh_run(args):
    """Every GitHub call goes through here (tests replace it)."""
    return subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60)


def find_repo(spec, reg):
    low = spec.lower()
    return next((rid for rid, m in reg.items() if low in (rid, m["local_dir"].lower(), m["display_name"].lower())), None)


# ---------------------------------------------------------------- ensure

def cmd_ensure(args, reg, root):
    cfg = resolver.load_local_config(root)
    pid, top = atlas.enclosing_platform(root, reg)
    ws = workspace(root, reg)
    failed = incomplete = False
    print(f"workspace {ws}")
    for rid, m in sorted(reg.items()):
        if rid == pid:
            print(f"  {rid:16} this checkout {top}")
            continue
        res = resolver.resolve(m, root, config=cfg)
        if res["status"] == "ok":
            info = resolver.inspect(res["path"])
            refs = ", ".join(f"{r['name']} {'ok' if resolver.rev(res['path'], r['commit']) else 'MISSING (fetch it)'}" for r in m["refs"])
            print(f"  {rid:16} ok   {res['path']}  [{info['branch'] or 'detached'}]{' DIRTY' if info['dirty'] else ''}  refs: {refs or 'none'}")
            continue
        explicit = (cfg.get("repos") or {}).get(rid)
        if explicit and explicit.startswith("<"):
            print(f"  {rid:16} placeholder path in atlas/.local/checkouts.json: replace it or remove the entry")
            failed = True
            continue
        dest = Path(explicit or ws / m["local_dir"]).expanduser()
        url = (m.get("repository") or {}).get("url")
        if res["status"] != "missing" or dest.exists():
            print(f"  {rid:16} {res['status'].upper()}: {res['reason']} (fix it or map it in atlas/.local/checkouts.json)")
            failed = True
            continue
        if not url:
            print(f"  {rid:16} MISSING: no repository URL registered yet, nothing to clone")
            incomplete = True
            continue
        if args.check:
            print(f"  {rid:16} would clone {url} -> {dest}")
            incomplete = True
            continue
        r = subprocess.run(["git", "clone", "-q", url, str(dest)], capture_output=True, text=True)
        if r.returncode:
            print(f"  {rid:16} clone FAILED: {r.stderr.strip()}")
            failed = True
            continue
        ident = {k: v for k, v in (cfg.get("identity") or {}).items() if v and not v.startswith("<")}
        for key in ("name", "email"):
            if ident.get(key):
                resolver.git(dest, "config", f"user.{key}", ident[key])
        print(f"  {rid:16} cloned {url} -> {dest}" + (f" (identity {ident.get('email')})" if ident.get("email") else ""))
    if args.check:
        print("check only: nothing was written")
    return FAIL if failed else INCOMPLETE if incomplete else OK


# ---------------------------------------------------------------- impact <symbol|path>

def _swift_units(files):
    """Targets ({name: {path, deps}}) and products ({name: [targets]}) of Package.swift."""
    text = files.get("Package.swift", "")
    pkg = manifests.read("Package.swift", text)
    targets = {}
    for t in pkg.get("targets", []):
        base = "Tests" if t["kind"] == "testTarget" else "Sources"
        targets[t["name"]] = {"path": (t["path"] or f"{base}/{t['name']}").rstrip("/") + "/",
                              "deps": [d["name"] for d in t["deps"] if "package" not in d]}
    body = manifests.strip_comments(text)
    products = {n: re.findall(r'"([^"]+)"', ts) for n, ts in re.findall(r'\.library\(\s*name:\s*"([^"]+)"[^)]*?targets:\s*\[([^\]]*)\]', body)}
    return targets, products


def _gradle_units(files):
    mods = {}
    for rel, text in files.items():
        found = re.match(r"^Android/([^/]+)/build\.gradle\.kts$", rel)
        if found:
            mods[f":{found.group(1)}"] = {"path": f"Android/{found.group(1)}/", "deps": manifests.read(rel, text)["projects"]}
    return mods


def _closure(units, roots):
    seen, todo = set(), list(roots)
    while todo:
        n = todo.pop()
        if n in units and n not in seen:
            seen.add(n)
            todo += units[n]["deps"]
    return seen


def owner_of(rel, units):
    """Longest unit path that contains rel."""
    hits = [(len(u["path"]), name) for name, u in units.items() if rel.startswith(u["path"])]
    return max(hits)[1] if hits else None


def linked_products(path, commit, plat_meta):
    """Platform products an app's manifests at `commit` reference (manifests decide linkage)."""
    names = [n for n in resolver.git(path, "ls-tree", "-r", "--name-only", commit).splitlines() if manifests.is_manifest(n)]
    text = "\n".join(resolver.git(path, "show", f"{commit}:{n}", check=False) for n in names)
    pkg = re.escape(plat_meta["local_dir"])
    out = set()
    for p in plat_meta["products"]:
        name = re.escape(p["name"])
        if p["kind"] == "gradle-module":
            rx = re.escape(p.get("coordinates") or "") + r"(?![\w-])"
        else:
            rx = rf'name:\s*"{name}"\s*,\s*package:\s*"{pkg}"|package:\s*{pkg}\s*\n\s*product:\s*{name}\b|productName = "?{name}"?;'
        if re.search(rx, text):
            out.add(p["name"])
    return out


def grep(path, patterns, commit=None, limit=10, decl=False):
    """git grep for identifiers at a commit (or the working tree). Returns (lines, total)."""
    if not patterns:
        return [], 0
    if decl:
        args = ["grep", "-n", "-I", "-E"] + [x for p in patterns for x in (
            "-e", rf"(^|[^[:alnum:]_])({DECL_KEYWORDS})[[:space:]]+{re.escape(p)}([^[:alnum:]_]|$)")]
    else:
        args = ["grep", "-n", "-I", "-w", "-F"] + [x for p in patterns for x in ("-e", p)]
    out = resolver.git(path, *args, *([commit] if commit else []), "--", *CODE_GLOBS, check=False)
    lines = [ln.split(":", 1)[1] if commit and ln.startswith(commit) else ln for ln in out.splitlines()]
    return lines[:limit], len(lines)


def cmd_impact_symbol(args, reg, root):
    target, limit, text = args.repo, args.limit, []
    def say(*lines):
        text.extend(lines)
    pid, top = platform(reg, root)
    if not pid or not top:
        print("the OpenCine platform checkout is not available (run atlas ensure)", file=sys.stderr)
        return INCOMPLETE
    files = atlas.platform_files_at(top)
    targets, products = _swift_units(files)
    modules = _gradle_units(files)
    units = {**targets, **modules}
    is_path = "/" in target or (top / target).exists()
    head = resolver.git(top, "rev-parse", "HEAD")
    if is_path:
        if not (top / target).exists():
            print(f"{target}: no such path in {top} (paths are relative to the OpenCine root)", file=sys.stderr)
            return USAGE
        src = [top / target] if (top / target).is_file() else sorted(p for p in (top / target).rglob("*") if p.is_file())
        symbols = sorted({s for p in src if p.suffix in {".swift", ".kt", ".java"} for s in TYPE_DECL.findall(p.read_text(errors="replace"))})
        decl_files = [target.rstrip("/") + ("/" if (top / target).is_dir() else "")]
    else:
        symbols = [target]
        decl_files = sorted({d.split(":", 1)[0] for d in grep(top, symbols, limit=50, decl=True)[0]})
    owners = sorted({o for f in decl_files if (o := owner_of(f, units))})
    plat_meta = reg[pid]
    layer_of = {n: layer for layer, names in (plat_meta.get("layers") or {}).items() for n in names}
    # A product carries every target it reaches, so a Core symbol ships in every product above Core.
    carriers = {p for p, ts in products.items() if set(owners) & _closure(targets, ts)}
    carriers |= {m for m in modules if set(owners) & _closure(modules, [m])}
    uses, total = grep(top, symbols, limit=10 ** 6)
    by_unit = defaultdict(int)
    for ln in uses:
        by_unit[owner_of(ln.split(":", 1)[0], units) or "other"] += 1
    out = {"target": target, "kind": "path" if is_path else "symbol", "symbols": symbols, "declared_in": decl_files,
           "owners": {o: layer_of.get(o, "unassigned") for o in owners}, "products": sorted(carriers),
           "platform": {"checkout": str(top), "head": head, "uses": dict(by_unit)}, "apps": {}}
    say(f"{target}: {out['kind']} in the {plat_meta['display_name']} working tree ({head[:12]})")
    if is_path:
        say(f"  declares {len(symbols)} type(s): {', '.join(symbols[:12])}{' ...' if len(symbols) > 12 else ''}")
    say(*[f"  declared in {f}" for f in decl_files[:limit]] or ["  declaration: none found in OpenCine (app-owned, or a form this search does not read)"])
    for o in owners:
        say(f"  owner: {o} (layer {layer_of.get(o, 'unassigned')})")
    if owners:
        say(f"  shipped in: {', '.join(sorted(carriers)) or 'nothing (test or developer-only target)'}")
    say(f"  uses in {plat_meta['display_name']}: {total}" + (f" ({', '.join(f'{u} {c}' for u, c in sorted(by_unit.items()))})" if by_unit else ""))
    code, found = OK, bool(decl_files and not is_path) or total > 0
    for rid, m in sorted(reg.items()):
        if rid == pid or m["layer"] != "app":
            continue
        ref = {"name": args.app_ref, "commit": None} if args.app_ref else primary_ref(m, pid)
        res = resolver.resolve(m, root)
        tip = ref_tip(res["path"], ref) if ref and res["status"] == "ok" else None
        if not tip:
            why = "no registered ref" if not ref else f"checkout {res['status']}" if res["status"] != "ok" else f"{ref['name']} not available locally"
            say(f"{m['display_name']}: INCOMPLETE, {why} (python3 atlas/tools/atlas.py ensure)")
            out["apps"][rid] = {"status": "incomplete", "reason": why}
            code = INCOMPLETE
            continue
        via = sorted(linked_products(res["path"], tip, plat_meta) & carriers)
        lines, n = grep(res["path"], symbols, commit=tip, limit=limit)
        own, _ = grep(res["path"], symbols, commit=tip, limit=limit, decl=True)
        found = found or n > 0
        out["apps"][rid] = {"ref": ref["name"], "commit": tip, "links": via, "uses": n, "sample": lines, "declares": own}
        verdict = f"links {', '.join(via)}" if via else ("does not link the owner" if owners else "no OpenCine owner")
        say(f"{m['display_name']} @ {ref['name']} {tip[:12]}: {verdict}; {n} use(s)")
        say(*[f"    declares its own (a copy, or an app-owned type with this name): {ln[:140]}" for ln in own])
        say(*[f"    {ln[:160]}" for ln in lines])
        if n > len(lines):
            say(f"    ... {n - len(lines)} more (--limit)")
    if not found:
        say("nothing found: not declared in OpenCine and not used in any app")
        code = FAIL
    print(json.dumps(out, indent=2, sort_keys=True) if args.json else "\n".join(text))
    return code


# ---------------------------------------------------------------- issues

def cmd_issues(args, reg, root):
    if not shutil.which("gh"):
        print("gh (GitHub CLI) is not installed: issues not listed. Install it from https://cli.github.com.")
        return OK
    picked = [find_repo(r, reg) or r for r in args.repos] or sorted(reg)
    unknown = [r for r in picked if r not in reg]
    if unknown:
        print(f"unknown repo {', '.join(unknown)}; registered: {', '.join(sorted(reg))}", file=sys.stderr)
        return USAGE
    code, everything = OK, {}
    for rid in picked:
        m, repo = reg[rid], github_repo(reg[rid])
        if not repo:
            print(f"{m['display_name']}: no GitHub repository registered yet, skipped")
            continue
        try:
            r = gh_run(["issue", "list", "--repo", repo, "--state", "open", "--limit", str(args.limit),
                        "--json", "number,title,labels,updatedAt,url"])
        except subprocess.TimeoutExpired:
            print("offline: GitHub did not answer, issues not listed")
            return OK
        if r.returncode:
            if OFFLINE.search(r.stderr):
                print("offline: GitHub is unreachable, issues not listed")
                return OK
            print(f"{m['display_name']}: gh failed: {r.stderr.strip() or r.returncode}")
            code = FAIL
            continue
        issues = json.loads(r.stdout or "[]")
        everything[rid] = issues
        if args.json:
            continue
        print(f"{m['display_name']} ({repo}): {len(issues)} open")
        for i in issues:
            labels = ", ".join(lb["name"] for lb in i.get("labels", []))
            print(f"  {rid}#{i['number']:<5} {i['title'][:90]}{f'  [{labels}]' if labels else ''}  {i.get('updatedAt', '')[:10]}")
    if args.json:
        print(json.dumps(everything, indent=2, sort_keys=True))
    elif everything:
        print("start one: python3 atlas/tools/atlas.py task start <repo>#<number>")
    return code


# ---------------------------------------------------------------- task start

def fetch_issue(m, number):
    repo = github_repo(m)
    if not repo:
        return None, "the repository has no GitHub URL yet"
    if not shutil.which("gh"):
        return None, "gh is not installed"
    try:
        r = gh_run(["issue", "view", str(number), "--repo", repo, "--json", "number,title,body,labels,url,state,author"])
    except subprocess.TimeoutExpired:
        return None, "GitHub did not answer"
    if r.returncode:
        return None, ("offline" if OFFLINE.search(r.stderr) else r.stderr.strip())
    return json.loads(r.stdout), None


def _worktree(checkout, dest, branch, base):
    """Create or reuse a task worktree. `branch` None means detached at `base`."""
    if dest.exists():
        if dest.is_symlink() or Path(resolver.git(dest, "rev-parse", "--show-toplevel")).resolve() != dest.resolve() \
                or resolver.git(dest, "rev-parse", "--path-format=absolute", "--git-common-dir") \
                != resolver.git(checkout, "rev-parse", "--path-format=absolute", "--git-common-dir"):
            raise resolver.GitError(f"{dest} is not an exact worktree of the requested repository; preserve its owner")
        have = resolver.git(dest, "symbolic-ref", "--quiet", "--short", "HEAD", check=False) or None
        if have == branch and (branch or resolver.git(dest, "rev-parse", "HEAD") == base):
            return "reused"
        # A clean detached reference (an app's pinned OpenCine) becomes the task branch on request.
        if branch and have is None and not resolver.rev(checkout, f"refs/heads/{branch}") \
                and not resolver.git(dest, "status", "--porcelain"):
            resolver.git(dest, "checkout", "-q", "-b", branch, base)
            return "switched"
        raise resolver.GitError(f"{dest} exists but is not the task worktree ({have or 'detached'}); remove it or pick another task")
    dest.parent.mkdir(parents=True, exist_ok=True)
    if branch is None:
        resolver.git(checkout, "worktree", "add", "-q", "--detach", str(dest), base)
    elif resolver.rev(checkout, f"refs/heads/{branch}"):
        resolver.git(checkout, "worktree", "add", "-q", str(dest), branch)
    else:
        resolver.git(checkout, "worktree", "add", "-q", "-b", branch, str(dest), base)
    return "created"


def cmd_task_start(args, reg, root):
    found = re.match(r"^([\w.-]+)#(\d+)$", args.issue)
    rid = find_repo(found.group(1), reg) if found else None
    if not rid:
        print(f"{args.issue}: expected <repo>#<number> with a registered repo ({', '.join(sorted(reg))})", file=sys.stderr)
        return USAGE
    number = int(found.group(2))
    extra = [find_repo(r, reg) or r for r in args.with_repos]
    if [r for r in extra if r not in reg]:
        print(f"unknown repo in --with: {', '.join(r for r in extra if r not in reg)}", file=sys.stderr)
        return USAGE
    pid, _ = platform(reg, root)
    issue, why = fetch_issue(reg[rid], number)
    tracking = None
    if rid == pid and issue:
        config_path = Path(root) / "issue-sync.json"
        bot = json.loads(config_path.read_text())["bot_login"] if config_path.exists() else "opencine-atlas-sync[bot]"
        link = None
        # Ordinary Core reports can quote any marker syntax. Creator authority
        # precedes parsing; only sync-owned trackers can redirect to an app.
        author = issue.get("author") or {}
        login = author.get("login") or ""
        if author.get("is_bot") is True and login.startswith("app/"):
            login = login.removeprefix("app/") + "[bot]"
        if login == bot:
            try:
                link = linked_issues.parse_link(issue.get("body"), reg)
            except linked_issues.SyncError as exc:
                print(f"cannot route linked issue: {exc}", file=sys.stderr)
                return FAIL
        if link:
            if args.from_file:
                print("linked trackers require the original issue; --from-file cannot override their identity", file=sys.stderr)
                return USAGE
            tracking = {"repo": rid, "number": number, "url": issue.get("url")}
            if tracking["url"] != f"https://github.com/{github_repo(reg[rid])}/issues/{number}":
                print("invalid central tracking issue URL", file=sys.stderr)
                return FAIL
            rid, number = link["app"], link["number"]
            issue, why = fetch_issue(reg[rid], number)
            if not issue or issue.get("url") != link["url"] or issue.get("number") != number:
                print(f"original {rid}#{number} unavailable or invalid ({why or 'identity mismatch'}); no worktrees created", file=sys.stderr)
                return INCOMPLETE
            extra.insert(0, pid)
            print(f"linked   {tracking['repo']}#{tracking['number']} -> {rid}#{number} (original source of truth)")
    repos = list(dict.fromkeys([rid, *extra]))
    task = f"{rid}-{number}"
    branch = f"issue/{task}"
    session = None
    cfg = resolver.load_local_config(root)
    if getattr(args, "orca", False):
        import orca_tasks
        try:
            session = orca_tasks.OrcaTasks(reg, root)
            cfg = session.config()
        except orca_tasks.OrcaError as exc:
            print(str(exc), file=sys.stderr)
            return INCOMPLETE
    ws = workspace(root, reg)
    if session and not cfg.get("workspace") and not os.environ.get("OPENCAPTURE_WORKSPACE"):
        ws = Path(session.repo(pid)["path"]).resolve().parent
    folder = ws / "OpenCine-tasks" / task
    if args.from_file:
        title, _, body = Path(args.from_file).read_text().strip().partition("\n")
        given = {"title": title.strip().lstrip("# "), "body": body.strip()}
        issue = dict(issue or {"url": f"text given by the user, not on GitHub ({why})"}, **given)
        why = None
    if session:
        try:
            with session.lock(folder):
                return _start_task_worktrees(args, reg, root, cfg, session, rid, number, pid, repos, branch, folder, issue, why, tracking)
        except (orca_tasks.OrcaError, OSError, ValueError) as exc:
            print(f"Orca task incomplete: {exc}; preserve the task folder and rerun the same command", file=sys.stderr)
            return INCOMPLETE
    return _start_task_worktrees(args, reg, root, cfg, session, rid, number, pid, repos, branch, folder, issue, why, tracking)


def _start_task_worktrees(args, reg, root, cfg, session, rid, number, pid, repos, branch, folder, issue, why, tracking):
    if session:
        tracking = session.task_tracking(folder, rid, number, pid, tracking)
        if tracking and pid not in repos:
            repos = [*repos, pid]
    rows, pins = [], {}
    for r in repos:
        m = reg[r]
        res = resolver.resolve(m, root, config=cfg)
        if res["status"] != "ok":
            print(f"{r}: checkout {res['status']}: {res['reason']} (python3 atlas/tools/atlas.py ensure)", file=sys.stderr)
            return INCOMPLETE
        ref = ({"name": args.base} if args.base and r == rid else None) or (
            {"name": m["repository"]["default_branch"]} if r == pid else primary_ref(m, pid))
        base = ref and (resolver.rev(res["path"], f"refs/remotes/origin/{ref['name']}") or resolver.rev(res["path"], ref["name"]))
        if not base:
            print(f"{r}: base {ref['name'] if ref else '(none registered)'} not found locally; fetch it or pass --base", file=sys.stderr)
            return INCOMPLETE
        dest = folder / m["local_dir"]
        pin = resolver.git(res["path"], "show", f"{base}:opencine-pins.txt", check=False)
        for ln in pin.splitlines():
            parts = ln.split()
            if len(parts) == 2 and not ln.startswith("#"):
                pins.setdefault(parts[0], (parts[1], r))
        rows.append({"repo": r, "path": dest, "branch": branch, "base": f"{ref['name']} @ {base[:12]}", "base_sha": base,
                     "instructions": m.get("instructions", []), "checkout": res["path"]})
    plat = reg.get(pid)
    if plat and pid not in repos and plat["local_dir"] in pins:
        sha, by = pins[plat["local_dir"]]
        res = resolver.resolve(plat, root, config=cfg)
        dest = folder / plat["local_dir"]
        if res["status"] == "ok" and resolver.rev(res["path"], sha):
            rows.append({"repo": pid, "path": dest, "branch": None, "base": f"{by}'s pin @ {sha[:12]} (detached, read-only reference)",
                         "base_sha": sha, "instructions": plat.get("instructions", []), "checkout": res["path"]})
        else:
            print(f"warning: {pid} pin {sha[:12]} not available locally; {by} has no sibling OpenCine in the task folder")
            if session:
                return INCOMPLETE
    if session:
        session.preflight(rows, rid, number, pid, tracking)
    for row in rows:
        try:
            row["state"] = _worktree(row["checkout"], row["path"], row["branch"], row["base_sha"])
        except resolver.GitError as exc:
            print(str(exc), file=sys.stderr)
            return FAIL
    brief = folder / "TASK.md"
    text = task_brief(rid, number, issue, why, rows, reg, pid)
    if brief.exists():
        # A rerun (for example --with opencine) keeps what was written into the brief.
        table = text[text.index("## Worktrees"):text.index("## Routing decision")]
        addition = table.replace("## Worktrees", "## Worktrees after a rerun of task start", 1)
        if addition not in brief.read_text():
            with brief.open("a") as fh:
                fh.write("\n" + addition)
    else:
        brief.write_text(text)
    if tracking:
        line = (f"Linked tracking issue: {tracking['url']} ({tracking['repo']}#{tracking['number']}).\n"
                f"Original source of truth: https://github.com/{github_repo(reg[rid])}/issues/{number}. "
                "The original remains the canonical task and PR reference; hosted sync carries paired closure/reopening. "
                "Verify both actual states when reporting completion.\n")
        if line not in brief.read_text():
            with brief.open("a") as fh:
                fh.write("\n## Linked issue identities\n\n" + line)
    if session:
        receipt = session.adopt(rows, folder, rid, number, pid, tracking)
        note = ("\n## Orca task custody\n\n"
                "These Git worktrees are adopted/discovered through Orca's public catalog. "
                "Continue this agent in the task worktrees; no additional agent is started.\n"
                "Local receipt: `.atlas-orca.json`. On partial failure preserve work and rerun the same task command. "
                "Use Orca worktree removal after merge or deliberate abandonment; retain unique notes first.\n")
        if note not in brief.read_text():
            with brief.open("a") as fh:
                fh.write(note)
        for row in rows:
            cleanup = f"git -C {row['checkout']} worktree remove {row['path']}"
            # Replace only generated cleanup lines, keeping the rest of the operator's brief.
            text = brief.read_text().replace(cleanup, f"orca worktree rm --worktree path:{row['path'].resolve()} --json")
            brief.write_text(text)
        if not receipt["complete"]:
            print(f"Orca adoption incomplete: {receipt['error']}; preserved work and receipt {folder / '.atlas-orca.json'}", file=sys.stderr)
            return INCOMPLETE
        print(f"orca     adopted/discovered {len(receipt['adopted'])} verified worktrees; {folder / '.atlas-orca.json'}")
    want = ((resolver.load_local_config(root).get("identity") or {}).get("email") or "")
    want = None if want.startswith("<") else want
    for row in rows:
        print(f"{row['state']:8} {row['path']}  [{row['branch'] or 'detached'}]  base {row['base']}")
        have = resolver.git(row["path"], "config", "user.email", check=False)
        if want and have != want:
            print(f"WARNING  commits in {row['path']} would use {have or 'no email'}, not {want}: "
                  f"git -C {row['checkout']} config user.email {want}")
    print(f"brief    {brief}")
    if why:
        print(f"note     issue text not fetched ({why}); the brief links the issue instead")
    return OK


def task_brief(rid, number, issue, why, rows, reg, pid):
    m = reg[rid]
    url = (issue or {}).get("url") or (f"https://github.com/{github_repo(m)}/issues/{number}" if github_repo(m) else "(no remote yet)")
    title = (issue or {}).get("title") or "(issue text not fetched)"
    labels = ", ".join(lb["name"] for lb in (issue or {}).get("labels", [])) or "none"
    body = ((issue or {}).get("body") or f"Not fetched ({why}). Read it at {url}.").strip()
    if len(body) > 4000:
        body = body[:4000] + "\n\n(truncated; read the rest on GitHub)"
    table = "\n".join(
        f"| {r['repo']} | `{r['path']}` | {('`' + r['branch'] + '`') if r['branch'] else 'detached'} | {r['base']} | "
        f"{', '.join(r['instructions']) or 'README.md'} | `{resolver.git(r['path'], 'config', 'user.email', check=False) or 'unset'}` |"
        for r in rows)
    shared = pid in [r["repo"] for r in rows if r["branch"]]
    cleanup = "\n".join(f"git -C {r['checkout']} worktree remove {r['path']}" for r in rows) + "".join(
        f"\ngit -C {r['checkout']} branch -d {r['branch']}   # after it is merged" for r in rows if r["branch"])
    has_plat = any(r["repo"] == pid for r in rows)
    sibling = (f"Each app's `../OpenCine` resolves to the OpenCine folder in this task folder, so app builds use\n"
               f"{'this task branch of OpenCine' if shared else 'the OpenCine commit the app pins'}." if has_plat else
               "No repository here uses OpenCine at its base (no `opencine-pins.txt`), so there is no OpenCine folder.")
    pins = sorted({(r["repo"], ln.split()[1]) for r in rows if r["repo"] != pid
                   for ln in resolver.git(r["path"], "show", "HEAD:opencine-pins.txt", check=False).splitlines()
                   if len(ln.split()) == 2 and not ln.startswith("#")})
    plat_row = next((r for r in rows if r["repo"] == pid and r["branch"]), None)
    pin_note = "".join(f"\n- {app} pins OpenCine {sha[:12]}" + (f"; this task's OpenCine starts at {plat_row['base']}, so the app"
                                                                   " builds against newer OpenCine than it ships until its pin moves." if plat_row else ".")
                       for app, sha in pins)
    return f"""# {m['display_name']}#{number}: {title}

Status: in progress
Requested scope: fix this issue in the worktrees below. Merging, pushing, opening a PR, tagging,
publishing or moving an app pin each need explicit authorization (OpenCine AGENTS.md).
Issue: {url} (state {(issue or {}).get('state', 'unknown')}, labels {labels})

## Issue text

{body}

## Worktrees

| Repo | Worktree | Branch | Base | Instructions (read in the worktree) | Commit identity |
|---|---|---|---|---|---|
{table}

{sibling} Check the commit identity column (the worktree's git config) before the first commit.
Bases are local refs, read without fetching; fetch in the checkout and start again if they are stale.{pin_note}

## Routing decision (fill in before editing)

- Platforms affected (iOS, Android, both): Swift and Kotlin owners can differ.
- App-only or shared, and the owning target or module:
- Evidence (`atlas impact` lines, files read):

## Route before editing

1. Decide app-only or shared, from the OpenCine checkout:
   `python3 atlas/tools/atlas.py impact <symbol or path>` (declaration owner, apps that link it, call sites).
2. Shared code is fixed in OpenCine, never in an app copy.{'' if shared else f''' Add the OpenCine worktree on this
   task branch by rerunning `task start` with the same flags plus `--with {pid}`; existing worktrees
   and this file are kept.'''}
3. Follow the capability-not-brand and import rules in OpenCine `AGENTS.md`.

## Completion gate

- Each changed repository: its own checks, run in its worktree (iOS tests on a private simulator:
  `xcrun simctl create` plus `-derivedDataPath`; never the shared default simulator).
- A shared change: every app that `atlas impact` lists as linking the owner builds and passes its
  tests against this task's OpenCine worktree.
- Operator-visible behavior: proven on a physical device, or reported as `untested`.

## Handoff

- Commits per worktree (`git log <base>..HEAD`), checks run with results, hardware evidence or
  `untested`, remaining work, and the merge order (OpenCine first, then each app's pin move).

## Cleanup (after the work is merged or abandoned)

```sh
{cleanup}
```
"""
