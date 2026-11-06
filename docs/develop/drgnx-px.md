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

## Fuzzing

`px_frames` feeds arbitrary bytes in chunks through the decoder; every frame it returns must re-encode to exactly the
bytes it consumed ([runtime.md](runtime.md#fuzzing)).
