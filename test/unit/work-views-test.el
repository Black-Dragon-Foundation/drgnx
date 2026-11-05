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

(defmacro drgnx-work-views-test--with (&rest body)
  "BODY with the module `tools/work-space' set up, a gated hub serving the test's dirs (profile \"mock\"), this Emacs
connected to it, and `workspace' the workspace of the test's home folder."
  (declare (indent 0))
  `(drgnx-test-with-clock (:allow-pending t)
     (drgnx-test-with-modules '(tools/work-space)
       (drgnx-agents-mirror-test--with '()
         (add-hook 'drgnx-hub-event-functions #'drgnx-work-client-event)
         (add-hook 'drgnx-hub-disconnect-functions #'drgnx-work-client-disconnected)
         (drgnx-hub-connect)
         (drgnx-agents-mirror-test--settle (lambda () (process-live-p drgnx-hub--events)) "the subscribed connection")
         (let ((workspace (list :id "workspace:000000000001" :roots (list (getenv "HOME")))))
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

(provide 'work-views-test)
;;; work-views-test.el ends here
