;;; work-views-test.el --- the Work space's other views: Board, Timeline, the trail and the review view -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The pure tests (selection maps, row text) need no hub; the others run against a real hub as its own process, this
;; Emacs playing the editor inside the delivery gate (`drgnx-test-gated').  The agents behind the views are real
;; children (mock-acp): what they did is a condition the test settles on after each release of the hub's lines, never a
;; deadline.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-hub-client)
(require 'drgnx-keys)
(require 'drgnx-work-client)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/unit/agents-mirror-test" drgnx-dir) nil t)   ; its helpers and the hub fixtures
(load (expand-file-name "test/fixtures/work-space-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/git-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(declare-function drgnx-work-space-open "drgnx-work-space")
(declare-function drgnx-work-board-column "drgnx-work-board")
(declare-function drgnx-work-board-for-selection "drgnx-work-board")
(declare-function drgnx-work-board-to-selection "drgnx-work-board")
(declare-function drgnx-work-board-open "drgnx-work-board")
(declare-function drgnx-work-board-refresh "drgnx-work-board")
(declare-function drgnx-work-board-columns-of "drgnx-work-board")
(defvar drgnx-work-board--cards)
(declare-function drgnx-work-trail-open "drgnx-work-trail")
(declare-function drgnx-work-trail-row-text "drgnx-work-trail")
(declare-function drgnx-work-trail-conclusion-text "drgnx-work-trail")
(declare-function drgnx-work-trail-page-back "drgnx-work-trail")
(declare-function drgnx-work-trail-open-step "drgnx-work-trail")
(declare-function drgnx-work-trail-install "drgnx-work-trail")
(declare-function drgnx-work-trail-lit-steps "drgnx-work-trail")
(declare-function drgnx-work-trail-conclusion-steps "drgnx-work-trail")
(declare-function drgnx-work-trail-step-conclusions "drgnx-work-trail")
(declare-function drgnx-work-trail-pause "drgnx-work-trail")
(declare-function drgnx-work-trail-resume "drgnx-work-trail")
(declare-function drgnx-work-timeline-spans "drgnx-work-trail")
(defvar drgnx-work-trail--steps)
(defvar drgnx-work-trail--keys)
(defvar drgnx-work-trail--lit)
(defvar drgnx-work-trail-first-page)
(defvar drgnx-work-trail-page)
(defvar drgnx-work-trail-time-zone)
(defvar drgnx-work-timeline--sel)

(defvar drgnx-view-old-path)

(defmacro drgnx-work-views-test--with (&rest body)
  "BODY with the module `tools/work-space' set up, a gated hub serving the test's dirs (profile \"mock\"), this Emacs
connected to it, and `workspace' the workspace of the test's home folder."
  (declare (indent 0))
  `(drgnx-test-with-clock (:allow-pending t)
     (drgnx-test-with-modules '(tools/work-space)
       (drgnx-agents-mirror-test--with '()
         (add-hook 'drgnx-hub-event-functions #'drgnx-work-client-event)
         (add-hook 'drgnx-hub-event-functions #'drgnx-work-trail-event)
         (add-hook 'drgnx-hub-disconnect-functions #'drgnx-work-client-disconnected)
         (drgnx-hub-connect)
         (drgnx-agents-mirror-test--settle (lambda () (process-live-p drgnx-hub--events)) "the subscribed connection")
         ;; these tests read the frames this Emacs draws: the old path (the hub's rows: work-map-rows-test.el)
         (let ((drgnx-view-old-path t) (workspace (list :id "workspace:000000000001" :roots (list (getenv "HOME")))))
           ,@body)))))

;;;; Board

(defun drgnx-work-views-test--board-state ()
  "The fixture frame with tasks on its two agents: a1 works on task t1, a2 on task t2."
  (let ((frame (drgnx-work-fixture-frame)))
    (setf (plist-get frame :items)
          (mapcar (lambda (it)
                    (pcase (plist-get it :id)
                      ("agent:a1" (drgnx-work-fixture-changed frame "agent:a1" :task "task:t1"))
                      ("agent:a2" (drgnx-work-fixture-changed frame "agent:a2" :task "task:t2"))
                      (_ it)))
                  (plist-get frame :items)))
    (drgnx-work-client-init frame)))

(defconst drgnx-work-views-test--cards
  '((:id "task:t1" :title "hub rows" :status "running" :plan "plan:deferred" :progress (3 6))
    (:id "task:t2" :title "review item 3" :status "needs-input" :plan "plan:deferred")
    (:id "task:t3" :title "nobody has it" :status "open" :plan "plan:deferred"))
  "Three tasks of the fixture's plan: two with an agent, one with none.")

(ert-deftest drgnx-work-board/selection-maps-both-ways ()
  ;; pattern D: every row of the design's table (8.2), Map to Board and Board to Map
  (let ((s (drgnx-work-views-test--board-state)) (cards drgnx-work-views-test--cards))
    ;; the columns are the tracker's (norn::tracker::board_column)
    (should (equal '(queued running running waiting needs-you review done done queued)
                   (mapcar #'drgnx-work-board-column
                           '("open" "claimed" "running" "waiting" "needs-input" "in-review" "done" "dropped" "blocked"))))
    ;; Map to Board
    (should (equal '(:card "task:t1") (drgnx-work-board-for-selection s cards '(agent . "agent:a1"))))
    (should (equal '(:card "task:t1") (drgnx-work-board-for-selection s cards '(subagent . "agent:a1/t1"))))   ; its parent's
    (should (equal '(:lit ("task:t1" "task:t2")) (drgnx-work-board-for-selection s cards '(file . "file:drgnx/src/session.rs"))))
    (should (equal '(:lit ("task:t1")) (drgnx-work-board-for-selection s cards '(branch . "branch:drgnx/rp-df-hub"))))
    (should (equal '(:lit ("task:t1")) (drgnx-work-board-for-selection s cards '(machine . "machine:desktop"))))
    (dolist (sel '((plan . "plan:deferred") (spec . "spec:race-proof") (ask . "ask:1")))
      (should (equal '(:plans ("plan:deferred")) (drgnx-work-board-for-selection s cards sel))))
    ;; Board to Map: the task's agent's card; none: the plan, which has no agent
    (should (equal '(agent . "agent:a2") (drgnx-work-board-to-selection s cards "task:t2")))
    (should (equal '(plan . "plan:deferred") (drgnx-work-board-to-selection s cards "task:t3")))
    (should-not (drgnx-work-board-to-selection s cards "task:unknown"))))

(defun drgnx-work-views-test--repo ()
  "A git repository with a root commit under the test's home: the project the hub's tasks are made in."
  (let ((dir (expand-file-name "proj/" (getenv "HOME"))))
    (make-directory dir t)
    (drgnx-git-test dir "init" "-q" "-b" "main")
    (drgnx-git-test dir "-c" "user.name=Ada" "-c" "user.email=ada@t.invalid" "commit" "-q" "--allow-empty" "-m" "root")
    dir))

(defun drgnx-work-views-test--create-task (title)
  "A tracker task TITLE made through the hub, in a project of its own; its id."
  (plist-get (drgnx-agents-mirror-test--ask "tasks/write" (list :op "create" :title title
                                                                :cwd (drgnx-work-views-test--repo)))
             :id))

(defun drgnx-work-views-test--card-column (buffer id)
  (when-let* ((card (seq-find (lambda (c) (equal (plist-get c :id) id)) (buffer-local-value 'drgnx-work-board--cards buffer))))
    (drgnx-work-board-column (plist-get card :status))))

(ert-deftest drgnx-work-board/columns-follow-the-tracker ()
  ;; a task the tracker holds shows in the column of its status; when its status changes the board refreshes into
  ;; the next column
  (drgnx-work-views-test--with
    (let* ((id (drgnx-work-views-test--create-task "Alpha")) (map (drgnx-work-space-open workspace t))
           (board (drgnx-work-board-open map)))
      (drgnx-work-board-refresh board)
      (drgnx-agents-mirror-test--settle (lambda () (eq 'queued (drgnx-work-views-test--card-column board id)))
                                        "the new task in the queued column")
      (let* ((found (drgnx-agents-mirror-test--ask "tasks/find" (list :cursor nil)))
             (task (seq-find (lambda (c) (equal (plist-get c :id) id)) (plist-get found :tasks))))
        (drgnx-agents-mirror-test--ask "tasks/write" (list :op "update" :id id :ver (plist-get task :ver) :status "in-review")))
      (drgnx-work-board-refresh board)
      (drgnx-agents-mirror-test--settle (lambda () (eq 'review (drgnx-work-views-test--card-column board id)))
                                        "the task in the review column")
      (should (equal '(review) (mapcar #'car (seq-filter #'cdr (drgnx-work-board-columns-of
                                                                (buffer-local-value 'drgnx-work-board--cards board)))))))))

;;;; Timeline and the research trail

(defun drgnx-work-views-test--flat (s)
  "S as plain text, each character that carries a `display' property (a pixel gap) shown as |."
  (mapconcat (lambda (i) (if (get-text-property i 'display s) "|" (string (aref s i)))) (number-sequence 0 (1- (length s))) ""))

(defconst drgnx-work-views-test--steps
  '((:id 11 :seq 1 :session "s1" :class "tool" :tool "Read" :start 3600.0 :end 3601.5
         :detail (:origin "acp" :kind "read" :path "src/a.rs" :line_start 10 :line_end 14))
    (:id 12 :seq 2 :session "s1" :class "tool" :tool "Grep" :start 3602.0 :end 3602.4
         :detail (:origin "acp" :kind "search" :query "needle"))
    (:id 13 :seq 3 :session "s1" :class "tool" :tool "WebFetch" :start 3603.0 :end 3605.0
         :detail (:origin "acp" :kind "fetch" :url "https://example.test/a" :title "Page"))
    (:id 14 :seq 4 :session "s1" :class "think" :start 3606.0 :end 3611.0)
    (:id 15 :seq 5 :session "s1" :class "tool" :tool "Write" :start 3612.0 :end 3612.2
         :detail (:origin "acp" :kind "edit" :path "src/a.rs")))
  "Five steps of a session: a read with lines, a search, a page with a title, a thought and an edit.")

(defconst drgnx-work-views-test--conclusion
  '(:n 1 :id "decision:1" :kind "decision" :text "use a lock" :at 3613.0 :origin "own" :step 13
       :links (:named (11) :since_last (12 13) :unmatched ((:path "gone.rs"))))
  "A decision resting on the first three steps, one named source of which no step matches.")

(ert-deftest drgnx-work-trail/rows-golden ()
  ;; pattern D: a step's row is its kind's icon, its title, the numbers of the conclusions resting on it, then its time
  ;; and duration at the right (the | is that gap); a conclusion is a card saying what it rests on
  (let ((drgnx-work-trail-time-zone t) (cs (list drgnx-work-views-test--conclusion)))
    (should (equal '("▤ src/a.rs:10–14 [1]|01:00:00 1.5s\n"
                     "⌕ needle [1]|01:00:02 0.4s\n"
                     "◍ example.test · Page [1]|01:00:03 2.0s\n"
                     "… thinking|01:00:06 5.0s\n"
                     "✎ src/a.rs|01:00:12 0.2s\n")
                   (mapcar (lambda (st) (drgnx-work-views-test--flat (drgnx-work-trail-row-text st cs)))
                           drgnx-work-views-test--steps)))
    (should (equal (concat "⚑ 1  use a lock\n"
                           "   based on 3 steps · named, not read in this session: gone.rs\n")
                   (substring-no-properties (drgnx-work-trail-conclusion-text drgnx-work-views-test--conclusion))))))

(ert-deftest drgnx-work-trail/timeline-spans-follow-time ()
  ;; pattern D: a lane's segments sit at their time on the lane's width, at least 2 px wide, by kind
  (should (equal '((1 0 15 read) (2 20 4 search) (3 30 20 web) (4 60 50 thought) (5 120 2 edit))
                 (drgnx-work-timeline-spans drgnx-work-views-test--steps 3600.0 3620.0 200))))

(defun drgnx-work-views-test--steps-of (sid)
  (plist-get (drgnx-agents-mirror-test--ask "timeline/get" (list :scope "session" :id sid)) :steps))

(defun drgnx-work-views-test--agent-with-steps (n)
  "A mock session of the hub that answered N prompts, each with a tool call; its id, once it is idle again."
  (let ((id (plist-get (drgnx-agents-mirror-test--ask "agents/start" (list :profile "mock" :cwd (getenv "HOME"))) :id)))
    (dotimes (i n)
      (drgnx-agents-mirror-test--ask "agents/send" (list :id id :text (format "tool %d" i)))
      (drgnx-agents-mirror-test--settle
       (lambda ()
         (let ((got (drgnx-agents-mirror-test--ask "agents/get" (list :id id))))
           (and (string-search (format "You said: tool %d" i)
                               (mapconcat (lambda (e) (format "%s" (or (plist-get e :text) ""))) (plist-get got :entries) " "))
                (equal "idle" (plist-get (plist-get got :session) :status)))))
       (format "the answer to prompt %d and the session idle" i)))
    id))

(defun drgnx-work-views-test--ids (steps) (mapcar (lambda (s) (plist-get s :id)) steps))

(ert-deftest drgnx-work-trail/opens-with-the-last-screenful ()
  (drgnx-work-views-test--with
    (let* ((sid (drgnx-work-views-test--agent-with-steps 3)) (all (drgnx-work-views-test--steps-of sid))
           (drgnx-work-trail-first-page 2) (map (drgnx-work-space-open workspace t))
           (buf (drgnx-work-trail-open map sid)))
      (should (> (length all) 2))
      (drgnx-agents-mirror-test--settle (lambda () (buffer-local-value 'drgnx-work-trail--steps buf)) "the trail's first steps")
      (should (equal (drgnx-work-views-test--ids (last all 2))
                     (drgnx-work-views-test--ids (buffer-local-value 'drgnx-work-trail--steps buf)))))))

(ert-deftest drgnx-work-trail/pages-back-near-the-top ()
  (drgnx-work-views-test--with
    (let* ((sid (drgnx-work-views-test--agent-with-steps 3)) (all (drgnx-work-views-test--steps-of sid))
           (drgnx-work-trail-first-page 2) (drgnx-work-trail-page 2) (map (drgnx-work-space-open workspace t))
           (buf (drgnx-work-trail-open map sid)))
      (drgnx-agents-mirror-test--settle (lambda () (buffer-local-value 'drgnx-work-trail--steps buf)) "the first screenful")
      (should (= 2 (length (buffer-local-value 'drgnx-work-trail--steps buf))))
      (drgnx-work-trail-page-back buf)
      (drgnx-agents-mirror-test--settle (lambda () (= 4 (length (buffer-local-value 'drgnx-work-trail--steps buf))))
                                        "two steps more, older")
      (should (equal (drgnx-work-views-test--ids (last all 4))
                     (drgnx-work-views-test--ids (buffer-local-value 'drgnx-work-trail--steps buf))))
      ;; the rows are in step order: the older steps came in at the top
      (should (equal (mapcar (lambda (s) (list :step (plist-get s :id))) (last all 4))
                     (seq-filter (lambda (k) (eq (car k) :step)) (buffer-local-value 'drgnx-work-trail--keys buf)))))))

(ert-deftest drgnx-work-trail/appends-live ()
  (drgnx-work-views-test--with
    (let* ((sid (drgnx-work-views-test--agent-with-steps 1)) (map (drgnx-work-space-open workspace t))
           (buf (drgnx-work-trail-open map sid)) (n 0))
      (drgnx-agents-mirror-test--settle (lambda () (setq n (length (buffer-local-value 'drgnx-work-trail--steps buf))) (> n 0))
                                        "the trail's first steps")
      (drgnx-agents-mirror-test--ask "agents/send" (list :id sid :text "tool again"))
      (drgnx-agents-mirror-test--settle
       (lambda () (and (> (length (buffer-local-value 'drgnx-work-trail--steps buf)) n)
                       (equal (drgnx-work-views-test--ids (drgnx-work-views-test--steps-of sid))
                              (drgnx-work-views-test--ids (buffer-local-value 'drgnx-work-trail--steps buf)))))
       "the new steps in the trail, with none twice"))))

(defun drgnx-work-views-test--trail-fixture (&optional conclusions)
  "A trail buffer of session s1 holding the fixture steps and CONCLUSIONS, no hub involved."
  (let ((buf (generate-new-buffer " *work-trail-test*")))
    (with-current-buffer buf
      (drgnx-work-trail-install buf "s1" (copy-tree drgnx-work-views-test--steps) (copy-tree conclusions)))
    buf))

(ert-deftest drgnx-work-trail/l-lights-a-conclusions-steps ()
  ;; pattern D: `l' on a conclusion lights the steps its named sources matched (and those since the last conclusion);
  ;; `L' on a step names the conclusions that rest on it
  (let ((buf (drgnx-work-views-test--trail-fixture (list drgnx-work-views-test--conclusion))))
    (unwind-protect
        (with-current-buffer buf
          (should (equal '(11 12 13) (drgnx-work-trail-conclusion-steps 1)))
          (should (equal '(11) (drgnx-work-trail-conclusion-steps 1 t)))        ; the named ones only
          (drgnx-work-trail-lit-steps 1 t)
          (should (equal '(11) drgnx-work-trail--lit))
          (should (equal '(1) (drgnx-work-trail-step-conclusions 12)))
          (should-not (drgnx-work-trail-step-conclusions 14)))
      (kill-buffer buf))))

(ert-deftest drgnx-work-trail/s-ret-opens-the-file-as-read ()
  ;; a read step's S-RET opens the file as the agent read it, from `work/file-at', in a read-only buffer `file@step-N'
  (let ((buf (drgnx-work-views-test--trail-fixture)) calls opened)
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-hub-call)
                   (lambda (method params callback &rest _)
                     (push (cons method params) calls)
                     (funcall callback (list :bytes (base64-encode-string "one\ntwo\n") :seq 1) nil) 1)))
          (with-current-buffer buf
            (setq opened (drgnx-work-trail-open-step (car drgnx-work-views-test--steps) nil t)))
          (should (equal "work/file-at" (car (car calls))))
          (should (equal '(:session "s1" :path "src/a.rs" :seq 1) (cdr (car calls))))
          (should (equal "a.rs@step-1" (buffer-name opened)))
          (with-current-buffer opened
            (should buffer-read-only)
            (should (equal "one\ntwo\n" (buffer-string)))))
      (when (buffer-live-p opened) (kill-buffer opened))
      (kill-buffer buf))))

(ert-deftest drgnx-work-trail/pause-then-resume-is-labelled ()
  ;; `p' pauses (the hub's cancel-after-tool) and says so; `u' sends a plain continue; the trail labels both
  (drgnx-work-views-test--with
    (let* ((sid (drgnx-work-views-test--agent-with-steps 1)) (map (drgnx-work-space-open workspace t))
           (buf (drgnx-work-trail-open map sid)) calls)
      (drgnx-agents-mirror-test--settle (lambda () (buffer-local-value 'drgnx-work-trail--steps buf)) "the first steps")
      (advice-add 'drgnx-hub-call :before (lambda (method params &rest _) (push (cons method params) calls))
                  '((name . work-views-test-record)))
      (unwind-protect
          (with-current-buffer buf
            (drgnx-work-trail-pause)
            (drgnx-work-trail-resume))
        (advice-remove 'drgnx-hub-call 'work-views-test-record))
      (should (member (cons "agents/pause" (list :id sid)) calls))
      (should (member (cons "agents/send" (list :id sid :text "Continue.")) calls))
      (let ((text (with-current-buffer buf (progn (drgnx-view-draw-now drgnx-view) (buffer-string)))))
        (should (string-search "paused by you" text))
        (should (string-search "resumed by you" text))
        (should (< (string-search "paused by you" text) (string-search "resumed by you" text)))))))

;;;; The review view, the merge queue and the second reviewer

(declare-function drgnx-work-review-install "drgnx-work-review")
(declare-function drgnx-work-review-decision-text "drgnx-work-review")
(declare-function drgnx-work-review--accept "drgnx-work-review")
(declare-function drgnx-work-review--reject "drgnx-work-review")
(declare-function drgnx-work-review-second "drgnx-work-review")
(declare-function drgnx-work-map--chip-line "drgnx-work-map")
(declare-function drgnx-work-detail-sections "drgnx-work-detail")
(declare-function drgnx-keys-load-profiles "drgnx-keys")
(defvar drgnx-work-review--keys)
(defvar drgnx-work-lens--map)

(defconst drgnx-work-views-test--decisions
  '((:n 1 :id "decision:1" :kind "decision" :text "keep the lock" :origin "own" :at 1.0 :links nil)
    (:n 2 :id "decision:2" :kind "decision" :text "use SQLite" :origin "from-brief" :at 2.0 :links nil)
    (:n 3 :id "decision:3" :kind "decision" :text "drop the cache?" :origin "needs-user" :at 3.0 :links nil)
    (:n 4 :id "note:9" :kind "finding" :text "the cache is unused" :origin "own" :at 4.0 :links nil))
  "Three decisions of three origins, made in the order own, from the brief, needs your call; and a finding.")

(defconst drgnx-work-views-test--diff
  "--- a/src/a.rs\n+++ b/src/a.rs\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n@@ -9,1 +9,2 @@\n tail\n+more\n")

(ert-deftest drgnx-work-review/decisions-first-with-computed-dependents ()
  ;; pattern D: the review lists the decisions before the work, those from the brief first, then its own, then those
  ;; that need you; each says what git computed of it, and a finding is not a decision
  (let ((buf (generate-new-buffer " *work-review-test*")))
    (unwind-protect
        (with-current-buffer buf
          (drgnx-work-review-install
           buf "s1" :decisions drgnx-work-views-test--decisions
           :effects '(("decision:1" . (:decision "decision:1" :label "computed" :commits ("abc1234def")
                                                 :later_hunks ((:commit "9f3e1c2aa" :path "src/a.rs" :lines (10 20))))))
           :files '((:path "src/a.rs" :plus 2 :minus 1 :untracked nil))
           :diffs (list (cons "src/a.rs" drgnx-work-views-test--diff)))
          (should (equal '((:decisions) (:decision 2) (:decision 1) (:decision 3) (:summary) (:files)
                           (:file "src/a.rs") (:hunk "src/a.rs" 0) (:hunk "src/a.rs" 1))
                         drgnx-work-review--keys))
          (let ((text (substring-no-properties
                       (drgnx-work-review-decision-text (nth 0 drgnx-work-views-test--decisions)
                                                        (cdr (assoc "decision:1" '(("decision:1" . (:commits ("abc1234def")
                                                                                                             :later_hunks ((:commit "9f3e1c2aa" :path "src/a.rs" :lines (10 20))))))))))))
            (should (string-search "computed: 1 commit (abc1234)" text))
            (should (string-search "1 later hunk overlaps: src/a.rs:10–20 (9f3e1c2)" text))))
      (kill-buffer buf))))

(defmacro drgnx-work-views-test--calls (&rest body)
  "BODY with every call of the hub recorded, not made: `calls', newest first, of (METHOD . PARAMS)."
  (declare (indent 0))
  `(let (calls)
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params &rest _) (push (cons method params) calls) 1)))
       ,@body)
     calls))

(ert-deftest drgnx-work-review/hunk-reject-is-D ()
  ;; `a' accepts and `D' rejects, in every profile; a rejection marks the file pending and tells the agent, queued
  (let ((profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))))
    (dolist (p profiles)
      (let ((rows (plist-get (cdr p) :bind)))
        (should (member "D" (flatten-tree (assq 'work-review-reject rows))))
        (should (member "a" (flatten-tree (assq 'work-review-accept rows)))))))
  (let ((buf (generate-new-buffer " *work-review-test*")))
    (unwind-protect
        (with-current-buffer buf
          (drgnx-work-review-install buf "s1" :files '((:path "src/a.rs" :plus 2 :minus 1 :untracked nil))
                                     :diffs (list (cons "src/a.rs" drgnx-work-views-test--diff)))
          (let ((calls (drgnx-work-views-test--calls (drgnx-work-review--reject "src/a.rs" 1))))
            (should (= 2 (length calls)))
            (let ((mark (cdr (assoc "review/mark" calls))) (send (cdr (assoc "agents/send" calls))))
              (should (equal '("s1" "src/a.rs" "pending") (list (plist-get mark :agent) (plist-get mark :path) (plist-get mark :state))))
              (should (equal "s1" (plist-get send :id)))
              (should (string-search "src/a.rs" (plist-get send :text)))
              (should (string-search "@@ -9,1 +9,2 @@" (plist-get send :text)))))
          (let* ((calls (drgnx-work-views-test--calls (drgnx-work-review--accept "src/a.rs")))
                 (mark (cdr (assoc "review/mark" calls))))
            (should (equal "accepted" (plist-get mark :state)))
            (should (equal (secure-hash 'sha1 drgnx-work-views-test--diff) (plist-get mark :hash)))
            (should (equal "accept" (plist-get (plist-get mark :event) :kind)))))
      (kill-buffer buf))))

(ert-deftest drgnx-work-review/v-goes-through-propose ()
  ;; the second reviewer is a proposed job, never an agent started on the spot; its plan names the files and holds none of
  ;; the author's conclusions
  (let ((buf (generate-new-buffer " *work-review-test*")) file)
    (unwind-protect
        (with-current-buffer buf
          (drgnx-work-review-install buf "s1" :decisions drgnx-work-views-test--decisions
                                     :files '((:path "src/a.rs" :plus 2 :minus 1 :untracked nil))
                                     :diffs (list (cons "src/a.rs" drgnx-work-views-test--diff)))
          (setq default-directory temporary-file-directory)
          (let ((calls (drgnx-work-views-test--calls (drgnx-work-review-second))))
            (should (equal '("job/propose") (mapcar #'car calls)))
            (setq file (plist-get (cdr (car calls)) :plan))
            (should (file-name-absolute-p file))
            (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
              (should (string-search "**Role:** review" text))
              (should (string-search "src/a.rs" text))
              (dolist (c drgnx-work-views-test--decisions)
                (should-not (string-search (plist-get c :text) text))))))
      (when (and file (file-exists-p file)) (delete-file file))
      (kill-buffer buf))))

(ert-deftest drgnx-work-review/merge-queue-chip ()
  ;; a queued branch says where it stands in the queue and what it conflicts with; the integration branch's panel too.
  ;; Only what the hub sent shows: a branch with no queue fields has no chip
  (let* ((frame (drgnx-work-fixture-frame))
         (queued (drgnx-work-fixture-changed frame "branch:drgnx/rp-df-hub" :queue '(2 3) :conflicts '("rp-x")))
         (plain (drgnx-work-fixture-item frame "branch:drgnx/rp-fx-sess")))
    (let ((line (substring-no-properties (drgnx-work-map--chip-line queued))))
      (should (string-search "queue 2/3" line))
      (should (string-search "conflicts with rp-x" line)))
    (should-not (string-search "queue" (drgnx-work-map--chip-line plain)))
    (setf (plist-get frame :items) (mapcar (lambda (it) (if (equal (plist-get it :id) "branch:drgnx/rp-df-hub") queued it))
                                           (plist-get frame :items)))
    (let* ((state (drgnx-work-client-init frame))
           (sections (drgnx-work-detail-sections state '(branch . "branch:drgnx/rp-df-hub"))))
      (should (string-search "2 of 3" (cdr (assq :queue sections))))
      (should (string-search "rp-x" (cdr (assq :queue sections)))))
    (should-not (assq :queue (drgnx-work-detail-sections (drgnx-work-client-init (drgnx-work-fixture-frame))
                                                         '(branch . "branch:drgnx/rp-df-hub"))))))

(provide 'work-views-test)
;;; work-views-test.el ends here
