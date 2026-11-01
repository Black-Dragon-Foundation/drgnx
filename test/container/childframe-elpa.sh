#!/bin/sh
# Unpack the pinned child-frame packages (childframe-packages.eld, beside this script: NAME VERSION :archive gnu|melpa
# :sha256 of the archive file) into DIR/NAME-VERSION, each tarball checked against its sha256 before it is unpacked.
# Run at image build time by Containerfile.gui, which bakes DIR (/opt/childframe-elpa) into the GUI test image; the
# tests then read it with DRGNX_CHILDFRAME_ELPA and never reach the archives.  Usage: childframe-elpa.sh DIR
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dir=${1:?usage: childframe-elpa.sh DIR}
mkdir -p "$dir"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
grep -v '^[[:space:]]*;' "$here/childframe-packages.eld" | tr '\n' ' ' \
  | grep -oE '\([a-z0-9-]+ "[^"]+" :archive "[a-z]+" +:sha256 "[0-9a-f]{64}"\)' > "$work/pins"
[ -s "$work/pins" ] || { echo "childframe-elpa: no pins read from childframe-packages.eld" >&2; exit 1; }
n=0
while IFS= read -r pin; do
  name=$(printf '%s' "$pin" | sed -E 's/^\(([a-z0-9-]+) .*/\1/')
  version=$(printf '%s' "$pin" | sed -E 's/^\([a-z0-9-]+ "([^"]+)".*/\1/')
  archive=$(printf '%s' "$pin" | sed -E 's/.*:archive "([a-z]+)".*/\1/')
  sha=$(printf '%s' "$pin" | sed -E 's/.*:sha256 "([0-9a-f]{64})".*/\1/')
  case $archive in
    gnu) host=elpa.gnu.org ;;
    melpa) host=melpa.org ;;
    *) echo "childframe-elpa: $name: unknown archive $archive" >&2; exit 1 ;;
  esac
  curl -fsSL --retry 3 -o "$work/$name.tar" "https://$host/packages/$name-$version.tar"
  echo "$sha  $work/$name.tar" | sha256sum -c - >/dev/null \
    || { echo "childframe-elpa: $name-$version does not match its pin (the archive moved on: bump the pin)" >&2; exit 1; }
  tar -xf "$work/$name.tar" -C "$dir"
  [ -d "$dir/$name-$version" ] || { echo "childframe-elpa: $name-$version.tar holds no $name-$version/" >&2; exit 1; }
  n=$((n + 1))
done < "$work/pins"
echo "childframe-elpa: $n packages in $dir"
