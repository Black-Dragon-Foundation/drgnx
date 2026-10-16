#!/usr/bin/env bash
# drgnx installer — gets GNU Emacs 31.1 with native compilation, then drgnx.
#
#   curl -fsSL https://raw.githubusercontent.com/Black-Dragon-Foundation/drgnx/main/install.sh | bash
#
# Or download, read, then run it (recommended):
#   curl -fsSLO https://raw.githubusercontent.com/Black-Dragon-Foundation/drgnx/main/install.sh
#   less install.sh && bash install.sh --dry-run && bash install.sh
#
# What it does is printed as a plan before anything happens. Every step that needs root is announced
# and confirmed (unless --yes). It never edits your shell startup files without asking. Running it again
# is safe. Everything is a function; nothing runs until `main` on the last line, so a truncated download
# does nothing. Details: docs/install.md.
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

EMACS_VERSION=31.1
DRGNX_REPO=https://github.com/Black-Dragon-Foundation/drgnx.git
DOCS_URL=https://github.com/Black-Dragon-Foundation/drgnx/blob/main/docs/install.md
GNU_MIRROR="${DRGNX_INSTALL_MIRROR:-https://ftpmirror.gnu.org/emacs}"         # overridable for tests
GNU_KEYRING="${DRGNX_INSTALL_KEYRING:-https://ftp.gnu.org/gnu/gnu-keyring.gpg}"

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
  --branch B         drgnx branch to check out (default main)
  -h, --help         this help
EOF
}

parse_args() {
  DRY_RUN=0 YES=0 PREFIX="$HOME/.local" DIR="$HOME/.local/share/drgnx/drgnx" SOURCE_DIR="" METHOD=auto BRANCH=main
  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes|-y) YES=1 ;;
      --prefix) PREFIX="${2:?--prefix needs a directory}"; shift ;;
      --dir) DIR="${2:?--dir needs a directory}"; shift ;;
      --source-dir) SOURCE_DIR="${2:?--source-dir needs a directory}"; shift ;;
      --method) METHOD="${2:?--method needs a value}"; shift ;;
      --branch) BRANCH="${2:?--branch needs a value}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die 2 "unknown option: $1" ;;
    esac
    shift
  done
  case "$METHOD" in auto|package|source|keep) ;; *) die 2 "--method must be auto, package, source or keep" ;; esac
  if [[ -n "$SOURCE_DIR" ]]; then DIR="$SOURCE_DIR"; fi
}

# --- Detection --------------------------------------------------------------------------------------

os_field() { # FILE KEY → value of KEY in an os-release file, unquoted
  sed -n "s/^$2=//p" "$1" | head -1 | sed 's/^"\(.*\)"$/\1/; s/^'"'"'\(.*\)'"'"'$/\1/'
}

detect() {
  UNAME="${DRGNX_INSTALL_UNAME:-$(uname -s)}"
  ARCH="${DRGNX_INSTALL_ARCH:-$(uname -m)}"
  SESSION="${DRGNX_INSTALL_SESSION:-${XDG_SESSION_TYPE:-}}"
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
}

version_ge() { # A B → true if A >= B
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]
}

probe_emacs() {
  # Is there already an Emacs that is good for drgnx (>= 31.1, native compilation that compiles, graphical)?
  EMACS_FOUND="" EMACS_INFO=""
  local candidates=()
  if [[ -n "${DRGNX_INSTALL_EMACS:-}" ]]; then candidates=("$DRGNX_INSTALL_EMACS")
  else candidates=("$PREFIX/bin/emacs" emacs); fi
  local e info
  for e in "${candidates[@]}"; do
    [[ "$e" == none ]] && continue
    command -v "$e" >/dev/null 2>&1 || continue
    info="$("$e" --batch -Q --eval '(princ (format "%s %s %s" emacs-version
             (and (fboundp (quote native-comp-available-p)) (native-comp-available-p)
                  (condition-case nil (progn (native-compile (quote (lambda () 1))) t) (error nil)))
             (cond ((featurep (quote pgtk)) "pgtk") ((featurep (quote ns)) "ns") ((featurep (quote x)) "x") (t "nil"))))' 2>/dev/null || true)"
    [[ -n "$info" ]] || continue
    EMACS_INFO="$info"
    local v native gui
    read -r v native gui <<<"$info"
    if version_ge "$v" "$EMACS_VERSION" && [[ "$native" == t && "$gui" != nil ]]; then
      EMACS_FOUND="$(command -v "$e")"; return
    fi
  done
}

