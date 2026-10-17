;;; scenario-test.el --- batch tests: scenario helpers -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-scenario)

(defconst drgnx-scenario-test--fixtures
  (expand-file-name "../fixtures/" (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest drgnx-scenario/known-red-table ()
  (let ((process-environment (append (list "DRGNX_SCENARIO_CONFIG=minimal"
                                           (concat "DRGNX_UI_TEST=" drgnx-scenario-test--fixtures "scenario-ok"))
                                     process-environment)))
    (should (drgnx-scenario-known-red-p 'drgnx-fixture/known-red-assertion))
    (should-not (drgnx-scenario-known-red-p 'drgnx-fixture/green))
    (should (eq (drgnx-scenario-expected 'drgnx-fixture/known-red-assertion) :failed))
    (should (eq (drgnx-scenario-expected 'drgnx-fixture/green) :passed))
    (let ((process-environment (cons "DRGNX_SCENARIO_CONFIG=drgnx" process-environment)))
      (should (eq (drgnx-scenario-expected 'drgnx-fixture/known-red-assertion) :passed)))))

(ert-deftest drgnx-scenario/check-signals-an-assertion-with-the-trace ()
  (let ((err (should-error (drgnx-scenario-check nil "snapped back"
                                                 '(:trace [(:t_ms 196 :cause "timer:follow" :window "w3"
                                                                  :fields ["point"] :from (:point 17) :to (:point 36))]))
                           :type 'ert-test-failed)))
    (should (equal (plist-get (cadr err) :scenario) "snapped back"))
    (should (equal (plist-get (cadr err) :trace) ["+196 ms  timer:follow  w3 point 17 → 36"]))))

(ert-deftest drgnx-scenario/check-passes-silently ()
  (should (eq (drgnx-scenario-check t "fine" nil) t)))

(ert-deftest drgnx-scenario/fixture-repo ()
  (let (dir)
    (drgnx-scenario-with-fixture (root 'basic)
      (setq dir root)
      (should (file-exists-p (expand-file-name "src/app/main.py" root)))
      (should (file-directory-p (expand-file-name ".git" root))))
    (should-not (file-exists-p dir))))

(ert-deftest drgnx-scenario/unsettled-measurement-is-an-error-not-a-red ()
  (let ((err (should-error (drgnx-scenario-check nil "x" '(:settled :false :trace [])))))
    (should-not (eq (car err) 'ert-test-failed))))

(ert-deftest drgnx-scenario/require-is-an-error-not-a-red ()
  (should (eq (drgnx-scenario-require t "fine") t))
  (let ((err (should-error (drgnx-scenario-require nil "the Explorer shows the fixture"))))
    (should-not (eq (car err) 'ert-test-failed))
    (should (string-search "the Explorer shows the fixture" (error-message-string err)))))

(ert-deftest drgnx-scenario/unsettled-error-shows-what-kept-changing ()
  (let ((err (should-error (drgnx-scenario-check
                            nil "x" '(:settled :false
                                               :trace [(:t_ms 4900 :cause "timer:busy" :window "w1" :fields ["point"]
                                                              :from (:point 1) :to (:point 2))])))))
    (should (string-search "+4900 ms  timer:busy  w1 point 1 → 2" (error-message-string err)))))

(ert-deftest drgnx-scenario/a-fixture-leaves-no-buffers-roots-or-stale-fixtures ()
  ;; buffers in the fixture (dired too) go with it, Explorer roots in it are dropped, and fixtures this user
  ;; left behind (a run killed at its timeout) a day ago are deleted when the next is made
  (let* ((temporary-file-directory (file-name-as-directory (make-temp-file "drgnx-scenario-tmp" t)))
         (old (expand-file-name "drgnx-fixture-basic-old" temporary-file-directory))
         (recent (expand-file-name "drgnx-fixture-basic-recent" temporary-file-directory))
         (roots nil) dir buffers)
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-explorer-roots) (lambda () roots))
                  ((symbol-function 'drgnx-explorer-set-roots) (lambda (r) (setq roots r))))
          (make-directory old) (make-directory recent)
          (set-file-times old (time-subtract (current-time) (* 2 86400)))
          (drgnx-scenario-with-fixture (root 'basic)
            (setq dir root roots (list "/elsewhere/" (file-name-as-directory root)))
            (push (dired root) buffers)
            (push (find-file-noselect (expand-file-name "README.md" root)) buffers)
            (push (dired (expand-file-name "src" root)) buffers))
          (should-not (file-exists-p dir))
          (should-not (seq-some #'buffer-live-p buffers))
          (should (equal roots '("/elsewhere/")))
          (should-not (file-exists-p old))
          (should (file-exists-p recent)))
      (mapc (lambda (b) (when (buffer-live-p b) (kill-buffer b))) buffers)
      (delete-directory temporary-file-directory t))))
