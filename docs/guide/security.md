# Trusted folders and the "Restricted Mode" mark

A file you open can ask Emacs to do things: run a syntax checker that executes the file, rename symbols as it is
read, or make Emacs reach out to another machine. drgnx lets files from folders you trust do all of that, and holds
back what is risky in files from any other folder — like VS Code's Workspace Trust, but without a dialog. Nothing
here ever asks you a question; you trust a folder when you choose to.

## What is trusted

- drgnx's own folders: its checkout, its config dir (`~/.config/drgnx/` by default: [where drgnx keeps its files](files.md#where-drgnx-keeps-its-files)) and its packages dir, and the Lisp
  files Emacs itself came with.
- The folders you trusted with **Trust This Folder**. They are kept in `~/.local/state/drgnx/trusted-folders.eld`,
  so they stay trusted in the next session. A file drgnx cannot use trusts none of its folders: one that cannot be
  read, one with a mistake (`:folders` must be a list of folder names), and one a newer drgnx wrote. A message
  names the file and the reason, once each time the file changes. Trust This Folder copies a file it cannot use
  aside (`trusted-folders.eld.bak-…`, the newest three kept) before it writes a new one, and refuses to change a
  newer drgnx's file. Two Emacs sessions trusting folders at once both keep theirs. A folder in the file that
  Trust This Folder would refuse (below), and a remote folder, are not trusted; reading the file never contacts
  another machine.
- The folders of the `drgnx-trust-parents` setting that you marked `:code t` ("trusted, everything", below). A folder
  trusted only by its location is not trusted content.
- Anything you put in Emacs's own `trusted-content` option. drgnx only adds to it; `:all` trusts everything.

Every other folder is untrusted, including the projects you open, until you trust them.

## The "Restricted Mode" mark

A file from an untrusted folder shows **Restricted Mode** in the status bar, in a quiet colour from your theme;
hovering it says what that means (Flymake checkers and symbol shorthands from the folder are off). Click it
to trust the file's folder: its project's root when the file is in a project (a git repository, for example), else
the file's own folder. The mark is not shown for remote files, and Trust This Folder refuses a remote folder.

A folder that holds far more than one project is never trusted: `/`, your home folder, the temp folder, `/tmp/`,
`/var/tmp/` and `/dev/shm/`, or a folder above any of them. A file lying directly in one of them has to move into a
project folder first.

Or use the palette: **File: Trust This Folder**, and **File: Untrust This Folder** to take it back (drgnx's own
folders stay trusted). Untrusting always takes effect at once. When `trusted-folders.eld` cannot be changed (it
cannot be used, or a newer drgnx wrote it), the message says the folder is untrusted for this session only, and
why. Trusting a folder takes effect at once in its open files: their checkers run and their
shorthands come back, without reopening them.

## Workspace trust

A project's `.dir-locals.el`, `.dir-locals-2.el` and shared `.drgnx/settings.el` can set variables and run code when
you open one of its files. drgnx decides what applies from the project's trust (details and examples:
[Settings, "Trusted locations"](settings.md)):

- **Untrusted** (the default): safe values only from `.drgnx/settings.el`, and `.dir-locals*.el` behave exactly as in
  plain Emacs (Emacs asks before an unsafe value when you open a file; drgnx's own background opens apply safe values
  only and never ask).
- **Trusted by location** (below a folder of the `drgnx-trust-parents` setting): the project's data applies; its code
  (`eval:`, `mode:`, `(:eval …)`, risky and program-naming values) runs only after you review and allow it, and waits
  again whenever it changes. Such a project is **not** trusted content: Flymake checkers and symbol shorthands stay
  off there, because expanding the macros of its `.el` files is code too.
- **Trusted** (Trust This Folder): its data applies, and the code Trust This Folder showed you; later code waits.
- **Trusted, everything** (a `drgnx-trust-parents` entry with `:code t`, which you choose per folder): all of it
  applies with no review, and the folder is trusted content.

The rules behind it:
- Nothing prompts. Code that waits is listed for review; allowing a piece of code applies it at once to the open
  buffers.
- The allowed code is kept per project, value by value, in `trusted-folders.eld` on this machine. drgnx never puts a
  folder in `safe-local-variable-directories` (Emacs would apply every value there, an `eval` included, with no
  question) and never writes `safe-local-variable-values`. `drgnx doctor` warns about any folder you put in
  `safe-local-variable-directories` yourself that you did not trust.
- drgnx's security settings (`drgnx-trust-parents`, the agent, sandbox and key settings) are in Emacs's
  `ignored-local-variables`: no `.dir-locals.el`, `-*-` line or `Local Variables:` block can set them, whatever the
  folder's trust, and drgnx reads them only as their global value.
- `enable-local-variables` nil turns every workspace layer off; `enable-local-eval` nil stops every `eval`, allowed or
  not.
- Untrusting a project takes its values back at once and forgets its allowed code. Code that already ran cannot be
  undone.

## What is held back in an untrusted folder

- **Flymake checkers that run the file.** Outside trusted folders Flymake runs only checkers marked safe.
  Language-server diagnostics (eglot) count as safe — Emacs runs nothing from the file, it asks the server you
  installed — so they keep working everywhere. Another checker is switched off for that file, with one message saying
  why. Emacs 31.2 does the same; drgnx adds the check on Emacs versions that lack it.
- **Symbol shorthands** (`read-symbol-shorthands` in a file's or folder's local variables). They are dropped when
  the file opens, and given back when you trust the folder.

## What is guarded everywhere

- **Crafted remote names.** A file name with a control character anywhere in it, or whose `user@host` part
  holds a shell character (`; & | ! , < > ( ) { }`, quotes, a backquote, a space…) or has a user or host starting
  with `-`, is treated as a local name: TRAMP never connects for it. Ordinary remote names — `/ssh:host:/path`,
  `/ssh:user@host#2222:/x`, `/ssh:a@b|sudo:root@b:/x`, `/-:host:/x`, `/podman:name:/`, `$USER` in a name — work
  as before. drgnx appends its pattern to
  `tramp-ignored-file-name-regexp`; if you set that option yourself, add to it rather than replacing it.
