;;; drgnx-settings-doc.el --- the generated reference of drgnx's settings -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; docs/reference/settings.md is generated from the settings declared with `drgnx-defsetting', so it cannot drift
;; from the code.  Regenerate it after declaring or changing one (docs/develop/core.md):
;;   emacs --batch -Q -L core -L wb -L harness -L modules/tools -L modules/editor -l drgnx-settings-doc \
;;         --eval '(drgnx-settings-doc-regenerate "docs/reference/settings.md")'
;; Settings declared in a file are reached by a `(require FEATURE)' entry of `drgnx-settings-doc-sources'; each
;; port appends its own entry (one line each) and regenerates the reference.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-file)
(require 'drgnx-setting)

(defvar drgnx-settings-doc-sources
  '(
    ;; one entry per line, appended below by each port
    (require drgnx-agents)                ; Task 15: drgnx-agents-*
    (require drgnx-ai)                    ; Task 15: drgnx-ai-providers, drgnx-ai-roles
    (require drgnx-keys)
    (require drgnx-modules)
    (require drgnx-session)
    (require drgnx-look)
    (require drgnx-large-files)
    (require drgnx-search-chunk)          ; Task 17: drgnx-search-{include,exclude,off}
    (require drgnx-sandbox)               ; drgnx-sandbox-memory-max, -secret-files (US-WORKSPACE-NEVER-1)
    (require drgnx-sandbox-proxy)         ; drgnx-sandbox-proxy-pinned-addresses
    (require drgnx-settings-trust))       ; Task 18: drgnx-trust-parents
  "What declares the settings of the reference: entries `(require FEATURE)'.")

(defun drgnx-settings-doc-load ()
  "Load what `drgnx-settings-doc-sources' names, so every setting is declared."
  (dolist (source drgnx-settings-doc-sources)
    (pcase source
      (`(require ,feature) (require feature))
      (_ (error "drgnx-settings-doc: %S is not (require FEATURE)" source)))))

(defun drgnx-settings-doc--cell (text)
  "TEXT as a table cell: one line, no bare bars."
  (replace-regexp-in-string "|" "\\\\|" (replace-regexp-in-string "[ \t\n]+" " " (string-trim (or text "")))))

(defun drgnx-settings-doc--default (var)
  "The default of VAR as text."
  (condition-case nil
      (format "%S" (eval (car (get var 'standard-value)) t))
    (error "")))

(defun drgnx-settings-doc--section (var)
  "The reference section of the setting VAR."
  (let ((meta (drgnx-setting-meta var)))
    (concat
     (format "## %s\n\n" var)
     (when-let* ((doc (documentation-property var 'variable-documentation t)))
       (format "%s\n\n" (string-trim doc)))
     "| Key | Value |\n| --- | --- |\n"
     (format "| Default | `%s` |\n" (drgnx-settings-doc--cell (drgnx-settings-doc--default var)))
     (format "| Type | `%s` |\n" (drgnx-settings-doc--cell (format "%S" (get var 'custom-type))))
     (mapconcat (lambda (key)
                  (format "| `%s` | %s |" key
                          (if-let* ((value (plist-get meta key))) (format "`%s`" (drgnx-settings-doc--cell (format "%S" value))) "-")))
                drgnx-setting-keys "\n")
     "\n\n")))

(defun drgnx-settings-doc-markdown ()
  "The reference of every declared setting, sorted by name, as Markdown text."
  (concat "# Settings\n\n"
          "The settings drgnx declares with `drgnx-defsetting`, and the keys that say where each may be set, whether "
          "a workspace may set it, how it merges and whether an agent may change it. "
          "Generated from the declarations: do not edit; see docs/develop/core.md for how to regenerate it, and "
          "[Declaring a setting](../develop/settings.md) for the keys.\n\n"
          (mapconcat #'drgnx-settings-doc--section
                     (sort (drgnx-setting-names) (lambda (a b) (string< (symbol-name a) (symbol-name b)))) "")))

(defun drgnx-settings-doc-write (file)
  "Write `drgnx-settings-doc-markdown' to FILE (relative to the current folder), atomically."
  (drgnx-file-write-text (expand-file-name file) (drgnx-settings-doc-markdown)))

(defun drgnx-settings-doc-regenerate (file)
  "Declare every setting (`drgnx-settings-doc-load'), then write the reference to FILE.
The command in `docs/develop/core.md'."
  (drgnx-settings-doc-load)
  (drgnx-settings-doc-write file))

(provide 'drgnx-settings-doc)
;;; drgnx-settings-doc.el ends here
