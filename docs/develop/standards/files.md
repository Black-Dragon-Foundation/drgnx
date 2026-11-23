# Files

**The rule.** A file is written through `eitri`: `eitri::replace_file(path, bytes)` for an absolute path,
`eitri::write_regular(dir, rel, bytes, mode)` beneath a directory held open. Reads of a file a user or an agent can
change go through `eitri::read_regular` (bounded, regular files only). `std::fs::write`, `read_to_string`,
`File::create`, `rename` and `OpenOptions::open` are not used outside `eitri`.

**Doing it right.**

```rust
eitri::replace_file(&stig::state().join("session.json"), &bytes)?;
```

- `replace_file` writes a temporary file beside the target, `fsync`s it and renames it over the target through the
  parent's descriptor. A reader sees the old bytes or the new ones, never a part; a link at the target is replaced,
  never followed, and a link in a parent is refused; an existing file keeps its mode; on any error the old file is
  left whole and no temporary file remains.

- A file read goes through `eitri::read_file(abs, cap)` / `eitri::read_string(abs, cap)` (an absolute path, at most
  `cap` bytes, regular files only, a link in any component refused: `/proc/self` is a link, so a process reads
  `/proc/<its pid>/…`). A test that needs a file other code will write to makes it with `tempfile`.

**Enforced by:** clippy's `disallowed-methods` on the `std::fs` calls above. Owner: `eitri` (in `crates/hub/eitri`
until it moves into `crates/std`). Conformance: `crates/hub/eitri/tests/conformance.rs` (a planted link; a full disk
from `RLIMIT_FSIZE`).

**Why.** An in-place write that fails halfway leaves a truncated file, and a write through a planted link lets a
process overwrite a file it was never given. Both have happened to tools like this one.
