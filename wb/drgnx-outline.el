;;; drgnx-outline.el --- The Outline section: the editor's definitions -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A dock section below the Explorer listing the definitions of the file in the editor (imenu),
;; nested as imenu nests them.  A click shows the definition in the editor and keeps you in the
;; Outline (browse on); RET goes there.  It follows the editor (the bus's `editor-changed' edge)
;; and, half a second after you stop typing, the file's changes.  Files without an index, remote
;; files and very large buffers get a one-line notice instead — computing an index never blocks
;; typing.  The definition the editor's point is in is marked with an overlay (the Outline's own point is
;; yours and never moves), on the bus's `editor-point-changed' edge.
;;
;; The Outline is a view (wb/drgnx-view.el): a refresh syncs the keyed rows (NAME DEPTH ORDINAL), so an edit that only
;; moves definitions redraws no row, and the positions are integers (the imenu markers are released at once).
;; See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'imenu)
(require 'drgnx-wb)
(require 'drgnx-timer)
(require 'drgnx-view)

(defface drgnx-outline-group '((t :inherit shadow)) "A group of definitions (imenu submenu)." :group 'drgnx)

(defcustom drgnx-outline-max-size (* 1024 1024)
  "Buffers larger than this (characters) get no outline." :type 'integer :group 'drgnx)
(defcustom drgnx-outline-delay 0.5 "Idle seconds after an edit before the Outline follows it."
  :type 'number :group 'drgnx)

(defface drgnx-outline-current '((t :inherit highlight :weight bold))
  "The definition the editor's point is in." :group 'drgnx)

(defconst drgnx-outline-buffer-name " *drgnx outline*" "Internal (a leading space): not in C-x b or ibuffer.")
(defvar drgnx-outline--rows [] "Per line: [NAME DEPTH POSITION-or-nil KEY]; POSITION is an integer.")
(defvar drgnx-outline--table (make-hash-table :test #'equal) "KEY -> the row of `drgnx-outline--rows' it names.")
(defvar drgnx-outline--source nil "The buffer the Outline shows.")
(defvar drgnx-outline--reveal nil "Non-nil: a new file's rows are marked; their first draw shows the current definition.")

(defvar drgnx-outline-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m drgnx-wb-dock-map)
    (define-key m [mouse-1] #'drgnx-outline-mouse-jump)
    m))

(define-derived-mode drgnx-outline-mode special-mode "Outline"
  "The editor's definitions."
  (setq-local truncate-lines t cursor-type nil mode-line-format nil)
  (hl-line-mode 1))

(defun drgnx-outline--buffer ()
  (or (get-buffer drgnx-outline-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-outline-buffer-name)
        (drgnx-outline-mode)
        (drgnx-view-attach 'outline)
        (current-buffer))))

(defun drgnx-outline--position (pos)
  "POS (an imenu position: a marker, an overlay or an integer) as an integer; a marker is released."
  (cond ((markerp pos) (prog1 (marker-position pos) (set-marker pos nil)))
        ((overlayp pos) (overlay-start pos))
        (t pos)))

(defun drgnx-outline--flatten (index depth)
  "IMENU INDEX as rows [NAME DEPTH POSITION], POSITION an integer: no imenu marker stays in the source buffer."
  (cl-loop for (name . rest) in index
           when (and (stringp name)                     ; imenu answers (nil) when it found nothing
                     (not (equal name (car imenu--rescan-item))))
           append (if (imenu--subalist-p (cons name rest))
                      (cons (vector name depth nil) (drgnx-outline--flatten rest (1+ depth)))
                    (list (vector name depth (drgnx-outline--position rest))))))

(defun drgnx-outline--index (src)
  "SRC's rows, or a notice string."
  (with-current-buffer src
    (cond ((and buffer-file-name (file-remote-p buffer-file-name)) "Outline is off for remote files")
          ((> (buffer-size) drgnx-outline-max-size) "This file is too large for an outline")
          (t (let ((rows (while-no-input            ; a key pressed meanwhile wins: try again later
                           (ignore-errors
                             (let ((imenu-auto-rescan t) (imenu--index-alist nil) (non-essential t))
                               (drgnx-outline--flatten (imenu--make-index-alist t) 0))))))
               (cond ((eq rows t) 'interrupted)
                     (rows)
                     (t "No outline for this file")))))))

(defun drgnx-outline--watch (src)
  "Follow SRC's edits (and stop following the previous source)."
  (unless (eq src drgnx-outline--source)
    (when (buffer-live-p drgnx-outline--source)
      (with-current-buffer drgnx-outline--source (remove-hook 'after-change-functions #'drgnx-outline--changed t)))
    (setq drgnx-outline--source src)
    (when (buffer-live-p src)
      (with-current-buffer src (add-hook 'after-change-functions #'drgnx-outline--changed nil t)))))

(defun drgnx-outline--changed (&rest _)
  "An edit in the source: refresh once typing pauses."
  (drgnx-timer-soon 'outline-refresh drgnx-outline-delay #'drgnx-outline--idle :idle t
                    :owner (get-buffer drgnx-outline-buffer-name)))

(defun drgnx-outline--idle ()
  (drgnx-outline-refresh))

(defun drgnx-outline-refresh (&rest _)
  "Show the definitions of the file in the editor — only while the Outline is shown (showing it
refreshes it): an index can take most of a second to build.  Hidden, it stops following edits."
  (if (get-buffer-window drgnx-outline-buffer-name t)
      (drgnx-outline--refresh-1)
    (drgnx-outline--watch nil)))

(defun drgnx-outline--keyed (rows)
  "Make ROWS (vectors [NAME DEPTH POSITION]) `drgnx-outline--rows', each with its key (NAME DEPTH ORDINAL) added:
ORDINAL counts the earlier rows with that name and depth.  Fills `drgnx-outline--table'; returns the keys in order."
  (let ((seen (make-hash-table :test #'equal)) (keyed nil))
    (clrhash drgnx-outline--table)
    (dolist (r rows)
      (let* ((nd (cons (aref r 0) (aref r 1))) (n (gethash nd seen 0)) (key (list (aref r 0) (aref r 1) n))
             (row (vector (aref r 0) (aref r 1) (aref r 2) key)))
        (puthash nd (1+ n) seen)
        (puthash key row drgnx-outline--table)
        (push row keyed)))
    (setq keyed (nreverse keyed)
          drgnx-outline--rows (vconcat keyed))
    (mapcar (lambda (r) (aref r 3)) keyed)))

(defun drgnx-outline--sig (key)
  "KEY's signature: whether its row is a group.  A definition that moved has the same signature."
  (let ((r (gethash key drgnx-outline--table))) (and r (null (aref r 2)) t)))

(defun drgnx-outline--render-row (key)
  "The text of KEY's row: a notice, a group or a definition, from the column of the section's title (2)."
  (if (eq (car-safe key) :notice)
      (propertize (concat "  " (cadr key) "\n") 'face 'shadow)
    (let* ((r (gethash key drgnx-outline--table))
           (text (concat (make-string (+ 2 (* 2 (nth 1 key))) ?\s) (drgnx-wb-display-name (car key)) "\n")))
      (if (and r (null (aref r 2))) (propertize text 'face 'drgnx-outline-group) text))))

(drgnx-view-define 'outline :render #'drgnx-outline--render-row :delay 0 :key-test 'equal
                   :patched #'drgnx-outline--mark-current)

(defun drgnx-outline--refresh-1 ()
  "Sync the rows to the editor's file.  A new file replaces every row (two files can share a key, a group like
\"Variables\"), so the Outline starts at its top, and its next draw shows the current definition."
  (let* ((editor (drgnx-wb-editor-window)) (src (and editor (window-buffer editor)))
         (rows (and src (drgnx-outline--index src))) (new (not (eq src drgnx-outline--source))))
    (if (eq rows 'interrupted)
        (drgnx-outline--changed)                     ; you typed meanwhile: at the next pause
      (drgnx-outline--watch src)
      (with-current-buffer (drgnx-outline--buffer)
        (let ((keys (if (stringp (or rows ""))
                        (progn (setq drgnx-outline--rows [])
                               (clrhash drgnx-outline--table)
                               (list (list :notice (or rows ""))))
                      (drgnx-outline--keyed rows))))
          (when new
            (drgnx-view-reset drgnx-view nil)
            (setq drgnx-outline--reveal t))
          (drgnx-view-sync-rows drgnx-view keys #'drgnx-outline--sig))
        (drgnx-outline--mark-current)))))

(defun drgnx-outline--mark-current (&rest _)
  "Mark, in the Outline, the last definition that starts at or before the editor's point (an overlay: the
Outline's point and window are not touched, except by the first draw of a new file, which shows the marked row:
`drgnx-outline--reveal').  Nothing when the Outline is hidden or point is above them all."
  (when-let* ((buf (get-buffer drgnx-outline-buffer-name)))
    (with-current-buffer buf
      (mapc (lambda (o) (when (overlay-get o 'drgnx-outline-current) (delete-overlay o))) (overlays-in (point-min) (point-max)))
      (let ((reveal (and drgnx-outline--reveal (not (drgnx-view-pending-p drgnx-view)))))
        (when reveal (setq drgnx-outline--reveal nil))
        (when-let* ((window (get-buffer-window buf t)) ((buffer-live-p drgnx-outline--source))
                    (editor (drgnx-wb-editor-window)) ((eq (window-buffer editor) drgnx-outline--source))
                    (point (window-point editor))
                    (best (let ((best nil) (best-pos -1))
                            (seq-doseq (r drgnx-outline--rows)
                              (when-let* ((p (aref r 2)))
                                (when (and (<= p point) (>= p best-pos)) (setq best r best-pos p))))
                            best))
                    (start (drgnx-view-row-start drgnx-view (aref best 3))))
          (save-excursion
            (goto-char start)
            (let ((o (make-overlay (pos-bol) (pos-eol))))
              (overlay-put o 'drgnx-outline-current t)
              (overlay-put o 'face 'drgnx-outline-current)))
          (when reveal (drgnx-outline--reveal-row window start)))))))

(defun drgnx-outline--reveal-row (window start)
  "Put WINDOW's point (and the buffer's) on the row at START; a row below the first screen gets a third of the
window above it."
  (goto-char start)
  (drgnx-wb-with-owned-windows (list window)
    (set-window-point window start)
    (let ((height (window-body-height window)))
      (when (>= (count-lines (point-min) start) height)
        (set-window-start window (save-excursion (forward-line (- (/ height 3))) (point)) t)))))

(defun drgnx-outline-jump (i &optional select)
  "Show row I's definition in the editor (SELECT: and go there)."
  (when-let* ((r (and (< -1 i (length drgnx-outline--rows)) (aref drgnx-outline--rows i)))
              (pos (aref r 2)) (editor (drgnx-wb-editor-window)) ((buffer-live-p drgnx-outline--source)))
    (unless (eq (window-buffer editor) drgnx-outline--source) (set-window-buffer editor drgnx-outline--source))
    (set-window-point editor pos)
    (with-selected-window editor (recenter 3))
    (when select (select-window editor))))

(defun drgnx-outline-open () "Go to the definition at point." (interactive)
       (drgnx-outline-jump (1- (line-number-at-pos)) t))

(defun drgnx-outline-mouse-jump (event)
  "Show the clicked definition; stay in the Outline."
  (interactive "e")
  (when-let* ((posn (event-start event)) (pos (posn-point posn)))
    (with-selected-window (posn-window posn)
      (goto-char pos)
      (drgnx-outline-jump (1- (line-number-at-pos pos))))))

(defun drgnx-outline-focus () "Show the sidebar and focus the Outline." (interactive) (drgnx-wb-focus-section 'outline))

(defun drgnx-outline-setup ()
  "Put the Outline in the dock, below the Explorer, following the editor."
  (drgnx-wb-define-section 'outline :slot 1 :title " OUTLINE" :height 0.25 :buffer #'drgnx-outline--buffer
                           :on-show (lambda (_w) (drgnx-outline-refresh)))
  (drgnx-signal-subscribe 'editor-changed #'drgnx-outline-refresh)
  (drgnx-signal-subscribe 'editor-point-changed #'drgnx-outline--mark-current))

(provide 'drgnx-outline)
;;; drgnx-outline.el ends here
