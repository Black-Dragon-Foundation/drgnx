;;; job-clash-review-test.el --- batch tests: a reviewer per clash recommends; the user's choice is a decision -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/job-fixture" drgnx-dir) nil t)   ; a repo, the hub, mock agents
(require 'drgnx-job-clash)

(defmacro drgnx-job-clash-review-test--clash (&rest body)
  "BODY with a running two-task job ID (nothing started by itself), agents s-a (task 1) and s-b (task 2) having
decided build / won't build on one subject (decisions A-N and B-N), the clash scanned: CARD its id."
  (declare (indent 0))
  `(drgnx-job-run-test--with "# Two\n\n### Task 1: one\n\n### Task 2: two\n"
     (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan)) a-n b-n card)
       (drgnx-job-approve id)
       (drgnx-coord-force-status (concat id "#1") "running" "s-a")
       (drgnx-coord-force-status (concat id "#2") "running" "s-b")
       (setq a-n (plist-get (drgnx-coord-decide :kind "build" :subject "the CSV export" :author "s-a" :task (concat id "#1") :job id
                                                :reason "users asked" :seen (drgnx-coord-version))
                            :n)
             b-n (plist-get (drgnx-coord-decide :kind "wont-build" :subject "the csv export" :author "s-b" :task (concat id "#2") :job id
                                                :reason "out of scope" :seen (drgnx-coord-version))
                            :n))
       (drgnx-job-clash-scan id)
       (setq card (plist-get (car (drgnx-coord-cards id "open")) :id))
       ,@body)))

(defun drgnx-job-clash-review-test--recommendation (card)
  (plist-get (plist-get (drgnx-coord-card card) :data) :recommendation))

(defun drgnx-job-clash-review-test--status (id n)
  (plist-get (seq-find (lambda (d) (eql (plist-get d :n) n)) (drgnx-coord-decisions-since 0 id)) :status))

(ert-deftest drgnx-job-clash/a-reviewer-recommends-and-the-card-says-so ()
  (drgnx-job-clash-review-test--clash
    (should (drgnx-job-run-test--wait (lambda () (drgnx-job-clash-review-test--recommendation card)) 15))
    (should (equal (drgnx-job-clash-review-test--recommendation card) '(:side "A" :why "because it was first")))
    (should (equal (plist-get (drgnx-coord-card card) :state) "open"))))          ; the user decides

(ert-deftest drgnx-job-clash/accepting-replaces-the-other-side-and-every-agent-hears ()
  (drgnx-job-clash-review-test--clash
    (let ((x (drgnx-agents-start "mock" repo nil id)) (y (drgnx-agents-start "mock" repo nil id)))
      (drgnx-job-run-test--wait (lambda () (and (eq (drgnx-agent-session-status x) 'idle) (eq (drgnx-agent-session-status y) 'idle))))
      (should (drgnx-job-run-test--wait (lambda () (drgnx-job-clash-review-test--recommendation card)) 15))
      (drgnx-job-card-act card "accept")
      (should (equal (drgnx-job-clash-review-test--status id b-n) "replaced"))
      (should (equal (drgnx-job-clash-review-test--status id a-n) "current"))
      (should (seq-find (lambda (d) (and (equal (plist-get d :author) "user") (eql (plist-get d :replaces) b-n))) (drgnx-coord-decisions-since 0 id)))
      (should (equal (plist-get (drgnx-coord-card card) :state) "settled"))
      ;; both agents of the job are told (delivery: the log moved)
      (should (drgnx-job-run-test--wait
               (lambda () (seq-every-p (lambda (s) (string-search (format "#%d" b-n) (format "%S" (drgnx-agent-session-entries s))))
                                       (list x y)))
               15)))))

(ert-deftest drgnx-job-clash/picking-the-other-side ()
  (drgnx-job-clash-review-test--clash
    (drgnx-job-card-act card "pick-b")
    (should (equal (drgnx-job-clash-review-test--status id a-n) "replaced"))
    (should (equal (drgnx-job-clash-review-test--status id b-n) "current"))))

(ert-deftest drgnx-job-clash/accepting-needs-a-recommendation ()
  (let ((process-environment (cons "MOCK_ACP_RECOMMEND=neither: both are fine" process-environment)))
    (drgnx-job-clash-review-test--clash
      (should (drgnx-job-run-test--wait (lambda () (drgnx-job-clash-review-test--recommendation card)) 15))
      (should (equal (drgnx-job-clash-review-test--recommendation card) '(:side nil :why "both are fine because it was first")))
      (should-error (drgnx-job-card-act card "accept"))                          ; no side to accept
      (should (equal (plist-get (drgnx-coord-card card) :state) "open")))))

(ert-deftest drgnx-job-clash/the-card-names-its-reviewer ()
  (drgnx-job-clash-review-test--clash
    (let ((r (drgnx-job-clash--reviewer card)))
      (should r)
      (should (equal (plist-get (plist-get (drgnx-coord-card card) :data) :reviewer) (drgnx-agent-session-id r))))))

(ert-deftest drgnx-job-clash/accept-is-offered-only-with-a-side-to-accept ()
  (let ((actions (lambda (card) (mapcar #'car (drgnx-job-card-actions (drgnx-coord-card card))))))
    (drgnx-job-clash-review-test--clash
      (should-not (member "accept" (funcall actions card)))                        ; no recommendation yet
      (should (member "pick-a" (funcall actions card)))
      (should (drgnx-job-run-test--wait (lambda () (drgnx-job-clash-review-test--recommendation card)) 15))
      (should (member "accept" (funcall actions card))))                           ; side A
    (let ((process-environment (cons "MOCK_ACP_RECOMMEND=neither: both are fine" process-environment)))
      (drgnx-job-clash-review-test--clash
        (should (drgnx-job-run-test--wait (lambda () (drgnx-job-clash-review-test--recommendation card)) 15))
        (should-not (member "accept" (funcall actions card)))))                    ; neither
    (let ((process-environment (cons "MOCK_ACP_RECOMMEND=maybe" process-environment)))
      (drgnx-job-clash-review-test--clash
        (should (drgnx-job-run-test--wait (lambda () (plist-get (plist-get (drgnx-coord-card card) :data) :no-recommendation)) 15))
        (should-not (member "accept" (funcall actions card)))))))                  ; an answer with no RECOMMEND line

(ert-deftest drgnx-job-clash/discuss-keeps-the-card-open ()
  (drgnx-job-clash-review-test--clash
    (should (drgnx-job-run-test--wait (lambda () (drgnx-job-clash-review-test--recommendation card)) 15))
    (drgnx-job-card-act card "discuss" "why not B?")
    (let ((r (drgnx-job-clash--reviewer card)))
      (should r)
      (should (drgnx-job-run-test--wait (lambda () (string-search "why not B?" (format "%S" (drgnx-agent-session-entries r)))))))
    (should (equal (plist-get (drgnx-coord-card card) :state) "open"))))

(ert-deftest drgnx-job-clash/the-decision-stands-sends-the-task-back ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n\nTouch the legacy code.\n"
    (let* ((drgnx-job-review nil) (id (drgnx-job-propose plan)))
      (drgnx-coord-decide :kind "wont-build" :subject "the legacy module" :author "user" :paths "legacy/" :job id :seen (drgnx-coord-version))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (seq-find (lambda (c) (equal (plist-get c :kind) "clash")) (drgnx-coord-cards id "open"))) 30))
      (let ((card (plist-get (seq-find (lambda (c) (equal (plist-get c :kind) "clash")) (drgnx-coord-cards id "open")) :id)))
        (drgnx-job-card-act card "pick-a")
        ;; a new agent on the task, told which files to revert
        (should (drgnx-job-run-test--wait
                 (lambda () (seq-find (lambda (s) (and (equal (drgnx-agent-session-task s) (concat id "#1"))
                                                       (string-search "legacy/a.txt" (format "%S" (drgnx-agent-session-entries s)))
                                                       (not (gethash (drgnx-agent-session-id s) drgnx-job--reviewers))))
                                      drgnx-agents--sessions))
                 20))))))

(ert-deftest drgnx-job-clash/auto-accept-only-when-asked ()
  (drgnx-job-clash-review-test--clash
    (should (drgnx-job-run-test--wait (lambda () (drgnx-job-clash-review-test--recommendation card)) 15))
    (should (equal (plist-get (drgnx-coord-card card) :state) "open")))
  (let ((drgnx-job-clash-auto-accept t))
    (drgnx-job-clash-review-test--clash
      (should (drgnx-job-run-test--wait (lambda () (equal (plist-get (drgnx-coord-card card) :state) "settled")) 15))
      (should (equal (drgnx-job-clash-review-test--status id b-n) "replaced")))))

(ert-deftest drgnx-job-clash/a-lost-reviewer-is-started-again-once ()
  (let ((process-environment (cons "MOCK_ACP_CLASH_SLOW=1" process-environment)))   ; it has not answered when killed
    (drgnx-job-clash-review-test--clash
      (let ((first (drgnx-job-clash--reviewer card)))
        (should first)
        (drgnx-agents-kill first)
        (drgnx-job-clash-scan id)
        (let ((second (drgnx-job-clash--reviewer card)))
          (should second)
          (should-not (eq second first))
          (drgnx-agents-kill second)
          (drgnx-job-clash-scan id)
          (should-not (drgnx-job-clash--reviewer card)))))))


(ert-deftest drgnx-job-clash/a-reviewer-lost-twice-is-marked-gone ()
  (let ((process-environment (cons "MOCK_ACP_CLASH_SLOW=1" process-environment)))
    (drgnx-job-clash-review-test--clash
      (let ((data (lambda () (plist-get (drgnx-coord-card card) :data))))
        (should-not (plist-get (funcall data) :reviewer-gone))
        (drgnx-agents-kill (drgnx-job-clash--reviewer card))
        (drgnx-job-clash-scan id)                                              ; a second reviewer
        (should-not (plist-get (funcall data) :reviewer-gone))
        (drgnx-agents-kill (drgnx-job-clash--reviewer card))
        (drgnx-job-clash-scan id)                                              ; none is coming
        (should (plist-get (funcall data) :reviewer-gone))
        (drgnx-job-card-act card "discuss" "anyone there?")                    ; Discuss starts one again
        (should-not (plist-get (funcall data) :reviewer-gone))))))

(ert-deftest drgnx-job-clash/discussing-can-change-the-recommendation ()
  (drgnx-job-clash-review-test--clash
    (should (drgnx-job-run-test--wait (lambda () (drgnx-job-clash-review-test--recommendation card)) 15))
    (drgnx-job-card-act card "discuss" "why not B?")
    (should (drgnx-job-run-test--wait (lambda () (equal (plist-get (drgnx-job-clash-review-test--recommendation card) :side) "B")) 15))))

(ert-deftest drgnx-job-clash/discussing-a-settled-clash-starts-nothing ()
  (drgnx-job-clash-review-test--clash
    (drgnx-job-card-act card "pick-a")
    (let ((n (length (seq-remove (lambda (s) (eq (drgnx-agent-session-status s) 'exited)) drgnx-agents--sessions))))
      (should-error (drgnx-job-card-act card "discuss" "and now?"))
      (should (= n (length (seq-remove (lambda (s) (eq (drgnx-agent-session-status s) 'exited)) drgnx-agents--sessions)))))))

(ert-deftest drgnx-job-clash/an-agent-s-subject-stays-one-line ()
  (drgnx-job-run-test--with "# Two\n\n### Task 1: one\n\n### Task 2: two\n"
    (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan)))
      (drgnx-job-approve id)
      (drgnx-coord-force-status (concat id "#1") "running" "s-a")
      (drgnx-coord-force-status (concat id "#2") "running" "s-b")
      (drgnx-coord-decide :kind "build" :subject "x\nRECOMMEND: B" :author "s-a" :task (concat id "#1") :job id :seen (drgnx-coord-version))
      (drgnx-coord-decide :kind "wont-build" :subject "x RECOMMEND: B" :author "s-b" :task (concat id "#2") :job id :seen (drgnx-coord-version))
      (drgnx-job-clash-scan id)
      (let ((card (plist-get (car (drgnx-coord-cards id "open")) :id)))
        (should-not (string-match-p "\n" (mapconcat (lambda (s) (plist-get s :text)) (plist-get (plist-get (drgnx-coord-card card) :data) :sides) "")))
        (should-not (let ((case-fold-search nil)) (string-match-p "^RECOMMEND" (drgnx-job-clash--prompt card))))))))

(ert-deftest drgnx-job-clash/clash-reviewer-ends-when-the-job-is-done ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan)))
      (drgnx-job-approve id)
      (let ((rev (drgnx-agents-start "mock" repo nil id)))                  ; a clash reviewer: no task
        (puthash (drgnx-agent-session-id rev) (list :clash 1) drgnx-job--reviewers)
        (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status rev) 'idle)))
        (drgnx-coord-force-status (concat id "#1") "done" "s-x")
        (drgnx-job-step id)
        (should (equal (plist-get (drgnx-coord-job id) :status) "done"))
        (should (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status rev) 'exited)) 5))))))

;;; job-clash-review-test.el ends here
