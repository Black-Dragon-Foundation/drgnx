# Paths

**The rule.** The editor's directories come from `stig`: `config()`, `state()`, `cache()`, `data()`, `runtime()`. No
other code reads `HOME`, an `XDG_` variable or `std::env::home_dir`.

**Doing it right.**

```rust
let keys = stig::config().join("keys.toml");
let log_dir = stig::state().join("log");
```

- Each comes from XDG (`XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, `XDG_DATA_HOME`, `XDG_RUNTIME_DIR`), else
  the XDG default under `HOME`, then `drgnx`, then the profile when it is not the default: `DRGNX_PROFILE=dev` gives
  `~/.config/drgnx/dev`. An unknown profile is refused, never read as the default. A relative XDG value is ignored.
- A Wayland client finds its compositor's socket in the system's runtime directory, which is not `stig::runtime()`:
  `stig::system_runtime_dir()` (a relative `XDG_RUNTIME_DIR` is ignored), and `stig::SYSTEM_RUNTIME_VAR` names the
  variable for a child that is pointed at another one.
- A test never resolves the real directories: `raun::Sandbox` calls `stig::init_for_test(temp)`, and every directory
  is under the temp root with the `test` profile.
- `Dirs::from_lookup` resolves from any environment, for code that must answer for another one.

**Enforced by:** clippy's `disallowed-methods` on `std::env::home_dir`, and the scan rule `no-env-home` (a string
literal `"HOME"` or `"XDG_…"`). Owner: `stig`. Conformance: `crates/std/stig/tests/conformance.rs`.

**Why.** A dev build or a test that resolved the user's real folders has overwritten real work before. One resolver,
with the profile in the path, makes that impossible by construction.
