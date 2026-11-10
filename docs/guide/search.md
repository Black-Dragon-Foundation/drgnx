# Semantic Search

Semantic Search finds code by what it does, not by the words it uses: ask "where do we retry a failed request" and
the chunks that do that come back, even if none of them contains the word "retry". It is the project's code cut into
chunks, each chunk turned into a vector by an embedding model, and your question compared with them. The exact words
of your question, the names the code defines and the paths of its files are searched too, and the rankings are merged,
so an identifier you remember and a paraphrase both find their place.

The search is **Hrafn**, and it lives in the hub (Ratatoskr, [agents.md](agents.md)), not in Emacs: the hub indexes
your projects, keeps the index current as files change, runs the embedding model and answers the editor's question.
Emacs only asks and shows the answer, so typing is never slowed by indexing.

## Setting up

Keyword, symbol and path search work at once on any project, with nothing to set up. The model that adds meaning
comes with **Set Up Semantic Search** (the palette, or Help → Welcome → Semantic Search). It shows what is present and
then, in a frame:

1. when the built-in model (IBM's Granite small English r2) is missing, asks "Download granite-embedding-small-english-r2
   (N MB) for semantic search? It runs on this machine, on the GPU when one is fast enough." — and only on yes
   downloads it, from Hugging Face or from the mirror you name in `drgnx-search-model-mirror`, every file checked
   against its pinned sum;
2. offers a server (TEI in a capped container, or Ollama) **only** when this machine can run one: it shows the
   commands, the memory cap and whether a GPU image would run, and asks. A server is a choice, not the way to get
   speed: the built-in model needs none. On yes it starts it, adds the server to your providers and tells the hub;
3. indexes this project in the background, or, when the index is current, runs a test query and shows the top hit.

Run from `emacsclient -e`, in a daemon with no frame, or from a script, the wizard asks nothing and starts nothing: it
says "run M-x Set Up Semantic Search in a frame to download a model or start a server". Onboarding's step only
looks (`drgnx-search-setup-detect` changes nothing).

The first time a project's `.drgnx/ai.eld` routes a role to a remote provider, the command you ran asks once per
project whether that route may be used (never for several projects at once, never from a timer).

`drgnx doctor` has a `search` check. It asks the hub for the embedders and for the current project's index and names
the model in use, its device (the GPU, or the CPU) and, for a server, the address family that answered. It **warns**
when the built-in model embeds on the CPU because the GPU was lost (and says why), when the index has coverage errors
(a class with files and no chunks), and when no model answers ("keyword only", with the built-in model's state);
**info** when the hub is not running; otherwise ok. It never prompts and never starts the hub.

## Using it

| Command | What it does | VS Code | Emacs | Vim |
|---|---|---|---|---|
| Search: Semantic Search | asks for a question and shows the best chunks in the panel's Results tab | `C-k C-f` | `C-c s s` | `SPC s i` |
| Search: Index Project | has the hub index this project now; with `C-u`, from scratch | palette | palette | palette |
| Search: Index Status | files and chunks, the models that have vectors, the device, tier 2's state, coverage errors, what lags | palette | palette | palette |
| Search: Set Up Semantic Search | the wizard above | palette | palette | palette |

In the command palette, type `#` and your question — `#where do we parse the config` — to search without choosing a
command first; a bare `#` asks for the question. Semantic Search offers the symbol at point as the default: `RET` on an
empty prompt searches for it.

The results are the same kind of list as **Search in Project**: one line per chunk (its first line of text), `RET` or a
click jumps to the file at that line, and the preview follows the selection. The answer comes after the command
returned, and the results list then takes the focus. The list header and the echo area say which model took part and
what lags, in the hub's own words, for example "model granite-embedding-small-english-r2; vectors: 12 files behind
(…); keyword and symbol results are current". Without a model ready it says why ("built-in model not downloaded") and
the keyword, symbol and path results are there at once; without a hub the echo area says why there is no answer.

A hit in a file that changed since it was indexed is looked for again in the file as it is now (its first line, else its
symbol), so the jump lands where the code is. A search never edits anything and never waits for a running indexer.

While you type, the editor tells the hub (at most once every 2 seconds): the hub then holds the vectors back for 3
seconds, so building them never competes with a keystroke.

## For agents

Agents get the same search the editor uses, three ways, over the same index.

**The command line** (a client of the running hub; the hub starts when it is not running)

```
drgnx search index ROOT [--rebuild] [--now]                      # have the hub index the project (--now: also on battery)
drgnx search query ROOT QUESTION… [-k N] [--scope code|tests|docs|all] [--json]
```

`query` prints the best N chunks (default 10), one block each with the path, the line, the symbol and a preview, best
first, and ends with what lags. `--json` prints the answer as data. Tests rank below code; `--scope tests` or `all`
looks in them. `ROOT` is the project or any directory inside it.

```
drgnx search symbols ROOT NAME [--match auto|exact|prefix|contains|regex] [--kind KIND]… [--path GLOB] [--scope S] [-k N] [--json]
drgnx search outline ROOT FILE [--no-docs] [--json]
```

`symbols` lists where names are defined: each definition's file and lines, its kind, the definition around it (a
method's impl or class), its first doc line and its signature (its lines up to the one that names it). `--match auto`,
the default, tries the exact name, then names that start with it, then names that hold it (both ignoring case), and
says which one matched; `regex` takes a regular expression. Code comes before docs and tests; `--kind` and `--path`
narrow it. `outline` lists one file's definitions in order, with their lines, nested under what holds them. Both
answer from the index, so a file search leaves out (see [What is never indexed](#what-is-never-indexed)) is never in
them, and both end with how current the index is ("index: current", or how many files are waiting).

**The MCP tools**

`drgnx search mcp [ROOT]` serves the search tools over stdio (ROOT defaults to the current directory); their questions
go to the hub.

| Tool | Arguments | Answers |
|---|---|---|
| `search` | `query` (required, in words or a name), `scope`, `k` (1 to 50, default 10) | the best chunks, as `search query` prints them |
| `symbols` | `name` (required), `match`, `kind` (a list), `path` (a glob), `scope` (default `all`), `k` (1 to 100, default 20) | where names are defined, as `search symbols` prints them |
| `outline` | `path` (required, relative to the project), `docs` (default true) | one file's definitions, as `search outline` prints them |

Paths an agent names are relative to the project and stay inside it. The agents
drgnx starts get the same tools on a socket of their own, pinned to their job's project, when `settings.el` says
`(drgnx-agents-mcp (… search))` (Onboarding's Agents step asks; [agents.md](agents.md#what-agents-get)); it is listed
to them as `drgnx-search`. To give an agent outside drgnx the tool, add the server to its own MCP configuration, for
example for Claude Code:

```
claude mcp add drgnx-search -- /path/to/drgnx/bin/drgnx search mcp /path/to/project
```

An agent has no other way in: the hub's `search/*` methods are the editor's.

**Ask the Codebase** ([ai.md](ai.md)) uses the same search, asked from the editor without waiting for a model.

## How the index is made

- It is per project (a git repository and its linked worktrees), stored in the hub's state directory, not in the
  project. Index Status says what it holds; to drop a project's index, run Index Project with `C-u`.
- **Two tiers.** Tier 1 reads the files (symbols, chunks, full-text) and is fast: a project is searchable by keyword and
  symbol within a minute of the first query, and a saved file within about a second. The hub watches the files, and
  catches up after a branch switch once git's lock is gone. Tier 2 makes the vectors, with the built-in model and with
  each server that answers, in the background: capped in memory, at low priority, paced so that typing keeps its
  frame, and held back on battery until AC (Index Project with `--now` overrides that).
- **Languages.** Emacs Lisp, Rust, C, shell, Python, JavaScript, TypeScript, TSX, Go and Java are parsed: their chunks follow
  definitions, and their definitions are what `symbols` and `outline` list. Org and Markdown follow headings; other
  text is cut into windows of lines, with no definitions.
- **Content-keyed.** A vector belongs to the text of its chunk (and the chunker's version), so a file that changed only
  re-embeds the chunks that changed, and switching to another branch and back embeds nothing.
- **Which model answers.** A running server whose vectors cover at least 95 % of the project's chunks is used; else
  the built-in model (unless `drgnx-search-builtin` is nil); else a server whatever it covers. Each model keeps its
  own vectors, so a server that comes back finds its vectors still there. Every answer names the model that made it.
- The built-in model runs on the GPU when one is fast enough, else on the CPU, and the hub never starts a TEI or
  Ollama server by itself: only the wizard does, after you agreed.

### Search in a worktree

A search from a linked worktree (an agent's worktree, or one you made with `git worktree add`) answers from that
worktree: the project's index (the **base**, built from the main checkout) plus an overlay of only the files where the
worktree differs from it. A file the worktree changed is found as it is there, a file it deleted is not found, and a new
file is found there and nowhere else. The answer's last line says so: "worktree: 14 files differ from the base".

- The first search in a worktree builds its overlay in the background and answers from the base meanwhile ("worktree
  being indexed"). Afterwards the hub keeps it current from its file watches; a worktree past the watch budget (half of
  `fs.inotify.max_user_watches`) is checked when you search, at most every 5 seconds ("worktree being checked"), and
  doctor names it. drgnx never raises the limit itself.
- At most 16 worktrees keep an overlay; the one used least recently gives its up and builds it again on its next search.
  An overlay goes when its worktree is removed or has not been searched for 14 days, never while the worktree is
  `locked` (`git worktree lock`).
- The hub's `search/query` with `base: true` asks the base instead.
- What is indexed follows the base's rules: `.drgnx/search.eld` and the `drgnx-search-*` settings are read from the
  base checkout, so a branch that changes them takes effect when the change reaches the base. Size, binary and link
  checks run on each worktree's own files.
- **Which checkout is the base.** The main checkout by default. When most of your worktrees branch from another line
  (a release branch, say), set `drgnx-search-base` for the project to that checkout's folder: the overlays then hold
  fewer files. Changing it builds the base again from the new checkout, and every overlay with it.

### What is never indexed

Whatever the configuration says:

- dot files and everything under a dot directory (`.env`, `.git`, `.github`, …);
- files whose names look like keys or secrets (`*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.kdbx`, `*.keystore`, `*.jks`,
  `*.asc`, `*.gpg`, `*.env`, `id_rsa*`, `id_dsa*`, `id_ecdsa*`, `id_ed25519*`, any name containing `secret` or `credential`, and
  any name with `netrc` or `authinfo` as a whole component);
- binary files, files over 1 MiB, symbolic links, nested repositories and submodules, and files in a directory whose
  real path is outside the project;
- files that `.gitignore` excludes (the index lists the project's tracked files and the untracked ones that git does
  not ignore);
- your personal notes: any file whose real path is under `~/org` (except `~/org/board.org`) or on your own deny
  list, even one you opened to the store. A project whose root is inside `~/org` is refused outright. See
  [Personal notes](security.md#personal-notes).

Files marked generated (`.gitattributes` `linguist-generated`, "generated" or "DO NOT EDIT" in the first five lines,
names like `*-autoloads.el`, `*.lock`, `*.min.*`) are indexed for keyword search and rank lower, and get no vectors.

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
the defaults — that could send files you meant to exclude to a provider. Instead nothing is indexed for the project
until it is fixed. Without the file, the defaults apply. The file is read as plain data (nothing in it is ever evaluated,
and `;;` comments and keys this drgnx does not know are fine), and it may be at most 64 KiB: a bigger file is refused,
not cut. An empty file is refused too; delete it for the defaults. The file is one of drgnx's configuration files: see
the [configuration reference](../reference/config.md).

The same three keys are settings too: `drgnx-search-include`, `drgnx-search-exclude` and `drgnx-search-off`. A
project's `.drgnx/settings.el` or your private workspace file can set them, and so can your `settings.el` for every
project ([settings.md](settings.md), "Workspace settings"). `search.eld` counts as the project's shared settings; a
workspace's excludes are added to yours. The editor sends the values per project to the hub.

## How fast

Budgets on the desktop reference machine (4 pinned cores, an AMD Radeon GPU); your machine will differ. Embedding time is
linear in tokens, so throughput is in tokens.

| What | Budget |
|---|---|
| Tier-1 index of a project the size of drgnx (no vectors) | 60 s |
| One saved file searchable by keyword and symbol | 1 s after the debounce |
| Built-in model on a desktop GPU | 20,000 tokens/s (about 27 chunks/s) |
| Built-in model on 4 CPU cores | 680 tokens/s (about 1 chunk/s) |
| One question embedded | 50 ms (95th percentile) |
| A query, warm, 50,000 chunks | 100 ms (95th percentile) |
| A query, warm, 100,000 chunks | 200 ms (95th percentile) |
| The editor's main thread per answer | 16 ms (it only renders) |
| The embed worker's memory | 1.5 GiB, unloaded after 5 idle minutes |

A project of 5,000 chunks has its vectors in about 2.5 minutes on the desktop GPU and in 70 to 90 minutes on the CPU
alone; its keyword and symbol search is there from the first minute either way.

## Privacy

The built-in model runs on this machine: no text leaves it, and nothing is downloaded without your yes. To make
vectors with a server, the text of the chunks is sent to it — and the text of your question each time you search. A
local server (TEI, Ollama) keeps that on your machine; if a project's `.drgnx/ai.eld` points the `embed` role at a hosted
provider such as OpenRouter, the chunks of the indexed files go to it: keep the secrets out with `:exclude`, or turn
search off for that project with `:off t`. A project's `.drgnx/` files can only choose roles among the providers you
configured, never add a provider of their own ([ai.md](ai.md)). The vectors and the chunks' text stay in the local
index. An address written as `localhost` is used as `127.0.0.1` for the local servers; Ollama needs the model named in
the `embed` role (`(ollama . "qwen3-embedding:0.6b")`).
