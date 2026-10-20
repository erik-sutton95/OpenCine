#!/usr/bin/env bash
# Fails when a Swift parameter defaults to an async closure literal.
#
# A closure literal in a public (or @testable) default argument is compiled again into every
# client module. At -Onone those copies disagree with the library's on the async context size,
# and the linker can pair one copy's body with another's size, so the closure writes past its
# task allocation and the process aborts (swiftlang/swift#92017; hosted Z RunnerTests, Oct 2026).
# Default to a named function (`hostSleep(for:)`) or to `nil` resolved in the body instead.
set -euo pipefail
cd "$(git --no-optional-locks rev-parse --show-toplevel)"
roots=("$@")
[[ ${#roots[@]} -eq 0 ]] && roots=(Sources)
# A parameter: `name: <type with async> = {`, possibly split across lines. The type may not cross
# into the next `, name:` or contain `{`, `}` or `;`, so a function body or a stored property
# (`var`/`let`, which lives only in the library) never matches.
hits="$(find "${roots[@]}" -name '*.swift' -print0 | xargs -0 perl -0777 -ne '
  my $seg = qr/(?:(?!,\s*\w+\s*:)[^={};])*/;
  while (/(?:^|[,(])\s*((?:@\w+(?:\([^)]*\))?\s+)*(?:\w+\s+)?(\w+)\s*:$seg\basync\b$seg=\s*\{)/g) {
    next if $2 eq "var" || $2 eq "let";
    my $line = 1 + (substr($_, 0, $-[1]) =~ tr/\n//);
    (my $text = $1) =~ s/\s+/ /g;
    print "$ARGV:$line: $text\n";
  }
')"
if [[ -n "$hits" ]]; then
  printf '%s\n' "$hits" >&2
  echo "Async closure-literal default arguments found; default to a named function or nil (swiftlang/swift#92017)." >&2
  exit 1
fi
echo "No async closure-literal default arguments."
