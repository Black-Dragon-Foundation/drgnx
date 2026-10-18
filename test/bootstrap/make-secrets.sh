#!/usr/bin/env bash
# Container 1 of `drgnx test --bootstrap`, run as root in a fresh Fedora with the snapshot at /src (read-write): the
# encrypted provider keys, the way the first machine would have made them.
#   - identity.txt: an age identity; config.git gets a secrets.age encrypted to its recipient;
#   - config-pass.git: a second copy of the configuration whose secrets.age is locked with a passphrase (age asks for
#     it on a terminal: `drgnx secrets import` on a machine without the identity file), to test the terminal path.
# Bash, not Emacs Lisp: nothing but a base Fedora and age is here.  The key is built at run time (the pre-commit hook
# rejects one written out).
set -euo pipefail
. /src/test/bootstrap/pty-run.sh

step() { printf '\n=== %s\n' "$*"; }
fail() { printf 'E2E FAIL: %s\n' "$*"; exit 1; }
git_() { git -c user.name=drgnx-test -c user.email=test@drgnx.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }

step "prepare: age, git, script"
# fedora's updates-testing repository is flaky (a corrupt metadata download failed a run) and tests nothing of ours
for f in /etc/yum.repos.d/*testing*.repo; do [[ -e "$f" ]] && sed -i 's/^enabled=1/enabled=0/' "$f"; done
dnf -y -q install age git /usr/bin/script >/dev/null   # `script` is its own package on newer Fedora

key="sk-or-v1-$(head -c 24 /dev/zero | tr '\0' x)"
bundle="(:version 1 :keys ((:provider openrouter :host \"openrouter.ai\" :key \"$key\")))"
work=$(mktemp -d)

step "an age identity and secrets.age encrypted to it"
age-keygen -o /src/identity.txt 2>/dev/null
chmod 600 /src/identity.txt
recipient=$(age-keygen -y /src/identity.txt)
[[ "$recipient" == age1* ]] || fail "no recipient"
printf '%s\n' "$bundle" | age -r "$recipient" -o "$work/secrets.age"

# the passphrase copy is made from the repository as it is now, before the identity-locked file is committed to config.git
git clone -q --bare /src/config.git /src/config-pass.git

git_ clone -q /src/config.git "$work/c"
cp "$work/secrets.age" "$work/c/secrets.age"
git_ -C "$work/c" add secrets.age
git_ -C "$work/c" commit -q -m "provider keys (age identity)"
git_ -C "$work/c" push -q origin HEAD:main

step "secrets.age locked with a passphrase, typed on a terminal"
printf '%s\n' "$bundle" >"$work/bundle.txt"
pty_run "$work/age.typescript" "age -e -p -o '$work/secrets-pass.age' '$work/bundle.txt'" \
  "Enter passphrase" "drgnx-exit-test-passphrase" "Confirm passphrase" "drgnx-exit-test-passphrase"
[[ "$PTY_RC" == 0 ]] || { cat "$work/age.typescript"; fail "age -p exited $PTY_RC"; }
git_ clone -q /src/config-pass.git "$work/p"
cp "$work/secrets-pass.age" "$work/p/secrets.age"
git_ -C "$work/p" add secrets.age
git_ -C "$work/p" commit -q -m "provider keys (passphrase)"
git_ -C "$work/p" push -q origin HEAD:main

step "checks"
[[ "$(age -d -i /src/identity.txt "$work/secrets.age")" == "$bundle" ]] || fail "secrets.age does not decrypt to the bundle"
git --git-dir=/src/config.git show HEAD --stat | tail -3
git --git-dir=/src/config-pass.git show HEAD --stat | tail -3
step "keys OK"
