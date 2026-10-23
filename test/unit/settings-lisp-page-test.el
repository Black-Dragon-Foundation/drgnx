;;; settings-lisp-page-test.el --- the Lisp files page -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Settings: Lisp Files (design §8.1): your Lisp files in load order with what each sets and whether it won, the
;; findings, then the data files; RET opens a file at the line.  Each test runs in a child Emacs under a temp HOME
;; (test/settings-child.el): provenance and the loads must not reach the test runner.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(defconst drgnx-settings-lisp-page-test--head ";;; -*- lexical-binding: t -*-\n" "A Lisp file's first line.")

(defun drgnx-settings-lisp-page-test--load (name)
  "The form that loads NAME (a file in the child's config dir) inside `drgnx-settings-prov-with-load'."
  `(let ((f (expand-file-name ,name (drgnx-user-dir))))
     (drgnx-settings-prov-with-load f (load f nil t t))
     t))

(defun drgnx-settings-lisp-page-test--run (files forms)
  "Run FORMS in a child with FILES, after requiring the page; the value of the last."
  (let ((r (drgnx-settings-test-child (cons '(require 'drgnx-settings-lisp-page) forms) :files files)))
    (unless (and (null (plist-get r :error)) (equal (plist-get r :exit) 0))
      (ert-fail (list :error (plist-get r :error) :output (plist-get r :output))))
    (car (last (plist-get r :values)))))

(ert-deftest drgnx-settings-lisp-page/load-order ()
  ;; The early file, custom.el, config.el, the other listed file, the file config.el loaded, then settings.el.
  (let ((rows (drgnx-settings-lisp-page-test--run
               `(("settings.el" . "(drgnx-settings :version 1\n (sat-lp-s 2))\n")
                 ("custom.el" . ,drgnx-settings-lisp-page-test--head)
                 ("config.el" . ,(concat drgnx-settings-lisp-page-test--head
                                         "(setq sat-lp-w 3)\n"
                                         "(load (expand-file-name \"lisp/helper.el\" (drgnx-user-dir)) nil t t)\n"))
                 ("lisp/helper.el" . ,drgnx-settings-lisp-page-test--head)
                 ("early.el" . ,drgnx-settings-lisp-page-test--head)
                 ("more.el" . ,drgnx-settings-lisp-page-test--head))
               `((defvar sat-lp-w 0)
                 (drgnx-settings-prov-watch 'sat-lp-w)
                 (setq drgnx-user-lisp-files '(("more.el" :on nil) ("early.el" :on t :early t)))
                 ,(drgnx-settings-lisp-page-test--load "custom.el")
                 ,(drgnx-settings-lisp-page-test--load "config.el")
                 (mapcar (lambda (r) (list (file-relative-name (plist-get r :file) (drgnx-user-dir)) (plist-get r :role)
                                           (plist-get r :on) (plist-get r :loaded)
                                           (mapcar (lambda (s) (list (plist-get s :var) (plist-get s :line)
                                                                     (plist-get s :won)))
                                                   (plist-get r :settings))))
                         (drgnx-settings-lisp-page-rows))))))
    (should (equal rows '(("early.el" early t nil nil)
                          ("custom.el" custom t t nil)
                          ("config.el" config t t ((sat-lp-w 2 won)))
                          ("more.el" listed nil nil nil)
                          ("lisp/helper.el" loaded t t nil)
                          ("settings.el" data nil nil ((sat-lp-s 2 unknown))))))))

(ert-deftest drgnx-settings-lisp-page/findings-shown ()
  ;; The index's findings are rows of the file, and the page says them; nothing is loaded.
  (pcase-let ((`(,findings ,shown)
               (drgnx-settings-lisp-page-test--run
                `(("config.el" . ,(concat drgnx-settings-lisp-page-test--head
                                          "(setq custom-file \"/nowhere/custom.el\")\n"
                                          "(setq fill-column 80)\n")))
                '((let ((row (cl-find 'config (drgnx-settings-lisp-page-rows) :key (lambda (r) (plist-get r :role)))))
                    (list (mapcar (lambda (f) (list (plist-get f :kind) (plist-get f :line))) (plist-get row :findings))
                          (with-current-buffer (drgnx-settings-lisp-files)
                            (list (and (string-match-p "! line 2: moves custom-file" (buffer-string)) t)
                                  (and (string-match-p "! line 3: a setq of a buffer-local variable" (buffer-string))
                                       t)))))))))
    (should (equal findings '((custom-file 2) (buffer-local-setq 3))))
    (should (equal shown '(t t)))))

(ert-deftest drgnx-settings-lisp-page/opens-at-the-line ()
  (should (equal (drgnx-settings-lisp-page-test--run
                  `(("config.el" . ,(concat drgnx-settings-lisp-page-test--head "\n(setq sat-lp-o 1)\n")))
                  '((with-current-buffer (drgnx-settings-lisp-files)
                      (goto-char (point-min))
                      (re-search-forward "^ +sat-lp-o ")
                      (with-current-buffer (drgnx-settings-lisp-page-open)
                        (list (file-name-nondirectory buffer-file-name) (line-number-at-pos)
                              (buffer-substring-no-properties (line-beginning-position) (line-end-position)))))))
                 '("config.el" 3 "(setq sat-lp-o 1)"))))

(provide 'settings-lisp-page-test)
;;; settings-lisp-page-test.el ends here
