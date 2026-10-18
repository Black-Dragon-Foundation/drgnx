# The agent sandbox

## MCP through a socket

A sandboxed agent has no `work.db`, no hub socket and no keys, so drgnx's MCP servers (coordination, search) run
outside the sandbox, one per connection, started by the hub. Inside, the agent's `drgnx` MCP entry starts a
**bridge** (`core/drgnx-mcp-bridge.el`) that copies the agent's stdio to the session's own socket:

```
emacs --batch -Q --eval "(setq load-prefer-newer t)" -L CORE -l drgnx-mcp-bridge -f drgnx-mcp-bridge-main /run/drgnx/mcp.sock
```

`drgnx-mcp-bridge-command SOCKET` builds that argv (through `drgnx-command-ignoring-sigpipe`, like the other MCP
servers). The socket a connection comes in on tells the hub which session it is: nothing inside the sandbox names the
agent, so nothing there can claim to be another.

What the bridge does, and nothing more:

- It connects to the one socket named by its argument (`make-network-process :family 'local`). Its code opens no
  file, starts no process and reads no environment variable; with `-Q` Emacs loads no init file.
- One JSON-RPC message per line, both ways. Each line must be a single JSON object of at most
  `drgnx-mcp-bridge-max-line` bytes (16 MiB); anything else ends the bridge with status 1 and a line on stderr
  (`drgnx-mcp-bridge: from the agent: message too large`, `… malformed message`), and the message is not forwarded.
  JSON-RPC batches (a top-level array) count as malformed: MCP 2025-06-18 removed batching. The same holds for lines
  from the server, whose pieces are kept as a list and joined once at the newline, so a long line costs linear time
  however it is chunked. The bridge forwards each line as it came, never re-serialized.
- It exits 0 when stdin ends or the server closes the connection, and 1 with
  `drgnx-mcp-bridge: cannot connect to SOCKET: …` when the socket is not there.

**The bridge is not a security boundary.** Any process inside the sandbox can connect to `/run/drgnx/mcp.sock`
directly, with its own code. The bridge's size limit, frame checks and stepping protect nothing; they keep an honest
agent's traffic well formed. The hub side owns the size limits, the malformed-frame handling and the recovery from a
wedged server, and treats every byte on the socket as hostile. The hub must close the connection when its
per-connection server exits and when the session ends: while a request is pending the bridge does not read stdin, so
if the agent dies then, the bridge outlives it. On Linux bwrap's pid namespace and `--die-with-parent` reap it; on
macOS (Seatbelt, no pid namespace) only the hub's close ends it.

**Why it runs in step.** A batch Emacs cannot wait on stdin and a socket at once: `read-from-minibuffer` blocks in
`getchar`, and no process output is read meanwhile. A bridge that only copied lines would deadlock on the first
request: the answer would sit unread while the bridge waits for the agent's next line. So after forwarding a request
(a message with an `id` and a `method`) the bridge reads the socket until that id's answer has come back, writing
whatever the server sends meanwhile, and only then reads stdin again. Notifications are forwarded without waiting.
A server request (an `id` and a `method`) during a call is written at once and does not end the wait. drgnx's servers
(`drgnx-mcp-serve`) answer each request in turn, send nothing unasked and make no requests of the client, so with them
this behaves exactly like today's direct stdio server. The bridge has no timeout: a slow search is legitimate, and a
wedged server is the hub's to end. The limits, for any server that did more:

- **A server-to-client request during a call deadlocks.** If the server sends `elicitation/create`,
  `sampling/createMessage`, `roots/list` or `ping` while a `tools/call` is pending and then waits for the client's
  reply, the bridge writes the request to stdout but does not read the reply from stdin until the call's answer
  comes, which never does. Both sides wait for ever (until the hub closes the connection).
- A message the server sends while no request is pending reaches the agent only when the agent next writes.
- A `notifications/cancelled` from the agent is forwarded only after the answer it meant to cancel.
- A server close while the bridge waits for input is noticed at the agent's next line (or at the end of stdin).

A full-duplex bridge, probed on Linux and not built: the launcher hands the agent's stdin to Emacs as fd 3
(`exec emacs … 3<&0 </dev/null`) and the bridge reads it through a child `sh -c "exec cat <&3"`, which inherits the
fd (reopening `/dev/stdin` fails: under libuv it is a socketpair). The bridge then copies bytes with no parsing and
none of these limits, at the cost of `sh` and `cat` in the sandbox and one more process; it relies on Emacs leaving
inherited fds open in its children, unverified on macOS. It is the upgrade path once a drgnx server first sends
anything unasked or makes a server request.

**Cost** (Emacs 30.2, Linux, one bridge, measured with a local fake server): start to connected 60 ms (median of 10),
and a round trip through the bridge 0.10 ms against 0.07 ms straight to the socket.

Tests: `test/unit/mcp-bridge-test.el` (`drgnx-mcp-bridge/`) runs the bridge as a child Emacs against a fake server on
a socket in the test's temporary directory.
