"""tools/publish.py: manifest rewriting, dry run, end-to-end publish to file:// remotes,
idempotence and resume. No network, no gh, no SwiftPM: fixture verify commands are shell checks."""
import contextlib
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from support import AtlasCase, commit, make_repo, meta, sh, tree_digest, write_registry

import manifests  # noqa: E402
import publish  # noqa: E402

URLS = {"OpenCineCore": "https://github.com/o/OpenCineCore", "OpenCineDJI": "https://github.com/o/OpenCineDJI"}

DJI_SWIFT = '''\
// swift-tools-version: 6.0
import PackageDescription

// DJI integration for OpenCine apps. Foundation plus OpenCineCore.
let package = Package(
    name: "OpenCineDJI",
    dependencies: [
        // Sibling checkout pinned in opencine-pins.txt until OpenCineCore is published.
        .package(path: "../OpenCineCore"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(path: "../NotReleased"),
    ],
    targets: []
)
'''

PROJECT_YML = '''\
name: OpenPocketCine
packages:
  Sentry:
    url: https://github.com/getsentry/sentry-cocoa
    exactVersion: 9.24.0
  OpenPocketViewCore:
    path: ..
  # Candidate shared contracts (OpenCine plan CORE-02) and portable media math (OpenCineMedia,
  # re-exported by OpenPocketViewCore), a sibling checkout of OpenCineCore. One package identity:
  # Package.swift's ../OpenCineCore is the same directory. Swap to the published URL + exact
  # version when the package has a remote. The app and tests call both products directly.
  OpenCineCore:
    path: ../../OpenCineCore
  # DJI protocol, wire and session code (OpenCine plan VENDOR-01), re-exported by
  # OpenPocketViewCore. Same directory as Package.swift's ../OpenCineDJI. Listed here because
  # Xcode links a re-exported package product only into targets that name it.
  OpenCineDJI:
    path: ../../OpenCineDJI

targets:
  OpenPocketCine:
    sources:
      - path: OpenPocketCine
'''

PBXPROJ = '''\
		objects = {
			packageReferences = (
				C1 /* XCRemoteSwiftPackageReference "ZIPFoundation" */,
				OCC1 /* XCLocalSwiftPackageReference "../../OpenCineCore" */,
				OZC1 /* XCLocalSwiftPackageReference ".." */,
			);
/* Begin XCLocalSwiftPackageReference section */
		OCC1 /* XCLocalSwiftPackageReference "../../OpenCineCore" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = ../../OpenCineCore;
		};
		OZC1 /* XCLocalSwiftPackageReference ".." */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = ..;
		};
/* End XCLocalSwiftPackageReference section */

/* Begin XCRemoteSwiftPackageReference section */
		C1 /* XCRemoteSwiftPackageReference "ZIPFoundation" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/weichsel/ZIPFoundation.git";
			requirement = {
				kind = upToNextMajorVersion;
				minimumVersion = 0.9.0;
			};
		};
/* End XCRemoteSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		OCC2 /* OpenCineCore */ = {
			isa = XCSwiftPackageProductDependency;
			package = OCC1 /* XCLocalSwiftPackageReference "../../OpenCineCore" */;
			productName = OpenCineCore;
		};
/* End XCSwiftPackageProductDependency section */
'''

WORKFLOW = '''\
jobs:
  test:
    name: Swift
    steps:
      - uses: actions/checkout@v7
      # OpenCineCore is a sibling checkout at ../OpenCineCore, pinned by SHA in
      # opencine-pins.txt. Works only once the OpenCineCore remote exists.
      - name: Check out pinned OpenCineCore
        run: scripts/checkout-opencine.sh
      - name: Test
        run: swift test

  android:
    name: Android
    steps:
      # Same pinned ../OpenCineCore as the Swift job.
      - name: Check out pinned OpenCineCore
        run: scripts/checkout-opencine.sh
      - name: Test
        working-directory: Android
        run: ./gradlew test
'''

