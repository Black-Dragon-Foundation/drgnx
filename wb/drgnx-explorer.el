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

(defun drgnx-explorer--row (path depth dirp expanded)
  "One row: indent guides, chevron, name; text properties carry PATH, DEPTH and DIRP."
  (let ((name (file-name-nondirectory (directory-file-name path))))
    (propertize
     (concat (propertize (apply #'concat (make-list (max 0 (1- depth)) "│ ")) 'face 'drgnx-explorer-guide)
             (propertize (cond ((not dirp) "  ") (expanded "▾ ") (t "▸ ")) 'face 'drgnx-explorer-guide)
             (propertize (if (= depth 0) (upcase name) name)
                         'face (cond ((= depth 0) 'drgnx-explorer-root) (dirp 'drgnx-explorer-directory)
                                     (t 'drgnx-explorer-file)))
             "\n")
     'drgnx-node path 'drgnx-depth depth 'drgnx-dir dirp 'mouse-face 'highlight)))

(defun drgnx-explorer--subtree-rows (dir depth)
  "Rows for DIR's children at DEPTH, recursing into expanded folders, as one string."
  (let (rows)
    (cl-labels ((walk (dir depth)
                  (pcase-dolist (`(,name . ,dirp) (drgnx-explorer-children dir))
                    (let* ((path (expand-file-name name dir)) (open (and dirp (drgnx-explorer--expanded-p path))))
                      (push (drgnx-explorer--row path depth dirp open) rows)
                      (when open (walk path (1+ depth)))))))
      (walk dir depth))
    (apply #'concat (nreverse rows))))

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
    (let ((inhibit-read-only t) (at (get-text-property (point) 'drgnx-node)))
      (erase-buffer)
      (dolist (root drgnx-explorer--roots)
        (let ((path (directory-file-name (expand-file-name root))))
          (insert (drgnx-explorer--row path 0 t t))
          (insert (drgnx-explorer--subtree-rows path 1))))
      (goto-char (or (and at (drgnx-explorer--row-pos at)) (point-min))))))

(defun drgnx-explorer--row-pos (path)
  "Start of PATH's row, or nil."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((m (text-property-search-forward 'drgnx-node path t))) (prop-match-beginning m))))

(defun drgnx-explorer--subtree-end (bol depth)
  "End of the rows below the row at BOL that are deeper than DEPTH."
  (save-excursion
    (goto-char bol)
    (forward-line 1)
    (while (and (not (eobp)) (> (or (get-text-property (point) 'drgnx-depth) 0) depth))
      (forward-line 1))
    (point)))

(defun drgnx-explorer--set-chevron (bol depth expanded)
  (let* ((p (+ bol (* 2 (max 0 (1- depth))))) (props (text-properties-at p)))
    (delete-region p (1+ p))
    (save-excursion (goto-char p) (insert (apply #'propertize (if expanded "▾" "▸") props)))))

(defun drgnx-explorer-toggle-at (pos)
  "Expand or collapse the folder whose row is at POS (roots stay expanded)."
  (with-current-buffer (drgnx-explorer--buffer)
    (let ((path (get-text-property pos 'drgnx-node)) (depth (get-text-property pos 'drgnx-depth))
          (inhibit-read-only t)
          (bol (save-excursion (goto-char pos) (pos-bol))))
      (when (and path (get-text-property pos 'drgnx-dir) (> depth 0))
        (if (drgnx-explorer--expanded-p path)
            (progn (remhash path drgnx-explorer--expanded)
                   (delete-region (save-excursion (goto-char bol) (forward-line 1) (point))
                                  (drgnx-explorer--subtree-end bol depth))
                   (drgnx-explorer--set-chevron bol depth nil))
          (puthash path t drgnx-explorer--expanded)
          (save-excursion (goto-char bol) (forward-line 1) (insert (drgnx-explorer--subtree-rows path (1+ depth))))
          (drgnx-explorer--set-chevron bol depth t))
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
               (not (equal (with-current-buffer (window-buffer w) (get-text-property (window-point w) 'drgnx-node))
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

(defun drgnx-explorer--node () (get-text-property (point) 'drgnx-node))

(defun drgnx-explorer-activate (pos &optional keep-focus)
  "A folder toggles; a file opens in the editor (KEEP-FOCUS keeps the Explorer selected)."
  (when-let* ((path (get-text-property pos 'drgnx-node)))
    (if (get-text-property pos 'drgnx-dir)
        (drgnx-explorer-toggle-at pos)
      (drgnx-wb-show-in-editor (find-file-noselect path) (not keep-focus)))))

(defun drgnx-explorer-next () "Next row." (interactive) (forward-line 1) (when (eobp) (forward-line -1)))
(defun drgnx-explorer-previous () "Previous row." (interactive) (forward-line -1))

(defun drgnx-explorer-expand ()
  "Expand the folder at point; on an expanded folder, go to its first child."
  (interactive)
  (when (get-text-property (point) 'drgnx-dir)
    (if (and (drgnx-explorer--expanded-p (drgnx-explorer--node)) (> (get-text-property (point) 'drgnx-depth) 0))
        (drgnx-explorer-next)
      (drgnx-explorer-toggle-at (point)))))

(defun drgnx-explorer-collapse ()
  "Collapse the folder at point; otherwise go to the parent folder."
  (interactive)
  (if (and (get-text-property (point) 'drgnx-dir) (drgnx-explorer--expanded-p (drgnx-explorer--node))
           (> (get-text-property (point) 'drgnx-depth) 0))
      (drgnx-explorer-toggle-at (point))
    (let ((depth (get-text-property (point) 'drgnx-depth)))
      (while (and (not (bobp)) (>= (get-text-property (point) 'drgnx-depth) depth) (> depth 0))
        (forward-line -1)))))

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
    (when (and (integer-or-marker-p pos) (not (get-text-property pos 'drgnx-dir)) (get-text-property pos 'drgnx-node))
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
  (hl-line-mode 1))

(defun drgnx-explorer-setup ()
  "Put the Explorer in the dock and let it follow the editor."
  (drgnx-wb-define-section 'explorer :slot 0 :title " EXPLORER" :buffer #'drgnx-explorer--buffer)
  (drgnx-signal-subscribe 'editor-changed #'drgnx-explorer--follow))

(provide 'drgnx-explorer)
;;; drgnx-explorer.el ends here