- **Remote names in compile and grep output.** In a local compilation or grep buffer, a remote file name or an
  "Entering directory" line naming a remote directory is read as a local name (quoted with `/:`). Output text never
  makes Emacs connect anywhere, and clicking such an error opens nothing remote.
- **Links in the Work tab and agent edits.** A Work row, graph box, commit or worktree that names a remote file opens
  nothing and says so. When an agent proposes a change to a remote name from a local session, the review does not
  open and the agent is told the change was rejected; in a session started in a remote folder, its files review as
  usual.
- **Links in AI answers.** The Sources links of an Ask the Codebase answer open a remote file only when you asked
  about a remote folder. A remote name that shows up in a local folder's answer is not opened; a message says so.
- **Host names in text.** `ffap` (find file at point) never pings a host name it finds in text
  (`ffap-machine-p-known` is set to `reject` while you leave it at its default). Emacs's own defaults already keep
  directory-local variables and auto-revert away from remote files; drgnx leaves them as they are.
- **Auto-saving remote files.** If you turn on `auto-save-visited-mode`, it saves local files only:
  `remote-file-name-inhibit-auto-save-visited` is set to t while you leave it at its default (nil).
- **The hub's socket (Ratatoskr).** Its directory is yours and mode 0700, and the socket, the cap file
  (`hub-HASH.cap`) and the lock are 0600. Ratatoskr also asks the system who connected (the peer's uid) and closes a
  connection from any other user at once, root included, with the peer's pid in its log. That holds even when a socket
  was opened up by mistake. The cap proves an editor or the CLI to the hub, and the hub to them. Each proof covers
  that connection's own challenge, so a hello line someone captured does not work on another connection. Without a
  proof a connection may only ping, read the hub's status, list the sessions (names and jobs), read spending and
  send coordination notices; everything that starts, stops, answers, approves, configures or reads a transcript needs
  it. The cap keeps out
  a connection that reaches a socket it should not have, such as one bound into a container. It is worth nothing
  against unsandboxed programs running as you: they can read the cap file. The agent sandbox is the boundary
  there, not the cap.
- **The Lisp hub behind Ratatoskr.** Until each part moves to Rust, Ratatoskr runs the Lisp hub as its child on a
  private socket of its own and checks every call (who may make it, and every value in it) before passing it on, so
  the Lisp hub only ever gets calls the front accepted. Only the front knows that socket: the Lisp hub forgets it at
  start, so the agents it runs reach the hub through the front like everyone else. Its environment is a fixed list
  (paths, locale, the ssh agent, proxies and certificates, the terminal and display): a provider key set in the
  environment that starts the hub never reaches it, or its agents. Keys reach the hub over the socket, from you.
  The Lisp hub also serves only Ratatoskr: each time it starts, Ratatoskr gives it a new secret in its environment
  (never on its command line or in a file), and it closes, unanswered, any connection that does not open with that
  secret. Agents' own sockets are in a directory per session, apart from the Lisp hub's, so a sandbox given an
  agent's sockets never reaches it.
- **Your keys go only to a hub that proved itself.** Your editor and the CLI hand provider keys over only after the
  hub showed, in its answer to their hello, that it read the same cap file. A hub that cannot show it is closed and
  you are told; a hub of an older drgnx (before Ratatoskr) still gets your editor's calls but never a key. The
  coordination servers your agents run never read the cap: they stay at the level of a connection without a proof.
- **Your keys stay in the hub's memory.** The gateway runs inside Ratatoskr, and the keys your editor hands it are
  held only in its memory: never in a file, its database, its log, an environment or a command line, and never
  passed to the Lisp hub behind it. Agents get a token instead, which works only for them and only on the hub's own
  port or their session's socket; the hub keeps a hash of it, never the token. `ratatoskr doctor` names the providers
  whose key the hub holds, never a key. A restarted hub has no key until your editor connects again; when it asks
  for one, the editor reads the provider's environment variable again and never prompts (no Keychain, no `.gpg`
  file), else it tells you to run AI: Load Keys. The provider list the editor sends the hub (and again when the
  providers in settings.el change) holds no key. The Lisp hub behind Ratatoskr registers its agents through Ratatoskr, without keys.
- **The hub is not dumpable.** Another program running as you (an agent outside a sandbox, a debugger) cannot read
  the hub's memory, and so your keys, with `ptrace` or `/proc/PID/mem`, and the hub writes no core file. This does
  not stop root, or a program given the `CAP_SYS_PTRACE` capability. A hub that cannot protect itself this way (on
  macOS, one started under a debugger) takes no key at all: `ratatoskr doctor` and `ratatoskr status` print "keys:
  refused, this hub cannot protect keys" with the reason; restart the hub outside the debugger. `ratatoskr stop` signals only the process that
  is actually listening on the hub's socket, asked of the system (on Linux through a pidfd, which cannot hit a reused
  pid), never a process named by a file or a command line: a program that calls itself `ratatoskr` is never stopped
  by mistake.
- **Providers over plain http.** A provider's URL is `https`, or `http` for any host. A provider that takes a key
  at an `http` address off this machine (a server on your LAN) still works, but its key travels in clear text: the
  hub warns you when the provider list is applied, in its log once, and in `ratatoskr doctor`, and your editor shows
  it once per provider each time it starts. Use `https` for it.
  A keyless provider (a local Ollama) gets no warning.

## Where your keys live

The hub holds your provider keys, in its memory only (above). What else gets near them:

- **Agents** get a token, never a key. It reaches only Anthropic's Messages API, along the agent's own provider list,
  and only on the hub's port or the agent's session socket.
