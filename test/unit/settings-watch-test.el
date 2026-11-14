;;; settings-watch-test.el --- batch tests: no provenance watcher on a variable typing writes over and over -*- lexical-binding: t -*-
;; test-class: det

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Provenance watches the variables settings manage (`drgnx-settings-prov-watch'); a watcher costs a call on every
;; write, so none may sit on a variable that typing writes more than 1,000 times.  Every customizable variable is
;; counted over 1,100 typed characters (a counting watcher on each); a variable written that often must carry no
;; provenance watcher, even when every customizable variable is managed.  A control variable written once per command
;; proves the count sees such a variable.  Race-proof pattern D: the keys are a keyboard macro run to its end.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-settings-prov)

(defconst drgnx-settings-watch-test--keys 1100 "Characters typed: one more than the 1,000 writes the gate allows.")
(defconst drgnx-settings-watch-test--limit 1000 "Writes after which a variable is hot.")

(defvar drgnx-settings-watch-test--counts (make-hash-table :test 'eq) "Variable -> writes seen while typing.")

(defun drgnx-settings-watch-test--count (symbol _newval operation _where)
  "Variable watcher: count the `set's of SYMBOL."
  (when (eq operation 'set) (cl-incf (gethash symbol drgnx-settings-watch-test--counts 0))))

(defvar drgnx-settings-watch-test--control nil "Written by `post-self-insert-hook' on every typed character.")

(defun drgnx-settings-watch-test--write-control ()
  (setq drgnx-settings-watch-test--control last-command-event))

(defun drgnx-settings-watch-test--customizable ()
  "Every customizable variable now."
  (let (out)
    (mapatoms (lambda (s) (when (and (get s 'standard-value) (not (get s 'byte-obsolete-variable))) (push s out))))
    out))

(defun drgnx-settings-watch-test--type (vars)
  "Type the keys into a Lisp buffer, with a counting watcher on VARS; the hash table of writes."
  (clrhash drgnx-settings-watch-test--counts)
  (let ((buf (generate-new-buffer "drgnx-watch-test")))
    (unwind-protect
        (progn
          (dolist (v vars) (add-variable-watcher v #'drgnx-settings-watch-test--count))
          (save-window-excursion
            (switch-to-buffer buf)
            (emacs-lisp-mode)
            (add-hook 'post-self-insert-hook #'drgnx-settings-watch-test--write-control nil t)
            (execute-kbd-macro (make-string drgnx-settings-watch-test--keys ?a))
            (should (= (buffer-size) drgnx-settings-watch-test--keys))))
      (dolist (v vars) (remove-variable-watcher v #'drgnx-settings-watch-test--count))
      (kill-buffer buf))
    drgnx-settings-watch-test--counts))

(defun drgnx-settings-watch-test--hot (counts)
  "The variables of COUNTS written more than the limit."
  (let (out)
    (maphash (lambda (v n) (when (> n drgnx-settings-watch-test--limit) (push v out))) counts)
    out))

(ert-deftest drgnx-settings-watch/the-count-sees-a-variable-written-per-command ()
  (let ((counts (drgnx-settings-watch-test--type '(drgnx-settings-watch-test--control))))
    (should (> (gethash 'drgnx-settings-watch-test--control counts 0) drgnx-settings-watch-test--limit))
    (should (equal (drgnx-settings-watch-test--hot counts) '(drgnx-settings-watch-test--control)))))

(ert-deftest drgnx-settings-watch/no-managed-variable-is-written-more-than-1000-times-typing ()
  (let* ((vars (drgnx-settings-watch-test--customizable))
         (watched (make-hash-table :test 'eq))
         (drgnx-settings-prov--watched watched))
    (unwind-protect
        (progn
          (mapc #'drgnx-settings-prov-watch vars)        ; the most that could ever be managed: all of them
          (let ((hot (drgnx-settings-watch-test--hot (drgnx-settings-watch-test--type vars))))
            (should-not (cl-remove-if-not (lambda (v) (gethash v watched)) hot))))
      (maphash (lambda (v _) (remove-variable-watcher v #'drgnx-settings-prov--watch)) watched))))

;;; settings-watch-test.el ends here
