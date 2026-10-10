#!/usr/bin/env python3
"""Publish the OpenCine platform repository and move the apps onto it (RELEASE-01, ADR 0010).

Dry run by default: prints every step and every file diff it would make, and writes nothing.
`--execute` acts. Progress is kept in .local/publish-state.json, so rerunning the same command
resumes after the last finished step. Everything is driven by compat/release-<version>.json.

  preflight  recorded decisions, clean checkouts on the recorded branch and commit (the platform
             may differ from its recorded commit only under atlas/, where the record lives),
             recorded green evidence, publishable author emails, required tools
  platform   the one repository this atlas lives in: remote, clean-clone verify, one annotated
             tag, push main and the tag
  apps       the one package by URL + exact version, issue templates that route shared-code
             problems to OpenCine, resolve and commit lock files, Android sibling pin of the tag
             commit, clean-clone verify, push the branch, draft pull request (--open-prs)
  project    one GitHub project under the owner that links all four repositories and holds
             their open issues (`project` re-syncs it later)
  atlas      repository URL, refs, live edges once every app PR exists, compat/VERSIONS.md,
             `atlas check --sources`, commit on the platform's main, push

Other commands: `decide` and `record` edit the release record, `rewrite-authors` replaces
author emails before the first push, `table` prints compat/VERSIONS.md, `project` adds open
issues to the GitHub project (dry run unless --execute). See docs/PUBLISH.md.
Standard library only.
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import atlas  # noqa: E402
import resolver  # noqa: E402

OK, FAIL, USAGE = 0, 1, 2
FOOTER = "\U0001f916 Generated with [Claude Code](https://claude.com/claude-code)"
NOREPLY = re.compile(r"@users\.noreply\.github\.com$")
# Apps pin the one platform package by exact version and commit Package.resolved. The platform
# itself has no package dependency, so there is no library range to declare.
APP_REQUIREMENT = 'exact: "{v}"'
DECISIONS = {
    "owner": "GitHub account or organization for the new repositories (recommended: erik-sutton95, where the apps live)",
    "visibility": "public or private (recommended: public, so contributors resolve packages without credentials)",
    "android": "Android distribution for this release; only `sibling-pins` is automated (Gradle includes the OpenCine checkout pinned to the tag commit); a Maven namespace is a later release",
    "author_email": "email for commits and tags this run creates, and the target of `rewrite-authors`; `keep` publishes existing author emails as they are",
}
PINS_HEADER = """\
# The OpenCine platform at its released tag ({v}). scripts/checkout-opencine.sh checks it out next
# to this repository (CI fetches and verifies the commit; a developer's own checkout is only
# reported, never moved). Android builds read it (Gradle includeBuild named opencine) until Maven
# artifacts exist; Apple builds resolve the same version from Package.swift and Package.resolved.
"""
# One GitHub project (Projects v2) under the owner shows the issues of every repository.
PROJECT_TITLE = "OpenCapture"
CI_COMMENT = [
    "The OpenCine platform at the released tag in opencine-pins.txt, checked out next to the",
    "repository: the Android build includes its Gradle build until Maven artifacts exist. Apple",
    "builds resolve the same version from Package.swift and Package.resolved.",
]
CI_SHARED_TEST_COMMENT = [
    "The OpenCine platform at the released tag in opencine-pins.txt, checked out next to the",
    "repository for just core-test's shared integration tests. Apple application builds resolve",
    "the same version from Package.swift and Package.resolved.",
]
CI_SHARED_NOTES_COMMENT = [
    "The OpenCine platform at the released tag in opencine-pins.txt, checked out next to the",
    "repository for shared TestFlight and Play notes validators. Application builds resolve",
    "the same version from Package.swift and Package.resolved.",
]


class Stop(Exception):
    """A step cannot continue. The message says what to do."""


def atlas_root():
    return Path(os.environ.get("OPENCAPTURE_ATLAS_ROOT") or Path(__file__).resolve().parent.parent)


def git(path, *args, check=True):
    """Like resolver.git, but reads the environment at call time (identity, config isolation)."""
    r = subprocess.run(["git", "-C", str(path), *args], capture_output=True, env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
    if check and r.returncode:
        raise Stop(f"git {' '.join(args)} in {path}: {r.stderr.decode(errors='replace').strip()}")
    return r.stdout.decode(errors="replace").strip()


def base_name(rel):
    return posixpath.basename(posixpath.normpath(rel.rstrip("/")))


# ---------------------------------------------------------------- comment cleanup

# Sentences that only made sense while dependencies were sibling paths.
STALE = re.compile(
    r"sibling|\bcandidate\b|\.\./|opencine-pins|until (?:it is|\w+ is) published|once (?:it is|those \w+ are) published"
    r"|when published|swap to|switch to|same directory|has a remote|remotes? exists?|owner/URL", re.I)
CLAUSES = [
    (re.compile(r"\s*\((?:the )?sibling [^)]*\)"), ""),
    (re.compile(r",? which depends on the same \S+ checkout"), ""),
    (re.compile(r",?\s*(?:a |the )?sibling (?:path )?checkout(?: of \w+)?(?: next to this repository)?"), ""),
    (re.compile(r"^Candidate (\w)"), lambda m: m.group(1).upper()),
]


def _clean_paragraph(text):
    kept = []
    for s in re.split(r"(?<=[.!?])\s+(?=[A-Z(`])", text.strip()):
        for rx, rep in CLAUSES:
            s = rx.sub(rep, s)
        s = s.strip()
        if STALE.search(s) or len(re.findall(r"[A-Za-z]{2,}", s)) < 3:
            continue
        kept.append(s)
    return " ".join(kept)


def clean_comments(text, marker):
    """Drop stale sentences from whole-line comment blocks that mention sibling paths.

    Paragraphs without a stale sentence keep their exact lines; changed ones are rewrapped to
    the block's width; a block left empty disappears.
    """
    # The SwiftPM tools-version line is a directive, never part of a comment block.
    rx = re.compile(rf"^([ \t]*){re.escape(marker)}(?! swift-tools-version)(?: (.*))?$")
    lines, out, i = text.split("\n"), [], 0
    while i < len(lines):
        m = rx.match(lines[i])
        if not m:
            out.append(lines[i])
            i += 1
            continue
        indent, j, block = m.group(1), i, []
        while j < len(lines) and (c := rx.match(lines[j])) and c.group(1) == indent:
            block.append((lines[j], c.group(2) or ""))
            j += 1
        if not STALE.search(" ".join(b for _, b in block)):
            out += [raw for raw, _ in block]
            i = j
            continue
        paras, cur = [], []
        for raw, content in block:
            if content.strip():
                cur.append((raw, content.strip()))
            else:
                paras.append(cur)
                cur = []
        paras.append(cur)
        width = max(60, max(len(raw) for raw, _ in block))
        prefix, new = f"{indent}{marker} ", []
        for p in filter(None, paras):
            joined = " ".join(c for _, c in p)
            if not STALE.search(joined):
                body = [raw for raw, _ in p]
            else:
                cleaned = _clean_paragraph(joined)
                if not cleaned:
                    continue
                body = textwrap.wrap(cleaned, width=width, initial_indent=prefix, subsequent_indent=prefix,
                                     break_long_words=False, break_on_hyphens=False)
            if new:
                new.append(f"{indent}{marker}")
            new += body
        out += new
        i = j
    return "\n".join(out)


# ---------------------------------------------------------------- manifest rewriters (pure)

PACKAGE_PATH = re.compile(r'\.package\(\s*path:\s*"([^"]+)"\s*\)')


def rewrite_package_swift(text, urls, requirement):
    """`.package(path: "../X")` for a released X -> `.package(url: ..., <requirement>)`."""
    hit = []

    def sub(m):
        name = base_name(m.group(1))
        if name not in urls:
            return m.group(0)
        hit.append(name)
        return f'.package(url: "{urls[name]}", {requirement})'

    out = PACKAGE_PATH.sub(sub, text)
    return clean_comments(out, "//") if hit else text


def rewrite_project_yml(text, urls, version):
    """XcodeGen `packages:` entries with `path: ../../X` -> `url:` + `exactVersion:`."""
    m = re.search(r"(?m)^packages:[ \t]*\n((?:[ \t][^\n]*\n|\n)*)", text)
    if not m:
        return text
    hit = []

    def sub(mm):
        name = base_name(mm.group(2))
        if name not in urls:
            return mm.group(0)
        hit.append(name)
        return f"{mm.group(1)}url: {urls[name]}\n{mm.group(1)}exactVersion: {version}"

    block = re.sub(r"(?m)^([ \t]+)path:[ \t]*[\"']?([^\"'\s]+)[\"']?[ \t]*$", sub, m.group(1))
    if not hit:
        return text
    return text[:m.start(1)] + clean_comments(block, "#") + text[m.end(1):]


LOCAL_REF = re.compile(
    r'(?m)^(\t+)(\w+) /\* XCLocalSwiftPackageReference "([^"]+)" \*/ = \{\n'
    r'\t+isa = XCLocalSwiftPackageReference;\n\t+relativePath = "?([^";\n]+)"?;\n\t+\};\n')


def rewrite_pbxproj(text, urls, version):
    """Xcode local package references to a released X -> remote references, exact version."""
    converted = []

    def drop(m):
        name = base_name(m.group(4))
        if name not in urls:
            return m.group(0)
        converted.append((m.group(1), m.group(2), m.group(3), name))
        return ""

    out = LOCAL_REF.sub(drop, text)
    if not converted:
        return text
    entries = ""
    for ind, oid, label, name in converted:
        out = out.replace(f'/* XCLocalSwiftPackageReference "{label}" */', f'/* XCRemoteSwiftPackageReference "{name}" */')
        entries += (f'{ind}{oid} /* XCRemoteSwiftPackageReference "{name}" */ = {{\n'
                    f'{ind}\tisa = XCRemoteSwiftPackageReference;\n'
                    f'{ind}\trepositoryURL = "{urls[name]}";\n'
                    f'{ind}\trequirement = {{\n{ind}\t\tkind = exactVersion;\n{ind}\t\tversion = {version};\n{ind}\t}};\n'
                    f'{ind}}};\n')
    end = "/* End XCRemoteSwiftPackageReference section */"
    if end in out:
        out = out.replace(end, entries + end, 1)
    else:
        begin = "/* Begin XCSwiftPackageProductDependency section */"
        section = f"/* Begin XCRemoteSwiftPackageReference section */\n{entries}{end}\n\n"
        out = out.replace(begin, section + begin, 1) if begin in out else out.replace("\t};\n\trootObject", f"\n{section}\t}};\n\trootObject", 1)
    return re.sub(r"/\* Begin XCLocalSwiftPackageReference section \*/\n/\* End XCLocalSwiftPackageReference section \*/\n\n?", "", out)


def rewrite_pins(text, shas, version):
    """Keep the pinned names; point each released one at its tag commit; fresh header."""
    entries = []
    for line in text.splitlines():
        parts = line.split()
        if parts and not line.lstrip().startswith("#"):
            entries.append(f"{parts[0]} {shas.get(parts[0], parts[1] if len(parts) > 1 else '')}".rstrip())
    return PINS_HEADER.format(v=version) + "\n".join(entries) + "\n"


def rewrite_checkout_script(text, base):
    m = re.search(r"base=\$\{1:-([^}]+)\}", text)
    return text.replace(m.group(1), base) if m and m.group(1) != base else text


CHECKOUT_RUN = re.compile(r"^\s*(?:-\s+)?run:\s*(?:sh\s+)?(?:\./)?scripts/checkout-opencine\.sh\b")


def rewrite_workflow(text, keep_for_android):
    """Keep pinned siblings for shared core tests, notes validators and Android Gradle;
    drop the checkout and its comment from ordinary remote Swift/iOS jobs."""
    lines = text.split("\n")
    i = len(lines)
    while i > 0:
        i -= 1
        if not CHECKOUT_RUN.match(lines[i]):
            continue
        j = i
        while j > 0 and not re.match(r"^\s*- ", lines[j]):
            j -= 1
        indent = re.match(r"^(\s*)-", lines[j]).group(1)
        end = i + 1
        while end < len(lines) and lines[end].startswith(indent + "  ") and lines[end].strip():
            end += 1
        k = j
        while k > 0 and lines[k - 1].startswith(indent + "#"):
            k -= 1
        start = next((n for n in range(j, -1, -1) if re.match(r"^  [\w-]+:\s*$", lines[n])), 0)
        stop = next((n for n in range(i + 1, len(lines)) if re.match(r"^  [\w-]+:\s*$", lines[n])), len(lines))
        job = "\n".join(lines[start:stop])
        shared_core_tests = re.search(r"(?m)^\s*run:\s*just\s+core-test(?:\s|$)", job)
        shared_notes = re.search(
            r"(?m)^\s*(?:run:\s*)?(?:\./)?scripts/(?:ios|android)-release-notes-(?:check|test)\.sh(?:\s|$)", job)
        if shared_core_tests:
            lines[k:j] = [f"{indent}# {c}" for c in CI_SHARED_TEST_COMMENT]
        elif shared_notes:
            lines[k:j] = [f"{indent}# {c}" for c in CI_SHARED_NOTES_COMMENT]
        elif keep_for_android and "gradlew" in job:
            lines[k:j] = [f"{indent}# {c}" for c in CI_COMMENT]
        else:
            del lines[k:end]
            if k < len(lines) and k > 0 and not lines[k].strip() and not lines[k - 1].strip():
                del lines[k]
        i = k
    return "\n".join(lines)


def drop_checkout_from_script(text):
    """Xcode Cloud post-clone: the iOS build no longer needs sibling checkouts."""
    lines = text.split("\n")
    i = len(lines)
    while i > 0:
        i -= 1
        if "scripts/checkout-opencine.sh" in lines[i] and not lines[i].lstrip().startswith("#"):
            k = i
            if k > 0 and re.match(r'\s*step "', lines[k - 1]):
                k -= 1
            while k > 0 and lines[k - 1].lstrip().startswith("#") and not lines[k - 1].startswith("#!"):
                k -= 1
            del lines[k:i + 1]
            if 0 < k < len(lines) and not lines[k].strip() and not lines[k - 1].strip():
                del lines[k]
            i = k
    return "\n".join(lines)


# Issue templates: an app issue form asks whether the problem is app-only or shared, and the
# chooser links OpenCine's tracker. Existing app templates are edited, never replaced.
SHARED_LINK = """\
  - name: Shared camera, UI or multicam code (OpenCine)
    url: {url}/issues/new/choose
    about: For contributors. A bug in code several apps share belongs in OpenCine. Not sure? Report it here; maintainers move it.