choose_method() {
  if [[ "$METHOD" != auto ]]; then CHOSEN="$METHOD"
  elif [[ -n "$EMACS_FOUND" ]]; then CHOSEN=keep
  else
    case "$FAMILY" in
      macos) if [[ "$ARCH" == arm64 ]] && version_ge "$VERSION_ID" 15; then CHOSEN=cask; else CHOSEN=formula; fi ;;
      fedora) if version_ge "${VERSION_ID:-0}" 45; then CHOSEN=package; else CHOSEN=source; fi ;;
      arch) CHOSEN=package ;;
      debian) CHOSEN=source ;;
      *) die 2 "no automatic install for ${PRETTY:-this system} yet. Install GNU Emacs $EMACS_VERSION with native compilation (see $DOCS_URL), then run: bash install.sh --method keep" ;;
    esac
  fi
  if [[ "$CHOSEN" == package && "$FAMILY" == debian ]]; then CHOSEN=source; fi   # no 31.1 packages there yet
  case "$FAMILY:$SESSION" in
    fedora:x11) PKG=(dnf install -y emacs-gtk+x11) ;;
    fedora:*)   PKG=(dnf install -y emacs-pgtk) ;;
    arch:x11)   PKG=(pacman -S --needed --noconfirm emacs) ;;
    arch:*)     PKG=(pacman -S --needed --noconfirm emacs-wayland) ;;
    *)          PKG=() ;;
  esac
  if [[ "$SESSION" == x11 ]]; then GUI_FLAG=--with-x-toolkit=gtk3; else GUI_FLAG=--with-pgtk; fi
  case "$FAMILY" in
    fedora) DEPS=(dnf builddep -y emacs) ;;
    debian) DEPS=(apt-get build-dep -y emacs) ;;
    *)      DEPS=() ;;
  esac
  BUILD_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/drgnx/build"
  CONFIGURE=(./configure "--prefix=$PREFIX" --with-native-compilation=aot --with-tree-sitter "$GUI_FLAG")
}

print_plan() {
  say "drgnx install — ${PRETTY:-$OS}"
  say ""
  say "1. Emacs:"
  case "$CHOSEN" in
    keep) if [[ -n "$EMACS_FOUND" ]]; then note "keep the installed Emacs ${EMACS_INFO%% *} ($EMACS_FOUND): native compilation works"
          else note "keep the installed Emacs (--method keep)${EMACS_INFO:+: $EMACS_INFO}"; fi ;;
    package) note "install with: sudo ${PKG[*]}" ;;
    cask) note "brew trust d12frosted/emacs-plus && brew tap d12frosted/emacs-plus"
          note "brew install --cask emacs-plus-app   (prebuilt, native compilation)" ;;
    formula) note "brew trust d12frosted/emacs-plus && brew tap d12frosted/emacs-plus"
             note "brew install emacs-plus@31   (built from source, ~30 minutes)" ;;
    source)
      note "build GNU Emacs $EMACS_VERSION from source into $PREFIX (about 20-40 minutes)"
      note "download $GNU_MIRROR/emacs-$EMACS_VERSION.tar.xz and verify its signature (gnu-keyring.gpg) before installing anything"
      [[ "$FAMILY" == debian ]] && note "enable Debian source packages for build dependencies (a drgnx-owned apt list, removed afterwards)"
      note "build dependencies: sudo ${DEPS[*]}"
      note "${CONFIGURE[*]} && make && make install   (in $BUILD_DIR, logs kept there)" ;;
  esac
  say "2. drgnx:"
  if [[ -n "$SOURCE_DIR" ]]; then note "use the checkout in $DIR"
  elif [[ -d "$DIR/.git" ]]; then note "update $DIR (git pull --ff-only)"
  else note "git clone $DRGNX_REPO (branch $BRANCH) into $DIR"; fi
  say "3. Link $PREFIX/bin/drgnx → $DIR/bin/drgnx"
  say "4. Run drgnx doctor"
}

# --- Doing it -----------------------------------------------------------------------------------------

have_tty() { (exec </dev/tty) 2>/dev/null; }

confirm() { # QUESTION → true if yes
  ((YES)) && return 0
  local ans
  printf '%s [y/N] ' "$1" >/dev/tty
  read -r ans </dev/tty || return 1
  [[ "$ans" == y || "$ans" == Y || "$ans" == yes ]]
}

as_root() { # CMD… — announced, confirmed, then run as root
  if ((EUID == 0)); then "$@"; return; fi
  command -v sudo >/dev/null 2>&1 || die 1 "this step needs root and sudo is not available: $*"
  say "As root: $*"
  confirm "Run it?" || die 1 "stopped before: $*"
  sudo "$@"
}

install_emacs_package() {
  case "$FAMILY" in
    fedora|arch) as_root "${PKG[@]}" ;;
  esac
  EMACS_BIN=emacs
}

install_emacs_brew() {
  command -v brew >/dev/null 2>&1 || die 1 "Homebrew is needed on macOS: install it from https://brew.sh, then run this again"
  brew trust d12frosted/emacs-plus 2>/dev/null || true
  brew tap d12frosted/emacs-plus
  if [[ "$CHOSEN" == cask ]]; then
    brew install --cask emacs-plus-app
    EMACS_BIN=/Applications/Emacs.app/Contents/MacOS/Emacs
  else
    brew install emacs-plus@31
    EMACS_BIN="$(brew --prefix emacs-plus@31)/bin/emacs"
  fi
}

