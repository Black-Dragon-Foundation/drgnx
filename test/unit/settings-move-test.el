;;; settings-move-test.el --- Move into Settings, and back -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Move into Settings and Move to My Lisp (design §8.3): only a certain, top-level, single setter with a constant value
;; moves, and only when the value in effect stays; both files change by one place, a backup of your file is kept, and
;; one Undo puts both back.  Each test runs in a child Emacs under a temp HOME (test/settings-child.el): provenance
;; installs watchers, and the files written are the child's.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(defconst drgnx-settings-move-test--head ";;; config.el -*- lexical-binding: t -*-\n"
  "The first line of the test's config.el.")

(defconst drgnx-settings-move-test--settings "(drgnx-settings :version 1\n ;; keep me\n (sat-mv-q 1))\n"
  "The test's settings.el: one entry, with a comment above it.")

(defun drgnx-settings-move-test--load (name)
  "The form that loads NAME (a file in the child's config dir) inside `drgnx-settings-prov-with-load'."
  `(let ((f (expand-file-name ,name (drgnx-user-dir))))
     (drgnx-settings-prov-with-load f (load f nil t t))
     t))

(defun drgnx-settings-move-test--text (name)
  "The form that reads NAME (a file in the child's config dir) as text, nil when it is missing."
  `(drgnx-file-read-bounded (expand-file-name ,name (drgnx-user-dir))))

