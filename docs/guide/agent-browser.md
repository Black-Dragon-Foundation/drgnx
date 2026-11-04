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
