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
