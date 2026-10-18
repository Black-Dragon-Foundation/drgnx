# Config files

Every file drgnx keeps in its config and state folders, and the project files it reads. Generated from the definitions: do not edit; see docs/develop/core.md for how to regenerate it, and [Files](../guide/files.md) for what a mistake in one does.

## agents.eld

Folder: config. Format: 1. Read: when it changes. On a mistake: the defaults.

Agent profiles, the MCP servers agents get, OpenRouter restrictions and job routes.

| Key | Type | Required | What |
| --- | --- | --- | --- |
| `:profiles` | alist of string to plist | no | Your agent profiles; the built-in ones need none |
| `:profiles * :command` | list of string | yes | The program and its arguments |
| `:profiles * :env` | list of string | no | NAME=value pairs added to its environment |
| `:profiles * :mode` | one of queue, steer, interrupt | no | What a message to a busy agent does |
| `:profiles * :ai` | symbol | no | The provider environment it gets |
| `:profiles * :model` | string | no | The model it asks for |
| `:profiles * :doc` | string | no | One line |
| `:default` | string | no | The profile New Agent Session… offers |
| `:mcp` | list of one of coordination, search | no | The MCP servers agents get |
| `:openrouter` | not an OpenRouter restriction (:only :ignore :data-collection :zdr) | no | Which providers OpenRouter may use |
| `:routes` | alist of symbol to string or list of string | no | Which profiles do each job role: a list of names, or one name |

## keys.eld

Folder: config. Format: 1. Read: at start. On a mistake: its last good copy, else the defaults.

Your key bindings: the profile stack, entries that win over it, keys taken away.

| Key | Type | Required | What |
| --- | --- | --- | --- |
| `:layers` | a profile stack such as ((emacs editing) (vscode app window)) | no | The key profile stack, later layers winning; omitted: the default (VS Code) |
| `:pending-layers` | a profile stack such as ((vim app editing window)) | no | A stack waiting for its modal engine to be installed (drgnx sync) |
| `:bind` | list of (ID KEY… [:map MAP]) | no | Command id → keys, winning over every layer |
| `:unbind` | list of symbol | no | Command ids that get no key |
| `:mac-option` | characters or meta | no | What the left Option key does on a Mac with VS Code's keys |
| `:tty-fallback` | any | no | Chord → another Alt key for it, in a legacy terminal: (("C-S-p" . "M-Z")) |
## ai.eld

Folder: config. Format: 1. Read: when it changes. On a mistake: its last good copy, else the defaults.

Your AI providers and each role's chain of providers and models; never a key.

| Key | Type | Required | What |
| --- | --- | --- | --- |
| `:providers` | alist of symbol to plist | no | Providers of your own, or presets moved (an entry replaces the preset with its id) |
| `:providers * :name` | string | no | What the provider is called |
| `:providers * :kind` | one of openai, ollama, llamacpp, tei, anthropic | no | How to talk to it |
| `:providers * :url` | string | no | Its address |
| `:providers * :key-env` | string | no | The environment variable holding its key (never the key) |
| `:providers * :caps` | list of symbol | no | What it does: chat, fim, embed |
| `:providers * :price` | (IN . OUT) dollars per million tokens | no | What the agent gateway counts its spend by |
| `:providers * :messages` | boolean | no | Whether it serves Anthropic's Messages API |
| `:roles` | alist of symbol to alist of symbol to string or null | no | Each role's chain of (PROVIDER . MODEL), tried in order |

## ai.eld

Folder: project. Format: 1. Read: when it changes. On a mistake: refused.

A project's roles, among the providers you have: never a provider or a key of its own.

| Key | Type | Required | What |
| --- | --- | --- | --- |
| `:roles` | alist of symbol to alist of symbol to string or null | no | The project's roles (a remote provider in a chain is asked about once) |

## layouts.eld

Folder: config. Format: 1. Read: when it changes. On a mistake: its last good copy, else the defaults.

Your own layouts; the built-in ones are not stored.

| Key | Type | Required | What |
| --- | --- | --- | --- |
| `* :left` | symbol or null | no | The left dock's view |
| `* :right` | symbol or null | no | The right area's tab |
| `* :panel` | symbol or null | no | The panel's tab |
| `* :editor` | symbol | no | The editor area's shape |
| `* :windows` | any | no | The editor area's window state |
| `* :px` | plist | no | Sizes in pixels |
| `* :px :left` | natnum or null | no |  |
| `* :px :panel` | natnum or null | no |  |
| `* :px :right` | natnum or null | no |  |

## modules.eld

Folder: config. Format: 2. Read: at start. On a mistake: its last good copy, else the defaults.

Which modules run, their flags, external modules.

| Key | Type | Required | What |
| --- | --- | --- | --- |
| `:disabled` | list of symbol | no | Modules you turned off |
| `:enabled` | list of symbol | no | Modules that are off until chosen, chosen on |
| `:flags` | alist of symbol to list of symbol | no | Module flags |
| `:external` | list of any | no | External modules (each is checked when it loads) |
| `:theme` | symbol | no | The colour theme onboarding chose |

## projects.eld

Folder: config. Format: 1. Read: when it changes. On a mistake: its last good copy, else the defaults.

The projects drgnx knows: the work tracker and search scan their roots.

| Key | Type | Required | What |
| --- | --- | --- | --- |
| `:projects` | list of plist | no | The projects Import Projects added |
| `:projects * :name` | string | no | The project's name |
| `:projects * :root` | home-path | yes | Its folder |
| `:projects * :url` | string or null | no | Its remote's URL |

