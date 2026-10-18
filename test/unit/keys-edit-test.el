;;; keys-edit-test.el --- batch tests: writing keys.eld (bind, unbind, reset, undo) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-keys-edit)

(defmacro drgnx-keys-edit-test--with-dir (&rest body)
  "BODY with DRGNX_CONFIG_DIR a temp dir (never the user's), no applied keys, and `drgnx-keys-apply' counted
in `applied'."
  `(let* ((dir (make-temp-file "drgnx-keys-edit" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" dir) process-environment))
          (drgnx-keys-last (list :bindings nil)) (drgnx-keys-problems nil) (applied 0))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-keys-apply) (lambda () (cl-incf applied) drgnx-keys-last))
                   ((symbol-function 'drgnx-surfaces-refresh) #'ignore))
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

(defun drgnx-keys-edit-test--bindings (&rest triples)
  "A `drgnx-keys-last' with bindings from (ID KEY MAP) triples."
  (list :bindings (mapcar (lambda (tr) (list :id (nth 0 tr) :key (nth 1 tr) :map (nth 2 tr))) triples)))

;;;; Fix round 1

(ert-deftest drgnx-keys-edit/undo-refused-after-a-later-change ()
  ;; something else (the profile switch, a hand edit, another session) wrote keys.eld since: undo must not erase it
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put drgnx-keys-edit-test--sample)
   (drgnx-keys-edit-bind 'open-file "C-c f")
   (let ((later (concat (drgnx-keys-edit-test--text) ";; edited by hand\n")))
     (drgnx-keys-edit-test--put later)
     (let ((err (should-error (drgnx-keys-edit-undo) :type 'user-error)))
       (should (string-search "changed" (cadr err))))
     (should (equal (drgnx-keys-edit-test--text) later)))
   ;; a file this writer created, then changed by someone else, is not deleted either
   (delete-file (drgnx-keys-file))
   (drgnx-keys-edit-bind 'palette "C-c p")
   (drgnx-keys-edit-test--put (concat (drgnx-keys-edit-test--text) ";; mine\n"))
   (should-error (drgnx-keys-edit-undo) :type 'user-error)
   (should (file-exists-p (drgnx-keys-file)))))

(ert-deftest drgnx-keys-edit/undo-copy-survives-a-restart ()
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put drgnx-keys-edit-test--sample)
   (drgnx-keys-edit-bind 'open-file "C-c f")
   (let ((saved (with-temp-buffer (insert-file-contents (concat (drgnx-keys-file) ".undo")) (read (current-buffer)))))
     (should (equal (plist-get saved :old) drgnx-keys-edit-test--sample))
     (should (equal (plist-get saved :new) (drgnx-keys-edit-test--text))))
   ;; the state is in that file only: a new session (nothing in memory) undoes from it
   (drgnx-keys-edit-undo)
   (should (equal (drgnx-keys-edit-test--text) drgnx-keys-edit-test--sample))
   (should-not (file-exists-p (concat (drgnx-keys-file) ".undo")))
   ;; an unreadable undo copy is not trusted
   (write-region "(:old" nil (concat (drgnx-keys-file) ".undo") nil 'silent)
   (should-error (drgnx-keys-edit-undo) :type 'user-error)))

(ert-deftest drgnx-keys-edit/rewriting-keeps-mac-keys-and-none-reasons ()
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put
    "(:bind ((palette \"C-c p\" \"C-c q\" :mac \"s-p\")\n (quit :none \"only on a Mac\" :mac \"s-q\")))\n")
   (drgnx-keys-edit-unbind 'palette "C-c q")
   (should (equal (alist-get 'palette (plist-get (drgnx-keys-read-user) :bind)) '("C-c p" :mac "s-p")))
   (drgnx-keys-edit-bind 'palette "C-c z")
   (should (equal (alist-get 'palette (plist-get (drgnx-keys-read-user) :bind)) '("C-c z" :mac "s-p")))
   ;; a key given to a :none entry drops the :none and keeps :mac; the reason is kept while it has no keys
   (drgnx-keys-edit-add 'quit "s-w")
   (should (equal (alist-get 'quit (plist-get (drgnx-keys-read-user) :bind)) '("s-w" :mac "s-q")))
   (drgnx-keys-edit-test--put "(:bind ((quit :none \"only on a Mac\" :mac (\"s-q\" \"s-w\"))))\n")
   (drgnx-keys-edit-unbind 'quit "s-w")
   (should (equal (alist-get 'quit (plist-get (drgnx-keys-read-user) :bind)) '(:none "only on a Mac" :mac "s-q")))
   (drgnx-keys-edit-unbind 'quit "s-q")
   (should (memq 'quit (plist-get (drgnx-keys-read-user) :unbind)))
   (drgnx-keys-edit-test--put
    "(:bind ((palette \"C-c p\" \"C-c q\" :mac \"s-p\")))\n")
   ;; no keys left anywhere: not bound at all
   (drgnx-keys-edit-unbind 'palette "C-c p")
   (drgnx-keys-edit-unbind 'palette "C-c q")
   (drgnx-keys-edit-unbind 'palette "s-p")
   (should-not (assq 'palette (plist-get (drgnx-keys-read-user) :bind)))
   (should (memq 'palette (plist-get (drgnx-keys-read-user) :unbind)))))

(ert-deftest drgnx-keys-edit/on-a-mac-edits-go-to-the-mac-keys ()
  (drgnx-keys-edit-test--with-dir
   (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos)))
     (drgnx-keys-edit-test--put "(:bind ((palette \"C-c p\" :mac \"s-p\")))\n")
     (drgnx-keys-edit-add 'palette "s-o")
     (should (equal (alist-get 'palette (plist-get (drgnx-keys-read-user) :bind)) '("C-c p" :mac ("s-p" "s-o"))))
     (drgnx-keys-edit-bind 'palette "s-k")
     (should (equal (alist-get 'palette (plist-get (drgnx-keys-read-user) :bind)) '("C-c p" :mac "s-k")))
     (should (drgnx-keys-edit-unbind 'palette "s-k"))   ; the key the editor shows
     (should (equal (alist-get 'palette (plist-get (drgnx-keys-read-user) :bind)) '("C-c p" :mac ()))))))

(ert-deftest drgnx-keys-edit/unbind-with-the-resolved-map ()
  ;; the entry has no :map, the command resolves to one (its own or its profile's): the editor row carries that map
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put "(:bind ((foo \"C-c f\" \"C-c g\")))\n")
   (setq drgnx-keys-last (drgnx-keys-edit-test--bindings '(foo "C-c f" (org . org-mode-map))
                                                         '(foo "C-c g" (org . org-mode-map))))
   (should-not (drgnx-keys-edit-unbind 'foo "C-c f" 'other-map))   ; another place: not this key
   (should (drgnx-keys-edit-unbind 'foo "C-c f" '(org . org-mode-map)))
   (should (equal (alist-get 'foo (plist-get (drgnx-keys-read-user) :bind)) '("C-c g")))))

(ert-deftest drgnx-keys-edit/a-symlinked-keys-eld-stays-a-symlink ()
  (drgnx-keys-edit-test--with-dir
   (let ((real (expand-file-name "real.eld" dir)))
     (write-region drgnx-keys-edit-test--sample nil real nil 'silent)
     (make-symbolic-link real (drgnx-keys-file))
     (drgnx-keys-edit-bind 'open-file "C-c f")
     (should (file-symlink-p (drgnx-keys-file)))
     (should (string-search "open-file" (with-temp-buffer (insert-file-contents real) (buffer-string))))
     (drgnx-keys-edit-undo)
     (should (file-symlink-p (drgnx-keys-file)))
     (should (equal (with-temp-buffer (insert-file-contents real) (buffer-string)) drgnx-keys-edit-test--sample)))))

(ert-deftest drgnx-keys-edit/replace-and-add-are-one-write-and-one-undo-step ()
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put drgnx-keys-edit-test--sample)
   ;; add keeps the keys it has, including those only the last resolution knows
   (setq drgnx-keys-last (drgnx-keys-edit-test--bindings '(save "C-s" nil)))
   (should (drgnx-keys-edit-add 'save "C-x C-s"))
   (should (equal (alist-get 'save (plist-get (drgnx-keys-read-user) :bind)) '("C-s" "C-x C-s")))
   (should-not (drgnx-keys-edit-add 'save "C-s"))         ; already there: no write
   (let ((n applied))
     (should (drgnx-keys-edit-replace 'save "C-s" "C-c s"))
     (should (= applied (1+ n))))
   (should (equal (alist-get 'save (plist-get (drgnx-keys-read-user) :bind)) '("C-c s" "C-x C-s")))
   (should-not (drgnx-keys-edit-replace 'save "C-z" "C-c z"))   ; it does not have that key
   (drgnx-keys-edit-undo)                                   ; the one step
   (should (equal (alist-get 'save (plist-get (drgnx-keys-read-user) :bind)) '("C-s" "C-x C-s")))
   ;; the same validation as bind
   (should-error (drgnx-keys-edit-replace 'save "C-s" "not a key (") :type 'user-error)
   (should-error (drgnx-keys-edit-add 'save "not a key (") :type 'user-error)
   ;; and the same refusal of a file that does not read
   (drgnx-keys-edit-test--put "(:bind")
   (should-error (drgnx-keys-edit-add 'save "C-c s") :type 'user-error)
   (should-error (drgnx-keys-edit-replace 'save "C-s" "C-c s") :type 'user-error)
   (should (equal (drgnx-keys-edit-test--text) "(:bind"))))

(ert-deftest drgnx-keys-edit/adding-unbind-to-a-file-without-one-leaves-no-blank-line ()
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put "(:layers ((emacs editing))\n :bind ((a \"C-c a\"))\n)\n")
   (drgnx-keys-edit-unbind 'a "C-c a")
   (should (equal (drgnx-keys-edit-test--text) "(:layers ((emacs editing))\n :bind ()\n :unbind (a)\n)\n"))))

(ert-deftest drgnx-keys-edit/one-step-is-one-undo ()
  (drgnx-keys-edit-test--with-dir
   ;; no keys.eld: two writes in one step, one undo and there is none again
   (drgnx-keys-edit-one-step
     (drgnx-keys-edit-bind 'palette "C-c p")
     (drgnx-keys-edit-bind 'save "C-c s"))
   (should (equal (plist-get (drgnx-keys-read-user) :bind) '((palette "C-c p") (save "C-c s"))))
   (drgnx-keys-edit-undo)
   (should-not (file-exists-p (drgnx-keys-file)))
   ;; a step inside a step: undo goes back to where the outer one started
   (drgnx-keys-edit-test--put drgnx-keys-edit-test--sample)
   (drgnx-keys-edit-one-step
     (drgnx-keys-edit-one-step (drgnx-keys-edit-bind 'open-file "C-c f"))
     (drgnx-keys-edit-bind 'save "C-c s")
     (drgnx-keys-edit-one-step (drgnx-keys-edit-bind 'palette "C-c q")))
   (drgnx-keys-edit-undo)
   (should (equal (drgnx-keys-edit-test--text) drgnx-keys-edit-test--sample))
   ;; an error inside a step: keys.eld still reads, and undo takes back what the step wrote
   (delete-file (drgnx-keys-file))
   (should-error (drgnx-keys-edit-one-step
                   (drgnx-keys-edit-bind 'save "C-c s")
                   (drgnx-keys-edit-bind 'open-file "not a key ("))
                 :type 'user-error)
   (should (equal (plist-get (drgnx-keys-read-user) :bind) '((save "C-c s"))))
   (should (equal (plist-get (car (read-from-string (drgnx-keys-edit--read (drgnx-keys-edit--undo-file)))) :old)
                  :absent))
   (drgnx-keys-edit-undo)
   (should-not (file-exists-p (drgnx-keys-file)))))

(provide 'keys-edit-test)
;;; keys-edit-test.el ends here
