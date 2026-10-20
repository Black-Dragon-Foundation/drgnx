# Notices

drgnx tells you things in one way: each notice has a severity (`info`, `warn`, `fail`) and a lifetime (an event,
a condition until it is fixed, or something waiting on you), and a rule decides where it shows. This page grows
with the notice routes; how the model works is in [Core: Notices](../develop/core.md#notices-drgnx-noticeel).

## On the desktop

Everything that waits on you — an agent asking for permission, an edit to review, a question, a job's card — is
a desktop notification when it is new, once, while no drgnx window has focus. While you are in drgnx you see it
there instead. A thing that stops waiting and starts again notifies again.

- **Linux and the BSDs:** the desktop's notification server, over D-Bus (GNOME, KDE, sway with mako or dunst, …).
  The notification is sent without waiting for an answer, so a notification server that hangs never holds drgnx.
  With no session bus (`DBUS_SESSION_BUS_ADDRESS` unset) there is no backend.
- **macOS:** Notification Center, through `osascript` (Homebrew's Emacs has no D-Bus). The text is passed to a
  fixed script as arguments, so nothing in it can run as a script. If it fails, the echo area says so.
- **Elsewhere,** or with no backend, the echo area tells you instead.

Something its producer marks as not interrupting (a job's `overlap` card, for example) is counted but never sent.
Nothing here ever asks you anything.

**Turning it off:** set `drgnx-notice-desktop` to nil (Customize, group `drgnx`), or turn off
`drgnx-notice-desktop-mode`. Job cards still follow `drgnx-job-ui-notify` until they join the notice model.
