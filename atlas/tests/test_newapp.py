"""SHELL-05 contract: `atlas new-app` writes a thin app from the real template next to a temporary
OpenCine sibling slot. It composes the shell, keeps the fake in its SIMULATED variants and copies
no shared code. Building and running it is scripts/template-app-check.sh."""
import contextlib
import io
import os
import re
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from support import TOOLS, atlas, resolver

import dupes  # noqa: E402

TOP = TOOLS.parent.parent  # the OpenCine checkout these tests run in
ID = "com.opencapture.opentestcine"
PKG = "Android/app/src/{}/kotlin/com/opencapture/opentestcine/{}"
FILES = {
    ".gitignore", "README.md", "opencine-pins.txt", "scripts/checkout-opencine.sh",
    ".github/workflows/ci.yml", ".github/workflows/release.yml",
    "ios/project.yml", "ios/OpenTestCine/App.swift", "ios/OpenTestCine/Shell.swift",
    "ios/OpenTestCine/Integrations.swift", "ios/OpenTestCine/OpenTestCine.entitlements",
    "ios/Simulated/Integrations.swift", "ios/Tests/ShellContractTests.swift", "ios/TestFlight/WhatToTest.en-US.txt",
    "Android/settings.gradle.kts", "Android/build.gradle.kts", "Android/gradle.properties", "Android/gradlew",
    "Android/gradlew.bat", "Android/gradle/wrapper/gradle-wrapper.jar", "Android/gradle/wrapper/gradle-wrapper.properties",
    "Android/app/build.gradle.kts", "Android/app/src/main/AndroidManifest.xml",
    PKG.format("main", "MainActivity.kt"), PKG.format("main", "Shell.kt"), PKG.format("camera", "Integrations.kt"),
    PKG.format("simulated", "Integrations.kt"), PKG.format("testSimulated", "ShellContractTest.kt"),
    "Android/Play/WhatToTest.en-US.txt", "Android/Play/whatsnew/whatsnew-en-US",
}
SIMULATED = {"ios/Simulated/Integrations.swift", "ios/Tests/ShellContractTests.swift",
             PKG.format("simulated", "Integrations.kt"), PKG.format("testSimulated", "ShellContractTest.kt")}


def run(*argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        try:
            code = atlas.main(list(argv))
        except SystemExit as exc:
            code = exc.code
    return code, out.getvalue()


class NewApp(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._env = mock.patch.dict(os.environ)
        cls._env.start()
        os.environ.pop("OPENCAPTURE_ATLAS_ROOT", None)  # the real atlas, registry and template
        cls._tmp = tempfile.TemporaryDirectory()
        cls.dest = Path(cls._tmp.name).resolve()
        cls.code, cls.out = run("new-app", "OpenTestCine", "--dest", str(cls.dest))
        cls.app = cls.dest / "OpenTestCine"
        cls.files = {str(p.relative_to(cls.app)): p for p in cls.app.rglob("*") if p.is_file()}

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()
        cls._env.stop()

    def text(self, rel):
        return self.files[rel].read_text()

    def test_writes_the_thin_app(self):
        self.assertEqual(self.code, 0, self.out)
        self.assertEqual(set(self.files), FILES)
        texts = {rel: p.read_text() for rel, p in self.files.items() if not rel.endswith(".jar")}
        self.assertEqual([rel for rel, t in texts.items() if re.search("__[A-Z_]+__|" + chr(0x2014), t)], [], "placeholders filled, no em dash")
        self.assertEqual(self.text("opencine-pins.txt").splitlines()[-1], f"OpenCine {resolver.git(TOP, 'rev-parse', 'HEAD')}")
        for script in ("scripts/checkout-opencine.sh", "Android/gradlew"):
            self.assertTrue(os.access(self.files[script], os.X_OK), script)
        # Brand configuration and identity.
        self.assertIn('ShellBrand(name: "OpenTestCine")', self.text("ios/OpenTestCine/Shell.swift"))
        self.assertIn('ShellBrand("OpenTestCine")', self.text(PKG.format("main", "Shell.kt")))
        self.assertIn(f"PRODUCT_BUNDLE_IDENTIFIER: {ID}\n", self.text("ios/project.yml"))
        self.assertIn(f'applicationId = "{ID}"', self.text("Android/app/build.gradle.kts"))
        # It composes the shared shell from the sibling OpenCine.
        self.assertIn("AppShell(", self.text("ios/OpenTestCine/App.swift"))
        self.assertIn("AppShell(", self.text(PKG.format("main", "MainActivity.kt")))
        self.assertIn("path: ../../OpenCine\n", self.text("ios/project.yml"))
        self.assertIn('includeBuild("../../OpenCine/Android")', self.text("Android/settings.gradle.kts"))

    def test_the_fake_stays_in_the_simulated_variants(self):
        code = {rel for rel in self.files if rel.endswith((".swift", ".kt"))}
        self.assertEqual({rel for rel in code if "FakeIntegration" in self.text(rel)}, {r for r in SIMULATED if "Integrations" in r})
        self.assertEqual([rel for rel in SIMULATED if "SIMULATED" not in self.text(rel)], [])
        shipping = self.text("ios/project.yml").split("\n  OpenTestCineSimulated:")[0].split("\n  OpenTestCine:")[1]
        self.assertIn("OpenCineAppKit", shipping)
        self.assertNotIn("product: OpenCineCoreTestSupport", shipping)
        self.assertIn('"simulatedImplementation"(testFixtures("com.opencapture.opencine:core"))', self.text("Android/app/build.gradle.kts"))
        self.assertIn('withFlavor("integrations" to "simulated").withBuildType("release")', self.text("Android/app/build.gradle.kts"))
        self.assertNotIn("imulated", self.text(".github/workflows/release.yml").split("\njobs:")[1], "release builds only what ships")

    def test_copies_no_shared_code(self):
        names = re.compile("OpenTestCine", re.I)
        app = dupes.index(dupes.directory_files(self.app), names)
        shared = dupes.index(dupes.working_tree_files(TOP), names)
        self.assertGreater(len(app["files"]), 5)
        self.assertEqual(app["files"].keys() & shared["files"].keys(), set())
        self.assertEqual(app["blocks"].keys() & shared["blocks"].keys(), set())

    def test_refusals_write_nothing(self):
        before = sorted(self.dest.rglob("*"))
        for argv in (["OpenTestCine"], ["lowercase"], ["OpenOtherCine", "--id", "Not.An.Id"],
                     ["OpenOtherCine", "--integration", "dji"]):
            code, out = run("new-app", *argv, "--dest", str(self.dest))
            self.assertEqual(code, atlas.USAGE, out)
        self.assertEqual(sorted(self.dest.rglob("*")), before)


if __name__ == "__main__":
    unittest.main()
