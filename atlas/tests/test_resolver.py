"""ATLAS-02: one Git-aware resolver and exact snapshot provenance."""
import json
import os
import unittest

from support import AtlasCase, commit, make_repo, meta, resolver, sh, write_registry

URL = "https://github.com/example/AppOne"


class Resolution(AtlasCase):
    def resolve(self, m, config=None):
        return resolver.resolve(m, self.root, env={}, config=config or {})

    def test_primary_clone_found_as_sibling(self):
        make_repo(self.ws / "AppOne", {"a.txt": "a"}, url="git@github.com:example/AppOne.git")
        res = self.resolve(meta("appone", local_dir="AppOne", url=URL))
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["path"], str(self.ws / "AppOne"))

    def test_ssh_host_alias_matches_canonical_url(self):
        make_repo(self.ws / "AppOne", {"a.txt": "a"}, url="git@github.com-personal:example/AppOne.git")
        self.assertEqual(self.resolve(meta("appone", local_dir="AppOne", url=URL))["status"], "ok")

    def test_linked_worktree_with_git_file(self):
        make_repo(self.ws / "AppOne", {"a.txt": "a"}, url=URL)
        wt = self.ws / "trees" / "feature one"
        sh(self.ws / "AppOne", "worktree", "add", "-q", "-b", "feature", str(wt))
        self.assertTrue((wt / ".git").is_file())
        res = self.resolve(meta("appone", local_dir="AppOne", url=URL), {"repos": {"appone": str(wt)}})
        self.assertEqual(res["status"], "ok")
        info = resolver.inspect(res["path"])
        self.assertEqual(info["branch"], "feature")
        self.assertIn("feature", [w["branch"] for w in info["worktrees"]])

    def test_spaces_and_symlinks_resolve_to_real_path(self):
        real = self.ws / "real place" / "App One"
        make_repo(real, {"a.txt": "a"}, url=URL)
        farm = self.ws / "my work"
        farm.mkdir()
        (farm / "AppOne").symlink_to(real)
        res = self.resolve(meta("appone", local_dir="AppOne", url=URL), {"workspace": str(farm)})
        self.assertEqual((res["status"], res["path"]), ("ok", str(real)))

    def test_missing_repo_is_reported_missing(self):
        self.assertEqual(self.resolve(meta("ghost", local_dir="Ghost"))["status"], "missing")

    def test_explicit_mapping_wins_and_never_falls_back(self):
        make_repo(self.ws / "AppOne", {"a.txt": "a"}, url=URL)
        other = self.ws / "elsewhere" / "AppOneCopy"
        make_repo(other, {"b.txt": "b"}, url=URL)
        m = meta("appone", local_dir="AppOne", url=URL)
        self.assertEqual(self.resolve(m, {"repos": {"appone": str(other)}})["path"], str(other))
        gone = self.resolve(m, {"repos": {"appone": str(self.ws / "gone")}})
        self.assertEqual((gone["status"], gone["path"]), ("missing", None))

    def test_two_discovered_checkouts_are_ambiguous(self):
        make_repo(self.ws / "AppOne", {"a.txt": "a"}, url=URL)
        second = self.ws / "other-workspace"
        make_repo(second / "AppOne", {"a.txt": "a"}, url=URL)
        res = self.resolve(meta("appone", local_dir="AppOne", url=URL), {"workspace": str(second)})
        self.assertEqual(res["status"], "ambiguous")
        self.assertEqual(len(res["candidates"]), 2)

    def test_wrong_remote_or_subdirectory_is_a_mismatch(self):
        make_repo(self.ws / "AppOne", {"sub/a.txt": "a"}, url="https://github.com/someone/else")
        m = meta("appone", local_dir="AppOne", url=URL)
        self.assertEqual(self.resolve(m)["status"], "mismatch")
        self.assertEqual(self.resolve(meta("x", local_dir="AppOne"), {"repos": {"x": str(self.ws / "AppOne" / "sub")}})["status"], "mismatch")


class Provenance(AtlasCase):
    def setUp(self):
        super().setUp()
        self.repo = self.ws / "AppOne"
        self.first = make_repo(self.repo, {"a.swift": "let a = 1\n"}, url=URL)
        self.second = commit(self.repo, {"a.swift": "let a = 2\n"}, "same instant")  # identical timestamp

    def test_same_day_commits_are_distinct_snapshots(self):
        one = resolver.snapshot_provenance("appone", self.repo, self.first, {"x": 1}, {"atlas": "t"})
        two = resolver.snapshot_provenance("appone", self.repo, self.second, {"x": 1}, {"atlas": "t"})
        self.assertNotEqual(one["source_commit"], two["source_commit"])
        self.assertNotEqual(one["source_tree"], two["source_tree"])
        self.assertEqual(len(one["source_commit"]), 40)
        self.assertEqual(two["source_ref"], None)  # a raw SHA has no symbolic ref
        self.assertEqual(resolver.snapshot_provenance("appone", self.repo, "main", {}, {})["source_ref"], "refs/heads/main")

    def test_scan_config_hash_tracks_config(self):
        self.assertEqual(resolver.config_hash({"a": 1, "b": 2}), resolver.config_hash({"b": 2, "a": 1}))
        self.assertNotEqual(resolver.config_hash({"a": 1}), resolver.config_hash({"a": 2}))

    def test_dirty_work_is_never_stamped_clean(self):
        (self.repo / "a.swift").write_text("let a = 3\n")
        committed = resolver.snapshot_provenance("appone", self.repo, "HEAD", {}, {})
        self.assertFalse(committed["dirty"])  # reads the commit, not the working tree
        overlay = resolver.snapshot_provenance("appone", self.repo, "HEAD", {}, {}, overlay=True)
        self.assertEqual((overlay["dirty"], overlay["scope"]), (True, "local-overlay"))
        before = overlay["content_hash"]
        (self.repo / "new.swift").write_text("untracked\n")
        self.assertNotEqual(resolver.worktree_content_hash(self.repo), before)

    def test_stale_distinguishes_same_day_commits(self):
        pinned = meta("appone", local_dir="AppOne", url=URL, refs=[{"name": "main", "commit": self.first, "role": "baseline"}])
        write_registry(self.root, [pinned])
        code, out = self.run_atlas("stale", "--json")
        row = json.loads(out)[0]
        self.assertEqual(code, 0)
        self.assertTrue(row["source"].startswith("outdated"), row)


if __name__ == "__main__":
    unittest.main()
