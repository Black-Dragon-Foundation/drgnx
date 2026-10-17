;;; check-test.el --- batch tests: bin/drgnx check, the parallel run of every tier -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-check)

(defmacro drgnx-check-test--with (dir &rest body)
  (declare (indent 1))
  `(let ((,dir (file-name-as-directory (make-temp-file "drgnx-check" t))))
     (unwind-protect (progn ,@body) (delete-directory ,dir t))))

(defun drgnx-check-test--job (dir name phase &rest props)
  "A fake job NAME of PHASE: writes when it starts and ends into DIR/times, sleeps SLEEP, exits CODE."
  (append (list :name name :phase phase
                :command (list "sh" "-c" (format "echo \"%s start $(date +%%s.%%N)\" >> %stimes; sleep %s; echo \"%s end $(date +%%s.%%N)\" >> %stimes; exit %d"
                                                 name dir (or (plist-get props :sleep) 0.3) name dir (or (plist-get props :code) 0))))
          props))

(defun drgnx-check-test--times (dir)
  "Alist NAME → (START . END) from DIR/times."
  (let (out)
    (dolist (l (split-string (with-temp-buffer (insert-file-contents (concat dir "times")) (buffer-string)) "\n" t))
      (pcase-let ((`(,name ,what ,time) (split-string l)))
        (let ((e (or (assoc name out) (car (push (list name nil) out)))))
          (if (equal what "start") (setcar (cdr e) (string-to-number time)) (setcdr (cdr e) (string-to-number time))))))
    (mapcar (lambda (e) (cons (car e) (cons (cadr e) (cddr e)))) out)))

