"""Hosted all-field two-way sync against disposable paginated GitHub data."""
import copy
import json
import unittest
from urllib.parse import parse_qs, urlsplit

from support import meta
import linked_issues as linked
import issue_sync as sync

BOT = "opencine-atlas-sync[bot]"


def registry():
    return {"opencine": meta("opencine", "platform", "OpenCine", url="https://github.com/o/OpenCine"),
            "app": meta("app", "app", "App", url="https://github.com/o/App"),
            "future": meta("future", "app", "Future", url="https://github.com/o/Future")}


def issue(number=12, repo="o/App", **fields):
    return dict(number=number, title=fields.pop("title", "Feed freezes"), body=fields.pop("body", "**Original Markdown** @operator"),
                html_url=f"https://github.com/{repo}/issues/{number}", state=fields.pop("state", "open"),
                labels=fields.pop("labels", []), assignees=fields.pop("assignees", []),
                user={"login": fields.pop("author", "reporter"), "type": "User"}, **fields)


class API:
    def __init__(self):
        self.issues = {"o/App": [issue()], "o/Future": [], "o/OpenCine": []}
        self.comments, self.labels, self.calls, self.denied = {}, {}, [], set()
        self.fail = None
        self.next_id = 1000

    def request(self, method, path, payload=None):
        self.calls.append((method, path, copy.deepcopy(payload)))
        if self.fail and self.fail(method, path, payload):
            raise linked.SyncError("SIMULATED failure")
        parsed = urlsplit(path)
        parts = parsed.path.split("/")
        repo, tail = "/".join(parts[2:4]), parts[4:]
        query = parse_qs(parsed.query)
        def page(values):
            p = int(query.get("page", [1])[0]); return copy.deepcopy(values[(p - 1) * 100:p * 100])
        if tail[0] == "assignees":
            if (repo, tail[1]) in self.denied: raise linked.SyncError("ineligible", status=404)
            return None
        if tail[0] == "labels":
            if method == "GET": return page(self.labels.get(repo, []))
            self.labels.setdefault(repo, []).append(copy.deepcopy(payload)); return copy.deepcopy(payload)
        if len(tail) == 1:
            if method == "GET": return page(self.issues[repo])
            self.next_id += 1
            found = issue(self.next_id, repo, **payload)
            found["labels"] = [{"name": v} for v in payload.get("labels", [])]
            found["assignees"] = [{"login": v} for v in payload.get("assignees", [])]
            found["user"] = {"login": BOT, "type": "Bot"}
            self.issues[repo].append(found)
            return copy.deepcopy(found)
        if tail[1] == "comments":
            comment_id = int(tail[2]); found = next(c for items in self.comments.values() for c in items if c["id"] == comment_id)
            if method == "PATCH": found.update(payload)
            return copy.deepcopy(found)
        number = int(tail[1])
        if len(tail) == 3:
            key = repo, number
            if method == "GET": return page(self.comments.get(key, []))
            return self.comment(repo, number, payload["body"], BOT)
        found = next(i for i in self.issues[repo] if i["number"] == number)
        if method == "PATCH":
            for key, value in payload.items():
                found[key] = [{"login": v} for v in value] if key == "assignees" else [{"name": v} for v in value] if key == "labels" else value
        return copy.deepcopy(found)

    def comment(self, repo, number, body, author="operator"):
        self.next_id += 1
        value = {"id": self.next_id, "body": body, "html_url": f"https://github.com/{repo}/issues/{number}#issuecomment-{self.next_id}",
                 "user": {"login": author, "type": "Bot" if author == BOT else "User"}}
        self.comments.setdefault((repo, number), []).append(value)
        return copy.deepcopy(value)

    @property
    def source(self): return self.issues["o/App"][0]
    @property
    def tracker(self): return self.issues["o/OpenCine"][0]
    @property
    def writes(self): return [c for c in self.calls if c[0] != "GET"]