- **The editor** can take a token of its own for its AI requests (chat, completion, embeddings), so the request
  carries the token and the hub adds the key. That token reaches only a provider's own paths
  (`http://127.0.0.1:PORT/p/PROVIDER/…`), one provider per request, and only on the hub's port on this machine:
  never an agent's session socket, and never the Messages API agents use. One process holds one such token (asking
  again replaces it); it goes when that process does, and it survives a restart of the hub. A keyless provider on
  your machine (a local Ollama, llama.cpp, TEI) needs no key and is reached directly. Chat, completion, edits, commit
  messages, embeddings and gptel all take this route ([ai.md](ai.md#where-requests-go)); the editor fetches its token
  again on every reconnect and keeps it in memory only. A background request that has no token yet fails with "drgnx hub is starting; try again" and never
  waits.
- **The editor keeps no key once the hub has one.** AI: Load Keys (and onboarding, the Store key button of Agent
  Settings, a command that finds a key in your Keychain or keyring) reads a key, hands it to the hub over the proven
  socket and, once the hub answered, forgets it: it is gone from the editor's memory and auth-source's cache, the
  gptel backend holds the editor token, and nothing the editor sends carries it but that one hand-over. Until a hub
  runs, a key AI: Load Keys found waits in memory and goes when the editor connects. Checking whether a provider is
  usable (AI: Choose, onboarding's checks) reads its key only to see that there is one, and keeps nothing: neither the
  key nor auth-source's copy of the file. When the hub restarts (an update, `drgnx hub restart`), the editor hands
  over again the keys it can read without asking: your environment and a plain `~/.authinfo`. A key that lives only in
  your Keychain, keyring or a `.gpg` file cannot be read without asking, so a notice says "the drgnx hub restarted
  without your … key: run AI: Load Keys". A provider with a key is never asked directly,
  and an agent of a keyed profile (OpenRouter, Anthropic, Kimi, DeepSeek) does not start without the hub: "the drgnx
  hub is not running; agents reach providers through it".
- **Which keys the hub holds** is all anyone can ask of it: the provider names (`ratatoskr doctor`, and the hub's
  `gateway/keys-held`), never a key. Your editor judges a provider usable from that list.
- **Keys in your environment** (`OPENROUTER_API_KEY` and the like) stay where you put them: drgnx never unsets them,
  so the programs your Emacs starts (shells, `compile`) still see them; agents do not (their environment drops every
  provider key) and use the copy the hub holds. `drgnx doctor` notes such a key ("OPENROUTER_API_KEY is set in this
  Emacs's environment; children inherit it; agents use the copy the hub holds"). To keep a key out of shells too, keep
  it in your Keychain or keyring instead and let AI: Load Keys hand it over.

## Who an agent is

The coordination tools (hello, reports, messages, tasks, decisions) act as one agent, and the agent never says
which: Ratatoskr knows it from how the connection reached it.

- **An agent drgnx runs** gets a socket of its own (`mcp.sock`, in its session's private directory: mode 0700, the
  socket 0600, both yours). Whoever connects to that socket is that agent, with its job and task. A name in a tool's
  arguments, or `DRGNX_AGENT` in an environment, changes nothing. The socket closes when the program that opened the
  session (your editor, or the hub's job) is gone, and comes back on the same path after a hub restart while that
  program still runs.
- **An agent drgnx did not start** (Claude Code in a terminal, for example) reaches the tools through a bridge on the
  hub's main socket, without the cap. Ratatoskr names it after the process that started the bridge, from the system,
  not from the bridge: `ext:KIND:PID-HASH` (the kind the bridge gives, that process's pid and a hash of its start
  time, so a reused pid is a new name). Such an agent is unverified: it can say hello, report edits and tests and send
  messages, but the tools of drgnx's jobs (claiming, updating or completing a job's task, recording a decision) refuse
  it. A bridge whose parent is init (pid 1) is refused.
- Any program running as you can still connect to these sockets: the agent sandbox, not the socket, is the boundary
  between agents and your account.

## Personal notes

Your personal notes never enter drgnx's store (`work.db`), so no agent can read them through it. Kept out:
everything under `~/org/` except `~/org/board.org`, your task board, which the tracker reads. Ratatoskr checks each
path after resolving links, so a link from a project into `~/org`, or `..` in a path, changes nothing.

- **Always kept out:** `~/org/notes.org`, and under `~/org` any file whose name starts with `notes`, `journal`,
  `diary` or `personal` (any case), or anything inside a folder so named. You cannot open these.
- **Your own additions:** `personal-notes-deny.json` in your config folder lists more files, folders and globs to keep
  out, anywhere, as firmly as the built-in ones:

  ```json
  {"version": 1, "entries": [{"kind": "folder", "path": "~/Documents/diary"},
                             {"kind": "glob", "path": "~/docs/*.private"}]}
  ```

  A glob has `*` and `?` in its last part only. The built-in list cannot be shortened. If this file cannot be read
  or has a mistake, the built-in list still applies and no personal file is opened (below) until you fix it.
- **Opening one file:** `personal-notes-allow.json` in your config folder names single files under `~/org` that the store
  may read, for example a reading list a plan refers to: `{"version": 1, "paths": ["~/org/reading.org"]}`. Only
  existing regular files count: a folder, a glob or a path outside `~/org` is ignored. A file that is always kept out
  stays out even if listed.
- Keep both files `0600`. An opt-in file that others may write is ignored entirely. `drgnx doctor` lists every entry
  it ignored and why.
- **The work scan's own door.** The scan that reads your plans (`drgnx work scan`) applies the same rules in Lisp
  (`core/drgnx-deny.el`, held to the same table of cases as the hub's check) before it sends anything: it skips
  files the rules deny, and drops a plan's `**Spec:**` that names one, even through a link. The hub checks again
  (defence in depth). The code indexer (Hrafn, in the hub) asks the same check with the opt-ins ignored: a file you opened for the store
  is not opened for the code index. A scan root inside `~/org` (or `~/org` itself) is refused the same way, opt-ins
  ignored, with "the work tracker never reads a project inside ~/org (personal notes)": nothing under it is read and
  git never runs there (nor in a repository inside `~/org` that a project contains); the other roots are scanned.
- **The entity embedder skips them too.** When the hub makes the store's search vectors (a `tei` embedding provider
  in your providers), an entity whose source, path or id the rules deny is never sent, even one stored before you
  added its folder to your deny list. A text you excise (or a file you revoke) while the provider is answering gets
  no vector of what was sent.
- **The code search index never reads `~/org`.** The hub refuses to index a project whose root is inside
  `~/org` (or reaches it through a link), before it reads anything there. For a project that contains `~/org` (your home folder as a git repository), every file whose
  real path is under `~/org` is left out, the board excepted; nothing of it is read, sent to an embedding provider
  or stored.
- **Every other way in is checked too.** Importing an export (`graph/import`) drops a record that names a denied
  path or has a source form it cannot read; a store from before schema 7 loses such rows when it is upgraded
  (its pre-upgrade backup keeps them, and `drgnx doctor` lists that backup); and an export (`graph/export`) checks
  every record again, so a path you add to your deny list never leaves in a later export, nor do the notes of the
  changes that wrote such a record. A test plants random
  bytes in fixture notes and checks that none of them reaches the store, its write-ahead log, the code index, an
  export, the embedding provider or the hub's log; the hub never writes a file under `~/org`.

### Opening a personal file to the store

Use the commands rather than editing the files by hand (palette, Preferences):

- **Open a Personal File to the Store…** (`drgnx-store-allow-personal-file`) asks for one file under `~/org`. A
  folder, a file outside `~/org`, the board and a file that is always kept out (`notes.org`, the names above, your
  own deny entries) are refused before anything is asked. It then asks once, naming the file ("Agents in your
  projects may read what the tracker parses from it"), writes `personal-notes-allow.json` (`0600`, replaced in one
  step), and asks the hub to apply it now; the next scan reads the file.
- **Close a Personal File to the Store…** (`drgnx-store-revoke-personal-file`) offers the files you opened. Closing
  one **excises** what came in from it (every version, the search index, the notices that quoted it; see "Removing
  something for good"), then compacts the store. If dated backups or older copies of the store still hold its text,
  it names them and asks once whether to delete them; say yes, or they keep it (they cannot be found again later,
  since what they hold is gone from the store). Your exports are only listed: they are your files.
- **Keep a Path Out of the Store…** (`drgnx-store-deny-personal-path`) adds a file, a folder or a glob to your own
  deny list; whatever came in from it is excised at once. **Stop Keeping a Path Out…**
  (`drgnx-store-undeny-personal-path`) takes one of your entries back (nothing stored changes); the built-in list
  cannot be shortened.
- None of them reads the file's content, and they run only when you call them. What each did (and a hub that did
  not apply it at once) is a Store notice, shown once in the echo area and kept in the Notices list.
- **Any change counts, not only the commands'.** Any program running as you can edit these files (an agent too:
  the same Unix user is no boundary). The hub looks at both files every two seconds and when it starts, applies any
  change at once (a file closed while the hub was down is excised at its next start; no backup is ever deleted
  that way, only by the command's question), and tells every drgnx editor:
  "personal-file opt-ins changed: +1 / −0". An entry it ignored is counted in that notice, and `drgnx doctor` says
  why. If you did not make the change, close the file again.

## Grants

An agent reads only its own project in drgnx's store: the project of the folder it was started in (for an agent
outside drgnx, the folder its bridge reported). To let it read another project, you give a **grant**; nothing else
widens what it sees.

- A grant is for a project (every agent working in it), a profile (every session of that profile, in any project)
  or one session, and opens one project or all of them (`*`, future ones included). It may expire.
- A second kind of grant lets agents edit the title, text and status of tasks **you** made, one task or a whole
  project. It never reaches a task in a project other than the agent's own: no grant lets an agent write into
  another project.
- **Only you make, change and revoke grants.** The store refuses any write of a grant that does not come from you,
  whatever path it takes (an agent's tool, a proposed change, an import, a scanned file), and the same holds for the
  store's settings. An agent can only ask (an access card in the Work cockpit), never grant itself or another
  anything.
- **An agent's request** (`access_request`) waits on a card in the Work cockpit with its reason. You answer with one
  of four choices: **This session** (that session only, while it lives and for a day at most), **Its project**
  (every agent working in the requester's project), **Its profile** (every session of its profile) or **Refuse**.
  The first three give a read grant of the project it asked for; the agent is told either way. drgnx's own
  background process can refuse a request for you, never grant one.
- You can list, give and revoke grants directly too, through the hub method `graph/grants`.
- Revoking takes effect at once: the next read by any agent runs without it, and a walk through the graph already
  running stops at its next step.
- An agent sees the grants given to it, never the others (they would name your other projects).
- Text agents wrote is shown to other agents as data, not instructions, fenced with its author and project, even
  under a grant and even to the agent that wrote it.

## Settings grants

drgnx's store keeps the history of your settings (who changed what, and when). Only you change settings. An agent
may change one only under a **settings grant** you gave, and the store checks it on every write, whatever path the
write takes.

- A settings grant is for a project, a profile or one session, like any grant, and opens either your **global
  settings** (`settings.el`) or **its project's settings** (the agent's own project's private and shared workspace
  files, never another project's). It may name the settings it covers, with `*` as a wildcard (`fill-column`,
  `python-*`); without names it covers every setting the hard deny-list leaves. It may expire.
- **The hard deny-list is never grantable.** No grant lets an agent change drgnx's security settings (agent
  profiles, routes, OpenRouter limits, providers, the sandbox switches, keys, modules, `drgnx-trust-*`, your Lisp
  files), Emacs's (`enable-local-variables`, `enable-local-eval`, `ignored-local-variables`, `safe-local-variable-*`,
  `trusted-content`, `custom-file`, `load-path`, `package-archives`), or any setting whose name says it holds code or
  a program (`…-hook`, `…-function`, `…-program`, `…-command`, `…-interpreter`, `…-executable`, `…-args`, and Emacs's
  other risky endings).
- A settings grant lets an agent read nothing it could not read before.
- Outside agents (not started by drgnx) never change settings, even under a grant.
- Only you make settings grants, as every grant.

## Agents and your settings files

A job agent's sandbox keeps your settings files out of the agent's reach, so an agent
that is allowed to write in a folder still cannot change what your Emacs loads as you:

- **Your config files are closed by their true paths.** `settings.el`, `config.el`, `custom.el`, `described.el`,
  `workspaces/` and every file in `drgnx-user-lisp-files` are closed wherever they really live: when `settings.el` is
  a link into your dotfiles (GNU Stow, a dotfiles checkout), the sandbox closes the dotfiles file, and a job asked to
  write in the dotfiles folder is refused, in every tier. So is each file in `workspaces/` that is a link of its own.
  A link whose target does not exist yet closes the place it points at.
- **A job's folders keep their settings files read-only.** In each folder a job may write, an existing
  `.dir-locals.el`, `.dir-locals-2.el` and `.drgnx/` are pinned read-only: the job can neither change nor replace
  them. One that does not exist is not pinned (the job may create it), and one that is a link is pinned where it
  points when that is inside the job's folders. Only those three, at the top of each folder.
- **The reduced tier cannot pin.** Without a mount namespace (the reduced tier on Linux), pins do not hold;
  `ratatoskr sandbox check` and the doctor say so. There, as for a new file, [workspace trust](#workspace-trust)
  guards them: a folder's settings code runs only after you review it.

## Agents and your CLI's login folder

An agent's CLI needs its login folder (`~/.claude`, `~/.codex` or `~/.gemini`), and your own CLI, outside any sandbox,
uses the same folder: its settings and their hooks, commands, skills, plugins, `CLAUDE.md`, and also the keys of your
Claude Code's daemon and live sessions, your prompt history and every project's transcripts. So a session sees only
the parts of its own CLI's login folder that the CLI uses (never another CLI's, never the folder itself), and writes
only some of them:

| CLI | Readable only | Writable |
|---|---|---|
| Claude Code | `settings.json`, `CLAUDE.md`, `agents/`, `commands/`, `skills/`, `plugins/`, `output-styles/`, `keybindings.json` | `.credentials.json` (the token, refreshed in place), `todos/`, and `projects/<the session's folder>/` (its transcript) |
| Codex | `config.toml`, `AGENTS.md`, `prompts/`, `skills/`, `rules/` | `auth.json`, `log/`, and a `sessions/` of its own |
| Gemini CLI | `google_accounts.json`, `settings.json`, `GEMINI.md`, `commands/`, `extensions/` | `oauth_creds.json`, and a `tmp/` of its own |

A missing writable folder is made first; a file that does not exist is not made (a login that keeps its token
elsewhere, such as the macOS keychain, has none). One of the readable files that is a link, into your dotfiles say,
is read where it really is. Everything else (`hooks/`, `shell-snapshots/`, which Claude Code's Bash tool sources,
Claude Code's `daemon/` and `sessions/` with their keys, `history.jsonl`, the other projects' folders) cannot be
read, written or added to.

A chat in your project runs in the folder your own Claude Code uses there, so its `projects/` folder would be yours:
your transcripts and the project's auto memory. On the full tier the chat gets an empty folder of its own (in its
scratch folder) in that place, and sees nothing of yours; on the reduced tier and on macOS it gets none, and Claude Code
keeps no transcript of that chat. Codex's `sessions/` and Gemini's `tmp/` hold every session of that CLI, yours too, so
no session gets yours: on the full tier each gets an empty folder of its own (in its scratch folder) in that place,
which keeps what it records while that folder lasts; on the reduced tier and on macOS it gets none, so Codex and
Gemini CLI there cannot keep or resume a session of their own (if the CLI cannot start without one, use the full
tier).

## Secrets in the store

An agent's write to the store that looks like a credential is refused ("looks like a secret; do not store
credentials"): a private key block, an AWS key id, a key with a known prefix (`sk-`, `ghp_`, `gho_`, `github_pat_`,
`glpat-`, `xoxb-` and the like), `password=…`-style assignments (`password`, `passwd`, `secret`, `token`, `api_key`
with a value of 8 or more characters), and long random-looking strings. Commit ids, paths, URLs and dates pass.

