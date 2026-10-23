# Semantic Search

Semantic Search finds code by what it does, not by the words it uses: ask "where do we retry a failed request" and
the chunks that do that come back, even if none of them contains the word "retry". It is the project's code cut into
chunks, each chunk turned into a vector by an embedding model, and your question compared with them. The exact words
of your question are searched too (SQLite's full-text index) and the two rankings are merged, so an identifier
you remember and a paraphrase both find their place.

The search itself runs inside Emacs, in Emacs Lisp, with the SQLite that Emacs carries (`sqlite-available-p`) — no
Python and no database server. Turning text into vectors is done by an embedding model server (through `curl`).

## Setting up

Choose **Set Up Semantic Search** (the palette, or Help → Welcome → Semantic Search). It:

1. asks the local providers which run (the same one-second probe as [ai.md](ai.md)) and takes the first one of the
   `embed` role that answers; when the role has none running but another provider does (TEI, or an Ollama with an
   embedding model), that one is put first in the role. With none running it stops and says how to start one — TEI:
   `podman run -p 8080:80 -m 4g ghcr.io/huggingface/text-embeddings-inference:cpu-latest --model-id BAAI/bge-small-en-v1.5`
   (the memory cap keeps a model from taking the machine), or Ollama: `ollama pull nomic-embed-text`;
2. makes a test call (the embedding of the test question, five seconds at most) and reports the model and the number of
   dimensions it gives — the only wait (besides the probe, which takes a second or so); only once it works is the `embed`
   role changed, if it had to be;
3. indexes this project **in the background** and tells you so (Index Status shows how far it is). When the project's
   index is already current it runs a test query instead (with the vector of the test call: one embedding in all) and shows the top hit; when the index was built with another
   model it says so and leaves it to you (`C-u` Index Project rebuilds).

The default is a local [Text Embeddings Inference](ai.md) server (TEI), so nothing leaves your machine. Without the
wizard you need an `embed` role that answers ([ai.md](ai.md)) and **Search: Index Project**.

`drgnx doctor` has a `search` check: **fail** when this Emacs has no SQLite or its SQLite has no FTS5; **warn** when
an index was built with another model or number of dimensions than the provider gives now (fix: Index Project with
`C-u`), when one cannot be read, when a project's `.drgnx/search.eld` cannot be read (see below), or when more than
20 files of a project changed since it was indexed; **info** when no
embedding provider is reachable (searches then use keywords only); otherwise ok, with the number of indexes and chunks.
It looks at the current project and the projects drgnx knows (at most 20); projects without an index are only counted.
The warnings name what differs ("built with bge-small (384), the provider gives 768", or "built with A, the provider is B").
It never prompts, and it is quick: the embedding provider is asked once, for one second at most, and git is bounded per
project (a project whose files are not counted in time is left out of the stale test), about four seconds in all.

## Using it

| Command | What it does | VS Code | Emacs | Vim |
|---|---|---|---|---|
| Search: Semantic Search | asks for a question and shows the best chunks in the panel's Results tab | `C-k C-f` | `C-c s s` | `SPC s i` |
| Search: Index Project | builds or refreshes this project's index in a background job; with `C-u`, from scratch | palette | palette | palette |
| Search: Index Status | chunks, files, model, when it was last indexed, whether a job runs, the index file, a broken `.drgnx/search.eld` | palette | palette | palette |
| Search: Set Up Semantic Search | finds and tests an embedding model, indexes this project in the background | palette | palette | palette |

In the command palette, type `#` and your question — `#where do we parse the config` — to search without choosing a
command first; a bare `#` asks for the question. Semantic Search offers the symbol at point as the default: `RET` on an
empty prompt searches for it.

Index Project while a job for the project still runs starts nothing and says so; with `C-u` it says "an index job is
already running for PROJECT; rebuild after it finishes". In an Emacs without SQLite, Index Project and Index Status
only say "this Emacs has no SQLite — semantic search needs Emacs built with SQLite".

The results are the same kind of list as **Search in Project**: one line per chunk (its first top-level line — one starting at column 0 that is not just closing brackets, else its first non-blank line — and the
jump goes to that line), `RET` or a click
jumps to the file, and the preview follows the selection. The answer comes after the command returned (the question is embedded in the background), and the results list then takes the focus, as Search in Project's does. The hits are grouped by file, the files in the order of their best hit (xref's grouping). When an answer is partial the echo
area says why, in one line, and the list header repeats it:

- **no index** — the project has not been indexed: run Index Project;
- **keyword results only** — no embedding provider answered (the model is not running, or you are offline), so only
  the words of the question were searched; start the model and search again;
- **built with another model** — the index was made with a different model or dimension than the `embed` role
  answers with now; `C-u` Index Project rebuilds with the new model (a chunk made by one model cannot be compared
  with a question embedded by another);
- **search is off for this project (.drgnx/search.eld)** — the project turned search off with `:off t`; the index,
  if one was made before, is not searched;
