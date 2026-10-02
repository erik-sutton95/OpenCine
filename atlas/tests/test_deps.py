"""ATLAS-03: manifest evidence, typed edges, consumer waves and forbidden directions."""
import json
import unittest

import support  # noqa: F401  (puts tools/ on sys.path)
import manifests  # noqa: E402
from support import AtlasCase, atlas, make_repo, meta, write_registry

SWIFT_HEADER = "// swift-tools-version: 6.0\nimport PackageDescription\n"


def package(name, deps=""):
    return SWIFT_HEADER + f'let package = Package(\n    name: "{name}",\n    dependencies: [{deps}],\n    targets: []\n)\n'


class Readers(unittest.TestCase):
    def test_comment_and_example_urls_are_not_dependencies(self):
        text = SWIFT_HEADER + (
            '// .package(url: "https://github.com/example/UI.git", from: "1.0.0"),\n'
            '/* .package(path: "../UI") */\n'
            'let docs = "see https://github.com/example/UI.git"\n'
            'let package = Package(name: "A", dependencies: [], targets: [])\n'
        )
        r = manifests.read("Package.swift", text)
        self.assertEqual((r["status"], r["deps"]), ("parsed", []))

    def test_swift_package_urls_paths_and_unknowns(self):
        r = manifests.read("Package.swift", package("A", '.package(url: "https://x.example/a.git", from: "1.0.0"), .package(path: "../B")'))
        self.assertEqual([(d["type"], d["value"]) for d in r["deps"]], [("url", "https://x.example/a.git"), ("path", "../B")])
        unknown = manifests.read("Package.swift", package("A", ".package(url: someVariable, from: \"1.0.0\")"))
        self.assertEqual(unknown["status"], "unknown")
        self.assertEqual(manifests.read("Package.swift", "garbage")["status"], "unknown")

    def test_xcodegen_pbxproj_gradle_catalog_and_lock(self):
        yml = ("packages:\n  Sentry:\n    url: https://x.example/sentry  # pinned\n  Core:\n    path: ../../Core\n"
               "targets:\n  App:\n    type: application\n")
        r = manifests.read("ios/project.yml", yml)
        self.assertEqual([d["value"] for d in r["deps"]], ["https://x.example/sentry", "../../Core"])
        self.assertEqual(r["products"], ["App"])
        self.assertEqual(manifests.read("ios/project.yml", "packages:\n  Lost:\n    from: 1.0.0\n")["status"], "unknown")
        pbx = ('/* x */ isa = XCLocalSwiftPackageReference; relativePath = ../UI; '
               'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://x.example/z.git"; '
               'isa = PBXNativeTarget; buildPhases = ( ); name = Runner;')
        r = manifests.read("ios/R.xcodeproj/project.pbxproj", pbx)
        self.assertEqual(sorted(d["value"] for d in r["deps"]), ["../UI", "https://x.example/z.git"])
        self.assertEqual(r["products"], ["Runner"])
        settings = 'rootProject.name = "A"\n// includeBuild("../Nope")\nincludeBuild("../../UI/Android")\ninclude(\n  ":app",\n  ":ui"\n)\n'
        r = manifests.read("Apps/Android/settings.gradle.kts", settings)
        self.assertEqual([d["value"] for d in r["deps"]], ["../../UI/Android"])
        self.assertEqual(r["products"], [":app", ":ui"])
        build = 'kotlin { explicitApi() }\ndependencies {\n  implementation(project(":ui"))\n  api("com.example:ui:1.0")\n  implementation(libs.x)\n}\n'
        r = manifests.read("Apps/Android/app/build.gradle.kts", build)
        self.assertEqual((r["status"], [d["value"] for d in r["deps"]]), ("parsed", ["com.example:ui"]))
        toml = '[versions]\nk = "1"\n[libraries]\nui = { module = "com.example:ui", version.ref = "k" }  # comment\nz = "g:z:1.0"\n'
        self.assertEqual([d["value"] for d in manifests.read("gradle/libs.versions.toml", toml)["deps"]], ["com.example:ui", "g:z"])
        lock = json.dumps({"pins": [{"location": "https://x.example/a", "state": {"version": "1.0"}}], "version": 3})
        self.assertEqual(manifests.read("Package.resolved", lock)["deps"][0]["value"], "https://x.example/a")
        self.assertEqual(manifests.read("Package.resolved", "{")["status"], "unknown")

    def test_path_dependency_outside_repo(self):
        self.assertEqual(manifests.outside_dir("ios/project.yml", ".."), None)
        self.assertEqual(manifests.outside_dir("ios/project.yml", "../../Core"), "Core")
        self.assertEqual(manifests.outside_dir("Package.swift", "../UI"), "UI")


