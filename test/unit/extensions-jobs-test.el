;;; extensions-jobs-test.el --- the Extensions view's jobs: the queue of clicks, progress files, results -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: no process and no real clock.  The hub is stubbed at the job client: `drgnx-exec-start' records each
;; start and answers a new id at once, and `exec/list' answers when the test says.  The file-notify watch is a stub
;; whose callback the test calls.  The batch sync is played by the test: it takes pending.eld and writes the progress
;; file as `drgnx sync --pending --progress FILE' does, and its end is the hub's `exec-done' event.  The progress reads
;; run on the virtual clock (clock-fixture.el).  Every drgnx location is a temp directory.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-timer)
(require 'drgnx-exec)
(require 'drgnx-pkg-wants)
(require 'drgnx-pkg)                    ; the layer loads it at a job's first MISSING line: here, not inside a test
(load (expand-file-name "modules/tools/drgnx-extensions-jobs" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defvar drgnx-extensions-jobs-test--starts nil "The jobs started, newest first: (:id ID :name NAME :argv ARGV KEYS…).")
(defvar drgnx-extensions-jobs-test--list nil "The callback of the last `exec/list' call, or nil.")
(defvar drgnx-extensions-jobs-test--notify nil "The progress watch's callback, or nil.")
(defvar drgnx-extensions-jobs-test--backend t "Non-nil: file-notify has a backend.")
(defvar drgnx-extensions-jobs-test--stops nil "The ids `drgnx-exec-stop' was called with.")
(defvar drgnx-extensions-jobs-test--waits 0 "Waits made while a progress read ran.")
(defvar drgnx-extensions-jobs-test--in-read nil "Non-nil while a progress read runs.")

(defun drgnx-extensions-jobs-test--start (name argv &rest keys)
  "The stub of `drgnx-exec-start': records the start and answers the next id at once."
  (let ((id (format "job-%d" (1+ (length drgnx-extensions-jobs-test--starts)))))
    (push (append (list :id id :name name :argv argv) keys) drgnx-extensions-jobs-test--starts)
    (funcall (plist-get keys :callback) id nil)
    nil))

(defun drgnx-extensions-jobs-test--hub-call (method _params callback &rest _)
  "The stub of `drgnx-hub-call': `exec/list' keeps its CALLBACK for the test to answer."
  (when (equal method "exec/list") (setq drgnx-extensions-jobs-test--list callback)))