POST_CLONE = '''\
#!/bin/sh
# Xcode Cloud: generate the project.
set -eu
fi
# Candidate (OpenCine UI-01): Package.swift takes ../OpenCineUI pinned by SHA in
# opencine-pins.txt. Delete when the app pins them by url + version.
step "check out pinned OpenCine packages next to the repository"
scripts/checkout-opencine.sh
step "xcodegen generate"
'''


class Rewriters(unittest.TestCase):
    def test_package_swift_library_range_and_comments(self):
        req = '.upToNextMinor(from: "0.1.0")'  # the rewriter takes any requirement
        out = publish.rewrite_package_swift(DJI_SWIFT, URLS, req)
        self.assertIn('.package(url: "https://github.com/o/OpenCineCore", .upToNextMinor(from: "0.1.0")),', out)
        self.assertIn('.package(path: "../NotReleased")', out)  # not a released package: untouched
        self.assertIn("swift-crypto.git", out)
        self.assertNotIn("Sibling checkout", out)
        self.assertIn("// DJI integration for OpenCine apps.", out)  # unrelated comments keep their lines
        self.assertTrue(out.startswith("// swift-tools-version: 6.0\n"))
        self.assertEqual(publish.rewrite_package_swift(out, URLS, req), out)  # idempotent
        deps = manifests.read_package_swift("Package.swift", out)["deps"]
        self.assertIn({"type": "url", "value": URLS["OpenCineCore"]}, [{"type": d["type"], "value": d["value"]} for d in deps])

    def test_package_swift_app_exact(self):
        text = '    dependencies: [\n        // DJI wire code. Sibling checkout until OpenCineDJI is published.\n        .package(path: "../OpenCineDJI"),\n    ],\n'
        out = publish.rewrite_package_swift(text, URLS, 'exact: "0.1.0"')
        self.assertIn('.package(url: "https://github.com/o/OpenCineDJI", exact: "0.1.0"),', out)
        self.assertIn("        // DJI wire code.\n", out)

    def test_paragraphs_and_clauses(self):
        text = ("// Developer-only harness.\n//\n// Every package is a sibling path checkout pinned in opencine-pins.txt, so SwiftPM\n"
                "// resolves one copy.\nlet x = 1\n# Lab CLI for verifying Insta360Protocol (sibling OpenCineInsta360 package) against a Luna.\n")
        out = publish.clean_comments(text, "//")
        self.assertEqual(out.splitlines()[:2], ["// Developer-only harness.", "let x = 1"])
        self.assertIn("# Lab CLI for verifying Insta360Protocol against a Luna.", publish.clean_comments(text, "#"))

    def test_tools_version_line_is_never_a_comment(self):
        text = ('// swift-tools-version: 5.9\n// Lab CLI for verifying Insta360Protocol (sibling OpenCineInsta360 package) against a Luna.\n'
                'import PackageDescription\nlet package = Package(dependencies: [.package(path: "../../../OpenCineCore")])\n')
        out = publish.rewrite_package_swift(text, URLS, 'exact: "0.1.0"')
        self.assertTrue(out.startswith("// swift-tools-version: 5.9\n// Lab CLI for verifying Insta360Protocol against a Luna.\n"), out)

    def test_project_yml(self):
        out = publish.rewrite_project_yml(PROJECT_YML, URLS, "0.1.0")
        self.assertIn("  OpenCineCore:\n    url: https://github.com/o/OpenCineCore\n    exactVersion: 0.1.0\n", out)
        self.assertIn("  OpenCineDJI:\n    url: https://github.com/o/OpenCineDJI\n    exactVersion: 0.1.0\n", out)
        self.assertIn("    path: ..\n", out)  # the app's own root package
        self.assertIn("      - path: OpenPocketCine\n", out)  # target sources are not packages
        self.assertIn("Shared contracts (OpenCine plan CORE-02) and portable media math", out)
        self.assertIn("Listed here because", out)
        self.assertNotIn("sibling", out.lower())
        self.assertNotIn("../../OpenCine", out)
        self.assertEqual(publish.rewrite_project_yml(out, URLS, "0.1.0"), out)
        # The app's own lockfile check (tools/ios-package-resolved-check.py) reads this shape.
        import re
        found = re.findall(r"(?m)^  ([A-Za-z0-9_]+):\n    url: (\S+)\n    exactVersion: (\S+)\s*$", out)
        self.assertEqual([f[0] for f in found], ["Sentry", "OpenCineCore", "OpenCineDJI"])

    def test_pbxproj(self):
        out = publish.rewrite_pbxproj(PBXPROJ, URLS, "0.1.0")
        self.assertNotIn('XCLocalSwiftPackageReference "../../OpenCineCore"', out)
        self.assertIn('OCC1 /* XCRemoteSwiftPackageReference "OpenCineCore" */,', out)
        self.assertIn('package = OCC1 /* XCRemoteSwiftPackageReference "OpenCineCore" */;', out)
        self.assertIn('repositoryURL = "https://github.com/o/OpenCineCore";\n\t\t\trequirement = {\n\t\t\t\tkind = exactVersion;\n\t\t\t\tversion = 0.1.0;', out)
        self.assertIn("relativePath = ..;", out)
        self.assertEqual(publish.rewrite_pbxproj(out, URLS, "0.1.0"), out)
        parsed = manifests.read_pbxproj("project.pbxproj", out)
        self.assertEqual(parsed["status"], "parsed")
        self.assertIn(URLS["OpenCineCore"], [d["value"] for d in parsed["deps"]])

    def test_pbxproj_without_remote_section(self):
        text = PBXPROJ.split("/* Begin XCRemoteSwiftPackageReference section */")[0] + PBXPROJ.split("/* End XCRemoteSwiftPackageReference section */\n\n")[1]
        out = publish.rewrite_pbxproj(text, URLS, "0.1.0")
        self.assertIn("/* Begin XCRemoteSwiftPackageReference section */\n\t\tOCC1", out)
        self.assertEqual(manifests.read_pbxproj("project.pbxproj", out)["status"], "parsed")

    def test_pins_and_checkout_script(self):
        out = publish.rewrite_pins("# old header\nOpenCineCore abc\nOther def\n", {"OpenCineCore": "f" * 40}, "0.1.0")
        self.assertTrue(out.startswith("# The OpenCine platform at its released tag (0.1.0)."))
        self.assertTrue(out.endswith(f"OpenCineCore {'f' * 40}\nOther def\n"))
        script = "# Usage: x [base-url]   (default https://github.com/erik-sutton95)\nbase=${1:-https://github.com/erik-sutton95}\n"
        self.assertIn("base=${1:-file:///tmp/r}", publish.rewrite_checkout_script(script, "file:///tmp/r"))
        self.assertEqual(publish.rewrite_checkout_script(script, "https://github.com/erik-sutton95"), script)

    def test_workflow_keep_for_android(self):
        out = publish.rewrite_workflow(WORKFLOW, keep_for_android=True)
        swift, android = out.split("  android:")
        self.assertNotIn("checkout-opencine", swift)
        self.assertNotIn("sibling checkout at", swift)
        self.assertIn("      - name: Test\n        run: swift test", swift)
        self.assertIn("      # The OpenCine platform at the released tag in opencine-pins.txt", android)
        self.assertIn("run: scripts/checkout-opencine.sh", android)
        self.assertNotIn("Same pinned", android)
        self.assertEqual(publish.rewrite_workflow(out, keep_for_android=True), out)

    def test_workflow_drop_everywhere(self):
        out = publish.rewrite_workflow(WORKFLOW, keep_for_android=False)
        self.assertNotIn("checkout-opencine", out)
        self.assertNotIn("\n\n\n", out)

    def test_post_clone(self):
        out = publish.drop_checkout_from_script(POST_CLONE)
        self.assertEqual(out, '#!/bin/sh\n# Xcode Cloud: generate the project.\nset -eu\nfi\nstep "xcodegen generate"\n')
        nikon = 'set -eu\n\n# Candidate: siblings.\n"$CI_PRIMARY_REPOSITORY_PATH/scripts/checkout-opencine.sh"\n\ncat > x\n'
        self.assertEqual(publish.drop_checkout_from_script(nikon), "set -eu\n\ncat > x\n")


