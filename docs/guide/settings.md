# Settings

Your settings in one place: `settings.el` in your config dir, the Settings page, and how they meet your own Lisp,
Customize and the packages you use. The contributor side is [docs/develop/settings.md](../develop/settings.md).

This page is being written; each section below comes with the part of drgnx it describes.

## The files

Your settings live in `settings.el` in your config dir ([files.md](files.md)). It is one Lisp form that drgnx reads
as data and never loads:

```elisp
;;; settings.el --- your settings  -*- lexical-binding: t; mode: lisp-data -*-
;; Written by drgnx Settings and by you. Kept sorted; a comment above an entry stays with it.
;; Values are data: write 80 or (a b), not '(a b). Code goes in config.el. drgnx reads this file; never load it.
(drgnx-settings
 :version 1
 (drgnx-agents-default "claude")
 ;; the review profile reads every project
 (drgnx-agents-profiles
  (("review" :command ("claude-agent-acp") :mode queue :model "opus" :doc "Reviews")))
 (eglot-autoshutdown t)
 (fill-column 100)
 (:mode python-ts-mode
  (fill-column 88)))
```

- **Entries** are `(VARIABLE VALUE)`. The value is written as it is and never evaluated: `80`, `"claude"`, `(a b)`.
  A leading `'` or `#'` is accepted and means the same value without it; drgnx itself never writes one.
- **Sections** hold entries for one place: `(:mode MODE ENTRY…)` applies in buffers of that major mode.
- **The head** `drgnx-settings` only marks the file. Loading the file by mistake stops at it, before any entry runs.
- **Workspace files** have the same shape under the head `drgnx-workspace-settings`: a repository's
  `.drgnx/settings.el`, shared with everyone who clones it, and your private workspace files. They may also hold
  `(:dir "SUBDIR/" ENTRY…)` for one folder and `(:eval FORM…)`, code that runs in the workspace's buffers.
- **Limits:** 1 MiB for a settings file, 64 KiB for a repository's `.drgnx/settings.el`. A bigger file is refused,
  never cut short.
- **A mistake.** A file that does not read (a missing paren, the wrong head, no `:version`, or one written by a newer
  drgnx) fails as a whole: drgnx names the file, the line and the column, keeps a last good copy of `settings.el` to
  fall back on, and writes nothing to it until you fix it. One malformed entry fails alone: the rest of the file
  stands. Two entries for the same variable in the same place: the first wins, and the second is named as a problem.

## Editing by hand

`settings.el` is yours as much as drgnx's: edit it in any editor, any time. When drgnx writes it (the Settings page,
an agent with a grant), it changes as little as it can:

- **One entry, one span.** Changing a setting replaces that entry's text and nothing else; every other byte of the
  file stays as you left it.
- **Sorted places, your order kept.** A new entry goes before the first entry whose name sorts after it, and
  sections go after the plain entries. A file you ordered by hand keeps your order: drgnx never re-sorts it behind
  your back. **Settings: Sort File** sorts the file (or the workspace settings file you are in) when you ask: entries
  by name, then sections by kind and name, each with its comments.
- **Comments.** The `;` lines directly above an entry (no blank line between) and a comment at the end of its last
  line belong to the entry: they stay when its value changes and go when it is removed. A comment inside a value is
  lost when drgnx replaces that value; put it above the entry instead.
- **The same text every time.** A value fits on one line up to column 100; a longer list breaks before each keyword,
  or one element per line, each line one column in. Your own print settings change nothing, so diffs stay small.
- **A second entry** for a variable goes when drgnx next writes that variable.
- **An open buffer.** If `settings.el` is open with unsaved edits, drgnx does not write it and says "settings.el has
  unsaved edits in a buffer; save or revert it first". An open buffer with no edits is reverted after drgnx writes.
- **Checked before it lands.** The new text is read back before it replaces the file; when anything but the change
  would differ, nothing is written. Two drgnx sessions never write the file at once.

## The Settings page (Task 26)

## Editing a value (Task 27)

## Who wins (Task 8)

## Where a value comes from

drgnx tells you where each value comes from, down to the file and line, and it says when it is not sure. It
explains the value Emacs has; it never works out a value of its own.

- **The layers, lowest first:** the package's default, a drgnx module, Settings (`settings.el:14`), Customize
  (`custom.el:9`, or "this session only"), your Lisp (`config.el:31`). In a buffer, per-language settings, your
  mode hooks, the workspace files, `.dir-locals.el` and file-local variables come on top.
- **Your Lisp, at its line.** While `custom.el`, `config.el` and your Lisp files load, drgnx notes the line each
  form starts at, file by file, so a `load` inside a form never hides the outer file. `setq`, `setopt`,
  `customize-set-variable`, `use-package :custom` and macros are all seen, because drgnx watches the variable itself.
- **Deferred.** A `with-eval-after-load` body, or a `use-package :config` that waits for its package, runs when the
  package loads. drgnx shows it as "your Lisp (config.el:4), deferred, first seen during config.el:8": the body's own
  line, and the form that loaded the package. That `require` is never blamed for the value.
- **A package's own default.** When a package defines a variable whose value Settings already holds, the value is
  Settings', not the line that loaded the package.
- **Line unknown.** When the line cannot be confirmed (a compiled file, a `set` through a function, several setters
  in one form), drgnx says "your Lisp (config.el, line unknown)" and lists the lines that could have set it.
  Settings offers no Move or Undo on such a line.
- **Changed this session.** After start, a change by anything but Settings itself (`M-x set-variable`, a `setq` you
  evaluate) is shown as "changed this session".
- **Only one buffer.** A `setq` of a variable that is always per buffer (`fill-column`, `indent-tabs-mode`) in
  `config.el` sets only the buffer that was current, and the default stays. drgnx points this out: you probably
  meant `setq-default`.

## Changes apply at once (Task 13)

## Modules and your settings (Task 9)

## Per language (Task 10)

## Workspace settings (Task 17)

## Shared settings (Task 17)

## Trusted locations (Task 18)

## Reviewing a workspace's code (Task 19)

## Settings the runtime reads (Task 22)

## History and undo (Task 25)

## Your Lisp files (Task 28)

## Moving a setting (Task 28)

## Bringing an existing init.el (Task 29)

## Keeping custom.el tidy (Task 30)

## Packages' settings (Task 31)

## Moving from the old files (Task 14)

## Safe mode and Turn Off Package Settings (Task 8)