(defun drgnx-extensions-jobs-test--add-watch (_dir _flags callback)
  "The stub of `file-notify-add-watch': no backend signals, as file-notify does."
  (unless drgnx-extensions-jobs-test--backend (signal 'file-notify-error '("No file notification package available")))
  (setq drgnx-extensions-jobs-test--notify callback)
  'progress-watch)

(defmacro drgnx-extensions-jobs-test--with (root &rest body)
  "BODY with ROOT a temp dir holding every drgnx location, the hub stubbed and the job layer set up (torn down after),
on the virtual clock.  The hub's job list has not answered yet: `drgnx-extensions-jobs-test--listed' answers it."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-ext-jobs" t)))
          (process-environment (append (list (concat "XDG_STATE_HOME=" ,root "state") (concat "DRGNX_DATA_DIR=" ,root "data")
                                             (concat "DRGNX_CONFIG_DIR=" ,root "config") (concat "XDG_CACHE_HOME=" ,root "cache"))
                                       process-environment))
          (drgnx-exec--jobs (make-hash-table :test #'equal)) (drgnx-exec--stale nil)
          (drgnx-hub-event-functions nil) (drgnx-hub-disconnect-functions nil) (drgnx-exec-listed-hook nil)
          (drgnx-extensions-jobs-changed-functions nil) (drgnx-extensions-jobs-plan-functions nil)
          (drgnx-extensions-jobs-done-functions nil)
          (drgnx-extensions-jobs-test--starts nil) (drgnx-extensions-jobs-test--list nil)
          (drgnx-extensions-jobs-test--notify nil) (drgnx-extensions-jobs-test--stops nil))
     (make-directory (concat ,root "config") t)
     (unwind-protect
         (drgnx-test-with-clock ()
           (cl-letf (((symbol-function 'drgnx-exec-start) #'drgnx-extensions-jobs-test--start)
                     ((symbol-function 'drgnx-exec-stop) (lambda (id) (push id drgnx-extensions-jobs-test--stops) nil))
                     ((symbol-function 'drgnx-hub-call) #'drgnx-extensions-jobs-test--hub-call)
                     ((symbol-function 'drgnx-hub-connect) #'ignore)
                     ((symbol-function 'file-notify-add-watch) #'drgnx-extensions-jobs-test--add-watch)
                     ((symbol-function 'file-notify-rm-watch) #'ignore))
             (unwind-protect (progn (drgnx-extensions-jobs-setup) ,@body)
               (drgnx-extensions-jobs-teardown))))
       (delete-directory ,root t))))

(defun drgnx-extensions-jobs-test--listed (&rest rows)
  "The hub answers the job list with ROWS (exec/list rows)."
  (funcall drgnx-extensions-jobs-test--list (list :jobs rows) nil))

(defun drgnx-extensions-jobs-test--job (n)
  "The Nth job started (1 the first)."
  (nth (- (length drgnx-extensions-jobs-test--starts) n) drgnx-extensions-jobs-test--starts))

(defun drgnx-extensions-jobs-test--file (job)
  "JOB's progress file: the argument after --progress."
  (cadr (member "--progress" (plist-get job :argv))))

(defun drgnx-extensions-jobs-test--write (file object)
  "Replace FILE with the JSON OBJECT (a plist), as a run's step does."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert (json-serialize object))))

(defun drgnx-extensions-jobs-test--take (job)
  "What JOB's `drgnx sync --pending' does under the sync lock: take the queue, then write its start step.  The tickets."
  (let ((tickets (mapcar (lambda (e) (plist-get e :ticket)) (drgnx-pkg-pending-take))))
    (drgnx-extensions-jobs-test--write (drgnx-extensions-jobs-test--file job)
                                       (list :step "start" :command "sync" :tickets (vconcat tickets)))
    tickets))

(defun drgnx-extensions-jobs-test--seen (&optional file)
  "The watch tells of a change to FILE (default any), and the reads it asks for run."
  (funcall drgnx-extensions-jobs-test--notify
           (list 'progress-watch 'changed (or file (expand-file-name "x.json" (drgnx-extensions-jobs-dir)))))
  (drgnx-test-advance 1))

(defun drgnx-extensions-jobs-test--done (job &optional exit lines status)
  "The hub's exec-done event for JOB: EXIT (default 0), the summary's LINES, STATUS (default \"done\")."
  (let ((exit (or exit 0)))
    (run-hook-with-args 'drgnx-hub-event-functions "exec-done"
                        (list :id (plist-get job :id) :status (or status "done") :exit exit
                              :summary (list :exit exit :failing nil :lines lines :log "/state/hub/exec/log")))))

(defun drgnx-extensions-jobs-test--queue ()
  "The entries of pending.eld."
  (plist-get (plist-get (drgnx-file-read (drgnx-pkg-pending-file)) :data) :entries))

(defun drgnx-extensions-jobs-test--status (id) (plist-get (drgnx-extensions-jobs-state id) :status))

(ert-deftest drgnx-extensions-jobs/clicks-batch-into-one-waiting-job ()
  (drgnx-extensions-jobs-test--with root
    (drgnx-extensions-jobs-test--listed)
    (let ((tickets (mapcar (lambda (n) (drgnx-extensions-jobs-queue (list :add n))) '(magit corfu eat))))
      (should (equal tickets '(1 2 3)))
      ;; the first click starts the job; the job's start step is not seen yet, so the others wait for it too
      (should (= (length drgnx-extensions-jobs-test--starts) 1))
      (let ((job (drgnx-extensions-jobs-test--job 1)))
        (should (string-prefix-p "Extensions: " (plist-get job :name)))
        (should (equal (plist-get job :machine) "local"))
        (should (eq (plist-get job :local-only) t))
        (should (eql (plist-get job :timebox) 7200))
        (should (equal (seq-take (plist-get job :argv) 5)
                       (list (expand-file-name "bin/drgnx" drgnx-dir) "sync" "--pending" "--wait" "--progress")))
        (dolist (tk tickets) (should (eq (drgnx-extensions-jobs-test--status tk) 'queued)))
        (should (eq (drgnx-extensions-jobs-test--status 'magit) 'queued))
        (should (equal (drgnx-extensions-jobs-test--take job) '(1 2 3)))
        (drgnx-extensions-jobs-test--seen)
        (should (eq (drgnx-extensions-jobs-test--status "corfu") 'busy))
        (should (equal (plist-get (drgnx-extensions-jobs-state 3) :tickets) '(1 2 3)))
        (should (= (length drgnx-extensions-jobs-test--starts) 1))))))

(ert-deftest drgnx-extensions-jobs/a-click-after-the-job-started-starts-one-more ()
  (drgnx-extensions-jobs-test--with root
    (drgnx-extensions-jobs-test--listed)
    (drgnx-extensions-jobs-queue '(:add magit))
    (drgnx-extensions-jobs-test--take (drgnx-extensions-jobs-test--job 1))
    (drgnx-extensions-jobs-test--seen)
    (drgnx-extensions-jobs-queue '(:add corfu))
    (should (= (length drgnx-extensions-jobs-test--starts) 2))
    (should (eq (drgnx-extensions-jobs-test--status 'magit) 'busy))
    (should (eq (drgnx-extensions-jobs-test--status 'corfu) 'queued))
    ;; a third click joins the second job, which has not started yet
    (drgnx-extensions-jobs-queue '(:add eat))
    (should (= (length drgnx-extensions-jobs-test--starts) 2))))

(ert-deftest drgnx-extensions-jobs/a-click-between-take-and-start-gets-a-job ()
  ;; pattern A: every place the second click can land among the first job's take, its start step seen, and its end
  (dolist (at '(0 1 2 3))
    (drgnx-extensions-jobs-test--with root
      (drgnx-extensions-jobs-test--listed)
      (drgnx-extensions-jobs-queue '(:add magit))
      (let ((took nil) (finished nil) (i 0) (j1 (drgnx-extensions-jobs-test--job 1)))
        (dolist (ev '(take seen done))
          (when (= i at) (drgnx-extensions-jobs-queue '(:add corfu)))
          (setq i (1+ i))
          (pcase ev
            ('take (push (cons (plist-get j1 :id) (drgnx-extensions-jobs-test--take j1)) took))
            ('seen (drgnx-extensions-jobs-test--seen))
            ('done (drgnx-extensions-jobs-test--done j1) (push (plist-get j1 :id) finished))))
        (when (= i at) (drgnx-extensions-jobs-queue '(:add corfu)))
        ;; every job started since runs to its end
        (let ((rounds 0) next)
          (while (setq next (seq-find (lambda (j) (not (member (plist-get j :id) finished)))
                                      (reverse drgnx-extensions-jobs-test--starts)))
            (should (< (setq rounds (1+ rounds)) 5))
            (push (cons (plist-get next :id) (drgnx-extensions-jobs-test--take next)) took)
            (drgnx-extensions-jobs-test--seen)
            (drgnx-extensions-jobs-test--done next)
            (push (plist-get next :id) finished)))
        ;; each ticket was taken by exactly one job, none is left, and no job was started for nothing
        (dolist (tk '(1 2))
          (should (= 1 (seq-count (lambda (c) (memq tk (cdr c))) took)))
          (should (eq (drgnx-extensions-jobs-test--status tk) 'done)))
        (should-not (drgnx-extensions-jobs-test--queue))
        (should (seq-every-p #'cdr took))
        (should (= (length drgnx-extensions-jobs-test--starts) (if (= at 0) 1 2)))))))

(ert-deftest drgnx-extensions-jobs/progress-files-follow-their-token ()
  (drgnx-extensions-jobs-test--with root
    (drgnx-extensions-jobs-test--listed)
    (drgnx-extensions-jobs-queue '(:add magit))
    (let* ((job (drgnx-extensions-jobs-test--job 1)) (file (drgnx-extensions-jobs-test--file job))
           (other (expand-file-name "other-token.json" (drgnx-extensions-jobs-dir))))
      ;; named by a token the editor made before the hub answered, in the shared progress directory
      (should (equal (file-name-directory file) (file-name-as-directory (expand-file-name "extensions/progress" (drgnx-state-dir)))))
      (should (string-suffix-p ".json" file))
      (should-not (string-search (plist-get job :id) file))
      (drgnx-extensions-jobs-test--take job)
      (drgnx-extensions-jobs-test--write file '(:step "download" :pkg "magit" :i 1 :n 2))
      (drgnx-extensions-jobs-test--write (concat file ".plan.json") '(:step "plan" :seq 1 :generation 3 :replaces [] :removes [] :adds ["magit-4.2"]))
      (drgnx-extensions-jobs-test--write other '(:step "download" :pkg "eat" :i 1 :n 1))
      (drgnx-extensions-jobs-test--seen file)
      (let ((s (drgnx-extensions-jobs-state 'magit)))
        (should (eq (plist-get s :status) 'busy))
        (should (eq (plist-get s :step) 'download))
        (should (equal (list (plist-get s :pkg) (plist-get s :i) (plist-get s :n)) '("magit" 1 2)))
        (should (equal (plist-get s :job) (plist-get job :id))))
      ;; a file of a job this session did not start says nothing about its rows
      (should-not (drgnx-extensions-jobs-state 'eat))
      ;; once its result is read, the job's files go; the other job's stay
      (drgnx-extensions-jobs-test--done job 0 '("installed: magit"))
      (should-not (file-exists-p file))
      (should-not (file-exists-p (concat file ".plan.json")))
      (should (file-exists-p other)))))

(ert-deftest drgnx-extensions-jobs/partly-compiled-is-not-a-failure ()
  (drgnx-extensions-jobs-test--with root
    (drgnx-extensions-jobs-test--listed)
    (drgnx-extensions-jobs-queue '(:add magit))
    (let ((job (drgnx-extensions-jobs-test--job 1)))
      (drgnx-extensions-jobs-test--take job)
      (drgnx-extensions-jobs-test--done job 0 '("installed: magit"
                                                "WARNING magit: magit-extras.el does not byte-compile (it runs uncompiled)"
                                                "WARNING magit: magit-x.el does not byte-compile (it runs uncompiled)"
                                                "generation 4"))
      (let ((s (drgnx-extensions-jobs-state 'magit)))
        (should (eq (plist-get s :status) 'done))
        (should-not (plist-get s :error))
        (should (equal (plist-get s :warnings) '("partly compiled: magit-extras.el, magit-x.el")))))))

(ert-deftest drgnx-extensions-jobs/a-different-version-says-so ()
  (drgnx-extensions-jobs-test--with root
    (drgnx-extensions-jobs-test--listed)
    (drgnx-extensions-jobs-queue '(:add magit :latest "4.2"))
    (drgnx-extensions-jobs-queue '(:add corfu :latest "1.0"))
    ;; what the page showed is the view's, not the queue's
    (should (equal (mapcar (lambda (e) (plist-member e :latest)) (drgnx-extensions-jobs-test--queue)) '(nil nil)))
    (let* ((job (drgnx-extensions-jobs-test--job 1)) (file (drgnx-extensions-jobs-test--file job)))
      (drgnx-extensions-jobs-test--take job)
      (drgnx-extensions-jobs-test--write (concat file ".plan.json")
                                         '(:step "plan" :seq 1 :generation 5 :replaces [] :removes [] :adds ["corfu-1.0" "magit-4.3"]))
      (drgnx-extensions-jobs-test--seen)
      (drgnx-extensions-jobs-test--done job 0 '("installed: corfu magit"))
      (should (eq (drgnx-extensions-jobs-test--status 'magit) 'done))
      (should (equal (plist-get (drgnx-extensions-jobs-state 'magit) :warnings) '("installed 4.3, not the 4.2 the page showed")))
      (should-not (plist-get (drgnx-extensions-jobs-state 'corfu) :warnings)))))

(ert-deftest drgnx-extensions-jobs/progress-reads-at-most-four-a-second ()
  (drgnx-extensions-jobs-test--with root
    (drgnx-extensions-jobs-test--listed)
    (drgnx-extensions-jobs-queue '(:add magit))
    (let* ((job (drgnx-extensions-jobs-test--job 1)) (file (drgnx-extensions-jobs-test--file job))
           (reads 0) (read (symbol-function 'drgnx-extensions-jobs--read)))
      (drgnx-extensions-jobs-test--take job)
      (cl-letf (((symbol-function 'drgnx-extensions-jobs--read) (lambda () (setq reads (1+ reads)) (funcall read))))
        ;; 20 changes in one second of virtual time
        (dotimes (i 20)
          (drgnx-extensions-jobs-test--write file (list :step "native" :pkg "magit" :i (1+ i) :n 20))
          (funcall drgnx-extensions-jobs-test--notify (list 'progress-watch 'changed file))
          (drgnx-test-advance 0.05))
        (should (<= reads 4))
        (should (> reads 0))
        ;; the last change is never dropped
        (drgnx-test-advance 1)
        (should (<= reads 5))
        (should (eql (plist-get (drgnx-extensions-jobs-state 'magit) :i) 20))))))

(ert-deftest drgnx-extensions-jobs/no-notify-backend-shows-elapsed-only ()
  (let ((drgnx-extensions-jobs-test--backend nil))
    (drgnx-extensions-jobs-test--with root
      (drgnx-extensions-jobs-test--listed)
      (should-not drgnx-extensions-jobs-test--notify)
      (drgnx-extensions-jobs-queue '(:add magit))
      (let ((job (drgnx-extensions-jobs-test--job 1)))
        (drgnx-extensions-jobs-test--take job)
        (drgnx-extensions-jobs-test--write (drgnx-extensions-jobs-test--file job) '(:step "download" :pkg "magit" :i 1 :n 1))
        (drgnx-test-advance 30)
        (let ((s (drgnx-extensions-jobs-state 'magit)))
          ;; the row shows how long it has run, not a step it cannot see
          (should (eq (plist-get s :status) 'busy))
          (should-not (plist-get s :step))
          (should (>= (- (drgnx-timer-now) (plist-get s :since)) 30)))
        ;; the end comes from the hub
        (drgnx-extensions-jobs-test--done job 0 '("installed: magit"))
        (should (eq (drgnx-extensions-jobs-test--status 'magit) 'done))))))

(ert-deftest drgnx-extensions-jobs/the-plan-step-runs-the-plan-hook-once ()
  (drgnx-extensions-jobs-test--with root
    (drgnx-extensions-jobs-test--listed)
    (let ((plans nil))
      (add-hook 'drgnx-extensions-jobs-plan-functions (lambda (p) (push p plans)))
      (drgnx-extensions-jobs-queue '(:add magit))
      (let* ((job (drgnx-extensions-jobs-test--job 1)) (file (drgnx-extensions-jobs-test--file job))
             (theirs (expand-file-name "another-session.json.plan.json" (drgnx-extensions-jobs-dir))))
        (drgnx-extensions-jobs-test--take job)
        (drgnx-extensions-jobs-test--write (concat file ".plan.json")
                                           '(:step "plan" :seq 1 :generation 7 :replaces ["magit-4.1"] :removes [] :adds []))
        (drgnx-extensions-jobs-test--seen)
        (drgnx-extensions-jobs-test--seen)
        (should (= (length plans) 1))
        (should (equal (plist-get (car plans) :generation) 7))
        (should (equal (plist-get (car plans) :replaces) '("magit-4.1")))
        ;; a plan another session's job wrote (the state directory is shared): once too
        (drgnx-extensions-jobs-test--write theirs '(:step "plan" :seq 1 :generation 8 :replaces ["eat-0.9"] :removes [] :adds []))
        (drgnx-extensions-jobs-test--seen)
        (drgnx-extensions-jobs-test--seen)
        (should (= (length plans) 2))
        (should (equal (plist-get (car plans) :generation) 8))
        ;; the run's next swap has a plan of its own
        (drgnx-extensions-jobs-test--write (concat file ".plan.json")
                                           '(:step "plan" :seq 2 :generation 7 :replaces ["magit-4.2"] :removes [] :adds []))
        (drgnx-extensions-jobs-test--seen)
        (should (= (length plans) 3))))))

(ert-deftest drgnx-extensions-jobs/setup-waits-for-the-job-list ()
  (drgnx-extensions-jobs-test--with root
    ;; a click another session queued, and one made here, before the hub said which jobs run
    (drgnx-pkg-pending-add '(:add eat))
    (drgnx-extensions-jobs-queue '(:add magit))
    (drgnx-test-advance 5)
    (should-not drgnx-extensions-jobs-test--starts)
    (drgnx-extensions-jobs-test--listed)
    (should (= (length drgnx-extensions-jobs-test--starts) 1))
    (should (eq (drgnx-extensions-jobs-test--status 'eat) 'queued))
    (should (equal (drgnx-extensions-jobs-test--take (drgnx-extensions-jobs-test--job 1)) '(1 2)))))

(ert-deftest drgnx-extensions-jobs/a-failed-job-keeps-its-reason ()
  (drgnx-extensions-jobs-test--with root
    (drgnx-extensions-jobs-test--listed)
    (drgnx-extensions-jobs-queue '(:add magit))
    (drgnx-extensions-jobs-queue '(:add corfu))
    (let ((job (drgnx-extensions-jobs-test--job 1)) (done nil))
      (add-hook 'drgnx-extensions-jobs-done-functions (lambda (id result) (push (cons id result) done)))
      (drgnx-extensions-jobs-test--take job)
      (drgnx-extensions-jobs-test--done job 1 '("installing magit-4.2"
                                                "drgnx: magit-4.2.tar: download failed (404 Not Found) — nothing was changed"))
      (dolist (p '(magit corfu))
        (should (eq (drgnx-extensions-jobs-test--status p) 'failed))
        (should (equal (plist-get (drgnx-extensions-jobs-state p) :error)
                       "magit-4.2.tar: download failed (404 Not Found) — nothing was changed")))
      (should (equal (caar done) (plist-get job :id)))
      (should (eq (plist-get (cdar done) :status) 'failed))
      ;; Retry queues the failed entries again, into one new job
      (should (equal (drgnx-extensions-jobs-retry 'corfu) '(3 4)))
      (should (eq (drgnx-extensions-jobs-test--status 'magit) 'queued))
      (should (= (length drgnx-extensions-jobs-test--starts) 2))
      ;; a name no archive has: the row says where it looked
      (drgnx-extensions-jobs-test--take (drgnx-extensions-jobs-test--job 2))
      (drgnx-extensions-jobs-test--done (drgnx-extensions-jobs-test--job 2) 0 '("installed: magit corfu"))
      (drgnx-extensions-jobs-queue '(:add nosuch))
      (drgnx-extensions-jobs-test--take (drgnx-extensions-jobs-test--job 3))
      (drgnx-extensions-jobs-test--done (drgnx-extensions-jobs-test--job 3) 1
                                        '("MISSING nosuch: Package ‘nosuch’ is unavailable"
                                          "drgnx: MISSING nosuch: Package ‘nosuch’ is unavailable"
                                          "the run cannot have everything it asked for — nothing was changed"))
      (should (eq (drgnx-extensions-jobs-test--status 'nosuch) 'failed))
      (should (equal (plist-get (drgnx-extensions-jobs-state 'nosuch) :error)
                     "not in any archive you use: gnu, nongnu, melpa")))))

(ert-deftest drgnx-extensions-jobs/cancel-takes-a-queued-ticket-out ()
  (drgnx-extensions-jobs-test--with root
    (drgnx-extensions-jobs-test--listed)
    (drgnx-extensions-jobs-queue '(:add magit))
    (drgnx-extensions-jobs-queue '(:add corfu))
    (let ((changed nil))
      (add-hook 'drgnx-extensions-jobs-changed-functions (lambda (ids) (setq changed (append ids changed))))
      (should (drgnx-extensions-jobs-cancel 2))
      (should (memq 'corfu changed)))
    (should (equal (mapcar (lambda (e) (plist-get e :ticket)) (drgnx-extensions-jobs-test--queue)) '(1)))
    (should-not (drgnx-extensions-jobs-state 'corfu))
    (should-not (drgnx-extensions-jobs-state 2))
    ;; once a run took it, Cancel stops the job instead
    (drgnx-extensions-jobs-test--take (drgnx-extensions-jobs-test--job 1))
    (should-not (drgnx-extensions-jobs-cancel 1))
    (drgnx-extensions-jobs-cancel (plist-get (drgnx-extensions-jobs-state 'magit) :job))
    (should (equal drgnx-extensions-jobs-test--stops (list (plist-get (drgnx-extensions-jobs-test--job 1) :id))))))

(ert-deftest drgnx-extensions-jobs/a-left-queue-gets-a-job-at-open ()
  (drgnx-extensions-jobs-test--with root
    ;; the editor closed with ticket 7 queued and no job for it
    (make-directory (file-name-directory (drgnx-pkg-pending-file)) t)
    (with-temp-file (drgnx-pkg-pending-file) (prin1 '(:next 8 :entries ((:ticket 7 :add magit))) (current-buffer)))
    (drgnx-extensions-jobs-test--listed (list :id "old-1" :name "grammars" :status "running" :argv '("make")))
    (should (= (length drgnx-extensions-jobs-test--starts) 1))
    (should (eq (drgnx-extensions-jobs-test--status 7) 'queued))
    (should (eq (drgnx-extensions-jobs-test--status 'magit) 'queued))
    ;; the next list (every subscription reads it) finds the job waiting: no second one
    (drgnx-extensions-jobs-test--listed)
    (should (= (length drgnx-extensions-jobs-test--starts) 1))))

(ert-deftest drgnx-extensions-jobs/a-busy-queue-file-says-try-again ()
  (drgnx-extensions-jobs-test--with root
    (drgnx-extensions-jobs-test--listed)
    ;; another drgnx holds pending.eld: the click is refused for now, never failed
    (cl-letf (((symbol-function 'drgnx-pkg-pending-add)
               (lambda (_entry) (signal 'drgnx-file-busy (list (drgnx-pkg-pending-file) "4242")))))
      (should-not (drgnx-extensions-jobs-queue '(:add magit))))
    (let ((s (drgnx-extensions-jobs-state 'magit)))
      (should (eq (plist-get s :status) 'busy))
      (should (equal (plist-get s :error) "busy, try again")))
    (should-not drgnx-extensions-jobs-test--starts)
    ;; the next click goes through
    (should (eql (drgnx-extensions-jobs-queue '(:add magit)) 1))
    (should (eq (drgnx-extensions-jobs-test--status 'magit) 'queued))))

(defun drgnx-extensions-jobs-test--count-wait (&rest _)
  "Count a wait made while a progress read runs."
  (when drgnx-extensions-jobs-test--in-read (setq drgnx-extensions-jobs-test--waits (1+ drgnx-extensions-jobs-test--waits))))

(ert-deftest drgnx-extensions-jobs/nothing-waits-in-a-timer ()
  (let ((drgnx-extensions-jobs-test--waits 0) (drgnx-extensions-jobs-test--in-read nil))
    (drgnx-extensions-jobs-test--with root
      (drgnx-extensions-jobs-test--listed)
      (let ((read (symbol-function 'drgnx-extensions-jobs--read)))
        (advice-add 'accept-process-output :before #'drgnx-extensions-jobs-test--count-wait)
        (unwind-protect
            (cl-letf (((symbol-function 'drgnx-hub-call-sync)
                       (lambda (&rest _) (drgnx-extensions-jobs-test--count-wait) (error "the hub was waited for")))
                      ((symbol-function 'drgnx-extensions-jobs--read)
                       (lambda () (let ((drgnx-extensions-jobs-test--in-read t)) (funcall read)))))
              ;; a whole round: clicks, the start, a click between take and start, plans, steps, the end
              (drgnx-extensions-jobs-queue '(:add magit))
              (let* ((job (drgnx-extensions-jobs-test--job 1)) (file (drgnx-extensions-jobs-test--file job)))
                (drgnx-extensions-jobs-test--take job)
                (drgnx-extensions-jobs-queue '(:add corfu))
                (drgnx-extensions-jobs-test--write (concat file ".plan.json") '(:step "plan" :seq 1 :generation 2 :replaces [] :removes [] :adds ["magit-4.2"]))
                (drgnx-extensions-jobs-test--seen)
                (drgnx-extensions-jobs-test--write file '(:step "native" :pkg "magit" :i 1 :n 3))
                (drgnx-extensions-jobs-test--seen)
                (drgnx-extensions-jobs-test--done job 0 '("installed: magit"))
                (should (= (length drgnx-extensions-jobs-test--starts) 2))))
          (advice-remove 'accept-process-output #'drgnx-extensions-jobs-test--count-wait))
        (should (= drgnx-extensions-jobs-test--waits 0))))))

(provide 'extensions-jobs-test)
;;; extensions-jobs-test.el ends here
