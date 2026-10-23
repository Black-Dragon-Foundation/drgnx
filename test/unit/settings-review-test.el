;;; settings-review-test.el --- batch tests: Review and Allow, and the quiet path -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Built on the fixture of settings-trust-test.el (`drgnx-stt--with': temp config, a location folder with a project,
;; fresh trust caches).  Everything runs with `inhibit-interaction' t and `yes-or-no-p'/`y-or-n-p' signalling, so a
;; prompt is a failure.  Notices are recorded, not posted.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/unit/settings-trust-test" drgnx-dir) nil t)
(require 'drgnx-settings-review)

(defvar drgnx-str--notices nil "The (TEXT . PLIST) notices posted.")

(defmacro drgnx-str--with (&rest body)
  "BODY in a trusted-by-location fixture whose .dir-locals.el is `drgnx-stt--dl', prompts forbidden."
  (declare (indent 0) (debug t))
  `(drgnx-stt--with (list (list drgnx-stt--ws))
     (let ((drgnx-settings-review--notified nil) (drgnx-settings-review--scheduled nil)
           (drgnx-str--notices nil) (inhibit-interaction t))
       (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "prompted")))
                 ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "prompted")))
                 ((symbol-function 'run-at-time) (lambda (&rest _) nil))
                 ((symbol-function 'drgnx-notify)
                  (lambda (_source _severity text &rest args) (push (cons text args) drgnx-str--notices) 'key)))
         (drgnx-stt--put ".dir-locals.el" drgnx-stt--dl)
         ,@body))))

(defun drgnx-str--review ()
  "The review buffer of the project, drawn."
  (drgnx-settings-review-code drgnx-stt--proj))

(defun drgnx-str--goto (var)
  "Move to VAR's piece in the current review buffer."
  (goto-char (point-min))
  (should (re-search-forward (format "  %s  (" (regexp-quote (symbol-name var))) nil t))
  (beginning-of-line))

(ert-deftest drgnx-settings-review/lists-waiting-pairs-with-lines ()
  (drgnx-str--with
    (drgnx-stt--open "a.txt")
    (with-current-buffer (drgnx-str--review)
      (unwind-protect
          (let ((text (buffer-string)))
            (should (string-match-p "^\\.dir-locals\\.el:3  drgnx-stt-risky-function  (code)" text))
            (should (string-match-p "^\\.dir-locals\\.el:4  eval  (code)" text))
            (should (string-match-p "    ignore" text))
            (should (string-match-p "\\[Allow All\\]" text))
            (should-not (string-match-p "drgnx-stt-data" text)))   ; data applies in a trusted location
        (kill-buffer)))
    (should (equal (drgnx-settings-workspace-waiting-summary drgnx-stt--proj) '(:settings 0 :code 2)))))

(ert-deftest drgnx-settings-review/an-untrusted-workspace-lists-what-waits-for-trust ()
  (drgnx-stt--with nil
    (drgnx-stt--put ".drgnx/settings.el" "(drgnx-workspace-settings\n :version 1\n (drgnx-stt-data \"x\")\n (:eval (push 'w1 drgnx-stt--evals)))\n")
    (should (equal (drgnx-settings-workspace-waiting-summary drgnx-stt--proj) '(:settings 1 :code 1)))
    (with-current-buffer (drgnx-str--review)
      (unwind-protect
          (progn (should (string-match-p "not trusted" (buffer-string)))
                 (should-not (string-match-p "\\[Allow\\]" (buffer-string))))
        (kill-buffer)))))

(ert-deftest drgnx-settings-review/a-changed-pair-shows-its-diff ()
  (drgnx-str--with
    (drgnx-stt--open "a.txt")
    (drgnx-settings-trust-allow drgnx-stt--proj (drgnx-settings-trust-waiting drgnx-stt--proj))
    (drgnx-stt--put ".dir-locals.el" (replace-regexp-in-string "ignore" "identity" drgnx-stt--dl))
    (drgnx-stt--reopen "a.txt")
    (let ((item (car (drgnx-settings-trust-waiting drgnx-stt--proj))))
      (should (equal (drgnx-settings-review-item-diff item) '("- ignore" "+ identity"))))
    (with-current-buffer (drgnx-str--review)
      (unwind-protect
          (let ((text (buffer-string)))
            (should (string-match-p "changed since you allowed it" text))
            (should (string-match-p "    - ignore\n    \\+ identity" text)))
        (kill-buffer)))))

(ert-deftest drgnx-settings-review/allow-applies-and-rehacks ()
  (drgnx-str--with
    (with-current-buffer (drgnx-stt--open "a.txt")
      (should-not (local-variable-p 'drgnx-stt-risky-function))
      (with-current-buffer (drgnx-str--review)
        (unwind-protect
            (progn (drgnx-str--goto 'drgnx-stt-risky-function)
                   (drgnx-settings-review-allow-at-point)
                   (should-not (string-match-p "drgnx-stt-risky-function" (buffer-string)))
                   (should (string-match-p "eval" (buffer-string))))
          (kill-buffer)))
      (should (eq drgnx-stt-risky-function 'ignore))             ; the open buffer, not reopened
      (should-not drgnx-stt--evals))
    (should (equal (drgnx-stt--vars (drgnx-settings-trust-waiting drgnx-stt--proj)) '(eval)))
    (with-current-buffer (drgnx-str--review)
      (unwind-protect
          (progn (drgnx-settings-review-allow-all)
                 (should (string-match-p "Nothing waits" (buffer-string))))
        (kill-buffer)))
    (should (equal drgnx-stt--evals '(dl)))))

(ert-deftest drgnx-settings-review/deny-is-remembered ()
  (drgnx-str--with
    (drgnx-stt--open "a.txt")
    (with-current-buffer (drgnx-str--review)
      (unwind-protect
          (progn (drgnx-str--goto 'drgnx-stt-risky-function)
                 (drgnx-settings-review-deny-at-point))
        (kill-buffer)))
    (drgnx-settings-trust-allow drgnx-stt--proj (drgnx-settings-trust-waiting drgnx-stt--proj))
    (setq drgnx-settings-trust--data nil)                        ; read it back from trusted-folders.eld
    (setq drgnx-stt--evals nil)
    (with-current-buffer (drgnx-stt--reopen "a.txt")
      (should-not (local-variable-p 'drgnx-stt-risky-function))  ; denied: ignored silently
      (should (equal drgnx-stt--evals '(dl))))
    (should-not (drgnx-settings-trust-waiting drgnx-stt--proj))))

(ert-deftest drgnx-settings-review/one-notice-per-workspace-per-session ()
  (drgnx-str--with
    (should (drgnx-settings-review-notify drgnx-stt--proj))
    (should-not (drgnx-settings-review-notify drgnx-stt--proj))
    (should (= 1 (length drgnx-str--notices)))
    (let ((n (car drgnx-str--notices)))
      (should (string-match-p "^2 pieces of code wait in " (car n)))
      (should (equal (car (plist-get (cdr n) :command)) 'drgnx-settings-review-code)))
    ;; nothing waiting: no notice at all
    (drgnx-settings-trust-allow drgnx-stt--proj (drgnx-settings-trust-waiting drgnx-stt--proj))
    (let ((other (drgnx-stt--project (expand-file-name "other/" drgnx-stt--ws))))
      (should-not (drgnx-settings-review-notify other)))
    (should (= 1 (length drgnx-str--notices)))))

(ert-deftest drgnx-settings-review/never-prompts ()
  (drgnx-str--with
    (should (equal (drgnx-settings-review--text '(:settings 3 :code 1)) "3 settings and 1 piece of code wait"))
    (drgnx-stt--open "a.txt")
    (drgnx-settings-review-notify drgnx-stt--proj)
    (with-current-buffer (drgnx-str--review)
      (unwind-protect
          (progn (drgnx-settings-review-allow-all)
                 (drgnx-str--goto-none))
        (kill-buffer)))
    (should-not drgnx-stt--prompts)))

(defun drgnx-str--goto-none ()
  "Allow at point with nothing under it is a quiet error, not a prompt."
  (goto-char (point-max))
  (should-error (drgnx-settings-review-allow-at-point) :type 'user-error))

(provide 'settings-review-test)
;;; settings-review-test.el ends here
