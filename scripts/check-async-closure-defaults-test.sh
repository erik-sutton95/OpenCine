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
cat > "$dir/bad/Split.swift" <<'SWIFT'
public init(
    read:
        @escaping @MainActor (Int) async throws ->
        String = { _ in "" }
) {}
SWIFT
cat > "$dir/good/Good.swift" <<'SWIFT'
public func run(
    sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:),
    progress: (@Sendable (Double) async -> Void)? = nil,
    log: @escaping (String) -> Void = { _ in },
    open: @escaping (URL) async -> Bool, changed: @escaping (String?) -> Void = { _ in }
) {}
func body(x: Int) async {
    let y: Int = { 1 }()
}
final class Model {
    var first: () async -> Void = {}, second: () async -> Void = {}
    let third: (Int) async -> Int = { $0 }
    @ObservationIgnored private var wait: @MainActor (Duration) async -> Void = { _ in }
}
SWIFT
out="$(scripts/check-async-closure-defaults.sh "$dir/bad" 2>&1 || true)"
for file in Bad.swift Split.swift; do
  if ! grep -q "$file:" <<< "$out"; then
    echo "expected $file to be flagged; got: $out" >&2; exit 1
  fi
done
scripts/check-async-closure-defaults.sh "$dir/good" >/dev/null
echo "check-async-closure-defaults self-test passed."
