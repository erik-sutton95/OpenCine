#!/usr/bin/env python3
"""Rehearse tools/publish.py end to end without GitHub (RELEASE-01, ADR 0010, docs/PUBLISH.md).

Copies the platform repository (the committed HEAD of the checkout this atlas runs from, as
`main`) and every app branch from compat/release-<v>.json into disposable clones next to empty
bare repositories behind a file:// base. The real checkouts are only read (app clones borrow
their objects through alternates and never write to them). Then:

  1. dry run: must succeed past the decisions it reports and write nothing
  2. decide + rewrite-authors in the clones (the real record keeps its decisions empty)
  3. --execute --open-prs with the file:// base: every step, including clean-clone verification
  4. the same command again: must report every step done and change nothing
  5. an independent consumer that takes OpenCine 0.1.0 from the file remote by exact version and
     builds against OpenCineCore, the way a new app would

Usage: python3 tools/rehearse_publish.py [--dir DIR] [--remote DIR] [--version 0.1.0]
Gradle verify steps need JAVA_HOME and ANDROID_HOME. Standard library only.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))
import publish  # noqa: E402

NOREPLY = "9084979+erik-sutton95@users.noreply.github.com"


def run(cmd, cwd=None, log=None, env=None):
    print(f"$ {' '.join(map(str, cmd))}", flush=True)
    r = subprocess.run([str(c) for c in cmd], cwd=cwd, env=env, text=True, capture_output=True)
    out = r.stdout + r.stderr
    if log:
        Path(log).write_text(out)
    return r.returncode, out


def git(path, *args):
    return subprocess.run(["git", "-C", str(path), *args], check=True, capture_output=True, text=True).stdout.strip()


def fingerprint(repos, bares):
    """Refs of every repository, plus the status of every path (ignored ones included) in each clone."""
    out = []
    for p in repos + bares:
        out.append(f"{p}\n" + subprocess.run(["git", "-C", str(p), "for-each-ref", "--format=%(refname) %(objectname)"],
                                             capture_output=True, text=True).stdout)
    for p in repos:
        out.append(subprocess.run(["git", "-C", str(p), "status", "--porcelain", "--ignored", "-uall"], capture_output=True, text=True).stdout)
    return "\n".join(out)


def tweak_record(atlas, rel, version, report):
    """With a file:// base SwiftPM and Xcode record a lock location without the scheme, which the
    apps' own lockfile check (written for https URLs) cannot match. Only in the cloned record, run
    that check on a copy with the scheme restored; on GitHub the location is the URL as written."""
    record = atlas / "compat" / f"release-{version}.json"
    data = json.loads(record.read_text())
    fix = ("cp ios/Package.resolved ios/Package.resolved.orig && "
           "sed -i '' 's#\"location\" : \"/#\"location\" : \"file:///#' ios/Package.resolved && {}; "
           "s=$?; mv ios/Package.resolved.orig ios/Package.resolved; [ $s = 0 ]")
    for clone, original in zip(data["apps"], rel["apps"]):
        clone["verify"] = [fix.format(c) if "ios-package-resolved-check" in c else c for c in original["verify"]]
    record.write_text(json.dumps(data, indent=2) + "\n")
    if git(atlas, "status", "--porcelain"):
        git(atlas, "commit", "-q", "-am", "rehearsal: lockfile check reads file:// locations")
    report.append("rehearsal-only change: apps' Package.resolved check runs on a copy with the file:// scheme restored")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default="/tmp/opencine-publish-rehearsal", help="disposable folder (recreated)")
    ap.add_argument("--remote", help="folder for the bare repositories; each run uses a fresh run-<time> folder inside (default <dir>/fake-github)")
    ap.add_argument("--version", default="0.1.0")
    ap.add_argument("--resume", action="store_true",
                    help="keep the clones and remotes of an interrupted rehearsal and rerun the publish on them")
    args = ap.parse_args(argv)
    top, started = Path(args.dir), time.time()
    remotes = Path(args.remote or top / "fake-github")
    # A fresh folder per run: SwiftPM and Xcode cache repositories by URL, and a 0.1.0 tag that
    # moved between rehearsals would resolve to a commit the new remote does not have.
    if args.resume:
        runs = sorted(remotes.glob("run-*"))
        if not runs:
            sys.exit(f"nothing to resume in {remotes}")
        remote = runs[-1]
    else:
        remote = remotes / time.strftime("run-%Y%m%d-%H%M%S")
    base = f"file://{remote}"
    real = publish.Run(argparse.Namespace(version=args.version, remote_base=None, owner=None, execute=False), publish.atlas_root())
    rel = real.release
    report = [f"publish rehearsal {time.strftime('%Y-%m-%d %H:%M:%S %Z')}, remote base {base}"
              + (" (resumed on the existing clones)" if args.resume else "")]
    ws = top / "ws"
    atlas = ws / real.name(real.platform_id) / real.atlas_prefix
    names = [real.name(r) for r in real.packages + [a["repo"] for a in rel["apps"]]]
    repos, bares = [ws / n for n in names], [remote / n for n in names]
    if args.resume:
        if not (atlas / ".local" / "publish-state.json").is_file():
            sys.exit(f"nothing to resume in {ws}")
        return publish_and_check(args, real, rel, top, remote, base, atlas, repos, bares, report, started, resume=True)

    for d in (top, remotes):
        if d.exists():
            if not (d / ".rehearsal").exists():
                sys.exit(f"{d} exists and was not made by this script; choose another --dir/--remote")
            shutil.rmtree(d)
        d.mkdir(parents=True)
        (d / ".rehearsal").write_text("disposable\n")
    ws.mkdir()
    remote.mkdir()
    # 1. clones. The platform clone is the committed HEAD of the checkout this atlas runs from,
    # named after the record's branch, so a task branch can be rehearsed before it merges.
    src, plat = real.path(real.platform_id), ws / real.name(real.platform_id)
    branch = rel["platform"]["branch"]
    git(ws, "clone", "-q", "--no-checkout", str(src), str(plat))
    git(plat, "-c", "advice.detachedHead=false", "checkout", "-q", "-B", branch, git(src, "rev-parse", "HEAD"))
    git(plat, "remote", "remove", "origin")
    email = subprocess.run(["git", "-C", str(src), "config", "--local", "user.email"], capture_output=True, text=True).stdout.strip()
    if email:  # the real repository commits with its repo-local address; so does its clone
        git(plat, "config", "user.email", email)
    for a in rel["apps"]:
        src = git(real.path(a["repo"]), "rev-parse", "--path-format=absolute", "--git-common-dir")
        dest = ws / real.name(a["repo"])
        git(ws, "clone", "-q", "--shared", "--no-checkout", src, str(dest))
        git(dest, "remote", "remove", "origin")
        git(dest, "fetch", "-q", src, "refs/remotes/origin/*:refs/remotes/origin/*")
        git(dest, "-c", "advice.detachedHead=false", "checkout", "-q", "-B", a["branch"], git(real.path(a["repo"]), "rev-parse", "HEAD"))
        git(dest, "remote", "add", "origin", real.reg[a["repo"]]["repository"]["url"])
        git(dest, "config", "remote.origin.pushurl", "file:///nonexistent/rehearsal-push-disabled")
    for rid in real.packages + [a["repo"] for a in rel["apps"]]:
        subprocess.run(["git", "init", "-q", "--bare", str(remote / real.name(rid))], check=True)
        # scripts/checkout-opencine.sh fetches <base>/<Name>.git; GitHub serves both spellings.
        (remote / f"{real.name(rid)}.git").symlink_to(real.name(rid))
    report.append(f"clones: {', '.join(names)}")

    env = {k: v for k, v in os.environ.items() if k not in ("OPENCAPTURE_ATLAS_ROOT", "OPENCAPTURE_WORKSPACE")}
    env["PYTHONDONTWRITEBYTECODE"] = "1"  # bytecode caches are not the tool writing
    tool = [sys.executable, atlas / "tools" / "publish.py"]
    pub = [*tool, "--remote-base", base]

    tweak_record(atlas, rel, args.version, report)

    # 2. dry run writes nothing (decisions are still empty in the cloned record: preflight reports them)
    before = fingerprint(repos, bares)
    code, out = run(pub, log=top / "1-dry-run.log", env=env)
    same = fingerprint(repos, bares) == before and not (atlas / ".local").exists()
    report.append(f"1 dry run: exit {code} (1 expected: decisions not recorded), wrote nothing: {same}")
    if not same:
        sys.exit("\n".join(report + ["FAILED: the dry run changed something"]))

    # 3. decisions and author rewrite in the clones
    code, out = run([*tool, "decide", "--owner", "erik-sutton95", "--visibility", "public", "--android", "sibling-pins",
                     "--author-email", NOREPLY], env=env)
    report.append(f"2 decide: exit {code}")
    code, out = run([*tool, "rewrite-authors", "--execute"], log=top / "2-rewrite-authors.log", env=env)
    report.append(f"2 rewrite-authors: exit {code}; " + "; ".join(ln.strip() for ln in out.splitlines() if "->" in ln))
    if code:
        sys.exit("\n".join(report + [out]))

    return publish_and_check(args, real, rel, top, remote, base, atlas, repos, bares, report, started)


def publish_and_check(args, real, rel, top, remote, base, atlas, repos, bares, report, started, resume=False):
    env = {k: v for k, v in os.environ.items() if k not in ("OPENCAPTURE_ATLAS_ROOT", "OPENCAPTURE_WORKSPACE")}
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    pub = [sys.executable, atlas / "tools" / "publish.py", "--remote-base", base]
    if resume:
        tweak_record(atlas, rel, args.version, report)
    # 4. execute, then again
    t0 = time.time()
    code, out = run([*pub, "--execute", "--open-prs"], log=top / "3-execute.log", env=env)
    report.append(f"3 execute: exit {code} in {int(time.time() - t0)} s (log {top / '3-execute.log'})")
    if code:
        print(out[-4000:])
        (top / "REHEARSAL.txt").write_text("\n".join(report) + "\n")
        sys.exit("\n".join(report))
    before = fingerprint(repos, bares)
    code, out = run([*pub, "--execute", "--open-prs"], log=top / "4-rerun.log", env=env)
    reran = [ln for ln in out.splitlines() if ln.startswith("  run ")]
    report.append(f"4 rerun: exit {code}, steps run again: {len(reran)}, changed nothing: {fingerprint(repos, bares) == before}")

    # 5. what landed in the file remotes
    name = real.name(real.platform_id)
    bare = remote / name
    tag = git(bare, "rev-parse", f"{args.version}^{{commit}}")
    kind = git(bare, "cat-file", "-t", args.version)
    deps = git(bare, "show", f"{args.version}:Package.swift").count(".package(")
    report.append(f"  {name}: {kind} {args.version} -> {tag[:12]}, Package.swift package dependencies {deps}")
    for a in rel["apps"]:
        bare = remote / real.name(a["repo"])
        head = git(bare, "rev-parse", f"refs/heads/{a['branch']}")
        files = git(bare, "ls-tree", "-r", "--name-only", head).splitlines()
        lock = [f for f in a.get("lockfiles", []) if f in files]
        report.append(f"  {real.name(a['repo'])}: {a['branch']} -> {head[:12]}, lockfiles committed {lock}")
    report.append(f"  {name} main (atlas registry update after the tag) -> {git(remote / name, 'rev-parse', 'main')[:12]}")

    # 6. a new consumer: OpenCine at exactly the tag from the file remote, building one product
    consumer = top / "consumer"
    (consumer / "Sources" / "Consumer").mkdir(parents=True)
    (consumer / "Sources" / "Consumer" / "Consumer.swift").write_text("import OpenCineCore\n")
    (consumer / "Package.swift").write_text(
        f'// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(\n    name: "Consumer",\n'
        f'    platforms: [.iOS(.v17), .macOS(.v13)],\n    dependencies: [.package(url: "{base}/{name}", exact: "{args.version}")],\n'
        f'    targets: [.target(name: "Consumer", dependencies: [.product(name: "OpenCineCore", package: "{name}")])]\n)\n')
    code, out = run(["swift", "build"], cwd=consumer, log=top / "5-consumer-build.log")
    pins = json.loads((consumer / "Package.resolved").read_text())["pins"] if (consumer / "Package.resolved").is_file() else []
    report.append(f"5 consumer resolve + build of OpenCineCore: exit {code}, pins " + ", ".join(f"{p['identity']} {p['state'].get('version')}" for p in pins))
    report.append(f"total {int(time.time() - started)} s")
    (top / "REHEARSAL.txt").write_text("\n".join(report) + "\n")
    print("\n".join(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
