# Settings

The settings drgnx declares with `drgnx-defsetting`, and the keys that say where each may be set, whether a workspace may set it, how it merges and whether an agent may change it. Generated from the declarations: do not edit; see docs/develop/core.md for how to regenerate it, and [Declaring a setting](../develop/settings.md) for the keys.

## drgnx-keys-bind

Command id -> keys, entries (ID KEY… [:map MAP]) that win over every layer.  Keyboard Shortcuts writes them.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat sexp)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-keys--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of (pred drgnx-keys--bind-entry-p "(ID KEY… [:map MAP])"))` |

## drgnx-keys-layers

The key-profile stack: (PROFILE SCOPE…), later layers win.  Settings: Keyboard Profile sets it.

| Key | Value |
| --- | --- |
| Default | `((vscode app editing window))` |
| Type | `(repeat (cons symbol (repeat symbol)))` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-keys--layers-settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(pred drgnx-keys--layers-ok-p "a profile stack such as ((emacs editing) (vscode app window))")` |

## drgnx-keys-mac-option

What the left Option key does on a Mac with VS Code's keys: `characters' (it types @ # { [) or `meta'; nil: Meta.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(choice (const :tag "Meta" nil) (const characters) (const meta))` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-keys--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or null (pred drgnx-keys--mac-option-p "characters or meta"))` |

## drgnx-keys-pending-layers

A stack waiting for its modal engine to be installed (drgnx sync); nil when none waits.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat (cons symbol (repeat symbol)))` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-keys--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or null (pred drgnx-keys--layers-ok-p "a profile stack such as ((vim app editing window))"))` |

## drgnx-keys-tty-fallback

Chord -> another Alt key for it, in a legacy terminal: (("C-S-p" . "M-Z")).

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(alist :key-type string :value-type string)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-keys--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `any` |

## drgnx-keys-unbind

Command ids that get no key, whatever the layers say.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat symbol)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-keys--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of symbol)` |

## drgnx-large-files-ask-above

Above this size (MiB) a file opens in chunks, lean or raw (a command asks once); nil: never.  Read when a file opens.

| Key | Value |
| --- | --- |
| Default | `50` |
| Type | `(choice (const :tag "Never" nil) number)` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `lower-only` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `grantable` |
| `:schema` | `(or null (pred drgnx-large-files--mib-p "a size in MiB above 0"))` |

## drgnx-large-files-chunk-size

How much of the file (MiB) a chunk holds.  Read when a file opens.

| Key | Value |
| --- | --- |
| Default | `1` |
| Type | `number` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `grantable` |
| `:schema` | `(pred drgnx-large-files--mib-p "a size in MiB above 0")` |

## drgnx-large-files-chunks-above

Above this size (MiB) the question's default is chunks, else lean.  Read when a file opens.

| Key | Value |
| --- | --- |
| Default | `500` |
| Type | `number` |
| `:scope` | `global` |
| `:workspace` | `data` |
| `:merge` | `lower-only` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `grantable` |
| `:schema` | `(pred drgnx-large-files--mib-p "a size in MiB above 0")` |

## drgnx-look-theme

The colour theme ui/look loads at start (Color Theme picks it); nil: the theme Emacs starts with.  A change
switches the theme at once while the module runs.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(choice (const :tag "Emacs's own" nil) symbol)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-look--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(or null symbol)` |

## drgnx-modules-disabled

Modules you turned off.  Preferences: Modules writes this; a change turns the module off or on at once.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat symbol)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-modules--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of symbol)` |

## drgnx-modules-enabled

Modules that are off until chosen, chosen on.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat symbol)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-modules--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of symbol)` |

## drgnx-modules-external

External modules, each (:name NAME :path DIR :features (FEATURE…)); each is checked when it loads.
They run code from DIR, so no workspace may set this and no agent may change it.

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(repeat sexp)` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-modules--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(list-of any)` |

## drgnx-modules-flags

Module flags: ((MODULE FLAG…)…).

| Key | Value |
| --- | --- |
| Default | `nil` |
| Type | `(alist :key-type symbol :value-type (repeat symbol))` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | `drgnx-modules--settings-apply` |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | `(alist symbol (list-of symbol))` |

## drgnx-session-keep-running

Non-nil: drgnx keeps running in the background when its last window closes (reopening is instant).
nil: closing the last window quits drgnx (after asking to save changed files).  Set it with
Preferences: Keep drgnx Running in the Background, which remembers it in settings.el.  Read when a window closes.

| Key | Value |
| --- | --- |
| Default | `t` |
| Type | `boolean` |
| `:scope` | `global` |
| `:workspace` | `never` |
| `:merge` | `replace` |
| `:on-error` | `last-good` |
| `:apply` | - |
| `:runtime` | - |
| `:agents` | `never` |
| `:schema` | - |

