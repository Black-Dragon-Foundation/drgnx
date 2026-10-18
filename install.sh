#!/usr/bin/env bash
# drgnx installer — gets GNU Emacs 31.1 with native compilation, then drgnx.
#
#   curl -fsSL https://raw.githubusercontent.com/Black-Dragon-Foundation/drgnx/main/install.sh | bash
#
# Or download, read, then run it (recommended):
#   curl -fsSLO https://raw.githubusercontent.com/Black-Dragon-Foundation/drgnx/main/install.sh
#   less install.sh && bash install.sh --dry-run && bash install.sh
#
# With --config URL (or --chezmoi URL) it then hands over to "drgnx bootstrap", which sets this machine up
# from your configuration repository; the URL is https or a local path, and is never evaluated.
#
# What it does is printed as a plan before anything happens. Every step that needs root is announced
# and confirmed (unless --yes). It never edits your shell startup files without asking. Running it again
# is safe. Everything is a function; nothing runs until `main` on the last line, so a truncated download
# does nothing. Details: docs/guide/install.md.
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

EMACS_VERSION=31.1
DRGNX_REPO="${DRGNX_INSTALL_REPO:-https://github.com/Black-Dragon-Foundation/drgnx.git}"
DOCS_URL=https://github.com/Black-Dragon-Foundation/drgnx/blob/main/docs/guide/install.md
GNU_MIRROR="${DRGNX_INSTALL_MIRROR:-https://ftpmirror.gnu.org/emacs}"         # overridable for tests
GNU_KEYRING="${DRGNX_INSTALL_KEYRING:-https://ftp.gnu.org/gnu/gnu-keyring.gpg}"
EMACS_SIGNER="${DRGNX_INSTALL_SIGNER:-8DC2487E51ABDD90B5C4753F0F56D0553B6D411B}"   # who signs $EMACS_VERSION (docs/guide/install.md)
APT_DIR="${DRGNX_INSTALL_APT_DIR:-/etc/apt}"
HOMEBREW_INSTALLER_URL=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf 'drgnx install: %s\n' "$*" >&2; }
die()  { local code=$1; shift; printf 'drgnx install: %s\n' "$*" >&2; exit "$code"; }

usage() {
  cat <<'EOF'
usage: install.sh [options]
  --dry-run          print the plan and exit; change nothing
  --yes              do not ask (root steps may still ask for your password)
  --prefix DIR       where a source-built Emacs and the drgnx command go (default ~/.local)
  --dir DIR          where drgnx is checked out (default ~/.local/share/drgnx/drgnx)
  --source-dir DIR   use this existing drgnx checkout instead of cloning
  --method M         auto (default) | package | source | keep (do not install Emacs)
                     | formula (macOS: Homebrew's emacs-plus@31, built from source)
  --branch B         drgnx branch to check out (default main)
  --config URL       then set this machine up from your configuration repository: runs
                     "drgnx bootstrap --config URL" (an https URL or a local path; asks before keys,
                     desktop and shell)
  --chezmoi URL      the same with a chezmoi source repository (cannot be combined with --config)
  --identity FILE    an age identity file for the secrets in the configuration (with --config or
                     --chezmoi; passed on as a path, never read here; mode 600)
  -h, --help         this help
EOF
}

parse_args() {
  DRY_RUN=0 YES=0 PREFIX="$HOME/.local" DIR="$HOME/.local/share/drgnx/drgnx" SOURCE_DIR="" METHOD=auto BRANCH=main
  CONFIG="" CHEZMOI="" IDENTITY="" CONFIG_LOCAL=0
  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes|-y) YES=1 ;;
      --prefix) need_value "$1" "${2-}" "a directory"; PREFIX="$2"; shift ;;
      --dir) need_value "$1" "${2-}" "a directory"; DIR="$2"; shift ;;
      --source-dir) need_value "$1" "${2-}" "a directory"; SOURCE_DIR="$2"; shift ;;
      --method) need_value "$1" "${2-}" "a value"; METHOD="$2"; shift ;;
      --branch) need_value "$1" "${2-}" "a value"; BRANCH="$2"; shift ;;
      --config) need_value "$1" "${2-}" "a URL or a path"; config_ref CONFIG "$1" "$2"; shift ;;
      --chezmoi) need_value "$1" "${2-}" "a URL or a path"; config_ref CHEZMOI "$1" "$2"; shift ;;
      --identity) need_value "$1" "${2-}" "a file"; IDENTITY="$(abs_path "$(home_path "$2")")"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die 2 "unknown option: $1" ;;
    esac
    shift
  done
  case "$METHOD" in auto|package|source|keep|formula) ;; *) die 2 "--method must be auto, package, source, keep or formula" ;; esac
  if [[ -n "$CONFIG" && -n "$CHEZMOI" ]]; then die 2 "--config and --chezmoi cannot be used together"; fi
  if [[ -n "$IDENTITY" && -z "$CONFIG$CHEZMOI" ]]; then die 2 "--identity needs --config or --chezmoi"; fi
  HANDOVER=0 BOOTSTRAP_ARGS=()   # the hand-over to `drgnx bootstrap' (Task 12): always an array, never a string to eval
  if [[ -n "$CONFIG" ]]; then HANDOVER=1 BOOTSTRAP_ARGS=(--config "$CONFIG"); fi
  if [[ -n "$CHEZMOI" ]]; then HANDOVER=1 BOOTSTRAP_ARGS=(--chezmoi "$CHEZMOI"); fi
  if [[ -n "$IDENTITY" ]]; then BOOTSTRAP_ARGS+=(--identity "$IDENTITY"); fi
  if ((YES)); then BOOTSTRAP_ARGS+=(--yes); fi
  if [[ -n "$SOURCE_DIR" ]]; then DIR="$SOURCE_DIR"; fi
  PREFIX="$(abs_path "$PREFIX")" DIR="$(abs_path "$DIR")"   # links and the build tree need absolute paths
}

