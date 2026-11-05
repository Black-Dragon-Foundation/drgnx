# Runners: your other machines run jobs

A **runner** is another machine of yours that runs drgnx's jobs (builds, tests) when it would finish them sooner than
this one. drgnx reaches it the way you already do, through your own `ssh`.

## How drgnx reaches your machines

- **Your ssh, your config.** A runner is a host as your ssh knows it: whatever `ssh <host>` reaches (a `Host` entry,
  Tailscale, a `ProxyJump` through a bastion) is what drgnx uses. Its user, port, keys and proxy stay yours.
- **A few options are always drgnx's.** For each runner drgnx writes its own small ssh config in your runtime folder
  (`$XDG_RUNTIME_DIR/drgnx-runners/<runner>/ssh_config`, readable by you only) and reads yours after it. ssh keeps the
  first value it reads, so these win over anything in `~/.ssh/config`:
  - no agent forwarding, no X11, no port forwarding (your `LocalForward` and the like never open), no local command:
    nothing on the runner can reach back into this machine through the connection;
  - never a prompt (`BatchMode yes`): drgnx runs in the background, so a password or passphrase question would hang;
  - strict host keys, never learned or updated on their own;
  - its own command with no terminal, even if your config sets `RemoteCommand` or `RequestTTY`;
  - a keep-alive every 15 s, compression, and a connection kept 10 minutes after its last use.
- **One connection per runner, three sessions on it.** Restarting drgnx picks up the same connection, so a host that
  asks for a fresh login now and then (Tailscale SSH) doesn't ask again for a restart.
- **A dropped connection is never a job's result.** drgnx checks a runner with a real round trip through it, not by
  asking the local ssh process, which still answers after the network is gone. A lost connection is dialed again after
  5 s, 15 s, 45 s, then every 2 minutes; the job's result comes only from the runner itself.

### When a runner needs you

drgnx never answers a login for you and never opens a link. When ssh says the host wants you first, the runner waits
for you, and drgnx says what to run in a terminal, for example: "Log in to desktop: run `ssh desktop true` in a
terminal". That covers:

- Tailscale SSH's "requires an additional check" (the card shows the login link it printed);
- a key that needs its passphrase (load it into your agent, or run the command once);
- a host whose key you haven't accepted yet: check it and accept it in that terminal.

**A changed host key is never accepted.** The runner stops until you have found out why the key changed and fixed your
`known_hosts` yourself.

## Which jobs go where

All jobs wait in one queue, this machine's and your runners' alike, and each goes to the allowed machine that finishes
it first (ties stay here). A job you start has priority 1; an agent's has 3, or 5 when it marks it `background`; only
you can set or bump a priority. A job's row says where it runs and, while it waits, why. Each project chooses, in its
settings:

- `drgnx-runners-send`: which of its jobs may leave this machine: `"heavy"` (the default: only jobs marked heavy),
  `"all"` or `"none"`;
- `drgnx-runners-heavy`: suite or command patterns whose jobs count as heavy;
- `drgnx-runners-image`: the image (pinned by digest) a runner runs its command jobs in;
- `drgnx-runners-weight`: its share against other projects within a priority (default 1);
- `drgnx-runners-project-visibility`: `"private"` (the default) or `"public"`.

A job marked `local_only`, or started with `machine: local`, never leaves this machine; `machine: NAME` pins it to one
runner.

## When a machine fails

A lost link is never a job's result: a job on a runner whose link drops is *detached*, and comes back when the runner
answers again (a runner that lingers keeps its jobs for 10 minutes), or goes back to the queue. A **strike** is a
failure that is the runner's, not the job's: setup or sync failed, the job's image is missing, the disk guard couldn't
free room, the runner's own guard killed jobs, its link was lost while jobs ran (the second time in a day), its health
check failed, or a key didn't arrive although the link stayed up. A red test, a crash, a job's own out-of-memory, a
time-out, a preemption or an eviction never is.

**Two strikes in a row, or two within an hour, bench the runner**: no job is placed there, and the runner list shows
`benched: REASON (HH:MM, HH:MM)`, the reason of the strike that benched it and the times of its last two (UTC). Every
5 minutes the hub checks each runner: its probe and the runner contract, a canary `true` in its image under the job
caps, its free disk above the floor, and its clock within 2 s of this machine's. A pass brings a benched runner back
with no strikes; a failure is one more strike. `drgnx runner unbench NAME` brings it back at once.
