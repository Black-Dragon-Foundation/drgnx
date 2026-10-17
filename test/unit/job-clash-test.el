;;; job-clash-test.el --- batch tests: clashes found by fixed rules -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/job-fixture" drgnx-dir) nil t)   ; a repo, the hub, mock agents
(require 'drgnx-job-clash)

(defconst drgnx-job-clash-test--two "# Two\n\n### Task 1: one\n\n### Task 2: two\n")

(defmacro drgnx-job-clash-test--running (plan-text &rest body)
  "BODY with a running job ID of PLAN-TEXT, nothing started by itself; tasks 1 and 2 held by agents s-a and s-b."
  (declare (indent 1))
  `(drgnx-job-run-test--with ,plan-text
     (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan)))
       (drgnx-job-approve id)
       (drgnx-coord-force-status (concat id "#1") "running" "s-a")
       (when (drgnx-coord-task (concat id "#2")) (drgnx-coord-force-status (concat id "#2") "running" "s-b"))
       ,@body)))

(defun drgnx-job-clash-test--decide (id kind subject author &rest more)
  (apply #'drgnx-coord-decide :kind kind :subject subject :author author :job id :seen (drgnx-coord-version) more))

(defun drgnx-job-clash-test--cards (id &optional kind)
  (seq-filter (lambda (c) (or (null kind) (equal (plist-get c :kind) kind))) (drgnx-coord-cards id "open")))

(ert-deftest drgnx-job-clash/build-and-wont-build-on-one-subject-is-a-clash ()
  (drgnx-job-clash-test--running drgnx-job-clash-test--two
    (drgnx-job-clash-test--decide id "build" "The CSV export" "s-a" :task (concat id "#1"))
    (drgnx-job-clash-test--decide id "wont-build" "the  csv export " "s-b" :task (concat id "#2"))
    (drgnx-job-clash-scan id)
    (let ((cards (drgnx-job-clash-test--cards id "clash")))
      (should (= 1 (length cards)))
      (let ((data (plist-get (car cards) :data)))
        (should (equal (plist-get data :rule) "contradiction"))
        (should (equal (mapcar (lambda (s) (plist-get s :label)) (plist-get data :sides)) '("A" "B")))
        (should (equal (sort (mapcar (lambda (s) (plist-get s :agent)) (plist-get data :sides)) #'string<) '("s-a" "s-b")))))
    (drgnx-job-clash-scan id)
    (should (= 1 (length (drgnx-job-clash-test--cards id "clash"))))))

(ert-deftest drgnx-job-clash/the-user-s-decision-wins-without-a-card ()
  (drgnx-job-clash-test--running drgnx-job-clash-test--two
    (drgnx-job-clash-test--decide id "wont-build" "x" "user")
    (let ((n (plist-get (drgnx-job-clash-test--decide id "build" "X " "s-a" :task (concat id "#1")) :n)))
      (drgnx-job-clash-scan id)
      (should-not (drgnx-job-clash-test--cards id "clash"))
      (should (equal (plist-get (seq-find (lambda (d) (eql (plist-get d :n) n)) (drgnx-coord-decisions-since 0 id)) :status) "replaced"))
      (should (seq-find (lambda (d) (and (equal (plist-get d :kind) "replaces") (eql (plist-get d :replaces) n) (equal (plist-get d :author) "user")))
                        (drgnx-coord-decisions-since 0 id))))))

(ert-deftest drgnx-job-clash/a-proposed-decision-is-a-clash ()
  (drgnx-job-clash-test--running drgnx-job-clash-test--two
    ;; s-a decides about task 2, which it does not hold: proposed
    (should (equal (plist-get (drgnx-job-clash-test--decide id "wont-build" "the importer" "s-a" :task (concat id "#2")) :status) "proposed"))
    (drgnx-job-clash-scan id)
    (let ((card (car (drgnx-job-clash-test--cards id "clash"))))
      (should card)
      (should (equal (plist-get (plist-get card :data) :rule) "proposed")))))

(ert-deftest drgnx-job-clash/a-task-that-touches-what-will-not-be-built-waits ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n\nTouch the legacy code.\n"
    (let* ((id (drgnx-job-propose plan)))
      (drgnx-job-clash-test--decide id "wont-build" "the legacy module" "user" :paths "legacy/, old/*.c")
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (drgnx-job-clash-test--cards id "clash")) 30))
      (let ((card (car (drgnx-job-clash-test--cards id "clash"))))
        (should (equal (plist-get (plist-get card :data) :rule) "against-decision"))
        (should (equal (plist-get card :task) (concat id "#1"))))
      (drgnx-job-run-test--wait #'ignore 2.5)                                 ; a tick: no reviewer, still in review
      (should-not (drgnx-job--reviewer-of (concat id "#1")))
      (should (equal (drgnx-job-run-test--status id 1) "in-review")))))

(ert-deftest drgnx-job-clash/two-held-writes-are-a-stalled-card ()
  (drgnx-job-clash-test--running drgnx-job-clash-test--two
    (let ((s (drgnx-agents--make :id "s-a" :name "a" :profile "mock" :cwd repo :task (concat id "#1") :job id :status 'idle)))
      (push s drgnx-agents--sessions)
      (drgnx-coord-note-held "s-a" t)
      (drgnx-job-clash-scan id)
      (should-not (drgnx-job-clash-test--cards id "stalled"))
      (drgnx-coord-note-held "s-a" t)
      (drgnx-job-clash-scan id)
      (should (equal (plist-get (car (drgnx-job-clash-test--cards id "stalled")) :task) (concat id "#1")))
      ;; a write that goes through: the count starts again
      (drgnx-coord-note-held "s-a" nil)
      (should (= 0 (drgnx-coord-held "s-a")))
      (setq drgnx-agents--sessions (delq s drgnx-agents--sessions)))))

(ert-deftest drgnx-job-clash/overlapping-tasks-are-advisory ()
  ;; both tasks append to task.txt: when the first is in review, the other open task changed the same file
  (drgnx-job-run-test--with drgnx-job-clash-test--two
    (let* ((drgnx-job-review nil) (id (drgnx-job-propose plan)))
      (drgnx-job-approve id)
      (should (drgnx-job-run-test--wait (lambda () (drgnx-job-clash-test--cards id "overlap")) 30))
      (let ((card (car (drgnx-job-clash-test--cards id "overlap"))))
        (should (member "task.txt" (plist-get (plist-get card :data) :files))))
      (should (= 1 (length (drgnx-job-clash-test--cards id "overlap"))))   ; one per pair
      (should (member (drgnx-job-run-test--status id 1) '("in-review" "done"))))))

(ert-deftest drgnx-job-clash/covers ()
  (should (drgnx-job-clash--covers-p "legacy/a.txt" "legacy/"))
  (should-not (drgnx-job-clash--covers-p "legacy2/a" "legacy/"))
  (should (drgnx-job-clash--covers-p "legacy/a.txt" "legacy"))
  (should (drgnx-job-clash--covers-p "a/b.lock" "*.lock"))
  (should (drgnx-job-clash--covers-p "old/x.c" "old/*.c"))
  (should-not (drgnx-job-clash--covers-p "new/x.c" "old/*.c"))
  (should (equal (drgnx-job-clash--paths "legacy/, old/*.c\nb") '("legacy/" "old/*.c" "b"))))

;;; job-clash-test.el ends here
