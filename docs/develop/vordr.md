# vordr: the orchestration gates' pure core

`vordr` holds what the hub decides without touching a machine: the pack's policy paths (`pack`), job rows and failure
classes, and the job pack (`jobs`).

## The job pack (`jobs`)

`.drgnx/jobs.toml` is a project's jobs as data (`jobs::FILE`; format version `jobs = 1`). `jobs::load(text, file)`
reads it with `toml_edit`, so every refusal carries its file and line (`LintError`); `lint` returns them all.

- **Tables**: `[toolchains.NAME]`, `[caches.NAME]`, `[[artifact]]`, `[[stage]]`, `[pipelines]`, `[gate]`, `[defaults]`.
  Defaults merge under each entry; `JobPack::resolve(name)` inlines the toolchain and caches into one `forseti::Canon`,
  the input of the artifact key.
- **Names, never guesses**: a parser or dialect not in the lists is refused by name (`PARSERS` equals the executor's; a
  hub test keeps them equal). `timebox`, `stall` and `silent` need a `why`. `host-mise` is refused. A toolchain image
  needs `@sha256:` and 64 hex digits, or `{artifact = "NAME"}`.
- **Placeholders** are validated; `{key:NAME}` is allowed only in `env`.
- **Reserved**: matrix, sync, sparse, shards, bisect, `kind = "fetch"`, `parser = "ktap"`, `os = "macos"`,
  `expect.log-has`, git-URL inputs, `{cell.*}`, `{shard}` and `{input.*}` are refused with "not built yet (after
  launch)", so a pack never silently ignores them.
- **Overlay**: `merge_overlay(repo, overlay)` adds the overlay's entries and replaces entries of the same name (listed in
  `replaced`). The hub finds the pack in `ratatoskr::runners::jobpack`: an author's run reads the frozen tree, a gate the
  base commit; then the overlay (the project setting `jobs-overlay`, a folder with its own `jobs.toml`). A job that
  comes from the overlay places only on `mine` runners, and the overlay's files are never mirrored.

Tests: `the_hello_c_pack_parses`, `each_reserved_field_says_not_built_yet`, `a_limit_without_a_reason_is_refused`,
`the_allowed_keys_are_in_the_fields_list` and the rest of `jobs::tests`.
