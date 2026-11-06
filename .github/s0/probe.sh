#!/usr/bin/env bash
# S0 probes: P9 (Q8's nine checks), P4 (stdio, detach keys), P6 (podman import). Local only (org folder).
# Usage: probe.sh SECTION PATH...   SECTION = p9 | p4 | detach | p6 | setup-ssh | service | all
# Runs on the host under test (the VM gate). Needs: busybox and alpine/socat images, sudo -n for ausearch.
D=$(cd "$(dirname "$0")" && pwd)
. "$D/lib.sh"
trap cleanup EXIT

H4=$(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')
H6=$(ip -o -6 addr show scope global | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')

service_up() {  # the API service the remote and ssh paths talk to; CONF: an optional CONTAINERS_CONF_OVERRIDE
  local conf=${1:-}
  mkdir -p "$(dirname "$SOCK")"
  rm -f "$SOCK"
  if [ -n "$conf" ]; then
    CONTAINERS_CONF_OVERRIDE=$conf podman system service --time=0 "unix://$SOCK" &
  else
    podman system service --time=0 "unix://$SOCK" &
  fi
  SRVPID=$!; PIDS+=("$SRVPID")
  timeout 20 bash -c "until [ -S '$SOCK' ]; do sleep 0.1; done" || note "service socket not up"
  podman --remote --url "unix://$SOCK" version --format 'service up: server {{.Server.Version}}'
}

service_down() {
  kill "$SRVPID" 2>/dev/null; wait "$SRVPID" 2>/dev/null
}

setup_ssh() {  # Step 4's ssh:// connection to this host's own sshd, with S0's key (copied in by the caller)
  chmod 600 "$HOME/s0key"
  ssh -i "$HOME/s0key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
    "$USER@127.0.0.1" true && echo "ssh to 127.0.0.1: ok"
  podman system connection rm s0-ssh >/dev/null 2>&1
  podman system connection add s0-ssh --identity "$HOME/s0key" "ssh://$USER@127.0.0.1$SOCK"
  podman system connection list
}

p9() {
  set_path "$1"
  say "P9 (Q8) on $PATHNAME: server $("${P[@]}" version --format '{{.Server.Version}}')"
  local sp jp out rc sidekeep=()

  note "check 1: the pair starts (sidecar default userns as 65534, job keep-id)"
  side_up bld-s0-side "$B" nc -lk -s 127.0.0.1 -p 3128 -e cat
  out=$("${P[@]}" run -d "${JOB[@]}" --network=container:bld-s0-side --name bld-s0-job "$B" sleep 600 2>&1); rc=$?
  echo "job start rc=$rc ${out:0:300}"
  if [ $rc -ne 0 ]; then
    note "check 1: refused; retry with both keep-id"
    side_down bld-s0-side; podman rm -f -t 0 bld-s0-side bld-s0-job >/dev/null 2>&1
    sidekeep=(--userns=keep-id)
    side_up bld-s0-side "${sidekeep[@]}" "$B" nc -lk -s 127.0.0.1 -p 3128 -e cat
    "${P[@]}" run -d "${JOB[@]}" --network=container:bld-s0-side --name bld-s0-job "$B" sleep 600; echo "retry rc=$?"
  fi
  "${P[@]}" ps -a --filter name=bld-s0 --format '{{.Names}} {{.Status}} netmode={{.Networks}}'
  echo "sidecar argv: podman run ${SIDE[*]} ${sidekeep[*]} --name bld-s0-side --entrypoint sh $B -c 'nc -lk -s 127.0.0.1 -p 3128 -e cat & ...; echo READY; cat >/dev/null; kill ...'"
  echo "job argv:     podman run -d ${JOB[*]} --network=container:bld-s0-side --name bld-s0-job $B sleep 600"
  podman inspect --format 'job: NetworkMode={{.HostConfig.NetworkMode}} UsernsMode={{.HostConfig.UsernsMode}} Deps={{.Dependencies}}' bld-s0-job

  note "check 2: one netns, owned by the sidecar's user namespace"
  sp=$(ctrpid bld-s0-side); jp=$(ctrpid bld-s0-job)
  echo "pids: sidecar $sp job $jp"
  echo "netns in side: $("${P[@]}" exec bld-s0-side readlink /proc/self/ns/net)  in job: $("${P[@]}" exec bld-s0-job readlink /proc/self/ns/net)"
  podman unshare sh -c "echo userns: sidecar \$(readlink /proc/$sp/ns/user) job \$(readlink /proc/$jp/ns/user) pause \$(readlink /proc/self/ns/user); lsns -t net -p $sp -o NS,ONS,NPROCS,PID,COMMAND; lsns -t net -p $jp -o NS,ONS,NPROCS,PID,COMMAND; lsns -t user -p $jp -o NS,PNS,ONS,PID,COMMAND"
  echo "uid_map side: $(podman unshare cat /proc/$sp/uid_map | tr -s ' ' | tr '\n' ';')  job: $(podman unshare cat /proc/$jp/uid_map | tr -s ' ' | tr '\n' ';')"
  echo "job's caps in its netns: $("${P[@]}" exec bld-s0-job sh -c 'ip link add bld0 type dummy 2>&1; ip link set lo down 2>&1' | tr '\n' ' ')"

  note "check 3: reach from the job (host v4: $H4 v6: $H6)"
  "${P[@]}" exec -e "H4=$H4" -e "H6=$H6" bld-s0-job sh -c '
    echo "addr:"; ip -o addr; echo "link:"; ip -o link; echo "route4:[$(ip route 2>&1)] route6:[$(ip -6 route 2>&1)]"
    for t in 1.1.1.1:443 169.254.1.1:53 169.254.1.2:80 10.0.2.2:80 host.containers.internal:80; do
      o=$(wget -T 2 -q -O- "http://$t/" 2>&1 | head -1); echo "$t $o"; done
    for a in $H4; do for p in 22 80; do o=$(wget -T 2 -q -O- "http://$a:$p/" 2>&1 | head -1); echo "$a:$p $o"; done; done
    for a in $H6 2606:4700:4700::1111; do o=$(wget -T 2 -q -O- "http://[$a]:22/" 2>&1 | head -1); echo "[$a]:22 $o"; done
    echo "relay 127.0.0.1:3128: [$(echo ping-relay | nc -w 2 127.0.0.1 3128 2>&1)]"
    echo "relay [::1]:3128: [$(wget -T 2 -q -O- "http://[::1]:3128/" 2>&1 | head -1)]"'

  note "check 4: the job can't take 127.0.0.1:3128"
  "${P[@]}" exec bld-s0-job sh -c 'o=$(timeout 3 nc -l -s 127.0.0.1 -p 3128 2>&1); echo "job nc bind 127.0.0.1:3128 rc=$? $o"; o=$(timeout 3 nc -l -s 0.0.0.0 -p 3128 2>&1); echo "job nc bind 0.0.0.0:3128 rc=$? $o"'
  # a sidecar stand-in that sets SO_REUSEPORT, then jobs that set it too, as the job's uid and as 65534 (same kuid)
  side_up bld-s0-side-rp "$S" socat -d TCP-LISTEN:3128,bind=127.0.0.1,reuseaddr,reuseport,fork EXEC:cat
  for u in keep-id-uid 65534 0; do
    local uf=(); [ "$u" != keep-id-uid ] && uf=(--user "$u:$u")
    out=$("${P[@]}" run "${JOB[@]}" "${uf[@]}" --network=container:bld-s0-side-rp --name bld-s0-job-rp --entrypoint timeout "$S" 3 socat TCP-LISTEN:3128,bind=127.0.0.1,reuseport EXEC:cat 2>&1); rc=$?
    echo "job as $u, SO_REUSEPORT, vs a SO_REUSEPORT listener (65534): rc=$rc (124/143 = bound and waited) ${out:0:200}"
  done
  out=$("${P[@]}" run "${JOB[@]}" --user 65534:65534 --network=container:bld-s0-side --name bld-s0-job-rp --entrypoint timeout "$S" 3 socat TCP-LISTEN:3128,bind=127.0.0.1,reuseport EXEC:cat 2>&1); rc=$?
  echo "job as 65534, SO_REUSEPORT, vs the plain listener (65534, no SO_REUSEPORT): rc=$rc ${out:0:200}"
  side_down bld-s0-side-rp

  note "check 5: sysctls under container:"
  out=$("${P[@]}" run "${JOB[@]}" --network=container:bld-s0-side --name bld-s0-job-sc --sysctl net.ipv4.ip_unprivileged_port_start=0 "$B" cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>&1); rc=$?
  echo "job --sysctl net.ipv4.ip_unprivileged_port_start=0: rc=$rc out=[$out]"
  out=$("${P[@]}" run "${JOB[@]}" --network=container:bld-s0-side --name bld-s0-job-sc --sysctl net.ipv6.conf.all.disable_ipv6=1 "$B" cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>&1); rc=$?
  echo "job --sysctl net.ipv6.conf.all.disable_ipv6=1: rc=$rc out=[$out]"
  echo "ping_group_range: sidecar [$("${P[@]}" exec bld-s0-side cat /proc/sys/net/ipv4/ping_group_range)] job [$("${P[@]}" exec bld-s0-job cat /proc/sys/net/ipv4/ping_group_range)]"
  echo "ip_unprivileged_port_start in the shared netns: $("${P[@]}" exec bld-s0-job cat /proc/sys/net/ipv4/ip_unprivileged_port_start)"
  grep -n -A3 '^default_sysctls' /usr/share/containers/containers.conf /etc/containers/containers.conf 2>/dev/null | head -8

  note "check 7: labels"
  ps -o label=,pid=,user=,comm= -p "$sp,$jp"
  avc "P9 $PATHNAME"

  note "check 8: /etc/hosts, resolv.conf; --dns"
  for c in bld-s0-side bld-s0-job; do
    echo "$c /etc/hosts: [$("${P[@]}" exec $c cat /etc/hosts 2>&1 | tr '\n' ';')]"
    echo "$c /etc/resolv.conf: [$("${P[@]}" exec $c cat /etc/resolv.conf 2>&1 | tr '\n' ';')]"
    echo "$c /etc/hostname: [$("${P[@]}" exec $c cat /etc/hostname 2>&1 | tr '\n' ';')]"
  done
  out=$("${P[@]}" run --rm --network=none --dns=none --name bld-s0-dns1 "$B" cat /etc/resolv.conf 2>&1); echo "sidecar --network=none --dns=none: rc=$? [${out:0:200}]"
  out=$("${P[@]}" run --rm --network=none --dns=192.0.2.1 --name bld-s0-dns2 "$B" cat /etc/resolv.conf 2>&1); echo "sidecar --network=none --dns=192.0.2.1: rc=$? [${out:0:200}]"
  out=$("${P[@]}" run "${JOB[@]}" --network=container:bld-s0-side --dns=none --name bld-s0-job-dns "$B" cat /etc/resolv.conf 2>&1); echo "job container: --dns=none: rc=$? [${out:0:200}]"
  out=$("${P[@]}" run "${JOB[@]}" --network=container:bld-s0-side --dns=192.0.2.1 --name bld-s0-job-dns "$B" cat /etc/resolv.conf 2>&1); echo "job container: --dns=192.0.2.1: rc=$? [${out:0:200}]"
  out=$("${P[@]}" run "${JOB[@]}" --network=container:bld-s0-side --add-host=x:192.0.2.1 --name bld-s0-job-dns "$B" true 2>&1); echo "job container: --add-host: rc=$? [${out:0:200}]"
  out=$("${P[@]}" run "${JOB[@]}" --network=container:bld-s0-side --hostname=j --name bld-s0-job-dns "$B" hostname 2>&1); echo "job container: --hostname: rc=$? [${out:0:200}]"

  note "check 6: lifecycle"
  out=$("${P[@]}" rm bld-s0-side 2>&1); echo "rm of the running sidecar with the job alive: rc=$? ${out:0:300}"
  out=$("${P[@]}" rm -f -t 0 bld-s0-side 2>&1); echo "rm -f of the sidecar with the job alive: rc=$? ${out:0:300}"
  "${P[@]}" ps -a --filter name=bld-s0 --format '{{.Names}} {{.Status}}'
  "${P[@]}" kill bld-s0-side; echo "kill sidecar rc=$?"
  timeout 30 tail --pid="${SP[bld-s0-side]}" -f /dev/null; wait "${SP[bld-s0-side]}"; echo "sidecar client exit=$?"
  side_close bld-s0-side
  "${P[@]}" ps -a --filter name=bld-s0 --format 'after kill: {{.Names}} {{.Status}}'
  "${P[@]}" exec bld-s0-job sh -c 'echo "job after the kill: $(ip -o addr | tr "\n" ";") relay:[$(echo x | nc -w 2 127.0.0.1 3128 2>&1)]"'
  out=$("${P[@]}" rm -f -t 0 bld-s0-job 2>&1); echo "rm -f job: rc=$? $out"
  "${P[@]}" ps -a --filter name=bld-s0 --format 'after job rm: {{.Names}} {{.Status}}'
  echo "left: [$("${P[@]}" ps -a --filter name=bld-s0 --format '{{.Names}}' | tr '\n' ' ')]"
  rm_ours
  avc "P9 $PATHNAME end"
}

p4() {
  set_path "$1"
  say "P4 stdio on $PATHNAME"
  local out rc kp t0 t1 t2
  out=$(printf 'hello\n' | "${P[@]}" run -i --rm --log-driver=none --detach-keys= --name bld-s0-p4a "$B" cat 2>&1); echo "both ways: [$out]"
  out=$("${P[@]}" run -i --rm --log-driver=none --detach-keys= --name bld-s0-p4b "$B" sh -c 'cat >/dev/null; echo EOF-SEEN' </dev/null 2>&1); echo "stdin EOF reaches it: [$out]"
  rm -f "$W/k.in" "$W/k.out"; mkfifo "$W/k.in" "$W/k.out"
  "${P[@]}" run -i --log-driver=none --detach-keys= --name bld-s0-p4k "$B" sh -c 'echo R; cat >/dev/null; echo EOF-SEEN' <"$W/k.in" >"$W/k.out" 2>&1 &
  kp=$!; PIDS+=("$kp")
  exec 8>"$W/k.in" 9<"$W/k.out"
  IFS= read -r -t 60 out <&9; echo "kill test: container up [$out]"
  t0=$EPOCHREALTIME; kill -9 "$kp"; wait "$kp" 2>/dev/null; exec 9<&-
  out=$(timeout 30 podman wait bld-s0-p4k 2>&1); rc=$?; t1=$EPOCHREALTIME
  echo "client kill -9: container exit=[$out] wait rc=$rc after $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}') s; state $(podman inspect --format '{{.State.Status}} {{.State.ExitCode}}' bld-s0-p4k 2>&1)"
  exec 8>&-
  podman rm -f -t 0 bld-s0-p4k >/dev/null 2>&1
  avc "P4 $PATHNAME"
}

detach() {
  set_path "$1"
  say "P4 detach keys on $PATHNAME (client override: ${2:-none}; keys ${3:-default})"
  local conf=${2:-} keys=${3:-$'\x10\x11'} f out rc t0 t1 n=0 envs=()
  [ -n "$conf" ] && { keys=q; envs=(CONTAINERS_CONF_OVERRIDE="$conf"); }
  for f in with without; do
    local fl=(); [ $f = with ] && fl=(--detach-keys=)
    n=$((n + 1))
    t0=$EPOCHREALTIME
    out=$({ for ((i = 0; i < ${#keys}; i++)); do printf '%s' "${keys:i:1}"; sleep 0.5; done; sleep 4; } |
      { timeout -s KILL 20 env "${envs[@]}" "${P[@]}" run -i --log-driver=none "${fl[@]}" --name bld-s0-dk$n "$B" sh -c 'cat >/dev/null; echo EOF-SEEN' 2>&1
        echo "client ended rc=$? (137: killed, still attached at 20 s; the remote client forwards SIGTERM) at +$(awk -v a="$t0" -v b="$EPOCHREALTIME" 'BEGIN{printf "%.2f", b-a}') s"; })
    timeout 10 podman wait bld-s0-dk$n >/dev/null 2>&1 || note "bld-s0-dk$n still $(podman inspect --format '{{.State.Status}}' bld-s0-dk$n) 10 s after its client ended"
    local fin; fin=$(podman inspect --format '{{.State.FinishedAt}}' bld-s0-dk$n 2>&1); fin=${fin% UTC}
    echo "$f --detach-keys=, keys$(printf '%s' "$keys" | od -An -tx1 | tr -s ' ') one byte each 0.5 s apart, stdin held ~4 s more: out=[$(echo "$out" | tr '\n' ';')] container $(podman inspect --format '{{.State.Status}} exit {{.State.ExitCode}}' bld-s0-dk$n 2>&1), ended at +$(awk -v a="$t0" -v b="$(date -d "$fin" +%s.%N 2>/dev/null)" 'BEGIN{printf "%.2f", b-a}') s"
    podman rm -f -t 0 bld-s0-dk$n >/dev/null 2>&1
  done
}

p6() {
  set_path "$1"
  say "P6 podman import on $PATHNAME"
  local tag=$PX
  [ "$PATHNAME" != local ] && tag=localhost/bld-s0-px:$PATHNAME
  "${P[@]}" image exists "$tag" && "${P[@]}" rmi "$tag" >/dev/null
  "${P[@]}" import --change 'ENTRYPOINT ["/px"]' "$W/px.tar" "$tag"; echo "import rc=$?"
  "${P[@]}" image inspect --format 'entrypoint={{.Config.Entrypoint}} user=[{{.Config.User}}]' "$tag"
  out=$("${P[@]}" run "${SIDE[@]}" --name bld-s0-p6 "$tag" --version </dev/null 2>&1); echo "run as 65534, read-only, --network=none: rc=$? [$(echo "$out" | head -1)]"
  out=$("${P[@]}" run "${SIDE[@]}" --name bld-s0-p6 --entrypoint /px "$tag" --version </dev/null 2>&1); echo "same with --entrypoint: rc=$? [$(echo "$out" | head -1)]"
  [ "$PATHNAME" != local ] && "${P[@]}" rmi "$tag" >/dev/null
  avc "P6 $PATHNAME"
}

sec=$1; shift
case $sec in
  service) service_up "$@"; wait "$SRVPID" ;;
  p9 | p4 | p6) service_up; [[ " $* " == *" ssh "* ]] && setup_ssh; for p in "$@"; do $sec "$p"; done; service_down ;;
  detach) service_up; [[ " $* " == *" ssh "* ]] && setup_ssh
    for p in "$@"; do detach "$p"; detach "$p" "$W/dk.conf"; done; service_down
    note "server started with detach_keys=q"
    service_up "$W/dk.conf"; for p in "$@"; do [ "$p" != local ] && detach "$p" "" q; done; service_down ;;
  *) echo "usage: probe.sh p9|p4|detach|p6 PATH..." >&2; exit 2 ;;
esac
