;;; lisp-index-test.el --- the static Lisp index -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-lisp-index)
(require 'drgnx-paths)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(defvar lisp-index-test--canary nil "Set only if the index evaluates a form.")

(defmacro lisp-index-test--with-file (text &rest body)
  "Run BODY with `file' bound to a temp file holding TEXT and the cache dir under a temp dir."
  (declare (indent 1))
  `(let* ((root (make-temp-file "lisp-index-" t))
          (file (expand-file-name "init.el" root)))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-cache-dir) (lambda () (expand-file-name "cache" root))))
           (with-temp-file file (insert ,text))
           ,@body)
       (delete-directory root t))))

(defun lisp-index-test--setters (file)
  (plist-get (drgnx-lisp-index-file file) :setters))

(defun lisp-index-test--sig (s)
  (list (plist-get s :var) (plist-get s :kind) (plist-get s :line)))

(ert-deftest drgnx-lisp-index/finds-every-form-kind ()
  (lisp-index-test--with-file
      "(setq a 1)
(setq-default b 2)
(setopt c 3)
(customize-set-variable 'd 4)
(custom-set-variables '(e 5))
(progn (setq f 6))
"
    (should (equal (mapcar #'lisp-index-test--sig (lisp-index-test--setters file))
                   '((a setq 1) (b setq-default 2) (c setopt 3) (d customize-set-variable 4)
                     (e custom-set-variables 5) (f setq 6))))
    (let ((a (car (lisp-index-test--setters file))))
      (should (plist-get a :const-p))
      (should (equal (plist-get a :value) 1))
      (should (plist-get a :top-level))
      (should-not (plist-get a :conditional)))))

(ert-deftest drgnx-lisp-index/marks-conditional ()
  (lisp-index-test--with-file
      "(setq top 1)
(when foo (setq in-when 2))
(unless foo (setq in-unless 3))
(with-eval-after-load 'x (setq in-after 4))
(add-hook 'h (lambda () (setq in-hook 5)))
(progn (setq in-progn 6))
"
    (let ((by (mapcar (lambda (s) (cons (plist-get s :var) (list (plist-get s :top-level) (plist-get s :conditional))))
                      (lisp-index-test--setters file))))
      (should (equal (alist-get 'top by) '(t nil)))
      (should (equal (alist-get 'in-progn by) '(t nil)))
      (dolist (v '(in-when in-unless in-after in-hook))
        (should (equal (alist-get v by) '(nil t)))))))

(ert-deftest drgnx-lisp-index/multi-pair-setq-each-pair ()
  (lisp-index-test--with-file
      "(setq a 1
      b 'two
      c (+ 1 2))
"
    (let ((ss (lisp-index-test--setters file)))
      (should (equal (mapcar #'lisp-index-test--sig ss) '((a setq 1) (b setq 2) (c setq 3))))
      (should (equal (plist-get (nth 1 ss) :value) 'two))
      (should (plist-get (nth 1 ss) :const-p))
      (should-not (plist-get (nth 2 ss) :const-p))
      (should (equal (plist-get (nth 2 ss) :value) '(+ 1 2)))
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-substring (plist-get (nth 1 ss) :beg) (plist-get (nth 1 ss) :end))
                       "b 'two"))))))

(ert-deftest drgnx-lisp-index/custom-set-variables-entry-lines ()
  (lisp-index-test--with-file
      "(custom-set-variables
 '(alpha 1)
 '(beta \"x\" t)
 '(gamma (quote (1 2))))
"
    (should (equal (mapcar #'lisp-index-test--sig (lisp-index-test--setters file))
                   '((alpha custom-set-variables 2) (beta custom-set-variables 3)
                     (gamma custom-set-variables 4))))
    (should (equal (plist-get (nth 2 (lisp-index-test--setters file)) :value) '(1 2)))))

(ert-deftest drgnx-lisp-index/use-package-custom-entries ()
  (lisp-index-test--with-file
      "(use-package foo
  :custom
  (foo-one 1)
  (foo-two \"s\" \"doc\")
  :config
  (setq foo-three 3))
"
    (let ((ss (lisp-index-test--setters file)))
      (should (equal (mapcar #'lisp-index-test--sig ss)
                     '((foo-one use-package-custom 3) (foo-two use-package-custom 4) (foo-three setq 6))))
      (should-not (plist-get (nth 0 ss) :conditional))
      (should (plist-get (nth 2 ss) :conditional)))))

(ert-deftest drgnx-lisp-index/findings-custom-file-and-emacs-dir ()
  (lisp-index-test--with-file
      "(setq custom-file \"/x/custom.el\")
(setq user-emacs-directory \"/y/\")
(load (expand-file-name \"a.el\" user-emacs-directory))
(setq z (locate-user-emacs-file \"b\"))
"
    (let ((f (plist-get (drgnx-lisp-index-file file) :findings)))
      (should (equal (mapcar (lambda (x) (cons (plist-get x :kind) (plist-get x :line))) f)
                     '((custom-file . 1) (user-emacs-directory . 2) (emacs-dir-use . 3) (emacs-dir-use . 4))))
      (should (string-match-p "custom-file" (plist-get (car f) :text))))))

(ert-deftest drgnx-lisp-index/buffer-local-setq-finding ()
  (lisp-index-test--with-file
      "(setq fill-column 100)
(setq-default fill-column 90)
(setq not-a-known-variable 1)
"
    (let ((f (plist-get (drgnx-lisp-index-file file) :findings)))
      (should (equal (mapcar (lambda (x) (cons (plist-get x :kind) (plist-get x :line))) f)
                     '((buffer-local-setq . 1)))))))

(ert-deftest drgnx-lisp-index/never-evaluates ()
  (setq lisp-index-test--canary nil)
  (lisp-index-test--with-file
      "(setq lisp-index-test--canary 'evaluated)
(setq a #.(setq lisp-index-test--canary 'read-eval))
(setq b 2)
"
    (let ((ss (lisp-index-test--setters file)))
      (should (eq (plist-get (car ss) :var) 'lisp-index-test--canary))
      (should-not lisp-index-test--canary))))

(ert-deftest drgnx-lisp-index/cache-by-stamp ()
  (lisp-index-test--with-file "(setq a 1)\n"
    (should (equal (mapcar (lambda (s) (plist-get s :var)) (drgnx-lisp-index-setters 'a (list file))) '(a)))
    (let ((cache (drgnx-lisp-index--cache-file file)))
      (should (file-exists-p cache))
      (should (string-prefix-p (expand-file-name "cache/lisp-index/" root) cache))
      ;; Same stamp: the cache answers, even when the index function would now say something else.
      (cl-letf (((symbol-function 'drgnx-lisp-index-file) (lambda (_) (error "Indexed again"))))
        (should (= 1 (length (drgnx-lisp-index-setters 'a (list file)))))
        (should (= 0 (drgnx-lisp-index-refresh (list file)))))
      ;; A changed file (new size, hence a new stamp) is read again.
      (with-temp-file file (insert "(setq a 1)\n(setq a 2)\n"))
      (should (= 2 (length (drgnx-lisp-index-setters 'a (list file)))))
      (should (equal (plist-get (cadr (drgnx-lisp-index-setters 'a (list file))) :file) file)))))

(defconst lisp-index-test--start
  '((require 'cl-lib)
    (let ((ran 0))
      (cl-letf (((symbol-function 'drgnx-lisp-index-refresh) (lambda (&rest _) (setq ran (1+ ran)) 0))
                ((symbol-function 'drgnx-pkg-activate) #'ignore) ((symbol-function 'drgnx-modules-start) #'ignore)
                ((symbol-function 'drgnx-keys-apply) #'ignore) ((symbol-function 'drgnx-surfaces-refresh) #'ignore)
                ((symbol-function 'drgnx-session-setup) #'ignore))
        (drgnx-init)
        (let ((entry (gethash 'lisp-index drgnx-timer--table)))
          (list (assq 'lisp-index (drgnx-timer-pending))
                (and entry (memq (drgnx-timer--entry-timer entry) timer-idle-list) t)
                ran)))))
  "A start in the child: the `lisp-index' timer it leaves pending, whether it is an idle timer, and how often the
refresh ran.")

(ert-deftest drgnx-lisp-index/start-up-schedules-the-refresh-and-does-not-run-it ()
  ;; drgnx-init leaves one idle timer for the refresh and never runs it during the start; safe mode schedules none.
  (let ((r (drgnx-settings-test-child lisp-index-test--start)))
    (should-not (plist-get r :error))
    (should (equal (car (last (plist-get r :values))) '((lisp-index :core start) t 0))))
  (let ((r (drgnx-settings-test-child lisp-index-test--start :env '("DRGNX_SAFE=1"))))
    (should-not (plist-get r :error))
    (should (equal (car (last (plist-get r :values))) '(nil nil 0)))))

(provide 'lisp-index-test)
;;; lisp-index-test.el ends here
