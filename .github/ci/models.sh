#!/usr/bin/env bash
# The pinned model files of models.txt into DIR/<id>/<file>, the layout the tests read from DRGNX_TEST_MODELS: a file
# already there under its sum is kept (a restored cache), any other is fetched from Hugging Face at its pinned revision
# and must match its sha256 before it takes its name.
#   models.sh DIR
# Exit 1 on a failed fetch or a wrong sum, 2 on a usage error.  bash 3.2-safe (macOS).  docs/develop/ci.md
set -eu -o pipefail
[ $# = 1 ] || { echo "usage: models.sh DIR" >&2; exit 2; }
dir=$1
list=$(cd "$(dirname "$0")" && pwd)/models.txt

sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

sed 's/#.*//' "$list" | awk 'NF' | while read -r id repo rev name sha; do
  f=$dir/$id/$name
  if [ -f "$f" ] && [ "$(sum "$f")" = "$sha" ]; then echo "models: $id/$name kept"; continue; fi
  mkdir -p "$(dirname "$f")"
  curl -fsSL -o "$f.part" "https://huggingface.co/$repo/resolve/$rev/$name"
  got=$(sum "$f.part")
  if [ "$got" != "$sha" ]; then
    echo "models: $id/$name has sha256 $got, not $sha" >&2; rm -f "$f.part"; exit 1
  fi
  mv -f "$f.part" "$f"
  echo "models: $id/$name fetched"
done
