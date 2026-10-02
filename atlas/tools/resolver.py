"""The one checkout resolver and snapshot provenance used by every atlas command.

Standard library only. Nothing in this module writes to a checkout.
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

ATLAS_VERSION = "0.1.0"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
# Built so this source line itself never matches.
PRIVATE_PATH_RE = re.compile(
    r"(?<![\w.])(?:/(?:Users|home)/[\w.-]+|/private/(?:tmp|var)/|/var/(?:folders)/|[A-Za-z]:\\Users\\)"
)


class GitError(RuntimeError):
    pass


# Reads must not refresh a shared checkout's index (plain `git status` may rewrite it).
GIT_ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0")


def git(path, *args, check=True, binary=False):
    r = subprocess.run(["git", "-C", str(path), *args], capture_output=True, env=GIT_ENV)
    if check and r.returncode:
        raise GitError(f"git {' '.join(args)} in {path}: {r.stderr.decode(errors='replace').strip()}")
    return r.stdout if binary else r.stdout.decode(errors="replace").strip()


def normalize_url(url):
    """Canonical `host/owner/repo` for https, ssh and scp-style Git URLs.

    `github.com-<alias>` ssh host aliases (used to pick an account) map to github.com.
    """
    if not url:
        return None
    m = re.match(r"^(?:[a-z][a-z0-9+.-]*://)?(?:[^@/]+@)?([^/:]+)[:/](.+?)(?:\.git)?/*$", url.strip().lower())
    if not m:
        return url.strip().lower()
    host, path = m.groups()
    host = re.sub(r"^github\.com-[\w.-]+$", "github.com", host)
    return f"{host}/{path}"


def load_local_config(atlas_root):
    p = Path(atlas_root) / ".local" / "checkouts.json"
    if not p.is_file():
        return {}
    return json.loads(p.read_text())


def _workspaces(atlas_root, config, env):
    seen = []
    # The atlas lives at <OpenCine checkout>/atlas, so the folder holding the sibling checkouts is
    # two levels up; one level up is kept for a standalone atlas root (the tests use one).
    here = Path(atlas_root).resolve()
    for w in (config.get("workspace"), env.get("OPENCAPTURE_WORKSPACE"), str(here.parent), str(here.parent.parent)):
        if w and not w.startswith("<") and w not in seen:
            seen.append(w)
    return seen


def _verify(path, meta):
    """Return (real_path, None) for a checkout top level whose remotes match, else (None, reason)."""
    p = Path(path).expanduser()
    if not p.exists():
        return None, "path does not exist"
    real = p.resolve()
    try:
        top = git(real, "rev-parse", "--show-toplevel")
    except GitError:
        return None, "not a Git checkout"
    if Path(top).resolve() != real:
        return None, f"inside a Git checkout but not its top level ({top})"
    want = normalize_url((meta.get("repository") or {}).get("url"))
    if want:
        remotes = git(real, "remote", "-v", check=False).split()
        if want not in {normalize_url(u) for u in remotes[1::3]}:
            return None, "no remote matches the registered repository URL"
    return real, None


def resolve(meta, atlas_root, env=None, config=None):
    """Resolve a registry entry to one verified checkout.

    Returns {"status": ok|missing|ambiguous|mismatch, "path", "reason", "candidates"}.
    An explicit mapping in .local/checkouts.json wins and never falls back to discovery.
    """
    env = os.environ if env is None else env
    config = load_local_config(atlas_root) if config is None else config
    explicit = (config.get("repos") or {}).get(meta["id"])
    if explicit:
        real, why = _verify(explicit, meta)
        if real:
            return {"status": "ok", "path": str(real), "reason": "explicit mapping", "candidates": [str(real)]}
        status = "missing" if why == "path does not exist" else "mismatch"
        return {"status": status, "path": None, "reason": f"explicit mapping: {why}", "candidates": [explicit]}
    found, rejected = [], []
    for ws in _workspaces(atlas_root, config, env):
        cand = Path(ws).expanduser() / meta["local_dir"]
        if not cand.exists():
            continue
        real, why = _verify(cand, meta)
        if real and str(real) not in found:
            found.append(str(real))
        elif not real:
            rejected.append(f"{cand}: {why}")
    if len(found) == 1:
        return {"status": "ok", "path": found[0], "reason": "workspace discovery", "candidates": found}
    if len(found) > 1:
        return {"status": "ambiguous", "path": None, "reason": "several checkouts found; add an explicit mapping", "candidates": found}
    if rejected:
        return {"status": "mismatch", "path": None, "reason": "; ".join(rejected), "candidates": []}
    return {"status": "missing", "path": None, "reason": "no checkout found", "candidates": []}


def worktrees(path):
    out, cur = [], {}
    for line in git(path, "worktree", "list", "--porcelain").splitlines() + [""]:
        if not line:
            if cur:
                out.append(cur)
            cur = {}
            continue
        key, _, value = line.partition(" ")
        if key == "worktree":
            cur = {"path": value, "branch": None, "commit": None}
        elif key == "HEAD":
            cur["commit"] = value
        elif key == "branch":
            cur["branch"] = value.removeprefix("refs/heads/")
        elif key in ("detached", "prunable", "locked"):
            cur[key] = True
    return out


def inspect(path):
    branch = git(path, "symbolic-ref", "--quiet", "--short", "HEAD", check=False) or None
    return {
        "path": str(path),
        "branch": branch,
        "commit": git(path, "rev-parse", "HEAD"),
        "dirty": bool(git(path, "status", "--porcelain", "--untracked-files=normal")),
        "worktrees": worktrees(path),
    }


def rev(path, ref):
    """Full commit SHA for a ref, or None if it does not resolve."""
    out = git(path, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}", check=False)
    return out if SHA_RE.match(out or "") else None


def worktree_content_hash(path):
    """Fingerprint of uncommitted state: HEAD, tracked diff, and untracked file contents."""
    h = hashlib.sha256()
    h.update(git(path, "rev-parse", "HEAD").encode())
    h.update(git(path, "diff", "HEAD", "--binary", "--no-ext-diff", binary=True))
    untracked = git(path, "ls-files", "--others", "--exclude-standard", "-z", binary=True).split(b"\0")
    for rel in sorted(u for u in untracked if u):
        h.update(rel + b"\0")
        f = Path(path) / rel.decode()
        if f.is_file():
            h.update(f.read_bytes())
    return h.hexdigest()


def config_hash(config):
    return hashlib.sha256(json.dumps(config, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def snapshot_provenance(repo_id, path, ref, scan_config, tool_versions, scope="baseline", overlay=False):
    """Provenance for one scan. A committed snapshot is clean by construction (it reads a
    commit, not the working tree). `overlay=True` describes the working tree instead and
    records a content hash so it can never pass as a committed baseline."""
    commit = rev(path, ref)
    if not commit:
        raise GitError(f"{ref!r} does not resolve to a commit in {path}")
    symbolic = None if SHA_RE.match(ref) else (git(path, "rev-parse", "--symbolic-full-name", ref, check=False) or ref)
    meta = {
        "repository_id": repo_id,
        "source_commit": commit,
        "source_ref": symbolic,
        "source_tree": git(path, "rev-parse", f"{commit}^{{tree}}"),
        "dirty": False,
        "scope": scope,
        "scan_config_hash": config_hash(scan_config),
        "tool_versions": tool_versions,
        "built_at": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if overlay:
        meta["scope"] = "local-overlay"
        meta["dirty"] = bool(git(path, "status", "--porcelain"))
        meta["content_hash"] = worktree_content_hash(path)
    return meta
