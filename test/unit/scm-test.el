;;; scm-test.el --- batch tests: the Source Control module's Lisp side -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: the module is set up and torn down as the user's session does it; only the hub is stubbed (what the view
;; sends is recorded).  The rows are the hub's (view::scm, tested there).  See docs/develop/hub.md, "The Source Control
;; view".
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-grid)
(require 'drgnx-modules)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-vc" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-scm" drgnx-dir) nil t)

(defvar drgnx-scm-test--sent nil "What the view asked the hub, newest first: (METHOD . PARAMS).")
(defvar drgnx-scm-test--failed nil "The failure function of each call, newest first (nil when none).")

(defmacro drgnx-scm-test--with (&rest body)
  "BODY with the view's calls to the hub recorded, none sent or answered."
  (declare (indent 0))
  `(let ((drgnx-scm-test--sent nil) (drgnx-scm-test--failed nil))
     (cl-letf (((symbol-function 'drgnx-scm--call)
                (lambda (method params &optional _then failed)
                  (push (cons method params) drgnx-scm-test--sent)
                  (push failed drgnx-scm-test--failed))))
       ,@body)))

(ert-deftest drgnx-scm/the-module-registers-the-git-commands-and-goes-cleanly ()
  "Setup registers the view and the palette's Git commands (\"Git: Commit\", VS Code's words) and its hooks; teardown
takes them away."
  (drgnx-test-with-modules '(tools/scm) :strict t
                           (should (eq (plist-get (alist-get 'tools/scm (drgnx-modules-report)) :status) 'ok))
                           (should (equal (drgnx-commands-label (drgnx-commands-get 'git-commit)) "Git: Commit"))
                           (should (equal (drgnx-commands-label (drgnx-commands-get 'git-push)) "Git: Push"))
                           (should (equal (drgnx-commands-label (drgnx-commands-get 'scm-view)) "View: Show Source Control"))
                           (should (eq (drgnx-cmd-command (drgnx-commands-get 'scm-view)) #'drgnx-scm-show))
                           (should (memq #'drgnx-scm--hub-event drgnx-hub-event-functions))
                           (should (memq #'drgnx-scm--saved after-save-hook)))
  (should-not (drgnx-commands-get 'git-commit))
  (should-not (memq #'drgnx-scm--saved after-save-hook)))

(ert-deftest drgnx-scm/vc-yields-source-control-to-the-side-bar ()
  "With tools/scm on, Source Control is its view, whichever module starts first; without it, VC's status."
  (drgnx-test-with-modules '(tools/vc tools/scm)
    (should (eq (drgnx-cmd-command (drgnx-commands-get 'scm-view)) #'drgnx-scm-show))
    (should (drgnx-commands-get 'scm-blame)))
  (drgnx-test-with-modules '(tools/vc)
    (should (eq (drgnx-cmd-command (drgnx-commands-get 'scm-view)) #'drgnx-vc-status))))

(ert-deftest drgnx-scm/commit-sends-the-message-and-empties-the-box ()
  "Ctrl+Enter in the box: `git/commit' with the repository the box acts on and its text; nothing staged and no
message asks for a message first."
  (drgnx-scm-test--with
    (let ((drgnx-scm--branches '(("/r/app" . "main"))) (drgnx-scm--target nil))
      (unwind-protect
          (cl-letf (((symbol-function 'drgnx-scm--staged-p) #'always)
                    ((symbol-function 'drgnx-wb-focus-section) #'ignore))
            (should-error (drgnx-scm-commit) :type 'user-error)
            (should-not drgnx-scm-test--sent)
            (with-current-buffer (drgnx-scm--message-buffer) (insert "  Fix the parser\n"))
            (drgnx-scm-commit)
            (pcase-let ((`(,method . ,params) (car drgnx-scm-test--sent)))
              (should (equal method "git/commit"))
              (should (equal (plist-get params :root) "/r/app"))
              (should (equal (plist-get params :message) "Fix the parser"))
              (should (eq (plist-get params :all) :false)))
            ;; the box empties as the commit starts, before git answers; a failure puts the message back
            (should (zerop (with-current-buffer (drgnx-scm--message-buffer) (buffer-size))))
            (funcall (car drgnx-scm-test--failed))
            (should (equal (with-current-buffer (drgnx-scm--message-buffer) (string-trim (buffer-string)))
                           "Fix the parser")))
        (when (get-buffer drgnx-scm-message-buffer-name) (kill-buffer drgnx-scm-message-buffer-name))))))

(ert-deftest drgnx-scm/discard-asks-and-untracked-files-go-to-the-trash ()
  "Discard asks first (no answer, nothing done); tracked files go back through `git/discard', untracked ones to the
trash, never deleted for good."
  (drgnx-scm-test--with
    (let* ((root (make-temp-file "drgnx-scm" t)) (new (expand-file-name "new.txt" root)) asked trashed)
      (unwind-protect
          (progn
            (with-temp-file new (insert "x"))
            (cl-letf (((symbol-function 'y-or-n-p) (lambda (q) (push q asked) nil)))
              (drgnx-scm--discard root '(("a.txt") ("new.txt" . t))))
            (should (string-match-p "2 files" (car asked)))
            (should-not drgnx-scm-test--sent)
            (should (file-exists-p new))
            (cl-letf (((symbol-function 'y-or-n-p) #'always)
                      ((symbol-function 'move-file-to-trash) (lambda (f) (push f trashed) (delete-file f))))
              (drgnx-scm--discard root '(("a.txt") ("new.txt" . t))))
            (should (equal (caar drgnx-scm-test--sent) "git/discard"))
            (should (equal (plist-get (cdar drgnx-scm-test--sent) :paths) ["a.txt"]))
            (should (equal trashed (list new))))
        (delete-directory root t)))))

;;; scm-test.el ends here
