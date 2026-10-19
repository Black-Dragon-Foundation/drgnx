;;; drgnx-grammars.el --- Module lang/grammars: tree-sitter grammars on request -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A file whose language has a tree-sitter mode but no grammar opens as usual; the echo area says once per language
;; which command installs it (never a prompt).  Install Language Support builds the grammars in a durable job (a
;; batch Emacs: git and a C compiler), into drgnx's data dir; when it ends, open buffers of those languages switch to
;; their tree-sitter mode.  See docs/guide/editing.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-jobs)
(require 'drgnx-timer)

(defvar treesit-extra-load-path)
(declare-function treesit-language-available-p "treesit.c")

(defconst drgnx-grammars-modes
  '((python python-mode python-ts-mode) (javascript js-mode js-ts-mode) (json js-json-mode json-ts-mode)
    (css css-mode css-ts-mode) (html mhtml-mode html-ts-mode "\\.html?\\'") (bash sh-mode bash-ts-mode)
    (c c-mode c-ts-mode) (cpp c++-mode c++-ts-mode) (java java-mode java-ts-mode) (ruby ruby-mode ruby-ts-mode)
    (yaml yaml-mode yaml-ts-mode "\\.ya?ml\\'") (rust rust-mode rust-ts-mode "\\.rs\\'") (go go-mode go-ts-mode "\\.go\\'")
    (typescript typescript-mode typescript-ts-mode "\\.ts\\'") (tsx nil tsx-ts-mode "\\.tsx\\'") (toml conf-toml-mode toml-ts-mode "\\.toml\\'")
    (lua lua-mode lua-ts-mode "\\.lua\\'"))
  "LANGUAGE MODE TS-MODE [FILE-REGEXP]: files in MODE (or matching FILE-REGEXP) want LANGUAGE's grammar for TS-MODE.")

(defconst drgnx-grammars-sources
  '((bash "https://github.com/tree-sitter/tree-sitter-bash" "v0.23.3") (c "https://github.com/tree-sitter/tree-sitter-c" "v0.23.6")
    (cpp "https://github.com/tree-sitter/tree-sitter-cpp" "v0.23.4") (css "https://github.com/tree-sitter/tree-sitter-css" "v0.23.2")
    (go "https://github.com/tree-sitter/tree-sitter-go" "v0.23.4") (html "https://github.com/tree-sitter/tree-sitter-html" "v0.23.2")
    (java "https://github.com/tree-sitter/tree-sitter-java" "v0.23.5") (javascript "https://github.com/tree-sitter/tree-sitter-javascript" "v0.23.1" "src")
    (json "https://github.com/tree-sitter/tree-sitter-json" "v0.24.8") (lua "https://github.com/tree-sitter-grammars/tree-sitter-lua" "v0.3.0")
    (python "https://github.com/tree-sitter/tree-sitter-python" "v0.23.6") (ruby "https://github.com/tree-sitter/tree-sitter-ruby" "v0.23.1")
    (rust "https://github.com/tree-sitter/tree-sitter-rust" "v0.23.3") (toml "https://github.com/tree-sitter-grammars/tree-sitter-toml" "v0.7.0")
    (tsx "https://github.com/tree-sitter/tree-sitter-typescript" "v0.23.2" "tsx/src")
    (typescript "https://github.com/tree-sitter/tree-sitter-typescript" "v0.23.2" "typescript/src")
    (yaml "https://github.com/tree-sitter-grammars/tree-sitter-yaml" "v0.7.2"))
  "LANGUAGE URL REVISION [SOURCE-DIR]: where a grammar comes from (`treesit-language-source-alist' entries).  REVISION is
the newest tag whose parser is tree-sitter ABI 14 (what Emacs 30 loads, and what its tree-sitter modes' queries were
written against); `drgnx-grammars-recipe' drops it on Emacs 31 or later with an ABI 15 library.")

(defun drgnx-grammars--abi ()
  "The tree-sitter ABI version of this Emacs's library, or nil when it cannot say."
  (and (fboundp 'treesit-library-abi-version) (treesit-library-abi-version)))

(defun drgnx-grammars-recipe (lang)
  "LANG's `drgnx-grammars-sources' entry, as built here: pinned to its ABI 14 tag on Emacs 30 whatever the library's
ABI (a pinned parser loads in a newer library, and Emacs 30's modes were written against those grammars); the default
branch (no revision) only on Emacs 31 or later with an ABI 15 library.  Nil if LANG is unknown."
  (when-let* ((e (assq lang drgnx-grammars-sources)))
    (let ((abi (drgnx-grammars--abi)))
      (if (and (>= emacs-major-version 31) abi (>= abi 15)) (append (list (nth 0 e) (nth 1 e) nil) (nthcdr 3 e)) e))))

(defvar drgnx-grammars--hinted nil "Languages whose missing grammar was mentioned this session.")

(defun drgnx-grammars-dir () (expand-file-name "tree-sitter/" (drgnx-data-dir)))

(defun drgnx-grammars-language (&optional buffer)
  "The language BUFFER's file wants a grammar for, or nil."
  (with-current-buffer (or buffer (current-buffer))
    (car (or (seq-find (lambda (e) (and (nth 1 e) (derived-mode-p (nth 1 e)))) drgnx-grammars-modes)
             (and buffer-file-name
                  (seq-find (lambda (e) (and (nth 3 e) (string-match-p (nth 3 e) buffer-file-name))) drgnx-grammars-modes))))))

