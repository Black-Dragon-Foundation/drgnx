;;; run-ert-test.el --- batch tier sanity -*- lexical-binding: t -*-
(require 'ert)
(ert-deftest drgnx-run-ert/loaded ()
  (should (fboundp 'drgnx-run-ert)))

(defconst drgnx-run-ert-test--fixtures
  (expand-file-name "../fixtures/" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-run-ert-test--batch (dir results)
  "Run the suite in DIR in a fresh batch Emacs; return its exit code."
  (let ((process-environment (cons (concat "DRGNX_TEST_RESULTS=" results) process-environment)))
    (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                  "--batch" "-Q" "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" dir)))

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
