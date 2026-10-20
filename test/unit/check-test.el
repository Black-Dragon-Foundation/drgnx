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

(ert-deftest drgnx-check/the-plan-holds-the-tty-tier-where-tmux-is ()
  ;; the terminal tier runs `bin/drgnx test --tty' (each file in an Emacs of its own, as every shard), counted as a
  ;; GUI job for memory (each session is an Emacs in a tmux server), in the parallel phase; not without tmux or --no-gui
  (let* ((jobs (drgnx-check-plan :root drgnx-dir :tty t))
         (tty (seq-find (lambda (j) (equal (plist-get j :name) "tty")) jobs)))
    (should tty)
    (should (equal (plist-get tty :command) (list (expand-file-name "bin/drgnx" drgnx-dir) "test" "--tty")))
    (should (plist-get tty :gui))
    (should (eql (plist-get tty :phase) 2))
    (should (eql (plist-get tty :timeout) (alist-get 'tty drgnx-check-timeouts)))
    ;; no desktop for the Emacs that runs the tier: a dead bus, no display or compositor, as a unit shard
    (should (member "DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/drgnx-unit-test" (plist-get tty :env)))
    (dolist (v '("DISPLAY" "WAYLAND_DISPLAY" "SWAYSOCK")) (should (member v (plist-get tty :env))))
    (should-not (seq-find (lambda (e) (string-prefix-p "DRGNX_TEST_ONE_PROCESS" e)) (plist-get tty :env))))
  (should-not (seq-find (lambda (j) (equal (plist-get j :name) "tty")) (drgnx-check-plan :root drgnx-dir :tty nil)))
  (should-not (seq-find (lambda (j) (equal (plist-get j :name) "tty")) (drgnx-check-plan :root drgnx-dir :tty t :gui nil))))

(ert-deftest drgnx-check/the-unit-shards-start-without-the-users-desktop ()
  ;; dbus.el connects with the C environment: the shard process gets a dead bus and no display or compositor
  ;; (a live shard too: the sessions its tests start run their own compositor and bus)
  (dolist (n '("unit-1" "unit-timing" "live-1"))
    (let ((env (plist-get (seq-find (lambda (j) (equal (plist-get j :name) n)) (drgnx-check-plan :root drgnx-dir)) :env)))
      (should (member "DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/drgnx-unit-test" env))
      (dolist (v '("DISPLAY" "WAYLAND_DISPLAY" "SWAYSOCK" "I3SOCK" "HYPRLAND_INSTANCE_SIGNATURE" "NIRI_SOCKET"))
        (should (member v env))))))

(ert-deftest drgnx-check/a-live-shard-never-sees-the-real-home-or-provider-keys ()
  ;; A live shard ran with the environment check was started in: the real HOME, session bus and API keys.  It runs
  ;; in the unit tier's sandbox (harness/run-ert.el): a temp HOME, a dead bus, the keys unset.
  (drgnx-check-test--with dir
    (let ((root (concat dir "root/")) (out (concat dir "env.eld")) (home (concat dir "real-home/")))
      (make-directory (concat root "test/unit") t)
      (make-directory (concat root "test/live") t)
      (make-directory home)
      (dolist (d '("harness" "core" "wb")) (make-symbolic-link (expand-file-name d drgnx-dir) (concat root d)))
      (with-temp-file (concat root "test/live/env-test.el")
        (insert (format "(require 'ert)\n(ert-deftest live-env/record ()\n  (with-temp-file %S (prin1 (mapcar #'getenv '(\"HOME\" \"OPENROUTER_API_KEY\" \"ANTHROPIC_API_KEY\" \"ANTHROPIC_AUTH_TOKEN\" \"OPENAI_API_KEY\" \"DBUS_SESSION_BUS_ADDRESS\")) (current-buffer))))\n" out)))
      (let* ((process-environment (append (list (concat "HOME=" home) "OPENROUTER_API_KEY=sk-or-x" "ANTHROPIC_API_KEY=sk-ant-x"
                                                "ANTHROPIC_AUTH_TOKEN=x" "OPENAI_API_KEY=sk-x"
                                                "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1/bus" "DRGNX_TEST_SELECTOR")
                                          process-environment))
             (live (seq-find (lambda (j) (equal (plist-get j :name) "live-1")) (drgnx-check-plan :root root :live-shards 1 :dir dir))))
        (should (plist-get (drgnx-check-run (list live) :dir dir :jobs 1 :gui-slots 1) :ok))
        (pcase-let ((`(,h . ,rest) (with-temp-buffer (insert-file-contents out) (read (current-buffer)))))
          (should-not (string-prefix-p (directory-file-name home) h))
          (should (equal rest '(nil nil nil nil "unix:path=/nonexistent/drgnx-unit-test"))))))))

(ert-deftest drgnx-check/the-ui-job-gets-a-longer-timeout-under-parallel-load ()
  ;; CHK-4: the session test's own 110 s default is too tight next to the parallel shards
  (let ((ui (seq-find (lambda (j) (equal (plist-get j :name) "ui")) (drgnx-check-plan :root drgnx-dir))))
    (should (member "DRGNX_UI_TEST_TIMEOUT=300" (plist-get ui :env)))))

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

(ert-deftest drgnx-check/perf-is-a-plain-job ()
  ;; --perf exits 0 or 1: a busy machine does not make it a third outcome (it judges what load does not move)
  (should-not (plist-member (seq-find (lambda (j) (equal (plist-get j :name) "perf"))
                                      (drgnx-check-plan :root drgnx-dir :unit-shards 1 :live-shards 1 :perf t))
                            :not-judged))
  (drgnx-check-test--with dir
    (let ((r (drgnx-check-run (list (drgnx-check-test--job dir "perf" 5 :code 3)) :dir dir :jobs 2 :gui-slots 1)))
      (should (eq (plist-get (car (plist-get r :jobs)) :status) 'failed))
      (should (string-match-p "perf +FAILED (exit 3)" (drgnx-check-summary r))))))

(ert-deftest drgnx-check/a-group-of-zombies-has-ended ()
  ;; In a container whose PID 1 never reaps (GitHub's job containers), an ended job's processes stay as zombies:
  ;; signal 0 to the group still succeeds, yet nothing runs — waiting for them took the whole grace.
  (let ((procs '((101 (pgrp . 100) (state . "Z")) (102 (pgrp . 100) (state . "Z")) (201 (pgrp . 200) (state . "S")))))
    (cl-letf (((symbol-function 'signal-process) (lambda (_pid _sig) 0))
              ((symbol-function 'list-system-processes) (lambda () (mapcar #'car procs)))
              ((symbol-function 'process-attributes) (lambda (pid) (cdr (assq pid procs)))))
      (should-not (drgnx-check--group-running-p 100))
      (should (drgnx-check--group-running-p 200)))))

(ert-deftest drgnx-check/shards-run-files-apart ()
  ;; Each unit shard runs every file of its share in an Emacs of its own (a hook or feature one file leaves never
  ;; reaches the next); the timing tests, alone in their phase, keep one Emacs.
  (drgnx-check-test--with dir
    (let ((root (concat dir "root/")))
      (make-directory (concat root "test/unit") t)
      (dolist (d '("harness" "core" "wb")) (make-symbolic-link (expand-file-name d drgnx-dir) (concat root d)))
      (with-temp-file (concat root "test/unit/a-leaks-test.el")
        (insert "(require 'ert)\n(defun iso-check--leaked () nil)\n(ert-deftest iso-check-a/leaks () (add-hook 'kill-buffer-hook #'iso-check--leaked) (provide 'iso-check--fake))\n"))
      (with-temp-file (concat root "test/unit/b-clean-test.el")
        (insert "(require 'ert)\n(ert-deftest iso-check-b/clean () (should-not (featurep 'iso-check--fake)) (should-not (memq 'iso-check--leaked (default-value 'kill-buffer-hook))))\n"))
      (let* ((plan (drgnx-check-plan :root root :unit-shards 1 :gui nil :dir dir))
             (unit (seq-find (lambda (j) (equal (plist-get j :name) "unit-1")) plan))
             (timing (seq-find (lambda (j) (equal (plist-get j :name) "unit-timing")) plan))
             (r (drgnx-check-run (list unit) :dir dir :jobs 1 :gui-slots 1)))
        (should (plist-get r :ok))
        (let ((json (json-parse-string (with-temp-buffer (insert-file-contents (concat dir "unit-1.json")) (buffer-string))
                                       :object-type 'plist)))
          (should (equal (list (plist-get json :passed) (plist-get json :failed)) '(2 0)))
          (should (= 2 (length (plist-get json :files)))))
        (should-not (member "DRGNX_TEST_ONE_PROCESS=1" (plist-get unit :env)))
        (should (member "DRGNX_TEST_ONE_PROCESS=1" (plist-get timing :env)))))))

(ert-deftest drgnx-check/the-durations-file-is-written-atomically ()
  ;; a rename that fails keeps the old file as it was and leaves no temp file; the new one is data read back
  (drgnx-check-test--with dir
    (let* ((process-environment (cons (concat "XDG_STATE_HOME=" dir "state") process-environment))
           (file (drgnx-check-durations-file)) old)
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert "((\"a.el\" . 1.5))\n"))
      (setq old (with-temp-buffer (insert-file-contents file) (buffer-string)))
      (with-temp-file (concat dir "unit-1.json")
        (insert "{\"tests\":[{\"file\":\"b.el\",\"seconds\":2.0},{\"file\":\"b.el\",\"seconds\":1.0}]}"))
      (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (signal 'file-error '("Renaming" "no")))))
        (should-error (drgnx-check--save-durations dir) :type 'file-error))
      (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) old))
      (should (equal (directory-files (file-name-directory file)) '("." ".." "durations.eld")))
      (drgnx-check--save-durations dir)
      (should (equal (drgnx-check-durations) '(("b.el" . 3.0) ("a.el" . 1.5))))
      (should (equal (directory-files (file-name-directory file)) '("." ".." "durations.eld"))))))

(ert-deftest drgnx-check/a-durations-file-with-a-mistake-reads-as-no-times ()
  (drgnx-check-test--with dir
    (let* ((process-environment (cons (concat "XDG_STATE_HOME=" dir "state") process-environment))
           (file (drgnx-check-durations-file)))
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert "((\"a.el\" . 1.5)"))
      (should-not (drgnx-check-durations))
      (with-temp-file file (insert "((\"a.el\" . 1.5)) extra"))
      (should-not (drgnx-check-durations)))))

(ert-deftest drgnx-check/leaks-are-merged-across-shards ()
  ;; `check --leaks': the unit jobs run with the census on; the shards' :leaks are one report, each leak once.
  (drgnx-check-test--with dir
    (let ((jobs (drgnx-check-plan :root drgnx-dir :unit-shards 2 :gui nil :dir dir :leaks t))
          (off (drgnx-check-plan :root drgnx-dir :unit-shards 2 :gui nil :dir dir)))
      (dolist (j jobs)
        (when (string-prefix-p "unit" (plist-get j :name))
          (should (member "DRGNX_TEST_LEAKS=1" (plist-get j :env)))))
      (dolist (j off) (should-not (member "DRGNX_TEST_LEAKS=1" (plist-get j :env)))))
    (let ((a '(:test "a/one" :file "/x/a-test.el" :what "hook kill-buffer-hook +a-fn" :source "core/a.el"))
          (b '(:test :null :file "/x/b-test.el" :what "advice ignore +b-fn" :source :null))
          (c '(:test "c/three" :file "/x/c-test.el" :what "timer +c-fn once" :source "core/c.el")))
      (dolist (shard `(("unit-1" ,a ,b) ("unit-2" ,c ,a) ("unit-timing" ,b) ("ui")))
        (with-temp-file (concat dir (car shard) ".json")
          (insert (json-serialize (list :total 1 :passed 1 :failed 0 :failures [] :known_red [] :tests []
                                        :leaks (vconcat (cdr shard)))))))
      ;; a shard that failed to write its summary, or an older one without :leaks, adds nothing
      (with-temp-file (concat dir "unit-3.json") (insert (json-serialize (list :total 0 :tests []))))
      (with-temp-file (concat dir "unit-4.json") (insert "not json"))
      (let ((merged (drgnx-check-leaks dir)))
        (should (= 3 (length merged)))
        (should (equal (mapcar (lambda (l) (plist-get l :what)) merged)
                       '("hook kill-buffer-hook +a-fn" "advice ignore +b-fn" "timer +c-fn once"))))
      (let ((text (drgnx-check-leaks-report (drgnx-check-leaks dir))))
        (should (string-match-p "\\`Leaks (3)" text))
        (should (string-match-p "a/one +a-test\\.el +hook kill-buffer-hook \\+a-fn +\\[core/a\\.el\\]" text))
        (should (string-match-p "advice ignore \\+b-fn" text)))
      (should (equal (drgnx-check-leaks-report nil) "")))
    (should (equal (drgnx-check--parse-args '("--leaks" "--no-perf")) '(:jobs 8 :shards 4 :perf nil :gui t :leaks t)))))
