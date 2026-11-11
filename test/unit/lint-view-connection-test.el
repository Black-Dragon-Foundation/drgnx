;;; lint-view-connection-test.el --- a hub-fed view subscribes on the connection its patches come back on -*- lexical-binding: t -*-
;; test-class: det
;; The hub keys a view by (connection, view): its env, its model and its rows go to the connection that asked.  An
;; editor talks to the hub on two connections: calls (`drgnx-hub-call', `drgnx-hub--client') and the subscribed one
;; (`drgnx-hub--events'), where the view's env goes and its patches come back.  A view subscribed with
;; `drgnx-hub-call' gets no rows at all against a real hub, while a test with one mock connection passes; that hid the
;; Board's and the Explorer's subscriptions (sja-complete, 2026-11-10).  This lint fails on a `drgnx-hub-call' (or
;; `-sync') whose method is a literal `.../subscribe' or `view/...' in core/, wb/ or modules/.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)

(defconst drgnx-lint-view-connection--allowed
  '(("modules/tools/drgnx-agents-editor-here.el" . "agents/presence/subscribe"))
  "(FILE . METHOD) left on the call connection, and why: who is here's old path (no view; its answer fills the cache,
and the code is frozen until it goes).")

(defun drgnx-lint-view-connection--offenders ()
  "(FILE . METHOD) of each view subscription asked on the call connection, not allowed."
  (let (rows)
    (dolist (f (append (directory-files (expand-file-name "core" drgnx-dir) t "\\.el\\'")
                       (directory-files (expand-file-name "wb" drgnx-dir) t "\\.el\\'")
                       (directory-files-recursively (expand-file-name "modules" drgnx-dir) "\\.el\\'")))
      (with-temp-buffer
        (insert-file-contents f)
        (goto-char (point-min))
        (while (re-search-forward "(drgnx-hub-call\\(?:-sync\\)?[ \t\n]+\"\\([^\"]+\\)\"" nil t)
          (let ((method (match-string 1)) (file (file-relative-name f drgnx-dir)))
            (when (and (string-match-p "/subscribe\\'\\|\\`view/" method)
                       (not (member (cons file method) drgnx-lint-view-connection--allowed)))
              (push (cons file method) rows))))))
    (nreverse rows)))

(ert-deftest drgnx-lint/views-subscribe-on-the-events-connection ()
  "Every hub-fed view subscribes on `drgnx-hub--events' (`drgnx-work-client--call' or `drgnx-hub--call-on'), never
with `drgnx-hub-call': the hub sends a view's rows to the connection that asked."
  (should (equal nil (drgnx-lint-view-connection--offenders))))

;;; lint-view-connection-test.el ends here
