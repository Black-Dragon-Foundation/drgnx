;;; lint-segments-test.el --- lint: the status bar reads no producer module's internals -*- lexical-binding: t -*-
;; A segment that shows a module's state belongs to that module (docs/guide/face.md, "Segments of your own"): the
;; module defines it in its setup (`drgnx-statusbar-define-segment', recorded, so its teardown takes it back) and
;; calls `(drgnx-statusbar-refresh t)' when its state changes.  The bar itself then has no reason to reach into the
;; producers: no symbol `drgnx-OTHER--…' of the producers' families and no `fboundp' of their functions.  The lint
;; reads `modules/ui/drgnx-statusbar.el' with the Lisp reader (comments and docstrings never count).
(require 'ert)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)

(defconst drgnx-lint-segments--file "modules/ui/drgnx-statusbar.el" "The file the lint reads.")

(defconst drgnx-lint-segments--producers '("agent" "agents" "hub" "job" "jobs" "cockpit")
  "Name families of the modules whose state the bar once read: `drgnx-FAMILY-…' is another module's.")

(defun drgnx-lint-segments--forms (file)
  "The top-level forms of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (with-syntax-table emacs-lisp-mode-syntax-table
      (let (forms)
        (goto-char (point-min))
        (condition-case nil
            (while (progn (forward-comment (buffer-size)) (not (eobp)))
              (push (read (current-buffer)) forms))
          (error nil))
        (nreverse forms)))))

(defun drgnx-lint-segments--symbols (form)
  "Every symbol in FORM (a tree), `declare-function' and `defvar' declarations included."
  (cond ((symbolp form) (list form))
        ((consp form) (append (drgnx-lint-segments--symbols (car form)) (drgnx-lint-segments--symbols (cdr form))))
        ((stringp form) nil)
        (t nil)))

(defun drgnx-lint-segments--other-p (sym)
  "Whether SYM is something of a producer module the bar must not read: a private symbol `drgnx-FAMILY…--x', or a
function of the family (`drgnx-FAMILY-x') the bar asks `fboundp' about or declares.  The family's public hooks
\(`drgnx-hub-event-functions') are the bar's to subscribe to, so they are not listed."
  (let ((name (symbol-name sym)))
    (and (not (string-suffix-p "-functions" name))
         (seq-some (lambda (family)
                     (let ((prefix (concat "drgnx-" family)))
                       (and (string-prefix-p prefix name)
                            (let ((rest (substring name (length prefix))))
                              (or (string-empty-p rest) (string-prefix-p "-" rest))))))
                   drgnx-lint-segments--producers))))

(ert-deftest drgnx-lint/segments-read-no-private-symbols ()
  (let (bad)
    (dolist (form (drgnx-lint-segments--forms (expand-file-name drgnx-lint-segments--file drgnx-dir)))
      (dolist (sym (drgnx-lint-segments--symbols form))
        (when (drgnx-lint-segments--other-p sym)
          (push sym bad))))
    (should-not (delete-dups bad))))

(ert-deftest drgnx-lint/segments-lint-sees-a-producer-symbol ()
  ;; the lint's own check: a producer's symbol is found, the bar's own is not
  (should (drgnx-lint-segments--other-p 'drgnx-hub--events))
  (should (drgnx-lint-segments--other-p 'drgnx-agents-sessions))
  (should (drgnx-lint-segments--other-p 'drgnx-job-ui--running))
  (should-not (drgnx-lint-segments--other-p 'drgnx-statusbar--now))
  (should-not (drgnx-lint-segments--other-p 'drgnx-hubris)))

(provide 'lint-segments-test)
