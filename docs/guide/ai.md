# AI

drgnx has one registry of model providers for every AI feature — ghost-text completion, inline edit, chat, embeddings
and agents. It knows OpenRouter and the common local runners without configuration, and each feature uses a *role*:
a chain of providers and models tried in order, so a feature keeps working when one provider is down.

## Providers

| Id | Provider | Address (default) |
|---|---|---|
| `openrouter` | OpenRouter | `https://openrouter.ai/api/v1` (key: `OPENROUTER_API_KEY` or auth-source) |
| `moonshot` | Moonshot (Kimi) | `https://api.moonshot.ai/anthropic` (key: `MOONSHOT_API_KEY` or auth-source) |
| `deepseek` | DeepSeek | `https://api.deepseek.com/anthropic` (key: `DEEPSEEK_API_KEY` or auth-source) |
| `ollama` | Ollama | `http://127.0.0.1:11434` |
| `lmstudio` | LM Studio | `http://127.0.0.1:1234/v1` |
| `llamacpp` | llama.cpp server | `http://127.0.0.1:8012` (start it with `--port 8012`: its 8080 is TEI's) |
| `vllm` | vLLM | `http://127.0.0.1:8000/v1` |
| `jan` | Jan | `http://127.0.0.1:1337/v1` |
| `localai` | LocalAI | `http://127.0.0.1:8090/v1` |
| `koboldcpp` | KoboldCpp | `http://127.0.0.1:5001/v1` |
| `tabbyapi` | TabbyAPI, text-generation-webui | `http://127.0.0.1:5000/v1` |
| `gpt4all` | GPT4All | `http://127.0.0.1:4891/v1` |
| `lemonade` | Lemonade | `http://127.0.0.1:13305/api/v1` |
| `llamafile` | llamafile | `http://127.0.0.1:8081/v1` (start it with `--port 8081`) |
| `tei` | Text Embeddings Inference | `http://127.0.0.1:8080` |
| `anthropic` | Anthropic API (agents only, through the gateway) | `https://api.anthropic.com/v1` (key: `ANTHROPIC_API_KEY` or auth-source) |

The local presets use `127.0.0.1`, not `localhost`: `localhost` resolves to `::1` first, and a container's IPv6 port
forward can accept the connection and then reset it, which curl-based clients do not retry on IPv4.

Add your own, or move one, in `ai.eld` in drgnx's config directory (`~/.config/drgnx/ai.eld`); a project's `.drgnx/ai.eld` at its
root can choose **roles** (and wins), among the providers the presets and your `ai.eld` define — never a provider
or a key variable of its own, so a cloned repository cannot send your code, or a key, somewhere you did not choose:

```elisp
(:version 1
 :providers ((box :name "GPU box" :kind openai :url "http://box:9000/v1" :key-env "BOX_KEY" :caps (chat fim)))
 :roles ((chat (box . "qwen2.5-coder:32b") (openrouter . "openrouter/auto"))
         (complete (ollama . "qwen2.5-coder:1.5b"))))
```

`:kind` is `openai` (any OpenAI-compatible server), `ollama`, `llamacpp` or `tei` (`anthropic` too, for a provider of
the agent gateway that speaks Anthropic's API; see below).

**An `ai.eld` with a mistake** (a parenthesis missing, a `:kind` that is none of these, a `:price` that is not
`(IN . OUT)`, a model that is not a string): your last good providers and roles are used, and drgnx says once where the
mistake is (`Open Config File…` takes you there). Choosing a provider or model never overwrites a file it cannot read,
and says so; an `ai.eld` written by a newer drgnx is used when it fits, but is not changed. Choosing changes only the
role you chose: your comments, your providers and any key of your own stay as they are.

A project's `.drgnx/ai.eld` is read with a limit of 64 KiB. A bigger file, or one with a mistake, is not used at all
(there is no last good copy of a project's file: its roles are left out and drgnx says why once), and drgnx never writes it.

A project's role may still name a provider that is not on this machine (OpenRouter, say): every pause in that
repository would then make a paid call and send your code away. So the first time you run a command that uses AI
there (Edit with AI, Ask the Codebase, Generate Commit Message, the semantic search commands), drgnx asks once whether that project may use the remote provider, and keeps
your answer for that project root in `ai-project-routes.eld` in drgnx's state directory (delete the entry to be asked
again; it is asked again only if the project later names a remote provider you were not asked about; a file that
does not read is copied aside, as `ai-project-routes.eld.bak-…`, before your answer is written). The project is
its real directory, so one repository reached through two paths is asked once, and a link re-pointed at another
repository does not inherit the answer. A provider whose address has no host counts as remote. Choose Provider/Model
changes your own `ai.eld` chain, never a copy of the project's. Until you say
yes, and after a no, the project's remote steps are left out of its chains: ghost text, the search index and every
other automatic path use only the local steps (or your own `ai.eld`'s chain when none is left). Nothing is ever
asked from a timer, hook or in batch.

## Roles

| Role | Used by | Default chain |
|---|---|---|
| `complete` | ghost-text completion (fill in the middle) | Ollama `qwen2.5-coder:1.5b` (fits next to TEI on a 6 GB GPU) |
| `edit` | inline edit | OpenRouter `openrouter/auto`, then Ollama `qwen2.5-coder:7b` |
| `chat` | chat (gptel), Ask the Codebase | as `edit` |
| `embed` | semantic search (embeddings: a vector per text, scaled to length 1) | TEI |
| `agent` | Claude Code on OpenRouter, through the agent gateway ([agents.md](agents.md)) | OpenRouter, with the model the agent asks for |

A provider in your `ai.eld` may carry `:price (IN . OUT)` — US dollars per million input and output tokens — so the
agent gateway can count what agents spend when the provider does not report a cost; `:messages t` says it serves
Anthropic's Messages API, so the gateway can carry agents to it (OpenRouter, Ollama, Anthropic, Moonshot and DeepSeek do).

With nothing set up, onboarding's AI step sets up Ollama, LM Studio or OpenRouter for you and fills these roles with
models sized to the machine ([onboarding.md](onboarding.md#setting-ai-up)): `drgnx-ai-default-models` gives Inline
Completion `qwen2.5-coder:1.5b` and Edit and Chat `qwen2.5-coder:7b` when both fit in the room models get (the GPU's
free memory; on an Apple silicon Mac two thirds of the RAM, which it shares with the GPU, while an Intel Mac counts
as having none — `drgnx-ai-vram`), else `:3b`, else the 1.5B too; LM Studio serves the same GGUF models as `qwen2.5-coder-…-instruct` (`drgnx-ai-lmstudio-models`).

The `embed` role works like the others: its chain is tried in order and the next provider answers when one is down, has
no key, or sends something that is not a vector per text. TEI needs no model (`(tei)`); for Ollama, llama.cpp and the
OpenAI-compatible runners the chain names one, for example `(ollama . "nomic-embed-text")`. Providers that can embed
list `embed` in their `:caps`. Vectors come back scaled to length 1, even when the numbers are so small that their
squares underflow; an empty request asks nobody. For Lisp callers, `drgnx-ai-embed-sync` takes `:timeout nil` (no
limit), ends its request on C-g, and reports who answered through `:on-answer` (`drgnx-ai-embed-last-info` is only a
mirror of the last answer).

## Ghost text and Tab

In code buffers (module `tools/ai`), a short pause (0.3 s) asks the `complete` role to fill in the middle: the model
sees up to 2,000 characters before point and 1,000 after. Its answer shows after point, dimmed (face
`drgnx-ai-ghost`, from your theme's `shadow`). It shows only if nothing changed and point did not move since the
question. Anything else you do clears it and drops the question in flight. If the buffer changes under a showing
suggestion with no command of yours (a revert, an agent's edit), Tab and the accept commands drop it instead of
inserting it into changed text; Tab then indents as usual.

| Key | While a suggestion shows | Otherwise |
|---|---|---|
| `Tab` | accept it all | see below |
| `C-<right>` (Mac: ⌘→) | accept its next word | the usual (`right-word`; Mac: line end) |
| `C-g` | dismiss it | the usual (cancel) |

Escape is not bound while a suggestion shows, so `Esc x` still works as `M-x`; any other key or command also drops
the suggestion.

**Under Vim keys** (evil), suggestions come only while you type: in insert state (and Emacs state); moving around in
normal or visual state never asks. One `Esc` in insert state does both — it drops the suggestion and goes back to normal
state, leaving the buffer as it was; `Tab` in insert state accepts it and you stay in insert state. A modal engine
says when not to ask through `drgnx-ai-ghost-inhibit-functions` (an abnormal hook: any function that returns non-nil
stops the question); with VS Code or Emacs keys it is empty and ghost text asks as it always did.

**Accept Suggestion Line** and **Toggle AI Completion** are in the palette. With no `complete` provider running,
nothing is asked, and drgnx posts the notice "No AI provider for completion" (source `ai`; Enter on it runs
**Choose AI Provider/Model…**). It stays in the Notices list until a provider answers, then goes by itself; drgnx
looks for running providers again at most once a minute. Turning
`tools/ai` off (Preferences: Modules) takes ghost text out of the buffers that have it, with any showing suggestion.

**Tab is one key for everything.** It does the first of these that applies:
1. accept the suggestion;
2. the completion popup's own Tab (corfu, company, built-in completion);
3. the next snippet field (yasnippet, tempel);
4. cycle an org or outline heading;
5. what Tab does in that mode without ghost text (a mode's own Tab — cperl, octave, ESS), else indent.

## Inline edit

**Edit with AI…** rewrites the selected region, or the defun at point when nothing is selected, as you say. Keys:
VS Code `C-k C-e` (⌘K ⌘E on a Mac), Emacs `C-c e`, Vim `SPC a e`; never `C-i`, which is Tab in a terminal. It asks the `edit` role.
Under Vim keys the selection is the visual one, as Vim's operators take it: `V` and `j` select whole lines, and the
edit covers both lines with the last newline; in visual (`v`) the characters under both ends are in it. A block
(`C-v`) selects the lines it touches, whole: an edit rewrites one stretch of text, never a rectangle. An empty
selection counts as none (the defun at point).
The answer opens as a diff against the buffer as it is now (a code fence the model adds is dropped), and nothing
changes until you decide:

- `C-c C-a` applies the hunk at point (to a copy; the diff stays on screen), `n`/`p` move between hunks;
- `C-c C-c` (Done) puts the hunks you applied into the buffer's region;
- `C-c C-k` (Reject), or closing the diff, drops it all.

Each edit gets its own diff buffer (`*AI edit: NAME*`, then `*AI edit: NAME*<2>`), so a second edit of the same buffer
never takes over the first one's review.

Edits you make elsewhere in the buffer meanwhile stay — text typed right before or after the region too. If the
region itself changed while the model answered, no review opens; if it changed since, Done refuses rather than
overwrite it.

## Ask the Codebase

**Ask the Codebase…** (Vim `SPC a q`; the palette) answers a question about the project from its own code:
1. Up to six of the question's words (four letters or more) are searched for with ripgrep (find and grep, any POSIX or BSD one, without it), never in dot files or directories (`.env`, `.git`) — what
   is found goes to a model. Without ripgrep (which also honours `.gitignore`), the folders `node_modules`, `vendor`,
   `target`, `dist`, `build` and `__pycache__` are skipped by name. A search that runs longer than 10 s
   (`drgnx-ai-search-timeout`) is cut off and the question goes on without code; lines are cut to 500 characters.
2. The five files that hold the most of them each give a snippet around their first match.
3. The snippets and the question go to the `chat` role.

When the project has a [semantic search index](search.md), the five best chunks for the question by meaning join the
snippets (same index and embedding model as Semantic Search; without a reachable embedding provider they are the keyword
hits of the index, and a project without an index gets the word search only). The excerpts of the two kinds go to the model together.

The answer opens in `*AI answer*` with the files it drew on as links. Other ways to find code join through
`drgnx-ai-retrievers` (each a function of the question, the project root and a callback); the semantic search adds
its own when the search module is on. `drgnx-ai-ask-request` is the same search and question without the buffer —
onboarding tests Ask the Codebase with it over a small temporary project.

## Stopping a request

**Stop AI Request** (the palette; no key by default) cancels the Edit with AI and Ask the Codebase requests in flight:
the model's process ends and nothing opens when it would have answered. With nothing in flight it says so. It does not
touch ghost text (any key you type drops that question) or a job an agent is running ([agents.md](agents.md)).

## Choosing a provider and model

**Choose AI Provider/Model…** first looks for what runs here now (a second at most), then asks for a role and a
provider. Only providers that can be asked are offered: local
ones the probe found running, remote ones with their key. Then it asks for a model, offering the ones the provider
reported. It makes one test call. Only if that answers is the choice kept: at the head of the role's chain in
`ai.eld`, with the previous providers behind it as fallbacks. A key is never written there.

## Chat (gptel)

With module `extra/llm` (gptel installed), gptel's backend comes from the `chat` role: its first provider that can
be asked. drgnx sets it up again whenever a probe finishes. A backend you set yourself is never replaced, and neither is
gptel's default ChatGPT backend once you have set your own `gptel-api-key`. gptel asks for the key only when it
sends.

## Detection, fallback and the doctor

drgnx asks the local providers whether they run — every address at once, one second each, in the background,
never holding up Emacs — and remembers which answered and which models they have (a probe updates the providers it
asked; what it knows of the others stays). The answers are also saved in `ai-detected.eld` in the state directory
(for the doctor), under a lock, adding to what another Emacs saved; a probe that finds the file locked skips the
save and the next one writes it, and a file with a mistake is copied aside (`ai-detected.eld.bak-…`) first. It probes once Emacs is first idle, again in onboarding and Choose, and while no `complete` provider runs. Something
answering on TEI's
port is taken for TEI only when its `/info` says so (LocalAI can answer there too).

The local runner onboarding set up (`drgnx-ai-managed`, kept in `ai-local.eld` in the state directory, changed under
a lock with its other keys left alone) is started
again when it is down: `drgnx-ai-ensure-local` asks its address in the background and, when nothing answers and no
drgnx job runs it, starts it as a drgnx job with one message ("Starting Ollama…"). It runs a moment after the first
window opens (never at daemon start) and when a request finds nothing listening there (`drgnx-ai-refused-functions`),
never in batch, never asking anything. A look that finds the server down starts it at most once a minute; a look
that finds it up counts for nothing, so a refusal a moment later still restarts it. The refusal is heard even in a
process that never loaded the probe (a search, a script).

A request walks its role's chain: a provider without its key or the capability (chat, fill in the middle) is
skipped; no answer, an error status (429, 5xx …) or an answer that does not parse moves on to the next. The feature
hears which provider answered, or every reason none did — so with OpenRouter unreachable, a local runner answers.

`drgnx doctor` checks `ai`: which providers were found (a key is looked for in the environment only — the doctor
never opens auth-source), and whether the GPU has room for the completion model next to what already holds it
(TEI, say): a 1.5B model at 4 bits needs about 1.6 GB.

## Where requests go

Every request to a provider **with a key** (OpenRouter, Anthropic, … — chat, completion, edits, commit messages,
embeddings, the search index, gptel) goes to the hub's gateway on this machine, `http://127.0.0.1:PORT/p/PROVIDER/…`,
with a token of your editor's own (`Authorization: Bearer …`). The hub adds the provider's key and passes the answer
back, streaming included; the editor's requests carry no key. A provider **without** a key (a local Ollama, llama.cpp,
TEI) is asked directly, as before. The fallback along a role's list is still the editor's: the gateway passes one
provider through per request.

- **Commands start the hub.** Edit with AI, Ask, Choose, the commit message, `drgnx onboard`, `drgnx search` and the
  other terminal commands make sure the hub runs and wait for it (`drgnx hub start` does the same by hand). Ghost text
  and other background work never wait: with no token yet the request fails with "drgnx hub is starting; try again"
  (the provider is skipped, the next one in the list is asked) and the hub's start is asked for in the background.
- **A provider is usable when the hub holds its key** (`drgnx hub status`, the hub's `gateway/keys-held`, kept up to
  date as keys come and go) or it needs none. A key your environment has is handed to the hub when your editor
  connects; a key found by a command you run (Keychain, keyring, `.authinfo`) is handed over by that command, once.
- **The search indexer** is a background job: it is given the gateway's address only, asks the hub for a token of its
  own, and goes with it when it ends. It never has a key in its environment.
- **gptel** gets a backend at the gateway (`/p/PROVIDER/chat/completions`) once the hub gave your editor its token.

## Keys

drgnx reads a key when a feature needs it, from where you already keep it: the provider's environment variable
(`OPENROUTER_API_KEY` for OpenRouter), else auth-source (`~/.authinfo`, `~/.authinfo.gpg`, the macOS Keychain, your
Linux keyring) with the provider's host — e.g. `machine openrouter.ai password sk-or-…`.

drgnx writes a key in exactly one place: the macOS Keychain, or the Linux keyring (Secret Service; needs
`secret-tool`, from `libsecret-tools` or `libsecret`). Only when you ask — in onboarding (choose OpenRouter in the AI
step, in the drgnx app: the key is read with `read-passwd`, never shown) or a command you run —
never into a drgnx file, and never on a command line (it goes to the store on stdin). A Keychain that is locked
or denies access gives an error saying so; the environment variable always works instead. drgnx never sends a key to
a model. On a Mac the key is an internet password for `openrouter.ai`, account `drgnx`, in your login keychain
(stored with `/usr/bin/security`, never a `security` found elsewhere on your path, and read back with the same
program for that account, so another password for the host cannot answer in its place). `security` reports success
whatever it made of the key, so drgnx compares what it reads back with what you gave, without showing either; when
they differ, or the Keychain does not answer, drgnx deletes the item and says so. A key with a line break or a NUL
character is refused before anything is stored (API keys never contain them).
Keychain Access shows it, and `security delete-internet-password -s openrouter.ai -a drgnx` removes it. On Linux the
keyring is looked at only when Emacs has D-Bus support, a session bus can be reached and a Secret Service answers on
it (an SSH login, WSL or a container often has a bus but no keyring daemon), so such a machine gets no "invalid
backend spec" noise in `*Messages*`. Loading the Secret Service client pings it once, only from a command you ran.

Sources that may ask for something — files Emacs decrypts with GnuPG (`.gpg`, its backups `.gpg~` and `.gpg.~N~`,
and `.plist` files, which auth-source reads as a plstore), the Keychain, the keyring, and any `auth-sources` entry
that is a plist — are only read from commands you run in
the drgnx app or an interactive Emacs (Edit with AI, Ask the Codebase, Choose, AI: Load Keys); a batch Emacs never
opens the Keychain or keyring (a `.gpg` file it is asked to read can still want its passphrase on standard input).
Entries of `auth-sources` that are plists, such as `(:source (:secrets "Login"))` or
`(:source (:macos-keychain-internet default))`, count as the stores they name. And
even with `auth-sources` set to nil, those commands still read the system's own store (the Keychain on a Mac, the
keyring on Linux), because that is where onboarding puts the key. Background features
(ghost text, the hub, agents) never read them — they use the environment or a key the hub was handed earlier. So that
they have it after a restart, `drgnx open` (which the drgnx app runs) has drgnx read the keys of the providers your
roles name once per start, a moment after its window shows (macOS may ask whether Emacs may use the Keychain), and
hand them to the hub. Once the hub has taken a key your Emacs forgets it (its memory and auth-source's cache): only
the hub holds it, and every feature reaches the provider through the hub's gateway. Until a hub runs, a key found
waits in memory and goes when your Emacs connects. A key in your environment stays there
([security.md](security.md#where-your-keys-live)).
**AI: Load Keys** does the same at any time — needed when drgnx was started some other way; ghost text posts a notice
("No key for … loaded: AI: Load Keys reads it from the Keychain") when its provider's key is not loaded. The `drgnx` command-line
tool, which runs in batch Emacs, never reads the Keychain or keyring: set `OPENROUTER_API_KEY` for it. In short: the
key you gave onboarding works in the drgnx app; in a terminal (`drgnx onboard`, `drgnx search`, …) use the
environment variable. The one exception is `drgnx secrets` (below), which you run on a terminal to carry your keys
to another machine.

### Keys on a second machine

`drgnx secrets export` puts the keys your keyring holds for the providers that take one (OpenRouter, Anthropic, any
provider of yours with a `:key-env`) into `secrets.age` in your config dir, encrypted with
[age](https://age-encryption.org) and a passphrase you choose. Copy the config dir to the other machine (or clone
it), then run `drgnx secrets import` there and type the passphrase: each key goes into that machine's Keychain or
keyring, where drgnx finds it as above. A key in the environment only is not exported — store it first
(onboarding's AI step) or set the variable on the other machine too. The palette has both as **Portability: Export
Keys** and **Portability: Import Keys** (a terminal opens, where age asks for the passphrase). The details — what the
file holds, age keys instead of a passphrase, a machine without a keyring — are in
[second-machine.md](second-machine.md#your-provider-keys-secretsage).

## Agents

Agent profiles can take their provider from the registry; the key is resolved when the agent starts:

- **claude** — Claude Code through `claude-agent-acp` with its own login (a subscription, kept in Claude Code's own
  files, or the Anthropic key or Bedrock/Vertex switches in your environment). drgnx only launches it; it never reads
  its login. Other vendors' keys in Emacs's environment are not passed on (below).
- **claude (OpenRouter)** — Claude Code on OpenRouter: `ANTHROPIC_BASE_URL=https://openrouter.ai/api`,
  `ANTHROPIC_AUTH_TOKEN` = your OpenRouter key, `ANTHROPIC_API_KEY` empty.
- **claude (Ollama)** — Claude Code on a local Ollama model.
- **claude (Kimi)** and **claude (DeepSeek)** — Claude Code on Kimi or DeepSeek through the vendor's own
  Anthropic-compatible API (`:ai claude-moonshot`, `claude-deepseek`): `ANTHROPIC_BASE_URL` = the vendor's address,
  `ANTHROPIC_AUTH_TOKEN` = your `MOONSHOT_API_KEY` or `DEEPSEEK_API_KEY` (or auth-source for `api.moonshot.ai` or
  `api.deepseek.com`), `ANTHROPIC_API_KEY` empty. The vendor bills you per token for an API key; Kimi's coding
  membership is a subscription on a different endpoint, which these profiles do not use.
- **claude (Kimi via OpenRouter)** and **claude (DeepSeek via OpenRouter)** — the same models through OpenRouter
  (`:ai claude-openrouter` with a `:model`), billed by OpenRouter with your OpenRouter key.

A profile's `:model` (any profile with an `:ai`) also sets `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`,
`ANTHROPIC_DEFAULT_OPUS_MODEL` and `CLAUDE_CODE_SUBAGENT_MODEL` to that name, and `ANTHROPIC_DEFAULT_HAIKU_MODEL`
(Claude Code's small, background model) to the profile's `:small-model`, else to the `:model`. A `claude-moonshot` or
`claude-deepseek` profile without a `:model` does not start. The built-in names are data in
`drgnx-agents-builtin-profiles`: copy a profile into `agents.eld` to use another model. Nothing about the route is
written to `~/.claude/settings.json`: two profiles share Claude Code's configuration directory and differ only in
these variables, so a model in that file's `env` would override them (the Claude page in Agent Settings notes it).

Moonshot and DeepSeek carry no `:price`, so the gateway cannot price their answers and counts their spend as zero (a
job's budget does not stop them). Give the provider a `:price (IN . OUT)` in your `ai.eld` to count it.

**Agents do not inherit other vendors' keys.** Whatever Emacs's environment holds, an agent gets only the variables
of its own route (its provider key or the gateway's token, the model names). The others -- every vendor key and route
variable, `drgnx-agents-scrubbed-env` -- are unset for it, so a Kimi agent never sees your DeepSeek or OpenRouter key,
and a Claude agent never sees `OPENAI_API_KEY`. A profile with no `:ai` route is your own login, and keeps its own
agent's names from the environment (`drgnx-agents-own-env`, found from the profile's command): Claude Code
`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, the model names, `CLAUDE_CODE_OAUTH_TOKEN` and the
Bedrock and Vertex switches (the `AWS_*` and `GOOGLE_APPLICATION_CREDENTIALS` they need are never scrubbed); Codex
`OPENAI_API_KEY` and `OPENAI_BASE_URL`; Gemini `GEMINI_API_KEY` and `GOOGLE_API_KEY`. A profile with a route (Kimi,
DeepSeek, OpenRouter, Ollama) gets none of these, only its route's. To pass any other variable on, remove it from
`drgnx-agents-scrubbed-env` (Customize), or set it in the profile's `:env`.

In `agents.eld`, `:ai claude-openrouter`, `claude-ollama`, `claude-moonshot` or `claude-deepseek` gives any profile
that environment. Durable jobs get the keys they need in their environment too — never in a command line or a file (under systemd, the value travels in
`systemd-run`'s own environment).

### OpenRouter restrictions

OpenRouter chooses, among the providers that serve a model, one for each request. The `:openrouter` setting in
`agents.eld` narrows that choice for every OpenRouter route of every agent:

```elisp
(:openrouter (:only ("anthropic" "google-vertex") :ignore ("azure") :data-collection deny :zdr t))
```

- `:only` -- the provider slugs OpenRouter may use (nothing else serves the request); `:ignore` -- slugs it must not use;
- `:data-collection deny` -- only providers that keep no data (`allow` leaves the choice to your OpenRouter account
  settings: it is not sent);
- `:zdr t` -- zero-data-retention endpoints only.

Each key is optional; an empty value (`()`, `nil`) is no restriction. Restrictions fail closed: a value that is not a
slug list, `deny`/`allow` or `t`/`nil`, a key other than these four, or an `agents.eld` that does not read (a parenthesis
short) is never read as "no restriction". An agent with an OpenRouter route does not start, and its session says which
key is wrong; the Agent Settings page shows *unreadable* with the reason. The hub refuses such a registration too. The gateway puts them into the
request's top-level `provider` object (`only`, `ignore`, `data_collection`, `zdr`), which OpenRouter's Anthropic-compatible
`/api/v1/messages` accepts (its `ProviderPreferences`). They apply to Messages requests (`/v1/messages`, also with a query
such as `?beta=true`) sent to the provider with the id `openrouter` only: other providers' requests are unchanged, and so
are the token count (`/v1/messages/count_tokens`) and the model list, which route to no provider. A custom provider that
points at openrouter.ai under another id is not covered.

If the agent's own request already has a `provider` object, the two are merged and the stricter value wins: `only` is
the intersection of the two lists (when both set one; none in common is a 400 `invalid_request_error` from the gateway,
nothing is sent), `ignore` the union, `data_collection` `deny` if either says so, `zdr` on if either says so. The agent's
other keys (`order`, `sort`, `require_parameters`, `allow_fallbacks`, …) pass through. If restrictions are set and the
body cannot be read as a JSON object (or its `provider` is not one), the gateway answers 400 `invalid_request_error`
and sends nothing: a request that might not honour them never goes out. Without restrictions the body goes as it was.

An agent with an OpenRouter route always goes through the gateway, since only the hub holds the key
([agents.md](agents.md#the-hub-and-the-gateway)); `drgnx-agents-use-gateway` changes nothing for it. When the hub cannot be had (it
does not start, its socket refuses), the agent does not start, with restrictions or without; its session says why
(with restrictions set: that they apply through the hub only; start the hub). The hub's answer to a registration
lists the restrictions it kept. A hub started before drgnx had restrictions keeps none, so the agent does not start
and the session says to restart the hub (`drgnx hub stop`, then start an agent). Without restrictions, the agents are
bound by your OpenRouter account settings alone ([openrouter.ai/settings/privacy](https://openrouter.ai/settings/privacy)). A model
that no allowed provider serves fails with OpenRouter's own error, which the agent shows.
Set it from Agent Settings (`r`, **OpenRouter Restrictions…**, [agent-settings.md](agent-settings.md#routes)); comments
and the other settings in `agents.eld` stay.

## Tests

- `test/unit/ai-test.el` (providers, roles, keys, agent environments), `test/unit/ai-client-test.el` (requests,
  fallback with every reason, cancel, probes, the doctor's check), `test/unit/ai-ghost-test.el` (ghost text, accept,
  the Tab arbiter), `test/unit/ai-edit-test.el` (the review, hunk by hunk), `test/unit/modal-ai-test.el` (ghost text
  and Edit with AI's selection under Vim keys, with the real evil in its own Emacs, and unchanged without them), `test/unit/ai-ask-test.el` (Ask, Choose,
  gptel), `test/unit/ai-onboard-test.el` (the onboarding step; setting up Ollama, LM Studio and OpenRouter with fake
  `brew`, `ollama`, `lms`, `sysctl` and `security`; the room on a Mac and the models for it).
- `test/unit/ai-keys-test.el` (binary) — after AI: Load Keys hands a key to the hub the editor holds none (its key
  table, auth-source's cache, gptel, what it sends), the environment is left as it was, and chat, completion,
  embeddings and the commit message still work through the hub.
- `test/unit/agents-profiles-test.el` — Kimi and DeepSeek profiles: gateway environments (a token, never a key), the
  OpenRouter model chain, the missing-key message, routes on the Claude page, the runner unsetting the keys.
- `test/unit/gateway-openrouter-test.el` -- the restrictions in the request body, other providers untouched, the setting
  in `agents.eld` with its comments, the Routes line and the Change command.
- `test/live/drgnx-ai-test.el` — in a GUI session: typing, the suggestion as ghost text, Tab takes it; an inline
  edit's second hunk applied with keys, Done puts only that one in the buffer.
- `drgnx test --perf` — the `typing-with-ghost` workload holds keystroke p95 under 16 ms with ghost text on.

The mock model (`test/fixtures/mock-llm.el`) is a batch Emacs serving scripted answers on a port; no test reaches
a real provider (the unit runner unsets the provider keys).
