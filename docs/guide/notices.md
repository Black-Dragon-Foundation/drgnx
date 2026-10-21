# Notices

drgnx tells you things in one way: each notice has a severity (`info`, `warn`, `fail`) and a lifetime (an event,
a condition until it is fixed, or something waiting on you), and a rule decides where it shows. This page grows
with the notice routes; how the model works is in [Core: Notices](../develop/core.md#notices-drgnx-noticeel).

## What interrupts you

Only two things reach the echo area on their own:

- **A failure,** once, when it is new: `drgnx: TEXT`, followed by the command that helps, when there is one
  (`drgnx: boom — Fix X (F9)`).
- **A new thing that waits on you** (an agent asking, an edit to review, a job's card): `drgnx: waiting on you: TEXT`.
  When the desktop already told you (see below), the echo area stays quiet.

Everything else — information, warnings, a condition that is not a failure — shows in the status bar's counts and in
the Notices list, and the echo area only when its producer asks for it. A producer that says it must never interrupt
you is never echoed.

The echo is polite:

- **At most one line every 2 seconds** (`drgnx-notice-echo-interval`). What comes meanwhile is merged: `drgnx: 2 new
  problems — Show Notices (KEY)`, `drgnx: 2 new things wait on you — Show Notices (KEY)`, or both.
- **Never over your command's message,** while a command runs or while the minibuffer is in use: the line waits for
  the end of the next command after which the echo area is empty.
- **Not while drgnx starts.** When startup is over, one line sums up what failed: `drgnx: 1 module did not start
  (tools/agents-ui) — Show Notices (KEY)` (up to three names, then "and N more"), or `drgnx: N problems at startup`.
  Nothing is said when nothing failed.
- **Not in batch,** and a daemon with no window yet holds its lines until the first one opens.

Every line also lands in `*Messages*`. Turn the echo off with `drgnx-notice-echo-mode`.

## The two counts

The mode line shows up to two counts. `◐ N waiting on you` is the number of different things that wait for you (an
agent's question, an edit to review, a job's card); a thing two places hold counts once. `✕ F ⚠ W` is the number of
problems now: `✕` for what does not work, `⚠` for what drgnx works around (information is not counted). Click the
first to act on the newest thing when everything waiting comes from one place, or to open the list; click the
second to open the list.

## The Notices list

**View → Show Notices** (or the palette) opens `*drgnx Notices*` in the bottom panel, in three sections:

- **Needs you (N):** what waits on you. Each row has the button that takes you there. It goes when its source stops
  holding it, so it has no Dismiss.
- **Problems (✕ F ⚠ W):** what is wrong now, newest first, with what to do about it. **Dismiss** hides a problem
  until it comes back with other text.
- **Recent:** what happened lately, newest first (a repeat shows as `×N`). **Dismiss** hides an event.

An empty section says "Nothing here." The list follows changes by itself; `g` draws it again. The command
`notices` has no key: it is in the palette and behind the counts.

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
`drgnx-notice-desktop-mode`. `drgnx-job-ui-notify` is the obsolete name of `drgnx-notice-desktop`; job cards are the Jobs source of the model.
