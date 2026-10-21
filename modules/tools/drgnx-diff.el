;;; drgnx-diff.el --- Module tools/diff: the diff view — split or unified, files folded, open at the line -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The changes of the working tree, the index, a branch against its base or a commit, in one buffer: unified
;; (one column) or split (old beside new), switched in place.  Each file can be folded (TAB), all at once too;
;; a file of more than `drgnx-diff-fold-lines' lines starts folded and is drawn only when opened, so big diffs
;; show at once.  RET opens the file at the line.  git runs in the background; the view says "Loading…" until
;; it ends.  Review Branch and Pull Requests show their changes here.  See docs/guide/git.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'text-property-search)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-file)                   ; `drgnx-file-truename': git's names in an agent's worktree, with no file name handler

(declare-function drgnx-wb-editor-window "drgnx-wb")

(defvar drgnx-diff-default-layout 'unified "The layout a new diff view starts in: `unified' or `split'.")
(defvar drgnx-diff-fold-lines 2000 "A file whose hunks have more lines than this starts folded (drawn when opened).")

(defvar-local drgnx-diff-layout nil "This view's layout: `unified' or `split'.")
(defvar-local drgnx-diff--files nil "The parsed files (see `drgnx-diff-parse').")
(defvar-local drgnx-diff--folded nil "A vector: is file I folded?")
(defvar-local drgnx-diff--root nil "The repository the paths are relative to.")
(defvar-local drgnx-diff--width nil "Columns to lay out for (nil: the window's).")
(defvar-local drgnx-diff--proc nil "The git process still loading this view.")
(defvar-local drgnx-diff--source nil "What this view shows (see `drgnx-diff-show').")
(defvar-local drgnx-diff--landing nil "The file point lands on once loaded.")
(defvar-local drgnx-diff--laid-width nil "The width the split layout was last drawn for.")

;;;; Parsing

(defun drgnx-diff--path (s)
  "The path in a ---/+++ line's S: nil for /dev/null, without a/ or b/ and the tab git adds after a spaced name."
  (let ((s (string-remove-suffix "\t" s)))
    (cond ((equal s "/dev/null") nil)
          ((string-match "\\`[ab]/" s) (substring s 2))
          (t s))))

(defun drgnx-diff-parse (text)
  "TEXT (git diff output) as a list of files (:old :new :status :binary :hunks).  A hunk is (:old-start :old-len :new-start
:new-len :header :lines), its lines (CHAR . TEXT) with CHAR one of + - space \\."
  (let (files file hunks hunk lines (old-left 0) (new-left 0))
    (cl-flet ((end-hunk () (when hunk (push (plist-put hunk :lines (nreverse lines)) hunks) (setq hunk nil lines nil)))
              (end-file () (when file (push (plist-put file :hunks (nreverse hunks)) files) (setq file nil hunks nil))))
      (dolist (l (split-string text "\n"))
        (cond
         ;; inside a hunk: its counts say which lines are its own (a removed "-- x" reads as "--- x")
         ((and hunk (or (> old-left 0) (> new-left 0) (string-prefix-p "\\" l)) (not (string-empty-p l))
               (memq (aref l 0) '(?\s ?- ?+ ?\\)))
          (let ((c (aref l 0)))
            (pcase c (?\s (cl-decf old-left) (cl-decf new-left)) (?- (cl-decf old-left)) (?+ (cl-decf new-left)))
            (push (cons c (substring l 1)) lines)))
         ((string-prefix-p "diff --git " l)
          (end-hunk) (end-file)
          (let* ((s (substring l 11)) (p (and (string-prefix-p "a/" s) (substring s 2 (/ (1- (length s)) 2)))))
            (setq file (list :old p :new p :status 'modified :hunks nil))))
         ((null file))
         ((string-match "\\`@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@ ?\\(.*\\)" l)
          (end-hunk)
          (let ((n (lambda (i d) (if (match-string i l) (string-to-number (match-string i l)) d))))
            (setq hunk (list :old-start (funcall n 1 0) :old-len (funcall n 2 1) :new-start (funcall n 3 0)
                             :new-len (funcall n 4 1) :header (match-string 5 l) :lines nil)
                  old-left (plist-get hunk :old-len) new-left (plist-get hunk :new-len))))
         (hunk)                                             ; a stray line after a hunk's counts: not ours
         ((string-prefix-p "new file mode" l) (plist-put file :status 'added))
         ((string-prefix-p "deleted file mode" l) (plist-put file :status 'deleted))
         ((string-prefix-p "rename from " l) (plist-put file :old (substring l 12)) (plist-put file :status 'renamed))
         ((string-prefix-p "rename to " l) (plist-put file :new (substring l 10)) (plist-put file :status 'renamed))
         ((string-prefix-p "Binary files " l)       ; the status stays (deleted, added, ...); no ---/+++ lines name a missing side
          (plist-put file :binary t)
          (pcase (plist-get file :status)
            ('deleted (plist-put file :new nil))
            ('added (plist-put file :old nil))))
         ((string-prefix-p "--- " l) (plist-put file :old (drgnx-diff--path (substring l 4))))
         ((string-prefix-p "+++ " l) (plist-put file :new (drgnx-diff--path (substring l 4))))))
      (end-hunk) (end-file))
    (nreverse files)))

;;;; Rendering

(defun drgnx-diff--columns ()
  (or drgnx-diff--width (when-let* ((w (get-buffer-window))) (window-body-width w)) 160))

(defun drgnx-diff--size (file)
  "FILE's hunk lines."
  (apply #'+ (mapcar (lambda (h) (length (plist-get h :lines))) (plist-get file :hunks))))

(defun drgnx-diff--name (file)
  (let* ((old (plist-get file :old)) (new (plist-get file :new)) (bin (plist-get file :binary)))
    (pcase (plist-get file :status)
      ('renamed (format "%s → %s%s" old new (if bin " (binary)" "")))
      ('deleted (format "%s (deleted%s)" old (if bin ", binary" "")))
      ('added (format "%s (new%s)" new (if bin ", binary" "")))
      (_ (if bin (format "%s (binary)" (or new old)) (or new old))))))

(defun drgnx-diff--counts (file)
  (let ((a 0) (d 0))
    (dolist (h (plist-get file :hunks))
      (dolist (l (plist-get h :lines)) (pcase (car l) (?+ (cl-incf a)) (?- (cl-incf d)))))
    (cons a d)))

(defun drgnx-diff--row (text loc &optional face)
  "Insert TEXT and a newline, located at LOC, in FACE."
  (let ((b (point)))
    (insert text "\n")
    (put-text-property b (point) 'drgnx-diff-loc loc)
    (when face (put-text-property b (1- (point)) 'face face))))

(defun drgnx-diff--cell (n text width)
  "A split cell: line number N (or blank) and TEXT, exactly WIDTH columns (cut with …)."
  (let ((s (concat (if n (format "%4d " n) "     ") (string-replace "\r" "" (string-replace "\t" "    " text)))))
    (if (and (<= (length s) width) (= (string-bytes s) (length s)))   ; ASCII: columns are characters
        (concat s (make-string (- width (length s)) ?\s))
      (truncate-string-to-width s width nil ?\s "…"))))

(defun drgnx-diff--insert-unified (i path hunk)
  (let ((new (plist-get hunk :new-start)) (loc nil))
    (dolist (l (plist-get hunk :lines))
      (pcase (car l)
        (?\s (setq loc (list i path new)) (cl-incf new) (drgnx-diff--row (concat " " (cdr l)) loc))
        (?+ (setq loc (list i path new)) (cl-incf new) (drgnx-diff--row (concat "+" (cdr l)) loc 'diff-added))
        (?- (setq loc (list i path new)) (drgnx-diff--row (concat "-" (cdr l)) loc 'diff-removed))
        (?\\ (drgnx-diff--row (concat "\\" (cdr l)) loc 'shadow))))))

(defun drgnx-diff--insert-split (i path hunk)
  (let* ((w (max 20 (/ (- (drgnx-diff--columns) 3) 2)))
         (old (plist-get hunk :old-start)) (new (plist-get hunk :new-start)) (dels nil) (adds nil) (marks nil) (loc nil))
    (cl-flet ((flush ()
                (setq dels (nreverse dels) adds (nreverse adds))
                (while (or dels adds)
                  (let* ((d (pop dels)) (a (pop adds)) (b (point))
                         (left (drgnx-diff--cell (car d) (or (cdr d) "") w))   ; faces by the cells' lengths: wide characters are not one column
                         (right (if a (drgnx-diff--cell (car a) (cdr a) w) "")))
                    (setq loc (list i path (if a (car a) new)))
                    (insert left " │ " right "\n")
                    (put-text-property b (point) 'drgnx-diff-loc loc)
                    (when d (put-text-property b (+ b (length left)) 'face 'diff-removed))
                    (when a (put-text-property (+ b (length left) 3) (1- (point)) 'face 'diff-added))))
                (dolist (m (nreverse marks))               ; "\ No newline" notes come after the pairs they follow
                  (drgnx-diff--row (concat "\\" m) loc 'shadow))
                (setq marks nil)))
      (dolist (l (plist-get hunk :lines))
        (pcase (car l)
          (?- (push (cons old (cdr l)) dels) (cl-incf old))
          (?+ (push (cons new (cdr l)) adds) (cl-incf new))
          (?\s (flush)
               (setq loc (list i path new))
               (drgnx-diff--row (concat (drgnx-diff--cell old (cdr l) w) " │ " (drgnx-diff--cell new (cdr l) w)) loc)
               (cl-incf old) (cl-incf new))
          (?\\ (push (cdr l) marks))))
      (flush))))

(defun drgnx-diff--insert-file (i)
  "Insert file I: its header, then (unfolded) its hunks."
  (let* ((file (nth i drgnx-diff--files)) (b (point)) (path (plist-get file :new))
         (folded (aref drgnx-diff--folded i)) (counts (drgnx-diff--counts file))
         (first (car (plist-get file :hunks))))
    (drgnx-diff--row (format "%s %s  +%d −%d%s" (if folded "▸" "▾") (drgnx-diff--name file) (car counts) (cdr counts)
                             (if (and folded (plist-get file :hunks)) (format "  (%d lines folded — TAB)" (drgnx-diff--size file)) ""))
                     (list i path (if first (max 1 (plist-get first :new-start)) 1)) 'diff-file-header)
    (put-text-property b (point) 'drgnx-diff-header t)
    (unless folded
      (dolist (h (plist-get file :hunks))
        (drgnx-diff--row (format "@@ -%d,%d +%d,%d @@ %s" (plist-get h :old-start) (plist-get h :old-len)
                                 (plist-get h :new-start) (plist-get h :new-len) (or (plist-get h :header) ""))
                         (list i path (max 1 (plist-get h :new-start))) 'diff-hunk-header)
        (if (eq drgnx-diff-layout 'split) (drgnx-diff--insert-split i path h) (drgnx-diff--insert-unified i path h))))
    (put-text-property b (point) 'drgnx-diff-file i)))

(defun drgnx-diff--render ()
  "Draw the view from `drgnx-diff--files' in `drgnx-diff-layout'."
  (unless (and drgnx-diff--folded (= (length drgnx-diff--folded) (length drgnx-diff--files)))
    (setq drgnx-diff--folded (vconcat (mapcar (lambda (f) (> (drgnx-diff--size f) drgnx-diff-fold-lines)) drgnx-diff--files))))
  (let ((inhibit-read-only t) (inhibit-modification-hooks t))
    (erase-buffer)
    (if (null drgnx-diff--files) (insert "No changes.\n")
      (dotimes (i (length drgnx-diff--files)) (drgnx-diff--insert-file i)))))

;;;; Moving about

(defun drgnx-diff--goto (i line)
  "Point to the first row of file I at new LINE (else file I's header); nil when there is no file I."
  (let ((here (point)) (m nil))
    (goto-char (point-min))
    (setq m (text-property-search-forward 'drgnx-diff-loc nil
                                          (lambda (_ loc) (and loc (eql (nth 0 loc) i) (eql (nth 2 loc) line)))))
    (unless m
      (goto-char (point-min))
      (setq m (text-property-search-forward 'drgnx-diff-file i #'eql)))
    (if m (goto-char (prop-match-beginning m)) (goto-char here) nil)))

(defun drgnx-diff--rerender-keeping-place ()
  (let ((loc (get-text-property (point) 'drgnx-diff-loc)))
    (drgnx-diff--render)
    (if loc (drgnx-diff--goto (nth 0 loc) (nth 2 loc)) (goto-char (point-min)))))

(defun drgnx-diff--in-view ()
  "Signal unless this is a diff view (a command run from the palette elsewhere must never redraw that buffer)."
  (unless (derived-mode-p 'drgnx-diff-mode) (user-error "Not a diff view")))

(defun drgnx-diff-toggle-layout ()
  "Diff: Toggle Split/Unified — the same place, in the other layout."
  (interactive)
  (drgnx-diff--in-view)
  (setq drgnx-diff-layout (if (eq drgnx-diff-layout 'split) 'unified 'split))
  (drgnx-diff--rerender-keeping-place))

(defun drgnx-diff--fold-all (state)
  (drgnx-diff--in-view)
  (setq drgnx-diff--folded (make-vector (length drgnx-diff--files) state))
  (let ((i (nth 0 (get-text-property (point) 'drgnx-diff-loc))))
    (drgnx-diff--render)
    (unless (and i (drgnx-diff--goto i -1)) (goto-char (point-min)))))

(defun drgnx-diff-collapse-all () "Diff: Collapse All — file headers only." (interactive) (drgnx-diff--fold-all t))
(defun drgnx-diff-expand-all () "Diff: Expand All — every file drawn." (interactive) (drgnx-diff--fold-all nil))

(defun drgnx-diff-toggle-file ()
  "Diff: Toggle File — fold or open the file at point (only it is drawn again)."
  (interactive)
  (drgnx-diff--in-view)
  (let ((i (get-text-property (point) 'drgnx-diff-file)))
    (unless i (user-error "No file here"))
    (aset drgnx-diff--folded i (not (aref drgnx-diff--folded i)))
    (drgnx-diff--goto i -1)
    (let* ((inhibit-read-only t) (inhibit-modification-hooks t) (b (point))
           (e (or (next-single-property-change b 'drgnx-diff-file) (point-max))))
      (delete-region b e)
      (drgnx-diff--insert-file i)
      (goto-char b))))

(defun drgnx-diff-next-file ()
  "Diff: Next File."
  (interactive)
  (drgnx-diff--in-view)
  (let ((i (get-text-property (point) 'drgnx-diff-file)))
    (unless (drgnx-diff--goto (if i (1+ i) 0) -1) (user-error "No next file"))))

(defun drgnx-diff-prev-file ()
  "Diff: Previous File."
  (interactive)
  (drgnx-diff--in-view)
  (let ((i (get-text-property (point) 'drgnx-diff-file)))
    (unless (and i (> i 0) (drgnx-diff--goto (1- i) -1)) (user-error "No previous file"))))

(defun drgnx-diff--editor-window ()
  (let ((w (and (fboundp 'drgnx-wb-editor-window) (drgnx-wb-editor-window)))) (and (window-live-p w) w)))

(defun drgnx-diff-visit ()
  "Diff: Open File at Line — the file as it is now, at the line of point."
  (interactive)
  (drgnx-diff--in-view)
  (let ((loc (get-text-property (point) 'drgnx-diff-loc)))
    (unless loc (user-error "No file here"))
    (unless (nth 1 loc) (user-error "This file is deleted in this change"))
    ;; git's name, maybe a link an agent made in its worktree: resolved with no file name handler and opened by that
    ;; true name (`find-file' of the name as listed follows its links again, with handlers on: into Tramp)
    (let ((f (drgnx-file-truename (nth 1 loc) drgnx-diff--root)))
      (unless (and f (let ((file-name-handler-alist nil)) (file-exists-p f)))
        (user-error "%s is not in the working tree" (nth 1 loc)))
      (when-let* ((w (drgnx-diff--editor-window))) (select-window w))
      (find-file f)
      (goto-char (point-min))
      (forward-line (1- (max 1 (nth 2 loc)))))))

;;;; Loading

(defun drgnx-diff--git-line (root &rest args)
  "The first line git ARGS print in ROOT, or nil when git fails."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory root)))
      (when (eql 0 (apply #'call-process "git" nil '(t nil) nil args))
        (car (split-string (buffer-string) "\n" t))))))

(defun drgnx-diff-default-base (root)
  "The branch ROOT's work is measured against: origin/HEAD's target, else main, else master; nil when none is."
  (or (drgnx-diff--git-line root "symbolic-ref" "-q" "--short" "refs/remotes/origin/HEAD")
      (seq-find (lambda (b) (drgnx-diff--git-line root "rev-parse" "--verify" "-q" (concat "refs/heads/" b))) '("main" "master"))))

(defun drgnx-diff--toplevel (dir)
  (let ((top (drgnx-diff--git-line dir "rev-parse" "--show-toplevel")))
    (unless top (user-error "%s is not in a git repository" (abbreviate-file-name dir)))
    (file-name-as-directory top)))

(defun drgnx-diff--args (source)
  (let ((flags '("--no-color" "--no-ext-diff" "-M" "--src-prefix=a/" "--dst-prefix=b/")))   ; whatever diff.noprefix / mnemonicPrefix say
    (pcase source
      ('working (append '("diff") flags '("HEAD")))
      ('staged (append '("diff" "--cached") flags))
      (`(range ,base ,head) (append '("diff") flags (list (format "%s...%s" base head))))
      (`(commit ,sha) (append '("show" "--format=") flags (list sha)))
      (_ (error "drgnx-diff: unknown source %S" source)))))

(defun drgnx-diff--label (source root)
  (format "%s — %s"
          (pcase source
            ('working "working tree") ('staged "staged")
            (`(range ,base ,head) (format "%s...%s" base head))
            (`(commit ,sha) (substring sha 0 (min 10 (length sha)))))
          (file-name-nondirectory (directory-file-name root))))

(defun drgnx-diff--load ()
  "Run git for this view's source in the background; draw when it ends (a newer load replaces it)."
  (when (process-live-p drgnx-diff--proc) (delete-process drgnx-diff--proc))
  (let ((inhibit-read-only t)) (erase-buffer) (insert "Loading…\n"))
  (let* ((buf (current-buffer))
         (out (generate-new-buffer " *drgnx-diff out*" t)) (err (generate-new-buffer " *drgnx-diff err*" t))
         (default-directory drgnx-diff--root) p)
    (setq p (make-process
             :name "drgnx-diff" :buffer out :stderr err :noquery t :connection-type 'pipe
             :coding 'utf-8-unix
             :command (append '("git" "-c" "core.quotePath=false") (drgnx-diff--args drgnx-diff--source))
             :sentinel (drgnx-guard-wrap
                        (lambda (proc _event)
                          (unless (process-live-p proc)
                            (when (and (buffer-live-p buf) (eq proc (buffer-local-value 'drgnx-diff--proc buf)))
                              (with-current-buffer buf
                                (setq drgnx-diff--proc nil)
                                (if (eql (process-exit-status proc) 0)
                                    (progn (setq drgnx-diff--files (drgnx-diff-parse (with-current-buffer out (buffer-string)))
                                                 drgnx-diff--folded nil)
                                           (drgnx-diff--render)
                                           (goto-char (point-min))
                                           (when drgnx-diff--landing
                                             (let ((i (seq-position drgnx-diff--files drgnx-diff--landing
                                                                    (lambda (f path) (equal (plist-get f :new) path)))))
                                               (when i (drgnx-diff--goto i -1)))))
                                  (let ((inhibit-read-only t))
                                    (erase-buffer)
                                    (insert "git failed:\n" (with-current-buffer err (buffer-string)))))))
                            (when-let* ((ep (get-buffer-process err))) (delete-process ep))
                            (kill-buffer out) (kill-buffer err)))
                        "the diff's git")))
    (setq drgnx-diff--proc p)))

(defun drgnx-diff--revert (_ignore-auto _noconfirm)
  "`revert-buffer-function': run the diff of this view's source again."
  (when drgnx-diff--source (drgnx-diff--load)))

(defvar drgnx-diff-mode-map (make-sparse-keymap) "Keys come from the key profiles (diff-* commands).")

(define-derived-mode drgnx-diff-mode special-mode "Diff"
  "A diff view: split or unified, files folded and opened, RET opens the file at the line."
  (require 'diff-mode)                                   ; its faces
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'drgnx-diff--revert)
  (setq drgnx-diff-layout (or drgnx-diff-layout drgnx-diff-default-layout))
  (add-hook 'window-size-change-functions #'drgnx-diff--resized nil t))

(defun drgnx-diff--resized (w)
  "A split view is laid out for its window's width: drawn again when that changes."
  (with-current-buffer (window-buffer w)
    (when (and (eq drgnx-diff-layout 'split) (null drgnx-diff--width) (null drgnx-diff--proc) drgnx-diff--files
               (not (eql (window-body-width w) drgnx-diff--laid-width)))
      (setq drgnx-diff--laid-width (window-body-width w))
      (with-selected-window w (drgnx-diff--rerender-keeping-place)))))

(defun drgnx-diff-show (source &optional root file)
  "Show SOURCE's changes: `working' (against HEAD), `staged', (range BASE HEAD) (BASE...HEAD) or (commit SHA), in
the repository of ROOT (default: this one); point lands on FILE when given.  The view's buffer."
  (let* ((root (drgnx-diff--toplevel (or root default-directory)))
         (buf (get-buffer-create (format "*diff: %s*" (drgnx-diff--label source root)))))
    (with-current-buffer buf
      (unless (derived-mode-p 'drgnx-diff-mode) (drgnx-diff-mode))
      (setq default-directory root drgnx-diff--root root drgnx-diff--source source drgnx-diff--landing file)
      (drgnx-diff--load))
    (let ((w (drgnx-diff--editor-window)))
      (if w (progn (set-window-buffer w buf) (select-window w)) (pop-to-buffer buf)))
    buf))

(defun drgnx-diff-working () "Diff: Working Tree — every change since the last commit." (interactive) (drgnx-diff-show 'working))
(defun drgnx-diff-staged () "Diff: Staged — what the next commit holds." (interactive) (drgnx-diff-show 'staged))

(defun drgnx-diff-branch ()
  "Diff: Branch vs Base — this branch's changes since it left its base (origin/HEAD, main or master)."
  (interactive)
  (let* ((root (drgnx-diff--toplevel default-directory)) (base (drgnx-diff-default-base root)))
    (unless base (user-error "No base branch: set origin/HEAD or create main"))
    (drgnx-diff-show (list 'range base "HEAD") root)))

(defun drgnx-diff--teardown ()
  "Turned off: the diff views are closed (a view still loading stops its git)."
  (dolist (b (buffer-list))
    (when (provided-mode-derived-p (buffer-local-value 'major-mode b) 'drgnx-diff-mode)
      (when (process-live-p (buffer-local-value 'drgnx-diff--proc b)) (delete-process (buffer-local-value 'drgnx-diff--proc b)))
      (let ((kill-buffer-query-functions nil)) (kill-buffer b)))))

(drgnx-module-define 'tools/diff
                     :doc "The diff view: split or unified, files folded, open the file at the line; fast on big diffs."
                     :stage 'idle :teardown #'drgnx-diff--teardown
                     :setup
                     (lambda ()
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((diff-working "Diff: Working Tree" drgnx-diff-working "Every change since the last commit")
                                        (diff-staged "Diff: Staged" drgnx-diff-staged "What the next commit holds")
                                        (diff-branch "Diff: Branch vs Base" drgnx-diff-branch "This branch's changes since it left its base")
                                        (diff-toggle-layout "Diff: Toggle Split/Unified" drgnx-diff-toggle-layout "Old beside new, or one column")
                                        (diff-collapse-all "Diff: Collapse All" drgnx-diff-collapse-all "File headers only")
                                        (diff-expand-all "Diff: Expand All" drgnx-diff-expand-all "Every file drawn")
                                        (diff-toggle-file "Diff: Toggle File" drgnx-diff-toggle-file "Fold or open the file at point")
                                        (diff-next-file "Diff: Next File" drgnx-diff-next-file "The next file's header")
                                        (diff-prev-file "Diff: Previous File" drgnx-diff-prev-file "The previous file's header")
                                        (diff-visit "Diff: Open File at Line" drgnx-diff-visit "The file as it is now, at this line")))
                         (drgnx-command-define id :category "Source Control" :title title :command fn :doc doc
                                               :when (unless (memq id '(diff-working diff-staged diff-branch))
                                                       (lambda () (derived-mode-p 'drgnx-diff-mode)))))))

(provide 'drgnx-diff)
;;; drgnx-diff.el ends here
