"""Plan 3.4 direction rules between targets and Gradle modules inside the one platform repo."""
import json
import os
import unittest
from unittest import mock

from support import AtlasCase, atlas, meta, write_registry

PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "P",
    products: [.library(name: "Core", targets: ["Core"])],
    targets: [
        .target(name: "Core"),
        .target(name: "UI", dependencies: ["Core"]),
        .target(name: "Multi", dependencies: [.target(name: "Core")]),
        .target(name: "Vendor", dependencies: ["Core", "CShim"]),
        .target(name: "CShim", exclude: ["LICENSE"]),
        .testTarget(name: "HarnessTests", dependencies: ["Vendor", "Multi", .byName(name: "Core")]),
    ]
)
'''
SETTINGS = 'rootProject.name = "p"\ninclude(\n    ":core", // contracts\n    ":multicam",\n)\n'
CORE_GRADLE = "plugins { }\ndependencies {\n    api(libs.kotlinx.coroutines.core)\n}\n"
MULTI_GRADLE = 'dependencies {\n    api(project(":core"))\n    testImplementation(testFixtures(project(":core")))\n}\n'
LAYERS = {"core": ["Core", ":core"], "ui": ["UI"], "multicam": ["Multi", ":multicam"], "vendor": ["Vendor", "CShim"], "harness": ["HarnessTests"]}


def files(package=PACKAGE, multi=MULTI_GRADLE, settings=SETTINGS):
    return {"Package.swift": package, "Android/settings.gradle.kts": settings,
            "Android/core/build.gradle.kts": CORE_GRADLE, "Android/multicam/build.gradle.kts": multi}


class TargetLayers(unittest.TestCase):
    m = {"layers": LAYERS}

    def test_clean_platform_passes(self):
        self.assertEqual(atlas.target_layer_errors(self.m, files()), [])

    def test_forbidden_target_and_module_edges(self):
        bad = PACKAGE.replace('.target(name: "Core"),', '.target(name: "Core", dependencies: ["UI"]),')
        bad = bad.replace('.target(name: "Multi", dependencies: [.target(name: "Core")])', '.target(name: "Multi", dependencies: ["Vendor"])')
        bad = bad.replace('.target(name: "UI", dependencies: ["Core"])', '.target(name: "UI", dependencies: ["Core", "HarnessTests"])')
        errs = atlas.target_layer_errors(self.m, files(bad, MULTI_GRADLE.replace('project(":core"))\n', 'project(":core"))\n    implementation(project(":multicam"))\n')))
        joined = "\n".join(errs)
        self.assertIn("Core (core) -> UI (ui): forbidden: core must not depend on ui", joined)
        self.assertIn("Multi (multicam) -> Vendor (vendor): forbidden: multicam must not depend on vendor", joined)
        self.assertIn("UI (ui) -> HarnessTests (harness): forbidden: nothing may build against the harness", joined)
        self.assertEqual(len(errs), 3, joined)  # a module depending on itself breaks no layer rule

    def test_kotlin_module_direction(self):
        layers = dict(LAYERS, core=["Core"], ui=["UI", ":core"])  # :core relabelled ui: multicam -> ui is forbidden
        errs = atlas.target_layer_errors({"layers": layers}, files())
        self.assertTrue(any("Android/multicam/build.gradle.kts: :multicam (multicam) -> :core (ui)" in e for e in errs), errs)

    def test_allowed_target_edge_lets_one_edge_through(self):
        pkg = PACKAGE.replace('.target(name: "UI", dependencies: ["Core"])', '.target(name: "UI", dependencies: ["Core", "Vendor"])')
        allow = {"from": "UI", "to": "Vendor", "reason": "test"}
        self.assertEqual(atlas.target_layer_errors({"layers": LAYERS, "allowed_target_edges": [allow]}, files(pkg)), [])
        bad = pkg.replace('.target(name: "Multi", dependencies: [.target(name: "Core")])', '.target(name: "Multi", dependencies: ["UI"])')
        errs = atlas.target_layer_errors({"layers": LAYERS, "allowed_target_edges": [allow]}, files(bad))
        self.assertEqual(errs, ["Package.swift: Multi (multicam) -> UI (ui): forbidden: multicam must not depend on ui (library)"])
        stale = atlas.target_layer_errors({"layers": LAYERS, "allowed_target_edges": [allow]}, files())
        self.assertEqual(stale, ["meta.json allowed_target_edges: UI -> Vendor is not a dependency; remove the exception"])

    def test_unassigned_unknown_external_and_atlas(self):
        pkg = PACKAGE.replace('.target(name: "CShim", exclude: ["LICENSE"]),',
                              '.target(name: "CShim", exclude: ["LICENSE"]),\n        .target(name: "New", path: "atlas/tools", dependencies: [.product(name: "X", package: "x"), "Ghost"]),')
        pkg = pkg.replace("    targets: [", '    dependencies: [.package(url: "https://example.invalid/x", from: "1.0.0")],\n    targets: [')
        joined = "\n".join(atlas.target_layer_errors(self.m, files(pkg, settings=SETTINGS + 'include(":lost")\n')))
        for want in ("New: not assigned to a layer", "New builds from atlas/tools: nothing may build against the atlas",
                     "New uses product X of package x", "New depends on unknown Ghost", "package dependency https://example.invalid/x",
                     "Android/lost/build.gradle.kts: missing for included module :lost"):
            self.assertIn(want, joined)

    def test_unparsable_dependency_is_reported(self):
        pkg = PACKAGE.replace('dependencies: ["Core", "CShim"]', 'dependencies: shared')
        self.assertTrue(any("dependency not understood" in e for e in atlas.target_layer_errors(self.m, files(pkg))))


class CheckReadsEnclosingPlatform(AtlasCase):
    """`atlas check` reads the working tree of the platform checkout the atlas lives in."""

    def setUp(self):
        super().setUp()
        self.platform = self.ws / "Platform"
        self.root = self.platform / "atlas"
        (self.root / "repos").mkdir(parents=True)
        p = mock.patch.dict(os.environ, {"OPENCAPTURE_ATLAS_ROOT": str(self.root)})
        p.start()
        self.addCleanup(p.stop)
        m = meta("platform", "platform", "Platform", status="candidate")
        m["layers"] = LAYERS
        write_registry(self.root, [m])
        for rel, text in files().items():
            f = self.platform / rel
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(text)

    def test_clean_then_violation(self):
        code, out = self.run_atlas("check")
        self.assertEqual(code, 0, out)
        self.assertIn("Target layers: platform working tree checked", out)
        (self.platform / "Package.swift").write_text(PACKAGE.replace('.target(name: "Core"),', '.target(name: "Core", dependencies: ["Vendor"]),'))
        code, out = self.run_atlas("check")
        self.assertEqual(code, 1, out)
        self.assertIn("platform working tree: Package.swift: Core (core) -> Vendor (vendor): forbidden", out)

    def test_bad_layers_map_is_a_registry_error(self):
        m = json.loads((self.root / "repos/platform/meta.json").read_text())
        m["layers"]["app"] = ["UI"]
        (self.root / "repos/platform/meta.json").write_text(json.dumps(m))
        code, out = self.run_atlas("check")
        self.assertEqual(code, 1, out)
        self.assertIn("layers maps a product layer", out)

    def test_allowed_target_edge_needs_known_names_and_a_reason(self):
        m = json.loads((self.root / "repos/platform/meta.json").read_text())
        m["allowed_target_edges"] = [{"from": "UI", "to": "Ghost", "reason": "x"}, {"from": "UI", "to": "Vendor"}]
        (self.root / "repos/platform/meta.json").write_text(json.dumps(m))
        code, out = self.run_atlas("check")
        self.assertEqual(code, 1, out)
        self.assertIn("allowed_target_edges[0] needs from and to", out)
        self.assertIn("allowed_target_edges[1] needs from and to", out)


if __name__ == "__main__":
    unittest.main()
