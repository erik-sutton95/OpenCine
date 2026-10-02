"""compat plan/run: status semantics, workspace isolation, cleanup, injected breaks."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from support import AtlasCase, make_repo, meta, sh, tree_digest, write_registry

import compat  # noqa: E402  (support puts tools/ on sys.path)

API = "public func hello() {}\n"


class Compat(AtlasCase):
    def setUp(self):
        super().setUp()
        self.lib = make_repo(self.ws / "Lib", {"Sources/api.txt": API})
        self.app = make_repo(self.ws / "App", {"README": "app\n"})
        ref = lambda sha: [{"name": "main", "commit": sha, "role": "baseline"}]  # noqa: E731
        write_registry(self.root, [meta("lib", "ui", "Lib", refs=ref(self.lib)), meta("app", "app", "App", refs=ref(self.app)),
                                   meta("ghost", "app", "Ghost")])

    def write_candidates(self, checks, consumer="app", commit=None):
        doc = {"schema_version": 1, "candidates": [{
            "id": "c1", "package": {"repo": "lib", "commit": self.lib},
            "consumers": [{"repo": consumer, "ref": "main", "commit": commit or self.app, "checks": checks}]}]}
        (self.root / "compat").mkdir(exist_ok=True)
        (self.root / "compat" / "candidates.json").write_text(json.dumps(doc))

    def statuses(self):
        doc = json.loads((self.root / "compat" / "candidates.json").read_text())
        return {c["name"]: c["status"] for c in doc["candidates"][0]["consumers"][0]["checks"]}

    def result(self, name="c1"):
        return json.loads((self.root / "compat" / "results" / f"{name}.json").read_text())

    def sources_digest(self):
        return tree_digest(self.ws / "Lib", self.ws / "App")

    def test_clean_run_passes_inside_the_workspace_and_leaves_sources_untouched(self):
        self.write_candidates([
            {"name": "resolve", "recipe": "cd ../Lib && pwd -P && test -f Sources/api.txt", "resolves_package": True},
            {"name": "api", "recipe": "grep -q 'func hello' ../Lib/Sources/api.txt", "expect": []},
            {"name": "identity", "fingerprint": {"command": "cksum < ../Lib/Sources/api.txt", "touch": "Sources/api.txt"}},
            {"name": "na", "status": "not-applicable", "reason": "intentionally not built"},
            {"name": "label", "status": "not-run", "reason": "no recipe yet"},
        ])
        before = self.sources_digest()
        code, out = self.run_atlas("compat", "run", "c1")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.statuses(), {"resolve": "passed", "api": "passed", "identity": "passed", "na": "not-applicable", "label": "not-run"})
        rec = self.result()["consumers"][0]
        self.assertEqual(rec["checks"][0]["package_roots"], ["<workspace>"])
        self.assertTrue(rec["workspace_was_removed"])
        self.assertEqual((rec["commit"], rec["package"]["commit"]), (self.app, self.lib))
        self.assertEqual(self.sources_digest(), before, "compat run wrote to a source checkout")
        self.assertEqual(sh(self.ws / "Lib", "worktree", "list").count("\n"), 0)
        self.assertEqual(self.run_atlas("check")[0], 0, "recorded results must pass atlas check (no private paths)")

    def test_package_path_outside_the_workspace_fails(self):
        live = (self.ws / "Lib").resolve()
        self.write_candidates([
            {"name": "leak", "recipe": f"echo {live}/Sources/api.txt"},
            {"name": "silent", "recipe": "true", "resolves_package": True},
        ])
        code, out = self.run_atlas("compat", "run", "c1")
        self.assertEqual(code, 1, out)
        checks = self.result()["consumers"][0]["checks"]
        self.assertEqual([c["status"] for c in checks], ["failed", "failed"])
        self.assertIn("outside the disposable workspace", checks[0]["reason"])
        self.assertIn("resolution not proven", checks[1]["reason"])

    def test_unavailable_is_never_passed(self):
        checks = [{"name": "tool", "recipe": "true", "tools": ["atlas-no-such-tool"]},
                  {"name": "env", "recipe": "true", "env": ["ATLAS_NO_SUCH_DIR"]},
                  {"name": "fp", "fingerprint": {"command": "true", "touch": "Sources/missing.txt"}},
                  {"name": "ok", "recipe": "true"}]
        self.write_candidates(checks)
        code, _ = self.run_atlas("compat", "run", "c1")
        self.assertEqual(code, 3)
        self.assertEqual(self.statuses(), {"tool": "unavailable", "env": "unavailable", "fp": "unavailable", "ok": "passed"})
        for consumer, commit in (("app", "b" * 40), ("ghost", "c" * 40)):
            self.write_candidates([{"name": "ok", "recipe": "true"}], consumer=consumer, commit=commit)
            code, out = self.run_atlas("compat", "run", "c1")
            self.assertEqual(code, 3, out)
            self.assertEqual(self.statuses(), {"ok": "unavailable"})

    def test_workspace_removed_after_failure_and_interrupt(self):
        marker = self.ws / "workspace.txt"
        stray = 'touch "$(python3 -c "import tempfile; print(tempfile.gettempdir())")/lock_$(basename "$ATLAS_COMPAT_WORKSPACE").lock"'
        self.write_candidates([{"name": "boom", "recipe": f'echo "$ATLAS_COMPAT_WORKSPACE" > {marker}; {stray}; echo "$PWD/A.swift:1:2: error: boom"; exit 7'}])
        code, _ = self.run_atlas("compat", "run", "c1")
        self.assertEqual(code, 1)
        self.assertEqual(self.statuses(), {"boom": "failed"})
        failed = self.result()["consumers"][0]["checks"][0]
        self.assertIn("exit 7", failed["reason"])
        self.assertEqual(failed["first_errors"], ["<workspace>/App/A.swift:1:2: error: boom"])
        workspace = Path(marker.read_text().strip())
        self.assertFalse(workspace.exists())
        self.assertEqual(list(Path(tempfile.gettempdir()).glob(f"*{workspace.name}*")), [], "stray lock files left behind")

        seen = []

        def interrupt(check, ctx):
            seen.append(ctx["consumer_dir"].parent)
            raise KeyboardInterrupt

        with mock.patch.dict(compat.RUNNERS, {"recipe": interrupt}), self.assertRaises(KeyboardInterrupt):
            self.run_atlas("compat", "run", "c1")
        self.assertTrue(seen and not seen[0].exists())

    def test_injected_break_fails_only_inside_the_workspace(self):
        self.write_candidates([{"name": "api", "recipe": "grep -q 'func hello' ../Lib/Sources/api.txt"}])
        (self.ws / "Lib" / "Sources" / "api.txt").write_text(API.replace("hello", "hola"))
        patch = self.ws / "break.patch"
        patch.write_text(sh(self.ws / "Lib", "diff") + "\n")
        sh(self.ws / "Lib", "checkout", "--", "Sources/api.txt")
        candidates = (self.root / "compat" / "candidates.json").read_bytes()
        before = self.sources_digest()

        code, out = self.run_atlas("compat", "run", "c1", "--inject-break", str(patch))
        self.assertEqual(code, 1, out)
        broken = self.result("c1.inject-break")
        self.assertEqual(broken["consumers"][0]["checks"][0]["status"], "failed")
        self.assertEqual(broken["break_patch"]["files"], ["Sources/api.txt"])
        self.assertEqual((self.root / "compat" / "candidates.json").read_bytes(), candidates, "a break run never records statuses")
        self.assertEqual(self.sources_digest(), before)

        self.assertEqual(self.run_atlas("compat", "run", "c1")[0], 0)
        self.assertEqual(self.statuses(), {"api": "passed"})

    def test_native_outputs_must_be_built_by_the_run(self):
        native = {"name": "native", "native_outputs": ["out/*.so"]}
        self.write_candidates([{"name": "build", "recipe": "mkdir -p out && echo x > out/libcore.so"}, native])
        self.assertEqual(self.run_atlas("compat", "run", "c1")[0], 0)
        self.assertEqual(self.statuses(), {"build": "passed", "native": "passed"})
        self.write_candidates([native])
        self.run_atlas("compat", "run", "c1")
        self.assertEqual(self.statuses(), {"native": "not-run"})
        self.app = make_repo(self.ws / "App2", {"prebuilt/libcore.so": "stale\n"})
        write_registry(self.root, [meta("app", "app", "App2", refs=[{"name": "main", "commit": self.app, "role": "baseline"}])])
        self.write_candidates([{"name": "build", "recipe": "mkdir -p out && echo x > out/libcore.so"}, native])
        self.assertEqual(self.run_atlas("compat", "run", "c1")[0], 1)
        self.assertEqual(self.statuses()["native"], "failed")

    def test_plan_reports_what_would_run(self):
        self.write_candidates([{"name": "ok", "recipe": "true"}, {"name": "tool", "recipe": "true", "tools": ["atlas-no-such-tool"]},
                               {"name": "na", "status": "not-applicable", "reason": "why"}])
        code, out = self.run_atlas("compat", "plan")
        self.assertEqual(code, 0)
        self.assertIn("run          ok", out)
        self.assertIn("unavailable  tool  (missing tool atlas-no-such-tool)", out)
        self.assertIn("keep not-applicable na", out)
        self.assertIn("<workspace>/App, <workspace>/Lib", out)

    def test_consumer_pin_is_recorded_and_replaced_by_the_candidate(self):
        other = "d" * 40
        self.app = make_repo(self.ws / "App2", {"pins.txt": f"# pins\nLib {other}\n"})
        write_registry(self.root, [meta("app", "app", "App2", refs=[{"name": "main", "commit": self.app, "role": "baseline"}])])
        self.write_candidates([{"name": "tested", "recipe": 'test "$(git -C ../Lib rev-parse HEAD)" = "$ATLAS_COMPAT_PACKAGE_COMMIT"'}])
        doc = json.loads((self.root / "compat" / "candidates.json").read_text())
        doc["candidates"][0]["consumers"][0]["pin_file"] = "pins.txt"
        (self.root / "compat" / "candidates.json").write_text(json.dumps(doc))
        self.assertIn(f"consumer pins {other[:12]}, differs from the candidate under test", self.run_atlas("compat", "plan")[1])
        self.assertEqual(self.run_atlas("compat", "run", "c1")[0], 0)
        con = json.loads((self.root / "compat" / "candidates.json").read_text())["candidates"][0]["consumers"][0]
        self.assertEqual((con["pinned_package_commit"], con["checks"][0]["status"]), (other, "passed"))
        self.assertEqual(self.result()["consumers"][0]["consumer_pin"], other)

    def test_single_consumer_rerun_keeps_the_other_results(self):
        other = make_repo(self.ws / "Other", {"README": "other\n"})
        write_registry(self.root, [meta("other", "app", "Other", refs=[{"name": "main", "commit": other, "role": "baseline"}])])
        self.write_candidates([{"name": "ok", "recipe": "true"}])
        doc = json.loads((self.root / "compat" / "candidates.json").read_text())
        doc["candidates"][0]["consumers"].append({"repo": "other", "commit": other, "checks": [{"name": "ok", "recipe": "false"}]})
        (self.root / "compat" / "candidates.json").write_text(json.dumps(doc))
        self.assertEqual(self.run_atlas("compat", "run", "c1")[0], 1)
        first = self.result()["consumers"][0]
        self.run_atlas("compat", "run", "c1", "--consumer", "other")
        rec = self.result()["consumers"]
        self.assertEqual([r["repo"] for r in rec], ["app", "other"])
        self.assertEqual(rec[0], first)
        self.assertTrue(rec[1]["toolchain"] and rec[1]["finished_at"])

    def test_check_validates_reasons_and_results(self):
        self.write_candidates([{"name": "na", "status": "not-applicable"}])
        self.assertIn("not-applicable check needs a reason", self.run_atlas("check")[1])
        self.write_candidates([{"name": "ok", "recipe": "true"}])
        (self.root / "compat" / "results").mkdir()
        (self.root / "compat" / "results" / "c1.json").write_text(json.dumps(
            {"consumers": [{"repo": "app", "commit": "abc", "package": {}, "checks": [{"name": "ok", "status": "passed"}]}]}))
        self.assertIn("passed without exact package and consumer commits", self.run_atlas("check")[1])


if __name__ == "__main__":
    unittest.main()
