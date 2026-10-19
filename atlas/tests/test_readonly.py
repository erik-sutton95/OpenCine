"""Every check/preview command writes nothing: atlas files, checkouts and .git included."""
import unittest

from support import AtlasCase, make_repo, meta, tree_digest, write_registry

READ_ONLY = [
    ("doctor",), ("check",), ("check", "--sources"), ("stale",), ("locate", "app"),
    ("deps", "app"), ("impact", "app"), ("impact", "app", "--include-candidates"), ("compat", "plan"),
    ("ensure", "--check"), ("impact", "SomeSymbol"), ("impact", "Package.swift"),
    ("dupes",), ("dupes", "--check", "--top", "2"),
]


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

    def test_check_and_preview_commands_write_nothing(self):
        self.assert_read_only()

if __name__ == "__main__":
    unittest.main()
