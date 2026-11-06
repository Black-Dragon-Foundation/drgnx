# drgnx-px: the relay sidecar

`drgnx-px` (`runtime/crates/drgnx-px`) relays a networked container job's TCP connections to its owner's proxy. The
job reaches nothing but the sidecar; the sidecar holds no policy, no resolver and no TLS. It carries each connection
as a stream of frames over its own stdin and stdout, which `podman run -i` joins to the owner (the hub locally, the
job helper on a runner), and the owner hands each stream to the job's proxy.

## Frames

Every frame is a 9-byte header and a payload:

```
u32 stream id (big-endian; the high bit is 0) | u8 kind | u32 payload length (big-endian) | payload
```

| Kind | Way | Stream | Payload |
|---|---|---|---|
| `READY` 0 | sidecar → owner | 0 | JSON `{"version":1,"listen":"<ip:port>"}`, the address the sidecar bound |
| `OPEN` 1 | sidecar → owner | odd | none: a new job connection |
| `DATA` 2 | both | odd | 1–16384 bytes |
| `CREDIT` 3 | both | odd | a u32 (big-endian), never 0: more bytes the receiver may now send on the stream |
| `FIN` 4 | both | odd | none: this side's half-close |
| `RST` 5 | both | odd | none: the stream ends now |
| `BEAT` 6 | owner → sidecar | 0 | none |
| `EVENT` 7 | sidecar → owner | 0 | JSON `{"foreign_source":"<ip>"}` |

Limits (`drgnx_px::frame`): `MAX_DATA` 16384, `MAX_CONTROL` 4096 bytes of JSON, `WINDOW` 262144 bytes of credit per
stream and direction, `MAX_STREAMS` 64.

The decoder (`frame::Decoder`) joins frames split across reads and holds at most one frame's bytes. It judges what a
frame shows on its own, and any of these closes the channel (`frame::Violation`):

- the stream id's high bit set (`HighBit`), checked first; then an unknown kind (`UnknownKind`); then an even id other
  than 0 (`EvenId`: only the sidecar opens streams, with odd ids);
- `READY`, `BEAT` or `EVENT` off stream 0, or any other kind on it (`WrongStream`);
- a length the kind doesn't allow (`Length`), judged from the header before any payload is held;
- a payload of the wrong form (`BadPayload`): `READY` that isn't exactly version 1 and an `ip:port`, an `EVENT` whose
  `foreign_source` doesn't parse as an IP address (it is never passed on as text), a `CREDIT` of 0.

What depends on the channel's state (which streams are open, credit, which side may send a kind) belongs to the relay
core.

## The relay core (`mux`)

