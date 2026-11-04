#!/bin/sh
# handshake-shim.sh COMMAND [ARG...] -- run a third-party binary as one job in its own process group and speak the
# announce-and-park protocol for it (docs/develop/harness.md, "Announce and park").
#   DRGNX-STATE: RUNNING   the job is started; the shim now waits for the job.
#   DRGNX-STATE: STOPPED   the job and every process of its group are gone (zombies do not count).
# A TERM, INT, HUP, USR1 or USR2 sent to the shim goes to the whole group.  After STOPPED the shim waits for a line
# GO on its standard input and exits.
set -m
for sig in TERM INT HUP USR1 USR2; do
	trap "kill -s $sig -- -\$job 2>/dev/null" "$sig"
done
job=
"$@" </dev/null >&2 &
job=$!
printf 'DRGNX-STATE: RUNNING\n'
while kill -0 "$job" 2>/dev/null; do
	wait "$job"
done

# members of the group that are not zombies; without /proc, any member at all
group_alive() {
	if [ -d /proc/self ]; then
		for stat in /proc/[0-9]*/stat; do
			s=$(cat "$stat" 2>/dev/null) || continue
			set -- ${s##*) }
			[ "$1" != Z ] && [ "$3" = "$job" ] && return 0
		done
		return 1
	fi
	kill -0 -- "-$job" 2>/dev/null
}
while group_alive; do
	sleep 0.05
done
printf 'DRGNX-STATE: STOPPED\n'
read -r go
