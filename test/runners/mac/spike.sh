#!/bin/bash
# The Mac runner's spikes S1–S3 on a macOS CI host (runtime.yml's on-demand job, `only: rt-macrunner`;
# test/runners/mac/README.md). The CI user (passwordless sudo) plays the hub; a fresh standard account `drgnx-runner`,
# reached over a localhost sshd with a throwaway key, plays the runner, with nobody logged in to it.
#   spike.sh up                  the account, Remote Login, the key, mrspike built and copied into its root
#   spike.sh s1                  launchd (`bootstrap user/<uid>`) and the setsid launcher: does a job outlive its ssh?
#   spike.sh s3                  the watchdog: a 512 MiB grant with an escaped child; its CPU idle and in a 16-way build
#   spike.sh s2-build NIDHOGG    a Nidhogg build with Naglfar under the draft build profile, as the runner account
#   spike.sh s2-ert              drgnx ERT selectors under the same profile
#   spike.sh denials             what Seatbelt denied, from the unified log
# Results: $MR_OUT/results.md (the summary) and its logs. Keys stay in $MR_KEYS (never uploaded).
# bash 3.2 (macOS).
set -uo pipefail

U=drgnx-runner
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT_REL=.drgnx-runner.noindex          # the runner root, under the runner account's home
if [ "${1:-}" != remote ]; then
  OUT=${MR_OUT:?MR_OUT: the results folder}
  KEYS=${MR_KEYS:?MR_KEYS: a folder for the throwaway key}
  RES="$OUT/results.md"
  mkdir -p "$OUT" "$KEYS"
fi

say() { printf '%s\n' "$*" | tee -a "$RES"; }
mr() { ssh -F "$KEYS/ssh_config" mr "$@"; }
uid_of() { id -u "$U"; }
home_of() { printf '/Users/%s' "$U"; }
root_of() { printf '%s/%s' "$(home_of)" "$ROOT_REL"; }

up() {
  say "## Setup"
  pw=$(openssl rand -hex 24)
  sudo sysadminctl -addUser "$U" -fullName "drgnx runner" -password "$pw" -home "$(home_of)" 2>&1 | tail -n 3
  unset pw
  sudo createhomedir -c -u "$U" >/dev/null 2>&1 || true
  [ -d "$(home_of)" ] || { sudo mkdir -p "$(home_of)"; sudo chown "$U:staff" "$(home_of)"; }
  if dseditgroup -o checkmember -m "$U" admin >/dev/null 2>&1; then say "- $U is an admin (unexpected)"; else say "- $U is a standard account (uid $(uid_of))"; fi
  ssh-keygen -q -t ed25519 -N '' -C drgnx-mac-runner-spike -f "$KEYS/key"
  sudo mkdir -p "$(home_of)/.ssh"
  sudo cp "$KEYS/key.pub" "$(home_of)/.ssh/authorized_keys"
  sudo chown -R "$U:staff" "$(home_of)/.ssh"
  sudo chmod 700 "$(home_of)/.ssh"; sudo chmod 600 "$(home_of)/.ssh/authorized_keys"
  sudo dseditgroup -o edit -a "$U" -t user com.apple.access_ssh >/dev/null 2>&1 || true
  sudo launchctl enable system/com.openssh.sshd
  sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
  cat > "$KEYS/ssh_config" <<EOF
Host mr
  HostName 127.0.0.1
  User $U
  IdentityFile $KEYS/key
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $KEYS/known_hosts
  ControlMaster auto
  ControlPath $KEYS/cm-%C
  ControlPersist 300
  ConnectionAttempts 10
  ConnectTimeout 5
EOF
  mr 'id; echo "HOME=$HOME"; launchctl managername; sw_vers; uname -m; sysctl -n sysctl.proc_translated kern.bootsessionuuid' 2>&1 | tee -a "$OUT/setup.log"
  say "- the runner's launchd session: $(mr 'launchctl managername' 2>&1)"
  say "- \`launchctl print user/<uid>\` over ssh: $(mr 'launchctl print user/$(id -u) 2>&1 | head -n 1' 2>&1)"
  say "- \`launchctl print gui/<uid>\` over ssh (runner account): $(mr 'launchctl print gui/$(id -u) 2>&1 | head -n 1' 2>&1)"
  say "- \`launchctl print gui/<uid>\` for the CI user (an Aqua session?): $(launchctl print "gui/$(id -u)" 2>&1 | head -n 1)"
  rustc -O --edition 2021 -o "$KEYS/mrspike" "$HERE/mrspike.rs" || { say "- mrspike did not build"; return 1; }
  mr "mkdir -p ~/$ROOT_REL && chmod 700 ~/$ROOT_REL && tmutil addexclusion ~/$ROOT_REL; echo tmutil=\$?" 2>&1 | tee -a "$OUT/setup.log"
  mr "cat > ~/$ROOT_REL/mrspike && chmod 755 ~/$ROOT_REL/mrspike" < "$KEYS/mrspike"
  mr "cat > ~/$ROOT_REL/spike.sh" < "$0"
  mr "cat > ~/$ROOT_REL/base.sbpl" < "$HERE/../../../runtime/crates/gleipnir/src/sbpl/base.sbpl"
  say "- the root: $(mr "ls -ld ~/$ROOT_REL" 2>&1)"
}

