;;; drgnx-explorer.el --- The Explorer: a file tree in the left dock -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; drgnx's own file tree, built on plain Emacs.  The model is the roots, the set of expanded
;; folders and a per-folder listing cache (one `directory-files-and-attributes' call per folder,
;; reused while the folder's modification time is unchanged).  Rendering is incremental:
;; expanding a folder inserts its rows after the folder's row, collapsing deletes them.
;; Click model (VS Code): a click on a folder toggles it, on a file opens it in the editor and
;; keeps the Explorer focused; a double click on a file focuses the editor; drags do nothing.
;; The follower reveals the editor's file only on the change bus's `editor-changed' edge, never
;; while the Explorer is selected or a button is held, never outside the roots, and never
;; recentres a visible row.  See docs/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'text-property-search)
(require 'hl-line)
(require 'project)
(require 'drgnx-wb)

(defgroup drgnx-explorer nil "The drgnx Explorer." :group 'drgnx)

(defcustom drgnx-explorer-exclude
  "\\`\\(?:\\.git\\|\\.hg\\|\\.svn\\|\\.DS_Store\\|__pycache__\\|\\.#.*\\)\\'"
  "Names the Explorer never shows (a regexp)."
  :type 'regexp)

(defface drgnx-explorer-root '((t :inherit bold)) "The root rows.")
(defface drgnx-explorer-directory '((t :inherit default)) "Folder names.")
(defface drgnx-explorer-file '((t :inherit default)) "File names.")
(defface drgnx-explorer-guide '((t :inherit shadow)) "Indent guides and chevrons.")

(defconst drgnx-explorer-buffer-name "*drgnx explorer*")

(defvar drgnx-explorer--roots nil "The Explorer's root directories (never changed by the follower).")
(defvar drgnx-explorer--expanded (make-hash-table :test #'equal) "Expanded folders (paths without trailing /).")
(defvar drgnx-explorer--cache (make-hash-table :test #'equal) "Folder → (MTIME . CHILDREN).")
(defvar drgnx-explorer--pressed nil "Non-nil while a mouse button pressed in the Explorer is held.")

;;;; The model

(defun drgnx-explorer--before (a b)
  "Folders first, then natural, case-insensitive name order (file2 before file10)."
  (if (eq (cdr a) (cdr b))
      (string-version-lessp (downcase (car a)) (downcase (car b)))
    (cdr a)))

(defun drgnx-explorer-children (dir)
  "DIR's entries as sorted (NAME . DIRP), without excluded names; cached while DIR is unchanged."
  (let* ((dir (file-name-as-directory dir))
         (mtime (file-attribute-modification-time (file-attributes dir)))
         (hit (gethash dir drgnx-explorer--cache)))
    (if (and hit (equal (car hit) mtime))
        (cdr hit)
      (let (entries)
        (dolist (e (ignore-errors (directory-files-and-attributes dir nil nil t)))
          (let ((name (car e)) (type (file-attribute-type (cdr e))))
            (unless (or (member name '("." "..")) (string-match-p drgnx-explorer-exclude name))
              (push (cons name (or (eq type t)
                                   (and (stringp type) (file-directory-p (expand-file-name name dir)))))
                    entries))))
        (setq entries (sort entries #'drgnx-explorer--before))
        (puthash dir (cons mtime entries) drgnx-explorer--cache)
        entries))))

(defun drgnx-explorer--expanded-p (path) (gethash path drgnx-explorer--expanded))

;;;; Rows

(defvar drgnx-explorer--prefixes (make-hash-table :test #'equal)
  "(DEPTH . KIND) → the row prefix (indent guides and chevron), built once.")

(defun drgnx-explorer--prefix (depth kind)
  "Guides for DEPTH and the chevron for KIND (`file', `open', `closed') — plain text, built once
and shared by every row (faces are painted by `drgnx-explorer--fontify', for visible rows only)."
  (let ((key (cons depth kind)))
    (or (gethash key drgnx-explorer--prefixes)
        (puthash key (concat (apply #'concat (make-list (max 0 (1- depth)) "│ "))
                             (pcase kind ('file "  ") ('open "▾ ") (_ "▸ ")))
                 drgnx-explorer--prefixes))))

(defmacro drgnx-explorer--bulk (&rest body)
  "Run BODY, which builds many rows, without a garbage collection in the middle of it; the
garbage is collected afterwards, outside the interaction being measured by the user's eye."
  `(let ((gc-cons-threshold (max gc-cons-threshold (* 64 1024 1024)))) ,@body))

(defvar-local drgnx-explorer--rows []
  "The rows' data, one vector [NAME DEPTH DIRP PARENT] per line, in order (a virtual list: the
buffer holds plain text, this holds what each line is).  PARENT is the folder's path, shared by
its children; nil for a root, whose NAME is its path.  Only the functions below change the
buffer, and they keep both in step.")

(defun drgnx-explorer--index (pos) (1- (line-number-at-pos pos t)))

(defun drgnx-explorer--row-data (pos)
  "The data vector of the row at POS, or nil."
  (when pos
    (let ((i (drgnx-explorer--index pos)))
      (and (< -1 i (length drgnx-explorer--rows)) (aref drgnx-explorer--rows i)))))

(defun drgnx-explorer--line-pos (i)
  "Start of line I (0-based)."
  (save-excursion (goto-char (point-min)) (forward-line i) (point)))

(defun drgnx-explorer--path (v)
  (if (aref v 3) (concat (aref v 3) "/" (aref v 0)) (aref v 0)))

(defun drgnx-explorer-node-at (pos) "Path of the row at POS."
  (when-let* ((v (drgnx-explorer--row-data pos))) (drgnx-explorer--path v)))
(defun drgnx-explorer-depth-at (pos) "Depth of the row at POS (0 for a root)."
  (when-let* ((v (drgnx-explorer--row-data pos))) (aref v 1)))
(defun drgnx-explorer-dir-at (pos) "Non-nil if the row at POS is a folder."
  (when-let* ((v (drgnx-explorer--row-data pos))) (aref v 2)))

(defun drgnx-explorer--fontify (beg end)
  "Paint the rows between BEG and END (jit-lock: only what is displayed): guides and chevron, the
name's face, the hover highlight."
  (save-excursion
    (goto-char beg)
    (forward-line 0)
    (let ((inhibit-read-only t) (end (save-excursion (goto-char end) (pos-eol)))
          (i (drgnx-explorer--index (point))) (rows drgnx-explorer--rows))
      (with-silent-modifications
        (while (and (< (point) end) (< i (length rows)))
          (let* ((v (aref rows i)) (depth (aref v 1))
                 (name-start (+ (point) (* 2 (max 0 (1- depth))) (if (= depth 0) 0 2))))
            (put-text-property (point) name-start 'face 'drgnx-explorer-guide)
            (add-text-properties name-start (pos-eol)
                                 (list 'face (cond ((= depth 0) 'drgnx-explorer-root) ((aref v 2) 'drgnx-explorer-directory)
                                                   (t 'drgnx-explorer-file))
                                       'mouse-face 'highlight)))
          (forward-line 1)
          (setq i (1+ i))))))
  `(jit-lock-bounds ,beg . ,end))

(defun drgnx-explorer--insert-subtree (dir depth)
  "Insert, at point, the rows of DIR's children at DEPTH, recursing into expanded folders; return
their data vectors in order (for `drgnx-explorer--rows').
Hot path (thousands of rows per expand): garbage is what makes a GUI session pause, so a row
allocates only its small data vector; the text is shared strings (prefix, name, newline) and
faces come later, from jit-lock, for the rows on screen."
  (drgnx-explorer--bulk
   (let (parts data)
     (cl-labels ((walk (dir depth)
                   (let ((parent (directory-file-name dir)))
                     (pcase-dolist (`(,name . ,dirp) (drgnx-explorer-children dir))
                       (let ((open (and dirp (drgnx-explorer--expanded-p (concat parent "/" name)))))
                         (push (drgnx-explorer--prefix depth (if dirp (if open 'open 'closed) 'file)) parts)
                         (push (drgnx-wb-display-name name) parts)
                         (push "\n" parts)
                         (push (vector name depth dirp parent) data)
                         (when open (walk (concat parent "/" name) (1+ depth))))))))
       (walk dir depth))
     ;; One insertion: inserting each part separately runs the change hooks (jit-lock) per part.
     (insert (apply #'concat (nreverse parts)))
     (nreverse data))))

(defun drgnx-explorer--buffer ()
  "The Explorer buffer, created and rendered on first use."
  (or (get-buffer drgnx-explorer-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-explorer-buffer-name)
        (drgnx-explorer-mode)
        (unless drgnx-explorer--roots (setq drgnx-explorer--roots (list (drgnx-explorer--default-root))))
        (drgnx-explorer--render)
        (current-buffer))))

(defun drgnx-explorer--default-root ()
  "The project of the editor's buffer, else its directory."
  (let ((default-directory (with-current-buffer (window-buffer (drgnx-wb-editor-window)) default-directory)))
    (file-name-as-directory (expand-file-name (if-let* ((p (project-current))) (project-root p) default-directory)))))

(defun drgnx-explorer--render ()
  "Render every root from scratch, keeping the row at point by its path."
  (with-current-buffer (get-buffer-create drgnx-explorer-buffer-name)
    (let* ((inhibit-read-only t) (at (drgnx-explorer-node-at (point))) data
           (kept (mapcar (lambda (w) (list w (drgnx-explorer-node-at (window-start w)) (drgnx-explorer-node-at (window-point w))))
                         (get-buffer-window-list (current-buffer) nil t))))
      (erase-buffer)
      (dolist (root drgnx-explorer--roots)
        (let ((path (directory-file-name (expand-file-name root))))
          (insert (drgnx-explorer--prefix 0 'open) (drgnx-wb-display-name (upcase (file-name-nondirectory path))) "\n")
          (push (list (vector path 0 t nil)) data)
          (push (drgnx-explorer--insert-subtree path 1) data)))
      (setq drgnx-explorer--rows (apply #'vconcat (nreverse data)))
      (goto-char (or (and at (drgnx-explorer--row-pos at)) (point-min)))
      (pcase-dolist (`(,w ,top ,pt) kept)
        (when-let* ((p (and top (drgnx-explorer--row-pos top)))) (set-window-start w p t))
        (when-let* ((p (and pt (drgnx-explorer--row-pos pt)))) (set-window-point w p)))
      (when hl-line-mode (hl-line-highlight)))))

(defun drgnx-explorer--row-pos (path)
  "Start of PATH's row, or nil."
  (let* ((parent (directory-file-name (file-name-directory path))) (name (file-name-nondirectory path))
         (i (cl-position-if (lambda (v) (if (aref v 3)
                                            (and (equal (aref v 0) name) (equal (aref v 3) parent))
                                          (equal (aref v 0) path)))
                            drgnx-explorer--rows)))
    (and i (drgnx-explorer--line-pos i))))

(defun drgnx-explorer--subtree-last (i)
  "Index just after the rows below row I that are deeper than it."
  (let ((depth (aref (aref drgnx-explorer--rows i) 1)) (j (1+ i)) (n (length drgnx-explorer--rows)))
    (while (and (< j n) (> (aref (aref drgnx-explorer--rows j) 1) depth)) (setq j (1+ j)))
    j))

(defun drgnx-explorer--set-chevron (bol depth expanded)
  (let ((p (+ bol (* 2 (max 0 (1- depth))))))
    (delete-region p (1+ p))
    (save-excursion (goto-char p) (insert (if expanded "▾" "▸")))))

(defun drgnx-explorer-toggle-at (pos)
  "Expand or collapse the folder whose row is at POS (roots stay expanded)."
  (with-current-buffer (drgnx-explorer--buffer)
    (let* ((i (drgnx-explorer--index pos)) (v (drgnx-explorer--row-data pos))
           (inhibit-read-only t)
           (bol (save-excursion (goto-char pos) (pos-bol)))
           (next (save-excursion (goto-char bol) (forward-line 1) (point))))
      (when (and v (aref v 2) (> (aref v 1) 0))
        (let ((path (drgnx-explorer--path v)) (depth (aref v 1)) (rows drgnx-explorer--rows))
          (if (drgnx-explorer--expanded-p path)
              (let ((j (drgnx-explorer--subtree-last i)))
                (remhash path drgnx-explorer--expanded)
                (delete-region next (save-excursion (goto-char next) (forward-line (- j i 1)) (point)))
                (setq drgnx-explorer--rows (vconcat (seq-subseq rows 0 (1+ i)) (seq-subseq rows j)))
                (drgnx-explorer--set-chevron bol depth nil))
            (puthash path t drgnx-explorer--expanded)
            (let ((new (save-excursion (goto-char next) (drgnx-explorer--insert-subtree path (1+ depth)))))
              (setq drgnx-explorer--rows (vconcat (seq-subseq rows 0 (1+ i)) new (seq-subseq rows (1+ i)))))
            (drgnx-explorer--set-chevron bol depth t)))
        t))))

(defun drgnx-explorer--root-of (file)
  (seq-find (lambda (r) (string-prefix-p (file-name-as-directory (expand-file-name r)) file)) drgnx-explorer--roots))

(defun drgnx-explorer-reveal (file &optional window)
  "Show FILE's row: expand its folders and put WINDOW's point on it (no scroll if visible).
Returns non-nil if FILE is under a root."
  (let* ((file (expand-file-name file)) (root (drgnx-explorer--root-of file)))
    (when root
      (with-current-buffer (drgnx-explorer--buffer)
        (let ((dir (directory-file-name (expand-file-name root))) (rel (file-relative-name file root)))
          (dolist (part (butlast (split-string rel "/" t)))
            (setq dir (expand-file-name part dir))
            (unless (drgnx-explorer--expanded-p dir)
              (when-let* ((pos (drgnx-explorer--row-pos dir))) (drgnx-explorer-toggle-at pos)))))
        (when-let* ((pos (drgnx-explorer--row-pos file)))
          (if (window-live-p window)
              (progn
                (set-window-point window pos)
                (unless (pos-visible-in-window-p pos window)
                  (set-window-start window (save-excursion (goto-char pos)
                                                           (forward-line (- (/ (window-body-height window) 4)))
                                                           (pos-bol))))
                (save-excursion (goto-char pos) (when hl-line-mode (hl-line-highlight))))
            (goto-char pos))
          t)))))

(defun drgnx-explorer--follow (buffer)
  "On `editor-changed': reveal BUFFER's file — unless the user is in the Explorer or holds a button."
  (let ((w (drgnx-wb-section-window 'explorer))
        (file (and (buffer-live-p buffer) (buffer-local-value 'buffer-file-name buffer))))
    (when (and (window-live-p w) file (not (eq (selected-window) w)) (not drgnx-explorer--pressed)
               (not (equal (with-current-buffer (window-buffer w) (drgnx-explorer-node-at (window-point w)))
                           file)))
      (drgnx-explorer-reveal file w))))

(defun drgnx-explorer-set-roots (roots)
  "Show ROOTS (directories) in the Explorer."
  (setq drgnx-explorer--roots (mapcar (lambda (r) (file-name-as-directory (expand-file-name r))) roots))
  (drgnx-explorer--buffer)
  (drgnx-explorer--render))

(defun drgnx-explorer-roots () drgnx-explorer--roots)

(defun drgnx-explorer-refresh ()
  "Re-read changed folders and render again, keeping expansion and the selected row."
  (interactive)
  (drgnx-explorer--buffer)
  (drgnx-explorer--render))

;;;; Commands

(defun drgnx-explorer--node () (drgnx-explorer-node-at (point)))

(defun drgnx-explorer-activate (pos &optional keep-focus)
  "A folder toggles; a file opens in the editor (KEEP-FOCUS keeps the Explorer selected)."
  (when-let* ((path (drgnx-explorer-node-at pos)))
    (if (drgnx-explorer-dir-at pos)
        (drgnx-explorer-toggle-at pos)
      (drgnx-wb-show-in-editor (find-file-noselect path) (not keep-focus)))))

(defun drgnx-explorer-next () "Next row." (interactive) (forward-line 1) (when (eobp) (forward-line -1)))
(defun drgnx-explorer-previous () "Previous row." (interactive) (forward-line -1))

(defun drgnx-explorer-expand ()
  "Expand the folder at point; on an expanded folder, go to its first child."
  (interactive)
  (when (drgnx-explorer-dir-at (point))
    (if (and (drgnx-explorer--expanded-p (drgnx-explorer--node)) (> (drgnx-explorer-depth-at (point)) 0))
        (drgnx-explorer-next)
      (drgnx-explorer-toggle-at (point)))))

(defun drgnx-explorer-collapse ()
  "Collapse the folder at point; otherwise go to the parent folder."
  (interactive)
  (if (and (drgnx-explorer-dir-at (point)) (drgnx-explorer--expanded-p (drgnx-explorer--node))
           (> (drgnx-explorer-depth-at (point)) 0))
      (drgnx-explorer-toggle-at (point))
    (let* ((i (drgnx-explorer--index (point))) (depth (drgnx-explorer-depth-at (point))) (j i))
      (when (and depth (> depth 0))
        (while (and (> j 0) (>= (aref (aref drgnx-explorer--rows j) 1) depth)) (setq j (1- j)))
        (forward-line (- j i))))))

(defun drgnx-explorer-open () "Open the file (focus the editor) or toggle the folder at point."
  (interactive) (drgnx-explorer-activate (point)))
(defun drgnx-explorer-preview () "Open the file at point, keeping the Explorer focused."
  (interactive) (drgnx-explorer-activate (point) t))
(defun drgnx-explorer-toggle () "Expand or collapse the folder at point."
  (interactive) (drgnx-explorer-toggle-at (point)))

(defun drgnx-explorer-focus () "Show the sidebar and focus the Explorer."
  (interactive) (drgnx-wb-focus-section 'explorer))

;;;; Mouse (the click model)

(defun drgnx-explorer-mouse-press (event)
  "Press: select the row under EVENT (and the Explorer); nothing else happens until release."
  (interactive "e")
  (setq drgnx-explorer--pressed t)
  (let* ((posn (event-start event)) (w (posn-window posn)) (pos (posn-point posn)))
    (when (window-live-p w)
      (unless (eq w (selected-window)) (select-window w))
      (when (integer-or-marker-p pos) (goto-char pos)))))

(defun drgnx-explorer-mouse-click (event)
  "Release without moving: a folder toggles, a file opens keeping the Explorer focused."
  (interactive "e")
  (setq drgnx-explorer--pressed nil)
  (let ((pos (posn-point (event-end event))))
    (when (integer-or-marker-p pos) (goto-char pos) (drgnx-explorer-activate pos t))))

(defun drgnx-explorer-mouse-double (event)
  "Double click: on a file, focus the editor (the first click opened it); on a folder, nothing
\(the first click toggled it)."
  (interactive "e")
  (setq drgnx-explorer--pressed nil)
  (let ((pos (posn-point (event-end event))))
    (when (and (integer-or-marker-p pos) (not (drgnx-explorer-dir-at pos)) (drgnx-explorer-node-at pos))
      (drgnx-wb-focus-editor))))

(defun drgnx-explorer-mouse-ignore (_event)
  "Drags and repeated presses do nothing in the Explorer (no drag-to-move)."
  (interactive "e")
  (setq drgnx-explorer--pressed nil))

(defvar drgnx-explorer-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map drgnx-wb-dock-map)
    ;; The click model is part of the Explorer, not a key choice: mouse events are bound here.
    (keymap-set map "<down-mouse-1>" #'drgnx-explorer-mouse-press)
    (keymap-set map "<mouse-1>" #'drgnx-explorer-mouse-click)
    (keymap-set map "<double-down-mouse-1>" #'ignore)
    (keymap-set map "<double-mouse-1>" #'drgnx-explorer-mouse-double)
    (keymap-set map "<triple-down-mouse-1>" #'ignore)
    (keymap-set map "<triple-mouse-1>" #'drgnx-explorer-mouse-ignore)
    (keymap-set map "<drag-mouse-1>" #'drgnx-explorer-mouse-ignore)
    map)
  "Keys of the Explorer; keyboard keys come from the key profiles.")

(define-derived-mode drgnx-explorer-mode nil "Explorer"
  "The drgnx Explorer (file tree)."
  (setq buffer-read-only t buffer-undo-list t truncate-lines t cursor-type nil mode-line-format nil)
  (setq-local hl-line-sticky-flag t)
  ;; A press on a partly visible row must not scroll: the row would move under the pointer.
  (setq-local scroll-margin 0 make-cursor-line-fully-visible nil)
  (hl-line-mode 1)
  (jit-lock-register #'drgnx-explorer--fontify))

(defun drgnx-explorer-setup ()
  "Put the Explorer in the dock and let it follow the editor."
  (drgnx-wb-define-section 'explorer :slot 0 :title " EXPLORER" :buffer #'drgnx-explorer--buffer
                           ;; Like VS Code: showing the Explorer reveals the active editor's file.
                           :on-show (lambda (_w) (drgnx-explorer--follow (window-buffer (drgnx-wb-editor-window)))))
  (drgnx-signal-subscribe 'editor-changed #'drgnx-explorer--follow))

(provide 'drgnx-explorer)
;;; drgnx-explorer.el ends here
