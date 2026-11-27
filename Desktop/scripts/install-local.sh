#!/usr/bin/env bash
# Installs a built camera module into OpenCine's modules folder.
# Usage: install-local.sh <built module.app> <module.json>
set -euo pipefail
bundle="$1"
manifest="$2"
id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$manifest")"
name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["bundleName"])' "$manifest")"
target="$HOME/Library/Application Support/OpenCine/Modules/$id"
mkdir -p "$target"
rm -rf "${target:?}/$name"
ditto "$bundle" "$target/$name"
cp "$manifest" "$target/module.json"
echo "Installed $id at $target"