# --- on the runner (over ssh) ---

remote_plist() { # LABEL DIR SECS: a launchd job that writes its pid, sleeps SECS and writes `done`
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key><array>
    <string>/bin/sh</string><string>-c</string>
    <string>echo \$\$ &gt; $2/pid; /bin/sleep $3; date &gt; $2/done</string>
  </array>
  <key>StandardOutPath</key><string>$2/out.log</string>
  <key>StandardErrorPath</key><string>$2/out.log</string>
  <key>AbandonProcessGroup</key><false/>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
EOF
}

remote_s1_launchd() { # DIR LABEL SECS
  d=$1; mkdir -p "$d"; rm -f "$d"/*
  remote_plist "$2" "$d" "$3" > "$d/job.plist"
  launchctl bootstrap "user/$(id -u)" "$d/job.plist"; echo "bootstrap-rc=$?"
  sleep 2
  launchctl print "user/$(id -u)/$2" 2>&1 | grep -E '^\s*(state|pid|domain|type) ' | head -n 6
  echo "pid-file=$(cat "$d/pid" 2>/dev/null)"
}

remote_s1_setsid() { # DIR SECS
  d=$1; mkdir -p "$d"; rm -f "$d"/*
  ~/"$ROOT_REL"/mrspike detach "$d/out.log" -- /bin/sh -c "echo \$\$ > $d/pid; /bin/sleep $2; date > $d/done"
  sleep 1; echo "pid-file=$(cat "$d/pid" 2>/dev/null)"
}

remote_s1_bootout() { # DIR LABEL: start a long job with a child that leaves the session; bootout; what is left?
  d=$1; mkdir -p "$d"; rm -f "$d"/*
  cat > "$d/job.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$2</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string>
    <string>echo \$\$ &gt; $d/pid; /bin/sleep 600 &amp; echo \$! &gt; $d/child; ~/$ROOT_REL/mrspike escape 16 &gt; $d/escaped; wait</string></array>
  <key>AbandonProcessGroup</key><false/>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
  launchctl bootstrap "user/$(id -u)" "$d/job.plist"; echo "bootstrap-rc=$?"
  sleep 3
  launchctl bootout "user/$(id -u)/$2"; echo "bootout-rc=$?"
  sleep 3
  for f in pid child; do p=$(cat "$d/$f" 2>/dev/null); echo "$f=$p alive=$(kill -0 "$p" 2>/dev/null && echo yes || echo no)"; done
  e=$(awk '{print $2}' "$d/escaped" 2>/dev/null); echo "escaped=$e alive=$(kill -0 "$e" 2>/dev/null && echo yes || echo no)"
  [ -n "$e" ] && kill -9 "$e" 2>/dev/null
  true
}

remote() { # the runner-side entry: remote FUNCTION ARGS...
  f=$1; shift; "remote_$f" "$@"
}

cut_link() { # end every ssh session of the runner account: the master, then any sshd session left
  ssh -F "$KEYS/ssh_config" -O stop mr >/dev/null 2>&1 || true
  sleep 2
  sudo pkill -KILL -u "$U" sshd 2>/dev/null || true
  sudo pkill -KILL -u "$U" sshd-session 2>/dev/null || true
  sleep 3
  left=$(ps -axo user=,pid=,command= | awk -v u="$U" '$1 == u' | grep -E 'sshd' || true)
  [ -z "$left" ] || say "  - sshd processes of $U left after the cut: $left"
}

alive_as_root() { # FILE: the pid in FILE is alive?
  p=$(sudo cat "$1" 2>/dev/null)
  [ -n "$p" ] && sudo kill -0 "$p" 2>/dev/null && echo "yes ($p)" || echo "no (${p:-no pid})"
}

s1() {
  say "## S1: a job outlives its ssh session"
  r=$(root_of)
  out=$(mr "bash ~/$ROOT_REL/spike.sh remote s1_launchd ~/$ROOT_REL/s1-launchd drgnx-run.spike.s1 75" 2>&1)
  printf '%s\n' "$out" > "$OUT/s1-launchd.log"
  say "- launchd: \`bootstrap user/<uid>\` over ssh: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-600)"
  out=$(mr "bash ~/$ROOT_REL/spike.sh remote s1_setsid ~/$ROOT_REL/s1-setsid 75" 2>&1)
  printf '%s\n' "$out" > "$OUT/s1-setsid.log"
  say "- setsid launcher started: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  cut_link
  say "- after the link was cut (master stopped, sessions killed):"
  say "  - launchd job alive: $(alive_as_root "$r/s1-launchd/pid")"
  say "  - setsid job alive: $(alive_as_root "$r/s1-setsid/pid")"
  say "  - the user domain with no session: $(sudo launchctl print "user/$(uid_of)" 2>&1 | head -n 1)"
  sleep 80
  for k in launchd setsid; do
    if sudo test -f "$r/s1-$k/done"; then say "  - **$k: PASS** (wrote done after the cut: $(sudo cat "$r/s1-$k/done"))"
    else say "  - **$k: FAIL** (no done file; log: $(sudo cat "$r/s1-$k/out.log" 2>/dev/null | tail -n 3 | tr '\n' ' '))"; fi
  done
  out=$(mr "bash ~/$ROOT_REL/spike.sh remote s1_bootout ~/$ROOT_REL/s1-bootout drgnx-run.spike.s1b" 2>&1)
  printf '%s\n' "$out" > "$OUT/s1-bootout.log"
  say "- bootout of a job with a background child and an escaped child: $(printf '%s' "$out" | tr '\n' ' ')"
  out=$(mr "launchctl submit -l drgnx-run.spike.submit -- /bin/sleep 5; echo submit-rc=\$?; launchctl list | grep drgnx-run || true" 2>&1)
  say "- \`launchctl submit\` (legacy) over ssh: $(printf '%s' "$out" | tr '\n' ' ')"
}

s3() {
  say "## S3: the watchdog"
  mr "~/$ROOT_REL/mrspike watch --grant-mib 512 --report ~/$ROOT_REL/s3-oom.txt -- /bin/sh -c '~/$ROOT_REL/mrspike escape 320; ~/$ROOT_REL/mrspike hog 400 120'" > /dev/null 2>&1
  say "- 512 MiB grant, a 320 MiB child that left the session + a 400 MiB job: $(mr "cat ~/$ROOT_REL/s3-oom.txt" 2>&1 | tr '\n' ' ')"
  mr "~/$ROOT_REL/mrspike watch --grant-mib 100000 --report ~/$ROOT_REL/s3-idle.txt -- /bin/sleep 60" > /dev/null 2>&1
  say "- idle (a 60 s sleep): $(mr "cat ~/$ROOT_REL/s3-idle.txt" 2>&1 | tr '\n' ' ')"
  # a 16-way build: 16 clang workers over 320 compiles of one generated C file
  mr "mkdir -p ~/$ROOT_REL/s3-build && cd ~/$ROOT_REL/s3-build && { for i in \$(seq 1 1500); do echo \"int f\$i(int x){int s=0;for(int j=0;j<x;j++)s+=j*\$i%7;return s;}\"; done; } > big.c"
  mr "cd ~/$ROOT_REL/s3-build && ~/$ROOT_REL/mrspike watch --grant-mib 100000 --report ~/$ROOT_REL/s3-build.txt -- /bin/sh -c 'seq 1 320 | xargs -P16 -I{} /usr/bin/cc -O2 -c big.c -o o{}.o'" > /dev/null 2>&1
  say "- a 16-way compile: $(mr "cat ~/$ROOT_REL/s3-build.txt" 2>&1 | tr '\n' ' ')"
  say "- host: $(sysctl -n hw.ncpu) CPUs, $(( $(sysctl -n hw.memsize) >> 20 )) MiB"
}

# The draft build addition (design §5.4) on Gleipnir's base: shell text here for the spike; M5 builds it in Rust.
ancestors() { # PATH...: every directory above each path, once
  for p in "$@"; do
    q=$(dirname "$p")
    while [ "$q" != / ]; do echo "$q"; q=$(dirname "$q"); done
  done | sort -u
}

profile() { # SLOT ATTEMPT CACHE TOOLS DEVDIR USERDIR
  slot=$1 att=$2 cache=$3 tools=$4 dev=$5 udir=$6
  cat "$HERE/../../../runtime/crates/gleipnir/src/sbpl/base.sbpl" 2>/dev/null || cat "$HERE/base.sbpl"
  echo '; the build addition (draft, spike S2)'
  echo '(allow system-socket (socket-domain AF_UNIX))'
  echo '(deny file-read* (subpath "/Users"))'
  echo '(allow file-read* (literal "/"))'
  printf '(allow file-read-metadata'
  for p in /tmp /var /etc $(ancestors "$slot" "$att" "$cache" "$tools" "$dev" "$udir"); do printf ' (literal "%s")' "$p"; done
  echo ')'
  printf '(allow file-read*'
  for p in /usr /bin /sbin /System /Library /opt/homebrew /private/etc /dev/fd /private/var/select /private/var/db/timezone /private/var/db/xcode_select_link \
           "$dev" "$slot" "$att" "$cache" "$tools" "$udir"; do printf ' (subpath "%s")' "$p"; done
  echo ')'
  echo '(allow file-read* (literal "/dev/null") (literal "/dev/zero") (literal "/dev/random") (literal "/dev/urandom") (literal "/dev/tty") (literal "/dev/dtracehelper"))'
  echo '(deny file-read* (subpath "/opt/homebrew/var") (subpath "/usr/local/var"))'
  printf '(allow file-write*'
  for p in "$slot" "$att" "$cache" "$udir"; do printf ' (subpath "%s")' "$p"; done
  echo ')'
  echo '(allow mach-lookup (global-name "com.apple.bsd.dirhelper"))'
  echo '(deny network*)'
  echo '(deny network-outbound (remote unix-socket))'
}

remote_s2_build() { # the runner side: the profile, then the build under it, under the watchdog (observing only)
  r=~/$ROOT_REL; a=$r/att-s2; mkdir -p "$a/home" "$a/tmp" "$r/cache"
  udir=$(cd -P "$(getconf DARWIN_USER_DIR)/.." && pwd -P)
  dev=$(cd -P "$(xcode-select -p)" && pwd -P)
  profile "$(cd -P "$r/slot-nidhogg" && pwd -P)" "$(cd -P "$a" && pwd -P)" "$(cd -P "$r/cache" && pwd -P)" "$(cd -P "$r/tools" && pwd -P)" "$dev" "$udir" > "$a/build.sb"
  echo "developer dir: $dev; user dir: $udir"
  cd "$r/slot-nidhogg" || return 1
  start=$(date +%s)
  "$r/mrspike" watch --grant-mib 100000 --report "$a/watch.txt" -- /usr/bin/sandbox-exec -f "$a/build.sb" /usr/bin/env -i \
    HOME="$a/home" TMPDIR="$a/tmp/" PATH="$r/tools/cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    RUSTUP_HOME="$r/tools/rustup" CARGO_HOME="$r/cache/cargo" LANG=en_US.UTF-8 \
    /bin/bash nidhogg/build.sh --host --naglfar --dev --stage build --jobs 3 --build-dir "$a/nbuild" > "$a/build.log" 2>&1
  rc=$?
  echo "build-rc=$rc seconds=$(( $(date +%s) - start ))"
  cat "$a/watch.txt"
  tail -n 30 "$a/build.log"
}

s2_build() { # NIDHOGG_CHECKOUT
  say "## S2: a Nidhogg build with Naglfar under the draft build profile"
  r=$(root_of)
  sudo ditto "$1" "$r/slot-nidhogg"
  # the toolchain: the CI image's rustup, copied into the runner root (the design's setup job would install it there)
  sudo mkdir -p "$r/tools"
  sudo ditto "$HOME/.rustup" "$r/tools/rustup"
  sudo ditto "$HOME/.cargo/bin" "$r/tools/cargo/bin"
  sudo chown -R "$U:staff" "$r/slot-nidhogg" "$r/tools"
  out=$(mr "bash ~/$ROOT_REL/spike.sh remote s2_build" 2>&1)
  printf '%s\n' "$out" > "$OUT/s2-build.log"
  sudo cp "$r/att-s2/build.sb" "$OUT/s2-build.sb" 2>/dev/null; sudo chmod 644 "$OUT/s2-build.sb" 2>/dev/null
  sudo cp "$r/att-s2/build.log" "$OUT/s2-build-full.log" 2>/dev/null; sudo chmod 644 "$OUT/s2-build-full.log" 2>/dev/null
  say "- $(printf '%s' "$out" | grep -E 'build-rc=|developer dir' | tr '\n' ' ')"
  say "- watchdog during the build: $(printf '%s' "$out" | grep -E '^verdict=' | head -n 1)"
  if printf '%s' "$out" | grep -q 'build-rc=0'; then say "- **S2 build: PASS**"; else say "- **S2 build: FAIL** (tail in s2-build.log; denials below)"; fi
}

remote_s2_ert() { # SELECTOR EMACS (relative to the Nidhogg prefix)
  r=~/$ROOT_REL; a=$r/att-ert; mkdir -p "$a/home" "$a/tmp"
  udir=$(cd -P "$(getconf DARWIN_USER_DIR)/.." && pwd -P)
  dev=$(cd -P "$(xcode-select -p)" && pwd -P)
  profile "$(cd -P "$r/slot-drgnx" && pwd -P)" "$(cd -P "$a" && pwd -P)" "$(cd -P "$r/cache" && pwd -P)" "$(cd -P "$r/tools" && pwd -P)" "$dev" "$udir" > "$a/ert.sb"
  cd "$r/slot-drgnx" || return 1
  emacs=$r/tools/nidhogg/$2
  echo "emacs=$emacs"
  /usr/bin/sandbox-exec -f "$a/ert.sb" /usr/bin/env -i HOME="$a/home" TMPDIR="$a/tmp/" \
    PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" LANG=en_US.UTF-8 DRGNX_EMACS="$emacs" DRGNX_TEST_SELECTOR="$1" \
    /bin/bash bin/drgnx test > "$a/ert.log" 2>&1
  echo "ert-rc=$?"
  grep -E 'Ran [0-9]+ tests|unexpected' "$a/ert.log" | tail -n 5
}

s2_ert() { # DRGNX_CHECKOUT DRGNX_EMACS SELECTOR (the Nidhogg prefix is DRGNX_EMACS's ../..)
  say "## S2: drgnx ERT selectors under the draft build profile"
  r=$(root_of)
  sudo ditto "$1" "$r/slot-drgnx"
  sudo mkdir -p "$r/tools/nidhogg"
  prefix=$(cd -P "$(dirname "$2")/.." && pwd -P); rel=bin/$(basename "$2")
  sudo ditto "$prefix" "$r/tools/nidhogg"
  sudo chown -R "$U:staff" "$r/slot-drgnx" "$r/tools/nidhogg"
  out=$(mr "bash ~/$ROOT_REL/spike.sh remote s2_ert '$3' '$rel'" 2>&1)
  printf '%s\n' "$out" > "$OUT/s2-ert.log"
  sudo cp "$r/att-ert/ert.log" "$OUT/s2-ert-full.log" 2>/dev/null; sudo chmod 644 "$OUT/s2-ert-full.log" 2>/dev/null
  say "- $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-600)"
  if printf '%s' "$out" | grep -q 'ert-rc=0'; then say "- **S2 ERT: PASS**"; else say "- **S2 ERT: FAIL**"; fi
}

denials() {
  say "## Seatbelt denials (unified log, last 4 h)"
  sudo log show --last 4h --style compact --predicate 'eventMessage CONTAINS "deny("' 2>/dev/null | cut -c1-1000 > "$OUT/denials.log"
  say "- $(wc -l < "$OUT/denials.log" | tr -d ' ') lines; the distinct operation and path (first 200):"
  say '```'
  sed -n 's/.*deny([0-9]*) \([a-z*-]*\) \([^ ]*\).*/\1 \2/p' "$OUT/denials.log" | sort | uniq -c | sort -rn | head -n 200 | tee -a "$RES" >/dev/null
  grep -oE 'deny\([0-9]+\) (mach-lookup|sysctl-read|iokit-open|process-info[a-z-]*|signal|ipc-[a-z-]*) [^ ]+' "$OUT/denials.log" | sed 's/deny([0-9]*) //' | sort | uniq -c | sort -rn | head -n 50 | tee -a "$RES" >/dev/null
  say '```'
}

cmd=${1:-}; shift || true
case "$cmd" in
  up) up ;;
  s1) s1 ;;
  s3) s3 ;;
  s2-build) s2_build "$@" ;;
  s2-ert) s2_ert "$@" ;;
  denials) denials ;;
  remote) remote "$@" ;;
  *) echo "usage: spike.sh up|s1|s3|s2-build DIR|s2-ert DRGNX NIDHOGG SELECTOR|denials" >&2; exit 2 ;;
esac