class TwoWay(unittest.TestCase):
    def setUp(self): self.api = API()

    def run_sync(self, execute=True, full=False):
        return sync.reconcile(registry(), self.api, execute=execute, bot_login=BOT, full=full)

    def created(self):
        result = self.run_sync()
        self.assertTrue(result["complete"], result)
        return self.api.tracker

    def test_dry_run_zero_writes_backfill_all_registry_and_ordinary_core_untouched(self):
        self.api.issues["o/Future"] = [issue(3, "o/Future")]
        self.api.issues["o/OpenCine"] = [issue(70, "o/OpenCine", body="Native Core issue")]
        result = self.run_sync(False)
        self.assertTrue(result["complete"], result)
        self.assertEqual(result["counts"]["create"], 2)
        self.assertEqual(self.api.writes, [])

    def test_title_body_close_reopen_both_directions_and_no_echo(self):
        tracker = self.created()
        self.api.source.update(title="Changed app", body="Markdown `code`\n@someone <!-- syntax -->", state="closed")
        self.assertTrue(self.run_sync()["complete"])
        self.assertIn("Changed app", tracker["title"])
        self.assertEqual(sync.report_body(tracker["body"]), self.api.source["body"])
        self.assertEqual(tracker["state"], "closed")
        tracker["title"] = "[app#12] Central edited"
        tracker["body"] = sync.replace_report(tracker["body"], "# Central description\n$(never executed)\n```\n@operator")
        tracker["state"] = "open"
        self.assertTrue(self.run_sync()["complete"])
        self.assertEqual(self.api.source["title"], "Central edited")
        self.assertEqual(self.api.source["body"], "# Central description\n$(never executed)\n```\n@operator")
        self.assertEqual(self.api.source["state"], "open")
        before = len(self.api.writes)
        self.assertTrue(self.run_sync()["complete"])
        self.assertEqual(len(self.api.writes), before)

    def test_unchanged_pair_skips_both_comment_inventories_until_an_endpoint_changes(self):
        self.api.comment("o/App", 12, "Indexed")
        tracker = self.created()
        # GitHub's issue inventory carries both cheap change signals for every pair.
        self.api.source.update(updated_at="2026-01-01T00:00:00Z", comments=1)
        tracker.update(updated_at="2026-01-01T00:00:01Z", comments=2)
        self.assertTrue(self.run_sync()["complete"])
        state = sync._one_json(tracker["body"], sync.ROOT_PREFIX)
        self.assertEqual(set(state["poll"]),
                         {"source_updated_at", "source_comments", "tracker_comments"},
                         "a wall-clock field here would rewrite every tracker body")
        start = len(self.api.calls)
        self.assertTrue(self.run_sync()["complete"])
        quiet = self.api.calls[start:]
        self.assertFalse([call for call in quiet if "comments?" in call[1]],
                         "an unchanged pair must not read either comment thread")
        self.assertEqual([call for call in quiet if call[0] != "GET"], [])
        # A comment edit bumps its issue's updated_at, so the pair is polled and copied.
        self.api.source["updated_at"] = "2026-01-02T00:00:00Z"
        self.api.comments["o/App", 12][0]["body"] = "Edited after the checkpoint"
        self.assertTrue(self.run_sync()["complete"])
        copies = [c for c in self.api.comments["o/OpenCine", tracker["number"]]
                  if sync.COMMENT_PREFIX in c["body"]]
        self.assertEqual(len(copies), 1)
        self.assertEqual(sync.comment_body(copies[0]["body"]), "Edited after the checkpoint")
        # A new source comment changes the cheap comment count, without needing updated_at.
        self.api.comment("o/App", 12, "Added after the checkpoint")
        self.api.source["comments"] = 2
        start = len(self.api.calls)
        self.assertTrue(self.run_sync()["complete"])
        reads = [call for call in self.api.calls[start:]
                 if "comments?" in call[1] and "/o/App/issues/12/" in call[1]]
        self.assertTrue(reads, "a new source comment must trigger a thread read")
        copies = [c for c in self.api.comments["o/OpenCine", tracker["number"]]
                  if sync.COMMENT_PREFIX in c["body"]]
        self.assertEqual(len(copies), 2)
        self.assertIn("Added after the checkpoint", [sync.comment_body(c["body"]) for c in copies])

    def test_comment_arriving_after_the_inventory_blocks_a_poll_checkpoint(self):
        self.api.comment("o/App", 12, "First")
        tracker = self.created()
        self.api.source.update(updated_at="2026-01-01T00:00:00Z", comments=1)
        tracker.update(updated_at="2026-01-01T00:00:01Z", comments=2)
        self.assertTrue(self.run_sync()["complete"])
        request, injected = self.api.request, [False]

        def comment_arrives(method, path, payload=None):
            if not injected[0] and method == "GET" and path == "/repos/o/App/issues/12":
                injected[0] = True
                self.api.comment("o/App", 12, "Arrived after the inventory")
                self.api.source["comments"] = 2
                self.api.source["updated_at"] = "2026-01-02T00:00:00Z"
            return request(method, path, payload)

        self.api.request = comment_arrives
        try:
            self.assertTrue(self.run_sync(full=True)["complete"])
        finally:
            self.api.request = request
        state = sync._one_json(tracker["body"], sync.ROOT_PREFIX)
        self.assertNotIn("poll", state,
                         "a comment the inventory did not see must be read again")
        start = len(self.api.calls)
        self.assertTrue(self.run_sync()["complete"])
        self.assertTrue([call for call in self.api.calls[start:]
                         if "comments?" in call[1] and "/o/App/issues/12/" in call[1]])
        copies = [c for c in self.api.comments["o/OpenCine", tracker["number"]]
                  if sync.COMMENT_PREFIX in c["body"]]
        self.assertIn("Arrived after the inventory",
                      [sync.comment_body(c["body"]) for c in copies])

    def test_forced_full_pass_reads_every_pair_and_writes_nothing_when_unchanged(self):
        self.api.comment("o/App", 12, "Indexed")
        tracker = self.created()
        self.api.source.update(updated_at="2026-01-01T00:00:00Z", comments=1)
        tracker.update(updated_at="2026-01-01T00:00:01Z", comments=2)
        self.assertTrue(self.run_sync()["complete"])
        before = len(self.api.writes)
        start = len(self.api.calls)
        self.assertTrue(self.run_sync(full=True)["complete"])
        reads = [call for call in self.api.calls[start:] if "comments?" in call[1]]
        self.assertEqual(len(reads), 2, "a forced full pass reads both endpoint threads")
        self.assertEqual(len(self.api.writes), before, "a full pass with no upstream change writes nothing")

    def test_released_checked_poll_checkpoint_is_accepted_and_skipped(self):
        self.api.comment("o/App", 12, "Indexed")
        tracker = self.created()
        self.api.source.update(updated_at="2026-01-01T00:00:00Z", comments=1)
        tracker.update(updated_at="2026-01-01T00:00:01Z", comments=2)
        self.assertTrue(self.run_sync()["complete"])
        state = sync._one_json(tracker["body"], sync.ROOT_PREFIX)
        state["poll"]["checked"] = 123
        tracker["body"] = sync._render(
            "app", 12, sync._values(tracker, True, "app", registry()), state, registry(), tracker["body"])
        start = len(self.api.calls)
        self.assertTrue(self.run_sync()["complete"])
        quiet = self.api.calls[start:]
        self.assertFalse([call for call in quiet if "comments?" in call[1]])
        self.assertEqual([call for call in quiet if call[0] != "GET"], [])

    def test_conflicting_content_is_preserved_while_independent_state_syncs(self):
        tracker = self.created()
        self.api.source.update(title="App edit", body="App body", state="closed")
        tracker["title"] = "[app#12] Central edit"
        tracker["body"] = "Notes before\n" + sync.replace_report(tracker["body"], "Central body") + "\nNotes after"
        result = self.run_sync()
        self.assertFalse(result["complete"], result)
        self.assertEqual({c["field"] for c in result["conflicts"]}, {"title", "body"})
        self.assertEqual(self.api.source["body"], "App body")
        self.assertEqual(sync.report_body(tracker["body"]), "Central body")
        self.assertEqual(tracker["state"], "closed")
        self.assertTrue(tracker["body"].startswith("Notes before\n"))
        self.assertTrue(tracker["body"].endswith("\nNotes after"))
        before = len(self.api.writes)
        self.run_sync()
        self.assertEqual(len(self.api.writes), before, "unresolved conflicts do not spam writes")

    def test_three_way_label_assignee_add_remove_and_missing_label_creation(self):
        self.api.source["labels"] = [{"name": "bug"}]
        self.api.labels = {"o/App": [{"name": "bug", "color": "ff0000", "description": "App bug"}], "o/OpenCine": []}
        self.api.source["assignees"] = [{"login": "alice"}]
        tracker = self.created()
        self.assertEqual(tracker["labels"], [{"name": "bug"}])
        self.api.labels["o/OpenCine"].append({"name": "review", "color": "123456", "description": None})
        self.api.source["labels"] = []
        tracker["labels"].append({"name": "review"})
        self.api.source["assignees"] = []
        tracker["assignees"].append({"login": "bob"})
        self.assertTrue(self.run_sync()["complete"])
        self.assertEqual(self.api.source["labels"], [{"name": "review"}])
        self.assertEqual(tracker["labels"], [{"name": "review"}])
        self.assertEqual(self.api.source["assignees"], [{"login": "bob"}])
        self.assertFalse(any(m == "DELETE" for m, _, _ in self.api.writes))

    def test_ineligible_assignee_is_explicit_and_other_fields_progress(self):
        tracker = self.created()
        tracker["assignees"] = [{"login": "outside"}]
        tracker["state"] = "closed"
        self.api.denied.add(("o/App", "outside"))
        result = self.run_sync()
        self.assertFalse(result["complete"])
        self.assertIn("assignees", [c["field"] for c in result["conflicts"]])
        self.assertEqual(self.api.source["assignees"], [])
        self.assertEqual(tracker["assignees"], [{"login": "outside"}])
        self.assertEqual(self.api.source["state"], "closed")

    def test_comment_create_edit_both_directions_provenance_and_echo_free(self):
        original = self.api.comment("o/App", 12, "Original @operator ```\n<!-- marker -->")
        tracker = self.created()
        replicas = self.api.comments["o/OpenCine", tracker["number"]]
        copies = [c for c in replicas if sync.COMMENT_PREFIX in c["body"]]
        self.assertEqual(len(copies), 1)
        self.assertIn(original["html_url"], copies[0]["body"])
        self.assertIn("operator", copies[0]["body"])
        self.api.comments["o/App", 12][0]["body"] = "App comment edited"
        self.assertTrue(self.run_sync()["complete"])
        self.assertEqual(sync.comment_body(copies[0]["body"]), "App comment edited")
        copies[0]["body"] = sync.replace_comment_body(copies[0]["body"], "Edited through central copy")
        self.assertTrue(self.run_sync()["complete"])
        self.assertEqual(self.api.comments["o/App", 12][0]["body"], "Edited through central copy")
        central = self.api.comment("o/OpenCine", tracker["number"], "Central new comment", "maintainer")
        self.assertTrue(self.run_sync()["complete"])
        self.assertTrue(any(central["html_url"] in c["body"] for c in self.api.comments["o/App", 12]))
        count = len(self.api.writes)
        self.assertTrue(self.run_sync()["complete"])
        self.assertEqual(len(self.api.writes), count)

    def test_comment_conflict_preserves_both_and_deleted_peer_is_not_recreated(self):
        self.api.comment("o/App", 12, "Initial")
        tracker = self.created()
        comments = self.api.comments["o/OpenCine", tracker["number"]]
        peer = next(c for c in comments if sync.COMMENT_PREFIX in c["body"])
        self.api.comments["o/App", 12][0]["body"] = "App competing"
        peer["body"] = sync.replace_comment_body(peer["body"], "Central competing")
        result = self.run_sync()
        self.assertFalse(result["complete"])
        self.assertEqual(sync.comment_body(peer["body"]), "Central competing")
        self.assertEqual(self.api.comments["o/App", 12][0]["body"], "App competing")
        comments.remove(peer)
        result = self.run_sync()
        self.assertTrue(result["complete"], result)
        self.assertFalse(any(sync.COMMENT_PREFIX in c["body"] for c in comments))
        self.assertIn("peer_deleted", json.dumps(comments))
        self.assertTrue(self.run_sync()["complete"])
        self.assertFalse(any(sync.COMMENT_PREFIX in c["body"] for c in comments))

    def test_deleted_original_tombstones_copy_and_preserves_last_text(self):
        self.api.comment("o/App", 12, "Retain this text")
        tracker = self.created()
        self.api.comments["o/App", 12].clear()
        result = self.run_sync()
        self.assertTrue(result["complete"], result)
        copied = next(c for c in self.api.comments["o/OpenCine", tracker["number"]] if sync.COMMENT_PREFIX in c["body"])
        self.assertIn("deleted", copied["body"])
        self.assertIn("Retain this text", copied["body"])
        self.assertEqual(self.api.comments["o/App", 12], [])

    def test_public_forged_marker_cannot_authorize_reverse_writes(self):
        tracker = self.created()
        forged = copy.deepcopy(tracker)
        forged.update(number=70, html_url="https://github.com/o/OpenCine/issues/70",
                      user={"login": "attacker", "type": "User"}, title="[app#12] Forged reverse title")
        self.api.issues["o/OpenCine"].append(forged)
        self.api.source["title"] = "Legitimate source update"
        result = self.run_sync()
        self.assertTrue(result["complete"], result)
        self.assertEqual(self.api.source["title"], "Legitimate source update")
        self.assertEqual(tracker["title"], "[app#12] Legitimate source update")
        self.assertEqual(forged["title"], "[app#12] Forged reverse title")
        self.assertFalse(any(method != "GET" and path.endswith("/issues/70") for method, path, _ in self.api.calls))

    def test_paginated_threads_and_state_shards_with_missing_shard_are_honest(self):
        for n in range(102): self.api.comment("o/App", 12, f"Comment {n}")
        tracker = self.created()
        self.assertTrue(any("comments?" in p and p.endswith("page=2") for _, p, _ in self.api.calls))
        thread = self.api.comments["o/OpenCine", tracker["number"]]
        states = [c for c in thread if sync.STATE_PREFIX in c["body"]]
        self.assertGreater(len(states), 1)
        thread.remove(states[0])
        count = len(self.api.writes)
        self.assertFalse(self.run_sync()["complete"])
        self.assertEqual(len(self.api.writes), count)

    def test_partial_write_never_advances_baseline_and_recovers(self):
        tracker = self.created()
        tracker["title"] = "[app#12] Reverse title"
        self.api.fail = lambda m, p, data: m == "PATCH" and "/o/App/issues/12" in p
        result = self.run_sync()
        self.assertFalse(result["complete"])
        self.assertEqual(self.api.source["title"], "Feed freezes")
        self.api.fail = None
        self.assertTrue(self.run_sync()["complete"])
        self.assertEqual(self.api.source["title"], "Reverse title")

    def test_large_report_is_complete_data_or_explicit_incomplete_never_truncated(self):
        self.api.source["body"] = "A" * 13000 + "\n**final sentinel**"
        tracker = self.created()
        self.assertEqual(sync.report_body(tracker["body"]), self.api.source["body"])
        self.api.source["body"] = "A" * 66000
        result = self.run_sync()
        self.assertFalse(result["complete"])
        self.assertEqual(len(self.api.source["body"]), 66000)

    def test_source_marker_text_and_entities_roundtrip_without_authority(self):
        self.api.source["body"] = '<!-- atlas-linked-issue:bad -->\n```\n&copy; @operator <pre>quote</pre>\n' + chr(0x2014)
        tracker = self.created()
        self.assertEqual(sync.report_body(tracker["body"]), self.api.source["body"])
        self.assertEqual(linked.parse_link(tracker["body"], registry())["app"], "app")

    def test_missing_index_blocks_pair_before_field_mutation(self):
        self.api.comment("o/App", 12, "Indexed")
        tracker = self.created()
        self.api.comments["o/OpenCine", tracker["number"]] = [c for c in self.api.comments["o/OpenCine", tracker["number"]] if sync.STATE_PREFIX not in c["body"]]
        tracker["title"] = "[app#12] Reverse mutation must wait"
        count = len(self.api.writes)
        result = self.run_sync()
        self.assertFalse(result["complete"])
        self.assertEqual(len(self.api.writes), count)
        self.assertEqual(self.api.source["title"], "Feed freezes")

    def test_complete_issue_inventories_duplicate_owned_markers_and_partial_reads(self):
        self.api.issues["o/App"] = [issue(n) for n in range(1, 102)]
        self.api.issues["o/OpenCine"] = [issue(n, "o/OpenCine") for n in range(1, 102)]
        result = self.run_sync(False)
        self.assertTrue(result["complete"], result)
        self.assertEqual(result["counts"]["create"], 101)
        self.assertTrue(any("o/OpenCine/issues?" in p and p.endswith("page=2") for _, p, _ in self.api.calls))
        self.api = API(); tracker = self.created()
        duplicate = copy.deepcopy(tracker); duplicate.update(number=99, html_url="https://github.com/o/OpenCine/issues/99")
        self.api.issues["o/OpenCine"].append(duplicate)
        count = len(self.api.writes)
        self.assertFalse(self.run_sync()["complete"])
        self.assertEqual(len(self.api.writes), count)
        self.api = API()
        for n in range(101): self.api.comment("o/App", 12, str(n))
        self.api.fail = lambda m, p, data: m == "GET" and "comments?" in p and p.endswith("page=2")
        self.assertFalse(self.run_sync()["complete"])
        self.assertEqual(self.api.writes, [])

    def test_successful_empty_central_inventory_never_duplicates_trackers(self):
        # 2026-10-22: during a GitHub degradation the central listing read successfully but
        # without the existing trackers, and the engine created a second tracker per issue.
        self.created()
        count, trackers = len(self.api.writes), len(self.api.issues["o/OpenCine"])
        request, served = self.api.request, []
        def degraded(method, path, payload=None):
            if method == "GET" and path.startswith("/repos/o/OpenCine/issues?") and not served:
                served.append(path)
                return []
            return request(method, path, payload)
        self.api.request = degraded
        result = self.run_sync()
        self.assertFalse(result["complete"], result)
        self.assertEqual(len(self.api.writes), count, "an unconfirmed absence must never create a tracker")
        self.assertEqual(len(self.api.issues["o/OpenCine"]), trackers)
        self.assertIn("central inventory changed between reads", json.dumps(result["errors"]))

    def test_automatic_run_refuses_mass_tracker_creation(self):
        self.api.issues["o/App"] = [issue(n) for n in range(1, 7)]
        planned = self.run_sync(False)
        self.assertTrue(planned["complete"], planned)
        self.assertEqual(planned["counts"]["create"], 6)
        result = self.run_sync()
        self.assertFalse(result["complete"], result)
        self.assertEqual(self.api.writes, [])
        self.assertIn("6 new trackers planned", json.dumps(result["errors"]))
        result = sync.reconcile(registry(), self.api, execute=True, bot_login=BOT, allow_backfill=True)
        self.assertTrue(result["complete"], result)
        self.assertEqual(result["counts"]["create"], 6)

    def test_receipt_records_inventory_sizes(self):
        self.api.issues["o/Future"] = [issue(3, "o/Future"), issue(4, "o/Future", state="closed")]
        self.api.issues["o/OpenCine"] = [issue(70, "o/OpenCine", body="Native Core issue")]
        result = self.run_sync()
        self.assertTrue(result["complete"], result)
        self.assertEqual(result["inventory"], {"central_issues": 1, "authenticated_trackers": 0,
                                               "sources": {"app": 1, "future": 2}})
        self.assertEqual(self.run_sync()["inventory"]["authenticated_trackers"], 2)

    def test_uncertain_comment_post_recovers_from_carrier_without_duplicate(self):
        for origin_repo in ("o/App", "o/OpenCine"):
            with self.subTest(origin=origin_repo):
                self.api = API()
                tracker = self.created()
                number = 12 if origin_repo == "o/App" else tracker["number"]
                original = self.api.comment(origin_repo, number, "Uncertain copy")
                request, lost = self.api.request, [False]
                def lost_response(method, path, payload=None):
                    value = request(method, path, payload)
                    if method == "POST" and payload and payload.get("body", "").startswith(sync.COMMENT_PREFIX) and not lost[0]:
                        lost[0] = True
                        raise linked.SyncError("SIMULATED lost response after server accepted copy")
                    return value
                self.api.request = lost_response
                result = self.run_sync()
                self.assertFalse(result["complete"])
                self.assertIsNotNone(result["uncertain"])
                self.api.request = request
                result = self.run_sync()
                self.assertTrue(result["complete"], result)
                copies = [c for comments in self.api.comments.values() for c in comments
                          if c["body"].startswith(sync.COMMENT_PREFIX) and original["html_url"] in c["body"]]
                self.assertEqual(len(copies), 1)
                count = len(self.api.writes)
                self.assertTrue(self.run_sync()["complete"])
                self.assertEqual(len(self.api.writes), count)

    def test_deleted_uncertain_new_copy_is_never_recreated_in_either_direction(self):
        for origin_repo in ("o/App", "o/OpenCine"):
            for delete_index in (False, True):
                with self.subTest(origin=origin_repo, delete_index=delete_index):
                    self.api = API()
                    self.api.comment("o/App", 12, "Existing indexed pair")
                    tracker = self.created()
                    number = 12 if origin_repo == "o/App" else tracker["number"]
                    text = "Retain uncertain new content and human deletion intent"
                    original = self.api.comment(origin_repo, number, text)
                    request, accepted, checkpoints = self.api.request, [], []
                    def lose_copy_response(method, path, payload=None):
                        value = request(method, path, payload)
                        if method == "POST" and payload and payload.get("body", "").startswith(sync.COMMENT_PREFIX):
                            accepted.append((path.split("/issues/")[0].removeprefix("/repos/"), value))
                            state = sync._one_json(tracker["body"], sync.ROOT_PREFIX)
                            indexes = [c for c in self.api.comments["o/OpenCine", tracker["number"]] if c["id"] in state["shards"]]
                            checkpoints.extend(e for c in indexes for e in sync._one_json(c["body"], sync.STATE_PREFIX)["entries"]
                                               if e["origin"]["url"] == original["html_url"])
                            raise linked.SyncError("SIMULATED lost accepted carrier response")
                        return value
                    self.api.request = lose_copy_response
                    result = self.run_sync()
                    self.assertFalse(result["complete"], result)
                    self.assertEqual(len(accepted), 1)
                    target, peer = accepted[0]
                    target_number = tracker["number"] if target == "o/OpenCine" else 12
                    self.api.comments[target, target_number] = [c for c in self.api.comments[target, target_number] if c["id"] != peer["id"]]
                    if delete_index:
                        self.api.comments["o/OpenCine", tracker["number"]] = [
                            c for c in self.api.comments["o/OpenCine", tracker["number"]] if not c["body"].startswith(sync.STATE_PREFIX)]
                    self.api.request = request
                    count = len(self.api.writes)
                    result = self.run_sync()
                    self.assertFalse(result["complete"], result)
                    self.assertFalse(any(a["action"] == "comment-create" for a in result["actions"]), result)
                    self.assertEqual(len(checkpoints), 1, "attempt must be durable and referenced before carrier POST")
                    self.assertEqual(checkpoints[0]["last_body"], text)
                    self.assertEqual(checkpoints[0].get("pending"), "attempted")
                    self.assertIn(original["id"], [c["id"] for c in self.api.comments[origin_repo, number]])
                    if delete_index:
                        self.assertEqual(len(self.api.writes), count)
                    else:
                        self.assertTrue(result["conflicts"], result)
                        self.assertIn(text, json.dumps(list(self.api.comments.values())))
                        self.api.source["title"] = "Independent field still progresses"
                        self.api.issues["o/Future"] = [issue(3, "o/Future")]
                        result = self.run_sync()
                        self.assertFalse(result["complete"], result)
                        self.assertIn("Independent field still progresses", tracker["title"])
                        self.assertTrue(any(i["title"].startswith("[future#3]") for i in self.api.issues["o/OpenCine"]))

    def test_unconfirmed_copy_attempt_without_acceptance_is_explicit_and_not_retried(self):
        for origin_repo in ("o/App", "o/OpenCine"):
            with self.subTest(origin=origin_repo):
                self.api = API()
                tracker = self.created()
                number = 12 if origin_repo == "o/App" else tracker["number"]
                self.api.comment(origin_repo, number, "Unconfirmed content retained")
                request = self.api.request
                def reject_copy(method, path, payload=None):
                    if method == "POST" and payload and payload.get("body", "").startswith(sync.COMMENT_PREFIX):
                        raise linked.SyncError("SIMULATED no accepted carrier, outcome unknown")
                    return request(method, path, payload)
                self.api.request = reject_copy
                self.assertFalse(self.run_sync()["complete"])
                self.api.request = request
                count = len(self.api.writes)
                result = self.run_sync()
                self.assertFalse(result["complete"], result)
                self.assertTrue(result["conflicts"], result)
                self.assertEqual(len(self.api.writes), count, "ambiguous absence never authorizes another POST")

    def test_prepared_index_resumes_if_attempt_checkpoint_was_not_accepted(self):
        self.api.comment("o/App", 12, "Prepared content")
        request, triggered = self.api.request, [False]
        def reject_attempt_checkpoint(method, path, payload=None):
            if method == "PATCH" and payload and '"pending":"attempted"' in payload.get("body", ""):
                triggered[0] = True
                raise linked.SyncError("SIMULATED before attempted checkpoint acceptance")
            return request(method, path, payload)
        self.api.request = reject_attempt_checkpoint
        self.assertFalse(self.run_sync()["complete"])
        self.assertTrue(triggered[0])
        self.api.request = request
        self.assertTrue(self.run_sync()["complete"])
        copies = [c for c in self.api.comments["o/OpenCine", self.api.tracker["number"]] if c["body"].startswith(sync.COMMENT_PREFIX)]
        self.assertEqual(len(copies), 1)

    def test_lost_attempt_checkpoint_response_fails_closed_without_carrier(self):
        self.api.comment("o/App", 12, "Retained before uncertain attempt checkpoint")
        request, triggered = self.api.request, [False]
        def lose_attempt_checkpoint(method, path, payload=None):
            value = request(method, path, payload)
            if method == "PATCH" and payload and '"pending":"attempted"' in payload.get("body", "") and not triggered[0]:
                triggered[0] = True
                raise linked.SyncError("SIMULATED lost accepted attempt checkpoint response")
            return value
        self.api.request = lose_attempt_checkpoint
        self.assertFalse(self.run_sync()["complete"])
        self.assertTrue(triggered[0])
        self.api.request = request
        count = len(self.api.writes)
        result = self.run_sync()
        self.assertFalse(result["complete"], result)
        self.assertTrue(result["conflicts"], result)
        self.assertEqual(len(self.api.writes), count)

    def test_invalid_prepared_record_refuses_before_any_pair_write(self):
        for origin_repo in ("o/App", "o/OpenCine"):
            for defect in ("same_endpoint", "origin_number", "peer_type", "base", "body_type", "pending", "deleted_pending"):
                with self.subTest(origin=origin_repo, defect=defect):
                    self.api = API()
                    tracker = self.created()
                    number = 12 if origin_repo == "o/App" else tracker["number"]
                    original = self.api.comment(origin_repo, number, "Prepared record must be validated")
                    request = self.api.request
                    def stop_before_attempt(method, path, payload=None):
                        if method == "PATCH" and payload and '"pending":"attempted"' in payload.get("body", ""):
                            raise linked.SyncError("SIMULATED prepared-only checkpoint")
                        return request(method, path, payload)
                    self.api.request = stop_before_attempt
                    self.assertFalse(self.run_sync()["complete"])
                    self.api.request = request
                    index = next(c for c in self.api.comments["o/OpenCine", tracker["number"]] if c["body"].startswith(sync.STATE_PREFIX))
                    data = sync._one_json(index["body"], sync.STATE_PREFIX)
                    entry = next(e for e in data["entries"] if e["origin"]["url"] == original["html_url"])
                    self.assertEqual(entry["pending"], "prepared")
                    if defect == "same_endpoint": entry["peer_repo"] = origin_repo
                    elif defect == "origin_number":
                        entry["origin"]["number"] += 1
                        entry["origin"]["url"] = f"https://github.com/{origin_repo}/issues/{number + 1}#issuecomment-{original['id']}"
                    elif defect == "peer_type": entry["peer_id"] = True
                    elif defect == "base": entry["base"] = "invalid fingerprint"
                    elif defect == "body_type": entry["last_body"] = 1
                    elif defect == "pending": entry["pending"] = "unsupported"
                    else: entry["deleted"] = "peer_deleted"
                    index["body"] = sync.STATE_PREFIX + sync._json(data) + " -->"
                    damaged = index["body"]
                    self.api.source["title"] = "Independent title must wait for valid pair state"
                    tracker["state"] = "closed"
                    count = len(self.api.writes)
                    result = self.run_sync()
                    self.assertFalse(result["complete"], result)
                    self.assertTrue(result["errors"], result)
                    self.assertEqual(len(self.api.writes), count, "invalid durable binding refuses before fields, indexes or carriers")
                    self.assertEqual(index["body"], damaged)
                    self.assertEqual(self.api.source["state"], "open")
                    self.assertNotIn("Independent title", tracker["title"])

    def test_silently_ignored_assignment_does_not_remove_original(self):
        self.api.source["assignees"] = [{"login": "alice"}]
        request = self.api.request
        def ignore_assignment(method, path, payload=None):
            if method in {"POST", "PATCH"} and "/o/OpenCine/issues" in path and payload:
                payload = dict(payload); payload.pop("assignees", None)
            return request(method, path, payload)
        self.api.request = ignore_assignment
        self.assertFalse(self.run_sync()["complete"])
        self.assertEqual(self.api.source["assignees"], [{"login": "alice"}])
        self.assertFalse(self.run_sync()["complete"])
        self.assertEqual(self.api.source["assignees"], [{"login": "alice"}])
        self.api.request = request
        self.assertTrue(self.run_sync()["complete"])
        self.assertEqual(self.api.tracker["assignees"], [{"login": "alice"}])

    def test_operator_preformatted_notes_and_native_marker_quotes_remain_data(self):
        self.api.issues["o/OpenCine"] = [issue(70, "o/OpenCine", body="Quoted <!-- atlas-linked-issue:bad -->")]
        result = self.run_sync()
        self.assertTrue(result["complete"], result)
        tracker = self.api.issues["o/OpenCine"][1]
        tracker["body"] = "<pre>Operator notes</pre>\n" + tracker["body"]
        self.api.source["body"] = "New report"
        self.assertTrue(self.run_sync()["complete"])
        self.assertTrue(tracker["body"].startswith("<pre>Operator notes</pre>\n"))

    def test_quoted_index_marker_roundtrips_and_cannot_poison_durable_state(self):
        text = 'Parser report quoting <!-- atlas-sync-index: and <!-- atlas-sync-comment: with "quotes" & entities'
        self.api.comment("o/App", 12, text)
        tracker = self.created()
        thread = self.api.comments["o/OpenCine", tracker["number"]]
        index = next(c for c in thread if c["body"].startswith(sync.STATE_PREFIX))
        self.assertEqual(index["body"].count(sync.STATE_PREFIX), 1)
        self.assertEqual(sync._one_json(index["body"], sync.STATE_PREFIX)["entries"][0]["last_body"], text)
        count = len(self.api.writes)
        self.assertTrue(self.run_sync()["complete"])
        self.assertEqual(len(self.api.writes), count)

        central_text = "Core report quoting <!-- atlas-sync-index: and <!-- atlas-sync-metadata:"
        self.api.comment("o/OpenCine", tracker["number"], central_text)
        self.assertTrue(self.run_sync()["complete"])
        indexes = [c for c in thread if c["body"].startswith(sync.STATE_PREFIX)]
        self.assertTrue(all(c["body"].count(sync.STATE_PREFIX) == 1 for c in indexes))
        self.assertTrue(any(e["last_body"] == central_text for c in indexes for e in sync._one_json(c["body"], sync.STATE_PREFIX)["entries"]))
        count = len(self.api.writes)
        self.assertTrue(self.run_sync()["complete"])
        self.assertEqual(len(self.api.writes), count)

    def test_failed_shard_rollover_retains_deleted_both_text_and_recovers(self):
        reg = registry()
        app_repo = "o/OpenPocketCine"
        reg["app"]["repository"]["url"] = "https://github.com/" + app_repo
        del self.api.issues["o/App"]
        self.api.issues[app_repo] = [issue(12, app_repo)]
        def run(): return sync.reconcile(reg, self.api, execute=True, bot_login=BOT)
        self.assertTrue(run()["complete"])
        number = self.api.tracker["number"]
        for n in range(49): self.api.comment("o/OpenCine", number, f"Core original {n}")
        sentinel = "Unique last content after both endpoints are deleted"
        original = self.api.comment(app_repo, 12, sentinel)
        self.assertTrue(run()["complete"])
        thread = self.api.comments["o/OpenCine", number]
        peer = next(c for c in thread if c["body"].startswith(sync.COMMENT_PREFIX) and original["html_url"] in c["body"])
        self.api.comments[app_repo, 12] = [c for c in self.api.comments[app_repo, 12] if c["id"] != original["id"]]
        thread.remove(peer)
        self.assertTrue(run()["complete"])
        self.assertIn(sentinel, json.dumps(list(self.api.comments.values())))
        self.api.comment("o/OpenCine", number, "New Core comment must not move the sole tombstone")
        self.api.fail = lambda method, path, payload: (method == "POST" and path.endswith("/comments") and payload
            and payload["body"].startswith(sync.STATE_PREFIX) and '"shard":1' in payload["body"])
        result = run()
        self.assertFalse(result["complete"])
        self.assertIsNotNone(result["uncertain"])
        self.assertIn(sentinel, json.dumps(list(self.api.comments.values())))
        self.api.fail = None
        self.assertTrue(run()["complete"])
        self.assertIn(sentinel, json.dumps(list(self.api.comments.values())))
        count = len(self.api.writes)
        self.assertTrue(run()["complete"])
        self.assertEqual(len(self.api.writes), count)

    def test_label_definition_comes_only_from_paired_field_source(self):
        self.api.issues["o/Future"] = [issue(3, "o/Future", labels=[{"name": "triage"}])]
        self.api.labels = {"o/OpenCine": [],
                           "o/App": [{"name": "triage", "color": "ff0000", "description": "Unrelated app definition"}],
                           "o/Future": [{"name": "triage", "color": "0000ff", "description": "Actual source definition"}]}
        result = self.run_sync()
        self.assertTrue(result["complete"], result)
        definition = next(v for v in self.api.labels["o/OpenCine"] if v["name"] == "triage")
        self.assertEqual(definition, self.api.labels["o/Future"][0])

    def test_every_index_failure_boundary_preserves_deleted_both_content(self):
        for mode in ("before_patch", "after_patch", "after_new_post"):
            with self.subTest(mode=mode):
                self.api = API()
                reg, app_repo = registry(), "o/OpenPocketCine"
                reg["app"]["repository"]["url"] = "https://github.com/" + app_repo
                del self.api.issues["o/App"]
                self.api.issues[app_repo] = [issue(12, app_repo)]
                def run(): return sync.reconcile(reg, self.api, execute=True, bot_login=BOT)
                self.assertTrue(run()["complete"])
                tracker = self.api.tracker
                number = tracker["number"]
                originals = [self.api.comment("o/OpenCine", number, f"Core {n}") for n in range(49)]
                sentinel = "Only surviving deleted-both content"
                original = self.api.comment(app_repo, 12, sentinel)
                self.assertTrue(run()["complete"])
                thread = self.api.comments["o/OpenCine", number]
                copied = next(c for c in thread if c["body"].startswith(sync.COMMENT_PREFIX) and original["html_url"] in c["body"])
                thread.remove(copied)
                self.api.comments[app_repo, 12] = [c for c in self.api.comments[app_repo, 12] if c["id"] != original["id"]]
                self.assertTrue(run()["complete"])
                index = next(c for c in thread if c["body"].startswith(sync.STATE_PREFIX))
                first = next(c for c in thread if c["id"] == originals[0]["id"])
                first["body"] = "Confirmed new content forces existing shard patch"
                self.api.comment("o/OpenCine", number, "Appended entry forces a new shard")
                request, triggered = self.api.request, [False]
                def fail_once(method, path, payload=None):
                    old_patch = method == "PATCH" and path.endswith(f"/comments/{index['id']}")
                    new_post = method == "POST" and path.endswith("/comments") and payload and payload["body"].startswith(sync.STATE_PREFIX) and '"shard":1' in payload["body"]
                    hit = not triggered[0] and (old_patch if mode != "after_new_post" else new_post)
                    if hit and mode == "before_patch":
                        triggered[0] = True
                        raise linked.SyncError("SIMULATED before index patch")
                    value = request(method, path, payload)
                    if hit:
                        triggered[0] = True
                        raise linked.SyncError("SIMULATED lost index write response")
                    return value
                self.api.request = fail_once
                result = run()
                self.assertTrue(triggered[0])
                self.assertFalse(result["complete"], result)
                self.assertIn(sentinel, json.dumps(list(self.api.comments.values())))
                self.api.request = request
                self.assertTrue(run()["complete"])
                self.assertIn(sentinel, json.dumps(list(self.api.comments.values())))

    def test_growing_index_record_preflights_all_shards_before_any_index_write(self):
        tracker = self.created()
        number = tracker["number"]
        originals = [self.api.comment("o/OpenCine", number, f"Core {n}") for n in range(51)]
        self.assertTrue(self.run_sync()["complete"])
        thread = self.api.comments["o/OpenCine", number]
        before = {c["id"]: c["body"] for c in thread if c["body"].startswith(sync.STATE_PREFIX)}
        next(c for c in thread if c["id"] == originals[0]["id"])["body"] = "First shard would change"
        next(c for c in thread if c["id"] == originals[-1]["id"])["body"] = chr(0x1F4A1) * 6000
        result = self.run_sync()
        self.assertFalse(result["complete"], result)
        self.assertTrue(any("index shard too large" in e["error"] for e in result["errors"]))
        after = {c["id"]: c["body"] for c in thread if c["id"] in before}
        self.assertEqual(after, before, "size failure must preserve every existing durable shard")


if __name__ == "__main__":
    unittest.main()
