#!/usr/bin/env bash
# Self-test for check-async-closure-defaults.sh: flags a literal default, passes the safe forms.
set -euo pipefail
cd "$(git --no-optional-locks rev-parse --show-toplevel)"
dir="$(mktemp -d "${TMPDIR:-/tmp}/async-defaults.XXXXXX")"
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/bad" "$dir/good"
cat > "$dir/bad/Bad.swift" <<'SWIFT'
public func run(
    sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
) {}
SWIFT
cat > "$dir/good/Good.swift" <<'SWIFT'
public func run(
    sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:),
    progress: (@Sendable (Double) async -> Void)? = nil,
    log: @escaping (String) -> Void = { _ in },
    open: @escaping (URL) async -> Bool, changed: @escaping (String?) -> Void = { _ in }
) {}
final class Model {
    @ObservationIgnored private var wait: @MainActor (Duration) async -> Void = { _ in }
}
SWIFT
if scripts/check-async-closure-defaults.sh "$dir/bad" >/dev/null 2>&1; then
  echo "expected the async closure-literal default to be flagged" >&2; exit 1
fi
scripts/check-async-closure-defaults.sh "$dir/good" >/dev/null
echo "check-async-closure-defaults self-test passed."
