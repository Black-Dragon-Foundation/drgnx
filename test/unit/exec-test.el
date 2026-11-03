;;; exec-test.el --- batch tests: drgnx-exec, the editor's client for the hub's jobs -*- lexical-binding: t -*-
;; test-class: cond
;; The hub is the real Ratatoskr (DRGNX_RATATOSKR_BIN; the tests skip without it).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-exec)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)

(defmacro drgnx-exec-test--with-hub (root &rest body)
  "BODY with ROOT a fresh folder, the hub's folders under it, a hub serving them and the job cache following it."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-exec" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" ,root "config") (concat "DRGNX_DATA_DIR=" ,root "data")
                                             (concat "XDG_STATE_HOME=" ,root "state") (concat "HOME=" ,root "home"))
                                       process-environment))
          (drgnx-exec--jobs (make-hash-table :test #'equal)) (drgnx-exec--stale nil))
     (dolist (d '("config" "data" "state" "home" "work")) (make-directory (concat ,root d) t))
     (unwind-protect
         (drgnx-test-with-ratatoskr ,root
           (drgnx-exec-sync)
           ,@body)
       (drgnx-exec-unsync)
       (delete-directory ,root t))))

(defun drgnx-exec-test--start (root name argv &rest keys)
  "Start job NAME running ARGV in ROOT's work folder; wait for the callback; its id."
  (let (id why (called nil))
    (apply #'drgnx-exec-start name argv :cwd (concat root "work")
           :callback (lambda (i w) (setq id i why w called t)) keys)
    (drgnx-test-wait (lambda () called) :what "the job's start is answered")
    (should-not why)
    id))

(ert-deftest drgnx-exec/start-is-async ()
  (drgnx-exec-test--with-hub root
    (let ((called nil) id)
      (should-not (drgnx-exec-start "quick" '("true") :cwd (concat root "work")
                                    :callback (lambda (i _w) (setq id i called t))))
      (should-not called)               ; answered by the hub, never inside the call
      (drgnx-test-wait (lambda () called) :what "the start is answered")
      (should (stringp id))
      ;; a start the hub refuses comes back as an error text, not a signal
      (setq called nil id nil)
      (let (why)
        (drgnx-exec-start "bad" '("true") :cwd (concat root "work") :memory-max "lots"
                          :callback (lambda (i w) (setq id i why w called t)))
        (drgnx-test-wait (lambda () called) :what "the refusal is answered")
        (should-not id)
        (should (string-search "a size such as" why))))))

(ert-deftest drgnx-exec/get-reads-the-cache ()
  (drgnx-exec-test--with-hub root
    (let ((fifo (concat root "gate")) id)
      (should (eql 0 (call-process "mkfifo" nil nil nil fifo)))
      (setq id (drgnx-exec-test--start root "held" (list "sh" "-c" (concat "read x < " (shell-quote-argument fifo)))
                                       :env '("JOB_X=1")))
      ;; get and list never call the hub: with every call to it failing they still answer
      (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) (error "the hub was called")))
                ((symbol-function 'drgnx-hub-call-sync) (lambda (&rest _) (error "the hub was called"))))
        (let ((job (drgnx-exec-get id)))
          (should (equal (plist-get job :name) "held"))
          (should (eq (plist-get job :status) 'running))
          (should (equal (plist-get job :cwd) (directory-file-name (file-truename (concat root "work")))))
          (should (stringp (plist-get job :started))))
        (should (equal (mapcar (lambda (j) (plist-get j :id)) (drgnx-exec-list)) (list id))))
      ;; release it, so no job outlives the test
      (make-process :name "exec-test-release" :noquery t :command (list "sh" "-c" (concat "echo go > " (shell-quote-argument fifo))))
      (drgnx-test-wait (lambda () (eq (plist-get (drgnx-exec-get id) :status) 'done)) :what "the held job ends"))))

(ert-deftest drgnx-exec/done-event-updates-the-cache ()
  (drgnx-exec-test--with-hub root
    (let ((ok (drgnx-exec-test--start root "ends-well" '("true")))
          (bad (drgnx-exec-test--start root "ends-badly" '("sh" "-c" "exit 3"))))
      (drgnx-test-wait (lambda () (and (eq (plist-get (drgnx-exec-get ok) :status) 'done)
                                       (eq (plist-get (drgnx-exec-get bad) :status) 'failed)))
                       :what "both jobs' exec-done events reach the cache")
      (should (eql (plist-get (drgnx-exec-get ok) :exit) 0))
      (should (eql (plist-get (drgnx-exec-get bad) :exit) 3))
      ;; a job started by another client is learned from its end
      (let ((other nil))
        (drgnx-hub-call "exec/start" (list :argv ["true"] :cwd (concat root "work") :name "elsewhere")
                        (lambda (r _e) (setq other (plist-get r :id))))
        (drgnx-test-wait (lambda () (and other (eq (plist-get (drgnx-exec-get other) :status) 'done)))
                         :what "a job this client did not start is cached when it ends")
        (should (equal (plist-get (drgnx-exec-get other) :name) "elsewhere"))))))

(ert-deftest drgnx-exec/log-is-command-only ()
  (drgnx-exec-test--with-hub root
    (let ((id (drgnx-exec-test--start root "loud" '("sh" "-c" "echo one; echo two; echo three"))))
      (drgnx-test-wait (lambda () (eq (plist-get (drgnx-exec-get id) :status) 'done)) :what "the job ends")
      (should (equal (drgnx-exec-log id 1000) "one\ntwo\nthree\n"))
      (should (equal (drgnx-exec-log id 6) "three\n"))     ; the end, MAX-BYTES of it
      ;; from a timer or a hook (no interaction) it refuses to wait for the hub
      (let ((inhibit-interaction t))
        (should-error (drgnx-exec-log id 1000))))))

(ert-deftest drgnx-exec/log-reads-the-end-in-one-call ()
  (drgnx-exec-test--with-hub root
    (let ((long (drgnx-exec-test--start root "long" '("seq" "1" "3000")))
          (bytes (drgnx-exec-test--start root "bytes" '("sh" "-c" "printf 'one\\n\\377 end\\n'")))
          (calls 0) (call (symbol-function 'drgnx-hub-call-sync)))
      (drgnx-test-wait (lambda () (and (eq (plist-get (drgnx-exec-get long) :status) 'done)
                                       (eq (plist-get (drgnx-exec-get bytes) :status) 'done)))
                       :what "both jobs end")
      (cl-letf (((symbol-function 'drgnx-hub-call-sync) (lambda (&rest args) (cl-incf calls) (apply call args))))
        ;; the end of a log longer than one slice, asked once: the hub reads the file's end, not all of it
        (should (equal (drgnx-exec-log long 10) "2999\n3000\n"))
        (should (eql calls 1)))
      ;; a byte that is not UTF-8 is replaced, the rest kept
      (let ((log (drgnx-exec-log bytes 100)))
        (should (string-prefix-p "one\n" log))
        (should (string-suffix-p " end\n" log))))))

(provide 'exec-test)
;;; exec-test.el ends here

;;;; the time box, as the request says it (the hub stubbed: only what drgnx-exec-start sends)

(load (expand-file-name "test/fixtures/exec-calls-fixture" drgnx-dir) nil t)

(ert-deftest drgnx-exec/time-box-params ()
  (drgnx-test-with-exec-calls calls
    (drgnx-exec-start "default" '("true") :cwd "/")
    (drgnx-exec-start "boxed" '("true") :cwd "/" :timebox 90.5)
    (drgnx-exec-start "server" '("true") :cwd "/" :no-timebox t)
    (drgnx-exec-start "both" '("true") :cwd "/" :timebox 90 :no-timebox t)
    (pcase-let ((`(,both ,server ,boxed ,default) calls))
      ;; nothing asked: the hub's own default applies
      (should-not (plist-member default :timebox_s))
      (should-not (plist-member default :no_timebox))
      (should (eql (plist-get boxed :timebox_s) 91))
      (should-not (plist-member boxed :no_timebox))
      (should (eq (plist-get server :no_timebox) t))
      (should-not (plist-member server :timebox_s))
      ;; no time box wins over a time box: the hub refuses both together
      (should (eq (plist-get both :no_timebox) t))
      (should-not (plist-member both :timebox_s)))))
