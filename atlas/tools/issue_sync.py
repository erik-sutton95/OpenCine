"""GitHub-hosted, all-field, two-way issue reconciliation with durable common bases.

State and comment indexes live on authenticated bot-owned GitHub objects. A runner's
filesystem is never the durable state. No DELETE, access grants or global-label edits.
"""
from __future__ import annotations

from collections import Counter
import copy
import hashlib
import html
import json
import re
from urllib.parse import quote

import linked_issues as linked

ROOT_PREFIX = "<!-- atlas-sync-metadata:"
STATE_PREFIX = "<!-- atlas-sync-index:"
COMMENT_PREFIX = "<!-- atlas-sync-comment:"
REPORT = re.compile(r"<pre>([\s\S]*?)</pre>")
FIELDS = ("title", "body", "state", "labels", "assignees")
LIMIT = 65000
SHARD_ENTRIES = 50
# A routine run sees a few new app issues at most. More planned creates means either a
# deliberate backfill or a central inventory that read successfully but incompletely
# (2026-10-22: one tracker per open app issue was duplicated during a GitHub degradation).
MAX_AUTOMATIC_CREATES = 5


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def _json(value):
    # JSON string values may contain literal marker introducers. Escaping angle
    # brackets keeps those values inert while json.loads restores exact text.
    return json.dumps(value, sort_keys=True, separators=(",", ":")).replace("<", "\\u003c").replace(">", "\\u003e")


def _encoded(value):
    return html.escape(value).replace("@", "&#64;").replace(chr(0x2014), "&#8212;")


def _one_json(body, prefix):
    matches = re.findall(re.escape(prefix) + r"(\{[^\n]*\}) -->", body)
    if body.count(prefix) != 1 or len(matches) != 1:
        raise linked.SyncError("missing or ambiguous authenticated sync metadata")
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value: raise linked.SyncError("duplicate sync metadata JSON key")
            value[key] = item
        return value
    return json.loads(matches[0], object_pairs_hook=unique)


def _report_match(body):
    start, end = 0, len(body)
    if linked.BEGIN in body:
        start, end = body.index(linked.BEGIN), body.index(linked.END)
    matches = list(REPORT.finditer(body, start, end))
    if len(matches) != 1:
        raise linked.SyncError("tracking report must contain exactly one editable encoded report")
    return matches[0]


def report_body(body):
    return html.unescape(_report_match(body)[1])


def replace_report(body, text):
    match = _report_match(body)
    result = body[:match.start()] + "<pre>" + _encoded(text) + "</pre>" + body[match.end():]
    if len(result) > LIMIT: raise linked.SyncError("report exceeds GitHub body size; no truncation permitted")
    return result


def comment_body(body):
    return report_body(body)


def replace_comment_body(body, text):
    return replace_report(body, text)


def _bot(value, login):
    user = value.get("user") or {}
    return user.get("login") == login and user.get("type") == "Bot"


def _values(issue, central=False, app=None, reg=None):
    title = issue["title"]
    if central:
        prefix = f"[{reg[app]['display_name']}#{linked.parse_link(issue['body'], reg)['number']}] "
        if title.startswith(prefix): title = title[len(prefix):]
    return {"title": title, "body": report_body(issue["body"]) if central else issue.get("body") or "",
            "state": issue["state"], "labels": sorted({v["name"].casefold() for v in issue.get("labels", [])}),
            "assignees": sorted({v["login"].lower() for v in issue.get("assignees", [])})}


def _base(values):
    return {key: list(value) if key in {"labels", "assignees"} else digest(value) for key, value in values.items()}