need_value() { [[ -n "$2" ]] || { usage >&2; die 2 "$1 needs $3"; }; }   # OPTION VALUE WHAT — a bad option: exit 2

home_path() { case "$1" in "~/"*) printf '%s' "$HOME/${1#"~/"}" ;; *) printf '%s' "$1" ;; esac; }   # ~/x → $HOME/x

# VAR OPTION VALUE — set VAR to VALUE if it is an https URL (no user name or password in it, no blank) or a
# local path (made absolute); anything else (http, ssh, git@host:…, file://, ext::…) is a bad option: exit 2.
# The value is data from here on: it is only ever quoted or passed as one argument, never evaluated, and never
# echoed in an error (it may hold a password).
config_ref() {
  local var="$1" opt="$2" v="$3" rest
  local why="$opt takes an https URL or a local path (not http, ssh, git@host:, file:// or a URL with a password: use a git credential helper for private repositories)"
  if [[ "$v" == *[[:cntrl:]]* ]]; then die 2 "$why"; fi
  case "$v" in
    https://*)
      rest="${v#https://}"
      if [[ -z "${rest%%/*}" || "${rest%%/*}" == *@* || "$rest" == *[[:space:]]* ]]; then die 2 "$why"; fi
      printf -v "$var" '%s' "$v" ;;
    *)
      if [[ "$v" =~ ^[^/]*: ]]; then die 2 "$why"; fi          # a scheme, or scp-style host:path
      printf -v "$var" '%s' "$(abs_path "$(home_path "$v")")"
      CONFIG_LOCAL=1 ;;
  esac
}

abs_path() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }

# --- Detection --------------------------------------------------------------------------------------

os_field() { # FILE KEY → value of KEY in an os-release file, unquoted
  sed -n "s/^$2=//p" "$1" | head -1 | sed 's/^"\(.*\)"$/\1/; s/^'"'"'\(.*\)'"'"'$/\1/'
}

detect() {
  UNAME="${DRGNX_INSTALL_UNAME:-$(uname -s)}"
  ARCH="${DRGNX_INSTALL_ARCH:-$(uname -m)}"
  SESSION="${DRGNX_INSTALL_SESSION:-${XDG_SESSION_TYPE:-}}"
  OSTREE=0         # image-based (Silverblue, Kinoite, Bazzite, …): the system is read-only, dnf cannot install
  if [[ -e "${DRGNX_INSTALL_OSTREE_BOOTED:-/run/ostree-booted}" ]]; then OSTREE=1; fi
  if [[ -z "$SESSION" || "$SESSION" == tty ]]; then
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then SESSION=wayland
    elif [[ -n "${DISPLAY:-}" ]]; then SESSION=x11
    else SESSION=wayland; fi                  # no display (server, container): the pgtk build works on both
  fi
  if [[ "$UNAME" == Darwin ]]; then
    OS=macos FAMILY=macos ID=macos VERSION_ID="${DRGNX_INSTALL_MACOS:-$(sw_vers -productVersion 2>/dev/null || echo 0)}"
    PRETTY="macOS $VERSION_ID ($ARCH)"
    return
  fi
  OS=linux
  local f="${DRGNX_INSTALL_OS_RELEASE:-/etc/os-release}"
  [[ -r "$f" ]] || die 2 "cannot read $f to tell which Linux this is — see $DOCS_URL"
  ID="$(os_field "$f" ID)" VERSION_ID="$(os_field "$f" VERSION_ID)" PRETTY="$(os_field "$f" PRETTY_NAME)"
  local like; like="$(os_field "$f" ID_LIKE)"
  FAMILY=unknown
  for id in $ID $like; do
    case "$id" in
      fedora) FAMILY=fedora; break ;;
      arch) FAMILY=arch; break ;;
      debian|ubuntu) FAMILY=debian; break ;;
    esac
  done
  FEDORA_VERSION=""
  if [[ "$FAMILY" == fedora ]]; then   # RHEL clones and Amazon Linux list fedora in ID_LIKE but are not Fedora
    local platform; platform="$(os_field "$f" PLATFORM_ID)"
    if [[ "$platform" =~ ^platform:f([0-9]+)$ ]]; then FEDORA_VERSION="${BASH_REMATCH[1]}"
    elif [[ "$ID" == fedora && -z "$platform" ]]; then FEDORA_VERSION="$VERSION_ID"
    else FAMILY=unknown; fi
  fi
}