enable_deb_src() {
  # A drgnx-owned list mirroring the system's sources as deb-src, so `apt-get build-dep` works; removed afterwards.
  local f out=/etc/apt/sources.list.d/drgnx-deb-src.sources tmp
  tmp="$(mktemp)"
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -e "$f" ]] || continue
    sed 's/^Types:.*/Types: deb-src/' "$f" >>"$tmp"; printf '\n' >>"$tmp"
  done
  if [[ -s "$tmp" ]]; then
    as_root install -m 644 "$tmp" "$out"
  elif [[ -r /etc/apt/sources.list ]]; then
    grep -E '^deb ' /etc/apt/sources.list | sed 's/^deb /deb-src /' >"$tmp" || true
    as_root install -m 644 "$tmp" /etc/apt/sources.list.d/drgnx-deb-src.list
  fi
  rm -f "$tmp"
  as_root apt-get update -qq
}

disable_deb_src() {
  as_root rm -f /etc/apt/sources.list.d/drgnx-deb-src.sources /etc/apt/sources.list.d/drgnx-deb-src.list
  as_root apt-get update -qq || true
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

fetch_emacs_source() { # download, verify and unpack into $BUILD_DIR/emacs-VERSION (kept across runs)
  local src="emacs-$EMACS_VERSION"
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
  [[ -d "$src" ]] && return
  say "Downloading $src and its signature…"
  curl -fsSLO "$GNU_MIRROR/$src.tar.xz"
  curl -fsSLO "$GNU_MIRROR/$src.tar.xz.sig"
  curl -fsSLo gnu-keyring.gpg "$GNU_KEYRING"
  if ! gpg --batch --no-default-keyring --keyring "./gnu-keyring.gpg" --verify "$src.tar.xz.sig" "$src.tar.xz" 2>"$BUILD_DIR/gpg.log"; then
    rm -f "$src.tar.xz" "$src.tar.xz.sig"
    die 1 "the signature of $src.tar.xz does not verify — nothing was installed (details: $BUILD_DIR/gpg.log)"
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
      disable_deb_src ;;
    *) die 2 "no source-build recipe for $PRETTY — see $DOCS_URL" ;;
  esac
  cd "$BUILD_DIR/emacs-$EMACS_VERSION"
  say "Configuring (log: $BUILD_DIR/configure.log)…"
  "${CONFIGURE[@]}" >"$BUILD_DIR/configure.log" 2>&1 || die 1 "configure failed — see $BUILD_DIR/configure.log"
  grep -q 'Does Emacs have native lisp compiler? *yes' "$BUILD_DIR/configure.log" ||
    die 1 "configure did not enable native compilation (libgccjit missing?) — see $BUILD_DIR/configure.log"
  say "Building, this takes a while (log: $BUILD_DIR/make.log)…"
  make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" >"$BUILD_DIR/make.log" 2>&1 ||
    die 1 "the build failed — see $BUILD_DIR/make.log (nothing was installed)"
  make install >"$BUILD_DIR/install.log" 2>&1 || die 1 "make install failed — see $BUILD_DIR/install.log"
  EMACS_BIN="$PREFIX/bin/emacs"
}

fetch_drgnx() {
  if [[ -n "$SOURCE_DIR" ]]; then return; fi
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

path_hint() {
  case ":$PATH:" in *":$PREFIX/bin:"*) return ;; esac
  local rc="$HOME/.profile" line="export PATH=\"$PREFIX/bin:\$PATH\""
  say ""
  say "$PREFIX/bin is not on your PATH."
  if ((YES)) || ! have_tty; then note "add this to your shell startup file: $line"; return; fi
  if confirm "Add it to $rc?"; then
    grep -qxF "$line" "$rc" 2>/dev/null || printf '\n# added by the drgnx installer\n%s\n' "$line" >>"$rc"
    note "added to $rc — open a new terminal (or: . $rc)"
  else
    note "add this to your shell startup file: $line"
  fi
}

main() {
  parse_args "$@"
  detect
  probe_emacs
  choose_method
  print_plan
  if ((DRY_RUN)); then exit 0; fi
  if ((!YES)) && ! have_tty; then
    die 3 "no terminal to ask questions on — re-run with --yes, or download install.sh and run it (see $DOCS_URL)"
  fi
  say ""
  confirm "Go ahead?" || die 1 "nothing was changed"
  EMACS_BIN="${EMACS_FOUND:-emacs}"
  case "$CHOSEN" in
    keep) ;;
    package) install_emacs_package ;;
    cask|formula) install_emacs_brew ;;
    source) install_emacs_source ;;
  esac
  fetch_drgnx
  link_drgnx
  say ""
  DRGNX_EMACS="$EMACS_BIN" "$DIR/bin/drgnx" doctor || warn "the doctor found problems (above)"
  path_hint
  say ""
  say "Done. Start drgnx with:  $EMACS_BIN --init-directory $DIR/init"
}

main "$@"
