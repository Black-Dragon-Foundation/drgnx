# Gleipnir: the sandbox

Gleipnir is the Rust sandbox in `runtime/crates/gleipnir` ([runtime.md](runtime.md#crate-names)). It runs a program
inside a boundary the kernel enforces: bubblewrap with Landlock and seccomp on Linux (the full tier), Landlock and
seccomp alone (the reduced tier), or Seatbelt on macOS. It is self-contained: the caller passes every path, name and
port, and nothing in gleipnir names a drgnx directory or reads a drgnx variable. Nothing in drgnx uses it yet; job
agents run as before until phase 6. The Lisp libraries on main are described in [sandbox.md](sandbox.md).

Each section below is written by the task named in it.

## Using it (Task 13)

## The spec (Task 2)

## What is refused (Task 2)

## Platforms (Task 2)

## Toolchain roots (Task 3)

## The bubblewrap argv (Task 7)

## The inner helper (Task 8)

## Landlock (Task 5)

## seccomp (Task 4)

## macOS: Seatbelt (Task 9)

## The relay (Task 11)

## The proxy (Task 10)

An isolated sandbox has no network, only its own loopback. Its programs reach the outside through `HTTPS_PROXY`,
which the relay forwards to a CONNECT proxy outside the sandbox (`net::proxy`). One proxy serves one job: the caller
starts it with `proxy::start(config, resolver, events)` and hands it each session's listener with
`listen(listener, tag)` (a Unix socket on Linux, a `127.0.0.1:0` TCP listener on macOS). Every listener shares the
one allowlist, changed at run time with `allow(target)` and `deny(&target)`. `close(tag)` drops a session's listener
and every connection it accepted; `shutdown()` (or dropping the handle) ends them all.

**The answers.** The proxy reads the request head (the line and headers up to the blank line) and looks only at the
request line, never at `Host:`:

| Request | Answer | Event |
|---|---|---|
| `CONNECT host:port HTTP/1.1` (or `1.0`) to a listed target | `200 Connection established`, then the bytes are spliced both ways | — |
| a well-formed public target that is not listed | 403 | `Denied` |
| a target with `*` | 403 | `Refused { Wildcard }` |
| an address literal that is not public, listed or not | 403 | `Refused { Private }` |
| a name whose DNS answer has no public address (and no pin) | 403 | `Refused { Private }` |
| a target with a byte outside printable ASCII (a NUL, a U-label) | 400 | `Refused { NotAscii }` |
| another method, a malformed line or target, a head over `max_head` (8192) or slower than `head_timeout` (10 s) | 400 | `Refused { BadRequest }` |
| a first byte of `0x04` or `0x05` (a SOCKS greeting) | closed, no answer | — |
| a connection over `max_conns` (64, across all listeners) | 403 | — |
| listed, but it does not resolve or no address connects | 502 | — |

Each event is sent once per target per tag, before the client is answered; the tag tells the caller which session
asked. Only `Denied` may become a question to the user: a private address, a wildcard or a malformed request is never
offered. A refused request's `target` is shown with every byte outside printable ASCII escaped.

**The matching.** A target is parsed strictly (`net::host::parse_target`), with no `idna` stack:
- a name is ASCII letters, digits and inner hyphens, labels of 1–63 characters, at most 253 in all, lower-cased, one
  trailing dot dropped, and its last label starts with a letter. A-labels (`xn--…`) are names like any other; a
  U-label, `_` and `*` are refused;
- an IPv4 address is exactly four decimal octets with no leading zeros (no `127.1`, `2130706433`, `0x7f.0.0.1` or
  `010.0.0.1`); an IPv6 address is written in brackets, with no zone;
- the port is decimal, 1–65535, with no leading zero.

Allowlist entries are exact `host:port` targets: `example.com:443` allows neither `www.example.com:443` nor
`example.com:80`. There are no wildcard entries (the parked Lisp proxy had `*.name` entries; the design allows exact
`host:port` only).

**The addresses.** `net::host::is_public` decides what is public. Not public: IPv4 0/8, 10/8, 100.64/10, 127/8,
169.254/16 (with the cloud metadata address), 172.16/12, 192.0.0/24, 192.0.2/24, 192.168/16, 198.18/15,
198.51.100/24, 203.0.113/24, 224/4 and 240/4; IPv6 `::`, `::1`, `fc00::/7`, `fe80::/10`, `fec0::/10`, `ff00::/8`,
`2001:db8::/32`, `2001::/32` (Teredo), `64:ff9b:1::/48` and `100::/64`. An IPv6 address that carries an IPv4 one is
judged by that IPv4 address: `::ffff:0:0/96`, `::/96`, `64:ff9b::/96` and `2002::/16`. Where the proxy connects is
decided once per request:
- an address literal is the address itself, and only a public one gets this far;
- a pinned name (`ProxyConfig::pinned`, name to address) uses its pin and asks no resolver. It must still be listed,
  and this is the only way to reach an address that is not public (a registry on the company network);
- any other name is resolved once. The answer is filtered to its public addresses, each taken on the target's port; an
  answer with none left is refused as `Private`.

The proxy then connects to those very addresses, the first that answers, and never resolves again, so a DNS answer
that changes after the check (rebinding) cannot lead it anywhere else.

**Limits.**
- Once a target is allowed, the bytes are not inspected: TLS stays end to end, and the proxy cannot tell what is
  sent to an allowed host. A broad entry (a code host) can carry data out; entries should be as narrow as the work.
- `deny` stops new connections only; a tunnel already spliced stays until either side closes.
- There is no idle timeout on a spliced connection, and connecting upstream waits as long as the system's TCP
  connect does. Both hold one of the `max_conns` places meanwhile.
- The proxy speaks HTTP CONNECT only: no plain HTTP forwarding and no SOCKS.

## The check (Task 12)

## Proving it (Tasks 14 and 15)

## What this does not claim yet (Task 19)
