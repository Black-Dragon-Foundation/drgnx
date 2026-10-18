;;; mod-cockpit-graph-test.el --- batch tests: the Work graph (columns, edges, the waiting mark, colours, the outline, clicks, redraws) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/cockpit-fixture" drgnx-dir) nil t)   ; a project, a job, worktrees, events
(load (expand-file-name "modules/tools/drgnx-cockpit" drgnx-dir) nil t)

(defun drgnx-cockpit-graph-test--box (layout id)
  (seq-find (lambda (b) (equal (plist-get b :id) id)) (plist-get layout :boxes)))

(defun drgnx-cockpit-graph-test--line (lines id)
  "The line of LINES whose node is ID (the first)."
  (seq-find (lambda (l) (equal (get-text-property 0 'drgnx-cockpit-node l) id)) lines))

(defmacro drgnx-cockpit-graph-test--with (&rest body)
  "BODY in the cockpit fixture, with the Work graph's buffer G shown in the selected window and the hub's sessions
the fixture's."
  (declare (indent 0))
  `(drgnx-cockpit-fixture-with
     (let ((drgnx-cockpit-graph-filter nil) (drgnx-cockpit--draws 0) (drgnx-cockpit--timer nil)
           (config (current-window-configuration)))
       (cl-letf (((symbol-function 'drgnx-cockpit-sessions) (lambda () sessions)))
         (let ((g (drgnx-cockpit-graph-buffer)))
           (unwind-protect
               (save-window-excursion
                 (delete-other-windows)
                 (set-window-buffer (selected-window) g)
                 ,@body)
             (when (timerp drgnx-cockpit--timer) (cancel-timer drgnx-cockpit--timer))
             (kill-buffer g)
             (set-window-configuration config)))))))

(defun drgnx-cockpit-graph-test--tick ()
  "Run the redraw on its way now (as its timer would)."
  (should (timerp drgnx-cockpit--timer))
  (cancel-timer drgnx-cockpit--timer)
  (drgnx-cockpit--tick))

(defun drgnx-cockpit-graph-test--goto (id)
  "Point on node ID's line in the graph's outline."
  (goto-char (point-min))
  (let ((m (text-property-search-forward 'drgnx-cockpit-node id t)))
    (should m)
    (goto-char (prop-match-beginning m))))

(ert-deftest drgnx-cockpit-graph/columns-and-edges ()
  (drgnx-cockpit-fixture-with
    (let* ((m (drgnx-cockpit-model :sessions sessions))
           (l (drgnx-cockpit-graph-layout m '(8 . 16)))
           (todo (plist-get (seq-find (lambda (n) (eq (plist-get n :kind) 'todo)) (plist-get m :nodes)) :id))
           (col (lambda (layout id) (plist-get (drgnx-cockpit-graph-test--box layout id) :col))))
      ;; spec | plan | tasks and TODOs | agents, jobs and reviews
      (should (= 0 (funcall col l (concat "spec:" spec))))
      (should (= 1 (funcall col l (concat "plan:" plan))))
      (dolist (n '(1 2 3 4 5 6)) (should (= 2 (funcall col l (format "task:%s#%d" plan n)))))
      (should (= 2 (funcall col l todo)))
      (dolist (id '("job:jx" "agent:s-1" "agent:s-2" "agent:ext:claude-code:42")) (should (= 3 (funcall col l id))))
      ;; every node a box, every edge of the model an edge of the layout (needs and blocks too)
      (should (= (length (plist-get l :boxes)) (length (plist-get m :nodes))))
      (dolist (e (plist-get m :edges))
        (should (member (list :from (plist-get e :from) :to (plist-get e :to) :kind (plist-get e :kind)) (plist-get l :edges))))
      (should (seq-find (lambda (e) (eq (plist-get e :kind) 'needs)) (plist-get l :edges)))
      ;; columns left to right, boxes inside the drawing, never overlapping in a column
      (let ((xs (mapcar (lambda (c) (plist-get (seq-find (lambda (b) (= (plist-get b :col) c)) (plist-get l :boxes)) :x)) '(0 1 2 3))))
        (should (equal xs (sort (copy-sequence xs) #'<))))
      (dolist (b (plist-get l :boxes))
        (should (<= (+ (plist-get b :x) (plist-get b :w)) (plist-get l :w)))
        (should (<= (+ (plist-get b :y) (plist-get b :h)) (plist-get l :h)))
        (dolist (o (plist-get l :boxes))
          (when (and (not (eq b o)) (= (plist-get b :col) (plist-get o :col)))
            (should (or (<= (+ (plist-get b :y) (plist-get b :h)) (plist-get o :y))
                        (<= (+ (plist-get o :y) (plist-get o :h)) (plist-get b :y)))))))
      ;; a parent sits level with what it joins: the plan between its first and its last task
      (let ((p (drgnx-cockpit-graph-test--box l (concat "plan:" plan)))
            (t1 (drgnx-cockpit-graph-test--box l (format "task:%s#1" plan)))
            (t6 (drgnx-cockpit-graph-test--box l (format "task:%s#6" plan))))
        (should (< (plist-get t1 :y) (plist-get p :y) (plist-get t6 :y))))
      ;; a kind no column lists goes in the last; adding a column is adding a list
      (let* ((drgnx-cockpit-graph-columns '((spec plan) (task)))
             (l2 (drgnx-cockpit-graph-layout m '(8 . 16))))
        (should (= 0 (funcall col l2 (concat "plan:" plan))))
        (dolist (id (list "job:jx" "agent:s-1" todo)) (should (= 1 (funcall col l2 id)))))
      (let* ((drgnx-cockpit-graph-columns '((spec) (plan) (task todo) (job) (agent review)))
             (l3 (drgnx-cockpit-graph-layout m '(8 . 16))))
        (should (= 3 (funcall col l3 "job:jx")))
        (should (= 4 (funcall col l3 "agent:s-1")))))))

(ert-deftest drgnx-cockpit-graph/waiting-nodes-have-the-dot ()
  (drgnx-cockpit-fixture-with
    (let* ((m (drgnx-cockpit-model :sessions sessions))
           (lines (drgnx-cockpit-graph-outline m))
           (mark (alist-get 'waiting (drgnx-cockpit-graph--glyph-table)))
           (t3 (drgnx-cockpit-graph-test--line lines (format "task:%s#3" plan)))
           (t4 (drgnx-cockpit-graph-test--line lines (format "task:%s#4" plan))))
      ;; the fixture's reopened ask card makes T3 wait; T4 does not
      (should (plist-get (seq-find (lambda (n) (equal (plist-get n :id) (format "task:%s#3" plan))) (plist-get m :nodes)) :waiting))
      (let ((i (string-search (concat mark " ") t3)))
        (should i)
        (should (eq (get-text-property i 'face t3) 'drgnx-cockpit-waiting))
        (should (string-search "waits on you" t3)))
      (should-not (string-search (concat mark " ") t4))
      ;; the first line says how many wait on you, in the waiting face
      (should (string-match-p "2 waiting on you" (car lines)))
      (should (eq (get-text-property 0 'face (car lines)) 'drgnx-cockpit-waiting))
      ;; a terminal that is not UTF-8: the mark's ASCII form
      (cl-letf (((symbol-function 'drgnx-cockpit-graph--ascii-p) #'always))
        (should (string-search "? T3" (drgnx-cockpit-graph-test--line (drgnx-cockpit-graph-outline m) (format "task:%s#3" plan)))))
      ;; the drawing: the mark and a dot in the waiting face's colour, on each waiting node
      (let ((old (face-attribute 'drgnx-cockpit-waiting :foreground)))
        (unwind-protect
            (progn
              (set-face-attribute 'drgnx-cockpit-waiting nil :foreground "#ee1111")
              (let ((svg (drgnx-cockpit-graph-svg (drgnx-cockpit-graph-layout m '(8 . 16)))))
                (should (= 2 (cl-loop with start = 0 while (string-match "<circle[^>]*fill=\"#ee1111\"" svg start)
                                      count t do (setq start (match-end 0)))))
                (should (string-match-p "fill=\"#ee1111\"[^>]*>&#9680;<" svg))))   ; ◐, as svg.el writes it
          (set-face-attribute 'drgnx-cockpit-waiting nil :foreground old))))))

(ert-deftest drgnx-cockpit-graph/svg-has-no-colour-literal-not-from-a-face ()
  (drgnx-cockpit-fixture-with
    (let* ((m (drgnx-cockpit-model :sessions sessions))
           (layout (drgnx-cockpit-graph-layout m '(8 . 16)))
           (faces '(default drgnx-cockpit-waiting drgnx-cockpit-done drgnx-cockpit-running drgnx-cockpit-blocked drgnx-cockpit-edge))
           (saved (mapcar (lambda (f) (cons f (face-attribute f :foreground))) faces))
           (bg (face-attribute 'default :background))
           (colours (lambda (svg) (cl-loop with start = 0 while (string-match "\\(?:fill\\|stroke\\)=\"\\([^\"]*\\)\"" svg start)
                                           collect (match-string 1 svg) do (setq start (match-end 0))))))
      ;; faces without a colour (batch): only the image's foreground and none
      (dolist (c (funcall colours (drgnx-cockpit-graph-svg layout)))
        (should (string-match-p "\\`\\(none\\|currentColor\\|#[0-9a-f]\\{6\\}\\)\\'" c)))
      ;; the job's edge to its plan goes round the tasks' column (never behind a task, as if it came out of one)
      (should (string-match-p "d=\"M[0-9]+,[0-9]+ H[0-9]+ V[0-9]+ H[0-9]+ V[0-9]+ H[0-9]+\"" (drgnx-cockpit-graph-svg layout)))
      (unwind-protect
          (progn
            ;; as a theme sets them: every colour in the drawing is one of these
            (cl-loop for f in faces for i from 1 do (set-face-attribute f nil :foreground (format "#0000%02x" i)))
            (set-face-attribute 'default nil :background "#101010")
            (let* ((svg (drgnx-cockpit-graph-svg layout))
                   (allowed (append '("none" "currentColor" "#101010") (cl-loop for i from 1 to (length faces) collect (format "#0000%02x" i)))))
              (dolist (c (funcall colours svg)) (should (member c allowed)))
              (dolist (i '(1 2 3 4 6)) (should (string-search (format "#0000%02x" i) svg)))   ; text, waiting, done, running, lines
              (should-not (string-match-p "rgb(\\|hsl(" svg))))
        (pcase-dolist (`(,f . ,c) saved) (ignore-errors (set-face-attribute f nil :foreground c)))
        (ignore-errors (set-face-attribute 'default nil :background bg))))))

(ert-deftest drgnx-cockpit-graph/terminal-gets-the-outline ()
  (drgnx-cockpit-graph-test--with
    (let ((image-p (lambda () (text-property-not-all (point-min) (point-max) 'display nil))))
      ;; batch: a terminal frame — the outline, every node on a line
      (should (drgnx-cockpit-graph-redraw t))
      (with-current-buffer g
        (should-not (funcall image-p))
        (dolist (n (plist-get drgnx-cockpit--model :nodes))
          (goto-char (point-min))
          (should (text-property-search-forward 'drgnx-cockpit-node (plist-get n :id) t)))
        (goto-char (point-min))
        (should (re-search-forward "^Spec The spec" nil t))
        (should (re-search-forward "Plan M99 — the plan  1/6 done" nil t))
        (should (re-search-forward "T2 task 2  ← claude · jx#2" nil t))
        (should (re-search-forward "blocks: T3, T4" nil t))
        (should (re-search-forward "needs: T2" nil t))
        (should (re-search-forward "^AGENTS" nil t)))
      ;; a small window (Review Focus 5): no error, the outline
      (let ((w (split-window-right 20)))
        (set-window-buffer w g)
        (should (drgnx-cockpit-graph-redraw t))
        (with-current-buffer g (should-not (funcall image-p)))
        (delete-window w))
      (when (image-type-available-p 'svg)
        (cl-letf (((symbol-function 'display-images-p) #'always))
          ;; a graphical window too narrow for the drawing (a 500 px frame): the outline
          (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 500)))
            (drgnx-cockpit-graph-redraw t)
            (with-current-buffer g (should-not (funcall image-p))))
          ;; …with room: the drawing; the option off: the outline again
          (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 5000)))
            (drgnx-cockpit-graph-redraw t)
            (with-current-buffer g (should (funcall image-p)) (should-not cursor-type))   ; no box round a slice
            (let ((drgnx-cockpit-graph-svg nil))
              (drgnx-cockpit-graph-redraw t)
              (with-current-buffer g (should-not (funcall image-p)) (should cursor-type)))))))))

(ert-deftest drgnx-cockpit-graph/clicks-open-the-right-tab ()
  (drgnx-cockpit-graph-test--with
    (drgnx-cockpit-graph-redraw t)
    (let ((opened (lambda () (list (buffer-file-name (window-buffer (selected-window)))
                                   (with-selected-window (selected-window) (line-number-at-pos)))))
          (jobs nil) (msg nil))
      (cl-letf (((symbol-function 'drgnx-job-ui-show) (lambda (id) (push id jobs)))
                ((symbol-function 'message) (lambda (fmt &rest args) (setq msg (and fmt (apply #'format fmt args))))))
        ;; RET: a spec or plan → its file at its line
        (with-current-buffer g (drgnx-cockpit-graph-test--goto (concat "plan:" plan)))
        (with-selected-window (get-buffer-window g) (call-interactively #'drgnx-cockpit-graph-open))
        (should (equal (funcall opened) (list plan 1)))
        ;; a plan task no job runs: read-only — open in plan, and Start Job is named, never done
        (set-window-buffer (selected-window) g) (setq msg nil)
        (with-current-buffer g (drgnx-cockpit-graph-test--goto (format "task:%s#5" plan)))
        (with-selected-window (get-buffer-window g) (call-interactively #'drgnx-cockpit-graph-open))
        (should (equal (funcall opened) (list plan (plan-line 5))))
        (should (string-match-p "read-only.*Start Job from Plan" msg))
        (should-not jobs)
        ;; a job → its window; an agent with no session here says so
        (set-window-buffer (selected-window) g)
        (with-current-buffer g (drgnx-cockpit-graph-test--goto "job:jx"))
        (with-selected-window (get-buffer-window g) (call-interactively #'drgnx-cockpit-graph-open))
        (should (equal jobs '("jx")))
        (with-current-buffer g (drgnx-cockpit-graph-test--goto "agent:s-1"))
        (with-selected-window (get-buffer-window g) (call-interactively #'drgnx-cockpit-graph-open))
        (should (string-match-p "claude · jx#2" msg))
        ;; o on an agent: the plan line of its task
        (with-current-buffer g (drgnx-cockpit-graph-test--goto "agent:s-2"))
        (with-selected-window (get-buffer-window g) (drgnx-cockpit-graph-open-in-plan (drgnx-cockpit--node-here)))
        (should (equal (funcall opened) (list plan (plan-line 5))))
        ;; a click on an outline line opens it
        (set-window-buffer (selected-window) g)
        (let ((pos (with-current-buffer g (drgnx-cockpit-graph-test--goto (format "task:%s#2" plan)) (point))))
          (drgnx-cockpit-graph-click (list 'mouse-1 (list (get-buffer-window g) pos '(0 . 0) 0))))
        (should (equal (funcall opened) (list plan (plan-line 2))))
        ;; a click on a box of the drawing (its hot spot) opens it
        (when (image-type-available-p 'svg)
          (set-window-buffer (selected-window) g)
          (cl-letf (((symbol-function 'display-images-p) #'always) ((symbol-function 'window-body-width) (lambda (&rest _) 5000)))
            (drgnx-cockpit-graph-redraw t))
          (let ((area (car (rassoc (concat "spec:" spec) (buffer-local-value 'drgnx-cockpit--spots g)))))
            (should area)
            (with-current-buffer g
              (should (eq (lookup-key (get-text-property (1- (point-max)) 'keymap) (vector area 'mouse-1)) #'drgnx-cockpit-graph-click)))
            (drgnx-cockpit-graph-click (list 'mouse-1 (list (get-buffer-window g) area '(0 . 0) 0)))
            (should (equal (funcall opened) (list spec 1)))))))))

(ert-deftest drgnx-cockpit-graph/redraw-only-when-changed ()
  (drgnx-cockpit-graph-test--with
    (drgnx-cockpit-graph-redraw t)
    (let ((n drgnx-cockpit--draws))
      ;; a change, then a burst of events: one redraw on its way, one draw
      (drgnx-coord-force-status "jx#4" "running" "s-1")
      (dotimes (_ 20) (drgnx-cockpit--hub-event "job" '(:id "jx")))
      (drgnx-cockpit-graph-test--tick)
      (should (= drgnx-cockpit--draws (1+ n)))
      (with-current-buffer g (drgnx-cockpit-graph-test--goto (format "task:%s#4" plan)) (should (looking-at ".*running")))
      ;; the same burst again, nothing changed: nothing drawn
      (dotimes (_ 20) (drgnx-cockpit--hub-event "card" '(:job "jx")) (drgnx-cockpit--agent-changed nil))
      (drgnx-cockpit-graph-test--tick)
      (should (= drgnx-cockpit--draws (1+ n)))
      ;; a transcript's chunks never schedule one
      (drgnx-cockpit--hub-event "agent-entries" '(:id "s-1"))
      (should-not drgnx-cockpit--timer)
      ;; a patch: an outline line that did not change keeps its text (and the window its point)
      (with-current-buffer g (drgnx-cockpit-graph-test--goto (concat "spec:" spec)))
      (let ((pt (window-point (get-buffer-window g))))
        (drgnx-coord-force-status "jx#4" "done" "s-1")
        (drgnx-cockpit-schedule)
        (drgnx-cockpit-graph-test--tick)
        (should (= drgnx-cockpit--draws (+ 2 n)))
        (should (= pt (window-point (get-buffer-window g))))))))

(ert-deftest drgnx-cockpit-graph/hidden-pane-does-not-redraw ()
  (drgnx-cockpit-graph-test--with
    (drgnx-cockpit-graph-redraw t)
    (let ((n drgnx-cockpit--draws))
      (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
      (drgnx-coord-force-status "jx#4" "running" "s-1")
      (dotimes (_ 5) (drgnx-cockpit--hub-event "job" '(:id "jx")))
      (drgnx-cockpit-schedule)
      (should-not drgnx-cockpit--timer)                        ; nothing on its way
      (should (= n drgnx-cockpit--draws))
      (should (buffer-local-value 'drgnx-cockpit--stale g))
      ;; shown again: it catches up
      (set-window-buffer (selected-window) g)
      (drgnx-cockpit--on-show (selected-window))
      (drgnx-cockpit-graph-test--tick)
      (should (= (1+ n) drgnx-cockpit--draws))
      (should-not (buffer-local-value 'drgnx-cockpit--stale g)))))

(ert-deftest drgnx-cockpit-graph/commands-and-keys-in-every-profile ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (cl-letf (((symbol-function 'drgnx-pane-define-kind) #'ignore))
      (funcall (plist-get (alist-get 'tools/cockpit drgnx-modules--table) :setup)))
    (should (equal (plist-get (alist-get 'tools/cockpit drgnx-modules--table) :requires) '(tools/work tools/jobs)))
    (pcase-dolist (`(,id ,fn) '((cockpit-filter drgnx-cockpit-graph-filter) (cockpit-open drgnx-cockpit-graph-open)
                                (cockpit-open-in-plan drgnx-cockpit-graph-open-in-plan) (cockpit-refresh drgnx-cockpit-graph-refresh)))
      (should (eq (drgnx-cmd-command (drgnx-commands-get id)) fn))
      (should (eq (drgnx-cmd-map (drgnx-commands-get id)) 'drgnx-cockpit-graph-mode-map))))
  ;; Show Work as Graph opens this graph while tools/cockpit runs, the Work tab's older graph without it
  (let ((shown nil))
    (cl-letf (((symbol-function 'drgnx-cockpit-graph-show) (lambda () (push 'cockpit shown)))
              ((symbol-function 'drgnx-work-ui-graph) (lambda () (push 'old shown))))
      (cl-letf (((symbol-function 'drgnx-modules--ok-p) (lambda (m) (eq m 'tools/cockpit)))) (drgnx-work-ui-show-graph))
      (cl-letf (((symbol-function 'drgnx-modules--ok-p) #'ignore)) (drgnx-work-ui-show-graph)))
    (should (equal shown '(old cockpit))))
  (dolist (profile '("vscode" "emacs" "vim"))
    (let ((text (with-temp-buffer (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir)) (buffer-string))))
      (dolist (row '("(cockpit-filter \"f\")" "(cockpit-open \"RET\")" "(cockpit-open-in-plan \"o\")" "(cockpit-refresh \"g\")"
                     "(work-graph "))
        (should (string-search row text))))))

;;; mod-cockpit-graph-test.el ends here
