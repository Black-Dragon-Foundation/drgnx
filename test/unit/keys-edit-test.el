;;; keys-edit-test.el --- batch tests: writing keys.eld (bind, unbind, reset, undo) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-keys-edit)

(defmacro drgnx-keys-edit-test--with-dir (&rest body)
  "BODY with DRGNX_CONFIG_DIR a temp dir (never the user's), no applied keys, and `drgnx-keys-apply' counted
in `applied'."
  `(let* ((dir (make-temp-file "drgnx-keys-edit" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" dir) process-environment))
          (drgnx-keys-last (list :bindings nil)) (drgnx-keys-problems nil) (drgnx-keys-edit--undo nil) (applied 0))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-keys-apply) (lambda () (cl-incf applied) drgnx-keys-last)))
           (ignore applied)
           ,@body)
       (delete-directory dir t))))

(defun drgnx-keys-edit-test--put (text)
  (write-region text nil (drgnx-keys-file) nil 'silent))

(defun drgnx-keys-edit-test--text ()
  (when (file-exists-p (drgnx-keys-file))
    (with-temp-buffer (insert-file-contents (drgnx-keys-file)) (buffer-string))))

(defconst drgnx-keys-edit-test--sample
  ";; my keys, hand written\n(:layers ((emacs editing) (vscode app window)) ; the stack\n :bind ((palette \"C-c p\") ; mine\n        ;; a note about line numbers\n        (line-numbers \"C-c l\" \"<f9>\"))\n :unbind (keys-sheet\n          ;; no key for this\n          other))\n")

(ert-deftest drgnx-keys-edit/bind-keeps-comments-and-layers ()
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put drgnx-keys-edit-test--sample)
   (should (drgnx-keys-edit-bind 'open-file '("C-c f") '(org . org-mode-map)))
   (drgnx-keys-edit-bind 'line-numbers "C-c n")        ; a string is one key; the old entry is replaced
   (drgnx-keys-edit-bind 'keys-sheet '("C-c k"))        ; binding an unbound id drops it from :unbind
   (let ((text (drgnx-keys-edit-test--text)) (user (drgnx-keys-read-user)))
     (dolist (c '(";; my keys, hand written" "; the stack" "; mine" ";; a note about line numbers"
                  ";; no key for this"))
       (should (string-search c text)))
     (should (equal (plist-get user :layers) '((emacs editing) (vscode app window))))
     (should (equal (plist-get user :bind)
                    '((palette "C-c p") (line-numbers "C-c n") (open-file "C-c f" :map (org . org-mode-map))
                      (keys-sheet "C-c k"))))
     (should (equal (plist-get user :unbind) '(other))))
   (should (= applied 3))))

(ert-deftest drgnx-keys-edit/unbind-then-reset ()
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put drgnx-keys-edit-test--sample)
   ;; line-numbers has two keys in the user's entry; the profile's keys come from the last resolution
   (setq drgnx-keys-last '(:bindings ((:id palette :key "C-c p" :map nil) (:id line-numbers :key "C-c l" :map nil)
                                      (:id line-numbers :key "<f9>" :map nil)
                                      (:id save :key "C-s" :map nil) (:id save :key "C-x C-s" :map nil))))
   (drgnx-keys-edit-unbind 'line-numbers "<f9>")
   (should (equal (alist-get 'line-numbers (plist-get (drgnx-keys-read-user) :bind)) '("C-c l")))
   (drgnx-keys-edit-unbind 'line-numbers "C-c l")
   (let ((user (drgnx-keys-read-user)))
     (should-not (assq 'line-numbers (plist-get user :bind)))
     (should (equal (plist-get user :unbind) '(keys-sheet other line-numbers))))
   ;; a profile key: the rest is written as the command's own keys
   (drgnx-keys-edit-unbind 'save "C-s")
   (should (equal (alist-get 'save (plist-get (drgnx-keys-read-user) :bind)) '("C-x C-s")))
   (drgnx-keys-edit-unbind 'save "C-x C-s")
   (should (memq 'save (plist-get (drgnx-keys-read-user) :unbind)))
   ;; a key the command does not have: nothing is written
   (let ((before (drgnx-keys-edit-test--text)))
     (should-not (drgnx-keys-edit-unbind 'palette "C-c z"))
     (should (equal before (drgnx-keys-edit-test--text))))
   (drgnx-keys-edit-reset 'line-numbers)
   (should-not (memq 'line-numbers (plist-get (drgnx-keys-read-user) :unbind)))
   (should (assq 'palette (plist-get (drgnx-keys-read-user) :bind)))
   (drgnx-keys-edit-reset-all)
   (let ((user (drgnx-keys-read-user)) (text (drgnx-keys-edit-test--text)))
     (should-not (plist-get user :bind))
     (should-not (plist-get user :unbind))
     (should (equal (plist-get user :layers) '((emacs editing) (vscode app window))))
     (dolist (c '(";; my keys, hand written" "; the stack"))
       (should (string-search c text))))))

(ert-deftest drgnx-keys-edit/broken-file-never-written ()
  (drgnx-keys-edit-test--with-dir
   (dolist (broken '("(:bind ((palette \"C-c p\")"          ; a missing parenthesis
                     "(1 2 3)"                              ; not a plist
                     "(:bind palette)"                      ; :bind is not a list
                     "(:unbind (a . b))"                    ; :unbind is not a proper list
                     "nonsense"))
     (drgnx-keys-edit-test--put broken)
     (dolist (op (list (lambda () (drgnx-keys-edit-bind 'palette "C-c p"))
                       (lambda () (drgnx-keys-edit-unbind 'palette "C-c p"))
                       (lambda () (drgnx-keys-edit-reset 'palette))
                       #'drgnx-keys-edit-reset-all))
       (let ((err (should-error (funcall op) :type 'user-error)))
         (should (string-search "keys.eld" (cadr err)))))
     (should (equal (drgnx-keys-edit-test--text) broken))
     (should-not (file-exists-p (concat (drgnx-keys-file) ".undo")))
     (should-not (directory-files (drgnx-user-dir) nil "\\`\\.keys-")))   ; no stray temp file either
   (should (= applied 0))))

(ert-deftest drgnx-keys-edit/undo-restores ()
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put drgnx-keys-edit-test--sample)
   (drgnx-keys-edit-bind 'open-file "C-c f")
   (drgnx-keys-edit-bind 'palette "C-c q")
   ;; one step: back to before the second change, not the first
   (drgnx-keys-edit-undo)
   (should (equal (alist-get 'palette (plist-get (drgnx-keys-read-user) :bind)) '("C-c p")))
   (should (alist-get 'open-file (plist-get (drgnx-keys-read-user) :bind)))
   (should-error (drgnx-keys-edit-undo) :type 'user-error)   ; nothing more to undo
   ;; a file that did not exist is removed again
   (delete-file (drgnx-keys-file))
   (setq drgnx-keys-edit--undo nil)
   (drgnx-keys-edit-bind 'palette "C-c p")
   (should (file-exists-p (drgnx-keys-file)))
   (drgnx-keys-edit-undo)
   (should-not (file-exists-p (drgnx-keys-file)))
   (should (= applied 5))))

(ert-deftest drgnx-keys-edit/missing-file-is-created-with-a-header ()
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-reset-all)                              ; nothing to change: nothing created
   (should-not (file-exists-p (drgnx-keys-file)))
   (drgnx-keys-edit-bind 'palette '("C-c p" "<f1>"))
   (let ((text (drgnx-keys-edit-test--text)))
     (should (string-prefix-p ";; drgnx keys" text))
     (should (equal (drgnx-keys-read-user) '(:bind ((palette "C-c p" "<f1>"))))))
   ;; a file holding only comments works the same
   (drgnx-keys-edit-test--put ";; just a note\n")
   (drgnx-keys-edit-bind 'palette "C-c p")
   (should (string-prefix-p ";; just a note" (drgnx-keys-edit-test--text)))
   (should (equal (plist-get (drgnx-keys-read-user) :bind) '((palette "C-c p"))))))

(ert-deftest drgnx-keys-edit/invalid-input-is-refused ()
  (drgnx-keys-edit-test--with-dir
   (should-error (drgnx-keys-edit-bind 'palette "not a key (") :type 'user-error)
   (should-error (drgnx-keys-edit-bind 'palette nil) :type 'user-error)
   (should-error (drgnx-keys-edit-bind "palette" "C-c p") :type 'user-error)
   (should-not (file-exists-p (drgnx-keys-file)))))

(ert-deftest drgnx-keys-edit/keeps-entries-comment-lines-when-removing ()
  ;; removing an entry takes its line and trailing comment, not its neighbours'
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put
    "(:bind ((a \"C-c a\") ; first\n ;; keep me\n (b \"C-c b\") ; second\n (c \"C-c c\")))\n")
   (drgnx-keys-edit-reset 'b)
   (should (equal (drgnx-keys-edit-test--text) "(:bind ((a \"C-c a\") ; first\n ;; keep me\n (c \"C-c c\")))\n"))
   (drgnx-keys-edit-reset 'a)
   (should (equal (plist-get (drgnx-keys-read-user) :bind) '((c "C-c c"))))
   (should (string-search ";; keep me" (drgnx-keys-edit-test--text)))))

(provide 'keys-edit-test)
;;; keys-edit-test.el ends here
