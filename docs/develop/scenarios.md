# Scenarios

Behaviour scenarios state how drgnx's UI must behave — VS Code is the reference — and run inside a harness
session of a configuration: `bin/drgnx test --scenario [--config drgnx|DIR]` (see
[harness.md](harness.md#scenario-tier)). They were first run against a **reference configuration** — an earlier
treemacs- and ibuffer-based Emacs setup that drgnx grows out of — to turn its known UI problems into evidence. Those that fail there are listed as known reds in
`test/scenario/known-red.eld`; the workbench (M3) must make every one of them pass on drgnx. No fixes go into
the reference configuration.

Each red below is quoted from its trace (time from the start of the measurement, cause, window, what changed).
The last results of each configuration are kept in `$XDG_STATE_HOME/drgnx/ui/scenarios/<config>.json`.

## Explorer (file tree)

| Scenario | Expected (VS Code) | Reference | Why (trace) — **drgnx: all green since M3a** ([workbench.md](../guide/workbench.md)) |
|---|---|---|---|
| `explorer-click-stays` | a single click on a folder keeps the selection on it | **red** | `treemacs-leftclick-action` selects the folder (point 55 → 30), `mouse-set-point` (30 → 36); at +196 ms the configuration's workspace timer — the Explorer follow — moves it back to the editor's file (36 → 55) |
| `explorer-follow-override` | with the follow switched off, `explorer-click-stays` passes | green | **confirms H1**: the follow is the cause |
| `explorer-expand-stays` | a double click expands the folder; selection and view stay | **red** | the click and `treemacs-doubleclick-action` expand the folder (+139 ms); at +308 ms the follow moves the selection to the editor's file (30 → 72) |
| `explorer-hold-is-a-click` | press, hold 300 ms, release without moving: a click on that row | **red** | the press selects `tests` (41 → 55); at +160 ms the follow reveals the editor's file, re-expanding the collapsed folder above, so the rows move under the held button; the release arrives as **`drag-mouse-1`** — the mechanism by which a click once moved a folder (with drag-to-move on, a drag moves files) |
| `explorer-keys-stay` | `n n` moves the selection two rows and it stays there | **red** | two `treemacs-next-line` (55 → 71 → 87); at +699 ms the follow moves it back (87 → 55) — with no other activity |
| `explorer-keys-then-background-event` | a buffer created in the background (an agent or status poll) does not move the selection | **red** | one background buffer event re-arms the follow; at +210 ms it moves the selection back (87 → 55) |
| `explorer-keys-during-churn` | keys move the selection while buffers come and go every 100 ms, and it stays after | **red** | during the churn the follow's 0.15 s debounce is re-armed every 100 ms and never fires; 70 ms after the churn stops it moves the selection back (87 → 55) |
| `explorer-cross-project-keeps-root` | opening a file of another project keeps the Explorer's root | **red** | an anonymous timer grows the echo area 20 → 40 px, shrinking every window by 20 px (+234 ms); at +705…743 ms the follow selects the Explorer, replaces its root with the other project and moves back |
| `explorer-double-click-opens-a-file` | a double click on a file opens it and focuses the editor | drgnx only | the click model is drgnx's own: other configurations skip it |
| `explorer-drag-does-nothing` | press on one row, release on another: nothing opens, toggles or moves | drgnx only | as above |
| `explorer-pressed-flag-clears-after-release` | the Explorer counts the button as held only between press and release (click, double click, drag) | drgnx only | as above |
| `explorer-click-on-a-partly-visible-bottom-row` | a click on a row that shows only in part opens it, without scrolling | drgnx only | as above; the test scrolls the text up by half a row when the window holds a whole number of rows |

## Buffers panel (open editors)

| Scenario | Expected (VS Code) | Reference | Why (trace) |
|---|---|---|---|
| `buffers-header-survives-refresh` | the panel shows its header line and keeps it | **red** | the header is 0 px: `header-line-format` is set to nil by `ibuffer-update` ← the workspace refresh ← the workspace timer (a variable watcher caught the call chain) |
| `buffers-scroll-kept` | a scrolled panel stays scrolled when another file is opened | **red** | the workspace timer resets the panel's start (392 → 1) on each refresh (+193 ms, again at +1232 ms); the top row goes from `file09.txt` to `main.py` |
| `buffers-close-hits-row` | × on a row closes that row's buffer, even if another file was opened just before | **red** | opening another file re-sorts the rows by recency, so the × aimed at `README.md` now belongs to `guide.md`, and the panel's close-at-mouse command closes that |

## New frames

`frame-from-daemon-fast` runs in the controller after the in-session suite (because it starts a daemon
session itself) when the suite has a `frames.eld` budget: it opens three frames with `emacsclient -c` and
compares the median time-to-visible with the budget (500 ms). On the reference configuration it is **green**
(median ~400–430 ms over runs; the first frame of a daemon takes 500–870 ms).

The reported 2.1 s for a new frame does **not** reproduce in an isolated session. The reference configuration alone is
therefore not what makes frames slow; the cause is state the harness leaves out on purpose (saved workspace
layouts restored per frame, many open buffers, language servers, the real display's scale). Measuring it needs
the live session and is left for the user to authorise.

## Hypotheses — outcome

- **H1** (the follow snaps the Explorer back after a click) — confirmed on screen, and by the override
  experiment.
- **H2** (background buffer activity re-triggers the follow) — confirmed: a single background event snaps the
  selection back; during continuous churn the debounce is starved and the follow fires as soon as it stops; and
  the follow undoes keyboard browsing even with no background activity.
- **H3** (root switching) — confirmed: the follow replaces the Explorer's root with the other project's (an
  earlier draft blamed treemacs' own follow mode too; with nested timers attributed correctly, the configuration's
  follow alone does it), with echo-area jank on the way.
- **H4** (the Buffers panel is rebuilt on every signal) — confirmed: header wiped, scroll reset, rows re-sorted
  under the pointer.
- **Step 0** (a click turned into a drag that moved files) — the mechanism is reproduced: the follow changes the
  tree under a held button and the release arrives as a drag.

## The cloud mock

`ratatoskr-mock cloud` stands in for AWS and GCP in tests of the cloud runners. It reaches no real cloud: no network
beyond its own listener, no real credentials (any `Authorization` header is accepted, and a fake token is built in
pieces in tests).

```
ratatoskr-mock cloud --listen 127.0.0.1:0 --podman-remote SOCK|none --prefix P --run R [--hub ID]
                     [--image IMG] [--network NET] [--podman PATH] [--metadata-url URL] [--run-opt OPT]... [--log FILE]
                     [--parent PID]
```

It prints `MOCK-CLOUD-PORT N`. With `--podman-remote SOCK` each instance that reaches `running` is a container
`<P>-cloud-<id>` labelled `drgnx.fleet=<R>` on the network `fleet-<R>` (only such names are ever created or removed):
its `dnsName` is the container's name, its console is the container's `/run/fleet-console`, and with
`--metadata-url URL` (the mock as the containers reach it) it gets `DRGNX_FAKE_CLOUD_METADATA=URL/__metadata/<id>`,
which the fake runner's stand-in for cloud-init reads its user-data from (`test/runners/README.md`, "Cloud
machines"; `fleet.sh up --cloud`). Each `--run-opt OPT` (one `podman run` argument, such as `--volume=SRC:DST:ro`
with SRC on the podman host) is added to every instance's `podman run`: `fleet.sh` gives the machines what its runners
have (systemd, `/dev/fuse` and `/dev/net/tun`, `unmask=ALL`, `SYS_ADMIN`, the share and the base image), so rootless
podman runs jobs on them. `none` keeps instances in memory. With `--hub ID` it models the fixture policy: tag conditions and the explicit
denies (`iam:PassRole`, `ModifyImageAttribute`, `ModifySnapshotAttribute`), answering `UnauthorizedOperation`, and
`DryRunOperation` for an allowed `DryRun`. It does not evaluate IAM in general.

**What it serves**, on one listener:

- EC2 Query (XML) at `POST /`: `RunInstances` (`ClientToken`, `TagSpecification`, spot, shutdown behaviour, IMDSv2
  options), `DescribeInstances` (filters `instance-state-name`, `instance-id`, `tag:K`, `tag-key`; the request's
  region only), `DescribeInstanceAttribute` (shutdown behaviour), `TerminateInstances`, `GetConsoleOutput` (output
  only with `Latest=true`), `DescribeSpotPriceHistory`, the image, snapshot and security-group calls,
  `DescribeSubnets`, STS `GetCallerIdentity` and the Pricing `GetProducts`.
- GCE REST at `/compute/v1/projects/…`: `instances.insert|get|delete|stop|aggregatedList|getSerialPortOutput`,
  `images.getFromFamily|insert|get|delete`, `firewalls.insert|get|delete`, `zoneOperations.get`; Resource Manager
  `projects:testIamPermissions`; Billing `services/…/skus`. `requestId` makes `insert` idempotent; a `stop` clears
  `scheduling.terminationTime`; a deadline the clock passes deletes (or stops) the instance.
- Instance metadata at `/__metadata/<id or name>/…`: IMDSv2 (`PUT latest/api/token`, a request with `X-Mock-Hops`
  above the hop limit is dropped; `spot/instance-action`; `latest/user-data`, what `RunInstances` passed) and GCE's
  `preempted` and `maintenance-event`.
- The console and serial output carry the instance's host keys as cloud-init's `write-ssh-key-fingerprints` prints
  them: the fingerprints through `logger -s -t cloud-init` (each line after a prefix such as
  `<14>Nov  6 00:00:00 cloud-init: `), between `#####` lines and `-----BEGIN/END SSH HOST KEY FINGERPRINTS-----`,
  then the public keys as they are between `-----BEGIN/END SSH HOST KEY KEYS-----`. In memory the keys are made up
  (an ed25519 and an ECDSA one, shaped like real ones) and each fingerprint is its key's SHA-256; with containers the
  image prints its real ones.

**The clock is virtual.** It starts at 2026-11-06T00:00:00Z and moves only by `POST /__mock/clock`
(`{"advance_s": n}` or `{"set": t}`), so boot delays, notices and deadlines need no sleeping.

**Knobs** (`POST /__mock/<name>`, JSON body; `times` defaults to 1):

| Knob | Body | Injects |
|---|---|---|
| `boot-delay` | `{seconds}` | instances stay `pending` that long |
| `stuck` | `{id or "next", on: "start"\|"end"}` | an instance that never leaves pending, or never finishes ending |
| `spot-notice` | `{id or "next", at or in_s}` | the notice in the metadata at that time, the interruption 120 s (GCE: the given duration) later |
| `capacity`, `quota` | `{times, provider?}` | `InsufficientInstanceCapacity` / `VcpuLimitExceeded` on `RunInstances`; in the operation's `error` on GCE |
| `fail` | `{op, status, code, message, times}` | any API error on a call (`op` is the EC2 action or GCE method; `*` any) |
| `timeout` | `{op, times}` | a call that never answers |
| `expire`, `token` | `{}`, `{accept}` | 401 (`ExpiredToken`) on every call until a token is accepted; then only that token |
| `shutdown-mismatch` | `{value}` | `DescribeInstanceAttribute` reports another shutdown behaviour |
| `no-termination-time` | `{}` | GCE ignores `terminationTime` |
| `deny-permissions` | `{permissions}` | `testIamPermissions` leaves them out |
| `prices` | `{aws\|gcp: {spot\|ondemand: {TYPE: n}}}` | the price lists; raising them mid-run makes a projection overrun |
| `poweroff` | `{id}` | the instance powers itself off (terminate or stop, as started) |
| `rotate-hostkey` | `{id}` | new host keys: in the console, and with containers in the machine's sshd (restarted on them before the knob answers) |
| `seed` | `{provider, id, tags, zone?}` | an instance the hub did not make |
| `reset` | `{}` | everything but the clock and the configuration |

`GET /__mock/resources` lists everything the mock holds (instances, images, groups, prices, operations, faults left,
and `unknown_requests`). A request the mock does not implement answers 501, is printed on stderr and listed there.
