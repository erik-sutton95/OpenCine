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
    if not isinstance(state, dict) or set(state) != {"version", "base", "shards"} or state["version"] != 1 \
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


class Runner:
    def __init__(self, reg, api, execute, login, result):
        self.reg, self.api, self.execute, self.login, self.result = reg, api, execute, login, result
        _, self.central, self.apps = linked.identities(reg)
        self.labels, self.threads = {}, {}

    def write(self, action, pair, method, path, payload):
        self.result["actions"].append({"action": action, "source": pair, "method": method, "path": path, "payload": payload})
        if not self.execute: return None
        self.result["uncertain"] = {"source": pair, "method": method, "path": path}
        value = self.api.request(method, path, payload)
        self.result["applied"].append({"action": action, "source": pair, "method": method, "path": path})
        self.result["uncertain"] = None
        return value

    def eligible(self, repo, logins):
        for login in logins:
            try: self.api.request("GET", f"/repos/{repo}/assignees/{quote(login, safe='')}")
            except linked.SyncError as exc:
                if getattr(exc, "status", None) == 404: return False
                raise
        return len(logins) <= 10

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

    def _index(self, tracker, state, pair):
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
                key = self._entry_key(entry)
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

    def comment_sync(self, app, number, tracker, state, pair):
        source_repo = self.apps[app]
        endpoints = {source_repo: number, self.central: tracker["number"]}
        owned, entries = self._index(tracker, state, pair)
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
        for key, original in originals.items():
            if key in entries: continue
            repo, n, cid = key
            target = next(r for r in endpoints if r != repo)
            origin = {"repo": repo, "number": n, "id": cid, "author": original["user"]["login"], "url": original["html_url"]}
            entry = {"origin": origin, "peer_repo": target, "peer_id": None,
                     "base": digest(original["body"]), "last_body": original["body"], "deleted": None}
            body = self._carrier(entry, original["body"])
            peer = self.write("comment-create", pair, "POST", f"/repos/{target}/issues/{endpoints[target]}/comments", {"body": body})
            if not self.execute: continue
            if not _bot(peer, self.login) or peer.get("body") != body: raise linked.SyncError("copied comment authority not confirmed")
            entry["peer_id"] = peer["id"]
            entries[key] = entry
            carriers[key] = target, peer, {"origin": origin, "base": entry["base"], "version": 1}
        for key, entry in entries.items():
            if key[0] not in endpoints or key[1] != endpoints[key[0]] or entry.get("peer_repo") not in endpoints \
                    or entry["peer_repo"] == key[0] or type(entry.get("peer_id")) is not int \
                    or not isinstance(entry.get("last_body"), str) or not re.fullmatch(r"[0-9a-f]{64}", entry.get("base", "")):
                raise linked.SyncError("comment index crosses this authenticated issue pair")
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
        # The durable index is separate from deletable carriers. Bound both count and
        # encoded byte size, retaining full last content in one or more bot-owned shards.
        # Existing membership is durable: a failed append must never remove the
        # sole last-content/tombstone record from an already committed shard.
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
        bodies = []
        for i, values in enumerate(chunks):
            body = STATE_PREFIX + _json({"version": 1, "source": pair, "shard": i, "entries": values}) + " -->"
            # Validate every shard before modifying any durable index object.
            # A growing existing record is an explicit size blocker, never an
            # instruction to move or discard its previous confirmed content.
            if len(body) > LIMIT: raise linked.SyncError("comment index shard too large; no content discarded")
            bodies.append(body)
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
            ids.append(comment["id"])
        return ids

    def pair(self, app, source, tracker):
        pair = f"{app}#{source['number']}"
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
            if not self.execute:
                for comment in self.threads[source_repo, source["number"]]:
                    self.result["actions"].append({"source": pair, "action": "comment-create", "origin": comment["html_url"]})
                return
            if not _bot(tracker, self.login) or linked.parse_link(tracker.get("body"), self.reg) != linked.source_identity(app, source["number"], self.reg):
                raise linked.SyncError("created tracker authority/identity not confirmed; fresh inventory required")
            self.threads[self.central, tracker["number"]] = []
        state = _validate_base(_one_json(tracker["body"], ROOT_PREFIX))
        self._index(tracker, state, pair)
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
            body = _render(app, source["number"], b_values, checkpoint, self.reg, b["body"])
            self.issue_patch(self.central, b, {"body": body} if body != b["body"] else {}, pair, True, app)


def reconcile(reg, api, execute=False, bot_login="opencine-atlas-sync[bot]"):
    result = {"version": 2, "mode": "execute" if execute else "dry-run", "complete": False,
              "actions": [], "applied": [], "errors": [], "conflicts": [], "tombstones": [], "counts": {}, "uncertain": None}
    try:
        if not re.fullmatch(r"[A-Za-z0-9_-]+\[bot\]", bot_login): raise linked.SyncError("a configured sync App bot identity is required")
        runner = Runner(reg, api, execute, bot_login, result)
        central = linked.inventory(api, runner.central)
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
        sources = {}
        for app, repo in sorted(runner.apps.items()):
            for item in linked.inventory(api, repo): sources[app, item["number"]] = item
        if set(mirrors) - set(sources): raise linked.SyncError("a tracked original is missing; deletion/transfer/visibility needs review")
        pairs = [(app, item, mirrors.get((app, number))) for (app, number), item in sorted(sources.items())
                 if (app, number) in mirrors or item["state"] == "open"]
        # Complete all read inventories before any write, so partial API reads never
        # masquerade as empty threads, deleted comments or missing label definitions.
        for repo in [runner.central, *runner.apps.values()]:
            runner.labels[repo] = {v["name"].casefold(): v for v in _pages(api, f"/repos/{repo}/labels")}
        for app, source, tracker in pairs:
            runner.threads[runner.apps[app], source["number"]] = _comments(api, runner.apps[app], source["number"])
            if tracker: runner.threads[runner.central, tracker["number"]] = _comments(api, runner.central, tracker["number"])
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
