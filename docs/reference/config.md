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

## face.eld

Folder: state. Format: 1. Read: when it changes. On a mistake: its last good copy, else the defaults.

What the face remembers between runs: the title bar's variant, its GTK theme (read by bin/drgnx) and the start page's dismissal.

| Key | Type | Required | What |
| --- | --- | --- | --- |
| `:variant` | symbol or null | no | The title bar's variant: dark, light or nil |
| `:gtk-theme` | string or null | no | The GTK theme the launchers start GTK with |
| `:start-dismissed` | boolean or null | no | t once "Don't show this again" was chosen |

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

## large-files.eld

Folder: config. Format: 1. Read: when it changes. On a mistake: its last good copy, else the defaults.

When a file is large: the size that asks (or opens in chunks, lean or raw), the size above which chunks is the default, and a chunk's size.

| Key | Type | Required | What |
| --- | --- | --- | --- |
| `:ask-above` | null or a size in MiB above 0 | no | Above this size (MiB) a file opens in chunks, lean or raw (a command asks once); nil: never |
| `:chunks-above` | a size in MiB above 0 | no | Above this size (MiB) the question's default is chunks, else lean |
| `:chunk-size` | a size in MiB above 0 | no | How much of the file (MiB) a chunk holds |

## large-files.eld

Folder: project. Format: 1. Read: when it changes. On a mistake: refused.

A project's lower large-file sizes: it can only lower yours, never raise them or set the chunk size.

| Key | Type | Required | What |
| --- | --- | --- | --- |
| `:ask-above` | null or a size in MiB above 0 | no | Lowers your :ask-above for the project (a higher value or nil is ignored) |
| `:chunks-above` | a size in MiB above 0 | no | Lowers your :chunks-above for the project (a higher value is ignored) |

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

## drgnx.lock.eld

Folder: config. Format: 1. Read: when it changes. On a mistake: drgnx sync stops until it is fixed; nothing is changed.

Every installed package, pinned by drgnx sync.  A mistake in it stops the sync, and drgnx never replaces the file.

| Key | Type | Required | What |
| --- | --- | --- | --- |
| `:packages` | list of (NAME :version :archive :kind :file :sha256 :size :requires :summary) | yes | What is installed: one entry per package |
| `:from-shipped` | boolean | no | Copied from the lock drgnx ships; the first sync completes it |

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

## onboarding.eld

Folder: state. Format: 1. Read: when it changes. On a mistake: its last good copy, else the defaults.

Which onboarding steps ran and how they ended, so a run resumes where it stopped.

| Key | Type | Required | What |
| --- | --- | --- | --- |
| `* :status` | symbol | no | How the step ended: ok, info, warn or fail |
| `* :message` | string or null | no | What it said |
| `* :time` | string or null | no | When it ended |

## packages.eld

Folder: config. Format: 1. Read: at start. On a mistake: drgnx sync stops until it is fixed; nothing is changed.

The packages you want besides the modules', their sources and archives.  Read at each drgnx sync; a mistake in it stops the sync (nothing is applied or replaced).

| Key | Type | Required | What |
| --- | --- | --- | --- |
| `:packages` | list of symbol | no | Packages to install besides the modules' |
| `:git` | alist of symbol to plist | no | Packages no archive has, installed from their repository |
| `:git * :url` | string | no | Where the repository is |
| `:git * :rev` | string | no | A branch, a tag or a commit |
| `:git * :commit` | string | no | The commit to install |
| `:git * :lisp-dir` | string | no | Where the package's files are |
| `:archives` | alist of string to string | no | The archives: name and URL or directory |
| `:archive-priorities` | alist of string to number | no | Which archive wins: name and priority |

## projects.eld

Folder: config. Format: 1. Read: when it changes. On a mistake: its last good copy, else the defaults.

The projects drgnx knows: the work tracker and search scan their roots.

| Key | Type | Required | What |
| --- | --- | --- | --- |
| `:projects` | list of plist | no | The projects Import Projects added |
| `:projects * :name` | string | no | The project's name |
| `:projects * :root` | home-path | yes | Its folder |
| `:projects * :url` | string or null | no | Its remote's URL |

## search.eld

Folder: project. Format: 1. Read: when it changes. On a mistake: refused.

Narrows what a project's semantic search indexes: only these globs, not these, or off.

| Key | Type | Required | What |
| --- | --- | --- | --- |
| `:include` | list of string | no |  |
| `:exclude` | list of string | no |  |
| `:off` | boolean | no |  |

## session.eld

Folder: config. Format: 1. Read: at start. On a mistake: its last good copy, else the defaults.

Whether drgnx keeps running when its last window closes (read at every start).

| Key | Type | Required | What |
| --- | --- | --- | --- |
| `:keep-running` | boolean | no | Keep drgnx running when its last window closes |

