;;; extensions-plugins-test.el --- batch tests: plugins in the Extensions view -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: D
;; The hub is not running: rows are fed to the page as the hub sends them (decoded JSON), `drgnx-hub-call' and the
;; settings writer are stubbed to record what the user's commands do.  No process, no timer.  See
;; docs/guide/extensions.md ("Plugins") and docs/guide/plugins.md.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-view)
(require 'drgnx-hub-client)
(require 'drgnx-settings-editors)
(load (expand-file-name "modules/tools/drgnx-plugins-ui" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-list" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-details" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-plugins" drgnx-dir) nil t)

(defvar drgnx-agents-plugins)

(defconst drgnx-extensions-plugins-test--hash-a (make-string 64 ?a))
(defconst drgnx-extensions-plugins-test--hash-b (make-string 64 ?b))

(defun drgnx-extensions-plugins-test--row (&rest plist)
  "A `plugins/list' row for \"rewrite-msg\", with PLIST over its defaults."
  (append plist
          (list :name "rewrite-msg" :version "0.2" :hash drgnx-extensions-plugins-test--hash-a :state "approved"
                :abilities '("fix") :hosts '("x:443")
                :hooks '((:point "before-commit" :verdicts ("allow" "deny"))))))

(ert-deftest drgnx-extensions-plugins/on-appends-at-the-end ()
  (let (committed)
    (cl-letf (((default-value 'drgnx-agents-plugins) '("a" "b"))
              ((symbol-function 'drgnx-settings-editors-commit)
               (lambda (var tab root value) (push (list var tab root value) committed) value))
              ((symbol-function 'drgnx-extensions-plugins-refresh) #'ignore))
      (drgnx-extensions-plugins-set-on "c" t)
      (should (equal committed '((drgnx-agents-plugins user nil ("a" "b" "c")))))
      (setq committed nil)
      (drgnx-extensions-plugins-set-on "a" nil)
      (should (equal (nth 3 (car committed)) '("b")))
      (setq committed nil)
      (drgnx-extensions-plugins-move "a" 1)
      (should (equal (nth 3 (car committed)) '("b" "a")))
      (setq-default drgnx-agents-plugins '("a" "b" "c"))
      (setq committed nil)
      (drgnx-extensions-plugins-move "c" -1)
      (should (equal (nth 3 (car committed)) '("a" "c" "b"))))))

(ert-deftest drgnx-extensions-plugins/the-replace-diff-names-what-is-new ()
  (let* ((old '(:abilities ("fix") :hosts ("x") :hooks ((:point "before-commit" :verdicts ("allow") :tools ("a")))))
         (new '(:abilities ("fix" "fix2") :hosts ("x" "y")
                           :hooks ((:point "before-commit" :verdicts ("allow" "change") :tools ("a" "b"))
                                   (:point "after-edit" :verdicts ("annotate")))))
         (lines (drgnx-extensions-plugins-diff new old)))
    (should (member "New host y" lines))
    (should (member "New ability fix2" lines))
    (should (member "New verdict change at before-commit" lines))
    (should (member "New hook at after-edit" lines))
    (should (member "Wider tools at before-commit: b" lines))
    (should-not (member "New host x" lines))
    (should (null (drgnx-extensions-plugins-diff old old)))))

(ert-deftest drgnx-extensions-plugins/a-changed-page-leads-with-the-diff ()
  (let ((drgnx-plugins--rows
         (list (drgnx-extensions-plugins-test--row
                :state "changed" :hosts '("x:443" "y:443")
                :approved_reach '(:abilities ("fix") :hosts ("x:443") :hooks ((:point "before-commit" :verdicts ("allow" "deny")))))))
        (drgnx-plugins-page-sections (list #'drgnx-extensions-plugins--diff-section)))
    (let ((text (with-temp-buffer (drgnx-plugins-page-insert "rewrite-msg") (buffer-string))))
      (should (string-search "New host y:443" text))
      (should (< (string-search "New host y:443" text) (string-search "What it may reach" text)))
      (should (eq (get-text-property (string-search "New host" text) 'face text)
                  (drgnx-extensions-list--attention))))))

(ert-deftest drgnx-extensions-plugins/a-changed-plugin-without-its-approved-reach-says-so ()
  ;; an approval stored before the hub kept the approved reach, or one whose stored copy does not read
  (let ((drgnx-plugins--rows (list (drgnx-extensions-plugins-test--row :state "changed")))
        (drgnx-plugins-page-sections (list #'drgnx-extensions-plugins--diff-section)))
    (let* ((text (with-temp-buffer (drgnx-plugins-page-insert "rewrite-msg") (buffer-string)))
           (at (string-search "What you approved before is not known: read the whole reach below" text)))
      (should at)
      (should (< at (string-search "What it may reach" text)))
      (should (eq (get-text-property at 'face text) (drgnx-extensions-list--attention))))))

(ert-deftest drgnx-extensions-plugins/approve-sends-the-displayed-hash ()
  (let ((drgnx-plugins--rows (list (drgnx-extensions-plugins-test--row :state "unapproved"))) calls)
    (cl-letf (((symbol-function 'drgnx-hub-call)
               (lambda (method params _cb &rest _) (push (cons method params) calls) 1)))
      (with-temp-buffer
        (drgnx-extensions-details-mode)
        (setq drgnx-extensions-details--id "plugin:rewrite-msg")
        (drgnx-extensions-plugins-page-text "rewrite-msg")
        ;; the files change on disk after the page was drawn: the list now says another hash
        (setq drgnx-plugins--rows (list (drgnx-extensions-plugins-test--row :hash drgnx-extensions-plugins-test--hash-b)))
        (drgnx-extensions-plugins-approve)
        (should (equal (car calls) (cons "plugins/approve"
                                         (list :name "rewrite-msg" :hash drgnx-extensions-plugins-test--hash-a))))))))

(ert-deftest drgnx-extensions-plugins/approve-holds-once-when-the-page-changed-under-the-user ()
  "M13: the page was redrawn with another hash while it was open: the first Approve says so and sends nothing; the
second, after reading, sends the hash the page now shows."
  (let ((drgnx-plugins--rows (list (drgnx-extensions-plugins-test--row :state "unapproved"))) calls)
    (cl-letf (((symbol-function 'drgnx-hub-call)
               (lambda (method params _cb &rest _) (push (cons method params) calls) 1)))
      (with-temp-buffer
        (drgnx-extensions-details-mode)
        (setq drgnx-extensions-details--id "plugin:rewrite-msg")
        (drgnx-extensions-plugins-page-text "rewrite-msg")
        (setq drgnx-plugins--rows (list (drgnx-extensions-plugins-test--row :hash drgnx-extensions-plugins-test--hash-b)))
        (drgnx-extensions-plugins-page-text "rewrite-msg")   ; a plugin event redraws the page
        (should-error (drgnx-extensions-plugins-approve) :type 'user-error)
        (should-not calls)
        (drgnx-extensions-plugins-approve)
        (should (equal (car calls) (cons "plugins/approve"
                                         (list :name "rewrite-msg" :hash drgnx-extensions-plugins-test--hash-b))))))))

(ert-deftest drgnx-extensions-plugins/a-burst-of-events-is-one-question-and-a-late-answer-is-dropped ()
  "M4: five `plugin' events are one debounced `plugins/list'; of two questions asked, only the newest answer is read."
  (let (debounced calls listed)
    (cl-letf (((symbol-function 'drgnx-timer-debounce) (lambda (key _s fn &rest _) (push (cons key fn) debounced) key))
              ((symbol-function 'drgnx-hub-call) (lambda (_m _p cb &rest _) (push cb calls) 1))
              ((symbol-function 'drgnx-plugins--listed) (lambda (result _err) (push result listed)))
              ((symbol-function 'drgnx-extensions-plugins--redraw) #'ignore)
              ((symbol-function 'get-buffer) (lambda (_n) t)))
      (dotimes (_ 5) (drgnx-extensions-plugins--event "plugin" nil))
      (should (equal (delete-dups (mapcar #'car debounced)) '(extensions-plugins-refresh)))
      (should-not calls)                              ; nothing asked until the debounce fires
      (funcall (cdr (car debounced)))
      (funcall (cdr (car debounced)))                 ; two questions in flight
      (should (= 2 (length calls)))
      (funcall (cadr calls) 'old nil)                 ; the older answer comes last-but-first: dropped
      (funcall (car calls) 'new nil)
      (should (equal listed '(new))))))

(ert-deftest drgnx-extensions-plugins/the-diff-sees-the-advisory-flag-and-the-store-size ()
  "M9: a hook that stops being advisory and a bigger key-value store are new; a smaller store, a hook turning advisory
and a stored reach that never had the size are not."
  (let ((old '(:abilities ("a") :hosts nil :kv_bytes 1000
                          :hooks ((:point "before-commit" :verdicts ("allow") :advisory t))))
        (hook (lambda (advisory) `(:point "before-commit" :verdicts ("allow") :advisory ,advisory))))
    (should (equal (drgnx-extensions-plugins-diff `(:abilities ("a") :kv_bytes 4096 :hooks (,(funcall hook nil))) old)
                   '("Not advisory any more at before-commit: a failure of the hook now denies"
                     "Bigger key-value store: 4096 bytes, was 1000")))
    (should (null (drgnx-extensions-plugins-diff `(:abilities ("a") :kv_bytes 500 :hooks (,(funcall hook t))) old)))
    (should (null (drgnx-extensions-plugins-diff `(:abilities ("a") :kv_bytes 4096 :hooks (,(funcall hook nil)))
                                                 '(:abilities ("a") :hooks ((:point "before-commit" :verdicts ("allow")))))))))

(ert-deftest drgnx-extensions-plugins/settings-plugins-opens-the-view ()
  (let (applied)
    (cl-letf (((symbol-function 'drgnx-module-running-p) (lambda (m) (eq m 'tools/extensions)))
              ((symbol-function 'drgnx-extensions-open) #'ignore)
              ((symbol-function 'drgnx-extensions-list--apply-query) (lambda (q) (push q applied)))
              ((symbol-function 'drgnx-hub-ensure) (lambda () (error "the own page was opened"))))
      (drgnx-plugins-open)
      (should (equal applied '("@plugins"))))))

(ert-deftest drgnx-extensions-plugins/the-page-is-in-the-view-with-its-buttons ()
  (let ((drgnx-plugins--rows (list (drgnx-extensions-plugins-test--row :state "unapproved"))))
    (with-temp-buffer
      (drgnx-extensions-details-mode)
      (setq drgnx-extensions-details--id "plugin:rewrite-msg")
      (let ((text (drgnx-extensions-plugins-page-text "rewrite-msg")))
        (should (string-search "Approve this version" text))
        (should (get-text-property (string-search "Approve this version" text) 'action text))))))

(ert-deftest drgnx-extensions-plugins/the-cli-hint-is-only-for-the-page-without-the-view ()
  (let ((drgnx-plugins--rows (list (drgnx-extensions-plugins-test--row :state "approved"))))
    (cl-letf (((symbol-function 'drgnx-module-running-p) (lambda (m) (eq m 'tools/extensions))))
      (should-not (string-search "ratatoskr plugins remove"
                                 (with-temp-buffer (drgnx-plugins-page-insert "rewrite-msg") (buffer-string)))))
    (cl-letf (((symbol-function 'drgnx-module-running-p) #'ignore))
      (should (string-search "ratatoskr plugins remove"
                             (with-temp-buffer (drgnx-plugins-page-insert "rewrite-msg") (buffer-string)))))))

(provide 'extensions-plugins-test)
;;; extensions-plugins-test.el ends here