"""
SHARED_QUESTION = """
  - type: dropdown
    id: shared
    attributes:
      label: Does this happen in another OpenCapture app too? (optional)
      description: >
        OpenPocketCine, OpenInstaCine and OpenZCine share code in OpenCine ({url}).
        Maintainers move a problem that is not specific to this app there.
      options:
        - I am not sure
        - Only in this app
        - Also in another OpenCapture app
"""


def route_issue_templates(rel, text, opencine_url):
    """Add the OpenCine link to an issue chooser and the app-only-or-shared question to a form."""
    if f"{opencine_url}/issues" in text or "id: shared" in text:
        return text
    if rel.endswith("ISSUE_TEMPLATE/config.yml") and re.search(r"(?m)^contact_links:[ \t]*\n", text):
        return re.sub(r"(?m)^contact_links:[ \t]*\n\n?", lambda m: "contact_links:\n" + SHARED_LINK.format(url=opencine_url), text, count=1)
    if re.search(r"ISSUE_TEMPLATE/[^/]+\.ya?ml$", rel) and re.search(r"(?m)^body:", text):
        return text.rstrip("\n") + "\n" + SHARED_QUESTION.format(url=opencine_url)
    return text


# ---------------------------------------------------------------- the run

class Run:
    def __init__(self, args, root):
        self.args, self.root = args, root
        self.release_path = root / "compat" / f"release-{args.version}.json"
        if not self.release_path.is_file():
            raise Stop(f"no release record {self.release_path.relative_to(root)}")
        self.release = json.loads(self.release_path.read_text())
        self.version = self.release["version"]
        self.reg, errors = atlas.load_registry(root)
        if errors:
            raise Stop("; ".join(errors))
        self.execute = getattr(args, "execute", False)
        self.owner = getattr(args, "owner", None) or (self.release.get("decisions") or {}).get("owner") or "erik-sutton95"
        self.base = (getattr(args, "remote_base", None) or "").rstrip("/") or None
        self.file_mode = bool(self.base and self.base.startswith("file://"))
        self.state_path = root / ".local" / "publish-state.json"
        self.state = json.loads(self.state_path.read_text()) if self.state_path.is_file() else {
            "version": self.version, "remote_base": self.base, "steps": {}}
        self.logs = root / ".local" / "publish-logs"
        # The platform is the repository this atlas lives in (<platform>/atlas).
        self.platform_id = self.release["platform"]["repo"]
        self.packages = [self.platform_id]
        self.names = {self.reg[r]["local_dir"]: r for r in self.packages}
        self.atlas_prefix = git(root, "rev-parse", "--show-prefix")
        self._paths = {}

    # -- naming
    def name(self, rid):
        return self.reg[rid]["local_dir"]

    def url(self, name):
        """What manifests and the registry record: the canonical repository identity."""
        return f"{self.base}/{name}" if self.base else f"https://github.com/{self.owner}/{name}"

    def url_base(self):
        return self.base or f"https://github.com/{self.owner}"

    def push_url(self, name, registered=None):
        if self.base:
            return f"{self.base}/{name}"
        m = re.match(r"https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$", registered or "")
        return f"git@github.com-personal:{m.group(1)}/{m.group(2)}.git" if m else f"git@github.com-personal:{self.owner}/{name}.git"

    def entry(self, rid):
        return next(e for e in [self.release["platform"]] + self.release["apps"] if e["repo"] == rid)

    def path(self, rid):
        if rid in self._paths:
            return self._paths[rid]
        if rid == self.platform_id:
            p = Path(git(self.root, "rev-parse", "--show-toplevel"))
        else:
            res = resolver.resolve(self.reg[rid], self.root)
            if res["status"] != "ok":
                raise Stop(f"{rid}: checkout {res['status']}: {res['reason']} (map it in .local/checkouts.json)")
            p = Path(res["path"])
            branch = self.entry(rid)["branch"]
            wt = next((w for w in resolver.worktrees(p) if w.get("branch") == branch), None)
            if not wt:
                raise Stop(f"{rid}: no worktree of {p} has {branch} checked out")
            p = Path(wt["path"])
        self._paths[rid] = p
        return p

    def tag_shas(self, placeholder=True):
        out = {}
        for rid in self.packages:
            sha = self.state["steps"].get(f"tag:{self.name(rid)}")
            if sha or placeholder:
                out[self.name(rid)] = sha or f"<{self.name(rid)} {self.version} tag commit>"
        return out

    def email_args(self):
        e = (self.release.get("decisions") or {}).get("author_email")
        return ["-c", f"user.email={e}"] if e and e != "keep" else []

    # -- state
    def save_state(self):
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.state_path.write_text(json.dumps(self.state, indent=2, sort_keys=True) + "\n")

    def step(self, key, what, fn, preview=None):
        done = self.state["steps"].get(key)
        if done is not None:
            print(f"  done   {key}: {done if isinstance(done, str) else json.dumps(done)}")
            return done
        if not self.execute:
            print(f"  would  {what}")
            if preview:
                preview()
            return None
        print(f"  run    {what}", flush=True)
        value = fn()
        self.state["steps"][key] = value
        self.save_state()
        return value

    # -- preflight
    def expected_head(self, rid):
        if rid == self.platform_id:
            return self.entry(rid)["commit"]
        return self.state["steps"].get("app-convert:" + self.name(rid)) or self.entry(rid)["commit"]

    def atlas_only(self, a, b):
        """True when commits a and b of the platform differ only under atlas/ (registry, record)."""
        changed = git(self.path(self.platform_id), "diff", "--name-only", a, b).splitlines()
        return all(f.startswith(self.atlas_prefix) for f in changed)

    def preflight(self):
        problems, warnings = [], []
        if self.state.get("remote_base") != self.base or self.state.get("version") != self.version:
            problems.append(f".local/publish-state.json belongs to a run with remote base {self.state.get('remote_base')} "
                            f"and version {self.state.get('version')}; rerun with those, or move the state file away to start over")
        d = self.release.get("decisions") or {}
        for key, hint in DECISIONS.items():
            if not d.get(key):
                problems.append(f"decision not recorded: {key}: {hint}. Record it: python3 tools/publish.py decide --{key.replace('_', '-')} <value>")
        if d.get("owner") and d["owner"] != self.owner:
            problems.append(f"--owner {self.owner} differs from the recorded decision {d['owner']}")
        if d.get("visibility") and d["visibility"] != self.args.visibility:
            problems.append(f"--visibility {self.args.visibility} differs from the recorded decision {d['visibility']}")
        if d.get("android") and d["android"] != "sibling-pins":
            problems.append(f"android decision {d['android']!r}: only sibling-pins is automated; publish Maven artifacts separately (docs/PUBLISH.md)")
        commands = [c for e in [self.release["platform"]] + self.release["apps"] for c in e.get("verify", []) + e.get("resolve", [])]
        tools = {"git"} | {c.split()[0] for c in commands} | (set() if self.base else {"gh"})
        problems += [f"tool not found: {t}" for t in sorted(tools) if not shutil.which(t)]
        if any(re.search(r"gradlew|android-check", c) for c in commands):
            problems += [f"{v} is not set (Gradle verify steps need it)" for v in ("JAVA_HOME", "ANDROID_HOME") if not os.environ.get(v)]
        if not self.base and shutil.which("gh") and not self.gh_token(check=False):
            problems.append(f"gh has no token for {self.args.gh_user}: gh auth login, then retry")
        for rid in self.packages + [a["repo"] for a in self.release["apps"]]:
            try:
                self.check_repo(rid, problems, warnings, d)
            except Stop as exc:
                problems.append(str(exc))
        for w in warnings:
            print(f"WARNING {w}")
        for p in problems:
            print(f"BLOCKED {p}")
        print(f"preflight: {'passed' if not problems else f'{len(problems)} problem(s)'}, {len(warnings)} warning(s)")
        return not problems

    def check_repo(self, rid, problems, warnings, d):
        e, path, name = self.entry(rid), self.path(rid), self.name(rid)
        head, want = git(path, "rev-parse", "HEAD"), self.expected_head(rid)
        branch = git(path, "symbolic-ref", "--quiet", "--short", "HEAD", check=False)
        if branch != e["branch"]:
            problems.append(f"{name}: on {branch or 'a detached HEAD'}, expected {e['branch']}")
        same = head == want or (rid == self.platform_id and resolver.rev(path, want) and self.atlas_only(want, head))
        if not same:
            problems.append(f"{name}: {e['branch']} is at {head[:12]}, the release record expects {want[:12]}. "
                            f"Rerun its tests, then: python3 tools/publish.py record {rid} --evidence '<where the green run is recorded>'")
        if git(path, "status", "--porcelain", "--untracked-files=normal"):
            problems.append(f"{name}: uncommitted changes in {path}")
        ev = e.get("evidence") or {}
        if not (ev.get("status") == "passed" and ev.get("commit") == e["commit"] and ev.get("where")):
            problems.append(f"{name}: no passed test evidence recorded for {e['commit'][:12]} (record it with `publish.py record`)")
        if d.get("author_email") and d["author_email"] != "keep":
            span = [e["branch"]] if rid == self.platform_id else [e["branch"], "--not", "--remotes"]
            emails = set(git(path, "log", "--format=%ae%n%ce", *span).split())
            bad = sorted(x for x in emails if x != d["author_email"] and not NOREPLY.search(x))
            if bad:
                problems.append(f"{name}: commits to publish carry {', '.join(bad)}; run python3 tools/publish.py rewrite-authors --execute "
                                f"(new repositories only) or record author_email keep")
        for f in e.get("notes_files", []):
            if f not in git(path, "log", "--format=", "--name-only", e["branch"], "--not", "--remotes").split():
                warnings.append(f"{name}: {f} is not changed on {e['branch']}; the app's CI requires it before the PR can pass")

    # -- GitHub
    def gh_token(self, check=True):
        r = subprocess.run(["gh", "auth", "token", "--user", self.args.gh_user], capture_output=True, text=True)
        if r.returncode and check:
            raise Stop(f"gh auth token --user {self.args.gh_user}: {r.stderr.strip()}")
        return r.stdout.strip()

    def gh(self, *args, check=True):
        r = subprocess.run(["gh", *args], capture_output=True, text=True, env=dict(os.environ, GH_TOKEN=self.gh_token()))
        if r.returncode and check:
            raise Stop(f"gh {' '.join(args[:3])}: {r.stderr.strip()}")
        return r

    # -- shared steps
    def create_remote(self, rid):
        name, path = self.name(rid), self.path(rid)
        if not self.base:
            if self.gh("repo", "view", f"{self.owner}/{name}", check=False).returncode:
                self.gh("repo", "create", f"{self.owner}/{name}", f"--{self.args.visibility}",
                        "--description", self.entry(rid).get("description", ""))
        elif self.file_mode and not Path(self.base[len("file://"):], name).is_dir():
            raise Stop(f"{self.url(name)}: no repository there (file remote base: create it with git init --bare)")
        want, cur = self.push_url(name), git(path, "remote", "get-url", "origin", check=False)
        if not cur:
            git(path, "remote", "add", "origin", want)
        elif cur != want:
            raise Stop(f"{name}: origin is {cur}, expected {want}; fix the remote or rerun with the matching --remote-base")
        return want

    def commit(self, path, files, message):
        present = [f for f in files if (path / f).exists()]
        gone = [f for f in files if not (path / f).exists()]
        if present:
            git(path, "add", "--", *present)
        if gone:
            git(path, "rm", "-q", "--cached", "--ignore-unmatch", "--", *gone)
        extra = [ln for ln in git(path, "status", "--porcelain", "--untracked-files=normal").splitlines()
                 if ln[3:].strip('"') not in files]
        if extra:
            raise Stop(f"{path}: unexpected changes, not committed:\n" + "\n".join(extra))
        if git(path, "diff", "--cached", "--name-only"):
            git(path, *self.email_args(), "commit", "-q", "-m", message)
        return git(path, "rev-parse", "HEAD")

    def rewrites(self, rid, requirement, is_app):
        """{relative path: new text, or None to delete} for one checkout."""
        path, urls = self.path(rid), {n: self.url(n) for n in self.names}
        tracked = git(path, "ls-files").splitlines()
        out = {}
        for rel in tracked:
            if not (path / rel).is_file() or re.search(r"(^|/)(\.build|build|vendor|reference|ref|DerivedData)/", rel):
                continue
            base = posixpath.basename(rel)
            if base == "Package.swift":
                fn = lambda t: rewrite_package_swift(t, urls, requirement)  # noqa: E731
            elif base == "project.yml":
                fn = lambda t: rewrite_project_yml(t, urls, self.version)  # noqa: E731
            elif base == "project.pbxproj":
                fn = lambda t: rewrite_pbxproj(t, urls, self.version)  # noqa: E731
            else:
                continue
            old = (path / rel).read_text()
            if (new := fn(old)) != old:
                out[rel] = new
        if is_app:
            for rel in tracked:
                if re.match(r"^\.github/ISSUE_TEMPLATE/(config|bug_report)\.ya?ml$", rel):
                    old = (path / rel).read_text()
                    if (new := route_issue_templates(rel, old, self.url(self.name(self.platform_id)))) != old:
                        out[rel] = new
        sibling_gradle = bool(git(path, "grep", "-l", "-E", r"includeBuild\(.(\.\./)+(" + "|".join(self.names) + ")/",
                                  "--", "*.gradle.kts", "*.gradle", check=False))
        keep = is_app or sibling_gradle
        if "opencine-pins.txt" in tracked:
            if keep:
                out["opencine-pins.txt"] = rewrite_pins((path / "opencine-pins.txt").read_text(), self.tag_shas(), self.version)
                script = path / "scripts/checkout-opencine.sh"
                if script.is_file() and (new := rewrite_checkout_script(script.read_text(), self.url_base())) != script.read_text():
                    out["scripts/checkout-opencine.sh"] = new
            else:
                out["opencine-pins.txt"] = None
                if "scripts/checkout-opencine.sh" in tracked:
                    out["scripts/checkout-opencine.sh"] = None
        for rel in tracked:
            if rel.startswith(".github/workflows/") and rel.endswith((".yml", ".yaml")) or rel.endswith("ci_scripts/ci_post_clone.sh"):
                old = (path / rel).read_text()
                if "scripts/checkout-opencine.sh" not in old:
                    continue
                new = drop_checkout_from_script(old) if rel.endswith(".sh") else rewrite_workflow(old, keep)
                if new != old:
                    out[rel] = new
        return {k: v for k, v in out.items() if v is None or (path / k).read_text() != v}

    def show(self, rid, changes):
        path = self.path(rid)
        for rel, new in sorted(changes.items()):
            if new is None:
                print(f"         delete {rel}")
                continue
            diff = difflib.unified_diff((path / rel).read_text().splitlines(), new.splitlines(),
                                        f"a/{rel}", f"b/{rel}", n=1, lineterm="")
            print("\n".join("         " + ln for ln in diff))
        stale = git(path, "grep", "-l", "-E", r"opencine-pins|\.\./OpenCine", "--", "*.md", check=False).split()
        if stale:
            print(f"         note: docs that mention sibling paths or pins (review by hand): {', '.join(stale)}")

    def apply(self, rid, changes):
        path = self.path(rid)
        for rel, new in changes.items():
            if new is None:
                (path / rel).unlink(missing_ok=True)
            else:
                (path / rel).write_text(new)

    def verify(self, rid, commit, commands):
        """Run commands in a fresh clone at `commit`: no local overrides, packages from remotes."""
        name, tmp = self.name(rid), Path(tempfile.mkdtemp(prefix="opencine-publish-"))
        src = git(self.path(rid), "rev-parse", "--path-format=absolute", "--git-common-dir")
        try:
            dest = tmp / name
            git(tmp, "clone", "-q", "--shared", "--no-checkout", src, str(dest))
            git(dest, "-c", "advice.detachedHead=false", "checkout", "-q", "--detach", commit)
            self.logs.mkdir(parents=True, exist_ok=True)
            env = dict(os.environ, CI="1")
            # shell=True: commands come from the reviewed release record, never from outside input.
            for n, cmd in enumerate(commands, 1):
                cmd = cmd.replace("{base}", self.url_base())
                log = self.logs / f"{name}-{n}.log"
                print(f"         $ {cmd}", flush=True)
                with log.open("w") as fh:
                    code = subprocess.run(cmd, shell=True, cwd=dest, env=env, stdout=fh, stderr=subprocess.STDOUT).returncode
                if code:
                    tail = "\n".join(log.read_text(errors="replace").splitlines()[-25:])
                    raise Stop(f"{name}: `{cmd}` failed with exit {code} in a clean clone at {commit[:12]}; log {log}\n{tail}")
            return {"commit": commit, "passed": commands}
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    # -- the platform repository
    def publish_platform(self):
        rid = self.platform_id
        name, e = self.name(rid), self.entry(rid)
        print(f"{name}")
        self.step(f"remote:{name}", f"create {self.url(name)} ({self.args.visibility}) unless it exists; origin {self.push_url(name)}",
                  lambda: self.create_remote(rid))
        verified = self.step(f"verify:{name}", f"verify a clean clone of {e['branch']}: {'; '.join(e.get('verify', []))}",
                             lambda: self.verify(rid, git(self.path(rid), "rev-parse", f"refs/heads/{e['branch']}"), e.get("verify", [])))
        self.step(f"tag:{name}", f"annotated tag {self.version} on the verified {e['branch']} commit",
                  lambda: self.tag(rid, verified["commit"]))
        self.step(f"push:{name}", f"push {e['branch']} and {self.version} to origin",
                  lambda: self.push(rid, [f"refs/heads/{e['branch']}", f"refs/tags/{self.version}"]))

    def tag(self, rid, commit):
        path = self.path(rid)
        have = git(path, "rev-parse", "-q", "--verify", f"refs/tags/{self.version}^{{commit}}", check=False)
        if have and have != commit:
            raise Stop(f"{self.name(rid)}: tag {self.version} already exists at {have[:12]}, not at {commit[:12]}")
        if not have:
            git(path, *self.email_args(), "tag", "-a", self.version, "-m", f"{self.name(rid)} {self.version}", commit)
        return commit

    def push(self, rid, refs, url=None):
        path = self.path(rid)
        git(path, "push", "-q", url or "origin", *[f"{r}:{r}" for r in refs])
        return git(path, "rev-parse", refs[0])

    # -- apps
    def publish_app(self, rid):
        name, e = self.name(rid), self.entry(rid)
        print(f"{name} ({e['branch']})")
        req = APP_REQUIREMENT.format(v=self.version)
        head = self.step(f"app-convert:{name}", f"take OpenCine by URL, {req}; resolve ({'; '.join(e.get('resolve', []))}); commit",
                         lambda: self.convert_app(rid, req), preview=lambda: self.show(rid, self.rewrites(rid, req, True)))
        self.step(f"app-verify:{name}", f"verify a clean clone: {'; '.join(e.get('verify', []))}",
                  lambda: self.verify(rid, head, e.get("verify", [])))
        url = self.push_url(name, self.reg[rid]["repository"].get("url"))
        self.step(f"app-push:{name}", f"push {e['branch']} to {url}", lambda: self.push(rid, [f"refs/heads/{e['branch']}"], url))
        if self.args.open_prs:
            self.step(f"pr:{name}", "open a draft pull request against main", lambda: self.open_pr(rid))
        else:
            print("  skip   pull request (pass --open-prs)")

    def convert_app(self, rid, requirement):
        path, e = self.path(rid), self.entry(rid)
        changes = self.rewrites(rid, requirement, True)
        self.apply(rid, changes)
        logs = []
        for n, cmd in enumerate(e.get("resolve", []), 1):
            self.logs.mkdir(parents=True, exist_ok=True)
            log = self.logs / f"{self.name(rid)}-resolve-{n}.log"
            print(f"         $ {cmd}", flush=True)
            with log.open("w") as fh:
                if subprocess.run(cmd, shell=True, cwd=path, stdout=fh, stderr=subprocess.STDOUT).returncode:
                    raise Stop(f"{self.name(rid)}: `{cmd}` failed; log {log}; the converted files are left uncommitted in {path}")
            logs.append(str(log))
        used = ", ".join(sorted(n for n in self.names if any(v and self.url(n) in v for v in changes.values())))
        body = (f"Apple builds resolve {used} {self.version} from {self.url_base()} and commit "
                "Package.resolved (Xcode Cloud resolves from it). Android keeps the sibling checkout, now "
                f"pinned to the {self.version} tag commit in opencine-pins.txt, until Maven artifacts exist. "
                + ("Issue templates ask whether a problem is app-only or shared and link OpenCine. "
                   if any(k.startswith(".github/ISSUE_TEMPLATE/") for k in changes) else "")
                + "Generated by OpenCine atlas/tools/publish.py.")
        msg = f"build: take OpenCine {self.version} by URL and exact version\n\n" + textwrap.fill(body, 72, break_long_words=False, break_on_hyphens=False)
        return self.commit(path, list(changes) + e.get("lockfiles", []), msg)

    def pr_body(self, rid):
        name, e = self.name(rid), self.entry(rid)
        app_url = (self.reg[rid]["repository"].get("url") or self.url(name)).rstrip("/")
        steps = self.state["steps"]
        v = steps.get(f"app-verify:{name}") or {}
        pins = git(self.path(rid), "show", "HEAD:opencine-pins.txt", check=False).split()
        rows = "\n".join(f"| {n} | {self.version} | `{sha[:12]}` |" for n, sha in self.tag_shas(placeholder=False).items() if n in pins)
        checks = "\n".join(f"  - `{c.replace('{base}', self.url_base())}`" for c in v.get("passed", []))
        notes = "\n".join(f"- [ ] `{f}` updated (the CI notes gate requires it)" for f in e.get("notes_files", []))
        ev = e.get("evidence") or {}
        return f"""Draft. Moves {name} onto the shared OpenCine platform (work packages {', '.join(e.get('work_packages', []))}) and takes it as a released version.