def _validate_base(state):
    if not isinstance(state, dict) or not {"version", "base", "shards"} <= set(state) \
            or not set(state) <= {"version", "base", "shards", "poll"} or state["version"] != 1 \
            or not isinstance(state["base"], dict) or set(state["base"]) != set(FIELDS) or not isinstance(state["shards"], list):
        raise linked.SyncError("unsupported durable issue state schema")
    for field in FIELDS:
        value = state["base"][field]
        if field in {"labels", "assignees"}:
            if not isinstance(value, list) or any(not isinstance(v, str) for v in value) or value != sorted(set(value)):
                raise linked.SyncError("invalid common set baseline")
        elif not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
            raise linked.SyncError("invalid common field fingerprint")
    if any(type(v) is not int or v < 1 for v in state["shards"]) or len(set(state["shards"])) != len(state["shards"]):
        raise linked.SyncError("invalid comment index references")
    # The released schema carried a "checked" timestamp; accept it for one release but
    # ignore it, because a wall-clock field would rewrite every reconciled tracker body.
    poll = state.get("poll")
    required = {"source_updated_at", "source_comments", "tracker_comments"}
    if poll is not None and (not isinstance(poll, dict)
            or not required <= set(poll) or not set(poll) <= required | {"checked"}
            or not isinstance(poll["source_updated_at"], str) or not poll["source_updated_at"]
            or type(poll["source_comments"]) is not int or poll["source_comments"] < 0
            or type(poll["tracker_comments"]) is not int or poll["tracker_comments"] < 0):
        raise linked.SyncError("invalid poll checkpoint")
    return state


def _render(app, number, values, state, reg, old=None):
    source = dict(values, number=number)
    block = linked.managed_block(app, dict(source, body=""), reg)
    block = replace_report(block, values["body"])
    block = block.replace(linked.BEGIN + "\n", linked.BEGIN + "\n" + ROOT_PREFIX + _json(state) + " -->\n", 1)
    if old:
        block = old[:old.index(linked.BEGIN)] + block + old[old.index(linked.END) + len(linked.END):]
    if len(block) > LIMIT: raise linked.SyncError("tracking body/state exceeds GitHub size; source retained without truncation")
    return block


def _title(app, number, title, reg):
    result = f"[{reg[app]['display_name']}#{number}] {title}"
    if len(result) > 256: raise linked.SyncError("tracking title exceeds GitHub size; no truncation permitted")
    return result


def _pages(api, path):
    values, page = [], 1
    while True:
        chunk = api.request("GET", f"{path}?per_page=100&page={page}")
        if not isinstance(chunk, list): raise linked.SyncError("incomplete paginated metadata/comment inventory")
        values.extend(chunk)
        if len(chunk) < 100: return values
        page += 1


def _comments(api, repo, number):
    values = _pages(api, f"/repos/{repo}/issues/{number}/comments")
    seen = set()
    for value in values:
        cid = value.get("id")
        if type(cid) is not int or cid < 1 or cid in seen or not isinstance(value.get("body"), str) \
                or value.get("html_url") != f"https://github.com/{repo}/issues/{number}#issuecomment-{cid}":
            raise linked.SyncError("invalid or duplicate canonical comment inventory")
        seen.add(cid)
    return values


def _conflict(result, pair, field, reason):
    result["conflicts"].append({"source": pair, "field": field, "reason": reason})


def _poll_baseline(source, tracker):
    """The stored poll signals as read by the pre-write issue inventory."""
    return source.get("updated_at"), source.get("comments"), (tracker or {}).get("comments")


def _poll_checkpoint(source, tracker):
    """Endpoint signals cheap enough to decide that a pair needs no read this run."""
    updated_at, comments = source.get("updated_at"), source.get("comments")
    tracker_comments = tracker.get("comments")
    if not isinstance(updated_at, str) or not updated_at or type(comments) is not int or comments < 0 \
            or type(tracker_comments) is not int or tracker_comments < 0:
        return None
    return {"source_updated_at": updated_at, "source_comments": comments,
            "tracker_comments": tracker_comments}


def _poll_unchanged(state, source, tracker):
    poll = state.get("poll")
    if not poll:
        return False
    return poll["source_updated_at"] == source.get("updated_at") \
        and poll["source_comments"] == source.get("comments") \
        and poll["tracker_comments"] == tracker.get("comments")


def _fields_match_base(values, base):
    return all(values[field] == base[field] if field in {"labels", "assignees"}
               else digest(values[field]) == base[field] for field in FIELDS)


