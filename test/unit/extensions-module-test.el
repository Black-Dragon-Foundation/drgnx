;;; extensions-module-test.el --- batch tests: the Extensions module starts and stops the job, live and project layers -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: the module is set up and torn down as the user's session does it; only the hub is stubbed (no process).
;; Every drgnx location is a temp directory.  See docs/develop/extensions.md.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions" drgnx-dir) nil t) ; the libraries load here, not inside the test

(defvar drgnx-extensions-module-test--hooks
  '((drgnx-hub-event-functions . drgnx-extensions-jobs--event)
    (drgnx-exec-listed-hook . drgnx-extensions-jobs--listed)
    (drgnx-extensions-jobs-plan-functions . drgnx-extensions-live-plan)
    (drgnx-extensions-jobs-done-functions . drgnx-extensions-live--done)
    (drgnx-extensions-jobs-before-functions . drgnx-extensions-live-before)
    (drgnx-extensions-jobs-plan-gone-functions . drgnx-extensions-live--plan-gone)
    (kill-emacs-hook . drgnx-extensions-live--kill)
    (drgnx-settings-changed-functions . drgnx-extensions-project--changed)
    (drgnx-extensions-jobs-done-functions . drgnx-extensions-project--job-done)
    (drgnx-hub-connected-functions . drgnx-extensions--send-modules)
    (drgnx-modules-after-teardown-functions . drgnx-extensions--send-modules))
  "The hooks the layers add: (HOOK . FUNCTION).")

(defun drgnx-extensions-module-test--on ()
  "The hooks of the layers that are on now."
  (cl-remove-if-not (lambda (h) (and (boundp (car h)) (memq (cdr h) (symbol-value (car h)))))
                    drgnx-extensions-module-test--hooks))

(defmacro drgnx-extensions-module-test--with (&rest body)
  "BODY with every drgnx location a temp directory and the hub's calls answered by nothing."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-ext-module" t)))
          (process-environment (append (list (concat "XDG_STATE_HOME=" root "state") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_CACHE_HOME=" root "cache"))
                                       process-environment)))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-hub-call) #'ignore)
                   ((symbol-function 'drgnx-hub-connect) #'ignore)
                   ((symbol-function 'file-notify-add-watch) (lambda (&rest _) nil)))
           ,@body)
       (delete-directory root t))))

(ert-deftest drgnx-extensions-module/setup-starts-the-three-layers-and-teardown-stops-them ()
  (drgnx-extensions-module-test--with
    (should-not (drgnx-extensions-module-test--on))
    (drgnx-test-with-modules '(tools/extensions) :strict t
                             (should (eq (plist-get (alist-get 'tools/extensions (drgnx-modules-report)) :status) 'ok))
                             (should (equal (sort (mapcar #'cdr (drgnx-extensions-module-test--on)) #'string<)
                                            (sort (mapcar #'cdr drgnx-extensions-module-test--hooks) #'string<))))
    (should-not (drgnx-extensions-module-test--on))))

(ert-deftest drgnx-extensions-module/the-modules-reach-the-hub-as-built-in-rows ()
  (drgnx-extensions-module-test--with
    (let ((calls nil))
      (cl-letf (((symbol-function 'drgnx-hub-call)
                 (lambda (method params _callback &rest _) (when (equal method "extensions/modules") (push params calls)))))
        (drgnx-test-with-modules '(tools/extensions)
          ;; the hub's subscription is up: the table goes to it, without a wait
          (run-hooks 'drgnx-hub-connected-functions)
          (should (= (length calls) 1))
          (let* ((modules (append (plist-get (car calls) :modules) nil))
                 (me (seq-find (lambda (m) (equal (plist-get m :name) "tools/extensions")) modules)))
            (should me)
            (should (equal (plist-get me :state) "on"))
            (should (stringp (plist-get me :doc)))
            (should (vectorp (plist-get me :packages)))
            (should (vectorp (plist-get me :flags))))
          ;; a module turned off or on: the table again
          (run-hooks 'drgnx-modules-after-teardown-functions)
          (should (= (length calls) 2)))))))

;;; extensions-module-test.el ends here
