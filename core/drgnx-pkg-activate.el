;;; drgnx-pkg-activate.el --- Sessions use the packages drgnx sync installed; nothing else installs -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A session activates the packages directory `drgnx sync' fills (its quickstart file, no scan, no
;; network) and installs nothing: use-package's :ensure only records the package for the next sync,
;; and package-install, package-refresh-contents and friends called from automatic code (startup,
;; timers, hooks — also those running inside a user command — and `drgnx-automatic' code) signal instead
;; of reaching the network.  A package the user installs with a command they run (M-x package-install,
;; list-packages, an Install button) still installs (into the same directory).  See
;; docs/guide/packages.md.

;;; Code:
(require 'seq)
(require 'drgnx-paths)

(define-error 'drgnx-pkg-error "drgnx packages")

(defvar package-user-dir)
(defvar package-gnupghome-dir)
(defvar package-quickstart)
(defvar package-quickstart-file)
(defvar native-comp-eln-load-path)
(defvar use-package-ensure-function)
(declare-function package-installed-p "package")

(defun drgnx-pkg-activate ()
  "Use the packages directory drgnx sync fills: activate its packages (from its quickstart file)."
  (let ((elpa (drgnx-elpa-dir)))
    (setq package-user-dir elpa
          package-gnupghome-dir (expand-file-name "gnupg" (drgnx-data-dir))
          use-package-ensure-function #'drgnx-pkg-ensure)
    (when (and (boundp 'native-comp-eln-load-path) (fboundp 'native-comp-available-p) (native-comp-available-p))
      (add-to-list 'native-comp-eln-load-path (expand-file-name "eln-cache/" (drgnx-data-dir))))
    ;; For good, not let-bound: package.el refreshes this file after a package the user installs.
    (setq package-quickstart t
          package-quickstart-file (expand-file-name "drgnx-quickstart.el" elpa))
    (when (file-directory-p elpa) (package-activate-all))))

;;;; use-package :ensure only records

(defun drgnx-pkg-wanted-file () (expand-file-name "packages-wanted.eld" (drgnx-state-dir)))

(defun drgnx-pkg--record-want (name)
  (unless (or (and (fboundp 'package-installed-p) (package-installed-p name))
              (locate-library (symbol-name name)))
    (let* ((file (drgnx-pkg-wanted-file))
           (old (and (file-readable-p file)
                     (ignore-errors (with-temp-buffer (insert-file-contents file) (read (current-buffer)))))))
      (unless (memq name old)
        (make-directory (file-name-directory file) t)
        (with-temp-file file (prin1 (append old (list name)) (current-buffer)))
        (message "drgnx: %s is not installed — drgnx sync installs it (until then its configuration waits)" name)))))

(defun drgnx-pkg-ensure (name &optional args &rest _)
  "`use-package-ensure-function': record what use-package would install for the next `drgnx sync'; nil.
ARGS are the :ensure values, read as use-package does: nil nothing, t NAME, a symbol that package,
\(PACKAGE :pin …) PACKAGE."
  (dolist (ensure (or args '(t)))
    (let ((package (if (eq ensure t) name ensure)))
      (when (consp package) (setq package (car package)))
      (when (stringp package) (setq package (intern package)))
      (when (and package (symbolp package)) (drgnx-pkg--record-want package))))
  nil)

;;;; The guard

(defconst drgnx-pkg--guarded
  '(package-install package-refresh-contents package-vc-install package-upgrade package-upgrade-all
                    package-vc-upgrade package-vc-upgrade-all package-reinstall package-install-selected-packages)
  "What reaches the network or installs: only a command the user runs may call these.")

(defun drgnx-pkg--in-timer-p ()
  (seq-some (lambda (f) (memq (cadr f) '(timer-event-handler internal-timer-start-idle))) (backtrace-frames)))

(defun drgnx-pkg--in-hook-p ()
  "Is a hook running (a hook runner is on the stack)?  A hook inside a user command (find-file, a mode) is
not the user asking to install."
  (seq-some (lambda (f) (memq (cadr f) '(run-hooks run-hook-with-args run-hook-with-args-until-success
                                                   run-hook-with-args-until-failure run-hook-wrapped run-mode-hooks)))
            (backtrace-frames)))

(defvar drgnx-guard--automatic)

(defun drgnx-pkg--automatic-context ()
  "Why the current context is not the user's own doing, or nil."
  (cond ((not after-init-time) "startup")
        ((null this-command) "automatic code")
        ((drgnx-pkg--in-timer-p) "a timer")
        ((bound-and-true-p drgnx-guard--automatic) "automatic code")
        ((drgnx-pkg--in-hook-p) "a hook")))

(defun drgnx-pkg--guard (orig &rest args)
  "Around ORIG (an install or refresh): signal when the call comes from startup, a timer, a hook or other
automatic code; a command the user runs (M-x, a menu button, M-:) may install."
  (if-let* ((why (drgnx-pkg--automatic-context)))
      (signal 'drgnx-pkg-error
              (list (format "drgnx installs packages only with `drgnx sync' or a command you run (refused %s %S from %s)"
                            (if (symbolp orig) orig "an install") args why)))
    (apply orig args)))

(define-minor-mode drgnx-pkg-guard-mode
  "Refuse package installs and archive refreshes from automatic code (timers, hooks, startup)."
  :global t :group 'drgnx
  (dolist (f drgnx-pkg--guarded)
    (if drgnx-pkg-guard-mode (advice-add f :around #'drgnx-pkg--guard) (advice-remove f #'drgnx-pkg--guard))))

(provide 'drgnx-pkg-activate)
;;; drgnx-pkg-activate.el ends here
