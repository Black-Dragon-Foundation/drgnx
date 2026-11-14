#!/bin/bash
# The macOS lane's localhost sshd for `drgnx-ratatoskr`'s `macos::the_generated_config_against_a_localhost_sshd`
# (docs/develop/ci.md, "macOS"): Remote Login on, a throwaway key that may log in to the runner user, and one
# `Host` entry in ~/.ssh/config that names it. `up` prints the host name the row takes as DRGNX_TEST_SSHD_HOST;
# `down` takes everything back (a runner is thrown away after the job, so this is only for a self-hosted Mac).
#   macos-sshd.sh up DIR      DIR holds the key (a fresh folder; the caller removes it)
#   macos-sshd.sh down DIR
set -euo pipefail

host=drgnx-sshd-test
marker="# drgnx-sshd-test"
ssh_dir=$HOME/.ssh

usage() { echo "usage: macos-sshd.sh up|down DIR" >&2; exit 2; }
[ $# -eq 2 ] || usage
cmd=$1 dir=$2

case "$cmd" in
  up)
    [ "$(uname -s)" = Darwin ] || { echo "macos-sshd.sh: macOS only" >&2; exit 2; }
    mkdir -p "$dir" "$ssh_dir"
    chmod 700 "$ssh_dir"
    ssh-keygen -q -t ed25519 -N '' -C drgnx-sshd-test -f "$dir/key"
    touch "$ssh_dir/authorized_keys" "$ssh_dir/config"
    chmod 600 "$ssh_dir/authorized_keys" "$ssh_dir/config"
    printf '%s %s\n' "$(cat "$dir/key.pub")" "$marker" >> "$ssh_dir/authorized_keys"
    # the user's own file comes first in the generated config's Include, so this entry is what `ssh <host>` reads
    {
      printf '%s\n' "$marker begin"
      printf 'Host %s\n  HostName 127.0.0.1\n  IdentityFile %s\n  IdentitiesOnly yes\n' "$host" "$dir/key"
      printf '%s\n' "$marker end"
    } >> "$ssh_dir/config"
    sudo launchctl enable system/com.openssh.sshd
    sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
    # sshd starts on the first connection (launchd's socket): the host key is read once it answers
    ssh-keyscan -T 10 -t ed25519 127.0.0.1 >> "$ssh_dir/known_hosts"
    ssh -o ConnectionAttempts=10 -o ConnectTimeout=5 -o BatchMode=yes "$host" true
    echo "$host"
    ;;
  down)
    if [ -f "$ssh_dir/authorized_keys" ]; then
      grep -vF "$marker" "$ssh_dir/authorized_keys" > "$dir.keys" || true
      cat "$dir.keys" > "$ssh_dir/authorized_keys"
      rm -f "$dir.keys"
    fi
    if [ -f "$ssh_dir/config" ]; then
      awk -v b="$marker begin" -v e="$marker end" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0}' \
        "$ssh_dir/config" > "$dir.config"
      cat "$dir.config" > "$ssh_dir/config"
      rm -f "$dir.config"
    fi
    sudo launchctl bootout system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
    ;;
  *) usage ;;
esac