| Package | Version | Tag commit |
|---|---|---|
{rows}

- Apple: Package.swift and the Xcode project take OpenCine by URL and exact version; Package.resolved is committed, so Xcode Cloud resolves exactly this version.
- Android: Gradle still includes the OpenCine build (named `opencine`) from a sibling checkout pinned to the tag commit in `opencine-pins.txt` (`scripts/checkout-opencine.sh`) until Maven artifacts are published.

### Evidence

- Before the URL switch: {ev.get('where', 'not recorded')} (commit `{e['commit'][:12]}`).
- After the URL switch, in a clean clone at `{(v.get('commit') or '')[:12]}` with no local overrides, these passed:
{checks}
- Not run by the publish script: simulator test suites (CI runs them) and hardware. Device checklist: [{e.get('checklist')}]({app_url}/blob/{e['branch']}/{e.get('checklist')}).

### Before marking ready

- [ ] CI gate green, and the Native and Android jobs actually ran
{notes}
- [ ] Xcode Cloud: a build of this branch passes `ci_post_clone.sh` and resolves from the committed Package.resolved
- [ ] Device checklist items run on hardware

{FOOTER}
"""

    def open_pr(self, rid):
        name, e = self.name(rid), self.entry(rid)
        body = self.pr_body(rid)
        out = self.root / ".local" / "publish" / f"{name}-pr.md"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(body)
        if self.file_mode:
            return f"rehearsal: no pull request with a file remote base; body at .local/publish/{out.name}"
        if self.base:
            raise Stop("pull requests need GitHub; omit --open-prs with a custom --remote-base")
        repo = re.sub(r"^https://github\.com/", "", self.reg[rid]["repository"]["url"]).rstrip("/")
        have = self.gh("pr", "list", "--repo", repo, "--head", e["branch"], "--state", "all", "--json", "url", "--jq", ".[0].url").stdout.strip()
        if have:
            return have
        return self.gh("pr", "create", "--repo", repo, "--base", "main", "--head", e["branch"], "--draft",
                       "--title", e.get("pr_title", f"OpenCine {self.version}"), "--body-file", str(out)).stdout.strip()

    # -- GitHub project
    def project_repos(self):
        apps = [re.sub(r"^https://github\.com/", "", self.reg[a["repo"]]["repository"]["url"] or "").rstrip("/") for a in self.release["apps"]]
        return [f"{self.owner}/{self.name(self.platform_id)}"] + [a for a in apps if a]

    def sync_project(self):
        """Find or create the owner's project, link the four repositories, add open issues it lacks."""
        title = self.release.get("project_title", PROJECT_TITLE)
        found = json.loads(self.gh("project", "list", "--owner", self.owner, "--format", "json", "--limit", "100").stdout or "{}")
        proj = next((p for p in found.get("projects", []) if p.get("title") == title), None)
        if not proj:
            proj = json.loads(self.gh("project", "create", "--owner", self.owner, "--title", title, "--format", "json").stdout)
        num = str(proj["number"])
        repos = self.project_repos()
        for repo in repos:
            r = self.gh("project", "link", num, "--owner", self.owner, "--repo", repo, check=False)
            if r.returncode and "already" not in r.stderr.lower():
                raise Stop(f"gh project link {repo}: {r.stderr.strip()} (the token needs the project scope: docs/PUBLISH.md)")
        items = json.loads(self.gh("project", "item-list", num, "--owner", self.owner, "--format", "json", "--limit", "2000").stdout or "{}")
        have = {(i.get("content") or {}).get("url") for i in items.get("items", [])}
        added = []
        for repo in repos:
            for issue in json.loads(self.gh("issue", "list", "--repo", repo, "--state", "open", "--limit", "1000", "--json", "url").stdout or "[]"):
                if issue["url"] not in have:
                    self.gh("project", "item-add", num, "--owner", self.owner, "--url", issue["url"])
                    added.append(issue["url"])
        print(f"         project {proj.get('url', num)}: linked {', '.join(repos)}; added {len(added)} open issue(s)")
        return {"number": proj["number"], "url": proj.get("url"), "added": len(added)}

    # -- atlas
    def update_atlas(self):
        steps, apps = self.state["steps"], [a["repo"] for a in self.release["apps"]]
        live = all(steps.get(f"pr:{self.name(a)}") for a in apps)
        rid, name = self.platform_id, self.name(self.platform_id)
        m = self.reg[rid]
        m["repository"]["url"] = self.url(name)
        m["refs"] = [{"name": self.entry(rid)["branch"], "commit": steps[f"tag:{name}"], "role": "baseline"}]
        if live:
            m["status"] = "active"
        changed = [rid]
        for app in apps:
            m, e = self.reg[app], self.entry(app)
            head = steps[f"app-push:{self.name(app)}"]
            m["refs"] = [r for r in m["refs"] if r["name"] != e["branch"]] + [{"name": e["branch"], "commit": head, "role": "candidate"}]
            for edge in m["edges"]:
                if edge["to"] == rid and edge.get("ref") == e["branch"]:
                    edge["evidence"] = dict(edge.get("evidence") or {"path": "Package.swift"}, source_commit=head)
                    edge["note"] = f"url dependency {self.url(name)}, {APP_REQUIREMENT.format(v=self.version)}; Android: sibling pin of the tag commit"
            changed.append(app)
        for r in changed:
            (self.root / "repos" / r / "meta.json").write_text(json.dumps(self.reg[r], indent=2) + "\n")
        (self.root / "compat" / "VERSIONS.md").write_text(versions_table(self))
        r = subprocess.run([sys.executable, str(Path(__file__).resolve().parent / "atlas.py"), "check", "--sources"], capture_output=True,
                           text=True, env=dict(os.environ, OPENCAPTURE_ATLAS_ROOT=str(self.root)))
        print("\n".join("         " + ln for ln in (r.stdout + r.stderr).strip().splitlines()))
        if r.returncode:
            raise Stop("atlas check --sources failed; the registry edits are left uncommitted for review")
        files = [f"{self.atlas_prefix}repos/{r}/meta.json" for r in changed] + [f"{self.atlas_prefix}compat/VERSIONS.md"]
        why = "platform active (every app PR exists)" if live else "platform stays candidate until every app PR exists"
        head = self.commit(self.path(rid), files, f"Record the published platform and its {self.version} tag\n\n{why.capitalize()}. Generated by atlas/tools/publish.py.")
        self.push(rid, [f"refs/heads/{self.entry(rid)['branch']}"])
        return head

    def run(self):
        print(f"publish {self.version}: {'EXECUTE' if self.execute else 'dry run (nothing is written; --execute acts)'}; "
              f"owner {self.owner}; remotes {self.base or 'GitHub (ssh github.com-personal, https identity)'}")
        ok = self.preflight()
        if not ok and self.execute:
            return FAIL
        if not ok:
            print("(dry run continues so the whole plan can be reviewed; --execute refuses until preflight passes)")
        self.publish_platform()
        for app in self.release["apps"]:
            self.publish_app(app["repo"])
        print("GitHub project")
        if self.base:
            print("  skip   GitHub project (custom --remote-base)")
        else:
            self.step("project", f"find or create the project {self.release.get('project_title', PROJECT_TITLE)!r} under {self.owner}, "
                      f"link {', '.join(self.project_repos())} and add their open issues", self.sync_project)
        print(f"{self.name(self.platform_id)} atlas")
        # Keyed by the PR state, so a later `--open-prs` run updates the registry again (status active).
        live = all(self.state["steps"].get(f"pr:{self.name(a['repo'])}") for a in self.release["apps"])
        self.step(f"atlas:{'live' if live else 'candidate'}",
                  "set the repository URL and refs, active once every app PR exists, compat/VERSIONS.md, atlas check --sources, commit on main, push",
                  self.update_atlas)
        print("finished" if self.execute else "dry run finished: rerun with --execute to act")
        return OK if ok else FAIL


