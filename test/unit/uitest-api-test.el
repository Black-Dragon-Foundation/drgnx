;;; uitest-api-test.el --- batch tests: JSON API shapes -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'drgnx-uitest)

(ert-deftest drgnx-uitest/api-state-is-json ()
  (let ((s (json-parse-string (drgnx-uitest-api-state) :object-type 'plist)))
    (should (plist-get s :frame))
    (should (> (length (plist-get s :windows)) 0))
    (should (stringp (plist-get (aref (plist-get s :windows) 0) :id)))))

(ert-deftest drgnx-uitest/api-keys-queues ()
  (let ((drgnx-uitest--queue nil) (drgnx-uitest--timer 'dummy))
    (should (equal (json-parse-string (drgnx-uitest-api-keys "C-x b") :object-type 'plist)
                   '(:queued 2)))
    (setq drgnx-uitest--queue nil)))

(ert-deftest drgnx-uitest/api-report-is-json ()
  (drgnx-uitest-api-measure-begin)
  (let ((r (json-parse-string (drgnx-uitest-api-measure-end) :object-type 'plist)))
    (should (integerp (plist-get r :settle_ms)))
    (should (vectorp (plist-get r :guard)))))

(ert-deftest drgnx-uitest/frame-hook-timing-is-removed-after-reading ()
  (drgnx-uitest-api-time-frame-hooks)
  (should (advice-member-p #'drgnx-uitest--time-run-hooks 'run-hooks))
  (drgnx-uitest-api-frame-hook-times)
  (should-not (advice-member-p #'drgnx-uitest--time-run-hooks 'run-hooks))
  (should-not (advice-member-p 'drgnx-uitest-frame-time 'make-frame)))

(ert-deftest drgnx-uitest/api-as-refuses-another-id ()
  (let ((drgnx-uitest-session-id "drgnx-ui-1-aaaaaa") (ran nil))
    (should (equal (json-parse-string (drgnx-uitest-api-as "drgnx-ui-2-bbbbbb" (setq ran t) "{}") :object-type 'plist)
                   '(:refused "this session is drgnx-ui-1-aaaaaa, not drgnx-ui-2-bbbbbb")))
    (should-not ran)))

(ert-deftest drgnx-uitest/api-as-runs-for-its-own-id ()
  (let ((drgnx-uitest-session-id "drgnx-ui-1-aaaaaa"))
    (should (equal (drgnx-uitest-api-as "drgnx-ui-1-aaaaaa" (concat "a" "b")) "ab"))))

(defun drgnx-uitest-test--asks-the-hub ()
  "A caller that asks the hub, as a hook in a GUI row would."
  (drgnx-hub--connect-socket #'ignore))

(ert-deftest drgnx-uitest/a-hub-asked-with-none-names-its-callers ()
  ;; the GUI rows run no hub: code that asks one fails, and the error names who asked (`drgnx-uitest--hub-callers')
  (require 'drgnx-hub-client)
  (let* ((root (make-temp-file "drgnx-uitest-hub" t))
         (process-environment (cons (concat "XDG_RUNTIME_DIR=" root) process-environment)))
    (unwind-protect
        (let ((msg (error-message-string (should-error (drgnx-uitest-test--asks-the-hub)))))
          (should (string-search "does not exist (no hub)" msg))
          (should (string-search "called from: " msg))
          (should (string-search "drgnx-uitest-test--asks-the-hub" msg)))
      (delete-directory root t))))
