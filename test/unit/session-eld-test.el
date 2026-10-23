;;; session-eld-test.el --- batch tests: the keep-running choice, a setting -*- lexical-binding: t -*-
;; Every test runs under `drgnx-test-with-areas' (temp config and state folders), so nothing reaches ~.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/areas-fixture" drgnx-dir) nil t)
(require 'drgnx-session)

(defun drgnx-session-eld-test--text () (drgnx-test-areas-text))

(ert-deftest drgnx-session-eld/the-setting-is-read-when-a-window-closes ()
  (let ((meta (drgnx-setting-meta 'drgnx-session-keep-running)))
    (should (eq (plist-get meta :scope) 'global))
    (should (eq (plist-get meta :workspace) 'never))
    (should-not (plist-get meta :apply)))              ; read on use: nothing to apply
  (should (eq (indirect-variable 'drgnx-keep-running) 'drgnx-session-keep-running))
  (should (eq (default-value 'drgnx-session-keep-running) t)))

(ert-deftest drgnx-session-eld/a-process-that-has-not-applied-settings-el-reads-the-choice ()
  (drgnx-test-with-areas
    (should (eq (cdar (drgnx-settings-area-values '(drgnx-session-keep-running))) t))
    (drgnx-test-areas-put-entries '((drgnx-session-keep-running . nil)))
    (should-not (cdar (drgnx-settings-area-values '(drgnx-session-keep-running))))
    (drgnx-test-areas-put-entries '((drgnx-session-keep-running . "yes please")))     ; refused by its type: the default
    (should (eq (cdar (drgnx-settings-area-values '(drgnx-session-keep-running))) t))))

(ert-deftest drgnx-session-eld/a-mistake-in-the-file-refuses-every-writer ()
  (drgnx-test-with-areas
    (let ((drgnx-keep-running t)
          (broken ";; half typed\n(drgnx-settings :version 1 (drgnx-session-keep-running nil)\n"))
      (drgnx-test-areas-put broken)
      (should-error (drgnx-session-set-keep-running t) :type 'drgnx-settings-refused)
      (should (equal (drgnx-session-eld-test--text) broken))
      (should drgnx-keep-running))))

(ert-deftest drgnx-session-eld/set-keeps-comments ()
  (drgnx-test-with-areas
    (let ((drgnx-keep-running t))
      (drgnx-test-areas-put ";; my settings\n(drgnx-settings\n :version 1\n ;; the session\n (drgnx-session-keep-running t) ; end\n (drgnx-look-theme tango))\n")
      (should-not (drgnx-session-set-keep-running nil))
      (should-not drgnx-keep-running)
      (let ((text (drgnx-session-eld-test--text)))
        (should (string-prefix-p ";; my settings\n(drgnx-settings\n :version 1\n ;; the session\n (drgnx-session-keep-running nil)" text))
        (should (string-search "; end" text))
        (should (string-search "(drgnx-look-theme tango)" text)))
      (should (eq (drgnx-session-set-keep-running t) t))
      (should (string-search "(drgnx-session-keep-running t)" (drgnx-session-eld-test--text))))))

(ert-deftest drgnx-session-eld/a-new-file-holds-the-choice ()
  (drgnx-test-with-areas
    (let ((drgnx-keep-running t))
      (should-not (file-exists-p (drgnx-config-file 'settings)))
      (drgnx-session-set-keep-running nil)
      (should (string-search "(drgnx-session-keep-running nil)" (drgnx-session-eld-test--text)))
      (should-not drgnx-keep-running))))

(ert-deftest drgnx-session-eld/set-reaches-the-settings-writer ()
  (drgnx-test-with-areas
    (let ((drgnx-keep-running t) (seen nil))
      (cl-letf (((symbol-function 'drgnx-settings-area-set) (lambda (&rest args) (setq seen args) nil)))
        (drgnx-session-set-keep-running nil))
      (should (equal seen '(((drgnx-session-keep-running))))))))

(provide 'session-eld-test)
;;; session-eld-test.el ends here