## Removing something for good

The store keeps every version of what is written into it. When a secret or a personal text got in by mistake,
**excise** it: only you can, and the reason you give is kept, never the text.

- Excising a task, note or other entry replaces its title, text and data (or the fields you name) with
  `[excised <n>]` in every version it ever had, in the search index, in its embedding, in the stored replies and
  notes of the changes that wrote it, linked it or quoted it, and in the notices and cards that quoted it. Excising one change does the
  same for what that change wrote. The history still shows that something changed, and who changed it.
- Then the store file is compacted, so the old bytes leave the file and its write-ahead log. If a drgnx editor still
  has the store open for reading, the log cannot be emptied yet: you are told so, and you can run the clean-up again
  after closing it.
- A **revert honours the lock**: it restores only what the agent could have written itself. The protected paths (`.git`,
  the provider's configuration folders, `.envrc`, `mise.toml`) and the credential patterns are never restored, a link is
  restored as a link and never followed, and the restore of a sandboxed agent's tree runs inside its sandbox. A checkpoint
  can therefore never widen a sandbox. `history.db` is a privacy door like the store: the personal-notes deny-list applies to it.
- **Copies outside the store** are listed, not changed silently: the dated backups and the pre-upgrade copies
  (`backup/work-pre7-*.db`, `work.db.schema5`, and the `work.db.schema7-*` files a rollback set aside) that still
  hold the text, which you can have deleted; exports, which are
  made again; and session transcripts holding the text, which can be rewritten without it.
- A value shorter than 12 characters is not searched for in those copies, since it would match unrelated text.

## When something you trust is held back

A checker that stays silent, or a shorthand that does not apply: look for **Restricted Mode** in the status bar, and trust
the folder if you trust its files. A remote name refused by TRAMP because of an unusual user name: open it with a
plain `user@host` (an ssh config `Host` alias works for anything ssh accepts).

## The permissions matrix

Every action an agent takes is checked against a matrix: rows are things an agent may do (start agents, spend,
edit code, commit, push, change settings), columns are its role (manager, worker, chat), its agent and its
provider. Each cell is Allow, Ask or Never, sometimes with a limit. Three presets ship: Cautious, Balanced and
Autonomous. Your own cells, a project's and a plan's refine the preset; where several columns apply the most
restrictive wins, and a more specific column never widens. `unsandboxed` and `user.private` are never allowed.
Three rows are about the agent's own browser, which runs inside its sandbox ([agent-browser.md](agent-browser.md)):

- **`browser`**: the session gets a browser of its own, which can reach only the agent's local servers. Cautious
  asks; Balanced allows it for managers and workers and asks for chats; Autonomous allows it.
- **`browser.web`**: that browser may open any public site (HTTPS and plain HTTP, ports 80 and 443). Only
  Autonomous allows it; the other presets ask.
- **`plugin.abilities`**: an approved plugin's tools (its abilities) are offered to the session and may run. Never
  hides them; Ask shows a card with the tool and its arguments for every call.
- **`browser.private`**: that browser may reach a private address you name (your LAN, your tailnet, this computer).
  It asks in every preset, Autonomous included, and an Allow you write for it still asks: no setting turns this
  card off.

A session's project and plan are those of the task it works on (a plan run's, or the task it was started with).
A chat started in a project (the Agents panel, Review Branch) sees the project read-only (a linked worktree's
repository too, so it can run `git log` and `git diff`) and writes only a scratch folder of its own; with `chat.project-read` set to Never for it, such a start is refused (start the chat without a
project).

