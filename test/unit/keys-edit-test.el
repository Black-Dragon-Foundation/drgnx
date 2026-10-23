;;; keys-edit-test.el --- batch tests: writing the keys settings (bind, unbind, reset, undo) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/areas-fixture" drgnx-dir) nil t)
(require 'drgnx-keys-edit)

(defmacro drgnx-keys-edit-test--with-dir (&rest body)
  "BODY under a temp config (`drgnx-test-with-areas'), no applied keys, and `drgnx-keys-apply' counted in `applied'."
  `(drgnx-test-with-areas
     (let ((drgnx-keys-last (list :bindings nil)) (drgnx-keys-problems nil) (applied 0))
       (cl-letf (((symbol-function 'drgnx-keys-apply) (lambda () (cl-incf applied) drgnx-keys-last))
                 ((symbol-function 'drgnx-surfaces-refresh) #'ignore))
         (ignore applied)
         ,@body))))

(defun drgnx-keys-edit-test--put (text) (drgnx-test-areas-put text))
(defun drgnx-keys-edit-test--text () (drgnx-test-areas-text))

(defun drgnx-keys-edit-test--user ()
  "The three lists the editor writes, and the stack, as settings.el holds them now (a plist like `drgnx-keys-read-user')."
  (let ((v (drgnx-settings-area-fresh '(drgnx-keys-layers drgnx-keys-bind drgnx-keys-unbind drgnx-keys-tty-fallback))))
    (list :layers (cdr (assq 'drgnx-keys-layers v)) :bind (cdr (assq 'drgnx-keys-bind v))
          :unbind (cdr (assq 'drgnx-keys-unbind v)) :tty-fallback (cdr (assq 'drgnx-keys-tty-fallback v)))))

(defun drgnx-keys-edit-test--put-bind (bind)
  "settings.el holds BIND (a value of `drgnx-keys-bind') and nothing else."
  (drgnx-test-areas-put-entries (list (cons 'drgnx-keys-bind bind))))

(defconst drgnx-keys-edit-test--sample
  ";; my settings, hand written\n(drgnx-settings\n :version 1\n ;; a note about bindings\n (drgnx-keys-bind ((palette \"C-c p\") (line-numbers \"C-c l\" \"<f9>\")))\n (drgnx-keys-layers ((emacs editing) (vscode app window))) ; the stack\n ;; no key for these\n (drgnx-keys-unbind (keys-sheet other)))\n")

(ert-deftest drgnx-keys-edit/bind-keeps-comments-and-layers ()
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put drgnx-keys-edit-test--sample)
   (should (drgnx-keys-edit-bind 'open-file '("C-c f") '(org . org-mode-map)))
   (drgnx-keys-edit-bind 'line-numbers "C-c n")        ; a string is one key; the old entry is replaced
   (drgnx-keys-edit-bind 'keys-sheet '("C-c k"))        ; binding an unbound id drops it from the unbind list
   (let ((text (drgnx-keys-edit-test--text)) (user (drgnx-keys-edit-test--user)))
     (dolist (c '(";; my settings, hand written" "; the stack" ";; a note about bindings" ";; no key for these"))
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
   (should (equal (alist-get 'line-numbers (plist-get (drgnx-keys-edit-test--user) :bind)) '("C-c l")))
   (drgnx-keys-edit-unbind 'line-numbers "C-c l")
   (let ((user (drgnx-keys-edit-test--user)))
     (should-not (assq 'line-numbers (plist-get user :bind)))
     (should (equal (plist-get user :unbind) '(keys-sheet other line-numbers))))
   ;; a profile key: the rest is written as the command's own keys
   (drgnx-keys-edit-unbind 'save "C-s")
   (should (equal (alist-get 'save (plist-get (drgnx-keys-edit-test--user) :bind)) '("C-x C-s")))
   (drgnx-keys-edit-unbind 'save "C-x C-s")
   (should (memq 'save (plist-get (drgnx-keys-edit-test--user) :unbind)))
   ;; a key the command does not have: nothing is written
   (let ((before (drgnx-keys-edit-test--text)))
     (should-not (drgnx-keys-edit-unbind 'palette "C-c z"))
     (should (equal before (drgnx-keys-edit-test--text))))
   (drgnx-keys-edit-reset 'line-numbers)
   (should-not (memq 'line-numbers (plist-get (drgnx-keys-edit-test--user) :unbind)))
   (should (assq 'palette (plist-get (drgnx-keys-edit-test--user) :bind)))
   (drgnx-keys-edit-reset-all)
   (let ((user (drgnx-keys-edit-test--user)) (text (drgnx-keys-edit-test--text)))
     (should-not (plist-get user :bind))
     (should-not (plist-get user :unbind))
     (should (equal (plist-get user :layers) '((emacs editing) (vscode app window))))
     (dolist (c '(";; my settings, hand written" "; the stack"))
       (should (string-search c text))))))

(ert-deftest drgnx-keys-edit/broken-file-never-written ()
  (drgnx-keys-edit-test--with-dir
   (dolist (broken '("(drgnx-settings :version 1 (drgnx-keys-bind ((palette \"C-c p\")))"   ; a missing parenthesis
                     "(1 2 3)"                                                          ; not a settings form
                     "nonsense"
                     "(drgnx-settings :version 99 (drgnx-keys-unbind (a)))\n"))        ; written by a newer drgnx
     (drgnx-keys-edit-test--put broken)
     (dolist (op (list (lambda () (drgnx-keys-edit-bind 'palette "C-c p"))
                       (lambda () (drgnx-keys-edit-unbind 'palette "C-c p"))
                       (lambda () (drgnx-keys-edit-reset 'palette))
                       #'drgnx-keys-edit-reset-all))
       (let ((err (should-error (funcall op) :type 'user-error)))
         (should (string-search "settings.el" (cadr err)))))
     (should (equal (drgnx-keys-edit-test--text) broken))
     (should-not (file-exists-p (drgnx-keys-edit--undo-file))))
   (should (= applied 0))))

(ert-deftest drgnx-keys-edit/undo-restores ()
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put drgnx-keys-edit-test--sample)
   (drgnx-keys-edit-bind 'open-file "C-c f")
   (drgnx-keys-edit-bind 'palette "C-c q")
   ;; one step: back to before the second change, not the first
   (drgnx-keys-edit-undo)
   (should (equal (alist-get 'palette (plist-get (drgnx-keys-edit-test--user) :bind)) '("C-c p")))
   (should (alist-get 'open-file (plist-get (drgnx-keys-edit-test--user) :bind)))
   (should-error (drgnx-keys-edit-undo) :type 'user-error)   ; nothing more to undo
   ;; a setting that had no entry gets none again
   (drgnx-keys-edit-reset-all)
   (delete-file (drgnx-config-file 'settings))
   (drgnx-keys-edit-bind 'palette "C-c p")
   (should (drgnx-settings-area-has-entry-p 'drgnx-keys-bind))
   (drgnx-keys-edit-undo)
   (should-not (drgnx-settings-area-has-entry-p 'drgnx-keys-bind))
   (should (= applied 6))))

(ert-deftest drgnx-keys-edit/missing-file-is-created-with-a-header ()
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-reset-all)                              ; nothing to change: nothing created
   (should-not (file-exists-p (drgnx-config-file 'settings)))
   (drgnx-keys-edit-bind 'palette '("C-c p" "<f1>"))
   (let ((text (drgnx-keys-edit-test--text)))
     (should (string-prefix-p ";;; settings.el" text))
     (should (equal (plist-get (drgnx-keys-edit-test--user) :bind) '((palette "C-c p" "<f1>")))))
   ;; a file holding only a header and comments works the same
   (drgnx-keys-edit-test--put ";; just a note\n(drgnx-settings :version 1)\n")
   (drgnx-keys-edit-bind 'palette "C-c p")
   (should (string-prefix-p ";; just a note" (drgnx-keys-edit-test--text)))
   (should (equal (plist-get (drgnx-keys-edit-test--user) :bind) '((palette "C-c p"))))))

(ert-deftest drgnx-keys-edit/invalid-input-is-refused ()
  (drgnx-keys-edit-test--with-dir
   (should-error (drgnx-keys-edit-bind 'palette "not a key (") :type 'user-error)
   (should-error (drgnx-keys-edit-bind 'palette nil) :type 'user-error)
   (should-error (drgnx-keys-edit-bind "palette" "C-c p") :type 'user-error)
   (should-not (file-exists-p (drgnx-config-file 'settings)))))

(ert-deftest drgnx-keys-edit/removing-an-entry-keeps-the-others ()
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put-bind '((a "C-c a") (b "C-c b") (c "C-c c")))
   (drgnx-keys-edit-reset 'b)
   (should (equal (plist-get (drgnx-keys-edit-test--user) :bind) '((a "C-c a") (c "C-c c"))))
   (drgnx-keys-edit-reset 'a)
   (should (equal (plist-get (drgnx-keys-edit-test--user) :bind) '((c "C-c c"))))))

(defun drgnx-keys-edit-test--bindings (&rest triples)
  "A `drgnx-keys-last' with bindings from (ID KEY MAP) triples."
  (list :bindings (mapcar (lambda (tr) (list :id (nth 0 tr) :key (nth 1 tr) :map (nth 2 tr))) triples)))

;;;; Fix round 1

(ert-deftest drgnx-keys-edit/undo-refused-after-a-later-change ()
  ;; something else (the profile switch, a hand edit, another session) changed the setting since: undo must not erase it
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put drgnx-keys-edit-test--sample)
   (drgnx-keys-edit-bind 'open-file "C-c f")
   (drgnx-keys--save-key :bind '((by-hand "C-c h")))
   (let ((later (drgnx-keys-edit-test--text)))
     (let ((err (should-error (drgnx-keys-edit-undo) :type 'user-error)))
       (should (string-search "changed" (cadr err))))
     (should (equal (drgnx-keys-edit-test--text) later)))
   ;; a comment added by hand is not a change of the setting: undo goes on, and only its entry changes
   (delete-file (drgnx-keys-edit--undo-file))
   (drgnx-keys-edit-bind 'palette "C-c p")
   (drgnx-keys-edit-test--put (concat (drgnx-keys-edit-test--text) ";; mine\n"))
   (drgnx-keys-edit-undo)
   (should (string-search ";; mine" (drgnx-keys-edit-test--text)))
   (should (file-exists-p (drgnx-config-file 'settings)))))

(ert-deftest drgnx-keys-edit/undo-copy-survives-a-restart ()
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put drgnx-keys-edit-test--sample)
   (drgnx-keys-edit-bind 'open-file "C-c f")
   (let ((saved (with-temp-buffer (insert-file-contents (drgnx-keys-edit--undo-file)) (read (current-buffer)))))
     (should (equal (plist-get saved :old) '((drgnx-keys-bind ((palette "C-c p") (line-numbers "C-c l" "<f9>"))))))
     (should (equal (cdr (assq 'drgnx-keys-bind (plist-get saved :new)))
                    '((palette "C-c p") (line-numbers "C-c l" "<f9>") (open-file "C-c f")))))
   ;; the state is in that file only: a new session (nothing in memory) undoes from it
   (drgnx-keys-edit-undo)
   (should (equal (drgnx-keys-edit-test--text) drgnx-keys-edit-test--sample))
   (should-not (file-exists-p (drgnx-keys-edit--undo-file)))
   ;; an unreadable undo copy is not trusted
   (write-region "(:old" nil (drgnx-keys-edit--undo-file) nil 'silent)
   (should-error (drgnx-keys-edit-undo) :type 'user-error)))

(ert-deftest drgnx-keys-edit/rewriting-keeps-mac-keys-and-none-reasons ()
  ;; edits on Linux keep the :mac keys as they are (on a Mac they go to the :mac keys: …/on-a-mac-edits-go-to-…)
  (drgnx-keys-edit-test--with-dir
   (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux)))
     (drgnx-keys-edit-test--put-bind '((palette "C-c p" "C-c q" :mac "s-p") (quit :none "only on a Mac" :mac "s-q")))
     (drgnx-keys-edit-unbind 'palette "C-c q")
     (should (equal (alist-get 'palette (plist-get (drgnx-keys-edit-test--user) :bind)) '("C-c p" :mac "s-p")))
     (drgnx-keys-edit-bind 'palette "C-c z")
     (should (equal (alist-get 'palette (plist-get (drgnx-keys-edit-test--user) :bind)) '("C-c z" :mac "s-p")))
     ;; a key given to a :none entry drops the :none and keeps :mac; the reason is kept while it has no keys
     (drgnx-keys-edit-add 'quit "s-w")
     (should (equal (alist-get 'quit (plist-get (drgnx-keys-edit-test--user) :bind)) '("s-w" :mac "s-q")))
     (drgnx-keys-edit-test--put-bind '((quit :none "only on a Mac" :mac ("s-q" "s-w"))))
     (drgnx-keys-edit-unbind 'quit "s-w")
     (should (equal (alist-get 'quit (plist-get (drgnx-keys-edit-test--user) :bind)) '(:none "only on a Mac" :mac "s-q")))
     (drgnx-keys-edit-unbind 'quit "s-q")
     (should (memq 'quit (plist-get (drgnx-keys-edit-test--user) :unbind)))
     (drgnx-keys-edit-test--put-bind '((palette "C-c p" "C-c q" :mac "s-p")))
     ;; no keys left anywhere: not bound at all
     (drgnx-keys-edit-unbind 'palette "C-c p")
     (drgnx-keys-edit-unbind 'palette "C-c q")
     (drgnx-keys-edit-unbind 'palette "s-p")
     (should-not (assq 'palette (plist-get (drgnx-keys-edit-test--user) :bind)))
     (should (memq 'palette (plist-get (drgnx-keys-edit-test--user) :unbind))))))

(ert-deftest drgnx-keys-edit/on-a-mac-edits-go-to-the-mac-keys ()
  (drgnx-keys-edit-test--with-dir
   (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos)))
     (drgnx-keys-edit-test--put-bind '((palette "C-c p" :mac "s-p")))
     (drgnx-keys-edit-add 'palette "s-o")
     (should (equal (alist-get 'palette (plist-get (drgnx-keys-edit-test--user) :bind)) '("C-c p" :mac ("s-p" "s-o"))))
     (drgnx-keys-edit-bind 'palette "s-k")
     (should (equal (alist-get 'palette (plist-get (drgnx-keys-edit-test--user) :bind)) '("C-c p" :mac "s-k")))
     (should (drgnx-keys-edit-unbind 'palette "s-k"))   ; the key the editor shows
     (should (equal (alist-get 'palette (plist-get (drgnx-keys-edit-test--user) :bind)) '("C-c p" :mac ()))))))

(ert-deftest drgnx-keys-edit/unbind-with-the-resolved-map ()
  ;; the entry has no :map, the command resolves to one (its own or its profile's): the editor row carries that map
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put-bind '((foo "C-c f" "C-c g")))
   (setq drgnx-keys-last (drgnx-keys-edit-test--bindings '(foo "C-c f" (org . org-mode-map))
                                                         '(foo "C-c g" (org . org-mode-map))))
   (should-not (drgnx-keys-edit-unbind 'foo "C-c f" 'other-map))   ; another place: not this key
   (should (drgnx-keys-edit-unbind 'foo "C-c f" '(org . org-mode-map)))
   (should (equal (alist-get 'foo (plist-get (drgnx-keys-edit-test--user) :bind)) '("C-c g")))))

(ert-deftest drgnx-keys-edit/replace-and-add-are-one-write-and-one-undo-step ()
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put drgnx-keys-edit-test--sample)
   ;; add keeps the keys it has, including those only the last resolution knows
   (setq drgnx-keys-last (drgnx-keys-edit-test--bindings '(save "C-s" nil)))
   (should (drgnx-keys-edit-add 'save "C-x C-s"))
   (should (equal (alist-get 'save (plist-get (drgnx-keys-edit-test--user) :bind)) '("C-s" "C-x C-s")))
   (should-not (drgnx-keys-edit-add 'save "C-s"))         ; already there: no write
   (let ((n applied))
     (should (drgnx-keys-edit-replace 'save "C-s" "C-c s"))
     (should (= applied (1+ n))))
   (should (equal (alist-get 'save (plist-get (drgnx-keys-edit-test--user) :bind)) '("C-c s" "C-x C-s")))
   (should-not (drgnx-keys-edit-replace 'save "C-z" "C-c z"))   ; it does not have that key
   (drgnx-keys-edit-undo)                                   ; the one step
   (should (equal (alist-get 'save (plist-get (drgnx-keys-edit-test--user) :bind)) '("C-s" "C-x C-s")))
   ;; the same validation as bind
   (should-error (drgnx-keys-edit-replace 'save "C-s" "not a key (") :type 'user-error)
   (should-error (drgnx-keys-edit-add 'save "not a key (") :type 'user-error)
   ;; and the same refusal of a file that does not read
   (drgnx-keys-edit-test--put "(drgnx-settings :version 1 (drgnx-keys-bind")
   (should-error (drgnx-keys-edit-add 'save "C-c s") :type 'user-error)
   (should-error (drgnx-keys-edit-replace 'save "C-s" "C-c s") :type 'user-error)
   (should (equal (drgnx-keys-edit-test--text) "(drgnx-settings :version 1 (drgnx-keys-bind"))))

(ert-deftest drgnx-keys-edit/the-only-key-taken-away-puts-the-command-in-unbind ()
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put-bind '((a "C-c a")))
   (drgnx-keys-edit-unbind 'a "C-c a")
   (let ((user (drgnx-keys-edit-test--user)))
     (should-not (plist-get user :bind))
     (should (equal (plist-get user :unbind) '(a))))))

(ert-deftest drgnx-keys-edit/one-step-is-one-undo ()
  (drgnx-keys-edit-test--with-dir
   ;; no entries: two writes in one step, one undo and there are none again
   (drgnx-keys-edit-one-step
     (drgnx-keys-edit-bind 'palette "C-c p")
     (drgnx-keys-edit-bind 'save "C-c s"))
   (should (equal (plist-get (drgnx-keys-edit-test--user) :bind) '((palette "C-c p") (save "C-c s"))))
   (drgnx-keys-edit-undo)
   (should-not (drgnx-settings-area-has-entry-p 'drgnx-keys-bind))
   ;; a step inside a step: undo goes back to where the outer one started
   (drgnx-keys-edit-test--put drgnx-keys-edit-test--sample)
   (drgnx-keys-edit-one-step
     (drgnx-keys-edit-one-step (drgnx-keys-edit-bind 'open-file "C-c f"))
     (drgnx-keys-edit-bind 'save "C-c s")
     (drgnx-keys-edit-one-step (drgnx-keys-edit-bind 'palette "C-c q")))
   (drgnx-keys-edit-undo)
   (should (equal (drgnx-keys-edit-test--text) drgnx-keys-edit-test--sample))
   ;; an error inside a step: settings.el still reads, and undo takes back what the step wrote
   (delete-file (drgnx-config-file 'settings))
   (drgnx-test-areas-reset)                                  ; and nothing of it is applied any more
   (should-error (drgnx-keys-edit-one-step
                   (drgnx-keys-edit-bind 'save "C-c s")
                   (drgnx-keys-edit-bind 'open-file "not a key ("))
                 :type 'user-error)
   (should (equal (plist-get (drgnx-keys-edit-test--user) :bind) '((save "C-c s"))))
   (should (eq (cdr (assq 'drgnx-keys-bind
                          (plist-get (car (read-from-string (drgnx-keys-edit--read (drgnx-keys-edit--undo-file)))) :old)))
               :absent))
   (drgnx-keys-edit-undo)
   (should-not (drgnx-settings-area-has-entry-p 'drgnx-keys-bind))))

(ert-deftest drgnx-keys-edit/a-bind-list-that-does-not-fit-is-refused-not-rewritten ()
  ;; A list the setting's schema refuses: every writer that would rewrite it refuses, and leaves the bytes alone.
  (drgnx-keys-edit-test--with-dir
   (dolist (text '("(drgnx-settings :version 1 (drgnx-keys-bind ((palette \"C-c p\") not-an-entry)))\n"
                   "(drgnx-settings :version 1 (drgnx-keys-bind foo))\n"
                   "(drgnx-settings :version 1 (drgnx-keys-unbind (palette (nested))))\n"))
     (drgnx-keys-edit-test--put text)
     (dolist (op (list (lambda () (drgnx-keys-edit-bind 'palette "C-c x"))
                       (lambda () (drgnx-keys-edit-unbind 'palette "C-c p"))
                       #'drgnx-keys-edit-reset-all))
       (let ((err (should-error (funcall op) :type 'user-error)))
         (should (string-search "not changed" (cadr err)))))
     (should (equal (drgnx-keys-edit-test--text) text)))
   (should (= applied 0))))

(ert-deftest drgnx-keys-edit/sets-a-tty-fallback ()
  (drgnx-keys-edit-test--with-dir
   (drgnx-keys-edit-test--put drgnx-keys-edit-test--sample)
   ;; the profile has three chords a legacy terminal cannot send, and M-J
   (setq drgnx-keys-last '(:bindings ((:id palette :key "C-S-p" :map nil) (:id search :key "C-S-f" :map nil)
                                      (:id explorer :key "C-S-e" :map nil) (:id panel :key "M-J" :map nil)
                                      (:id other :key "C-c a" :map nil))))
   (should (drgnx-keys-edit-set-tty-fallback "C-S-p" "M-Z"))
   (let ((text (drgnx-keys-edit-test--text)) (user (drgnx-keys-edit-test--user)))
     (should (equal (plist-get user :tty-fallback) '(("C-S-p" . "M-Z"))))
     ;; comments, layers and the other entries are as they were
     (dolist (c '(";; my settings, hand written" "; the stack" ";; a note about bindings" ";; no key for these"))
       (should (string-search c text)))
     (should (equal (plist-get user :layers) '((emacs editing) (vscode app window))))
     (should (equal (plist-get user :bind) '((palette "C-c p") (line-numbers "C-c l" "<f9>")))))
   (should (= applied 1))
   ;; another chord is added; the same chord again replaces its entry
   (drgnx-keys-edit-set-tty-fallback "C-S-e" "M-Y")
   (drgnx-keys-edit-set-tty-fallback "C-S-p" "M-Q")
   (should (equal (plist-get (drgnx-keys-edit-test--user) :tty-fallback) '(("C-S-p" . "M-Q") ("C-S-e" . "M-Y"))))
   ;; a key that clashes is refused with the reason, and nothing is written
   (let ((before (drgnx-keys-edit-test--text)) (n applied))
     (dolist (case '(("C-S-f" "M-v" "Emacs's")            ; scroll-down-command
                     ("C-S-f" "M-P" "reserved")           ; the start of a terminal's reply
                     ("C-S-f" "M-J" "bound in the key profile")
                     ("C-S-f" "M-Y" "already the fallback of C-S-e")
                     ("C-S-f" "<f5>" "not Alt with a character key")
                     ("C-c a" "M-W" "needs no fallback")   ; a plain terminal sends it
                     ("C-S-q" "M-W" "needs no fallback"))) ; the profile has no such chord
       (let ((err (should-error (drgnx-keys-edit-set-tty-fallback (nth 0 case) (nth 1 case)) :type 'user-error)))
         (should (string-search (nth 2 case) (cadr err)))))
     (should (equal before (drgnx-keys-edit-test--text)))
     (should (= applied n)))
   ;; Undo takes back the last change
   (drgnx-keys-edit-undo)
   (should (equal (plist-get (drgnx-keys-edit-test--user) :tty-fallback) '(("C-S-p" . "M-Z") ("C-S-e" . "M-Y"))))))

(provide 'keys-edit-test)
;;; keys-edit-test.el ends here
