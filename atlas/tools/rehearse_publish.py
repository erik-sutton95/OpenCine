#!/usr/bin/env python3
"""Rehearse tools/publish.py end to end without GitHub (RELEASE-01, docs/PUBLISH.md).

Copies the committed atlas, every package and every app branch from compat/release-<v>.json into
disposable clones next to empty bare repositories behind a file:// base. The real checkouts are
only read (app clones borrow their objects through alternates and never write to them). Then:

  1. dry run: must succeed past the decisions it reports and write nothing
  2. decide + rewrite-authors in the clones (the real record keeps its decisions empty)
  3. --execute --open-prs with the file:// base: every step, including clean-clone verification
  4. the same command again: must report every step done and change nothing
  5. an independent consumer resolving every package tag from the file remotes with exact pins,
     the way a cross-brand app would (one dependency closure)

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


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default="/tmp/opencine-publish-rehearsal", help="disposable folder (recreated)")
    ap.add_argument("--remote", help="bare repositories for the file:// base (default <dir>/fake-github)")
    ap.add_argument("--version", default="0.1.0")
    args = ap.parse_args(argv)
    top, started = Path(args.dir), time.time()
    remote = Path(args.remote or top / "fake-github")
    for d in (top, remote):
        if d.exists():
            if not (d / ".rehearsal").exists():
                sys.exit(f"{d} exists and was not made by this script; choose another --dir/--remote")
            shutil.rmtree(d)
        d.mkdir(parents=True)
        (d / ".rehearsal").write_text("disposable\n")
    ws = top / "ws"
    ws.mkdir()
    base = f"file://{remote}"
    real = publish.Run(argparse.Namespace(version=args.version, remote_base=None, owner=None, execute=False), publish.atlas_root())
    rel = real.release
    report = [f"publish rehearsal {time.strftime('%Y-%m-%d %H:%M:%S %Z')}, remote base {base}"]

    # 1. clones
    atlas = ws / real.name(real.atlas_id)
    git(ws, "clone", "-q", str(real.root), str(atlas))
    git(atlas, "remote", "remove", "origin")
    email = subprocess.run(["git", "-C", str(real.root), "config", "--local", "user.email"], capture_output=True, text=True).stdout.strip()
    if email:  # the real atlas commits with its repo-local address; so does its clone
        git(atlas, "config", "user.email", email)
    repos = [atlas]
    for p in rel["packages"]:
        dest = ws / real.name(p["repo"])
        git(ws, "clone", "-q", "--branch", p["branch"], str(real.path(p["repo"])), str(dest))
        git(dest, "remote", "remove", "origin")
        repos.append(dest)
    for a in rel["apps"]:
        src = git(real.path(a["repo"]), "rev-parse", "--path-format=absolute", "--git-common-dir")
        dest = ws / real.name(a["repo"])
        git(ws, "clone", "-q", "--shared", "--no-checkout", src, str(dest))
        git(dest, "remote", "remove", "origin")
        git(dest, "fetch", "-q", src, "refs/remotes/origin/*:refs/remotes/origin/*")
        git(dest, "-c", "advice.detachedHead=false", "checkout", "-q", "-B", a["branch"], git(real.path(a["repo"]), "rev-parse", "HEAD"))
        git(dest, "remote", "add", "origin", real.reg[a["repo"]]["repository"]["url"])
        git(dest, "config", "remote.origin.pushurl", "file:///nonexistent/rehearsal-push-disabled")
        repos.append(dest)
    for rid in [real.atlas_id] + real.packages + [a["repo"] for a in rel["apps"]]:
        subprocess.run(["git", "init", "-q", "--bare", str(remote / real.name(rid))], check=True)
    bares = [remote / real.name(rid) for rid in [real.atlas_id] + real.packages + [a["repo"] for a in rel["apps"]]]
    report.append(f"clones: {', '.join(p.name for p in repos)}")

    env = {k: v for k, v in os.environ.items() if k not in ("OPENCAPTURE_ATLAS_ROOT", "OPENCAPTURE_WORKSPACE")}
    tool = [sys.executable, atlas / "tools" / "publish.py"]
    pub = [*tool, "--remote-base", base]

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
    for rid in real.packages:
        bare = remote / real.name(rid)
        tag = git(bare, "rev-parse", f"{args.version}^{{commit}}")
        kind = git(bare, "cat-file", "-t", args.version)
        manifest = git(bare, "show", f"{args.version}:Package.swift")
        ranges = manifest.count(".upToNextMinor(from:")
        paths = manifest.count(".package(path:")
        report.append(f"  {real.name(rid)}: {kind} {args.version} -> {tag[:12]}, Package.swift url ranges {ranges}, path deps {paths}")
    for a in rel["apps"]:
        bare = remote / real.name(a["repo"])
        head = git(bare, "rev-parse", f"refs/heads/{a['branch']}")
        files = git(bare, "ls-tree", "-r", "--name-only", head).splitlines()
        lock = [f for f in a.get("lockfiles", []) if f in files]
        report.append(f"  {real.name(a['repo'])}: {a['branch']} -> {head[:12]}, lockfiles committed {lock}")
    report.append(f"  atlas main -> {git(remote / real.name(real.atlas_id), 'rev-parse', 'main')[:12]}")

    # 6. a cross-brand consumer: every package at exactly the tag, resolved from the file remotes
    consumer = top / "consumer"
    (consumer / "Sources" / "Consumer").mkdir(parents=True)
    (consumer / "Sources" / "Consumer" / "Consumer.swift").write_text("// resolution only\n")
    deps = ",\n".join(f'        .package(url: "{base}/{real.name(r)}", exact: "{args.version}")' for r in real.packages)
    (consumer / "Package.swift").write_text(
        f'// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(\n    name: "Consumer",\n'
        f'    platforms: [.iOS(.v17), .macOS(.v14)],\n    dependencies: [\n{deps}\n    ],\n'
        '    targets: [.target(name: "Consumer")]\n)\n')
    code, out = run(["swift", "package", "resolve"], cwd=consumer, log=top / "5-consumer-resolve.log")
    pins = json.loads((consumer / "Package.resolved").read_text())["pins"] if not code else []
    report.append(f"5 cross-brand consumer resolve: exit {code}, pins " + ", ".join(f"{p['identity']} {p['state'].get('version')}" for p in pins))
    report.append(f"total {int(time.time() - started)} s")
    (top / "REHEARSAL.txt").write_text("\n".join(report) + "\n")
    print("\n".join(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
