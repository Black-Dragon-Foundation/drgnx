;;; settings-tidy-test.el --- Tidy custom.el, and en/disable-command -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Settings: Tidy custom.el (design §8.4) works on the file, not the session: entries equal to the default go,
;; `package-selected-packages' loses its duplicates, the form is printed as Customize prints it, text outside the form
;; stays, Customize's own saver is never called, and one Undo puts the file back.  `en/disable-command' writes to
;; custom.el, never the checkout's init.el.  Each test runs in a child Emacs under a temp HOME
;; (test/settings-child.el): the files written are the child's.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(defconst drgnx-settings-tidy-test--header
  (concat "(custom-set-variables\n"
          " ;; custom-set-variables was added by Custom.\n"
          " ;; If you edit it by hand, you could mess it up, so be careful.\n"
          " ;; Your init file should contain only one such instance.\n"
          " ;; If there is more than one, they won't work right.\n")
  "The start of the form as Customize prints it.")

(defconst drgnx-settings-tidy-test--head ";;; custom.el -*- lexical-binding: t -*-\n"
  "The first line of the test's custom.el.")

(defun drgnx-settings-tidy-test--run (vars files forms)
  "In a child with FILES: custom.el is `custom-file', VARS are options (standard value 0); then FORMS: their values."
  (let* ((pre (append '((require 'drgnx-settings-tidy)
                        (setq custom-file (expand-file-name "custom.el" (drgnx-user-dir))))
                      (mapcar (lambda (v) `(defcustom ,v 0 "A test option." :type 'sexp :group 'emacs)) vars)))
         (r (drgnx-settings-test-child (append pre forms) :files files)))
    (unless (and (null (plist-get r :error)) (equal (plist-get r :exit) 0))
      (ert-fail (list :error (plist-get r :error) :output (plist-get r :output))))
    (nthcdr (length pre) (plist-get r :values))))

(defconst drgnx-settings-tidy-test--text '(drgnx-file-read-bounded custom-file)
  "The form that reads the child's custom.el.")

(ert-deftest drgnx-settings-tidy/drops-defaults ()
  ;; sat-td-a is its default: it goes.  sat-td-c is its default too, but carries a comment: it stays.  sat-td-gone is
  ;; defined by nothing: listed, kept, and removed only when asked.  The rest is sorted, one entry per line.
  (let ((custom (concat drgnx-settings-tidy-test--head
                        "(custom-set-variables\n"
                        " ;; custom-set-variables was added by Custom.\n"
                        " '(sat-td-b 3)\n '(sat-td-gone 1)\n '(sat-td-a 0) '(sat-td-c 0 nil nil \"why\"))\n")))
    (pcase-let ((`(,first ,second ,record ,after ,bak ,undone)
                 (drgnx-settings-tidy-test--run
                  '(sat-td-a sat-td-b sat-td-c) `(("custom.el" . ,custom))
                  `((let ((p (drgnx-settings-tidy-plan)))
                      (list (plist-get p :dropped) (plist-get p :undefined) (plist-get p :entries)
                            (plist-get p :removed)))
                    (let ((p (drgnx-settings-tidy-plan :remove '(sat-td-gone))))
                      (list (plist-get p :dropped) (plist-get p :undefined) (plist-get p :entries)
                            (plist-get p :removed)))
                    (let ((r (drgnx-settings-tidy-apply (drgnx-settings-tidy-plan :remove '(sat-td-gone)))))
                      (and r t))
                    ,drgnx-settings-tidy-test--text
                    (drgnx-file-read-bounded (plist-get (car drgnx-settings-tidy--undo) :bak))
                    (progn (drgnx-settings-tidy-undo) ,drgnx-settings-tidy-test--text)))))
      (should (equal first '((sat-td-a) (sat-td-gone) (sat-td-b sat-td-c sat-td-gone) nil)))
      (should (equal second '((sat-td-a) nil (sat-td-b sat-td-c) (sat-td-gone))))
      (should record)
      (should (equal after (concat drgnx-settings-tidy-test--head drgnx-settings-tidy-test--header
                                   " '(sat-td-b 3)\n '(sat-td-c 0 nil nil \"why\"))\n")))
      (should (equal bak custom))
      (should (equal undone custom)))))

(ert-deftest drgnx-settings-tidy/keeps-hand-edits-made-since-start ()
  ;; custom.el is loaded (sat-td-a saved as 1), then edited by hand (5, and sat-td-b added), and this session saves
  ;; sat-td-c in its symbol properties only.  Tidy prints the file's form: 5 and sat-td-b, never the session's.
  (let ((custom (concat drgnx-settings-tidy-test--head drgnx-settings-tidy-test--header " '(sat-td-a 1))\n"))
        (edited (concat drgnx-settings-tidy-test--head "(custom-set-variables\n '(sat-td-b 7)\n '(sat-td-a 5))\n")))
    (pcase-let ((`(,loaded ,new)
                 (drgnx-settings-tidy-test--run
                  '(sat-td-a sat-td-b sat-td-c) `(("custom.el" . ,custom))
                  `((progn (load custom-file nil t t) sat-td-a)
                    (progn (drgnx-file-write-text custom-file ,edited)
                           (put 'sat-td-c 'saved-value '(9))
                           (plist-get (drgnx-settings-tidy-plan) :new))))))
      (should (equal loaded 1))
      (should (equal new (concat drgnx-settings-tidy-test--head drgnx-settings-tidy-test--header
                                 " '(sat-td-a 5)\n '(sat-td-b 7))\n"))))))

(ert-deftest drgnx-settings-tidy/keeps-text-outside-the-form ()
  (let* ((before (concat ";;; custom.el --- mine -*- lexical-binding: t -*-\n;; a note of mine\n"
                         "(put 'narrow-to-region 'disabled nil)   ; and this\n\n"))
         (after (concat "\n;; between\n(custom-set-faces\n ;; custom-set-faces was added by Custom.\n"
                        " '(default ((t (:height 120)))))\n;;; custom.el ends here\n"))
         (custom (concat before "(custom-set-variables\n ;; custom-set-variables was added by Custom.\n"
                         " '(sat-td-b 3) '(sat-td-a 0))" after)))
    (should (equal (car (drgnx-settings-tidy-test--run
                         '(sat-td-a sat-td-b) `(("custom.el" . ,custom))
                         `((progn (drgnx-settings-tidy-apply (drgnx-settings-tidy-plan))
                                  ,drgnx-settings-tidy-test--text))))
                   (concat before drgnx-settings-tidy-test--header " '(sat-td-b 3))" after)))))

(ert-deftest drgnx-settings-tidy/never-uses-custom-save-variables ()
  ;; Customize's savers print the session; with each of them made to fail, Tidy still writes the file.
  (let ((custom (concat drgnx-settings-tidy-test--head "(custom-set-variables\n '(sat-td-b 3)\n '(sat-td-a 0))\n")))
    (should (equal (car (drgnx-settings-tidy-test--run
                         '(sat-td-a sat-td-b) `(("custom.el" . ,custom))
                         `((progn
                             (require 'cus-edit)
                             (dolist (f '(custom-save-all custom-save-variables custom-save-faces custom-save-delete
                                                          customize-save-variable))
                               (advice-add f :override (lambda (&rest _) (error "Tidy called a saver of Customize"))))
                             (drgnx-settings-tidy-apply (drgnx-settings-tidy-plan))
                             ,drgnx-settings-tidy-test--text))))
                   (concat drgnx-settings-tidy-test--head drgnx-settings-tidy-test--header " '(sat-td-b 3))\n")))))

(ert-deftest drgnx-settings-tidy/dedups-selected-packages ()
  (let ((custom (concat drgnx-settings-tidy-test--head
                        "(custom-set-variables\n"
                        " '(package-selected-packages '(magit vertico magit corfu vertico)))\n")))
    (pcase-let ((`(,deduped ,text)
                 (drgnx-settings-tidy-test--run
                  nil `(("custom.el" . ,custom))
                  `((progn (require 'package)
                           (let ((p (drgnx-settings-tidy-plan))) (drgnx-settings-tidy-apply p) (plist-get p :deduped)))
                    ,drgnx-settings-tidy-test--text))))
      (should (equal deduped '(magit vertico)))
      (should (equal text (concat drgnx-settings-tidy-test--head drgnx-settings-tidy-test--header
                                  " '(package-selected-packages '(magit vertico corfu)))\n"))))))

(ert-deftest drgnx-settings-tidy/refuses-what-it-cannot-be-sure-of ()
  ;; A comment of yours inside the form, an entry of another shape, a file that does not read: never rewritten.
  (should (equal (drgnx-settings-tidy-test--run
                  '(sat-td-a)
                  `(("custom.el" . ,(concat drgnx-settings-tidy-test--head
                                            "(custom-set-variables\n ;; mine\n '(sat-td-a 1))\n"))
                    ("other.el" . "(custom-set-variables (list 'sat-td-a 1))\n")
                    ("broken.el" . "(custom-set-variables '(sat-td-a 1)\n"))
                  '((plist-get (drgnx-settings-tidy-plan) :refused)
                    (plist-get (drgnx-settings-tidy-plan :file (expand-file-name "other.el" (drgnx-user-dir))) :refused)
                    (plist-get (drgnx-settings-tidy-plan :file (expand-file-name "broken.el" (drgnx-user-dir)))
                               :refused)))
                 '(comment unknown-entry unreadable))))

(ert-deftest drgnx-settings-tidy/disable-command-writes-custom-file ()
  ;; user-init-file is the checkout's init/init.el, as in drgnx: disable-command and enable-command write custom.el.
  (let ((init ";;; init.el --- the checkout's -*- lexical-binding: t -*-\n")
        (custom (concat drgnx-settings-tidy-test--head "(custom-set-variables\n '(sat-td-a 1))\n")))
    (pcase-let ((`(,advised ,disabled ,after-disable ,after-enable ,checkout)
                 (drgnx-settings-tidy-test--run
                  '(sat-td-a) `(("custom.el" . ,custom) ("~/checkout/init/init.el" . ,init))
                  `((progn (setq user-init-file (expand-file-name "~/checkout/init/init.el"))
                           (and (advice-member-p #'drgnx-settings-tidy-disable-command 'en/disable-command) t))
                    (progn (defun sat-td-cmd () (interactive) t)
                           (disable-command 'sat-td-cmd)
                           (get 'sat-td-cmd 'disabled))
                    ,drgnx-settings-tidy-test--text
                    (progn (enable-command 'sat-td-cmd) ,drgnx-settings-tidy-test--text)
                    (drgnx-file-read-bounded user-init-file)))))
      (should advised)
      (should (eq disabled t))
      (should (equal after-disable (concat custom "(put 'sat-td-cmd 'disabled t)\n")))
      (should (equal after-enable (concat custom "(put 'sat-td-cmd 'disabled nil)\n")))
      (should (equal checkout init)))))

(ert-deftest drgnx-settings-tidy/doctor-reports-size-and-dormant ()
  (let ((custom (concat drgnx-settings-tidy-test--head "(custom-set-variables\n '(sat-td-a 1)\n '(sat-td-gone 2))\n")))
    (pcase-let ((`((,status ,detail ,fix) ,missing)
                 (drgnx-settings-tidy-test--run
                  '(sat-td-a) `(("custom.el" . ,custom))
                  '((progn (require 'drgnx-doctor)
                           (drgnx-doctor-check 'custom-file (list :custom-file (drgnx-doctor--custom-file))))
                    (drgnx-doctor--custom-file (expand-file-name "nothing.el" (drgnx-user-dir)))))))
      (should (eq status 'info))
      (should (string-match-p (concat "\\`custom\\.el: [0-9.]+ [KMG]?i?B, 2 entries, 1 dormant "
                                      "(nothing in this Emacs defines sat-td-gone)\\'")
                              detail))
      (should fix)
      (should-not missing))))

(provide 'settings-tidy-test)
;;; settings-tidy-test.el ends here