def run_publish(*argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        code = publish.main(list(argv))
    return code, out.getvalue()


class EndToEnd(AtlasCase):
    """The platform repository (with the atlas inside it at atlas/) and an app branch that takes it
    by path, published to bare repositories behind a file:// base."""

    def setUp(self):
        super().setUp()
        ident = {"GIT_AUTHOR_NAME": "t", "GIT_COMMITTER_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                 "GIT_COMMITTER_EMAIL": "t@example.invalid", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        p = mock.patch.dict(os.environ, ident)
        p.start()
        self.addCleanup(p.stop)
        # Not resolved: on macOS a realpath under /private or /var/folders trips the atlas private-path check.
        self.remote = Path(tempfile.mkdtemp(dir="/tmp", prefix="publish-test-"))
        self.addCleanup(shutil.rmtree, self.remote, True)
        self.base = f"file://{self.remote}"
        for name in ("Platform", "App"):
            subprocess.run(["git", "init", "-q", "--bare", str(self.remote / name)], check=True)
        self.marker = self.remote / "app-verify-ok"  # under /tmp: the release record must hold no private path
        self.platform = self.ws / "Platform"
        self.root = self.platform / "atlas"
        p = mock.patch.dict(os.environ, {"OPENCAPTURE_ATLAS_ROOT": str(self.root)})
        p.start()
        self.addCleanup(p.stop)
        plat = make_repo(self.platform, {"Package.swift": 'let package = Package(name: "Platform", targets: [])\n'})
        make_repo(self.ws / "App", {"README.md": "app\n"}, url="https://github.com/example/App")
        sh(self.ws / "App", "config", "remote.origin.pushurl", "file:///nonexistent/push-disabled")
        sh(self.ws / "App", "update-ref", "refs/remotes/origin/main", "HEAD")
        sh(self.ws / "App", "checkout", "-q", "-b", "opencine/integration")
        app = commit(self.ws / "App", {
            "Package.swift": ('let package = Package(name: "App",\n    dependencies: [\n'
                              '        // Sibling checkout until Platform is published.\n        .package(path: "../Platform"),\n    ])\n'),
            "ios/project.yml": "packages:\n  Platform:\n    path: ../../Platform\ntargets: {}\n",
            "opencine-pins.txt": f"# pins\nPlatform {plat}\n",
            "scripts/checkout-opencine.sh": "base=${1:-https://github.com/example}\n",
            ".github/workflows/ci.yml": WORKFLOW.replace("OpenCineCore", "Platform"),
        }, "integration")
        evidence = lambda sha: {"status": "passed", "commit": sha, "where": "fixture"}  # noqa: E731
        self.release = {
            "version": "0.1.0",
            "decisions": {"owner": "example", "visibility": "public", "android": "sibling-pins", "author_email": "t@example.invalid"},
            "platform": {"repo": "platform", "branch": "main", "commit": plat, "evidence": evidence(plat),
                         "verify": ["test -f Package.swift", "test -f atlas/compat/release-0.1.0.json"]},
            "apps": [{"repo": "app", "branch": "opencine/integration", "commit": app, "evidence": evidence(app),
                      "resolve": ["true"], "lockfiles": [], "checklist": "docs/CHECKLIST.md", "work_packages": ["UI-01"],
                      "verify": ["grep -q 'exact: \"0.1.0\"' Package.swift", f"test -e {self.marker}"]}],
        }
        app_edge = {"to": "platform", "kind": "library", "status": "candidate", "confidence": "confirmed", "ref": "opencine/integration",
                    "platforms": ["apple"], "evidence": {"path": "Package.swift", "source_commit": app}}
        write_registry(self.root, [
            meta("platform", "platform", "Platform", status="candidate", refs=[{"name": "main", "commit": plat, "role": "baseline"}]),
            meta("app", "app", "App", url="https://github.com/example/App", edges=[app_edge],
                 refs=[{"name": "main", "commit": sh(self.ws / "App", "rev-parse", "main"), "role": "baseline"},
                       {"name": "opencine/integration", "commit": app, "role": "candidate"}]),
        ])
        (self.root / "compat").mkdir()
        (self.root / "compat" / "release-0.1.0.json").write_text(json.dumps(self.release, indent=2) + "\n")
        (self.root / ".gitignore").write_text(".local/\n")
        commit(self.platform, {}, "atlas")  # the record names the commit before the atlas: only atlas/ differs

    def publish(self, *extra):
        return run_publish("--remote-base", self.base, "--owner", "example", *extra)

    def test_dry_run_writes_nothing(self):
        before = tree_digest(self.ws, self.remote)
        code, out = self.publish()
        self.assertEqual(code, 0, out)
        self.assertEqual(tree_digest(self.ws, self.remote), before)
        self.assertIn("would  verify a clean clone of main", out)
        self.assertIn(f'+        .package(url: "{self.base}/Platform", exact: "0.1.0"),', out)
        self.assertIn("<Platform 0.1.0 tag commit>", out)  # app pins preview before the tag exists

    def test_publish_resume_and_idempotence(self):
        code, out = self.publish("--execute", "--open-prs")
        self.assertEqual(code, 1, out)  # the app verify marker is missing: stops after the platform
        self.assertIn("STOPPED App: `test -e", out)
        state = json.loads((self.root / ".local" / "publish-state.json").read_text())["steps"]
        self.assertIn("push:Platform", state)
        self.assertNotIn("app-verify:App", state)
        tag = sh(self.remote / "Platform", "rev-parse", "0.1.0^{commit}")
        self.assertEqual(tag, state["verify:Platform"]["commit"])

        self.marker.write_text("ok\n")
        code, out = self.publish("--execute", "--open-prs")
        self.assertEqual(code, 0, out)
        self.assertIn("done   tag:Platform", out)
        self.assertEqual(sh(self.remote / "Platform", "rev-parse", "0.1.0^{commit}"), tag)
        self.assertEqual(sh(self.remote / "Platform", "cat-file", "-t", "0.1.0"), "tag")  # annotated
        branch = "refs/heads/opencine/integration"
        manifest = sh(self.remote / "App", "show", f"{branch}:Package.swift")
        self.assertIn(f'.package(url: "{self.base}/Platform", exact: "0.1.0")', manifest)
        self.assertNotIn("Sibling", manifest)
        self.assertIn(f"url: {self.base}/Platform\n    exactVersion: 0.1.0", sh(self.remote / "App", "show", f"{branch}:ios/project.yml"))
        self.assertIn(f"Platform {tag}", sh(self.remote / "App", "show", f"{branch}:opencine-pins.txt"))
        self.assertIn(f"base=${{1:-{self.base}}}", sh(self.remote / "App", "show", f"{branch}:scripts/checkout-opencine.sh"))
        self.assertIn("checkout-opencine", sh(self.remote / "App", "show", f"{branch}:.github/workflows/ci.yml"))  # Android keeps it
        msg = sh(self.remote / "App", "log", "-1", "--format=%B", branch)
        self.assertIn(f"resolve Platform 0.1.0 from {self.base}", msg.replace("\n", " "))
        body = (self.root / ".local" / "publish" / "App-pr.md").read_text()
        self.assertTrue(body.rstrip().endswith(publish.FOOTER))
        self.assertIn(f"| Platform | 0.1.0 | `{tag[:12]}` |", body)
        self.assertNotIn(chr(0x2014), body)

        # The registry update is a commit on the platform's own main, after the tag.
        plat_meta = json.loads(sh(self.remote / "Platform", "show", "main:atlas/repos/platform/meta.json"))
        self.assertEqual(plat_meta["repository"]["url"], f"{self.base}/Platform")
        self.assertEqual(plat_meta["status"], "active")
        self.assertEqual(plat_meta["refs"], [{"name": "main", "commit": tag, "role": "baseline"}])
        app_meta = json.loads((self.root / "repos" / "app" / "meta.json").read_text())
        head = sh(self.remote / "App", "rev-parse", branch)
        self.assertIn({"name": "opencine/integration", "commit": head, "role": "candidate"}, app_meta["refs"])
        self.assertEqual(app_meta["edges"][0]["evidence"]["source_commit"], head)
        self.assertIn("| Platform | 0.1.0 exact |", (self.root / "compat" / "VERSIONS.md").read_text())
        self.assertNotEqual(sh(self.remote / "Platform", "rev-parse", "main"), tag)

        before = tree_digest(self.ws, self.remote)
        code, out = self.publish("--execute", "--open-prs")
        self.assertEqual(code, 0, out)
        self.assertNotIn("run    ", out)
        self.assertEqual(tree_digest(self.ws, self.remote), before)

    def test_prs_later_make_the_platform_active(self):
        self.marker.write_text("ok\n")
        code, out = self.publish("--execute")
        self.assertEqual(code, 0, out)
        self.assertIn("skip   pull request", out)
        m = json.loads((self.root / "repos" / "platform" / "meta.json").read_text())
        self.assertEqual((m["status"], m["repository"]["url"]), ("candidate", f"{self.base}/Platform"))
        code, out = self.publish("--execute", "--open-prs")
        self.assertEqual(code, 0, out)
        self.assertEqual(json.loads((self.root / "repos" / "platform" / "meta.json").read_text())["status"], "active")

    def test_preflight_blocks(self):
        rel = self.root / "compat" / "release-0.1.0.json"
        self.release["decisions"]["owner"] = None
        rel.write_text(json.dumps(self.release, indent=2) + "\n")
        sh(self.platform, "commit", "-q", "-am", "undecided")
        (self.platform / "stray.txt").write_text("x\n")
        code, out = self.publish("--execute")
        self.assertEqual(code, 1)
        self.assertIn("decision not recorded: owner", out)
        self.assertIn("Platform: uncommitted changes", out)
        self.assertFalse((self.root / ".local" / "publish-state.json").exists())

    def test_platform_may_move_only_under_atlas(self):
        commit(self.platform, {"atlas/notes.txt": "x\n"}, "atlas only")
        code, out = self.publish()
        self.assertEqual(code, 0, out)
        commit(self.platform, {"Sources/A.swift": "// code\n"}, "code")
        code, out = self.publish()
        self.assertEqual(code, 1)
        self.assertIn("Platform: main is at", out)
        code, out = run_publish("record", "platform", "--evidence", "fixture rerun")
        self.assertEqual(code, 0, out)
        code, out = self.publish()
        self.assertEqual(code, 0, out)

    def test_record_moves_registry_refs_and_versions(self):
        head = commit(self.ws / "App", {"opencine-pins.txt": "Platform bumped\n"}, "pin bump")
        code, out = run_publish("record", "app", "--evidence", "fixture rerun")
        self.assertEqual(code, 0, out)
        app = json.loads((self.root / "repos" / "app" / "meta.json").read_text())
        self.assertIn({"name": "opencine/integration", "commit": head, "role": "candidate"}, app["refs"])
        self.assertEqual(app["edges"][0]["evidence"]["source_commit"], head)
        self.assertIn(f"`opencine/integration` at `{head[:12]}`", (self.root / "compat" / "VERSIONS.md").read_text())
        self.assertEqual(sh(self.platform, "status", "--porcelain"), "")  # all three files committed

    def test_author_emails_block_and_rewrite(self):
        sh(self.platform, "commit", "-q", "--allow-empty", "-m", "work email", "--author", "W <w@work.example>")
        code, out = run_publish("record", "platform", "--evidence", "fixture rerun")
        self.assertEqual(code, 0, out)
        code, out = self.publish()
        self.assertEqual(code, 1)
        self.assertIn("w@work.example", out)
        code, out = run_publish("rewrite-authors", "--execute")
        self.assertEqual(code, 0, out)
        self.assertNotIn("w@work.example", sh(self.platform, "log", "--format=%ae"))
        code, out = self.publish()
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main()
