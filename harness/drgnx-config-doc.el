;;; drgnx-config-doc.el --- the generated reference of drgnx's config files -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; docs/reference/config.md is generated from the config definitions (`drgnx-config-define') and their schemas, so it
;; cannot drift from the code.  Regenerate it after a change to a definition (docs/develop/core.md):
;;   emacs --batch -Q -L core -L wb -L harness -L modules/tools -l drgnx-config-doc \
;;         --eval '(drgnx-config-doc-regenerate "docs/reference/config.md")'
;; Files defined at load are reached by a `(require FEATURE)' entry of `drgnx-config-doc-sources'; files a module
;; defines in its setup, by a `(require FILE)' entry for the module's file and a `(setup MODULE)' entry after it.
;; Each port appends its own entries (one line each) and regenerates the reference.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-file)
(require 'drgnx-schema)
(require 'drgnx-config)

(declare-function drgnx-modules--run-setup "drgnx-modules-record" (module setup))
(defvar drgnx-modules--table)

(defvar drgnx-config-doc-sources
  '(
    ;; one entry per line, appended below by each port
    (require drgnx-projects)
    (require drgnx-agents)
    (require drgnx-layouts)
    (setup tools/layouts)
    (require drgnx-modules)
    (require drgnx-keys)
    (require drgnx-ai)
    (require drgnx-pkg)
    (require drgnx-session)
    (require drgnx-search-chunk)
    (require drgnx-onboard)
    (require drgnx-face-state)
    )
  "What defines the config files of the reference: entries `(require FEATURE)' and `(setup MODULE)'.
`(require FEATURE)' loads a core feature that defines files at load.  `(setup MODULE)' runs the setup of the module
\(already defined, so its file has an earlier `(require FEATURE)' entry) through `drgnx-modules--run-setup'.
One line per source, so ports append theirs without conflict.")

(defun drgnx-config-doc-load ()
  "Load what `drgnx-config-doc-sources' names, so every config file is defined."
  (dolist (source drgnx-config-doc-sources)
    (pcase source
      (`(require ,feature) (require feature))
      (`(setup ,module)
       (require 'drgnx-modules)
       (let ((spec (alist-get module drgnx-modules--table)))
         (unless spec (error "drgnx-config-doc: module %s is not defined: its file needs a (require …) entry first" module))
         (when-let* ((failure (drgnx-modules--run-setup module (plist-get spec :setup))))
           (error "drgnx-config-doc: the setup of %s failed: %s" module (or (car failure) (cdr failure))))))
      (_ (error "drgnx-config-doc: %S is neither (require FEATURE) nor (setup MODULE)" source)))))

(defun drgnx-config-doc--cell (text)
  "TEXT as a table cell: one line, no bare bars."
  (replace-regexp-in-string "|" "\\\\|" (replace-regexp-in-string "[ \t\n]+" " " (string-trim (or text ""))) nil nil))

(defun drgnx-config-doc--section (def)
  "The reference section of the definition DEF."
  (let ((rows (drgnx-schema-describe (plist-get def :schema))))
    (concat
     (format "## %s\n\n" (plist-get def :file))
     (format "Folder: %s. Format: %d. Read: %s. On a mistake: %s.\n\n"
             (plist-get def :dir) (plist-get def :version)
             (if (eq (plist-get def :reload) 'start) "at start" "when it changes")
             (cond ((plist-get def :on-mistake) (plist-get def :on-mistake))
                   ((eq (plist-get def :dir) 'project) "refused")
                   ((plist-get def :last-good) "its last good copy, else the defaults")
                   (t "the defaults")))
     (when-let* ((doc (plist-get def :doc))) (format "%s\n\n" doc))
     (when rows
       (concat "| Key | Type | Required | What |\n| --- | --- | --- | --- |\n"
               (mapconcat (lambda (row)
                            (pcase-let ((`(,path ,type ,doc ,required) row))
                              (format "| `%s` | %s | %s | %s |"
                                      (mapconcat (lambda (k) (format "%s" k)) path " ")
                                      (drgnx-config-doc--cell type) (if required "yes" "no") (drgnx-config-doc--cell doc))))
                          rows "\n")
               "\n\n")))))

(defun drgnx-config-doc-markdown ()
  "The reference of every defined config file, sorted by name, as Markdown text."
  (let ((defs (mapcar #'drgnx-config-definition (drgnx-config-names))))
    (concat "# Config files\n\n"
            "Every file drgnx keeps in its config and state folders, and the project files it reads. "
            "Generated from the definitions: do not edit; see docs/develop/core.md for how to regenerate it, "
            "and [Files](../guide/files.md) for what a mistake in one does.\n\n"
            (mapconcat #'drgnx-config-doc--section defs ""))))

(defun drgnx-config-doc-write (file)
  "Write `drgnx-config-doc-markdown' to FILE (relative to the current folder), atomically, through
`drgnx-file-write-text'."
  (drgnx-file-write-text (expand-file-name file) (drgnx-config-doc-markdown)))

(defun drgnx-config-doc-regenerate (file)
  "Define every config file (`drgnx-config-doc-load'), then write the reference to FILE (`drgnx-config-doc-write').
The command in `docs/develop/core.md'.  Run it once in a fresh `emacs --batch -Q': a second load would set a module
up twice."
  (drgnx-config-doc-load)
  (drgnx-config-doc-write file))

(provide 'drgnx-config-doc)
;;; drgnx-config-doc.el ends here
