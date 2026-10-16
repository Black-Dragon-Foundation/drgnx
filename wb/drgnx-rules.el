;;; drgnx-rules.el --- Where buffers go: the rules table -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Every buffer Emacs displays goes to a *place* — the editor, a dock, a panel tab, the popup
;; lane — chosen by one table of rules (`drgnx-wb-place').  The table is one entry at the end of
;; `display-buffer-alist', so the user's own entries and explicit actions still win.  A buffer no
;; rule matches goes to the editor and is logged in `drgnx-wb-unrouted' (a rule is missing).
;; Internal buffers (names starting with a space) are left alone unless a rule names them.
;; `drgnx-rules-mode' also sets the window defaults that keep Emacs from splitting or resizing
;; on its own.  See docs/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wb)

(defvar drgnx-rules--table nil
  "Rules, tried first to last: (MATCHER PLACE . PROPS).  `drgnx-wb-place' puts new ones first.")
(defvar drgnx-rules--places nil "Alist PLACE → function (BUFFER ALIST PROPS) → window or nil.")
(defvar drgnx-wb-unrouted nil "Buffers no rule matched, newest first: plists (:buffer :mode :time).")
(defconst drgnx-rules--unrouted-max 200)

(defun drgnx-wb-place (matcher place &rest props)
  "Send buffers matching MATCHER to PLACE (with PROPS, e.g. :tab).  Returns MATCHER.
MATCHER: a major-mode symbol or a list of them (derived modes match too), a buffer-name regexp,
or a predicate (a lambda, not a symbol) called with the buffer name and the display action.
Later rules are tried first; a rule with the same MATCHER is replaced where it stands."
  (if-let* ((cell (assoc matcher drgnx-rules--table)))
      (setcdr cell (cons place props))
    (push (cons matcher (cons place props)) drgnx-rules--table))
  matcher)

(defun drgnx-wb-define-place (place fn)
  "Define PLACE: FN takes (BUFFER ALIST PROPS) and returns the window it showed BUFFER in, or nil."
  (setf (alist-get place drgnx-rules--places) fn)
  place)

(defun drgnx-rules--internal-p (name) (string-prefix-p " " name))