- **this Emacs has no SQLite** — semantic search is unavailable there.

A search never edits anything and never waits for a running indexer.

## For agents

Agents get the same search the editor uses, three ways. They all call the same function as **Semantic Search**, over the
same index, so an agent and you see the same hits (and a missing index or a missing embedding provider shows the same notices).

**The command line**

```
drgnx search index ROOT [--rebuild]      # build or refresh the index (what Index Project runs); one summary line
drgnx search query ROOT QUESTION… [-k N] # the best N chunks (default 10), one line each
```

`query` prints `PATH:LINE: first line of the chunk` for each hit, best first, with PATH relative to the project and
LINE the number of the line printed (the chunk's first top-level line, as in the list) — the format `grep -n` has, so tools that read
grep output read this. When an answer is partial (keywords only because no
embedding provider answered, or the index was built with another model) the reason is printed on **stderr**. Without an
index it prints how to make one and exits 1. `ROOT` is the project or any directory inside it: both commands use its git
top level, so a sub-directory never makes an index of its own.

Both run in the foreground, in the shell you call them from: `drgnx search index` is not the background job (no
memory cap, no lower priority) — wrap it yourself if you need that, for example
`systemd-run --user --scope -p MemoryMax=1G -p MemorySwapMax=0 nice drgnx search index ROOT`.

**The MCP tool**

`drgnx search mcp [ROOT]` serves one MCP tool over stdio (ROOT defaults to the current directory):

| Argument | |
|---|---|
| `query` (required) | what you look for, in words |
| `k` | how many hits, 1 to 50 (default 10); a value that is not an integer is an invalid-params error |
| `path` | the project, or any directory inside it; default: the server's project. A path in no git project is an error |

`path` is not limited to the server's own project: the agent can search **any git project of yours that already has an
index** (read-only — the tool never indexes and never edits; a project without an index is an error result). Give an
agent the server only if it may read the indexed code of all your projects. A sandboxed job agent's server is the
exception: the hub pins it to the job's project, so a `path` outside that project is an error result, and any path
inside it searches the project itself.

The answer is the text `query` prints: one `PATH:LINE: first line` per hit, and a last line `note: …` when the answer is
partial. With no index the tool returns an error result — "no index for ROOT — run `drgnx search index ROOT` or Search:
Index Project". The server never asks anything and never edits anything. It embeds the question with the `embed` role of
the project searched, like the editor; a hosted provider's key comes from the server's own environment or a plain
auth-source file, like any drgnx batch process (a local model needs none).

To give an agent the tool, add the server to the agent's own MCP configuration, for example for Claude Code:

```
claude mcp add drgnx-search -- /path/to/drgnx/bin/drgnx search mcp /path/to/project
```

(add `-e NAME=value` for the key variable of a hosted `embed` provider). drgnx adds this server to the agents it starts by itself
only when `settings.el` says `(drgnx-agents-mcp (… search))` (Onboarding's Agents step asks; [agents.md](agents.md#what-agents-get)); `drgnx-search-mcp-server-spec` (core/drgnx-search-mcp.el) returns the ACP `mcpServers` entry for a
project — command, arguments and the environment: the state and config directories (`XDG_*_HOME`, `DRGNX_*_DIR`) and
**never a key**, because the entry is handed to the agent — for a profile or a script that wants to pass it in
`session/new`.

**Ask the Codebase** ([ai.md](ai.md)) uses the index too, when the project has one.

## How the index is made

- It is per project (a git repository), stored under drgnx's state directory (`~/.local/state/drgnx/search/` on
  Linux), not in the project. Index Status names the file; to drop a project's index, delete that file (and turn
  search off with `:off t` if it should not come back).
- **Indexing is incremental.** A file is read again only when its content changed (staged or not, and untracked files
  count); files that are gone are forgotten. A big project's first index takes a while; later runs take seconds.
  A leading byte-order mark and Windows line ends (CRLF) are dropped before a file is cut into chunks. A file whose
  one chunk the embedding provider refuses even alone is skipped (counted in the summary, tried again by the next run,
  its earlier rows kept); two such refusals in a row mean the provider is down and stop the run. If a fallback
  provider answers with vectors of the same size as the index's, the run stops saying "answered by fallback X" —
  run it again when the first provider is back, or rebuild to change the model.
- It runs in a **background job** — a separate Emacs under systemd, capped at 1 GiB of memory, at low priority — so
  the editor stays responsive. One job per project at a time. A second start within 30 seconds of a job that has no result yet does nothing (the job it would start would only exit with "indexing"); Index Project says so, and trying again a moment later works. Its log: Show Job Log (Agents tab). Starting a new job
  removes the project's earlier finished index jobs (also those killed without a trace, by a reboot say) but the last one, so their logs do not pile up.
- **After a save**: when you save a file of a project that has an index, drgnx re-indexes that project 30 seconds after the
  last save (a burst of saves is one run), at the next moment Emacs is idle, so the job never starts while you type.
  While an indexer still holds the project's lock it waits another 30 seconds. Nothing happens for a project without an
  index, and it never asks anything.

