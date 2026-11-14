;;; drgnx-lang-packs.el --- Module lang/packs: language packs applied at startup, a hint when one is missing -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The installed packs (`active.eld', derived from the lock by `drgnx packs sync', core/drgnx-packs.el) are applied at
;; startup: their grammar folders go on `treesit-extra-load-path', their tree-sitter modes replace the classic ones
;; (`major-mode-remap-alist', `auto-mode-alist') when every required grammar loads.  Nothing prompts: Emacs's own
;; install question (`treesit-ensure-installed') is turned off, and a mode whose grammar is missing is never remapped.
;; A file of a pack that is not installed gets one echo line per pack per session naming the command that installs it.
;; A grammar a parser was already made for keeps its folder first on the load path until restart, so a session never
;; mixes two builds of one grammar (docs/develop/packs.md).

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-packs)
;; the generic mode is this module's: its file sits beside this one
(unless (featurep 'drgnx-pack-ts-mode)
  (load (expand-file-name "drgnx-pack-ts-mode" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(defvar treesit-extra-load-path)
(defvar treesit-auto-install-grammar)
(defvar drgnx-lang-packs--pinned nil
  "Alist LANG → FOLDER: the folder of each grammar this session made a parser for (set once per language, so at most
one entry per grammar).  Kept first on the load path until restart.")
(defvar drgnx-lang-packs--apply-owned nil
  "A function that runs `drgnx-lang-packs-apply' as the module (made by its setup, so what a later refresh changes is
recorded on it and goes with its teardown); it does nothing once the module is off.")
(defvar drgnx-lang-packs--hinted nil "Packs whose missing support was mentioned this session (one entry per pack).")
(declare-function treesit-language-available-p "treesit.c")
(declare-function drgnx-exec-start "drgnx-exec")
(declare-function drgnx-exec-get "drgnx-exec")

