"""Public Orca catalog adoption on temporary physical sibling Git worktrees."""
import copy
import json
from pathlib import Path

from support import AtlasCase, make_repo, meta, sh

import orca_tasks


class Catalog:
    def __init__(self, case):
        self.calls, self.fail = [], None
        self.repos = [{"id": rid, "path": str(path), "gitRemoteIdentity": {"remoteUrl": f"https://github.com/o/{rid}"}}
                      for rid, path in case.checkouts.items()]
        self.worktrees = {}
        for row in case.rows:
            rid, path = row["repo"], row["path"]
            self.worktrees[rid] = [{"id": rid + "::" + str(path), "repoId": rid, "path": str(path),
                                    "identity": {"key": "wt2:test:" + rid}, "linkedIssue": None,
                                    "parentWorktreeId": None, "comment": "", "isMainWorktree": False}]
        self.caller = {"id": "opencine::launcher", "repoId": "opencine", "path": str(case.checkouts["opencine"]),
                       "linkedIssue": 70, "isMainWorktree": False, "identity": {"key": "wt2:caller"}}

    def __call__(self, args):
        self.calls.append(list(args))
        if self.fail and self.fail(args):
            raise orca_tasks.OrcaError("SIMULATED Orca failure")
        if args[:2] == ["repo", "list"]:
            return {"repos": copy.deepcopy(self.repos)}
        if args[:2] == ["worktree", "current"]:
            return {"worktree": copy.deepcopy(self.caller)}
        if args[:2] == ["worktree", "list"]:
            rid = args[args.index("--repo") + 1].removeprefix("id:")
            return {"worktrees": copy.deepcopy(self.worktrees[rid])}
        selector = args[args.index("--worktree") + 1].removeprefix("id:")
        row = next(w for items in self.worktrees.values() for w in items if w["id"] == selector)
        if args[:2] == ["worktree", "set"]:
            for flag, key in (("--issue", "linkedIssue"), ("--parent-worktree", "parentWorktreeId"), ("--comment", "comment")):
                if flag in args:
                    value = args[args.index(flag) + 1]
                    row[key] = int(value) if flag == "--issue" and value != "null" else None if value == "null" else value.removeprefix("id:")
        return {"worktree": copy.deepcopy(row)}

    @property
    def writes(self):
        return [args for args in self.calls if args[:2] == ["worktree", "set"]]


class OrcaTasks(AtlasCase):
    def setUp(self):
        super().setUp()
        self.checkouts, self.rows, self.reg = {}, [], {}
        self.folder = self.ws / "OpenCine-tasks" / "app-12"
        self.folder.mkdir(parents=True)
        for rid, name in (("opencine", "OpenCine"), ("app", "App")):
            checkout = self.ws / name
            make_repo(checkout, {"Package.swift": '.package(path: "../OpenCine")\n' if rid == "app" else "// core\n"}, url=f"https://github.com/o/{rid}")
            path = self.folder / name
            sh(checkout, "worktree", "add", "-q", "-b", "issue/app-12", str(path))
            self.checkouts[rid] = checkout
            self.reg[rid] = meta(rid, "platform" if rid == "opencine" else "app", name, url=f"https://github.com/o/{rid}")
            self.rows.append({"repo": rid, "path": path, "checkout": str(checkout), "branch": "issue/app-12"})
        self.api = Catalog(self)
        self.tracking = {"repo": "opencine", "number": 70, "url": "https://github.com/o/opencine/issues/70"}

    def session(self):
        return orca_tasks.OrcaTasks(self.reg, self.root, run=self.api)

    def adopt(self, session=None):
        session = session or self.session()
        session.preflight(self.rows, "app", 12, "opencine", self.tracking)
        return session.adopt(self.rows, self.folder, "app", 12, "opencine", self.tracking)

    def test_adopt_verifies_identity_links_parent_physical_paths_and_rerun(self):
        receipt = self.adopt()
        self.assertTrue(receipt["complete"], receipt)
        core, app = self.api.worktrees["opencine"][0], self.api.worktrees["app"][0]
        self.assertEqual(core["linkedIssue"], 70)
        self.assertEqual(core["parentWorktreeId"], self.api.caller["id"])
        self.assertEqual(app["linkedIssue"], 12)
        self.assertIsNone(app["parentWorktreeId"], "runtime forbids cross-repository lineage")
        self.assertIn(core["id"], app["comment"])
        self.assertEqual((self.rows[1]["path"] / "../OpenCine").resolve(), self.rows[0]["path"].resolve())
        count = len(self.api.writes)
        self.assertTrue(self.adopt()["complete"])
        self.assertEqual(len(self.api.writes), count, "rerun reuses exact catalog ownership")
        self.assertFalse(any("create" in a or "--agent" in a for a in self.api.calls))

    def test_conflicting_or_duplicate_issue_links_refuse_all_metadata_writes(self):
        for kind in ("wrong", "duplicate", "parent", "owner"):
            with self.subTest(kind=kind):
                self.api = Catalog(self)
                row = self.api.worktrees["app"][0]
                if kind == "wrong": row["linkedIssue"] = 55
                if kind == "duplicate": self.api.worktrees["app"].append(dict(row, id="app::elsewhere", path=str(self.ws / "other"), linkedIssue=12))
                if kind == "parent": row["parentWorktreeId"] = "unrelated::parent"
                if kind == "owner": row["comment"] = "another task owns this"
                with self.assertRaises(orca_tasks.OrcaError): self.adopt()
                self.assertEqual(self.api.writes, [])

    def test_mismatched_caller_core_issue_refuses_to_reparent(self):
        self.api.caller["linkedIssue"] = 99
        with self.assertRaises(orca_tasks.OrcaError): self.adopt()
        self.assertEqual(self.api.writes, [])

    def test_partial_adoption_preserves_work_and_receipt_then_recovers(self):
        self.api.fail = lambda a: a[:2] == ["worktree", "set"] and a[a.index("--worktree") + 1].startswith("id:app::")
        receipt = self.adopt()
        self.assertFalse(receipt["complete"])
        self.assertEqual(len(receipt["adopted"]), 1)
        self.assertTrue((self.folder / "App" / "Package.swift").exists())
        self.assertEqual(json.loads((self.folder / ".atlas-orca.json").read_text())["source"], "app#12")
        self.api.fail = None
        self.assertTrue(self.adopt()["complete"])

    def test_catalog_must_confirm_identity_and_exact_link_after_set(self):
        real = self.api
        def missing_identity(args):
            result = real(args)
            if args[:2] == ["worktree", "show"]:
                result["worktree"].pop("identity")
            return result
        receipt = self.adopt(orca_tasks.OrcaTasks(self.reg, self.root, run=missing_identity))
        self.assertFalse(receipt["complete"])
        self.assertIn("identity", receipt["error"])

    def test_missing_or_ambiguous_registered_repo_is_incomplete(self):
        self.api.repos.pop()
        session = self.session()
        with self.assertRaises(orca_tasks.OrcaError): self.adopt(session)
        self.assertEqual(self.api.writes, [])
