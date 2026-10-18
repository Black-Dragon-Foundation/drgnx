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
  The same holds for lines from the server, whose pieces are kept as a list and joined once at the newline, so a long
  line costs linear time however it is chunked.
- It exits 0 when stdin ends or the server closes the connection, and 1 with
  `drgnx-mcp-bridge: cannot connect to SOCKET: …` when the socket is not there.

**Why it runs in step.** A batch Emacs cannot wait on stdin and a socket at once: `read-from-minibuffer` blocks in
`getchar`, and no process output is read meanwhile. A bridge that only copied lines would deadlock on the first
request: the answer would sit unread while the bridge waits for the agent's next line. So after forwarding a request
(a message with an `id` and a `method`) the bridge reads the socket until that id's answer has come back, writing
whatever the server sends meanwhile, and only then reads stdin again. Notifications are forwarded without waiting.
drgnx's servers answer each request in turn and send nothing unasked, so this costs nothing with them. Two limits
follow:

- A message the server sends while no request is pending reaches the agent only when the agent next writes.
- A server close while the bridge waits for input is noticed at the agent's next line (or at the end of stdin).

**Cost** (Emacs 30.2, Linux, one bridge, measured with a local fake server): start to connected 60 ms (median of 10),
and a round trip through the bridge 0.10 ms against 0.07 ms straight to the socket.

Tests: `test/unit/mcp-bridge-test.el` (`drgnx-mcp-bridge/`) runs the bridge as a child Emacs against a fake server on
a socket in the test's temporary directory.
