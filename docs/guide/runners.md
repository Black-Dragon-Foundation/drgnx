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
`known_hosts` yourself. Either way the runner list shows it as `needs a login: ssh desktop true`, and no job is placed
there until it answers again.

## Adding and removing a machine

```
drgnx runner add desktop --trust mine            # a host as your ssh knows it
drgnx runner list                                # every runner, in 60 columns; one out of rotation says why
drgnx runner check desktop | bench desktop | unbench desktop
drgnx runner trust desktop shared                # mine, my-cloud or shared
drgnx runner remove desktop --yes                # stops our units and containers there, untags its image, deletes its folder
```

`add` options: `--name` (default: the host's first label), `--profile dedicated|workstation` (default dedicated: nobody
sits at the machine), `--accept all|heavy`, `--root DIR` (the one folder drgnx keeps there, an absolute path on the runner: no `~`; default `.drgnx-runner` in its home)
and `--prefix` (what its units and containers are named after, default `drgnx`).

What `add` does, in order, and stops at the first thing that is wrong:

1. Asks the host for its architecture and home folder through your ssh.
2. Copies the runner (one small static program) for that architecture into the runner folder. When none is built it
   says so and names the command: `drgnx build runner-bundle --arch aarch64`.
3. Asks the runner about the host. It **refuses the machine drgnx itself runs on** (it already runs jobs as `local`),
   and a host that lacks something a runner needs: a systemd user manager, cgroup v2 with the memory, pids and cpu
   controllers delegated to you and podman on the systemd cgroup manager, rootless podman 5 or newer, git, and, on an
   SELinux host, a policy that lets a keyed job's key socket be created as a container's (`container_t`; the stock
   container-selinux allows it). The refusal
   lists **everything** that is missing, each with what to run there to fix it.
4. Pulls the image in `drgnx-runners-image` (pinned by digest), tags it `localhost/<prefix>-runner:<digest start>` so a
   `podman image prune` there never removes it, and times a reference workload in it under the runner's caps.
5. Records the runner and connects it.

The runner list is yours alone: an agent can't add, bench, change or remove a machine. A runner that can't be reached
when drgnx starts stays in the list as `not connected`; `drgnx runner check NAME` connects it again. Removing a runner
refuses while a job is on it.

## The runner list

**Show Runners** (palette) opens the list in the editor: a row per runner, the same as `drgnx runner list`, in at most
60 columns. A runner is a dot (full while it takes jobs, empty while it is out of rotation), its name, trust, profile and
what it accepts; the second line is its size, the jobs running there, its free disk and when it was last checked (UTC),
with the numbers in the code face. A runner out of rotation says why on lines of its own, for example
`benched: image pull failed twice (14:02, 14:20)`. A runner of trust `my-cloud` carries a cloud mark. The list follows the
hub: a change shows at once, and **g** reads it again.

The commands for the row at point (all in the palette; none has a key of its own):

| Command | Does |
|---|---|
| Check Runner | its probe, its contract and a canary, now |
| Bench Runner / Unbench Runner | out of rotation / back in rotation at once |
| Set Runner Trust… | `mine`, `my-cloud` or `shared` |
| Set Runner Jobs… | accepts `all` jobs or only the `heavy` ones |
| Remove Runner | stops our units and containers there and deletes its folder (asks first) |
| Show Runner Log | what the hub knows of it: state, strikes, last strike |

Global: **Add Runner…** (a host as your ssh knows it, and its trust) and **Runners: Load Keys**. Which settings a
project and you choose for runners are listed under "Which jobs go where"; `drgnx-runners-key-host` (default
`drgnx-runner-keys`) is the host your job keys are filed under in your key store.

**Cards.** What waits for you is a card in the Notices list and the needs-you count, and goes by itself when the hub's
list or ask no longer says it:

