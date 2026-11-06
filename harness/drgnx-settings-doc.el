;;; drgnx-settings-doc.el --- the generated reference of drgnx's settings -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; docs/reference/settings.md is generated from the settings declared with `drgnx-defsetting', so it cannot drift
;; from the code.  Regenerate it after declaring or changing one (docs/develop/core.md):
;;   emacs --batch -Q -L core -L wb -L harness -L modules/tools -L modules/editor -L modules/ui -l drgnx-settings-doc \
;;         --eval '(drgnx-settings-doc-regenerate "docs/reference/settings.md")'
;; Every file under core/, wb/, modules/ and harness/ with a line that starts `(drgnx-defsetting ' is loaded, so a
;; setting declared anywhere is in the reference (test/unit/settings-doc-test.el reads the files on its own and fails
;; on a declared setting the reference lacks).

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-setting)

(defconst drgnx-settings-doc-dirs '("core" "wb" "modules" "harness")
  "The folders of the checkout whose Lisp files may declare settings.")

(defun drgnx-settings-doc-files ()
  "Every Lisp file under `drgnx-settings-doc-dirs' with a line that starts `(drgnx-defsetting ', sorted."
  (let (files)
    (dolist (dir drgnx-settings-doc-dirs)
      (dolist (file (directory-files-recursively (expand-file-name dir drgnx-dir) "\\.el\\'"))
        (with-temp-buffer
          (insert-file-contents file)
          (when (re-search-forward "^[ \t]*(drgnx-defsetting[ \t]" nil t) (push file files)))))
    (sort files #'string<)))

(defun drgnx-settings-doc-load ()
  "Load every file that declares a setting (`drgnx-settings-doc-files'), so every setting is declared.  A file whose
feature is already there is not loaded again."
  (dolist (file (drgnx-settings-doc-files))
    (unless (featurep (intern (file-name-base file)))
      (load (file-name-sans-extension file) nil t))))

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
