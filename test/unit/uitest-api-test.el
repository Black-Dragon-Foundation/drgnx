;;; uitest-api-test.el --- batch tests: JSON API shapes -*- lexical-binding: t -*-
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
