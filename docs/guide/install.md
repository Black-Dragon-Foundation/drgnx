# Installing drgnx

drgnx runs on **[Nidhogg](#nidhogg)**, its own Emacs build (GNU Emacs 31.1 with a small patch series, native compilation
included). A stock GNU Emacs, whatever its version, fails the doctor's `emacs-version` check. The installer builds Nidhogg
if you do not have it, then installs drgnx and checks the result.

```sh
curl -fsSL https://raw.githubusercontent.com/Black-Dragon-Foundation/drgnx/main/install.sh | bash
```

Safer — download, read, try, run:

```sh
curl -fsSLO https://raw.githubusercontent.com/Black-Dragon-Foundation/drgnx/main/install.sh
less install.sh
bash install.sh --dry-run
bash install.sh
```

Afterwards, **on a Mac** the installer opens the drgnx app, and its first start opens the Welcome, which sets up
the rest — keys, packages, AI, Claude Code ([onboarding.md](onboarding.md)). Next time, open **drgnx** with
Spotlight (⌘Space, type "drgnx") or Launchpad, or run `drgnx .` in a project folder ([opening.md](opening.md)). The
app is in `~/Applications` (your home folder's Applications, not the one in Finder's sidebar). To keep it in the
Dock, drag `~/Applications/drgnx.app` there: while drgnx runs the Dock shows **Emacs**, and "Keep in Dock" on that
icon pins Emacs, not drgnx. **On Linux** run `drgnx open` (or the Emacs command the installer prints); the first start
opens the Welcome there too, and `drgnx onboard` runs the same steps in the terminal. `drgnx doctor` checks the
machine at any time.

## What install.sh does

1. **Detects** the platform (`/etc/os-release`, derivatives through `ID_LIKE`; Fedora and its remixes by
   `PLATFORM_ID`, so RHEL clones and Amazon Linux are not taken for Fedora; macOS version and CPU). Relative
   `--prefix`, `--dir` and `--source-dir` are taken relative to the current directory.
2. **Prints a plan** — every step, every command that will run as root — before doing anything.
   `--dry-run` stops here and changes nothing.
3. **Asks** "Go ahead?" and before **every** root step (`As root: …`). Questions are read from the terminal
   (`/dev/tty`), so `curl … | bash` can still ask. Without a terminal it refuses (exit 3) unless you pass
   `--yes`; with `--yes` root steps are still announced, and `sudo` may still ask for your password.
