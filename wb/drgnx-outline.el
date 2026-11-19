;;; drgnx-outline.el --- The Outline section: the editor's definitions -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A dock section below the Explorer listing the definitions of the file in the editor, nested by the definitions
;; around them.  The hub builds the list (`outline/set', docs/develop/hub.md, "The Outline panel's rows"): it outlines
;; the file with Hrafn's parse, from the editor's unsaved text where the edit history tracks the buffer, else from the
;; disk, again once the edits pause, and sends the rows, which Sjá draws.  Lisp sends the file the editor shows (when
;; that changes, and after a save) and nothing per keystroke.  A click shows the definition in the editor and keeps
;; you in the Outline (browse on); RET goes there.  The definition the editor's point is in is marked with an overlay
;; (the Outline's own point is yours and never moves): Sjá names it (`at-line'), on the bus's `editor-point-changed'
;; edge.  A file with nothing to outline, a remote file or one past a megabyte gets a one-line notice; with the hub
;; down the section says it waits for it.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'drgnx-wb)
(require 'drgnx-view)
(require 'drgnx-icons)
(require 'drgnx-history)                 ; `drgnx-history-ask': `outline/scopes' of a tracked buffer

(declare-function drgnx-hub--call-on "drgnx-hub-client" (conn method params callback &rest keys))
(declare-function drgnx-hub-call "drgnx-hub-client" (method params callback &rest keys))
(declare-function drgnx-view-env-register "drgnx-view-env" (view buffer &optional resubscribe headless))
(declare-function nidhogg-view-get "nidhogg-views" (h what &optional arg arg2))
(defvar drgnx-hub--events)

(defface drgnx-outline-current '((t :inherit drgnx-accent))
  "The definition the editor's point is in: a marker of where you are, its text in the accent, never a fill, so the
sidebar's one selection stays the only one." :group 'drgnx)

(defconst drgnx-outline-title "Outline" "The Outline section's title.")
(defconst drgnx-outline-buffer-name" *drgnx outline*" "Internal (a leading space): not in C-x b or ibuffer.")
(defconst drgnx-outline-hub-view "outline" "The Outline's hub-fed view (`outline/set').")
(defvar drgnx-outline--source nil "The buffer the Outline shows.")
(defvar drgnx-outline--sent :none "The file last sent to the hub (nil: none), or :none before the first.")
(defvar drgnx-outline--reveal nil "Non-nil: a new file's first rows show the current definition.")
(defvar drgnx-outline--mark nil "The overlay that marks the current definition, or nil.")
(defvar drgnx-outline--waiting nil "The overlay saying the Outline waits for the hub, or nil.")

(defvar drgnx-outline-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m drgnx-wb-dock-map)
    (define-key m [mouse-1] #'drgnx-outline-mouse-jump)
    m))

(define-derived-mode drgnx-outline-mode special-mode "Outline"
  "The editor's definitions."
  (setq-local truncate-lines t cursor-type nil mode-line-format nil)
  (drgnx-wb-rows-setup))

(defun drgnx-outline--hub-p ()
  "Non-nil when the hub's subscribed connection is up (the hub sends the rows there)."
  (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events)))

