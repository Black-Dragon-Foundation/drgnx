# Data hygiene

**The rule.** A token, key, password or credential is held in a `hulda::Secret<T>`. Its `Debug` and `Display` print
`‹redacted›`; the value is reached only through `.expose()`. A type that is partly secret implements `hulda::Redact`.

**Doing it right.**

```rust
#[derive(Debug)]
struct Login { user: String, token: hulda::Secret<String> }   // Debug shows the user, not the token

send(login.token.expose());                                   // the one place it leaves
tracing::info!(token = annall::redact(&login.token), "signed in");
```

- An error that carries a secret keeps it in a `Secret` field: `annall::log_error` logs the whole source chain with
  `Debug`, and the secret shows as `‹redacted›`.
- Call `.expose()` only where the value is sent or checked, never to format it.

**Enforced by:** the scan rule `secret-has-redact`: a type whose name ends in `Token`, `Secret`, `Key`, `Password` or
`Credential` and that derives `Debug` is a finding unless every field is a `Secret`. Owner: `hulda`. Conformance:
`crates/std/hulda/tests/conformance.rs` (a secret in an error's source never reaches the log).

**Why.** Secrets leak through the paths nobody looks at: an error's source, a debug print, a panic message. Making the
type print nothing closes all of them at once.