(defun drgnx-rules--match-p (matcher name buffer action)
  (cond ((stringp matcher) (string-match-p matcher name))
        ((drgnx-rules--internal-p name) nil)          ; internal buffers: only a name rule takes them
        ((or (symbolp matcher) (and (consp matcher) (seq-every-p #'symbolp matcher)))
         (and buffer (with-current-buffer buffer (apply #'derived-mode-p (ensure-list matcher)))))
        ((functionp matcher) (funcall matcher name action))))

(defun drgnx-wb-rule-for (buffer-or-name &optional action)
  "The (PLACE . PROPS) of the first rule matching BUFFER-OR-NAME, or nil."
  (let* ((name (if (bufferp buffer-or-name) (buffer-name buffer-or-name) buffer-or-name))
         (buffer (get-buffer name)))
    (cdr (seq-find (lambda (r) (drgnx-rules--match-p (car r) name buffer action)) drgnx-rules--table))))

(defconst drgnx-rules--explicit-actions
  '(display-buffer-pop-up-frame display-buffer-use-some-frame display-buffer-no-window
    display-buffer-in-child-frame)
  "Actions a caller only names on purpose (C-x 5 b, no window wanted): they win over the rules.")

(defun drgnx-rules--explicit-p (action)
  (seq-some (lambda (f) (memq f drgnx-rules--explicit-actions)) (ensure-list (car-safe action))))

(defun drgnx-rules--condition (name action)
  "Our `display-buffer-alist' condition: a rule matches, or the buffer is not internal — unless
the caller asked for a frame or for no window."
  (and (not (drgnx-rules--explicit-p action))
       (or (not (drgnx-rules--internal-p name)) (drgnx-wb-rule-for name action))))

(defun drgnx-rules--log (buffer)
  (push (list :buffer (buffer-name buffer) :mode (buffer-local-value 'major-mode buffer) :time (float-time))
        drgnx-wb-unrouted)
  (when (> (length drgnx-wb-unrouted) drgnx-rules--unrouted-max)
    (setq drgnx-wb-unrouted (seq-take drgnx-wb-unrouted drgnx-rules--unrouted-max))))

(defun drgnx-wb-run-body-function (window alist)
  "Run ALIST's `body-function' on WINDOW, as `window--display-buffer' does — a place that shows a
buffer itself calls this (*Completions* and *Process List* are filled by it)."
  (when-let* ((fn (cdr (assq 'body-function alist))) ((functionp fn)))
    (let ((inhibit-read-only t) (inhibit-modification-hooks t)) (funcall fn window))))

(defvar drgnx-rules--placing nil
  "Non-nil while a place shows a buffer: its own `display-buffer-in-side-window' calls are meant.")

(defun drgnx-rules--display (buffer alist)
  "Our `display-buffer-alist' action: show BUFFER where its rule says (unmatched: the editor, logged)."
  (let ((rule (drgnx-wb-rule-for buffer (cons nil alist))))
    (unless rule (drgnx-rules--log buffer))
    (let ((place (or (car rule) 'editor)) (drgnx-rules--placing t))
      (funcall (or (alist-get place drgnx-rules--places) (error "drgnx: no place %s" place))
               buffer alist (cdr rule)))))

(defun drgnx-rules--balance (orig &optional window-or-frame)
  "Around `balance-windows': balancing the whole frame balances the editors only — the docks and
the panel keep their size (finder balances the frame)."
  (let ((target (if (or (null window-or-frame) (framep window-or-frame))
                    (window-main-window (window-normalize-frame window-or-frame))
                  window-or-frame)))
    (unless (window-live-p target) (funcall orig target))))

(defun drgnx-rules--side-window (orig buffer alist)
  "Around `display-buffer-in-side-window': a package calling it directly (which-key does) for a
buffer a rule places goes to that place; any other buffer gets a slot of its own, so it never
takes over a dock's or the panel's window (Emacs reuses a same-slot side window)."
  (cond
   (drgnx-rules--placing (funcall orig buffer alist))
   ((drgnx-wb-rule-for buffer (cons nil alist)) (drgnx-rules--display buffer alist))
   (t
    (let* ((side (or (cdr (assq 'side alist)) 'bottom))
           (ours (seq-filter (lambda (w) (and (eq (window-parameter w 'window-side) side)
                                              (window-parameter w 'drgnx-role)))
                             (window-list nil 'nomini)))
           (slot (or (cdr (assq 'slot alist)) 0)))
      (when (seq-some (lambda (w) (eql (window-parameter w 'window-slot) slot)) ours)
        (setq alist (cons (cons 'slot (1+ (apply #'max (mapcar (lambda (w) (or (window-parameter w 'window-slot) 0)) ours))))
                          alist)))
      (funcall orig buffer alist)))))

;;;; Places: editor, current

(defun drgnx-rules--free-p (w)
  "W is an editor window a buffer may be shown in (not one the user locked with C-x w d)."
  (and (drgnx-signal-editor-window-p w) (not (window-dedicated-p w))))

(defun drgnx-rules--editor-window (alist)
  "The selected window if it is a free editor, else the editor used last, else any free editor —
not the selected one when ALIST says `inhibit-same-window' and another exists."
  (let* ((avoid (and (cdr (assq 'inhibit-same-window alist)) (selected-window)))
         (ok (lambda (w) (and w (drgnx-rules--free-p w) (not (eq w avoid))))))
    (or (seq-find ok (list (selected-window) (drgnx-wb-editor-window)))
        (seq-find ok (window-list nil 'nomini))
        (and avoid (drgnx-rules--free-p avoid) avoid))))     ; one editor: it (never a split)

(defun drgnx-rules--editor (buffer alist _props)
  "A window already showing BUFFER in the editor area, else the editor used last; never a split.
Nil when every editor is locked (C-x w d): Emacs' own actions decide then."
  (let ((w (or (seq-find (lambda (w) (and (eq (window-buffer w) buffer) (drgnx-signal-editor-window-p w)))
                         (window-list nil 'nomini))
               (drgnx-rules--editor-window alist))))
    (when w (window--display-buffer buffer w 'reuse alist))))

(defun drgnx-rules--current (buffer alist props)
  "The selected window, unless it is a dock or dedicated (then the editor)."
  (let ((w (selected-window)))
    (if (drgnx-rules--free-p w)
        (window--display-buffer buffer w 'reuse alist)
      (drgnx-rules--editor buffer alist props))))

(drgnx-wb-define-place 'editor #'drgnx-rules--editor)
(drgnx-wb-define-place 'current #'drgnx-rules--current)

;;;; The mode

(defconst drgnx-rules--defaults
  '((split-height-threshold . nil) (split-width-threshold . nil) (even-window-sizes . nil)
    (window-combination-resize . nil) (switch-to-buffer-obey-display-actions . t) (resize-mini-windows . nil)
    (window-sides-vertical . t) (message-truncate-lines . t) (eldoc-echo-area-use-multiline-p . nil))
  "Window defaults: nothing splits or resizes on its own; the echo area, messages and eldoc stay one
line (a tall message never takes pixels from the panel); `switch-to-buffer' follows the rules; the
left and right docks run the frame's full height, the panel sits under the editors.")

(defvar drgnx-rules--saved nil "The values `drgnx-rules-mode' replaced.")

(defun drgnx-rules--minibuffer-setup ()
  "While reading, the minibuffer may grow (icomplete-vertical, fido-vertical); the echo area may not."
  (setq-local resize-mini-windows 'grow-only))
(defconst drgnx-rules--entry '(drgnx-rules--condition (drgnx-rules--display)))

(define-minor-mode drgnx-rules-mode
  "Show every buffer where the rules table says; set window defaults that never split or resize."
  :global t :group 'drgnx
  (if drgnx-rules-mode
      (progn
        (unless drgnx-rules--saved
          (setq drgnx-rules--saved (mapcar (lambda (d) (cons (car d) (symbol-value (car d)))) drgnx-rules--defaults)))
        (pcase-dolist (`(,var . ,val) drgnx-rules--defaults) (set var val))
        (setq display-buffer-alist (append (remove drgnx-rules--entry display-buffer-alist) (list drgnx-rules--entry)))
        (advice-add 'display-buffer-in-side-window :around #'drgnx-rules--side-window)
        (advice-add 'balance-windows :around #'drgnx-rules--balance)
        (add-hook 'minibuffer-setup-hook #'drgnx-rules--minibuffer-setup))
    (advice-remove 'display-buffer-in-side-window #'drgnx-rules--side-window)
    (advice-remove 'balance-windows #'drgnx-rules--balance)
    (remove-hook 'minibuffer-setup-hook #'drgnx-rules--minibuffer-setup)
    (setq display-buffer-alist (remove drgnx-rules--entry display-buffer-alist))
    (pcase-dolist (`(,var . ,val) drgnx-rules--saved) (set var val))
    (setq drgnx-rules--saved nil)))

(defun drgnx-wb-show-unrouted ()
  "List the buffers no rule matched (each one is a rule to add)."
  (interactive)
  (with-current-buffer (get-buffer-create "*drgnx unrouted*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (if drgnx-wb-unrouted "Buffers no rule matched (newest first):\n\n" "Every buffer was routed.\n"))
      (dolist (u drgnx-wb-unrouted)
        (insert (format "%s  %-30s %s\n" (format-time-string "%T" (plist-get u :time))
                        (plist-get u :buffer) (plist-get u :mode)))))
    (special-mode)
    (pop-to-buffer (current-buffer))))

(drgnx-wb-place "\\`\\*drgnx unrouted\\*\\'" 'editor)
;; Files, and buffers that are worked in like files (lists, settings, dired), go to the editor.
;; Names too: several are displayed before their mode is set.
(drgnx-wb-place (lambda (name _action) (buffer-file-name (get-buffer name))) 'editor)
(drgnx-wb-place '(dired-mode Buffer-menu-mode ibuffer-mode Custom-mode proced-mode edit-abbrevs-mode
                  bookmark-bmenu-mode tabulated-list-mode command-history-mode)
                'editor)
(drgnx-wb-place "\\`\\*\\(scratch\\|Ibuffer\\|Buffer List\\|Customize.*\\|Proced\\|Abbrevs\\|Bookmark List\\)\\*\\'" 'editor)

(provide 'drgnx-rules)
;;; drgnx-rules.el ends here
