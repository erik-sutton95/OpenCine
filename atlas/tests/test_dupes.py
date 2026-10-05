"""SHELL-00: atlas dupes finds identical and near-identical files and function blocks between
repositories, and holds them to a committed baseline."""
import json
import unittest
from unittest import mock

from support import AtlasCase, commit, make_repo, meta, sh, tree_digest, write_registry

import dupes  # noqa: E402

FUNC = """func shared(_ x: Int) -> Int {
    var total = 0
    for i in 0..<x {
        total += i * 2
    }
    if total > 100 {
        total -= 100
    }
    return total
}
"""
KOTLIN = """package com.opencapture.{app}

import kotlin.math.abs

// {App} keeps this helper.
class Helper {{
    fun clamp(v: Int): Int {{
        val a = abs(v)
        return if (a > 10) 10 else a
    }}
}}
"""


class Dupes(AtlasCase):
    def setUp(self):
        super().setUp()
        # The atlas lives inside the platform checkout, as in OpenCine.
        self.plat = self.ws / "OpenCine"
        self.root = self.plat / "atlas"
        self.root.mkdir(parents=True)
        (self.root / "repos").mkdir()
        self.env = mock.patch.dict("os.environ", {"OPENCAPTURE_ATLAS_ROOT": str(self.root)})
        self.env.start()
        self.addCleanup(self.env.stop)
        make_repo(self.plat, {"Package.swift": "let package = Package(name: \"OpenCine\", targets: [])\n",
                              "Sources/Core/Shared.swift": "struct S {}\n" + FUNC,
                              "Sources/Core/Own.swift": "struct OnlyHere {\n    let a = 1\n    let b = 2\n}\n"})
        self.a = make_repo(self.ws / "Alpha", {
            "Sources/Copy.swift": "struct S {}\n" + FUNC,                                   # exact copy of a platform file
            "Android/Helper.kt": KOTLIN.format(app="alpha", App="Alpha"),                   # near copy of Beta's
            "Sources/Big.swift": "struct AlphaOnly {\n    let x = 1\n}\n" + FUNC.replace("shared", "twice"),
        }, url="https://github.com/o/Alpha")
        self.b = make_repo(self.ws / "Beta", {
            "Android/Helper.kt": KOTLIN.format(app="beta", App="Beta"),
            "Sources/Other.swift": "struct BetaOnly {\n    let y = 2\n    let z = 3\n}\n" + FUNC.replace("shared", "twice"),
        }, url="https://github.com/o/Beta")
        plat_meta = meta("opencine", "platform", "OpenCine", status="candidate")
        plat_meta["layers"] = {"core": []}
        self.metas = [plat_meta] + [meta(r, "app", d, url=f"https://github.com/o/{d}", refs=[{"name": "main", "commit": c, "role": "baseline"}])
                                    for r, d, c in (("alpha", "Alpha", self.a), ("beta", "Beta", self.b))]
        write_registry(self.root, self.metas)
        # Display names are the app names normalization replaces.
        for m in self.metas:
            m["display_name"] = m["local_dir"]
        write_registry(self.root, self.metas)

    def test_pairs_exact_near_and_blocks(self):
        r = dupes.measure(*self.reg())
        self.assertEqual(r["missing"], {})
        alpha_plat = r["pairs"]["alpha|opencine"]
        self.assertEqual((alpha_plat["files"], alpha_plat["exact_files"]), (1, 1))
        self.assertEqual(alpha_plat["blocks"], 0, "blocks inside a shared file are not counted twice")
        ab = r["pairs"]["alpha|beta"]
        self.assertEqual((ab["files"], ab["exact_files"]), (1, 0), "comments, imports, package and app names differ only")
        self.assertEqual(ab["blocks"], 1, "the renamed function is a shared block")
        self.assertEqual(ab["lines"], ab["file_lines"] + ab["block_lines"])
        self.assertEqual(r["pairs"]["beta|opencine"]["lines"], 0)

    def reg(self):
        import atlas  # noqa: PLC0415
        reg, _ = atlas.load_registry(self.root)
        return reg, self.root

    def test_baseline_check_and_unavailable_repos(self):
        before = tree_digest(self.ws)
        code, out = self.run_atlas("dupes", "--check")
        self.assertEqual(code, 0, out)
        self.assertEqual(tree_digest(self.ws), before, "without --write-baseline nothing is written")
        self.assertEqual(self.run_atlas("dupes", "--write-baseline")[0], 0)
        base = json.loads((self.root / dupes.BASELINE).read_text())
        self.assertEqual(set(base["pairs"]), {"alpha|beta", "alpha|opencine", "beta|opencine"})
        self.assertEqual(self.run_atlas("dupes", "--check")[0], 0)
        # A new copy in the platform working tree grows a pair: the check fails.
        (self.plat / "Sources/Core/Helper.kt").write_text(KOTLIN.format(app="opencine", App="OpenCine"))
        code, out = self.run_atlas("dupes", "--check")
        self.assertEqual(code, 1, out)
        self.assertIn("grew in alpha|opencine", out)
        # A repository that cannot be read is reported, never counted as zero, and blocks a baseline.
        sh(self.ws / "Beta", "remote", "set-url", "origin", "https://github.com/o/Elsewhere")
        (self.plat / "Sources/Core/Helper.kt").unlink()
        code, out = self.run_atlas("dupes", "--check")
        self.assertEqual(code, 0, out)
        self.assertIn("beta: NOT CHECKED", out)
        self.assertIn("alpha / beta", out)
        self.assertIn("not checked", out)
        self.assertEqual(self.run_atlas("dupes", "--write-baseline")[0], 1)

    def test_an_unregistered_app_folder_is_measured_never_recorded(self):
        app = self.ws / "Gamma"  # a generated app: no registry entry, no Git
        (app / "ios").mkdir(parents=True)
        (app / "ios/Copy.swift").write_text("struct S {}\n" + FUNC)
        (app / "build").mkdir()
        (app / "build/Generated.swift").write_text("struct S {}\n" + FUNC)
        pair = dupes.measure(*self.reg(), app=app)["pairs"]["app:Gamma|opencine"]
        self.assertEqual((pair["files"], pair["exact_files"]), (1, 1), "build output is not source")
        code, out = self.run_atlas("dupes", "--app", str(app))
        self.assertEqual(code, 0, out)
        self.assertIn("app:Gamma / opencine", out)
        before = tree_digest(self.ws)
        self.assertEqual(self.run_atlas("dupes", "--app", str(app), "--write-baseline")[0], 1)
        self.assertEqual(tree_digest(self.ws), before)

    def test_a_candidate_reads_its_consumer_commits(self):
        (self.ws / "Alpha/Sources/Copy.swift").unlink()
        gone = commit(self.ws / "Alpha", {}, "drop the copy")  # the registry ref still has it
        (self.root / "compat").mkdir()
        (self.root / "compat/candidates.json").write_text(json.dumps({"candidates": [
            {"id": "union", "package": {"repo": "opencine", "commit": None},
             "consumers": [{"repo": "alpha", "ref": "union", "commit": gone, "checks": []}]}]}))
        self.assertEqual(dupes.measure(*self.reg())["pairs"]["alpha|opencine"]["files"], 1)
        code, out = self.run_atlas("dupes", "--candidate", "union")
        self.assertEqual(code, 0, out)
        self.assertIn(f"alpha: candidate union union {gone}", out)
        self.assertIn("beta: main", out, "a repository the candidate does not list keeps its registry ref")
        self.assertEqual(dupes.measure(*self.reg(), refs=dupes.candidate_refs(self.root, "union"))["pairs"]["alpha|opencine"]["files"], 0)
        before = tree_digest(self.ws)
        self.assertEqual(self.run_atlas("dupes", "--candidate", "union", "--write-baseline")[0], 1)
        self.assertEqual(self.run_atlas("dupes", "--candidate", "nope")[0], 1)
        self.assertEqual(tree_digest(self.ws), before)

    def test_blocks_skip_types_and_short_bodies(self):
        text = "class Foo(val a: Int) {\n    fun one() { }\n" + "    fun two(x: Int): Int {\n" + "        x\n" * 6 + "    }\n}\n"
        self.assertEqual([b.split("(")[0].strip() for b in dupes.blocks(text, ".kt")], ["fun one", "fun two"])
        c = "static int add(int a, int b) {\n  return a + b;\n}\nif (x) {\n}\n"
        self.assertEqual(len(dupes.blocks(c, ".c")), 1)


if __name__ == "__main__":
    unittest.main()