- **`chat.project-edit`** (pair mode): a chat in your project may edit your own checkout, live, through the editor
  that has the file open. Cautious never; Balanced asks, which here means the Pair toggle is yours to turn on;
  Autonomous allows it, so chats start paired. It replaces the chat's `code.edit`, which stays Never: the chat's own
  edit tools and commands still cannot write the checkout. The hub's door also needs `chat.project-read`, and it
  never writes `.git/`, the agents' own configuration (`.claude`, `.codex`, `.gemini`, `.envrc`, `mise.toml`), a CI
  or build file (`.github/`, `Makefile*`, `build.rs`, `*.sh`: `code.ci-config` is Never for chats), a credential
  file, or anything outside the checkout, links resolved. Every file the hub serves a chat (its `read_file`, an ACP
  `fs/read_text_file`) skips the same credential files the sandbox hides.

- **`huddles`**: when two agents' work clashes (their changes will conflict when they merge, or their decisions
  contradict) the hub may open a huddle: each states its position, at most twice, and you decide. Balanced and
  Autonomous allow it; Cautious asks first (a card, nothing prompts). A reply reaches the other agent quoted, as that
  agent's text, never as an instruction, and no reply answers a card; an agreement is a card for you, never a
  recorded decision. A clash against a decision never opens one.

