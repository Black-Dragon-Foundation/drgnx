# The agent browser

A sandboxed agent session can drive a headless Chromium that runs inside its own sandbox. The agent tests its web app,
reads a page or takes a screenshot, and the browser can reach only what you allowed. This page covers what a session
gets, what it can and cannot reach, how to answer its cards, how to get a browser and what the doctor says.

**Not there yet.** You cannot watch the agent's browser: the [Live view](live.md) only says that watching arrives
later, and the browser has no window of its own. Your own browser (with your sign-ins) is not offered to agents, the
reduced sandbox tier (no bubblewrap) gives no browser, and macOS gives none. Each of these says so in the doctor or in
a notice instead of failing quietly.

## What a session gets

When the `browser` row of the [permissions matrix](security.md#the-permissions-matrix) allows it (Balanced: managers and
workers; a chat asks), a session starts with a headless browser inside its own sandbox, next to the agent and under the
same limits. The agent finds it at `PLAYWRIGHT_MCP_CDP_ENDPOINT` (and `DRGNX_BROWSER_CDP`), a
`ws://127.0.0.1:9222/devtools/browser/…` address with a secret of its own that only that session's environment holds.
Playwright MCP and other CDP clients connect there with no setup ([agents.md](agents.md#what-a-session-gets-with-the-browser)).

With no card and no grant the browser reaches only the agent's own local servers (see below). A host that cannot give
a browser starts the session without one, says why in `agents/get` and shows one notice with the fix: no full
sandbox tier, a kernel below Landlock ABI 9, or no browser found.

## What it can reach, and what a grant really gives

| Target | Needs | Notes |
|---|---|---|
| Servers the agent started inside its sandbox | nothing | `http://127.0.0.1:PORT` |
| Servers on this computer | a `browser.private` grant | as `host.drgnx.internal:PORT`, only for the ports in `drgnx-agents-browser-local-ports` (3000, 3001, 4173, 4200, 5000, 5173, 8000, 8080, 8888) |
| Your LAN, tailnet, other private addresses | a `browser.private` grant | one target at a time, or a /24 or /64 for numbers on your LAN |
| Public web sites | the `browser.web` row | HTTPS and plain HTTP on ports 80 and 443, through the session's web proxy |

Be clear about the web grant. It lets the agent's browser open any public site, and a page can send out whatever the
agent types into it or reads from your allowed servers. drgnx checks each connection (where it leads, not only the
name), but it cannot judge what the agent chooses to send. That is why only Autonomous allows the web without asking.

**Never reachable, whatever you grant:** the hub's own ports, an Emacs server port, any address of this computer outside
the ports you listed, link-local metadata addresses such as `169.254.169.254`, non-web ports on the public web, and the
hosts in `drgnx-agents-browser-deny-hosts`. A name that resolves to a different address than the one checked (DNS
rebinding) is refused.

## Answering a card

Three rows ask: `browser`, `browser.web` and `browser.private`. Each card says what the session wants, written from what
the hub saw and never from the agent's words, with the answers **Allow once** (ten minutes by default, for the one
target named), **Allow for this session**, **Allow for this plan**, **Refuse**, and for a numeric LAN address its /24
or /64, or every LAN address. `browser.private` asks in every preset, Autonomous included; `host.drgnx.internal` and
tailnet or link-local addresses are offered one target at a time. A refused target is not asked about again by that
session. The full list of answers is in [security.md](security.md#answering-a-browser-card).

## Downloads

A download the page makes lands in the browser's downloads folder (`/tmp/drgnx-browser/downloads` in the sandbox), not
in the folder Playwright asked for, because the browser cannot write there. Playwright's `download.path()` therefore
does not find the file; the agent reads it from that folder.

## Memory and idle

A session and its browser share one memory cap, `drgnx-agents-session-memory` (4G by default), enforced with a user
systemd scope. At `drgnx-agents-browser-memory-high` (75% by default) the browser is stopped and starts again at the
agent's next command. A browser that gets no command for `drgnx-agents-browser-idle` seconds (600) is stopped the same
way. Without a user systemd the session has no cap and the doctor warns.

## Which browser

drgnx looks for a browser in this order and takes the first it finds:

1. `drgnx-agents-browser-program`: the absolute path of a Chromium, Chrome or headless shell. drgnx runs it once with
   `--version` to learn what it is. A path that is not an executable file is an error; it is not silently replaced.
2. A system headless shell: `/usr/lib64/chromium-browser/headless_shell` (Fedora's `chromium-headless`), then
   `chrome-headless-shell` on `PATH`.
3. A system Chromium or Chrome: `/usr/lib64/chromium-browser/chromium-browser`, `/usr/lib/chromium/chromium`,
   `/opt/google/chrome/chrome`.
4. The newest download of `drgnx browser install`.

A path under `/snap/` is skipped at every step (a snap's browser cannot be confined). With none found, the fix text is:
install a distro package (Fedora: `dnf install chromium-headless`), set `drgnx-agents-browser-program`, or run
`drgnx browser install`.

`drgnx browser list` shows the browser sessions would get (or why there is none), the downloads, and the versions
drgnx can install. `--json` prints the same as one JSON object.

## `drgnx browser install`

```sh
drgnx browser install              # the newest pinned version
drgnx browser install --version V  # a pinned version
```

It downloads a Chrome for Testing `chrome-headless-shell` into `browsers/<version>/` in drgnx's data folder. It runs
only when you run it: drgnx never downloads a browser by itself, and the command asks nothing.

**What "checksum-verified" means.** Chrome for Testing publishes download URLs and no digests. drgnx therefore ships
its own table (`version`, release date, a sha256 per platform, in the Ratatoskr source) and installs only a version in
that table. The table moves with each drgnx release, so `--version` can name only a version the release knows. A
platform with no digest in the table (today everything but Linux x86_64) cannot be installed this way: use a distro
package or set `drgnx-agents-browser-program`.

**What it does, in order.**

1. Downloads over HTTPS (your `HTTPS_PROXY` applies) into `browsers/<version>.partial/`, hashing as it streams, and
   refuses a download over 512 MiB.
2. Compares the sha256 with the table's. A mismatch removes everything and fails.
3. Unpacks the archive there. An entry that is an absolute path, climbs out of the folder (`..`), is a link, is neither
   a file nor a folder, or repeats a name fails the whole install; so does an archive over 4096 entries, a file over
   1 GiB or more than 2 GiB in all. Sizes are counted as they are written, whatever the archive declares.
4. Makes the browser executable, writes `installed.json`, and renames `<version>.partial` to `<version>`.

Any failure removes the `.partial` folder, and a `.partial` folder found later is never used: the next install
replaces it. Only a folder with `installed.json` counts as installed. Running the command again for an installed
version downloads nothing.

Exit code 0 when it installed (or it was there), 1 when it could not, 2 for arguments that do not parse.

## Settings

| Setting | Default | |
|---|---|---|
| `drgnx-agents-browser-program` | nil | the browser to use, absolute path; nil finds one |

The other `drgnx-agents-browser-*` settings and `drgnx-agents-session-memory` are in the
[settings reference](../reference/settings.md).

## The doctor's lines

`drgnx doctor` has an `agent-browser` line in the Agents group. It reads the `browser` section of `ratatoskr doctor
--json`, which says what a session would get here:

| Line | When |
|---|---|
| `ok` | The full tier and Landlock ABI 9 or later (Mode A), a browser found, a user systemd for the memory cap. It also gives the last check's start time and peak memory, or says that no check has run yet. |
| `info` | No session can have a browser here: the kernel's Landlock ABI is below 9 (the line says "refused: Landlock ABI N < 9" and what fixes it), only the reduced tier runs ("not yet, phase 2"), or this is a Mac ("not yet"). |
| `warn` | No browser was found (install a distro package such as `chromium-headless`, or run `drgnx browser install`), no user systemd answers so the session has no memory cap, a downloaded browser is more than 28 days old, or the last check failed. |
| `fail` | A refusal of the web proxy did not hold. The doctor judges four targets in-process, each of which must be refused: `host.drgnx.internal:1` with no grant, `example.com:22`, `169.254.169.254:80` under a private grant, and the hub's own gateway port under a grant for it. |

Sessions that start without a browser because of the first three reasons say so once per reason in a notice, with the
same fix.

**The check.** `Agents: Check the Agent Browser` (in the palette) runs a throwaway session in the real sandbox, with the
same browser, tier and ABI a session would get, but no card: the hub opens a page (`data:text/html,<p>drgnx`), takes a
screenshot and stops. It takes a few seconds and gives up after 45. Its result (whether it worked, the time to the
first answer, the screenshot's size, the scope's peak memory, and the reason when it failed) is kept in
`hub/browser-check.json` in the state folder, and the doctor shows it. The check also reports when the browser's
standard error names a path under `/sys/`, a read the sandbox does not allow. The doctor itself never starts a browser:
it has two seconds, so it only reads the last result.
