;;; settings-index-test.el --- The settings index, descriptions and other tools' files -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Task 31 (design 10): `drgnx sync' reads packages' `.el' files as text for their `defcustom's, so the Settings page
;; shows them before the package loads; descriptions make plain `defvar's settings and refine `defcustom's; other
;; tools' files in a workspace are listed.  Everything runs on temp directories, in this process.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-settings-index)
(require 'drgnx-settings-described)
(require 'drgnx-settings-apply)
(require 'drgnx-settings-editors)
(require 'drgnx-settings-page)

(defvar drgnx-settings-index-test--loaded nil "Set to t if the fixture package's code ever ran.")

(defmacro drgnx-settings-index-test--with-package (&rest body)
  "Run BODY with a fixture package `fixpkg-1.0' in a temp dir; `index' is the index file written for it."
  (declare (indent 0))
  `(let* ((root (make-temp-file "idx" t))
          (pkg (expand-file-name "fixpkg-1.0" root))
          (index (expand-file-name "cache/settings-index.eld" root)))
     (unwind-protect
         (progn
           (make-directory pkg)
           (with-temp-file (expand-file-name "fixpkg.el" pkg)
             (insert ";;; fixpkg.el --- fixture -*- lexical-binding: t -*-\n"
                     "(setq drgnx-settings-index-test--loaded t)\n"
                     "(defgroup fixpkg nil \"The fixture.\" :group 'tools)\n"
                     "(defcustom fixpkg-width 80 \"Columns shown.\n\nMore.\" :type 'integer :group 'fixpkg :safe #'integerp)\n"
                     "(defcustom fixpkg-style 'plain \"Style.\" :type '(choice (const plain) (const fancy)) :group 'fixpkg)\n"
                     "(defcustom fixpkg-dyn nil \"Computed.\" :type (list 'repeat 'string) :group 'fixpkg :risky t)\n"
                     "(defcustom fixpkg-server-program \"fix\" \"Program.\" :type 'string :group 'fixpkg)\n"
                     "(defvar fixpkg-plain 3 \"Not a defcustom.\")\n"
                     "(with-eval-after-load 'x (error \"never\"))\n"))
           (with-temp-file (expand-file-name "fixpkg-autoloads.el" pkg)
             (insert "(defcustom fixpkg-auto 1 \"Skipped.\" :type 'integer)\n"))
           (cl-letf (((symbol-function 'drgnx-settings-index-file) (lambda () index))
                     ((symbol-function 'drgnx-settings-index-sources) (lambda () (list (cons pkg "fixpkg")))))
             (setq drgnx-settings-index--cache nil)
             (unwind-protect (progn ,@body) (setq drgnx-settings-index--cache nil))))
       (delete-directory root t))))

(ert-deftest drgnx-settings-index/finds-defcustoms-statically ()
  (drgnx-settings-index-test--with-package
    (should (= 5 (drgnx-settings-index-build)))      ; 4 defcustoms and the defgroup; the autoloads file is left out
    (let ((e (drgnx-settings-index-entry 'fixpkg-width)))
      (should (eq 'integer (plist-get e :type)))
      (should (eq 'fixpkg (plist-get e :group)))
      (should (equal "fixpkg" (plist-get e :package)))
      (should (equal "fixpkg.el" (plist-get e :file)))
      (should (= 4 (plist-get e :line)))
      (should (eq 'integerp (plist-get e :safe)))
      (should (string-prefix-p "Columns shown." (plist-get e :doc))))
    (should (eq t (plist-get (drgnx-settings-index-entry 'fixpkg-dyn) :risky)))
    (should-not (drgnx-settings-index-entry 'fixpkg-auto))
    (should-not (drgnx-settings-index-entry 'fixpkg-plain))
    (should (equal '(fixpkg-dyn fixpkg-server-program fixpkg-style fixpkg-width)
                   (drgnx-settings-index-group-members 'fixpkg)))
    (should (equal (drgnx-settings-index-group-members 'fixpkg) (drgnx-settings-index-group-members 'tools)))))

(ert-deftest drgnx-settings-index/never-loads-a-package ()
  (drgnx-settings-index-test--with-package
    (setq drgnx-settings-index-test--loaded nil)
    (drgnx-settings-index-build)
    (drgnx-settings-index-group-members 'fixpkg)
    (should-not drgnx-settings-index-test--loaded)
    (should-not (featurep 'fixpkg))
    (should-not (boundp 'fixpkg-width))
    (should (drgnx-settings-index-unloaded-p 'fixpkg-width))))

(ert-deftest drgnx-settings-index/a-computed-type-gets-the-lisp-editor ()
  (drgnx-settings-index-test--with-package
    (drgnx-settings-index-build)
    (should (eq 'number (drgnx-settings-editors--head 'number)))
    (should (eq 'number (drgnx-settings-editors-kind 'fixpkg-width)))
    (should (eq 'choice (drgnx-settings-editors-kind 'fixpkg-style)))
    (should (plist-get (drgnx-settings-index-entry 'fixpkg-dyn) :computed))
    (should (eq 'lisp (drgnx-settings-editors-kind 'fixpkg-dyn)))
    ;; once loaded, the live type wins
    (unwind-protect
        (progn (custom-declare-variable 'fixpkg-dyn nil "d" :type '(repeat string))
               (should (eq 'widget (drgnx-settings-editors-kind 'fixpkg-dyn))))
      (put 'fixpkg-dyn 'standard-value nil) (put 'fixpkg-dyn 'custom-type nil) (makunbound 'fixpkg-dyn))))

(defmacro drgnx-settings-index-test--with-described (text &rest body)
  "Run BODY with the user's described.el holding TEXT."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "dsc" t)) (file (expand-file-name "described.el" dir)))
     (unwind-protect
         (progn (with-temp-file file (insert ,text))
                (setq drgnx-settings-described--cache nil)
                (cl-letf (((symbol-function 'drgnx-settings-described-files) (lambda () (list file))))
                  (clrhash drgnx-setting--cache)
                  ,@body))
       (setq drgnx-settings-described--cache nil)
       (clrhash drgnx-setting--cache)
       (delete-directory dir t))))

(ert-deftest drgnx-settings-index/a-described-defvar-is-a-setting ()
  (defvar drgnx-settings-index-test--dv 3 "A plain defvar.")
  (drgnx-settings-index-test--with-described
      "(drgnx-described (drgnx-settings-index-test--dv :type integer :doc \"How many.\" :group fixgrp :scope global))"
    (should (drgnx-settings-described-defvar-p 'drgnx-settings-index-test--dv))
    (should (memq 'drgnx-settings-index-test--dv (drgnx-settings-described-group-vars 'fixgrp)))
    (should (eq 'integer (drgnx-setting-type 'drgnx-settings-index-test--dv)))
    (should (eq 'global (plist-get (drgnx-setting-meta 'drgnx-settings-index-test--dv) :scope)))
    (should (eq 'number (drgnx-settings-editors-kind 'drgnx-settings-index-test--dv)))
    (unwind-protect
        (progn
          (should (eq 'applied (drgnx-settings-push 'drgnx-settings-index-test--dv 9)))
          (should (= 9 (default-value 'drgnx-settings-index-test--dv)))
          (should (drgnx-settings-teardown 'drgnx-settings-index-test--dv))
          (should (= 3 (default-value 'drgnx-settings-index-test--dv))))
      (put 'drgnx-settings-index-test--dv 'theme-value nil))
    ;; an undescribed defvar is not one
    (defvar drgnx-settings-index-test--other 1 "x")
    (should-not (drgnx-settings-described-defvar-p 'drgnx-settings-index-test--other))))

(ert-deftest drgnx-settings-index/editing-a-description-applies-at-once ()
  "US-T31-META-CACHE-1: the meta cache of a looked-up symbol follows the description files."
  (drgnx-settings-index-test--with-described "(drgnx-described (tab-width :scope global))"
    (should (eq 'global (plist-get (drgnx-setting-meta 'tab-width) :scope)))
    (with-temp-file (car (drgnx-settings-described-files))
      (insert "(drgnx-described (tab-width :scope workspace :merge alist))   "))
    (should (eq 'alist (plist-get (drgnx-setting-meta 'tab-width) :merge)))))

(ert-deftest drgnx-settings-index/description-files-are-checked-once-per-command ()
  ;; interactive: a meta lookup (even a hit) looks at the description files once per command, by
  ;; `drgnx-file-stamp' (never the access time)
  (drgnx-settings-index-test--with-described "(drgnx-described (tab-width :scope global))"
    (let ((noninteractive nil) (num-input-keys 100) (drgnx-settings-described--tick nil) (looks 0)
          (files (symbol-function 'drgnx-settings-described-files)))
      (cl-letf (((symbol-function 'drgnx-settings-described-files) (lambda () (cl-incf looks) (funcall files))))
        (dotimes (_ 3) (should (eq 'global (plist-get (drgnx-setting-meta 'tab-width) :scope))))
        (should (= looks 1))
        (should (equal (car drgnx-settings-described--cache)
                       (mapcar (lambda (f) (cons f (drgnx-file-stamp f))) (funcall files))))
        (setq num-input-keys 101)
        (drgnx-setting-meta 'tab-width)
        (should (= looks 2))))))

(ert-deftest drgnx-settings-index/descriptions-refine-defcustoms ()
  (drgnx-settings-index-test--with-described
      "(drgnx-described (fill-column :workspace never :merge alist) (tab-width :scope global))"
    (should (eq 'never (plist-get (drgnx-setting-meta 'fill-column) :workspace)))
    (should (eq 'alist (plist-get (drgnx-setting-meta 'fill-column) :merge)))
    (should (eq 'global (plist-get (drgnx-setting-meta 'tab-width) :scope)))
    (should (eq 'data (plist-get (drgnx-setting-meta 'tab-width) :workspace))))
  ;; the shipped descriptions mark the program-holding and merged settings
  (let ((drgnx-dir drgnx-dir))
    (setq drgnx-settings-described--cache nil)
    (clrhash drgnx-setting--cache)
    (should (eq 'code (plist-get (drgnx-setting-meta 'eglot-server-programs) :workspace)))
    (should (eq 'alist (plist-get (drgnx-setting-meta 'auto-mode-alist) :merge)))
    (should (eq 'global (plist-get (drgnx-setting-meta 'gc-cons-threshold) :scope)))))

(ert-deftest drgnx-settings-index/other-tools-listed ()
  (let ((root (make-temp-file "ot" t)))
    (unwind-protect
        (progn
          (dolist (f '(".editorconfig" "pyproject.toml" "notes.txt")) (write-region "" nil (expand-file-name f root)))
          (should (equal '(".editorconfig" "pyproject.toml")
                         (mapcar #'file-name-nondirectory (drgnx-settings-index-other-tools-in root))))
          (should-not (drgnx-settings-index-other-tools-in nil))
          (should (string-match-p "pyproject.toml" (drgnx-settings-page--other-tools-text root))))
      (delete-directory root t))))

(provide 'settings-index-test)
;;; settings-index-test.el ends here
