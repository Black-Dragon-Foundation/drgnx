# Settings (contributors)

How drgnx's settings work inside: the files, the layers and how they are applied, and the two readers that read them.
The user's side is [docs/guide/settings.md](../guide/settings.md) (once it exists).

## The data subset

Settings files are data, never code: drgnx never `load`s them. Two readers read them and must agree: the editor's
(Emacs's `read`, behind the config layer's checks in `core/drgnx-file.el`) and the runtime's (`runtime/crates/huginn`).
Both read the cases in `test/fixtures/huginn/cases.json`.

(The table of what the subset holds and what both refuse: Task 1.)
