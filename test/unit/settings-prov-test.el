;;; settings-prov-test.el --- provenance and drgnx-settings-explain -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Who set a variable (design §4.5, V1).  Each test runs in a child Emacs under a temp HOME (test/settings-child.el):
;; provenance installs watchers and advice, which must not reach the test runner.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(defun drgnx-settings-prov-test--settings (&rest vars)
  "A settings.el naming VARS (each with 0), one entry per line from line 2."
  (concat "(drgnx-settings :version 1"
          (mapconcat (lambda (v) (format "\n (%s 0)" v)) vars "")
          ")\n"))

(defun drgnx-settings-prov-test--load (name)
  "The form that loads NAME (a file in the child's config dir) inside `drgnx-settings-prov-with-load'."
  `(let ((f (expand-file-name ,name (drgnx-user-dir))))
     (drgnx-settings-prov-with-load f (load f nil t t))
     t))

(defun drgnx-settings-prov-test--run (forms files)
  "Run FORMS in a child with FILES; the values, or a failure with what the child said."
  (let ((r (drgnx-settings-test-child forms :files files)))
    (unless (and (null (plist-get r :error)) (equal (plist-get r :exit) 0))
      (ert-fail (list :error (plist-get r :error) :output (plist-get r :output))))
    (plist-get r :values)))

(defconst drgnx-settings-prov-test--explain
  '(lambda (var) (let ((e (drgnx-settings-explain var)))
                   (list (plist-get e :source) (plist-get e :line) (plist-get e :certain) (plist-get e :layer)
                         (and (plist-get e :file) (file-name-nondirectory (plist-get e :file))))))
  "A form for the child: VAR's explanation as (SOURCE LINE CERTAIN LAYER FILE-NAME).")

(defconst drgnx-settings-prov-test--first
  '(lambda (var) (let ((r (car (drgnx-settings-prov var))))
                   (list (plist-get r :kind) (and (plist-get r :file) (file-name-nondirectory (plist-get r :file)))
                         (plist-get r :line) (plist-get r :value))))
  "A form for the child: VAR's newest record as (KIND FILE-NAME LINE VALUE).")

(defconst drgnx-settings-prov-test--v1-files
  `(("settings.el" . ,(drgnx-settings-prov-test--settings 'q-prov-a 'q-prov-b))
    ("q-outer.el" . ";;; q-outer.el -*- lexical-binding: t -*-
(setq q-prov-b 3)

(progn (load (expand-file-name \"q-inner.el\" (file-name-directory load-file-name)) nil t t)
       (setq q-prov-a 4))
")
    ("q-inner.el" . ";;; q-inner.el -*- lexical-binding: t -*-
(setq q-prov-b 2)
"))
  "V1: a `setq' after a nested `load' in one form, and the inner file's own `setq'.")

(defun drgnx-settings-prov-test--v1 (forms)
  "Run V1's load, then FORMS, in a child; the values of FORMS."
  (nthcdr 3 (drgnx-settings-prov-test--run
             (append '((defvar q-prov-a 0) (defvar q-prov-b 0)) (list (drgnx-settings-prov-test--load "q-outer.el")) forms)
             drgnx-settings-prov-test--v1-files)))

(ert-deftest drgnx-settings-prov/nested-load-records-the-outer-form ()
  ;; The setq after the nested load is recorded at the outer file's form (line 4), not at the inner file's last form.
  (pcase-let ((`(,rec ,ex) (drgnx-settings-prov-test--v1
                            `((funcall ,drgnx-settings-prov-test--first 'q-prov-a)
                              (funcall ,drgnx-settings-prov-test--explain 'q-prov-a)))))
    (should (equal rec '(lisp "q-outer.el" 4 4)))
    (should (equal ex '("your Lisp (q-outer.el:5)" 5 t G4 "q-outer.el")))))

(ert-deftest drgnx-settings-prov/the-inner-setq-at-its-line ()
  (pcase-let ((`(,rec ,ex ,n) (drgnx-settings-prov-test--v1
                               `((funcall ,drgnx-settings-prov-test--first 'q-prov-b)
                                 (funcall ,drgnx-settings-prov-test--explain 'q-prov-b)
                                 (length (drgnx-settings-prov 'q-prov-b))))))
    (should (equal rec '(lisp "q-inner.el" 2 2)))
    (should (equal ex '("your Lisp (q-inner.el:2)" 2 t G4 "q-inner.el")))
    (should (= n 2))))                  ; q-outer.el:2 first, then q-inner.el:2

(ert-deftest drgnx-settings-prov/defcustom-init-is-drgnx-not-the-require ()
  ;; A package's defcustom taking the value of theme drgnx is drgnx's (settings.el:2), never the require's line.
  (pcase-let ((`(,value ,rec ,ex)
               (nthcdr 2 (drgnx-settings-prov-test--run
                          `((progn (custom-declare-theme 'drgnx nil)
                                   (let ((custom--inhibit-theme-enable nil)) (custom-theme-set-variables 'drgnx '(q-prov-c 7)))
                                   (setq custom-enabled-themes (delq 'drgnx custom-enabled-themes))
                                   (push (expand-file-name "lisp" (getenv "HOME")) load-path))
                            ,(drgnx-settings-prov-test--load "config.el")
                            q-prov-c
                            (funcall ,drgnx-settings-prov-test--first 'q-prov-c)
                            (funcall ,drgnx-settings-prov-test--explain 'q-prov-c))
                          `(("settings.el" . "(drgnx-settings :version 1\n (q-prov-c 7))\n")
                            ("config.el" . ";;; config.el -*- lexical-binding: t -*-\n(require 'q-pkg)\n")
                            ("~/lisp/q-pkg.el" . ";;; q-pkg.el -*- lexical-binding: t -*-
(defcustom q-prov-c 1 \"A test option.\" :type 'integer :group 'emacs)
(provide 'q-pkg)
"))))))
    (should (equal value 7))
    (should (eq (car rec) 'drgnx))
    (should (equal ex '("Settings (settings.el:2)" 2 t G2 "settings.el")))))

(ert-deftest drgnx-settings-prov/a-defvar-is-a-definition ()
  (pcase-let ((`(,rec ,ex)
               (cdr (drgnx-settings-prov-test--run
                     `(,(drgnx-settings-prov-test--load "q-def.el")
                       (funcall ,drgnx-settings-prov-test--first 'q-prov-d)
                       (plist-get (drgnx-settings-explain 'q-prov-d) :kind))
                     `(("settings.el" . ,(drgnx-settings-prov-test--settings 'q-prov-d))
                       ("q-def.el" . ";;; q-def.el -*- lexical-binding: t -*-\n(defvar q-prov-d 5)\n"))))))
    (should (equal rec '(definition "q-def.el" nil 5)))
    (should (eq ex 'default))))

(ert-deftest drgnx-settings-prov/after-load-is-deferred-first-seen-during ()
  ;; The body of a with-eval-after-load runs when the require at config.el:5 loads the package: deferred, its own
  ;; line (3) from the static index, first seen during config.el:5.  The require is never blamed.
  (pcase-let ((`(,rec ,during ,ex)
               (nthcdr 2 (drgnx-settings-prov-test--run
                          `((push (expand-file-name "lisp" (getenv "HOME")) load-path)
                            ,(drgnx-settings-prov-test--load "config.el")
                            (funcall ,drgnx-settings-prov-test--first 'q-prov-e)
                            (let ((d (plist-get (car (drgnx-settings-prov 'q-prov-e)) :during)))
                              (list (file-name-nondirectory (car d)) (cdr d)))
                            (funcall ,drgnx-settings-prov-test--explain 'q-prov-e))
                          `(("settings.el" . ,(drgnx-settings-prov-test--settings 'q-prov-e))
                            ("config.el" . ";;; config.el -*- lexical-binding: t -*-
(with-eval-after-load 'q-later
  (setq q-prov-e 9))

(require 'q-later)
")
                            ("~/lisp/q-later.el" . ";;; q-later.el -*- lexical-binding: t -*-
(defvar q-prov-e 1)
(provide 'q-later)
"))))))
    (should (equal rec '(deferred "config.el" nil 9)))   ; the file the static index names
    (should (equal during '("config.el" 5)))
    (should (equal ex '("your Lisp (config.el:3), deferred, first seen during config.el:5" 3 t G4 "config.el")))))

(ert-deftest drgnx-settings-prov/a-byte-compiled-file-has-the-static-line ()
  ;; A compiled file has no lines: it is recorded as the file, and the static index (of its .el) adds the line.
  (pcase-let ((`(,rec ,ex)
               (nthcdr 3 (drgnx-settings-prov-test--run
                          `((defvar q-prov-f 0)
                            (progn (require 'bytecomp) ; first, so the `let' binds it dynamically
                                   (let ((byte-compile-warnings nil) (inhibit-message t))
                                     (byte-compile-file (expand-file-name "q-comp.el" (drgnx-user-dir)))))
                            ,(drgnx-settings-prov-test--load "q-comp.elc")
                            (funcall ,drgnx-settings-prov-test--first 'q-prov-f)
                            (funcall ,drgnx-settings-prov-test--explain 'q-prov-f))
                          `(("settings.el" . ,(drgnx-settings-prov-test--settings 'q-prov-f))
                            ("q-comp.el" . ";;; q-comp.el -*- lexical-binding: t -*-\n(defvar q-prov-f)\n(setq q-prov-f 6)\n"))))))
    (should (equal rec '(lisp "q-comp.elc" nil 6)))
    (should (equal ex '("your Lisp (q-comp.el:3)" 3 t G4 "q-comp.el")))))

(ert-deftest drgnx-settings-prov/uncertain-lists-candidates ()
  ;; A `set' the index cannot see: the record names config.el, the index finds no setter in that form, so the line is
  ;; unknown and the index's setters of the variable are the candidates.
  (pcase-let ((`(,ex ,cands)
               (cddr (drgnx-settings-prov-test--run
                      `((defvar q-prov-g 0)
                        ,(drgnx-settings-prov-test--load "config.el")
                        (funcall ,drgnx-settings-prov-test--explain 'q-prov-g)
                        (mapcar (lambda (c) (list (file-name-nondirectory (plist-get c :file)) (plist-get c :line)))
                                (plist-get (drgnx-settings-explain 'q-prov-g) :candidates)))
                      `(("settings.el" . ,(drgnx-settings-prov-test--settings 'q-prov-g))
                        ("config.el" . ";;; config.el -*- lexical-binding: t -*-\n(setq q-prov-g 1)\n(set 'q-prov-g 2)\n"))))))
    (should (equal ex '("your Lisp (config.el, line unknown)" nil nil G4 "config.el")))
    (should (equal cands '(("config.el" 2))))))

(ert-deftest drgnx-settings-prov/let-and-makunbound-are-ignored ()
  (should (equal (cddr (drgnx-settings-prov-test--run
                        `((defvar q-prov-h 1)
                          ,(drgnx-settings-prov-test--load "q-let.el")
                          (length (drgnx-settings-prov 'q-prov-h))
                          (progn (makunbound 'q-prov-h) (length (drgnx-settings-prov 'q-prov-h))))
                        `(("settings.el" . ,(drgnx-settings-prov-test--settings 'q-prov-h))
                          ("q-let.el" . ";;; q-let.el -*- lexical-binding: t -*-
(setq q-prov-h 2)
(let ((q-prov-h 3)) (ignore q-prov-h))
"))))
                 '(1 1))))

(ert-deftest drgnx-settings-prov/an-alias-is-resolved ()
  ;; settings.el names the alias; a write through it is recorded on the base variable, and both explain the same.
  (should (equal (cdr (drgnx-settings-prov-test--run
                       `((progn (defvar q-prov-base 1) (defvaralias 'q-prov-alias 'q-prov-base) t)
                         ,(drgnx-settings-prov-test--load "q-alias.el")
                         (funcall ,drgnx-settings-prov-test--first 'q-prov-alias)
                         (funcall ,drgnx-settings-prov-test--first 'q-prov-base)
                         (funcall ,drgnx-settings-prov-test--explain 'q-prov-alias))
                       `(("settings.el" . ,(drgnx-settings-prov-test--settings 'q-prov-alias))
                         ("q-alias.el" . ";;; q-alias.el -*- lexical-binding: t -*-\n(setq q-prov-alias 5)\n"))))
                 '(t (lisp "q-alias.el" 2 5) (lisp "q-alias.el" 2 5) ("your Lisp (q-alias.el:2)" 2 t G4 "q-alias.el")))))

(ert-deftest drgnx-settings-prov/explained-winner-is-symbol-value ()
  ;; V1's values, a later session write, a buffer-local value and a variable nobody set: the explained winner is
  ;; always Emacs's value, never one drgnx computed.
  (should (equal (drgnx-settings-prov-test--v1
                  '((let ((vars '(q-prov-a q-prov-b fill-column)) out)
                      (dolist (v vars) (push (equal (plist-get (drgnx-settings-explain v) :value) (symbol-value v)) out))
                      (setq q-prov-b 30)
                      (push (equal (plist-get (drgnx-settings-explain 'q-prov-b) :value) 30) out)
                      (push (plist-get (drgnx-settings-explain 'q-prov-b) :source) out)
                      (with-temp-buffer
                        (setq-local q-prov-a 42)
                        (push (plist-get (drgnx-settings-explain 'q-prov-a) :value) out))
                      (nreverse out))))
                 '((t t t t "changed this session" 42)))))

(provide 'settings-prov-test)
;;; settings-prov-test.el ends here
