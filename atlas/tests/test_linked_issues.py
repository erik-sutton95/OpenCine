"""Linked issues use disposable API data; these tests never contact GitHub."""
import json
import subprocess
import unittest
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