- **Ask** puts one card in front of you showing what the hub itself knows (the command, the paths, the diff's
  hash), never the agent's own description. The same question open twice is one card. An agent's permission request
  waits under that card's id: answering the request settles the card, and settling the card in the Work cockpit
  answers the request. Before the agent goes on the hub checks again: if the matrix has since become Never for it,
  it is refused whatever you answered.
- **Away:** when you are away the matrix can switch to a stricter (or looser) preset on its own; it applies from the
  next action.
- **Managers** may hand a worker less than they have, never more. A worker a manager started may do only what all
  three allow: its own cells (every layer above, for its role, agent and provider: your Never for its provider binds
  it too), what the manager handed it, and the manager's own cells as they are at that moment, so tightening the
  manager reaches the workers it already started. The grants are recorded before the worker starts, and are kept
  across a hub restart and when the worker is moved to another model (narrowed again for the new model's columns); a
  worker whose grants are gone gets nothing. A manager's own Ask card shows the call it is about (the tool and its
  arguments), and your answer counts for that call only.
- A project's or a plan's override (its `matrix` field) counts only when you wrote that field; an agent's write of
  it is ignored, and so is an agent's write of another field of the same plan for the matter of who wrote the
  override.
- **How a tool call is read.** The hub maps an agent's tool call to a row by its kind and a plain reading of its
  command: a `read` or `search` is `code.read`, a `fetch` is `network`, a command containing `git push` (to `main`
  or `master`: `push.main`) or `git commit` is that row, anything else is `code.edit`. A push written another way
  (`git -C . push`, an alias, a script) counts as `code.edit`. That coarse map is acceptable because the rows that
  matter outside the worktree are enforced elsewhere: the sandbox (Gleipnir) decides what network an agent has, and
  a push needs credentials the sandbox does not give the agent.
