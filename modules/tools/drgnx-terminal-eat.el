;;; drgnx-terminal-eat.el --- Module tools/terminal-eat: a real terminal (eat) for New Terminal -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; New Terminal runs the user's shell in eat when this module has run (its package is synced); the
;; terminal's environment names this Emacs's server (`drgnx-terminal-environment').  Setup only sets
;; variables: eat itself loads when the first terminal starts.  In a terminal, the active key profile's
;; app and window keys reach drgnx and its editing keys go to the shell (`drgnx-terminal-key-split');
;; Ctrl+Shift+C/V copy and paste.  See docs/guide/modules.md and docs/guide/keys.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-gc)
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
(declare-function eat-yank "eat")
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

;;;; Which keys reach drgnx, which the shell

(defcustom drgnx-terminal-skip-shell-keys '("C-p" "C-b" "C-k" "C-f")
  "First keys that reach drgnx in a terminal even though readline uses them: VS Code's commandsToSkipShell.
Quick Open (C-p), Toggle Sidebar (C-b), every C-k chord, and Find (C-f, which searches the terminal's text).
It only applies to keys the active key stack binds to an app or window command, so the Emacs and Vim profiles,
which bind none of them, leave these keys to the shell.  Every other control or Alt key of such a command goes to
the shell.  Key descriptions of one event, e.g. \"C-p\" or \"M-j\"."
  :type '(repeat string) :group 'drgnx)

(defconst drgnx-terminal--meta-bit #x8000000 "The meta modifier bit of an event.")

(defvar drgnx-terminal--eat-default-non-bound nil
  "Eat's `eat-semi-char-non-bound-keys' as it was when eat loaded (set once, by `drgnx-terminal-apply-keys').")

(defvar drgnx-surfaces-cheatsheet-sections nil
  "Abnormal hook of the key sheet: each function returns (TITLE . LINES) or nil; shown after \"Key problems\".")

(defun drgnx-terminal--eat-default ()
  "Eat's own non-bound keys, captured once eat is loaded; nil when eat is not there."
  (or drgnx-terminal--eat-default-non-bound
      (when (require 'eat nil t)
        (setq drgnx-terminal--eat-default-non-bound (default-value 'eat-semi-char-non-bound-keys)))))

(defun drgnx-terminal--eat-reserved ()
  "Keys eat leaves to Emacs: its non-bound list, and C-c (a prefix there: C-c C-c sends, other C-c keys are Emacs's)."
  (cons [?\C-c] (drgnx-terminal--eat-default)))

(defun drgnx-terminal--eat-keys (event)
  "EVENT as eat's keys vector: M-x is [?\\e ?x]."
  (if (and (integerp event) (/= 0 (logand event drgnx-terminal--meta-bit)))
      (vector ?\e (logand event (lognot drgnx-terminal--meta-bit)))
    (vector event)))

(defun drgnx-terminal--shell-event-p (event)
  "Non-nil when EVENT is an ASCII character, control or plain, or M- plus one: what readline and zle mean."
  (and (integerp event) (<= 0 (logand event (lognot drgnx-terminal--meta-bit)) 127)))

(defun drgnx-terminal--bindings ()
  "Global bindings (plists of `drgnx-keys-last') of the active stack's app and window commands."
  (seq-filter (lambda (b)
                (and (memq (plist-get b :map) '(nil global-map))
                     (let ((cmd (drgnx-commands-get (plist-get b :id))))
                       (and cmd (memq (drgnx-cmd-scope cmd) '(app window))))))
              (plist-get drgnx-keys-last :bindings)))

(defun drgnx-terminal-key-split ()
  "Where the active key profile's keys go in a terminal: (:to-drgnx KEYS :to-shell KEYS), key strings.
Only global bindings of commands with scope app or window count.  A key whose first event is an ASCII control
or Alt character that eat sends to the shell goes to the shell (C-a, C-e, C-w, C-k, M-f as readline mean them),
unless its first key is in `drgnx-terminal-skip-shell-keys'; every other key reaches drgnx (as do the keys eat
leaves to Emacs: C-x, C-c, C-g, C-h, C-u, C-q, C-\\, M-x, M-:, M-!, M-&)."
  (let ((reserved (drgnx-terminal--eat-reserved)) to-drgnx to-shell)
    (dolist (b (drgnx-terminal--bindings))
      (let* ((key (plist-get b :key)) (event (aref (key-parse key) 0)))
        (if (and (drgnx-terminal--shell-event-p event)
                 (not (member (drgnx-terminal--eat-keys event) reserved))
                 (not (member (key-description (vector event)) drgnx-terminal-skip-shell-keys)))
            (cl-pushnew key to-shell :test #'equal)
          (cl-pushnew key to-drgnx :test #'equal))))
    (list :to-drgnx (nreverse to-drgnx) :to-shell (nreverse to-shell))))

(defun drgnx-terminal-apply-keys (&rest _)
  "Make eat's semi-char keymap leave the keys that reach drgnx to drgnx (and so the key sheet's \"In the terminal\").
Eat's own list plus the first events of `:to-drgnx' that eat would send to the shell; the keymap is rebuilt and
put into `minor-mode-map-alist' (the alist keeps the old map).  Runs when eat loads and after `drgnx-keys-apply'."
  (when (featurep 'eat)
    (let* ((default (drgnx-terminal--eat-default))
           (reference (eat-term-make-keymap #'eat-self-input '(:ascii :arrow :navigation) nil))
           (extra nil))
      (dolist (key (plist-get (drgnx-terminal-key-split) :to-drgnx))
        (let ((keys (drgnx-terminal--eat-keys (aref (key-parse key) 0))))
          (when (and (not (member keys (drgnx-terminal--eat-reserved))) (commandp (lookup-key reference keys)))
            (cl-pushnew keys extra :test #'equal))))
      (setq-default eat-semi-char-non-bound-keys (append default (nreverse extra)))
      (eat-update-semi-char-mode-map)
      (when-let* ((cell (assq 'eat--semi-char-mode minor-mode-map-alist)))
        (setcdr cell eat-semi-char-mode-map)))))

(defun drgnx-terminal--key-title (key)
  "The title of the first command the active stack binds KEY to."
  (when-let* ((b (seq-find (lambda (b) (equal (plist-get b :key) key)) (drgnx-terminal--bindings)))
              (cmd (drgnx-commands-get (plist-get b :id))))
    (drgnx-cmd-title cmd)))

(defun drgnx-terminal--collapse-chords (keys)
  "KEYS with the chords of one first key (two or more, e.g. C-k C-s and C-k C-o) shown once, as \"C-k chords\"."
  (let (seen out)
    (dolist (k keys)
      (let* ((v (key-parse k)) (prefix (key-description (vector (aref v 0)))))
        (if (or (< (length v) 2)
                (= 1 (seq-count (lambda (k2) (let ((v2 (key-parse k2))) (and (> (length v2) 1) (equal (aref v2 0) (aref v 0)))))
                                keys)))
            (push k out)
          (unless (member prefix seen)
            (push prefix seen)
            (push (concat prefix " chords") out)))))
    (nreverse out)))

(defun drgnx-terminal-cheatsheet-section ()
  "The key sheet's \"In the terminal\" section: (TITLE . LINES), or nil without eat or keys."
  (when (and (drgnx-modules--ok-p 'tools/terminal-eat) (drgnx-terminal--eat-default))
    (let* ((split (drgnx-terminal-key-split))
           (to-drgnx (drgnx-terminal--collapse-chords (plist-get split :to-drgnx)))
           (to-shell (drgnx-terminal--collapse-chords (plist-get split :to-shell))))
      (when (or to-drgnx to-shell)
        (cons "In the terminal"
              (append (when to-drgnx (list (format "Reach drgnx: %s" (string-join to-drgnx ", "))))
                      (mapcar (lambda (k)
                                (let ((title (drgnx-terminal--key-title k)))   ; nil for "C-k chords"
                                  (format "%s goes to the shell (%soutside the terminal, or the palette)"
                                          k (if title (concat title ": ") ""))))
                              to-shell)))))))

(defun drgnx-terminal--sheet-sections (&rest _)
  "Append the `drgnx-surfaces-cheatsheet-sections' to the key sheet unless it shows them itself (after \"Key problems\")."
  (when-let* ((buffer (get-buffer "*drgnx keys*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (save-excursion
          (dolist (fn drgnx-surfaces-cheatsheet-sections)
            (pcase (funcall fn)
              (`(,title . ,lines)
               (when (and lines (not (save-excursion (goto-char (point-min)) (search-forward (concat "\n" title "\n") nil t))))
                 (goto-char (point-max))
                 (insert "\n" (propertize title 'face 'drgnx-sheet-heading) "\n")
                 (dolist (l lines) (insert "  " l "\n")))))))))))

(defun drgnx-terminal-copy ()
  "Copy the selected text of the terminal to the kill ring and deselect it; with no selection do nothing."
  (interactive)
  (when (use-region-p)
    (copy-region-as-kill (region-beginning) (region-end))
    (deactivate-mark)))

(defun drgnx-terminal--in-terminal-p () (derived-mode-p 'eat-mode))

(defun drgnx-terminal-eat--doctor ()
  "Problems that make eat ask or fail (eat is not loaded for this: its terminfo is found beside its library)."
  (let ((terminfo (if (boundp 'eat-term-terminfo-directory) eat-term-terminfo-directory
                    (when-let* ((lib (locate-library "eat"))) (expand-file-name "terminfo" (file-name-directory lib))))))
    (append (when (eq eat-eshell-fallback-if-stty-not-available 'ask)
              (list "eat would ask when stty is missing (eat-eshell-fallback-if-stty-not-available is ask)"))
            (unless (and terminfo (file-directory-p terminfo))
              (list "eat's terminfo is missing: drgnx sync")))))

(drgnx-module-define 'tools/terminal-eat
                     :doc "New Terminal is your shell in a real terminal (eat)."
                     :stage 'startup :requires '(tools/terminal) :packages '(eat)
                     :doctor #'drgnx-terminal-eat--doctor
                     :setup
                     (lambda ()
                       ;; never `ask' (a hidden prompt freezes the daemon); drgnx's quit asks once about running programs
                       (setq-default eat-eshell-fallback-if-stty-not-available nil
                                     eat-query-before-killing-running-terminal 'auto
                                     eat-kill-buffer-on-exit t)
                       (add-hook 'kill-buffer-query-functions #'drgnx-terminal-eat--refresh-before-kill -90)
                       (advice-add 'eat--pre-prompt :after #'drgnx-terminal-eat--note-integration)
                       (advice-add 'eat--process-output-queue :after #'drgnx-terminal-eat--collect-in-gap)
                       ;; which keys reach drgnx and which the shell: now if eat is loaded, else when it loads
                       (with-eval-after-load 'eat (drgnx-terminal-apply-keys))
                       (advice-add 'drgnx-keys-apply :after #'drgnx-terminal-apply-keys)
                       (add-hook 'drgnx-surfaces-cheatsheet-sections #'drgnx-terminal-cheatsheet-section)
                       (advice-add 'drgnx-surfaces-cheatsheet :after #'drgnx-terminal--sheet-sections)
                       (drgnx-command-define 'terminal-copy :category "Terminal" :title "Copy" :scope 'editing
                                             :command #'drgnx-terminal-copy :map '(eat . eat-mode-map)
                                             :when #'drgnx-terminal--in-terminal-p
                                             :doc "Copy the selected text of the terminal to the kill ring")
                       (drgnx-command-define 'terminal-paste :category "Terminal" :title "Paste" :scope 'editing
                                             :command #'eat-yank :map '(eat . eat-mode-map)
                                             :when #'drgnx-terminal--in-terminal-p
                                             :doc "Paste the kill ring into the terminal")))

(provide 'drgnx-terminal-eat)
;;; drgnx-terminal-eat.el ends here
