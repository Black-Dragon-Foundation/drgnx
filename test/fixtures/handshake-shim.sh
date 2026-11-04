#!/bin/sh
# handshake-shim.sh COMMAND [ARG...] -- run a third-party binary as one job in its own process group and speak the
# announce-and-park protocol for it (docs/develop/harness.md, "Announce and park").
#   DRGNX-STATE: RUNNING   the job is started; the shim parks: it waits for a line GO before it waits for the job.
#   DRGNX-STATE: STOPPED   the job and every process of its group are gone (zombies do not count); the shim parks,
#                          then exits.
# A TERM, INT, HUP, USR1 or USR2 sent to the shim goes to the whole group.  The job itself runs while the shim is
# parked (a third-party binary cannot park): the shim, the process the test signals, says nothing more until GO.
set -m
for sig in TERM INT HUP USR1 USR2; do
	trap "kill -s $sig -- -\$job 2>/dev/null" "$sig"
done

# a line GO on standard input; a read a signal cut short is read again, and the end of the input ends the wait
park() {
	while :; do
		if read -r go; then
			[ "$go" = GO ] && return 0
		else
			[ $? -gt 128 ] || return 0
		fi
	done
}

job=
"$@" </dev/null >&2 &
job=$!
printf 'DRGNX-STATE: RUNNING\n'
park
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
park
