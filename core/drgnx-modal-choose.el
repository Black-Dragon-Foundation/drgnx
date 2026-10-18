;;; drgnx-modal-choose.el --- Choosing a modal key stack: its engine's module, installing it, a pending switch -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A key stack with a modal profile (Vim) needs that profile's engine (evil), which a module provides that is off
;; until chosen (editor/evil).  Keyboard Profile… and onboarding's Look and Keys call `drgnx-modal-prepare' before
;; they switch: it turns the module on and, when the engine is installed, runs the module now; when it is not, a
;; command the user ran asks once and installs it (`drgnx sync' as a job, its progress shown), and anything else
;; (`drgnx onboard --non-interactive', code, a daemon) records the stack in keys.eld as `:pending-layers' without
;; asking.  The stack switches only once the engine is loaded — never the Vim keys without evil.  At the next start
;; `drgnx-modal-apply-pending' switches a pending stack whose engine is now loaded.  A stack without a modal profile
;; turns the engine modules off (from the next start).  See docs/guide/keys.md ("Choosing a profile").

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-guard)
(require 'drgnx-modules)
(require 'drgnx-pkg-activate)
(require 'drgnx-keys)
(require 'drgnx-modal)
(require 'drgnx-onboard)

(declare-function drgnx-pkg--module-packages "drgnx-pkg")

(defvar drgnx-modal-engine-modules '((evil . editor/evil))
  "Alist ENGINE → the module that provides it, for an engine not registered yet (its module has not run).")

(defun drgnx-modal--engine-module (engine)
  "The module of ENGINE: what it registered with, else `drgnx-modal-engine-modules'."
  (or (plist-get (alist-get engine drgnx-modal-engines) :module)
      (alist-get engine drgnx-modal-engine-modules)))