# ---------------------------------------------------------------- compat/VERSIONS.md

POLICY = """\
## Version policy (0.x)

- One version for everything: one annotated semantic-version tag on the OpenCine repository,
  without a prefix (`0.1.0`). Every Swift product and Gradle module shares it; the tag commit is the
  source SHA recorded everywhere else.
- Below 1.0, an incompatible interface change in any product bumps the minor version (0.1.x to
  0.2.0). Compatible fixes and additions bump the patch version. Never ship an incompatible change
  as a patch.
- The platform has no package dependencies, so there are no library ranges to keep compatible.
- Applications pin the exact version (`exact:`, `exactVersion:`) and commit Package.resolved. A bump
  is its own reviewed pull request per app with the update record of plan 10.2.
- No shipping app depends on a moving branch. Android takes the OpenCine checkout pinned to the tag
  commit (`opencine-pins.txt`, one line) until Maven artifacts exist (ADR 0007), then the same version
  as coordinates.
- Wire and JNI schema, artifact, app and relay protocol versions are separate and recorded
  separately.
- Rollback: pin the previous version in the app (its lock files show it). A published tag is never
  moved or deleted; fix forward with a new patch.
"""


def _app_cell(texts, name):
    joined = "\n".join(texts)
    m = re.search(rf'/{name}"?,\s*exact:\s*"([^"]+)"|/{name}\n\s+exactVersion:\s*(\S+)|/{name}";\s*requirement = \{{\s*kind = exactVersion;\s*version = ([^;]+);', joined)
    if m:
        return f"{next(g for g in m.groups() if g)} exact"
    if re.search(rf'(?:path:\s*"?|relativePath = "?)[./]*/{name}\b', joined):
        return "sibling path"
    return ""


