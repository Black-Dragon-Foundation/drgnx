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

## Adding and removing a machine

```
drgnx runner add desktop --trust mine            # a host as your ssh knows it
drgnx runner list                                # every runner, in 60 columns; one out of rotation says why
drgnx runner check desktop | bench desktop | unbench desktop
drgnx runner trust desktop shared                # mine, my-cloud or shared
drgnx runner remove desktop --yes                # stops our units and containers there, deletes its folder
```

`add` options: `--name` (default: the host's first label), `--profile dedicated|workstation` (default dedicated: nobody
sits at the machine), `--accept all|heavy`, `--root DIR` (the one folder drgnx keeps there, default `~/.drgnx-runner`)
and `--prefix` (what its units and containers are named after, default `drgnx`).

What `add` does, in order, and stops at the first thing that is wrong:

1. Asks the host for its architecture and home folder through your ssh.
2. Copies the runner (one small static program) for that architecture into the runner folder. When none is built it
   says so and names the command: `drgnx build runner-bundle --arch aarch64`.
3. Asks the runner about the host. It **refuses the machine drgnx itself runs on** (it already runs jobs as `local`),
   and a host that lacks something a runner needs: a systemd user manager, cgroup v2 with the memory, pids and cpu
   controllers delegated to you and podman on the systemd cgroup manager, rootless podman 5 or newer, git. The refusal
   lists **everything** that is missing, each with what to run there to fix it.
4. Pulls the image in `drgnx-runners-image` (pinned by digest) and times a reference workload in it under the runner's
   caps.
5. Records the runner and connects it.

The runner list is yours alone: an agent can't add, bench, change or remove a machine. A runner that can't be reached
when drgnx starts stays in the list as `not connected`; `drgnx runner check NAME` connects it again. Removing a runner
refuses while a job is on it.

## Keys

Some jobs need a secret: a registry token to publish, a deploy key to fetch a private dependency. A job names the
keys it needs (names only); drgnx gets them to the job on the runner without writing them anywhere there:

- **Only in memory.** The key travels inside drgnx's own connection and goes straight to a small helper that lives
  exactly as long as the job. The helper keeps it in memory that is never swapped, never in a core dump and not
  readable by other programs, and wipes it when the job ends. Nothing is written to the runner's disk, and podman's
  own records (`podman inspect`) show the key's name, never its value.
- **Into the job's own environment.** The job's command runs as `drgnx-key exec NAME=VARIABLE -- your command`
  (drgnx sets that up, the job can't change it): `drgnx-key` reads each key and starts the command with the variable
  set, in that process only. A tool that reads a secret from a pipe can use `drgnx-key get NAME` instead.
- **A key that never arrives is drgnx's problem, not the job's.** `drgnx-key` waits up to 60 s for a key; if it
  doesn't come (the connection dropped before drgnx could send it), the job ends as "key not delivered", never as a
  failed test.
- **Network goes through drgnx's proxy.** A job that may use the network reaches only the hosts it was allowed, through
  a proxy beside it; cloud metadata services and link-local addresses are never reachable, even by a name you allowed.

If the runner's disk gets low (below 20 GB, or 10 % of the runner folder's disk), the job that grew most since it
started is stopped and ends as "disk", not as a failure.

**The runner bundle.** drgnx copies three small programs to a runner: `sleipnir` (the runner itself), `drgnx-key` and
`drgnx-fwd` (the job's way to the proxy). They are built static, so they start on any Linux and in any image.
`install.sh` builds them for this machine's processor; for a runner of the other kind, run
`drgnx build runner-bundle --arch aarch64` (or `x86_64`).

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
- `drgnx-runners-project-visibility`: `"private"` (the default) or `"public"` (see below);
- `drgnx-runners-shared-overlay`: off (the default) or on: whether a `shared` runner may have its uncommitted files.
  Your own settings only: a repository's files can never turn it on.

A job marked `local_only`, or started with `machine: local`, never leaves this machine; `machine: NAME` pins it to one
runner.

## What is sent where

A job runs exactly what you had when you started it. At that moment drgnx **freezes its inputs**: the commit, every
uncommitted change against it (staged, unstaged, new files that aren't ignored, deletions), and a copy of each changed
file's bytes. Edits you make afterwards never reach that job. A runner checks the commit out in a folder of its own,
outside anything the job can write, and writes the changed files over it; git there runs none of a repository's hooks
or settings.

**A job's trust** is worked out then, from your project's word and from what the origin already has:

| The job | is |
|---|---|
| names keys | `private+keys` |
| a `public` project (`drgnx-runners-project-visibility`) whose commit your `origin` remote already has (its `refs/remotes/origin/` reach it) | `public` |
| anything else: a private project, or a public one with commits not pushed yet | `private` |

drgnx never guesses a project's visibility. The origin it reads is what your repository last fetched or pushed, so
push (or fetch) first.

**Which runner may take it:**

| Job trust | `mine` | `my-cloud` | `shared` |
|---|---|---|---|
| `public` | yes | yes | yes |
| `private` | yes | yes | no |
| `private+keys` | yes | when every key is on its list | no |

A job no runner may take runs here, and its row says why: "runs here: 1 commit not on origin", "runs here: project
alpha is private; the only free runner is shared".

**How the code gets there:**

- **On the public origin:** the runner fetches the commit from the origin itself, at its own speed. This is the only
  way a `shared` runner ever gets code; nothing of your history is pushed to it.
- **Anything else, to your own machines:** drgnx sends the commits the runner's copy lacks, as one git bundle (resumed
  where it stopped after a dropped connection) sent in 1 MiB pieces. A private origin with a deploy key named for the
  project lets the runner fetch from the origin instead (with the keys).
- **The uncommitted files** go by content: the runner says which it lacks, and only those are sent. Your `mise.toml`,
  `.envrc`, `.claude`, `.codex`, `.gemini` and `.git/hooks` are never sent to any runner; it gets their committed
  versions.
- **A `shared` runner and uncommitted files:** with `drgnx-runners-shared-overlay` off, a job with uncommitted changes
  never goes to a shared runner ("runs here: 2 uncommitted files, …"). With it on, each file is scanned first, and one
  that looks like a secret keeps the job off the shared runner, naming the file.

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