version_ge() { # A B → true if A >= B
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]
}

probe_emacs() {
  # Is there already an Emacs that is good for drgnx (>= 31.1, native compilation that compiles, graphical)?
  # On macOS also /Applications/Emacs.app, which is usually not on PATH (DRGNX_INSTALL_MACOS_APP=none|PATH overrides
  # it: tests). APP_OLD: that app is there but not good enough — what it is ("Emacs 30.2", or "unknown").
  EMACS_FOUND="" EMACS_INFO="" APP_OLD=""
  local candidates=() app=""
  if [[ -n "${DRGNX_INSTALL_EMACS:-}" ]]; then candidates=("$DRGNX_INSTALL_EMACS")
  else candidates=("$PREFIX/bin/emacs" emacs); fi
  if [[ "$FAMILY" == macos ]]; then
    app="${DRGNX_INSTALL_MACOS_APP:-/Applications/Emacs.app/Contents/MacOS/Emacs}"
    if [[ "$app" == none ]]; then app=""; else candidates+=("$app"); fi
  fi
  local e info
  for e in "${candidates[@]}"; do
    [[ "$e" == none ]] && continue
    command -v "$e" >/dev/null 2>&1 || continue
    info="$("$e" --batch -Q --eval '(princ (format "%s %s %s" emacs-version
             (and (fboundp (quote native-comp-available-p)) (native-comp-available-p)
                  (condition-case nil (progn (native-compile (quote (lambda () 1))) t) (error nil)))
             (cond ((featurep (quote pgtk)) "pgtk") ((featurep (quote ns)) "ns") ((featurep (quote x)) "x") (t "nil"))))' 2>/dev/null || true)"
    if [[ -z "$info" ]]; then
      if [[ -n "$app" && "$e" == "$app" ]]; then APP_OLD=unknown; fi
      continue
    fi
    EMACS_INFO="$info"
    local v native gui
    read -r v native gui <<<"$info"
    if version_ge "$v" "$EMACS_VERSION" && [[ "$native" == t && "$gui" != nil ]]; then
      EMACS_FOUND="$(command -v "$e")" APP_OLD=""; return
    fi
    if [[ -n "$app" && "$e" == "$app" ]]; then APP_OLD="Emacs $v"; fi
  done
}