class Graph(AtlasCase):
    """core <- ui <- app, built from real manifests in temporary repos."""

    def setUp(self):
        super().setUp()
        self.core = make_repo(self.ws / "Core", {"Package.swift": package("Core")})
        self.ui = make_repo(self.ws / "UI", {"Package.swift": package("UI", '.package(path: "../Core")')})
        self.app = make_repo(self.ws / "App", {
            "Package.swift": package("App", '.package(path: "../UI"), .package(path: "../Core")'),
            "Apps/Android/settings.gradle.kts": 'includeBuild("../../../UI/Android")\ninclude(":app")\n',
        })
        self.metas = {
            "core": meta("core", "core", "Core", refs=[self._ref(self.core)]),
            "ui": meta("ui", "ui", "UI", refs=[self._ref(self.ui)]),
            "app": meta("app", "app", "App", refs=[self._ref(self.app)]),
        }
        write_registry(self.root, self.metas.values())

    @staticmethod
    def _ref(sha):
        return {"name": "main", "commit": sha, "role": "baseline"}

    def test_app_ui_core_chain_gives_consumer_waves(self):
        code, out = self.run_atlas("impact", "core", "--json")
        self.assertEqual(code, 0, out)
        waves = [[item["repo"] for item in wave] for wave in json.loads(out)["waves"]]
        self.assertEqual(waves, [["ui"], ["app"]])
        self.assertEqual(json.loads(out)["copy_cycles"], [])
        code, out = self.run_atlas("impact", "ui", "--json")
        self.assertEqual([[i["repo"] for i in w] for w in json.loads(out)["waves"]], [["app"]])
        code, out = self.run_atlas("deps", "app", "--json")
        derived = json.loads(out)["manifest_edges"]
        self.assertEqual(sorted((e["to"], e["evidence"]["path"]) for e in derived),
                         [("core", "Package.swift"), ("ui", "Apps/Android/settings.gradle.kts"), ("ui", "Package.swift")])
        self.assertTrue(all(len(e["evidence"]["source_commit"]) == 40 for e in derived))
        self.assertEqual(self.run_atlas("check", "--sources")[0], 0)

    def test_manufacturer_to_ui_is_forbidden(self):
        sha = make_repo(self.ws / "Vendor", {"Package.swift": package("Vendor", '.package(path: "../UI")')})
        write_registry(self.root, [meta("vendor", "vendor", "Vendor", refs=[self._ref(sha)])])
        code, out = self.run_atlas("deps", "vendor")
        self.assertEqual(code, 1, out)
        self.assertIn("FORBIDDEN vendor -> ui", out)
        code, out = self.run_atlas("check", "--sources")
        self.assertEqual(code, 1)
        self.assertIn("forbidden: vendor must not depend on ui", out)
        # the same rule applies to an authored edge, with no checkouts needed
        authored = meta("vendor", "vendor", "Vendor", edges=[{"to": "ui", "kind": "library", "status": "live", "confidence": "inferred"}])
        write_registry(self.root, [authored])
        code, out = self.run_atlas("check")
        self.assertEqual(code, 1)
        self.assertIn("forbidden: vendor must not depend on ui", out)

    def test_nothing_may_depend_on_the_atlas(self):
        write_registry(self.root, [meta("atlas-self", "atlas"),
                                   meta("app", "app", "App", edges=[{"to": "atlas-self", "kind": "library", "status": "live", "confidence": "inferred"}])])
        code, out = self.run_atlas("check")
        self.assertEqual(code, 1)
        self.assertIn("nothing may build against the atlas", out)

    def test_missing_checkout_is_incomplete_not_success(self):
        write_registry(self.root, [meta("lost", "app", "Lost", refs=[self._ref(self.core)])])
        code, out = self.run_atlas("impact", "core")
        self.assertEqual(code, 3, out)
        self.assertIn("INCOMPLETE lost", out)
        self.assertEqual(self.run_atlas("check", "--sources")[0], 3)
        self.assertEqual(self.run_atlas("deps", "lost")[0], 3)

    def test_comment_url_cannot_confirm_an_edge(self):
        url = "https://github.com/example/UI"
        self.metas["ui"]["repository"]["url"] = url
        sha = make_repo(self.ws / "Other", {"Package.swift": SWIFT_HEADER + f'// .package(url: "{url}.git", from: "1.0.0")\nlet package = Package(name: "O", targets: [])\n'})
        claim = {"to": "ui", "kind": "library", "status": "live", "confidence": "confirmed",
                 "evidence": {"path": "Package.swift", "source_commit": sha}}
        write_registry(self.root, [self.metas["ui"], meta("other", "app", "Other", refs=[self._ref(sha)], edges=[claim])])
        code, out = self.run_atlas("deps", "other", "--json")
        self.assertEqual(json.loads(out)["manifest_edges"], [])
        code, out = self.run_atlas("check", "--sources")
        self.assertEqual(code, 1)
        self.assertIn("declares no such dependency", out)

    def test_build_cycles_and_candidate_rules(self):
        lib = {"kind": "library", "status": "live", "confidence": "inferred"}
        write_registry(self.root, [meta("a", "app", edges=[dict(lib, to="b")]), meta("b", "app", edges=[dict(lib, to="a")])])
        code, out = self.run_atlas("check")
        self.assertIn("build cycle", out)
        write_registry(self.root, [meta("a", "app", edges=[dict(lib, to="cand")]), meta("b", "app"), meta("cand", "ui", status="candidate")])
        code, out = self.run_atlas("check")
        self.assertEqual(code, 1)
        self.assertIn("candidate repository cannot have or be the target of a live edge", out)

    def test_copy_cycle_shares_a_wave_and_is_reported(self):
        copy = {"kind": "source-copy", "status": "live", "confidence": "inferred", "scope": ["x"], "mechanism": "script", "donor_revision": None}
        self.metas["core"]["edges"] = [dict(copy, to="app")]
        write_registry(self.root, [self.metas["core"]])
        self.assertEqual(self.run_atlas("check")[0], 0)
        # core copies from app while app builds against ui and core: a real cycle, so no order
        # inside it can be derived; both share wave 1 and the cycle is reported.
        code, out = self.run_atlas("impact", "app", "--json")
        self.assertEqual([[i["repo"] for i in w] for w in json.loads(out)["waves"]], [["core", "ui"]])
        self.assertEqual(json.loads(out)["copy_cycles"], [["app", "core", "ui"]])
        code, out = self.run_atlas("impact", "app", "--json", "--registry-only")
        self.assertEqual([[i["repo"] for i in w] for w in json.loads(out)["waves"]], [["core"]])
        self.assertEqual(json.loads(out)["manifests"], "not checked")


