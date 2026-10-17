;;; work-ui-test.el --- batch tests: the Work tab (tree, open, filter, refresh, graph, agents on a task) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(require 'drgnx-agents)                ; loaded before any test stubs its functions
(load (expand-file-name "modules/tools/drgnx-work-ui" drgnx-dir) nil t)

(defun drgnx-work-ui-test--git (dir &rest args)
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (apply #'call-process "git" nil t nil "-c" "user.name=t" "-c" "user.email=t@t.invalid" args)
      (string-trim (buffer-string)))))

(defmacro drgnx-work-ui-test--with (root &rest body)
  "BODY with ROOT a temp dir holding a spec, a plan of two tasks (one with a recorded commit of the
git repository ROOT/code), a lone plan, and the tracker's database in a temp data dir, scanned."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-work-ui" t)))
          (process-environment (append (list (concat "DRGNX_DATA_DIR=" ,root "data") (concat "DRGNX_CONFIG_DIR=" ,root "config"))
                                       process-environment))
          (drgnx-work-db--handles nil) (drgnx-work-ui--expanded (make-hash-table :test #'equal))
          (drgnx-work-ui-filter-text nil) (drgnx-work-ui-hide-merged nil))
     (unwind-protect
         (progn
           (make-directory (concat ,root "docs/specs") t) (make-directory (concat ,root "docs/plans") t)
           (make-directory (concat ,root "code") t)
           (write-region "# The Spec\n\nWhy.\n" nil (concat ,root "docs/specs/s.md") nil 'silent)
           (write-region "# Plan Alpha\n\n**Spec:** `../specs/s.md`\n\n### Task 1: first\n\n- [x] **Step 1: write it**\n- [ ] **Step 2: run it**\n\n### Task 2: second\n\n- [ ] **Step 1: later**\n"
                         nil (concat ,root "docs/plans/alpha.md") nil 'silent)
           (write-region "# Plan Beta\n\n### Task 1: only\n\n- [ ] one\n" nil (concat ,root "docs/plans/beta.md") nil 'silent)
           (write-region "# Plan Delta\n\n### Task 1: no steps\n" nil (concat ,root "docs/plans/delta.md") nil 'silent)
           (drgnx-work-ui-test--git (concat ,root "code") "init" "-q" "-b" "main")
           (write-region "x" nil (concat ,root "code/f") nil 'silent)
           (drgnx-work-ui-test--git (concat ,root "code") "add" "-A")
           (drgnx-work-ui-test--git (concat ,root "code") "commit" "-q" "-m" "did the first task")
           (drgnx-work-scan (list ,root))
           (drgnx-work-record (concat "task:" ,root "docs/plans/alpha.md#1") (concat ,root "code/")
                              (drgnx-work-ui-test--git (concat ,root "code") "rev-parse" "HEAD"))
           ,@body)
       (drgnx-work-db-close-all)
       (when (get-buffer "*drgnx Work*") (kill-buffer "*drgnx Work*"))
       (delete-directory ,root t))))

(defun drgnx-work-ui-test--goto (text)
  (goto-char (point-min))
  (should (search-forward text nil t))
  (beginning-of-line))

(ert-deftest drgnx-work-ui/the-tree-shows-each-spec-with-its-plans-and-their-counts ()
  (drgnx-work-ui-test--with root
    (with-current-buffer (drgnx-work-ui-buffer)
      (let ((text (buffer-string)))
        (should (string-match-p "◆ The Spec" text))
        (should (string-match-p "^  ▸ ▣ 0/2 Plan Alpha  steps 1/3 · 1 commit$" text))    ; under its spec; tasks first
        (should (string-match-p "^▸ ▣ 0/1 Plan Beta  steps 0/1 · 0 commits$" text))       ; no spec: a root
        (should (string-match-p "^▸ ▣ 0/1 Plan Delta  0 commits$" text))                    ; no steps: none counted
        (should-not (string-search "Task 1: first" text))))))                                   ; plans start folded

(ert-deftest drgnx-work-ui/tab-unfolds-a-plan-into-tasks-and-a-task-into-steps-and-commits ()
  (drgnx-work-ui-test--with root
    (with-current-buffer (drgnx-work-ui-buffer)
      (drgnx-work-ui-test--goto "Plan Alpha")
      (drgnx-work-ui-toggle)
      (should (string-search "☐ Task 1: first" (buffer-string)))
      (should (equal (plist-get (drgnx-work-ui--node) :title) "Plan Alpha"))   ; point stays on the line folded
      (drgnx-work-ui-test--goto "Task 1: first")
      (drgnx-work-ui-toggle)
      (let ((text (buffer-string)))
        (should (string-search "☑ Step 1: write it" text))
        (should (string-search "☐ Step 2: run it" text))
        (should (string-match-p "● [0-9a-f]\\{7\\} did the first task" text)))
      (drgnx-work-ui-test--goto "Plan Alpha")
      (drgnx-work-ui-toggle)                                     ; folds again, its children with it
      (should-not (string-search "Task 1: first" (buffer-string))))))

(ert-deftest drgnx-work-ui/ret-opens-a-task-at-its-line-and-a-commit-as-a-diff ()
  (drgnx-work-ui-test--with root
    (with-current-buffer (drgnx-work-ui-buffer)
      (drgnx-work-ui-test--goto "Plan Alpha") (drgnx-work-ui-toggle)
      (drgnx-work-ui-test--goto "Task 2: second")
      (let ((b (save-window-excursion (drgnx-work-ui-open) (current-buffer))))
        (unwind-protect
            (with-current-buffer b
              (should (equal (buffer-file-name) (concat root "docs/plans/alpha.md")))
              (should (looking-at-p "### Task 2: second")))
          (kill-buffer b)))
      (with-current-buffer (drgnx-work-ui-buffer)
        (drgnx-work-ui-test--goto "Task 1: first") (drgnx-work-ui-toggle)
        (drgnx-work-ui-test--goto "did the first task")
        (let ((b (save-window-excursion (drgnx-work-ui-open) (current-buffer))))
          (unwind-protect
              (with-current-buffer b
                (should (derived-mode-p 'diff-mode))
                (should (string-search "did the first task" (buffer-string))))
            (kill-buffer b)))))))

(ert-deftest drgnx-work-ui/the-filter-and-hide-merged-narrow-the-plans ()
  (drgnx-work-ui-test--with root
    (with-current-buffer (drgnx-work-ui-buffer)
      (drgnx-work-ui-filter "beta")
      (should (string-search "Plan Beta" (buffer-string)))
      (should-not (string-search "Plan Alpha" (buffer-string)))
      (should-not (string-search "The Spec" (buffer-string)))   ; a spec with no plan shown is hidden too
      (drgnx-work-ui-filter "")
      (should (string-search "Plan Alpha" (buffer-string)))
      (drgnx-work-update-node (concat "plan:" root "docs/plans/beta.md") :merged t)
      (drgnx-work-ui-toggle-merged)
      (should-not (string-search "Plan Beta" (buffer-string)))
      (should (string-search "Plan Alpha" (buffer-string))))))

(defun drgnx-work-ui-test--graph ()
  "Show Work as Graph as on a graphical frame (batch has none); its buffer."
  (cl-letf (((symbol-function 'display-images-p) #'always)) (save-window-excursion (drgnx-work-ui-graph))))

(defun drgnx-work-ui-test--edge-ids (layout)
  (mapcar (lambda (e) (mapcar (lambda (b) (plist-get b :id)) e)) (plist-get layout :edges)))

(defun drgnx-work-ui-test--box (layout id) (seq-find (lambda (b) (equal (plist-get b :id) id)) (plist-get layout :boxes)))

(ert-deftest drgnx-work-ui/the-graph-lays-out-specs-plans-and-branches-in-columns ()
  (drgnx-work-ui-test--with root
    (let ((alpha (concat "plan:" root "docs/plans/alpha.md")) (beta (concat "plan:" root "docs/plans/beta.md")))
      (drgnx-work-update-node alpha :branch "feature")
      (drgnx-work-update-node beta :title (concat "Plan Beta " (make-string 80 ?x)))
      (let* ((l (drgnx-work-ui-graph-layout))
             (spec (drgnx-work-ui-test--box l (concat "spec:" root "docs/specs/s.md")))
             (a (drgnx-work-ui-test--box l alpha)) (b (drgnx-work-ui-test--box l beta))
             (br (drgnx-work-ui-test--box l "branch feature")))
        (should (and spec a b br))
        (should (< (plist-get spec :x) (plist-get a :x) (plist-get br :x)))      ; columns: spec | plan | branch
        (should (= (plist-get a :x) (plist-get b :x)))
        (should (equal (plist-get a :lines) '("Plan Alpha" "0/2 tasks · 1 commit")))
        (should (= (length (car (plist-get b :lines))) 48))                      ; a long title is cut…
        (should (string-suffix-p "…" (car (plist-get b :lines))))
        (should (member (list (plist-get spec :id) alpha) (drgnx-work-ui-test--edge-ids l)))
        (should (member (list alpha "branch feature") (drgnx-work-ui-test--edge-ids l)))
        (let ((boxes (plist-get l :boxes)))                                     ; …and no two boxes overlap
          (dolist (p boxes)
            (dolist (q boxes)
              (unless (eq p q)
                (should-not (and (< (plist-get p :x) (+ (plist-get q :x) (plist-get q :w)))
                                 (< (plist-get q :x) (+ (plist-get p :x) (plist-get p :w)))
                                 (< (plist-get p :y) (+ (plist-get q :y) (plist-get q :h)))
                                 (< (plist-get q :y) (+ (plist-get p :y) (plist-get p :h)))))))))))))

(ert-deftest drgnx-work-ui/plans-on-one-branch-each-link-their-own-branch-box ()
  (drgnx-work-ui-test--with root
    (dolist (p '("alpha" "beta"))
      (let ((id (concat "plan:" root "docs/plans/" p ".md")))
        (drgnx-work-update-node id :branch "main")
        (drgnx-work-put-edge id "branch:/repo/.git:main" 'on-branch 'inferred "branch")))
    (let ((l (drgnx-work-ui-graph-layout)))
      (dolist (e (plist-get l :edges))
        (when (eq (plist-get (cadr e) :kind) 'branch)
          (should (= (plist-get (car e) :y) (plist-get (cadr e) :y))))))))   ; beside its own plan

(ert-deftest drgnx-work-ui/a-big-graph-is-drawn-in-bands-emacs-can-show ()
  (drgnx-work-ui-test--with root
    (dotimes (i 60)
      (write-region (format "# Plan %02d

### Task 1: x
" i) nil (format "%sdocs/plans/many-%02d.md" root i) nil 'silent))
    (drgnx-work-scan (list root))
    (let* ((g (drgnx-work-ui-test--graph))
           (images (with-current-buffer g
                     (delete-dups (cl-loop for p from (point-min) below (point-max)
                                           for d = (get-text-property p 'display)
                                           when d collect (if (eq (car d) 'image) d (cadr d))))))
           (covered (make-hash-table :test #'equal)))
      (unwind-protect
          (progn
            (should (> (length images) 1))
            (dolist (img images)
              (should (string-match "<svg width=\"[0-9]+\" height=\"\\([0-9]+\\)\"" (image-property img :data)))
              (should (<= (string-to-number (match-string 1 (image-property img :data))) drgnx-work-ui-graph-band))
              (pcase-dolist (`((rect . ((,_ . ,y0) . (,_ . ,y1))) ,area . ,_) (image-property img :map))
                (cl-incf (gethash area covered 0) (- y1 y0))))
            ;; every box clickable all over, across the bands it spans
            (pcase-dolist (`(,area . ,box) drgnx-work-ui--graph-spots)
              (should (= (gethash area covered 0) (plist-get box :h)))))
        (kill-buffer g)))))

(ert-deftest drgnx-work-ui/the-graph-on-a-text-frame-says-it-cannot-be-shown ()
  (drgnx-work-ui-test--with root
    (cl-letf (((symbol-function 'display-images-p) #'ignore))
      (should-error (drgnx-work-ui-graph) :type 'user-error))))

(ert-deftest drgnx-work-ui/g-draws-the-graph-again-and-wide-graphs-scroll-sideways ()
  (drgnx-work-ui-test--with root
    (let ((g (drgnx-work-ui-test--graph)))
      (unwind-protect
          (with-current-buffer g
            (should truncate-lines)                                              ; sideways, not wrapped
            (cl-letf (((symbol-function 'display-images-p) #'always)) (revert-buffer))
            (should (get-text-property (point-min) 'display)))
        (kill-buffer g)))))

(ert-deftest drgnx-work-ui/the-graph-takes-its-colours-from-the-theme ()
  (drgnx-work-ui-test--with root
    (let ((old (face-attribute 'drgnx-work-ui-graph-plan :foreground)))
      (unwind-protect
          (progn
            (set-face-attribute 'drgnx-work-ui-graph-plan nil :foreground "#123456")   ; as a theme would
            (let ((svg (drgnx-work-ui-graph-svg (drgnx-work-ui-graph-layout))))
              (should (string-search "#123456" svg))
              (should (string-search "currentColor" svg)))                     ; faces with no colour (batch)
            ;; Emacs's colour names are X11's (grey50, dark cyan); SVG knows only CSS's: written as #rrggbb
            (set-face-attribute 'drgnx-work-ui-graph-plan nil :foreground "dark cyan")
            (let ((svg (drgnx-work-ui-graph-svg (drgnx-work-ui-graph-layout))))
              (should (string-search "#008b8b" svg))
              (should-not (string-search "dark cyan" svg))))                      ; faces with no colour (batch)
        (set-face-attribute 'drgnx-work-ui-graph-plan nil :foreground old)))))

(ert-deftest drgnx-work-ui/a-tall-graph-scrolls-line-by-line ()
  (drgnx-work-ui-test--with root
    (let ((g (drgnx-work-ui-test--graph)))
      (unwind-protect
          (with-current-buffer g
            (should (> (count-lines (point-min) (point-max)) 1))              ; slices, one per line
            (goto-char (point-max)) (forward-line -1)
            (should (get-text-property (point) 'keymap)))                     ; every slice clickable
        (kill-buffer g)))))

(ert-deftest drgnx-work-ui/the-graph-shows-no-cursor-and-a-press-moves-nothing ()
  (drgnx-work-ui-test--with root
    (let ((g (drgnx-work-ui-test--graph)))
      (unwind-protect
          (with-current-buffer g
            (should (null cursor-type))                                          ; no box drawn round the image
            (should (eq (lookup-key (get-text-property (point-min) 'keymap) [down-mouse-1]) #'ignore)))
        (kill-buffer g)))))

(ert-deftest drgnx-work-ui/a-click-on-a-box-opens-what-it-shows ()
  (drgnx-work-ui-test--with root
    (drgnx-work-update-node (concat "plan:" root "docs/plans/alpha.md") :branch "feature")
    (let* ((g (drgnx-work-ui-test--graph))
           (img (with-current-buffer g (let ((d (get-text-property (point-min) 'display))) (if (eq (car d) 'image) d (cadr d)))))
           (keymap (with-current-buffer g (get-text-property (point-min) 'keymap)))
           (area (lambda (title) (seq-find (lambda (a) (string-prefix-p title (plist-get (nth 2 a) 'help-echo))) (image-property img :map)))))
      (unwind-protect
          (let* ((a (funcall area "Plan Alpha")) (br (funcall area "branch feature"))
                 ;; a click as Emacs delivers it: plain mouse-1, the hot spot in its position
                 (click (lambda (spot) (funcall (lookup-key keymap [mouse-1]) (list 'mouse-1 (list nil (nth 1 spot) '(0 . 0) 0))))))
            (should (eq (car (car a)) 'rect))
            (should (eq (lookup-key keymap (vector (nth 1 a) 'mouse-1)) (lookup-key keymap [mouse-1])))   ; prefixed: the same
            (let ((b (save-window-excursion (funcall click a) (current-buffer))))
              (unwind-protect (should (equal (buffer-file-name b) (concat root "docs/plans/alpha.md")))
                (kill-buffer b)))
            ;; a branch without a worktree, a plan whose file went: said, never an error
            (should (stringp (funcall click br)))
            (delete-file (concat root "docs/plans/alpha.md"))
            (should (stringp (funcall click a))))
        (kill-buffer g)))))

(ert-deftest drgnx-work-ui/refresh-scans-in-another-process-and-redraws ()
  (drgnx-work-ui-test--with root
    (let ((drgnx-work-roots (list root)))
      (write-region "# Plan Gamma\n\n### Task 1: x\n\n- [ ] y\n" nil (concat root "docs/plans/gamma.md") nil 'silent)
      (with-current-buffer (drgnx-work-ui-buffer)
        (should-not (string-search "Plan Gamma" (buffer-string)))
        (let ((p (drgnx-work-ui-refresh)))
          (should (processp p))                                 ; not the scan itself: Emacs stays free
          (let ((d (+ (float-time) 60))) (while (and (process-live-p p) (< (float-time) d)) (accept-process-output p 0.1)))
          (accept-process-output nil 0.2))
        (should (string-search "Plan Gamma" (buffer-string)))))))

(ert-deftest drgnx-work-ui/an-agent-started-on-a-task-works-on-it ()
  (drgnx-work-ui-test--with root
    (let ((started nil))
      (cl-letf (((symbol-function 'drgnx-agents-start) (lambda (profile cwd task) (setq started (list profile cwd task)) 'session))
                ((symbol-function 'drgnx-agents-ui-transcript) #'ignore))
        (with-current-buffer (drgnx-work-ui-buffer)
          (drgnx-work-ui-test--goto "Plan Alpha") (drgnx-work-ui-toggle)
          (drgnx-work-ui-test--goto "Task 2: second")
          (drgnx-work-ui-start-agent "mock")
          (should (equal started (list "mock" (concat root "docs/plans/") (concat "task:" root "docs/plans/alpha.md#2"))))
          (drgnx-work-update-node (concat "plan:" root "docs/plans/alpha.md") :worktree (concat root "code/"))
          (drgnx-work-ui-start-agent "mock")                     ; the plan's worktree, when it has one
          (should (equal (nth 1 started) (concat root "code/"))))))))

(ert-deftest drgnx-work-ui/every-command-is-registered ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (funcall (plist-get (alist-get 'tools/work drgnx-modules--table) :setup))
    (dolist (id '(work-view work-refresh work-open work-toggle work-filter work-hide-merged work-graph work-start-agent work-open-worktree))
      (should (drgnx-commands-get id)))))

(ert-deftest drgnx-work-ui/doctor-says-whether-the-tracker-can-work ()
  (require 'drgnx-doctor)
  (should (eq 'fail (car (drgnx-doctor-check 'work '(:sqlite nil)))))
  (should (eq 'info (car (drgnx-doctor-check 'work '(:sqlite t :svg t :work-plans nil)))))
  (should (eq 'warn (car (drgnx-doctor-check 'work '(:sqlite t :svg nil :work-plans 3)))))   ; no graph without SVG
  (should (equal '(ok "3 plans tracked") (seq-take (drgnx-doctor-check 'work '(:sqlite t :svg t :work-plans 3)) 2))))

(ert-deftest drgnx-work-ui/commits-recorded-for-a-todo-or-the-plan-show-and-count ()
  (drgnx-work-ui-test--with root
    (let* ((plan (concat "plan:" root "docs/plans/alpha.md")) (code (concat root "code/"))
           (commit (lambda (msg) (write-region msg nil (concat code msg) nil 'silent)
                     (drgnx-work-ui-test--git code "add" "-A") (drgnx-work-ui-test--git code "commit" "-q" "-m" msg)
                     (drgnx-work-ui-test--git code "rev-parse" "HEAD"))))
      (drgnx-work-put-node "todo:/b.org#1" :kind 'todo :title "a todo" :path "/b.org" :line 1 :status "open" :parent plan :ord 1 :source "/b.org")
      (drgnx-work-record "todo:/b.org#1" code (funcall commit "for-the-todo"))
      (drgnx-work-record plan code (funcall commit "for-the-plan"))
      (with-current-buffer (drgnx-work-ui-buffer)
        (should (string-match-p "Plan Alpha  steps 1/3 · todos 0/1 · 3 commits" (buffer-string)))
        (drgnx-work-ui-test--goto "Plan Alpha") (drgnx-work-ui-toggle)
        (drgnx-work-ui-test--goto "TODO a todo")
        (should (looking-at-p "    ▸ ○ TODO a todo"))
        (drgnx-work-ui-toggle)
        (should (string-search "for-the-todo" (buffer-string)))))))

;;; work-ui-test.el ends here
