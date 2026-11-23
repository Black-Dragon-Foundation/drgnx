# The vector protocol, v1

One machine's vectors served to another: `ratatoskr embed serve` on the machine that has them (a desktop with a GPU,
a team's server, CI), a `vectors` provider on the machine that wants them. Code: `crates/hub/ratatoskr/src/embed_serve.rs`
(the server, the wire types) and `src/search/remote.rs` (the client source, `RemoteVectors`).

## Serving

```
ratatoskr embed serve --listen ADDR:PORT [--plain] [--no-embed]
ratatoskr embed serve --stop
ratatoskr embed serve --new-token
```

The server runs inside the hub (`embed/serve-start`, `embed/serve-stop`, `embed/serve-token`; [hub.md](hub.md)), so it
answers from the same vector cache tier 2 fills and embeds with the same engine or built-in model. The first start
prints the URL, the certificate's sha256 and the **token, once**; later starts print the URL and the certificate only.
`--new-token` prints a new token once, and the old one is refused from the next request.

- **TLS by default.** A self-signed certificate (`rcgen`, for `localhost` and the address served) is made at the first
  TLS start and kept in `<state>/embed-serve/cert.der` and `key.der` (0600). The client pins its sha256 on first use.
- **Plain HTTP** (`--plain`) only on loopback or a Tailscale address (100.64.0.0/10, fd7a:115c:a1e0::/48), where the
  tunnel is the encryption; anything else is refused before the port is bound or a token made.
- **The token.** Only its sha256 is kept (`<state>/embed-serve/token.sha256`, 0600, replaced whole). Every request
  carries `Authorization: Bearer TOKEN`; the server hashes it and compares in constant time.
- **`--no-embed`**: lookups only; `/v1/embed` answers 403.
- **Logs.** Each request is logged at info as `embed serve` with the peer, method, path and status. Neither a token nor
  a text is ever logged.

## The wire

JSON over HTTP/1.1. Keys are 64 lower-case hex characters: `KeyKind::key(text)`, the sha256 of the key version and the
text (`hrafn::chunk_key` for a chunk's embed text, `hrafn::path_key` for a path, whose text is `hrafn::path_text`).
Vectors travel in the cache's stored form, so a lookup moves a row unchanged: `{bits, vec, scale}`, `vec` the stored
bytes in base64 (the sign bytes, `ceil(dims / 8)` of them, then one int8 per dimension), `scale` the int8 step.

### `GET /v1/info`

```json
{"version": 1, "fingerprints": [{"hex": "…64 hex…", "record": {…}}], "embed": true, "max_batch": 64, "max_tokens": 8192}
```

`fingerprints`: every model whose cache file this machine has, and the models its embedders state now; `record` is the
fingerprint's record (`FingerprintRecord::to_json`), whose sha256 is `hex`. `embed`: whether `/v1/embed` answers for any
of them (false with `--no-embed`).

### `POST /v1/lookup`

```json
{"fingerprint": "…", "kind": "chunk", "keys": ["…", "…"]}
→ {"found": {"KEY": {"bits": 8, "vec": "…", "scale": 0.0123}}}
```

Answered from the cache alone; a key the cache lacks is not in `found`. A lookup never carries a text.

### `POST /v1/embed`

```json
{"fingerprint": "…", "kind": "path", "items": [{"key": "…", "text": "…"}]}
→ {"vectors": {"KEY": {"bits": 8, "vec": "…", "scale": 0.0123}}}
```

Every item's key must be the key of its text (`kind.key(text)`); if one is not, the answer is
`422 {"error": "key-mismatch", "key": "THAT KEY"}` and **nothing** of the request is embedded or written, so a client
cannot put a vector into the cache under another text's key. Otherwise the texts are embedded by this machine's
embedder of that fingerprint, added to the cache, and answered as stored. An embed is spend on both sides (a lookup is
free): the server records a `spend` row as `embed-serve`, the client one under its provider id.

### Errors and limits

| Status | `error`               | When                                                           |
|--------|-----------------------|----------------------------------------------------------------|
| 400    | `bad-request`         | a body that is not the request (`detail` says why)             |
| 400    | `bad-key`             | a key that is not 64 hex characters                            |
| 401    | `unauthorized`        | no token, or not the token                                     |
| 403    | `no-embed`            | `/v1/embed` on a server started with `--no-embed`              |
| 404    | `unknown-fingerprint` | a fingerprint this server does not serve (or cannot embed for) |
| 404    | `not-found`           | any other path                                                 |
| 413    | `too-many`            | more than `max_batch` (64) keys or items                       |
| 413    | `too-large`           | a body over 8 MiB                                              |
| 422    | `key-mismatch`        | an item whose key is not its text's (`key` names it)           |
| 502    | `failed`              | the embedder or the cache failed (`detail`)                    |

`max_tokens` (8,192) is the longest text the server's embedders take; a longer one is cut by the embedder, as for a
local text.

## The client: a `vectors` provider

```elisp
(setq drgnx-ai-providers
      '((desk :kind vectors :url "https://100.94.36.51:7878" :key-env "DESK_VECTORS_TOKEN")
        (team :kind vectors :url "https://vectors.example.org:7878" :key-env "TEAM_TOKEN" :trusted t)))
```

- The token comes from the entry's `key_env` through the gateway's key hand-over; it is never logged and never in an
  error.
- **Lookup-only unless trusted.** Without `:trusted t` the source is `SourceKind::Lookup`: the chain asks it for the keys
  the cache lacks and never sends it a text. With `:trusted t` it is `Embed`: it is asked for the keys first, and only
  the ones it lacks go to it as texts. (`:trusted t` on a `tei` or `ollama` provider off this machine lets it be sent
  text too.)
- **Its identity** is the first fingerprint its `/v1/info` serves, and its `max_batch` is the source's.
- **The certificate is pinned on first use** in `runtime.db`'s `kv` (`vectors.pin.<provider>`). A later handshake
  with another certificate fails with "the server's certificate changed; check it and run Search: forget server pin"
  and nothing is asked of the server; `search/forget-pin {provider}` forgets the pin, and the next answer pins anew.
- A remote is never held by this machine's battery or load, and one that is down is backed off like any source (1, 5, 30
  minutes, then 6 hours); its keys go on to the next source meanwhile.