- "Log in to desktop: run `ssh desk true` in a terminal" while a runner waits for a login;
- "desktop benched: image pull failed twice (14:02, 14:20)" while a runner is benched;
- "needs your keys: run Runners: Load Keys" while the hub asks for job keys it doesn't hold.

A card only says what to run. The editor never answers a login, and never reads your key store on its own.

## Runners on the Work map

On the Work space map (layer 6, with the files) every runner is a machine chip, and the hub's own machine stays as
`local`.

- **The icon** says what it is: `cloud` for a machine in your cloud account, `monitor` for a machine somebody sits at,
  `server` for a dedicated host. Where the font has no icon the glyph stands in (`☁` for cloud).
- **The chip** is the runner's name, its load as jobs over cores (`3/16`) and, for cloud, the cost. The dot before the
  icon follows the runner's state: green when it takes jobs, the accent while it runs them, the warning colour when it
  is benched, the attention colour when it needs a login, your keys or your confirm (each is also a card), the error
  colour when it cannot be reached, and a dim one while it drains or is being preempted.
- **A "runs on" edge** joins an agent to the machine its job runs on. It shows on the selected chain, like the others.
- **An agent's card** says `job · desktop · 3:10/6m` while a job it started runs: the machine, the time so far and the
  time box. A job that waits says `job · NAME · waiting`.
- **The strip** shows `desktop 3/16` for each machine, and `cloud $3.10/$50` after a cloud machine's load when cloud
  is on.
- **Enter on a machine** opens its queue in the side panel: the jobs running there, each with its agent, state, time and
  the names of the keys sent to it (never their values), and the jobs that wait for a machine. `l` shows the end of the
  log of the job on the row point is on (press it again for what came since).

The laptop icon is not used yet: the runner list does not say which hosts have a battery.

## Keys

Some jobs need a secret: a registry token to publish, a deploy key to fetch a private dependency. A job names the
keys it needs (names only); drgnx gets them to the job on the runner without writing them anywhere there:

- **Only keys the project lists.** A job may name only keys on the project's `drgnx-runners-job-keys` list (names,
  like `("CRATES_IO_TOKEN")`); one naming any other is refused when it is started. An agent's job also needs the
  matrix's `job.keys` (ask by default, allowed under Autonomous for the manager and workers, never for chat). A
  repository's own files can't set either.
