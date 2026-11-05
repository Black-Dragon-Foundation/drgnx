#!/usr/bin/env bash
# The fake fleet: N containers acting as SSH runners (fake-runner/Containerfile) and one harness container (the "hub")
# on one podman network. Run it through the heavy slot (see README.md); it starts only containers named
# $DRGNX_FLEET_PREFIX-<run>-*.
#   fleet.sh up --runners N [--max-sessions K] [--no-linger] [--sshd-opt OPT]...
#   fleet.sh exec I -- CMD...        as `runner` in runner I (1-based)
#   fleet.sh test FILTER             the test binary $DRGNX_FLEET_TEST_BIN in the harness, with --ignored FILTER
#   fleet.sh host BIN [FILTER...]    a runner-host test binary in every runner, with --ignored
#   fleet.sh down                    removes this run's containers, network and state
#   fleet.sh status                  prints this run's containers
set -euo pipefail
PREFIX=${DRGNX_FLEET_PREFIX:-bld-fleet}
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
RUN=${DRGNX_FLEET_RUN:-$(basename "$top" | tr -c 'a-zA-Z0-9' '-' | cut -c1-20 | sed 's/-*$//')}
STATE=${DRGNX_FLEET_DIR:-$top/.claude/tmp/fleet}/$RUN
NET=fleet-$RUN
IMAGE=localhost/drgnx-fake-runner:f45
BASE=registry.fedoraproject.org/fedora:45
HUB_IMAGE=${DRGNX_FLEET_HUB_IMAGE:-localhost/drgnx-dev:f45}
ORG=${DRGNX_ORG:-${top%%/drgnx/*}}   # the org folder: a worktree lives in <org>/drgnx/.claude/worktrees/NAME
name() { echo "$PREFIX-$RUN-$1"; }
die() { echo "fleet.sh: $*" >&2; exit 2; }
# every podman call names only our own prefix
mine() { podman ps -a --filter "name=^$PREFIX-$RUN-" --format '{{.Names}}'; }

up() {
  local n=1 max_sessions="" linger=1 opts=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --runners) n=$2; shift 2 ;;
      --max-sessions) max_sessions=$2; shift 2 ;;
      --no-linger) linger=0; shift ;;
      --sshd-opt) opts+=("$2"); shift 2 ;;
      *) die "up: unknown option $1" ;;
    esac
  done
  mkdir -p "$STATE/share"; chmod 700 "$STATE"
  # keys: a user CA, one hub key, and a certificate for it; plain key login works too
  [ -f "$STATE/ca" ] || ssh-keygen -q -t ed25519 -N '' -f "$STATE/ca" -C fleet-ca
  [ -f "$STATE/hub" ] || { ssh-keygen -q -t ed25519 -N '' -f "$STATE/hub" -C fleet-hub
    ssh-keygen -q -s "$STATE/ca" -I fleet-hub -n runner -V +1d "$STATE/hub.pub"; }
  cp "$STATE/ca.pub" "$STATE/ca.pub.share"; cp "$STATE/hub.pub" "$STATE/authorized_keys"
  # the pinned base image, from the host's store, loaded into each runner at first boot
  podman image exists "$BASE" || podman pull -q "$BASE" >/dev/null
  echo "base image digest: $(podman image inspect "$BASE" --format '{{.Digest}}')"
  rm -f "$STATE/base.tar"; podman save -q -o "$STATE/base.tar" "$BASE"
  podman build -q -t "$IMAGE" -f "$here/fake-runner/Containerfile" "$here/fake-runner" >/dev/null
  podman network exists "$NET" || podman network create "$NET" >/dev/null
  {
    printf 'MaxSessions %s\n' "${max_sessions:-10}"
    for o in ${opts[@]+"${opts[@]}"}; do printf '%s\n' "$o"; done
  } > "$STATE/50-fleet.conf"
  : > "$STATE/known_hosts"
  local i
  for i in $(seq 1 "$n"); do
    podman run -d --name "$(name r$i)" --hostname "r$i" --network "$NET" --network-alias "r$i" \
      --memory 3g --memory-swap 3g --systemd=always --device /dev/fuse --device /dev/net/tun \
      --security-opt label=disable --security-opt unmask=ALL --cap-add SYS_ADMIN ${DRGNX_FLEET_RUNNER_OPTS:-} \
      -v "$STATE/ca.pub.share:/fleet/ca.pub:ro" -v "$STATE/authorized_keys:/fleet/authorized_keys:ro" \
      -v "$STATE/base.tar:/fleet/base.tar:ro" -v "$STATE/share:/fleet/share:ro" -v "$STATE/50-fleet.conf:/etc/ssh/sshd_config.d/50-fleet.conf:ro" \
      "$IMAGE" >/dev/null
  done
  for i in $(seq 1 "$n"); do
    # wait on the announced state: the user manager of `runner` is up (the unit is active), not a sleep
    podman exec "$(name r$i)" systemctl is-system-running --wait >/dev/null 2>&1 || true
    podman exec "$(name r$i)" systemctl is-active --quiet sshd.service || die "runner $i: sshd is not active"
    [ "$linger" = 1 ] || podman exec "$(name r$i)" rm -f /var/lib/systemd/linger/runner
  done
  # the harness: the org folder mounted as ctr.sh does, a temporary HOME with the ssh config and known_hosts
  podman run -d --name "$(name hub)" --hostname hub --network "$NET" --memory 2g --memory-swap 2g --init \
    --security-opt label=disable -v "$ORG:$ORG" -v "$STATE:$STATE" -w "$top" -e HOME="$STATE/home" \
    "$HUB_IMAGE" sleep infinity >/dev/null
  mkdir -p "$STATE/home/.ssh"; chmod 700 "$STATE/home/.ssh"
  cp "$STATE/hub" "$STATE/home/.ssh/id_ed25519"; cp "$STATE/hub-cert.pub" "$STATE/home/.ssh/id_ed25519-cert.pub"
  : > "$STATE/home/.ssh/known_hosts"
  for i in $(seq 1 "$n"); do
    # host keys are learned at the first connection by the code under test; scan only so a bare `ssh` works
    podman exec "$(name hub)" bash -c "ssh-keyscan -q r$i >> '$STATE/home/.ssh/known_hosts' 2>/dev/null" || true
    printf 'Host r%s\n  User runner\n  IdentityFile %s/home/.ssh/id_ed25519\n  UserKnownHostsFile %s/home/.ssh/known_hosts\n' \
      "$i" "$STATE" "$STATE" >> "$STATE/home/.ssh/config"
  done
  echo "fleet $RUN up: $n runner(s); harness HOME=$STATE/home"
}

exec_runner() {
  local i=$1; shift; [ "${1:-}" = -- ] && shift
  podman exec -i "$(name r$i)" runuser -u runner -- env XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "$@"
}

# host BIN [FILTER...]: a runner-host test binary (`#[ignore = "runner-host"]` rows), run with --ignored in every
# runner as `runner`; a `sleipnir` binary next to BIN goes along, and the tests find it as SLEIPNIR_TEST_BIN
host_tests() {
  local bin=$1 rc=0 c; shift
  cp "$bin" "$STATE/share/runner_host"
  [ ! -x "$(dirname "$bin")/../sleipnir" ] || cp "$(dirname "$bin")/../sleipnir" "$STATE/share/sleipnir"
  for c in $(mine | grep -- '-r[0-9]*$'); do
    echo "== $c"
    podman exec -i "$c" runuser -u runner -- env XDG_RUNTIME_DIR=/run/user/1000 \
      DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus SLEIPNIR_TEST_BIN=/fleet/share/sleipnir \
      /fleet/share/runner_host --ignored --test-threads=1 "$@" || rc=1
  done
  return $rc
}

# --container: the slot scripts wrap a command in the dev container unless its words say it handles its own
# containers; this script starts podman itself, so the heavy slot must run it on the host: `$HEAVY fleet.sh --container up`
[ "${1:-}" = --container ] && shift
case "${1:-}" in
  up) shift; up "$@" ;;
  exec) shift; i=$1; shift; exec_runner "$i" "$@" ;;
  test) shift; bin=${DRGNX_FLEET_TEST_BIN:?set DRGNX_FLEET_TEST_BIN to the container-built test binary}
        podman exec -e HOME="$STATE/home" "$(name hub)" "$bin" --ignored "$@" ;;
  put) shift; for f in "$@"; do cp "$f" "$STATE/share/"; done ;;   # files appear in every runner at /fleet/share
  check-linger)   # log in over ssh, start a unit, log out, log in again: the unit is still active
        h=$(name hub)
        podman exec -e HOME="$STATE/home" "$h" ssh -F "$STATE/home/.ssh/config" r1 'systemd-run --user --unit=s1-linger --collect sleep 600'
        podman exec -e HOME="$STATE/home" "$h" ssh -F "$STATE/home/.ssh/config" r1 'systemctl --user is-active s1-linger' ;;
  host) shift; host_tests "$@" ;;
  s1)   # the fake runner's own checks (sleipnir's runner-host tests that pin the image): build, run in every runner
        args=(test -p sleipnir --no-default-features --features linux --test runner_host --no-run --message-format=json)
        if [ -n "${DRGNX_FLEET_HOST_RUSTC:-}" ]; then   # CI: the runner's own toolchain
          out=$(cd "$top" && cargo "${args[@]}" --locked --manifest-path runtime/Cargo.toml)
        else
          out=$(cd "$top" && DRGNX_BUILDER=local "$ORG/.claude/tmp/ratatoskr-cargo.sh" "${args[@]}")
        fi
        bin=$(printf '%s\n' "$out" | grep -o '"executable":"[^"]*runner_host-[^"]*"' | tail -1 | cut -d'"' -f4)
        [ -n "$bin" ] || die "s1: the runner_host test binary was not built"
        host_tests "$bin" check_limits_passes_inside_a_fake_runner a_capped_container_runs_in_a_transient_slice \
          the_container_gets_its_caps linger_keeps_a_unit_after_the_session_ends ;;
  status) mine ;;
  down) for c in $(mine); do podman rm -f -v "$c" >/dev/null; done
        podman network rm -f "$NET" >/dev/null 2>&1 || true
        rm -r "$STATE" 2>/dev/null || true ;;
  *) die "usage: fleet.sh up|exec|test|host|s1|put|check-linger|status|down" ;;
esac
