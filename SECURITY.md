# Security policy

drgnx is pre-release. Only the `main` branch is supported; fixes land there.

## Reporting a vulnerability

Please report it privately through GitHub — **Security → Report a vulnerability**
(<https://github.com/Black-Dragon-Foundation/drgnx/security/advisories/new>). Please don't open a public issue
or pull request for it.

Say what you found, how to reproduce it, and what it lets someone do. The conversation happens in the private
advisory; once a fix is on `main`, the advisory is published, with credit to you unless you'd rather not be named.

## What counts

drgnx starts AI agents in a sandbox and hands them API keys, runs jobs on the user's machines, and serves its
commands to agents over MCP. Anything that lets someone run code, read secrets or write outside drgnx's own
directories without the user asking for it is in scope — for example in the hub, the sandbox (Gleipnir), the agent
and job runners, the gateway, or the MCP server. The earlier Emacs-based drgnx (tag `classic-final`) is no longer
supported.
