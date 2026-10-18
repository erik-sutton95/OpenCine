"""Adopt Atlas's physical sibling Git worktrees through the public Orca catalog.

No relocation, global settings, source rewriting, agent launch or GitHub writes.
Failure preserves every worktree and records partial local custody for a rerun.
"""
from __future__ import annotations

import json
from contextlib import contextmanager
import os
from pathlib import Path
import shlex
import subprocess
import sys

import resolver


class OrcaError(RuntimeError):
    pass


def orca_run(args):
    if os.environ.get("ORCA_CLI_COMMAND"):
        command = shlex.split(os.environ["ORCA_CLI_COMMAND"])
    elif os.environ.get("ORCA_DEV_REPO_ROOT"):
        command = ["orca-dev"]
    else:
        command = ["orca-ide" if sys.platform.startswith("linux") and not os.environ.get("ORCA_TERMINAL_HANDLE") else "orca"]
    try:
        result = subprocess.run([*command, *args, "--json"], capture_output=True, text=True, timeout=60)
        value = json.loads(result.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        raise OrcaError(f"Orca {' '.join(args[:2])} unavailable or returned no JSON; preserve work and retry the same command") from exc
    if not isinstance(value, dict):
        raise OrcaError(f"Orca {' '.join(args[:2])} returned malformed JSON; preserve work and retry the same command")
    if result.returncode or not value.get("ok"):
        error = value.get("error")
        code = error.get("code", "unknown") if isinstance(error, dict) else "unknown"
        raise OrcaError(f"Orca {' '.join(args[:2])} failed ({code}); preserve work and rerun task start")
    if not isinstance(value.get("result"), dict):
        raise OrcaError(f"Orca {' '.join(args[:2])} returned no result object; preserve work and retry the same command")
    return value["result"]


def _number(worktree):
    value = worktree.get("linkedIssue")
    return value.get("number") if isinstance(value, dict) else value


class OrcaTasks:
    def __init__(self, reg, root, run=None):
        self.reg, self.root, self.run = reg, Path(root), run or orca_run
        self.registered = self.run(["repo", "list"]).get("repos", [])
        self.matches = {}
        for rid, m in reg.items():
            want = resolver.normalize_url((m.get("repository") or {}).get("url"))
            self.matches[rid] = [r for r in self.registered if want and resolver.normalize_url(
                (r.get("gitRemoteIdentity") or {}).get("remoteUrl")) == want]
        self.caller = self.run(["worktree", "current"]).get("worktree")

    def repo(self, rid):
        matches = self.matches.get(rid, [])
        if len(matches) != 1:
            raise OrcaError(f"{rid}: expected one registered Orca repository, found {len(matches)}; add the verified checkout with orca repo add --path, or resolve duplicates")
        return matches[0]

    def config(self):
        """Verified registered sources make a fresh clicked Core issue workspace usable."""
        cfg = resolver.load_local_config(self.root)
        paths = dict(cfg.get("repos") or {})
        for rid in self.reg:
            if rid not in paths:
                paths[rid] = self.repo(rid)["path"]
        return dict(cfg, repos=paths)

    @contextmanager
    def lock(self, folder):
        # Lazy import keeps legacy raw-Git commands portable. The supported Orca path
        # requires a POSIX advisory lock, released by the OS even after interruption.
        try:
            import fcntl
        except ImportError:
            raise OrcaError("--orca task locking requires a POSIX host; raw Git mode remains available") from None
        folder.mkdir(parents=True, exist_ok=True)
        with (folder / ".atlas-task.lock").open("a") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise OrcaError("another task-start process owns this original issue; reuse its task after it finishes") from None
            yield

    def _list(self, rid):
        return self.run(["worktree", "list", "--repo", "id:" + self.repo(rid)["id"]]).get("worktrees", [])

    def task_tracking(self, folder, rid, number, pid, requested=None):
        """The original and tracker are two entry points into one owned task."""
        path = Path(folder) / ".atlas-orca.json"
        saved = json.loads(path.read_text()) if path.exists() else {}
        if saved and saved.get("source") != f"{rid}#{number}":
            raise OrcaError("task custody receipt belongs to another original issue")
        previous = saved.get("tracking")
        for value in (requested, previous):
            if value is None: continue
            import linked_issues
            core_repo = linked_issues.github_repo(self.reg[pid])
            if not isinstance(value, dict) or set(value) != {"repo", "number", "url"} or value["repo"] != pid \
                    or type(value["number"]) is not int or value["number"] < 1 or not core_repo \
                    or value["url"] != f"https://github.com/{core_repo}/issues/{value['number']}":
                raise OrcaError("invalid saved tracking identity; preserve the task receipt")
        if requested and previous and requested != previous:
            raise OrcaError("task already belongs to a different tracking issue")
        return requested or previous

    def _plan(self, rows, rid, number, pid, tracking):
        source = f"{rid}#{number}"
        receipt_path = Path(rows[0]["path"]).parent / ".atlas-orca.json"
        saved = json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
        if saved and saved.get("source") != source:
            raise OrcaError("task custody receipt belongs to another original issue")
        prior = {}
        for record in saved.get("adopted", []) + saved.get("prior_adopted", []):
            prior.setdefault(record["id"], record)
        tracking = self.task_tracking(receipt_path.parent, rid, number, pid, tracking)
        core = next((r for r in rows if r["repo"] == pid), None)
        expected_core_issue = tracking["number"] if tracking else number if rid == pid else None
        caller = self.caller
        if caller and caller.get("repoId") == self.repo(pid)["id"] and _number(caller) is not None \
                and _number(caller) != expected_core_issue:
            raise OrcaError("caller Core workspace is linked to a different issue; start from the matching issue or an unlinked workspace")
        launcher = caller if caller and caller.get("repoId") == self.repo(pid)["id"] \
            and _number(caller) == expected_core_issue and expected_core_issue is not None and not caller.get("isMainWorktree") else None
        catalogs = {r["repo"]: self._list(r["repo"]) for r in rows}
        located = {}
        for row in rows:
            path = Path(row["path"]).resolve()
            matches = [w for w in catalogs[row["repo"]] if Path(w["path"]).resolve() == path]
            if len(matches) > 1:
                raise OrcaError(f"{row['repo']}: ambiguous physical task worktree in Orca")
            located[row["repo"]] = matches[0] if matches else None
        if launcher and located.get(pid) and launcher["id"] == located[pid]["id"]:
            launcher = None  # The adopted task is never its own launcher parent.
        plan = []
        for row in rows:
            repo_id = row["repo"]
            wt = located[repo_id]
            issue = number if repo_id == rid else expected_core_issue if repo_id == pid else None
            # Public Orca lineage is within one repository. Cross-repository parent
            # requests return LINEAGE_PARENT_CONTEXT_CONFLICT; use companion IDs.
            parent = launcher["id"] if repo_id == pid and launcher else None
            if repo_id == pid and wt and wt.get("comment", "").startswith(f"atlas-task:{source}\n"):
                record = prior.get(wt["id"])
                if record and record.get("parent") == wt.get("parentWorktreeId") \
                        and record.get("identity") == (wt.get("identity") or {}).get("key") \
                        and record.get("issue") == issue and Path(record["path"]).resolve() == Path(wt["path"]).resolve():
                    parent = record["parent"]
            for other in catalogs[repo_id]:
                if issue is not None and _number(other) == issue and (not wt or other["id"] != wt["id"]) \
                        and (not launcher or other["id"] != launcher["id"]) and other["id"] != parent:
                    raise OrcaError(f"{repo_id}#{issue}: another Orca worktree already owns the issue ({other['id']})")
            if wt:
                if wt.get("isMainWorktree") or _number(wt) not in (None, issue):
                    raise OrcaError(f"{repo_id}: conflicting task issue ownership")
                if wt.get("comment") and not wt["comment"].startswith(f"atlas-task:{source}\n"):
                    raise OrcaError(f"{repo_id}: foreign task comment; preserve its owner")
                if wt.get("parentWorktreeId") not in (None, parent):
                    raise OrcaError(f"{repo_id}: refusing to reparent another task")
            plan.append({"row": row, "worktree": wt, "issue": issue, "parent": parent})
        return plan

    def preflight(self, rows, rid, number, pid, tracking=None):
        self._plan(rows, rid, number, pid, tracking)

    def adopt(self, rows, folder, rid, number, pid, tracking=None):
        folder = Path(folder)
        state_path = folder / ".atlas-orca.json"
        source = f"{rid}#{number}"
        tracking = self.task_tracking(folder, rid, number, pid, tracking)
        previous = json.loads(state_path.read_text()) if state_path.exists() else {}
        if previous and previous.get("source") != source:
            raise OrcaError("task custody receipt belongs to another original issue")
        prior = {}
        for record in previous.get("adopted", []) + previous.get("prior_adopted", []):
            prior.setdefault(record["id"], record)
        state = {"version": 1, "source": source, "tracking": tracking, "mode": "adopted/discovered",
                 "complete": False, "adopted": [], "prior_adopted": list(prior.values()), "attempting": None, "error": None}

        def save():
            temp = state_path.with_suffix(".tmp")
            temp.write_text(json.dumps(state, indent=2) + "\n")
            temp.replace(state_path)

        save()
        try:
            plan = self._plan(rows, rid, number, pid, tracking)
            # Adopt the task Core first so apps can have its returned catalog ID as parent.
            plan.sort(key=lambda p: p["row"]["repo"] != pid)
            for item in plan:
                row, wt = item["row"], item["worktree"]
                if not wt:
                    raise OrcaError(f"{row['repo']}: public Orca catalog did not discover the exact task path; keep worktrees and rerun")
                companions = [p["worktree"]["id"] for p in plan if p["worktree"] and p["row"]["repo"] != row["repo"]]
                comment = (f"atlas-task:{source}\nAtlas-owned physical sibling task; see {folder / 'TASK.md'}.\n"
                           + "Companions: " + ", ".join(companions))
                state["attempting"] = {"id": wt["id"], "path": str(Path(row["path"]).resolve()),
                                       "issue": item["issue"], "parent": item["parent"], "companions": companions}
                save()
                if _number(wt) != item["issue"] or wt.get("parentWorktreeId") != item["parent"] or wt.get("comment") != comment:
                    args = ["worktree", "set", "--worktree", "id:" + wt["id"], "--issue",
                            str(item["issue"]) if item["issue"] is not None else "null", "--comment", comment]
                    args += ["--parent-worktree", "id:" + item["parent"]] if item["parent"] else []
                    self.run(args)
                actual = self.run(["worktree", "show", "--worktree", "id:" + wt["id"]])["worktree"]
                if not (actual.get("identity") or {}).get("key") or actual.get("id") != wt["id"] \
                        or Path(actual["path"]).resolve() != Path(row["path"]).resolve() \
                        or _number(actual) != item["issue"] or actual.get("parentWorktreeId") != item["parent"] \
                        or actual.get("comment") != comment:
                    raise OrcaError(f"{row['repo']}: Orca did not confirm exact identity, issue, owner and parent")
                state["adopted"].append(dict(state["attempting"], identity=actual["identity"]["key"]))
                state["attempting"] = None
                save()
            state["complete"] = True
            state.pop("prior_adopted", None)
        except (OrcaError, OSError, ValueError, KeyError) as exc:
            state["error"] = str(exc)
        save()
        return state
