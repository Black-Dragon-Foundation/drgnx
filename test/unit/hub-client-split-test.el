;;; hub-client-split-test.el --- batch tests: the hub's socket client is its own file -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)

(defun drgnx-hub-client-split-test--child (form)
  "The output of a child batch Emacs (-Q, drgnx's load path) that evaluates FORM (printed with `princ')."
  (let ((dirs (append (list "core" "wb" "modules" "harness")
                      (mapcar (lambda (d) (concat "modules/" d)) (directory-files (expand-file-name "modules" drgnx-dir) nil "\\`[^.]"))))
        (default-directory drgnx-dir))
    (with-temp-buffer
      (apply #'call-process (expand-file-name invocation-name invocation-directory) nil t nil
             "--batch" "-Q"
             (append (cl-loop for d in dirs append (list "-L" (expand-file-name d drgnx-dir)))
                     (list "--eval" (format "(princ %S)" form))))
      (buffer-string))))

(defun drgnx-hub-client-split-test--features (names)
  "A form listing which of the features NAMES are loaded."
  `(prin1-to-string (seq-filter #'featurep ',names)))

(ert-deftest drgnx-hub-client/loads-no-runtime ()
  (let ((out (drgnx-hub-client-split-test--child
              `(progn (require 'drgnx-hub-client)
                      ,(drgnx-hub-client-split-test--features
                        '(drgnx-hub drgnx-gateway drgnx-job drgnx-coord drgnx-agents drgnx-acp))))))
    (should (equal out "nil"))))

(ert-deftest drgnx-hub-client/editor-modules-do-not-load-the-hub ()
  (let ((out (drgnx-hub-client-split-test--child
              `(progn (dolist (f '(drgnx-agents-ui drgnx-cockpit-cards drgnx-cockpit-feed drgnx-job-ui
                                                   drgnx-agents-mirror drgnx-shell-env drgnx-onboard))
                        (require f))
                      ,(drgnx-hub-client-split-test--features '(drgnx-hub drgnx-gateway drgnx-job))))))
    (should (equal out "nil"))))

(ert-deftest drgnx-hub-client/the-hub-still-loads-whole ()
  (let ((out (drgnx-hub-client-split-test--child
              '(progn (require 'drgnx-hub)
                      (prin1-to-string (list (fboundp 'drgnx-hub-serve) (fboundp 'drgnx-hub-call)))))))
    (should (equal out "(t t)"))))

(ert-deftest drgnx-hub-client/declarations-name-the-right-file ()
  (let ((out (drgnx-hub-client-split-test--child
              '(progn
                 (require 'check-declare)
                 (let ((inhibit-message t) (lines nil))
                   (dolist (d '("core" "modules" "harness"))
                     (ignore-errors (check-declare-directory (expand-file-name d drgnx-dir))))
                   (when-let* ((b (get-buffer "*Check Declarations Warnings*")))
                     (with-current-buffer b
                       (dolist (l (split-string (buffer-string) "\n"))
                         (when (string-match-p "drgnx-\\(hub\\|coord\\)-" l) (push l lines)))))
                   (mapconcat #'identity (nreverse lines) "\n")))))
        )
    (should (equal out ""))))

;;; hub-client-split-test.el ends here