def versions_table(run):
    steps = run.state["steps"]
    out = [f"# OpenCine versions and app pins\n\nGenerated by `python3 tools/publish.py table` from "
           f"[release-{run.version}.json](release-{run.version}.json), the registry and the app manifests at the "
           "commits below. Regenerate after a release or a pin bump.\n", POLICY,
           "## Platform\n"]
    rid = run.platform_id
    m, name = run.reg[rid], run.name(rid)
    tag = steps.get(f"tag:{name}")
    release = run.version if tag else f"unreleased ({run.entry(rid)['branch']})"
    out += [f"{name}: {release} at `{(tag or run.entry(rid)['commit'])[:12]}`. Products by layer (meta.json `layers`):\n",
            "| Layer | Swift products | Gradle modules |", "|---|---|---|"]
    swift = {p["name"] for p in m["products"] if p["kind"] == "swift-library"}
    gradle = {p["name"]: p.get("coordinates") or p["name"] for p in m["products"] if p["kind"] == "gradle-module"}
    for layer, names in (m.get("layers") or {}).items():
        s_names = ", ".join(n for n in names if n in swift) or "none"
        g_names = ", ".join(f"`{gradle[n]}`" for n in names if n in gradle) or "none"
        out.append(f"| {layer} | {s_names} | {g_names} |")
    out += ["", "## Applications", "",
            "Released app `main` branches take no shared package yet. Each candidate branch below takes OpenCine:", ""]
    tags = run.tag_shas(placeholder=False)
    for app in run.release["apps"]:
        rid, name = app["repo"], run.name(app["repo"])
        commit = steps.get(f"app-push:{name}") or steps.get(f"app-convert:{name}") or app["commit"]
        try:
            path = run.path(rid)
            files = git(path, "ls-tree", "-r", "--name-only", commit).splitlines()
            texts = [git(path, "show", f"{commit}:{f}") for f in files
                     if posixpath.basename(f) in ("Package.swift", "project.yml", "project.pbxproj") and not f.startswith(("tools/", "Tests/"))]
            pins = dict(ln.split()[:2] for ln in git(path, "show", f"{commit}:opencine-pins.txt", check=False).splitlines()
                        if len(ln.split()) >= 2 and not ln.startswith("#"))
        except Stop:
            out.append(f"- {name}: checkout unavailable, not read\n")
            continue
        out += [f"### {name} `{app['branch']}` at `{commit[:12]}`", "", "| Package | Apple | Android sibling pin |", "|---|---|---|"]
        for pkg in sorted(set(pins) | {n for n in run.names if _app_cell(texts, n)}):
            apple = _app_cell(texts, pkg) or "not used"
            android = pins.get(pkg)
            android = "none" if not android else f"`{android[:12]}`" + (f" ({run.version} tag)" if tags.get(pkg) == android else "")
            if apple == "sibling path" and android != "none":
                apple = f"sibling path at `{pins[pkg][:12]}`"
            out.append(f"| {pkg} | {apple} | {android} |")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


