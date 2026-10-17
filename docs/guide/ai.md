# AI

drgnx has one registry of model providers for every AI feature — ghost-text completion, inline edit, chat, embeddings
and agents. It knows OpenRouter and the common local runners without configuration, and each feature uses a *role*:
a chain of providers and models tried in order, so a feature keeps working when one provider is down.

## Providers

| Id | Provider | Address (default) |
|---|---|---|
| `openrouter` | OpenRouter | `https://openrouter.ai/api/v1` (key: `OPENROUTER_API_KEY` or auth-source) |
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

`:kind` is `openai` (any OpenAI-compatible server), `ollama`, `llamacpp` or `tei`.

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
Anthropic's Messages API, so the gateway can carry agents to it (OpenRouter, Ollama and Anthropic do).

The `embed` role works like the others: its chain is tried in order and the next provider answers when one is down, has
no key, or sends something that is not a vector per text. TEI needs no model (`(tei)`); for Ollama, llama.cpp and the
OpenAI-compatible runners the chain names one, for example `(ollama . "nomic-embed-text")`. Providers that can embed
list `embed` in their `:caps`.

## Ghost text and Tab

In code buffers (module `tools/ai`), a short pause (0.3 s) asks the `complete` role to fill in the middle: the model
sees up to 2,000 characters before point and 1,000 after. Its answer shows after point, dimmed (face
`drgnx-ai-ghost`, from your theme's `shadow`). It shows only if nothing changed and point did not move since the
question. Anything else you do clears it and drops the question in flight.

| Key | While a suggestion shows | Otherwise |
|---|---|---|
| `Tab` | accept it all | see below |
| `C-<right>` | accept its next word | the usual (`right-word`) |
| `Escape` | dismiss it | the usual |

**Accept Suggestion Line** and **Toggle AI Completion** are in the palette. With no `complete` provider running,
nothing is asked, and drgnx says so once; it looks for running providers again at most once a minute.

**Tab is one key for everything.** It does the first of these that applies:
1. accept the suggestion;
2. the completion popup's own Tab (corfu, company, built-in completion);
3. the next snippet field (yasnippet, tempel);
4. cycle an org or outline heading;
5. what Tab does in that mode without ghost text (a mode's own Tab — cperl, octave, ESS), else indent.

## Inline edit

**Edit with AI…** rewrites the selected region, or the defun at point when nothing is selected, as you say. Keys:
VS Code `C-k C-e`, Emacs `C-c e`, Vim `SPC a e`; never `C-i`, which is Tab in a terminal. It asks the `edit` role.
The answer opens as a diff against the buffer as it is now (a code fence the model adds is dropped), and nothing
changes until you decide:

- `C-c C-a` applies the hunk at point (to a copy; the diff stays on screen), `n`/`p` move between hunks;
- `C-c C-c` (Done) puts the hunks you applied into the buffer's region;
- `C-c C-k` (Reject), or closing the diff, drops it all.

Edits you make elsewhere in the buffer meanwhile stay — text typed right before or after the region too. If the
region itself changed while the model answered, no review opens; if it changed since, Done refuses rather than
overwrite it.

## Ask the Codebase

**Ask the Codebase…** (Vim `SPC a q`; the palette) answers a question about the project from its own code:
1. Up to six of the question's words (four letters or more) are searched for with ripgrep (grep without it), never in dot files or directories (`.env`, `.git`) — what
   is found goes to a model.
2. The five files that hold the most of them each give a snippet around their first match.
3. The snippets and the question go to the `chat` role.

When the project has a [semantic search index](search.md), the five best chunks for the question by meaning join the
snippets (same index and embedding model as Semantic Search; without a reachable embedding provider they are the keyword
hits of the index, and a project without an index gets the word search only). The excerpts of the two kinds go to the model together.

The answer opens in `*AI answer*` with the files it drew on as links. Other ways to find code join through
`drgnx-ai-retrievers` (each a function of the question, the project root and a callback); the semantic search adds
its own when the search module is on.

## Choosing a provider and model

**Choose AI Provider/Model…** first looks for what runs here now (a second at most), then asks for a role and a
provider. Only providers that can be asked are offered: local
ones the probe found running, remote ones with their key. Then it asks for a model, offering the ones the provider
reported. It makes one test call. Only if that answers is the choice kept: at the head of the role's chain in
`ai.eld`, with the previous providers behind it as fallbacks. A key is never written there.

## Chat (gptel)

With module `extra/llm` (gptel installed), gptel's backend comes from the `chat` role: its first provider that can
be asked. drgnx sets it up again whenever a probe finishes. A backend you set yourself is never replaced, and gptel
asks for the key only when it sends.

## Detection, fallback and the doctor

drgnx asks the local providers whether they run — every address at once, one second each, in the background,
never holding up Emacs — and remembers which answered and which models they have (a probe updates the providers it
asked; what it knows of the others stays). It probes once Emacs is first idle, again in onboarding and Choose, and while no `complete` provider runs. Something
answering on TEI's
port is taken for TEI only when its `/info` says so (LocalAI can answer there too).

A request walks its role's chain: a provider without its key or the capability (chat, fill in the middle) is
skipped; no answer, an error status (429, 5xx …) or an answer that does not parse moves on to the next. The feature
hears which provider answered, or every reason none did — so with OpenRouter unreachable, a local runner answers.

`drgnx doctor` checks `ai`: which providers were found (a key is looked for in the environment only — the doctor
never opens auth-source), and whether the GPU has room for the completion model next to what already holds it
(TEI, say): a 1.5B model at 4 bits needs about 1.6 GB.

## Keys

drgnx reads a key when a feature needs it, from where you already keep it: the provider's environment variable
(`OPENROUTER_API_KEY` for OpenRouter), else auth-source (`~/.authinfo`, `~/.authinfo.gpg`, the macOS Keychain, your
Linux keyring) with the provider's host — e.g. `machine openrouter.ai password sk-or-…`.

drgnx writes a key in exactly one place: the macOS Keychain, or the Linux keyring (Secret Service; needs
`secret-tool`, from `libsecret-tools` or `libsecret`). Only when you ask — in onboarding or a command you run —
never into a drgnx file, and never on a command line (it goes to the store on stdin). A Keychain that is locked
or denies access gives an error saying so; the environment variable always works instead. drgnx never sends a key to
a model.

Sources that may ask for something (`.gpg` files, the Keychain, the keyring) are only read from commands you run in
the drgnx app or an interactive Emacs (Edit with AI, Ask the Codebase, Choose); background features (ghost text, the
hub, agents) use the environment or a key read earlier, and the `drgnx` command-line tool, which runs in batch Emacs,
never reads the Keychain or keyring: set `OPENROUTER_API_KEY` for it.

## Agents

Agent profiles can take their provider from the registry; the key is resolved when the agent starts:

- **claude** — Claude Code through `claude-agent-acp` with its own login (subscription or API key). drgnx only
  launches it; it never reads its login.
- **claude (OpenRouter)** — Claude Code on OpenRouter: `ANTHROPIC_BASE_URL=https://openrouter.ai/api`,
  `ANTHROPIC_AUTH_TOKEN` = your OpenRouter key, `ANTHROPIC_API_KEY` empty.
- **claude (Ollama)** — Claude Code on a local Ollama model.

In `agents.eld`, `:ai claude-openrouter` or `:ai claude-ollama` gives any profile that environment. Durable jobs get
the keys they need in their environment too — never in a command line or a file (under systemd, the value travels in
`systemd-run`'s own environment).

## Tests

- `test/unit/ai-test.el` (providers, roles, keys, agent environments), `test/unit/ai-client-test.el` (requests,
  fallback with every reason, cancel, probes, the doctor's check), `test/unit/ai-ghost-test.el` (ghost text, accept,
  the Tab arbiter), `test/unit/ai-edit-test.el` (the review, hunk by hunk), `test/unit/ai-ask-test.el` (Ask, Choose,
  gptel), `test/unit/ai-onboard-test.el` (the onboarding step).
- `test/live/drgnx-ai-test.el` — in a GUI session: typing, the suggestion as ghost text, Tab takes it; an inline
  edit's second hunk applied with keys, Done puts only that one in the buffer.
- `drgnx test --perf` — the `typing-with-ghost` workload holds keystroke p95 under 16 ms with ghost text on.

The mock model (`test/fixtures/mock-llm.el`) is a batch Emacs serving scripted answers on a port; no test reaches
a real provider (the unit runner unsets the provider keys).
