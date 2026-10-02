"""Temporary Git repositories and atlas roots for the tests. Standard library only."""
import contextlib
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

TOOLS = Path(__file__).resolve().parent.parent / "tools"
sys.path.insert(0, str(TOOLS))
import atlas  # noqa: E402
import resolver  # noqa: E402

FIXED_DATE = "2026-09-30T12:00:00+00:00"


def sh(cwd, *args, date=FIXED_DATE):
    env = dict(os.environ, GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date, GIT_AUTHOR_NAME="t",
               GIT_AUTHOR_EMAIL="t@example.invalid", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid",
               GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    return subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, check=True, env=env).stdout.strip()


def make_repo(path, files, url=None):
    """Create a repo with one commit containing `files` ({relpath: text}). Returns the commit."""
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True)
    sh(path, "init", "-q", "-b", "main")
    if url:
        sh(path, "remote", "add", "origin", url)
    return commit(path, files, "initial")


def commit(path, files, message, date=FIXED_DATE):
    for rel, text in files.items():
        f = Path(path) / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)
    sh(path, "add", "-A")
    sh(path, "commit", "-q", "--allow-empty", "-m", message, date=date)
    return sh(path, "rev-parse", "HEAD")


def meta(rid, layer="app", local_dir=None, url=None, refs=(), edges=(), status="active", products=()):
    return {"schema_version": 1, "id": rid, "display_name": rid, "status": status, "layer": layer,
            "repository": {"url": url, "default_branch": "main"}, "local_dir": local_dir or rid,
            "refs": list(refs), "products": list(products), "instructions": [], "edges": list(edges),
            "summary_review": None}


def write_registry(root, metas):
    for m in metas:
        d = Path(root) / "repos" / m["id"]
        d.mkdir(parents=True, exist_ok=True)
        (d / "meta.json").write_text(json.dumps(m, indent=2) + "\n")


def tree_digest(*roots):
    """Hash of every file (path, bytes) under the roots, including .git internals."""
    h = hashlib.sha256()
    for root in roots:
        for p in sorted(Path(root).rglob("*")):
            if p.is_file() and not p.is_symlink():
                h.update(str(p).encode())
                h.update(p.read_bytes())
    return h.hexdigest()


class AtlasCase(unittest.TestCase):
    """Each test gets a workspace folder holding an `atlas` root and sibling checkouts."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.ws = Path(self._tmp.name).resolve()
        self.root = self.ws / "atlas"
        (self.root / "repos").mkdir(parents=True)
        patcher = mock.patch.dict(os.environ, {"OPENCAPTURE_ATLAS_ROOT": str(self.root)})
        patcher.start()
        os.environ.pop("OPENCAPTURE_WORKSPACE", None)
        self.addCleanup(patcher.stop)
        self.addCleanup(self._tmp.cleanup)

    def run_atlas(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            try:
                code = atlas.main(list(argv))
            except SystemExit as exc:
                code = exc.code
        return code, out.getvalue()
