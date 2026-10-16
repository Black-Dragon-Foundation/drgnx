;;; run-ert-test.el --- batch tier sanity -*- lexical-binding: t -*-
(require 'ert)
(ert-deftest drgnx-run-ert/loaded ()
  (should (fboundp 'drgnx-run-ert)))

(defconst drgnx-run-ert-test--fixtures
  (expand-file-name "../fixtures/" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-run-ert-test--batch (dir results &rest env)
  "Run the suite in DIR in a fresh batch Emacs (harness on the load path); return its exit code."
  (let ((process-environment (append (cons (concat "DRGNX_TEST_RESULTS=" results) env) process-environment)))
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
