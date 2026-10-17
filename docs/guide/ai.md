# AI

drgnx has one registry of model providers for every AI feature — ghost-text completion, inline edit, chat, embeddings
and agents. It knows OpenRouter and the common local runners without configuration, and each feature uses a *role*:
a chain of providers and models tried in order, so a feature keeps working when one provider is down.

## Providers

| Id | Provider | Address (default) |
|---|---|---|
| `openrouter` | OpenRouter | `https://openrouter.ai/api/v1` (key: `OPENROUTER_API_KEY` or auth-source) |
| `ollama` | Ollama | `http://localhost:11434` |
| `lmstudio` | LM Studio | `http://localhost:1234/v1` |
| `llamacpp` | llama.cpp server | `http://localhost:8012` (start it with `--port 8012`: its 8080 is TEI's) |
| `vllm` | vLLM | `http://localhost:8000/v1` |
| `jan` | Jan | `http://localhost:1337/v1` |
| `localai` | LocalAI | `http://localhost:8090/v1` |
| `koboldcpp` | KoboldCpp | `http://localhost:5001/v1` |
| `tabbyapi` | TabbyAPI, text-generation-webui | `http://localhost:5000/v1` |
| `gpt4all` | GPT4All | `http://localhost:4891/v1` |
| `lemonade` | Lemonade | `http://localhost:13305/api/v1` |
| `llamafile` | llamafile | `http://localhost:8081/v1` (start it with `--port 8081`) |
| `tei` | Text Embeddings Inference | `http://localhost:8080` |

Add your own, or move one, in `ai.eld` in drgnx's config directory (`~/.config/drgnx/ai.eld`); a project can do the
same in `.drgnx/ai.eld` at its root, and wins:

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
| `embed` | semantic search | TEI |

## Keys

drgnx reads a key when a feature needs it, from where you already keep it: the provider's environment variable
(`OPENROUTER_API_KEY` for OpenRouter), else auth-source (`~/.authinfo`, `~/.authinfo.gpg`, your keyring) with the
provider's host — e.g. `machine openrouter.ai password sk-or-…`. drgnx never writes a key anywhere, never puts one
on a command line and never sends one to a model. Sources that may ask for a passphrase (`.gpg` files, keyrings)
are only read from commands you run; background features use the environment or a key read earlier.

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
