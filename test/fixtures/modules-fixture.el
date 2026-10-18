;;; modules-fixture.el --- drgnx-test-with-modules: set modules up for a test, tear them down after -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `(drgnx-test-with-modules MODULES [:stages S] [:packages hidden] [:strict t] BODY…)' runs BODY with the
;; named modules (and the modules they require) set up in a fresh module table, report and state (a temporary
;; DRGNX_CONFIG_DIR), or every shipped module of the stages in :stages.  Afterwards it turns them off through
;; the product path (`drgnx-module-teardown', last set up first, then `drgnx-modules-after-teardown-functions'),
;; so every use also tests the teardown, and puts back a snapshot of every registry variable of
;; `drgnx-modules-fingerprint-registries' taken before.  The snapshot is copied values restored with `set' (a
;; keymap in place), never `let': binding a variable of a library that is first loaded inside BODY leaves it
;; void once the library is loaded (it is bound after, see `drgnx-test-modules/no-let-binding-trap').
;; `:strict t' fails the test, with the fingerprint diff, when the state after the teardown differs from the
;; state before the first setup (features excepted).  `:packages hidden' hides third-party features during the
;; setups, for tests of a result shape (the key snapshot) that must not depend on what is installed.
;; See docs/develop/harness.md ("Tests that set modules up").

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-modules-fingerprint)

(defvar drgnx-test-modules--files nil
  "Alist module NAME → the shipped file that defines it, scanned once from modules/.")

