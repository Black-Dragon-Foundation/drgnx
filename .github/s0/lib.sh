# S0 spike helpers (container-net relay plan, Task S0). Sourced by probe.sh and timing.sh. Local only.
# Every container, image and network is named bld-s0-*; cleanup removes jobs, then sidecars, then the rest.
set -u
B=docker.io/library/busybox:1.37
S=docker.io/alpine/socat:latest
PX=localhost/bld-s0-px:s0
W=${S0_WORK:-$HOME/s0w}
mkdir -p "$W"
UIDN=$(id -u)
SOCK=/run/user/$UIDN/podman/podman.sock
PIDS=()

# the sidecar's flags from the plan's Global Constraints (Q8: --network=none)
SIDE=(-i --rm --pull=never --log-driver=none --detach-keys= --user 65534:65534 --cap-drop=all
  --security-opt=no-new-privileges --read-only --pids-limit 32 --memory 128m --memory-swap 128m --cpus 1
  --label drgnx.owner=s0 --label drgnx.job=s0 --network=none)
# the job's flags as sleipnir's argv makes them today, with the Q8 network
JOB=(--rm --pull=never --userns=keep-id --cap-drop=all --security-opt=no-new-privileges --read-only --tmpfs /tmp
  --pids-limit 512 --memory 1G --memory-swap 1G --cpus 2 --oom-score-adj=1000 --cgroup-conf=memory.oom.group=1
  --label drgnx.owner=s0 --label drgnx.job=s0
  -e HTTP_PROXY=http://127.0.0.1:3128 -e HTTPS_PROXY=http://127.0.0.1:3128
  -e NO_PROXY=localhost,127.0.0.1,::1)

say() { printf '\n=== %s\n' "$*"; }
note() { printf -- '--- %s\n' "$*"; }

# P: the podman of the path under test; set_path local|remote|ssh
set_path() {
  case $1 in
    local) P=(podman) ;;
    remote) P=(podman --remote --url "unix://$SOCK") ;;
    ssh) P=(podman --remote --connection s0-ssh) ;;
  esac
  PATHNAME=$1
}

rm_ours() {
  local pat n
  for pat in '^bld-s0-job' '^bld-s0-side' '^bld-s0-'; do
    for n in $(podman ps -a --format '{{.Names}}' --filter "name=$pat"); do
      podman rm -f -t 0 "$n" >/dev/null 2>&1 || echo "cleanup: could not remove $n"
    done
  done
}

cleanup() {
  local p
  set +e
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  rm_ours
  for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null; done
  for p in "${!SF[@]}"; do side_close "$p" 2>/dev/null; done
  for p in "${!SO[@]}"; do [ -n "${SO[$p]}" ] && exec {SO[$p]}<&-; done 2>/dev/null
  exec 8>&- 2>/dev/null
  podman images --format '{{.Repository}}:{{.Tag}}' | grep '^localhost/bld-s0-' | xargs -r podman rmi >/dev/null 2>&1
  rm -f "$W"/*.in
}

# The sidecar stand-in, attached (-i) like the relay: stdin a fifo we hold open, stdout a fifo whose first line is
# READY (the relay's READY, in small); it exits at stdin EOF. NAME [FLAGS] IMAGE LISTENER...
declare -A SP SF SO
side_up() {
  local name=$1 fd ofd line flags=(); shift
  while [ "${1:0:2}" = -- ]; do flags+=("$1"); shift; done
  local image=$1; shift
  rm -f "$W/$name.in" "$W/$name.out"; mkfifo "$W/$name.in" "$W/$name.out"
  "${P[@]}" run "${SIDE[@]}" "${flags[@]}" --name "$name" --entrypoint sh "$image" \
    -c "$* & l=\$!; echo READY; cat >/dev/null; kill \$l" <"$W/$name.in" >"$W/$name.out" 2>&1 &
  SP[$name]=$!; PIDS+=("$!")
  exec {fd}>"$W/$name.in"; SF[$name]=$fd
  exec {ofd}<"$W/$name.out"; SO[$name]=$ofd
  if IFS= read -r -t 60 line <&"$ofd" && [ "$line" = READY ]; then :; else note "side_up: $name: [$line]"; fi
}

side_close() { [ -n "${SF[$1]:-}" ] && exec {SF[$1]}>&-; SF[$1]=; }  # stdin EOF to the sidecar

side_down() {  # close the sidecar's stdin and wait for its client
  side_close "$1"
  timeout 30 tail --pid="${SP[$1]}" -f /dev/null || note "side_down: $1's client still running"
  [ -n "${SO[$1]:-}" ] && exec {SO[$1]}<&-; SO[$1]=
}

avc() {
  local a
  command -v ausearch >/dev/null || { echo "AVC ($1): n/a (no ausearch; LSM $(cat /sys/kernel/security/lsm))"; return; }
  a=$(sudo -n ausearch -m avc,user_avc -ts recent 2>&1 | grep -E 'denied' | head -5)
  echo "AVC ($1): ${a:-none}"
}

ctrpid() { podman inspect --format '{{.State.Pid}}' "$1"; }
