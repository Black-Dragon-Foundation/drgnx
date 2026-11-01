#!/bin/sh
# Check out the pinned child-frame packages into DIR/NAME-VERSION (DIR must not exist yet).  childframe-packages.eld,
# beside this script, pins each package by its upstream git commit and the git tree hash of that commit: the commit is
# fetched, and both it and its tree must match before anything is unpacked, so no archive's compression or rebuild can
# change what is tested.  Run at image build time by Containerfile.gui, which bakes DIR (/opt/childframe-elpa) into
# the GUI test image; also `bin/drgnx childframe-elpa DIR`.  $DRGNX_CHILDFRAME_PINS names another pins file (the
# tests').  A package whose repository keeps extra files in extensions/ (corfu, vertico) has them put beside the rest,
# as the ELPA tarballs do.  No generated -autoloads.el or -pkg.el: the tests require the libraries.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dir=${1:?usage: childframe-elpa.sh DIR}
pins=${DRGNX_CHILDFRAME_PINS:-$here/childframe-packages.eld}
[ ! -e "$dir" ] || { echo "childframe-elpa: $dir exists already" >&2; exit 1; }
mkdir -p "$(dirname "$dir")"
work=$(mktemp -d "$(dirname "$dir")/.childframe.XXXXXX")
trap 'rm -rf "$work"' EXIT
grep -v '^[[:space:]]*;' "$pins" | tr '\n' ' ' \
  | grep -oE '\([a-z0-9-]+ "[^"]+" +:repo "[^"]+" +:commit "[0-9a-f]{40}" +:tree "[0-9a-f]{40}"\)' > "$work/pins"
[ -s "$work/pins" ] || { echo "childframe-elpa: no pins read from $pins" >&2; exit 1; }
n=0
while IFS= read -r pin; do
  name=$(printf '%s' "$pin" | sed -E 's/^\(([a-z0-9-]+) .*/\1/')
  version=$(printf '%s' "$pin" | sed -E 's/^\([a-z0-9-]+ "([^"]+)".*/\1/')
  repo=$(printf '%s' "$pin" | sed -E 's/.*:repo "([^"]+)".*/\1/')
  commit=$(printf '%s' "$pin" | sed -E 's/.*:commit "([0-9a-f]{40})".*/\1/')
  tree=$(printf '%s' "$pin" | sed -E 's/.*:tree "([0-9a-f]{40})".*/\1/')
  g="$work/git-$name"
  git init -q "$g"
  git -C "$g" fetch -q --depth 1 "$repo" "$commit" \
    || { echo "childframe-elpa: $name: cannot fetch $commit from $repo" >&2; exit 1; }
  [ "$(git -C "$g" rev-parse FETCH_HEAD)" = "$commit" ] \
    || { echo "childframe-elpa: $name: fetched a commit other than $commit" >&2; exit 1; }
  [ "$(git -C "$g" rev-parse 'FETCH_HEAD^{tree}')" = "$tree" ] \
    || { echo "childframe-elpa: $name-$version: the tree of $commit does not match its pin" >&2; exit 1; }
  mkdir -p "$work/out/$name-$version"
  git -C "$g" archive FETCH_HEAD | tar -x -C "$work/out/$name-$version"
  if [ -d "$work/out/$name-$version/extensions" ]; then
    cp "$work/out/$name-$version"/extensions/*.el "$work/out/$name-$version/"
  fi
  n=$((n + 1))
done < "$work/pins"
mv "$work/out" "$dir"
echo "childframe-elpa: $n packages in $dir"
