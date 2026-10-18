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
;; recentres a visible row.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'text-property-search)
(require 'hl-line)
(require 'project)
(require 'filenotify)
(require 'drgnx-wb)
(require 'drgnx-git)

(defgroup drgnx-explorer nil "The drgnx Explorer." :group 'drgnx)

(defcustom drgnx-explorer-exclude
  "\\`\\(?:\\.git\\|\\.hg\\|\\.svn\\|\\.DS_Store\\|__pycache__\\|\\.#.*\\)\\'"
  "Names the Explorer never shows (a regexp)."
  :type 'regexp)

(defface drgnx-explorer-root '((t :inherit bold)) "The root rows." :group 'drgnx)
(defface drgnx-explorer-directory '((t :inherit default)) "Folder names." :group 'drgnx)
(defface drgnx-explorer-file '((t :inherit default)) "File names." :group 'drgnx)
(defface drgnx-explorer-guide '((t :inherit shadow)) "Indent guides and chevrons." :group 'drgnx)
(defface drgnx-explorer-selected '((t :inherit region)) "Rows selected together (multi-select)." :group 'drgnx)

(defconst drgnx-explorer-buffer-name " *drgnx explorer*" "Internal (a leading space): not in C-x b or ibuffer.")

(defvar drgnx-explorer--roots nil "The Explorer's root directories (never changed by the follower).")
(defvar drgnx-explorer--expanded (make-hash-table :test #'equal) "Expanded folders (paths without trailing /).")
(defvar drgnx-explorer--cache (make-hash-table :test #'equal) "Folder → (MTIME . CHILDREN).")
(defvar drgnx-explorer--pressed nil
  "Non-nil while a mouse button pressed in the Explorer is held: `num-input-keys' at the press (or t).
Ask `drgnx-explorer--held-p', which knows when a release never came.")
(defvar drgnx-explorer--selection nil "Paths selected together (multi-select), or nil: the row at point.")
(defvar drgnx-explorer--focused-before nil "The focused row before the current press.")
(defvar drgnx-explorer--renders 0 "How many full renders (tests read it).")
(defvar drgnx-explorer--find nil
  "While Find filters the tree: (:query Q :files ALL-FILES :expanded SAVED :views SAVED).")

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
  "Start of line I (0-based, counted from the buffer's start, as `drgnx-explorer--index' counts)."
  (save-excursion (save-restriction (widen) (goto-char (point-min)) (forward-line i) (point))))

(defun drgnx-explorer--join (dir name)
  "DIR (no trailing /, except a root like / or C:/) and NAME as one path."
  (concat (file-name-as-directory dir) name))

(defun drgnx-explorer--path (v)
  (if (aref v 3) (drgnx-explorer--join (aref v 3) (aref v 0)) (aref v 0)))

(defun drgnx-explorer-node-at (pos) "Path of the row at POS."
       (when-let* ((v (drgnx-explorer--row-data pos))) (drgnx-explorer--path v)))
(defun drgnx-explorer-depth-at (pos) "Depth of the row at POS (0 for a root)."
       (when-let* ((v (drgnx-explorer--row-data pos))) (aref v 1)))
(defun drgnx-explorer-dir-at (pos) "Non-nil if the row at POS is a folder."
       (when-let* ((v (drgnx-explorer--row-data pos))) (aref v 2)))

(defcustom drgnx-explorer-git t "Show git status in the Explorer (letters, colours, dimmed ignored files)."
  :type 'boolean)

(defun drgnx-explorer--git-decorate (bol eol path dirp name-start)
  "Colour the name and put the status letter (● for a folder with changes) at the right edge."
  (when-let* ((status (and drgnx-explorer-git (drgnx-git-status path))))
    (pcase-let ((`(,letter ,face) (drgnx-git-look status)))
      (add-face-text-property name-start eol face)
      (let ((mark (if (and dirp (not (memq status '(ignored untracked)))) "●" letter)))
        (when mark
          (let ((o (make-overlay eol eol)))
            (overlay-put o 'drgnx-git t)
            (overlay-put o 'after-string (concat (propertize " " 'display '(space :align-to (- right 2)))
                                                 (propertize mark 'face face)))))))
    (ignore bol)))

(defun drgnx-explorer--fontify (beg end)
  "Paint the rows between BEG and END (jit-lock: only what is displayed): guides and chevron, the
name's face, the hover highlight, the git status."
  (save-excursion
    (goto-char beg)
    (forward-line 0)
    (let ((inhibit-read-only t) (end (save-excursion (goto-char end) (pos-eol)))
          (i (drgnx-explorer--index (point))) (rows drgnx-explorer--rows))
      (remove-overlays (point) (min (1+ end) (point-max)) 'drgnx-git t)   ; END: its empty overlay too
      (with-silent-modifications
        (while (and (< (point) end) (< i (length rows)))
          (let* ((v (aref rows i)) (depth (aref v 1))
                 (name-start (+ (point) (* 2 (max 0 (1- depth))) (if (= depth 0) 0 2))))
            (put-text-property (point) name-start 'face 'drgnx-explorer-guide)
            (add-text-properties name-start (pos-eol)
                                 (list 'face (cond ((= depth 0) 'drgnx-explorer-root) ((aref v 2) 'drgnx-explorer-directory)
                                                   (t 'drgnx-explorer-file))
                                       'mouse-face 'highlight))
            (drgnx-explorer--git-decorate (point) (pos-eol) (drgnx-explorer--path v) (aref v 2) name-start)
            (when (and drgnx-explorer--selection (member (drgnx-explorer--path v) drgnx-explorer--selection))
              (add-face-text-property name-start (pos-eol) 'drgnx-explorer-selected)))
          (forward-line 1)
          (setq i (1+ i))))))
  `(jit-lock-bounds ,beg . ,end))

(defvar drgnx-explorer--children-function #'drgnx-explorer-children
  "Where rows come from: the disk, or (during Find) the matches.")
(defvar drgnx-explorer--expanded-function #'drgnx-explorer--expanded-p
  "Which folders are open: the user's, or (during Find) every folder shown.")

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
                     (pcase-dolist (`(,name . ,dirp) (funcall drgnx-explorer--children-function dir))
                       (let ((open (and dirp (funcall drgnx-explorer--expanded-function (drgnx-explorer--join parent name)))))
                         (push (drgnx-explorer--prefix depth (if dirp (if open 'open 'closed) 'file)) parts)
                         (push (drgnx-wb-display-name name) parts)
                         (push "\n" parts)
                         (push (vector name depth dirp parent) data)
                         (when open (walk (drgnx-explorer--join parent name) (1+ depth))))))))
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
    (cl-incf drgnx-explorer--renders)
    (let* ((inhibit-read-only t) (views (drgnx-explorer--save-views)) data)
      (erase-buffer)
      (dolist (root drgnx-explorer--roots)
        (let ((path (directory-file-name (expand-file-name root))))
          (insert (drgnx-explorer--prefix 0 'open) (drgnx-wb-display-name (upcase (file-name-nondirectory path))) "\n")
          (push (list (vector path 0 t nil)) data)
          (push (drgnx-explorer--insert-subtree path 1) data)))
      (setq drgnx-explorer--rows (apply #'vconcat (nreverse data)))
      (drgnx-explorer--restore-views views)
      (drgnx-explorer--sync-watches)
      (drgnx-explorer--git-refresh))))

(defvar drgnx-explorer--git-timer nil)

(defun drgnx-explorer--git-refresh ()
  "Read the git status of every root in the background — started once the tree is on screen
(starting a process costs milliseconds the render should not wait for)."
  (when (and drgnx-explorer-git (not (timerp drgnx-explorer--git-timer)))
    (setq drgnx-explorer--git-timer
          (run-with-idle-timer 0.05 nil (lambda ()
                                          (setq drgnx-explorer--git-timer nil)
                                          (drgnx-git-refresh-tree drgnx-explorer--roots))))))

(defun drgnx-explorer--git-changed (_root)
  "A git status arrived: repaint the visible rows."
  (when-let* ((buf (get-buffer drgnx-explorer-buffer-name)))
    (with-current-buffer buf (jit-lock-refontify))))

(defun drgnx-explorer--save-views ()
  "The row (path) at point, and each window's first row and selected row."
  (cons (cons (drgnx-explorer-node-at (point)) (drgnx-explorer--index (point)))
        (mapcar (lambda (w) (list w (cons (drgnx-explorer-node-at (window-start w)) (drgnx-explorer--index (window-start w)))
                                  (cons (drgnx-explorer-node-at (window-point w)) (drgnx-explorer--index (window-point w)))))
                (get-buffer-window-list (current-buffer) nil t))))

(defun drgnx-explorer--place (spot)
  "Where SPOT (PATH . LINE) is now: PATH's row, else the same line (a deleted row's neighbour)."
  (or (and (car spot) (drgnx-explorer--row-pos (car spot)))
      (drgnx-explorer--line-pos (max 0 (min (cdr spot) (1- (length drgnx-explorer--rows)))))))

(defun drgnx-explorer--restore-views (views)
  "Put point and every window back on the rows (paths) VIEWS recorded."
  (goto-char (drgnx-explorer--place (car views)))
  (pcase-dolist (`(,w ,top ,pt) (cdr views))
    (when (window-live-p w)
      (drgnx-wb-with-owned-windows (list w)               ; the Explorer's own windows
        (set-window-start w (drgnx-explorer--place top) t)
        (set-window-point w (drgnx-explorer--place pt)))))
  (when hl-line-mode (hl-line-highlight)))

;;;; Live updates

(defcustom drgnx-explorer-event-delay 0.15
  "Seconds to gather file events before the changed folders are shown again."
  :type 'number)

(defvar drgnx-explorer--watches (make-hash-table :test #'equal) "Shown folder → watch descriptor (or `none').")
(defvar drgnx-explorer--dirty nil "Folders with file events not shown yet.")
(defvar drgnx-explorer--event-timer nil)
(defvar drgnx-explorer--relists 0 "How many folders were refreshed from events (tests read it).")
(defconst drgnx-explorer--splice-limit 20 "More changed folders than this at once: one full render instead.")

(defun drgnx-explorer--shown-folders ()
  "Every folder whose contents are on screen: the roots and the expanded, displayed folders."
  (let (out)
    (seq-doseq (v drgnx-explorer--rows)
      (when (and (aref v 2) (or (= (aref v 1) 0) (drgnx-explorer--expanded-p (drgnx-explorer--path v))))
        (push (drgnx-explorer--path v) out)))
    out))

(defun drgnx-explorer--sync-watches ()
  "Watch exactly the shown folders (a collapsed folder stops being watched; one that could not be
watched — the inotify limit — is tried again)."
  (let ((want (make-hash-table :test #'equal)) gone)
    (dolist (d (drgnx-explorer--shown-folders)) (puthash d t want))
    (maphash (lambda (d desc)
               (unless (and (gethash d want) (not (eq desc 'none)) (file-notify-valid-p desc))
                 (push (cons d desc) gone)))
             drgnx-explorer--watches)
    (pcase-dolist (`(,d . ,desc) gone)
      (remhash d drgnx-explorer--watches)            ; first: the `stopped' this sends is ours (ignored)
      (unless (eq desc 'none) (ignore-errors (file-notify-rm-watch desc))))
    (maphash (lambda (d _)
               (unless (gethash d drgnx-explorer--watches)
                 (puthash d (or (ignore-errors
                                  (file-notify-add-watch d '(change) (lambda (event) (drgnx-explorer--file-event event d))))
                                'none)
                          drgnx-explorer--watches)))
             want)))

(defun drgnx-explorer--unwatch-all ()
  (let (descs)
    (maphash (lambda (_ desc) (unless (eq desc 'none) (push desc descs))) drgnx-explorer--watches)
    (clrhash drgnx-explorer--watches)               ; first: the `stopped' events this sends are ours
    (dolist (desc descs) (ignore-errors (file-notify-rm-watch desc)))))

(defun drgnx-explorer--file-event (event dir)
  "A watch on DIR saw EVENT: remember DIR and arm one delayed refresh (no work here)."
  (when (eq (nth 1 event) 'stopped)
    (if (not (equal (gethash dir drgnx-explorer--watches) (car event)))
        (setq event nil)                            ; we removed it (collapse, re-render): nothing changed
      (remhash dir drgnx-explorer--watches)         ; the folder went (rm -rf …): watch it again if it comes back
      (setq dir (drgnx-explorer--parent dir))))
  (when (memq (nth 1 event) '(created deleted renamed stopped))
    (cl-pushnew dir drgnx-explorer--dirty :test #'equal)
    (unless (timerp drgnx-explorer--event-timer)
      (setq drgnx-explorer--event-timer
            (run-with-timer drgnx-explorer-event-delay nil #'drgnx-explorer--apply-file-events)))))

(defun drgnx-explorer--apply-file-events ()
  "Show the changed folders again — each once, in place; wait while a button is held."
  (setq drgnx-explorer--event-timer nil)
  (if (or (drgnx-explorer--held-p) drgnx-explorer--find)
      (setq drgnx-explorer--event-timer
            (run-with-timer drgnx-explorer-event-delay nil #'drgnx-explorer--apply-file-events))
    (let ((dirs drgnx-explorer--dirty))
      (setq drgnx-explorer--dirty nil)
      (when-let* ((buf (get-buffer drgnx-explorer-buffer-name)))
        (with-current-buffer buf
          (if (> (length dirs) drgnx-explorer--splice-limit)
              (progn (clrhash drgnx-explorer--cache) (drgnx-explorer--render))   ; a checkout: one pass
            (dolist (d dirs) (drgnx-explorer--refresh-dir d)))
          (drgnx-explorer--git-refresh))))))

(defun drgnx-explorer--refresh-dir (dir)
  "Re-list DIR (shown and expanded) and replace its rows in place, keeping views and selection."
  (when-let* ((pos (drgnx-explorer--row-pos dir))
              (v (drgnx-explorer--row-data pos))
              ((or (= (aref v 1) 0) (drgnx-explorer--expanded-p dir))))
    (cl-incf drgnx-explorer--relists)
    (remhash (file-name-as-directory dir) drgnx-explorer--cache)
    (let* ((inhibit-read-only t) (views (drgnx-explorer--save-views))
           (i (drgnx-explorer--index pos)) (j (drgnx-explorer--subtree-last i)) (rows drgnx-explorer--rows)
           (next (save-excursion (goto-char pos) (forward-line 1) (point))))
      (delete-region next (save-excursion (goto-char next) (forward-line (- j i 1)) (point)))
      (let ((new (save-excursion (goto-char next) (drgnx-explorer--insert-subtree dir (1+ (aref v 1))))))
        (setq drgnx-explorer--rows (vconcat (seq-subseq rows 0 (1+ i)) new (seq-subseq rows j))))
      (drgnx-explorer--restore-views views)
      (drgnx-explorer--sync-watches))))

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
      (when (and v (aref v 2) (> (aref v 1) 0) (not drgnx-explorer--find))   ; Find shows its own folders
        (let ((path (drgnx-explorer--path v)) (depth (aref v 1)) (rows drgnx-explorer--rows)
              (inhibit-quit t))                     ; a quit between the text and the rows would desync them
          (if (drgnx-explorer--expanded-p path)
              (let ((j (drgnx-explorer--subtree-last i)))
                (remhash path drgnx-explorer--expanded)
                (delete-region next (save-excursion (goto-char next) (forward-line (- j i 1)) (point)))
                (setq drgnx-explorer--rows (vconcat (seq-subseq rows 0 (1+ i)) (seq-subseq rows j)))
                (drgnx-explorer--set-chevron bol depth nil))
            (puthash path t drgnx-explorer--expanded)
            (let ((new (save-excursion (goto-char next) (drgnx-explorer--insert-subtree path (1+ depth)))))
              (setq drgnx-explorer--rows (vconcat (seq-subseq rows 0 (1+ i)) new (seq-subseq rows (1+ i)))))
            (drgnx-explorer--set-chevron bol depth t))
          (drgnx-explorer--sync-watches))
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
              (drgnx-wb-with-owned-windows (list window)
                (set-window-point window pos)
                (unless (pos-visible-in-window-p pos window)
                  (set-window-start window (save-excursion (goto-char pos)
                                                           (forward-line (- (/ (window-body-height window) 4)))
                                                           (pos-bol))))
                (save-excursion (goto-char pos) (when hl-line-mode (hl-line-highlight))))
            (goto-char pos))
          t)))))

(defun drgnx-explorer--follow (buffer)
  "On `editor-changed': reveal BUFFER's file — unless the user is in the Explorer or holds a button.
A remote file is never revealed: this runs from the change bus, where remote I/O could prompt."
  (let ((w (drgnx-wb-section-window 'explorer))
        (file (and (buffer-live-p buffer) (buffer-local-value 'buffer-file-name buffer))))
    (when (and file (file-remote-p file)) (setq file nil))
    (when (and (window-live-p w) file (not (eq (selected-window) w)) (not (drgnx-explorer--held-p))
               (not drgnx-explorer--find)
               (not (equal (with-current-buffer (window-buffer w) (drgnx-explorer-node-at (window-point w)))
                           file)))
      (drgnx-explorer-reveal file w))))

(defun drgnx-explorer-set-roots (roots)
  "Show ROOTS (directories) in the Explorer (this ends Find)."
  (when drgnx-explorer--find (setq drgnx-explorer--find nil) (drgnx-explorer--plain-title))
  (setq drgnx-explorer--roots (mapcar (lambda (r) (file-name-as-directory (expand-file-name r))) roots))
  (if (get-buffer drgnx-explorer-buffer-name) (drgnx-explorer--render) (drgnx-explorer--buffer)))   ; a new one renders itself

(defun drgnx-explorer-roots () drgnx-explorer--roots)

(defun drgnx-explorer-refresh ()
  "Re-read changed folders and render again, keeping expansion and the selected row (during Find: filter again)."
  (interactive)
  (drgnx-explorer--buffer)
  (if drgnx-explorer--find (drgnx-explorer--find-again) (drgnx-explorer--render)))

;;;; Commands

(defun drgnx-explorer--node () (drgnx-explorer-node-at (point)))

(defun drgnx-explorer-activate (pos &optional keep-focus)
  "A folder toggles; a file opens in the editor (KEEP-FOCUS keeps the Explorer selected)."
  (when-let* ((path (drgnx-explorer-node-at pos)))
    (if (drgnx-explorer-dir-at pos)
        (drgnx-explorer-toggle-at pos)
      (drgnx-wb-show-in-editor (find-file-noselect path) (not keep-focus)))))

(defun drgnx-explorer-next () "Next row (ends a multi-select)."
       (interactive) (drgnx-explorer--clear-selection) (forward-line 1) (when (eobp) (forward-line -1)))
(defun drgnx-explorer-previous () "Previous row (ends a multi-select)."
       (interactive) (drgnx-explorer--clear-selection) (forward-line -1))

;;;; Multi-select

(defvar drgnx-explorer--anchor nil "Where a Shift-selection started (a path).")

(defun drgnx-explorer--set-selection (paths)
  (setq drgnx-explorer--selection paths)
  (when-let* ((b (get-buffer drgnx-explorer-buffer-name))) (with-current-buffer b (jit-lock-refontify))))

(defun drgnx-explorer--clear-selection ()
  (setq drgnx-explorer--anchor nil)
  (when drgnx-explorer--selection (drgnx-explorer--set-selection nil)))

(defun drgnx-explorer--ensure-anchor ()
  "Start a range at the row here unless the anchor is a row on screen (not deleted, not from another root)."
  (unless (and drgnx-explorer--anchor (drgnx-explorer--row-pos drgnx-explorer--anchor))
    (setq drgnx-explorer--anchor (drgnx-explorer--node))))

(defun drgnx-explorer--select-range-to (pos)
  "Select every row from the anchor to the row at POS."
  (drgnx-explorer--ensure-anchor)
  (let* ((a (drgnx-explorer--index (or (drgnx-explorer--row-pos drgnx-explorer--anchor) (point))))
         (b (drgnx-explorer--index pos)))
    (drgnx-explorer--set-selection
     (cl-loop for i from (min a b) to (max a b) collect (drgnx-explorer--path (aref drgnx-explorer--rows i))))))

(defun drgnx-explorer--select-move (n)
  (drgnx-explorer--ensure-anchor)
  (forward-line n)
  (when (eobp) (forward-line -1))
  (drgnx-explorer--select-range-to (point)))

(defun drgnx-explorer-select-down () "Extend the selection one row down." (interactive) (drgnx-explorer--select-move 1))
(defun drgnx-explorer-select-up () "Extend the selection one row up." (interactive) (drgnx-explorer--select-move -1))

(defun drgnx-explorer-mark ()
  "Add the row here to the selection (or take it out), then go to the next row."
  (interactive)
  (let ((p (or (drgnx-explorer--node) (user-error "Nothing here"))))
    (drgnx-explorer--set-selection (if (member p drgnx-explorer--selection) (remove p drgnx-explorer--selection)
                                     (append drgnx-explorer--selection (list p))))
    (forward-line 1)
    (when (eobp) (forward-line -1))))

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

;;;; Find

(defvar-local drgnx-explorer--typed nil "Type-to-navigate: (TIME . PREFIX).")

(defun drgnx-explorer--navigate-type (char)
  "Jump to the next row whose name starts with what was typed (within a second) plus CHAR."
  (let* ((now (float-time))
         (prefix (concat (if (and drgnx-explorer--typed (< (- now (car drgnx-explorer--typed)) 1.0))
                             (cdr drgnx-explorer--typed) "")
                         (string char)))
         (rows drgnx-explorer--rows) (n (length rows)) (here (drgnx-explorer--index (point)))
         (from (if (> (length prefix) 1) here (1+ here))) found)
    (setq drgnx-explorer--typed (cons now prefix))
    (dotimes (k n)
      (let ((i (mod (+ from k) n)))
        (when (and (not found)
                   (string-prefix-p prefix (file-name-nondirectory (drgnx-explorer--path (aref rows i))) t))
          (setq found i))))
    (when found
      (goto-char (drgnx-explorer--line-pos found))
      (when hl-line-mode (hl-line-highlight)))))

(defun drgnx-explorer-type ()
  "Typing in the Explorer jumps to the next row starting with what you typed (as VS Code)."
  (interactive)
  (drgnx-explorer--navigate-type last-command-event))

(defun drgnx-explorer--all-files ()
  "Every file under the roots — the project's files (only those under the root) when there is a project;
excluded names left out.  A root that is your home or / and not a project is refused (far too many files)."
  (seq-mapcat (lambda (root)
                (let ((default-directory root))
                  (seq-remove (lambda (f) (seq-some (lambda (part) (string-match-p drgnx-explorer-exclude part))
                                                    (split-string (string-remove-prefix root f) "/" t)))
                              (if-let* ((p (project-current nil root)))
                                  (seq-filter (lambda (f) (string-prefix-p root f)) (project-files p))
                                (when (member (directory-file-name root)
                                              (list (directory-file-name (expand-file-name "~")) "" "/"))
                                  (user-error "Find needs a project folder here, not %s" (abbreviate-file-name root)))
                                (directory-files-recursively
                                 root "" nil (lambda (d) (not (string-match-p drgnx-explorer-exclude (file-name-nondirectory d)))))))))
              drgnx-explorer--roots))

(defconst drgnx-explorer--find-limit 5000 "Find shows at most this many matching files.")

(defun drgnx-explorer--find-apply (query)
  "Show only the files whose name contains QUERY (any case), with their folders — collapsed or not."
  (with-current-buffer (drgnx-explorer--buffer)
    (unless drgnx-explorer--find
      (setq drgnx-explorer--find (list :files (drgnx-explorer--all-files)
                                       :expanded (copy-hash-table drgnx-explorer--expanded)
                                       :views (drgnx-explorer--save-views))))
    (setq drgnx-explorer--find (plist-put drgnx-explorer--find :query query))
    (let ((tree (make-hash-table :test #'equal)) (q (downcase query)))
      (dolist (file (seq-take (seq-filter (lambda (file) (string-search q (downcase (file-name-nondirectory file))))
                                          (plist-get drgnx-explorer--find :files))
                              drgnx-explorer--find-limit))
        (progn
          (let ((path (directory-file-name file)))
            (while (let ((parent (directory-file-name (file-name-directory path))))
                     (unless (member (cons (file-name-nondirectory path) (not (equal path (directory-file-name file))))
                                     (gethash parent tree))
                       (push (cons (file-name-nondirectory path) (not (equal path (directory-file-name file)))) (gethash parent tree)))
                     (prog1 (not (or (member (file-name-as-directory parent) drgnx-explorer--roots)
                                     (equal parent path)))           ; at a root, or at / : stop
                       (setq path parent)))))))
      (let ((drgnx-explorer--children-function
             (lambda (dir) (sort (copy-sequence (gethash (directory-file-name dir) tree)) #'drgnx-explorer--before)))
            (drgnx-explorer--expanded-function (lambda (_) t))
            (inhibit-read-only t) data)
        (erase-buffer)
        (dolist (root drgnx-explorer--roots)
          (let ((path (directory-file-name (expand-file-name root))))
            (insert (drgnx-explorer--prefix 0 'open) (drgnx-wb-display-name (upcase (file-name-nondirectory path))) "\n")
            (push (list (vector path 0 t nil)) data)
            (push (drgnx-explorer--insert-subtree path 1) data)))
        (setq drgnx-explorer--rows (apply #'vconcat (nreverse data)))
        (goto-char (point-min))
        (when-let* ((w (drgnx-wb-section-window 'explorer)))
          (set-window-parameter w 'header-line-format (format " EXPLORER — %s" query)))))))

(defun drgnx-explorer--plain-title ()
  "The Explorer's title without a Find query."
  (when-let* ((w (drgnx-wb-section-window 'explorer)))
    (set-window-parameter w 'header-line-format " EXPLORER")))

(defun drgnx-explorer--forget-find ()
  "The Explorer was killed: its Find goes too (else the live updates would wait for it forever)."
  (setq drgnx-explorer--find nil))

(defun drgnx-explorer-find-clear ()
  "Leave Find: the tree, its open folders, the view and the selection come back as they were."
  (interactive)
  (when-let* ((state drgnx-explorer--find))
    (setq drgnx-explorer--find nil drgnx-explorer--expanded (plist-get state :expanded))
    (with-current-buffer (drgnx-explorer--buffer)
      (drgnx-explorer--render)
      (drgnx-explorer--restore-views (plist-get state :views)))
    (drgnx-explorer--plain-title)
    (when drgnx-explorer--dirty (drgnx-explorer--apply-file-events))))

(defun drgnx-explorer-find ()
  "Filter the Explorer to files whose names contain what you type (live); empty input clears it."
  (interactive)
  (let ((timer nil))
    (condition-case nil
        (let ((query (minibuffer-with-setup-hook
                         (lambda ()
                           (add-hook 'after-change-functions
                                     (lambda (&rest _)
                                       (let ((q (minibuffer-contents-no-properties)))
                                         (when (timerp timer) (cancel-timer timer))
                                         (setq timer (run-with-idle-timer
                                                      0.1 nil (lambda () (if (string-empty-p q) (drgnx-explorer-find-clear)
                                                                           (drgnx-explorer--find-apply q)))))))
                                     nil t))
                       (read-string "Find in Explorer: " (plist-get drgnx-explorer--find :query)))))
          (when (timerp timer) (cancel-timer timer))
          (if (string-empty-p query) (drgnx-explorer-find-clear) (drgnx-explorer--find-apply query)))
      (quit (when (timerp timer) (cancel-timer timer)) (drgnx-explorer-find-clear)))))

;;;; File operations
;; Each command takes its target paths when it starts — before any question — so a refresh while
;; you answer can never make it act on another row.  Nothing is ever overwritten; deletes go to
;; the trash unless asked otherwise.

(defvar drgnx-explorer--clipboard nil "(copy|cut PATHS) from Copy or Cut, for Paste.")

(defun drgnx-explorer--targets ()
  "The paths an operation acts on: the selection, else the row at point (never a root).  A path
inside another one selected goes: the folder carries it."
  (let* ((here (drgnx-explorer--node))
         (paths (if (and drgnx-explorer--selection here (member here drgnx-explorer--selection))
                    (seq-filter #'file-exists-p drgnx-explorer--selection)
                  ;; The focused row is not in the selection (a reveal, a right-click, typing): it is
                  ;; what the user means, as in VS Code.
                  (drgnx-explorer--clear-selection)
                  (and here (list here)))))
    (unless paths (user-error "No file or folder here"))
    (when (seq-find (lambda (p) (member (file-name-as-directory p) drgnx-explorer--roots)) paths)
      (user-error "Not on a root folder"))
    (seq-remove (lambda (p) (seq-some (lambda (q) (string-prefix-p (file-name-as-directory q) p)) paths))
                (delete-dups (copy-sequence paths)))))

(defun drgnx-explorer--folder-here ()
  "The folder at point, or the folder of the file at point."
  (let ((p (or (drgnx-explorer--node) (user-error "Nothing here"))))
    (if (drgnx-explorer-dir-at (point)) p (directory-file-name (file-name-directory p)))))

(defun drgnx-explorer--show-folder (dir)
  "Expand DIR (if collapsed) and show its current contents (during Find: filter again)."
  (if drgnx-explorer--find
      (drgnx-explorer--find-again)
    (drgnx-explorer--show-folder-1 dir)))

(defun drgnx-explorer--find-again ()
  "Filter again with fresh files (a file operation or a refresh during Find)."
  (setq drgnx-explorer--find (plist-put drgnx-explorer--find :files (drgnx-explorer--all-files)))
  (drgnx-explorer--find-apply (plist-get drgnx-explorer--find :query)))

(defun drgnx-explorer--show-folder-1 (dir)
  (with-current-buffer (drgnx-explorer--buffer)
    (let ((pos (drgnx-explorer--row-pos dir)))
      (when (and pos (> (drgnx-explorer-depth-at pos) 0) (not (drgnx-explorer--expanded-p dir)))
        (drgnx-explorer-toggle-at pos)))
    (drgnx-explorer--refresh-dir dir)
    (drgnx-explorer--git-refresh)))

(defun drgnx-explorer--select (path)
  (with-current-buffer (drgnx-explorer--buffer)
    (when-let* ((pos (drgnx-explorer--row-pos path)))
      (goto-char pos)
      (when-let* ((w (get-buffer-window (current-buffer)))) (set-window-point w pos))
      (when hl-line-mode (hl-line-highlight)))))

(defun drgnx-explorer--parent (path) (directory-file-name (file-name-directory (directory-file-name path))))

(defun drgnx-explorer--free-name (path)
  "PATH, or \"NAME copy.EXT\", \"NAME copy 2.EXT\", … — the first that does not exist."
  (if (not (file-exists-p path)) path
    (let* ((dir (file-name-directory path)) (file (file-name-nondirectory path))
           (ext (file-name-extension file t)) (base (file-name-sans-extension file)) (n 1) new)
      (while (file-exists-p (setq new (expand-file-name (format "%s copy%s%s" base (if (= n 1) "" (format " %d" n)) ext) dir)))
        (setq n (1+ n)))
      new)))

(defun drgnx-explorer--check-inside (path)
  "Refuse PATH unless it is inside one of the Explorer's folders (`../x', `~/x' or /x leave them)."
  (unless (drgnx-explorer--root-of path)
    (user-error "%s is outside the Explorer's folders" (abbreviate-file-name path))))

(defun drgnx-explorer-new-file ()
  "Create a file in the folder here — a path like a/b/c.txt makes the folders; a trailing / makes a folder."
  (interactive)
  (let* ((dir (drgnx-explorer--folder-here))
         (name (string-trim (read-string (format "New file (end with / for a folder) in %s: "
                                                 (abbreviate-file-name (file-name-as-directory dir))))))
         (path (progn (when (string-empty-p name) (user-error "No name given")) (expand-file-name name dir))))
    (drgnx-explorer--check-inside path)
    (when (file-exists-p path) (user-error "%s already exists" (abbreviate-file-name path)))
    (if (directory-name-p name)
        (make-directory path t)
      (make-directory (file-name-directory path) t)
      (write-region "" nil path nil 'silent nil 'excl))
    (drgnx-explorer--show-folder dir)
    (drgnx-explorer-reveal (directory-file-name path))  ; a/b/c.txt: open a and b
    (drgnx-explorer--select (directory-file-name path))
    (unless (directory-name-p name) (drgnx-wb-show-in-editor (find-file-noselect path)))))

(defun drgnx-explorer-rename ()
  "Rename the file or folder here; buffers visiting it (or files inside it) follow."
  (interactive)
  (let* ((old (car (drgnx-explorer--targets)))
         (name (string-trim (read-string "Rename to: " (file-name-nondirectory old))))
         (new (expand-file-name name (file-name-directory old))))
    (when (string-empty-p name) (user-error "No name given"))
    (unless (equal new old)
      (drgnx-explorer--check-inside new)
      ;; A case-only rename on a case-insensitive disk: NEW "exists" — it is OLD (`rename-file' knows).
      (when (and (file-exists-p new)
                 (not (and (file-name-case-insensitive-p old) (string-equal-ignore-case old new))))
        (user-error "%s already exists" (abbreviate-file-name new)))
      (rename-file old new)
      (drgnx-explorer--move-buffers old new)
      (let ((prefix (file-name-as-directory old)))
        (let (moved)
          (maphash (lambda (k _) (when (or (equal k old) (string-prefix-p prefix k)) (push k moved))) drgnx-explorer--expanded)
          (dolist (k moved)
            (remhash k drgnx-explorer--expanded)
            (puthash (concat new (substring k (length old))) t drgnx-explorer--expanded))))
      (drgnx-explorer--show-folder (drgnx-explorer--parent new))
      (drgnx-explorer--select new))))

(defun drgnx-explorer--move-buffers (old new)
  "Buffers visiting OLD (or files inside the folder OLD) now visit the same files under NEW."
  (let ((prefix (file-name-as-directory old)))
    (dolist (b (buffer-list))
      (when-let* ((f (buffer-file-name b)))
        (when (or (equal f old) (string-prefix-p prefix f))
          (with-current-buffer b (set-visited-file-name (concat new (substring f (length old))) t t)))))))

(defun drgnx-explorer--describe (paths)
  "PATHS named in a question: up to three names, then how many more."
  (let ((names (mapcar (lambda (p) (file-name-nondirectory (directory-file-name p))) paths)))
    (if (cdr names)
        (format "%d items (%s%s)" (length names) (string-join (seq-take names 3) ", ")
                (if (> (length names) 3) ", …" ""))
      (car names))))

(defun drgnx-explorer--close-buffers (paths)
  "Kill the unmodified buffers visiting PATHS (or files inside them) after a delete; say so for a modified
one, which stays (its text is the only copy).  Never prompts."
  (dolist (b (buffer-list))
    (when-let* ((f (buffer-file-name b))
                ((seq-some (lambda (p) (or (equal f p) (string-prefix-p (file-name-as-directory p) f))) paths)))
      (if (buffer-modified-p b)
          (message "%s was deleted but has unsaved changes: its buffer is kept" (file-name-nondirectory f))
        (let ((kill-buffer-query-functions nil)) (kill-buffer b))))))

(defun drgnx-explorer--trash-cross-device-p (path)
  "Non-nil when the trash is on another device than the local PATH: Emacs would copy it across, in the
foreground."
  (and (not (file-remote-p path))
       (let ((trash (expand-file-name (or trash-directory "~/.local/share/Trash/files"))))
         (while (not (file-exists-p trash)) (setq trash (file-name-directory (directory-file-name trash))))
         (let ((a (file-attribute-device-number (file-attributes path 'integer)))
               (b (file-attribute-device-number (file-attributes trash 'integer))))
           (and a b (not (equal a b)))))))

(defun drgnx-explorer--gio-trash (path)
  "Move PATH to the trash with `gio trash' in the background; non-nil when it was started.  A failure is
reported with a message, the folder is shown again when it ends."
  (when (executable-find "gio")
    (condition-case nil
        (let ((dir (drgnx-explorer--parent path)))
          (make-process :name "drgnx-gio-trash" :command (list "gio" "trash" "--" path)
                        :connection-type 'pipe :noquery t
                        :sentinel (lambda (_proc event)
                                    (unless (string-prefix-p "finished" event)
                                      (message "Could not move %s to the trash: %s"
                                               (file-name-nondirectory path) (string-trim event)))
                                    (when (get-buffer drgnx-explorer-buffer-name)
                                      (ignore-errors (drgnx-explorer--show-folder dir)))))
          t)
      (error nil))))

(defun drgnx-explorer-delete (&optional permanently)
  "Move the file(s) here to the trash (with PERMANENTLY — a prefix argument — delete them)."
  (interactive "P")
  (let ((paths (drgnx-explorer--targets)))
    (when (if permanently
              (yes-or-no-p (format "Delete %s permanently? " (drgnx-explorer--describe paths)))
            (y-or-n-p (format "Move %s to the trash? " (drgnx-explorer--describe paths))))
      (let ((delete-by-moving-to-trash (not permanently)))     ; the trash unless asked otherwise — not Emacs' default (nil)
        (dolist (p paths)
          (unless (and (not permanently) (drgnx-explorer--trash-cross-device-p p) (drgnx-explorer--gio-trash p))
            (if (and (file-directory-p p) (not (file-symlink-p p)))   ; a link goes, never what it points to
                (delete-directory p t (not permanently))
              (delete-file p (not permanently))))))
      (drgnx-explorer--close-buffers paths)
      (setq drgnx-explorer--selection nil)
      (dolist (d (delete-dups (mapcar #'drgnx-explorer--parent paths))) (drgnx-explorer--show-folder d)))))

(defun drgnx-explorer-delete-permanently () "Delete the file(s) here permanently (no trash)."
       (interactive) (drgnx-explorer-delete t))

(defun drgnx-explorer-copy () "Copy the file(s) here, for Paste."
       (interactive)
       (setq drgnx-explorer--clipboard (list 'copy (drgnx-explorer--targets)))
       (message "Copied %s" (drgnx-explorer--describe (cadr drgnx-explorer--clipboard))))

(defun drgnx-explorer-cut () "Cut the file(s) here, for Paste (they move)."
       (interactive)
       (setq drgnx-explorer--clipboard (list 'cut (drgnx-explorer--targets)))
       (message "Cut %s" (drgnx-explorer--describe (cadr drgnx-explorer--clipboard))))

(defun drgnx-explorer-paste ()
  "Paste copied or cut files into the folder here; a name that exists gets \" copy\" (never overwritten)."
  (interactive)
  (pcase-let ((`(,op ,paths) (or drgnx-explorer--clipboard (user-error "Nothing copied or cut")))
              (dir (drgnx-explorer--folder-here)))
    (dolist (p paths)                                   ; every check before the first move
      (when (and (eq op 'cut) (string-prefix-p (file-name-as-directory p) (file-name-as-directory dir)))
        (user-error "Cannot move %s into itself" (file-name-nondirectory p))))
    (dolist (p paths)
      (unless (and (eq op 'cut) (equal (drgnx-explorer--parent p) dir))
        (let ((target (drgnx-explorer--free-name (expand-file-name (file-name-nondirectory (directory-file-name p)) dir))))
          (cond ((eq op 'cut) (rename-file p target) (drgnx-explorer--move-buffers p target))
                ((file-directory-p p) (copy-directory p target t t))
                (t (copy-file p target nil t))))))
    (when (eq op 'cut)
      (setq drgnx-explorer--clipboard nil)
      (dolist (d (delete-dups (mapcar #'drgnx-explorer--parent paths))) (drgnx-explorer--show-folder d)))
    (drgnx-explorer--show-folder dir)))

(defun drgnx-explorer-copy-path () "Copy the absolute path of the file here."
       (interactive)
       (kill-new (car (drgnx-explorer--targets)))
       (message "%s" (current-kill 0)))

(defun drgnx-explorer-copy-relative-path () "Copy the path of the file here, relative to its root."
       (interactive)
       (let ((p (car (drgnx-explorer--targets))))
         (kill-new (file-relative-name p (drgnx-explorer--root-of p)))
         (message "%s" (current-kill 0))))

(defun drgnx-explorer-reveal-externally () "Show the folder here in the system's file manager."
       (interactive)
       (let ((p (or (drgnx-explorer--node) (user-error "Nothing here"))))
         (if (eq system-type 'darwin)
             (call-process "open" nil 0 nil "-R" p)
           (call-process "xdg-open" nil 0 nil (drgnx-explorer--folder-here)))))

;;;; Mouse (the click model)

(defun drgnx-explorer--held-p ()
  "Non-nil while the button pressed in the Explorer is held.  Its release may never reach the
Explorer's handlers — it came with a modifier (M-<mouse-1>), in another window, or not at all (focus
lost: see `drgnx-explorer--focus-changed') — so the press counts only until another key sequence
is read.  File events and timers read none."
  (and drgnx-explorer--pressed
       (or (not (integerp drgnx-explorer--pressed)) (= drgnx-explorer--pressed num-input-keys))))

(defun drgnx-explorer-mouse-press (event)
  "Press: select the row under EVENT (and the Explorer); nothing else happens until release."
  (interactive "e")
  (setq drgnx-explorer--pressed num-input-keys)       ; the release is the next key sequence
  (let* ((posn (event-start event)) (w (posn-window posn)) (pos (posn-point posn)))
    (when (window-live-p w)
      (unless (eq w (selected-window)) (select-window w))
      (setq drgnx-explorer--focused-before (drgnx-explorer--node))   ; Ctrl/Shift-click start from it
      (when (integer-or-marker-p pos) (goto-char pos)))))


(defun drgnx-explorer-mouse-toggle (event)
  "Ctrl-click: add the row to the selection, or take it out."
  (interactive "e")
  (setq drgnx-explorer--pressed nil)
  (when-let* ((pos (posn-point (event-end event))) ((integer-or-marker-p pos)) (p (drgnx-explorer-node-at pos)))
    (unless (or drgnx-explorer--selection (null drgnx-explorer--focused-before) (equal drgnx-explorer--focused-before p))
      (setq drgnx-explorer--selection (list drgnx-explorer--focused-before)))
    (goto-char pos)
    (setq drgnx-explorer--anchor p)
    (drgnx-explorer--set-selection (if (member p drgnx-explorer--selection) (remove p drgnx-explorer--selection)
                                     (append drgnx-explorer--selection (list p))))))

(defun drgnx-explorer-mouse-range (event)
  "Shift-click: select every row from the last one to this one."
  (interactive "e")
  (setq drgnx-explorer--pressed nil)
  (when-let* ((pos (posn-point (event-end event))) ((integer-or-marker-p pos)))
    (unless (and drgnx-explorer--anchor (drgnx-explorer--row-pos drgnx-explorer--anchor))
      (setq drgnx-explorer--anchor drgnx-explorer--focused-before))
    (drgnx-explorer--select-range-to pos)
    (goto-char pos)))

(defun drgnx-explorer-mouse-click (event)
  "Release without moving: a folder toggles, a file opens keeping the Explorer focused."
  (interactive "e")
  (setq drgnx-explorer--pressed nil)
  (drgnx-explorer--clear-selection)
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
    ;; Printable keys that no profile binds here jump by name (type-to-navigate).
    (keymap-set map "<remap> <self-insert-command>" #'drgnx-explorer-type)
    (keymap-set map "C-<down-mouse-1>" #'drgnx-explorer-mouse-press)   ; (globally: the buffer menu)
    (keymap-set map "C-<mouse-1>" #'drgnx-explorer-mouse-toggle)
    (keymap-set map "S-<down-mouse-1>" #'drgnx-explorer-mouse-press)   ; (globally: the font menu)
    (keymap-set map "S-<mouse-1>" #'drgnx-explorer-mouse-range)
    map)
  "Keys of the Explorer; keyboard keys come from the key profiles.")

(define-derived-mode drgnx-explorer-mode nil "Explorer"
  "The drgnx Explorer (file tree)."
  (setq buffer-read-only t buffer-undo-list t truncate-lines t cursor-type nil mode-line-format nil)
  (setq-local hl-line-sticky-flag t)
  ;; A press on a partly visible row must not scroll: the row would move under the pointer.
  (setq-local scroll-margin 0 make-cursor-line-fully-visible nil)
  (hl-line-mode 1)
  (jit-lock-register #'drgnx-explorer--fontify)
  (add-hook 'kill-buffer-hook #'drgnx-explorer--unwatch-all nil t)
  (add-hook 'kill-buffer-hook #'drgnx-explorer--forget-find nil t))

(defun drgnx-explorer--focus-changed ()
  "Focus changed: read git status again (git may have run elsewhere).  Emacs lost focus: a press
is over — its release will not come here (Wayland)."
  (unless (seq-some #'frame-focus-state (frame-list)) (setq drgnx-explorer--pressed nil))
  (drgnx-explorer--git-refresh))

(defun drgnx-explorer-setup ()
  "Put the Explorer in the dock and let it follow the editor."
  (drgnx-wb-define-section 'explorer :slot 0 :buffer #'drgnx-explorer--buffer
                           :title (lambda () (if drgnx-explorer--find
                                                 (format " EXPLORER — %s" (plist-get drgnx-explorer--find :query))
                                               " EXPLORER"))
                           ;; Like VS Code: showing the Explorer reveals the active editor's file.
                           :on-show (lambda (_w) (drgnx-explorer--follow (window-buffer (drgnx-wb-editor-window)))))
  (drgnx-signal-subscribe 'editor-changed #'drgnx-explorer--follow)
  ;; A save changes git status; so does git itself (another window, a terminal): check on focus.
  (drgnx-signal-subscribe 'modified-changed (lambda (_) (drgnx-explorer--git-refresh)))
  (add-function :after after-focus-change-function #'drgnx-explorer--focus-changed '((name . drgnx-explorer)))
  (add-hook 'drgnx-git-changed-functions #'drgnx-explorer--git-changed))

(provide 'drgnx-explorer)
;;; drgnx-explorer.el ends here
