;;; large-file-core-test.el --- batch tests: the large-file flag and the predicate producers check -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-large-file)

(ert-deftest drgnx-large-file/the-flag-survives-a-major-mode-change ()
  (with-temp-buffer
    (setq-local drgnx-large-file 'lean)
    (text-mode)
    (should (eq drgnx-large-file 'lean))
    (fundamental-mode)
    (should (eq drgnx-large-file 'lean))
    (should (drgnx-large-file-p))))

(ert-deftest drgnx-large-file/opening-counts-as-large ()
  ;; a lean open runs the major mode before the flag is set: the mode hooks see "large" all the same
  (with-temp-buffer
    (should-not (drgnx-large-file-p))
    (let ((drgnx-large-file--opening 'lean))
      (should (drgnx-large-file-p))
      (should (drgnx-large-file-p (current-buffer))))
    (should-not (drgnx-large-file-p))))

(ert-deftest drgnx-large-file/the-predicate-takes-a-buffer ()
  (let ((big (generate-new-buffer " lf-big")) (small (generate-new-buffer " lf-small")))
    (unwind-protect
        (progn
          (with-current-buffer big (setq-local drgnx-large-file 'chunks))
          (with-current-buffer small
            (should (drgnx-large-file-p big))
            (should-not (drgnx-large-file-p))
            (should-not (drgnx-large-file-p small))
            ;; an open in progress marks only the buffer it runs in
            (let ((drgnx-large-file--opening 'lean))
              (should (drgnx-large-file-p))
              (with-temp-buffer (should-not (drgnx-large-file-p small))))))
      (kill-buffer big)
      (kill-buffer small))))

;;; large-file-core-test.el ends here