- **You hand them over, the hub keeps them in memory.** When a job needs a key the hub doesn't hold, the hub asks
  (`runners/need-keys`, names only); your editor answers from your key store with `runners/keys`, from a command you
  run, never by itself. The hub holds the values in memory only, until it stops; `runners/keys-held` lists the names.
  In the editor the ask is a card, "needs your keys: run Runners: Load Keys". **Runners: Load Keys** (and **Add
  Runner…**, for the keys the project lists) read each key from your key store (an auth-source entry: host
  `drgnx-runners-key-host`, user the key's name; it may ask for a passphrase, because you ran it) and send it. The
  editor keeps what it sent in its own memory for the session, sends it again whenever a hub proves itself after a
  reconnect or restart, and forgets it when the runners module is turned off.
- **Only where trust allows, only after the job started.** Keys go to a `mine` runner, to a `my-cloud` runner only
  those on its own list, and never to a `shared` one; and only once the job has started there, one at a time. A
  keyed job never runs on this machine for now: it waits for a runner and says so.
- **What went where is recorded.** Each key sent is a `key_sent` record (the job, attempt, key name, runner and time);
  each read by the job, as the runner reports it, is a `key_use` record marked runner-reported. `runners/audit` lists
  them (by job or by key); the values are never in them.
- **The returned log has them masked.** The hub knows the values it sent a job, so its copy of the job's log has every
  one masked (`*`, the same length): raw, in base64 and percent-encoded, even split across two pieces of the log.
  drgnx also tells you when a line looks like some other secret ("this log may hold a secret at line N"), but never
  masks those: it would shred hashes and digests.
- **A private origin's deploy key.** With `drgnx-runners-origin-key` naming a read-only deploy key or token (a key
  like any other, held the same way), your own runners fetch a private project from its origin with it instead of
  being sent a bundle; an `https://` origin takes it as a token, an SSH one as a key.
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
`drgnx-px` (the relay sidecar, the job's way to the proxy). They are built static, so they start on any Linux and in any image.
`install.sh` builds them for this machine's processor; for a runner of the other kind, run
`drgnx build runner-bundle --arch aarch64` (or `x86_64`).

## Which jobs go where

All jobs wait in one queue, this machine's and your runners' alike, and each goes to the allowed machine that finishes
it first (ties stay here; then a runner that already holds the job's checkout and image). The first job of the
highest priority that fits nowhere yet keeps room on the machine where it can start soonest: other jobs still start
there only if they end before it does, so a large job isn't passed by small ones forever. A job you start has priority 1; an agent's has 3, or 5 when it marks it `background`; only
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

## What comes back

A job on a runner returns its log, its result and what it declared into its folder here (`<state>/hub/exec/<id>/`),
so `exec/get`, `exec/log` and the summary work as for a job on this machine. For now a runner sends back its log and
its result only; its reports, declared outputs and `changes.patch` (and `drgnx job fetch` for the larger ones) are
still to come, and go through these checks when they do. Nothing a runner returns touches your tree until the hub has
checked it:

- **Paths.** Every returned path is relative and normalised: one with `..`, an absolute name or a NUL byte is refused.
  Files are written beneath the job's folder without following a link (a link planted there is replaced or refused,
  never written through), and an archive holding a link, a device or a FIFO is refused.
- **Never returned,** whatever a job declares: a cargo `target/` (at any depth), a build tree (`CMakeFiles`,
  `CMakeCache.txt`, `build.ninja`, `config.status`) or an image (`oci-layout`, `.oci`, `.qcow2`, `.vmdk`, `.vdi`,
  `.iso`, `.img`).
- **Limits:** the hub keeps 64 MiB of a job's log (cut in the middle beyond that; the whole stays on the runner), 16 MiB
  of reports, 256 MiB of outputs and a 16 MiB `changes.patch`.
- **A patch is applied only when all of these hold:** every file it touches matches one of the job's `writes` globs
  (`*` and `?` stay within a folder, `**` is any number of folders, a trailing `/` is the whole folder); it touches no
  protected file (`.envrc`, `.claude`, `.codex`, `.gemini`, `mise.toml`, at any depth) and nothing under a `.git`
  folder; it adds no symbolic link or submodule and changes no executable bit (a new executable file counts); each
  file it changes is still the one the job was submitted with; it comes from the job's current attempt (its number
  and nonce); and its runner isn't `shared`. Otherwise it is kept, with the card "desktop returned changes to 3 files;
  review them".
- **A `shared` runner's results** never count for a gate or a job's `needs`, and are never promoted. Their summary, and
  so the wake of the agent that started the job, begins "output from runner NAME (shared)".

## When a machine fails

A lost link is never a job's result: a job on a runner whose link drops is *detached*, and comes back when the runner
answers again (a runner that lingers keeps its jobs for 10 minutes; drgnx asks again at every connection, so a job on
a runner whose linger was turned off goes back to the queue as soon as its link drops), or goes back to the queue. A
test job whose suite
can select rows then runs only the rows that have no result yet, and its old attempt is stopped when its runner answers
again; the result counts every row once, from its latest attempt, and its summary says where they ran: "rows 1–212 on
desktop (attempt 1), 213–240 on laptop (attempt 2)". A **strike** is a
failure that is the runner's, not the job's: setup or sync failed, the job's image is missing, the disk guard couldn't
free room, the runner's own guard killed jobs, its link was lost while jobs ran (the second time in a day), its health
check failed, or a key didn't arrive although the link stayed up. A red test, a crash, a job's own out-of-memory, a
time-out, a preemption or an eviction never is.

