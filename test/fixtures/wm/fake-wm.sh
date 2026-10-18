#!/bin/sh
# A stand-in for swaymsg, i3-msg, hyprctl and niri in tests: link it under one of those names.
#   DRGNX_FAKE_WM_LOG    file: appends "NAME ARGV..." per call; NAME's environment (SWAYSOCK, I3SOCK,
#                        HYPRLAND_INSTANCE_SIGNATURE, NIRI_SOCKET) goes to "$DRGNX_FAKE_WM_LOG.env"
#   DRGNX_FAKE_WM_DIR    directory of the replies
#   DRGNX_FAKE_WM_MAP    lines "ARGS-REGEXP FILE": the first regexp (grep -E) matching the arguments
#                        joined with spaces picks FILE (relative to DIR; ".json" is added if missing)
#   DRGNX_FAKE_WM_DELAY  seconds to sleep before answering
#   DRGNX_FAKE_WM_OUT    text printed to standard output (before any mapped reply)
#   DRGNX_FAKE_WM_STDERR text printed to standard error
#   DRGNX_FAKE_WM_EXIT   exit status (default 0)
name=$(basename "$0")
args="$*"
if [ -n "$DRGNX_FAKE_WM_LOG" ]; then
  printf '%s' "$name" >> "$DRGNX_FAKE_WM_LOG"
  for a in "$@"; do printf ' %s' "$a" >> "$DRGNX_FAKE_WM_LOG"; done
  printf '\n' >> "$DRGNX_FAKE_WM_LOG"
  printf 'SWAYSOCK=%s I3SOCK=%s HYPRLAND_INSTANCE_SIGNATURE=%s NIRI_SOCKET=%s\n' \
    "$SWAYSOCK" "$I3SOCK" "$HYPRLAND_INSTANCE_SIGNATURE" "$NIRI_SOCKET" >> "$DRGNX_FAKE_WM_LOG.env"
fi
[ -n "$DRGNX_FAKE_WM_DELAY" ] && sleep "$DRGNX_FAKE_WM_DELAY"
[ -n "$DRGNX_FAKE_WM_OUT" ] && printf '%s' "$DRGNX_FAKE_WM_OUT"
[ -n "$DRGNX_FAKE_WM_STDERR" ] && printf '%s' "$DRGNX_FAKE_WM_STDERR" >&2
printf '%s\n' "$DRGNX_FAKE_WM_MAP" | while IFS= read -r line; do
  [ -n "$line" ] || continue
  file=${line##* }
  pat=${line% *}
  if printf '%s' "$args" | grep -Eq -- "$pat"; then
    for f in "$DRGNX_FAKE_WM_DIR/$file" "$DRGNX_FAKE_WM_DIR/$file.json"; do
      [ -f "$f" ] && { cat "$f"; break; }
    done
    break
  fi
done
exit "${DRGNX_FAKE_WM_EXIT:-0}"
