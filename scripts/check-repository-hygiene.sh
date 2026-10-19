#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: scripts/check-repository-hygiene.sh [--staged]" >&2
  exit 64
}
mode="tracked"
if [[ $# -eq 1 && "$1" == "--staged" ]]; then
  mode="staged"
elif [[ $# -ne 0 ]]; then
  usage
fi
cd "$(git --no-optional-locks rev-parse --show-toplevel)"

is_forbidden_path() {
  local path="$1"
  case "$path" in
    .env.example|*/.env.example|Fixtures/*.cube|Tests/*.cube)
      return 1
      ;;
  esac
  case "$path" in
    vendor|vendor/*|ref|ref/*|captures|captures/*|.local|.local/*|.codex|.codex/*|images|images/*)
      return 0
      ;;
    */captures/*|*/.local/*|*/.codex/*)
      return 0
      ;;
    .build|.build/*|*/.build/*|build|build/*|*/build/*|DerivedData|DerivedData/*|*/DerivedData/*)
      return 0
      ;;
    .gradle|.gradle/*|*/.gradle/*|.kotlin|.kotlin/*|*/.kotlin/*|.cxx|.cxx/*|*/.cxx/*)
      return 0
      ;;
    __pycache__|*/__pycache__/*|*.pyc|.planning|.planning/*|STATUS.md|OVERNIGHT.md)
      return 0
      ;;
    .env|.env.*|*/.env|*/.env.*|.envrc|*/.envrc|secrets.*|*/secrets.*|*.secret)
      return 0
      ;;
    *.pem|*.key|*.p12|*.pfx|*.keystore|*.jks|*.cer|*.der|*.certSigningRequest)
      return 0
      ;;
    *.mobileprovision|*.provisionprofile|*.pcap|*.pcapng|*.btsnoop|*.cube|*.psd|*.psb)
      return 0
      ;;
    google-services.json|*/google-services.json|GoogleService-Info.plist|*/GoogleService-Info.plist)
      return 0
      ;;
    *credentials*.json|*service-account*.json|*.local.xcconfig|local.properties|*/local.properties)
      return 0
      ;;
    .claude/settings.local.json|.claude/*.log|.claude/worktrees/*|.claude/preserved-edits/*)
      return 0
      ;;
    .vercel/*|*/.vercel/*|.cursor/*|.windsurf/*|.windsurfrules|.gemini/*|GEMINI.md|.aider*)
      return 0
      ;;
    .cline/*|.clinerules*|.roo/*|.rooignore|.roomodes|.roorules*|.kilo/*|.kilocode/*|.kilocodeignore|.kilocodemodes)
      return 0
      ;;
    .continue/*|.opencode/*|opencode.json|.github/copilot-instructions.md|.github/instructions/*|.github/prompts/*)
      return 0
      ;;
    .DS_Store|*/.DS_Store|*/xcuserdata/*|*.xcuserstate)
      return 0
      ;;
  esac
  return 1
}

list_paths() {
  if [[ "$mode" == "staged" ]]; then
    git --no-optional-locks diff --cached --name-only --diff-filter=ACMR -z
  else
    git --no-optional-locks ls-files -z
  fi
}
violations=()
while IFS= read -r -d '' path; do
  if is_forbidden_path "$path"; then violations+=("$path"); fi
done < <(list_paths)
if (( ${#violations[@]} > 0 )); then
  echo "Repository hygiene check failed. These files must remain local:" >&2
  printf '  %q\n' "${violations[@]}" >&2
  exit 1
fi

# Filename-only diagnostics avoid printing credentials or private captured text.
mac_home='/''Users/'
linux_home='/''home/'
private_key='-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----'
content_pattern="${mac_home}[^[:space:]]+|${linux_home}[^[:space:]]+|${private_key}"
content_violations=()
scan_content() {
  if [[ "$mode" == "staged" ]]; then
    git --no-optional-locks grep --cached -I -E "$@" -e "$content_pattern" -- .
  else
    git --no-optional-locks grep -I -E "$@" -e "$content_pattern" -- .
  fi
}
if scan_content -q; then
  while IFS= read -r -d '' path; do content_violations+=("$path"); done < <(scan_content -l -z)
elif [[ "$?" -ne 1 ]]; then
  echo "Repository hygiene check failed. Cannot inspect tracked text." >&2
  exit 2
fi
if (( ${#content_violations[@]} > 0 )); then
  echo "Repository hygiene check failed. Private key data or machine-specific paths found in:" >&2
  printf '  %q\n' "${content_violations[@]}" >&2
  exit 1
fi

echo "Repository hygiene check passed (${mode} files)."
