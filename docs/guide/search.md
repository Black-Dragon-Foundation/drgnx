# Semantic Search

Semantic Search finds code by what it does, not by the words it uses: ask "where do we retry a failed request" and
the chunks that do that come back, even if none of them contains the word "retry". It is the project's code cut into
chunks, each chunk turned into a vector by an embedding model, and your question compared with them. The exact words
of your question are searched too (SQLite's full-text index) and the two rankings are merged, so an identifier
you remember and a paraphrase both find their place.

Everything runs inside Emacs, in Emacs Lisp, with the SQLite that Emacs itself carries (`sqlite-available-p`). There is
no server, no extra program and no Python.

## Setting up

Choose **Set Up Semantic Search** (the palette, or Help → Welcome) — it finds an embedding model, makes a test call
and builds the first index. The default is a local [Text Embeddings Inference](ai.md) server (TEI), so nothing
leaves your machine. Without the wizard you need an `embed` role that answers ([ai.md](ai.md)) and **Search: Index
Project**.

## Using it

| Command | What it does | VS Code | Emacs | Vim |
|---|---|---|---|---|
| Search: Semantic Search | asks for a question and shows the best chunks in the panel's Results tab | `C-k C-f` | `C-c s s` | `SPC s i` |
| Search: Index Project | builds or refreshes this project's index in a background job; with `C-u`, from scratch | palette | palette | palette |
| Search: Index Status | chunks, files, model, when it was last indexed, whether a job runs | palette | palette | palette |

In the command palette, type `#` and your question — `#where do we parse the config` — to search without choosing a
command first; a bare `#` asks for the question.

The results are the same kind of list as **Search in Project**: one line per chunk (its first line), `RET` or a click
jumps to the file, and the preview follows the selection. The best hit is first. When an answer is partial the echo
area says why, in one line, and the list header repeats it:

- **no index** — the project has not been indexed: run Index Project;
- **keyword results only** — no embedding provider answered (the model is not running, or you are offline), so only
  the words of the question were searched; start the model and search again;
- **built with another model** — the index was made with a different model or dimension than the `embed` role
  answers with now; `C-u` Index Project rebuilds with the new model (a chunk made by one model cannot be compared
  with a question embedded by another);
- **this Emacs has no SQLite** — semantic search is unavailable there.

A search never edits anything and never waits for a running indexer.

## How the index is made

- It is per project (a git repository), stored under drgnx's state directory (`~/.local/state/drgnx/search/` on
  Linux), not in the project.
- **Indexing is incremental.** A file is read again only when its content changed (staged or not, and untracked files
  count); files that are gone are forgotten. A big project's first index takes a while; later runs take seconds.
- It runs in a **background job** — a separate Emacs under systemd, capped at 1 GiB of memory, at low priority — so
  the editor stays responsive. One job per project at a time. Its log: Show Job Log (Agents tab).
- **After a save**: when you save a file of a project that has an index, drgnx re-indexes that project 30 seconds after the
  last save (a burst of saves is one run). Nothing happens for a project without an index, and it never asks
  anything.

### What is never indexed

Whatever the configuration says:

- dot files and everything under a dot directory (`.env`, `.git`, `.github`, …);
- files whose names look like keys or secrets (`*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.kdbx`, `*.keystore`, `*.jks`,
  `*.asc`, `*.gpg`, `*.env`, `id_rsa*`, `id_ed25519*`, and any name containing `secret`, `credential`, `authinfo` or
  `netrc`);
- binary files, files over 1 MiB, symbolic links, submodules;
- files that `.gitignore` excludes (the index lists the project's tracked files and the untracked ones that git does
  not ignore).

### `.drgnx/search.eld`

A project can narrow what is indexed with `.drgnx/search.eld` at its root (a plist; it can only narrow the list above):

```elisp
(:include ("src/" "*.md")        ; only these (globs on the path from the project root)
 :exclude ("vendor/" "*.min.js") ; but not these
 :off nil)                       ; t: no search for this project at all
```

`*` and `?` stay within one path component, `**/` stands for any number of directories, a glob without `/` matches at any
depth, and a trailing `/` means everything below that directory.

## Privacy

To make the vectors, the text of the chunks is sent to the provider of the `embed` role — and the text of your
question each time you search. With the default local TEI server (or Ollama, llama.cpp, LM Studio) that stays on your
machine. If you point the role at a hosted provider such as OpenRouter, the chunks of the indexed files go to it:
keep the secrets out with `:exclude`, or turn search off for that project with `:off t`. A project's
`.drgnx/` files can only choose roles among the providers you configured, never add a provider of their own ([ai.md](ai.md)).
The vectors and the chunks' text stay in the local index.
