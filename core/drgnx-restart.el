;;; drgnx-restart.el --- Restart drgnx from the editor -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-restart' asks the quit questions first (`drgnx-session-quit-confirm': save, lose changes?), and on a yes starts
;; a waiter that outlives this Emacs and opens drgnx again once it has ended, then quits.  A no or C-g leaves drgnx
;; running and nothing waiting.  A session that is the daemon of drgnx.service is restarted by the service manager
;; instead (`systemctl --user restart drgnx'), as `drgnx sync' advises; on macOS the daemon of drgnx's launch agent by
;; launchd (`launchctl kickstart -k').  The waiter is a transient systemd unit under
;; systemd (a plain detached process would die with the unit's cgroup), a detached process otherwise.

;;; Code:
(require 'subr-x)
(require 'drgnx-paths)

(declare-function drgnx-session-quit-confirm "drgnx-session" ())

(defvar drgnx-restart--setsid (executable-find "setsid") "setsid(1) where the system has it (Linux; macOS has none).")

(defun drgnx-restart--cgroup ()
  "The control group of this process (the text of /proc/self/cgroup), or nil where there is none."
  (when (file-readable-p "/proc/self/cgroup")
    (with-temp-buffer (insert-file-contents "/proc/self/cgroup") (buffer-string))))

(defun drgnx-restart--service-p ()
  "Non-nil when this Emacs is the daemon of drgnx.service: it runs under systemd (INVOCATION_ID) in that unit's cgroup."
  (let ((id (getenv "INVOCATION_ID")))
    (and id (not (string-empty-p id)) (string-search "drgnx.service" (or (drgnx-restart--cgroup) "")) t)))

(defconst drgnx-restart--agent-label "org.blackdragonfoundation.drgnx" "The launchd label of drgnx's daemon (core/drgnx-pkg.el).")

(defun drgnx-restart--agent-p ()
  "Non-nil when this Emacs is the daemon of drgnx's launch agent (macOS): launchd names its job in XPC_SERVICE_NAME."
  (equal (getenv "XPC_SERVICE_NAME") drgnx-restart--agent-label))

(defun drgnx-restart--under-systemd-p ()
  "Non-nil when this Emacs belongs to a systemd unit and a user manager can start another."
  (let ((id (getenv "INVOCATION_ID")))
    (and id (not (string-empty-p id)) (getenv "XDG_RUNTIME_DIR") (executable-find "systemd-run") t)))

(defun drgnx-restart--detach (argv)
  "Start ARGV in its own session, not waited for, outliving this Emacs: `setsid -f' where there is one, else perl
\(every macOS has it; it forks first, as `setsid -f' does, because Emacs's child leads its own process group)."
  (if drgnx-restart--setsid
      (apply #'call-process "setsid" nil 0 nil "-f" argv)
    (apply #'call-process "perl" nil 0 nil "-MPOSIX" "-e" "fork and exit; POSIX::setsid(); exec @ARGV" argv)))

(defun drgnx-restart--spawn (argv &optional unit)
  "Start ARGV so that it outlives this Emacs.  With UNIT (a name) and systemd, as a transient unit of the user manager
\(KillMode=process: what it starts stays); the detached way is also the fallback."
  (unless (and unit (drgnx-restart--under-systemd-p)
               (eql 0 (apply #'call-process "systemd-run" nil nil nil "--user" "--quiet" "--collect"
                             (format "--unit=%s" unit) "-p" "KillMode=process"
                             ;; a unit's ExecStart reads $ and % itself
                             (mapcar (lambda (a) (replace-regexp-in-string "[$%]" "\\&\\&" a)) argv))))
    (drgnx-restart--detach argv)))

(defun drgnx-restart--waiter ()
  "The shell line that waits for this Emacs to end (a minute at most), then opens drgnx unless something else did."
  (format "sleep 1; i=0; while kill -0 %d 2>/dev/null && [ $i -lt 300 ]; do sleep 0.2; i=$((i+1)); done; kill -0 %d 2>/dev/null || exec %s open"
          (emacs-pid) (emacs-pid) (shell-quote-argument (expand-file-name "bin/drgnx" drgnx-dir))))

;;;###autoload
(defun drgnx-restart ()
  "Restart drgnx: ask the quit questions first, then — only on a yes — restart it.  The layout comes back with drgnx
open.  A no or C-g leaves drgnx running."
  (interactive)
  (unless (fboundp 'drgnx-session-quit-confirm) (require 'drgnx-session))
  (when (drgnx-session-quit-confirm)
    (cond
     ((drgnx-restart--service-p) (drgnx-restart--spawn '("systemctl" "--user" "restart" "drgnx")))
     ;; kickstart -k kills the job and starts it again: launchd's restart
     ((drgnx-restart--agent-p)
      (drgnx-restart--spawn (list "launchctl" "kickstart" "-k" (format "gui/%d/%s" (user-uid) drgnx-restart--agent-label))))
     (t
      (drgnx-restart--spawn (list "sh" "-c" (drgnx-restart--waiter)) (format "drgnx-restart-%d" (emacs-pid)))
      (kill-emacs)))))

(provide 'drgnx-restart)
;;; drgnx-restart.el ends here
