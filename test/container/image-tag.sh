#!/usr/bin/env bash
# The tag of an image built from test/container: the first 16 hex digits of a sha256 over its Containerfile and every
# file its COPY and ADD lines take from the build context (this directory; a directory source counts each file in it).
# So an edit of anything the image is built from (nidhogg.sh with the Nidhogg pin, the child-frame pins, a build
# script) is a new tag, and an unchanged image keeps its tag; so is a change of the base image a `# base: NAME FILE`
# line names (test/container/base/).  `Test images` (.github/workflows/images.yml) publishes
# under it, the CI jobs look it up, and `bin/drgnx test --container` tags its local builds with it.
#   image-tag.sh test/container/Containerfile[.NAME]
# Prints the tag; exit 1 when a source is missing, 2 on a usage error.  bash 3.2-safe.  docs/develop/ci.md
set -eu -o pipefail
[ $# = 1 ] && [ -f "$1" ] || { echo "usage: image-tag.sh CONTAINERFILE" >&2; exit 2; }
file=$1
ctx=$(dirname "$file")

sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }   # of stdin

# the context sources of each COPY/ADD (continued lines joined, options and the destination left out); a COPY
# --from= takes from another stage, a URL from no file here
sources() {
  awk '
    { line = line $0 }
    /\\$/ { sub(/\\$/, " ", line); next }
    { sub(/^[ \t]+/, "", line); n = split(line, w, /[ \t]+/); line = ""
      op = toupper(w[1]); if (op != "COPY" && op != "ADD") next
      k = 0; from = 0
      for (i = 2; i <= n; i++) { if (w[i] ~ /^--from=/) from = 1; else if (w[i] !~ /^--/ && w[i] != "") a[++k] = w[i] }
      if (!from) for (i = 1; i < k; i++) if (a[i] !~ /:\/\//) print a[i] }' "$file"
}

# an image built on a base names it in a line `# base: NAME FILE` (FILE in this directory): the base's tag is part of
# this one, so a change to the base is a new tag for every image on it
base_file=$(awk '$1 == "#" && $2 == "base:" { print $4; exit }' "$file")

manifest() {
  sum < "$file" | cut -c1-64
  if [ -n "$base_file" ]; then
    [ -f "$ctx/$base_file" ] || { echo "image-tag.sh: $file names the base $base_file, which is not in $ctx" >&2; exit 1; }
    echo "base $(bash "$0" "$ctx/$base_file")"
  fi
  sources | while IFS= read -r src; do
    if [ -d "$ctx/$src" ]; then
      (cd "$ctx" && find "$src" -type f | LC_ALL=C sort | while IFS= read -r f; do echo "$(sum < "$f" | cut -c1-64)  $f"; done)
    elif [ -f "$ctx/$src" ]; then
      echo "$(sum < "$ctx/$src" | cut -c1-64)  $src"
    else
      echo "image-tag.sh: $file copies $src, which is not in $ctx" >&2; exit 1
    fi
  done
}
# a failed source fails the whole: never a tag of part of the inputs
tag=$(manifest | sum | cut -c1-16)
echo "$tag"
