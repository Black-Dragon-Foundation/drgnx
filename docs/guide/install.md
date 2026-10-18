# Installing drgnx

drgnx needs **GNU Emacs 31.1 or newer with native compilation**. Emacs 30.2 still works (the doctor warns).
The installer gets you such an Emacs if you do not have one, then drgnx, and checks the result.

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
   `PLATFORM_ID`, so RHEL clones and Amazon Linux are not taken for Fedora; macOS version and CPU) and the
   session (Wayland or X11; no display counts as Wayland). Relative `--prefix`, `--dir` and `--source-dir`
   are taken relative to the current directory.
2. **Prints a plan** — every step, every command that will run as root — before doing anything.
   `--dry-run` stops here and changes nothing.
3. **Asks** "Go ahead?" and before **every** root step (`As root: …`). Questions are read from the terminal
   (`/dev/tty`), so `curl … | bash` can still ask. Without a terminal it refuses (exit 3) unless you pass
   `--yes`; with `--yes` root steps are still announced, and `sudo` may still ask for your password.
4. **Emacs:** keeps an installed Emacs ≥ 31.1 whose native compilation works and that is graphical;
   otherwise installs one (table below).
5. **drgnx:** clones it into `~/.local/share/drgnx/drgnx` (or fast-forwards an existing checkout, never
   discarding local changes), installing git first if it is missing, and links `~/.local/bin/drgnx`.
6. **Compiles drgnx** (`drgnx build`).
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

Running it again is safe: a good Emacs is kept, the checkout is fast-forwarded.

The whole script consists of functions, called from `main` on its last line, so a truncated download
runs nothing.

### Options

