;;; settings-editors-test.el --- the Settings page's editors and their validation -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One editor per type, bounds, the widget pane, the Lisp editor, code never in Shared, a secret refused, and the
;; Lisp twin of the shared secret table.  Writes run in a child Emacs under a temp HOME (test/settings-child.el).

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'drgnx-paths)
(require 'drgnx-secrets)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(defconst drgnx-settings-editors-test--decls
  '((require 'drgnx-settings-page)
    (require 'drgnx-settings-editors)
    (defgroup sat-ed nil "Test group." :group 'tools)
    (drgnx-defsetting sat-ed-bool nil "A flag." :type 'boolean :group 'sat-ed :scope 'global)
    (drgnx-defsetting sat-ed-num 5 "A number." :type '(integer :min 1 :max 10) :group 'sat-ed :scope 'global)
    (drgnx-defsetting sat-ed-str "a" "Text." :type 'string :group 'sat-ed :scope 'global)
    (drgnx-defsetting sat-ed-file "/x" "A file." :type 'file :group 'sat-ed :scope 'global)
    (drgnx-defsetting sat-ed-dir "/x" "A dir." :type 'directory :group 'sat-ed :scope 'global)
    (drgnx-defsetting sat-ed-choice 'a "A choice." :type '(choice (const a) (const b)) :group 'sat-ed :scope 'global)
    (drgnx-defsetting sat-ed-sym 'a "A symbol." :type 'symbol :group 'sat-ed :scope 'global)
    (drgnx-defsetting sat-ed-keys [1] "Keys." :type 'key-sequence :group 'sat-ed :scope 'global)
    (drgnx-defsetting sat-ed-rep nil "A list." :type '(repeat string) :group 'sat-ed :scope 'global)
    (drgnx-defsetting sat-ed-any nil "Anything." :type 'sexp :group 'sat-ed :scope 'global)
    (drgnx-defsetting sat-ed-hook nil "Code." :type 'function :group 'sat-ed :workspace 'code)
    (drgnx-defsetting sat-ed-text "x" "Text 2." :type 'string :group 'sat-ed :scope 'global))
  "Forms that declare the settings the tests use.")

(defun drgnx-settings-editors-test--run (forms &optional files)
  "Run FORMS in a child after the declarations; the value of the last."
  (let ((r (drgnx-settings-test-child (append drgnx-settings-editors-test--decls forms) :files files)))
    (unless (and (null (plist-get r :error)) (equal (plist-get r :exit) 0))
      (ert-fail (list :error (plist-get r :error) :output (plist-get r :output))))
    (car (last (plist-get r :values)))))

(ert-deftest drgnx-settings-editors/one-editor-per-type ()
  (should (equal (drgnx-settings-editors-test--run
                  '((mapcar #'drgnx-settings-editors-kind
                            '(sat-ed-bool sat-ed-num sat-ed-str sat-ed-file sat-ed-dir sat-ed-choice sat-ed-sym
                                          sat-ed-keys sat-ed-rep sat-ed-any))))
                 '(toggle number text file directory choice completion shortcuts widget lisp))))

(ert-deftest drgnx-settings-editors/bounds-refuse ()
  (let ((r (drgnx-settings-editors-test--run
            '((list (drgnx-settings-editors-bounds 'sat-ed-num)
                    (car (drgnx-settings-editors-check 'sat-ed-num 0 'user))
                    (cdr (drgnx-settings-editors-check 'sat-ed-num 11 'user))
                    (drgnx-settings-editors-check 'sat-ed-num 3 'user)
                    (condition-case e (drgnx-settings-editors-commit 'sat-ed-num 11 'user nil)
                      (user-error (cadr e))))))))
    (should (equal (nth 0 r) '(1 . 10)))
    (should (string-match-p "highest" (nth 2 r)))
    (should-not (nth 3 r))
    (should (string-match-p "sat-ed-num" (nth 4 r)))))

(ert-deftest drgnx-settings-editors/a-widget-pane-for-repeat ()
  (let ((r (drgnx-settings-editors-test--run
            '((with-current-buffer (drgnx-settings-editors-widget-pane 'sat-ed-rep 'user nil '("p" "q"))
                (list (buffer-name) (and (string-match-p "Apply" (buffer-string)) t)
                      (widget-value (nth 3 drgnx-settings-editors--pane))))))))
    (should (equal r '("*Setting: sat-ed-rep*" t ("p" "q"))))))

(ert-deftest drgnx-settings-editors/lisp-editor-uses-the-data-reader ()
  (let ((r (drgnx-settings-editors-test--run
            '((list (drgnx-settings-editors-read-lisp "'(1 \"two\" three)")
                    (condition-case nil (drgnx-settings-editors-read-lisp "#.(+ 1 2)") (user-error 'refused))
                    (condition-case nil (drgnx-settings-editors-read-lisp "(1 2") (user-error 'refused))
                    (progn (drgnx-settings-editors-commit 'sat-ed-any 'user nil '(1 two))
                           (with-temp-buffer (insert-file-contents (drgnx-config-file 'settings))
                                             (and (string-match-p "sat-ed-any" (buffer-string)) t))))))))
    (should (equal r '((1 "two" three) refused refused t)))))

(ert-deftest drgnx-settings-editors/code-never-to-shared ()
  (let ((r (drgnx-settings-editors-test--run
            '((list (and (plist-get (drgnx-settings-page-row 'sat-ed-hook 'user nil) :code) t)
                    (cdr (drgnx-settings-editors-check 'sat-ed-hook 'ignore 'shared))
                    (drgnx-settings-editors-check 'sat-ed-hook 'ignore 'user)
                    (drgnx-settings-editors-check 'sat-ed-hook 'ignore 'workspace))))))
    (should (nth 0 r))
    (should (string-match-p "never in Shared" (nth 1 r)))
    (should-not (nth 2 r))
    (should-not (nth 3 r))))

(ert-deftest drgnx-settings-editors/a-secret-is-refused ()
  (let ((r (drgnx-settings-editors-test--run
            `((let ((key (concat "sk-or-" "v1-0a1b2c3d4e5f60718293a4b5c6d7e8f9")))
                (list (cdr (drgnx-settings-editors-check 'sat-ed-str key 'user))
                      (condition-case e (drgnx-settings-editors-commit 'sat-ed-str 'user nil key)
                        (user-error (cadr e)))
                      (file-exists-p (drgnx-config-file 'settings))
                      (drgnx-settings-editors-check 'sat-ed-str "plain" 'user)))))))
    (should (string-match-p "use your keyring" (nth 0 r)))
    (should (string-match-p "keyring" (nth 1 r)))
    (should-not (nth 2 r))
    (should-not (nth 3 r))))

(ert-deftest drgnx-secrets/every-case-in-the-shared-table ()
  (let* ((json-object-type 'alist) (json-array-type 'list)
         (file (expand-file-name "test/fixtures/secret-cases.json" drgnx-dir))
         (cases (alist-get 'cases (json-read-file file)))
         wrong)
    (dolist (c cases)
      (let* ((text (alist-get 'text c))
             (text (if (listp text) (apply #'concat text) text))
             (want (alist-get 'rule c))
             (got (drgnx-secrets-looks-like text)))
        (unless (equal got (and (stringp want) want))
          (push (format "%s: want %S, got %S" (alist-get 'name c) want got) wrong))))
    (should (> (length cases) 30))
    (should-not wrong)))

(provide 'settings-editors-test)
;;; settings-editors-test.el ends here
