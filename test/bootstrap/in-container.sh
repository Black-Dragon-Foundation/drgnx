#!/usr/bin/env bash
# Container 2 of `drgnx test --bootstrap`: a fresh Fedora with only what a desktop has (sudo, a user with a login
# keyring, script), where one command sets the user up from a configuration repository and an age identity, then
# the outcome is checked.  Run as root; it prepares, then runs itself again as the user `tester` inside a D-Bus session.
# The snapshot of the drgnx tree is /src (read-only): /src/drgnx.bundle, /src/config.git (the configuration, with
# secrets.age encrypted to /src/identity.txt) and /src/config-pass.git (secrets.age locked with a passphrase).
# Bash, not Emacs Lisp: no Emacs exists here until install.sh has put one in.
set -euo pipefail

step() { printf '\n=== %s\n' "$*"; }
fail() { printf 'E2E FAIL: %s\n' "$*"; exit 1; }

KEYRING_PASSWORD=exit-test-keyring-password   # throwaway: the keyring lives in this container
SUDO_PASSWORD=exit-test-sudo-password         # what the terminal test's stand-in sudo asks for
PASSPHRASE=drgnx-exit-test-passphrase         # what config-pass.git's secrets.age is locked with

if [[ "${1:-}" != --as-tester ]]; then
  . /etc/os-release
  [[ "$ID" == fedora ]] || fail "the exit test is written for Fedora (this is $ID)"
  step "prepare Fedora $VERSION_ID: sudo, a user, a keyring"
  # fedora's updates-testing repository is flaky (a corrupt metadata download failed a run) and tests nothing of ours
  for f in /etc/yum.repos.d/*testing*.repo; do [[ -e "$f" ]] && sed -i 's/^enabled=1/enabled=0/' "$f"; done
  dnf -y -q install sudo dbus-daemon gnome-keyring libsecret /usr/bin/script >/dev/null
  useradd -m tester
  echo 'tester ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/tester
  chmod 440 /etc/sudoers.d/tester
  # install.sh needs tester's sudo.  The nightly run on GitHub's runner failed there ("PAM account management error:
  # Authentication service cannot retrieve authentication info") where a local podman passes: the evidence, then stop
  if ! out="$(sudo -u tester sudo -n true 2>&1)"; then
    printf '%s\n' "$out"
    { ls -l /etc/shadow /usr/bin/sudo; grep -c '^tester:' /etc/shadow; grep -E '^(Cap(Eff|Bnd)|NoNewPrivs):' /proc/self/status
      cat /proc/self/attr/current; echo; ls /sys/fs/selinux; grep -E '^(passwd|shadow):' /etc/nsswitch.conf
      sudo -u tester grep -E '^(Cap(Eff|Bnd)|NoNewPrivs):' /proc/self/status; } 2>&1 || true
    fail "sudo does not work for a user in this container: the container runtime, not drgnx (the evidence is above)"
  fi
  home="$(getent passwd tester | cut -d: -f6)"
  # /src is read-only and belongs to someone else here: the identity needs mode 600 for tester, and git refuses a
  # repository another user owns, so tester gets copies of both (what a user would have after copying them over)
  install -o tester -g tester -m 600 /src/identity.txt "$home/identity.txt"
  mkdir -p /srv
  cp -R /src/config.git /srv/config.git
  cp -R /src/config-pass.git /srv/config-pass.git
  chown -R tester:tester /srv/config.git /srv/config-pass.git
  exec sudo -u tester -H env "PATH=$home/.local/bin:/usr/local/bin:/usr/bin:/bin" DRGNX_INSTALL_REPO=/src/drgnx.bundle \
    dbus-run-session -- bash /src/test/bootstrap/in-container.sh --as-tester
fi

# ---- as tester, in a session bus -----------------------------------------------------------------------------------
. /src/test/bootstrap/pty-run.sh
cd "$HOME"
CONFIG=$HOME/.config/drgnx
ELPA=$HOME/.local/share/drgnx/elpa
KEY="sk-or-v1-$(head -c 24 /dev/zero | tr '\0' x)"

step "a keyring, unlocked with a password fed on stdin (what a login does)"
eval "$(printf '%s' "$KEYRING_PASSWORD" | gnome-keyring-daemon --unlock --components=secrets)"
export GNOME_KEYRING_CONTROL SSH_AUTH_SOCK
printf '%s' probe | secret-tool store --label=exit-test-probe probe yes
[[ "$(secret-tool lookup probe yes)" == probe ]] || fail "the keyring does not store headless"
secret-tool clear probe yes

lookup_key() { secret-tool lookup host openrouter.ai service drgnx 2>/dev/null || true; }
doctor_row() { awk '$1 == "doctor" {print $2}' "$1"; }   # bootstrap's rows: STEP STATUS MESSAGE

# ---- 1: the one command --------------------------------------------------------------------------------------------
step "1. install.sh --yes --config … --identity …"
rc=0
bash /src/install.sh --yes --config /srv/config.git --identity "$HOME/identity.txt" >/tmp/run1.out 2>&1 || rc=$?
cat /tmp/run1.out
((rc == 0)) || fail "the one command exited $rc"

# ---- 2: the outcome ------------------------------------------------------------------------------------------------
step "2. the outcome"
# the repository's own lock is the shipped one, which the first sync completes (drops :from-shipped): the one file that may differ
[[ -z "$(git -C "$CONFIG" status --porcelain | grep -v ' drgnx.lock.eld$' || true)" ]] || { git -C "$CONFIG" status --short; fail "the config dir differs from the repository"; }
for f in /src/test/fixtures/bootstrap/config/*; do
  cmp -s "$f" "$CONFIG/${f##*/}" || fail "${f##*/} is not the fixture's"
done
[[ -f "$CONFIG/secrets.age" && -f "$CONFIG/drgnx.lock.eld" ]] || fail "secrets.age or the lock is not in the config dir"
! grep -q ':from-shipped' "$CONFIG/drgnx.lock.eld" || fail "the first sync did not complete the lock"
echo "config dir: the fixture, clean"

emacs --batch -Q --eval '(let ((l (with-temp-buffer (insert-file-contents "/src/etc/drgnx.lock.eld") (read (current-buffer)))))
  (dolist (p (plist-get l :packages)) (princ (format "%s %s\n" (car p) (plist-get (cdr p) :version)))))' >/tmp/lock.list </dev/null