class PrivatePaths(AtlasCase):
    def test_private_machine_paths_fail_check(self):
        write_registry(self.root, [meta("a", "app")])
        self.assertEqual(self.run_atlas("check")[0], 0)
        home = "/" + "Users/someone/Work/App"
        (self.root / "notes.md").write_text(f"see {home}/Package.swift\n")
        code, out = self.run_atlas("check")
        self.assertEqual(code, 1)
        self.assertIn("notes.md:1: private machine path", out)



class Candidates(AtlasCase):
    def test_unverified_checks_never_pass(self):
        write_registry(self.root, [meta("pkg", "ui"), meta("app", "app")])
        (self.root / "compat").mkdir()
        sha = "a" * 40
        doc = {"candidates": [{"id": "c1", "package": {"repo": "pkg", "commit": None},
                               "consumers": [{"repo": "app", "commit": sha, "checks": [{"recipe": "x", "status": "passed"}]}]}]}
        (self.root / "compat" / "candidates.json").write_text(json.dumps(doc))
        code, out = self.run_atlas("check")
        self.assertEqual(code, 1)
        self.assertIn("a passed check needs the exact package commit", out)
        doc["candidates"][0]["package"]["commit"] = sha
        doc["candidates"][0]["consumers"][0]["checks"][0]["status"] = "skipped"
        (self.root / "compat" / "candidates.json").write_text(json.dumps(doc))
        self.assertIn("check status must be one of", self.run_atlas("check")[1])
        doc["candidates"][0]["consumers"][0]["checks"][0]["status"] = "unavailable"
        (self.root / "compat" / "candidates.json").write_text(json.dumps(doc))
        self.assertEqual(self.run_atlas("check")[0], 0)


if __name__ == "__main__":
    unittest.main()
