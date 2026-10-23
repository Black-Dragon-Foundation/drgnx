;;; settings-compat-trust-test.el --- compatibility rows C8, C24: workspace trust in a child Emacs -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Each row runs in a child Emacs under a temp HOME with only `drgnx' required (workspace trust loads with
;; core/drgnx.el, through drgnx-settings-workspace).  Every open runs with `inhibit-interaction' t; the stock prompt,
;; `hack-local-variables-confirm', is recorded (in batch it only says no), so a row sees whether Emacs asked.

;;; Code:
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(defun drgnx-settings-compat-trust--open (file &rest forms)
  "FORMS evaluated in the buffer visiting FILE, opened with `inhibit-interaction' t; the stock prompt is recorded in
`drgnx-compat-asked' (the variables it asked about, per call)."
  `(let ((inhibit-interaction t))
     (cl-letf (((symbol-function 'hack-local-variables-confirm)
                (lambda (all-vars &rest _) (push (mapcar #'car all-vars) drgnx-compat-asked) nil)))
       (with-current-buffer (find-file-noselect ,file) ,@forms))))

(defconst drgnx-settings-compat-trust--c8-files
  '(("~/proj/a.txt" . "hi\n")
    ("~/proj/src/b.txt" . "hi\n")
    ("~/proj/.dir-locals.el" . "((nil . ((fill-column . 66) (drgnx-c8-data . \"x\") (eval . (setq drgnx-c8-ran t))))
 (text-mode . ((tab-width . 3) (subdirs . nil)))
 (\"src/\" . ((nil . ((fill-column . 50))))))\n"))
  "C8's files: an untrusted project's .dir-locals.el with nil, mode and subdir sections, `subdirs' and `eval'.")

(defconst drgnx-settings-compat-trust--c8-forms
  (list '(require 'cl-lib)
        '(defvar drgnx-c8-data nil)
        '(defvar drgnx-c8-ran nil)
        '(defvar drgnx-compat-asked nil)
        ;; an interactive open: Emacs's own prompt is asked (it says no in batch)
        (drgnx-settings-compat-trust--open
         "~/proj/a.txt" '(prog1 (list fill-column tab-width drgnx-c8-data drgnx-c8-ran drgnx-compat-asked)
                           (setq drgnx-compat-asked nil)))
        (drgnx-settings-compat-trust--open
         "~/proj/src/b.txt" '(prog1 (list fill-column tab-width drgnx-c8-data drgnx-c8-ran drgnx-compat-asked)
                               (setq drgnx-compat-asked nil)))
        ;; drgnx's automatic open (`:safe'): safe values only, no prompt
        `(let ((enable-local-variables :safe))
           (kill-buffer (get-file-buffer (expand-file-name "~/proj/a.txt")))
           ,(drgnx-settings-compat-trust--open
             "~/proj/a.txt" '(list fill-column tab-width drgnx-c8-data drgnx-c8-ran drgnx-compat-asked))))
  "C8's forms, the same in the drgnx and the stock child.")

(ert-deftest drgnx-settings-compat/c8-untrusted-dir-locals-are-stock ()
  (let ((r (drgnx-settings-test-child drgnx-settings-compat-trust--c8-forms
                                      :files drgnx-settings-compat-trust--c8-files))
        (stock (drgnx-settings-test-child drgnx-settings-compat-trust--c8-forms
                                          :files drgnx-settings-compat-trust--c8-files
                                          :env '("DRGNX_SETTINGS_TEST_STOCK=1"))))
    (should-not (plist-get r :error))
    (should-not (plist-get stock :error))
    (should (equal (plist-get r :values) (plist-get stock :values)))
    (let ((a (nth 4 (plist-get r :values))) (safe (nth 6 (plist-get r :values))))
      (should (nth 4 a))                                   ; the stock prompt was asked
      (should-not (nth 3 a))                               ; and the eval did not run
      (should (equal safe '(66 3 nil nil nil))))))         ; automatic open: safe values, no prompt

(ert-deftest drgnx-settings-compat/c24-a-clone-under-a-location ()
  (let* ((dl "((nil . ((fill-column . 66)\n         (drgnx-c24-data . \"data\")\n         (drgnx-c24-risky-function . %s)\n         (eval . (setq drgnx-c24-ran (1+ drgnx-c24-ran))))))\n")
         (root "~/workspace/clone/")
         (r (drgnx-settings-test-child
             (list '(require 'cl-lib)
                   '(defvar drgnx-c24-data nil)
                   '(defvar drgnx-c24-risky-function nil)
                   '(defvar drgnx-c24-ran 0)
                   '(defvar drgnx-compat-asked nil)
                   '(setq-default drgnx-trust-parents '(("~/workspace/")))
                   ;; data applies; the code waits, with no prompt
                   (drgnx-settings-compat-trust--open
                    (concat root "a.txt")
                    `(list drgnx-c24-data (local-variable-p 'drgnx-c24-risky-function) drgnx-c24-ran drgnx-compat-asked
                           (mapcar (lambda (i) (plist-get i :var)) (drgnx-settings-trust-waiting ,root))
                           (drgnx-settings-test-check-row 'fill-column :value 66
                                                          :source "Directory-local (~/workspace/clone/.dir-locals.el:1)")))
                   ;; after Allow it applies, at once
                   (drgnx-settings-compat-trust--open
                    (concat root "a.txt")
                    `(progn (drgnx-settings-trust-allow ,root (drgnx-settings-trust-waiting ,root))
                            (list drgnx-c24-risky-function drgnx-c24-ran drgnx-compat-asked)))
                   ;; a pull changes the risky value: it waits again; the unchanged eval keeps applying
                   `(progn (with-temp-file (expand-file-name ".dir-locals.el" ,root) (insert (format ,dl "identity")))
                           (setq dir-locals-directory-cache nil)
                           (kill-buffer (get-file-buffer (expand-file-name "a.txt" ,root)))
                           t)
                   (drgnx-settings-compat-trust--open
                    (concat root "a.txt")
                    `(list (local-variable-p 'drgnx-c24-risky-function) drgnx-c24-ran drgnx-compat-asked
                           (mapcar (lambda (i) (list (plist-get i :var) (plist-get i :value) (plist-get i :was)))
                                   (drgnx-settings-trust-waiting ,root))))
                   ;; nothing in custom.el or Emacs's own trust stores
                   '(list (file-exists-p (expand-file-name "custom.el" (drgnx-user-dir)))
                          (and custom-file (file-exists-p custom-file))
                          safe-local-variable-values safe-local-variable-directories))
             :files (list (cons (concat root "a.txt") "hi\n")
                          (cons (concat root ".git/HEAD") "ref: refs/heads/main\n")
                          (cons (concat root ".dir-locals.el") (format dl "ignore"))))))
    (should-not (plist-get r :error))
    (let ((v (plist-get r :values)))
      (should (equal (nth 6 v) '("data" nil 0 nil (drgnx-c24-risky-function eval) t)))
      (should (equal (nth 7 v) '(ignore 1 nil)))
      (should (equal (nth 9 v) '(nil 2 nil ((drgnx-c24-risky-function identity ignore)))))
      (should (equal (nth 10 v) '(nil nil nil nil))))))

(provide 'settings-compat-trust-test)
;;; settings-compat-trust-test.el ends here