- **What network a sandboxed agent has.** None of its own: its only way out is its session's proxy, which tunnels
  HTTPS (`CONNECT`) to an exact list of `host:port` and nothing else. The list is:
  - the provider hosts of the agent's profile (for a profile on the gateway, each provider its chain names);
  - its CLI's own hosts: Claude's API and `platform.claude.com` (where its login token is refreshed); Codex's API,
    `chatgpt.com` and `auth.openai.com`; Gemini's API, `oauth2.googleapis.com` and `cloudcode-pa.googleapis.com`;
  - the hosts you list under `agents-net-hosts` for the session's network tier (`provider-only`; none by default).

  A plugin's HTTP is not the agent's: it reaches only the hosts its approved manifest names, and where the session's
  network is not open, only those you also list on the `plugin` tier of `agents-net-hosts`
  ([plugins.md](plugins.md)). Anything else is refused. Each refused host is recorded once per session as an event (`proxy-denied`, with the
  host), so you can see what an agent tried to reach; it never raises a card. Optional traffic a CLI sends
  (telemetry, error reports, update checks) is refused the same way; Claude is told not to send it
  (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, [agents.md](agents.md#jobs-and-your-claude-settings)). To let a session reach another host, add it to
  the `provider-only` list of `agents-net-hosts`.
- **Container jobs** (`job.container`) run only images you put on `agents-container-images`, pinned by digest. The hub
  builds the `podman run` line itself: no capabilities, no new privileges, a read-only root, the worktree as the only
  mount, no network of its own (a granted network is the job's allow-list proxy, reached only through its relay sidecar `drgnx-px` on the job's own loopback, nothing else; the list is the setting `agents-net-hosts`, by default the package hosts of crates.io, npm and PyPI, port 443), limits from `agents-job-memory` and `agents-job-cpus`. An agent chooses an image name and a
  command and nothing else (`exec/start` refuses any other field); the command is never read as a podman option. The hub pulls the image itself (600 s at most) and names the container `drgnx-job-<id>`, removing leftovers at start.
- **Networked container jobs** need rootless podman 5.0 or newer and nothing else: no podman network, no bridge, no
  pasta. The job shares its sidecar's network namespace, which has a loopback only and no route; the namespace belongs
  to the sidecar's user namespace (the sidecar runs as `nobody` there), so even root inside the job can't change it.
  Each job has its own sidecar, so two jobs can't see each other. The job can't take the relay's port: `drgnx-px`
  listens without `SO_REUSEPORT` as another user. A job is refused, before anything starts, with one of:
  "Networked container jobs need podman 5.0 or newer; this host has `*version*`." (on a Mac: "… inside podman
  machine; this machine runs `*version*`: update its OS image (`podman machine os upgrade`), or remove and re-create
  the machine."), "drgnx runs containers rootless; this podman is rootful.", "drgnx could not build its proxy
  image: …", "The job's proxy did not start within 10 s: …", or the memory and cgroup reasons any container job has. A running one ends `infra` with its reason as the log's last line
  (`drgnx: infra: proxy: …`): the sidecar exited (its code and what it means; 137 is most likely its memory limit),
  broke the channel's rules, or stopped reading; the hub stopped; or a hub that restarted found it running. A port of
  your computer is reached only as `host.drgnx.internal:PORT` and only after you allow it on a card (the next section);
  the hub's own ports never, whatever you allow. On SELinux hosts nothing is to be set up: the job's network needs no
  socket rule, and a runner job's key socket is created as a container's (`container_t`; `drgnx doctor`'s
  `key sockets:` line checks that this host's policy allows it). The shape was checked on Fedora 45 with SELinux
  enforcing; Ubuntu (AppArmor) is CI's lane; RHEL and openSUSE are expected to work, unverified. **macOS** (podman machine) is expected to work, unverified: the relay crosses the
  machine over podman's SSH connection (about 170 MB/s into the job and 87 MB/s back on the test VM, before gvproxy),
  a machine restart ends running networked jobs, the machine's SSH and REST ports are never opened by a grant, and
  gvproxy forwards ports that containers publish to the Mac's loopback, so a container you run yourself with `-p`
  is reachable from the Mac as usual.
- **Keyed jobs** (`job.keys`): a job naming keys may name only those on the project's `drgnx-runners-job-keys` list,
  and an agent's needs the matrix's `job.keys` too (ask under Cautious and Balanced; allowed for the manager and workers
  under Autonomous; never for chat). The values reach the job on a runner of yours in memory only, are never sent to a
  `shared` runner, and are masked in the log the hub keeps ([runners.md](runners.md#keys)).

### Answering a browser card

A card of the three browser rows lists its own answers, and your answer becomes a grant the hub checks before it asks
again, so the agent's retry goes through without a second card.

- **The card** is written from what the hub saw, never from the agent's words:
  - `browser`: "*session* wants a browser in its sandbox";
  - `browser.web`: "*session* wants to open web sites (first: *host:port*)", with the line "The agent's browser and its
    own tools could then reach any public site; pages can send what the agent gives them";
  - `browser.private`: "*session* wants to open *target* → *address* (*class*)", where the class is your LAN, your
    network (IPv6), link-local, your tailnet (CGNAT) or this computer, with the line "Any page the agent opens could
    then send requests to it, including ones that change things";
  - `browser.private` for a container job: "Job *id* wants your port *PORT* (`host.drgnx.internal:PORT`)", with the
    lines "Allowing it opens the port for this session: its browser and its other jobs too. Revoking it refuses the
    next connection. Connections already open stay until they end; end the job to cut them." Its answers are the
    browser's scopes, never a range or every private address.
- **The answers:**
  - **Allow once**: for `agents-browser-once-window` (10 minutes by default), and only what the card named (the web
    card's first host, the private card's target);
  - **Allow for this session**, and **Allow for this plan** when the session works for a plan (every session of the
    plan then has it);
  - for a LAN or IPv6 ULA address written as a number, also its **/24** (IPv4) or **/64** (IPv6) on the same port,
    and **every LAN and ULA address** on any port, each for the session or the plan. A name (`printer.local`), this
    computer (`host.drgnx.internal:PORT`), your tailnet and link-local addresses are offered one target at a time;
  - **Refuse**: nothing is granted, and the session's browser is not asked about again.
- **Where you answer:** the card's notice runs **Agents: Answer Permission Card** (also in the palette, where it asks
  which card when several wait). It shows the card's line and its answers; the one you pick goes to the hub, which
  settles the card and writes the grant. Nothing ever asks you from the background. In the Work cockpit, Allow is
  the narrowest answer (once) and Deny is Refuse.
- A grant is yours alone (an agent cannot write one), and switching the row to Never ends it at once.

### Hooks never widen

Your hook rules and your plugins' hooks ([plugins.md](plugins.md#rules-and-hooks)) look at a step after the matrix
has, and they can only narrow what it says. A hook's `allow` means "no objection": a step the matrix asks about is
still asked about, and a step it refuses is refused before any hook runs. A hook can turn Allow or Ask into a refusal,
never the other way. A hook that fails (it times out, crashes, is busy, or answers something its manifest did not
declare) refuses the step too, unless it is declared advisory, and then its failure is a note under the step. Only
at the hub's own tools may a hook change a call, only for the tools it names, and the tool checks the changed
arguments, against its schema and its own matrix checks, before anything runs; at the permission seam a change is a
failure ([plugins.md](plugins.md#before-a-tool-call)).

## Checking it

`drgnx doctor` has a `security` line. It names the Emacs security issues that apply to your version (CVE numbers)
and says OK while all of the guards above are on, or WARN naming the ones that are off. If it warns, restart drgnx:
its startup turns the guards on.

On Nidhogg the list is shorter: Nidhogg 31.1-nidhogg.4 and later carry the fixes for the TRAMP user-name issue
(CVE-2026-108976) and the Flymake issue (CVE-2026-96442), so the doctor no longer names them. The shorthands issue
(CVE-2026-96269) stays listed as partly fixed: its full fix is only in Emacs 32.

## What each provider obeys

drgnx starts every agent's CLI with a lock: options that make it ask drgnx for each permission instead of deciding
alone. At the start of a session drgnx checks that the lock holds; if it does not, the session is ended, never run as
if it were locked.

| Provider | The lock | Where it comes from |
|---|---|---|
| Claude Code | policy-tier settings (no bypass or auto mode, only drgnx's hooks and permission rules, plus the deny and ask rules of your Claude settings), strict MCP config, Claude's own sandbox off (drgnx's is the boundary), mode `default` | `_meta.claudeCode.options` of the adapter |
| Codex (codex-acp 2.x) | its environment, never argv (codex-acp ignores `-c`, and a profile's own `-c` is dropped): `INITIAL_AGENT_MODE=read-only`, codex-acp's mode whose every turn has approvals `on-request` by you (never a reviewer model) in Codex's read-only sandbox, inside drgnx's, so a write or a network call asks; `CODEX_CONFIG` with the same policy, `web_search = "disabled"`, every MCP server's tools `prompt` and the worktree `untrusted`; inside the sandbox, read-only, `/etc/codex/requirements.toml` (only that policy and sandbox, only managed hooks: a turn in another mode is refused by Codex) and `/etc/codex/config.toml` (a managed PreToolUse hook calling drgnx's `before_tool`). codex-acp takes a mode it does not know for its auto-review mode without a word, so the session is refused unless codex-acp says it is in `read-only` | codex-acp 2.5.0 `src/index.ts` (the environment it reads), `src/AgentMode.ts` (its four modes and the fallback), `src/CodexAcpClient.ts` (each turn's policy); Codex 0.165 `config/src/config_requirements.rs`, `config/src/loader/mod.rs` (the requirements and System layers), `hooks/src/engine/discovery.rs` (`mcp_tool` hooks, managed only) |
| Gemini CLI | `--approval-mode default` (any `--yolo`, `-y` or `--approval-mode` in the profile's command is dropped); with a hook subscribed, `--admin-policy` with a file drgnx writes: the subscribed kinds' tools and every MCP tool `ask_user`, the tools of subagents and the bundled docs (which never ask) refused. Gemini drops a policy file whose rules miss a field its loader needs and runs on without it, saying so only on its stderr at exit, so drgnx checks the file as that loader does before it starts Gemini: a file that would not load is never passed, and a session with a hook subscribed is refused. drgnx's Gemini CLI build also says, when it starts, whether the file loaded and how many of its rules Gemini holds: a session it reports as not loaded, or holding fewer rules than drgnx wrote, is refused. It counts the rules by the file's name, so drgnx names the file after a hash of its content (`drgnx-<hash>.toml`), a name no system policy file has by accident | [Gemini CLI reference](https://www.mintlify.com/google-gemini/gemini-cli/reference/cli-options); Gemini CLI 0.67 `packages/core/src/policy/config.ts` (the admin tier, and that a `.toml` in `/etc/gemini-cli/policies` makes it ignore `--admin-policy`), `toml-loader.ts` (the fields every rule needs, and that a file without them is dropped) |
| Kimi Code | `KIMI_CODE_HOME` is a folder of drgnx's own (`agents/kimi-code` in its state folder): its `config.toml`, bound read-only, has `default_permission_mode = "manual"`, `default_plan_mode = false` and an ask rule for each subscribed kind's tools (which beats Kimi's own approval of reads); `--yolo`, `-y`, `--yes`, `--auto-approve` and `--auto` are dropped; mode `default`. Plan mode is refused, because Kimi writes its plan file there without asking the hooks: a session that reports it at the start is not started, and one that switches to it is ended. A switch Kimi's engine makes without telling the client (none does today) would go unseen | Kimi Code `docs/en/configuration/config-files.md`, `env-vars.md`, `agent-core-v2` `permissionPolicyService.ts` |
| DeepSeek Harness | `DSH_HOME` is a folder of drgnx's own (`agents/dsh`); `--patch` with an overlay, a list of loader patches: the `sandbox-policy` mode `danger-full-access` and, apart from it, the `approval` policy `ask` (the shipped bundle ties that mode to a policy that refuses every ask), and drgnx's ask plugin inserted for the subscribed kinds. Not enforced until that plugin ships with drgnx's DeepSeek Harness build | DeepSeek Harness 0.2.2 `apps/cli/src/args.ts`, `packages/boot/app-boot/src/index.ts` (the overlay format), `packages/bundle/base/cordis.patch.yml`, `packages/core/tools/src/pipeline.ts` |

Gateway profiles of Claude (a profile with `:ai`) in the worker and manager roles also get
`CLAUDE_CODE_PROMPT_CACHE_TTL=1h`; chats keep five minutes. Gateway profiles of Kimi Code and DeepSeek Harness get
the gateway's address and the session's own token in the variables they read (`KIMI_MODEL_BASE_URL`,
`KIMI_MODEL_API_KEY`; `DEEPSEEK_BASE_URL`, `DEEPSEEK_API_KEY`), never a provider key.

In every worktree `.claude`, `.codex`, `.gemini`, `.envrc`, `.git/hooks` and `mise.toml` are read-only for the agent.
Of Kimi Code's and DeepSeek Harness's own folders the agent may write only its login (`credentials`), sessions, logs
and locks.

The files a lock binds at a fixed path (Codex's `/etc/codex` pair, Kimi Code's `config.toml`) need the sandbox's
full tier: on another, such a session is not started. The files drgnx writes for one session (Gemini's admin policy,
DeepSeek's overlay) live in that session's own folder, which its agent reads and never writes.

**A hook never misses a step it subscribes to.** When a before-tool hook or rule subscribes to a kind, the lock makes
the agent ask about it, or the agent's own hook calls drgnx (Codex's managed hook, which fails open on a timeout:
its approvals still fail closed), or the tool is withheld (Codex's hosted web search, Gemini's subagents). An agent
that would still run such a step unseen (one with no lock, a Gemini whose system policy shadows drgnx's) is not
started, and the refusal names the kinds and why. The session's details list which kinds are hooked, and how.

An agent drgnx has no lock for (set `:provider claude|codex|gemini|kimi|deepseek` in its profile, or name the CLI in
its command) is shown as "not enforced": it is not started as a worker under the Cautious and Balanced presets. Codex
counts as enforced only once its lock has passed the sandboxed-launch and laundering checks, and DeepSeek Harness
once drgnx's ask plugin ships with its fork; until then they are "not enforced".