| Option | Meaning |
|---|---|
| `--dry-run` | print the plan and exit |
| `--yes`, `-y` | do not ask (for scripts and containers) |
| `--prefix DIR` | where a source-built Emacs and the `drgnx` command go (default `~/.local`) |
| `--dir DIR` | where drgnx is checked out (default `~/.local/share/drgnx/drgnx`) |
| `--source-dir DIR` | use an existing drgnx checkout instead of cloning |
| `--method M` | `auto` (default), `package`, `source`, `keep` (do not touch Emacs), or `formula` (macOS only: Homebrew's `emacs-plus@31`, built from source — also on Apple silicon, beside an older `/Applications/Emacs.app`); `package` and `source` only where the platform has that recipe (Fedora and Arch packages; Fedora and Debian-family source builds) — elsewhere it stops before the plan (exit 2) |
| `--branch B` | drgnx branch to clone (default `main`) |

Exit codes: 0 done, 1 a step failed (the message names it and its log), 2 unsupported platform or bad
option (an option without its value too), 3 no terminal to ask on and no `--yes`.

## Per platform

| Platform | Emacs comes from | Notes |
|---|---|---|
| Arch, EndeavourOS, Manjaro, … | `pacman -Syu emacs-wayland` (Wayland) / `emacs` (X11) | 31.1, native compilation; `-Syu` because Arch supports no partial upgrades |
| Fedora 45+ | `dnf install emacs-pgtk` (Wayland) / `emacs-gtk+x11` (X11) | 31.1, native compilation, tree-sitter |
| Fedora 44, Fedora remixes (Nobara, …) below 45 | source build (`dnf builddep emacs`) | |
| Image-based Fedora (Silverblue, Kinoite, Bazzite, …; `/run/ostree-booted`) | — (exit 2, unless a good Emacs is already there) | dnf cannot install on them: run the installer inside a toolbox (`toolbox create`, `toolbox enter`), or layer Emacs (`rpm-ostree install emacs-pgtk`, reboot) and run `bash install.sh --method keep` |
| Debian 13, Ubuntu 26.04, Linux Mint, Pop!_OS, … | source build (`apt-get build-dep emacs`) | see below |
| macOS, Apple silicon, 15+ | Homebrew `brew install --cask emacs-plus-app` (prebuilt) | [Homebrew](https://brew.sh) is installed first if missing, after asking (below); `brew trust d12frosted/emacs-plus` first |
| macOS, Intel or older | Homebrew `brew install emacs-plus@31` (builds, ~30 min) | same |
| anything else, including RHEL, Rocky, Alma and Amazon Linux | — (exit 2) | install Emacs 31.1 yourself (below), then `bash install.sh --method keep` |

Not used, on purpose: Flathub's Emacs (still 30.2) and the Snap (native compilation unverified; the sandbox
gets in the way of language servers and tools).

### macOS

The script runs under the `/bin/bash` that ships with macOS (3.2); nothing newer is needed. Run it in Terminal.

What you see, step by step:

1. Open Terminal (⌘Space, type "Terminal", Return), paste the install command and press Return.
2. It prints its plan and asks **Go ahead? [y/N]**: type `y`, Return. Without Homebrew it then asks **Install
   Homebrew?** — Homebrew asks for your Mac login password (nothing shows while you type; that is normal) and may
   install Apple's Command Line Tools: a few minutes, longer on a slow network. Right after a Homebrew it just
   installed, it asks **Add it to ~/.zprofile?** for Homebrew's line: answer `y`.
3. Emacs comes from Homebrew: a download on Apple silicon with macOS 15 or newer, a build of about 30 minutes on Intel
   or an older macOS.
4. After the drgnx app, before the doctor's check, if `~/.local/bin` (where the `drgnx` command is) is not on your PATH yet,
   it asks **Add it to ~/.zprofile?** again: answer `y`. Lines added there work in every **new** Terminal window, not
   in the one already open.
5. The drgnx app opens, and with it the Welcome: go on with [onboarding.md](onboarding.md).

The details:

- **A good Emacs is kept.** An `emacs` on your PATH (or in `--prefix`) that is 31.1+, graphical (`ns`) and compiles
  natively is used as it is; nothing is installed. `/Applications/Emacs.app/Contents/MacOS/Emacs` is looked at too
  (it is usually not on PATH): good enough, it is kept and remembered. **An older Emacs.app there stops the installer
  before Homebrew** (exit 2) — the cask would install over it: "an older Emacs.app is in /Applications (Emacs 30.2):
  move it aside, or run with --method formula". `--method formula` builds `emacs-plus@31`, which lives in Homebrew's
  prefix beside your Emacs.app.
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
the check for a terminal (so the tests need no `setsid`).

### The source build

Used where the distribution has no 31.1 yet. Everything happens in `$XDG_CACHE_HOME/drgnx/build` (default `~/.cache/drgnx/build`); logs stay there.

1. Download `emacs-31.1.tar.xz` and its signature from the GNU mirrors and verify it against the GNU keyring
   (`gnu-keyring.gpg`; the 31.1 release is signed by Sean Whitton, key
   `8DC2 487E 51AB DD90 B5C4 753F 0F56 D055 3B6D 411B`; the installer checks that fingerprint — a good
   signature by another key of the keyring is refused). **This happens before anything is installed** — if a
   download fails (no network, a mirror that has not synced the release yet) or the signature does not verify,
   the installer says so and stops (exit 1), and nothing has changed. gpg runs with a private home in the
   build directory; your `~/.gnupg` is not used. Only `curl`, `gpg` and `xz` are
   installed first, and only if missing.
2. Build dependencies, as root: Fedora `dnf builddep emacs`; Debian/Ubuntu `apt-get build-dep emacs` with
   source packages enabled through drgnx-owned lists (`/etc/apt/sources.list.d/drgnx-deb-src.sources` and
   `.list`, mirroring every `deb` source of the system, including Linux Mint's one-line lists), removed again
   afterwards — also when a step fails or the run is interrupted, then `libgccjit-N-dev` for the default `gcc` (Ubuntu 26.04 builds its own Emacs
   with gcc 14 but defaults to gcc 15).
3. `./configure --prefix=~/.local --with-native-compilation=aot --with-tree-sitter --with-pgtk` (X11:
   `--with-x-toolkit=gtk3`). The installer stops if configure did not enable native compilation.
4. `make -jN`, then `make install` into your prefix — no root, and only after the build succeeded. N is one job
   per CPU but at most one per 1.5 GiB of available memory (or of the container's memory limit): every job is an
   Emacs compiling Lisp natively, and one per CPU can exhaust the memory of a many-core machine.

Expect 10–40 minutes depending on the machine (most of it is compiling the Lisp natively ahead of time).

To do it by hand, follow the same steps; any Emacs ≥ 31.1 built with `--with-native-compilation` works.

## Emacs 30.2

drgnx keeps working on 30.2 until every target platform ships 31.1. `drgnx doctor` warns; nothing fails.

## Security

- Emacs up to 31.1 has known issues that are fixed in 31.2 (not yet released). On 30.2: command injection through
  crafted TRAMP file names (CVE-2026-79992, CVE-2026-108976), Flymake running code from files being edited
  (CVE-2026-96442) and code execution through `read-symbol-shorthands` when opening a file (CVE-2026-96269). On
  31.1: the last three (the shorthands one is only partly fixed there). `drgnx doctor`'s `security` line names
  the ones that apply to your Emacs. It says OK while drgnx's own guards for them are on (see
  [Trusted folders](security.md)) and WARN when one is off, so a warning that stays means a guard is missing, not
  that you must upgrade. Until you run 31.2, avoid opening files you do not trust.
- The installer verifies the Emacs tarball's signature, prints every root command before running it, and never
  edits shell startup files without asking.

## Which Emacs drgnx runs in

Every `drgnx` subcommand (build, doctor, test, sync, …) runs in one Emacs: `$DRGNX_EMACS` if set, else the one the
installer recorded, else `emacs` on your PATH. The installer writes the path of the Emacs it installed or kept to
the first line of `~/.config/drgnx/emacs` (`$DRGNX_CONFIG_DIR/emacs`); this matters on macOS, where
`/Applications/Emacs.app/Contents/MacOS/Emacs` is usually not on PATH. If that file names something that is no
longer an executable file, drgnx falls back to PATH's `emacs`. Edit the file, or set `DRGNX_EMACS`, to use another.

## drgnx doctor

`drgnx doctor` runs its checks inside the Emacs drgnx will use (see above) and prints
one line per check, `OK`, `WARN` or `FAIL`, with a fix under anything that is not ok. It exits 1 on any failure.
`--json` for tools, `--dev` adds the tools needed to develop drgnx (mutter, dbus-run-session, ImageMagick, a
pgtk Emacs; on a Mac, which has no mutter, D-Bus or pgtk, only ImageMagick). On a Mac the doctor also checks that the
drgnx app is installed (fix: `drgnx macos-app`), that Homebrew is there (also looked for in `/opt/homebrew/bin` and
`/usr/local/bin`, in case it is not on PATH) and that the `drgnx` command is on PATH (fix: add `~/.local/bin` to PATH in
your shell's profile, `~/.zprofile` for zsh or, with `SHELL` unset, when it exists; else `~/.profile`) — each only a warning.
The `claude-adapter` check reads the `package.json` of the Claude Code adapter that the `claude` agent profiles would
run, without running it. It wants `@agentclientprotocol/claude-agent-acp` 0.93.0 or newer. The deprecated
`@zed-industries/claude-agent-acp`, an older version, or a program of no package drgnx knows is a warning, with the
one-line command that fixes it, or advice when the adapter is not in a global npm prefix ([agents.md](agents.md#sessions)). No adapter is only a notice. Details: [core.md](../develop/core.md#doctor-drgnx-doctorel).

A terminal-only Emacs (no graphical build) passes the `gui` check: drgnx runs in terminals, with no images and one font
size, and popups in the bottom lane on Emacs 30.2.

**The Terminal group.** Run from a terminal, the doctor also checks that terminal: `terminal` (which one it is, its
`TERM` and terminfo), `terminal-colours`, `terminal-mouse`, `terminal-keys` (the kitty keyboard protocol,
modifyOtherKeys or neither; for a terminal that sends neither, a table of the shortcuts it cannot send with the
Alt+Shift key and the F6 form that stand for each, and the terminals that would send them: the ones you have installed,
else the install command for your system), `terminal-clipboard` (copy to your clipboard by OSC 52), `terminal-tmux`
(inside tmux, the lines to add to `~/.tmux.conf`; drgnx never edits it), `terminal-ssh` (over SSH, whether this machine
has your terminal's terminfo) and `terminal-popups`. Outside a terminal it says `not run from a terminal` and nothing
more. Nothing in it prompts or installs anything; inside tmux it asks tmux once (1 second at most). Each warning
carries its fix. In drgnx, **Check This Terminal** (Help, in the palette) shows the same group for the terminal window
you are in. Details: [terminal.md](terminal.md#check-this-terminal).

## Uninstall

```sh
rm -rf ~/.local/share/drgnx ~/.local/bin/drgnx "${XDG_CACHE_HOME:-$HOME/.cache}/drgnx" "${XDG_STATE_HOME:-$HOME/.local/state}/drgnx"
```

Your settings (`~/.config/drgnx`) stay unless you remove them too.

On macOS, also `rm -rf ~/Applications/drgnx.app`, and if you want them gone:

- Emacs: `brew uninstall --cask emacs-plus-app` (Apple silicon, macOS 15+) or `brew uninstall emacs-plus@31`;
- an OpenRouter key onboarding stored: `security delete-internet-password -s openrouter.ai -a drgnx` (or delete
  `openrouter.ai` in Keychain Access);
- what onboarding installed, each only if it did: `brew uninstall ollama` (models: `ollama rm NAME` first, or
  `~/.ollama`), `brew uninstall --cask lm-studio` (models in `~/.lmstudio`), `npm uninstall -g
  @agentclientprotocol/claude-agent-acp` (or `@zed-industries/claude-agent-acp`, the deprecated package earlier
  versions installed; add `--prefix ~/.local` if it is there), `brew uninstall node`, `brew uninstall --cask claude-code`.

A source-built Emacs: `make uninstall` in the build directory (`~/.cache/drgnx/build/emacs-31.1`, or under `$XDG_CACHE_HOME` if you set it) before deleting the cache (or
remove `~/.local/bin/emacs*`, `~/.local/share/emacs`, `~/.local/libexec/emacs`). A packaged Emacs: remove it
with your package manager. The PATH line (on a Mac also Homebrew's), if you let the installer add it, is marked
`# added by the drgnx installer` in `~/.profile` (zsh: `~/.zprofile`).

## Testing the installer

`bin/drgnx test` runs install.sh's plans for every platform fixture (fast). `bin/drgnx test --install
[NAME…]` runs it for real in fresh containers — source builds on Fedora 44, Debian 13 and Ubuntu 26.04,
packages on Fedora 45 and Arch — then checks the doctor, that a second run changes nothing, and that
`--dry-run` touches nothing. Each container is limited to 6 GiB of memory. Slow (about 10–20 minutes per source
build); logs in `~/.local/state/drgnx/install-tests/`.
