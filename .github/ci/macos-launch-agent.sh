#!/bin/bash
# macos-launch-agent.sh: drgnx's daemon launch agent on a real launchd (macos.yml, on demand: `only: launch-agent`).
# What the unit tests simulate on Linux, here for real: `drgnx service-unit --install` writes the plist and loads it
# into the user's GUI domain (gui/UID), launchd starts the daemon (RunAtLoad), `--refresh` reads the plist back as
# current, bin/drgnx's restart (bootout, then bootstrap) and Restart drgnx's (kickstart -k) each start a new daemon,
# and a bootout stops it.  A runner account with no GUI domain (no one logged in at the console) proves the same
# plist in the user/UID domain instead and says so: the GUI domain is then unproven.  Needs DRGNX_EMACS (nidhogg.sh
# macos); run from the checkout's root.
set -uo pipefail
: "${DRGNX_EMACS:?DRGNX_EMACS: run test/container/nidhogg.sh macos first}"
uid=$(id -u) label=org.blackdragonfoundation.drgnx
plist="$HOME/Library/LaunchAgents/$label.plist"
fail=0
say() { echo "launch-agent: $*"; }
bad() { echo "launch-agent: FAIL $*"; fail=1; }
pid_of() { launchctl print "$domain/$label" 2>/dev/null | awk '$1 == "pid" { print $3; exit }'; }
# the daemon's pid once launchd runs it, waiting at most 60 s; empty when it never ran
running() {
  local _ p
  for _ in $(seq 1 60); do
    p=$(pid_of)
    if [[ -n "$p" && "$p" != "${1:-}" ]]; then echo "$p"; return 0; fi
    sleep 1
  done
  return 1
}

if launchctl print "gui/$uid" >/dev/null 2>&1; then domain="gui/$uid"; else domain="user/$uid"; fi
say "domain: $domain"

bin/drgnx service-unit --install; rc=$?
say "drgnx service-unit --install: exit $rc"
[[ -f "$plist" ]] || bad "no plist at $plist"
plutil -lint "$plist" || bad "plutil rejects the plist"
if [[ "$domain" == "gui/$uid" ]]; then
  [[ $rc == 0 ]] || bad "service-unit --install exited $rc in the GUI domain"
else
  say "no GUI domain: loading the same plist into $domain (the GUI domain stays unproven)"
  launchctl bootstrap "$domain" "$plist" || bad "bootstrap $domain refused the plist"
fi

p1=$(running) || bad "launchd did not start the daemon"
say "daemon pid: ${p1:-none}"
launchctl print "$domain/$label" | grep -E '^\s*(state|program|pid|last exit code) ' || true

out=$(bin/drgnx service-unit --refresh 2>&1); say "service-unit --refresh: $out"
echo "$out" | grep -q 'up to date' || bad "--refresh did not read the plist back as current"

# bin/drgnx update --restart's two steps (update_restart)
launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
launchctl bootstrap "$domain" "$plist" || bad "bootstrap after bootout failed"
p2=$(running "$p1") || bad "no new daemon after bootout + bootstrap"
say "after the update's restart: pid ${p2:-none}"

# Restart drgnx inside a launch-agent session (core/drgnx-restart.el)
launchctl kickstart -k "$domain/$label" || bad "kickstart -k failed"
p3=$(running "$p2") || bad "no new daemon after kickstart -k"
say "after kickstart -k: pid ${p3:-none}"

launchctl bootout "$domain/$label" || bad "bootout failed"
sleep 2
if [[ -n "${p3:-}" ]] && kill -0 "$p3" 2>/dev/null; then bad "the daemon $p3 outlived bootout"; fi

if [[ $fail == 0 ]]; then say "ok ($domain)"; else say "failed ($domain)"; fi
exit $fail