# the fixture's modules (a minimal preset) need some of the lock's packages, not all of them: what is installed is
# exactly a locked NAME-VERSION, never another version of it
awk '{print $1 "-" $2}' /tmp/lock.list >/tmp/lock.dirs
n=0
for d in "$ELPA"/*/; do
  base=$(basename "$d")
  [[ "$base" =~ -[0-9] ]] || continue
  grep -qxF -- "$base" /tmp/lock.dirs || fail "elpa/$base is not what the lock pins"
  n=$((n + 1))
done
# and everything the configuration needs is there: its modules' packages and what they require, as the lock pins them
# (drgnx's own reading of the config, with this Emacs: a package a built-in satisfies is not needed)
emacs --batch -Q -L "$HOME/.local/share/drgnx/drgnx/core" --eval '(progn (require (quote drgnx-pkg))
  (let ((lock (drgnx-pkg-read-lock)))
    (dolist (n (drgnx-pkg--lock-closure (drgnx-pkg-manifest) lock))
      (princ (format "%s-%s\n" n (plist-get (alist-get n lock) :version))))))' >/tmp/needed.dirs </dev/null
[[ -s /tmp/needed.dirs ]] || fail "the configuration needs no package: not read"
while read -r want; do
  [[ -d "$ELPA/$want" ]] || fail "the configuration needs $want: not in elpa/"
done </tmp/needed.dirs
echo "elpa/: $n packages, each the version the lock pins; the $(wc -l </tmp/needed.dirs) the configuration needs are all there"

[[ "$(lookup_key)" == "$KEY" ]] || fail "the keyring does not hold the fixture key"
echo "keyring: holds the key of openrouter.ai"
hits="$(grep -rlF -- "$KEY" "$HOME" /tmp /src 2>/dev/null | grep -v "^$HOME/\.local/share/keyrings/" || true)"
[[ -z "$hits" ]] || fail "the key is in plain text in: $hits"
echo "the key is nowhere else under \$HOME, /tmp or /src"

rpm -q age >/dev/null || fail "age was not installed"
line=$(grep -n 'sudo dnf install -y age' /tmp/run1.out | head -1 | cut -d: -f1)
[[ -n "$line" ]] || fail "the output never announced the age install"
echo "age: installed by bootstrap, announced on output line $line"
[[ "$(doctor_row /tmp/run1.out)" == ok ]] || fail "the doctor step is not ok"
echo "doctor: ok"
for rc_file in .bashrc .bash_profile .profile .zshrc .zprofile .config/fish/config.fish; do
  ! grep -qs drgnx "$HOME/$rc_file" || fail "$rc_file was written (--yes never edits one)"
done
echo "no rc file mentions drgnx"

# ---- 3: again ------------------------------------------------------------------------------------------------------
step "3. a second run changes nothing"
rc=0
drgnx bootstrap --config /srv/config.git --identity "$HOME/identity.txt" --yes >/tmp/run2.out 2>&1 || rc=$?
cat /tmp/run2.out
((rc == 0)) || fail "the second run exited $rc"
! awk '$2 == "changed"' /tmp/run2.out | grep -q . || fail "the second run changed something"
[[ "$(doctor_row /tmp/run2.out)" == ok ]] || fail "the second run's doctor is not ok"

# ---- 4: no keyring -------------------------------------------------------------------------------------------------
step "4. without a session bus the keys step is skipped"
rc=0
env -u DBUS_SESSION_BUS_ADDRESS drgnx bootstrap --step keys --yes --identity "$HOME/identity.txt" >/tmp/run3.out 2>&1 || rc=$?
cat /tmp/run3.out
((rc == 0)) || fail "the keys step without a keyring exited $rc"
awk '$1 == "keys" && $2 == "skipped" && /keyring/' /tmp/run3.out | grep -q . || fail "keys was not skipped for want of a keyring"

# ---- 5: the real terminal ------------------------------------------------------------------------------------------
# bin/drgnx hands what needs a terminal (sudo's password, age's passphrase) back to the shell it runs in (exit 10);
# every unit test of that fakes the terminal, so this runs it once on a pseudo-terminal.  A stand-in sudo asks for a
# password on /dev/tty like the real one, then runs the real sudo (NOPASSWD).
step "5. the terminal hand-back: questions, sudo's password and age's passphrase typed on a pseudo-terminal"
sudo dnf remove -y -q age >/dev/null
rpm -q age >/dev/null 2>&1 && fail "age could not be removed"
rm -rf "$CONFIG"
secret-tool clear host openrouter.ai service drgnx
[[ -z "$(lookup_key)" ]] || fail "the key could not be removed from the keyring"
mkdir -p "$HOME/fakebin"
cat >"$HOME/fakebin/sudo" <<FAKE
#!/usr/bin/env bash
printf '[sudo] password for %s: ' "\$USER" >/dev/tty
IFS= read -rs typed </dev/tty
printf '\n' >/dev/tty
[[ "\$typed" == '$SUDO_PASSWORD' ]] || { echo "sudo: Sorry, try again." >&2; exit 1; }
echo "sudo \$*" >>"$HOME/fake-sudo.log"
exec /usr/bin/sudo "\$@"
FAKE
chmod +x "$HOME/fakebin/sudo"
rm -f "$HOME/fake-sudo.log"
PATH="$HOME/fakebin:$PATH" pty_run /tmp/pty.typescript \
  "drgnx bootstrap --config /srv/config-pass.git --step preflight --step config --step keys" \
  "(y or n)" y "(y or n)" y "password for" "$SUDO_PASSWORD" "Enter passphrase" "$PASSPHRASE"
cat /tmp/pty.typescript
[[ -z "$PTY_STUCK" ]] || fail "the terminal run was waiting for $PTY_STUCK (exit $PTY_RC; the screen is above)"
[[ "$PTY_RC" == 0 ]] || fail "the terminal run exited $PTY_RC"
grep -aq 'sudo dnf install -y age' "$HOME/fake-sudo.log" || fail "the stand-in sudo did not run the age install"
rpm -q age >/dev/null || fail "the terminal run did not install age"
[[ "$(lookup_key)" == "$KEY" ]] || fail "the keyring does not hold the key after the passphrase import"
! grep -aqF -- "$KEY" /tmp/pty.typescript || fail "the key is on the terminal"
! grep -aqF -e "$SUDO_PASSWORD" -e "$PASSPHRASE" /tmp/pty.typescript || fail "a password was echoed on the terminal"
echo "terminal: sudo and age asked, were answered, and the key is in the keyring"

step "E2E OK (Fedora)"
