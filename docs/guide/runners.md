# Runners: your other machines run jobs

A **runner** is another machine of yours that runs drgnx's jobs (builds, tests) when it would finish them sooner than
this one. drgnx reaches it the way you already do, through your own `ssh`.

## How drgnx reaches your machines

- **Your ssh, your config.** A runner is a host as your ssh knows it: whatever `ssh <host>` reaches (a `Host` entry,
  Tailscale, a `ProxyJump` through a bastion) is what drgnx uses. Its user, port, keys and proxy stay yours.
- **A few options are always drgnx's.** For each runner drgnx writes its own small ssh config in your runtime folder
  (`$XDG_RUNTIME_DIR/drgnx-runners/<runner>/ssh_config`, readable by you only) and reads yours after it. ssh keeps the
  first value it reads, so these win over anything in `~/.ssh/config`:
  - no agent forwarding, no X11, no port forwarding (your `LocalForward` and the like never open), no local command:
    nothing on the runner can reach back into this machine through the connection;
  - never a prompt (`BatchMode yes`): drgnx runs in the background, so a password or passphrase question would hang;
  - strict host keys, never learned or updated on their own;
  - its own command with no terminal, even if your config sets `RemoteCommand` or `RequestTTY`;
  - a keep-alive every 15 s, compression, and a connection kept 10 minutes after its last use.
- **One connection per runner, three sessions on it.** Restarting drgnx picks up the same connection, so a host that
  asks for a fresh login now and then (Tailscale SSH) doesn't ask again for a restart.
- **A dropped connection is never a job's result.** drgnx checks a runner with a real round trip through it, not by
  asking the local ssh process, which still answers after the network is gone. A lost connection is dialed again after
  5 s, 15 s, 45 s, then every 2 minutes; the job's result comes only from the runner itself.

### When a runner needs you

drgnx never answers a login for you and never opens a link. When ssh says the host wants you first, the runner waits
for you, and drgnx says what to run in a terminal, for example: "Log in to desktop: run `ssh desktop true` in a
terminal". That covers:

- Tailscale SSH's "requires an additional check" (the card shows the login link it printed);
- a key that needs its passphrase (load it into your agent, or run the command once);
- a host whose key you haven't accepted yet: check it and accept it in that terminal.

**A changed host key is never accepted.** The runner stops until you have found out why the key changed and fixed your
`known_hosts` yourself.
