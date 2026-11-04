;;; drgnx-watchdog.el --- Nidhogg's stall watchdog, on by default -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Where the running Emacs is a Nidhogg built with the stall watchdog (`(featurep 'nidhogg-watchdog)'), drgnx turns
;; it on at start: the day files go to (drgnx-state-dir)/watchdog/, the typing commands are the ones whose latency
;; counts as typing, and the package of a file is named by drgnx's owner map.  Only in an interactive Emacs (not in `drgnx safe'), and
;; only while the setting `drgnx-speed-watchdog' is on (the default).  `drgnx-watchdog-mode' is drgnx's side of
;; the switch: turning it off turns Nidhogg's mode off.  Without the feature nothing happens; the doctor's
;; `freezes' check says why (core/drgnx-watchdog-doctor.el).  The GC census stands down while the watchdog runs.

;;; Code:
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-owner)
(require 'drgnx-setting)
(require 'drgnx-settings-area)

(defvar nidhogg-watchdog-mode)
(defvar nidhogg-watchdog-log-directory)
(defvar nidhogg-watchdog-typing-commands)
(defvar nidhogg-watchdog-package-functions)
(declare-function nidhogg-watchdog-mode "nidhogg-watchdog")
(declare-function drgnx-watchdog-doctor-start "drgnx-watchdog-doctor")
(declare-function drgnx-watchdog-doctor-stop "drgnx-watchdog-doctor")
(declare-function drgnx-notify "drgnx-notice")

(defconst drgnx-watchdog-typing-commands
  '(self-insert-command delete-backward-char delete-char backward-delete-char-untabify newline)
  "The commands whose latency counts as typing latency.")

(defconst drgnx-watchdog-evil-typing-commands '(evil-delete-backward-char-and-join evil-ret evil-ret-and-indent)
  "Evil's insert-state equivalents of the typing commands; added when evil is loaded.")

(defvar drgnx-watchdog-mode)
(defvar drgnx-watchdog-start-error nil
  "The message of the error that stopped the last start of the watchdog, or nil (the doctor's `freezes' says it).")

(drgnx-defsetting drgnx-speed-watchdog t
  "Non-nil: run Nidhogg's stall watchdog (Help → Show Freezes) when this Emacs has it.
Read at every start; a change turns it on or off at once.  Without a watchdog in Emacs it does nothing."
  :type 'boolean :group 'drgnx :scope 'global :workspace 'never :apply #'drgnx-watchdog--settings-apply)

(defun drgnx-watchdog-available-p ()
  "Non-nil when this Emacs has the stall watchdog (a Nidhogg built with it)."
  (featurep 'nidhogg-watchdog))

(defun drgnx-watchdog-log-directory ()
  "Where the watchdog's day files go: (drgnx-state-dir)/watchdog/."
  (expand-file-name "watchdog/" (drgnx-state-dir)))

(defun drgnx-watchdog-typing-commands ()
  "The typing set: the built-in commands, and evil's insert-state ones when evil is loaded."
  (append drgnx-watchdog-typing-commands
          (and (featurep 'evil) drgnx-watchdog-evil-typing-commands)))

(defun drgnx-watchdog-package-of (file)
  "The package name (a string) drgnx's owner map gives FILE, or nil; Nidhogg falls back on its own mapping."
  (car-safe (drgnx-owner-of-file file)))

(defun drgnx-watchdog--wanted-p ()
  "Non-nil when the setting is on (settings.el's entry, also before it applied)."
  (not (null (cdar (drgnx-settings-area-values '(drgnx-speed-watchdog))))))

(define-minor-mode drgnx-watchdog-mode
  "Nidhogg's stall watchdog with drgnx's log folder, typing set and package owners.
Does nothing in an Emacs without the watchdog.  Turning it off turns Nidhogg's mode off."
  :global t :group 'drgnx
  (cond ((not (drgnx-watchdog-available-p)) (setq drgnx-watchdog-mode nil))
        (drgnx-watchdog-mode
         (setq nidhogg-watchdog-log-directory (drgnx-watchdog-log-directory)
               nidhogg-watchdog-typing-commands (drgnx-watchdog-typing-commands))
         (add-hook 'nidhogg-watchdog-package-functions #'drgnx-watchdog-package-of)
         (condition-case err
             (progn
               ;; the record hook first: Nidhogg's mode turns the hang files of an earlier session into records as it
               ;; starts, and the notice for a killed hang needs the hook to be there
               (when (require 'drgnx-watchdog-doctor nil t) (drgnx-watchdog-doctor-start))
               (nidhogg-watchdog-mode 1)
               (setq drgnx-watchdog-start-error nil))
           (error (drgnx-watchdog--start-failed err))))
        (t (remove-hook 'nidhogg-watchdog-package-functions #'drgnx-watchdog-package-of)
           (when (featurep 'drgnx-watchdog-doctor) (drgnx-watchdog-doctor-stop))
           (nidhogg-watchdog-mode -1))))

(defun drgnx-watchdog--start-failed (err)
  "The start failed with ERR: leave the mode off and the doctor's hook and timer undone, and say why once.  An error
here would escape drgnx's init, so it is contained."
  (setq drgnx-watchdog-mode nil
        drgnx-watchdog-start-error (error-message-string err))
  (remove-hook 'nidhogg-watchdog-package-functions #'drgnx-watchdog-package-of)
  (when (featurep 'drgnx-watchdog-doctor) (ignore-errors (drgnx-watchdog-doctor-stop)))
  (ignore-errors (nidhogg-watchdog-mode -1))
  (ignore-errors
    (drgnx-notify 'watchdog 'warn (format "The stall watchdog could not start: %s" drgnx-watchdog-start-error)
                  :id 'start :command 'freezes :fix "Set drgnx-speed-watchdog to nil to turn it off; docs/guide/speed.md")))

(defun drgnx-watchdog--settings-apply ()
  "`drgnx-speed-watchdog' changed: the watchdog on or off now, when it is not that already."
  (when (and (drgnx-watchdog-available-p) (not noninteractive) (not (getenv "DRGNX_SAFE")))
    (let ((want (and drgnx-speed-watchdog t)))
      (unless (eq (and drgnx-watchdog-mode t) want)
        (drgnx-watchdog-mode (if want 1 -1))))))

(defun drgnx-watchdog-maybe-start ()
  "Turn the watchdog on when this Emacs has it, is interactive, is not in safe mode and the setting is on.
`drgnx-gc-setup' calls it."
  (when (and (drgnx-watchdog-available-p) (not noninteractive) (not (getenv "DRGNX_SAFE")) (drgnx-watchdog--wanted-p))
    (drgnx-watchdog-mode 1)))

(provide 'drgnx-watchdog)
;;; drgnx-watchdog.el ends here
