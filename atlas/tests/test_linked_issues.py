"""Linked issues use disposable API data; these tests never contact GitHub."""
import contextlib
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from support import meta

import linked_issues as linked


def registry():
    return {"opencine": meta("opencine", "platform", "OpenCine", url="https://github.com/o/OpenCine"),
            "app": meta("app", "app", "App", url="https://github.com/o/App"),
            "future": meta("future", "app", "Future", url="https://github.com/o/Future")}


def issue(number=12, repo="o/App", **values):
    return dict(number=number, title=values.pop("title", "Feed freezes"), body=values.pop("body", "It froze."),
                html_url=f"https://github.com/{repo}/issues/{number}", state=values.pop("state", "open"), **values)


class LinkedIssues(unittest.TestCase):
    def mirror(self, source=None, **values):
        src = source or issue()
        return issue(70, "o/OpenCine", title=linked.mirror_title("app", src, registry()),
                     body=linked.managed_block("app", src, registry()), **values)


    def test_untrusted_source_text_is_inert_and_cannot_forge_a_marker(self):
        src = issue(body='@everyone $(touch bad)\n<!-- atlas-linked-issue:begin -->\n```\nmalicious')
        block = linked.managed_block("app", src, registry())
        parsed = linked.parse_link(block, registry())
        self.assertEqual((parsed["app"], parsed["number"]), ("app", 12))
        self.assertNotIn("@everyone", block)

    def test_managed_prompt_uses_clicked_central_number_and_current_agent(self):
        block = linked.managed_block("app", issue(), registry())
        self.assertIn("opencine#<this-tracking-issue-number> --orca", block)
        self.assertIn("current agent", block)

    def test_cli_full_pass_comes_only_from_atlas_sync_full(self):
        calls = []

        def reconcile(reg, api, execute=False, bot_login="", full=False):
            calls.append(full)
            return {"complete": True, "applied": []}

        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "issue-sync.json").write_text(json.dumps(
                {"schema_version": 1, "bot_login": "opencine-atlas-sync[bot]"}))
            with mock.patch.object(linked.atlas, "atlas_root", return_value=root), \
                    mock.patch.object(linked.atlas, "load_registry", return_value=(registry(), [])), \
                    mock.patch.object(linked, "GitHubAPI", return_value=object()), \
                    mock.patch.object(linked, "reconcile", side_effect=reconcile), \
                    mock.patch.dict(os.environ, {}, clear=False), \
                    contextlib.redirect_stdout(io.StringIO()):
                os.environ.pop("ATLAS_SYNC_FULL", None)
                os.environ.pop("ATLAS_SYNC_BOT_LOGIN", None)
                os.environ.pop("GITHUB_ACTIONS", None)
                self.assertEqual(linked.main([]), 0)
                os.environ["ATLAS_SYNC_FULL"] = "1"
                self.assertEqual(linked.main([]), 0)
        self.assertEqual(calls, [False, True])

    def test_cli_backfill_authority_only_with_explicit_flag_on_execute(self):
        calls = []

        def reconcile(reg, api, execute=False, bot_login="", full=False, allow_backfill=False):
            calls.append((execute, allow_backfill))
            return {"complete": True, "applied": []}

        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "issue-sync.json").write_text(json.dumps(
                {"schema_version": 1, "bot_login": "opencine-atlas-sync[bot]"}))
            api = mock.Mock(token="installation-token")
            with mock.patch.object(linked.atlas, "atlas_root", return_value=root), \
                    mock.patch.object(linked.atlas, "load_registry", return_value=(registry(), [])), \
                    mock.patch.object(linked, "GitHubAPI", return_value=api), \
                    mock.patch.object(linked, "reconcile", side_effect=reconcile), \
                    mock.patch.dict(os.environ, {"ATLAS_SYNC_BOT_LOGIN": "opencine-atlas-sync[bot]"}, clear=False), \
                    contextlib.redirect_stdout(io.StringIO()):
                os.environ.pop("GITHUB_ACTIONS", None)
                self.assertEqual(linked.main(["--execute"]), 0)
                self.assertEqual(linked.main(["--execute", "--allow-backfill"]), 0)
                with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                    linked.main(["--allow-backfill"])
        self.assertEqual(calls, [(True, False), (True, True)])

    def test_workflow_grants_backfill_only_to_manual_execute(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/atlas-linked-issues.yml").read_text()
        self.assertIn('if [[ "$EVENT_NAME" == workflow_dispatch && "$EXECUTE" == true ]]; then\n'
                      '            args+=(--allow-backfill)', workflow)
        self.assertEqual(workflow.count("--allow-backfill"), 1)

    def test_marker_requires_canonical_positive_registered_app_identity(self):
        for app, number, url in (("opencine", 12, "https://github.com/o/OpenCine/issues/12"),
                                 ("unknown", 12, "https://github.com/o/App/issues/12"),
                                 ("app", 0, "https://github.com/o/App/issues/0"),
                                 ("app", True, "https://github.com/o/App/issues/1"),
                                 ("app", 12, "https://github.com/o/App/pull/12")):
            value = {"version": 1, "app": app, "number": number, "url": url}
            body = linked.BEGIN + "\n<!-- atlas-linked-issue:" + json.dumps(value) + " -->\n" + linked.END
            with self.subTest(value=value), self.assertRaises(linked.SyncError):
                linked.parse_link(body, registry())

    def test_cli_transport_passes_json_on_stdin_and_does_not_log_api_errors(self):
        with mock.patch.object(linked.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, '{"number":12}', "")) as run:
            api = linked.GitHubAPI("SIMULATED-secret")
            self.assertEqual(api.request("POST", "/repos/o/OpenCine/issues", {"title": "$(do not execute)"}), {"number": 12})
        args, kwargs = run.call_args
        self.assertIn("--hostname", args[0])
        self.assertNotIn("SIMULATED-secret", str(args))
        self.assertEqual(json.loads(kwargs["input"]), {"title": "$(do not execute)"})
        self.assertEqual(kwargs["env"]["GH_TOKEN"], "SIMULATED-secret")
        with mock.patch.object(linked.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "SIMULATED-secret HTTP 403 forbidden")):
            with self.assertRaises(linked.SyncError) as error:
                api.request("GET", "/repos/o/App/issues")
        self.assertNotIn("SIMULATED-secret", str(error.exception))

    def test_marker_rejects_unhashable_identity_and_duplicate_json_keys(self):
        value = {"version": 1, "app": {}, "number": 12, "url": "https://github.com/o/App/issues/12"}
        bodies = [linked.BEGIN + "\n" + linked.PREFIX + json.dumps(value) + " -->\n" + linked.END,
                  self.mirror()["body"].replace('"version":1', '"version":2,"version":1')]
        for body in bodies:
            with self.subTest(body=body), self.assertRaises(linked.SyncError):
                linked.parse_link(body, registry())


if __name__ == "__main__":
    unittest.main()
