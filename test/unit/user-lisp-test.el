;;; user-lisp-test.el --- your Lisp files: on/off, early files, :emacs-dir, findings, bisect -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 29 (design §8.2): `drgnx-user-lisp-files'.  Each test that loads Lisp runs in a child Emacs
;; under a temp HOME (test/settings-child.el): the loader sets variables, writes settings.el and installs watchers.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(defun drgnx-user-lisp-test--run (files forms &optional env)
  "FORMS' values in a child whose config dir holds FILES, after `drgnx-settings-apply-global'."
  (let* ((start '((progn (drgnx-settings-apply-global)
                         (dolist (f '(drgnx-settings-lisp-page drgnx-settings-move drgnx-settings-prov drgnx-pkg))
                           (require f))
                         t)))
         (r (drgnx-settings-test-child (append start forms) :files files :env env)))
    (unless (and (null (plist-get r :error)) (equal (plist-get r :exit) 0))
      (ert-fail (list :error (plist-get r :error) :output (plist-get r :output))))
    (nthcdr (length start) (plist-get r :values))))

(defconst drgnx-user-lisp-test--off
  "(drgnx-settings :version 1\n (drgnx-user-lisp-files '((\"a.el\" :on nil))))\n"
  "settings.el with a.el listed and off.")

(ert-deftest drgnx-user-lisp/on-loads-now ()
  (should (equal (drgnx-user-lisp-test--run
                  `(("settings.el" . ,drgnx-user-lisp-test--off)
                    ("a.el" . "(setq sat-ul-a (1+ (or (bound-and-true-p sat-ul-a) 0)))\n"))
                  '((progn (defvar sat-ul-a nil) (drgnx-user-lisp-load-all) sat-ul-a) ; off: not loaded at start
                    (drgnx-user-lisp-set-on "a.el" t)
                    sat-ul-a
                    (drgnx-user-lisp-set-on "a.el" t)                                  ; on again: loaded once
                    sat-ul-a
                    (let ((row (cl-find "a.el" (drgnx-settings-lisp-page-rows) ; the loader told the page (US-LISP-PAGE-LOADS-1)
                                        :key (lambda (r) (file-name-nondirectory (plist-get r :file))) :test #'equal)))
                      (list (plist-get row :on) (plist-get row :loaded) (numberp (plist-get row :seconds))))))
                 '(nil loaded-now 1 already-loaded 1 (t t t)))))

(ert-deftest drgnx-user-lisp/off-at-next-start ()
  ;; Off: the file stays loaded now (code that ran cannot be unloaded), settings.el says :on nil, and the next
  ;; start's loader does not load it.
  (let ((r (drgnx-user-lisp-test--run
            `(("settings.el" . "(drgnx-settings :version 1\n (drgnx-user-lisp-files '((\"a.el\" :on t))))\n")
              ("a.el" . "(setq sat-ul-b (1+ (or (bound-and-true-p sat-ul-b) 0)))\n"))
            '((progn (defvar sat-ul-b nil) (drgnx-user-lisp-load-all) sat-ul-b)
              (drgnx-user-lisp-set-on "a.el" nil)
              sat-ul-b
              (drgnx-user-lisp-on-p (expand-file-name "a.el" (drgnx-user-dir)))
              (with-temp-buffer (insert-file-contents (expand-file-name "settings.el" (drgnx-user-dir)))
                                (buffer-string))))))
    (should (equal (cl-subseq r 0 4) '(1 off-at-next-start 1 nil)))
    (should (string-match-p ":on nil" (nth 4 r)))))

