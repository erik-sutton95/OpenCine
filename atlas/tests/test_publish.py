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
        req = publish.LIBRARY_REQUIREMENT.format(v="0.1.0")
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
        self.assertTrue(out.startswith("# Shared OpenCine packages at their released tags (0.1.0)."))
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
        self.assertIn("      # Shared OpenCine packages at the released tags in opencine-pins.txt", android)
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
    """Atlas, a Core package, a library on Core by path and an app branch on both, published to
    bare repositories behind a file:// base."""

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
        for name in ("atlas", "Core", "Lib", "App"):
            subprocess.run(["git", "init", "-q", "--bare", str(self.remote / name)], check=True)
        self.marker = self.remote / "app-verify-ok"  # under /tmp: the release record must hold no private path
        core = make_repo(self.ws / "Core", {"Package.swift": 'let package = Package(name: "Core", targets: [])\n'})
        lib = make_repo(self.ws / "Lib", {
            "Package.swift": ('let package = Package(name: "Lib",\n    dependencies: [\n'
                              '        // Sibling checkout until Core is published.\n        .package(path: "../Core"),\n    ])\n'),
            "opencine-pins.txt": f"# pins\nCore {core}\n",
            "scripts/checkout-opencine.sh": "base=${1:-https://github.com/example}\n",
            ".github/workflows/ci.yml": WORKFLOW.replace("OpenCineCore", "Core"),
        })
        make_repo(self.ws / "App", {"README.md": "app\n"}, url="https://github.com/example/App")
        sh(self.ws / "App", "config", "remote.origin.pushurl", "file:///nonexistent/push-disabled")
        sh(self.ws / "App", "update-ref", "refs/remotes/origin/main", "HEAD")
        sh(self.ws / "App", "checkout", "-q", "-b", "opencine/integration")
        app = commit(self.ws / "App", {
            "Package.swift": 'let package = Package(name: "App",\n    dependencies: [.package(path: "../Core"), .package(path: "../Lib")])\n',
            "ios/project.yml": "packages:\n  Lib:\n    path: ../../Lib\ntargets: {}\n",
            "opencine-pins.txt": f"Core {core}\nLib {lib}\n",
            "scripts/checkout-opencine.sh": "base=${1:-https://github.com/example}\n",
        }, "integration")
        evidence = lambda sha: {"status": "passed", "commit": sha, "where": "fixture"}  # noqa: E731
        self.release = {
            "version": "0.1.0",
            "decisions": {"owner": "example", "visibility": "public", "android": "sibling-pins", "author_email": "t@example.invalid"},
            "atlas": {"repo": "atlas", "branch": "main", "description": "atlas"},
            "packages": [
                {"repo": "core", "branch": "main", "commit": core, "verify": ["test -f Package.swift"], "evidence": evidence(core)},
                {"repo": "lib", "branch": "main", "commit": lib, "evidence": evidence(lib),
                 "verify": ["grep -q 'upToNextMinor(from: \"0.1.0\")' Package.swift", "test ! -e opencine-pins.txt"]},
            ],
            "apps": [{"repo": "app", "branch": "opencine/integration", "commit": app, "evidence": evidence(app),
                      "resolve": ["true"], "lockfiles": [], "checklist": "docs/CHECKLIST.md", "work_packages": ["UI-01"],
                      "verify": ["grep -q 'exact: \"0.1.0\"' Package.swift", f"test -e {self.marker}"]}],
        }
        lib_edge = {"to": "core", "kind": "library", "status": "candidate", "confidence": "confirmed", "platforms": ["apple"],
                    "evidence": {"path": "Package.swift", "source_commit": lib}}
        write_registry(self.root, [
            meta("atlas", "atlas", "atlas"),
            meta("core", "core", "Core", status="candidate", refs=[{"name": "main", "commit": core, "role": "baseline"}]),
            meta("lib", "vendor", "Lib", status="candidate", refs=[{"name": "main", "commit": lib, "role": "baseline"}], edges=[lib_edge]),
            meta("app", "app", "App", url="https://github.com/example/App", refs=[{"name": "main", "commit": sh(self.ws / "App", "rev-parse", "main"), "role": "baseline"}]),
        ])
        (self.root / "compat").mkdir()
        (self.root / "compat" / "release-0.1.0.json").write_text(json.dumps(self.release, indent=2) + "\n")
        (self.root / ".gitignore").write_text(".local/\n")
        make_repo(self.root, {})

    def publish(self, *extra):
        return run_publish("--remote-base", self.base, "--owner", "example", *extra)

    def test_dry_run_writes_nothing(self):
        before = tree_digest(self.ws, self.remote)
        code, out = self.publish()
        self.assertEqual(code, 0, out)
        self.assertEqual(tree_digest(self.ws, self.remote), before)
        self.assertIn("would  take released packages by URL", out)
        self.assertIn(f'+        .package(url: "{self.base}/Core", .upToNextMinor(from: "0.1.0")),', out)
        self.assertIn("delete opencine-pins.txt", out)
        self.assertIn("<Core 0.1.0 tag commit>", out)  # app pins preview before any tag exists

    def test_publish_resume_and_idempotence(self):
        code, out = self.publish("--execute", "--open-prs")
        self.assertEqual(code, 1, out)  # the app verify marker is missing: stops after the packages
        self.assertIn("STOPPED App: `test -e", out)
        state = json.loads((self.root / ".local" / "publish-state.json").read_text())["steps"]
        self.assertIn("push:Lib", state)
        self.assertNotIn("app-verify:App", state)
        tag = sh(self.remote / "Lib", "rev-parse", "0.1.0^{commit}")
        lib_commits = sh(self.ws / "Lib", "rev-list", "--count", "main")

        self.marker.write_text("ok\n")
        code, out = self.publish("--execute", "--open-prs")
        self.assertEqual(code, 0, out)
        self.assertIn("done   tag:Lib", out)
        self.assertEqual(sh(self.remote / "Lib", "rev-parse", "0.1.0^{commit}"), tag)
        self.assertEqual(sh(self.ws / "Lib", "rev-list", "--count", "main"), lib_commits)

        lib_manifest = sh(self.remote / "Lib", "show", "0.1.0:Package.swift")
        self.assertIn(f'.package(url: "{self.base}/Core", .upToNextMinor(from: "0.1.0"))', lib_manifest)
        self.assertNotIn("Sibling", lib_manifest)
        self.assertNotIn("checkout-opencine", sh(self.remote / "Lib", "show", "0.1.0:.github/workflows/ci.yml"))
        self.assertEqual(sh(self.remote / "Core", "cat-file", "-t", "0.1.0"), "tag")  # annotated
        branch = "refs/heads/opencine/integration"
        self.assertIn(f'.package(url: "{self.base}/Lib", exact: "0.1.0")', sh(self.remote / "App", "show", f"{branch}:Package.swift"))
        self.assertIn(f"url: {self.base}/Lib\n    exactVersion: 0.1.0", sh(self.remote / "App", "show", f"{branch}:ios/project.yml"))
        pins = sh(self.remote / "App", "show", f"{branch}:opencine-pins.txt")
        self.assertIn(f"Lib {tag}", pins)
        self.assertIn(f"base=${{1:-{self.base}}}", sh(self.remote / "App", "show", f"{branch}:scripts/checkout-opencine.sh"))
        body = (self.root / ".local" / "publish" / "App-pr.md").read_text()
        self.assertTrue(body.rstrip().endswith(publish.FOOTER))
        self.assertNotIn(chr(0x2014), body)

        lib_meta = json.loads(sh(self.remote / "atlas", "show", "main:repos/lib/meta.json"))
        self.assertEqual(lib_meta["repository"]["url"], f"{self.base}/Lib")
        self.assertEqual(lib_meta["status"], "active")
        self.assertEqual(lib_meta["edges"][0]["status"], "live")
        app_meta = json.loads((self.root / "repos" / "app" / "meta.json").read_text())
        self.assertIn({"name": "opencine/integration", "commit": sh(self.remote / "App", "rev-parse", branch), "role": "candidate"}, app_meta["refs"])
        self.assertIn("| Lib | 0.1.0 exact |", (self.root / "compat" / "VERSIONS.md").read_text())

        before = tree_digest(self.ws, self.remote)
        code, out = self.publish("--execute", "--open-prs")
        self.assertEqual(code, 0, out)
        self.assertNotIn("run    ", out)
        self.assertEqual(tree_digest(self.ws, self.remote), before)

    def test_prs_later_make_edges_live(self):
        self.marker.write_text("ok\n")
        code, out = self.publish("--execute")
        self.assertEqual(code, 0, out)
        self.assertIn("skip   pull request", out)
        lib = json.loads((self.root / "repos" / "lib" / "meta.json").read_text())
        self.assertEqual((lib["status"], lib["edges"][0]["status"]), ("candidate", "candidate"))
        self.assertEqual(lib["repository"]["url"], f"{self.base}/Lib")
        code, out = self.publish("--execute", "--open-prs")
        self.assertEqual(code, 0, out)
        lib = json.loads((self.root / "repos" / "lib" / "meta.json").read_text())
        self.assertEqual((lib["status"], lib["edges"][0]["status"]), ("active", "live"))

    def test_preflight_blocks(self):
        rel = self.root / "compat" / "release-0.1.0.json"
        self.release["decisions"]["owner"] = None
        rel.write_text(json.dumps(self.release, indent=2) + "\n")
        sh(self.root, "commit", "-q", "-am", "undecided")
        (self.ws / "Lib" / "stray.txt").write_text("x\n")
        code, out = self.publish("--execute")
        self.assertEqual(code, 1)
        self.assertIn("decision not recorded: owner", out)
        self.assertIn("Lib: uncommitted changes", out)
        self.assertFalse((self.root / ".local" / "publish-state.json").exists())

    def test_author_emails_block_and_rewrite(self):
        sh(self.ws / "Lib", "commit", "-q", "--allow-empty", "-m", "work email",
           "--author", "W <w@work.example>")
        code, out = run_publish("record", "lib", "--evidence", "fixture rerun")
        self.assertEqual(code, 0, out)
        code, out = self.publish()
        self.assertEqual(code, 1)
        self.assertIn("w@work.example", out)
        code, out = run_publish("rewrite-authors", "--execute")
        self.assertEqual(code, 0, out)
        self.assertNotIn("w@work.example", sh(self.ws / "Lib", "log", "--format=%ae"))
        code, out = self.publish()
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main()