(defun drgnx-outline--buffer ()
  "The Outline's buffer, made a hub-fed view when it is not."
  (or (get-buffer drgnx-outline-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-outline-buffer-name)
        (drgnx-outline-mode)
        (drgnx-view-patch-attach drgnx-outline-hub-view "unshown" :sja t)
        (add-hook 'drgnx-view-patch-patched-functions #'drgnx-outline--patched nil t)
        (require 'drgnx-view-env)
        (drgnx-view-env-register drgnx-outline-hub-view (current-buffer) #'drgnx-outline--resend)
        (current-buffer))))

(defun drgnx-outline--file (src)
  "The file the hub outlines for SRC: its local file's name, or nil (no file, a remote one)."
  (when-let* (((buffer-live-p src)) (f (buffer-file-name src)) ((not (file-remote-p f))))
    (expand-file-name f)))

(defun drgnx-outline--wait-for-hub ()
  "With the hub not up, show the line saying the Outline waits for it; its first rows take the line away."
  (with-current-buffer (drgnx-outline--buffer)
    (unless (or (drgnx-outline--hub-p) (overlayp drgnx-outline--waiting))
      (setq drgnx-outline--waiting (make-overlay (point-min) (point-min)))
      (overlay-put drgnx-outline--waiting 'before-string
                   (propertize "  Waiting for the hub to outline this file…\n" 'face 'shadow)))))

(defun drgnx-outline--send (file)
  "Tell the hub the Outline shows FILE (nil: no file)."
  (setq drgnx-outline--sent file)
  (if (not (drgnx-outline--hub-p))
      (drgnx-outline--wait-for-hub)
    (drgnx-hub--call-on drgnx-hub--events "outline/set"
                        (if file (list :view drgnx-outline-hub-view :file file) (list :view drgnx-outline-hub-view))
                        #'ignore)
    (setq drgnx-view-patch-hurry t)))

(defun drgnx-outline-scopes (buffer line callback)
  "Ask the hub for the definitions around LINE (from 1) of BUFFER's file (`outline/scopes': the Outline's parse of it,
BUFFER's unsaved text where the edit history tracks it, its changes handed over first, else the disk).  CALLBACK gets
them as a list of plists (:name :line), outermost first; nil for none or a failed question.  Nil when nothing was
asked: no local file, or no hub."
  (let ((cb (lambda (result _error) (funcall callback (plist-get result :scopes)))))
    (or (drgnx-history-ask buffer "outline/scopes" cb (list :line line))
        (when-let* ((file (drgnx-outline--file buffer)) ((drgnx-outline--hub-p)))
          (drgnx-hub-call "outline/scopes" (list :file file :line line) cb)
          t))))

(defun drgnx-outline--resend (_view)
  "The hub is up again (`drgnx-view-env-register'): it gets the file again."
  (unless (eq drgnx-outline--sent :none) (drgnx-outline--send drgnx-outline--sent)))

(defun drgnx-outline--saved ()
  "`after-save-hook' of the source: the hub reads the file again (the name too: a `write-file')."
  (when (eq (current-buffer) drgnx-outline--source)
    (drgnx-outline--send (drgnx-outline--file (current-buffer)))))

(defun drgnx-outline--watch (src)
  "Follow SRC's saves (and stop following the previous source)."
  (unless (eq src drgnx-outline--source)
    (when (buffer-live-p drgnx-outline--source)
      (with-current-buffer drgnx-outline--source (remove-hook 'after-save-hook #'drgnx-outline--saved t)))
    (setq drgnx-outline--source src)
    (when (buffer-live-p src)
      (with-current-buffer src (add-hook 'after-save-hook #'drgnx-outline--saved nil t)))))

(defun drgnx-outline-refresh (&rest _)
  "Show the definitions of the file in the editor, while the Outline is shown (showing it refreshes it); hidden, it
stops following the editor's saves."
  (if (and (get-buffer drgnx-outline-buffer-name) (drgnx-view-buffer-shown-p (get-buffer drgnx-outline-buffer-name)))
      (drgnx-outline--refresh-1)
    (drgnx-outline--watch nil)))

(defun drgnx-outline--refresh-1 ()
  "Tell the hub the editor's file when it is not the one it has.  A new file starts the Outline at its top, and its
first rows show the current definition."
  (let* ((editor (drgnx-wb-editor-window)) (src (and editor (window-buffer editor)))
         (new (not (eq src drgnx-outline--source))) (file (drgnx-outline--file src)))
    (drgnx-outline--buffer)
    (drgnx-outline--watch src)
    (when new (setq drgnx-outline--reveal t))
    (when (or new (not (equal file drgnx-outline--sent)))
      (drgnx-outline--send file))))

(defun drgnx-outline--handle ()
  "The Sjá instance of the Outline's model, or nil."
  (and drgnx-view-patch (drgnx-view-patch-handle drgnx-view-patch)))

(defun drgnx-outline--patched (_view _keys)
  "`drgnx-view-patch-patched-functions': the rows changed; the mark, the notice's quiet and a new file's reveal follow."
  (when drgnx-outline--waiting (delete-overlay drgnx-outline--waiting) (setq drgnx-outline--waiting nil))
  (drgnx-outline--mark-current))

(defun drgnx-outline--current-start ()
  "Where the row of the definition the editor's point is in starts in the Outline (the current buffer), or nil."
  (when-let* ((h (drgnx-outline--handle)) ((buffer-live-p drgnx-outline--source))
              (editor (drgnx-wb-editor-window)) ((eq (window-buffer editor) drgnx-outline--source))
              (line (with-current-buffer drgnx-outline--source (line-number-at-pos (window-point editor) t)))
              (id (nidhogg-view-get h 'at-line "order" line)))
    (drgnx-view-row-start nil id)))

(defun drgnx-outline--mark-current (&rest _)
  "Mark, in the Outline, the definition the editor's point is in (an overlay: the Outline's point and window are not
touched, except by the first rows of a new file, which show the marked row: `drgnx-outline--reveal').  Nothing when
the Outline is hidden or point is above every definition."
  (when-let* ((buf (get-buffer drgnx-outline-buffer-name)))
    (with-current-buffer buf
      (let* ((rows (and (drgnx-outline--handle) (nidhogg-view-get (drgnx-outline--handle) 'list "order")))
             (window (get-buffer-window buf t))
             (start (and window rows (drgnx-outline--current-start)))
             (reveal (and drgnx-outline--reveal (or rows (drgnx-view-key-at (point-min))))))
        (if (not start)
            (when drgnx-outline--mark (delete-overlay drgnx-outline--mark))
          (let ((end (save-excursion (goto-char start) (pos-eol))))
            (if (overlayp drgnx-outline--mark)
                (move-overlay drgnx-outline--mark start end)
              (setq drgnx-outline--mark (make-overlay start end))
              (overlay-put drgnx-outline--mark 'drgnx-outline-current t)
              (overlay-put drgnx-outline--mark 'face 'drgnx-outline-current))))
        (when (and (not rows) (drgnx-view-key-at (point-min))) (drgnx-outline--quiet))
        (when reveal
          (setq drgnx-outline--reveal nil)
          (when window (drgnx-outline--reveal-row window (or start (point-min)))))))))

(defun drgnx-outline--quiet ()
  "An Outline without definitions (its notice): no row stays selected, and the windows showing it are at its start,
not scrolled sideways.  The selection of the rows it replaced would otherwise outlive them: an empty overlay whose
fill stretches to the right edge before the notice, which pushes it off the window."
  (save-excursion (goto-char (point-min)) (drgnx-wb-selection-sync))
  (let ((ws (get-buffer-window-list (current-buffer) nil t)))
    (drgnx-wb-with-owned-windows ws               ; the Outline's own windows, moved by its draw (I9)
      (dolist (w ws)
        (set-window-point w (point-min))
        (set-window-hscroll w 0)))))

(defun drgnx-outline--reveal-row (window start)
  "Put WINDOW's point (and the buffer's) on the row at START, the window at the top; a row below the first screen
gets a third of the window above it, but the window never starts so late that blank room shows under the last row
of a list longer than it (a list does not scroll past its end)."
  (goto-char start)
  (drgnx-wb-with-owned-windows (list window)
    (set-window-point window start)
    (let* ((height (window-body-height window)) (line (count-lines (point-min) start))
           (rows (count-lines (point-min) (point-max)))
           (top (if (>= line height) (max 0 (min (- line (/ height 3)) (- rows height))) 0)))
      (set-window-start window (save-excursion (goto-char (point-min)) (forward-line top) (point)) t))))

(defun drgnx-outline-line-at (&optional pos)
  "The line (from 1) of the definition on the Outline's row at POS (default point), or nil."
  (when-let* ((h (drgnx-outline--handle)) (id (drgnx-view-key-at (or pos (point)))))
    (nidhogg-view-get h 'field "line" id)))

(defun drgnx-outline-jump (line &optional select)
  "Show the definition at LINE (from 1) of the Outline's file in the editor (SELECT: and go there)."
  (when-let* ((line) (editor (drgnx-wb-editor-window)) ((buffer-live-p drgnx-outline--source)))
    (unless (eq (window-buffer editor) drgnx-outline--source) (set-window-buffer editor drgnx-outline--source))
    (set-window-point editor (with-current-buffer drgnx-outline--source
                               (save-restriction (widen) (goto-char (point-min)) (forward-line (1- line)) (point))))
    (with-selected-window editor (recenter 3))
    (when select (select-window editor))))

(defun drgnx-outline-open () "Go to the definition at point." (interactive)
       (drgnx-outline-jump (drgnx-outline-line-at) t))

(defun drgnx-outline-mouse-jump (event)
  "Show the clicked definition; stay in the Outline."
  (interactive "e")
  (when-let* ((posn (event-start event)) (pos (posn-point posn)))
    (with-selected-window (posn-window posn)
      (goto-char pos)
      (drgnx-outline-jump (drgnx-outline-line-at pos)))))

(defun drgnx-outline-focus () "Show the sidebar and focus the Outline." (interactive) (drgnx-wb-focus-section 'outline))

(defun drgnx-outline-setup ()
  "Put the Outline in the dock, below the Explorer, following the editor."
  (require 'drgnx-panes)
  (drgnx-pane-define-kind 'outline :home 'left :slot 1 :title drgnx-outline-title :height 0.25 :collapsed t
                          :buffer #'drgnx-outline--buffer :on-show (lambda (_w) (drgnx-outline-refresh)))
  (drgnx-signal-subscribe 'editor-changed #'drgnx-outline-refresh)
  (drgnx-signal-subscribe 'editor-point-changed #'drgnx-outline--mark-current)
  (drgnx-wb-rows-follow))

(provide 'drgnx-outline)
;;; drgnx-outline.el ends here
