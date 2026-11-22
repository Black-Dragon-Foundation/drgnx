# xtask: repository tasks

Scripts that build or package the workspace, run from the repository root.

- `runner-bundle.sh [--arch x86_64|aarch64]`: the runner bundle (sleipnir, drgnx-key, drgnx-px) as static musl
  binaries in `target/bundle/<arch>/`.