choose_method() {
  if [[ "$METHOD" != auto ]]; then CHOSEN="$METHOD"
  elif [[ -n "$EMACS_FOUND" ]]; then CHOSEN=keep
  else
    case "$FAMILY" in
      macos) if [[ "$ARCH" == arm64 ]] && version_ge "$VERSION_ID" 15; then CHOSEN=cask; else CHOSEN=formula; fi ;;
      fedora) if version_ge "${FEDORA_VERSION:-0}" 45; then CHOSEN=package; else CHOSEN=source; fi ;;
      arch) CHOSEN=package ;;
      debian) CHOSEN=source ;;
      *) die 2 "no automatic install for ${PRETTY:-this system} yet. Install GNU Emacs $EMACS_VERSION with native compilation (see $DOCS_URL), then run: bash install.sh --method keep" ;;
    esac
  fi
  if [[ "$CHOSEN" == formula && "$FAMILY" != macos ]]; then die 2 "--method formula is for macOS (Homebrew's emacs-plus@31)"; fi
  if [[ "$CHOSEN" == cask && -n "$APP_OLD" ]]; then   # the cask installs /Applications/Emacs.app: never over yours
    die 2 "an older Emacs.app is in /Applications ($APP_OLD): move it aside, or run with --method formula (emacs-plus@31, built from source beside it) — see $DOCS_URL"
  fi
  if [[ "$CHOSEN" == package && "$FAMILY" == debian ]]; then CHOSEN=source; fi   # no 31.1 packages there yet
  if ((OSTREE)) && [[ "$FAMILY" == fedora && ( "$CHOSEN" == package || "$CHOSEN" == source ) ]]; then
    die 2 "${PRETTY:-this system} is image-based (rpm-ostree): dnf cannot install here. Either run this installer inside a toolbox (toolbox create, toolbox enter, then bash install.sh), or layer Emacs: rpm-ostree install emacs-pgtk, reboot, then run: bash install.sh --method keep (see $DOCS_URL)"
  fi
  case "$FAMILY:$SESSION" in
    fedora:x11) PKG=(dnf install -y emacs-gtk+x11) ;;
    fedora:*)   PKG=(dnf install -y emacs-pgtk) ;;
    arch:x11)   PKG=(pacman -Syu --needed --noconfirm emacs) ;;          # -yu: Arch supports no partial upgrades
    arch:*)     PKG=(pacman -Syu --needed --noconfirm emacs-wayland) ;;
    *)          PKG=() ;;
  esac
  if [[ "$SESSION" == x11 ]]; then GUI_FLAG=--with-x-toolkit=gtk3; else GUI_FLAG=--with-pgtk; fi
  case "$FAMILY" in
    fedora) DEPS=(dnf builddep -y emacs) ;;
    debian) DEPS=(apt-get build-dep -y emacs) ;;
    *)      DEPS=() ;;
  esac
  if [[ ( "$CHOSEN" == package && ${#PKG[@]} -eq 0 ) || ( "$CHOSEN" == source && ${#DEPS[@]} -eq 0 ) ]]; then
    die 2 "no --method $CHOSEN recipe for ${PRETTY:-this system} — use --method auto, or install GNU Emacs $EMACS_VERSION yourself (see $DOCS_URL), then run: bash install.sh --method keep"
  fi
  BUILD_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/drgnx/build"
  CONFIGURE=(./configure "--prefix=$PREFIX" --with-native-compilation=aot --with-tree-sitter "$GUI_FLAG")
  JOBS="$(build_jobs)"
}

find_brew() {
  # BREW = the Homebrew to use ("" if there is none; macOS only). DRGNX_INSTALL_BREW=none|PATH overrides
  # the search (tests): the brew on PATH first, then Apple silicon's, then Intel's prefix.
  BREW=""
  [[ "$FAMILY" == macos ]] || return 0
  if [[ -n "${DRGNX_INSTALL_BREW:-}" ]]; then
    [[ "$DRGNX_INSTALL_BREW" == none ]] || BREW="$DRGNX_INSTALL_BREW"
    return 0
  fi
  BREW="$(command -v brew 2>/dev/null || true)"
  local b
  if [[ -z "$BREW" ]]; then
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      if [[ -x "$b" ]]; then BREW="$b"; break; fi
    done
  fi
}

build_jobs() {
  # Parallel make jobs. Native compilation runs one Emacs per job, so: one per CPU, but at most one per
  # 1.5 GiB of available memory — one per CPU on a 16-thread machine starved a desktop into the OOM killer.
  local cpus kb max
  cpus="${DRGNX_INSTALL_NPROC:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
  kb="${DRGNX_INSTALL_MEMORY_KB:-}"
  if [[ -z "$kb" ]]; then
    kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
    [[ -n "$kb" ]] || kb=$((4 * 1024 * 1024))
    max="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)"     # a container's limit is below MemAvailable
    if [[ "$max" =~ ^[0-9]+$ ]] && ((max / 1024 < kb)); then kb=$((max / 1024)); fi
  fi
  local jobs=$((kb / (1536 * 1024)))
  ((jobs <= cpus)) || jobs=$cpus
  ((jobs >= 1)) || jobs=1
  printf '%s' "$jobs"
}

brew_is_rosetta() { [[ "$BREW" == /usr/local/bin/brew && "$ARCH" == arm64 ]]; }   # Intel's Homebrew on Apple silicon

plan_homebrew() { # the Homebrew lines of the plan (macOS)
  if [[ -z "$BREW" ]]; then
    note "Install Homebrew first (asked): it asks for your password, installs Apple's Command Line Tools if they are missing, and takes a few minutes:"
    note "  /bin/bash -c \"\$(curl -fsSL $HOMEBREW_INSTALLER_URL)\""
    note "then add its shellenv line to $(shell_rc) (asked)"
  elif brew_is_rosetta; then
    note "warning: $BREW is Homebrew for Intel, running under Rosetta on this Apple silicon Mac. It works, but a native one (/opt/homebrew) is better: see https://brew.sh"
  fi
}

planned_emacs() { # the Emacs this run leaves behind, as far as the plan can tell (the formula's path is an estimate:
                  # beside brew; the run records `brew --prefix emacs-plus@31` itself)
  case "$CHOSEN" in
    keep) echo "${EMACS_FOUND:-emacs}" ;;
    cask) echo /Applications/Emacs.app/Contents/MacOS/Emacs ;;
    formula) if [[ -n "$BREW" ]]; then echo "$(dirname "$(dirname "$BREW")")/opt/emacs-plus@31/bin/emacs"
             else echo "emacs-plus@31's bin/emacs"; fi ;;
    source) echo "$PREFIX/bin/emacs" ;;
    *) echo emacs ;;
  esac
}

