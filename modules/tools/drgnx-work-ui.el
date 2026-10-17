;;; drgnx-work-ui.el --- Module tools/work: the Work tab (specs › plans › tasks › steps, TODOs, commits) and its graph -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The right dock's Work tab shows the work tracker's tree: each spec with the plans that came from
;; it (plans that name none are roots), each plan with its counts, branch and worktree, its tasks,
;; their steps, rulings and commits, and the board's TODOs.  TAB folds, RET opens the line's file at
;; its line (a commit: its diff), g scans again in another Emacs (this one never waits), f filters the
;; plans, m hides merged ones.  "Show Work as Graph" draws specs, plans and branches with svg.el:
;; every box opens what it shows, every colour comes from the theme.
;; See docs/guide/work.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'diff-mode)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-work)
(require 'drgnx-projects)
(require 'svg)
(require 'image)                        ; (setf image-property): not preloaded in every build (31.1 -nw)

(declare-function drgnx-wb-area-show "drgnx-area")
(declare-function drgnx-wb-define-tab "drgnx-area")
(declare-function drgnx-wb-place "drgnx-rules")
(declare-function drgnx-explorer-set-roots "drgnx-explorer")
(declare-function drgnx-explorer-roots "drgnx-explorer")
(declare-function drgnx-wb-sidebar-showing-p "drgnx-wb")
(declare-function drgnx-wb-toggle-sidebar "drgnx-wb")
(declare-function drgnx-agents-start "drgnx-agents")
(declare-function drgnx-agents-profile-names "drgnx-agents")
(declare-function drgnx-agents-ui-transcript "drgnx-agents-ui")

(defface drgnx-work-ui-spec '((t :inherit bold)) "A spec's title." :group 'drgnx)
(defface drgnx-work-ui-done '((t :inherit shadow)) "Done tasks, steps and TODOs; counts." :group 'drgnx)
(defface drgnx-work-ui-stale '((t :inherit warning)) "A task or commit no branch has any more (rebased, squashed)." :group 'drgnx)
(defface drgnx-work-ui-branch '((t :inherit font-lock-constant-face)) "A plan's branch." :group 'drgnx)

(defvar drgnx-work-ui--expanded (make-hash-table :test #'equal) "Node id → `open' or `closed' (specs start open).")
(defvar drgnx-work-ui-filter-text nil "Only plans whose title or path contain this (any case).")
(defvar drgnx-work-ui-hide-merged nil "Non-nil: merged plans are not shown.")
(defvar drgnx-work-ui--scan nil "The scan running in another Emacs (`drgnx-work-ui-refresh').")

(defvar drgnx-work-mode-map (let ((m (make-sparse-keymap))) (set-keymap-parent m special-mode-map) m))

(define-derived-mode drgnx-work-mode special-mode "Work"
  "The work tracker's tree (docs/guide/work.md)."
  (setq truncate-lines t buffer-read-only t))

;;;; The tree

(defun drgnx-work-ui--open-p (node)
  (let ((s (gethash (plist-get node :id) drgnx-work-ui--expanded)))
    (if s (eq s 'open) (eq (plist-get node :kind) 'spec))))

(defun drgnx-work-ui--plan-shown-p (plan)
  (and (not (and drgnx-work-ui-hide-merged (plist-get plan :merged)))
       (or (null drgnx-work-ui-filter-text) (string-empty-p drgnx-work-ui-filter-text)
           (let ((case-fold-search t))
             (string-match-p (regexp-quote drgnx-work-ui-filter-text)
                             (concat (plist-get plan :title) " " (plist-get plan :path)))))))

(defun drgnx-work-ui--kids (node)
  "NODE's children as the tree shows them (plans filtered)."
  (seq-filter (lambda (n) (or (not (eq (plist-get n :kind) 'plan)) (drgnx-work-ui--plan-shown-p n)))
              (drgnx-work-children (plist-get node :id))))

(defun drgnx-work-ui--roots ()
  (seq-filter (lambda (n)
                (if (eq (plist-get n :kind) 'plan) (drgnx-work-ui--plan-shown-p n)
                  ;; a spec stays when it has a plan shown, or nothing narrows the plans
                  (or (and (not drgnx-work-ui-hide-merged) (or (null drgnx-work-ui-filter-text) (string-empty-p drgnx-work-ui-filter-text)))
                      (drgnx-work-ui--kids n))))
              (drgnx-work-roots)))

(defun drgnx-work-ui--counts (c)
  "Steps, TODOs (those a plan has) and commits of counts C (`drgnx-work-counts')."
  (let* ((frac (lambda (k) (format "%d/%d" (car (plist-get c k)) (cdr (plist-get c k)))))
         (n (plist-get c :commits)))
    (string-join (delq nil (list (and (> (cdr (plist-get c :steps)) 0) (concat "steps " (funcall frac :steps)))
                                 (and (> (cdr (plist-get c :todos)) 0) (concat "todos " (funcall frac :todos)))
                                 (format "%d commit%s" n (if (= n 1) "" "s"))))
                 " · ")))

(defun drgnx-work-ui--line (node)
  "The text of NODE's line (without indentation and fold marker)."
  (let* ((done (equal (plist-get node :status) "done")) (title (or (plist-get node :title) ""))
         (title (if (eq (plist-get node :kind) 'task) (format "Task %s: %s" (plist-get node :ord) title) title)))
    (pcase (plist-get node :kind)
      ('spec (concat "◆ " (propertize title 'face 'drgnx-work-ui-spec)))
      ('plan (let ((c (drgnx-work-counts (plist-get node :id))))
               ;; the tasks first: a narrow dock cuts the end of long titles
               (concat "▣ " (format "%d/%d " (car (plist-get c :tasks)) (cdr (plist-get c :tasks))) title "  "
                       (propertize (drgnx-work-ui--counts c) 'face 'drgnx-work-ui-done)
                       (if (plist-get node :branch) (propertize (format "  [%s]" (plist-get node :branch)) 'face 'drgnx-work-ui-branch) "")
                       (if (plist-get node :merged) (propertize "  merged" 'face 'drgnx-work-ui-done) ""))))
      ('task (cond ((plist-get node :stale) (propertize (concat "⚠ " title "  (its commits are on no branch)") 'face 'drgnx-work-ui-stale))
                   (done (propertize (concat "☑ " title) 'face 'drgnx-work-ui-done))
                   (t (concat "☐ " title))))
      ('step (if done (propertize (concat "☑ " title) 'face 'drgnx-work-ui-done) (concat "☐ " title)))
      ('todo (if done (propertize (concat "✓ TODO " title) 'face 'drgnx-work-ui-done) (concat "○ TODO " title)))
      ('ruling (propertize (concat "§ " title) 'face 'drgnx-work-ui-done))
      ('commit (concat (if (plist-get node :gone) (propertize "⚠ " 'face 'drgnx-work-ui-stale) "● ") (substring (or (plist-get node :sha) "") 0 (min 7 (length (or (plist-get node :sha) "")))) " " title))
      (_ title))))

(defun drgnx-work-ui--insert (node depth)
  (let* ((foldable (or (memq (plist-get node :kind) '(spec plan task))
                       (and (eq (plist-get node :kind) 'todo) (drgnx-work-edges-to (plist-get node :id) 'implements))))
         (open (and foldable (drgnx-work-ui--open-p node)))
         (start (point)))
    (insert (make-string (* 2 depth) ?\s) (cond (open "▾ ") (foldable "▸ ") (t "  ")) (drgnx-work-ui--line node) "\n")
    (put-text-property start (point) 'drgnx-work-node node)
    (when open (dolist (k (drgnx-work-ui--kids node)) (drgnx-work-ui--insert k (1+ depth))))))

(defun drgnx-work-ui--node () (get-text-property (line-beginning-position) 'drgnx-work-node))

(defun drgnx-work-ui--render ()
  (let ((inhibit-read-only t) (id (plist-get (drgnx-work-ui--node) :id)) (line (line-number-at-pos)))
    (erase-buffer)
    (let ((roots (drgnx-work-ui--roots)))
      (if roots (dolist (r roots) (drgnx-work-ui--insert r 0))
        (insert (propertize "Nothing tracked yet — g scans the projects' specs, plans and ledgers.\n" 'face 'drgnx-work-ui-done))))
    (goto-char (point-min))
    (let ((m (and id (text-property-search-forward 'drgnx-work-node id (lambda (v n) (equal v (plist-get n :id)))))))
      (if m (goto-char (prop-match-beginning m)) (goto-char (point-min)) (forward-line (1- line))))))

(defun drgnx-work-ui-buffer ()
  "The Work tab's buffer, drawn from the tracker's database."
  (let ((b (get-buffer-create "*drgnx Work*")))
    (with-current-buffer b
      (unless (derived-mode-p 'drgnx-work-mode) (drgnx-work-mode))
      (drgnx-work-ui--render))
    b))

(defun drgnx-work-ui--redraw ()
  (when-let* ((b (get-buffer "*drgnx Work*")))
    (with-current-buffer b
      (let ((ws (get-buffer-window-list b nil t)) (pts nil))
        (dolist (w ws) (push (cons w (window-start w)) pts))
        (drgnx-work-ui--render)
        (pcase-dolist (`(,w . ,s) pts) (set-window-start w s t) (set-window-point w (point)))))))

(defun drgnx-work-ui-view ()
  "Show the Work tab in the right dock (scanning again in the background)."
  (interactive)
  (let ((b (drgnx-work-ui-buffer)))
    (if (fboundp 'drgnx-wb-area-show) (drgnx-wb-area-show 'right 'work b) (display-buffer b))
    (drgnx-work-ui-refresh)
    b))

(defun drgnx-work-ui-toggle ()
  "Fold or unfold the spec, plan or task on this line."
  (interactive)
  (when-let* ((n (drgnx-work-ui--node)) ((memq (plist-get n :kind) '(spec plan task todo))))
    (puthash (plist-get n :id) (if (drgnx-work-ui--open-p n) 'closed 'open) drgnx-work-ui--expanded)
    (drgnx-work-ui--render)))

(defun drgnx-work-ui-filter (text)
  "Show only the plans whose title or path contain TEXT (empty: all)."
  (interactive (list (read-string "Plans containing (empty: all): " drgnx-work-ui-filter-text)))
  (setq drgnx-work-ui-filter-text (if (string-empty-p text) nil text))
  (drgnx-work-ui--redraw))

(defun drgnx-work-ui-toggle-merged ()
  "Hide or show the merged plans."
  (interactive)
  (setq drgnx-work-ui-hide-merged (not drgnx-work-ui-hide-merged))
  (drgnx-work-ui--redraw)
  (message "Merged plans %s" (if drgnx-work-ui-hide-merged "hidden" "shown")))

;;;; Opening

(defun drgnx-work-ui--show-commit (node)
  (let* ((sha (plist-get node :sha)) (repo (or (plist-get node :repo) (plist-get node :path)))
         (_ (unless (file-directory-p repo) (user-error "The repository of %s is gone: %s" (substring sha 0 7) repo)))
         (b (get-buffer-create (format "*commit: %s*" (substring sha 0 7)))))
    (with-current-buffer b
      (let ((inhibit-read-only t) (default-directory (file-name-as-directory repo)))
        (erase-buffer)
        (unless (eql 0 (call-process "git" nil t nil "show" "--stat" "--patch" sha))
          (insert (format "\ngit cannot show %s in %s\n" sha repo)))
        (goto-char (point-min))
        (diff-mode)
        (setq buffer-read-only t)))
    (pop-to-buffer b)
    b))

(defun drgnx-work-ui-open ()
  "Open this line: the file at the line it came from, a commit as its diff."
  (interactive)
  (let ((n (or (drgnx-work-ui--node) (user-error "Nothing on this line"))))
    (if (eq (plist-get n :kind) 'commit) (drgnx-work-ui--show-commit n)
      (let ((path (or (plist-get n :path) (user-error "This line has no file"))))
        (pop-to-buffer (find-file-noselect path))
        (goto-char (point-min))
        (forward-line (1- (or (plist-get n :line) 1)))
        (current-buffer)))))

(defun drgnx-work-ui--plan-of (node)
  "The plan NODE belongs to (NODE itself when a plan)."
  (let ((n node))
    (while (and n (not (eq (plist-get n :kind) 'plan)))
      (setq n (and (plist-get n :parent) (drgnx-work-node (plist-get n :parent)))))
    n))

(defun drgnx-work-ui-open-worktree ()
  "Show the worktree of this line's plan in the Explorer."
  (interactive)
  (let* ((plan (or (drgnx-work-ui--plan-of (drgnx-work-ui--node)) (user-error "Not inside a plan")))
         (wt (or (plist-get plan :worktree) (user-error "This plan has no worktree"))))
    (drgnx-work-ui--show-worktree wt)))

(defun drgnx-work-ui--show-worktree (wt)
  "Add the worktree WT to the Explorer and show it (dired without the workbench)."
  (if (not (fboundp 'drgnx-explorer-set-roots)) (dired wt)
    (drgnx-explorer-set-roots (append (drgnx-explorer-roots) (unless (member wt (drgnx-explorer-roots)) (list wt))))
    (unless (drgnx-wb-sidebar-showing-p) (drgnx-wb-toggle-sidebar))))

(defun drgnx-work-ui-start-agent (profile)
  "Start an agent (PROFILE) on this line's task (a TODO, a plan): it works in the plan's worktree
and its commits are recorded for the task."
  (interactive (progn (require 'drgnx-agents)
                      (list (completing-read "Agent profile: " (drgnx-agents-profile-names) nil t))))
  (require 'drgnx-agents)
  (let* ((n (or (drgnx-work-ui--node) (user-error "Nothing on this line")))
         (task (pcase (plist-get n :kind)
                 ((or 'task 'todo 'plan) n)
                 ('step (drgnx-work-node (plist-get n :parent)))
                 (_ (user-error "Not a task, TODO or plan"))))
         (plan (drgnx-work-ui--plan-of task))
         (cwd (or (plist-get plan :worktree) (plist-get plan :repo) (file-name-directory (plist-get plan :path))))
         (s (drgnx-agents-start profile cwd (plist-get task :id))))
    (when (fboundp 'drgnx-agents-ui-transcript) (drgnx-agents-ui-transcript s))
    s))

;;;; Scanning again (in another Emacs)

(defun drgnx-work-ui-refresh ()
  "Scan the projects again in a batch Emacs — this one never waits — and redraw when it is done.
Returns the process."
  (interactive)
  (if (process-live-p drgnx-work-ui--scan) drgnx-work-ui--scan
    (let ((process-environment (append (list (concat "DRGNX_EMACS=" (expand-file-name invocation-name invocation-directory)))
                                       (and drgnx-work-git-notes (list "DRGNX_WORK_GIT_NOTES=1"))   ; the scan collects jobs
                                       process-environment))
          (default-directory drgnx-dir)                 ; the current one may be gone
          (out (get-buffer-create " *drgnx work scan*")))
      (with-current-buffer out (erase-buffer))          ; only this scan's output is reported
      (setq drgnx-work-ui--scan
            (make-process :name "drgnx-work-scan" :buffer out :noquery t
                          :connection-type 'pipe
                          :command (append (list (expand-file-name "bin/drgnx" drgnx-dir) "work" "scan"
                                                 "--board" (drgnx-projects-board-file))
                                           (drgnx-work-default-roots))
                          :sentinel (lambda (p _)
                                      (unless (process-live-p p)
                                        (if (eql 0 (process-exit-status p)) (drgnx-work-ui--redraw)
                                          (message "Work: the scan failed: %s"
                                                   (if (buffer-live-p (process-buffer p))
                                                       (with-current-buffer (process-buffer p) (string-trim (buffer-string)))
                                                     (format "exit %s" (process-exit-status p))))))))))))

(defun drgnx-work-ui--agent-turn (_s event)
  (when (eq event 'turn-end) (drgnx-work-ui--redraw)))

;;;; The graph (svg.el: no external program; every box a hot spot; colours from the theme's faces)

(defface drgnx-work-ui-graph-spec '((t :inherit (bold font-lock-keyword-face))) "A spec in the graph." :group 'drgnx)
(defface drgnx-work-ui-graph-plan '((t :inherit default)) "A plan in the graph." :group 'drgnx)
(defface drgnx-work-ui-graph-merged '((t :inherit shadow)) "A merged plan in the graph." :group 'drgnx)
(defface drgnx-work-ui-graph-branch '((t :inherit font-lock-constant-face)) "A branch in the graph." :group 'drgnx)
(defface drgnx-work-ui-graph-edge '((t :inherit shadow)) "The lines between boxes in the graph." :group 'drgnx)

(defconst drgnx-work-ui-graph-title-max 48 "Longer titles are cut (the full one shows on hover).")

(defun drgnx-work-ui--cut (s)
  (if (> (length s) drgnx-work-ui-graph-title-max) (concat (substring s 0 (1- drgnx-work-ui-graph-title-max)) "…") s))

(defun drgnx-work-ui--metrics ()
  "(CHAR-WIDTH . LINE-HEIGHT) in pixels of the default font (a sensible minimum without a frame)."
  (cons (max 7 (default-font-width)) (max 14 (default-font-height))))

(defun drgnx-work-ui-graph-layout ()
  "The graph's boxes and edges: (:boxes (BOX…) :edges ((FROM-BOX TO-BOX)…) :w W :h H).  A BOX is (:id :kind
:node :lines :tip :x :y :w :h :merged).  Columns: specs | plans | branches; a spec sits beside its plans."
  (let* ((m (drgnx-work-ui--metrics)) (cw (car m)) (lh (cdr m)) (pad (/ lh 2)) (vgap (/ lh 2)) (hgap (* 6 cw))
         (box (lambda (id kind node lines tip)
                (list :id id :kind kind :node node :lines lines :tip tip :merged (plist-get node :merged)
                      :w (+ (* 2 pad) (* cw (apply #'max (mapcar #'string-width lines))))
                      :h (+ (* 2 pad) (* lh (length lines))))))
         (plan-box (lambda (p)
                     (let* ((c (drgnx-work-counts (plist-get p :id))) (n (plist-get c :commits))
                            (counts (format "%d/%d tasks · %d commit%s" (car (plist-get c :tasks)) (cdr (plist-get c :tasks)) n (if (= n 1) "" "s"))))
                       (funcall box (plist-get p :id) 'plan p (list (drgnx-work-ui--cut (plist-get p :title)) counts)
                                (format "%s\n%s%s" (plist-get p :title) counts (if (plist-get p :merged) " · merged" ""))))))
         (y vgap) cols boxes edges)
    ;; rows first (x later, from each column's widest box)
    (dolist (r (drgnx-work-ui--roots))
      (let* ((spec (and (eq (plist-get r :kind) 'spec) r))
             (plans (if spec (seq-filter (lambda (n) (eq (plist-get n :kind) 'plan)) (drgnx-work-ui--kids r)) (list r)))
             (top y) (pbs nil))
        (dolist (p plans)
          (let ((pb (funcall plan-box p)))
            (setq pb (plist-put pb :y y) pb (plist-put pb :col 1))
            (push pb boxes) (push pb pbs)
            (when-let* ((name (plist-get p :branch)))
              (let* ((bid (or (car (car (drgnx-work-edges-from (plist-get p :id) 'on-branch))) (concat "branch " name)))
                     (bb (funcall box bid 'branch p (list name) (format "branch %s%s" name (if (plist-get p :worktree) (concat "\n" (plist-get p :worktree)) "")))))
                (setq bb (plist-put bb :y y) bb (plist-put bb :col 2))
                (push bb boxes)
                (push (list pb bb) edges)))
            (setq y (+ y (plist-get pb :h) vgap))))
        (when spec
          (let* ((sb (funcall box (plist-get spec :id) 'spec spec (list (drgnx-work-ui--cut (plist-get spec :title))) (plist-get spec :title)))
                 (h (plist-get sb :h)))
            ;; beside its plans, centred; a spec taller than its plans pushes the next rows down
            (setq sb (plist-put sb :y (max top (- (/ (+ top y (- vgap)) 2) (/ h 2)))) sb (plist-put sb :col 0))
            (setq y (max y (+ (plist-get sb :y) h vgap)))
            (push sb boxes)
            (dolist (pb (reverse pbs)) (push (list sb pb) edges))))))
    (dotimes (c 3) (push (apply #'max 0 (mapcar (lambda (b) (if (eql (plist-get b :col) c) (plist-get b :w) 0)) boxes)) cols))
    (setq cols (nreverse cols))
    (let ((xs (list hgap (+ hgap (nth 0 cols) hgap) (+ hgap (nth 0 cols) hgap (nth 1 cols) hgap))))
      (dolist (b boxes) (plist-put b :x (nth (plist-get b :col) xs)))
      (list :boxes (nreverse boxes) :edges (nreverse edges)
            :w (+ (nth 2 xs) (nth 2 cols) hgap) :h (+ y vgap)))))

(defvar color-name-rgb-alist)

(defun drgnx-work-ui--hex (c)
  "Colour C as #rrggbb, or nil: SVG knows CSS's colour names only, Emacs's are X11's (grey50, dark cyan)."
  (cond ((string-match-p "\\`#[0-9a-fA-F]\\{6\\}\\'" c) c)
        ((let ((v (if (display-graphic-p) (color-values c)
                    ;; without a display `color-values' rounds to terminal colours: the X11 table instead
                    (unless (boundp 'color-name-rgb-alist) (load "term/tty-colors" nil t))
                    (cdr (assoc (downcase (replace-regexp-in-string "[ \t]" "" c)) color-name-rgb-alist)))))
           (and v (apply #'format "#%02x%02x%02x" (mapcar (lambda (x) (/ x 257)) v)))))))

(defun drgnx-work-ui--colour (face attr)
  "FACE's ATTR colour as the theme sets it (#rrggbb), or currentColor (the image's foreground) when it has none."
  (let ((c (face-attribute face attr nil t)))
    (or (and (stringp c) (not (string-prefix-p "unspecified" c)) (drgnx-work-ui--hex c)) "currentColor")))

(defun drgnx-work-ui--box-face (b)
  (pcase (plist-get b :kind) ('spec 'drgnx-work-ui-graph-spec) ('branch 'drgnx-work-ui-graph-branch)
         (_ (if (plist-get b :merged) 'drgnx-work-ui-graph-merged 'drgnx-work-ui-graph-plan))))

(defconst drgnx-work-ui-graph-band 1000
  "The tallest image the graph is drawn in (pixels): Emacs refuses images over `max-image-size' (ten frame
heights, scaled on high-DPI screens), so a big graph is several images, one below the other.")

(defun drgnx-work-ui-graph-svg (layout)
  "The SVG text of LAYOUT (`drgnx-work-ui-graph-layout'), in the theme's colours."
  (with-temp-buffer (svg-print (drgnx-work-ui--graph-dom layout)) (buffer-string)))

(defun drgnx-work-ui-graph-bands (layout)
  "LAYOUT drawn as bands no taller than `drgnx-work-ui-graph-band': ((Y0 HEIGHT SVG-TEXT)…), each a
window (viewBox) on the same drawing, so lines cross from one band into the next."
  (let ((dom (drgnx-work-ui--graph-dom layout)) (w (plist-get layout :w)) (h (plist-get layout :h)))
    (cl-loop for y0 from 0 below h by drgnx-work-ui-graph-band
             collect (let* ((hb (min drgnx-work-ui-graph-band (- h y0)))
                            (band (svg-create w hb :viewBox (format "0 %d %d %d" y0 w hb))))
                       (dolist (c (dom-children dom)) (dom-append-child band c))
                       (list y0 hb (with-temp-buffer (svg-print band) (buffer-string)))))))

(defun drgnx-work-ui--graph-dom (layout)
  "The SVG of LAYOUT as a DOM, in the theme's colours."
  (let* ((m (drgnx-work-ui--metrics)) (lh (cdr m)) (pad (/ lh 2))
         (svg (svg-create (plist-get layout :w) (plist-get layout :h)))
         (bg (let ((c (drgnx-work-ui--colour 'default :background))) (if (equal c "currentColor") "none" c)))
         (edge (drgnx-work-ui--colour 'drgnx-work-ui-graph-edge :foreground)))
    (pcase-dolist (`(,from ,to) (plist-get layout :edges))
      (let* ((a from) (b to)
             (x1 (+ (plist-get a :x) (plist-get a :w))) (y1 (+ (plist-get a :y) (/ (plist-get a :h) 2)))
             (x2 (plist-get b :x)) (y2 (+ (plist-get b :y) (/ (plist-get b :h) 2))) (mx (/ (+ x1 x2) 2)))
        (svg-node svg 'path :d (format "M%d,%d C%d,%d %d,%d %d,%d" x1 y1 mx y1 mx y2 x2 y2)
                  :fill "none" :stroke edge :stroke-width 1.5)))
    (dolist (b (plist-get layout :boxes))
      (let* ((face (drgnx-work-ui--box-face b)) (fg (drgnx-work-ui--colour face :foreground)))
        (svg-rectangle svg (plist-get b :x) (plist-get b :y) (plist-get b :w) (plist-get b :h)
                       :rx (/ pad 2) :fill bg :stroke fg :stroke-width (if (eq (plist-get b :kind) 'spec) 2 1)
                       :stroke-dasharray (if (plist-get b :merged) "4,3" "none"))
        (seq-do-indexed (lambda (line i)
                          (svg-text svg line :x (+ (plist-get b :x) pad) :y (+ (plist-get b :y) pad (* lh i) (round (* lh 0.8)))
                                    :fill (if (> i 0) (drgnx-work-ui--colour 'drgnx-work-ui-graph-edge :foreground) fg)
                                    :font-size (round (* lh 0.75))
                                    :font-weight (if (eq (plist-get b :kind) 'spec) "bold" "normal")))
                        (plist-get b :lines))))
    svg))

(defun drgnx-work-ui--graph-open (b)
  "Open what box B shows: a spec's or plan's file, a branch's worktree.  Says why when it cannot."
  (let ((node (plist-get b :node)))
    (pcase (plist-get b :kind)
      ('branch (if-let* ((wt (plist-get node :worktree)) ((file-directory-p wt)))
                   (progn (drgnx-work-ui--show-worktree wt) wt)
                 (message "Work: branch %s has no worktree" (car (plist-get b :lines)))))
      (_ (let ((path (plist-get node :path)))
           (if (and path (file-readable-p path)) (pop-to-buffer (find-file-noselect path))
             (message "Work: %s is gone" (or path (plist-get node :title)))))))))

(defvar drgnx-work-ui--graph-spots nil "Alist hot-spot id → the box it is (the graph shown last).")

(defun drgnx-work-ui-graph-click (event)
  "Open what the box under the click EVENT shows (its hot spot is in the click's position)."
  (interactive "e")
  ;; from the clicked window (the press selects nothing): what opens is placed beside the graph
  (let ((w (posn-window (event-start event)))) (when (window-live-p w) (select-window w)))
  (if-let* ((box (alist-get (posn-area (event-start event)) drgnx-work-ui--graph-spots)))
      (drgnx-work-ui--graph-open box)
    (message "Work: click a box to open it")))

(defun drgnx-work-ui-graph ()
  "Show specs, plans and branches as a graph (svg.el): click a box to open it, g to draw it again.
Returns the buffer."
  (interactive)
  (unless (and (display-images-p) (image-type-available-p 'svg))
    (user-error "Show Work as Graph needs a graphical frame of an Emacs with SVG support (librsvg); the Work tab shows the same tree"))
  (let* ((layout (drgnx-work-ui-graph-layout)) (map (make-sparse-keymap)) (spots nil) (i 0)
         (lh (cdr (drgnx-work-ui--metrics)))
         (b (get-buffer-create "*work graph*")))
    (dolist (box (plist-get layout :boxes))
      (let ((area (intern (format "drgnx-work-box-%d" (cl-incf i)))))
        (push (cons area box) spots)
        ;; a click comes as mouse-1 with the hot spot in its position, or prefixed by it: both open
        (define-key map (vector area 'mouse-1) #'drgnx-work-ui-graph-click)
        (define-key map (vector area 'double-mouse-1) #'ignore)))
    (setq spots (nreverse spots))
    (define-key map [mouse-1] #'drgnx-work-ui-graph-click)
    (define-key map [down-mouse-1] #'ignore)            ; a press neither moves point nor selects
    (define-key map [double-mouse-1] #'ignore)          ; a double click opens once (its first click did)
    (setq drgnx-work-ui--graph-spots spots)
    (with-current-buffer b
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (setq-local cursor-type nil                      ; no cursor box drawn round the image
                    truncate-lines t                     ; a wide graph scrolls sideways
                    revert-buffer-function (lambda (&rest _) (drgnx-work-ui-graph)))
        (pcase-dolist (`(,y0 ,hb ,svg) (drgnx-work-ui-graph-bands layout))
          (let ((img (create-image svg 'svg t :scale 1.0 :foreground (drgnx-work-ui--colour 'default :foreground))))
            ;; each band's hot spots in its own pixels (never scaled): the boxes it shows, cut to it — a box
            ;; across two bands is one hot spot in each.  Set after `create-image', which would measure the
            ;; image for them (impossible without a window system).
            (setf (image-property img :map)
                  (delq nil (mapcar (lambda (s)
                                      (let* ((box (cdr s)) (top (max y0 (plist-get box :y)))
                                             (bot (min (+ y0 hb) (+ (plist-get box :y) (plist-get box :h)))))
                                        (when (< top bot)
                                          (list (cons 'rect (cons (cons (plist-get box :x) (- top y0))
                                                                  (cons (+ (plist-get box :x) (plist-get box :w)) (- bot y0))))
                                                (car s) (list 'help-echo (plist-get box :tip) 'pointer 'hand)))))
                                    spots)))
            ;; in slices — lines of rows, columns across: it scrolls like text both ways (hot spots follow)
            (insert-sliced-image img nil nil (max 1 (/ hb (* 2 lh))) (max 1 (ceiling (plist-get layout :w) 400)))))
        (put-text-property (point-min) (point-max) 'keymap map)
        (put-text-property (point-min) (point-max) 'pointer 'hand)
        (goto-char (point-min))))
    (pop-to-buffer b)
    b))

;;;; The module

(drgnx-module-define 'tools/work
                     :doc "Work: specs › plans › tasks › TODOs › commits in the right dock's Work tab; the graph."
                     :stage 'startup :requires '(core/workbench)
                     :setup
                     (lambda ()
                       (add-hook 'drgnx-agents-task-functions #'drgnx-work-ui--agent-turn 90)
                       (when (fboundp 'drgnx-wb-define-tab)
                         (drgnx-wb-define-tab 'right 'work :title "Work")
                         ;; …and in the bottom panel, for the Agent layout (the same buffer)
                         (drgnx-wb-define-tab 'panel 'work :title "Work" :placeholder #'drgnx-work-ui-buffer))
                       (when (fboundp 'drgnx-wb-place)
                         (drgnx-wb-place 'drgnx-work-mode 'right :tab 'work)
                         (drgnx-wb-place "\\`\\*\\(commit: \\|work graph\\*\\)" 'editor))
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((work-view "Show Work" drgnx-work-ui-view "Specs, plans, tasks, TODOs and commits, in the right dock")
                                        (work-graph "Show Work as Graph" drgnx-work-ui-graph "Specs, plans and branches as a graph; click a box to open it")
                                        (work-start-agent "Start Agent on Task…" drgnx-work-ui-start-agent "An agent on this task; its commits are recorded for it")
                                        (work-open-worktree "Open Plan's Worktree" drgnx-work-ui-open-worktree "The worktree of this plan, in the Explorer")))
                         (drgnx-command-define id :category "Work" :title title :command fn :doc doc))
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((work-open "Open" drgnx-work-ui-open "The file at this line, or the commit's diff")
                                        (work-toggle "Fold" drgnx-work-ui-toggle "Fold or unfold this spec, plan or task")
                                        (work-refresh "Scan Again" drgnx-work-ui-refresh "Read the projects again (in the background)")
                                        (work-filter "Filter Plans…" drgnx-work-ui-filter "Only the plans whose title or path contain a text")
                                        (work-hide-merged "Hide Merged Plans" drgnx-work-ui-toggle-merged "Hide or show the plans already merged")))
                         (drgnx-command-define id :category "Work" :title title :command fn :doc doc :map 'drgnx-work-mode-map))))

(provide 'drgnx-work-ui)
;;; drgnx-work-ui.el ends here
