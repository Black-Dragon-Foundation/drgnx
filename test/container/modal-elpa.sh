#!/bin/sh
# Unpack the pinned packages the modal, kitty and Quick Open tests load (evil, goto-chg, evil-collection, kkp, vertico,
# compat, orderless) into DIR, from MELPA's or GNU ELPA's tarballs (the lock's :archive), each checked against the sha256 in etc/drgnx.lock.eld.  Usage: modal-elpa.sh DIR  (run it in a
# container: the tarballs are untrusted until the check passes, and only DIR is written).  Then run the tests with
# DRGNX_MODAL_ELPA=DIR and DRGNX_USER_ELPA=DIR (docs/develop/harness.md, "Modal tests").
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
dir=${1:?usage: modal-elpa.sh DIR}
mkdir -p "$dir"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for pkg in evil goto-chg evil-collection kkp vertico compat orderless; do
  block=$(grep -A3 "^[[:space:]]*($pkg :version" "$root/etc/drgnx.lock.eld")
  version=$(printf '%s' "$block" | grep -o ':version "[^"]*"' | head -1 | cut -d'"' -f2)
  archive=$(printf '%s' "$block" | grep -o ':archive "[^"]*"' | head -1 | cut -d'"' -f2)
  sha=$(printf '%s' "$block" | grep -o '"[0-9a-f]\{64\}"' | head -1 | tr -d '"')
  [ -n "$version" ] && [ -n "$sha" ] || { echo "modal-elpa: $pkg is not pinned in etc/drgnx.lock.eld" >&2; exit 1; }
  case "$archive" in
    melpa) host=https://melpa.org/packages ;;
    gnu) host=https://elpa.gnu.org/packages ;;
    *) echo "modal-elpa: $pkg is from the archive '$archive', which this script does not fetch" >&2; exit 1 ;;
  esac
  curl -fsSL --retry 3 -o "$work/$pkg.tar" "$host/$pkg-$version.tar"
  echo "$sha  $work/$pkg.tar" | sha256sum -c - >/dev/null || { echo "modal-elpa: $pkg-$version does not match its pin" >&2; exit 1; }
  tar -xf "$work/$pkg.tar" -C "$dir"
done
