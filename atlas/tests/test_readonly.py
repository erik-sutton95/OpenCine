"""Every check/preview command writes nothing: atlas files, checkouts and .git included."""
import json
import unittest

from support import AtlasCase, make_repo, meta, tree_digest, write_registry

READ_ONLY = [
    ("doctor",), ("check",), ("check", "--sources"), ("stale",), ("locate", "app"),
    ("deps", "app"), ("impact", "app"), ("impact", "app", "--include-candidates"), ("graph", "plan"),
]


def fake_snapshot(root, rid, sha):
    d = root / "repos" / rid / "snapshots" / sha
    d.mkdir(parents=True)
    (d / "snapshot.json").write_text(json.dumps({
        "repository_id": rid, "source_commit": sha, "source_ref": "refs/heads/main", "source_tree": "1" * 40,
        "dirty": False, "scope": "baseline", "scan_config_hash": "2" * 64,
        "tool_versions": {"graphify": "0.9.11"}, "built_at": "2026-10-01T00:00:00Z"}))
    (d / "GRAPH_REPORT.md").write_text("# report\n")


class ReadOnly(AtlasCase):
    def setUp(self):
        super().setUp()
        self.app = make_repo(self.ws / "App", {"Package.swift": 'let package = Package(name: "A", targets: [])\n'})
        self.lib = make_repo(self.ws / "Lib", {"Package.swift": 'let package = Package(name: "L", targets: [])\n'})
        (self.ws / "App" / "dirty.txt").write_text("uncommitted user work\n")
        ref = lambda sha: [{"name": "main", "commit": sha, "role": "baseline"}]  # noqa: E731
        write_registry(self.root, [meta("app", "app", "App", refs=ref(self.app)), meta("lib", "ui", "Lib", refs=ref(self.lib))])

    def assert_read_only(self):
        before = tree_digest(self.ws)
        for argv in READ_ONLY:
            code, out = self.run_atlas(*argv)
            self.assertIn(code, (0, 1, 3), f"{argv}: {out}")
            self.assertEqual(tree_digest(self.ws), before, f"{' '.join(argv)} changed files")

    def test_zero_snapshots(self):
        self.assert_read_only()

    def test_one_snapshot(self):
        fake_snapshot(self.root, "app", self.app)
        self.assert_read_only()

    def test_many_snapshots(self):
        fake_snapshot(self.root, "app", self.app)
        fake_snapshot(self.root, "lib", self.lib)
        self.assert_read_only()


if __name__ == "__main__":
    unittest.main()
