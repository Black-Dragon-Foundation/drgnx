# The agent browser

A sandboxed agent session can drive a headless Chromium that runs inside its own sandbox. This page covers the
first step: which browser drgnx uses, and how to get one.

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
