;;; run-ert-test.el --- batch tier sanity -*- lexical-binding: t -*-
(require 'ert)
(ert-deftest drgnx-run-ert/loaded ()
  (should (fboundp 'drgnx-run-ert)))

(defconst drgnx-run-ert-test--fixtures
  (expand-file-name "../fixtures/" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-run-ert-test--batch (dir results &rest env)
  "Run the suite in DIR in a fresh batch Emacs (harness on the load path); return its exit code."
  (let ((process-environment (append (cons (concat "DRGNX_TEST_RESULTS=" results) env)
                                     (list "DRGNX_TEST_SELECTOR")           ; not this run's selector
                                     process-environment))
        ;; never a buffer's deleted directory, which call-process refuses
        (default-directory (if (file-directory-p default-directory) default-directory temporary-file-directory)))
    (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                  "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                  "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" dir)))

(defun drgnx-run-ert-test--json (file)
  (json-parse-string (with-temp-buffer (insert-file-contents file) (buffer-string)) :object-type 'plist))

(ert-deftest drgnx-run-ert/mixed-suite-writes-results-and-fails ()
  (let* ((tmp (make-temp-file "drgnx-ert" t)) (results (expand-file-name "results.json" tmp))
         (fixture (expand-file-name "ert-mixed" drgnx-run-ert-test--fixtures)))
    (unwind-protect
        (progn
          (should (= (drgnx-run-ert-test--batch fixture results) 1))
          (let ((r (drgnx-run-ert-test--json results)))
            (should (equal (list (plist-get r :total) (plist-get r :passed) (plist-get r :failed)) '(2 1 1)))
            (should (equal (plist-get (aref (plist-get r :failures) 0) :name) "drgnx-fixture/fails"))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/suite-that-fails-to-load-is-a-failure ()
  (let* ((tmp (make-temp-file "drgnx-ert" t)) (results (expand-file-name "results.json" tmp)))
    (unwind-protect
        (progn
          (write-region "(error \"boom\")\n" nil (expand-file-name "broken-test.el" tmp))
          (should (= (drgnx-run-ert-test--batch tmp results) 1))
          (let ((r (drgnx-run-ert-test--json results)))
            (should (= (plist-get r :failed) 1))
            (should (string-prefix-p "load " (plist-get (aref (plist-get r :failures) 0) :name)))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/relative-suite-dir ()
  (let* ((tmp (make-temp-file "drgnx-ert" t)) (results (expand-file-name "results.json" tmp))
         (default-directory drgnx-run-ert-test--fixtures))
    (unwind-protect
        (progn
          (drgnx-run-ert-test--batch "ert-mixed" results)
          (should (= (plist-get (drgnx-run-ert-test--json results) :total) 2)))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/known-red-assertion-is-expected-with-its-trace ()
  (let* ((tmp (make-temp-file "drgnx-ert" t)) (results (expand-file-name "results.json" tmp))
         (dir (expand-file-name "scenario-ok" drgnx-run-ert-test--fixtures)))
    (unwind-protect
        (progn
          (should (= (drgnx-run-ert-test--batch dir results "DRGNX_SCENARIO_CONFIG=minimal"
                                                (concat "DRGNX_UI_TEST=" dir))
                     0))
          (let* ((r (drgnx-run-ert-test--json results))
                 (red (aref (plist-get r :known_red) 0)))
            (should (= (plist-get r :failed) 0))
            (should (equal (plist-get red :name) "drgnx-fixture/known-red-assertion"))
            (should (equal (plist-get red :summary) "the Explorer snapped back"))
            (should (equal (aref (plist-get red :trace) 0) "+196 ms  timer:follow  w3 point 17 → 36"))
            (should (= (length (plist-get r :tests)) 2))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/known-red-error-is-unexpected ()
  (let* ((tmp (make-temp-file "drgnx-ert" t)) (results (expand-file-name "results.json" tmp))
         (dir (expand-file-name "scenario-error" drgnx-run-ert-test--fixtures)))
    (unwind-protect
        (progn
          (should (= (drgnx-run-ert-test--batch dir results "DRGNX_SCENARIO_CONFIG=minimal"
                                                (concat "DRGNX_UI_TEST=" dir))
                     1))
          (should (= (plist-get (drgnx-run-ert-test--json results) :failed) 1)))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/known-red-needs-a-scenario-check ()
  (let* ((tmp (make-temp-file "drgnx-ert" t)) (results (expand-file-name "results.json" tmp))
         (dir (expand-file-name "scenario-bare" drgnx-run-ert-test--fixtures)))
    (unwind-protect
        (should (= (drgnx-run-ert-test--batch dir results "DRGNX_SCENARIO_CONFIG=minimal"
                                              (concat "DRGNX_UI_TEST=" dir))
                   1))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/unit-tests-never-see-the-users-drgnx-dirs ()
  ;; M5 review I9: the batch runner gives the whole suite temp config, data, state and cache dirs.
  (skip-unless (getenv "DRGNX_TEST_ISOLATED"))
  (dolist (v '("DRGNX_CONFIG_DIR" "DRGNX_DATA_DIR" "XDG_STATE_HOME" "XDG_CACHE_HOME" "HOME"))
    (should (string-prefix-p (file-truename temporary-file-directory) (file-truename (getenv v)))))
  (should (string-prefix-p (file-truename temporary-file-directory) (file-truename project-list-file))))

(ert-deftest drgnx-run-ert/a-file-watch-event-does-not-stop-later-sentinels ()
  ;; Batch Emacs has no command loop: a file-notify event waits in the input queue for ever, and while input
  ;; waits Emacs runs no process sentinel (timers still run).  The runner drains the queue after each test.
  (require 'filenotify)
  (let* ((dir (make-temp-file "drgnx-watch" t))
         (default-directory (file-name-as-directory dir))   ; the process below needs an existing directory
         (w (file-notify-add-watch dir '(change) #'ignore)))
    (unwind-protect
        (progn
          (write-region "x" nil (expand-file-name "a" dir) nil 'silent)
          (accept-process-output nil 0.3)                                     ; the event arrives
          (drgnx-run-ert-drain-events)
          (let* ((got nil) (p (make-process :name "after-watch" :command '("true") :sentinel (lambda (&rest _) (setq got t))))
                 (deadline (+ (float-time) 3)))
            (while (and (not got) (< (float-time) deadline)) (accept-process-output nil 0.05))
            (should got)
            (ignore p)))
      (file-notify-rm-watch w)
      (drgnx-run-ert-drain-events)
      (delete-directory dir t))))

(ert-deftest drgnx-run-ert/a-shard-runs-only-its-files-and-results-say-file-and-time ()
  ;; bin/drgnx check runs the unit suite in shards: the runner takes files as well as a directory
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-shard" t))) (results (expand-file-name "r.json" tmp)))
    (unwind-protect
        (progn
          (with-temp-file (concat tmp "one-test.el") (insert "(require 'ert)\n(ert-deftest shard-one () (should t))\n"))
          (with-temp-file (concat tmp "two-test.el") (insert "(require 'ert)\n(ert-deftest shard-two () (should t))\n"))
          (should (eql 0 (let ((process-environment (append (list (concat "DRGNX_TEST_RESULTS=" results) "DRGNX_TEST_SELECTOR")
                                                            process-environment))
                               (default-directory tmp))
                           (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                                         "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                                         "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch"
                                         (concat tmp "one-test.el")))))
          (let ((tests (plist-get (drgnx-run-ert-test--json results) :tests)))
            (should (equal (mapcar (lambda (te) (plist-get te :name)) tests) '("shard-one")))
            (should (equal (file-name-nondirectory (plist-get (aref tests 0) :file)) "one-test.el"))
            (should (numberp (plist-get (aref tests 0) :seconds)))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/a-selector-picks-the-tests-a-run-takes ()
  ;; bin/drgnx check runs the :timing tests alone, after the parallel phase: DRGNX_TEST_SELECTOR
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-sel" t))) (results (expand-file-name "r.json" tmp)))
    (unwind-protect
        (progn
          (with-temp-file (concat tmp "sel-test.el")
            (insert "(require 'ert)\n(ert-deftest sel-fast () :tags '(:timing) (should t))\n(ert-deftest sel-plain () (should t))\n"))
          (let ((process-environment (append (list (concat "DRGNX_TEST_RESULTS=" results) "DRGNX_TEST_SELECTOR=(tag :timing)")
                                             process-environment))
                (default-directory tmp))
            (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                          "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                          "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" (concat tmp "sel-test.el")))
          (should (equal (mapcar (lambda (te) (plist-get te :name)) (plist-get (drgnx-run-ert-test--json results) :tests))
                         '("sel-fast"))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/unit-tests-never-see-the-users-provider-keys ()
  ;; a test that runs the onboarding's AI step (a live test call) must never reach a paid provider
  (skip-unless (getenv "DRGNX_TEST_ISOLATED"))
  (dolist (v '("OPENROUTER_API_KEY" "ANTHROPIC_API_KEY" "ANTHROPIC_AUTH_TOKEN" "OPENAI_API_KEY"))
    (should-not (getenv v))))

(ert-deftest drgnx-run-ert/unit-tests-start-no-hub-unless-they-say-so ()
  ;; an agent on an :ai profile in any test would start a durable hub that outlives the suite
  (skip-unless (getenv "DRGNX_TEST_ISOLATED"))
  (should (equal (getenv "DRGNX_NO_HUB_START") "1")))
