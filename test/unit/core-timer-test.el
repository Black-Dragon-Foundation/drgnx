;;; core-timer-test.el --- batch tests: the timer layer — keys, owners, the fire wrapper, failures -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defvar drgnx-timer-test--calls nil "What the test functions saw, newest first.")
(defvar drgnx-timer-test--plan nil "What `drgnx-timer-test--maybe-fail' does at each call, in order: `fail' or `ok'.")
(defvar drgnx-timer-test-hook nil "A global hook a timer function adds to.")

(defun drgnx-timer-test--note (&rest args) (push (cons 'called args) drgnx-timer-test--calls))
(defun drgnx-timer-test--fail (&rest _) (push 'failed drgnx-timer-test--calls) (error "Boom"))
(defun drgnx-timer-test--maybe-fail ()
  (let ((step (pop drgnx-timer-test--plan)))
    (push step drgnx-timer-test--calls)
    (when (eq step 'fail) (error "Boom"))))
(defun drgnx-timer-test--hook-fn () nil)
(defun drgnx-timer-test--add-hook () (add-hook 'drgnx-timer-test-hook #'drgnx-timer-test--hook-fn))

(defun drgnx-timer-test--restart ()
  "A one-shot's FN: notes whether its key is still active, and starts the key again the first time."
  (push (drgnx-timer-active-p 'tm-k) drgnx-timer-test--calls)
  (when (= 1 (length drgnx-timer-test--calls)) (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--restart)))

(defun drgnx-timer-test--where ()
  "Changes the match data and notes the current buffer."
  (string-match "b+" "aabbb")
  (push (current-buffer) drgnx-timer-test--calls))

(defun drgnx-timer-test--seams ()
  "Notes the layer's seams next to the fixture's clock."
  (push (list (float-time (drgnx-timer--idle-time)) (drgnx-timer--input-pending-p)
              (- (drgnx-timer--now) (drgnx-test-clock-now)))
        drgnx-timer-test--calls))

(defmacro drgnx-timer-test--with (&rest body)
  "BODY on the virtual clock, with no recorded timer errors, a state dir of its own, a fresh module table holding
`test/tm', and the test's calls, plan and hook empty; all restored after."
  `(let* ((state (make-temp-file "drgnx-timer-state" t))
          (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
          (drgnx-timer-errors nil) (drgnx-timer-test--calls nil) (drgnx-timer-test--plan nil)
          (drgnx-timer-test-hook nil)
          (drgnx-modules--table (list (list 'test/tm :doc "a module for the timer tests")))
          (drgnx-modules--report nil) (drgnx-modules--stacks nil) (drgnx-modules--runs nil)
          (drgnx-modules--features nil))
     (unwind-protect (drgnx-test-with-clock () ,@body)
       (delete-directory state t))))

(defun drgnx-timer-test--on (setup)
  "Run SETUP as module `test/tm''s setup (a fresh run token); the module is then on."
  (should-not (drgnx-modules--run-setup 'test/tm setup))
  (drgnx-modules--record 'test/tm 'startup 0 'ok))

(defun drgnx-timer-test--report-file () (expand-file-name drgnx-timer-report-file (drgnx-state-dir)))

;;;; Keys

(ert-deftest drgnx-timer/a-second-start-leaves-one-timer ()
  (drgnx-timer-test--with
   (should (eq 'tm-k (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--note)))
   (drgnx-timer-start 'tm-k 2 #'drgnx-timer-test--note :idle t)   ; another kind of Emacs timer: replaced all the same
   (should-not timer-list)
   (should (= 1 (length timer-idle-list)))
   (drgnx-timer-start 'tm-k 2 #'drgnx-timer-test--note)
   (should (= 1 (+ (length timer-list) (length timer-idle-list))))
   (drgnx-test-advance 3)
   (should (= 1 (length drgnx-timer-test--calls)))
   (should-not (drgnx-timer-active-p 'tm-k))))

(ert-deftest drgnx-timer/a-replaced-ripe-timer-does-not-run ()
  (drgnx-timer-test--with
   (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--note :args '(old))
   (let ((old (car timer-list)))
     (drgnx-timer-start 'tm-k 5 #'drgnx-timer-test--note :args '(new))
     ;; as if still on the list `timer_check' copied before the restart: Emacs runs it, the layer does not call FN
     (timer-activate old)
     (timer-event-handler old)
     (should-not drgnx-timer-test--calls)
     (should (drgnx-timer-active-p 'tm-k))
     (drgnx-test-advance 5)
     (should (equal drgnx-timer-test--calls '((called new)))))))

(ert-deftest drgnx-timer/cancel-owner-counts ()
  (drgnx-timer-test--with
   (with-temp-buffer
     (let ((buf (current-buffer)))
       (drgnx-timer-start (cons 'tm-a buf) 1 #'drgnx-timer-test--note :owner buf)
       (drgnx-timer-start (cons 'tm-b buf) 1 #'drgnx-timer-test--note :owner buf :repeat 1)
       (drgnx-timer-start 'tm-c 1 #'drgnx-timer-test--note)
       (should (= 2 (drgnx-timer-cancel-owner buf)))
       (should (= 0 (drgnx-timer-cancel-owner buf)))
       (should (= 1 (length timer-list)))
       (should (drgnx-timer-active-p 'tm-c))
       ;; a module symbol matches every run of the module
       (drgnx-timer-test--on #'ignore)
       (drgnx-timer-start 'tm-m1 1 #'drgnx-timer-test--note :owner 'test/tm)
       (setf (alist-get 'test/tm drgnx-modules--runs) (list 'test/tm))   ; a new run's token
       (drgnx-timer-start 'tm-m2 1 #'drgnx-timer-test--note :owner 'test/tm)
       (should (= 2 (drgnx-timer-cancel-owner 'test/tm)))
       (should (= 1 (drgnx-timer-cancel-owner :core)))
       (should-not timer-list)
       (should-not (drgnx-timer-cancel 'tm-c))))))

(ert-deftest drgnx-timer/keys-must-not-hold-mutable-objects ()
  (drgnx-timer-test--with
   (dolist (key (list (list 'tm-k 1 2) (cons 'tm-k (record 'tm-struct 1)) (cons 'tm-k (vector 1)) '("tm-k" . 1)
                      (cons 'tm-k (list 'a)) nil 3 "tm-k"))
     (should-error (drgnx-timer-start key 1 #'drgnx-timer-test--note) :type 'wrong-type-argument))
   (should-not timer-list)
   (should (= 0 (hash-table-count drgnx-timer--table)))
   (with-temp-buffer
     (let ((ok (list 'tm-k (cons 'tm-k 'a) (cons 'tm-k 3) (cons 'tm-k "s") (cons 'tm-k (current-buffer))
                     (cons 'tm-k (selected-window)) (cons 'tm-k (selected-frame)))))
       (dolist (key ok) (should (equal key (drgnx-timer-start key 1 #'drgnx-timer-test--note))))
       (should (= (length ok) (length timer-list)))
       (drgnx-timer-reset)))))

(ert-deftest drgnx-timer/fn-must-be-a-symbol ()
  (drgnx-timer-test--with
   (dolist (fn (list nil (lambda () 1) (apply-partially #'+ 1) "drgnx-timer-test--note"))
     (should-error (drgnx-timer-start 'tm-k 1 fn) :type 'wrong-type-argument))
   (should-not timer-list)
   (should-not (drgnx-timer-active-p 'tm-k))))

(ert-deftest drgnx-timer/a-wall-repeat-must-be-seconds ()
  ;; Emacs 31's `run-at-time' refuses a REPEAT that is not a number; Emacs 30 took t and ran the timer once.  The
  ;; layer refuses it on every Emacs, so a setup with `:repeat t' on a wall timer fails here and not only on 31.
  (drgnx-timer-test--with
   (dolist (repeat (list t 'yes "30"))
     (should-error (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--note :repeat repeat) :type 'wrong-type-argument))
   (should-not timer-list)
   (should-not (drgnx-timer-active-p 'tm-k))
   ;; seconds, and an idle timer's non-nil, are fine
   (should (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--note :repeat 30))
   (should (drgnx-timer-start 'tm-i 1 #'drgnx-timer-test--note :repeat t :idle t))
   (drgnx-timer-reset)))

;;;; Owners

(ert-deftest drgnx-timer/a-dead-owner-is-never-called ()
  (drgnx-timer-test--with
   ;; a killed buffer: its own kill-buffer-hook entry cancels the timer at once (no global hook)
   (let ((buf (generate-new-buffer " tm-owner")))
     (drgnx-timer-start (cons 'tm-k buf) 1 #'drgnx-timer-test--note :owner buf :repeat 1)
     (should (memq #'drgnx-timer--buffer-killed (buffer-local-value 'kill-buffer-hook buf)))
     (should-not (memq #'drgnx-timer--buffer-killed (default-value 'kill-buffer-hook)))
     (with-current-buffer buf (fundamental-mode))   ; a major mode change keeps the key list and the hook
     (should (buffer-local-value 'drgnx-timer--buffer-keys buf))
     (kill-buffer buf)
     (should (= 0 (hash-table-count drgnx-timer--table)))
     (should-not timer-list))
   ;; a buffer made with inhibit-buffer-hooks: no kill-buffer-hook, so dropped when it fires
   (let ((buf (generate-new-buffer " tm-owner" t)))
     (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--note :owner buf :repeat 1)
     (kill-buffer buf)
     (should (drgnx-timer-active-p 'tm-k))
     (drgnx-test-advance 2)
     (should-not (drgnx-timer-active-p 'tm-k))
     (should-not timer-list))
   ;; a dead process: dropped when it fires
   (let* ((done nil)
          (proc (make-process :name "tm-owner" :command '("true") :noquery t :connection-type 'pipe
                              :sentinel (lambda (_p _e) (setq done t))))
          (until (+ (drgnx-test-real-time) 30)))
     (drgnx-timer-start (cons 'tm-k proc) 1 #'drgnx-timer-test--note :owner proc :repeat 1)
     (while (and (not done) (< (drgnx-test-real-time) until)) (accept-process-output proc 0.05))
     (should done)
     (should-not (drgnx-timer-start 'tm-other 1 #'drgnx-timer-test--note :owner proc))   ; already gone: refused
     (drgnx-test-advance 2)
     (should (= 0 (hash-table-count drgnx-timer--table)))
     (should-not timer-list))
   (should-not drgnx-timer-test--calls)))

(ert-deftest drgnx-timer/a-module-turned-off-is-never-called ()
  (drgnx-timer-test--with
   (drgnx-timer-test--on (lambda () (drgnx-timer-start 'tm-setup 1 #'drgnx-timer-test--note :repeat 1)))
   ;; later code (a hook function) names its module
   (drgnx-timer-start 'tm-later 1 #'drgnx-timer-test--note :owner 'test/tm :repeat 1)
   (drgnx-timer-start 'tm-idle 1 #'drgnx-timer-test--note :owner 'test/tm :idle t :repeat t)
   (should-not (drgnx-module-teardown 'test/tm))
   (drgnx-test-advance 3)
   (drgnx-test-idle 2)
   (should-not drgnx-timer-test--calls)
   (should-not (drgnx-timer-active-p 'tm-later))
   (should-not (drgnx-timer-active-p 'tm-idle))
   (should-not timer-idle-list)
   (drgnx-timer-reset)))   ; a no-op since the run-end hook: tm-setup's key went with the run (drgnx-timer-own tests)

(ert-deftest drgnx-timer/a-module-with-no-run-refuses-the-start ()
  (drgnx-timer-test--with
   (should-not (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--note :owner 'test/never))
   (drgnx-timer-test--on #'ignore)
   (should-not (drgnx-module-teardown 'test/tm))
   (should-not (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--note :owner 'test/tm))   ; turned off: no run
   (let ((buf (generate-new-buffer " tm-owner")))
     (kill-buffer buf)
     (should-not (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--note :owner buf)))
   (should-not (drgnx-timer-active-p 'tm-k))
   (should-not timer-list)
   (should-error (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--note :owner :none) :type 'wrong-type-argument)))

(ert-deftest drgnx-timer/the-default-owner-is-the-running-setup ()
  (drgnx-timer-test--with
   (let (later)
     (drgnx-timer-test--on (lambda ()
                             (drgnx-timer-start 'tm-setup 1 #'drgnx-timer-test--note)
                             (setq later (drgnx-modules-with-owner
                                           (drgnx-timer-start 'tm-deferred 1 #'drgnx-timer-test--note)))))
     (funcall later)
     (let ((pending (drgnx-timer-pending)) (token (alist-get 'test/tm drgnx-modules--runs)))
       (should (member '(tm-setup test/tm start) pending))
       (should (member '(tm-deferred test/tm start) pending))
       (should (eq token (drgnx-timer--entry-token (gethash 'tm-setup drgnx-timer--table))))
       (should (eq token (drgnx-timer--entry-token (gethash 'tm-deferred drgnx-timer--table)))))
     (drgnx-timer-reset))))

(ert-deftest drgnx-timer/core-outside-a-setup ()
  (drgnx-timer-test--with
   (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--note)
   (should (equal (drgnx-timer-pending) '((tm-k :core start))))
   (should (equal (drgnx-timer--owner nil) '(:core)))
   (should (drgnx-timer-cancel 'tm-k))
   (should-not (drgnx-timer-cancel 'tm-k))))

;;;; The fire wrapper

(ert-deftest drgnx-timer/a-one-shot-leaves-the-table-before-fn ()
  (drgnx-timer-test--with
   (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--restart)
   (drgnx-test-advance 1)
   (should (equal drgnx-timer-test--calls '(nil)))   ; FN saw its key gone
   (should (drgnx-timer-active-p 'tm-k))             ; and its restart stands
   (drgnx-test-advance 1)
   (should (equal drgnx-timer-test--calls '(nil nil)))
   (should-not (drgnx-timer-active-p 'tm-k))))

(ert-deftest drgnx-timer/fn-runs-in-its-buffer-and-keeps-match-data ()
  (drgnx-timer-test--with
   (with-temp-buffer
     (let ((buf (current-buffer)))
       (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--where :owner buf)
       (with-temp-buffer
         (should (string-match "x\\(y\\)" "axyz"))
         (let ((md (match-data)))
           (drgnx-test-advance 1)
           (should (equal (match-data) md))
           (should (equal drgnx-timer-test--calls (list buf)))))))))

(ert-deftest drgnx-timer/a-module-one-shot-is-recorded ()
  (drgnx-timer-test--with
   (drgnx-timer-test--on #'ignore)
   (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--add-hook :owner 'test/tm)
   (drgnx-test-advance 1)
   (should (memq #'drgnx-timer-test--hook-fn drgnx-timer-test-hook))
   (should (alist-get 'test/tm drgnx-modules--stacks))       ; its add-hook went on the module's stack
   (should-not (drgnx-module-teardown 'test/tm))
   (should-not (memq #'drgnx-timer-test--hook-fn drgnx-timer-test-hook))))

(ert-deftest drgnx-timer/a-repeat-is-not-recorded ()
  (drgnx-timer-test--with
   (drgnx-timer-test--on #'ignore)
   (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--add-hook :owner 'test/tm :repeat 1)
   (drgnx-test-advance 1)
   (should (memq #'drgnx-timer-test--hook-fn drgnx-timer-test-hook))
   (should-not (alist-get 'test/tm drgnx-modules--stacks))   ; no net around a repeat: nothing recorded
   (should-not (drgnx-module-teardown 'test/tm))
   (should (memq #'drgnx-timer-test--hook-fn drgnx-timer-test-hook))
   (drgnx-test-advance 1)                                     ; its owner is gone: dropped, not called
   (should-not (drgnx-timer-active-p 'tm-k))
   (should-not timer-list)))

;;;; Failures

(ert-deftest drgnx-timer/three-failures-in-a-row-stop-and-record ()
  (drgnx-timer-test--with
   (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--fail :repeat 1)
   (drgnx-test-advance 10)
   (should (= 3 (length drgnx-timer-test--calls)))
   (should-not (drgnx-timer-active-p 'tm-k))
   (should-not timer-list)
   (should (= 3 (length drgnx-timer-errors)))
   (let ((e (car drgnx-timer-errors)))
     (should (eq (plist-get e :key) 'tm-k))
     (should (eq (plist-get e :owner) :core))
     (should (eq (plist-get e :fn) 'drgnx-timer-test--fail))
     (should (equal (plist-get e :error) "Boom"))
     (should (= 3 (plist-get e :failures)))
     (should (plist-get e :stopped))
     (should (< (abs (- (plist-get e :time) (drgnx-test-clock-now) -7)) 1e-3)))   ; virtual time of the third run
   (should (equal (mapcar (lambda (e) (list (plist-get e :failures) (plist-get e :stopped))) drgnx-timer-errors)
                  '((3 t) (2 nil) (1 nil))))))

(ert-deftest drgnx-timer/a-success-resets-the-count ()
  (drgnx-timer-test--with
   (setq drgnx-timer-test--plan '(fail fail ok fail fail ok fail fail fail))
   (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--maybe-fail :repeat 1)
   (drgnx-test-advance 6)
   (should (drgnx-timer-active-p 'tm-k))
   (should (equal (mapcar (lambda (e) (plist-get e :failures)) drgnx-timer-errors) '(2 1 2 1)))
   (drgnx-test-advance 3)
   (should-not (drgnx-timer-active-p 'tm-k))
   (should (plist-get (car drgnx-timer-errors) :stopped))))

(ert-deftest drgnx-timer/a-one-shot-failure-is-recorded ()
  (drgnx-timer-test--with
   (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--fail)
   (drgnx-test-advance 1)
   (should (= 1 (length drgnx-timer-errors)))
   (should (= 1 (plist-get (car drgnx-timer-errors) :failures)))
   (should-not (plist-get (car drgnx-timer-errors) :stopped))
   (should-not (drgnx-timer-active-p 'tm-k))
   (should-not (file-exists-p (drgnx-timer-test--report-file)))))   ; nothing stopped: no report

(ert-deftest drgnx-timer/errors-are-capped-at-50 ()
  (drgnx-timer-test--with
   ;; due 10 ms apart, so they run in the order started (Emacs leaves the order of equal times open)
   (dotimes (i 60) (drgnx-timer-start (cons 'tm-k i) (+ 1 (* i 0.01)) #'drgnx-timer-test--fail))
   (drgnx-test-advance 2)
   (should (= 60 (length drgnx-timer-test--calls)))
   (should (= 50 (length drgnx-timer-errors)))
   (should (equal (plist-get (car drgnx-timer-errors) :key) '(tm-k . 59)))
   (should (equal (plist-get (car (last drgnx-timer-errors)) :key) '(tm-k . 10)))))

(ert-deftest drgnx-timer/no-debugger-in-batch ()
  (drgnx-timer-test--with
   (let* ((entered nil)
          (debug-on-error t)
          (debugger (lambda (&rest _) (setq entered t) nil)))
     (drgnx-timer-start 'tm-k 1 #'drgnx-timer-test--fail :repeat 1)
     (drgnx-test-advance 1)
     (should-not entered)
     (should (= 1 (length drgnx-timer-errors)))
     (should (drgnx-timer-active-p 'tm-k))
     (drgnx-timer-cancel 'tm-k))
   ;; a daemon with no client frame has only the initial terminal: no debugger either
   (let ((noninteractive nil)) (should-not (drgnx-timer--debugger-p)))))

(ert-deftest drgnx-timer/a-stop-writes-the-report ()
  (drgnx-timer-test--with
   (with-temp-buffer
     (let ((buf (current-buffer)) (file (drgnx-timer-test--report-file)))
       (should (string-prefix-p (file-name-as-directory state) file))   ; the test's own state dir
       (drgnx-timer-start (cons 'tm-k buf) 1 #'drgnx-timer-test--fail :owner buf :repeat 1)
       (drgnx-test-advance 3)
       (should (file-exists-p file))
       (let* ((report (with-temp-buffer (insert-file-contents file) (read (current-buffer))))
              (stopped (plist-get report :stopped))
              (e (car stopped)))
         (should (= 1 (length stopped)))
         (should (eq (car (plist-get e :key)) 'tm-k))
         (should (stringp (cdr (plist-get e :key))))   ; a buffer is written as its printed form: the file stays readable
         (should (stringp (plist-get e :owner)))
         (should (eq (plist-get e :fn) 'drgnx-timer-test--fail))
         (should (equal (plist-get e :error) "Boom"))
         (should (eq (plist-get e :stopped) t)))))))

;;;; Reads

(ert-deftest drgnx-timer/describe-names-key-owner-kind-fn ()
  (drgnx-timer-test--with
   (with-temp-buffer
     (drgnx-timer-test--on #'ignore)
     (drgnx-timer-start 'tm-a 1 #'drgnx-timer-test--note :owner 'test/tm)
     (drgnx-timer-start (cons 'tm-b (current-buffer)) 2 #'drgnx-timer-test--note :owner (current-buffer) :idle t)
     (let ((raw (run-at-time 3 nil #'drgnx-timer-test--note)))
       (should (equal (drgnx-timer-describe (car timer-list))
                      '(:key tm-a :owner test/tm :kind start :fn drgnx-timer-test--note)))
       (should (equal (drgnx-timer-describe (car timer-idle-list))
                      (list :key (cons 'tm-b (current-buffer)) :owner (current-buffer) :kind 'start
                            :fn 'drgnx-timer-test--note)))
       (should-not (drgnx-timer-describe raw))
       (should-not (drgnx-timer-describe 'tm-a))
       (cancel-timer raw)
       (drgnx-timer-reset)))))

(ert-deftest drgnx-timer/pending-lists-live-keys ()
  (drgnx-timer-test--with
   (should-not (drgnx-timer-pending))
   (drgnx-timer-start 'tm-a 1 #'drgnx-timer-test--note)
   (drgnx-timer-start 'tm-b 1 #'drgnx-timer-test--note :repeat 1)
   (let ((p (drgnx-timer-pending)))
     (should (= 2 (length p)))
     (should (member '(tm-a :core start) p))
     (should (member '(tm-b :core start) p)))
   (drgnx-test-advance 1)
   (should (equal (drgnx-timer-pending) '((tm-b :core start))))
   (drgnx-timer-cancel 'tm-b)
   (should-not (drgnx-timer-pending))))

(ert-deftest drgnx-timer/reset-cancels-all ()
  (drgnx-timer-test--with
   (with-temp-buffer
     (let ((raw (run-at-time 5 nil #'drgnx-timer-test--note)))
       (drgnx-timer-start 'tm-a 1 #'drgnx-timer-test--note)
       (drgnx-timer-start 'tm-b 1 #'drgnx-timer-test--note :idle t :repeat t)
       (drgnx-timer-start (cons 'tm-c (current-buffer)) 1 #'drgnx-timer-test--note :owner (current-buffer))
       (drgnx-timer-reset)
       (should (= 0 (hash-table-count drgnx-timer--table)))
       (should-not timer-idle-list)
       (should (equal timer-list (list raw)))   ; a timer the layer did not make is never cancelled
       (cancel-timer raw)))))

;;;; The contract with the clock fixture (spec §8)

(ert-deftest drgnx-timer/the-clock-fixture-drives-the-seams ()
  ;; point 1, against the layer's real seams (the fixture's own test fakes them)
  (drgnx-timer-test--with
   (dolist (seam '(drgnx-timer--now drgnx-timer--idle-time drgnx-timer--input-pending-p))
     (should (advice--p (symbol-function seam))))
   (should (< (abs (- (drgnx-timer--now) (drgnx-test-clock-now))) 1e-6))
   (should (< (abs (- (drgnx-timer-now) (drgnx-test-clock-now))) 1e-6))
   (should-not (drgnx-timer--idle-time))
   (should-not (drgnx-timer--input-pending-p))
   (drgnx-test-advance 2)
   (should (< (abs (- (drgnx-timer-now) (drgnx-test-clock-now))) 1e-6))
   (drgnx-timer-start 'tm-k 0.5 #'drgnx-timer-test--seams :idle t)
   (drgnx-test-idle 1)
   (should (equal (length drgnx-timer-test--calls) 1))
   (pcase-let ((`(,idle ,input ,skew) (car drgnx-timer-test--calls)))
     (should (< (abs (- idle 0.5)) 1e-6))
     (should-not input)
     (should (< (abs skew) 1e-6))))
  (dolist (seam '(drgnx-timer--now drgnx-timer--idle-time drgnx-timer--input-pending-p))
    (should-not (advice--p (symbol-function seam))))
  (should (< (abs (- (drgnx-timer-now) (drgnx-test-real-time))) 1)))

(ert-deftest drgnx-timer/pending-layer-timers-are-named-and-cleared ()
  ;; point 4: the end check names a pending layer timer by key, owner and kind, then the table is empty
  (let ((drgnx-timer-test--calls nil))
    (let ((err (should-error (drgnx-test-with-clock ()
                               (drgnx-timer-start 'tm-left 5 #'drgnx-timer-test--note))
                             :type 'ert-test-failed)))
      (should (string-match-p "(tm-left :core start)" (format "%S" err))))
    (should (= 0 (hash-table-count drgnx-timer--table)))
    (should-not drgnx-timer-test--calls)))

(ert-deftest drgnx-timer/reset-clears-the-table-whatever-an-entry-holds ()
  ;; An entry whose "timer" is not one (a test's stub) never makes `drgnx-timer-reset' signal or stop early.
  (cl-letf (((symbol-function 'run-with-idle-timer) (lambda (&rest _) (list 'not-a-timer))))
    (drgnx-timer-start 'tm-bad 5 #'drgnx-timer-test--note :idle t)
    (drgnx-timer-start 'tm-bad2 5 #'drgnx-timer-test--note :idle t))
  (drgnx-timer-start 'tm-good 5 #'drgnx-timer-test--note)
  (let ((good (gethash 'tm-good drgnx-timer--table)))
    (unwind-protect
        (progn (drgnx-timer-reset)
               (should-not (drgnx-timer-pending))
               (should-not (memq (drgnx-timer--entry-timer good) timer-list)))
      (clrhash drgnx-timer--table))))

(provide 'core-timer-test)
;;; core-timer-test.el ends here
