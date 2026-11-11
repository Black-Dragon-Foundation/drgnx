;;; drgnx-search-edit.el --- Edit Results: the Search view's results as an editable buffer -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Edit Results (docs/guide/replace.md, "Edit Results"): the Search view's matches as a buffer in the editor area, one
;; line per source line (the hub's `search/edit-doc'), under read-only file headers and line numbers.  Everything else
;; is a normal buffer: the user's own editing commands change the lines.  Saving collects the lines changed since the
;; buffer was made (each change marks its line; collecting walks the marked lines only) and writes them through the
;; Search view's write path (`search/edits' with `lines', then `search/apply'): every line is checked against its file
;; where it was, and one changed underneath is skipped and shown, the user's text kept.  A line typed into several
;; lines replaces the one; Delete Line deletes it on save.  The buffer stays after a save; Undo All Saves puts the
;; files back, newest save first.  Each line is fontified by its file's major mode, in a hidden buffer per mode, as
;; it shows (jit-lock).

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'jit-lock)
(require 'drgnx-setting)

(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-wb-show-in-editor "drgnx-wb")
(declare-function drgnx-replace--live-view "drgnx-replace")
(declare-function drgnx-replace--rows-p "drgnx-replace")
(declare-function drgnx-replace--text "drgnx-replace")
(declare-function drgnx-replace--open-paths "drgnx-replace")
(defvar drgnx-hub--events)
(defvar drgnx-replace-view)
(defvar drgnx-replace--root)

(drgnx-defsetting drgnx-search-edit-context 0
  "Lines of context Edit Results shows around each match line (0 to 3), editable too, dim."
  :type 'natnum :group 'drgnx :scope 'global :agents 'never :schema 'natnum)

(drgnx-defsetting drgnx-search-edit-max-lines 20000
  "The most lines Edit Results opens; a search with more asks to be narrowed."
  :type 'natnum :group 'drgnx :scope 'global :agents 'never :schema 'natnum)

(defface drgnx-search-edit-file '((t :inherit drgnx-ui-heading))
  "An Edit Results file header (its path and how many lines)." :group 'drgnx)

(defface drgnx-search-edit-number '((t :inherit line-number))
  "An Edit Results line's number in its file." :group 'drgnx)

(defface drgnx-search-edit-context '((t :inherit shadow))
  "An Edit Results context line (no match on it): dim." :group 'drgnx)

(defface drgnx-search-edit-edited '((t :inherit diff-changed))
  "An Edit Results line changed and not saved yet." :group 'drgnx)

(defface drgnx-search-edit-deleted '((t :inherit shadow :strike-through t))
  "An Edit Results line marked for deletion (Delete Line), or deleted by a save." :group 'drgnx)

(defface drgnx-search-edit-conflict '((t :inherit warning))
  "An Edit Results line whose file changed underneath: skipped, the user's text kept." :group 'drgnx)

(defface drgnx-search-edit-held '((t :inherit shadow))
  "An Edit Results line an agent holds: read-only." :group 'drgnx)

(cl-defstruct (drgnx-search-edit--line (:constructor drgnx-search-edit--line-make) (:copier nil))
  "One source line of an Edit Results buffer: ID (the hub's `l:K'), PATH, LINE (its first line in the file, from 1),
OLD (its text in the file as the buffer knows it: several lines once a save split it), EOL (a newline ends it in the
file), KIND (`match' or `context'), START and END (markers around its text), STATE (nil, `edited', `deleted', or
`gone' once a save deleted it), CONFLICT (why its last save skipped it), NOTE (text shown after it), OV (its overlay)."
  id path line old eol kind start end state conflict note ov)

(defvar-local drgnx-search-edit--lines nil "This buffer's lines, a vector in buffer order.")
(defvar-local drgnx-search-edit--marked nil "The lines changed since the buffer was made or saved: a hash, line → t.")
(defvar-local drgnx-search-edit--view nil "The Search view the buffer edits the results of.")
(defvar-local drgnx-search-edit--title nil "What the header line names: the search.")
(defvar-local drgnx-search-edit--status nil "The last save's report, on the header line.")
(defvar-local drgnx-search-edit--pending nil
  "Saves the hub has not ended: alist CHANGE → (LINES . SKIPPED), the lines sent and what the edit set skipped.")
(defvar-local drgnx-search-edit--saves nil
  "The written saves, newest first: alist CHANGE → the lines of its files as they were before it, each (LINE OLD LINE#
STATE).")
(defvar-local drgnx-search-edit--undoing nil "The saves Undo All Saves has still to put back, newest first.")

(defvar drgnx-search-edit--buffers nil "The live Edit Results buffers: the hub's change events go to their owner.")

;;;; Building

(defun drgnx-search-edit--header (path root count)
  "PATH's header (relative to ROOT, COUNT lines): read-only, nothing can be typed before it."
  (propertize (format "%s  (%d)\n" (file-relative-name path root) count)
              'face 'drgnx-search-edit-file 'read-only t 'front-sticky '(read-only)))

(defun drgnx-search-edit--insert (lines root)
  "Insert LINES (the hub's `search/edit-doc' lines, by file and line) under their files' headers (ROOT their folder);
the buffer's lines vector."
  (let* ((width (length (number-to-string (apply #'max 1 (mapcar (lambda (l) (plist-get l :line)) lines)))))
         (counts (make-hash-table :test #'equal)) (path nil) (out nil))
    (dolist (l lines) (cl-incf (gethash (plist-get l :path) counts 0)))
    (dolist (l lines)
      (unless (equal (plist-get l :path) path)
        (setq path (plist-get l :path))
        (insert (drgnx-search-edit--header path root (gethash path counts))))
      ;; the number: read-only, nothing typed before it; text typed after it is the line's
      (insert (propertize (format (format "%%%dd  " width) (plist-get l :line)) 'face 'drgnx-search-edit-number
                          'read-only t 'front-sticky '(read-only) 'rear-nonsticky t))
      (let ((start (point-marker)) (context (equal (plist-get l :kind) "context")))
        (insert (plist-get l :text))
        (when context (add-face-text-property start (point) 'drgnx-search-edit-context t))
        (insert (propertize "\n" 'read-only t))
        (let ((rec (drgnx-search-edit--line-make
                    :id (plist-get l :line_id) :path path :line (plist-get l :line) :old (plist-get l :text)
                    :eol (plist-get l :eol) :kind (if context 'context 'match)
                    ;; text typed at either end is the line's: the start stays before it, the end moves after it
                    :start start :end (copy-marker (1- (point)) t))))
          (when (plist-get l :held)
            (add-text-properties start (1- (point)) '(read-only "An agent holds this line" front-sticky (read-only)))
            (add-face-text-property start (1- (point)) 'drgnx-search-edit-held))
          (push rec out))))
    (vconcat (nreverse out))))

(defun drgnx-search-edit--buffer-name (query)
  "The tab of an Edit Results buffer of QUERY."
  (format "Search: %s" query))

(defun drgnx-search-edit--open (view query root answer)
  "Show ANSWER (`search/edit-doc') of VIEW's search for QUERY (in ROOT) as an Edit Results buffer, made again unless
one of this search has unsaved edits."
  (let ((buf (get-buffer-create (drgnx-search-edit--buffer-name query))))
    (with-current-buffer buf
      (unless (and (derived-mode-p 'drgnx-search-edit-mode) (drgnx-search-edit--unsaved-p))
        (drgnx-search-edit-mode)
        (setq drgnx-search-edit--view view drgnx-search-edit--title query)
        (let ((inhibit-read-only t) (inhibit-modification-hooks t))
          (erase-buffer)
          (setq drgnx-search-edit--lines (drgnx-search-edit--insert (plist-get answer :lines) root)))
        (setq drgnx-search-edit--marked (make-hash-table :test #'eq))
        (setq drgnx-search-edit--status
              (when-let* ((skipped (plist-get answer :skipped)))
                (format "%d file%s left out: %s" (length skipped) (if (cdr skipped) "s" "")
                        (plist-get (car skipped) :why))))
        (set-buffer-modified-p nil)
        (goto-char (point-min))
        (forward-line 1)))
    (if (fboundp 'drgnx-wb-show-in-editor) (drgnx-wb-show-in-editor buf t) (pop-to-buffer buf))
    buf))

(defun drgnx-search-edit--call (method params then)
  "METHOD with PARAMS to the hub on the subscribed connection; THEN with its result in this buffer.  An error is a
message (a callback: nothing to signal to)."
  (let ((buf (current-buffer)))
    (unless (fboundp 'drgnx-hub--call-on) (require 'drgnx-hub-client))
    (drgnx-hub--call-on drgnx-hub--events method params
                        (lambda (result error)
                          (if error
                              (message "Edit Results: %s" error)
                            (when (buffer-live-p buf) (with-current-buffer buf (funcall then result))))))))

(defun drgnx-search-edit-results ()
  "Open the Search view's results as an editable buffer: save writes the lines you change to their files."
  (interactive)
  (with-current-buffer (drgnx-replace--live-view)
    (unless (drgnx-replace--rows-p) (user-error "Edit Results needs a text search"))
    (let ((view drgnx-replace-view) (query (drgnx-replace--text 'find)) (root drgnx-replace--root))
      (when (string-empty-p query) (user-error "Nothing searched"))
      (drgnx-search-edit--call
       "search/edit-doc" (list :view view :context (min 3 drgnx-search-edit-context)
                               :max drgnx-search-edit-max-lines)
       (lambda (r)
         (if (plist-get r :over)
             (message "Edit Results: narrow the search (%d lines; at most %d)" (plist-get r :total)
                      drgnx-search-edit-max-lines)
           (drgnx-search-edit--open view query root r)))))))

;;;; Marks

(defun drgnx-search-edit--line-at (pos)
  "The line whose text holds POS (between its start and end markers), or nil: a binary search over the lines."
  (let ((v drgnx-search-edit--lines) (lo 0) (hi (1- (length drgnx-search-edit--lines))) found)
    (while (<= lo hi)
      (let* ((mid (/ (+ lo hi) 2)) (l (aref v mid)))
        (if (<= (drgnx-search-edit--line-start l) pos)
            (setq found l lo (1+ mid))
          (setq hi (1- mid)))))
    (and found (<= pos (drgnx-search-edit--line-end found)) found)))

(defun drgnx-search-edit--text (l)
  "L's text in the buffer now."
  (buffer-substring-no-properties (drgnx-search-edit--line-start l) (drgnx-search-edit--line-end l)))

(defun drgnx-search-edit--decorate (l)
  "Show L's state: its overlay's face (edited, deleted, conflict) and note."
  (let ((ov (or (drgnx-search-edit--line-ov l)
                (setf (drgnx-search-edit--line-ov l)
                      (make-overlay (drgnx-search-edit--line-start l) (drgnx-search-edit--line-end l) nil nil t)))))
    (move-overlay ov (drgnx-search-edit--line-start l) (drgnx-search-edit--line-end l))
    (overlay-put ov 'face (cond ((memq (drgnx-search-edit--line-state l) '(deleted gone)) 'drgnx-search-edit-deleted)
                                ((drgnx-search-edit--line-conflict l) 'drgnx-search-edit-conflict)
                                ((drgnx-search-edit--line-state l) 'drgnx-search-edit-edited)))
    (overlay-put ov 'after-string
                 (let ((note (or (and (drgnx-search-edit--line-conflict l)
                                      (format "changed since: your text kept (%s)" (drgnx-search-edit--line-conflict l)))
                                 (drgnx-search-edit--line-note l))))
                   (and note (propertize (concat "  " note) 'face 'drgnx-search-edit-conflict))))))

(defun drgnx-search-edit--mark (l state)
  "Mark L as STATE (`edited', `deleted'; nil: unmarked) and show it."
  (setf (drgnx-search-edit--line-state l) state)
  ;; modified: a save (`:w' too) has something to write, a deletion included (it changes no text)
  (if state (progn (puthash l t drgnx-search-edit--marked) (set-buffer-modified-p t))
    (remhash l drgnx-search-edit--marked))
  (drgnx-search-edit--decorate l))

(defun drgnx-search-edit--changed (beg _end _len)
  "`after-change-functions': the line holding BEG is edited (a deleted one stays deleted)."
  (when-let* ((l (drgnx-search-edit--line-at beg)))
    (unless (memq (drgnx-search-edit--line-state l) '(deleted gone))
      (drgnx-search-edit--mark l 'edited))))

(defun drgnx-search-edit--unsaved-p ()
  "Whether this buffer has marked lines not saved."
  (and drgnx-search-edit--marked (> (hash-table-count drgnx-search-edit--marked) 0)))

;;;; Fontification

(defvar drgnx-search-edit--mode-buffers (make-hash-table :test #'eq)
  "MODE → the hidden buffer that fontifies a line in MODE; emptied (the buffers killed) with the last Edit Results.")

(defun drgnx-search-edit--mode-of (path)
  "The major mode PATH's name gives (`auto-mode-alist'), or nil."
  (let ((m (assoc-default path auto-mode-alist #'string-match)))
    (when (consp m) (setq m (car m)))
    (when (and m (fboundp 'major-mode-remap)) (setq m (major-mode-remap m)))
    (and m (functionp m) (not (eq m 'fundamental-mode)) m)))

(defun drgnx-search-edit--mode-buffer (mode)
  "The hidden buffer that fontifies in MODE (its hooks not run)."
  (let ((b (gethash mode drgnx-search-edit--mode-buffers)))
    (unless (buffer-live-p b)
      (setq b (generate-new-buffer (format " *drgnx search edit %s*" mode)))
      (with-current-buffer b
        (delay-mode-hooks (funcall mode))
        (font-lock-set-defaults))
      (puthash mode b drgnx-search-edit--mode-buffers))
    b))

(defun drgnx-search-edit--faces (mode text)
  "TEXT's faces in MODE: a list of (FROM TO FACE), from 0."
  (with-current-buffer (drgnx-search-edit--mode-buffer mode)
    (let ((inhibit-read-only t) out)
      (erase-buffer)
      (insert text)
      (ignore-errors (font-lock-ensure))
      (let ((p (point-min)))
        (while (< p (point-max))
          (let ((next (next-single-property-change p 'face nil (point-max))) (face (get-text-property p 'face)))
            (when face (push (list (1- p) (1- next) face) out))
            (setq p next))))
      (nreverse out))))

(defun drgnx-search-edit--fontify (beg end)
  "jit-lock: the lines between BEG and END fontified by their files' modes; context lines dim."
  (let ((i (drgnx-search-edit--index-at-or-after beg)) (v drgnx-search-edit--lines))
    (while (and (< i (length v)) (< (drgnx-search-edit--line-start (aref v i)) end))
      (let* ((l (aref v i)) (s (drgnx-search-edit--line-start l)) (e (drgnx-search-edit--line-end l))
             (mode (drgnx-search-edit--mode-of (drgnx-search-edit--line-path l))))
        (remove-text-properties s e '(face nil))
        (when mode
          (pcase-dolist (`(,from ,to ,face) (drgnx-search-edit--faces mode (buffer-substring-no-properties s e)))
            (put-text-property (+ s from) (min e (+ s to)) 'face face)))
        (when (eq (drgnx-search-edit--line-kind l) 'context) (add-face-text-property s e 'drgnx-search-edit-context t)))
      (cl-incf i))))

(defun drgnx-search-edit--index-at-or-after (pos)
  "The index of the first line whose text ends at or after POS (the number of lines when none does)."
  (let ((v drgnx-search-edit--lines) (lo 0) (hi (1- (length drgnx-search-edit--lines))))
    (while (<= lo hi)
      (let ((mid (/ (+ lo hi) 2)))
        (if (>= (drgnx-search-edit--line-end (aref v mid)) pos) (setq hi (1- mid)) (setq lo (1+ mid)))))
    lo))

(defun drgnx-search-edit--killed ()
  "`kill-buffer-hook': this buffer is gone from the list; the last one takes the hidden mode buffers with it."
  (setq drgnx-search-edit--buffers (delq (current-buffer) drgnx-search-edit--buffers))
  (unless (cl-some #'buffer-live-p drgnx-search-edit--buffers)
    (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) drgnx-search-edit--mode-buffers)
    (clrhash drgnx-search-edit--mode-buffers)))

(defun drgnx-search-edit--kill-query ()
  "`kill-buffer-query-functions': with unsaved edits, killing from a command you ran asks; never from code."
  (or (not (drgnx-search-edit--unsaved-p))
      (not this-command)
      (yes-or-no-p (format "%s has unsaved edits; kill it anyway? " (buffer-name)))))

;;;; The mode

(defvar drgnx-search-edit-keys-map (make-sparse-keymap)
  "Edit Results' keys (Save, Abort, Delete Line, Take the File's Line), from the key profiles.")

(defvar drgnx-search-edit-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m drgnx-search-edit-keys-map)
    ;; every profile's save (`save-file' runs `save-buffer') saves the edited lines
    (define-key m [remap save-buffer] #'drgnx-search-edit-save)
    m)
  "Edit Results' keymap: the profiles' keys, and the profile's save.")

(defvar drgnx-search-edit-normal-state-map (make-sparse-keymap)
  "Edit Results' keys in Vim's normal state (`d d' Delete Line, `Z Q' Discard), from the key profiles.  Evil reads it
through the mode's normal-state auxiliary map (`drgnx-search-edit-evil-aux').")

;;;; Vim's states

(defvar evil-normal-state-map)
(declare-function evil-get-auxiliary-keymap "evil-core")
(declare-function evil-set-auxiliary-keymap "evil-core")

(defvar drgnx-search-edit--vim-own nil
  "Non-nil while `drgnx-search-edit--vim-key' runs evil's own command: the view's Vim prefixes stand aside.")

(defun drgnx-search-edit--vim-key ()
  "A key under one of a view's Vim prefixes that the profile does not bind (`d w' once `d d' is Delete Line, `Z Z'
once `Z Q' is Discard): what evil's normal state does with it.  A command of its own there (`Z Z') runs; else the
prefix's own (the `d' operator) runs and reads the rest of the keys as it would have: while it runs, the
prefixes stand aside (`drgnx-search-edit--vim-own'), so the operator looks its keys up and reads its motion in
evil's own maps."
  (interactive)
  (let* ((keys (this-command-keys-vector))
         (map (and (boundp 'evil-normal-state-map) evil-normal-state-map))
         (whole (and map (lookup-key map keys)))
         (first (and map (lookup-key map (vector (aref keys 0)))))
         (drgnx-search-edit--vim-own t))
    (cond ((commandp whole) (setq this-command whole) (call-interactively whole))
          ((commandp first)
           (setq unread-command-events (append (cdr (append keys nil)) unread-command-events)
                 this-command first)
           (call-interactively first))
          (t (undefined)))))

(defun drgnx-search-edit--vim-prefix (ev map)
  "MAP, a view's Vim prefix map under EV; while evil's own command runs (`drgnx-search-edit--vim-own'), what evil's
normal state binds EV to (the prefix map's parents would still make EV a prefix)."
  (if drgnx-search-edit--vim-own (lookup-key evil-normal-state-map (vector ev)) map))

(defun drgnx-search-edit--vim-prefixes (wrapper)
  "Fill WRAPPER, a view's auxiliary map whose parent is a profile-filled state map: under each prefix the profile
made there (`d' of `d d'), every other key is evil's own (`drgnx-search-edit--vim-key').  Made again from the
parent each time (an Edit Results buffer opens, the keys are applied again), so a prefix the profile no longer has
leaves nothing behind."
  (let ((parent (keymap-parent wrapper)) own)
    (map-keymap (lambda (ev _) (push ev own)) wrapper)
    (dolist (ev own) (define-key wrapper (vector ev) nil t))
    (when parent
      (map-keymap (lambda (ev def)
                    (when (keymapp def)
                      (let ((m (make-sparse-keymap)))
                        (set-keymap-parent m def)
                        (define-key m [t] #'drgnx-search-edit--vim-key)
                        (define-key wrapper (vector ev) `(menu-item "" ,m :filter ,(apply-partially #'drgnx-search-edit--vim-prefix ev))))))
                  parent))))

(defun drgnx-search-edit-evil-aux (mode-map state keys)
  "Make the profile-filled keymap KEYS the keys of MODE-MAP's buffers in evil's STATE: a wrapper with KEYS as parent
becomes MODE-MAP's auxiliary map for STATE, with evil's own keys under KEYS' prefixes
\(`drgnx-search-edit--vim-prefixes').
Needs evil loaded.  Returns a function that puts back what MODE-MAP had there (for the module's undo; nothing when
another took the place since)."
  (let* ((key (vector (intern (format "%s-state" state))))
         (prev (lookup-key mode-map key))
         (wrapper (make-sparse-keymap)))
    (set-keymap-parent wrapper keys)
    (evil-set-auxiliary-keymap mode-map state wrapper)
    (drgnx-search-edit--vim-prefixes wrapper)
    (lambda ()
      (when (eq (lookup-key mode-map key) wrapper)
        (if (keymapp prev) (define-key mode-map key prev) (define-key mode-map key nil t))))))

(defun drgnx-search-edit--refresh-vim-prefixes (&rest _)
  "Make Edit Results' normal-state prefixes again from the profile's keys (`drgnx-search-edit--vim-prefixes'), when
evil reads them; `drgnx-keys-after-apply-functions' and every new Edit Results buffer call it."
  (let ((aux (and (fboundp 'evil-get-auxiliary-keymap)
                  (evil-get-auxiliary-keymap drgnx-search-edit-mode-map 'normal))))
    (when (and aux (eq (keymap-parent aux) drgnx-search-edit-normal-state-map))
      (drgnx-search-edit--vim-prefixes aux))))

(defun drgnx-search-edit--write ()
  "`write-contents-functions': saving the buffer (`save-buffer', Vim's `:w', the profile's Save) saves the edited
lines, never a file named by the buffer; true, so nothing else writes."
  (drgnx-search-edit-save)
  t)

(define-derived-mode drgnx-search-edit-mode nil "Edit Results"
  "The Search view's results as an editable buffer: change the lines with any command; save writes them to their
files, each checked against its file; Delete Line deletes a line on save; Abort drops the edits."
  (setq-local truncate-lines t)
  ;; `:w' and every save reach the edited lines; the global save hooks (whitespace, formatters) never see them
  (setq-local write-contents-functions (list #'drgnx-search-edit--write))
  (setq-local before-save-hook nil after-save-hook nil)
  (setq-local require-final-newline nil)
  (drgnx-search-edit--refresh-vim-prefixes)
  (setq-local header-line-format '(:eval (drgnx-search-edit--header-line)))
  (font-lock-mode -1)
  (jit-lock-register #'drgnx-search-edit--fontify)
  (add-hook 'after-change-functions #'drgnx-search-edit--changed nil t)
  (add-hook 'kill-buffer-hook #'drgnx-search-edit--killed nil t)
  (add-hook 'kill-buffer-query-functions #'drgnx-search-edit--kill-query nil t)
  (cl-pushnew (current-buffer) drgnx-search-edit--buffers))

(defun drgnx-search-edit--header-line ()
  "The header line: the search, its lines, the unsaved count and the last save's report (cached values only)."
  (concat " " (propertize "Edit Results" 'face 'drgnx-ui-heading) " · " (or drgnx-search-edit--title "")
          (format " · %d lines" (length drgnx-search-edit--lines))
          (let ((n (if drgnx-search-edit--marked (hash-table-count drgnx-search-edit--marked) 0)))
            (if (> n 0) (format " · %d unsaved" n) ""))
          (if drgnx-search-edit--status (concat " · " drgnx-search-edit--status) "")))

;;;; Saving

(defun drgnx-search-edit--sorted-marked ()
  "The marked lines in buffer order."
  (sort (hash-table-keys drgnx-search-edit--marked)
        (lambda (a b) (< (drgnx-search-edit--line-start a) (drgnx-search-edit--line-start b)))))

(defun drgnx-search-edit--wire (l)
  "L as `search/edits' takes a line: deleted, or its text now as lines; nil when it is as its file has it."
  (let ((eol (if (drgnx-search-edit--line-eol l) t :false)))
    (if (eq (drgnx-search-edit--line-state l) 'deleted)
        (list :line_id (drgnx-search-edit--line-id l) :path (drgnx-search-edit--line-path l)
              :line (drgnx-search-edit--line-line l) :old (drgnx-search-edit--line-old l) :eol eol)
      (let ((new (drgnx-search-edit--text l)))
        (unless (equal new (drgnx-search-edit--line-old l))
          (list :line_id (drgnx-search-edit--line-id l) :path (drgnx-search-edit--line-path l)
                :line (drgnx-search-edit--line-line l) :old (drgnx-search-edit--line-old l)
                :new (vconcat (split-string new "\n")) :eol eol))))))

(defun drgnx-search-edit-save ()
  "Write the lines changed since the buffer was made or saved to their files (the Search view's write path); a line
whose file changed underneath is skipped and marked, your text kept."
  (interactive)
  (let (lines sent)
    (dolist (l (drgnx-search-edit--sorted-marked))
      (if-let* ((w (drgnx-search-edit--wire l)))
          (progn (push w lines) (push l sent))
        ;; typed back to what the file has
        (setf (drgnx-search-edit--line-conflict l) nil)
        (drgnx-search-edit--mark l nil)))
    (if (null lines)
        (progn (set-buffer-modified-p nil) (message "Edit Results: nothing to save"))
      (setq lines (nreverse lines) sent (nreverse sent))
      (drgnx-search-edit--call
       "search/edits" (list :view drgnx-search-edit--view :lines (vconcat lines))
       (lambda (r)
         (let ((skipped (append (plist-get r :skipped) nil)))
           (push (cons (plist-get r :change) (cons sent skipped)) drgnx-search-edit--pending)
           (drgnx-search-edit--call "search/apply" (list :view drgnx-search-edit--view :change (plist-get r :change)
                                                         :open (drgnx-replace--open-paths))
                                    #'ignore)))))))

(defun drgnx-search-edit--snapshot (paths)
  "The lines of PATHS as they are: (LINE OLD LINE# STATE) each, for Undo All Saves."
  (cl-loop for l across drgnx-search-edit--lines
           when (member (drgnx-search-edit--line-path l) paths)
           collect (list l (drgnx-search-edit--line-old l) (drgnx-search-edit--line-line l)
                         (drgnx-search-edit--line-state l))))

(defun drgnx-search-edit--lines-of (text)
  "How many file lines TEXT is."
  (1+ (cl-count ?\n text)))

(defun drgnx-search-edit--saved (change data)
  "The hub ended save CHANGE (DATA its `search-change'): the written lines take their new text, the lines after them
in their files move by the lines they added or removed, the skipped are marked with why."
  (pcase-let* ((`(,sent . ,before) (cdr (assoc change drgnx-search-edit--pending)))
               (skipped (append before (plist-get data :skipped) nil))
               (why (make-hash-table :test #'equal)))
    (setq drgnx-search-edit--pending (assoc-delete-all change drgnx-search-edit--pending))
    (dolist (s skipped) (when-let* ((id (plist-get s :id))) (puthash id (plist-get s :why) why)))
    (let* ((written (cl-remove-if (lambda (l) (gethash (drgnx-search-edit--line-id l) why)) sent))
           (paths (delete-dups (mapcar #'drgnx-search-edit--line-path written)))
           (snap (drgnx-search-edit--snapshot paths))
           (deltas (mapcar (lambda (l)
                             (list (drgnx-search-edit--line-path l) (drgnx-search-edit--line-line l)
                                   ;; a deleted last line (no newline after it) is emptied, not removed
                                   (- (cond ((not (eq (drgnx-search-edit--line-state l) 'deleted))
                                             (drgnx-search-edit--lines-of (drgnx-search-edit--text l)))
                                            ((drgnx-search-edit--line-eol l) 0)
                                            (t 1))
                                      (drgnx-search-edit--lines-of (drgnx-search-edit--line-old l)))))
                           written)))
      ;; the lines after a written one in its file move (from the lines as they were: every delta at once)
      (cl-loop for l across drgnx-search-edit--lines
               for n = (drgnx-search-edit--line-line l)
               do (setf (drgnx-search-edit--line-line l)
                        (+ n (cl-loop for (p at d) in deltas
                                      when (and (equal p (drgnx-search-edit--line-path l)) (< at n)) sum d))))
      (dolist (l written)
        (setf (drgnx-search-edit--line-conflict l) nil (drgnx-search-edit--line-note l) nil)
        (if (eq (drgnx-search-edit--line-state l) 'deleted)
            (let ((inhibit-read-only t))
              ;; gone first: the property change runs `after-change-functions', which leave a gone line alone
              (setf (drgnx-search-edit--line-state l) 'gone)
              (add-text-properties (drgnx-search-edit--line-start l) (drgnx-search-edit--line-end l)
                                   '(read-only "Deleted by a save" front-sticky (read-only)))
              (remhash l drgnx-search-edit--marked)
              (drgnx-search-edit--decorate l))
          (setf (drgnx-search-edit--line-old l) (drgnx-search-edit--text l))
          (drgnx-search-edit--mark l nil)))
      (dolist (l sent)
        (when-let* ((w (gethash (drgnx-search-edit--line-id l) why)))
          (setf (drgnx-search-edit--line-conflict l) w)
          (drgnx-search-edit--decorate l)))
      (when written (push (cons change snap) drgnx-search-edit--saves))
      (setq drgnx-search-edit--status
            (format "Saved %d line%s in %d file%s%s" (length written) (if (= (length written) 1) "" "s")
                    (length paths) (if (= (length paths) 1) "" "s")
                    (if skipped (format " · %d skipped" (length skipped)) "")))
      (unless (drgnx-search-edit--unsaved-p) (set-buffer-modified-p nil))
      (force-mode-line-update))))

(defun drgnx-search-edit--undone (undoes data)
  "The hub put save UNDOES back (DATA its `search-change'): its files' lines are as they were before it, but those of
a file it left alone; the lines whose text differs from the file's again are marked."
  (let ((left (append (plist-get data :left) nil)))
    (pcase-dolist (`(,l ,old ,n ,state) (cdr (assoc undoes drgnx-search-edit--saves)))
      (unless (member (drgnx-search-edit--line-path l) left)
        (setf (drgnx-search-edit--line-old l) old (drgnx-search-edit--line-line l) n)
        (when (eq (drgnx-search-edit--line-state l) 'gone)
          (let ((inhibit-read-only t))
            (remove-text-properties (drgnx-search-edit--line-start l) (drgnx-search-edit--line-end l)
                                    '(read-only nil front-sticky nil))))
        (drgnx-search-edit--mark l (cond ((eq (drgnx-search-edit--line-state l) 'gone) 'deleted)
                                         ((not (equal (drgnx-search-edit--text l) old)) 'edited)
                                         (t state)))))
    (setq drgnx-search-edit--saves (assoc-delete-all undoes drgnx-search-edit--saves))
    (setq drgnx-search-edit--status
          (format "Undone%s" (if left (format "; left alone (changed since): %s"
                                              (mapconcat #'file-name-nondirectory left ", "))
                               "")))
    (drgnx-search-edit--undo-next)
    (force-mode-line-update)))

(defun drgnx-search-edit-change (data)
  "The hub's `search-change' DATA, when a save or an undo of an Edit Results buffer ended: handled there, true; else
nil (another write's)."
  (let ((change (plist-get data :change)) (undoes (plist-get data :undoes)))
    (cl-loop for b in drgnx-search-edit--buffers
             thereis (and (buffer-live-p b)
                          (with-current-buffer b
                            (cond ((assoc change drgnx-search-edit--pending) (drgnx-search-edit--saved change data) t)
                                  ((and undoes (assoc undoes drgnx-search-edit--saves))
                                   (drgnx-search-edit--undone undoes data) t)))))))

(defun drgnx-search-edit--undo-next ()
  "Put back the next save Undo All Saves has left (`search/undo')."
  (when-let* ((change (pop drgnx-search-edit--undoing)))
    (drgnx-search-edit--call "search/undo" (list :view drgnx-search-edit--view :change change
                                                 :open (drgnx-replace--open-paths))
                             #'ignore)))

(defun drgnx-search-edit-undo-saves ()
  "Put back every save of this buffer, newest first (a file edited since is left alone and named).  The buffer's own
`undo' undoes typing, not files."
  (interactive)
  (unless drgnx-search-edit--saves (user-error "Nothing saved to undo"))
  (setq drgnx-search-edit--undoing (mapcar #'car drgnx-search-edit--saves))
  (drgnx-search-edit--undo-next))

;;;; Line commands

(defun drgnx-search-edit--here ()
  "The line at point, or a user error."
  (or (drgnx-search-edit--line-at (point))
      (save-excursion (end-of-line) (drgnx-search-edit--line-at (point)))
      (user-error "No result line here")))

(defun drgnx-search-edit-delete-line ()
  "Mark the line at point for deletion on save (struck and dim); again, unmark it."
  (interactive)
  (let ((l (drgnx-search-edit--here)))
    (pcase (drgnx-search-edit--line-state l)
      ('gone (user-error "Deleted by a save already"))
      ('deleted (drgnx-search-edit--mark l (unless (equal (drgnx-search-edit--text l) (drgnx-search-edit--line-old l))
                                             'edited)))
      (_ (drgnx-search-edit--mark l 'deleted)))
    (forward-line 1)))

(defun drgnx-search-edit--file-line (path n count)
  "COUNT lines of PATH from line N as they are now (its buffer's when it is open), joined by newlines; nil when the
file is shorter."
  (let ((b (find-buffer-visiting path)))
    (with-temp-buffer
      (if b (insert-buffer-substring b) (insert-file-contents path))
      (goto-char (point-min))
      (when (zerop (forward-line (1- n)))
        (let ((s (point)))
          (when (zerop (forward-line (1- count)))
            (buffer-substring-no-properties s (line-end-position))))))))

(defun drgnx-search-edit-refresh-line ()
  "Take the file's current text for the line at point: shown beside yours, which a save then writes over it."
  (interactive)
  (let* ((l (drgnx-search-edit--here))
         (now (drgnx-search-edit--file-line (drgnx-search-edit--line-path l) (drgnx-search-edit--line-line l)
                                            (drgnx-search-edit--lines-of (drgnx-search-edit--line-old l)))))
    (unless now (user-error "The file has no such line any more"))
    (setf (drgnx-search-edit--line-old l) now (drgnx-search-edit--line-conflict l) nil
          (drgnx-search-edit--line-note l) (format "file: %s" now))
    (drgnx-search-edit--mark l (unless (equal (drgnx-search-edit--text l) now) 'edited))))

(defun drgnx-search-edit-abort ()
  "Drop the unsaved edits and close Edit Results."
  (interactive)
  (clrhash drgnx-search-edit--marked)
  (set-buffer-modified-p nil)
  (kill-buffer (current-buffer)))

(provide 'drgnx-search-edit)
;;; drgnx-search-edit.el ends here
