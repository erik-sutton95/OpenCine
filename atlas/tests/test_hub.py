"""HUB-01 commands: ensure, impact <symbol|path>, issues and task start. No network: every gh call
goes through hub.gh_run, which these tests replace."""
import json
import os
import subprocess
import unittest
from unittest import mock

from support import AtlasCase, commit, make_repo, meta, sh, tree_digest, write_registry

import hub  # noqa: E402
import linked_issues  # noqa: E402
import orca_tasks  # noqa: E402
import resolver  # noqa: E402

PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "OpenCine",
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "Media", targets: ["Media"]),
        .library(name: "UI", targets: ["UI"]),
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "Media", dependencies: ["Core"]),
        .target(name: "UI"),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
    ]
)
'''
APP_PACKAGE = '''let package = Package(name: "App",
    dependencies: [.package(path: "../OpenCine")],
    targets: [.target(name: "App", dependencies: [.product(name: "Media", package: "OpenCine")])])
'''


def gh_ok(payload):
    return subprocess.CompletedProcess([], 0, json.dumps(payload), "")


class Hub(AtlasCase):
    def setUp(self):
        super().setUp()
        self.plat = make_repo(self.ws / "OpenCine", {
            "Package.swift": PACKAGE,
            "Sources/Core/Thing.swift": "public struct Thing {\n    public init() {}\n}\nprivate struct Hidden {}\n",
            "Sources/Media/Use.swift": "import Core\nlet t = Thing()\n",
            "Sources/UI/View.swift": "public struct Panel {}\n",
            "Tests/CoreTests/ThingTests.swift": "let x = Thing()\n",
            "Android/settings.gradle.kts": 'include(":core")\n',
            "Android/core/build.gradle.kts": "dependencies { }\n",
            "Android/core/src/main/kotlin/Thing.kt": "class Thing\n",
        })
        app = self.ws / "App"
        self.app_main = make_repo(app, {"README.md": "app\n"}, url="https://github.com/o/App")
        sh(app, "checkout", "-q", "-b", "opencine/integration")
        self.app_int = commit(app, {
            "Package.swift": APP_PACKAGE, "opencine-pins.txt": f"# pin\nOpenCine {self.plat}\n",
            "Sources/App/A.swift": "import Media\nfunc go() { _ = Thing() }\n",
        }, "take OpenCine")
        sh(app, "checkout", "-q", "main")
        self.other = make_repo(self.ws / "Other", {"Sources/O.swift": "struct Mine {}\n"}, url="https://github.com/o/Other")
        layers = {"core": ["Core", "Media", "CoreTests", ":core"], "ui": ["UI"]}
        products = [{"name": n, "kind": "swift-library", "manifest": "Package.swift"} for n in ("Core", "Media", "UI")] + [
            {"name": ":core", "kind": "gradle-module", "manifest": "Android/settings.gradle.kts", "coordinates": "com.opencapture.opencine:core"}]
        plat_meta = meta("opencine", "platform", "OpenCine", status="candidate", products=products,
                         refs=[{"name": "main", "commit": self.plat, "role": "baseline"}])
        plat_meta["layers"] = layers
        edge = {"to": "opencine", "kind": "library", "status": "candidate", "confidence": "inferred", "ref": "opencine/integration"}
        self.metas = [plat_meta,
                      meta("app", "app", "App", url="https://github.com/o/App", edges=[edge],
                           refs=[{"name": "main", "commit": self.app_main, "role": "baseline"},
                                 {"name": "opencine/integration", "commit": self.app_int, "role": "candidate"}]),
                      meta("other", "app", "Other", url="https://github.com/o/Other",
                           refs=[{"name": "main", "commit": self.other, "role": "baseline"}])]
        write_registry(self.root, self.metas)

    # -- impact
    def test_impact_symbol_owner_linking_apps_and_call_sites(self):
        code, out = self.run_atlas("impact", "Thing", "--json")
        self.assertEqual(code, 0, out)
        r = json.loads(out)
        self.assertEqual(r["owners"], {":core": "core", "Core": "core"})
        self.assertEqual(r["products"], [":core", "Core", "Media"])  # Media carries Core
        self.assertEqual(r["apps"]["app"]["links"], ["Media"])
        self.assertEqual(r["apps"]["app"]["ref"], "opencine/integration")
        self.assertEqual(r["apps"]["app"]["uses"], 1)
        self.assertEqual((r["apps"]["other"]["links"], r["apps"]["other"]["uses"]), ([], 0))
        self.assertEqual(r["platform"]["uses"], {":core": 1, "Core": 1, "CoreTests": 1, "Media": 1})
        code, out = self.run_atlas("impact", "Thing")
        self.assertIn("app @ opencine/integration", out)
        self.assertIn("Sources/App/A.swift:2:func go() { _ = Thing() }", out)

    def test_impact_path_uses_its_public_types(self):
        code, out = self.run_atlas("impact", "Sources/Core/Thing.swift", "--json")
        self.assertEqual(code, 0, out)
        r = json.loads(out)
        self.assertEqual((r["symbols"], list(r["owners"])), (["Thing"], ["Core"]))
        self.assertEqual(self.run_atlas("impact", "Sources/Nope.swift")[0], 2)

    def test_impact_unknown_and_app_only(self):
        self.assertEqual(self.run_atlas("impact", "NoSuchSymbol")[0], 1)
        code, out = self.run_atlas("impact", "Mine")
        self.assertEqual(code, 0, out)
        self.assertIn("declaration: none found in OpenCine", out)
        self.assertIn("other @ main", out)
        self.assertIn("declares its own (a copy, or an app-owned type with this name): Sources/O.swift:1:struct Mine {}", out)

    def test_impact_app_ref_reads_the_shipped_branch(self):
        r = json.loads(self.run_atlas("impact", "Thing", "--json", "--app-ref", "main")[1])
        self.assertEqual((r["apps"]["app"]["ref"], r["apps"]["app"]["commit"], r["apps"]["app"]["uses"]), ("main", self.app_main, 0))

    def test_impact_repo_ids_keep_consumer_waves(self):
        code, out = self.run_atlas("impact", "opencine", "--registry-only", "--include-candidates")
        self.assertIn("Impact of a change in opencine", out)

    def test_impact_reports_a_missing_app_as_incomplete(self):
        sh(self.ws / "App", "branch", "-D", "opencine/integration")
        self.metas[1]["refs"][1]["commit"] = "f" * 40
        write_registry(self.root, self.metas)
        code, out = self.run_atlas("impact", "Thing")
        self.assertEqual(code, 3, out)
        self.assertIn("app: INCOMPLETE", out)

    # -- ensure
    def test_ensure_check_writes_nothing_then_clones_with_identity(self):
        bare = self.ws / "remote" / "Gone.git"
        src = self.ws / "src"
        make_repo(src, {"README.md": "gone\n"})
        subprocess.run(["git", "clone", "-q", "--bare", str(src), str(bare)], check=True)
        url = f"file://{bare}"
        write_registry(self.root, self.metas + [meta("gone", "app", "Gone", url=url, refs=[])])
        before = tree_digest(self.ws)
        code, out = self.run_atlas("ensure", "--check")
        self.assertEqual(code, 3, out)
        self.assertIn(f"would clone {url}", out)
        self.assertEqual(tree_digest(self.ws), before)
        (self.root / ".local").mkdir()
        (self.root / ".local" / "checkouts.json").write_text(json.dumps({"identity": {"name": "Me", "email": "me@example.invalid"}}))
        code, out = self.run_atlas("ensure")
        self.assertEqual(code, 0, out)
        self.assertEqual(sh(self.ws / "Gone", "config", "user.email"), "me@example.invalid")
        code, out = self.run_atlas("ensure", "--check")
        self.assertEqual(code, 0, out)

    def test_ensure_never_touches_a_mismatched_folder(self):
        make_repo(self.ws / "Stray", {"x": "y\n"}, url="https://github.com/someone/else")
        write_registry(self.root, self.metas + [meta("stray", "app", "Stray", url="https://github.com/o/Stray", refs=[])])
        before = tree_digest(self.ws)
        code, out = self.run_atlas("ensure")
        self.assertEqual(code, 1, out)
        self.assertIn("MISMATCH", out)
        self.assertEqual(tree_digest(self.ws), before)

    # -- issues
    def issues(self, *argv, result=None, which="/usr/bin/gh"):
        with mock.patch.object(hub, "gh_run", side_effect=result) as gh, mock.patch.object(hub.shutil, "which", return_value=which):
            code, out = self.run_atlas("issues", *argv)
        return code, out, gh

    def test_issues_lists_every_registered_github_repo(self):
        listing = [{"number": 12, "title": "Feed freezes", "labels": [{"name": "bug"}], "updatedAt": "2026-10-01T00:00:00Z", "url": "u"}]
        code, out, gh = self.issues(result=lambda args: gh_ok(listing if "o/App" in args else []))
        self.assertEqual(code, 0, out)
        self.assertIn("app#12", out)
        self.assertIn("[bug]", out)
        self.assertIn("opencine: no GitHub repository registered yet, skipped", out)
        self.assertEqual(gh.call_count, 2)

    def test_issues_offline_and_without_gh_are_not_errors(self):
        offline = subprocess.CompletedProcess([], 1, "", "error connecting to api.github.com")
        code, out, _ = self.issues(result=lambda args: offline)
        self.assertEqual(code, 0, out)
        self.assertIn("offline", out)
        code, out, gh = self.issues(which=None)
        self.assertEqual(code, 0, out)
        self.assertIn("not installed", out)
        gh.assert_not_called()

    def test_issues_real_error_fails(self):
        bad = subprocess.CompletedProcess([], 1, "", "HTTP 404: Not Found")
        code, out, _ = self.issues("app", result=lambda args: bad)
        self.assertEqual(code, 1, out)
        self.assertEqual(self.issues("nope")[0], 2)

    # -- task start
    def start(self, *argv, issue=None):
        payload = issue or {"number": 12, "title": "Feed freezes", "body": "It froze.", "labels": [], "url": "https://github.com/o/App/issues/12", "state": "OPEN"}
        with mock.patch.object(hub, "gh_run", return_value=gh_ok(payload)), mock.patch.object(hub.shutil, "which", return_value="/usr/bin/gh"):
            return self.run_atlas("task", "start", *argv)

    def test_task_start_app_only(self):
        code, out = self.start("App#12")
        self.assertEqual(code, 0, out)
        task = self.ws / "OpenCine-tasks" / "app-12"
        wt = task / "App"
        self.assertEqual(sh(wt, "branch", "--show-current"), "issue/app-12")
        self.assertEqual(sh(wt, "rev-parse", "HEAD"), self.app_int, "branches from the ref the app consumes OpenCine on")
        self.assertEqual(sh(task / "OpenCine", "rev-parse", "HEAD"), self.plat, "../OpenCine is the app's pinned commit")
        self.assertEqual(sh(task / "OpenCine", "branch", "--show-current"), "")
        brief = (task / "TASK.md").read_text()
        self.assertIn("# app#12: Feed freezes", brief)
        self.assertIn("It froze.", brief)
        self.assertIn("--with opencine", brief)
        self.assertNotIn(chr(0x2014), brief)
        self.assertEqual(sh(self.ws / "App", "branch", "--show-current"), "main", "the shared checkout never switches")
        self.assertEqual(sh(self.ws / "App", "rev-parse", "opencine/integration"), self.app_int, "nothing is committed")
        code, out = self.start("app#12")
        self.assertEqual(code, 0, out)
        self.assertIn("reused", out)

    def test_task_start_shared_fix_puts_opencine_on_the_task_branch(self):
        self.assertEqual(self.start("app#12")[0], 0)
        task = self.ws / "OpenCine-tasks" / "app-12"
        with (task / "TASK.md").open("a") as fh:
            fh.write("\nDecision: shared, OpenCineMedia.\n")
        code, out = self.start("app#12", "--with", "opencine")
        self.assertEqual(code, 0, out)
        self.assertEqual(sh(task / "OpenCine", "branch", "--show-current"), "issue/app-12")
        brief = (task / "TASK.md").read_text()
        self.assertIn("Decision: shared, OpenCineMedia.", brief, "a rerun keeps what was written")
        self.assertIn("## Worktrees after a rerun of task start", brief)
        self.assertIn("| opencine |", brief.split("after a rerun")[1])

    def test_task_start_not_found_is_not_offline_and_pasted_text_fills_the_brief(self):
        missing = subprocess.CompletedProcess([], 1, "", "GraphQL: Could not resolve to an issue or pull request with the number of 77.")
        pasted = self.ws / "issue.txt"
        pasted.write_text("Waveform offset in I-Log\nGray card sits 10 IRE low.\n")
        with mock.patch.object(hub, "gh_run", return_value=missing), mock.patch.object(hub.shutil, "which", return_value="/usr/bin/gh"):
            code, out = self.run_atlas("task", "start", "app#77")
            self.assertEqual(code, 0, out)
            self.assertIn("Could not resolve to an issue", out)
            self.assertNotIn("offline", out)
            code, out = self.run_atlas("task", "start", "app#78", "--from-file", str(pasted))
        self.assertEqual(code, 0, out)
        brief = (self.ws / "OpenCine-tasks" / "app-78" / "TASK.md").read_text()
        self.assertIn("# app#78: Waveform offset in I-Log", brief)
        self.assertIn("Gray card sits 10 IRE low.", brief)
        self.assertIn("## Routing decision (fill in before editing)", brief)
        self.assertIn(f"app pins OpenCine {self.plat[:12]}.", brief)
        self.assertIn("Issue: text given by the user, not on GitHub", brief)
        self.assertNotIn("issues/78", brief)

    def test_task_start_offline_and_base_override(self):
        offline = subprocess.CompletedProcess([], 1, "", "dial tcp: lookup api.github.com: no such host")
        with mock.patch.object(hub, "gh_run", return_value=offline), mock.patch.object(hub.shutil, "which", return_value="/usr/bin/gh"):
            code, out = self.run_atlas("task", "start", "app#3", "--base", "main")
        self.assertEqual(code, 0, out)
        task = self.ws / "OpenCine-tasks" / "app-3"
        self.assertEqual(sh(task / "App", "rev-parse", "HEAD"), self.app_main)
        self.assertFalse((task / "OpenCine").exists(), "main has no OpenCine pin")
        brief = (task / "TASK.md").read_text()
        self.assertIn("Not fetched (offline)", brief)
        self.assertIn("so there is no OpenCine folder", brief)
        self.assertIn("branch -d issue/app-3", brief)
        self.assertEqual(self.run_atlas("task", "start", "nope#1")[0], 2)

    def linked_start(self, original=None, body=None, *flags, author=None):
        self.metas[0]["repository"]["url"] = "https://github.com/o/OpenCine"
        if not sh(self.ws / "OpenCine", "remote"):
            sh(self.ws / "OpenCine", "remote", "add", "origin", "https://github.com/o/OpenCine")
        write_registry(self.root, self.metas)
        reg = {m["id"]: m for m in self.metas}
        body = body if body is not None else linked_issues.managed_block(
            "app", {"number": 12, "title": "Feed freezes", "body": "Original report", "state": "open"}, reg)
        central = {"number": 70, "title": "Linked tracker", "body": body, "labels": [],
                   "url": "https://github.com/o/OpenCine/issues/70", "state": "OPEN",
                   "author": author if author is not None else {"is_bot": True, "login": "app/opencine-atlas-sync"}}
        source = original or {"number": 12, "title": "Original feed report", "body": "Original text, not tracker notes.",
                              "labels": [], "url": "https://github.com/o/App/issues/12", "state": "OPEN"}
        def fetch(args):
            return gh_ok(central if "o/OpenCine" in args else source)
        with mock.patch.object(hub, "gh_run", side_effect=fetch), mock.patch.object(hub.shutil, "which", return_value="/usr/bin/gh"):
            return self.run_atlas("task", "start", "opencine#70", *flags)

    def test_linked_task_routes_original_and_editable_core_in_existing_task(self):
        self.assertEqual(self.start("app#12")[0], 0)
        code, out = self.linked_start()
        self.assertEqual(code, 0, out)
        task = self.ws / "OpenCine-tasks" / "app-12"
        self.assertEqual(sh(task / "OpenCine", "branch", "--show-current"), "issue/app-12")
        self.assertEqual(sh(task / "App", "branch", "--show-current"), "issue/app-12")
        self.assertFalse((self.ws / "OpenCine-tasks" / "opencine-70").exists())
        text = (task / "TASK.md").read_text()
        self.assertIn("https://github.com/o/App/issues/12", text)
        self.assertIn("https://github.com/o/OpenCine/issues/70", text)
        self.assertIn("original remains", text.lower())
        self.assertEqual(self.linked_start()[0], 0)
        self.assertEqual((task / "TASK.md").read_text().count("Linked tracking issue:"), 1)

    def test_linked_task_fetches_original_and_rejects_wrong_source_before_mutation(self):
        code, out = self.linked_start()
        self.assertEqual(code, 0, out)
        self.assertIn("Original text, not tracker notes.", (self.ws / "OpenCine-tasks" / "app-12" / "TASK.md").read_text())
        wrong = {"number": 13, "title": "Wrong", "body": "", "url": "https://github.com/evil/repo/issues/13"}
        code, out = self.linked_start(wrong)
        self.assertNotEqual(code, 0, out)

    def test_unattested_app_author_keeps_quoted_tracker_in_core(self):
        code, out = self.linked_start(author={"is_bot": False, "login": "app/opencine-atlas-sync"})
        self.assertEqual(code, 0, out)
        task = self.ws / "OpenCine-tasks" / "opencine-70"
        self.assertTrue((task / "OpenCine").is_dir())
        self.assertFalse((task / "App").exists())
        self.assertFalse((self.ws / "OpenCine-tasks" / "app-12").exists())

    def test_invalid_linked_marker_fails_before_worktree_creation(self):
        code, out = self.linked_start(body="<!-- atlas-linked-issue:bad -->")
        self.assertNotEqual(code, 0, out)
        self.assertFalse((self.ws / "OpenCine-tasks").exists())

    def test_original_marker_text_is_report_data_after_single_validated_hop(self):
        source = {"number": 12, "title": "Quoted syntax", "body": "Example <!-- atlas-linked-issue:bad --> $(false)",
                  "url": "https://github.com/o/App/issues/12", "labels": [], "state": "OPEN"}
        code, out = self.linked_start(source)
        self.assertEqual(code, 0, out)
        self.assertIn("$(false)", (self.ws / "OpenCine-tasks" / "app-12" / "TASK.md").read_text())

    def test_existing_foreign_repository_with_same_task_branch_is_not_reused(self):
        self.assertEqual(self.start("app#12")[0], 0)
        foreign = self.ws / "OpenCine-tasks" / "app-12" / "Other"
        sh(self.ws / "Other", "worktree", "add", "-q", "-b", "issue/app-12", str(foreign))
        with self.assertRaises(Exception):
            hub._worktree(self.ws / "App", foreign, "issue/app-12", self.app_int)

    def test_native_core_task_keeps_its_identity_and_behavior(self):
        self.metas[0]["repository"]["url"] = "https://github.com/o/OpenCine"
        sh(self.ws / "OpenCine", "remote", "add", "origin", "https://github.com/o/OpenCine")
        write_registry(self.root, self.metas)
        code, out = self.start("opencine#4", issue={"number": 4, "title": "Core issue", "body": "Ordinary core report",
                                                   "url": "https://github.com/o/OpenCine/issues/4", "labels": [], "state": "OPEN"})
        self.assertEqual(code, 0, out)
        task = self.ws / "OpenCine-tasks" / "opencine-4"
        self.assertTrue((task / "OpenCine").is_dir())
        self.assertFalse((task / "App").exists())

    def test_native_core_marker_quotes_remain_data_before_authority(self):
        self.metas[0]["repository"]["url"] = "https://github.com/o/OpenCine"
        sh(self.ws / "OpenCine", "remote", "add", "origin", "https://github.com/o/OpenCine")
        write_registry(self.root, self.metas)
        reg = {m["id"]: m for m in self.metas}
        quoted = linked_issues.managed_block("app", {"number": 12, "title": "Example", "body": "Quoted source", "state": "open"}, reg)
        for number, body in ((4, "Quoted <!-- atlas-linked-issue:bad -->"), (5, quoted)):
            with self.subTest(number=number):
                code, out = self.start(f"opencine#{number}", issue={"number": number, "title": "Native parser report", "body": body,
                    "url": f"https://github.com/o/OpenCine/issues/{number}", "labels": [], "state": "OPEN", "author": {"login": "maintainer"}})
                self.assertEqual(code, 0, out)
                task = self.ws / "OpenCine-tasks" / f"opencine-{number}"
                self.assertTrue((task / "OpenCine").is_dir())
                self.assertFalse((task / "App").exists())

    def test_authenticated_duplicate_marker_fails_before_task_creation(self):
        self.metas[0]["repository"]["url"] = "https://github.com/o/OpenCine"
        reg = {m["id"]: m for m in self.metas}
        body = linked_issues.managed_block("app", {"number": 12, "title": "Example", "body": "", "state": "open"}, reg)
        code, out = self.linked_start(body=body + body)
        self.assertNotEqual(code, 0, out)
        self.assertFalse((self.ws / "OpenCine-tasks").exists())

    def test_fresh_orca_clicked_tracker_bootstraps_sources_and_reuses_physical_siblings(self):
        self.metas[0]["repository"]["url"] = "https://github.com/o/OpenCine"
        sh(self.ws / "OpenCine", "remote", "add", "origin", "https://github.com/o/OpenCine")
        launcher = self.ws / "orca" / "clicked-core-70"
        sh(self.ws / "OpenCine", "worktree", "add", "-q", "-b", "clicked-70", str(launcher))
        fresh_root = launcher / "atlas"
        write_registry(fresh_root, self.metas)
        reg = {m["id"]: m for m in self.metas}
        body = linked_issues.managed_block("app", {"number": 12, "title": "Feed", "body": "Report", "state": "open"}, reg)
        central = {"number": 70, "title": "Tracker", "body": body, "labels": [], "url": "https://github.com/o/OpenCine/issues/70", "state": "OPEN", "author": {"login": "opencine-atlas-sync[bot]"}}
        source = {"number": 12, "title": "Feed", "body": "Original", "labels": [], "url": "https://github.com/o/App/issues/12", "state": "OPEN"}
        repositories = [{"id": m["id"], "path": str(self.ws / m["local_dir"]),
                         "gitRemoteIdentity": {"remoteUrl": m["repository"]["url"]}} for m in self.metas]
        fields, calls = {}, []
        def catalog(args):
            calls.append(args)
            if args[:2] == ["repo", "list"]: return {"repos": repositories}
            def listed(rid):
                m = reg[rid]
                rows = []
                for gitrow in resolver.worktrees(self.ws / m["local_dir"]):
                    path = gitrow["path"]
                    identity = rid + "::" + path
                    row = {"id": identity, "path": path, "repoId": rid, "identity": {"key": "wt2:test:" + identity},
                           "linkedIssue": 70 if path == str(launcher) else None, "parentWorktreeId": None, "comment": "",
                           "isMainWorktree": path == str(self.ws / m["local_dir"])}
                    rows.append(dict(row, **fields.get(identity, {})))
                return rows
            if args[:2] == ["worktree", "current"]:
                return {"worktree": next(w for w in listed("opencine") if w["path"] == str(launcher))}
            if args[:2] == ["worktree", "list"]:
                return {"worktrees": listed(args[args.index("--repo") + 1].removeprefix("id:"))}
            identity = args[args.index("--worktree") + 1].removeprefix("id:")
            rid = identity.split("::")[0]
            if args[:2] == ["worktree", "set"]:
                update = fields.setdefault(identity, {})
                for flag, key in (("--issue", "linkedIssue"), ("--comment", "comment"), ("--parent-worktree", "parentWorktreeId")):
                    if flag in args:
                        value = args[args.index(flag) + 1]
                        update[key] = (None if value == "null" else int(value)) if flag == "--issue" else value.removeprefix("id:")
            return {"worktree": next(w for w in listed(rid) if w["id"] == identity)}
        def fetched(args): return gh_ok(central if "o/OpenCine" in args else source)
        with mock.patch.dict(os.environ, {"OPENCAPTURE_ATLAS_ROOT": str(fresh_root)}), \
                mock.patch.object(hub, "gh_run", side_effect=fetched), \
                mock.patch.object(hub.shutil, "which", return_value="/usr/bin/gh"), \
                mock.patch.object(orca_tasks, "orca_run", side_effect=catalog):
            self.assertFalse((fresh_root / ".local" / "checkouts.json").exists())
            control, _ = self.run_atlas("task", "start", "opencine#70")
            self.assertEqual(control, 3, "fresh raw mode has no app siblings; catalog bootstrap is necessary")
            code, out = self.run_atlas("task", "start", "opencine#70", "--orca")
            self.assertEqual(code, 0, out)
            task = self.ws / "OpenCine-tasks" / "app-12"
            receipt = json.loads((task / ".atlas-orca.json").read_text())
            self.assertTrue(receipt["complete"], receipt)
            self.assertEqual(len(receipt["adopted"]), 2)
            self.assertEqual((task / "App" / "../OpenCine").resolve(), (task / "OpenCine").resolve())
            self.assertEqual(sh(task / "App", "show", "HEAD:Package.swift"), APP_PACKAGE.strip())
            sets = sum(a[:2] == ["worktree", "set"] for a in calls)
            code, out = self.run_atlas("task", "start", "opencine#70", "--orca")
            self.assertEqual(code, 0, out)
            self.assertEqual(sum(a[:2] == ["worktree", "set"] for a in calls), sets)
            for flags in (("--with", "opencine"), ()):
                code, out = self.run_atlas("task", "start", "App#12", "--orca", *flags)
                self.assertEqual(code, 0, out)
                self.assertEqual(sum(a[:2] == ["worktree", "set"] for a in calls), sets)
                saved = json.loads((task / ".atlas-orca.json").read_text())
                self.assertEqual(saved["tracking"]["number"], 70)
                self.assertEqual(sh(task / "OpenCine", "branch", "--show-current"), "issue/app-12")
            self.assertFalse((fresh_root / ".local" / "checkouts.json").exists(), "bootstrap stays in memory")

    def test_registered_public_revision_is_not_rewound_to_a_stale_local_main(self):
        app = self.ws / "App"
        sh(app, "checkout", "-q", "-b", "published-tip", "main")
        published = commit(app, {"README.md": "published app\n"}, "published update")
        sh(app, "checkout", "-q", "main")
        ref = {"name": "main", "commit": published, "role": "baseline"}
        before = tree_digest(self.ws)
        self.assertEqual(hub.ref_tip(app, ref), published)
        self.assertEqual(sh(app, "rev-parse", "main"), self.app_main)
        self.assertEqual(tree_digest(self.ws), before, "routing must not switch or update the checkout")

    def test_current_descendant_tip_still_advances_a_registered_revision(self):
        app = self.ws / "App"
        advanced = commit(app, {"README.md": "new local app\n"}, "local update")
        ref = {"name": "main", "commit": self.app_main, "role": "baseline"}
        self.assertEqual(hub.ref_tip(app, ref), advanced)

        self.assertEqual(hub.primary_ref(self.metas[1], "opencine")["name"], "opencine/integration")
        self.assertEqual(hub.primary_ref(self.metas[2], "opencine")["name"], "main")


if __name__ == "__main__":
    unittest.main()
