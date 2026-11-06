# Extensions

## When a restart is needed

Most changes the Extensions view makes work at once, in the drgnx you are using:

- **A new package works at once.** Its commands, modes and keys are there as soon as the install ends, and a module
  that was waiting for it starts.
- **An update of a package you have not used yet** in this session loads the new version when you first use it.
- **An update of a package already loaded** keeps the version that is running, with everything it needs, until you
  restart drgnx; its row says "Restart to use 4.2 (4.1 is running)". Files of it that load later still come from
  the running version (drgnx keeps a copy of them for this session), never half from the new one.
- **Removing a package already loaded** leaves it running until you restart; its row says "Restart to finish
  removing".
- **A failed or stopped change** leaves the session as it was.

A row says "restart drgnx" at once when its files are gone with no copy kept, for instance a package you installed
with `M-x package-install` since the last change and then removed or replaced.

drgnx keeps the copies a running session uses (`~/.local/state/drgnx/elpa-in-use/`) until that session ends; a sync
from the command line or from onboarding keeps its usual advice to restart drgnx. Developers: [live
activation](../develop/extensions.md#live-activation).

## In one project

A package's page can turn the package off **in the project you are in** (its row says "Off in this project"). Its
file modes and buffer modes are then off there: a file it would open in its mode opens in the mode it would get
without the package (`.rs` in `rust-ts-mode` when `rust-mode` is off, for instance), and its buffer minor modes do not
turn on in that project's files. Other projects, and buffers that are not files (`*scratch*`, Magit's), are not
changed. Turning it off or on again applies at once: the project's open files take their modes again.

- Only a package that adds file modes or buffer modes and nothing else can be off in one project. One that changes
  Emacs as a whole (hooks, advice, global modes or keys, a theme: Magit, for instance) says "On in every project: it
  changes Emacs as a whole" and has no switch.
- The choice is yours: it is saved in your private workspace file for that project (`~/.config/drgnx/workspaces/`),
  never in the project's shared `.drgnx/settings.el`. A project's shared settings may list packages in
  `drgnx-packages-off` too ("Off in this project by the project's shared settings").
- No agent can change it.
- `drgnx doctor` says when an open file still has the mode of a package that is off in its project (after a hand
  edit of the setting): `M-x normal-mode` there sets it right.

Developers: [in one project](../develop/extensions.md#in-one-project).
