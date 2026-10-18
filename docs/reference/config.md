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