(defun drgnx-grammars-missing-p (lang)
  (and lang (assq lang drgnx-grammars-sources) (fboundp 'treesit-language-available-p) (not (treesit-language-available-p lang))))

(defun drgnx-grammars--hint ()
  "`find-file-hook': a file whose grammar is missing — said once per language, never asked."
  (let ((lang (drgnx-grammars-language)))
    (when (and lang (not (memq lang drgnx-grammars--hinted)) (drgnx-grammars-missing-p lang))
      (push lang drgnx-grammars--hinted)
      (message "Tree-sitter support for %s is not installed: Install Language Support (in the palette) adds it" lang))))

(defun drgnx-grammars--job-command (langs)
  "The command line of the job that builds LANGS's grammars into `drgnx-grammars-dir'.  A tree-sitter mode that pins
its grammar (Emacs 31) keeps its recipe; drgnx's is the fallback.  A grammar counts as installed only when its library
is in the directory and loads (`treesit-install-language-grammar' reports its own failures as warnings)."
  (let ((dir (drgnx-grammars-dir))
        (recipes (mapcar #'drgnx-grammars-recipe langs))
        (modes (delq nil (mapcar (lambda (e) (and (memq (car e) langs) (cons (car e) (nth 2 e)))) drgnx-grammars-modes))))
    (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "--eval"
          (prin1-to-string
           `(let ((failed nil))
              (require 'treesit)                     ; its variables are special only once loaded (--eval is lexical)
              (add-to-list 'treesit-extra-load-path ,dir)
              (dolist (l ',langs)
                (let ((mode (cdr (assq l ',modes))))   ; its library may pin the grammar (Emacs 31)
                  (when (and mode (autoloadp (symbol-function mode)))
                    (ignore-errors (autoload-do-load (symbol-function mode) mode))))
                (unless (assq l treesit-language-source-alist)
                  (push (assq l ',recipes) treesit-language-source-alist))
                (condition-case e (treesit-install-language-grammar l ,dir)
                  (error (message "%s" (error-message-string e))))
                (if (and (let ((built nil))           ; (no seq in a -Q batch Emacs)
                           (dolist (suffix dynamic-library-suffixes built)
                             (when (file-exists-p (expand-file-name (format "libtree-sitter-%s%s" l suffix) ,dir)) (setq built t))))
                         (treesit-language-available-p l))
                    (message "installed %s" l)
                  (setq failed t)
                  (message "FAILED %s: not built, or built for another tree-sitter than this Emacs's (see above)" l)))
              (kill-emacs (if failed 1 0)))))))

(defun drgnx-grammars-install (langs)
  "Install the tree-sitter grammars of LANGS (default: this buffer's language) in the background — a durable job; the
buffers of those languages switch to their tree-sitter modes when it is done."
  (interactive
   (list (let ((here (drgnx-grammars-language)))
           (if (drgnx-grammars-missing-p here) (list here)
             (list (intern (completing-read "Install language support for: "
                                            (mapcar (lambda (e) (symbol-name (car e))) drgnx-grammars-sources) nil t)))))))
  (make-directory (drgnx-grammars-dir) t)
  (let ((id (drgnx-jobs-start "grammars" (drgnx-grammars--job-command langs))))
    (message "Installing language support for %s in the background (Show Job Log: grammars)" (mapconcat #'symbol-name langs ", "))
    (drgnx-grammars--watch id langs)
    id))

(defun drgnx-grammars--watch (id langs)
  "When job ID ends: LANGS's buffers switch (looked at every 2 s for an hour; never waits)."
  (drgnx-timer-poll (cons 'grammars-watch id) 2 #'drgnx-grammars--watch-tick :deadline 3600 :args (list id langs)))

(defun drgnx-grammars--watch-tick (id langs)
  "The poll of `drgnx-grammars--watch': non-nil, once job ID is over and LANGS's buffers have switched."
  (let ((job (drgnx-jobs-get id)))
    (unless (eq (plist-get job :status) 'running)
      (drgnx-grammars--installed langs)
      (message (if (eql (plist-get job :exit) 0) "Language support installed: %s"
                 "Language support: some did not install (%s) — Show Job Log: grammars")
               (mapconcat #'symbol-name langs ", "))
      t)))

(defun drgnx-grammars--installed (langs)
  "LANGS's grammars may be there now: their files use the tree-sitter modes, open buffers switch."
  (dolist (e drgnx-grammars-modes)
    (pcase-let ((`(,lang ,mode ,ts ,re) e))
      (when (and (memq lang langs) (fboundp ts) (treesit-language-available-p lang))
        (when mode (drgnx-module-alist-put 'major-mode-remap-alist mode ts))
        (when re (add-to-list 'auto-mode-alist (cons re ts)))
        (dolist (b (buffer-list))
          (with-current-buffer b
            (when (and buffer-file-name (eq (drgnx-grammars-language) lang) (not (eq major-mode ts)))
              (with-demoted-errors "drgnx grammars: %S" (funcall ts)))))))))

(drgnx-module-define 'lang/grammars
                     :doc "Tree-sitter grammars on request: a hint when one is missing, installed in the background."
                     :stage 'startup
                     :setup
                     (lambda ()
                       (when (boundp 'treesit-extra-load-path) (add-to-list 'treesit-extra-load-path (drgnx-grammars-dir)))
                       (when (fboundp 'treesit-language-available-p) (drgnx-grammars--installed (mapcar #'car drgnx-grammars-modes)))
                       (add-hook 'find-file-hook #'drgnx-grammars--hint)
                       (drgnx-command-define 'grammars-install :category "Code" :title "Install Language Support…"
                                             :command #'drgnx-grammars-install
                                             :doc "Tree-sitter grammars for this language (built in the background)")))

(provide 'drgnx-grammars)
;;; drgnx-grammars.el ends here
