#!/usr/bin/env bash
# End-to-end install test, run as root inside a fresh distribution container by `drgnx test --install`.
# Bash, not Emacs Lisp: there is no Emacs here yet, getting one is what is being tested.
# A snapshot of the drgnx working tree is mounted read-only at /src, with /src/drgnx.bundle to clone
# from (DRGNX_INSTALL_REPO). The installer runs as an ordinary user with sudo, the way people run it.
set -euo pipefail

step() { printf '\n=== %s\n' "$*"; }
fail() { printf 'E2E FAIL: %s\n' "$*"; exit 1; }

. /etc/os-release
step "prepare $PRETTY_NAME: sudo and a user"
case "$ID" in
  fedora) dnf -y -q install sudo >/dev/null ;;
  debian|ubuntu) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo >/dev/null ;;
  arch) pacman -Syu --noconfirm --needed sudo >/dev/null ;;
  *) fail "no preparation recipe for $ID" ;;
esac
useradd -m tester
echo 'tester ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/tester
home="$(getent passwd tester | cut -d: -f6)"

as_tester() { sudo -u tester -H env PATH="$home/.local/bin:/usr/local/bin:/usr/bin:/bin" \
                 DRGNX_INSTALL_REPO=/src/drgnx.bundle "$@"; }

step "install.sh --yes"
as_tester bash /src/install.sh --yes || fail "install.sh exited $?"
[[ -d "$home/.local/share/drgnx/drgnx/.git" ]] || fail "drgnx was not cloned"

step "drgnx doctor"
out="$(as_tester drgnx doctor)" || { printf '%s\n' "$out"; fail "the doctor reports a failure"; }
printf '%s\n' "$out"
grep -q '^OK    emacs-version ' <<<"$out" || fail "emacs-version is not ok"
grep -q '^OK    native-compilation ' <<<"$out" || fail "native compilation is not ok"
grep -q '^OK    gui ' <<<"$out" || fail "not a graphical build"
grep -q '^OK    tree-sitter ' <<<"$out" || fail "no tree-sitter"

step "second run is a no-op"
rc=0; out="$(as_tester bash /src/install.sh --yes)" || rc=$?
((rc == 0)) || { printf '%s\n' "$out"; fail "second run exited $rc"; }
printf '%s\n' "$out"
grep -q 'keep the installed Emacs' <<<"$out" || fail "second run did not keep the installed Emacs"
grep -q 'git pull --ff-only' <<<"$out" || fail "second run did not update the checkout"
! grep -q '^As root:' <<<"$out" || fail "second run ran a root step"

step "--dry-run changes nothing"
touch /tmp/before-dry-run
sleep 1
as_tester bash /src/install.sh --dry-run >/dev/null || fail "--dry-run exited $?"
changed="$(find "$home" /usr/local /etc -newer /tmp/before-dry-run -print 2>/dev/null)"
[[ -z "$changed" ]] || fail "--dry-run changed: $changed"

step "E2E OK ($PRETTY_NAME)"
