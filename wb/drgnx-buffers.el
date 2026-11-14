;;; drgnx-buffers.el --- The Buffers panel: open editors in the left dock -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The files you have open, in the order you opened them — switching never re-sorts, so a row
;; never moves under the pointer.  Each row: the file's icon and its name; at the right edge the git letter and the
;; close button (hidden until the row is hovered), or ● in its place while the buffer has unsaved changes; on Nidhogg the
;; ● becomes × while the row is hovered (its mouse sensors).
;; The rows are the hub's (`buffers/set', view/buffers.rs), held and drawn by Sjá: this file tells the hub what changed
;; — a buffer opened, closed or renamed, an unsaved flag flipped (the change bus's edges, never a keystroke), the
;; window's scope, the filter — in one call per flush, and draws only the right edge of the rows the hub drew.  The
;; view and the selection stay on their rows through a draw, the title lives in the window, where no mode can erase
;; it, and the active editor's row is marked with an overlay.  With the hub down the panel says it waits; the commands
;; still work.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-wb)
(require 'drgnx-view)
(require 'drgnx-git)
(declare-function drgnx-wb-fit-sections "drgnx-wb")
(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-view-env-register "drgnx-view-env" (view buffer &optional resubscribe headless))
(defvar drgnx-hub--events)

(defface drgnx-buffers-close '((t :inherit shadow)) "The × of each row." :group 'drgnx)
(defface drgnx-buffers-modified '((t :inherit warning)) "The ● of a modified buffer." :group 'drgnx)
(defface drgnx-buffers-active '((t))
  "The row of the buffer shown in the active editor: no mark of its own (window-dark.html's Open list has none; the
Explorer's selected row is the current file), for a theme or you to give one." :group 'drgnx)

(defconst drgnx-buffers-buffer-name " *drgnx buffers*" "Internal (a leading space): not in C-x b or ibuffer.")

(defvar drgnx-buffers-hub-view "buffers" "The name of the Buffers panel's view in the hub and in Sjá.")

(defvar drgnx-buffers--active nil "Overlay on the active editor's row.")
(defvar drgnx-buffers--filter nil "Show only buffers whose names contain this text (any case), or nil.")
(defvar drgnx-buffers--title)          ; defined below

(defvar drgnx-buffers-all-windows nil
  "With several windows open: nil lists the buffers of the window you work in, t all of them.")
(declare-function drgnx-frame-buffers "drgnx-frames")
(declare-function drgnx-frames-count "drgnx-frames")

;;;; What the hub knows

(defvar drgnx-buffers--ids (make-hash-table :test #'eq :weakness 'key)
  "BUFFER → its row's id in the hub (\"bN\", N counting up in the order buffers were first seen).  Weak on the buffer;
a closed one's goes at the next set change.")
(defvar drgnx-buffers--by-id (make-hash-table :test #'equal :weakness 'value)
  "Id → its BUFFER (`drgnx-buffers--ids' the other way).  Weak on the buffer.")
(defvar drgnx-buffers--sent (make-hash-table :test #'eq :weakness 'key)
  "BUFFER → (NAME FILE MODIFIED) as the hub last got it: a change bus edge that changes none of them sends nothing.")
(defvar drgnx-buffers--next 0 "The N of the last id given.")
(defvar drgnx-buffers--ops nil "The changes not sent yet, newest first.")
(defvar drgnx-buffers--scope 'all "The scope the hub got last: the ids on rows (a vector), or `all'.")
(defvar drgnx-buffers--sends 0 "How many `buffers/set' calls went (tests read it).")
(defvar drgnx-buffers--pressed nil "Non-nil while a mouse button pressed in the panel is held.")

(defun drgnx-buffers--id (b)
  "Buffer B's row id, given it when it has none."
  (or (gethash b drgnx-buffers--ids)
      (let ((id (format "b%d" (cl-incf drgnx-buffers--next))))
        (puthash b id drgnx-buffers--ids)
        (puthash id b drgnx-buffers--by-id)
        id)))

(defun drgnx-buffers--queue (op)
  "Send OP to the hub with the others of this flush: one `buffers/set' when the command loop is next idle (a press
in the panel holds them until its release: rows never move under the pointer)."
  (push op drgnx-buffers--ops)
  (when-let* ((panel (get-buffer drgnx-buffers-buffer-name)))
    (drgnx-timer-soon 'buffers-send 0 #'drgnx-buffers--send :owner panel)))

(defun drgnx-buffers--hub-p ()
  "Non-nil when the hub's subscribed connection is up (the hub sends the rows there)."
  (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events)))

(defun drgnx-buffers--send ()
  "Send the changes queued (`drgnx-buffers--queue') in one `buffers/set' on the subscribed connection.  With the hub
down they are dropped: a reconnect sends the whole set again (`drgnx-buffers--resend')."
  (cond
   (drgnx-buffers--pressed)
   ((not (drgnx-buffers--hub-p)) (setq drgnx-buffers--ops nil))
   (drgnx-buffers--ops
    (let ((ops (vconcat (nreverse drgnx-buffers--ops))))
      (setq drgnx-buffers--ops nil)
      (cl-incf drgnx-buffers--sends)
      (with-current-buffer (or (get-buffer drgnx-buffers-buffer-name) (current-buffer))
        (setq drgnx-view-patch-hurry t))       ; the user waits for these rows: drawn at the next pass
      (condition-case nil
          (drgnx-hub--call-on drgnx-hub--events "buffers/set" (list :view drgnx-buffers-hub-view :ops ops) #'ignore)
        (error nil))))))

(defun drgnx-buffers--state (b)
  "(NAME FILE MODIFIED) of buffer B as the hub shows it."
  (list (buffer-name b) (buffer-file-name b) (and (buffer-modified-p b) t)))

(defun drgnx-buffers--put (b)
  "Queue buffer B's `put' when the hub's copy of it differs (new, renamed, another file, the flag flipped)."
  (let ((st (drgnx-buffers--state b)))
    (unless (equal st (gethash b drgnx-buffers--sent))
      (puthash b st drgnx-buffers--sent)
      (drgnx-buffers--queue (append (list :op "put" :id (drgnx-buffers--id b) :name (car st))
                                    (and (nth 1 st) (list :file (nth 1 st)))
                                    (list :modified (if (nth 2 st) t :false)))))))

(defun drgnx-buffers--forget (b)
  "Buffer B was closed: queue its `remove' and forget it."
  (when-let* ((id (gethash b drgnx-buffers--ids)))
    (drgnx-buffers--queue (list :op "remove" :id id))
    (remhash id drgnx-buffers--by-id))
  (remhash b drgnx-buffers--ids)
  (remhash b drgnx-buffers--sent))

(defun drgnx-buffers--set-changed (set)
  "The bus's `buffer-set-changed' (SET, the user buffers): the closed ones go, the new and renamed ones are put; new
ones go last, in SET's order."
  (let ((live (make-hash-table :test #'eq :size (length set))) gone)
    (dolist (b set) (puthash b t live))
    (maphash (lambda (b _) (unless (gethash b live) (push b gone))) drgnx-buffers--ids)
    (mapc #'drgnx-buffers--forget gone)
    (mapc #'drgnx-buffers--put set))
  (drgnx-buffers--scope-sync))

(defun drgnx-buffers--modified-changed (flipped)
  "The bus's `modified-changed': the buffers FLIPPED had their unsaved flag flip."
  (dolist (b flipped)
    (if-let* ((id (gethash b drgnx-buffers--ids)) (st (gethash b drgnx-buffers--sent)))
        (let ((m (and (buffer-modified-p b) t)))
          (unless (eq m (nth 2 st))
            (puthash b (list (nth 0 st) (nth 1 st) m) drgnx-buffers--sent)
            (drgnx-buffers--queue (list :op "modified" :id id :modified (if m t :false)))))
      (when (drgnx-signal-user-buffer-p b) (drgnx-buffers--put b)))))

(defun drgnx-buffers--scope-now ()
  "The ids on rows by the scope: with several windows and `drgnx-buffers-all-windows' off those of the selected
window's buffers (a vector), else `all'."
  (if (and (not drgnx-buffers-all-windows) (fboundp 'drgnx-frame-buffers) (> (drgnx-frames-count) 1))
      (vconcat (delq nil (mapcar (lambda (b) (gethash b drgnx-buffers--ids)) (drgnx-frame-buffers))))
    'all))

(defun drgnx-buffers--scope-sync (&rest _)
  "Queue the scope when it is not the one the hub has (another window, its buffers changed)."
  (let ((scope (drgnx-buffers--scope-now)))
    (unless (equal scope drgnx-buffers--scope)
      (setq drgnx-buffers--scope scope)
      (drgnx-buffers--queue (list :op "scope" :ids (if (eq scope 'all) :null scope))))))

(defun drgnx-buffers--resend (&rest _)
  "Send the hub every open buffer again, in open order, with the scope and the filter: at attach and when the hub is
up again (a new hub has none)."
  (setq drgnx-buffers--ops nil)
  (clrhash drgnx-buffers--sent)
  (drgnx-buffers--queue (list :op "reset"))
  (setq drgnx-buffers--scope nil)                ; the scope goes again too
  (let ((set (seq-filter #'drgnx-signal-user-buffer-p (buffer-list))))
    (dolist (b (sort (seq-filter (lambda (b) (gethash b drgnx-buffers--ids)) set)
                     (lambda (a b) (< (drgnx-buffers--n a) (drgnx-buffers--n b)))))
      (drgnx-buffers--put b))
    (drgnx-buffers--set-changed set))
  (drgnx-buffers--queue (list :op "filter" :text (or drgnx-buffers--filter :null))))

(defun drgnx-buffers--n (b) "The N of buffer B's id \"bN\"." (string-to-number (substring (gethash b drgnx-buffers--ids) 1)))

(defun drgnx-buffers-toggle-all-windows ()
  "List the buffers of every window, or of the window you work in."
  (interactive)
  (setq drgnx-buffers-all-windows (not drgnx-buffers-all-windows))
  (drgnx-buffers--scope-sync)
  (message "Buffers: %s" (if drgnx-buffers-all-windows "all windows" "this window")))

;;;; The rows the hub drew

(defun drgnx-buffers-buffer-at (pos)
  "The buffer of the row at POS, or nil."
  (when-let* ((pos) (panel (get-buffer drgnx-buffers-buffer-name)))
    (with-current-buffer panel
      (when-let* ((key (drgnx-view-key-at pos))) (gethash key drgnx-buffers--by-id)))))

(defun drgnx-buffers--row-pos (b)
  "Start of buffer B's row, or nil."
  (when-let* ((id (gethash b drgnx-buffers--ids)) (panel (get-buffer drgnx-buffers-buffer-name)))
    (with-current-buffer panel (drgnx-view-row-start drgnx-view id))))

(defun drgnx-buffers--shown ()
  "The buffers on rows, top to bottom (as the hub drew them)."
  (when-let* ((panel (get-buffer drgnx-buffers-buffer-name)))
    (with-current-buffer panel
      (save-excursion
        (goto-char (point-min))
        (let (out)
          (while (not (eobp))
            (when-let* ((key (get-text-property (point) drgnx-view-patch-id-prop))
                        (b (gethash key drgnx-buffers--by-id)))
              (push b out))
            (forward-line 1))
          (nreverse out))))))

(defun drgnx-buffers--on-control-p (posn)
  "Non-nil if POSN (a mouse position) is on a row's close button or ● at its right edge."
  (when-let* ((s (posn-string posn)))
    (and (stringp (car s)) (integerp (cdr s)) (< (cdr s) (length (car s)))
         (get-text-property (cdr s) 'drgnx-row-control (car s)))))

(defvar-local drgnx-buffers--hovered nil
  "The buffer whose row the pointer is on (Nidhogg's mouse sensors), or nil: its ● shows as × (VS Code's way).")

(defvar drgnx-buffers--sensors (make-hash-table :test #'eq :weakness 'key)
  "BUFFER → its row's `mouse-sensor-functions', one list per buffer: the value tells rows apart (by `eq') and stays
the same object through every repaint, so a repaint under a still pointer is no change.  Weak on the buffer.")

(defun drgnx-buffers--sensor (b)
  "The `mouse-sensor-functions' of buffer B's row."
  (or (gethash b drgnx-buffers--sensors)
      (puthash b (list #'drgnx-buffers--sense) drgnx-buffers--sensors)))

(defvar-local drgnx-buffers--tails nil "The tail overlay of each drawn row near what a window shows, by its key.")

(defun drgnx-buffers--tail (key beg eol)
  "Give KEY's drawn row (BEG to EOL) its tail at the right edge, its overlay moved rather than made again: the git
letter of the status the hub put on the name, and the close button, or ● while the hub says the buffer has unsaved
changes and the pointer is not on the row."
  (let* ((b (gethash key drgnx-buffers--by-id))
         (status (and (< beg eol) (intern-soft (get-text-property (1- eol) 'drgnx-git-status))))
         (status (and (assq status drgnx-git--looks) status))
         (letter (and status (car (drgnx-git-look status))))
         (modified (and (< beg eol) (get-text-property (1- eol) 'drgnx-buffers-modified)))
         (o (drgnx-wb-row-tail-overlay eol letter (and letter (drgnx-wb-git-mark-face status))
                                       (if (and modified (not (eq b drgnx-buffers--hovered)))
                                           (propertize (drgnx-face-glyph 'dot) 'face 'drgnx-buffers-modified
                                                       'help-echo "Unsaved changes")
                                         (propertize (drgnx-face-glyph 'close) 'help-echo "Close"))
                                       (gethash key drgnx-buffers--tails) (and b (drgnx-buffers--sensor b)))))
    (overlay-put o 'evaporate t)
    (puthash key o drgnx-buffers--tails)))

(defun drgnx-buffers--sense (window pos dir)
  "A row's mouse sensor: the pointer came onto (DIR `entered') or went off (`left') the row at POS in WINDOW.  A row
with unsaved changes shows its close button instead of ● while the pointer is on it; only that row's tail is drawn
again."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (when (derived-mode-p 'drgnx-buffers-mode)
        (let ((b (drgnx-buffers-buffer-at pos)) (was drgnx-buffers--hovered))
          (setq drgnx-buffers--hovered (cond ((eq dir 'entered) b) ((eq b was) nil) (t was)))
          (dolist (r (delete-dups (list was drgnx-buffers--hovered)))
            (when-let* (((buffer-live-p r)) (key (gethash r drgnx-buffers--ids))
                        (beg (drgnx-view-row-start drgnx-view key)))
              (drgnx-buffers--tail key beg (save-excursion (goto-char beg) (pos-eol))))))))))

(defvar-local drgnx-buffers--waiting nil
  "The overlay of the line saying the panel waits for the hub, until its first rows are drawn.")

(defun drgnx-buffers--wait-for-hub ()
  "With the hub not up, show the line saying the panel waits for it; its first rows take the line away."
  (unless (or (drgnx-buffers--hub-p) (overlayp drgnx-buffers--waiting))
    (setq drgnx-buffers--waiting (make-overlay (point-min) (point-min)))
    (overlay-put drgnx-buffers--waiting 'before-string
                 (propertize "  Waiting for the hub to list the open files…\n" 'face 'shadow))))

(defun drgnx-buffers--patched (view keys)
  "`drgnx-view-patch-patched-functions' of the panel: the drawn rows KEYS near what a window shows get their tail
\(`drgnx-buffers--tail'), the others lose it; then the active row's mark, the selection and the section's height
follow the rows."
  (when drgnx-buffers--waiting (delete-overlay drgnx-buffers--waiting) (setq drgnx-buffers--waiting nil))
  (let ((tails (or drgnx-buffers--tails (setq drgnx-buffers--tails (make-hash-table :test #'equal))))
        (spans (drgnx-wb-shown-spans)))
    (dolist (key keys)
      (let ((beg (drgnx-view-row-start view key)) (o (gethash key tails)))
        (if (and beg (or (eq spans t) (seq-some (lambda (s) (<= (car s) beg (cdr s))) spans)))
            (drgnx-buffers--tail key beg (save-excursion (goto-char beg) (pos-eol)))
          (when o (delete-overlay o) (remhash key tails)))))
    (when (> (hash-table-count tails) (drgnx-view-row-count view))
      (maphash (lambda (key o) (unless (overlay-buffer o) (remhash key tails))) tails)))
  (drgnx-wb-selection-sync)
  (drgnx-buffers--mark-active)
  (drgnx-wb-fit-sections (current-buffer)))

(defun drgnx-buffers--scrolled (window start)
  "`window-scroll-functions': the rows near what WINDOW shows from START that have no tail get one."
  (when drgnx-buffers--tails
    (let ((span (drgnx-wb-span start (window-body-height window))))
      (save-excursion
        (goto-char (car span))
        (while (< (point) (cdr span))
          (when-let* ((key (get-text-property (point) drgnx-view-patch-id-prop))
                      ((not (when-let* ((o (gethash key drgnx-buffers--tails))) (overlay-buffer o)))))
            (drgnx-buffers--tail key (point) (pos-eol)))
          (forward-line 1))))))

(defun drgnx-buffers--buffer ()
  "The panel's buffer, made a hub-fed view when it is not: the hub gets its env and the whole set."
  (or (get-buffer drgnx-buffers-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-buffers-buffer-name)
        (drgnx-buffers-mode)
        (drgnx-view-patch-attach drgnx-buffers-hub-view "unshown" :sja t)
        (add-hook 'drgnx-view-patch-patched-functions #'drgnx-buffers--patched nil t)
        (add-hook 'window-scroll-functions #'drgnx-buffers--scrolled nil t)
        (drgnx-buffers--wait-for-hub)
        (require 'drgnx-view-env)
        (drgnx-view-env-register drgnx-buffers-hub-view (current-buffer) #'drgnx-buffers--resend)
        (drgnx-buffers--resend)
        (current-buffer))))

(defun drgnx-buffers--release ()
  "The button came up: send what waited for it."
  (setq drgnx-buffers--pressed nil)
  (when drgnx-buffers--ops (drgnx-buffers--send)))

(defun drgnx-buffers--focus-changed ()
  "Emacs lost focus: a press is over — its release will not come here (Wayland)."
  (when (and drgnx-buffers--pressed (not (seq-some #'frame-focus-state (frame-list)))) (drgnx-buffers--release)))

(defun drgnx-buffers--mark-active (&rest _)
  "Mark the row of the buffer in the active editor (an overlay; no re-render)."
  (when-let* ((panel (get-buffer drgnx-buffers-buffer-name)))
    (with-current-buffer panel
      (let ((pos (when-let* ((w (drgnx-wb-editor-window))) (drgnx-buffers--row-pos (window-buffer w)))))
        (unless (overlayp drgnx-buffers--active)
          (setq drgnx-buffers--active (make-overlay 1 1))
          (overlay-put drgnx-buffers--active 'face 'drgnx-buffers-active))
        (if pos
            (move-overlay drgnx-buffers--active pos (save-excursion (goto-char pos) (pos-eol)) panel)
          (delete-overlay drgnx-buffers--active))))))

;;;; Commands

(defun drgnx-buffers-close-at (pos)
  "Close (kill) the buffer of the row at POS."
  (when-let* ((b (drgnx-buffers-buffer-at pos)))
    (when (buffer-live-p b) (kill-buffer b))))

(defun drgnx-buffers-open-at (pos)
  "Show the buffer of the row at POS in the editor and focus it."
  (when-let* ((b (drgnx-buffers-buffer-at pos)))
    (when (buffer-live-p b) (drgnx-wb-show-in-editor b t))))

(defun drgnx-buffers-next () "Next row." (interactive) (forward-line 1) (when (eobp) (forward-line -1)))
(defun drgnx-buffers-previous () "Previous row." (interactive) (forward-line -1))
(defun drgnx-buffers-open () "Open the row's buffer in the editor." (interactive) (drgnx-buffers-open-at (point)))
(defun drgnx-buffers-close () "Close the row's buffer." (interactive) (drgnx-buffers-close-at (pos-bol)))
(defun drgnx-buffers--user-buffers ()
  "The live buffers on rows: those the filter and the window let through (never ones hidden)."
  (seq-filter #'buffer-live-p (drgnx-buffers--shown)))

(defun drgnx-buffers-save-all () "Save every buffer with unsaved changes (no questions)."
       (interactive) (save-some-buffers t))

(defun drgnx-buffers-close-saved () "Close every buffer without unsaved changes."
       (interactive)
       (dolist (b (drgnx-buffers--user-buffers)) (unless (buffer-modified-p b) (kill-buffer b))))

(defun drgnx-buffers-close-others () "Close every buffer but the one of the row here."
       (interactive)
       (let ((keep (or (drgnx-buffers-buffer-at (point)) (user-error "No buffer here"))))
         (dolist (b (drgnx-buffers--user-buffers)) (unless (eq b keep) (kill-buffer b)))))

(defun drgnx-buffers-close-all () "Close every buffer in the panel (unsaved ones ask first)."
       (interactive)
       (dolist (b (drgnx-buffers--user-buffers)) (kill-buffer b)))

(defun drgnx-buffers--filter-apply (text)
  "Show only buffers whose names contain TEXT."
  (setq drgnx-buffers--filter (and text (not (string-empty-p text)) text))
  (drgnx-buffers--queue (list :op "filter" :text (or drgnx-buffers--filter :null)))
  (when-let* ((w (drgnx-wb-section-window 'buffers)))
    (set-window-parameter w 'header-line-format (drgnx-wb-section-header (drgnx-buffers--current-title)))))

(defun drgnx-buffers--current-title ()
  "The panel's title: the filter while one is on, else the title with its buttons."
  (if drgnx-buffers--filter (format "Open — %s" drgnx-buffers--filter) drgnx-buffers--title))

(defun drgnx-buffers-filter-clear () "Show every buffer again." (interactive) (drgnx-buffers--filter-apply nil))

(defun drgnx-buffers-filter ()
  "Show only buffers whose names contain what you type (live); empty input shows all."
  (interactive)
  (minibuffer-with-setup-hook
      (lambda () (add-hook 'after-change-functions
                           (lambda (&rest _) (drgnx-buffers--filter-apply (minibuffer-contents-no-properties))) nil t))
    (condition-case nil
        (drgnx-buffers--filter-apply (read-string "Filter buffers: " drgnx-buffers--filter))
      (quit (drgnx-buffers--filter-apply nil)))))

(defun drgnx-buffers-mouse-close (event)
  "Middle click: close that row's buffer (as VS Code)."
  (interactive "e")
  (let ((pos (posn-point (event-end event))))
    (when (integer-or-marker-p pos)
      (with-current-buffer (window-buffer (posn-window (event-end event))) (drgnx-buffers-close-at pos)))))

(defun drgnx-buffers-focus () "Show the sidebar and focus the Buffers panel."
       (interactive) (drgnx-wb-focus-section 'buffers))

(defun drgnx-buffers-mouse-press (event)
  "Press: select the row; the action happens on release."
  (interactive "e")
  (setq drgnx-buffers--pressed t)
  (let* ((posn (event-start event)) (w (posn-window posn)) (pos (posn-point posn)))
    (when (window-live-p w)
      (unless (eq w (selected-window)) (select-window w))
      (when (integer-or-marker-p pos) (goto-char pos)))))

(defun drgnx-buffers-mouse-click (event)
  "Release: the close button (or ●) at the row's right edge closes that row's buffer; elsewhere on the row, show it
in the editor."
  (interactive "e")
  (let* ((posn (event-end event)) (pos (posn-point posn)) (w (posn-window posn)))
    ;; Act on the rows the user saw, then send what waited for the release.
    (when (and (integer-or-marker-p pos) (window-live-p w))
      (with-current-buffer (window-buffer w)
        (if (drgnx-buffers--on-control-p posn) (drgnx-buffers-close-at pos) (drgnx-buffers-open-at pos)))))
  (drgnx-buffers--release))

(defun drgnx-buffers-mouse-ignore (_event) (interactive "e") (drgnx-buffers--release))

(defvar drgnx-buffers-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map drgnx-wb-dock-map)
    (keymap-set map "<down-mouse-1>" #'drgnx-buffers-mouse-press)
    (keymap-set map "<mouse-1>" #'drgnx-buffers-mouse-click)
    (keymap-set map "<double-down-mouse-1>" #'ignore)
    (keymap-set map "<double-mouse-1>" #'drgnx-buffers-mouse-ignore)
    (keymap-set map "<drag-mouse-1>" #'drgnx-buffers-mouse-ignore)
    (keymap-set map "<mouse-2>" #'drgnx-buffers-mouse-close)
    map)
  "Keys of the Buffers panel; keyboard keys come from the key profiles.")

(define-derived-mode drgnx-buffers-mode nil "Buffers"
  "The drgnx Buffers panel (open editors)."
  (setq buffer-read-only t buffer-undo-list t truncate-lines t cursor-type nil mode-line-format nil)
  ;; A press on a partly visible row must not scroll: the row would move under the pointer.
  (setq-local scroll-margin 0 make-cursor-line-fully-visible nil)
  (drgnx-wb-rows-setup))

(defvar drgnx-buffers--title "Open"
  "The panel's title (window-dark.html `.sec'); Save All and Close Saved are on the island header's ⋯.")

(defun drgnx-buffers-setup ()
  "Put the Buffers panel in the dock (above the Explorer) and keep it current."
  (drgnx-wb-define-section 'buffers :slot -1 :title #'drgnx-buffers--current-title :height 0.3 :fit 0.3
                           :buffer #'drgnx-buffers--buffer)
  (drgnx-state-subscribe 'selected-changed #'drgnx-wb--selected-changed)
  (drgnx-wb-rows-follow)
  (drgnx-signal-subscribe 'buffer-set-changed #'drgnx-buffers--set-changed)
  (drgnx-signal-subscribe 'modified-changed #'drgnx-buffers--modified-changed)
  (when (boundp 'mouse-sensor-enabled)                  ; Nidhogg: the ● of a hovered row becomes ×
    (drgnx-module-set 'mouse-sensor-enabled t))
  (drgnx-signal-subscribe 'editor-changed #'drgnx-buffers--mark-active)
  (drgnx-signal-subscribe 'editor-changed #'drgnx-buffers--scope-sync)
  (drgnx-signal-subscribe 'frame-changed #'drgnx-buffers--scope-sync)           ; another window: its buffers
  (drgnx-signal-subscribe 'tabs-changed #'drgnx-buffers--scope-sync)
  (add-function :after after-focus-change-function #'drgnx-buffers--focus-changed '((name . drgnx-buffers)))
  (drgnx-modules-push-undo "after-focus-change-function drgnx-buffers"
                           (lambda () (remove-function after-focus-change-function 'drgnx-buffers))))

(provide 'drgnx-buffers)
;;; drgnx-buffers.el ends here
