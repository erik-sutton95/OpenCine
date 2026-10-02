"""ATLAS-06: navigation cases are well formed and every expected path resolves at its pin."""
import json
import unittest
from pathlib import Path

import support  # noqa: F401  (puts tools/ on sys.path)
import atlas  # noqa: E402
import resolver  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
EVALS = ROOT / "evals" / "navigation"
CASES = json.loads((EVALS / "cases.json").read_text())
SNAPSHOTS = json.loads((EVALS / "snapshots.json").read_text())
REGISTRY, _ = atlas.load_registry(ROOT)


def checkout(snapshot):
    rid = snapshot.split("@", 1)[0]
    res = resolver.resolve(REGISTRY[rid], ROOT)
    sha = SNAPSHOTS[snapshot]
    return res["path"] if res["status"] == "ok" and resolver.rev(res["path"], sha) else None


AVAILABLE = all(checkout(s) for s in SNAPSHOTS)


class Cases(unittest.TestCase):
    def test_shape(self):
        self.assertTrue(8 <= len(CASES) <= 12)
        self.assertEqual(len({c["id"] for c in CASES}), len(CASES))
        topics = {c["topic"] for c in CASES}
        self.assertTrue({"wrong repository", "no code change"} <= topics)
        for c in CASES:
            e = c["expected"]
            self.assertIn(c["mode"], {"investigate", "plan", "implement"}, c["id"])
            self.assertIn(e["owner"], REGISTRY, c["id"])
            self.assertIn(e["snapshot"], SNAPSHOTS, c["id"])
            self.assertTrue(e["snapshot"].startswith(e["owner"] + "@"), c["id"])
            self.assertTrue(e["paths"] and e["must_mention"], c["id"])
            self.assertIsInstance(e["code_change"], bool)
        for snapshot, sha in SNAPSHOTS.items():
            rid, _, ref = snapshot.partition("@")
            self.assertIn({"name": ref, "commit": sha}, [{"name": r["name"], "commit": r["commit"]} for r in REGISTRY[rid]["refs"]])

    @unittest.skipUnless(AVAILABLE, "pinned commits are not available in local checkouts")
    def test_paths_exist_at_pinned_sha(self):
        for c in CASES:
            e = c["expected"]
            path, sha = checkout(e["snapshot"]), SNAPSHOTS[e["snapshot"]]
            for rel in e["paths"] + e["tests"]:
                kind = resolver.git(path, "cat-file", "-t", f"{sha}:{rel}", check=False)
                self.assertEqual(kind, "blob", f"{c['id']}: {rel} missing at {e['snapshot']}")
            for snapshot, rels in e.get("absent_at", {}).items():
                for rel in rels:
                    kind = resolver.git(checkout(snapshot), "cat-file", "-t", f"{SNAPSHOTS[snapshot]}:{rel}", check=False)
                    self.assertNotEqual(kind, "blob", f"{c['id']}: {rel} unexpectedly present at {snapshot}")


if __name__ == "__main__":
    unittest.main()
