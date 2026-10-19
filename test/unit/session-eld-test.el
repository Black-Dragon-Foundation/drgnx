;;; session-eld-test.el --- batch tests: session.eld through the config layer -*- lexical-binding: t -*-
;; Every test runs under `drgnx-test-with-config' (temp config and state folders), so nothing reaches ~.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-session)

(defun drgnx-session-eld-test--text () (drgnx-test-config-text 'session))

(ert-deftest drgnx-session-eld/load-sets-the-choice-only-when-the-file-has-the-key ()
  (drgnx-test-with-config
    (let ((drgnx-keep-running t))
      ;; no file: left alone
      (drgnx-session-load)
      (should drgnx-keep-running)
      ;; a file without the key: left alone, in either state
      (drgnx-test-config-put 'session "(:other 1)\n")
      (drgnx-config-reread 'session)
      (setq drgnx-keep-running nil)
      (drgnx-session-load)
      (should-not drgnx-keep-running)
      (setq drgnx-keep-running t)
      (drgnx-session-load)
      (should drgnx-keep-running)
      ;; a file with the key: applied, nil included
      (drgnx-test-config-put 'session "(:keep-running nil)\n")
      (drgnx-config-reread 'session)
      (drgnx-session-load)
      (should-not drgnx-keep-running))))

(ert-deftest drgnx-session-eld/a-mistake-uses-the-last-good-choice ()
  (drgnx-test-with-config
    (let ((drgnx-keep-running t)
          (broken ";; half typed\n(:keep-running nil\n"))
      (drgnx-test-config-put 'session "(:keep-running nil)\n")
      (drgnx-session-load)
      (should-not drgnx-keep-running)
      ;; the user breaks the file: the choice made before stays
      (drgnx-test-config-put 'session broken)
      (drgnx-config-reread 'session)
      (should (drgnx-config-problem 'session))
      (setq drgnx-keep-running t)
      (drgnx-session-load)
      (should-not drgnx-keep-running)
      ;; and no writer replaces the file
      (should-error (drgnx-session-set-keep-running t) :type 'drgnx-config-refused)
      (should (equal (drgnx-session-eld-test--text) broken)))))

(ert-deftest drgnx-session-eld/a-mistake-with-no-good-copy-leaves-the-choice-alone ()
  (drgnx-test-with-config
    (let ((drgnx-keep-running nil)
          (wrong "(:keep-running \"yes please\")\n"))
      (drgnx-test-config-put 'session wrong)
      (drgnx-session-load)
      (should-not drgnx-keep-running)
      (should (drgnx-config-problem 'session))
      (should-error (drgnx-session-set-keep-running t) :type 'drgnx-config-refused)
      (should (equal (drgnx-session-eld-test--text) wrong)))))

(ert-deftest drgnx-session-eld/set-keeps-comments ()
  (drgnx-test-with-config
    (let ((drgnx-keep-running t))
      (drgnx-test-config-put 'session ";; my session\n(:future (1 2) ; an unknown key\n :keep-running t) ; end\n")
      (should-not (drgnx-session-set-keep-running nil))
      (should-not drgnx-keep-running)
      (let ((text (drgnx-session-eld-test--text)))
        (should (string-prefix-p ";; my session\n(:future (1 2) ; an unknown key\n :keep-running " text))
        (should (string-suffix-p ") ; end\n" text))
        (should (string-search ":keep-running nil" text)))
      (should (eq (drgnx-session-set-keep-running t) t))
      (should (string-search ":keep-running t" (drgnx-session-eld-test--text)))
      (should (string-search "; an unknown key" (drgnx-session-eld-test--text))))))

(ert-deftest drgnx-session-eld/a-new-file-holds-the-choice ()
  (drgnx-test-with-config
    (let ((drgnx-keep-running t))
      (should-not (file-exists-p (drgnx-session-file)))
      (drgnx-session-set-keep-running nil)
      (let ((data (read (drgnx-session-eld-test--text))))
        (should (plist-member data :keep-running))
        (should-not (plist-get data :keep-running)))
      (should (equal (drgnx-session-file) (drgnx-config-file 'session))))))

(ert-deftest drgnx-session-eld/set-reaches-the-config-layer ()
  (drgnx-test-with-config
    (let ((drgnx-keep-running t) (seen nil))
      (cl-letf (((symbol-function 'drgnx-config-set) (lambda (&rest args) (setq seen args) nil)))
        (drgnx-session-set-keep-running nil))
      (should (equal seen '(session :keep-running nil))))))

(provide 'session-eld-test)
;;; session-eld-test.el ends here