(defun drgnx-settings-move-test--run (vars files forms)
  "In a child with FILES: declare VARS (options, standard value 0) and watch them, then run FORMS; their values."
  (let* ((pre (append '((require 'drgnx-settings-move))
                      (mapcar (lambda (v) `(defcustom ,v 0 "A test option." :type 'sexp :group 'emacs)) vars)
                      (mapcar (lambda (v) `(drgnx-settings-prov-watch ',v)) vars)))
         (r (drgnx-settings-test-child (append pre forms) :files files)))
    (unless (and (null (plist-get r :error)) (equal (plist-get r :exit) 0))
      (ert-fail (list :error (plist-get r :error) :output (plist-get r :output))))
    (nthcdr (length pre) (plist-get r :values))))

(defun drgnx-settings-move-test--refused (var config &optional before)
  "Why Move into Settings refuses VAR with CONFIG as config.el (BEFORE: forms run before it loads)."
  (car (last (drgnx-settings-move-test--run
              (list var)
              `(("settings.el" . ,drgnx-settings-move-test--settings)
                ("config.el" . ,(concat drgnx-settings-move-test--head config)))
              (append before
                      (list (drgnx-settings-move-test--load "config.el")
                            `(plist-get (drgnx-settings-move-plan ',var) :refused)))))))

(defun drgnx-settings-move-test--dated (text)
  "TEXT with the dates of its comment lines as DATE."
  (and text (replace-regexp-in-string "([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\})" "(DATE)" text)))

(ert-deftest drgnx-settings-move/refuses-a-conditional-form ()
  (should (eq (drgnx-settings-move-test--refused 'sat-mv-c "(when t\n  (setq sat-mv-c 3))\n") 'conditional)))

(ert-deftest drgnx-settings-move/refuses-a-second-setter ()
  (should (eq (drgnx-settings-move-test--refused 'sat-mv-s "(setq sat-mv-s 3)\n(setq sat-mv-s 3)\n") 'second-setter)))

(ert-deftest drgnx-settings-move/refuses-a-computed-value ()
  (should (eq (drgnx-settings-move-test--refused 'sat-mv-x "(setq sat-mv-x (+ 1 2))\n") 'computed)))

(ert-deftest drgnx-settings-move/refuses-a-value-change ()
  ;; Customize saved 2 (custom.el would load before config.el); config.el's setq makes it 1.  Moved, settings.el's 1
  ;; would lose to the saved 2.  Everything else holds: the line is certain.
  (pcase-let ((`(,certain ,refused)
               (last (drgnx-settings-move-test--run
                      '(sat-mv-v)
                      `(("settings.el" . ,drgnx-settings-move-test--settings)
                        ("config.el" . ,(concat drgnx-settings-move-test--head "(setq sat-mv-v 1)\n")))
                      `((custom-set-variables '(sat-mv-v 2))
                        ,(drgnx-settings-move-test--load "config.el")
                        (let ((e (drgnx-settings-explain 'sat-mv-v))) (list (plist-get e :certain) (plist-get e :line)))
                        (plist-get (drgnx-settings-move-plan 'sat-mv-v) :refused)))
                     2)))
    (should (equal certain '(t 2)))
    (should (eq refused 'value-change))))

(ert-deftest drgnx-settings-move/refuses-an-uncertain-line ()
  ;; other.el's setq is the only setter the static index finds; the newest write came from config.el's macro, which
  ;; the index cannot see: the record and the index disagree, so the line is not certain.
  (should (eq (car (last (drgnx-settings-move-test--run
                          '(sat-mv-u)
                          `(("settings.el" . ,drgnx-settings-move-test--settings)
                            ("other.el" . ,(concat drgnx-settings-move-test--head "(setq sat-mv-u 5)\n"))
                            ("config.el" . ,(concat drgnx-settings-move-test--head
                                                    "(defmacro sat-mv-set (v x) (list 'setq v x))\n(sat-mv-set sat-mv-u 5)\n")))
                          (list (drgnx-settings-move-test--load "other.el")
                                (drgnx-settings-move-test--load "config.el")
                                '(plist-get (drgnx-settings-move-plan 'sat-mv-u) :refused)))))
              'uncertain)))

(ert-deftest drgnx-settings-move/moves-one-pair-of-a-multi-pair-setq ()
  (pcase-let ((`(,refused ,config ,entry ,a ,b)
               (cdr (drgnx-settings-move-test--run
                     '(sat-mv-a sat-mv-b)
                     `(("settings.el" . ,drgnx-settings-move-test--settings)
                       ("config.el" . ,(concat drgnx-settings-move-test--head "(setq sat-mv-a 1\n      sat-mv-b 2)\n")))
                     `(,(drgnx-settings-move-test--load "config.el")
                       (let ((plan (drgnx-settings-move-plan 'sat-mv-b)))
                         (unless (plist-get plan :refused) (drgnx-settings-move-apply plan))
                         (plist-get plan :refused))
                       ,(drgnx-settings-move-test--text "config.el")
                       (drgnx-settings-move--entry-state 'sat-mv-b)
                       sat-mv-a sat-mv-b)))))
    (should-not refused)
    (should (equal (drgnx-settings-move-test--dated config)
                   (concat drgnx-settings-move-test--head ";; sat-mv-b: moved to Settings (DATE)\n(setq sat-mv-a 1)\n")))
    (should (equal entry '(2 nil)))
    (should (equal (list a b) '(1 2)))))

(ert-deftest drgnx-settings-move/moves-a-custom-set-variables-entry ()
  (let ((custom (concat ";;; custom.el -*- lexical-binding: t -*-\n(custom-set-variables\n"
                        " ;; custom-set-variables was added by Custom.\n"
                        " ;; If you edit it by hand, you could mess it up, so be careful.\n"
                        " '(sat-mv-k 4)\n '(sat-mv-l 5))\n")))
    (pcase-let ((`(,refused ,text ,entry ,k ,l)
                 (cdr (drgnx-settings-move-test--run
                       '(sat-mv-k sat-mv-l)
                       `(("settings.el" . ,drgnx-settings-move-test--settings) ("custom.el" . ,custom))
                       `(,(drgnx-settings-move-test--load "custom.el")
                         (let ((plan (drgnx-settings-move-plan 'sat-mv-k)))
                           (unless (plist-get plan :refused) (drgnx-settings-move-apply plan))
                           (plist-get plan :refused))
                         ,(drgnx-settings-move-test--text "custom.el")
                         (drgnx-settings-move--entry-state 'sat-mv-k)
                         sat-mv-k sat-mv-l)))))
      (should-not refused)
      (should (equal (drgnx-settings-move-test--dated text)
                     (concat ";;; custom.el -*- lexical-binding: t -*-\n;; sat-mv-k: moved to Settings (DATE)\n"
                             "(custom-set-variables\n"
                             " ;; custom-set-variables was added by Custom.\n"
                             " ;; If you edit it by hand, you could mess it up, so be careful.\n"
                             " '(sat-mv-l 5))\n")))
      (should (equal entry '(4 nil)))
      (should (equal (list k l) '(4 5))))))

(ert-deftest drgnx-settings-move/round-trip-with-one-undo ()
  ;; Into Settings, back to config.el, then each Undo puts both files back byte for byte; the value stays 7.
  (let ((config (concat drgnx-settings-move-test--head "(setq sat-mv-r 7) ; mine\n(setq sat-mv-t 8)\n")))
    (pcase-let ((`(,st1 ,st2 ,st3 ,st4)
                 (cdr (drgnx-settings-move-test--run
                       '(sat-mv-r sat-mv-t)
                       `(("settings.el" . ,drgnx-settings-move-test--settings) ("config.el" . ,config))
                       (append
                        (list (drgnx-settings-move-test--load "config.el"))
                        (let ((state `(list ,(drgnx-settings-move-test--text "config.el")
                                            ,(drgnx-settings-move-test--text "settings.el") sat-mv-r)))
                          `((progn (drgnx-settings-move-apply (drgnx-settings-move-plan 'sat-mv-r)) ,state)
                            (progn (drgnx-settings-move-apply (drgnx-settings-move-plan 'sat-mv-r 'back)) ,state)
                            (progn (drgnx-settings-move-undo) ,state)
                            (progn (drgnx-settings-move-undo) ,state))))))))
      (should (equal (list (drgnx-settings-move-test--dated (car st1)) (nth 2 st1))
                     (list (concat drgnx-settings-move-test--head
                                   ";; sat-mv-r: moved to Settings (DATE) ; mine\n(setq sat-mv-t 8)\n")
                           7)))
      (should (string-match-p "^ (sat-mv-r 7))$" (cadr st1)))
      (should (equal (drgnx-settings-move-test--dated (car st2))
                     (concat drgnx-settings-move-test--head
                             ";; sat-mv-r: moved to Settings (DATE) ; mine\n(setq sat-mv-t 8)\n"
                             "\n;; sat-mv-r: moved from Settings (DATE)\n(setopt sat-mv-r '7)\n")))
      (should (equal (cdr st2) (list drgnx-settings-move-test--settings 7)))
      (should (equal st3 st1))              ; Undo of the move back: the state after the first move
      (should (equal st4 (list config drgnx-settings-move-test--settings 7))))))

(ert-deftest drgnx-settings-move/keeps-a-bak ()
  (let ((config (concat drgnx-settings-move-test--head "(setq sat-mv-k 3)\n")))
    (pcase-let ((`(,baks ,text)
                 (cadr (drgnx-settings-move-test--run
                        '(sat-mv-k)
                        `(("settings.el" . ,drgnx-settings-move-test--settings) ("config.el" . ,config))
                        `(,(drgnx-settings-move-test--load "config.el")
                          (let ((r (drgnx-settings-move-apply (drgnx-settings-move-plan 'sat-mv-k))))
                            (list (directory-files (drgnx-user-dir) nil "\\`config\\.el\\.bak-")
                                  (drgnx-file-read-bounded (plist-get r :bak)))))))))
      (should (= (length baks) 1))
      (should (equal text config)))))

(provide 'settings-move-test)
;;; settings-move-test.el ends here
