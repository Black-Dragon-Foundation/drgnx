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
     (let ((drgnx-cockpit-graph-current-filter nil) (drgnx-cockpit--draws 0) (drgnx-cockpit--timer nil)
           (drgnx-cockpit--check-timer nil) (drgnx-cockpit--last-error nil)
           ;; no search for silent worktrees unless a test asks for one
           (drgnx-cockpit--silent nil) (drgnx-cockpit--silent-n 0) (drgnx-cockpit--silent-at (float-time))
           (drgnx-cockpit--silent-running nil)
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
             (should-not (timerp drgnx-cockpit--check-timer))       ; the buffer owned it
             (drgnx-cockpit-fixture-wait (lambda () (not drgnx-cockpit--silent-running)))
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
        (should (string-search "T3 task 3  waits on you · pending" t3)))          ; first: a cut line keeps it
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
      ;; the job's edge to its plan, past the tasks' column, is not drawn (behind a task it seemed to come out of it):
      ;; every line drawn joins neighbouring columns or two tasks
      (let* ((svg (drgnx-cockpit-graph-svg layout))
             (drawn (cl-loop with start = 0 while (string-match "<path " svg start) count t do (setq start (match-end 0))))
             (adjacent (seq-count (lambda (e) (and (not (eq (plist-get e :kind) 'blocks))
                                                   (<= (abs (- (plist-get (drgnx-cockpit-graph-test--box layout (plist-get e :from)) :col)
                                                               (plist-get (drgnx-cockpit-graph-test--box layout (plist-get e :to)) :col)))
                                                       1)))
                                  (plist-get layout :edges))))
        (should (seq-find (lambda (e) (equal (plist-get e :from) "job:jx")) (plist-get layout :edges)))   ; in the layout
        (should (= drawn adjacent)))
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
        (should (re-search-forward "^AGENTS" nil t))
        ;; hovering a waiting node shows the open question's first line
        (drgnx-cockpit-graph-test--goto (format "task:%s#3" plan))
        (should (equal (get-text-property (point) 'help-echo) "Pick a name"))
        (drgnx-cockpit-graph-test--goto "agent:s-1")
        (should (equal (get-text-property (point) 'help-echo) "which way?")))
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
      (should-not (buffer-local-value 'drgnx-cockpit--stale g))
      (drgnx-cockpit--on-show (selected-window))                ; shown again, nothing missed: nothing to do
      (should-not drgnx-cockpit--timer)
      ;; a redraw on its way when the graph is hidden draws nothing: it only notes the graph is stale
      (drgnx-coord-force-status "jx#4" "done" "s-1")
      (drgnx-cockpit-schedule)
      (should (timerp drgnx-cockpit--timer))
      (set-window-buffer (selected-window) (get-buffer "*scratch*"))
      (drgnx-cockpit-graph-test--tick)
      (should (= (1+ n) drgnx-cockpit--draws))
      (should (buffer-local-value 'drgnx-cockpit--stale g)))))

(ert-deftest drgnx-cockpit-graph/commands-and-keys-in-every-profile ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (cl-letf (((symbol-function 'drgnx-pane-define-kind) #'ignore))
      (funcall (plist-get (alist-get 'tools/cockpit drgnx-modules--table) :setup)))
    (should (equal (plist-get (alist-get 'tools/cockpit drgnx-modules--table) :requires) '(tools/work tools/jobs)))
    (pcase-dolist (`(,id ,fn) '((cockpit-filter drgnx-cockpit-graph-filter) (cockpit-open drgnx-cockpit-graph-open)
                                (cockpit-open-in-plan drgnx-cockpit-graph-open-in-plan) (cockpit-refresh drgnx-cockpit-graph-refresh)
                                (cockpit-next drgnx-cockpit-graph-select-next) (cockpit-previous drgnx-cockpit-graph-select-previous)))
      (should (eq (drgnx-cmd-command (drgnx-commands-get id)) fn))
      (should (eq (drgnx-cmd-map (drgnx-commands-get id)) 'drgnx-cockpit-graph-mode-map))))
  ;; Show Work as Graph opens this graph while tools/cockpit runs, the Work tab's older graph without it
  (let ((shown nil))
    (cl-letf (((symbol-function 'drgnx-cockpit-graph-show) (lambda () (push 'cockpit shown)))
              ((symbol-function 'drgnx-work-ui-graph) (lambda () (push 'old shown))))
      (cl-letf (((symbol-function 'drgnx-module-running-p) (lambda (m) (eq m 'tools/cockpit)))) (drgnx-work-ui-show-graph))
      (cl-letf (((symbol-function 'drgnx-module-running-p) #'ignore)) (drgnx-work-ui-show-graph)))
    (should (equal shown '(old cockpit))))
  (dolist (profile '("vscode" "emacs" "vim"))
    (let ((text (with-temp-buffer (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir)) (buffer-string))))
      (dolist (row (append '("(cockpit-filter \"f\")" "(cockpit-open \"RET\")" "(cockpit-open-in-plan \"o\")" "(cockpit-refresh \"g\")"
                             "(work-graph ")
                           (if (equal profile "vim") '("(cockpit-next \"TAB\" \"n\")" "(cockpit-previous \"<backtab>\" \"p\")")
                             '("(cockpit-next \"TAB\")" "(cockpit-previous \"<backtab>\")"))))
        (should (string-search row text))))))

(defmacro drgnx-cockpit-graph-test--drawn (&rest body)
  "BODY with the graph's windows graphical and wide enough for the drawing (skipped without SVG support)."
  (declare (indent 0))
  `(progn
     (unless (image-type-available-p 'svg) (ert-skip "this Emacs has no SVG support"))
     (cl-letf (((symbol-function 'display-images-p) #'always) ((symbol-function 'window-body-width) (lambda (&rest _) 5000)))
       ,@body)))

(ert-deftest drgnx-cockpit-graph/options-and-fonts-reach-the-drawing ()
  (drgnx-cockpit-graph-test--with
    (drgnx-cockpit-graph-test--drawn
      (let ((cols drgnx-cockpit-graph-columns) (layout (lambda () (buffer-local-value 'drgnx-cockpit--layout g))))
        (unwind-protect
            (progn
              (drgnx-cockpit-graph-redraw)
              (should (= 4 (length (plist-get (funcall layout) :titles))))
              ;; an option changed while the drawing shows: its setter asks for a redraw, which lays it out again
              (customize-set-variable 'drgnx-cockpit-graph-columns '((spec plan task todo) (agent job review)))
              (drgnx-cockpit-graph-test--tick)
              (should (= 2 (length (plist-get (funcall layout) :titles))))
              (should (equal '(0 1) (sort (delete-dups (mapcar (lambda (b) (plist-get b :col)) (plist-get (funcall layout) :boxes))) #'<)))
              ;; another font: measured again on the next redraw
              (cl-letf (((symbol-function 'drgnx-work-ui--metrics) (lambda () '(11 . 23))))
                (drgnx-cockpit-schedule)
                (drgnx-cockpit-graph-test--tick)
                (should (equal '(11 . 23) (plist-get (funcall layout) :metrics)))))
          (customize-set-variable 'drgnx-cockpit-graph-columns cols))))))

(ert-deftest drgnx-cockpit-graph/old-band-images-are-flushed ()
  (drgnx-cockpit-graph-test--with
    (drgnx-cockpit-graph-test--drawn
      (let ((images (lambda () (mapcar (lambda (b) (nth 2 b)) (buffer-local-value 'drgnx-cockpit--bands g))))
            (flushed nil))
        (drgnx-cockpit-graph-redraw t)
        (let ((old (funcall images)))
          (should old)
          (cl-letf (((symbol-function 'image-flush) (lambda (img &rest _) (push img flushed))))
            ;; drawn the same again: its cached pixels serve the new image, nothing is flushed
            (drgnx-cockpit-graph-redraw t)
            (should-not flushed)
            ;; a change: the old band's pixels go
            (setq old (funcall images))
            (drgnx-coord-force-status "jx#4" "running" "s-1")
            (drgnx-cockpit-graph-redraw)
            (dolist (i old) (should (memq i flushed)))
            ;; a change that moves no box (running → claimed, as long): the buffer's text stays, the band gets its
            ;; new drawing in place, its old pixels flushed first
            (let ((tick (with-current-buffer g (buffer-modified-tick))) (img (car (funcall images))))
              (setq flushed nil)
              (let ((data (image-property img :data)))
                (drgnx-coord-force-status "jx#4" "claimed" "s-1")
                (drgnx-cockpit-graph-redraw)
                (should (= tick (with-current-buffer g (buffer-modified-tick))))
                (should (eq img (car (funcall images))))
                (should (memq img flushed))
                (should-not (equal data (image-property img :data)))))
            ;; the outline instead: the drawing's images go too
            (setq old (funcall images) flushed nil)
            (let ((drgnx-cockpit-graph-svg nil)) (drgnx-cockpit-graph-redraw t))
            (dolist (i old) (should (memq i flushed)))
            (should-not (funcall images))))))))

(ert-deftest drgnx-cockpit-graph/nothing-changed-builds-no-model ()
  (drgnx-cockpit-graph-test--with
    (drgnx-cockpit-graph-redraw)
    (let* ((built 0) (orig (symbol-function 'drgnx-cockpit-model)))
      (cl-letf (((symbol-function 'drgnx-cockpit-model) (lambda (&rest args) (cl-incf built) (apply orig args))))
        ;; events, nothing written: the key is the same, no model is built
        (dotimes (_ 5) (drgnx-cockpit--hub-event "job" '(:id "jx")) (drgnx-cockpit-graph-test--tick))
        (should (= 0 built))
        (let ((t0 (float-time)))
          (dotimes (_ 100) (drgnx-cockpit-graph-redraw))
          (should (< (/ (- (float-time) t0) 100) 0.002)))                ; about 30 µs; loose for a loaded machine
        (should (= 0 built))
        ;; this Emacs writes the store: one build, one draw
        (drgnx-coord-force-status "jx#4" "running" "s-1")
        (drgnx-cockpit-schedule)
        (drgnx-cockpit-graph-test--tick)
        (should (= 1 built))))))

(ert-deftest drgnx-cockpit-graph/writes-of-other-processes-show ()
  (drgnx-cockpit-graph-test--with
    (drgnx-cockpit-graph-redraw)
    (should (timerp drgnx-cockpit--check-timer))                       ; started with the buffer
    (drgnx-cockpit--check)
    (should-not drgnx-cockpit--timer)                                   ; nothing written: nothing to do
    ;; another process (a second connection) writes the store
    (let ((db2 (sqlite-open (drgnx-work-db-file))))
      (unwind-protect (sqlite-execute db2 "update jtask set status = 'running' where id = 'jx#4'")
        (sqlite-close db2)))
    (drgnx-cockpit--check)
    (drgnx-cockpit--check)
    (should (timerp drgnx-cockpit--timer))                              ; one redraw on its way
    (let ((n drgnx-cockpit--draws))
      (drgnx-cockpit-graph-test--tick)
      (should (= (1+ n) drgnx-cockpit--draws)))
    (with-current-buffer g (drgnx-cockpit-graph-test--goto (format "task:%s#4" plan)) (should (looking-at ".*running")))
    (drgnx-cockpit--check)
    (should-not drgnx-cockpit--timer)))

(ert-deftest drgnx-cockpit-graph/silent-worktrees-show-as-not-reporting ()
  (drgnx-cockpit-graph-test--with
    ;; roots: jobs' repos and registered agents' folders; a remote one (a job's, an agent's) is never asked whether
    ;; it is a folder
    (drgnx-coord-job-create :id "jr" :title "remote" :repo "/ssh:nowhere.invalid:/r/" :tasks '((:n 1 :title "t" :role "implement")))
    (drgnx-coord-agent-register :id "ext:far:1" :kind "far" :cwd "/ssh:nowhere.invalid:/w" :worktree "/ssh:nowhere.invalid:/w")
    (let ((asked nil) (orig (symbol-function 'file-directory-p)))
      (cl-letf (((symbol-function 'file-directory-p) (lambda (f) (push f asked) (funcall orig f))))
        (should (equal (sort (drgnx-cockpit--roots) #'string<) (sort (list repo wt-a) #'string<))))
      (should-not (seq-find (lambda (f) (string-prefix-p "/ssh:" f)) asked)))
    ;; of the two worktrees, wt-a has an agent: only wt-b is silent (once, though two roots list it)
    (drgnx-cockpit--silent-scan t)
    (should (drgnx-cockpit-fixture-wait (lambda () (not drgnx-cockpit--silent-running))))
    (should (equal (mapcar (lambda (a) (plist-get a :worktree)) drgnx-cockpit--silent) (list wt-b)))
    (drgnx-cockpit-graph-test--tick)
    (with-current-buffer g
      (drgnx-cockpit-graph-test--goto (concat "agent:silent:" (directory-file-name wt-b)))
      (should (looking-at ".*wt-b +silent.*not reporting"))
      (should-not (text-property-any (point-min) (point-max) 'drgnx-cockpit-node (concat "agent:silent:" (directory-file-name wt-a)))))
    ;; not again before `drgnx-cockpit-silent-interval'
    (drgnx-cockpit--silent-scan)
    (should-not drgnx-cockpit--silent-running)))

(ert-deftest drgnx-cockpit-graph/keyboard-selects-in-column-order ()
  (drgnx-cockpit-graph-test--with
    ;; the outline: TAB to the next node's line (a task's needs and blocks lines are its own)
    (drgnx-cockpit-graph-redraw t)
    (with-selected-window (get-buffer-window g)
      (goto-char (point-min))
      (drgnx-cockpit-graph-select-next)
      (should (equal (get-text-property (point) 'drgnx-cockpit-node) (concat "spec:" spec)))
      (drgnx-cockpit-graph-select-next 4)                               ; plan, T1, T2, then T3 (T2's blocks line skipped)
      (should (equal (get-text-property (point) 'drgnx-cockpit-node) (format "task:%s#3" plan)))
      (drgnx-cockpit-graph-select-previous)
      (should (equal (get-text-property (point) 'drgnx-cockpit-node) (format "task:%s#2" plan))))
    ;; the drawing: boxes in column order, the focus stroke drawn again in its band only, RET opens the selection
    (drgnx-cockpit-graph-test--drawn
      (drgnx-cockpit-graph-redraw t)
      (let ((old (face-attribute 'drgnx-cockpit-focus :background)) (msg nil))
        (unwind-protect
            (with-selected-window (get-buffer-window g)
              (set-face-attribute 'drgnx-cockpit-focus nil :background "#00ee00")
              (setq drgnx-cockpit--selected nil)
              (let ((img (nth 2 (car drgnx-cockpit--bands))) (tick (buffer-modified-tick)))
                (should-not (string-search "#00ee00" (image-property img :data)))
                (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
                  (drgnx-cockpit-graph-select-next))
                (should (equal drgnx-cockpit--selected (concat "spec:" spec)))
                (should (string-prefix-p "Spec: The spec" msg))
                (should (eq img (nth 2 (car drgnx-cockpit--bands))))             ; the same image, its pixels again
                (should (string-search "stroke=\"#00ee00\"" (image-property img :data)))
                (should (= tick (buffer-modified-tick))))                         ; the buffer's text untouched
              (drgnx-cockpit-graph-select-next)
              (should (equal drgnx-cockpit--selected (concat "plan:" plan)))
              (drgnx-cockpit-graph-select-next)
              (should (equal drgnx-cockpit--selected (format "task:%s#1" plan)))    ; the tasks' column, top first
              (drgnx-cockpit-graph-select-previous 2)
              (should (equal drgnx-cockpit--selected (concat "spec:" spec)))
              ;; RET opens the selection: no completion asked
              (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (error "Asked"))))
                (call-interactively #'drgnx-cockpit-graph-open))
              (should (get-buffer-window (get-file-buffer spec))))
          (set-face-attribute 'drgnx-cockpit-focus nil :background old))))))

(ert-deftest drgnx-cockpit-graph/streaming-builds-no-model ()
  (drgnx-cockpit-graph-test--with
    (drgnx-cockpit-graph-redraw)
    (let* ((built 0) (orig (symbol-function 'drgnx-cockpit-model)))
      (cl-letf (((symbol-function 'drgnx-cockpit-model) (lambda (&rest args) (cl-incf built) (apply orig args))))
        ;; an agent streams: every chunk runs the changed hook, nothing the model reads changes
        (dotimes (_ 5) (drgnx-cockpit--agent-changed nil) (drgnx-cockpit-graph-test--tick))
        (should (= 0 built))
        ;; its status changes: one model
        (setq sessions (cons (plist-put (copy-sequence (car sessions)) :status 'busy) (cdr sessions)))
        (drgnx-cockpit--agent-changed nil)
        (drgnx-cockpit-graph-test--tick)
        (should (= 1 built))
        ;; done jobs shown or not: another model
        (let ((drgnx-cockpit-include-closed-jobs t))
          (drgnx-cockpit-schedule)
          (drgnx-cockpit-graph-test--tick)
          (should (= 2 built)))))))

(ert-deftest drgnx-cockpit-graph/a-theme-redraws ()
  (drgnx-cockpit-graph-test--with
    (drgnx-cockpit-graph-redraw)
    (should (memq #'drgnx-cockpit--theme-changed enable-theme-functions))
    (let ((n drgnx-cockpit--draws))
      (drgnx-cockpit--theme-changed 'some-theme)
      (drgnx-cockpit-graph-test--tick)
      (should (= (1+ n) drgnx-cockpit--draws)))))

(ert-deftest drgnx-cockpit-graph/the-drawing-tells-the-question-and-keeps-the-selection ()
  (drgnx-cockpit-graph-test--with
    (drgnx-cockpit-graph-test--drawn
      (let ((drgnx-cockpit-graph-band-height 100) (old (face-attribute 'drgnx-cockpit-focus :background))
            (t2 (format "task:%s#2" plan)) (t3 (format "task:%s#3" plan)))
        (unwind-protect
            (with-current-buffer g
              (set-face-attribute 'drgnx-cockpit-focus nil :background "#00ee00")
              (drgnx-cockpit-graph-redraw t)
              (should (> (length drgnx-cockpit--bands) 2))
              ;; hovering T3's box tells the open question
              (let ((area (car (rassoc t3 drgnx-cockpit--spots))))
                (should (seq-some (lambda (b) (seq-some (lambda (spot) (and (eq (nth 1 spot) area)
                                                                            (string-search "Pick a name" (plist-get (nth 2 spot) 'help-echo))))
                                                        (image-property (nth 2 b) :map)))
                                  drgnx-cockpit--bands)))
              ;; TAB: only the bands the focus stroke reaches are drawn again
              (let ((before (mapcar (lambda (b) (image-property (nth 2 b) :data)) drgnx-cockpit--bands)))
                (with-selected-window (get-buffer-window g) (drgnx-cockpit-graph-select-next))
                (let* ((e (drgnx-cockpit-graph-focus-element drgnx-cockpit--layout drgnx-cockpit--selected))
                       (changed (cl-loop for b in drgnx-cockpit--bands for d in before
                                         unless (equal d (image-property (nth 2 b) :data)) collect b)))
                  (should changed)
                  (should (< (length changed) (length drgnx-cockpit--bands)))
                  (dolist (b changed) (should (and (<= (car e) (+ (car b) (cadr b))) (>= (cadr e) (car b)))))))
              ;; a model change keeps the selection, and its stroke
              (drgnx-cockpit--focus t2)
              (drgnx-coord-force-status "jx#4" "running" "s-1")
              (drgnx-cockpit-graph-redraw)
              (should (equal drgnx-cockpit--selected t2))
              (should (seq-some (lambda (b) (string-search "#00ee00" (image-property (nth 2 b) :data))) drgnx-cockpit--bands)))
          (set-face-attribute 'drgnx-cockpit-focus nil :background old))))))

(ert-deftest drgnx-cockpit-graph/the-focus-stroke-stands-out ()
  (let ((saved (list (face-attribute 'default :background) (face-attribute 'default :foreground)
                     (face-attribute 'drgnx-cockpit-focus :background))))
    (unwind-protect
        (progn
          (set-face-attribute 'default nil :background "#ffffff" :foreground "#101010")
          ;; a pale highlight on a light background (under 3:1): the text colour instead
          (set-face-attribute 'drgnx-cockpit-focus nil :background "#eeeeee")
          (should (< (drgnx-cockpit-graph--contrast "#eeeeee" "#ffffff") 3))
          (should (equal (drgnx-cockpit-graph--focus-colour) "#101010"))
          ;; one that stands out: itself
          (set-face-attribute 'drgnx-cockpit-focus nil :background "#0000ff")
          (should (equal (drgnx-cockpit-graph--focus-colour) "#0000ff")))
      (ignore-errors (set-face-attribute 'default nil :background (nth 0 saved) :foreground (nth 1 saved)))
      (ignore-errors (set-face-attribute 'drgnx-cockpit-focus nil :background (nth 2 saved))))))

;;; mod-cockpit-graph-test.el ends here
