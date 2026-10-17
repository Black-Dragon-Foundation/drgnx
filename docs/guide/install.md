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

Afterwards, start drgnx with the command the installer prints
(`emacs --init-directory ~/.local/share/drgnx/drgnx/init`), and run `drgnx doctor` at any time. Then `drgnx onboard` (or Help → Welcome in drgnx) checks the
rest of your machine, sets keys and modules, and puts your projects on the board ([onboarding.md](onboarding.md)).

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
6. **Compiles drgnx** (`drgnx build`) and **checks** it: runs `drgnx doctor` with the Emacs it found or installed.
7. **PATH:** if `~/.local/bin` is not on your `PATH`, it offers to add one line to `~/.profile` — only when you
   answer yes; with `--yes` it only prints the line.

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
| `--method M` | `auto` (default), `package`, `source`, or `keep` (do not touch Emacs); `package` and `source` only where the platform has that recipe (Fedora and Arch packages; Fedora and Debian-family source builds) — elsewhere it stops before the plan (exit 2) |
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
| macOS, Apple silicon, 15+ | Homebrew `brew install --cask emacs-plus-app` (prebuilt) | needs [Homebrew](https://brew.sh); `brew trust d12frosted/emacs-plus` first |
| macOS, Intel or older | Homebrew `brew install emacs-plus@31` (builds, ~30 min) | |
| anything else, including RHEL, Rocky, Alma and Amazon Linux | — (exit 2) | install Emacs 31.1 yourself (below), then `bash install.sh --method keep` |

Not used, on purpose: Flathub's Emacs (still 30.2) and the Snap (native compilation unverified; the sandbox
gets in the way of language servers and tools).

### The source build

Used where the distribution has no 31.1 yet. Everything happens in `$XDG_CACHE_HOME/drgnx/build` (default `~/.cache/drgnx/build`); logs stay there.

1. Download `emacs-31.1.tar.xz` and its signature from the GNU mirrors and verify it against the GNU keyring
   (`gnu-keyring.gpg`; the 31.1 release is signed by Sean Whitton, key
   `8DC2 487E 51AB DD90 B5C4 753F 0F56 D055 3B6D 411B`). **This happens before anything is installed** — if the
   signature does not verify, the installer stops and nothing has changed. gpg runs with a private home in the
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

- Emacs up to 31.1 has known issues that are fixed in 31.2 (not yet released): command injection through
  crafted TRAMP file names, Flymake running code from files being edited, and code execution through
  `read-symbol-shorthands` when opening a file. `drgnx doctor` reports this until you run 31.2. Until then,
  avoid opening untrusted files and remote paths.
- The installer verifies the Emacs tarball's signature, prints every root command before running it, and never
  edits shell startup files without asking.

## drgnx doctor

`drgnx doctor` runs its checks inside the Emacs drgnx will use (`$DRGNX_EMACS`, default `emacs`) and prints
one line per check, `OK`, `WARN` or `FAIL`, with a fix under anything that is not ok. It exits 1 on any failure.
`--json` for tools, `--dev` adds the tools needed to develop drgnx (mutter, dbus-run-session, ImageMagick, a
pgtk Emacs). Details: [core.md](../develop/core.md#doctor-drgnx-doctorel).

## Uninstall

```sh
rm -rf ~/.local/share/drgnx ~/.local/bin/drgnx "${XDG_CACHE_HOME:-$HOME/.cache}/drgnx"
```

A source-built Emacs: `make uninstall` in the build directory (`~/.cache/drgnx/build/emacs-31.1`, or under `$XDG_CACHE_HOME` if you set it) before deleting the cache (or
remove `~/.local/bin/emacs*`, `~/.local/share/emacs`, `~/.local/libexec/emacs`). A packaged Emacs: remove it
with your package manager. The PATH line, if you let the installer add it, is marked
`# added by the drgnx installer` in `~/.profile`.

## Testing the installer

`bin/drgnx test` runs install.sh's plans for every platform fixture (fast). `bin/drgnx test --install
[NAME…]` runs it for real in fresh containers — source builds on Fedora 44, Debian 13 and Ubuntu 26.04,
packages on Fedora 45 and Arch — then checks the doctor, that a second run changes nothing, and that
`--dry-run` touches nothing. Each container is limited to 6 GiB of memory. Slow (about 10–20 minutes per source
build); logs in `~/.local/state/drgnx/install-tests/`.