(ert-deftest drgnx-user-lisp/off-skips-config-and-custom ()
  ;; config.el and custom.el have rows with the same switch (design §8.2): drgnx--load-user-config asks it.
  (should (equal (drgnx-user-lisp-test--run
                  `(("settings.el" . "(drgnx-settings :version 1\n (drgnx-user-lisp-files '((\"config.el\" :on nil))))\n")
                    ("config.el" . "(setq sat-ul-c 1)\n"))
                  '((progn (defvar sat-ul-c 0)
                           (drgnx--load-user-config)
                           sat-ul-c)))
                 '(0))))

(ert-deftest drgnx-user-lisp/early-file-loads-early ()
  ;; The early loader reads settings.el as data before drgnx exists; the page and notices hear of it afterwards, and
  ;; the later loader does not load it a second time.
  (let ((r (drgnx-user-lisp-test--run
            `(("settings.el" . "(drgnx-settings :version 1\n (drgnx-user-lisp-files '((\"e.el\" :early t) (\"l.el\"))))\n")
              ("e.el" . "(defvar sat-ul-e 0) (setq sat-ul-e (1+ sat-ul-e))\n(error \"boom in e\")\n")
              ("l.el" . "(defvar sat-ul-order nil) (push 'l sat-ul-order)\n"))
            '((progn (defvar sat-ul-order nil) (drgnx-user-lisp-load-early) (list (boundp 'sat-ul-e) sat-ul-order))
              (length drgnx-user-lisp--early-notes)
              (progn (drgnx-user-lisp-load-all) (list sat-ul-e sat-ul-order drgnx-user-lisp--early-notes))
              (let ((row (cl-find "e.el" (drgnx-settings-lisp-page-rows)
                                  :key (lambda (r) (file-name-nondirectory (plist-get r :file))) :test #'equal)))
                (list (plist-get row :early) (plist-get row :loaded) (plist-get (plist-get row :error) :text)))))))
    (should (equal (nth 0 r) '(t nil)))                ; e.el ran early, l.el did not
    (should (equal (nth 1 r) 1))
    (should (equal (nth 2 r) '(1 (l) nil)))            ; e.el once, l.el after, the notes handed over
    (should (equal (nth 3 r) '(t t "boom in e")))))

(ert-deftest drgnx-user-lisp/early-files-are-not-read-in-safe-mode ()
  (should (equal (drgnx-user-lisp-test--run
                  `(("settings.el" . "(drgnx-settings :version 1\n (drgnx-user-lisp-files '((\"e.el\" :early t))))\n")
                    ("e.el" . "(setq sat-ul-s 1)\n"))
                  '((progn (defvar sat-ul-s 0) (drgnx-user-lisp-load-early) (drgnx-user-lisp-load-all) sat-ul-s))
                  '("DRGNX_SAFE=1"))
                 '(0))))

(ert-deftest drgnx-user-lisp/emacs-dir-finds-its-lisp-dir ()
  ;; :emacs-dir binds user-emacs-directory for that one file: its locate-user-emacs-file finds its own lisp/, and
  ;; nothing after it sees the binding.
  (let ((r (drgnx-user-lisp-test--run
            `(("settings.el" . "(drgnx-settings :version 1\n (drgnx-user-lisp-files '((\"~/old/init.el\" :emacs-dir \"~/old/\"))))\n")
              ("~/old/init.el" . "(defvar sat-ul-found nil)\n(setq sat-ul-found (locate-user-emacs-file \"lisp/h.el\"))\n")
              ("~/old/lisp/h.el" . ";; helper\n"))
            '((let ((before user-emacs-directory))
                (drgnx-user-lisp-load-all)
                (list (expand-file-name sat-ul-found) (equal before user-emacs-directory)
                      (file-exists-p sat-ul-found) (expand-file-name "~/old/lisp/h.el")))))))
    (pcase-let ((`((,found ,same ,exists ,expect)) r))
      (should (equal found expect))
      (should same)
      (should exists))))

(ert-deftest drgnx-user-lisp/findings-listed ()
  ;; Adding shows what the file does to user-emacs-directory and custom-file, and offers the early-init.el beside it.
  (let ((r (drgnx-user-lisp-test--run
            '(("~/old/init.el" . "(setq custom-file (expand-file-name \"c.el\" user-emacs-directory))\n(load (locate-user-emacs-file \"lisp/x\"))\n(setq package-enable-at-startup t)\n(package-initialize)\n")
              ("~/old/early-init.el" . "(setq package-enable-at-startup nil)\n"))
            '((let ((plan (drgnx-user-lisp-add-plan (expand-file-name "~/old/init.el"))))
                (list (mapcar (lambda (f) (plist-get f :kind)) (plist-get plan :findings))
                      (plist-get plan :emacs-dir-uses)
                      (and (plist-get plan :early-init) (file-name-nondirectory (plist-get plan :early-init)))
                      (mapcar (lambda (b) (plist-get b :kind)) (plist-get plan :bootstraps))))))))
    (pcase-let ((`((,kinds ,uses ,early ,boots)) r))
      (should (memq 'custom-file kinds))
      (should (memq 'package-enable-at-startup kinds))
      (should (= uses 2))                              ; the custom-file line and the load line
      (should (equal early "early-init.el"))
      (should (equal boots '(package-initialize))))))

(ert-deftest drgnx-user-lisp/add-writes-the-file-and-the-early-file ()
  (let ((r (drgnx-user-lisp-test--run
            '(("~/old/init.el" . "(defvar sat-ul-i 0) (setq sat-ul-i (1+ sat-ul-i))\n")
              ("~/old/early-init.el" . "(defvar sat-ul-ei 0) (setq sat-ul-ei (1+ sat-ul-ei))\n"))
            '((progn (defvar sat-ul-i 0) (defvar sat-ul-ei 0)
                     (drgnx-user-lisp-add (expand-file-name "~/old/init.el")
                                          :early-init (expand-file-name "~/old/early-init.el"))
                     (list sat-ul-i sat-ul-ei
                           (mapcar (lambda (e) (list (file-name-nondirectory (car e)) (plist-get (cdr e) :early)))
                                   (drgnx-user-lisp--normal drgnx-user-lisp-files))))))))
    (should (equal (car r) '(1 1 (("early-init.el" t) ("init.el" nil)))))))

(ert-deftest drgnx-user-lisp/bootstrap-named-by-doctor ()
  (require 'drgnx-doctor)
  (require 'drgnx-user-lisp)
  (let ((f (make-temp-file "drgnx-ul" nil ".el"
                           "(defvar bootstrap-version)\n;; (package-initialize) commented out\n(package-initialize)\n(defvar elpaca-installer-version 0.8)\n")))
    (unwind-protect
        (let* ((bs (drgnx-user-lisp-bootstraps (list f)))
               (r (drgnx-doctor-check 'user-lisp-bootstrap (list :user-lisp-bootstraps bs))))
          (should (equal (mapcar (lambda (b) (plist-get b :kind)) bs) '(straight package-initialize elpaca)))
          (should (eq (car r) 'info))
          (should (string-match-p "package-initialize bootstrap" (nth 1 r)))
          (should-not (drgnx-doctor-check 'user-lisp-bootstrap nil)))
      (delete-file f))))

(ert-deftest drgnx-user-lisp/bisect-includes-user-files ()
  ;; Your Lisp files are candidates beside the modules: the culprit file (a string) is found, a config.el that is the
  ;; culprit too, and your settings.el is untouched.
  (let ((r (drgnx-user-lisp-test--run
            `(("settings.el" . "(drgnx-settings :version 1\n (drgnx-user-lisp-files '((\"a.el\") (\"bad.el\") (\"c.el\"))))\n")
              ("a.el" . "") ("bad.el" . "") ("c.el" . "") ("config.el" . ""))
            '((progn
                (require 'drgnx-pkg)
                (let* ((mods (make-temp-file "mods" t))
                       (before (with-temp-buffer (insert-file-contents (expand-file-name "settings.el" (drgnx-user-dir)))
                                                 (buffer-string)))
                       (on-p (lambda (dir name)
                               (let ((e (cl-find name (drgnx-user-lisp--normal
                                                       (drgnx-user-lisp--read-listed (expand-file-name "settings.el" dir)))
                                                 :key (lambda (x) (file-name-nondirectory (car x))) :test #'equal)))
                                 (or (null e) (drgnx-user-lisp--on (cdr e))))))
                       (bad (drgnx-pkg-bisect (lambda (dir) (funcall on-p dir "bad.el")) :modules-dir mods))
                       (cfg (drgnx-pkg-bisect (lambda (dir) (funcall on-p dir "config.el")) :modules-dir mods)))
                  (list (and (stringp bad) (file-name-nondirectory bad))
                        (and (stringp cfg) (file-name-nondirectory cfg))
                        (equal before (with-temp-buffer
                                        (insert-file-contents (expand-file-name "settings.el" (drgnx-user-dir)))
                                        (buffer-string))))))))))
    (should (equal (car r) '("bad.el" "config.el" t)))))

(ert-deftest drgnx-user-lisp/a-variable-set-only-in-config-has-its-line ()
  ;; US-MOVE-UNWATCHED-1: nothing manages the variable, yet provenance records the line while config.el loads, so
  ;; Move into Settings is not refused for "line unknown".
  (let ((r (drgnx-user-lisp-test--run
            '(("config.el" . ";;; config.el -*- lexical-binding: t -*-\n(setq sat-ul-w 5)\n"))
            '((progn (defcustom sat-ul-w 0 "A test option." :type 'sexp :group 'emacs)
                     (let ((f (expand-file-name "config.el" (drgnx-user-dir))))
                       (drgnx-settings-prov-with-load f (load f nil t t)))
                     (let ((e (drgnx-settings-explain 'sat-ul-w)))
                       (list sat-ul-w (plist-get e :line) (plist-get e :certain)
                             (plist-get (drgnx-settings-move-plan 'sat-ul-w) :refused))))))))
    (should (equal (car r) '(5 2 t nil)))))

;;; user-lisp-test.el ends here