(defun drgnx-modal--module-packages (module)
  "MODULE's packages: from its definition, else read from the module files (a process that did not load them)."
  (if-let* ((spec (alist-get module drgnx-modules--table)))
      (plist-get spec :packages)
    (require 'drgnx-pkg)
    (alist-get module (drgnx-pkg--module-packages (expand-file-name "modules" drgnx-dir)))))

(defun drgnx-modal--module-on-p (module)
  "Non-nil when modules.eld has MODULE on: in :enabled, not in :disabled."
  (let ((state (drgnx-modules-read-state)))
    (and (memq module (plist-get state :enabled)) (not (memq module (plist-get state :disabled))))))

(defun drgnx-modal--set-enabled (module on)
  "Choose MODULE (off until chosen) ON or off in modules.eld; the file is written only when that changes."
  (unless (eq (drgnx-modal--module-on-p module) (and on t))
    (if (assq module drgnx-modules--table)
        (drgnx-modules-set-enabled module on)
      ;; Not defined in this process (`drgnx onboard' loads no modules): an engine's module is off until chosen,
      ;; so :enabled is its switch, as `drgnx-modules-set-enabled' writes it.
      (let ((state (copy-sequence (drgnx-modules-read-state))))
        (setq state (plist-put state :enabled (append (remq module (plist-get state :enabled)) (and on (list module)))))
        (drgnx-modules-write-state (plist-put state :disabled (remq module (plist-get state :disabled))))))))

(defun drgnx-modal-set-module (layers)
  "Turn on the module of the engine LAYERS need (it runs from the next start, or now through
`drgnx-modal-engine-start-now') and every other modal engine's module off; LAYERS that need no engine turn them
all off.  The module is the engine's `:module', or `drgnx-modal-engine-modules' for one not registered yet.
Returns the module turned on, or nil."
  (let* ((engine (drgnx-modal-engine-for layers))
         (module (and engine (drgnx-modal--engine-module engine))))
    (dolist (m (delete-dups (delq nil (mapcar (lambda (e) (drgnx-modal--engine-module (car e)))
                                              (append drgnx-modal-engines drgnx-modal-engine-modules)))))
      (unless (eq m module) (drgnx-modal--set-enabled m nil)))
    (when module (drgnx-modal--set-enabled module t))
    module))

(defun drgnx-modal-engine-installed-p (engine)
  "Non-nil when every package of ENGINE's module is loaded, loadable here (`locate-library') or in drgnx's packages
directory (what drgnx sync installed, loadable after `drgnx-pkg-activate')."
  (when-let* ((module (drgnx-modal--engine-module engine)))
    (seq-every-p (lambda (p) (or (featurep p) (locate-library (symbol-name p)) (drgnx-onboard--installed-p p)))
                 (drgnx-modal--module-packages module))))

(defun drgnx-modal-engine-start-now (engine)
  "Make drgnx's packages loadable (`drgnx-pkg-activate') and run ENGINE's module now, as the startup stage does
(its module must be on in modules.eld).  Non-nil when ENGINE is then registered: its module ran and loaded it."
  (let* ((module (drgnx-modal--engine-module engine))
         (spec (alist-get module drgnx-modules--table)))
    (when (and spec (not (assq engine drgnx-modal-engines)))
      (condition-case err (drgnx-pkg-activate)
        (error (message "drgnx: packages not activated: %s" (error-message-string err))))
      (drgnx-modules--run-one module spec 'startup))
    (and (assq engine drgnx-modal-engines) t)))

;;;; keys.eld :pending-layers

(defun drgnx-modal--pending ()
  "keys.eld's `:pending-layers', or nil."
  (let ((drgnx-keys-problems nil)) (plist-get (drgnx-keys-read-user) :pending-layers)))

(defun drgnx-modal--forget-pending ()
  "Take `:pending-layers' and its value out of keys.eld; the rest of the file stays as it is."
  (let ((file (drgnx-keys-file)))
    (when (and (file-exists-p file) (let ((drgnx-keys-problems nil)) (plist-member (drgnx-keys-read-user) :pending-layers)))
      (let ((text (with-temp-buffer
                    (insert-file-contents file)
                    (set-syntax-table emacs-lisp-mode-syntax-table)
                    (goto-char (point-min))
                    (forward-comment (buffer-size))
                    (down-list 1)
                    (let ((done nil))
                      (while (and (not done) (progn (forward-comment (buffer-size)) (not (eq (char-after) ?\)))))
                        (let ((beg (point)) (k (read (current-buffer))))
                          (forward-comment (buffer-size))
                          (forward-sexp 1)
                          (when (eq k :pending-layers)
                            (skip-chars-forward " \t")
                            (when (eolp) (skip-chars-forward "\n") (skip-chars-forward " \t"))
                            (let ((end (point)))
                              (when (eq (char-after) ?\))  ; the last entry: the space before it goes too
                                (goto-char beg)
                                (skip-chars-backward " \t")
                                (setq beg (point)))
                              (delete-region beg end))
                            (setq done t)))))
                    (buffer-string)))
            (tmp (make-temp-file (expand-file-name ".keys-" (file-name-directory file)))))
        ;; As `drgnx-keys--save-key' writes: a temp file renamed over keys.eld.
        (with-temp-file tmp (insert text))
        (set-file-modes tmp #o644)
        (rename-file tmp file t)
        (drgnx-keys--write-report)))))   ; the key report no longer says a stack waits

;;;; Choosing

(defun drgnx-modal--can-ask-p (interactive)
  "Non-nil when a question can be answered: INTERACTIVE (a command the user ran), an Emacs with a user, not an
automatic path (`drgnx-guard'), not the daemon's own terminal."
  (and interactive (not noninteractive) (not inhibit-interaction) (not (drgnx-guard--context))
       (not (and (daemonp) (equal (terminal-name) "initial_terminal")))))

(defun drgnx-modal--profile-name (layers)
  "The name of the modal profile of LAYERS (\"Vim\")."
  (drgnx-keys--ensure-profiles)
  (seq-some (lambda (l) (let ((p (alist-get (car l) drgnx-keys-profiles)))
                          (and (plist-get p :modal) (or (plist-get p :name) (symbol-name (car l))))))
            layers))

(defun drgnx-modal--start (layers engine result was-on)
  "Turn on the module LAYERS need, start ENGINE's module now: RESULT when ENGINE is then loaded, else (fail REASON
nil) with the module as it was (WAS-ON)."
  (drgnx-modal-set-module layers)
  (if (drgnx-modal-engine-start-now engine)
      result
    (let* ((module (drgnx-modal--engine-module engine))
           (r (alist-get module drgnx-modules--report)))
      (unless was-on (drgnx-modal--set-enabled module nil))
      (list 'fail (pcase (plist-get r :status)
                    ('missing-packages (format "%s still needs %s" module (mapconcat #'symbol-name (plist-get r :missing) " ")))
                    ('failed (format "%s failed: %s" module (plist-get r :error)))
                    (_ (format "%s did not load %s" module engine)))
            nil))))

(defun drgnx-modal-prepare (layers &optional interactive)
  "Make the engine LAYERS need ready before a caller switches to them.  The result:
`ready'     LAYERS need no engine, or it is loaded (or installed, in a process that runs no modules: `drgnx
            onboard' saves the stack and the engine loads with it at the next start);
`started'   it was installed: its module is on and ran now;
`installed' INTERACTIVE, not installed: the user was told what it installs and said yes (asked once), drgnx sync
            ran as a job with its progress shown, and the module ran;
`declined'  the user said no: nothing changed;
`pending'   not installed and nobody to ask (not INTERACTIVE, batch, `inhibit-interaction', an automatic path, the
            daemon's own terminal): the module is on and keys.eld's `:pending-layers' is LAYERS, for
            `drgnx-modal-apply-pending' at a start once drgnx sync installed it; nothing asked;
\(fail REASON LOG) the sync or the module failed; the module is as it was.
Switch to LAYERS only on `ready', `started' or `installed'.  Those also set the modules for LAYERS
\(`drgnx-modal-set-module': no engine, every engine module off at the next start) and drop a pending stack."
  (let* ((engine (drgnx-modal-engine-for layers))
         (module (and engine (drgnx-modal--engine-module engine)))
         (was-on (and module (drgnx-modal--module-on-p module)))
         (result
          (cond
           ((or (null engine) (assq engine drgnx-modal-engines)) (drgnx-modal-set-module layers) 'ready)
           ((drgnx-modal-engine-installed-p engine)
            (if (assq module drgnx-modules--table)
                (drgnx-modal--start layers engine 'started was-on)
              ;; A process that runs no modules (drgnx onboard): the stack is saved and its engine loads with it
              ;; at the next start.
              (drgnx-modal-set-module layers)
              'ready))
           ((not (drgnx-modal--can-ask-p interactive))
            (drgnx-modal-set-module layers)
            (drgnx-keys--save-key :pending-layers layers)
            (drgnx-keys--write-report)   ; no apply runs now: the key report and the doctor say what waits
            'pending)
           ((not (y-or-n-p (format "%s keys need %s (module %s), not installed yet.  Install now with drgnx sync? "
                                   (drgnx-modal--profile-name layers)
                                   (mapconcat #'symbol-name (drgnx-modal--module-packages module) ", ")
                                   module)))
            'declined)
           (t (drgnx-modal-set-module layers)
              (let ((sync (drgnx-onboard--sync-job)))
                (if (eq sync 'ok) (drgnx-modal--start layers engine 'installed was-on)
                  (unless was-on (drgnx-modal--set-enabled module nil))
                  sync))))))
    (when (memq result '(ready started installed)) (drgnx-modal--forget-pending))
    result))

(defun drgnx-modal-wait-text (name result)
  "Why the stack NAME was not switched to, for a `drgnx-modal-prepare' RESULT other than a success."
  (pcase result
    ('pending (format "%s needs drgnx sync" name))
    ('declined (format "%s not chosen (its engine is not installed)" name))
    (`(fail ,why ,log) (format "%s did not start: %s%s" name why (if log (format " (log: %s)" log) "")))
    (_ (format "%s: %S" name result))))

(defun drgnx-modal-apply-pending ()
  "At a start, after the keys were applied: when keys.eld has `:pending-layers' and their engine is loaded now,
switch to them and save them as `:layers'; the pending entry goes.  Otherwise nothing changes (the current stack
stays; the doctor says what waits).  Never asks; an error is said in *Messages*.  Returns the layers switched to."
  (condition-case err
      (when-let* ((layers (drgnx-modal--pending))
                  ((null (drgnx-keys--layers-error layers)))
                  (engine (drgnx-modal-engine-for layers))
                  ((assq engine drgnx-modal-engines)))
        (drgnx-keys-use layers t)
        (drgnx-modal--forget-pending)
        layers)
    (error (message "drgnx: the key stack waiting in keys.eld was not applied: %s" (error-message-string err))
           nil)))

(provide 'drgnx-modal-choose)
;;; drgnx-modal-choose.el ends here
