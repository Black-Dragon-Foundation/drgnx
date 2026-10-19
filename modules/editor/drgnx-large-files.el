;;; drgnx-large-files.el --- Module editor/large-files: big files open in chunks, lean or raw, and never freeze -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Above a size (large-files.eld's `:ask-above', 50 MiB), a file opens in chunks, lean (whole, without the
;; expensive modes) or raw.  This file holds the config, the decision and the answers remembered for the session:
;; - `drgnx-large-files-thresholds' gives a file's thresholds in bytes: the user's large-files.eld, lowered by the
;;   project's .drgnx/large-files.eld.  A project file is untrusted: it may only lower `:ask-above' and
;;   `:chunks-above', never set the chunk size, and is never read when the user's `:ask-above' is nil (off).
;; - `drgnx-large-files--decide' is the decision, a pure function of the size, how the open came (a command, an
;;   automatic path, a caller that needs the whole text), the remembered answer and the thresholds.
;; - The answers are remembered per file (its truename, or a remote name as it is) in a capped cache.
;; - `large-file-warning-threshold' follows `:ask-above', so `insert-file' still gets Emacs's own question.
;; See docs/guide/modules.md and docs/reference/config.md.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-config)
(require 'drgnx-memo)
(require 'drgnx-guard)

(defvar drgnx-large-file-open)

(defconst drgnx-large-files--mib 1048576 "Bytes in a MiB: the config's sizes are numbers of MiB.")

(drgnx-cache-define 'drgnx-large-files--answers :key 'string :cap 256
                    :doc "File (truename, or a remote name) → the mode chosen for it: lean, raw or chunks.  For the
session only; capped at 256 files, the least recently used evicted.")

;;;; The config

(defun drgnx-large-files--mib-p (v)
  "Non-nil when V is a size in MiB: a number above 0 (fractions allowed), not infinite."
  (and (numberp v) (< 0 v 1.0e+INF)))

(defun drgnx-large-files--bytes (mib)
  "MIB MiB in bytes, rounded."
  (round (* mib drgnx-large-files--mib)))

(defun drgnx-large-files--define-config ()
  "Define large-files.eld and the project's .drgnx/large-files.eld.  The setup calls this; teardown undefines them."
  (drgnx-config-define
   'large-files
   :file "large-files.eld" :shape 'plist :version 1 :reload 'mtime :last-good t
   :schema '(plist (:ask-above (or null (pred drgnx-large-files--mib-p "a size in MiB above 0"))
                               "Above this size (MiB) a file opens in chunks, lean or raw (a command asks once); nil: never")
                   (:chunks-above (pred drgnx-large-files--mib-p "a size in MiB above 0")
                                  "Above this size (MiB) the question's default is chunks, else lean")
                   (:chunk-size (pred drgnx-large-files--mib-p "a size in MiB above 0")
                                "How much of the file (MiB) a chunk holds"))
   :default '(:version 1 :ask-above 50 :chunks-above 500 :chunk-size 1)
   :doc "When a file is large: the size that asks (or opens in chunks, lean or raw), the size above which chunks is the default, and a chunk's size.")
  (drgnx-config-define
   'large-files-project
   :dir 'project :file "large-files.eld" :shape 'plist :version 1 :reload 'mtime
   :schema '(plist (:ask-above (or null (pred drgnx-large-files--mib-p "a size in MiB above 0"))
                               "Lowers your :ask-above for the project (a higher value or nil is ignored)")
                   (:chunks-above (pred drgnx-large-files--mib-p "a size in MiB above 0")
                                  "Lowers your :chunks-above for the project (a higher value is ignored)"))
   :default nil
   :doc "A project's lower large-file sizes: it can only lower yours, never raise them or set the chunk size."))

(defun drgnx-large-files--project-root (file)
  "The folder holding the .drgnx/large-files.eld that applies to FILE, or nil.  Never looked for on a remote name."
  (let ((file (expand-file-name file)))
    (unless (file-remote-p file)
      (let ((default-directory "/"))
        (locate-dominating-file (file-name-directory file) ".drgnx/large-files.eld")))))

(defun drgnx-large-files-thresholds (file)
  "FILE's thresholds in bytes: (:ask-above BYTES-or-nil :chunks-above BYTES :chunk-size BYTES).
The user's large-files.eld, each size lowered by the project's .drgnx/large-files.eld when the project's is a
number below it.  With the user's `:ask-above' nil the project file is not read."
  (let ((ask (drgnx-config-get 'large-files :ask-above))
        (chunks (drgnx-config-get 'large-files :chunks-above)))
    (when-let* ((root (and ask (drgnx-large-files--project-root file))))
      (let ((p-ask (drgnx-config-get 'large-files-project :ask-above root))
            (p-chunks (drgnx-config-get 'large-files-project :chunks-above root)))
        (when (and (numberp p-ask) (< p-ask ask)) (setq ask p-ask))
        (when (and (numberp p-chunks) (< p-chunks chunks)) (setq chunks p-chunks))))
    (list :ask-above (and ask (drgnx-large-files--bytes ask))
          :chunks-above (drgnx-large-files--bytes chunks)
          :chunk-size (drgnx-large-files--bytes (drgnx-config-get 'large-files :chunk-size)))))

(defun drgnx-large-files--sync-threshold ()
  "Set `large-file-warning-threshold' to the user's `:ask-above' in bytes (nil when it is nil), when it differs."
  (let* ((ask (drgnx-config-get 'large-files :ask-above))
         (bytes (and ask (drgnx-large-files--bytes ask))))
    (unless (equal large-file-warning-threshold bytes)
      (drgnx-module-set 'large-file-warning-threshold bytes))))

;;;; The decision

(defun drgnx-large-files--decide (size how remembered thresholds chunks-ok)
  "How to open a file of SIZE bytes: `pass' (as Emacs does), `lean', `raw', `chunks' or (ask . DEFAULT).
HOW: `command' (the user's command: it may ask), `auto' (never asks) or `whole' (the caller needs the whole text).
REMEMBERED: the mode chosen for the file before, or nil.  THRESHOLDS: `drgnx-large-files-thresholds'.  CHUNKS-OK:
chunks can be built; without them chunks becomes raw.  Pure: the first rule that matches wins."
  (let ((ask (plist-get thresholds :ask-above))
        (chunks (if chunks-ok 'chunks 'raw)))
    (cond ((or (null ask) (<= size ask)) 'pass)
          ((eq how 'whole) 'lean)
          ((eq remembered 'chunks) chunks)
          ((memq remembered '(lean raw)) remembered)
          ((eq how 'command) (cons 'ask (if (<= size (plist-get thresholds :chunks-above)) 'lean chunks)))
          (t chunks))))

(defun drgnx-large-files--how ()
  "How the open running now came: `whole' or `auto' when `drgnx-large-file-open' says so in the current buffer;
else `auto' in automatic code (a timer, `drgnx-automatic', daemon startup), under `inhibit-interaction' or outside
a command; else `command'."
  (cond ((bound-and-true-p drgnx-large-file-open) (if (eq drgnx-large-file-open 'whole) 'whole 'auto))
        ((or (drgnx-guard-automatic-p) inhibit-interaction (null this-command)) 'auto)
        (t 'command)))

;;;; The remembered answers

(defun drgnx-large-files--key (file)
  "FILE's key among the answers: a remote name as it is (`file-remote-p' never connects), else its truename."
  (if (file-remote-p file) file (file-truename file)))

(defun drgnx-large-files-remember (file mode)
  "Remember MODE (`lean', `raw' or `chunks') for FILE, for the session."
  (drgnx-cache-put 'drgnx-large-files--answers (drgnx-large-files--key file) mode))

(defun drgnx-large-files-remembered (file)
  "The mode remembered for FILE this session, or nil."
  (drgnx-cache-get 'drgnx-large-files--answers (drgnx-large-files--key file)))

(defun drgnx-large-files--size-text (size)
  "SIZE bytes as a person reads it, for example \"412 MB\"."
  (file-size-human-readable size nil " " "B"))

;;;; The module

(drgnx-module-define 'editor/large-files
                     :doc "Large files: above a size, a file opens in chunks, lean or raw (a command asks once), never freezing Emacs."
                     :stage 'startup
                     :setup (lambda ()
                              (drgnx-large-files--define-config)
                              (drgnx-memo-activate 'drgnx-large-files--answers)
                              (drgnx-large-files--sync-threshold)
                              ;; the listener sets the threshold as this module, so each change is undone at teardown
                              (let ((sync (drgnx-modules-with-owner (drgnx-large-files--sync-threshold))))
                                (drgnx-module-hook 'drgnx-config-changed-functions config-changed (name)
                                  (when (eq name 'large-files) (funcall sync))))))

(provide 'drgnx-large-files)
;;; drgnx-large-files.el ends here
