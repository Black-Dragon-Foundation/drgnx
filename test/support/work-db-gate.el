;;; work-db-gate.el --- test tooling: the one-writer gate (opening work.db read-write signals) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The hub (Ratatoskr) is the one writer of work.db (schema 7).  With DRGNX_WORK_DB_GATE=1 this file advises
;; `sqlite-open' to signal `drgnx-work-db-gate' when the file is named work.db and is not opened read-only, so a
;; path that still opens the tracker's database for writing fails.  The unit-test runner (harness/run-ert.el) and
;; the Lisp backend (test/conformance/lisp-hub.sh) load it and call `drgnx-work-db-gate-enable' when the variable is
;; set; CI runs the whole suite once in this mode (docs/develop/ci.md, "The one-writer gate").
;;
;; The one other way through is the fixture that stands in for the hub (test/fixtures/work-fixture.el): it writes
;; the rows the hub would, binding `drgnx-work-db-gate-hub-standin'.
;;
;; The exemption is narrow: a test of the Rust-bound `local' writer mode (the standalone Lisp hub of the v0 rows, the
;; coordination unit tests that write in `local' mode) is defined with `drgnx-work-db-writer-deftest'.  It carries the
;; tag `:work-db-writer', binds `drgnx-coord-writer' to `local', and the runner leaves it out in gate mode.  The lint
;; `drgnx-lint/work-db-writer-tags-only-in-local-mode' keeps the tag to the Rust-bound code's test files.  Phase 7
;; deletes these tests with the Lisp they test.

;;; Code:
(require 'ert)

(define-error 'drgnx-work-db-gate "work.db opened read-write outside the hub (the one-writer gate)")

(defvar drgnx-work-db-gate-hub-standin) ; core/drgnx-work-db.el
(defvar drgnx-coord-writer)            ; core/drgnx-coord.el, until the Lisp writers are deleted

(defun drgnx-work-db-gate-p ()
  "Whether DRGNX_WORK_DB_GATE=1: the run is in gate mode."
  (equal (getenv "DRGNX_WORK_DB_GATE") "1"))

(defun drgnx-work-db-gate--open (orig &optional file readonly)
  "Around `sqlite-open': signal for a read-write open of a file named work.db; else call ORIG with FILE, READONLY."
  (when (and (stringp file) (not readonly) (equal (file-name-nondirectory file) "work.db")
             (not (bound-and-true-p drgnx-work-db-gate-hub-standin)))
    (signal 'drgnx-work-db-gate (list file)))
  (funcall orig file readonly))

(defun drgnx-work-db-gate-enable ()
  "Advise `sqlite-open' (once)."
  (advice-add 'sqlite-open :around #'drgnx-work-db-gate--open))

(defmacro drgnx-work-db-writer-deftest (name args &rest body)
  "`ert-deftest' for a test that writes work.db as the hub's stand-in: tagged `:work-db-writer', BODY run with
`drgnx-work-db-gate-hub-standin' bound (and the Lisp writers' `local' mode, while they exist).  Left out in gate mode (DRGNX_WORK_DB_GATE=1)."
  (declare (indent 2) (doc-string 3))
  (let ((doc (and (stringp (car body)) (list (pop body)))) (tags nil) (keys nil))
    (while (keywordp (car body))
      (if (eq (car body) :tags) (setq tags (cadr body)) (setq keys (append keys (list (car body) (cadr body)))))
      (setq body (cddr body)))
    `(ert-deftest ,name ,args ,@doc
                  :tags (append '(:work-db-writer) ,tags)
                  ,@keys
                  (let ((drgnx-coord-writer 'local) (drgnx-work-db-gate-hub-standin t)) ,@body))))

(provide 'work-db-gate)
;;; work-db-gate.el ends here
