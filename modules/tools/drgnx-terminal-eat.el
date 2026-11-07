;;; drgnx-terminal-eat.el --- Module tools/terminal-eat: a real terminal (eat) for New Terminal -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; New Terminal runs the user's shell in eat when this module has run (its package is synced); the
;; terminal's environment names this Emacs's server (`drgnx-terminal-environment').  Setup only sets
;; variables (eat's own once eat loads): eat itself loads when the first terminal starts.  In a terminal, the active key profile's
;; app and window keys reach drgnx and its editing keys go to the shell (`drgnx-terminal-key-split');
;; Ctrl+Shift+C/V copy and paste.  See docs/guide/modules.md and docs/guide/keys.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-gc)
(require 'drgnx-term (expand-file-name "drgnx-term" (file-name-directory (macroexp-file-name))))   ; the key split
(defvar drgnx-keys-last)
(defvar eat-semi-char-non-bound-keys)
(defvar eat-semi-char-mode-map)
(defvar eat-eshell-fallback-if-stty-not-available)
(defvar eat-query-before-killing-running-terminal)
(defvar eat-kill-buffer-on-exit)
(defvar eat-term-terminfo-directory)
(declare-function drgnx-terminal-environment "drgnx-terminal")
(declare-function drgnx-terminal-shell "drgnx-terminal")
(declare-function eat-mode "eat")
(declare-function eat-exec "eat")
(declare-function eat-term-make-keymap "eat")
(declare-function eat-self-input "eat")
(declare-function eat-update-semi-char-mode-map "eat")

;;;; Is a program running in the terminal?  (the quit and close-buffer questions)
;; Emacs asks before it stops a process whose query flag is set.  Eat sets it at every command (its shell
;; integration, etc/shell/drgnx.*) and clears it at every prompt; but it starts set, and without the integration
;; (declined) nothing ever clears it, so an idle shell would count as a running program.  So: the flag starts off,
;; and for a terminal whose shell has not sent a prompt mark the flag is "the shell has a child process".

(defvar-local drgnx-terminal-eat--shell nil "Non-nil in a terminal drgnx started for the user's shell.")
(defvar-local drgnx-terminal-eat--integrated nil "Non-nil once the shell in this terminal sent eat a prompt mark.")

(defun drgnx-terminal-eat--note-integration (&rest _)
  "After advice of `eat--pre-prompt' (it runs in the terminal buffer at every prompt mark): the shell reports."
  (setq drgnx-terminal-eat--integrated t))

(defvar drgnx-terminal-eat--ppids nil
  "During a refresh pass, a cons whose car is the parent pids of every process once the fallback scan ran (a hash table).")

(defun drgnx-terminal-eat--ppid-table ()
  "The parent pids of all processes, as a hash table; scanned once per refresh pass.
Local whatever `default-directory' is: process attributes of a TRAMP directory are the remote host's."
  (or (car drgnx-terminal-eat--ppids)
      (let ((default-directory "/") (table (make-hash-table)))
        (dolist (p (list-system-processes))
          (when-let* ((ppid (alist-get 'ppid (process-attributes p))))
            (puthash ppid t table)))
        (when drgnx-terminal-eat--ppids (setcar drgnx-terminal-eat--ppids table))
        table)))

(defun drgnx-terminal-eat--children-p (pid)
  "Non-nil when local process PID has a child process."
  (let ((default-directory "/")
        (file (format "/proc/%d/task/%d/children" pid pid)))
    (if (file-readable-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (string-match-p "[0-9]" (buffer-string)))
      (gethash pid (drgnx-terminal-eat--ppid-table)))))

(defun drgnx-terminal-eat--refresh (buffer)
  "Set the query flag of BUFFER's shell from its children, when eat's shell integration is not reporting."
  (when (and (buffer-live-p buffer) (buffer-local-value 'drgnx-terminal-eat--shell buffer)
             (eq (buffer-local-value 'eat-query-before-killing-running-terminal buffer) 'auto)
             (not (buffer-local-value 'drgnx-terminal-eat--integrated buffer)))
    (when-let* ((proc (get-buffer-process buffer))
                ((process-live-p proc)))
      (set-process-query-on-exit-flag proc (and (drgnx-terminal-eat--children-p (process-id proc)) t)))))

(defun drgnx-terminal-eat-refresh-query-flags ()
  "Bring the \"a program is running\" flag of every terminal shell up to date; no prompt, no waiting.
A shell whose integration reports (eat marked a prompt) keeps eat's own flag; any other is running when it has a
child process.  The quit question calls this before it collects the running programs."
  (let ((drgnx-terminal-eat--ppids (list nil)))
    (dolist (b (buffer-list)) (drgnx-terminal-eat--refresh b))))

(defvar drgnx-session-running-functions)

(defun drgnx-terminal-eat--refresh-for-quit ()
  "`drgnx-session-running-functions': bring the terminals' flags up to date before the quit question reads them;
names nothing (eat's shells are Emacs processes, which the question lists itself)."
  (drgnx-terminal-eat-refresh-query-flags)
  nil)

(defun drgnx-terminal-eat--refresh-before-kill ()
  "`kill-buffer-query-functions': refresh this terminal's flag before Emacs reads it; never vetoes."
  (drgnx-terminal-eat--refresh (current-buffer))
  t)

(defun drgnx-terminal-eat-start (dir &optional command)
  "A new eat terminal in DIR running the user's shell, shown by `pop-to-buffer' (the rules put it in the
panel); returns its buffer.  Its environment starts with `drgnx-terminal-environment'.  COMMAND (a program and
its arguments) runs instead of the shell, e.g. `drgnx secrets export' (Portability: Export Keys); its buffer
stays when it ends."
  (require 'eat)
  (let* ((default-directory (file-name-as-directory (expand-file-name dir)))
         (process-environment (append (drgnx-terminal-environment) process-environment))
         (buffer (generate-new-buffer "*eat*"))   ; *eat*, *eat*<2>, … (eat-make would reuse a running one)
         (ok nil))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (eat-mode)
            (setq drgnx-terminal-eat--shell (not command))
            (when command (setq-local eat-kill-buffer-on-exit nil)))   ; what the command printed stays readable
          (eat-exec buffer "eat" (if command (car command) (drgnx-terminal-shell)) nil (cdr command))
          (when (and (not command) (eq eat-query-before-killing-running-terminal 'auto))
            (set-process-query-on-exit-flag (get-buffer-process buffer) nil))   ; idle until a command or a child says not
          (setq ok t))
      (unless ok (kill-buffer buffer)))
    (pop-to-buffer buffer)
    buffer))

;;;; Garbage collections off the typing path
;; Eat's terminal emulation allocates about 520 bytes per line of output (for each text segment it writes, about 470 bytes:
;; 14 conses, 3 intervals, 10 vector cells and a string; the line feed adds a cons: measured in the perf lab), so a terminal
;; flooding output hands Emacs 20 to 30 MB of garbage a second and a collection every ~2 s.  The collection is run by
;; whichever code allocates when the threshold is crossed, and the keystroke's own handling is as likely a candidate as
;; eat's batch: a ~50 ms pause inside a keystroke.  Eat's latency settings and its scrollback do not change the amount
;; (the garbage is per line written), and eat's writer is not ours to rewrite.  So the pause is taken at a moment of our
;; choosing: after one of eat's output batches, through the GC owner's `drgnx-gc-gap' (core/drgnx-gc.el): when no key was
;; handled in the last `drgnx-gc-gap-quiet' seconds, none is waiting to be read, and most of the threshold has been consed.
;; The natural collection stays as the backstop and the threshold is unchanged.  This does not shorten the pause or the
;; garbage; it keeps the pause out of a keystroke's own handling (a key that arrives during it still waits).