(defun drgnx-lang-packs--folder-of (lang)
  "The folder on `treesit-extra-load-path' that holds LANG's library, or nil."
  (when (boundp 'treesit-extra-load-path)
    (seq-find (lambda (d) (seq-some (lambda (suffix) (file-exists-p (expand-file-name (format "libtree-sitter-%s%s" lang suffix) d)))
                                    dynamic-library-suffixes))
              treesit-extra-load-path)))

(defun drgnx-lang-packs--note-parser (lang &rest _)
  "`treesit-parser-create' advice: remember LANG's folder the first time a parser is made for it."
  (when (and (symbolp lang) (not (assq lang drgnx-lang-packs--pinned)))
    (when-let* ((dir (drgnx-lang-packs--folder-of lang)))
      (push (cons lang dir) drgnx-lang-packs--pinned))))

(defun drgnx-lang-packs--add-folders (active)
  "Put ACTIVE's grammar folders on the load path: in front, except a grammar a parser already exists for, whose
folder in use stays first (the new one goes after it).  The older folder of the build before packs
\(`<data>/tree-sitter/') goes last."
  (dolist (p (plist-get active :packs))
    (dolist (g (plist-get (cdr p) :grammars))
      (add-to-list 'treesit-extra-load-path (cdr g) (and (assq (car g) drgnx-lang-packs--pinned) t))))
  (let ((legacy (expand-file-name "tree-sitter/" (drgnx-data-dir))))
    (when (file-directory-p legacy) (add-to-list 'treesit-extra-load-path legacy t))))

(defun drgnx-lang-packs--grammars-load-p (manifest)
  "Whether every grammar MANIFEST requires loads."
  (seq-every-p (lambda (g) (or (not (plist-get g :required)) (treesit-language-available-p (plist-get g :name))))
               (plist-get manifest :grammars)))

(defun drgnx-lang-packs--file-regexp (manifest)
  "The regexp of the files of MANIFEST's pack: its `:mode-regexp', else one made of its extensions."
  (let ((files (plist-get manifest :files)))
    (or (plist-get files :mode-regexp)
        (and (plist-get files :extensions) (concat "\\." (regexp-opt (plist-get files :extensions) t) "\\'")))))

(defun drgnx-lang-packs--file-of-pack-p (pack file)
  "Whether FILE is a file of PACK, (NAME . MANIFEST): by its mode regexp or its extension."
  (let ((re (drgnx-lang-packs--file-regexp (cdr pack))))
    (and re (string-match-p re file))))

(defun drgnx-lang-packs--apply-pack (info)
  "Register one installed pack (INFO: its `active.eld' entry): its modes, once its required grammars load.  A
generic pack needs its translated queries as well."
  (let* ((m (drgnx-packs-read-manifest (plist-get info :manifest)))
         (mode (plist-get m :mode)) (generic (plist-get mode :generic))
         (ts (if generic 'drgnx-pack-ts-mode (plist-get mode :ts))))
    (when (and ts (fboundp ts) (fboundp 'treesit-language-available-p) (drgnx-lang-packs--grammars-load-p m)
               (or (not generic) (and (plist-get info :translated) (file-exists-p (plist-get info :translated)))))
      (when-let* ((classic (plist-get mode :classic))) (drgnx-module-alist-put 'major-mode-remap-alist classic ts))
      (when-let* ((re (drgnx-lang-packs--file-regexp m))) (add-to-list 'auto-mode-alist (cons re ts)))
      ts)))

(defun drgnx-lang-packs-apply ()
  "Apply `active.eld': the load path first, then each pack's modes.  Returns the tree-sitter modes now in use."
  (let ((active (drgnx-packs-active)))
    (when (boundp 'treesit-extra-load-path) (drgnx-lang-packs--add-folders active))
    (delq nil (mapcar (lambda (p) (with-demoted-errors "drgnx packs: %S" (drgnx-lang-packs--apply-pack (cdr p))))
                      (plist-get active :packs)))))

(defun drgnx-lang-packs--switch (modes)
  "Open buffers of the files MODES (tree-sitter modes) now cover switch to them."
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when-let* ((file buffer-file-name)
                  (ts (seq-find (lambda (m) (and (not (eq major-mode m)) (drgnx-lang-packs--wants-p m file))) modes)))
        (with-demoted-errors "drgnx packs: %S" (funcall ts))))))

(defun drgnx-lang-packs--wants-p (ts file)
  "Whether FILE, in a classic mode TS replaces (or a file TS's regexp matches), should be in TS."
  (or (let ((classic (car (rassq ts major-mode-remap-alist)))) (and classic (derived-mode-p classic)))
      (let ((re (car (rassq ts auto-mode-alist)))) (and re (string-match-p re file)))))

(defun drgnx-lang-packs-refresh ()
  "A pack job ended: apply `active.eld' again, and switch the open buffers its new modes cover."
  (drgnx-lang-packs--switch (and drgnx-lang-packs--apply-owned (funcall drgnx-lang-packs--apply-owned))))

;;;; The hint, and the command

(defun drgnx-lang-packs-pack-for-file (file &optional mode)
  "The built-in pack that owns FILE (or MODE), as (NAME . MANIFEST), or nil."
  (seq-find (lambda (p)
              (let* ((m (cdr p)) (md (plist-get m :mode)))
                (or (and file (drgnx-lang-packs--file-of-pack-p p file))
                    (and mode (or (provided-mode-derived-p mode (or (plist-get md :ts) 'ignore))
                                  (and (plist-get md :classic) (provided-mode-derived-p mode (plist-get md :classic))))))))
            (drgnx-packs-builtins)))

(defun drgnx-lang-packs--hint ()
  "`find-file-hook': a file whose pack has a grammar but is not installed — said once per pack, never asked."
  (when-let* ((p (drgnx-lang-packs-pack-for-file buffer-file-name major-mode)))
    (when (and (drgnx-packs--owned-grammars (cdr p)) (not (assq (intern (car p)) (drgnx-packs-locked)))
               (not (member (car p) drgnx-lang-packs--hinted)))
      (push (car p) drgnx-lang-packs--hinted)
      (message "Language support for %s is not installed: Install Language Support (in the palette) adds it"
               (plist-get (cdr p) :name)))))

(defun drgnx-lang-packs-install (names)
  "Install the packs NAMES (strings) in the background: a durable job running `drgnx packs sync --add'; open buffers
of those languages switch to their tree-sitter modes when it is done."
  (interactive
   (list (let ((here (drgnx-lang-packs-pack-for-file buffer-file-name major-mode)))
           (if (and here (not (assq (intern (car here)) (drgnx-packs-locked)))) (list (car here))
             (list (completing-read "Install language support for: "
                                    (mapcar #'car (seq-remove (lambda (p) (assq (intern (car p)) (drgnx-packs-locked)))
                                                              (seq-filter (lambda (p) (drgnx-packs--owned-grammars (cdr p)))
                                                                          (drgnx-packs-builtins))))
                                    nil t))))))
  (drgnx-exec-start "packs" (append (list (expand-file-name "bin/drgnx" drgnx-dir) "packs" "sync" "--add") names)
                    :callback (lambda (id why)
                                (if id (drgnx-lang-packs--watch id) (drgnx-notify 'hub 'warn why))))
  (message "Installing language support for %s in the background (Show Job Log: packs)" (mapconcat #'identity names ", "))
  nil)

(defun drgnx-lang-packs--watch (id)
  "When job ID ends: the packs are applied (looked at every 2 s for an hour; never waits)."
  (drgnx-timer-poll (cons 'packs-watch id) 2 #'drgnx-lang-packs--watch-tick :deadline 3600 :args (list id)))

(defun drgnx-lang-packs--watch-tick (id)
  "The poll of `drgnx-lang-packs--watch': non-nil, once job ID is over and its packs are applied."
  (let ((job (drgnx-exec-get id)))
    (unless (eq (plist-get job :status) 'running)
      (drgnx-lang-packs-refresh)
      (message (if (eql (plist-get job :exit) 0) "Language support installed"
                 "Language support: the install failed — Show Job Log: packs"))
      t)))

(drgnx-module-define 'lang/packs
                     :doc "Language packs: tree-sitter grammars and modes of the installed packs, a hint when one is missing, installed in the background."
                     :stage 'startup
                     :teardown (lambda () (setq drgnx-lang-packs--apply-owned nil) (drgnx-pack-ts-forget-preds))
                     :setup
                     (lambda ()
                       (drgnx-module-set 'treesit-auto-install-grammar 'never)   ; no mode's `treesit-ensure-installed' asks
                       (advice-add 'treesit-parser-create :before #'drgnx-lang-packs--note-parser)
                       (setq drgnx-lang-packs--apply-owned (drgnx-modules-with-owner (drgnx-lang-packs-apply)))
                       (drgnx-lang-packs-apply)
                       (add-hook 'find-file-hook #'drgnx-lang-packs--hint)
                       (drgnx-command-define 'grammars-install :category "Code" :title "Install Language Support…"
                                             :command #'drgnx-lang-packs-install
                                             :doc "A language pack's tree-sitter grammar and modes (built in the background)")))

(declare-function drgnx-pack-ts-forget-preds "drgnx-pack-ts-mode" ())

(provide 'drgnx-lang-packs)
;;; drgnx-lang-packs.el ends here