# ---------------------------------------------------------------- record editing commands

def save_release(run, message, extra=()):
    run.release_path.write_text(json.dumps(run.release, indent=2) + "\n")
    rels = [str(run.release_path.relative_to(run.root)), *extra]
    git(run.root, "add", "--", *rels)
    git(run.root, "commit", "-q", "-m", message, "--", *rels)
    print(f"committed {', '.join(rels)} in the atlas: {message.splitlines()[0]}")


def cmd_decide(run, args):
    d = run.release.setdefault("decisions", {})
    for key in DECISIONS:
        val = getattr(args, key)
        if val is not None:
            d[key] = val
    if d.get("visibility") not in (None, "public", "private"):
        raise Stop("visibility must be public or private")
    save_release(run, "Record publish decisions: " + ", ".join(f"{k} {v}" for k, v in d.items() if v))
    return OK


def cmd_record(run, args):
    e = run.entry(args.repo)
    path = run.path(args.repo)
    if git(path, "status", "--porcelain", "--untracked-files=normal"):
        raise Stop(f"{path} has uncommitted changes; record only a committed state")
    head = git(path, "rev-parse", "HEAD")
    e["commit"] = head
    e["evidence"] = {"status": "passed", "commit": head, "where": args.evidence}
    # The registry follows the record: the branch's ref (and an app's edges on that ref) point at
    # the recorded commit, and compat/VERSIONS.md is regenerated, all in the same commit.
    m = run.reg[args.repo]
    role = "baseline" if args.repo == run.platform_id else "candidate"
    m["refs"] = [r for r in m["refs"] if r["name"] != e["branch"]] + [{"name": e["branch"], "commit": head, "role": role}]
    for edge in m["edges"]:
        if edge.get("ref") == e["branch"] and edge.get("evidence"):
            edge["evidence"]["source_commit"] = head
    meta = f"repos/{args.repo}/meta.json"
    (run.root / meta).write_text(json.dumps(m, indent=2) + "\n")
    (run.root / "compat" / "VERSIONS.md").write_text(versions_table(run))
    save_release(run, f"Record {run.name(args.repo)} {e['branch']} at {head[:12]} for publishing", [meta, "compat/VERSIONS.md"])
    return OK


