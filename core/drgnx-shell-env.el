;;; drgnx-shell-env.el --- the login shell's environment in the daemon -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A daemon started by systemd, launchd or the macOS app lacks the PATH your login shell sets (~/.local/bin, mise
;; shims, cargo).  At start drgnx asks the login shell once — asynchronously, with a timeout, its input closed at
;; once — and takes PATH, MANPATH and INFOPATH (plus `drgnx-shell-env-extra-names') into this Emacs; never a key.
;; A running hub is sent the new PATH (`env/set'), so what it starts next finds the programs too.
;; See docs/guide/shell.md ("Your PATH in drgnx").

;;; Code:
(require 'seq)
(require 'subr-x)
(require 'drgnx-timer)

(declare-function drgnx-command-define "drgnx-registry")
(declare-function drgnx-ai-providers "drgnx-ai")
(declare-function drgnx-hub-running-p "drgnx-hub-client")
(declare-function drgnx-hub-call "drgnx-hub-client")

(defcustom drgnx-shell-env-names '("PATH" "MANPATH" "INFOPATH")
  "The variables drgnx takes from your login shell at start (`drgnx-shell-env-start')."
  :type '(repeat string) :group 'drgnx)

(defcustom drgnx-shell-env-extra-names nil
  "More variables to take from your login shell, besides `drgnx-shell-env-names'.  A key never is: a name
`drgnx-shell-env-refused-p' refuses is skipped also when listed here."
  :type '(repeat string) :group 'drgnx)

(defcustom drgnx-shell-env-timeout 5
  "Seconds your login shell may take to print its environment; after that it is stopped and nothing changes."
  :type 'number :group 'drgnx)

(defconst drgnx-shell-env--refused-re "\\(KEY\\|TOKEN\\|SECRET\\|PASSWORD\\|PASSPHRASE\\|CREDENTIALS?\\)"
  "Names never taken from the shell (case does not matter): keys come from the keyring.")

(defconst drgnx-shell-env--begin "\036drgnx-env-begin\n")
(defconst drgnx-shell-env--end "\036drgnx-env-end\n")

(defconst drgnx-shell-env--max-output (* 4 1024 1024)
  "Bytes a shell may print before it is stopped (an rc file that loops).")

(defun drgnx-shell-env-refused-p (name)
  "Is NAME never to be taken from the shell: any provider's key variable, or a name that looks like a secret?"
  (or (let ((case-fold-search t)) (string-match-p drgnx-shell-env--refused-re name))
      (and (require 'drgnx-ai nil t)
           (member name (delq nil (mapcar (lambda (p) (plist-get (cdr p) :key-env))
                                          (ignore-errors (drgnx-ai-providers)))))
           t)))

(defun drgnx-shell-env--names ()
  "The names to take: `drgnx-shell-env-names' and the extra ones, none refused."
  (seq-remove #'drgnx-shell-env-refused-p (delete-dups (append drgnx-shell-env-names drgnx-shell-env-extra-names nil))))

(defun drgnx-shell-env-command (shell)
  "The command that has SHELL, as a login and interactive shell, print its environment between two markers.
printf is the same in sh-like shells and fish."
  (list shell "-l" "-i" "-c" "printf '\\036drgnx-env-begin\\n'; env; printf '\\036drgnx-env-end\\n'"))

(defun drgnx-shell-env-parse (output names)
  "((NAME . VALUE)…) for NAMES, from the lines between the last begin marker in OUTPUT and the end marker after it
\(a prompt theme or an rc file may print anything around them); nil when either marker is missing.  A refused name
is never in it."
  (let ((i 0) start)
    (while (setq i (string-search drgnx-shell-env--begin output i))
      (setq i (+ i (length drgnx-shell-env--begin)) start i))
    (when-let* ((start start)
                (end (string-search drgnx-shell-env--end output start)))
      (let (alist)
        (dolist (line (split-string (substring output start end) "\n" t))
          (when-let* ((eq (string-search "=" line))
                      (name (substring line 0 eq))
                      ((member name names))
                      ((not (assoc name alist)))
                      ((not (drgnx-shell-env-refused-p name))))
            (push (cons name (substring line (1+ eq))) alist)))
        (nreverse alist)))))

(defun drgnx-shell-env-apply (alist)
  "Set ALIST's ((NAME . VALUE)…) in this Emacs: PATH is the shell's dirs, then this Emacs's dirs not among them,
and `exec-path' follows; other names are replaced.  The names that changed."
  (let (changed)
    (dolist (c alist)
      (let* ((name (car c)) (old (getenv name))
             (new (if (equal name "PATH")
                      (string-join (delete-dups (append (split-string (cdr c) path-separator t)
                                                        (and old (split-string old path-separator t))))
                                   path-separator)
                    (cdr c))))
        (unless (equal old new)
          (setenv name new)
          (push name changed))))
    (when (member "PATH" changed)
      (setq exec-path (append (parse-colon-path (getenv "PATH")) (list exec-directory))))
    (nreverse changed)))

(defun drgnx-shell-env--fail (why)
  "Say, in one line, that the shell's environment was not read, and WHY (never its output)."
  (message "drgnx: your login shell's environment was not read (%s)" why))

(defun drgnx-shell-env--skip-reason ()
  "Why the shell's environment is not read in this Emacs, or nil."
  (cond (noninteractive "a batch Emacs")
        ((eq system-type 'windows-nt) "Windows")
        ((let ((v (getenv "DRGNX_NO_SHELL_ENV"))) (and v (not (string-empty-p v)))) "DRGNX_NO_SHELL_ENV is set")))

(defun drgnx-shell-env--tell-hub (alist)
  "Send a running hub ALIST, so the agents and jobs it starts from now on get the new PATH.  Never an error."
  (condition-case nil
      (progn (require 'drgnx-hub-client)
             (when (drgnx-hub-running-p)
               (drgnx-hub-call "env/set"
                               (list :env (mapcan (lambda (c) (list (intern (concat ":" (car c))) (cdr c))) alist))
                               #'ignore)))
    (error nil)))

(defun drgnx-shell-env--finish (output why callback)
  "The shell is done: OUTPUT parsed and applied unless WHY says it failed; the hub told; CALLBACK given the names
that changed."
  (condition-case err
      (let ((alist (and (not why) (drgnx-shell-env-parse output (drgnx-shell-env--names)))))
        (if (not alist)
            (drgnx-shell-env--fail (or why "it printed no environment"))
          (let ((changed (drgnx-shell-env-apply alist)))
            (when (member "PATH" changed) (drgnx-shell-env--tell-hub alist))
            (when callback (funcall callback changed)))))
    (error (drgnx-shell-env--fail (error-message-string err)))))

(defun drgnx-shell-env--timed-out (p)
  "The deadline of the shell process P (`drgnx-shell-env-start'): say why, and end it (its sentinel says so)."
  (when (process-live-p p)
    (process-put p :why (format "no answer in %s s" drgnx-shell-env-timeout))
    (ignore-errors (kill-process p))))

(defun drgnx-shell-env-start (&optional callback)
  "Ask your login shell ($SHELL) for its environment and take `drgnx-shell-env-names' (and the extra names) from
it, without waiting: the process, or nil when skipped (a batch Emacs, Windows, DRGNX_NO_SHELL_ENV set) or it could
not start.  The shell's input is closed at once and it is stopped after `drgnx-shell-env-timeout'; it never asks
anything.  When PATH changed and a hub runs, the hub gets it too.  CALLBACK gets the names that changed; a failure is
one line in *Messages*."
  (unless (drgnx-shell-env--skip-reason)
    (condition-case err
        (let* ((shell (or (getenv "SHELL") shell-file-name))
               (default-directory (file-name-as-directory (expand-file-name "~")))
               (chunks nil) (size 0) (why nil)
               (proc (make-process
                      :name "drgnx-shell-env" :command (drgnx-shell-env-command shell) :connection-type 'pipe
                      :noquery t :buffer nil :coding 'utf-8-unix
                      :filter (lambda (p s)
                                (if (<= (setq size (+ size (length s))) drgnx-shell-env--max-output)
                                    (push s chunks)
                                  (setq why "it printed too much")
                                  (ignore-errors (kill-process p))))
                      :sentinel (lambda (p _event)
                                  (unless (process-live-p p)
                                    (drgnx-timer-cancel (cons 'shell-env-timeout p))
                                    (let ((output (apply #'concat (nreverse chunks))))
                                      (setq chunks nil)
                                      (drgnx-shell-env--finish output (or why (process-get p :why)) callback)))))))
          (drgnx-timer-start (cons 'shell-env-timeout proc) drgnx-shell-env-timeout #'drgnx-shell-env--timed-out
                             :args (list proc) :owner proc)
          (ignore-errors (process-send-eof proc))   ; a fast shell may have exited already: its sentinel has the answer
          proc)
      (error (drgnx-shell-env--fail (error-message-string err)) nil))))

(defun drgnx-shell-env-reload ()
  "Read your login shell's environment again, and say what changed."
  (interactive)
  (if (drgnx-shell-env-start
       (lambda (changed)
         (message (if changed "drgnx: from your login shell: %s" "drgnx: nothing changed: this Emacs has your login shell's %s")
                  (string-join (or changed (drgnx-shell-env--names)) ", "))))
      (message "drgnx: reading your login shell's environment…")
    (message "drgnx: your login shell's environment is not read here (%s)" (or (drgnx-shell-env--skip-reason) "see *Messages*"))))

(defun drgnx-shell-env-register-commands ()
  "Shell: Reload Environment, in the registry."
  (drgnx-command-define 'shell-reload-environment :category "Shell" :title "Reload Environment"
                        :command #'drgnx-shell-env-reload
                        :doc "Take PATH, MANPATH and INFOPATH from your login shell again (after you changed it)"))

(provide 'drgnx-shell-env)
;;; drgnx-shell-env.el ends here
