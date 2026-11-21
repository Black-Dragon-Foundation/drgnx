#!/usr/bin/env bash
# The AWS image's first-boot script and units, run for real against a stand-in for the instance metadata service (a `curl`
# in front of PATH that answers the two IMDSv2 requests from files), in a temporary root. Run it inside the dev container
# through the slot scripts (it writes only under a temporary directory).
#   bash test/runners/image-units.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
img=$(cd "$here/../../runtime/crates/drgnx-ratatoskr/src/runners/cloud/image" && pwd)
boot=$img/drgnx-first-boot
tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1" >&2; fails=$((fails + 1)); }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
# answers PUT .../api/token with a token and GET .../user-data (with that token) with $UD_FILE
case " $* " in
  *" -X PUT "*) echo "tok-test" ;;
  *"X-aws-ec2-metadata-token: tok-test"*) cat "$UD_FILE" ;;
  *) exit 22 ;;
esac
EOF
cat > "$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SYSTEMCTL_LOG"
EOF
chmod +x "$tmp/bin/curl" "$tmp/bin/systemctl"

# run NAME USERDATA [BAKED_CA]: first boot in a fresh root; echoes the root
boot_in() {
  local root=$tmp/root-$1
  mkdir -p "$root/ssh"
  [ -z "${3:-}" ] || printf '%s\n' "$3" > "$root/ssh/drgnx-ca.pub"
  printf '%s' "$2" > "$tmp/ud-$1"
  UD_FILE=$tmp/ud-$1 SYSTEMCTL_LOG=$root/systemctl.log PATH=$tmp/bin:$PATH DRGNX_ETC=$root \
    DRGNX_SYSTEMCTL=$tmp/bin/systemctl bash "$boot" > "$root/out" 2>&1
  echo $? > "$root/rc"
}
rc() { cat "$tmp/root-$1/rc"; }

CA='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE drgnx-ca'
NEWCA='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEW drgnx-ca'
UD=$'#cloud-config\ndrgnx-provider: aws\ndrgnx-principal: drgnx-c1\ndrgnx-watchdog-idle: 900\ndrgnx-watchdog-lifetime: 28800\ndrgnx-watchdog-unattended: 7200\n'

boot_in good "$UD" "$CA"
check "first boot succeeds" test "$(rc good)" = 0
check "the principal file holds the one principal" test "$(cat "$tmp/root-good/ssh/drgnx-principals")" = drgnx-c1
check "the baked CA key stays" test "$(cat "$tmp/root-good/ssh/drgnx-ca.pub")" = "$CA"
check "sshd trusts the CA and reads principals, no authorized_keys, no password" \
  bash -c "grep -qx 'TrustedUserCAKeys /etc/ssh/drgnx-ca.pub' '$tmp/root-good/ssh/sshd_config.d/01-drgnx.conf' &&
           grep -qx 'AuthorizedPrincipalsFile /etc/ssh/drgnx-principals' '$tmp/root-good/ssh/sshd_config.d/01-drgnx.conf' &&
           grep -qx 'AuthorizedKeysFile none' '$tmp/root-good/ssh/sshd_config.d/01-drgnx.conf' &&
           grep -qx 'PasswordAuthentication no' '$tmp/root-good/ssh/sshd_config.d/01-drgnx.conf'"
check "the watchdog's limits come from the user-data" \
  bash -c "grep -qx 'DRGNX_WATCHDOG_IDLE=900' '$tmp/root-good/drgnx/watchdog.env' &&
           grep -qx 'DRGNX_WATCHDOG_UNATTENDED=7200' '$tmp/root-good/drgnx/watchdog.env' &&
           grep -qx 'DRGNX_WATCHDOG_PROVIDER=aws' '$tmp/root-good/drgnx/watchdog.env'"
check "sshd is reloaded" grep -q 'reload-or-restart sshd.service' "$tmp/root-good/systemctl.log"

boot_in newca "$UD"$'drgnx-ca: '"$NEWCA"$'\n' "$CA"
check "a newer CA in the user-data replaces the baked one" test "$(cat "$tmp/root-newca/ssh/drgnx-ca.pub")" = "$NEWCA"

boot_in nums $'drgnx-principal: p1\ndrgnx-watchdog-idle: abc\n' "$CA"
check "a limit that is not a number falls back to the default" grep -qx 'DRGNX_WATCHDOG_IDLE=600' "$tmp/root-nums/drgnx/watchdog.env"

boot_in noprincipal $'drgnx-provider: aws\n' "$CA"
check "no principal is a failure" test "$(rc noprincipal)" != 0
boot_in oddprincipal $'drgnx-principal: a b;rm\n' "$CA"
check "a principal with odd characters is a failure" test "$(rc oddprincipal)" != 0
check "...and sshd is left alone" test ! -e "$tmp/root-oddprincipal/systemctl.log"
boot_in noca "$UD"
check "no CA key, baked or sent, is a failure" test "$(rc noca)" != 0

# the image's last steps remove the host keys and clean cloud-init before the snapshot, and power off with systemctl
grep -A6 'pub const FINAL_STEPS' "$img/../user_data.rs" > "$tmp/final-steps"
for s in 'rm -f /etc/ssh/ssh_host_*' 'cloud-init clean --logs' 'systemctl poweroff'; do
  check "the final steps hold: $s" grep -qF "\"$s\"" "$tmp/final-steps"
done

# the units
check "the first-boot unit runs the baked script" grep -q 'ExecStart=/usr/local/libexec/drgnx-first-boot' "$img/drgnx-first-boot.service"
check "the watchdog starts after the first boot, from its limits" \
  bash -c "grep -q 'Requires=drgnx-first-boot.service' '$img/drgnx-watchdog.service' && grep -q 'EnvironmentFile=/etc/drgnx/watchdog.env' '$img/drgnx-watchdog.service'"
# every option `sleipnir watchdog` refuses to start without is on the unit's command line
wd_src=$here/../../runtime/crates/sleipnir/src/watchdog.rs
wd_exec=$(grep '^ExecStart=' "$img/drgnx-watchdog.service")
needed=$(grep -o '"--[a-z-]* is needed"' "$wd_src" | cut -d' ' -f1 | tr -d '"' | sort -u)
check "the watchdog's source names the options it needs" test -n "$needed"
for o in $needed; do
  check "the watchdog unit passes $o" grep -q -- " $o " <<< "$wd_exec "
done
if command -v systemd-analyze > /dev/null; then
  # verify wants the ExecStart binaries to exist; a stand-in tree is enough for a syntax check
  check "systemd-analyze reads the units" bash -c "systemd-analyze verify --man=no '$img/drgnx-first-boot.service' 2>&1 | grep -v -e 'Command .* not found' -e 'is not executable' | grep -q -i -e 'unknown section' -e 'unknown key' && exit 1 || exit 0"
fi
if command -v shellcheck > /dev/null; then
  check "shellcheck is clean" shellcheck "$boot"
fi

echo "image-units: $fails failed"
[ "$fails" = 0 ]