4. **Emacs:** keeps an installed Nidhogg of the version the installer pins; otherwise builds [Nidhogg](#nidhogg) — also
   beside a stock GNU Emacs or an older Nidhogg. Where there is no build recipe (anything but Fedora 44/45, Ubuntu
   26.04 and macOS) it stops before the plan with exit 1 (`no Nidhogg recipe for … yet`) and installs no stock Emacs.
5. **drgnx:** clones it into `~/.local/share/drgnx/drgnx` (or fast-forwards an existing checkout, never
   discarding local changes), installing git first if it is missing, and links `~/.local/bin/drgnx`.
6. **Compiles drgnx** (`drgnx build`), then on Linux **refreshes `drgnx.service`'s Emacs** if the unit is installed
   (`drgnx service-unit --refresh`: only its `ExecStart=` line changes; you restart drgnx yourself, see
   [Staying up to date](#staying-up-to-date)).
   **Ratatoskr** (the agent runtime, written in Rust) is built from source next ([Ratatoskr's Rust toolchain](#ratatoskrs-rust-toolchain)).
   A failed build warns with the log path and the fix (`drgnx runtime build --install`); drgnx still runs, and
   agents say "Ratatoskr is not built".
7. **macOS: the drgnx app.** Installs `~/Applications/drgnx.app` (`drgnx macos-app`: Finder, Spotlight, the Dock,
   Open With — [opening.md](opening.md#on-macos-the-drgnx-app)); if that fails it warns and goes on.
8. **PATH:** if `~/.local/bin` is not on your `PATH`, it offers to add one line to `~/.profile` (`~/.zprofile`
   when your shell is zsh; with `SHELL` unset, `~/.zprofile` if it exists) — only when you answer yes; with `--yes`
   it only prints the line and that file.
9. **Checks** it all: runs `drgnx doctor` with the Emacs it found or installed — after the app and the PATH line, so
   it checks what is there. On a Mac `drgnx` counts as on PATH when `~/.local/bin/drgnx` exists and your shell's
   profile (`~/.zprofile` for zsh or, with `SHELL` unset, when it exists; else `~/.profile`) puts `~/.local/bin` on PATH (`export PATH=…`, or in zsh
   `path=(… ~/.local/bin …)` / `path+=(…)`; what a new Terminal sees), also in a drgnx the app started, whose own PATH
   lacks it.
10. **macOS: opens drgnx** (the app just installed), so the first start's Welcome takes over — only in a desktop
   session: not over SSH, and not under `--yes` without a terminal.

Running it again is safe: an installed Nidhogg of the pinned version is kept, the checkout is fast-forwarded.

Later, `drgnx update` does the same for the checkout, packages and build in one command ([Staying up to date](#staying-up-to-date)).

The whole script consists of functions, called from `main` on its last line, so a truncated download
runs nothing.

### Options

| Option | Meaning |
|---|---|
| `--dry-run` | print the plan and exit |
| `--yes`, `-y` | do not ask (for scripts and containers) |
| `--prefix DIR` | where Nidhogg (under `opt/nidhogg/`), its links and the `drgnx` command go (default `~/.local`) |
| `--dir DIR` | where drgnx is checked out (default `~/.local/share/drgnx/drgnx`; it does not follow `DRGNX_DATA_DIR` or `XDG_DATA_HOME`) |
| `--source-dir DIR` | use an existing drgnx checkout instead of cloning |
| `--jobs N`, `--memory GIB` | the build's parallel `make` jobs, and the memory cap (whole GiB, at least 3) of a Nidhogg container build; the same as the environment variables `DRGNX_INSTALL_JOBS` and `DRGNX_INSTALL_MEMORY`, and the flag wins. Without them the installer sizes the build itself (below). They go on to Nidhogg's `build.sh` as `--jobs` and `--memory` |
| `--method M` | `auto` (default: keep a current Nidhogg, else build one), `nidhogg` (build [Nidhogg](#nidhogg); only where there is a recipe — Fedora 44/45, Ubuntu 26.04, macOS — else exit 1) or `keep` (do not touch Emacs; the doctor fails on anything but Nidhogg). The methods that installed a stock GNU Emacs, `package`, `source`, `cask` and `formula`, were removed: they exit 2 with "method M was removed: drgnx runs on Nidhogg" |
| `--branch B` | drgnx branch to clone (default `main`) |
| `--config URL` | after installing, set this machine up from your configuration repository: hands over to `drgnx bootstrap --config URL` ([below](#on-a-second-machine)); an `https://` URL or a local path |
| `--chezmoi URL` | the same with a chezmoi source repository (`drgnx bootstrap --chezmoi URL`); not together with `--config` |
| `--identity FILE` | an age identity file for the `secrets.age` in the configuration; with `--config` or `--chezmoi` |

Exit codes: 0 done, 1 a step failed (the message names it and its log) or the system has no Nidhogg recipe, 2 bad
option (an option without its value too, a removed `--method`) or an image-based Fedora, 3 no terminal to ask on and
no `--yes`.
With `--config` or `--chezmoi` the exit code is `drgnx bootstrap`'s.

## On a second machine

One command installs drgnx and sets the machine up from your configuration repository
([second-machine.md](second-machine.md)):

```sh
curl -fsSL https://raw.githubusercontent.com/Black-Dragon-Foundation/drgnx/main/install.sh | bash -s -- --config https://example.org/you/drgnx-config.git
```

It does everything above up to the `PATH` hint, skips its own doctor and "Done" lines, and runs `drgnx bootstrap
--config URL` instead: that clones the configuration into your config folder (`$XDG_CONFIG_HOME/drgnx`, by default
`~/.config/drgnx`: [files.md](files.md#where-drgnx-keeps-its-files)), imports your provider keys from
`secrets.age` into the Keychain or keyring, installs the packages from the lock, and asks before the desktop entry
and the shell integration. The plan names this as its last line (`Then: drgnx bootstrap …`), so `--dry-run` shows
it. `bootstrap` asks on your terminal (`/dev/tty`), even when the script itself comes down a pipe.

- **The URL** is `https://…` or a local path (a clone on a USB stick, a mounted directory). `http://`, `ssh://`,
  `git@host:path`, `file://` and a URL with a user name, password or query (`?…`, `#…`) in it are refused (exit 2): a password in a URL
  shows in `ps` and in the shell history, so use a git credential helper for a private repository. The value is passed
  on as one argument and never evaluated by the shell. A local path must exist.
- **`--identity FILE`** is an age identity file that decrypts `secrets.age` without a passphrase (for a machine
  where nobody types, for example a container). The installer only checks it is a readable file that nobody
  else can read (`chmod 600 FILE`; it refuses otherwise, before installing anything) and passes the *path* on; it
  never reads or prints the file. Without it, `bootstrap` asks for the bundle's passphrase on the terminal.
- **`--chezmoi URL`** takes a chezmoi source repository instead of a drgnx configuration (your dotfiles). `bootstrap`
  shows `chezmoi diff` first and applies only after a separate yes.
- **`--yes`** is passed on: it confirms the announced `age`/`chezmoi` install, the key import and `chezmoi init`, and
  nothing else. Editing a shell startup file, the desktop entry, a commit in the configuration directory, `chezmoi
  apply` and replacing a key your keyring holds still wait for you, or are skipped with the command to run
  ([second-machine.md](second-machine.md#one-command-drgnx-bootstrap)).
- An existing config folder is never overwritten: `bootstrap` stops and says how to move it aside.

## Per platform

| Platform | Emacs comes from | Notes |
|---|---|---|
| Fedora 44/45, Ubuntu 26.04 | **Nidhogg**, built from source ([below](#nidhogg)) | in a podman container where podman runs, else on the machine |
| macOS | **Nidhogg**, built from source: `Nidhogg.app` | [Homebrew](https://brew.sh) supplies the build dependencies and is installed first if missing, after asking (below) |
| Image-based Fedora (Silverblue, Kinoite, Bazzite, …; `/run/ostree-booted`) | — (exit 2) | dnf cannot install on them: run the installer inside a toolbox (`toolbox create`, `toolbox enter`) |
| anything else: Debian, Arch, Linux Mint, other Fedora releases and remixes, RHEL, Rocky, Alma, Amazon Linux, … | — (exit 1: `no Nidhogg recipe for … yet`, NIDHOGG-DISTROS-1) | no stock GNU Emacs is installed instead; `bash install.sh --method keep` installs drgnx on an Emacs you have, and the doctor fails on it |

Not used, on purpose: Flathub's Emacs, the Snap and every other stock GNU Emacs package: drgnx runs on Nidhogg only.

### macOS

The script runs under the `/bin/bash` that ships with macOS (3.2); nothing newer is needed. Run it in Terminal.

What you see, step by step:

1. Open Terminal (⌘Space, type "Terminal", Return), paste the install command and press Return.
2. It prints its plan and asks **Go ahead? [y/N]**: type `y`, Return. Without Homebrew it then asks **Install
   Homebrew?** — Homebrew asks for your Mac login password (nothing shows while you type; that is normal) and may
   install Apple's Command Line Tools: a few minutes, longer on a slow network. Right after a Homebrew it just
   installed, it asks **Add it to ~/.zprofile?** for Homebrew's line: answer `y`.
3. Nidhogg is built on your Mac (`Nidhogg.app`; Homebrew supplies the build dependencies): 30-60 minutes.
4. After the drgnx app, before the doctor's check, if `~/.local/bin` (where the `drgnx` command is) is not on your PATH yet,
   it asks **Add it to ~/.zprofile?** again: answer `y`. Lines added there work in every **new** Terminal window, not
   in the one already open.
5. The drgnx app opens, and with it the Welcome: go on with [onboarding.md](onboarding.md).

The details:

- **Your Emacs is not replaced.** An `Emacs.app` in `/Applications` is never touched: Nidhogg is built into
  `~/.local/opt/nidhogg/<version>/Nidhogg.app`. With `--method keep` an `emacs` on your PATH (or in `--prefix`, or
  `/Applications/Emacs.app/Contents/MacOS/Emacs`) that is 31.1+, graphical (`ns`) and compiles natively is used as it
  is, and remembered; the doctor fails on it, being a stock GNU Emacs.
- **Homebrew first, if it is missing.** The plan lists it as the first step. Before running anything the installer
  explains that Homebrew's own installer asks for your password, installs Apple's Command Line Tools when they are
  missing and takes a few minutes, and asks "Install Homebrew?" (`--yes` answers yes). It then runs Homebrew's official
  installer (`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`).
  Under `--yes` that installer runs with `NONINTERACTIVE=1` and cannot ask for your password: run `sudo -v`
  first, or leave `--yes` out. Afterwards the installer evaluates `brew shellenv` for itself and offers to add the
  line `eval "$(/opt/homebrew/bin/brew shellenv)"` (`/usr/local/bin/brew` on Intel) to your shell's profile (`~/.zprofile`
  for zsh, the macOS default; else `~/.profile`) — only when you answer yes; with `--yes` it only prints the line.
- **Intel Homebrew on Apple silicon** (`/usr/local/bin/brew` on an arm64 Mac) runs under Rosetta. It is used, and the
  plan warns about it.
- **Your Emacs configuration is never touched.** `~/.emacs.d` and `~/.config/emacs` are neither read nor written;
  drgnx starts with its own `--init-directory`.
- **The drgnx app.** Before the doctor it installs `~/Applications/drgnx.app` — drgnx in Finder, Spotlight and the
  Dock, and in Open With for folders, text and code files ([opening.md](opening.md#on-macos-the-drgnx-app)). A failure
  only warns (run `drgnx macos-app` later). It is never put in `/Applications` and never starts at login.
- The last lines are "Done." and how to open drgnx next time — Spotlight (⌘Space, type "drgnx") or Launchpad, or
  `drgnx .` in a project — and that to keep it in the Dock you drag `~/Applications/drgnx.app` there, not the Emacs
  icon the Dock shows while drgnx runs (on Linux the last line is the Emacs command that starts drgnx). Then, in a desktop
  session (not over SSH, and not under `--yes` without a terminal), it says "Opening drgnx…" and opens the app: the
  first start opens the Welcome ([onboarding.md](onboarding.md)), which asks whether drgnx keeps running in the
  background when you close its last window.

For tests, `DRGNX_INSTALL_BREW=none|PATH` overrides the Homebrew detection and `DRGNX_INSTALL_TTY=none|yes` overrides
the check for a terminal (so the tests need no `setsid`). `DRGNX_INSTALL_RUNTIME=none` skips the Ratatoskr step
(toolchain probe and build) altogether.

## Nidhogg

Nidhogg is drgnx's own Emacs build: GNU Emacs 31.1 plus a small patch series, with the command `nidhogg` and the
variable `nidhogg-version` (for example `31.1-nidhogg.1`; `emacs-version` stays GNU's own, `"31.1"`). `drgnx doctor`'s
`emacs-version` check says `OK` on Nidhogg and `FAIL` on a stock GNU Emacs of any version ("GNU Emacs 31.1 is not Nidhogg,
drgnx's own Emacs build"), and on anything older than 31.1. Fix: run the installer again, which builds Nidhogg.

The installer builds Nidhogg from a pinned release: it fetches the tag (`v31.1-nidhogg.1`) of the Nidhogg repository and
checks that it is the exact commit the installer pins, before building anything. Where it goes: `~/.local/opt/nidhogg/<version>`
(under `--prefix`), with `~/.local/bin/nidhogg` and `nidhoggclient` linking to it; the Emacs drgnx records is that
`nidhogg`. A Nidhogg of the pinned version that is already installed at that prefix is kept, whether `auto` or
`--method keep` chose that: no fetch, no rebuild, no root step — but `nidhogg` and `nidhoggclient` are linked again, so
`~/.local/bin` has them; an older one is rebuilt beside it.

Where `podman` can run containers, the build happens in a podman container (Fedora 44/45, Ubuntu 26.04 image) capped at
min(6 GiB, available memory − 1 GiB) of memory, with `make -jN`, N = one job per 1.5 GiB of the cap (at most one per CPU);
the host gets only the runtime libraries (as root, asked, unless all are there). Without podman, or when `podman info`
fails, or inside a container, the plan says why and builds on the machine instead (the build dependencies as root,
asked). On macOS the build always runs on the machine (Homebrew formulae, then `Nidhogg.app`). Below 3 GiB of
usable memory the container build is refused (exit 1) instead of being killed by the kernel. A Nidhogg build takes
about 30–60 minutes.

What it does, in order (nothing is installed if one of the first steps fails, and a failed build or a Nidhogg that does not
start leaves the Emacs drgnx used, its record and the `nidhogg` link as they were):

1. Fetch the tag and check the commit (`git`, installed first if missing, as root and asked).
2. Install the packages named in the release's `nidhogg/deps/<system>.runtime` (container build) or `.build` (host build)
   as root, asked — skipped when `rpm -q` / `dpkg -s` / `brew list` say they are all there, so a second run needs no root.
3. Run the release's `nidhogg/build.sh` (`--container <system> --memory <N>g` or `--host`, `--jobs`, `--prefix`,
   `--build-dir ~/.cache/drgnx/build/nidhogg-build`; logs stay in that directory). A leftover prefix of a failed earlier run is removed first.
4. Start the new binary: it must answer as Nidhogg 31.1-nidhogg.1 with native compilation and a graphical build, else the run stops.
5. Link `~/.local/bin/nidhogg` and `nidhoggclient` (macOS: a two-line script that starts `Nidhogg.app`) and record the
   `nidhogg` binary as the Emacs drgnx runs in ([Which Emacs drgnx runs in](#which-emacs-drgnx-runs-in)).

The Nidhogg repository and the commit the installer pins are `DRGNX_INSTALL_NIDHOGG_REPO` (an https URL or a local path)
and `DRGNX_INSTALL_NIDHOGG_COMMIT`, for tests; the installer's own defaults are the published release. Older versions stay in
`~/.local/opt/nidhogg/<version>`; remove one you no longer need with `rm -rf`.

Debian, Arch and other systems have no Nidhogg recipe yet (NIDHOGG-DISTROS-1): the installer stops with exit 1 and
`no Nidhogg recipe for … yet`; it installs no stock GNU Emacs instead.

## Other Emacs

Only Nidhogg is supported. `drgnx doctor` fails the `emacs-version` check on a stock GNU Emacs and on anything older
than 31.1, and points to the installer. The installer never keeps an Emacs older than 31.1 (`--method keep` excepted: it
records whatever Emacs you point it at). On a system with a Nidhogg recipe the installer builds Nidhogg instead.

## Security

- Emacs 31.1 has known issues that are fixed in 31.2 (not yet released): command injection through crafted TRAMP
  user names (CVE-2026-108976), Flymake running code from files being edited (CVE-2026-96442) and code execution
  through `read-symbol-shorthands` when opening a file (CVE-2026-96269; only partly fixed in 31.1). `drgnx doctor`'s `security` line names
  the ones that apply to your Emacs. It says OK while drgnx's own guards for them are on (see
  [Trusted folders](security.md)) and WARN when one is off, so a warning that stays means a guard is missing, not
  that you must upgrade. Until you run 31.2, avoid opening files you do not trust.
- The installer checks that the Nidhogg tag is the exact commit it pins before building anything, prints every root
  command before running it, and never edits shell startup files without asking.

## Which Emacs drgnx runs in

Every `drgnx` subcommand (build, doctor, test, sync, …) runs in one Emacs: `$DRGNX_EMACS` if set, else the one the
installer recorded, else `nidhogg` on your PATH (see [Nidhogg](#nidhogg)), else `emacs` on your PATH. The installer writes the path of the Emacs it installed or kept to
the first line of `~/.local/share/drgnx/emacs` (drgnx's data dir: `$DRGNX_DATA_DIR/emacs`, else
`$XDG_DATA_HOME/drgnx/emacs`); this matters on macOS, where `/Applications/Emacs.app/Contents/MacOS/Emacs` is
usually not on PATH. The path is this machine's, so it is not in your config folder, which travels to your other
machines ([second-machine.md](second-machine.md)). Older installs wrote it to `~/.config/drgnx/emacs`: that
file is still read when the data dir has no usable record, and `drgnx doctor` asks you to move it. If neither names
an executable file, drgnx falls back to PATH's `nidhogg`; with none it stops and tells you to run `install.sh` (it never runs a bare `emacs`). Edit the file, or set `DRGNX_EMACS`, to use another.

## drgnx doctor

`drgnx doctor` runs its checks inside the Emacs drgnx will use (see above) and prints
one line per check, `OK`, `WARN` or `FAIL`, with a fix under anything that is not ok. It exits 1 on any failure.
`--json` for tools, `--dev` adds the tools needed to develop drgnx (mutter, dbus-run-session, ImageMagick, a
pgtk Emacs; on a Mac, which has no mutter, D-Bus or pgtk, only ImageMagick). On a Mac the doctor also checks that the
drgnx app is installed (fix: `drgnx macos-app`), that Homebrew is there (also looked for in `/opt/homebrew/bin` and
`/usr/local/bin`, in case it is not on PATH) and that the `drgnx` command is on PATH (fix: add `~/.local/bin` to PATH in
your shell's profile, `~/.zprofile` for zsh or, with `SHELL` unset, when it exists; else `~/.profile`) — each only a warning. `portable-config` warns when the config dir holds a key in plain text (it names the file,
never the key) or a machine-local file such as the old `emacs` record, and says which `projects.eld` roots are not
cloned on this machine (info only; [second-machine.md](second-machine.md#the-doctors-check)). The `modules`, `display-rules` and `key-problems` checks (and the problems under the Terminal group's keys row) are
what the running drgnx says as notices (see below); `modules-report.eld` and `wb-report.eld` are no longer written, and
`key-conflicts` still reads the conflict table of `keys-report.eld`. With Vim keys the `modal` check warns when the stack needs evil and it is not
installed or not running (fix: `drgnx sync`, then restart, or choose another Keyboard Profile…), says when Vim waits for `drgnx sync`, and on
GNOME notes that Alt+Space opens the window menu before drgnx sees it (Settings → Keyboard → Keyboard Shortcuts → Windows; the Leader
Menu is on `M-SPC`, which replaces Emacs' `cycle-spacing`).
The `claude-adapter` check reads the `package.json` of the Claude Code adapter that the `claude` agent profiles would
run, without running it. It wants `@agentclientprotocol/claude-agent-acp` 0.93.0 or newer. The deprecated
`@zed-industries/claude-agent-acp`, an older version, or a program of no package drgnx knows is a warning, with the
one-line command that fixes it, or advice when the adapter is not in a global npm prefix ([agents.md](agents.md#sessions)). No adapter is only a notice. Details: [core.md](../develop/core.md#doctor-drgnx-doctorel).
The `ai-env-keys` check names the provider key variables set in this Emacs's environment (never a value), as
information: "OPENROUTER_API_KEY is set in this Emacs's environment; children inherit it; agents use the copy the hub
holds". drgnx leaves them there ([security.md](security.md#where-your-keys-live)).

**What drgnx has told you.** Each running drgnx writes the problems it knows (the notices that are still true, and
the last 50 warnings and failures) to its own file in `~/.local/state/drgnx/notices/`, two seconds after a change; at
exit the file becomes `last.eld`. The doctor only reads them. A check of this kind prints what the running drgnx says
and ends with `(this session)`, or `(this session, pid 1234, 5678)` when more than one drgnx is running; with none
running, it prints the last session's, `(from the last session, 3 h ago)`, and those of a drgnx that died without
exiting. Before the first start it says `no session recorded yet — start drgnx once`. The file of a dead drgnx is
deleted after 7 days.

A terminal-only Emacs (no graphical build) passes the `gui` check: drgnx runs in terminals, with no images and one font
size.

**The Terminal group.** Run from a terminal, the doctor also checks that terminal: `terminal` (which one it is, its
`TERM` and terminfo), `terminal-colours`, `terminal-mouse`, `terminal-keys` (the kitty keyboard protocol,
modifyOtherKeys or neither; for a terminal that sends neither, a table of the shortcuts it cannot send with the
Alt+Shift key and the F6 form that stand for each, and the terminals that would send them: the ones you have installed,
else the install command for your system), `terminal-clipboard` (copy to your clipboard by OSC 52), `terminal-tmux`
(inside tmux, the lines to add to `~/.tmux.conf`; drgnx never edits it), `terminal-ssh` (over SSH, whether this machine
has your terminal's terminfo). Outside a terminal it says `not run from a terminal` and nothing
more. Nothing in it prompts or installs anything; inside tmux it asks tmux once (1 second at most). Each warning
carries its fix. In drgnx, **Check This Terminal** (Help, in the palette) shows the same group for the terminal window
you are in. Details: [terminal.md](terminal.md#check-this-terminal).

**The Desktop group.** `window-manager`: which window manager this desktop runs, its version and how many monitors it
has, and what drgnx can do there ([workbench.md](workbench.md) on Move to Monitor). Run it from a terminal
inside your desktop session: the doctor reads the window manager from that terminal's environment. It asks the
program's own `--version` and makes one read-only query (sway's outputs, for example), each within 1 second; it never
installs anything and never asks.

| Desktop | The row |
|---|---|
| sway, i3, Hyprland, niri, KDE Plasma (KWin) | `ok sway 1.10, 2 monitors: Move to Monitor and restore work` (the version and count left out when unknown) |
| X11 (another X window manager), macOS | `ok X11, 2 monitors: Move to Monitor and restore work (frame positions)` |
| GNOME | `ok GNOME (Wayland): apps cannot move windows; use Super+Shift+←/→` |
| its tool missing | `warn Hyprland: hyprctl not found: Move to Monitor and restore need it`, fix: the install line for this system (`sudo dnf install sway`, `sudo apt install sway`, `sudo pacman -S sway`; else "install PKG with your package manager"; Fedora has no Hyprland package; on Arch i3's is `i3-wm`) |
| no answer within 1 s | `warn sway did not answer within 1 s`, fix: run drgnx doctor from a terminal inside your sway session |
| KWin without D-Bus or a session bus | `warn` with the reason and its fix |
| another Wayland compositor | `info river (Wayland): no adapter; drgnx leaves window placement to it` |
| over SSH, or no display | `info no graphical session here: run drgnx doctor in your desktop's terminal to check its window manager` |

## Ratatoskr's Rust toolchain

Ratatoskr is built from source (no prebuilt binaries yet) with `cargo build --release --locked`; it needs Rust 1.88
or newer and a C compiler (`cc`; its bundled SQLite is C). The build takes a few minutes and about 1.5 GiB of memory per
parallel job. install.sh takes the first of these that applies (`--dry-run` says which):

1. `cargo` and `rustc` 1.88 or newer already on `PATH`.
2. The distro's default Rust package, only if its version is 1.88 or newer (asked first): Fedora `cargo rust gcc`,
   Ubuntu and Debian `cargo rustc gcc`, Arch `rust gcc`, macOS `brew install rust`. Fedora 44/45, Ubuntu 26.04 and
   Homebrew qualify.
3. A versioned Debian-family package when the default is too old (Ubuntu 24.04: `rustc-1.91 cargo-1.91`, binaries in
   `/usr/lib/rust-1.91/bin`).
4. Otherwise (Debian 13, other distros) a private rustup in `~/.local/share/drgnx/rustup` with Rust 1.93.1. rustup-init
   is downloaded from the versioned archive on static.rust-lang.org and checked against a sha256 recorded in
   install.sh before it runs; nothing touches `~/.rustup` or `~/.cargo`.

A missing `cc` is named in the plan (`gcc`; on macOS `xcode-select --install`). The choice is recorded in
`~/.local/share/drgnx/cargo` (the cargo's path, and `RUSTUP_HOME`/`CARGO_HOME` lines for a private rustup) because the
update timer's `PATH` lacks `~/.cargo/bin` and `/usr/lib/rust-1.91/bin`; `drgnx runtime build` and `drgnx update` use it.

The build uses `-j` by CPUs and memory (one job per 1.5 GiB available). On Linux with a user systemd it runs inside
`systemd-run --user --scope` with `MemoryMax` of jobs x 1.5 GiB + 1 GiB (never more than available minus 1 GiB) and no
swap; over SSH without a user manager it runs with `-j` alone and says so. **macOS has no memory cap**, only the job
count.

```sh
drgnx runtime build [--install]      # cargo build of Ratatoskr; --install also installs it
drgnx runtime install [--prefix DIR] # <data>/bin/ratatoskr (by rename), links DIR/bin/ratatoskr and rtsk
```

`runtime install` refuses a binary built with test hooks. The build's commit (`ratatoskr version --json`) is what the
doctor compares with the checkout.

## Staying up to date

One command brings the install to the newest `main` on GitHub:

```sh
drgnx update
```

It works in the install's own checkout (the folder the `drgnx` command runs from), and:

1. **Refuses, changing nothing**, when that folder is not a git checkout, is not on `main`, or has local changes to
   tracked files (the message says what to do).
2. **Fetches** `origin main` with a time limit and no prompts (no password, no credential helper, no ssh question).
   If you are already at `main` it says so and stops.
3. **Fast-forwards only.** If the checkout has local commits `main` does not have (it has *diverged*), it refuses and
   names the fix: `git rebase origin/main`, or `git reset --hard origin/main` to discard them.
4. Runs **`drgnx sync`** (packages, from the lock the new version ships), **`drgnx build`**, and then **`drgnx runtime
   build --install`** (Ratatoskr; the new binary replaces the old one only after a good build). If any fails, the
   checkout goes back to the commit it was on, that commit's packages are synced again (from the cache first) and it is
   rebuilt (and Ratatoskr too, when the installed binary is from another commit), and the message says how far that
   got. A failed Rust build rolls the whole update back, so the Lisp and the binary never differ: the last run reads
   "failed: runtime build failed (…)", and the doctor says to fix the toolchain, then `drgnx update`. The same happens if the update is interrupted (Ctrl-C, a timeout,
   logout) before it finished. Output of the steps is kept in `~/.local/state/drgnx/update/last.log`.
5. Points an installed `drgnx.service` at the Emacs drgnx uses now (`drgnx service-unit --refresh`; only the
   `ExecStart=` line changes; see [packages.md](packages.md#running-drgnx-as-a-daemon)). It never restarts the service.
6. Prints what changed (`old..new`, one line per commit, at most 15) and ends with "Restart drgnx to use it": it
   never restarts or talks to a running drgnx unless you pass `--restart` (below). Restart it soon: a running drgnx still has the old code in memory, and
   files it loads later come from the new version.

`drgnx update --back` returns to the commit before the last update (and re-syncs and rebuilds); it refuses when you
 changed the checkout's history since, so that commit is no longer part of it. It is named `--back`
because `drgnx rollback` already exists for *packages*. A second `--back` goes forward again.

`drgnx update --restart` (also with `--back`) restarts drgnx for you after a successful update: on Linux it runs
`systemctl --user restart drgnx` when the drgnx systemd user unit is enabled. The restart ends the daemon, so its
windows close and `emacsclient` sessions lose their server; run `drgnx` to open a window again. A failed update or
rollback never restarts, and with no drgnx service installed (and on macOS, which has none) it says so and changes
nothing. The daily timer never restarts.

### Updating by itself

```sh
drgnx update --auto on       # a daily timer
drgnx update --auto status   # is it on, when did it last run
drgnx update --auto off
```

On Linux this writes a systemd user timer and service (`drgnx-update.timer` / `.service` in
`~/.config/systemd/user`): daily, with a random delay of up to an hour, `Persistent=true` (a day missed while the
computer was off runs when it is back). On macOS it writes a launchd agent
(`~/Library/LaunchAgents/org.blackdragonfoundation.drgnx-update.plist`) that runs once a day at a time picked when you
turn it on. Both run `drgnx update --quiet`: no output when already current, one line on an update or a failure,
never a prompt; the timer runs only while you are logged in; the line is in the journal (`journalctl --user -u drgnx-update`) or, on macOS, in
`~/.local/state/drgnx/update/launchd.log`. `--auto status` also shows the last run: it is kept in
`~/.local/state/drgnx/update/last-run` (`$XDG_STATE_HOME/drgnx/update/`; the timer uses the `XDG_STATE_HOME`,
`XDG_CONFIG_HOME`, `DRGNX_CONFIG_DIR` and `DRGNX_EMACS` you had when you turned it on).

The timer does not undo your choices: after `drgnx update --back`, or after an update that failed and was moved back,
the timer skips that same commit and waits for a newer one; running `drgnx update` yourself takes it. A checkout with
local changes, on another branch or diverged fails the timer's run with the same message, until you fix it.

## Uninstall

```sh
rm -rf ~/.local/share/drgnx ~/.local/bin/drgnx "${XDG_CACHE_HOME:-$HOME/.cache}/drgnx" "${XDG_STATE_HOME:-$HOME/.local/state}/drgnx"
```

If you turned on automatic updates, run `drgnx update --auto off` first (it removes the timer or launchd agent).

Your settings (`$XDG_CONFIG_HOME/drgnx`, by default `~/.config/drgnx`) stay unless you remove them too.

On macOS, also `rm -rf ~/Applications/drgnx.app`, and if you want them gone:

- a stock Emacs an earlier installer put there: `brew uninstall --cask emacs-plus-app` or `brew uninstall emacs-plus@31`;
- an OpenRouter key onboarding stored: `security delete-internet-password -s openrouter.ai -a drgnx` (or delete
  `openrouter.ai` in Keychain Access);
- what onboarding installed, each only if it did: `brew uninstall ollama` (models: `ollama rm NAME` first, or
  `~/.ollama`), `brew uninstall --cask lm-studio` (models in `~/.lmstudio`), `npm uninstall -g
  @agentclientprotocol/claude-agent-acp` (or `@zed-industries/claude-agent-acp`, the deprecated package earlier
  versions installed; add `--prefix ~/.local` if it is there), `brew uninstall node`, `brew uninstall --cask claude-code`.

Nidhogg: `rm -rf ~/.local/opt/nidhogg ~/.local/bin/nidhogg ~/.local/bin/nidhoggclient` (macOS: the same). A stock Emacs an earlier installer built from source: `make uninstall` in the build directory
(`~/.cache/drgnx/build/emacs-31.1`, or under `$XDG_CACHE_HOME` if you set it) before deleting the cache (or
remove `~/.local/bin/emacs*`, `~/.local/share/emacs`, `~/.local/libexec/emacs`); one it installed as a package: remove it
with your package manager. The PATH line (on a Mac also Homebrew's), if you let the installer add it, is marked
`# added by the drgnx installer` in `~/.profile` (zsh: `~/.zprofile`).

## Testing the installer

`bin/drgnx test` runs install.sh's plans for every platform fixture (fast), and real runs against a stub Nidhogg repository
and build script. `bin/drgnx test --install
[NAME…]` runs it for real in fresh containers (there is no podman inside them: Nidhogg builds on the host, set
`DRGNX_INSTALL_NIDHOGG_REPO` and `DRGNX_INSTALL_NIDHOGG_COMMIT` to use a local Nidhogg repository) — Nidhogg on Fedora 44/45 and Ubuntu 26.04 —
then checks the doctor, that a second run changes nothing, and that `--dry-run` touches nothing. On Debian 13 and Arch
(no recipe) it checks that the installer exits 1 with `no Nidhogg recipe` and installs nothing, and on Arch that
`--method keep` on the distribution's own Emacs ends in `FAIL  emacs-version`. Each container is limited to 6 GiB of
memory. Slow where Nidhogg is built (30-60 minutes); logs in `~/.local/state/drgnx/install-tests/`.