print_plan() {
  say "drgnx install — ${PRETTY:-$OS}"
  say ""
  say "1. Emacs:"
  case "$CHOSEN" in
    keep) if [[ -n "$EMACS_FOUND" ]]; then note "keep the installed Emacs ${EMACS_INFO%% *} ($EMACS_FOUND): native compilation works"
          else note "keep the installed Emacs (--method keep)${EMACS_INFO:+: $EMACS_INFO}"; fi ;;
    package) note "install with: sudo ${PKG[*]}" ;;
    cask) plan_homebrew
          note "${BREW:-brew} trust d12frosted/emacs-plus && ${BREW:-brew} tap d12frosted/emacs-plus"
          note "${BREW:-brew} install --cask emacs-plus-app   (prebuilt, native compilation)" ;;
    formula) plan_homebrew
             note "${BREW:-brew} trust d12frosted/emacs-plus && ${BREW:-brew} tap d12frosted/emacs-plus"
             note "${BREW:-brew} install emacs-plus@31   (built from source, ~30 minutes)" ;;
    source)
      note "build GNU Emacs $EMACS_VERSION from source into $PREFIX (about 20-40 minutes)"
      note "download $GNU_MIRROR/emacs-$EMACS_VERSION.tar.xz and verify its signature (gnu-keyring.gpg) before installing anything"
      [[ "$FAMILY" == debian ]] && note "enable Debian source packages for build dependencies (a drgnx-owned apt list, removed afterwards)"
      note "build dependencies: sudo ${DEPS[*]}"
      [[ "$FAMILY" == debian ]] && note "then libgccjit for the default gcc (libgccjit-N-dev, N = gcc's major version)"
      note "${CONFIGURE[*]} && make -j$JOBS && make install   (in $BUILD_DIR, logs kept there; jobs limited by memory)" ;;
  esac
  say "2. drgnx:"
  if [[ -n "$SOURCE_DIR" ]]; then note "use the checkout in $DIR"
  elif [[ -d "$DIR/.git" ]]; then note "update $DIR (git pull --ff-only)"
  else note "git clone $DRGNX_REPO (branch $BRANCH) into $DIR (git is installed first if missing)"; fi
  say "3. Link $PREFIX/bin/drgnx → $DIR/bin/drgnx"
  note "Remember Emacs: $(planned_emacs)"
  say "4. Compile drgnx (drgnx build: byte-compiled, natively compiled as it loads)"
  if [[ "$OS" == macos ]]; then
    say "5. Install the drgnx app into $HOME/Applications/drgnx.app (Finder, Spotlight, the Dock, Open With)"
    if ((!HANDOVER)); then say "6. Run drgnx doctor"; say "7. Open the drgnx app"; fi
  elif ((!HANDOVER)); then
    say "5. Run drgnx doctor"
  fi
  if ((HANDOVER)); then   # bootstrap runs the doctor, and the desktop step opens drgnx
    local line
    printf -v line '%q ' "${BOOTSTRAP_ARGS[@]}"
    if ((YES)); then
      say "Then: drgnx bootstrap ${line}(--yes confirms the age/chezmoi install, the key import and chezmoi init: rc files, the desktop entry, commits, chezmoi apply and replacing a key still wait for you)"
    else
      say "Then: drgnx bootstrap ${line}(asks before keys, desktop and shell)"
    fi
  fi
}

# --- Doing it -----------------------------------------------------------------------------------------

have_tty() { # DRGNX_INSTALL_TTY=none|yes overrides the check (tests: no setsid needed to lose the terminal)
  case "${DRGNX_INSTALL_TTY:-}" in none) return 1 ;; yes) return 0 ;; esac
  (exec </dev/tty) 2>/dev/null
}

confirm() { # QUESTION → true if yes
  ((YES)) && return 0
  local ans
  printf '%s [y/N] ' "$1" >/dev/tty
  read -r ans </dev/tty || return 1
  [[ "$ans" == y || "$ans" == Y || "$ans" == yes ]]
}

as_root() { # [--no-ask] CMD… — announced, confirmed (unless --no-ask: cleanup), then run as root
  local ask=1
  if [[ "$1" == --no-ask ]]; then ask=0; shift; fi
  say "As root: $*"
  if ((EUID == 0)); then "$@"; return; fi
  command -v sudo >/dev/null 2>&1 || die 1 "this step needs root and sudo is not available: $*"
  if ((ask)); then confirm "Run it?" || die 1 "stopped before: $*"; fi
  sudo "$@"
}

install_emacs_package() {
  case "$FAMILY" in
    fedora|arch) as_root "${PKG[@]}" ;;
  esac
  EMACS_BIN=emacs
}

install_homebrew() { # macOS without Homebrew: explained, asked, then Homebrew's own installer
  [[ -z "$BREW" ]] || return 0
  say ""
  say "Emacs comes from Homebrew, which is not installed. Its installer asks for your password,"
  say "installs Apple's Command Line Tools if they are missing, and takes a few minutes."
  confirm "Install Homebrew?" || die 1 "Homebrew is needed on macOS: install it from https://brew.sh, then run this again"
  local script
  script="$(curl -fsSL "$HOMEBREW_INSTALLER_URL")" || die 1 "could not download Homebrew's installer ($HOMEBREW_INSTALLER_URL) — nothing was installed (no network?)"
  if ((YES)); then   # nobody to answer its questions; it needs sudo to work without a password prompt
    # </dev/null: its stdin must not be ours, which under `curl … | bash' is this script
    NONINTERACTIVE=1 /bin/bash -c "$script" </dev/null || die 1 "Homebrew's installer failed (above). With --yes it cannot ask for your password: run sudo -v first, or run without --yes"
  else
    /bin/bash -c "$script" </dev/tty || die 1 "Homebrew's installer failed (above) — nothing else was installed"
  fi
  local b candidates   # where its installer puts brew (DRGNX_INSTALL_BREW_PATHS, colon-separated: tests)
  IFS=: read -r -a candidates <<<"${DRGNX_INSTALL_BREW_PATHS:-/opt/homebrew/bin/brew:/usr/local/bin/brew}"
  for b in "${candidates[@]}"; do
    if [[ -x "$b" ]]; then BREW="$b"; break; fi
  done
  [[ -n "$BREW" ]] || die 1 "Homebrew was installed but brew was not found in /opt/homebrew/bin or /usr/local/bin — open a new terminal and run this again"
  eval "$("$BREW" shellenv)"
  brew_profile_hint
}

