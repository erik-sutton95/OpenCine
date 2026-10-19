"""Repository hygiene rejects local data without exempting SDK tests or atlas."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "check-repository-hygiene.sh"
MAC_HOME = "/" + "Users/"
LINUX_HOME = "/" + "home/"
PRIVATE_KEY = "-----" + "BEGIN PRIVATE KEY-----"


class RepositoryHygiene(unittest.TestCase):
    def fixture(self, files):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        subprocess.run(["git", "init", "-q", str(root)], check=True, env=env, capture_output=True)
        for path, value in files.items():
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(value, bytes):
                target.write_bytes(value)
            else:
                target.write_text(value)
            subprocess.run(["git", "-C", str(root), "add", "-f", "--", path],
                           check=True, env=env, capture_output=True)
        return root, env

    def check(self, root, env, staged=False):
        return subprocess.run(["bash", str(SCRIPT)] + (["--staged"] if staged else []),
                              cwd=root, env=env, capture_output=True, text=True, timeout=10)

    def test_synthetic_fixtures_resources_templates_and_skills_pass(self):
        root, env = self.fixture({
            "Fixtures/saved-cameras/document-v1.json": '{"name":"SIMULATED"}',
            "Fixtures/luts/identity.cube": "LUT_3D_SIZE 2\n0 0 0\n",
            "Tests/Media/identity.cube": "LUT_3D_SIZE 2\n0 0 0\n",
            "Android/monitor-ui/src/androidTest/assets/monitor_backdrop_reference.png": b"\x89PNG\x00fixture",
            "Sources/MonitorUI/Resources/Fonts/Sora-Regular.ttf": b"\x00fixture font",
            "atlas/templates/app/ios/Simulated/Resources/simulated.mp4.base64.tmpl": "U0lNVUxBVEVE\n",
            ".claude/skills/issue-to-task/SKILL.md": "# Shared workflow\n",
            ".env.example": "EXAMPLE=replace-me\n",
        })
        for staged in (False, True):
            result = self.check(root, env, staged)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_private_paths_rejected_even_inside_fixtures_resources_tests_and_atlas(self):
        paths = [".env", "Sources/.env.production", "Fixtures/private.pcap", "Tests/network.btsnoop",
                 "Sources/MonitorUI/Resources/device.p12", "atlas/.local/checkouts.json",
                 "Android/media/build/classes.bin", "Android/local.properties", "captures/frame.jpg",
                 "atlas/templates/app/secrets.json", "Tests/approvals.credentials.json",
                 "DerivedData/result.txt", "Samples/device.mobileprovision", ".claude/worktrees/work/file.kt",
                 "nested/.gradle/state.bin", "Sources/Info/GoogleService-Info.plist"]
        for path in paths:
            with self.subTest(path=path):
                root, env = self.fixture({path: "synthetic private data\n"})
                for staged in (False, True):
                    result = self.check(root, env, staged)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn(path, result.stderr)

    def test_machine_paths_are_not_exempted_in_tests_or_atlas(self):
        for path in ("Tests/Fixture.swift", "atlas/templates/app/README.md.tmpl"):
            for home in (MAC_HOME, LINUX_HOME):
                with self.subTest(path=path, home=home):
                    root, env = self.fixture({path: home + "fixture/private.txt\n"})
                    for staged in (False, True):
                        result = self.check(root, env, staged)
                        self.assertEqual(result.returncode, 1)
                        self.assertIn(path, result.stderr)
                        self.assertNotIn(home + "fixture", result.stderr)

    def test_private_key_contents_rejected_in_an_ordinary_source_filename(self):
        root, env = self.fixture({"Sources/Config.txt": PRIVATE_KEY + "\nsynthetic\n"})
        for staged in (False, True):
            result = self.check(root, env, staged)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Sources/Config.txt", result.stderr)
            self.assertNotIn(PRIVATE_KEY, result.stderr)

    def test_staged_content_comes_from_index_not_repaired_worktree(self):
        root, env = self.fixture({"Sources/Config.swift": MAC_HOME + "fixture/file\n"})
        (root / "Sources/Config.swift").write_text("portable value\n")
        self.assertEqual(self.check(root, env).returncode, 0)
        self.assertEqual(self.check(root, env, True).returncode, 1)

    def test_staged_delete_does_not_flag_removed_private_path(self):
        root, env = self.fixture({".env": "synthetic\n", "README.md": "# SDK\n"})
        subprocess.run(["git", "-C", str(root), "rm", "--cached", "-f", "--", ".env"],
                       check=True, env=env, capture_output=True)
        self.assertEqual(self.check(root, env, True).returncode, 0)

    def test_filename_with_newline_is_not_split_into_allowed_paths(self):
        root, env = self.fixture({"captures/fixture\nREADME.md": "synthetic\n"})
        result = self.check(root, env)
        self.assertEqual(result.returncode, 1)
        self.assertIn("captures", result.stderr)

    def test_readonly_and_invalid_usage(self):
        root, env = self.fixture({"README.md": "# SDK\n"})
        before = (root / ".git/index").read_bytes()
        for staged in (False, True):
            self.assertEqual(self.check(root, env, staged).returncode, 0)
        self.assertEqual((root / ".git/index").read_bytes(), before)
        for arguments in (("--unknown",), ("--staged", "extra")):
            result = subprocess.run(["bash", str(SCRIPT), *arguments], cwd=root, env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 64)


if __name__ == "__main__":
    unittest.main()