### What is never indexed

Whatever the configuration says:

- dot files and everything under a dot directory (`.env`, `.git`, `.github`, …);
- files whose names look like keys or secrets (`*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.kdbx`, `*.keystore`, `*.jks`,
  `*.asc`, `*.gpg`, `*.env`, `id_rsa*`, `id_dsa*`, `id_ecdsa*`, `id_ed25519*`, any name containing `secret` or `credential`, and
  any name with `netrc` or `authinfo` as a whole component — at the start or after `.`, `_` or `-`, followed by the end, `~` or a `.`: `.netrc`, `work.netrc`, `prod.authinfo`, `authinfo.gpg.bak` (code is not caught: `netrc-parser.el`, `netrc.el` and `authinfo-helper.py` are indexed);
- binary files, files over 1 MiB, files whose path contains a newline, symbolic links, submodules, and files in a directory whose real path is outside the
  project (a directory replaced by a symbolic link to elsewhere);
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

`:include` and `:exclude` must be lists of strings and `:off` `t` or `nil`. A file that is there but cannot be read (a `.drgnx` directory you cannot enter, a `search.eld` that is a symlink to nothing, or one that is not a regular file, count too), is
not a plist or gives a key another type (`:exclude "vendor/"` instead of `:exclude ("vendor/")`) never falls back to
the defaults — that could send files you meant to exclude to the provider. Instead nothing is indexed for the project:
the indexer stops with ".drgnx/search.eld cannot be read: …", a search of an index made earlier refuses with the same message (in the editor, from the command line and for agents), saving a file does not schedule a re-index, and Index
Project, Index Status and `drgnx doctor` say what is wrong. Without the file, the defaults apply. The file is read as plain data (nothing in it is ever evaluated, and `;;` comments and keys this drgnx does not know are fine), and it may be at most 64 KiB: a bigger file is refused, not cut. An empty file is refused too; delete it for the defaults. The file is one of drgnx's configuration files: see the [configuration reference](../reference/config.md). A `.drgnx` or `search.eld` that is a symlink to a readable config (dotfile managers do that) works like the file itself.

The same three keys are settings too: `drgnx-search-include`, `drgnx-search-exclude` and `drgnx-search-off`. A
project's `.drgnx/settings.el` or your private workspace file can set them, and so can your `settings.el` for every
project ([settings.md](settings.md), "Workspace settings"). `search.eld` counts as the project's shared settings; a
workspace's excludes are added to yours.

## How fast

Measured on one development machine with a local TEI server on a GPU (Qwen3-Embedding-0.6B, 1024 dimensions); yours will
differ. The project indexed is drgnx's own repository (289 files, 1,462 chunks):

| What | Result |
|---|---|
| First index (embedding included) | 231 s, about 6 chunks per second |
| Indexer peak memory | about 80 MiB (83,276 KiB resident), far below the job's 1 GiB cap |
| Index again, nothing changed | 0.1 s of work, 0.24 s for the command |
| Size of the index | 6.8 MB |
| A question, from the command line (compiled: `drgnx build`) | p50 0.26 s, p95 0.31 s (30 runs: 3 rounds of 10 questions) |
| The same, uncompiled (a checkout that was not built) | p50 0.73 s, p95 0.80 s — the 500 dot products of the re-rank run about six times slower |
| Recall@10 of the search against exact float cosine | 1.00 (20 questions; all 1,462 chunks re-embedded as floats; the quantized scan found all 10 of the exact top 10 every time). This is drgnx's own small index: the 500 re-ranked candidates are about a third of it, so it is not a measurement at large scale |

A question from the command line includes starting a batch Emacs and loading drgnx; embedding the question takes
about 25 ms, and inside a running Emacs there is no start-up to pay. The index is searched as vectors of one bit and one
byte per dimension: a Hamming scan of the one-bit fingerprints picks 500 candidates, which are re-ranked with the bytes. The question is quantized the same way, so the re-rank is a sum of integers. (The recall and timing figures above were measured before this change, with the question kept as floats; they have not been measured again.) The fingerprints are kept in memory for the last project searched; while an index run adds files a query reads only the new chunks, and the index is read after the embedding answer arrives, not inside the process that delivers it.
The recall above was measured with the real model, not random vectors.

## Privacy

To make the vectors, the text of the chunks is sent to the provider of the `embed` role — and the text of your
question each time you search. With the default local TEI server (or Ollama, llama.cpp, LM Studio) that stays on your
machine. If you point the role at a hosted provider such as OpenRouter, the chunks of the indexed files go to it:
keep the secrets out with `:exclude`, or turn search off for that project with `:off t`. A project's
`.drgnx/` files can only choose roles among the providers you configured, never add a provider of their own ([ai.md](ai.md)).
The vectors and the chunks' text stay in the local index.