(defun drgnx-terminal-eat--collect-in-gap (&rest _)
  "After advice of `eat--process-output-queue': an output batch ended, so this is a gap; `drgnx-gc-gap' collects when it
is quiet (no key handled in `drgnx-gc-gap-quiet', none waiting) and the threshold is nearly reached."
  (drgnx-gc-gap))

;;;; Which keys reach drgnx, which the shell (the split itself is the terminal's: `drgnx-terminal-key-split')

(defvar drgnx-terminal--eat-default-non-bound nil
  "Eat's `eat-semi-char-non-bound-keys' as it was when eat loaded (set once, by `drgnx-terminal-apply-keys').")

(defun drgnx-terminal--eat-default ()
  "Eat's own non-bound keys, captured once eat is loaded; nil when eat is not there."
  (or drgnx-terminal--eat-default-non-bound
      (when (require 'eat nil t)
        (setq drgnx-terminal--eat-default-non-bound (default-value 'eat-semi-char-non-bound-keys)))))

(defun drgnx-terminal--eat-reserved ()
  "Keys eat leaves to Emacs: its non-bound list, and C-c (a prefix there: C-c C-c sends, other C-c keys are Emacs's)."
  (cons [?\C-c] (drgnx-terminal--eat-default)))

(defun drgnx-terminal-apply-keys (&rest _)
  "Make eat's semi-char keymap leave the keys that reach drgnx to drgnx.
Eat's own list plus the first events of `:to-drgnx' that eat would send to the shell; the keymap is rebuilt and
put into `minor-mode-map-alist' (the alist keeps the old map).  Runs when eat loads and after `drgnx-keys-apply'."
  (when (featurep 'eat)
    (let* ((default (drgnx-terminal--eat-default))
           (reference (eat-term-make-keymap #'eat-self-input '(:ascii :arrow :navigation) nil))
           (extra nil))
      (dolist (key (plist-get (drgnx-terminal-key-split (drgnx-terminal--eat-reserved)) :to-drgnx))
        (let ((keys (drgnx-terminal--keys-vector (aref (key-parse key) 0))))
          (when (and (not (member keys (drgnx-terminal--eat-reserved))) (commandp (lookup-key reference keys)))
            (cl-pushnew keys extra :test #'equal))))
      (setq-default eat-semi-char-non-bound-keys (append default (nreverse extra)))
      (eat-update-semi-char-mode-map)
      (when-let* ((cell (assq 'eat--semi-char-mode minor-mode-map-alist)))
        (setcdr cell eat-semi-char-mode-map)))))

(defun drgnx-terminal-eat--doctor ()
  "Problems that make eat ask or fail (eat is not loaded for this: its terminfo is found beside its library)."
  (let ((terminfo (if (boundp 'eat-term-terminfo-directory) eat-term-terminfo-directory
                    (when-let* ((lib (locate-library "eat"))) (expand-file-name "terminfo" (file-name-directory lib))))))
    (append (when (eq (bound-and-true-p eat-eshell-fallback-if-stty-not-available) 'ask)
              (list "eat would ask when stty is missing (eat-eshell-fallback-if-stty-not-available is ask)"))
            (unless (and terminfo (file-directory-p terminfo))
              (list "eat's terminfo is missing: drgnx sync")))))

(defun drgnx-terminal-eat--options ()
  "Eat's options as drgnx wants them, set once eat is loaded (so turning the module off gives eat's own back)."
  ;; never `ask' (a hidden prompt freezes the daemon); drgnx's quit asks once about running programs
  (drgnx-module-set 'eat-eshell-fallback-if-stty-not-available nil)
  (drgnx-module-set 'eat-query-before-killing-running-terminal 'auto)
  (drgnx-module-set 'eat-kill-buffer-on-exit t))

(defun drgnx-terminal-eat--teardown ()
  "Eat's own keys again: its semi-char map leaves only its own non-bound keys to Emacs (`drgnx-terminal-apply-keys'
added the keys that reach drgnx).  The options, hooks and advice are recorded."
  (when (and (featurep 'eat) drgnx-terminal--eat-default-non-bound)
    (setq-default eat-semi-char-non-bound-keys drgnx-terminal--eat-default-non-bound)
    (eat-update-semi-char-mode-map)
    (when-let* ((cell (assq 'eat--semi-char-mode minor-mode-map-alist)))
      (setcdr cell eat-semi-char-mode-map))))

(drgnx-module-define 'tools/terminal-eat
                     :doc "New Terminal is your shell in a real terminal (eat)."
                     :stage 'startup :requires '(tools/terminal) :packages '(eat)
                     :doctor #'drgnx-terminal-eat--doctor
                     :teardown #'drgnx-terminal-eat--teardown
                     :setup
                     (lambda ()
                       (add-hook 'kill-buffer-query-functions #'drgnx-terminal-eat--refresh-before-kill -90)
                       (add-hook 'drgnx-session-running-functions #'drgnx-terminal-eat--refresh-for-quit)
                       (advice-add 'eat--pre-prompt :after #'drgnx-terminal-eat--note-integration)
                       (advice-add 'eat--process-output-queue :after #'drgnx-terminal-eat--collect-in-gap)
                       ;; eat's options, and which keys reach drgnx and which the shell: now if eat is loaded, else
                       ;; when it loads
                       (eval-after-load 'eat (drgnx-modules-with-owner
                                               (drgnx-terminal-eat--options)
                                               (drgnx-terminal-apply-keys)))
                       (advice-add 'drgnx-keys-apply :after #'drgnx-terminal-apply-keys)))

(provide 'drgnx-terminal-eat)
;;; drgnx-terminal-eat.el ends here