class Runner:
    def __init__(self, reg, api, execute, login, result):
        self.reg, self.api, self.execute, self.login, self.result = reg, api, execute, login, result
        _, self.central, self.apps = linked.identities(reg)
        self.labels, self.threads, self.eligible_cache = {}, {}, {}

    def write(self, action, pair, method, path, payload):
        self.result["actions"].append({"action": action, "source": pair, "method": method, "path": path, "payload": payload})
        if not self.execute: return None
        self.result["uncertain"] = {"source": pair, "method": method, "path": path}
        value = self.api.request(method, path, payload)
        self.result["applied"].append({"action": action, "source": pair, "method": method, "path": path})
        self.result["uncertain"] = None
        return value

    def eligible(self, repo, logins):
        if len(logins) > 10: return False
        for login in logins:
            key = repo, login
            if key not in self.eligible_cache:
                try: self.api.request("GET", f"/repos/{repo}/assignees/{quote(login, safe='')}")
                except linked.SyncError as exc:
                    if getattr(exc, "status", None) != 404: raise
                    self.eligible_cache[key] = False
                else:
                    self.eligible_cache[key] = True
            if not self.eligible_cache[key]: return False
        return True

    def label_plan(self, repo, names, pair, definition_repo):
        for name in names:
            if name in self.labels[repo]: continue
            definition = self.labels[definition_repo].get(name)
            if not definition: raise linked.SyncError(f"{pair}: paired source label definition unavailable for {name}")
            payload = {key: definition.get(key) for key in ("name", "color", "description")}
            payload["color"] = payload["color"] or "ededed"
            self.write("label-create", pair, "POST", f"/repos/{repo}/labels", payload)
            self.labels[repo][name] = definition

    def issue_patch(self, repo, snapshot, payload, pair, central=False, app=None):
        if not payload: return snapshot
        if self.execute:
            current = self.api.request("GET", f"/repos/{repo}/issues/{snapshot['number']}")
            if any(current.get(key) != snapshot.get(key) for key in ("title", "body", "state", "labels", "assignees")):
                raise linked.SyncError(f"{pair}: issue changed after planning; preserve both and replan")
        value = self.write("update", pair, "PATCH", f"/repos/{repo}/issues/{snapshot['number']}", payload)
        if self.execute:
            # GitHub may silently ignore ineligible assignments: verify actual fields.
            value = self.api.request("GET", f"/repos/{repo}/issues/{snapshot['number']}")
            for field, want in payload.items():
                have = value.get(field)
                if field == "labels": have = sorted(v["name"].casefold() for v in have); want = sorted(want)
                if field == "assignees": have = sorted(v["login"].lower() for v in have); want = sorted(want)
                if have != want: raise linked.SyncError(f"{pair}: write did not confirm {field}; baseline retained")
            return value
        return dict(snapshot, **payload)

    def _index(self, tracker, state, pair, endpoints):
        thread = self.threads[self.central, tracker["number"]]
        owned, entries = {}, {}
        for comment in thread:
            if _bot(comment, self.login) and STATE_PREFIX in comment["body"]:
                value = _one_json(comment["body"], STATE_PREFIX)
                if value.get("version") != 1 or value.get("source") != pair or type(value.get("shard")) is not int \
                        or value["shard"] < 0 or not isinstance(value.get("entries"), list):
                    raise linked.SyncError("invalid authenticated comment index schema")
                if value["shard"] in owned: raise linked.SyncError("duplicate authenticated comment index shard")
                owned[value["shard"]] = (comment, value)
        for i, cid in enumerate(state["shards"]):
            if i not in owned or owned[i][0]["id"] != cid:
                raise linked.SyncError("durable comment index shard missing or replaced; refusing resurrection")
        if owned and sorted(owned) != list(range(len(owned))):
            raise linked.SyncError("comment index shards are incomplete")
        for _, value in owned.values():
            for entry in value["entries"]:
                key = self._validate_entry(entry, endpoints)
                if key in entries: raise linked.SyncError("duplicate durable comment pair")
                entries[key] = entry
        return owned, entries

    @staticmethod
    def _entry_key(entry):
        if not isinstance(entry, dict) or not isinstance(entry.get("origin"), dict):
            raise linked.SyncError("invalid comment pair record")
        origin = entry["origin"]
        if set(origin) != {"repo", "number", "id", "author", "url"} or type(origin["id"]) is not int or origin["id"] < 1 \
                or type(origin["number"]) is not int or origin["number"] < 1 or not isinstance(origin["author"], str) \
                or not re.fullmatch(r"[A-Za-z0-9_-]+(?:\[bot\])?", origin["author"]):
            raise linked.SyncError("invalid comment origin identity")
        if origin["url"] != f"https://github.com/{origin['repo']}/issues/{origin['number']}#issuecomment-{origin['id']}":
            raise linked.SyncError("invalid canonical comment origin URL")
        return origin["repo"], origin["number"], origin["id"]

    def _validate_entry(self, entry, endpoints):
        key = self._entry_key(entry)
        pending, peer_id, deleted = entry.get("pending"), entry.get("peer_id"), entry.get("deleted")
        base = entry.get("base")
        if key[0] not in endpoints or key[1] != endpoints[key[0]] or entry.get("peer_repo") not in endpoints \
                or entry["peer_repo"] == key[0] or pending not in (None, "prepared", "attempted") \
                or deleted not in (None, "origin_deleted", "peer_deleted") or (pending and deleted is not None) \
                or (peer_id is None and not pending and deleted != "origin_deleted") \
                or (peer_id is not None and (type(peer_id) is not int or peer_id < 1 or pending)) \
                or not isinstance(entry.get("last_body"), str) or not isinstance(base, str) \
                or not re.fullmatch(r"[0-9a-f]{64}", base):
            raise linked.SyncError("comment index crosses this authenticated issue pair or has invalid record state")
        return key

    def _carrier(self, entry, body, deleted=None):
        marker = {"version": 1, "origin": entry["origin"], "base": entry["base"]}
        if deleted: marker["deleted"] = deleted
        text = (f"{COMMENT_PREFIX}{_json(marker)} -->\n"
                f"Originally by `{entry['origin']['author']}`: {entry['origin']['url']}\n\n"
                + ("Logical deletion: " + deleted + "; last content retained.\n\n" if deleted else "")
                + "<pre>" + _encoded(body) + "</pre>")
        if len(text) > LIMIT: raise linked.SyncError("comment/provenance exceeds GitHub size; no truncation permitted")
        return text

    def _comment_patch(self, repo, comment, body, pair):
        if body == comment["body"]: return
        if self.execute:
            current = self.api.request("GET", f"/repos/{repo}/issues/comments/{comment['id']}")
            if current["body"] != comment["body"]: raise linked.SyncError("comment changed after planning; preserve competing edits")
        value = self.write("comment-update", pair, "PATCH", f"/repos/{repo}/issues/comments/{comment['id']}", {"body": body})
        if self.execute:
            value = self.api.request("GET", f"/repos/{repo}/issues/comments/{comment['id']}")
            if not value or value.get("body") != body:
                raise linked.SyncError("comment write not confirmed; baseline retained")
        comment["body"] = body

    def _save_index(self, tracker, owned, entries, pair):
        # Existing membership is durable: interrupted appends never move the
        # sole last-content/tombstone record out of its committed shard.
        chunks, assigned = [], set()
        for i in range(len(owned)):
            chunk = []
            for old in owned[i][1]["entries"]:
                key = self._entry_key(old)
                chunk.append(entries[key])
                assigned.add(key)
            chunks.append(chunk)
        for _, entry in sorted(entries.items()):
            if self._entry_key(entry) in assigned: continue
            if not chunks: chunks.append([])
            trial = [*chunks[-1], entry]
            if len(trial) > SHARD_ENTRIES or len(_json(trial)) > LIMIT - 400:
                chunks.append([entry])
            else:
                chunks[-1] = trial
        values = [{"version": 1, "source": pair, "shard": i, "entries": chunk} for i, chunk in enumerate(chunks)]
        bodies = [STATE_PREFIX + _json(value) + " -->" for value in values]
        # Preflight all bodies before modifying any index, including a growing
        # existing record. Oversize leaves prior content intact, never relocated.
        if any(len(body) > LIMIT for body in bodies):
            raise linked.SyncError("comment index shard too large; no content discarded")
        ids = []
        for i, body in enumerate(bodies):
            if i in owned:
                comment = owned[i][0]
                self._comment_patch(self.central, comment, body, pair)
            else:
                comment = self.write("index-create", pair, "POST", f"/repos/{self.central}/issues/{tracker['number']}/comments", {"body": body})
                if not _bot(comment, self.login) or comment.get("body") != body: raise linked.SyncError("index authority not confirmed")
                comment = self.api.request("GET", f"/repos/{self.central}/issues/comments/{comment['id']}")
                if not _bot(comment, self.login) or comment.get("body") != body:
                    raise linked.SyncError("index readback not confirmed; prior manifest retained")
            owned[i] = comment, values[i]
            ids.append(comment["id"])
        return ids

    def _reference_index(self, app, number, tracker, state, ids, pair):
        if ids == state["shards"]: return tracker
        checkpoint = dict(state, shards=ids)
        body = _render(app, number, _values(tracker, True, app, self.reg), checkpoint, self.reg, tracker["body"])
        tracker = self.issue_patch(self.central, tracker, {"body": body}, pair, True, app)
        state["shards"] = ids
        return tracker

    def comment_sync(self, app, number, tracker, state, pair):
        source_repo = self.apps[app]
        endpoints = {source_repo: number, self.central: tracker["number"]}
        owned, entries = self._index(tracker, state, pair, endpoints)
        originals, carriers = {}, {}
        for repo, n in endpoints.items():
            for comment in self.threads.get((repo, n), []):
                if _bot(comment, self.login) and STATE_PREFIX in comment["body"]:
                    continue
                if _bot(comment, self.login) and COMMENT_PREFIX in comment["body"]:
                    value = _one_json(comment["body"], COMMENT_PREFIX)
                    key = self._entry_key(value)
                    if value.get("version") != 1 or key[0] not in endpoints or key[1] != endpoints[key[0]] or key[0] == repo \
                            or not re.fullmatch(r"[0-9a-f]{64}", value.get("base", "")):
                        raise linked.SyncError("foreign or invalid authenticated comment carrier")
                    if key in carriers: raise linked.SyncError("duplicate copied comments for one origin")
                    carriers[key] = (repo, comment, value)
                else:
                    originals[repo, n, comment["id"]] = comment
        # Recover a confirmed copy whose index checkpoint was interrupted.
        for key, (repo, peer, value) in carriers.items():
            if key not in entries:
                entries[key] = {"origin": value["origin"], "peer_repo": repo, "peer_id": peer["id"],
                                "base": value["base"], "last_body": comment_body(peer["body"]), "deleted": value.get("deleted")}
            elif entries[key].get("pending"):
                entry = entries[key]
                if entry["origin"] != value["origin"] or entry["peer_repo"] != repo or entry["base"] != value["base"]:
                    raise linked.SyncError("pending copy does not match authenticated carrier")
                entry["peer_id"] = peer["id"]
                entry.pop("pending")
        for key, original in originals.items():
            if key in entries: continue
            repo, n, cid = key
            target = next(r for r in endpoints if r != repo)
            origin = {"repo": repo, "number": n, "id": cid, "author": original["user"]["login"], "url": original["html_url"]}
            entry = {"origin": origin, "peer_repo": target, "peer_id": None,
                     "base": digest(original["body"]), "last_body": original["body"], "deleted": None, "pending": "prepared"}
            self._carrier(entry, original["body"])
            entries[key] = entry
        prepared = [(key, entry) for key, entry in entries.items() if entry.get("pending") == "prepared"]
        if prepared and self.execute:
            # First record full origins/text without claiming any carrier attempt.
            # Reference every shard before POST, so deleting attempt evidence is
            # detected even if the carrier response or later checkpoint is lost.
            ids = self._save_index(tracker, owned, entries, pair)
            tracker = self._reference_index(app, number, tracker, state, ids, pair)
        for key, entry in prepared:
            original = originals.get(key)
            if not original:
                entry.pop("pending")
                entry["deleted"] = "origin_deleted"
                self.result["tombstones"].append({"source": pair, "origin": entry["origin"]["url"], "reason": entry["deleted"]})
                continue
            entry["base"], entry["last_body"] = digest(original["body"]), original["body"]
            body = self._carrier(entry, original["body"])
            if self.execute:
                # An absent carrier after this confirmed intent is ambiguous:
                # it may have been accepted and human-deleted. Never retry it.
                entry["pending"] = "attempted"
                self._save_index(tracker, owned, entries, pair)
            target = entry["peer_repo"]
            peer = self.write("comment-create", pair, "POST", f"/repos/{target}/issues/{endpoints[target]}/comments", {"body": body})
            if not self.execute: continue
            if not _bot(peer, self.login) or peer.get("body") != body: raise linked.SyncError("copied comment authority not confirmed")
            entry["peer_id"] = peer["id"]
            entry.pop("pending")
            carriers[key] = target, peer, {"origin": entry["origin"], "base": entry["base"], "version": 1}
        for key, entry in entries.items():
            if self._validate_entry(entry, endpoints) != key:
                raise linked.SyncError("comment origin changed during reconciliation")
            pending = entry.get("pending")
            if pending:
                if self.execute or pending == "attempted":
                    _conflict(self.result, pair, "comment:" + str(key[2]), "unconfirmed copy attempt; retained text and no carrier recreation")
                continue
            original = originals.get(key)
            carrier = carriers.get(key)
            if carrier and carrier[1]["id"] != entry["peer_id"]:
                raise linked.SyncError("comment index peer identity mismatch")
            if entry.get("deleted"):
                continue
            if not original or not carrier:
                entry["deleted"] = "origin_deleted" if not original else "peer_deleted"
                self.result["tombstones"].append({"source": pair, "origin": entry["origin"]["url"], "reason": entry["deleted"]})
                if carrier:
                    self._comment_patch(carrier[0], carrier[1], self._carrier(entry, comment_body(carrier[1]["body"]), entry["deleted"]), pair)
                continue
            source_body, peer_body = original["body"], comment_body(carrier[1]["body"])
            if source_body == peer_body:
                entry["base"], entry["last_body"] = digest(source_body), source_body
            elif digest(source_body) == entry["base"]:
                self._comment_patch(key[0], original, peer_body, pair)
                entry["base"], entry["last_body"] = digest(peer_body), peer_body
            elif digest(peer_body) == entry["base"]:
                self._comment_patch(carrier[0], carrier[1], self._carrier(entry, source_body), pair)
                entry["base"], entry["last_body"] = digest(source_body), source_body
            else:
                _conflict(self.result, pair, "comment:" + str(key[2]), "competing comment edits preserved")
        if not self.execute: return state["shards"]
        return self._save_index(tracker, owned, entries, pair)

    def pair(self, app, source, tracker):
        pair = f"{app}#{source['number']}"
        conflicts_before = len(self.result["conflicts"])
        poll_baseline = _poll_baseline(source, tracker)
        source_repo = self.apps[app]
        src = _values(source)
        if tracker is None:
            target = copy.deepcopy(src)
            if not self.eligible(self.central, target["assignees"]):
                _conflict(self.result, pair, "assignees", "target cannot assign intended users; no access granted")
                target["assignees"] = []
            self.label_plan(self.central, target["labels"], pair, source_repo)
            initial_base = _base(src)
            # GitHub can silently ignore assignments without sufficient permission.
            # Empty common sets cannot turn an unconfirmed create into removals on
            # the original; the verified checkpoint advances them after equality.
            initial_base["assignees"], initial_base["labels"] = [], []
            state = {"version": 1, "base": initial_base, "shards": []}
            payload = dict(target, title=_title(app, source["number"], target["title"], self.reg),
                           body=_render(app, source["number"], target, state, self.reg))
            tracker = self.write("create", pair, "POST", f"/repos/{self.central}/issues", payload)
            poll_baseline = _poll_baseline(source, tracker)
            if not self.execute:
                for comment in self.threads[source_repo, source["number"]]:
                    self.result["actions"].append({"source": pair, "action": "comment-create", "origin": comment["html_url"]})
                return
            if not _bot(tracker, self.login) or linked.parse_link(tracker.get("body"), self.reg) != linked.source_identity(app, source["number"], self.reg):
                raise linked.SyncError("created tracker authority/identity not confirmed; fresh inventory required")
            self.threads[self.central, tracker["number"]] = []
        state = _validate_base(_one_json(tracker["body"], ROOT_PREFIX))
        # Validate every persisted record before field, label, index or carrier
        # writes. A prepared record is never permission to repair its binding.
        self._index(tracker, state, pair, {source_repo: source["number"], self.central: tracker["number"]})
        current = _values(tracker, True, app, self.reg)
        desired_src, desired_core, next_base = copy.deepcopy(src), copy.deepcopy(current), copy.deepcopy(state["base"])
        for field in FIELDS:
            a, b, base = src[field], current[field], state["base"][field]
            if field in {"labels", "assignees"}:
                a_set, b_set, old = set(a), set(b), set(base)
                resolved = sorted((old - ((old - a_set) | (old - b_set))) | (a_set - old) | (b_set - old))
                if field == "assignees" and (not self.eligible(source_repo, resolved) or not self.eligible(self.central, resolved)):
                    _conflict(self.result, pair, field, "target cannot assign intended users; assignments preserved")
                    continue
                desired_src[field] = desired_core[field] = resolved
                next_base[field] = resolved
            elif a == b:
                next_base[field] = digest(a)
            elif digest(a) == base:
                desired_src[field] = b; next_base[field] = digest(b)
            elif digest(b) == base:
                desired_core[field] = a; next_base[field] = digest(a)
            else:
                _conflict(self.result, pair, field, "competing edits preserved on both sides")
        for repo, values in ((source_repo, desired_src), (self.central, desired_core)):
            self.label_plan(repo, values["labels"], pair, self.central if repo == source_repo else source_repo)
        app_payload = {f: v for f, v in desired_src.items() if v != src[f]}
        core_payload = {f: v for f, v in desired_core.items() if v != current[f] and f != "body"}
        if "title" in core_payload: core_payload["title"] = _title(app, source["number"], desired_core["title"], self.reg)
        # Preflight all size bounds before writing either issue.
        rendered = _render(app, source["number"], desired_core, state, self.reg, tracker["body"])
        if rendered != tracker["body"]: core_payload["body"] = rendered
        if len(desired_src["body"]) > LIMIT: raise linked.SyncError("source report exceeds GitHub size; no truncation")
        source = self.issue_patch(source_repo, source, app_payload, pair)
        tracker = self.issue_patch(self.central, tracker, core_payload, pair, True, app)
        shard_ids = self.comment_sync(app, source["number"], tracker, state, pair)
        if self.execute:
            a = self.api.request("GET", f"/repos/{source_repo}/issues/{source['number']}")
            b = self.api.request("GET", f"/repos/{self.central}/issues/{tracker['number']}")
            a_values, b_values = _values(a), _values(b, True, app, self.reg)
            for field in FIELDS:
                if next_base[field] != state["base"][field] and (a_values[field] != desired_src[field] or b_values[field] != desired_core[field]):
                    raise linked.SyncError("field changed before checkpoint; common baseline retained")
            checkpoint = {"version": 1, "base": next_base, "shards": shard_ids}
            # An unresolved conflict must be reported again on the next run, so only a
            # clean pair earns the poll checkpoint that lets reconcile skip its threads.
            # A comment may arrive after the thread inventories but before these readbacks.
            # Storing its count would let the next incremental run skip an unreconciled
            # comment, so only checkpoint signals that match the pre-write inventory.
            if len(self.result["conflicts"]) == conflicts_before \
                    and _poll_baseline(a, b) == poll_baseline:
                poll = _poll_checkpoint(a, b)
                if poll: checkpoint["poll"] = poll
            body = _render(app, source["number"], b_values, checkpoint, self.reg, b["body"])
            self.issue_patch(self.central, b, {"body": body} if body != b["body"] else {}, pair, True, app)


