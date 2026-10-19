# drgnx-paths.sh — where drgnx keeps each kind of file, for bash: the rule of core/drgnx-paths.el's drgnx-paths-dir.
# bin/drgnx sources it; install.sh carries a byte-identical copy (curl pipes it, so it cannot source a sibling file).
# SPDX-License-Identifier: GPL-3.0-or-later

xdg_dir() { # VAR DEFAULT — $VAR when it is an absolute path, else DEFAULT: the XDG spec ignores an empty or relative value
  local v="${!1:-}"
  if [[ "$v" == /* ]]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

drgnx_dir() { # KIND — config, state, cache or data: the directory, without a trailing slash (docs/guide/files.md)
  local own="" var base dir s=/
  case "$1" in
    config) own=DRGNX_CONFIG_DIR var=XDG_CONFIG_HOME base="$HOME/.config" ;;
    state) var=XDG_STATE_HOME base="$HOME/.local/state" ;;
    cache) var=XDG_CACHE_HOME base="$HOME/.cache" ;;
    data) own=DRGNX_DATA_DIR var=XDG_DATA_HOME base="$HOME/.local/share" ;;
    *) printf 'drgnx_dir: no kind %s\n' "$1" >&2; return 2 ;;
  esac
  if [[ -n "$own" && "${!own:-}" == /* ]]; then dir="${!own}"
  else
    dir="$(xdg_dir "$var" "$base")/drgnx"
    # an old ~/.config/drgnx is still used while $XDG_CONFIG_HOME/drgnx does not exist (the doctor says move it)
    if [[ "$1" == config && ! -d "$dir" && -d "$base/drgnx" ]]; then dir="$base/drgnx"; fi
  fi
  # $s, not \/: before bash 4.3 (macOS's 3.2) a quoted ${x//p/r} keeps the backslash of an escaped replacement
  while [[ "$dir" == *//* ]]; do dir="${dir//$s$s/$s}"; done
  while [[ "$dir" == */ && "$dir" != / ]]; do dir="${dir%/}"; done
  printf '%s' "$dir"
}
