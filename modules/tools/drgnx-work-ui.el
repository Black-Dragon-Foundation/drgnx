;;; drgnx-work-ui.el --- Module tools/work: the Work tab (specs › plans › tasks › steps, TODOs, commits) and its graph -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The right dock's Work tab shows the work tracker's tree: each spec with the plans that came from
;; it (plans that name none are roots), each plan with its counts, branch and worktree, its tasks,
;; their steps, rulings and commits, and the board's TODOs.  TAB folds, RET opens the line's file at
;; its line (a commit: its diff), g scans again in another Emacs (this one never waits), f filters the
;; plans, m hides merged ones.  "Work: Show as Graph" draws specs, plans and branches with Graphviz.
;; See docs/work.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'diff-mode)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-work)
(require 'drgnx-projects)

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
(defface drgnx-work-ui-stale '((t :inherit warning)) "A task whose recorded commits git no longer has." :group 'drgnx)
(defface drgnx-work-ui-branch '((t :inherit font-lock-constant-face)) "A plan's branch." :group 'drgnx)

(defvar drgnx-work-ui--expanded (make-hash-table :test #'equal) "Node id → `open' or `closed' (specs start open).")
(defvar drgnx-work-ui-filter-text nil "Only plans whose title or path contain this (any case).")
(defvar drgnx-work-ui-hide-merged nil "Non-nil: merged plans are not shown.")
(defvar drgnx-work-ui--scan nil "The scan running in another Emacs (`drgnx-work-ui-refresh').")

(defvar drgnx-work-mode-map (let ((m (make-sparse-keymap))) (set-keymap-parent m special-mode-map) m))

(define-derived-mode drgnx-work-mode special-mode "Work"
  "The work tracker's tree (docs/work.md)."
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
      ('task (cond ((plist-get node :stale) (propertize (concat "⚠ " title "  (its commits are gone)") 'face 'drgnx-work-ui-stale))
                   (done (propertize (concat "☑ " title) 'face 'drgnx-work-ui-done))
                   (t (concat "☐ " title))))
      ('step (if done (propertize (concat "☑ " title) 'face 'drgnx-work-ui-done) (concat "☐ " title)))
      ('todo (if done (propertize (concat "✓ TODO " title) 'face 'drgnx-work-ui-done) (concat "○ TODO " title)))
      ('ruling (propertize (concat "§ " title) 'face 'drgnx-work-ui-done))
      ('commit (concat "● " (substring (or (plist-get node :sha) "") 0 (min 7 (length (or (plist-get node :sha) "")))) " " title))
      (_ title))))

(defun drgnx-work-ui--insert (node depth)
  (let* ((foldable (memq (plist-get node :kind) '(spec plan task)))
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
  (when-let* ((n (drgnx-work-ui--node)) ((memq (plist-get n :kind) '(spec plan task))))
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
    (if (not (fboundp 'drgnx-explorer-set-roots)) (dired wt)
      (drgnx-explorer-set-roots (append (drgnx-explorer-roots) (unless (member wt (drgnx-explorer-roots)) (list wt))))
      (unless (drgnx-wb-sidebar-showing-p) (drgnx-wb-toggle-sidebar)))))

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
    (let ((process-environment (cons (concat "DRGNX_EMACS=" (expand-file-name invocation-name invocation-directory)) process-environment)))
      (setq drgnx-work-ui--scan
            (make-process :name "drgnx-work-scan" :buffer (get-buffer-create " *drgnx work scan*") :noquery t
                          :connection-type 'pipe
                          :command (append (list (expand-file-name "bin/drgnx" drgnx-dir) "work" "scan"
                                                 "--board" (drgnx-projects-board-file))
                                           (drgnx-work-default-roots))
                          :sentinel (lambda (p _)
                                      (unless (process-live-p p)
                                        (if (eql 0 (process-exit-status p)) (drgnx-work-ui--redraw)
                                          (message "Work: the scan failed: %s"
                                                   (with-current-buffer (process-buffer p) (string-trim (buffer-string))))))))))))

(defun drgnx-work-ui--agent-turn (_s event)
  (when (eq event 'turn-end) (drgnx-work-ui--redraw)))

;;;; The graph

(defun drgnx-work-ui--q (s) (concat "\"" (replace-regexp-in-string "[\"\\]" "\\\\\\&" (or s "")) "\""))

(defun drgnx-work-ui-dot ()
  "The tracker as Graphviz DOT: specs, the plans shown, their branches."
  (let ((out (list "  rankdir=LR; node [shape=box, fontname=\"sans\"];" "digraph work {")))   ; pushed: newest first
    (dolist (r (drgnx-work-ui--roots))
      (let ((plans (if (eq (plist-get r :kind) 'plan) (list r)
                     (push (format "  %s [label=%s, shape=note];" (drgnx-work-ui--q (plist-get r :id)) (drgnx-work-ui--q (plist-get r :title))) out)
                     (seq-filter (lambda (n) (eq (plist-get n :kind) 'plan)) (drgnx-work-ui--kids r)))))
        (dolist (p plans)
          (let* ((c (drgnx-work-counts (plist-get p :id))) (n (plist-get c :commits)))
            (push (format "  %s [label=%s%s];" (drgnx-work-ui--q (plist-get p :id))
                          (concat "\"" (replace-regexp-in-string "[\"\\]" "\\\\\\&" (plist-get p :title))
                                  (format "\\n%d/%d tasks · %d commit%s" (car (plist-get c :tasks)) (cdr (plist-get c :tasks)) n (if (= n 1) "" "s"))
                                  "\"")
                          (if (plist-get p :merged) ", style=dashed" ""))
                  out)
            (unless (eq r p) (push (format "  %s -> %s;" (drgnx-work-ui--q (plist-get r :id)) (drgnx-work-ui--q (plist-get p :id))) out))
            (when-let* ((b (plist-get p :branch)))
              (push (format "  %s [shape=ellipse];" (drgnx-work-ui--q (concat "branch " b))) out)
              (push (format "  %s -> %s;" (drgnx-work-ui--q (plist-get p :id)) (drgnx-work-ui--q (concat "branch " b))) out))))))
    (string-join (nreverse (cons "}" out)) "\n")))

(defun drgnx-work-ui-graph ()
  "Show the tracker as a graph (Graphviz; without it, the DOT text).  Returns the buffer."
  (interactive)
  (let ((dot (drgnx-work-ui-dot)) (b (get-buffer-create "*work graph*")) (dot-bin (executable-find "dot")))
    (with-current-buffer b
      (let ((inhibit-read-only t))
        (erase-buffer)
        (fundamental-mode)
        (if (and dot-bin (display-images-p) (image-type-available-p 'svg))
            (let ((svg (with-temp-buffer
                         (insert dot)
                         (and (eql 0 (call-process-region (point-min) (point-max) dot-bin t t nil "-Tsvg")) (buffer-string)))))
              (if svg (insert-image (create-image svg 'svg t)) (insert dot)))
          (insert dot)
          (unless dot-bin (message "Work: install Graphviz (dot) to see this as a graph"))))
      (goto-char (point-min))
      (setq buffer-read-only t))
    (pop-to-buffer b)
    b))

;;;; The module

(drgnx-module-define 'tools/work
  :doc "Work: specs › plans › tasks › TODOs › commits in the right dock's Work tab; the graph."
  :stage 'startup :requires '(core/workbench)
  :setup
  (lambda ()
    (add-hook 'drgnx-agents-task-functions #'drgnx-work-ui--agent-turn 90)
    (when (fboundp 'drgnx-wb-define-tab) (drgnx-wb-define-tab 'right 'work :title "Work"))
    (when (fboundp 'drgnx-wb-place)
      (drgnx-wb-place 'drgnx-work-mode 'right :tab 'work)
      (drgnx-wb-place "\\`\\*\\(commit: \\|work graph\\*\\)" 'editor))
    (pcase-dolist (`(,id ,title ,fn ,doc)
                   '((work-view "Show Work" drgnx-work-ui-view "Specs, plans, tasks, TODOs and commits, in the right dock")
                     (work-graph "Show Work as Graph" drgnx-work-ui-graph "Specs, plans and branches drawn with Graphviz")
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