(defun drgnx-check-test--overlap (times names)
  "The most of NAMES that ran at the same moment."
  (let ((spans (mapcar (lambda (n) (alist-get n times nil nil #'equal)) names)))
    ;; at each moment one of them starts: how many are running then
    (apply #'max (mapcar (lambda (s) (seq-count (lambda (o) (and (<= (car o) (car s)) (< (car s) (cdr o)))) spans)) spans))))

(ert-deftest drgnx-check/phases-run-in-order-and-jobs-of-a-phase-together ()
  :tags '(:timing)                                      ; overlaps of 0.3 s sleeps: a quiet machine
  (drgnx-check-test--with dir
    (let* ((jobs (list (drgnx-check-test--job dir "build" 1)
                       (drgnx-check-test--job dir "u1" 2) (drgnx-check-test--job dir "u2" 2) (drgnx-check-test--job dir "u3" 2)
                       (drgnx-check-test--job dir "perf" 4)))
           (r (drgnx-check-run jobs :dir dir :jobs 8 :gui-slots 2))
           (tm (drgnx-check-test--times dir)))
      (should (plist-get r :ok))
      (should (<= (cddr (assoc "build" tm)) (cadr (assoc "u1" tm))))                  ; build first
      (should (= 3 (drgnx-check-test--overlap tm '("u1" "u2" "u3"))))                 ; together
      (dolist (u '("u1" "u2" "u3")) (should (<= (cddr (assoc u tm)) (cadr (assoc "perf" tm))))))))   ; perf alone, last

(ert-deftest drgnx-check/gui-jobs-never-exceed-the-slots-memory-allows ()
  :tags '(:timing)                                      ; overlaps of 0.3 s sleeps: a quiet machine
  (drgnx-check-test--with dir
    (let* ((jobs (mapcar (lambda (n) (drgnx-check-test--job dir n 2 :gui t)) '("g1" "g2" "g3" "g4")))
           (r (drgnx-check-run (cons (drgnx-check-test--job dir "u1" 2 :sleep 0.8) jobs) :dir dir :jobs 8 :gui-slots 2))
           (tm (drgnx-check-test--times dir)))
      (should (plist-get r :ok))
      (should (= 2 (drgnx-check-test--overlap tm '("g1" "g2" "g3" "g4"))))
      (should (= 3 (drgnx-check-test--overlap tm '("u1" "g1" "g2" "g3" "g4"))))))          ; unit shards are not GUI
  (should (= 1 (drgnx-check-gui-slots 2000)))                                             ; MiB available
  (should (= 1 (drgnx-check-gui-slots 3500)))
  (should (= 3 (drgnx-check-gui-slots 5000)))
  (should (= 4 (drgnx-check-gui-slots 64000))))

(ert-deftest drgnx-check/a-failing-job-is-named-with-its-log-and-the-rest-still-run ()
  (drgnx-check-test--with dir
    (let* ((r (drgnx-check-run (list (drgnx-check-test--job dir "bad" 2 :code 3) (drgnx-check-test--job dir "good" 2)
                                     (drgnx-check-test--job dir "later" 3))
                               :dir dir :jobs 4 :gui-slots 1))
           (bad (seq-find (lambda (j) (equal (plist-get j :name) "bad")) (plist-get r :jobs)))
           (summary (drgnx-check-summary r)))
      (should-not (plist-get r :ok))
      (should (eql (plist-get bad :exit) 3))
      (should (file-exists-p (plist-get bad :log)))
      (should (assoc "later" (drgnx-check-test--times dir)))                                  ; ran anyway
      (should (string-match-p "bad +FAILED (exit 3)" summary))
      (should (string-search (plist-get bad :log) summary))
      (should (eql (drgnx-check-exit-code r) 1)))))

(ert-deftest drgnx-check/a-short-job-is-seen-ending-while-a-long-one-runs ()
  :tags '(:timing)                                      ; within 1.5 s: a quiet machine
  ;; the first real run noticed every job of the parallel phase only when the last ended
  (drgnx-check-test--with dir
    (let* ((r (drgnx-check-run (list (drgnx-check-test--job dir "short" 2 :sleep 0.3) (drgnx-check-test--job dir "long" 2 :sleep 4))
                               :dir dir :jobs 4 :gui-slots 1))
           (short (seq-find (lambda (j) (equal (plist-get j :name) "short")) (plist-get r :jobs))))
      (should (< (plist-get short :seconds) 1.5)))))

(ert-deftest drgnx-check/a-failing-build-stops-everything ()
  (drgnx-check-test--with dir
    (let ((r (drgnx-check-run (list (drgnx-check-test--job dir "build" 1 :code 1) (drgnx-check-test--job dir "u1" 2))
                              :dir dir :jobs 4 :gui-slots 1)))
      (should-not (plist-get r :ok))
      (should-not (assoc "u1" (drgnx-check-test--times dir))))))

(ert-deftest drgnx-check/a-hanging-job-is-ended-at-its-timeout-children-and-all ()
  (drgnx-check-test--with dir
    (let* ((secs (+ 30000 (random 30000)))                    ; a sleep no other process has
           (t0 (float-time))
           (r (drgnx-check-run (list (drgnx-check-test--job dir "hang" 2 :sleep secs :timeout 1)) :dir dir :jobs 2 :gui-slots 1)))
      (should (< (- (float-time) t0) 10))
      (should (eq (plist-get (car (plist-get r :jobs)) :status) 'timeout))
      (sleep-for 0.3)
      (should-not (seq-find (lambda (p) (string-match-p (format "sleep %d" secs) (or (cdr (assq 'args (process-attributes p))) "")))
                            (list-system-processes))))))

(ert-deftest drgnx-check/shards-are-balanced-by-how-long-their-files-took ()
  (let ((shards (drgnx-check-shard '("a" "b" "c" "d" "e") 2 '(("a" . 10) ("b" . 9) ("c" . 4) ("d" . 3) ("e" . 2)))))
    (should (= (length shards) 2))
    (should (equal (sort (mapcar (lambda (s) (apply #'+ (mapcar (lambda (f) (cdr (assoc f '(("a" . 10) ("b" . 9) ("c" . 4) ("d" . 3) ("e" . 2))))) s))) shards) #'<)
                   '(13 15))))
  (should (= (length (drgnx-check-shard '("a" "b") 4 nil)) 2)))                              ; never an empty shard

(ert-deftest drgnx-check/the-plan-holds-every-tier ()
  (let* ((jobs (drgnx-check-plan :root drgnx-dir :unit-shards 3 :live-shards 2 :perf t))
         (names (mapcar (lambda (j) (plist-get j :name)) jobs)))
    (should (equal (plist-get (car jobs) :name) "build"))
    (dolist (n '("unit-1" "unit-2" "unit-3" "unit-timing" "ui" "live-1" "live-2" "scenario" "bench" "perf")) (should (member n names)))
    (should (seq-every-p (lambda (j) (plist-get j :gui)) (seq-filter (lambda (j) (member (plist-get j :name) '("ui" "live-1" "scenario" "bench" "perf"))) jobs)))
    (let ((phase (lambda (n) (plist-get (seq-find (lambda (j) (equal (plist-get j :name) n)) jobs) :phase))))
      ;; the parallel phase, then each that measures time alone: the timing unit tests, the bench, perf
      ;; scenarios hold frame budgets (a frame from the daemon < 500 ms): alone too
      (should (equal (mapcar phase '("unit-1" "ui" "live-1" "unit-timing" "scenario" "bench" "perf")) '(2 2 2 3 4 5 6))))
    (should (member "DRGNX_TEST_SELECTOR=(not (tag :timing))" (plist-get (seq-find (lambda (j) (equal (plist-get j :name) "unit-1")) jobs) :env)))
    (should (member "DRGNX_TEST_SELECTOR=(tag :timing)" (plist-get (seq-find (lambda (j) (equal (plist-get j :name) "unit-timing")) jobs) :env)))
    (should-not (member "perf" (mapcar (lambda (j) (plist-get j :name)) (drgnx-check-plan :root drgnx-dir :unit-shards 1 :live-shards 1))))))

;;; check-test.el ends here

;;;; Final review fixes

(ert-deftest drgnx-check/a-job-ended-early-gets-time-to-clean-up ()
  ;; a job's Emacs stops its sessions when told to end: TERM, then time for that, then KILL
  (drgnx-check-test--with dir
    (let ((job (list :name "slow-exit" :phase 2 :timeout 1
                     :command (list "sh" "-c" (format "trap 'sleep 1; echo cleaned > %scleaned; exit 0' TERM; sleep 60 & wait" dir)))))
      (drgnx-check-run (list job) :dir dir :jobs 2 :gui-slots 1)
      (should (file-exists-p (concat dir "cleaned"))))))

(ert-deftest drgnx-check/a-job-never-waits-on-the-terminal ()
  (drgnx-check-test--with dir
    (let* ((t0 (float-time))
           (r (drgnx-check-run (list (list :name "reads" :phase 2 :timeout 5 :command (list "sh" "-c" "read x; echo done")))
                               :dir dir :jobs 2 :gui-slots 1)))
      (should (eq (plist-get (car (plist-get r :jobs)) :status) 'ok))       ; stdin is empty, not an open pipe
      (should (< (- (float-time) t0) 3)))))

(ert-deftest drgnx-check/a-bad-number-is-refused-not-run ()
  ;; the arguments only: a bad one is said, never a run (--jobs 0 used to loop for ever)
  (dolist (args '(("--jobs" "abc") ("--jobs" "0") ("--shards") ("--jobs" "-2") ("--frobnicate")))
    (should (stringp (plist-get (drgnx-check--parse-args args) :error))))
  (should (equal (drgnx-check--parse-args '("--jobs" "6" "--no-perf"))
                 '(:jobs 6 :shards 4 :perf nil :gui t))))

(ert-deftest drgnx-check/perf-on-a-busy-machine-is-not-judged-and-not-a-pass ()
  ;; bin/drgnx test --perf exits 3 when the machine was too busy to measure (no history line written)
  (drgnx-check-test--with dir
    (let* ((r (drgnx-check-run (list (drgnx-check-test--job dir "perf" 5 :code 3 :not-judged 3)) :dir dir :jobs 2 :gui-slots 1)))
      (should (eq (plist-get (car (plist-get r :jobs)) :status) 'not-judged))
      (should (string-match-p "perf +NOT JUDGED (busy)" (drgnx-check-summary r)))
      (should (eql (drgnx-check-exit-code r) 1))))
  (should (eql 3 (plist-get (seq-find (lambda (j) (equal (plist-get j :name) "perf"))
                                      (drgnx-check-plan :root drgnx-dir :unit-shards 1 :live-shards 1 :perf t))
                            :not-judged))))