shell_rc() { # the login profile the user's shell reads (the doctor's rule, drgnx-doctor--shell-profile)
  case "${SHELL:-}" in
    */zsh) echo "$HOME/.zprofile" ;;                            # zsh (macOS's default) never reads ~/.profile
    "") if [[ -e "$HOME/.zprofile" ]]; then echo "$HOME/.zprofile"; else echo "$HOME/.profile"; fi ;;   # no SHELL: a guess
    *) echo "$HOME/.profile" ;;
  esac
}

brew_profile_hint() { # Homebrew's own installer asks you to put this in your profile; so do we, but ask
  local line="eval \"\$($BREW shellenv)\"" rc
  rc="$(shell_rc)"
  grep -qxF "$line" "$rc" 2>/dev/null && return
  say ""
  say "Homebrew must be on your PATH in new terminals."
  offer_rc_line "$rc" "$line"
}

install_emacs_brew() {
  [[ -n "$BREW" ]] || die 1 "Homebrew is needed on macOS: install it from https://brew.sh, then run this again"
  "$BREW" trust d12frosted/emacs-plus 2>/dev/null || true
  "$BREW" tap d12frosted/emacs-plus
  if [[ "$CHOSEN" == cask ]]; then
    "$BREW" install --cask emacs-plus-app
    EMACS_BIN=/Applications/Emacs.app/Contents/MacOS/Emacs
  else
    "$BREW" install emacs-plus@31
    EMACS_BIN="$("$BREW" --prefix emacs-plus@31)/bin/emacs"
  fi
}

