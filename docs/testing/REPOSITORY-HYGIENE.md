# Repository hygiene

Run `scripts/check-repository-hygiene.sh` before proposing a public change.
Use `--staged` for a local pre-commit check. Both modes read files and Git
metadata without changing the working tree or index. The staged mode checks
added or changed path names and scans indexed text, so repairing only the
working copy cannot hide a private value already staged for a commit.

Keep private captures, signing files, credentials, environment files, generated
build output, personal tool state and local checkout configuration outside the
tracked repository. Use the existing ignored `atlas/.local/` directory for
machine-local Atlas configuration. Do not commit raw packet captures or signing
material as fixtures. The check rejects their paths even inside test, resource
or Atlas directories.

Reviewed synthetic data in `Fixtures/`, licensed product resources, existing
reference images, generated-app templates, compact Atlas snapshots and shared
`.claude/skills/` instructions remain valid repository content. The exceptions
are limited to `.env.example` placeholder files and synthetic `.cube` files in
`Fixtures/` or `Tests/`. These files still receive the text-content check;
there is no blanket exemption for tests, resources or Atlas.

Text must not contain developer home-directory paths or private key blocks.
Assemble a synthetic home-path prefix from literals when a privacy regression
needs that exact input. This preserves the tested runtime value while avoiding
a path-specific allowlist. Failure output names files without printing their
contents. This check complements the secret scanner; it is not a replacement
for credential detection or review of newly added binary resources.

The standard-library regression suite is included in the existing Atlas test
command:

```sh
python3 -m unittest discover -s atlas/tests -p test_hygiene.py
```

See [the agent guide](../../AGENTS.md) for source ownership and verification,
and [Atlas maintenance](../../atlas/docs/MAINTENANCE.md) for local configuration.