def cmd_rewrite_authors(run, args):
    target = (run.release.get("decisions") or {}).get("author_email")
    if not target or target == "keep":
        raise Stop("record the author email first: python3 tools/publish.py decide --author-email <address>")
    script = (f'case "$GIT_AUTHOR_EMAIL" in {target}|*@users.noreply.github.com) ;; *) GIT_AUTHOR_EMAIL={target};; esac; '
              f'case "$GIT_COMMITTER_EMAIL" in {target}|*@users.noreply.github.com) ;; *) GIT_COMMITTER_EMAIL={target};; esac; '
              "export GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL")
    changed = []
    for rid in run.packages:
        e, path = run.entry(rid), run.path(rid)
        if run.state["steps"].get(f"push:{run.name(rid)}"):
            print(f"{run.name(rid)}: already pushed; not rewritten")
            continue
        emails = set(git(path, "log", "--format=%ae%n%ce", e["branch"]).split())
        bad = sorted(x for x in emails if x != target and not NOREPLY.search(x))
        if not bad:
            continue
        print(f"{run.name(rid)}: {'rewrite' if args.execute else 'would rewrite'} {', '.join(bad)} -> {target} on {e['branch']}")
        if not args.execute:
            continue
        if git(path, "status", "--porcelain", "--untracked-files=normal"):
            raise Stop(f"{path} has uncommitted changes")
        old = git(path, "rev-parse", "HEAD")
        r = subprocess.run(["git", "-C", str(path), "filter-branch", "-f", "--env-filter", script, e["branch"]],
                           capture_output=True, text=True, env=dict(os.environ, FILTER_BRANCH_SQUELCH_WARNING="1"))
        if r.returncode:
            raise Stop(f"{run.name(rid)}: filter-branch failed: {r.stderr.strip()}")
        git(path, "config", "user.email", target)
        new = git(path, "rev-parse", "HEAD")
        same_tree = git(path, "rev-parse", f"{old}^{{tree}}") == git(path, "rev-parse", f"{new}^{{tree}}")
        # The recorded commit is usually below HEAD (the record itself is committed on top), so map
        # it through the rewrite: an env filter keeps the topology, commit for commit.
        olds, news = (git(path, "rev-list", "--topo-order", "--reverse", c).split() for c in (old, new))
        rec = dict(zip(olds, news)).get(e["commit"]) if len(olds) == len(news) else None
        if same_tree and rec and rec != e["commit"]:
            if (e.get("evidence") or {}).get("commit") == e["commit"]:
                e["evidence"]["commit"] = rec
                e["evidence"]["where"] += f" (authors rewritten, tree identical to {e['commit'][:12]})"
            e["commit"] = rec
        changed.append(f"{run.name(rid)} {old[:12]}->{new[:12]}")
        print(f"  {old[:12]} -> {new[:12]} (tree {'identical' if same_tree else 'CHANGED'}); old history kept under refs/original/")
    if changed:
        save_release(run, "Record package commits after the author email rewrite\n\n" + "\n".join(changed))
    return OK


