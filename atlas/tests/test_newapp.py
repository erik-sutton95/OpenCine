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
    ".gitignore", "README.md", "atlas-registration.example.json", "opencine-pins.txt", "scripts/checkout-opencine.sh", "scripts/check-simulated.sh",
    ".github/workflows/ci.yml", ".github/workflows/release.yml",
    "ios/project.yml", "ios/OpenTestCine/App.swift", "ios/OpenTestCine/Shell.swift",
    "ios/OpenTestCine/Integrations.swift", "ios/OpenTestCine/OpenTestCine.entitlements",
    "ios/Simulated/Integrations.swift", "ios/Simulated/SimulatedMedia.swift", "ios/Simulated/SimulatedLibrary.swift",
    "ios/Simulated/SimulatedPictures.swift",
    "ios/Simulated/Resources/simulated.mp4", "ios/Simulated/Resources/simulated.png",
    "ios/Tests/ShellContractTests.swift", "ios/UITests/OperatorFlowTests.swift", "ios/TestFlight/WhatToTest.en-US.txt",
    "Android/settings.gradle.kts", "Android/build.gradle.kts", "Android/gradle.properties", "Android/gradlew",
    "Android/gradlew.bat", "Android/gradle/wrapper/gradle-wrapper.jar", "Android/gradle/wrapper/gradle-wrapper.properties",
    "Android/app/build.gradle.kts", "Android/app/src/main/AndroidManifest.xml",
    PKG.format("main", "MainActivity.kt"), PKG.format("main", "Shell.kt"), PKG.format("camera", "Integrations.kt"),
    PKG.format("simulated", "Integrations.kt"), PKG.format("simulated", "SimulatedMedia.kt"),
    PKG.format("simulated", "SimulatedLibrary.kt"), PKG.format("simulated", "SimulatedPictures.kt"),
    "Android/app/src/simulated/assets/simulated.mp4",
    "Android/app/src/simulated/resources/simulated/simulated.mp4",
    "Android/app/src/simulated/resources/simulated/simulated.png",
    PKG.format("testSimulated", "ShellContractTest.kt"), PKG.format("androidTestSimulated", "OperatorFlowTest.kt"),
    PKG.format("androidTestSimulated", "MonitorPortraitStatusGeometryTest.kt"),
    "Android/Play/WhatToTest.en-US.txt", "Android/Play/whatsnew/whatsnew-en-US",
}
SIMULATED = {"ios/Simulated/Integrations.swift", "ios/Simulated/SimulatedMedia.swift", "ios/Simulated/SimulatedLibrary.swift",
             "ios/Simulated/SimulatedPictures.swift", "ios/Tests/ShellContractTests.swift",
             PKG.format("simulated", "Integrations.kt"), PKG.format("simulated", "SimulatedMedia.kt"),
             PKG.format("simulated", "SimulatedLibrary.kt"), PKG.format("simulated", "SimulatedPictures.kt"),
             PKG.format("testSimulated", "ShellContractTest.kt")}


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
        texts = {rel: p.read_text() for rel, p in self.files.items() if not rel.endswith((".jar", ".png", ".mp4"))}
        self.assertEqual([rel for rel, t in texts.items() if re.search("__[A-Z_]+__|" + chr(0x2014), t)], [], "placeholders filled, no em dash")
        self.assertEqual(self.text("opencine-pins.txt").splitlines()[-1], f"OpenCine {resolver.git(TOP, 'rev-parse', 'HEAD')}")
        for script in ("scripts/checkout-opencine.sh", "scripts/check-simulated.sh", "Android/gradlew"):
            self.assertTrue(os.access(self.files[script], os.X_OK), script)
        # Brand configuration and identity.
        self.assertIn('ShellBrand(name: "OpenTestCine")', self.text("ios/OpenTestCine/Shell.swift"))
        self.assertIn('ShellBrand("OpenTestCine")', self.text(PKG.format("main", "Shell.kt")))
        self.assertIn(f"PRODUCT_BUNDLE_IDENTIFIER: {ID}\n", self.text("ios/project.yml"))
        self.assertIn(f'applicationId = "{ID}"', self.text("Android/app/build.gradle.kts"))
        # It composes the shared shell from the sibling OpenCine.
        self.assertIn("MonitorOperatorScene(", self.text("ios/OpenTestCine/App.swift"))
        self.assertIn("MonitorOperatorScene(", self.text(PKG.format("main", "MainActivity.kt")))
        for source in ("ios/OpenTestCine/App.swift", PKG.format("main", "MainActivity.kt")):
            self.assertNotIn("MonitorSlot", self.text(source))
            self.assertNotIn("CoverPage", self.text(source))
        self.assertIn("path: ../../OpenCine\n", self.text("ios/project.yml"))
        self.assertIn('includeBuild("../../OpenCine/Android")', self.text("Android/settings.gradle.kts"))

    def test_the_fake_stays_in_the_simulated_variants(self):
        code = {rel for rel in self.files if rel.endswith((".swift", ".kt"))}
        fake_references = {rel for rel in code if "FakeIntegration" in self.text(rel)}
        self.assertTrue(fake_references <= SIMULATED)
        self.assertTrue({r for r in SIMULATED if "Integrations" in r} <= fake_references)
        self.assertEqual([rel for rel in SIMULATED if "SIMULATED" not in self.text(rel)], [])
        shipping = self.text("ios/project.yml").split("\n  OpenTestCineSimulated:")[0].split("\n  OpenTestCine:")[1]
        self.assertIn("OpenCineAppKit", shipping)
        self.assertNotIn("product: OpenCineCoreTestSupport", shipping)
        self.assertNotIn("OpenCineCoreTestSupport", self.text("ios/project.yml"))
        self.assertNotIn("testFixtures(", self.text("Android/app/build.gradle.kts"))
        self.assertIn('withFlavor("integrations" to "simulated").withBuildType("release")', self.text("Android/app/build.gradle.kts"))
        self.assertNotIn("imulated", self.text(".github/workflows/release.yml").split("\njobs:")[1], "release builds only what ships")

    def test_sample_resources_are_binary_and_simulated_only(self):
        ios = self.files["ios/Simulated/Resources/simulated.mp4"].read_bytes()
        android = self.files["Android/app/src/simulated/resources/simulated/simulated.mp4"].read_bytes()
        self.assertEqual(ios, android, "both platforms exercise the same source bytes")
        self.assertEqual(ios, self.files["Android/app/src/simulated/assets/simulated.mp4"].read_bytes())
        self.assertEqual(len(ios), 86_527)
        self.assertEqual(ios[4:8], b"ftyp")
        self.assertEqual(self.files["ios/Simulated/Resources/simulated.png"].read_bytes()[:8], b"\x89PNG\r\n\x1a\n")
        self.assertFalse(any(rel.endswith(".base64") for rel in self.files))

    def test_dry_run_reports_outputs_without_writing(self):
        before = sorted(self.dest.rglob("*"))
        code, out = run("new-app", "OpenDryRunCine", "--dest", str(self.dest), "--dry-run")
        self.assertEqual(code, 0, out)
        self.assertIn("nothing written", out)
        self.assertIn("simulated.mp4", out)
        self.assertIn("ShellContractTests.swift", out)
        self.assertEqual(sorted(self.dest.rglob("*")), before)

    def test_copies_no_shared_code(self):
        names = re.compile("OpenTestCine", re.I)
        app = dupes.index(dupes.directory_files(self.app), names)
        shared = dupes.index(dupes.working_tree_files(TOP), names)
        self.assertGreater(len(app["files"]), 5)
        self.assertEqual(app["files"].keys() & shared["files"].keys(), set())
        self.assertEqual(app["blocks"].keys() & shared["blocks"].keys(), set())

    def test_complete_flow_and_evidence_recipe_are_generated(self):
        swift = self.text("ios/Tests/ShellContractTests.swift")
        kotlin = self.text(PKG.format("testSimulated", "ShellContractTest.kt"))
        self.assertEqual(swift.count("@Test func"), 8)
        self.assertEqual(kotlin.count("    @Test\n"), 8)
        for source in (self.text("ios/UITests/OperatorFlowTests.swift"),
                       self.text(PKG.format("androidTestSimulated", "OperatorFlowTest.kt"))):
            self.assertIn("picturePixels", source)
            self.assertIn("companion.simulated", source)
            self.assertIn("capabilitychange", source.lower())
            self.assertIn("monitor.system.record", source)
        recipe = self.text("scripts/check-simulated.sh")
        for proof in ("source-manifest.json", "sharedSourceSHA256", "generatedSourceSHA256", "companionSourceSHA256",
                      "ios-tests.xcresult", "android-instrumentation.log", "TEMPLATE_EMULATOR", "ANDROID_SERIAL"):
            self.assertIn(proof, recipe)
        self.assertNotIn("sleep 2", recipe)
        self.assertIn("scripts/check-simulated.sh", self.text(".github/workflows/ci.yml"))
        self.assertIn("MonitorPlaybackFeedSession", self.text("ios/Simulated/SimulatedPictures.swift"))
        self.assertIn("feed.setEffects", self.text("ios/Simulated/SimulatedPictures.swift"))
        self.assertNotIn("OpenCineCoreTestSupport", swift)
        self.assertIn("REPLACE_WITH_AUTHORIZED_REPOSITORY_URL", self.text("atlas-registration.example.json"))
        self.assertFalse((self.app / ".git").exists())

    def test_simulated_picture_poll_bound_cannot_restart_itself(self):
        swift = self.text("ios/Simulated/SimulatedPictures.swift")
        self.assertIn("displayCheckExhausted", swift)
        self.assertIn("guard displayCheck == nil, !displayCheckExhausted", swift)
        self.assertIn("self.displayCheckExhausted = exhausted", swift)
        # Only a readiness, item or rate change may clear an exhausted poll.
        self.assertIn(
            "if restartClock {\n                self.clockStart = nil; self.clockAdvanced = false\n"
            "                self.displayCheckExhausted = false\n", swift)

    def test_refusals_write_nothing(self):
        before = sorted(self.dest.rglob("*"))
        for argv in (["OpenTestCine"], ["lowercase"], ["OpenOtherCine", "--id", "Not.An.Id"],
                     ["OpenOtherCine", "--integration", "dji"]):
            code, out = run("new-app", *argv, "--dest", str(self.dest))
            self.assertEqual(code, atlas.USAGE, out)
        self.assertEqual(sorted(self.dest.rglob("*")), before)


if __name__ == "__main__":
    unittest.main()