**Two strikes in a row, or two within an hour, bench the runner**: no job is placed there, and the runner list shows
`benched: REASON (HH:MM, HH:MM)`, the reason of the strike that benched it and the times of its last two (UTC). Every
5 minutes the hub checks each runner: its probe and the runner contract (the key socket's SELinux check among them), a canary `true` in its image under the job
caps, its free disk above the floor, and its clock within 2 s of this machine's. A pass brings a benched runner back
with no strikes; a failure is one more strike. `drgnx runner unbench NAME` brings it back at once.

After a restart of drgnx's hub, a job that holds keys and still runs on a runner waits for them before its log and
result come back: the hub asks for them ("needs your keys": run Runners: Load Keys), and the editor gives back the
keys it holds as it connects.

## Cloud: what you give drgnx

### Setting cloud up from the editor and the terminal

**Runners: Set Up Cloud…** asks four things: the monthly cap in dollars (you type it; an empty, zero or non-number answer
is refused and nothing is sent), the regions and machine sizes (comma separated, with defaults shown), and where the
credentials come from (`aws sso`, `aws profile`, `environment` or `gcloud`). It starts no machine. The hub checks the
account first, then raises the card **Start the first cloud machine** in Notices: it carries the projection (machine,
price, idle time, the worst case with drgnx down, this month against your cap) and every pre-flight line, a failed one
with its fix. **Runners: Start the First Cloud Machine** (the card's command) asks once more and only then confirms. The
other cards: "The cloud credentials need a login: run `…`, then Runners: Retry Cloud" (**Runners: Retry Cloud**), and
"cloud: on, not yet proven on this account" until the first machine has passed its checks, whose command is
**Runners: Turn Cloud Off** (asks first; ends every cloud machine of ours and deletes what drgnx made). **Runners: Cloud
Cost** says `cloud $3.10/$50`. **Runners: Rotate Cloud CA** replaces the SSH certificate authority, after a yes.

In the runner list a machine of trust `my-cloud` has a line of its own: `cost $0.42/h · $3.10 mo`, or `cost —` while the
hub has no price for it. The strip shows `cloud $3.10/$50` while cloud is on.

From a terminal: `drgnx runner cloud cost`, `drgnx runner cloud off [--yes]` (without `--yes` it says what it would do)
and `drgnx runner cloud rotate-ca`. The setup commands that print the role's policy are below.

drgnx can start machines of its own in your AWS account or GCP project, only with your permission and within your
limits. It talks to the provider's API directly, over HTTPS, with a role you create for it, scoped to what it does:

- **Credentials come from a command**, by default `aws configure export-credentials`, the same one your `aws` CLI
  uses (SSO, a profile, a role). drgnx runs it with no terminal and a 30 s limit. If it asks for anything (an MFA code,
  a password, a confirmation) or doesn't finish, drgnx doesn't answer it: the card says "the cloud credentials need a
  login: run `aws configure export-credentials` in a terminal", and nothing starts until you have. An expired session
  reads the same way. What the command prints stays in memory: never written, logged or shown.
- **Or a key in your keyring**, handed over like a job key (see "Keys"): the same JSON the command prints
  (`{"Version": 1, "AccessKeyId": …, "SecretAccessKey": …}`).
- **The role's policy**: `drgnx runner cloud setup aws` prints it, with your hub's id, regions and machine sizes filled
  in; you create the role, drgnx never creates IAM itself. It has one statement per resource type: machines, their
  disks and network interfaces may be started only with the tag `drgnx-hub=<your hub id>`, only in your sizes, only
  with metadata tokens required; tags only when they are made; ending a machine, and the image and security-group
  calls, only on resources with that tag; every call only in your regions. It denies `iam:PassRole` (machines get no
  role) and making an image or snapshot public. No cloud credential ever reaches a machine.

**On GCP** the same holds, in GCP's terms:

- **Credentials come from a command**, by default `gcloud auth print-access-token` (or `gcloud auth application-default
  print-access-token` for application default credentials), run the same way: no terminal, a 30 s limit, a login card
  when it asks for anything. **Or a service-account key** in your keyring (the JSON file GCP gives you), from which
  drgnx signs its own token requests; many organisations turn such keys off, so the command is the default.
- **The role**: `drgnx runner cloud setup gcp --project P [--member user:EMAIL]` prints a custom role with only the
  calls drgnx makes (start, read and delete its machines and their disks, read their serial console, the Fedora
  CoreOS base, its images and its SSH firewall rules; never a stop, a service account or IAM), the `gcloud` command
  that creates it, and the one that binds it to you. Give drgnx a **project of its own**: before the first start it
  checks the project for VMs it didn't start, and if there are any it warns you and gives the binding with a
  condition, so the role reaches only instances named `drgnx-…`.

Every machine drgnx starts is tagged (on GCP, labelled) with your hub's id and is started with an idempotency token,
so a retry after a crash or a lost answer finds the machine the first try made instead of paying for a second one. An
AWS machine ends itself when it powers off; a GCP machine is started with a deadline (its start plus the lifetime) at
which GCP deletes it, and never powers itself off (below).

**SSH to a cloud machine** uses no key of yours and never your `ssh-agent`. drgnx has its own SSH certificate
authority (kept in your keyring, held in memory while drgnx runs). For each connection it makes a fresh key in memory,
gives it to an `ssh-agent` of its own, and signs a certificate for it that names only that machine and lasts an hour.
The machine accepts certificates from that authority and nothing else. Its host keys are read from its console, where
it prints them at first boot, and pinned: a machine whose console doesn't show them is never connected to, and a host
key that changes later is refused.

**The image.** On AWS drgnx makes its own machine image from Fedora Cloud 45 (the newest listed one, named in the
output; if Fedora lists none for your region, drgnx says so and stops unless you named another base). It has git,
podman, the runner, the watchdog, your CA's public key, your project images and git mirrors and a warm cargo registry,
so a started machine is ready in about a minute. The image is encrypted, holds no host key and no secret of yours, and
is rebuilt only when what's in it changes. The two newest images are kept; older ones are deleted with their snapshots.
A machine's startup text (user-data) holds only its name, the watchdog's limits and, when newer, the CA's public key.

On GCP the machines run Fedora CoreOS `stable`, which sets a machine up once, at its first boot, from a config drgnx
writes (Ignition): the runner (fetched from your hub and checked by its hash), the watchdog, your CA's public key and
the machine's name, its host keys printed to its serial console, and automatic updates off, so no update reboots a
machine mid-job. That config holds nothing secret either. There is no baked GCP image yet: your project images, git
mirrors and the cargo cache are not preloaded on a GCP machine as they are on AWS.

### Spot

Cloud machines are spot machines by default, with on-demand when spot fails (`drgnx-runners-cloud-market`: `spot`,
`on-demand`, or `spot-then-on-demand`, the default). Spot costs much less, but the provider may take the machine back
with two minutes' notice (drgnx asks GCP for the same two minutes).

- **A notice** is seen by the machine itself within 5 seconds. The hub stops sending it work, and its jobs go back to
  the queue at once, to run elsewhere. That is never a strike against the machine and never a red result.
- **When spot fails in a region** twice within an hour (two notices, or "no spot capacity" twice), drgnx uses
  on-demand there for the next 6 hours.
- **A job that can't be restarted** never runs on spot: with `spot-then-on-demand` it gets an on-demand machine, and
  with `spot` it doesn't go to the cloud.

### What cloud can cost

You type a monthly cap at setup; there is no default. drgnx's own meter is the gate: each machine's running time at
its price when it started, its disk, its public IPv4 address and the data it sent back, and the storage of drgnx's
images. Each machine-hour is recorded.

- **Before a machine starts,** drgnx adds up this month's spend, the new machine's price for its expected work plus
  the idle time, and what already runs until its idle stop. If that passes the cap, the machine doesn't start, and the
  job waits or runs on what you have. The job says why, for example "cloud cap: $41 of $50 used; a c7a.4xlarge for
  ~40 min would pass it".
- **At the cap,** no new work goes to cloud machines, and each stops when its current jobs end.
- **At the cap plus one machine-hour,** every machine stops at once, and its jobs go back to the queue.

The bound you're shown at setup, with its dollar figure: while drgnx runs and has credentials, the cap plus one
machine-hour; with drgnx down, asleep or without credentials, at most your maximum machines × the unattended lifetime
(AWS) or × the lifetime (GCP) × the price. The provider's bill can differ (late charges, taxes, transfer drgnx didn't
see), so drgnx's figure is its estimate.

**Expired credentials:** when the credential command fails, or the provider says the session expired, the card says
"Run `aws sso login`, then Runners: Retry Cloud" (with your command), and no new machine starts. Machines that run keep
their jobs while drgnx reaches them and end by themselves (below). Once you've logged in, drgnx's next sweep ends
whatever is past its limits.

**The sweep:** when drgnx starts and every 10 minutes, it lists the machines tagged with its hub id in your regions,
reconnects to the running ones, and ends any it couldn't reach for 5 minutes, any past its lifetime, and any stopped
one (on GCP also any idle for the idle time). It never touches a machine without its tag.

**The network:** one security group per region (on GCP, two firewall rules, one for IPv4 and one for IPv6, named and
described with your hub id), tagged with your hub id: SSH (TCP 22) in, from anywhere, IPv4 and IPv6, and nothing else.
Your address changes behind carrier NAT, so the rule can't name it; the machines accept drgnx's short-lived
certificates only.

### When a cloud machine ends itself

Each machine drgnx starts runs a small watchdog of its own, so it ends even when drgnx doesn't come back:

- **Idle:** with no job for the idle time (15 minutes by default), counted from its last job and drgnx's last request
  for work, an AWS machine powers off, which ends it and its disks. On GCP the machine never powers itself off (a
  stopped GCP machine still bills its disk); drgnx deletes it instead.
- **drgnx gone:** its jobs run on to their own time limits and their results wait; 2 hours after drgnx was last in
  touch (the unattended lifetime) an AWS machine powers off whatever runs.
- **Lifetime:** at 8 hours an AWS machine powers off whatever runs; a GCP machine is deleted by GCP itself at its
  deadline, set when it was started.

## How it is tested

Runners are tested against containers that act as SSH machines (`test/runners/`): Fedora with `sshd`, systemd and
rootless podman, reached over real SSH by the hub's own transport and a real `sleipnir serve`. Only cloud APIs are
mocked. On that fake fleet, the **link drills** run every row 5 times and break the link the ways the world does:

- the hub's SSH master told to stop (`-O stop`) while a job runs;
- the network cut for 3 minutes under a job that holds a key and may reach one host (its proxy still refuses every
  other);
- linger turned off on the runner while a job runs there;
- `serve` stopped for 5 minutes, as a suspended machine;
- the hub restarted, with the editor connected and without it;
- the runner's host key changed: refused, never accepted, until you accept it;
- the disk falling below its floor, and the memory ladder stopping a job;
- four jobs at once over one machine that allows 3 SSH sessions.

Each must end with the job's own verdict (the linger drill: back in the queue at once, with no verdict), never a red,
crash or `infra` verdict from the link; the job reattached
by its nonce rather than run again; the hub's copy of its log equal to the runner's byte for byte; no more than 3
sessions on one connection; and, for a job with keys, the key sent once and never written on the runner. The time a
cut or a suspend lasts is moved on the queue's clock, so a drill takes the time its link needs to be called lost (45
seconds), not the 3 or 5 minutes it stands for.
