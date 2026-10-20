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

# Nidhogg: install.sh fetches the pinned tag from GitHub; `drgnx test --install' can point it at a local repository
# (DRGNX_INSTALL_NIDHOGG_REPO, mounted at /nidhogg-src) and the commit that tag is.
nidhogg_env=()
if [[ -n "${DRGNX_INSTALL_NIDHOGG_REPO:-}" ]]; then nidhogg_env+=("DRGNX_INSTALL_NIDHOGG_REPO=$DRGNX_INSTALL_NIDHOGG_REPO"); fi
if [[ -n "${DRGNX_INSTALL_NIDHOGG_COMMIT:-}" ]]; then nidhogg_env+=("DRGNX_INSTALL_NIDHOGG_COMMIT=$DRGNX_INSTALL_NIDHOGG_COMMIT"); fi
as_tester() { sudo -u tester -H env PATH="$home/.local/bin:/usr/local/bin:/usr/bin:/bin" \
                 DRGNX_INSTALL_REPO=/src/drgnx.bundle ${nidhogg_env[@]+"${nidhogg_env[@]}"} "$@"; }
sudo -u tester -H git config --global --add safe.directory '*'   # the mounted Nidhogg repository is root's

step "install.sh --yes"
as_tester bash /src/install.sh --yes || fail "install.sh exited $?"
[[ -d "$home/.local/share/drgnx/drgnx/.git" ]] || fail "drgnx was not cloned"

step "drgnx doctor"
out="$(as_tester drgnx doctor)" || { printf '%s\n' "$out"; fail "the doctor reports a failure"; }
printf '%s\n' "$out"
case "$ID:$VERSION_ID" in
  fedora:44|fedora:45|ubuntu:26.04)   # Nidhogg's recipes (nidhogg/deps)
    grep -q '^OK    emacs-version .*Nidhogg 31.1-nidhogg.1' <<<"$out" || fail "emacs-version is not Nidhogg 31.1-nidhogg.1" ;;
  *)   # no recipe yet: stock GNU Emacs 31.1, which the doctor warns about
    grep -q '^WARN  emacs-version ' <<<"$out" || fail "emacs-version is not a warning about stock Emacs" ;;
esac
grep -q '^OK    native-compilation ' <<<"$out" || fail "native compilation is not ok"
grep -q '^OK    gui ' <<<"$out" || fail "not a graphical build"
grep -q '^OK    tree-sitter ' <<<"$out" || fail "no tree-sitter"

step "second run is a no-op"
rc=0; out="$(as_tester bash /src/install.sh --yes)" || rc=$?
((rc == 0)) || { printf '%s\n' "$out"; fail "second run exited $rc"; }
printf '%s\n' "$out"
case "$ID:$VERSION_ID" in
  fedora:44|fedora:45|ubuntu:26.04) grep -q 'keep the installed Nidhogg' <<<"$out" || fail "second run did not keep the installed Nidhogg" ;;
  *) grep -q 'keep the installed Emacs' <<<"$out" || fail "second run did not keep the installed Emacs" ;;
esac
grep -q 'git pull --ff-only' <<<"$out" || fail "second run did not update the checkout"
! grep -q '^As root:' <<<"$out" || fail "second run ran a root step"

if [[ "$ID" == fedora ]] && rpm -q emacs-pgtk >/dev/null 2>&1; then
  # Fedora's `emacs` is an alternatives link to the emacs-desktop wrapper, which prefers a graphical build to
  # emacs-nw (priorities 85 for the wrapper, 80 pgtk, 65 nw): a terminal-only Emacs beside ours must not take over.
  step "emacs-nw beside emacs-pgtk: emacs stays graphical"
  dnf -y -q install emacs-nw >/dev/null
  rpm -q emacs-nw >/dev/null || fail "emacs-nw was not installed"
  printf 'emacs -> %s\n' "$(readlink -f "$(command -v emacs)")"
  gui="$(as_tester emacs --batch -Q --eval '(princ (cond ((featurep (quote pgtk)) "pgtk") ((featurep (quote x)) "x") (t "nil")))')"
  [[ "$gui" == pgtk ]] || fail "with emacs-nw installed, emacs is not the pgtk build (it reports gui=$gui)"
  out="$(as_tester bash /src/install.sh --yes)" || { printf '%s\n' "$out"; fail "run with emacs-nw present exited $?"; }
  grep -q 'keep the installed \(Emacs\|Nidhogg\)' <<<"$out" || { printf '%s\n' "$out"; fail "emacs-nw beside emacs-pgtk made the installer replace Emacs"; }
fi

step "--dry-run changes nothing"
touch /tmp/before-dry-run
sleep 1
as_tester bash /src/install.sh --dry-run >/dev/null || fail "--dry-run exited $?"
changed="$(find "$home" /usr/local /etc -newer /tmp/before-dry-run -print 2>/dev/null)"
[[ -z "$changed" ]] || fail "--dry-run changed: $changed"

step "E2E OK ($PRETTY_NAME)"
