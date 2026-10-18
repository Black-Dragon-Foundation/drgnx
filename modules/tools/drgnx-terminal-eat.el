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

(defun drgnx-terminal-eat-start (dir)
  "A new eat terminal in DIR running the user's shell, shown by `pop-to-buffer' (the rules put it in the
panel); returns its buffer.  Its environment starts with `drgnx-terminal-environment'."
  (require 'eat)
  (let* ((default-directory (file-name-as-directory (expand-file-name dir)))
         (process-environment (append (drgnx-terminal-environment) process-environment))
         (buffer (generate-new-buffer "*eat*"))   ; *eat*, *eat*<2>, … (eat-make would reuse a running one)
         (ok nil))
    (unwind-protect
        (progn
          (with-current-buffer buffer (eat-mode))
          (eat-exec buffer "eat" (drgnx-terminal-shell) nil nil)
          (setq ok t))
      (unless ok (kill-buffer buffer)))
    (pop-to-buffer buffer)
    buffer))

;;;; Which keys reach drgnx, which the shell

(defcustom drgnx-terminal-skip-shell-commands '(go-quick-open)
  "Commands whose keys reach drgnx in a terminal even when they are readline keys (VS Code's \"skip shell\" list).
Quick Open is C-p in the VS Code profile, as in VS Code's own terminal; in the Emacs and Vim profiles nothing
takes C-p, so it reaches the shell.  Every other control or Alt key of an app or window command goes to the shell."
  :type '(repeat symbol) :group 'drgnx)

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
unless its command is in `drgnx-terminal-skip-shell-commands'; every other key reaches drgnx (as do the keys eat
leaves to Emacs: C-x, C-c, C-g, C-h, C-u, C-q, C-\\, M-x, M-:, M-!, M-&)."
  (let ((reserved (drgnx-terminal--eat-reserved)) to-drgnx to-shell)
    (dolist (b (drgnx-terminal--bindings))
      (let* ((key (plist-get b :key)) (event (aref (key-parse key) 0)))
        (if (and (drgnx-terminal--shell-event-p event)
                 (not (member (drgnx-terminal--eat-keys event) reserved))
                 (not (memq (plist-get b :id) drgnx-terminal-skip-shell-commands)))
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

(defun drgnx-terminal-cheatsheet-section ()
  "The key sheet's \"In the terminal\" section: (TITLE . LINES), or nil without eat or keys."
  (when (and (drgnx-modules--ok-p 'tools/terminal-eat) (drgnx-terminal--eat-default))
    (let* ((split (drgnx-terminal-key-split)) (to-drgnx (plist-get split :to-drgnx)) (to-shell (plist-get split :to-shell)))
      (when (or to-drgnx to-shell)
        (cons "In the terminal"
              (append (when to-drgnx (list (format "Reach drgnx: %s" (string-join to-drgnx ", "))))
                      (mapcar (lambda (k) (format "%s goes to the shell (%s: outside the terminal, or the palette)"
                                                  k (drgnx-terminal--key-title k)))
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