`mux::Mux` is the channel's state machine, pure and the same on both ends (`Side::Sidecar`, `Side::Owner`). It steps
one `In` at a time (a received frame, or a local event: an accepted connection, bytes read within the stream's credit,
a local end, bytes drained from the stream's queue, a local reset, a `FIN` or `RST` the writer wrote) and returns what
the shell does (`Out`).

- **Streams.** Ids are odd, from 1, each `OPEN` the highest so far (`H`) plus 2, opened by the sidecar only; the last is
  2³¹−1, and the open after it is `IdsUsedUp`. A stream is closed by both `FIN`s or by an `RST` either way.
- **Closed streams** (RFC 9113 §5.1): their `DATA`, `CREDIT`, `FIN` and `RST` are discarded (`Out::Discarded`), and
  discarded `DATA` still counts against the credit the peer had left (a tombstone; past it, a violation). At most 1024
  tombstones are kept, oldest out first; frames for older streams are discarded uncounted.
- **Credit.** 262144 bytes per stream and direction. A receiver sends `CREDIT` for bytes that left its queue, when the
  queue empties or 64 KiB are uncredited. A `CREDIT` that would raise the sending credit above the window is a
  violation (RFC 9113 §6.9.1), as is `DATA` past the receive credit.
- **The count.** A stream counts toward the 64 from its `OPEN` until the peer's `RST` arrives, this end's `RST` is
  written, or both `FIN`s are in and this end's is written. "Written" means the writer took the frame: it writes
  frames in the order it takes them, each in full, so this end steps on at once, and the peer can't answer the frame
  while this end still counts its stream. A `FIN` held behind its stream's `DATA` keeps it counted. So an `OPEN` a
  freed place allows is always behind the frame that freed it, and a correct sidecar never sends a 65th.
  The owner still refuses an `OPEN` at 64 counted with `RST` and a tombstone; a further `OPEN` while 64 refusals are
  unwritten is a violation (`TooMany`).
- **Control.** `READY` once and first from the sidecar; `OPEN`, `READY` and `EVENT` only from the sidecar, `BEAT`
  only from the owner. A foreign source is reported once per address, at most 10 a second (the `Mux` reads the time the
  shell sets), and at most 256 addresses are remembered; the rest are counted (`EventsCounted`, once a second).
- Local events for a stream that isn't open are no-ops; a local open at 64 counted is `LocalTooMany`, returned rather
  than asserted.

## The writer's order (`pending`)

`pending::Pending` holds what waits for the writer: per stream its `DATA` (at most its credit), one coalesced `CREDIT`
and a held `FIN`; per channel `READY`, one `BEAT`, up to 16 `EVENT`s, and `order`, a FIFO of `OPEN`, `FIN` and `RST`.
`next` gives the frame to write:

- `READY` first; `OPEN`, `FIN` and `RST` in `order`'s FIFO order, so `OPEN`s leave in id order and before anything
  else of their stream; a stream's `DATA` leaves only after its `OPEN`.
- A `FIN` joins `order` only after its stream's last `DATA` is written. An `RST` joins at once and drops the stream's
  waiting `DATA`, `CREDIT` and unwritten `FIN`, but an `OPEN` still in `order` stays ahead of it, so an instant reset
  leaves as `OPEN`, then `RST`. `CREDIT`, `BEAT` and `EVENT` may overtake anything.
- A pass writes `READY` if it waits, then the control that waited when the pass began, then one `DATA` frame for each
  stream with `DATA` waiting. What becomes ready during a pass waits for the next one.

## The shell (`shell`)

`shell::Shell` runs one end over any `AsyncRead`/`AsyncWrite` pair, the same way on both ends, so neither end can
stop the other's pipe:

1. one reader reads the input unconditionally, decodes and steps the `Mux`; it awaits only the read, and what it does
   never blocks (bytes appended to a stream's queue, a task woken, a hook that must not block);
2. one writer owns the output, writes the frames `Pending::next` gives one at a time, and as it takes each `FIN` or
   `RST` steps the `Mux` with `In::Wrote`;
3. two tasks per stream over its consumer (`shell::Consumer`: the job's `TcpStream` in the sidecar, a `DuplexStream`
   in the owner): the queue to the consumer, whose writes become `CREDIT`, and the consumer to `DATA`, never past the
   stream's credit; both are aborted when the stream is dropped;
4. the state sits behind a `std::sync::Mutex` that is never held across an `.await`;
5. logs go through `shell::Log`, 16 KiB that drops lines when full (and then says how many) and never blocks.

A write that makes no progress for 60 s (`shell::STALL`, injectable) ends the channel (`End::Stalled`); on the
sidecar 60 s without a `BEAT` on its monotonic clock does too (`End::BeatLost`). When the channel ends, every stream
still there is aborted.

## The sidecar (`sidecar`, the binary)

```
drgnx-px --listen <ip:port> --job-ip <ip>
```

It binds the listen address with backlog 128 and never `SO_REUSEPORT` (a job running as the same uid could otherwise
bind the port beside it), sends `READY` with the bound address, and accepts while fewer than 64 streams are counted:
the 65th connection waits in the backlog until a stream closes. A connection from any address but `--job-ip` is
closed, and each such address is reported once as an `EVENT` (256 at most). The report is diagnostic: the connection
is closed whether or not it goes out, so an `EVENT` past the 256 addresses or past the 16 that may wait for the writer
is dropped, not counted. Accepted sockets get 64 KiB `SO_RCVBUF`
and `SO_SNDBUF` (the kernel doubles them, and autotuning is off). An `RST` either way, or any end of the channel,
closes the stream's job socket with `SO_LINGER {on, 0}`, so the job sees `ECONNRESET`, never a clean end. It runs
on tokio's current-thread runtime; fds 0, 1 and 2 are set non-blocking and driven through `AsyncFd` (never tokio's
blocking stdin); stdout carries frames only, and logs and panics go to stderr. A panic exits 101 at once.

| Exit | Why |
|---|---|
| 0 | stdin ended |
| 1 | bad arguments, stdio that isn't a pipe, or the channel's pipe failed |
| 2 | the listen address can't be bound |
| 3 | 60 s without a `BEAT` |
| 4 | a violation |
| 5 | a channel write without progress for 60 s |
| 6 | the stream ids are used up |
| 101 | a panic |

The feature `test-hooks` adds `--test-log-frames` (a log line per frame) and `--test-panic-on-beat`; a shipped build
has neither.

## Tests

- `src/frame/tests.rs`, `src/mux/tests.rs`, `src/pending/tests.rs`, `src/shell/tests.rs`: the rules on single
  scenarios, pure ([D]).
- `src/orders.rs`: both ends' `Mux` and `Pending` joined by two pipes, with each shell reduced to its local side, its
  consumer, its writer and its reader, run in every order of those steps by `skuld` ([A]): bytes once and in order,
  every `FIN` after its stream's last `DATA`, frames crossing a reset discarded, `OPEN`s in id order, an instant reset
  as `OPEN` then `RST`, and never a 65th counted stream at the owner.
- `tests/sidecar.rs`: the built binary against a test owner on its stdio ([C]; Linux only, as it binds 127.0.0.2–4):
  the source check, the 65th connection waiting, the bind rules, the buffers, the exit codes, resets reaching the job,
  and a stderr pipe nobody reads. Two of them need `--features test-hooks`:

```
cargo test -p drgnx-px --features test-hooks
```

## Fuzzing

`px_frames` feeds arbitrary bytes in chunks through the decoder; every frame it returns must re-encode to exactly the
bytes it consumed ([runtime.md](runtime.md#fuzzing)).
