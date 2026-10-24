# Trusted folders and the "Restricted Mode" mark

A file you open can ask Emacs to do things: run a syntax checker that executes the file, rename symbols as it is
read, or make Emacs reach out to another machine. drgnx lets files from folders you trust do all of that, and holds
back what is risky in files from any other folder — like VS Code's Workspace Trust, but without a dialog. Nothing
here ever asks you a question; you trust a folder when you choose to.

## What is trusted

- drgnx's own folders: its checkout, its config dir (`~/.config/drgnx/`) and its packages dir, and the Lisp
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
  again on every reconnect and keeps it in memory only. The search indexer job asks for a token of its own, so it goes
  with the job. A background request that has no token yet fails with "drgnx hub is starting; try again" and never
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
- **Your own additions:** `~/.config/drgnx/personal-notes-deny.json` lists more files, folders and globs to keep
  out, anywhere, as firmly as the built-in ones:

  ```json
  {"version": 1, "entries": [{"kind": "folder", "path": "~/Documents/diary"},
                             {"kind": "glob", "path": "~/docs/*.private"}]}
  ```

  A glob has `*` and `?` in its last part only. The built-in list cannot be shortened. If this file cannot be read
  or has a mistake, the built-in list still applies and no personal file is opened (below) until you fix it.
- **Opening one file:** `~/.config/drgnx/personal-notes-allow.json` names single files under `~/org` that the store
  may read, for example a reading list a plan refers to: `{"version": 1, "paths": ["~/org/reading.org"]}`. Only
  existing regular files count: a folder, a glob or a path outside `~/org` is ignored. A file that is always kept out
  stays out even if listed.
- Keep both files `0600`. An opt-in file that others may write is ignored entirely. `drgnx doctor` lists every entry
  it ignored and why.
- **The work scan's own door.** The scan that reads your plans (`drgnx work scan`) applies the same rules in Lisp
  (`core/drgnx-deny.el`, held to the same table of cases as the hub's check) before it sends anything: it skips
  files the rules deny, and drops a plan's `**Spec:**` that names one, even through a link. The hub checks again
  (defence in depth). The code indexer asks the same check with the opt-ins ignored: a file you opened for the store
  is not opened for the code index. A scan root inside `~/org` (or `~/org` itself) is refused the same way, opt-ins
  ignored, with "the work tracker never reads a project inside ~/org (personal notes)": nothing under it is read and
  git never runs there (nor in a repository inside `~/org` that a project contains); the other roots are scanned.
- **The entity embedder skips them too.** When the hub makes the store's search vectors (a `tei` embedding provider
  in your providers), an entity whose source, path or id the rules deny is never sent, even one stored before you
  added its folder to your deny list. A text you excise (or a file you revoke) while the provider is answering gets
  no vector of what was sent.
- **The code search index never reads `~/org`.** `drgnx search index` refuses a project whose root is inside
  `~/org` (or reaches it through a link) with "the search index never reads ~/org (personal notes)", before it
  reads anything there. For a project that contains `~/org` (your home folder as a git repository), every file whose
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

A job agent's sandbox (once jobs run in it, phase 6) keeps your settings files out of the agent's reach, so an agent
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
- **Copies outside the store** are listed, not changed silently: the dated backups and the pre-upgrade copies
  (`backup/work-pre7-*.db`, `work.db.schema5`, and the `work.db.schema7-*` files a rollback set aside) that still
  hold the text, which you can have deleted; exports, which are
  made again; and session transcripts holding the text, which can be rewritten without it.
- A value shorter than 12 characters is not searched for in those copies, since it would match unrelated text.

## When something you trust is held back

A checker that stays silent, or a shorthand that does not apply: look for **Restricted Mode** in the status bar, and trust
the folder if you trust its files. A remote name refused by TRAMP because of an unusual user name: open it with a
plain `user@host` (an ssh config `Host` alias works for anything ssh accepts).

## Checking it

`drgnx doctor` has a `security` line. It names the Emacs security issues that apply to your version (CVE numbers)
and says OK while all of the guards above are on, or WARN naming the ones that are off. If it warns, restart drgnx:
its startup turns the guards on.

## What each provider obeys

drgnx starts every agent's CLI with a lock: options that make it ask drgnx for each permission instead of deciding
alone. At the start of a session drgnx checks that the lock holds; if it does not, the session is ended, never run as
if it were locked.

| Provider | The lock | Where it comes from |
|---|---|---|
| Claude Code | policy-tier settings (no bypass or auto mode, only drgnx's hooks and permission rules, plus the deny and ask rules of your Claude settings), strict MCP config, Claude's own sandbox off (drgnx's is the boundary), mode `default` | `_meta.claudeCode.options` of the adapter |
| Codex | `-c approval_policy={ granular = {…} }` with every category (`sandbox_approval`, `rules`, `mcp_elicitations`, `request_permissions`, `skill_approval`) asked of drgnx, `approvals_reviewer = "user"`, `sandbox_mode = "danger-full-access"` (Gleipnir is the one sandbox) | [Codex configuration reference](https://developers.openai.com/codex/config-reference); codex-acp takes `-c` overrides ([source](https://github.com/zed-industries/codex-acp/blob/main/src/lib.rs)) |
| Gemini CLI | `--approval-mode default`; any `--yolo`, `-y` or `--approval-mode` in the profile's command is dropped | [Gemini CLI reference](https://www.mintlify.com/google-gemini/gemini-cli/reference/cli-options) |

Gateway profiles of Claude (a profile with `:ai`) in the worker and manager roles also get
`CLAUDE_CODE_PROMPT_CACHE_TTL=1h`; chats keep five minutes.

In every worktree `.claude`, `.codex`, `.gemini`, `.envrc`, `.git/hooks` and `mise.toml` are read-only for the agent.

An agent drgnx has no lock for (set `:provider claude|codex|gemini` in its profile, or name the CLI in its command)
is shown as "not enforced": it is not started as a worker under the Cautious and Balanced presets. Codex counts as
enforced only once its lock has passed the sandboxed-launch and laundering checks; until then it is "not enforced".
