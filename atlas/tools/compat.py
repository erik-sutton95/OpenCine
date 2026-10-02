"""Candidate consumer validation (plan 11.5, OPS-01). Standard library only.

`compat plan` is read-only. `compat run <candidate>` checks every consumer recorded in
compat/candidates.json at its exact commit against the candidate package at its exact
commit, inside a disposable workspace:

    <system temp>/atlas-compat-XXXX/
        <consumer local_dir>/   git clone --shared --no-checkout, checkout --detach <commit>
        <package local_dir>/    the same, so the consumer's ../<package> paths resolve here
        (anything recipes put under $ATLAS_COMPAT_WORKSPACE, e.g. DerivedData)

`clone --shared` reads objects through alternates and writes nothing to the source
checkouts, so there is no worktree metadata to prune. The workspace is deleted when the
consumer is done, also on failure or interrupt.

A check is one of:
  recipe          shell command at the consumer root; exit 0 is required to pass.
                  `resolves_package: true` also requires the output to name the package
                  by an absolute path inside the workspace; `expect` lists regexes that
                  must appear. Any package path outside the workspace fails every check.
  fingerprint     {command, touch}: the command's output must change after a one-byte edit
                  to <package>/<touch> (restored afterwards).
  native_outputs  globs under the consumer: native binaries the run must have built itself.
                  The fresh workspace must hold no native binaries before the checks run.
A check without any of these keeps its recorded status and reason. A consumer's
`pin_file` (`<Name> <sha>` lines) is read at its commit and recorded as
`pinned_package_commit`; the workspace always holds the candidate commit instead. Recipes see
$ATLAS_COMPAT_WORKSPACE and $ATLAS_COMPAT_PACKAGE_COMMIT.

Statuses: passed, failed, not-run, not-applicable, unavailable. A missing checkout, commit,
tool or environment directory, or a failed acquisition is unavailable, never passed.
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import resolver

STATUSES = ("passed", "failed", "not-run", "not-applicable", "unavailable")
OK, FAIL, USAGE, INCOMPLETE = 0, 1, 2, 3
NATIVE_SUFFIXES = (".so", ".a", ".dylib")
TAIL = 30
DEFAULT_TIMEOUT = 5400


def candidates_path(root):
    return Path(root) / "compat" / "candidates.json"


def results_path(root, cid, inject=False):
    return Path(root) / "compat" / "results" / f"{cid}{'.inject-break' if inject else ''}.json"


def load(root):
    p = candidates_path(root)
    return json.loads(p.read_text()) if p.is_file() else {"candidates": []}


def _dump(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2) + "\n")


def _now():
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def kind(check):
    for k in ("recipe", "fingerprint", "native_outputs"):
        if check.get(k):
            return k
    return None


# ---------------------------------------------------------------- environment

def missing_requirements(check, env):
    """Reason the check cannot run on this machine, or None."""
    tools = [t for t in check.get("tools", []) if not shutil.which(t, path=env.get("PATH"))]
    dirs = [v for v in check.get("env", []) if not env.get(v) or not Path(env[v]).is_dir()]
    bits = ([f"missing tool {', '.join(tools)}"] if tools else []) + ([f"{', '.join(dirs)} unset or not a directory"] if dirs else [])
    return "; ".join(bits) or None


def _first_line(cmd, env):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    lines = [ln.strip() for ln in (r.stdout + r.stderr).splitlines() if ln.strip()]
    return " ".join(lines[:2]) if cmd[0].endswith("xcodebuild") else (lines[0] if lines else None)


def toolchain(env):
    java = Path(env["JAVA_HOME"]) / "bin" / "java" if env.get("JAVA_HOME") else "java"
    return {
        "swift": _first_line(["swift", "--version"], env),
        "xcodebuild": _first_line(["xcodebuild", "-version"], env),
        "java": _first_line([str(java), "-version"], env),
        "just": _first_line(["just", "--version"], env),
        "xcodegen": _first_line(["xcodegen", "--version"], env),
        "git": _first_line(["git", "--version"], env),
        "swift_sdks": _first_line(["swift", "sdk", "list"], env),
        "android_ndk": sorted(p.name for p in (Path(env["ANDROID_HOME"]) / "ndk").glob("*")) if env.get("ANDROID_HOME") else None,
    }


def gradle_wrappers(consumer_dir):
    """{wrapper properties path: gradle distribution} for the consumer checkout."""
    out = {}
    for p in sorted(Path(consumer_dir).glob("**/gradle/wrapper/gradle-wrapper.properties")):
        m = re.search(r"distributionUrl=.*?gradle-([\w.-]+?)-(?:bin|all)\.zip", p.read_text())
        out[str(p.relative_to(consumer_dir))] = m.group(1) if m else None
    return out


# ---------------------------------------------------------------- sources

def source(reg, root, rid, commit, config):
    """(checkout path, None) when the registered repo has `commit` locally, else (None, reason)."""
    if rid not in reg:
        return None, f"{rid} is not a registered repo"
    res = resolver.resolve(reg[rid], root, config=config)
    if res["status"] != "ok":
        return None, f"{rid} checkout {res['status']}: {res['reason']}"
    if not resolver.rev(res["path"], commit or ""):
        return None, f"commit {commit} not in {rid}'s local object database"
    return res["path"], None


def acquire(src, commit, dest):
    """Clone `src` at `commit` into `dest` without writing to `src`. Raises GitError."""
    resolver.git(dest.parent, "clone", "--shared", "--no-checkout", "--quiet", str(src), dest.name)
    resolver.git(dest, "-c", "advice.detachedHead=false", "checkout", "--quiet", "--detach", commit)
    if resolver.git(dest, "rev-parse", "HEAD") != commit:
        raise resolver.GitError(f"{dest.name} is not at {commit}")


def read_pin(text, name):
    """Commit pinned for `name` in a `<Name> <sha>` pin file (comments start with #), or None."""
    for line in (text or "").splitlines():
        bits = line.split("#", 1)[0].split()
        if len(bits) == 2 and bits[0] == name:
            return bits[1]
    return None


def native_binaries(top):
    top = Path(top)
    return sorted(str(p.relative_to(top)) for p in top.rglob("*")
                  if p.name.endswith(NATIVE_SUFFIXES) and ".git" not in p.relative_to(top).parts and p.is_file())


# ---------------------------------------------------------------- evidence

def package_roots(text, name):
    """Directories that hold a path component exactly `name` in absolute paths in `text`."""
    roots = set()
    for token in re.findall(r"/[^\s'\"`:=,;]+", text):
        parts = re.sub(r"^/+", "/", token).split("/")
        for i, part in enumerate(parts[1:], 1):
            if part == name:
                roots.add("/".join(parts[:i]) or "/")
    return roots


def inside(path, forms):
    return any(path == f or path.startswith(f.rstrip("/") + "/") for f in forms)


def sanitize(text, forms):
    for f in sorted(forms, key=len, reverse=True):
        text = text.replace(f, "<workspace>")
    text = text.replace(str(Path.home()), "~")
    return resolver.PRIVATE_PATH_RE.sub("<private>", text)


# ---------------------------------------------------------------- execution

def run_shell(command, cwd, env, log_path, timeout):
    """Run `command` with bash in its own process group. Returns (exit code or None on timeout, text)."""
    with open(log_path, "wb") as log:
        proc = subprocess.Popen(["bash", "-c", command], cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, start_new_session=True)
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            code = None
        except BaseException:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            raise
        if code is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
    return code, Path(log_path).read_text(errors="replace")


def _tail(text, forms):
    return [sanitize(ln, forms) for ln in text.rstrip("\n").splitlines()[-TAIL:]]


def run_recipe(check, ctx):
    started = time.monotonic()
    code, text = run_shell(check["recipe"], ctx["consumer_dir"], ctx["env"], ctx["log"], ctx["timeout"])
    out = {"exit_code": code, "duration_s": round(time.monotonic() - started, 1), "log_tail": _tail(text, ctx["forms"])}
    roots = package_roots(text, ctx["package_name"])
    out["package_roots"] = sorted(sanitize(r, ctx["forms"]) for r in roots)
    leaked = sorted(r for r in roots if not inside(r, ctx["forms"]))
    missing = [rx for rx in check.get("expect", []) if not re.search(rx, text, re.M)]
    if code is None:
        return dict(out, status="failed", reason=f"timed out after {ctx['timeout']} s")
    if leaked:
        return dict(out, status="failed", reason=f"{ctx['package_name']} resolved outside the disposable workspace")
    if code != 0:
        errors = [ln for ln in text.splitlines() if re.search(r"\berror:|^e: ", ln)]
        return dict(out, status="failed", reason=f"exit {code}", first_errors=[sanitize(ln, ctx["forms"]) for ln in list(dict.fromkeys(errors))[:5]])
    if missing:
        return dict(out, status="failed", reason=f"expected output missing: {missing}")
    if check.get("resolves_package") and not roots:
        return dict(out, status="failed", reason=f"output never names {ctx['package_name']} by path; resolution not proven")
    return dict(out, status="passed")


def run_fingerprint(check, ctx):
    fp = check["fingerprint"]
    target = ctx["package_dir"] / fp["touch"]
    if not target.is_file():
        return {"status": "unavailable", "reason": f"{ctx['package_name']}/{fp['touch']} does not exist at the package commit"}
    started = time.monotonic()
    before = run_shell(fp["command"], ctx["consumer_dir"], ctx["env"], ctx["log"], ctx["timeout"])
    original = target.read_bytes()
    try:
        target.write_bytes(original + b"\n")
        after = run_shell(fp["command"], ctx["consumer_dir"], ctx["env"], ctx["log"].with_suffix(".after.log"), ctx["timeout"])
    finally:
        target.write_bytes(original)
    out = {"duration_s": round(time.monotonic() - started, 1), "touched": f"{ctx['package_name']}/{fp['touch']}",
           "before": sanitize(before[1].strip(), ctx["forms"])[-200:], "after": sanitize(after[1].strip(), ctx["forms"])[-200:]}
    if before[0] != 0 or after[0] != 0:
        return dict(out, status="failed", reason=f"fingerprint command exit {before[0]}/{after[0]}")
    if not before[1].strip() or before[1] == after[1]:
        return dict(out, status="failed", reason="fingerprint unchanged by a one-byte edit to the candidate package")
    return dict(out, status="passed")


def run_native(check, ctx):
    if ctx["prebuilt"]:
        return {"status": "failed", "reason": "native binaries present in the fresh workspace before any build",
                "prebuilt": ctx["prebuilt"]}
    found = sorted({p for g in check["native_outputs"] for p in ctx["consumer_dir"].glob(g) if p.is_file()})
    if not found:
        return {"status": "not-run", "reason": "no native output found; the build that stages it did not run or failed"}
    rows = [{"path": str(p.relative_to(ctx["consumer_dir"])), "bytes": p.stat().st_size,
             "built_this_run": p.stat().st_mtime >= ctx["started"]} for p in found]
    stale = [r["path"] for r in rows if not r["built_this_run"]]
    out = {"outputs": rows, "prebuilt": []}
    if stale:
        return dict(out, status="failed", reason=f"native outputs older than this run: {stale}")
    return dict(out, status="passed")


RUNNERS = {"recipe": run_recipe, "fingerprint": run_fingerprint, "native_outputs": run_native}


def _static(check):
    return {k: check[k] for k in ("status", "reason") if k in check}


def run_consumer(cand, con, reg, root, env, patch, timeout, logdir):
    """Run one consumer's checks in a fresh workspace. Returns its result record."""
    pkg = cand["package"]
    out = {"repo": con["repo"], "ref": con.get("ref"), "commit": con["commit"],
           "package": {"repo": pkg["repo"], "commit": pkg["commit"]}, "checks": []}
    todo = [c for c in con.get("checks", []) if kind(c) and c.get("status") != "not-applicable"]
    config = resolver.load_local_config(root)
    pkg_src, why = source(reg, root, pkg["repo"], pkg.get("commit"), config)
    con_src, why2 = source(reg, root, con["repo"], con["commit"], config)
    if why or why2 or con["repo"] == pkg["repo"]:
        reason = why or why2 or "consumer and package are the same repository"
        out["checks"] = [dict(_entry(c), status="unavailable", reason=reason) if c in todo else dict(_entry(c), **_static(c))
                         for c in con.get("checks", [])]
        return out
    pkg_name, con_name = reg[pkg["repo"]]["local_dir"], reg[con["repo"]]["local_dir"]
    out["layout"] = {"consumer": f"<workspace>/{con_name}", "package": f"<workspace>/{pkg_name}"}
    with tempfile.TemporaryDirectory(prefix="atlas-compat-") as tmp:
        ws = Path(tmp).resolve()
        # Tools print a macOS temp path with or without its "/private" prefix.
        forms = {tmp, str(ws), str(ws).removeprefix("/private")}
        out["workspace_was_removed"] = None
        ctx = {"consumer_dir": ws / con_name, "package_dir": ws / pkg_name, "package_name": pkg_name, "forms": forms,
               "env": dict(env, ATLAS_COMPAT_WORKSPACE=str(ws), ATLAS_COMPAT_PACKAGE_COMMIT=pkg["commit"]), "timeout": timeout, "started": time.time()}
        try:
            acquire(pkg_src, pkg["commit"], ctx["package_dir"])
            acquire(con_src, con["commit"], ctx["consumer_dir"])
            if patch:
                resolver.git(ctx["package_dir"], "apply", "--whitespace=nowarn", str(patch))
        except resolver.GitError as exc:
            reason = f"acquisition failed: {sanitize(str(exc), forms)}"
            out["checks"] = [dict(_entry(c), status="unavailable", reason=reason) if c in todo else dict(_entry(c), **_static(c))
                             for c in con.get("checks", [])]
        else:
            if con.get("pin_file"):
                pins = ctx["consumer_dir"] / con["pin_file"]
                out["consumer_pin"] = read_pin(pins.read_text() if pins.is_file() else "", pkg_name)
            ctx["prebuilt"] = native_binaries(ws)
            out["native_binaries_before_checks"] = ctx["prebuilt"]
            out["gradle"] = gradle_wrappers(ctx["consumer_dir"])
            for i, c in enumerate(con.get("checks", [])):
                entry = _entry(c)
                if c not in todo:
                    out["checks"].append(dict(entry, **_static(c)))
                    continue
                need = missing_requirements(c, ctx["env"])
                if need:
                    out["checks"].append(dict(entry, status="unavailable", reason=need))
                    continue
                ctx["log"] = logdir / f"{con['repo']}-{i:02d}-{c.get('name', kind(c))}.log"
                print(f"  {con['repo']}: {entry['name']} ...", flush=True)
                res = RUNNERS[kind(c)](c, ctx)
                print(f"  {con['repo']}: {entry['name']} {res['status']}{' (' + res['reason'] + ')' if res.get('reason') else ''}"
                      f"{' ' + str(res['duration_s']) + ' s' if 'duration_s' in res else ''}", flush=True)
                out["checks"].append(dict(entry, **res))
    out["workspace_was_removed"] = not ws.exists()
    # SwiftPM leaves empty lock files named after the workspace path in the system temp folder.
    for stray in Path(tempfile.gettempdir()).glob(f"*{ws.name}*"):
        if stray.is_file() and not stray.stat().st_size:
            stray.unlink()
    return out


def _entry(check):
    e = {"name": check.get("name") or check.get("recipe") or kind(check) or "check"}
    for k in ("recipe", "fingerprint", "native_outputs"):
        if check.get(k):
            e[k] = check[k]
    return e


def overall(records):
    statuses = [c["status"] for r in records for c in r["checks"]]
    if "failed" in statuses:
        return FAIL
    if "unavailable" in statuses:
        return INCOMPLETE
    return OK


def cmd_run(args, reg, root):
    data = load(root)
    cand = next((c for c in data["candidates"] if c.get("id") == args.candidate), None)
    if not cand:
        print(f"unknown candidate {args.candidate!r}; recorded: {', '.join(c.get('id', '?') for c in data['candidates'])}", file=sys.stderr)
        return USAGE
    picked = [(i, c) for i, c in enumerate(cand.get("consumers", [])) if not args.consumer or c["repo"] == args.consumer]
    if not picked:
        print(f"no consumer {args.consumer!r} in {args.candidate}", file=sys.stderr)
        return USAGE
    patch = Path(args.inject_break).resolve() if args.inject_break else None
    if patch and not patch.is_file():
        print(f"--inject-break: {args.inject_break} is not a file", file=sys.stderr)
        return USAGE
    env = dict(os.environ)
    started, t0 = _now(), time.monotonic()
    logdir = Path(root) / ".local" / "compat-logs" / args.candidate / started.replace(":", "")
    logdir.mkdir(parents=True, exist_ok=True)
    print(f"compat run {args.candidate}{' with injected break ' + patch.name if patch else ''}; logs in {logdir}")
    records, tools = [], toolchain(env)
    for _, con in picked:
        records.append(dict(run_consumer(cand, con, reg, root, env, patch, args.timeout, logdir), finished_at=_now(), toolchain=tools))
    record = {"schema_version": 1, "candidate": args.candidate, "mode": "inject-break" if patch else "clean",
              "started_at": started, "finished_at": _now(), "duration_s": round(time.monotonic() - t0, 1),
              "atlas_version": resolver.ATLAS_VERSION, "consumers": records}
    previous = results_path(root, args.candidate, inject=bool(patch))
    if args.consumer and previous.is_file():
        # Keep the other consumers' last results; each consumer record carries its own time and toolchain.
        order = [c["repo"] for c in cand["consumers"]]
        kept = [r for r in json.loads(previous.read_text()).get("consumers", []) if r.get("repo") != args.consumer]
        record["consumers"] = sorted(kept + records, key=lambda r: order.index(r["repo"]) if r["repo"] in order else len(order))
    if patch:
        record["break_patch"] = {"file": patch.name, "sha256": hashlib.sha256(patch.read_bytes()).hexdigest(),
                                 "files": sorted(set(re.findall(r"^\+\+\+ b/(\S+)", patch.read_text(), re.M)))}
        record["note"] = "Deliberately incompatible package; applied only inside the disposable workspace. Never recorded as a candidate status."
    _dump(results_path(root, args.candidate, inject=bool(patch)), record)
    if not patch:
        for (i, con), rec in zip(picked, records):
            for chk, res in zip(con.get("checks", []), rec["checks"]):
                chk["status"] = res["status"]
                chk.pop("reason", None)
                if res.get("reason"):
                    chk["reason"] = res["reason"]
                if kind(chk) and res["status"] != "not-applicable":
                    chk["checked_at"] = record["finished_at"]
            if con.get("pin_file"):
                con["pinned_package_commit"] = rec.get("consumer_pin")
            cand["consumers"][i] = con
        cand["validated_at"] = record["finished_at"]
        cand["validated_by"] = "atlas compat run"
        _dump(candidates_path(root), data)
    code = overall(records)
    removed = all(r.get("workspace_was_removed") is not False for r in records)
    print(f"result: {['ok', 'failed', 'usage', 'incomplete'][code]}; {record['duration_s']} s; workspaces removed: {removed}; "
          f"recorded in {results_path(root, args.candidate, inject=bool(patch)).relative_to(root)}")
    return code if removed else FAIL


# ---------------------------------------------------------------- plan

def cmd_plan(args, reg, root):
    data = load(root)
    cands = [c for c in data["candidates"] if not args.candidate or c.get("id") == args.candidate]
    if args.candidate and not cands:
        print(f"unknown candidate {args.candidate!r}", file=sys.stderr)
        return USAGE
    config = resolver.load_local_config(root)
    env = dict(os.environ)
    rows = []
    for cand in cands:
        pkg = cand["package"]
        pkg_src, pkg_why = source(reg, root, pkg["repo"], pkg.get("commit"), config)
        for con in cand.get("consumers", []):
            con_src, con_why = source(reg, root, con["repo"], con["commit"], config)
            tip = resolver.rev(con_src, con["ref"]) if con_src and con.get("ref") else None
            pin = None
            if con_src and con.get("pin_file") and con["repo"] in reg and pkg["repo"] in reg:
                text = resolver.git(con_src, "show", f"{con['commit']}:{con['pin_file']}", check=False)
                pin = read_pin(text, reg[pkg["repo"]]["local_dir"])
            checks = []
            for c in con.get("checks", []):
                if not kind(c) or c.get("status") == "not-applicable":
                    checks.append(dict(_entry(c), would=f"keep {c.get('status')}", reason=c.get("reason")))
                    continue
                why = pkg_why or con_why or missing_requirements(c, env)
                checks.append(dict(_entry(c), would="unavailable" if why else "run", reason=why))
            rows.append({"candidate": cand["id"], "package": f"{pkg['repo']}@{(pkg.get('commit') or 'none')[:12]}", "package_commit": pkg.get("commit"),
                         "consumer": con["repo"], "ref": con.get("ref"), "commit": con["commit"],
                         "ref_tip": tip, "consumer_pin": pin, "layout": [f"<workspace>/{reg[r]['local_dir']}" for r in (con["repo"], pkg["repo"]) if r in reg],
                         "checks": checks})
    if args.json:
        print(json.dumps(rows, indent=2))
        return OK
    for r in rows:
        moved = f" (ref tip now {r['ref_tip'][:12]})" if r["ref_tip"] and r["ref_tip"] != r["commit"] else ""
        print(f"{r['candidate']}: {r['package']} -> {r['consumer']}@{r['ref']} {r['commit'][:12]}{moved}")
        print(f"  workspace: {', '.join(r['layout'])}")
        if r["consumer_pin"]:
            same = "same as" if r["consumer_pin"] == r["package_commit"] else "differs from"
            print(f"  consumer pins {r['consumer_pin'][:12]}, {same} the candidate under test")
        for c in r["checks"]:
            print(f"  {c['would']:12} {c['name']}{'  (' + c['reason'] + ')' if c.get('reason') else ''}")
    return OK


def result_errors(root, reg):
    """compat/results/*.json: known statuses, and no passed check without exact SHAs."""
    errors = []
    for p in sorted((Path(root) / "compat" / "results").glob("*.json")):
        where = f"compat/results/{p.name}"
        try:
            rec = json.loads(p.read_text())
        except ValueError as exc:
            errors.append(f"{where}: invalid JSON ({exc})")
            continue
        for con in rec.get("consumers", []):
            for chk in con.get("checks", []):
                st = chk.get("status")
                if st not in STATUSES:
                    errors.append(f"{where}: {con.get('repo')} {chk.get('name')}: unknown status {st!r}")
                elif st == "passed" and not (resolver.SHA_RE.match(con.get("commit") or "") and resolver.SHA_RE.match((con.get("package") or {}).get("commit") or "")):
                    errors.append(f"{where}: {con.get('repo')} {chk.get('name')}: passed without exact package and consumer commits")
    return errors


def run(args, reg, root):
    return cmd_plan(args, reg, root) if args.ccmd == "plan" else cmd_run(args, reg, root)
