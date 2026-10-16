;;; runner-test.el --- live tests: the GUI suite runner -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ui)

(ert-deftest drgnx-live/hanging-suite-times-out-without-leftovers ()
  (let ((tmp (make-temp-file "drgnx-hang" t)) (t0 (float-time)))
    (unwind-protect
        (progn
          (write-region "(require 'ert)\n(ert-deftest drgnx-fixture/hangs () (sleep-for 60))\n"
                        nil (expand-file-name "hang-test.el" tmp))
          (pcase-let ((`(,rc ,results ,run) (drgnx-ui-run-ert-session tmp 8)))
            (should-not (eq rc 0))
            (should-not results)
            (should (< (- (float-time) t0) 20))
            (should (equal (with-temp-buffer
                             (call-process "pgrep" nil t nil "-f" "--" (file-name-nondirectory run))
                             (string-trim (buffer-string)))
                           ""))
            (should-not (file-exists-p (expand-file-name (file-name-nondirectory run) (drgnx-ui-runtime-dir))))
            (delete-directory run t)))
      (delete-directory tmp t))))

(ert-deftest drgnx-live/relative-suite-path-and-load-error-fail-fast ()
  (let* ((default-directory temporary-file-directory)   ; the checkout may be read-only (containers)
         (tmp (make-temp-file (expand-file-name "drgnx-rel" default-directory) t))
         (t0 (float-time)))
    (unwind-protect
        (progn
          (write-region "(error \"boom\")\n" nil (expand-file-name "broken-test.el" tmp))
          (pcase-let ((`(,rc ,results ,run) (drgnx-ui-run-ert-session (file-relative-name tmp) 30)))
            (should-not (eq rc 0))
            (should (< (- (float-time) t0) 20))
            (should (= (plist-get results :failed) 1))
            (delete-directory run t)))
      (delete-directory tmp t))))