def main(argv=None):
    ap = argparse.ArgumentParser(prog="publish", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", default="0.1.0", help="selects compat/release-<version>.json")
    ap.add_argument("--execute", action="store_true", help="act; without it nothing is written")
    ap.add_argument("--open-prs", action="store_true", help="open draft app pull requests (GitHub only)")
    ap.add_argument("--owner", default=None, help="owner of the new repositories (default: the recorded decision, else erik-sutton95)")
    ap.add_argument("--visibility", choices=["public", "private"], default="public")
    ap.add_argument("--remote-base", help="override every remote, e.g. file:///tmp/fake-github (no gh calls, no PRs)")
    ap.add_argument("--gh-user", default="erik-sutton95", help="gh account whose token runs gh (GH_TOKEN)")
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("decide", help="record publish decisions in the release record (commits it)")
    for key, hint in DECISIONS.items():
        p.add_argument(f"--{key.replace('_', '-')}", dest=key, help=hint)
    p = sub.add_parser("record", help="record a repository's current commit and where its green tests are recorded")
    p.add_argument("repo")
    p.add_argument("--evidence", required=True)
    p = sub.add_parser("rewrite-authors", help="replace non-noreply author emails in unpublished package history")
    p.add_argument("--execute", action="store_true")
    p = sub.add_parser("table", help="print compat/VERSIONS.md (--write to write it)")
    p.add_argument("--write", action="store_true")
    p = sub.add_parser("project", help="add open issues of all four repositories to the GitHub project (dry run unless --execute)")
    p.add_argument("--execute", action="store_true")
    args = ap.parse_args(argv)
    try:
        run = Run(args, atlas_root())
        if args.cmd == "decide":
            return cmd_decide(run, args)
        if args.cmd == "record":
            return cmd_record(run, args)
        if args.cmd == "rewrite-authors":
            return cmd_rewrite_authors(run, args)
        if args.cmd == "project":
            if not args.execute:
                print(f"would find or create the project {run.release.get('project_title', PROJECT_TITLE)!r} under {run.owner}, "
                      f"link {', '.join(run.project_repos())} and add their open issues (--execute acts)")
                return OK
            run.sync_project()
            return OK
        if args.cmd == "table":
            text = versions_table(run)
            if args.write:
                (run.root / "compat" / "VERSIONS.md").write_text(text)
            else:
                print(text, end="")
            return OK
        return run.run()
    except Stop as exc:
        print(f"STOPPED {exc}", file=sys.stderr)
        print("Nothing after this step ran. Fix the cause and rerun the same command to resume.", file=sys.stderr)
        return FAIL


if __name__ == "__main__":
    sys.exit(main())
