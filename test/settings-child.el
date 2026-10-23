;;; settings-child.el --- the settings rows' child Emacs, under a temp HOME -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The compatibility rows of the unified settings run in a child Emacs under a fresh temporary HOME and config dir,
;; so a row never sees the test runner's state, `~' or the user's drgnx.  `drgnx-settings-test-child' writes the
;; row's files, starts the child, evaluates the row's forms there and returns what they gave;
;; `drgnx-settings-test-check-row', called in the child, asserts a row's checks.  The child loads this file too.
;; See docs/develop/settings.md, "Testing in a child Emacs".

;;; Code:
(require 'cl-lib)
(require 'ert)

(declare-function drgnx-test-env "drgnx-test-env" (tier run &rest keys))
(declare-function drgnx-settings-explain "drgnx-settings-prov" (var &optional buffer))
(declare-function custom-variable-state "cus-edit" (symbol val))

(defconst drgnx-settings-test-child-timeout 120 "Seconds a child Emacs may run before it is stopped.")

(defconst drgnx-settings-test--self (file-name-sans-extension (or load-file-name buffer-file-name))
  "This file, without its suffix: the child loads it too.")

(defun drgnx-settings-test--file (root name)
  "Where NAME of a child's :files goes under ROOT: \"~/…\" under the temp HOME, anything else under the config dir."
  (if (string-prefix-p "~/" name)
      (expand-file-name (substring name 2) (expand-file-name "home" root))
    (expand-file-name name (expand-file-name "config" root))))

(defun drgnx-settings-test--write (file text)
  "Write TEXT to FILE (UTF-8), making its directory."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'utf-8-unix) (print-length nil) (print-level nil))
    (write-region text nil file nil 'silent)))

(cl-defun drgnx-settings-test-child (forms &key files env)
  "Evaluate FORMS in a child Emacs under a fresh temp HOME and config dir; a plist of what happened.
FILES: an alist (NAME . TEXT), written first; NAME is relative to the child's config dir (`drgnx-user-dir' there:
\"settings.el\", \"custom.el\", \"config.el\" …) or, when it starts with \"~/\", to its temp HOME.
ENV: strings for `process-environment' (\"K=V\" sets, a bare \"K\" unsets) that win over the rest: the test
environment of `drgnx-test-env' (HOME, the XDG and drgnx dirs under the temp root, no session bus, no provider
key), with DRGNX_SAFE and DRGNX_UI_RUN unset.  \"DRGNX_SETTINGS_TEST_STOCK=1\" makes the child a stock Emacs: drgnx is
not loaded (the stock answer of a row, `drgnx-settings-test-answer').
The child is this Emacs (`invocation-name'), batch and -Q, with this Emacs's `load-path', and requires `drgnx' as
the test runner's files do: no init file and no `drgnx-init' (a form calls it when a row needs a start).  FORMS
are evaluated in order, lexically; the first error stops them.  A child running longer than
`drgnx-settings-test-child-timeout' is stopped.
Returns (:results TEXTS :values VALUES :error TEXT :exit CODE :output TEXT :root DIR): each form's value printed
with `prin1', the same read back (nil when the text does not read), what stopped the forms (the message of an
error, the printed data of a failed `should', or why the child gave no results), the child's exit code, what it
printed, and the temp root (a truename; deleted when this returns)."
  (require 'drgnx-test-env)
  (let* ((root (file-name-as-directory (file-truename (make-temp-file "drgnx-settings-child" t))))
         (in (expand-file-name "forms.eld" root))
         (out (expand-file-name "results.eld" root)))
    (unwind-protect
        (let ((process-environment (append env (list "DRGNX_SAFE" "DRGNX_UI_RUN" "DRGNX_SETTINGS_TEST_STOCK")
                                           (drgnx-test-env 'unit root) process-environment)))
          (dolist (d '("home" "config")) (make-directory (expand-file-name d root) t))
          (dolist (f files) (drgnx-settings-test--write (drgnx-settings-test--file root (car f)) (cdr f)))
          (drgnx-settings-test--write in (let ((print-length nil) (print-level nil)) (prin1-to-string forms)))
          (with-temp-buffer
            (let* ((p (make-process :name "drgnx-settings-child" :buffer (current-buffer) :noquery t
                                    :connection-type 'pipe :sentinel #'ignore
                                    :command (list (expand-file-name invocation-name invocation-directory)
                                                   "--batch" "-Q" "--eval"
                                                   (format "(setq load-prefer-newer t load-path '%S)" load-path)
                                                   "-l" drgnx-settings-test--self
                                                   "--eval" (format "(drgnx-settings-test--child-main %S %S)" in out))))
                   (deadline (+ (float-time) drgnx-settings-test-child-timeout)))
              (while (and (process-live-p p) (< (float-time) deadline))
                (accept-process-output p 0.1))
              (let ((timed-out (process-live-p p)))
                (when timed-out (delete-process p))
                (accept-process-output nil 0)
                (let* ((r (and (file-exists-p out)
                               (with-temp-buffer (insert-file-contents out) (car (read-from-string (buffer-string))))))
                       (results (plist-get r :results)))
                  (list :results results
                        :values (mapcar (lambda (s) (condition-case nil (car (read-from-string s)) (error nil)))
                                        results)
                        :error (cond (timed-out (format "the child ran longer than %d s"
                                                        drgnx-settings-test-child-timeout))
                                     ((null r) (format "the child gave no results (exit %s)" (process-exit-status p)))
                                     (t (plist-get r :error)))
                        :exit (process-exit-status p)
                        :output (buffer-string)
                        :root root))))))
      (delete-directory root t))))

(defun drgnx-settings-test--child-main (in out)
  "In the child: evaluate the forms in file IN in order, and write what they gave to OUT."
  (let ((forms (with-temp-buffer (insert-file-contents in) (car (read-from-string (buffer-string)))))
        results err)
    (condition-case e
        (progn
          (unless (getenv "DRGNX_SETTINGS_TEST_STOCK") (require 'drgnx))
          (dolist (f forms) (push (let ((print-length nil) (print-level nil)) (prin1-to-string (eval f t))) results)))
      (ert-test-failed (setq err (let ((print-length nil) (print-level nil)) (prin1-to-string (cdr e)))))
      (error (setq err (error-message-string e))))
    (drgnx-settings-test--write out (let ((print-length nil) (print-level nil))
                                      (prin1-to-string (list :results (nreverse results) :error err))))))

(defun drgnx-settings-test-answer (var)
  "VAR's answer, compared between a stock Emacs and drgnx: its value and its `custom-variable-state'."
  (require 'cus-edit)
  (let ((v (symbol-value var)))
    (list v (custom-variable-state var v))))

(defun drgnx-settings-test--describe (var)
  "What `describe-variable' says of VAR, as text."
  (save-window-excursion
    (describe-variable var)
    (with-current-buffer (help-buffer) (buffer-string))))

(cl-defun drgnx-settings-test-check-row (var &key (value nil value-p) (state nil state-p) describe (source nil source-p)
                                             (stock-equal nil stock-p))
  "Assert a compatibility row's checks for VAR in the child (a form of `drgnx-settings-test-child'); t when they hold.
Each runs when its key is given: VALUE, the effective value (`symbol-value' in the current buffer); STATE, its
`custom-variable-state' (`saved', `set', `changed', `standard' …); DESCRIBE, a regexp `describe-variable's text
matches; SOURCE, the `:source' of `drgnx-settings-explain'; STOCK-EQUAL, the stock answer (`drgnx-settings-test-answer'
in a child with DRGNX_SETTINGS_TEST_STOCK=1 and the same files), which this answer must equal.  Always: the explained
winner, the `:value' of `drgnx-settings-explain', is `symbol-value'.  A failed check signals `ert-test-failed',
which the child returns as its :error."
  (require 'cus-edit)
  (require 'drgnx-settings-prov)
  (let ((v (symbol-value var)) (explained (drgnx-settings-explain var)))
    (when value-p (should (equal v value)))
    (when state-p (should (eq (custom-variable-state var v) state)))
    (when describe (should (string-match-p describe (drgnx-settings-test--describe var))))
    (when source-p (should (equal (plist-get explained :source) source)))
    (when stock-p (should (equal (drgnx-settings-test-answer var) stock-equal)))
    (should (equal (plist-get explained :value) v))
    t))

(provide 'settings-child)
;;; settings-child.el ends here
