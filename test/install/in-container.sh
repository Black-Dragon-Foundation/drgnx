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
case "$ID:$VERSION_ID" in
  fedora:44|fedora:45|ubuntu:26.04)
    # The Nidhogg a user who installed the release has: install.sh keeps it (a build from source takes 30-60 minutes);
    # this test is about the Ratatoskr build step.  Fedora's updates-testing is off: a metalink flake once broke dnf there.
    for f in /etc/yum.repos.d/*testing*.repo; do [[ -e "$f" ]] && sed -i 's/^enabled=1/enabled=0/' "$f"; done
    bash /src/test/container/nidhogg.sh "$ID-$VERSION_ID" >/dev/null ;;
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
# the mounted Nidhogg repository is root's; written as a file, since git may not be installed yet (install.sh installs it)
printf '[safe]\n\tdirectory = *\n' >"$home/.gitconfig" && chown tester "$home/.gitconfig"

case "$ID:$VERSION_ID" in
  fedora:44|fedora:45|ubuntu:26.04) ;;   # Nidhogg's recipes (nidhogg/deps): the rest of this script
  *)   # no recipe yet (NIDHOGG-DISTROS-1): the installer stops and installs no stock Emacs; the doctor fails on one
    step "install.sh --yes: no Nidhogg recipe, exit 1, nothing installed"
    rc=0; out="$(as_tester bash /src/install.sh --yes 2>&1)" || rc=$?
    printf '%s\n' "$out"
    ((rc == 1)) || fail "install.sh exited $rc, not 1"
    grep -q 'no Nidhogg recipe for .* yet (NIDHOGG-DISTROS-1)' <<<"$out" || fail "the message does not name the missing recipe"
    [[ ! -e "$home/.local/share/drgnx" && ! -e "$home/.local/opt" ]] || fail "the refused run installed something"
    if [[ "$ID" == arch ]]; then   # --method keep on the distribution's own Emacs: drgnx runs, and the doctor says FAIL
      step "--method keep on Arch's own Emacs: emacs-version FAILs"
      pacman -S --noconfirm --needed emacs-wayland >/dev/null
      as_tester bash /src/install.sh --yes --method keep || fail "install.sh --method keep exited $?"
      rc=0; out="$(as_tester drgnx doctor)" || rc=$?
      printf '%s\n' "$out"
      grep -q '^FAIL  emacs-version ' <<<"$out" || fail "emacs-version is not a failure for stock Emacs"
    fi
    step "E2E OK ($PRETTY_NAME)"
    exit 0 ;;
esac

step "install.sh --yes"
as_tester bash /src/install.sh --yes || fail "install.sh exited $?"
[[ -d "$home/.local/share/drgnx/drgnx/.git" ]] || fail "drgnx was not cloned"

step "drgnx doctor"
out="$(as_tester drgnx doctor)" || { printf '%s\n' "$out"; fail "the doctor reports a failure"; }
printf '%s\n' "$out"
grep -q '^OK    emacs-version .*Nidhogg 31.1-nidhogg.1' <<<"$out" || fail "emacs-version is not Nidhogg 31.1-nidhogg.1"
grep -q '^OK    native-compilation ' <<<"$out" || fail "native compilation is not ok"
grep -q '^OK    gui ' <<<"$out" || fail "not a graphical build"
grep -q '^OK    tree-sitter ' <<<"$out" || fail "no tree-sitter"
grep -q '^OK    ratatoskr ' <<<"$out" || fail "the ratatoskr check is not ok"

step "ratatoskr: built from this snapshot, no test hooks, linked as rtsk"
head="$(as_tester git -C "$home/.local/share/drgnx/drgnx" rev-parse HEAD)"
for bin in ratatoskr rtsk; do
  json="$(as_tester "$bin" version --json)" || fail "$bin version --json failed"
  printf '%s: %s\n' "$bin" "$json"
  grep -Eq "\"commit\": *\"$head\"" <<<"$json" || fail "$bin is not built from the snapshot's commit $head"
  grep -Eq '"test_hooks": *false' <<<"$json" || fail "$bin has test hooks"
done
[[ "$(as_tester rtsk version)" == "$(as_tester ratatoskr version)" ]] || fail "rtsk version differs from ratatoskr version"

step "second run is a no-op"
rc=0; out="$(as_tester bash /src/install.sh --yes)" || rc=$?
((rc == 0)) || { printf '%s\n' "$out"; fail "second run exited $rc"; }
printf '%s\n' "$out"
grep -q 'keep the installed Nidhogg' <<<"$out" || fail "second run did not keep the installed Nidhogg"
grep -q 'git pull --ff-only' <<<"$out" || fail "second run did not update the checkout"
! grep -q '^As root:' <<<"$out" || fail "second run ran a root step"

step "--dry-run changes nothing"
touch /tmp/before-dry-run
sleep 1
as_tester bash /src/install.sh --dry-run >/dev/null || fail "--dry-run exited $?"
changed="$(find "$home" /usr/local /etc -newer /tmp/before-dry-run -print 2>/dev/null)"
[[ -z "$changed" ]] || fail "--dry-run changed: $changed"

step "E2E OK ($PRETTY_NAME)"