enable_deb_src() {
  # drgnx-owned lists mirroring every system source as deb-src (deb822 .sources, one-line .list files and
  # sources.list — Linux Mint uses the .list form), so `apt-get build-dep` works. Removed afterwards, also
  # when a step fails or the run is interrupted.
  local d="$APT_DIR/sources.list.d" f sources list
  sources="$(mktemp)" list="$(mktemp)"
  for f in "$d"/*.sources; do
    [[ -e "$f" && "$f" != "$d"/drgnx-deb-src.* ]] || continue
    sed 's/^Types:.*/Types: deb-src/' "$f" >>"$sources"; printf '\n' >>"$sources"
  done
  for f in "$APT_DIR/sources.list" "$d"/*.list; do
    [[ -r "$f" && "$f" != "$d"/drgnx-deb-src.* ]] || continue
    { grep -E '^deb ' "$f" || true; } | sed 's/^deb /deb-src /' >>"$list"
  done
  trap disable_deb_src EXIT
  trap 'exit 130' INT TERM HUP     # so the EXIT trap runs on an interrupt too
  if [[ -s "$sources" ]]; then as_root install -m 644 "$sources" "$d/drgnx-deb-src.sources"; fi
  if [[ -s "$list" ]]; then as_root install -m 644 "$list" "$d/drgnx-deb-src.list"; fi
  rm -f "$sources" "$list"
  as_root apt-get update -qq
}

disable_deb_src() { # no question: the user already agreed to these files
  trap - EXIT INT TERM HUP
  as_root --no-ask rm -f "$APT_DIR/sources.list.d/drgnx-deb-src.sources" "$APT_DIR/sources.list.d/drgnx-deb-src.list"
  as_root --no-ask apt-get update -qq || true
}

download_tools() { # curl, gpg and xz — installed as root only when one is missing
  local t
  for t in curl gpg xz; do
    command -v "$t" >/dev/null 2>&1 && continue
    case "$FAMILY" in
      fedora) as_root dnf install -y curl gnupg2 xz ;;
      debian)
        as_root apt-get update -qq
        as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates gnupg xz-utils ;;
    esac
    return
  done
}

download() { # URL FILE — no half file is kept
  curl -fsSL -o "$2" "$1" && return
  rm -f "$2"
  die 1 "could not download $1 — nothing was installed (no network, or the mirror has not synced the release yet: try again later)"
}

fetch_emacs_source() { # download, verify and unpack into $BUILD_DIR/emacs-VERSION (kept across runs)
  local src="emacs-$EMACS_VERSION"
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
  [[ -d "$src" ]] && return
  say "Downloading $src and its signature…"
  download "$GNU_MIRROR/$src.tar.xz" "$src.tar.xz"
  download "$GNU_MIRROR/$src.tar.xz.sig" "$src.tar.xz.sig"
  download "$GNU_KEYRING" gnu-keyring.gpg
  rm -rf gnupg && mkdir -m 700 gnupg   # a private gpg home: the user's ~/.gnupg is neither needed nor touched
  if ! gpg --homedir ./gnupg --batch --no-default-keyring --keyring "./gnu-keyring.gpg" --status-fd 3 \
       --verify "$src.tar.xz.sig" "$src.tar.xz" 2>"$BUILD_DIR/gpg.log" 3>"$BUILD_DIR/gpg.status"; then
    rm -f "$src.tar.xz" "$src.tar.xz.sig"
    die 1 "the signature of $src.tar.xz does not verify — nothing was installed (details: $BUILD_DIR/gpg.log)"
  fi
  # Any key of the GNU keyring signs validly; the release's signer is pinned (VALIDSIG: the signing key's
  # fingerprint, and last the primary key's).
  if ! awk -v fp="$EMACS_SIGNER" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && ($3 == fp || $NF == fp) { ok = 1 }
                                  END { exit !ok }' "$BUILD_DIR/gpg.status"; then
    rm -f "$src.tar.xz" "$src.tar.xz.sig"
    die 1 "$src.tar.xz has a good signature, but not by the key that signs Emacs releases ($EMACS_SIGNER) — nothing was installed (details: $BUILD_DIR/gpg.log)"
  fi
  grep -E 'Good signature' "$BUILD_DIR/gpg.log" | sed 's/^/  /' || true
  rm -rf "$src.partial"      # unpacked aside: an interrupted unpack is never taken for a verified tree
  mkdir "$src.partial"
  tar xf "$src.tar.xz" -C "$src.partial"
  mv "$src.partial/$src" "$src"
  rmdir "$src.partial"
}

install_emacs_source() {
  download_tools
  fetch_emacs_source         # verified before anything is installed
  case "$FAMILY" in
    fedora)
      as_root dnf install -y dnf-plugins-core git make gcc
      as_root "${DEPS[@]}" ;;
    debian)
      as_root apt-get update -qq
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git build-essential
      enable_deb_src
      as_root env DEBIAN_FRONTEND=noninteractive "${DEPS[@]}" -qq
      disable_deb_src
      # The distro may build its emacs with an older gcc (Ubuntu 26.04: gcc-14, default 15).
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "libgccjit-$(gcc -dumpversion | cut -d. -f1)-dev" ;;
    *) die 2 "no source-build recipe for $PRETTY — see $DOCS_URL" ;;
  esac
  cd "$BUILD_DIR/emacs-$EMACS_VERSION"
  say "Configuring (log: $BUILD_DIR/configure.log)…"
  "${CONFIGURE[@]}" >"$BUILD_DIR/configure.log" 2>&1 || die 1 "configure failed — see $BUILD_DIR/configure.log"
  grep -q 'Does Emacs have native lisp compiler? *yes' "$BUILD_DIR/configure.log" ||
    die 1 "configure did not enable native compilation (libgccjit missing?) — see $BUILD_DIR/configure.log"
  say "Building, this takes a while (log: $BUILD_DIR/make.log)…"
  make -j"$JOBS" >"$BUILD_DIR/make.log" 2>&1 ||
    die 1 "the build failed — see $BUILD_DIR/make.log (nothing was installed)"
  make install >"$BUILD_DIR/install.log" 2>&1 || die 1 "make install failed — see $BUILD_DIR/install.log"
  EMACS_BIN="$PREFIX/bin/emacs"
}

need_git() { # a package install (Arch, Fedora 45) does not bring git
  command -v git >/dev/null 2>&1 && return
  case "$FAMILY" in
    fedora) as_root dnf install -y git ;;
    debian) as_root apt-get update -qq
            as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git ;;
    arch)   as_root pacman -S --needed --noconfirm git ;;
    *)      die 1 "git is needed to fetch drgnx: install it (macOS: xcode-select --install), then run this again" ;;
  esac
}

fetch_drgnx() {
  if [[ -n "$SOURCE_DIR" ]]; then return; fi
  need_git
  if [[ -d "$DIR/.git" ]]; then
    git -C "$DIR" pull --ff-only --quiet || warn "could not update $DIR (local changes?) — keeping it as it is"
  else
    mkdir -p "$(dirname "$DIR")"
    git clone --quiet --branch "$BRANCH" "$DRGNX_REPO" "$DIR"
  fi
}

link_drgnx() {
  mkdir -p "$PREFIX/bin"
  ln -sfn "$DIR/bin/drgnx" "$PREFIX/bin/drgnx"
}

remember_emacs() { # drgnx commands run in the Emacs just installed, even when it is not `emacs' on PATH (macOS)
  # in drgnx's data dir: the path is this machine's, and the config dir travels to others
  local dir="${DRGNX_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/drgnx}" e
  e="$(command -v "$EMACS_BIN" 2>/dev/null || true)"
  e="${e:-$EMACS_BIN}"
  [[ "$e" == /* ]] || warn "the Emacs ($e) is not an absolute path, which drgnx ignores: it will use the emacs on your PATH (or set DRGNX_EMACS)"
  { mkdir -p "$dir" && printf '%s\n' "$e" >"$dir/emacs"; } ||
    warn "could not record the Emacs in $dir/emacs: drgnx will use the emacs on your PATH (or set DRGNX_EMACS)"
}

offer_rc_line() { # RC LINE — add LINE to the startup file RC only if the user says yes (--yes does not count)
  local rc="$1" line="$2"
  if ((YES)) || ! have_tty; then note "add this to $rc: $line"; return; fi
  if confirm "Add it to $rc?"; then
    grep -qxF "$line" "$rc" 2>/dev/null || printf '\n# added by the drgnx installer\n%s\n' "$line" >>"$rc"
    note "added to $rc — open a new terminal (or: . $rc)"
  else
    note "add this to $rc: $line"
  fi
}

install_app() { # macOS: drgnx.app in ~/Applications (core/drgnx-macos.el); a failure warns, the run goes on
  say ""
  say "Installing the drgnx app (Finder, Spotlight, the Dock, Open With)…"
  if DRGNX_EMACS="$EMACS_BIN" "$DIR/bin/drgnx" macos-app && [[ -d "$HOME/Applications/drgnx.app" ]]; then return 0; fi
  warn "the drgnx app was not installed (above): run drgnx macos-app later to try again"
  return 1
}

open_app() { # APP — the first start opens the Welcome; only in a desktop session (not over SSH, not --yes without a terminal)
  [[ -z "${SSH_CONNECTION:-}" ]] || return 0
  if ((YES)) && ! have_tty; then return 0; fi
  say "Opening drgnx…"
  open -a "$1" || warn "could not open $1: open drgnx with Spotlight (⌘Space, type \"drgnx\")"
}

check_handover() { # before anything is installed: a local configuration is there, the identity file is private
  if ((CONFIG_LOCAL)) && [[ ! -e "${CONFIG:-$CHEZMOI}" ]]; then
    die 2 "the configuration ${CONFIG:-$CHEZMOI} does not exist"
  fi
  [[ -n "$IDENTITY" ]] || return 0
  local q mode
  printf -v q '%q' "$IDENTITY"
  if [[ ! -f "$IDENTITY" || ! -r "$IDENTITY" ]]; then die 2 "the identity file $q is not a readable file"; fi
  mode="$(ls -ldL -- "$IDENTITY" | cut -c5-10)"          # group and others: never the content
  if [[ "$mode" != "------" ]]; then die 2 "the identity file $q can be read by other users: chmod 600 $q, then run this again"; fi
}

hand_over() { # `drgnx bootstrap' decides everything from here (keys, desktop, shell): its exit code is ours
  local rc=0
  say ""
  say "Handing over to drgnx bootstrap…"
  # its questions go to the terminal; with none (or under --yes without one) it gets no input at all —
  # never the pipe of `curl … | bash', which carries this script
  if have_tty; then
    DRGNX_EMACS="$EMACS_BIN" "$DIR/bin/drgnx" bootstrap "${BOOTSTRAP_ARGS[@]}" </dev/tty || rc=$?
  else
    DRGNX_EMACS="$EMACS_BIN" "$DIR/bin/drgnx" bootstrap "${BOOTSTRAP_ARGS[@]}" </dev/null || rc=$?
  fi
  exit "$rc"
}

path_hint() {
  case ":$PATH:" in *":$PREFIX/bin:"*) return ;; esac
  local rc line="export PATH=\"$PREFIX/bin:\$PATH\""
  rc="$(shell_rc)"
  say ""
  say "$PREFIX/bin is not on your PATH."
  offer_rc_line "$rc" "$line"
}

main() {
  parse_args "$@"
  detect
  probe_emacs
  choose_method
  find_brew
  print_plan
  if ((DRY_RUN)); then exit 0; fi
  check_handover
  if ((!YES)) && ! have_tty; then
    die 3 "no terminal to ask questions on — re-run with --yes, or download install.sh and run it (see $DOCS_URL)"
  fi
  say ""
  confirm "Go ahead?" || die 1 "nothing was changed"
  EMACS_BIN="${EMACS_FOUND:-emacs}"
  case "$CHOSEN" in
    keep) ;;
    package) install_emacs_package ;;
    cask|formula) install_homebrew; install_emacs_brew ;;
    source) install_emacs_source ;;
  esac
  fetch_drgnx
  link_drgnx
  remember_emacs
  say ""
  DRGNX_EMACS="$EMACS_BIN" "$DIR/bin/drgnx" build >/dev/null || warn "drgnx build failed: run $DIR/bin/drgnx build to see why (drgnx still runs, uncompiled)"
  local app=""   # the app and the PATH line first: the doctor checks them
  if [[ "$OS" == macos ]] && install_app; then app="$HOME/Applications/drgnx.app"; fi
  path_hint
  if ((HANDOVER)); then hand_over; fi
  say ""
  DRGNX_EMACS="$EMACS_BIN" "$DIR/bin/drgnx" doctor || warn "the doctor found problems (above)"
  say ""
  if [[ "$OS" == macos ]]; then   # the app opens drgnx; the Dock shows Emacs while it runs
    say "Done."
    say "Next time: open drgnx with Spotlight (⌘Space, type \"drgnx\") or Launchpad, or run \"drgnx .\" in a project."
    say "To keep it in the Dock, drag ~/Applications/drgnx.app there — not the Emacs icon the Dock shows while drgnx runs."
  else
    say "Done. Start drgnx with:  $EMACS_BIN --init-directory $DIR/init"
  fi
  if [[ -n "$app" ]]; then open_app "$app"; fi
}

main "$@"