(defun drgnx-test-modules--scan ()
  "Set `drgnx-test-modules--files' from a text scan of every shipped module file (nothing is loaded)."
  (let (out)
    (dolist (file (directory-files-recursively (expand-file-name "modules" drgnx-dir) "\\`drgnx-.*\\.el\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (while (re-search-forward "^(drgnx-module-define '\\([^ \n()]+\\)" nil t)
          (push (cons (intern (match-string 1)) file) out))))
    (setq drgnx-test-modules--files (nreverse out))))

(defun drgnx-test-modules--file (name)
  "The shipped file that defines module NAME."
  (or (alist-get name (or drgnx-test-modules--files (drgnx-test-modules--scan)))
      (error "No shipped module file defines %s" name)))

(defun drgnx-test-modules--load (entries)
  "Load the files of ENTRIES and, repeatedly, of the modules they require.
An entry is a module name (its shipped file) or a string, a file to load (a fake module of a test).
Returns the names of the modules ENTRIES stand for."
  (let ((todo (copy-sequence entries)) (loaded nil) (names nil))
    (while todo
      (let ((entry (pop todo)))
        (if (stringp entry)
            (let ((before drgnx-modules--table))
              (load (file-name-sans-extension entry) nil t)
              (dolist (m drgnx-modules--table)
                (unless (assq (car m) before)
                  (push (car m) names)
                  (dolist (r (plist-get (cdr m) :requires)) (push r todo)))))
          (push entry names)
          (let ((file (and (not (assq entry drgnx-modules--table)) (drgnx-test-modules--file entry))))
            (unless (or (null file) (member file loaded))
              (push file loaded)
              (load (file-name-sans-extension file) nil t)
              (dolist (m drgnx-modules--table)
                (when (equal (alist-get (car m) drgnx-test-modules--files) file)
                  (dolist (r (plist-get (cdr m) :requires)) (push r todo)))))))))
    (nreverse names)))

;;;; The registry snapshot

(defun drgnx-test-modules--copy (value)
  "A copy of VALUE, deep enough for the lists a registry holds."
  (cond ((hash-table-p value)
         (let ((copy (copy-hash-table value)))
           (maphash (lambda (k v) (puthash k (copy-tree v) copy)) value)
           copy))
        ((keymapp value) (copy-keymap value))
        (t (copy-tree value))))

(defun drgnx-test-modules--snapshot ()
  "((VAR OBJECT COPY)…) for every bound variable of `drgnx-modules-fingerprint-registries'."
  (let (snap)
    (dolist (spec drgnx-modules-fingerprint-registries)
      (let ((var (if (consp spec) (car spec) spec)))
        (when (and (boundp var) (not (assq var snap)))
          (push (list var (symbol-value var) (drgnx-test-modules--copy (symbol-value var))) snap))))
    snap))

(defun drgnx-test-modules--restore (snap)
  "Put SNAP back: a table or keymap in place (it is referenced by identity), anything else with `set'."
  (pcase-dolist (`(,var ,object ,copy) snap)
    (cond ((and (hash-table-p copy) (hash-table-p object))
           (clrhash object)
           (maphash (lambda (k v) (puthash k v object)) copy)
           (set var object))
          ((and (keymapp copy) (keymapp object))
           (setcdr object (cdr copy))
           (set var object))
          (t (set var copy)))))

;;;; Hiding third-party features

(defvar drgnx-test-modules--library-dir nil "Emacs's own lisp directory (found before `locate-library' is hidden).")

(defun drgnx-test-modules--library-dir ()
  (or drgnx-test-modules--library-dir
      (setq drgnx-test-modules--library-dir
            (expand-file-name
             (file-name-directory (or (locate-library "subr") (error "Cannot find Emacs's lisp directory")))))))

(defun drgnx-test-modules--third-party-p (file)
  "Non-nil when FILE is neither part of Emacs nor of drgnx."
  (and file
       (not (string-prefix-p (drgnx-test-modules--library-dir) (expand-file-name file)))
       (not (string-prefix-p (expand-file-name drgnx-dir) (expand-file-name file)))))

(defun drgnx-test-modules--hidden-features ()
  (seq-filter (lambda (f) (drgnx-test-modules--third-party-p (ignore-errors (feature-file f)))) features))

(defmacro drgnx-test-modules--hiding (hide &rest body)
  "BODY, with the third-party features out of `features' and `locate-library' blind to them when HIDE.
The features come back after (unless BODY loaded them again)."
  (declare (indent 1))
  `(if (not ,hide)
       (progn ,@body)
     (let* ((hidden (drgnx-test-modules--hidden-features))
            (orig (symbol-function 'locate-library)))
       (setq features (seq-remove (lambda (f) (memq f hidden)) features))
       (unwind-protect
           (cl-letf (((symbol-function 'locate-library)
                      (lambda (&rest args)
                        (let ((found (apply orig args)))
                          (and found (not (drgnx-test-modules--third-party-p found)) found)))))
             ,@body)
         (dolist (f (reverse hidden)) (unless (memq f features) (setq features (nconc features (list f)))))))))

;;;; Running

(defun drgnx-test-modules--diff-lines (before after)
  "Readable lines for what differs between the fingerprints BEFORE and AFTER, features excepted."
  (mapcar (lambda (d) (if (plist-get d :source) (format "%s (%s)" (plist-get d :what) (plist-get d :source))
                        (plist-get d :what)))
          (seq-remove (lambda (d) (string-prefix-p "feature " (plist-get d :what)))
                      (drgnx-modules-fingerprint-diff before after))))

(defun drgnx-test-modules--setup (selected)
  "Run the setups of SELECTED in stage order; the names whose setup ran, in that order."
  (let (ran)
    (dolist (stage drgnx-modules-stages)
      (let ((stage-ran nil))
        (dolist (m (drgnx-modules--in-order stage))
          (when (and (memq (car m) selected) (drgnx-modules--run-one (car m) (cdr m) stage))
            (push (car m) ran) (setq stage-ran t)))
        (when stage-ran (run-hook-with-args 'drgnx-modules-after-stage-functions stage))))
    (nreverse ran)))

(defun drgnx-test-modules--teardown (ran)
  "Tear RAN down, the last first, then run the after-teardown functions.  The problems, (NAME . STRINGS)."
  (let (problems)
    (dolist (name (reverse ran))
      (let ((p (drgnx-module-teardown name)))
        (when (and p (not (equal p '("restart")))) (push (cons name p) problems))))
    (run-hooks 'drgnx-modules-after-teardown-functions)
    (nreverse problems)))

(defun drgnx-test-modules--closure (names)
  "NAMES and every module they require, from the loaded table."
  (let ((todo (copy-sequence names)) (out nil))
    (while todo
      (let ((n (pop todo)))
        (unless (memq n out)
          (push n out)
          (dolist (r (plist-get (alist-get n drgnx-modules--table) :requires)) (push r todo)))))
    (nreverse out)))

(defun drgnx-test-modules--run (modules opts body)
  "Run the function BODY with MODULES set up (see `drgnx-test-with-modules'); OPTS is its plist."
  (let* ((stages (plist-get opts :stages))
         (cfg (make-temp-file "drgnx-mods" t))
         (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
         (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
         (drgnx-modules--stacks nil) (drgnx-modules--runs nil) (drgnx-modules--features nil)
         (drgnx-module--claims (make-hash-table :test 'equal))
         (drgnx-module--releasers (make-hash-table :test 'equal))
         (snap (drgnx-test-modules--snapshot)))
    (unwind-protect
        (drgnx-test-modules--hiding (eq (plist-get opts :packages) 'hidden)
          (let* ((named (drgnx-test-modules--load modules))
                 (_ (when stages
                      (drgnx-test-modules--load
                       (mapcar #'car (or drgnx-test-modules--files (drgnx-test-modules--scan))))))
                 (selected (drgnx-test-modules--closure
                            (append named
                                    (and stages
                                         (mapcar #'car (seq-filter (lambda (m) (memq (plist-get (cdr m) :stage) stages))
                                                                   drgnx-modules--table))))))
                 (before (drgnx-modules-fingerprint))
                 (ran nil) (problems nil) (value nil))
            (unwind-protect
                (progn (setq ran (drgnx-test-modules--setup selected))
                       (setq value (funcall body)))
              (setq problems (drgnx-test-modules--teardown ran)))
            (when problems
              (ert-fail (list "modules did not tear down cleanly" problems)))
            (when (plist-get opts :strict)
              (when-let* ((lines (drgnx-test-modules--diff-lines before (drgnx-modules-fingerprint))))
                (ert-fail (cons "modules left state behind after their teardown:" lines))))
            value))
      (drgnx-test-modules--restore snap)
      (delete-directory cfg t))))

(defmacro drgnx-test-with-modules (modules &rest body)
  "Run BODY with MODULES (a list of module names, evaluated) set up and torn down after.
Keywords before BODY: `:stages' (a list of stages: every shipped module of them as well), `:packages hidden'
\(third-party features are hidden during the setups) and `:strict t' (fail with the fingerprint diff when the
state after differs from before, features excepted).  The module table, report, state and config directory
are fresh; the registries of `drgnx-modules-fingerprint-registries' are put back after.  Returns BODY's value."
  (declare (indent 1) (debug t))
  (let (opts)
    (while (keywordp (car body))
      (let ((key (pop body)) (val (pop body)))
        (push key opts) (push (if (eq val 'hidden) ''hidden val) opts)))
    `(drgnx-test-modules--run ,modules (list ,@(nreverse opts)) (lambda () ,@body))))

(provide 'modules-fixture)
;;; modules-fixture.el ends here