def _mirrors(central, reg, bot_login):
    mirrors = {}
    for tracker in central:
        # Unowned Core text has no routing, pair-selection or write authority,
        # even when it quotes a structurally valid authenticated marker.
        if not _bot(tracker, bot_login): continue
        identity = linked.parse_link(tracker.get("body"), reg)
        if not identity: continue
        key = identity["app"], identity["number"]
        if key in mirrors: raise linked.SyncError("duplicate authenticated central trackers")
        mirrors[key] = tracker
    return mirrors


def reconcile(reg, api, execute=False, bot_login="opencine-atlas-sync[bot]", full=False, allow_backfill=False):
    result = {"version": 2, "mode": "execute" if execute else "dry-run", "complete": False,
              "actions": [], "applied": [], "errors": [], "conflicts": [], "tombstones": [], "counts": {}, "uncertain": None}
    try:
        if not re.fullmatch(r"[A-Za-z0-9_-]+\[bot\]", bot_login): raise linked.SyncError("a configured sync App bot identity is required")
        runner = Runner(reg, api, execute, bot_login, result)
        central = linked.inventory(api, runner.central)
        mirrors = _mirrors(central, reg, bot_login)
        result["inventory"] = {"central_issues": len(central), "authenticated_trackers": len(mirrors), "sources": {}}
        sources = {}
        for app, repo in sorted(runner.apps.items()):
            items = linked.inventory(api, repo)
            result["inventory"]["sources"][app] = len(items)
            for item in items: sources[app, item["number"]] = item
        if set(mirrors) - set(sources): raise linked.SyncError("a tracked original is missing; deletion/transfer/visibility needs review")
        pairs = [(app, item, mirrors.get((app, number))) for (app, number), item in sorted(sources.items())
                 if (app, number) in mirrors or item["state"] == "open"]
        # A successful read is not proof of absence: GitHub can serve a well-formed but
        # incomplete listing. Bound automatic creation; a backfill is a reviewed manual run.
        creates = sum(tracker is None for _, _, tracker in pairs)
        if execute and not allow_backfill and creates > MAX_AUTOMATIC_CREATES:
            raise linked.SyncError(f"{creates} new trackers planned; automatic runs create at most "
                                   f"{MAX_AUTOMATIC_CREATES}; review a dry run and dispatch a manual backfill")
        # A pair whose fields still match the durable baseline and whose endpoint signals
        # still match the poll checkpoint cannot have changed: skip both comment inventories.
        # A forced full pass (the daily workflow schedule) reads every pair anyway.
        # Any invalid durable state is left to pair(), which refuses it explicitly.
        def unchanged(app, source, tracker):
            if tracker is None: return False
            try:
                state = _validate_base(_one_json(tracker["body"], ROOT_PREFIX))
                return _fields_match_base(_values(source), state["base"]) \
                    and _fields_match_base(_values(tracker, True, app, reg), state["base"]) \
                    and _poll_unchanged(state, source, tracker)
            except (linked.SyncError, ValueError, KeyError, TypeError):
                return False
        if not full:
            pairs = [pair for pair in pairs if not unchanged(*pair)]
        # Complete all read inventories before any write, so partial API reads never
        # masquerade as empty threads, deleted comments or missing label definitions.
        for repo in [runner.central, *runner.apps.values()]:
            runner.labels[repo] = {v["name"].casefold(): v for v in _pages(api, f"/repos/{repo}/labels")}
        for app, source, tracker in pairs:
            runner.threads[runner.apps[app], source["number"]] = _comments(api, runner.apps[app], source["number"])
            if tracker: runner.threads[runner.central, tracker["number"]] = _comments(api, runner.central, tracker["number"])
        if execute and creates:
            # Creation trusts absence, so confirm it with a second complete read that
            # must name exactly the same authenticated trackers.
            again = _mirrors(linked.inventory(api, runner.central), reg, bot_login)
            if {k: v["number"] for k, v in again.items()} != {k: v["number"] for k, v in mirrors.items()}:
                raise linked.SyncError("central inventory changed between reads; no tracker created, run a fresh plan")
        for app, source, tracker in pairs:
            try:
                runner.pair(app, source, tracker)
            except (linked.SyncError, OSError, ValueError, KeyError, TypeError) as exc:
                result["errors"].append({"source": f"{app}#{source['number']}", "error": str(exc)})
                if result["uncertain"]: break
        result["complete"] = not result["errors"] and not result["conflicts"]
    except (linked.SyncError, OSError, ValueError, KeyError, TypeError) as exc:
        result["errors"].append({"error": str(exc)})
    result["counts"] = dict(Counter(a["action"] for a in result["actions"]))
    return result
