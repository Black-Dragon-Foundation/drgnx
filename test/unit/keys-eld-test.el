;;; keys-eld-test.el --- batch tests: keys.eld through the config layer -*- lexical-binding: t -*-
;; Every test runs under `drgnx-test-with-config' (temp config and state folders).  Keys here are fakes; nothing is
;; bound: the tests read, write and refuse files, and the editor's apply and surface refresh are stubbed.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-keys)
(require 'drgnx-keys-edit)
(require 'drgnx-modal-choose)

(defun drgnx-keys-eld-test--put (text) (drgnx-test-config-put 'keys text))
(defun drgnx-keys-eld-test--text () (drgnx-test-config-text 'keys))
(defun drgnx-keys-eld-test--user ()
  "`drgnx-keys-read-user' as `drgnx-keys-apply' calls it: the file read again first."
  (drgnx-config-reread 'keys)
  (drgnx-keys-read-user))

(defmacro drgnx-keys-eld-test--editor (&rest body)
  "BODY with the editor's apply and surface refresh stubbed (they bind keys); `applied' counts the applies."
  (declare (indent 0))
  `(let ((applied 0))
     (ignore applied)
     (cl-letf (((symbol-function 'drgnx-keys-apply) (lambda () (cl-incf applied) nil))
               ((symbol-function 'drgnx-surfaces-refresh) #'ignore))
       ,@body)))

(defconst drgnx-keys-eld-test--sample
  ";; my keys, hand written\n(:layers ((emacs editing) (vscode app window)) ; the stack\n :bind ((palette \"C-c p\") ; mine\n        ;; a note\n        (line-numbers \"C-c l\" \"<f9>\"))\n :unbind (keys-sheet)\n :future-key 42) ; a key a later drgnx knows\n"
  "A keys.eld with comments, a stack, entries and a key this drgnx does not know.")

(defconst drgnx-keys-eld-test--other-stack '((vscode app editing window)))

;;;; Saving keys.eld by hand

(ert-deftest drgnx-keys-eld/a-hand-save-applies-the-keys-at-once ()
  ;; Open Config File…, fix the mistake, save: the notice clears and the keys are applied, without a restart.
  (drgnx-test-with-config
    (drgnx-keys-eld-test--editor
      (let ((drgnx-keys-last '(:layers nil)) (drgnx-keys--session-layers '((vim app)))
            (create-lockfiles nil) (buf nil))
        (should (memq #'drgnx-keys--config-changed drgnx-config-changed-functions))
        (drgnx-keys-eld-test--put "(:bind ((palette)))\n")
        (should (drgnx-config-problem 'keys))
        (unwind-protect
            (progn
              (drgnx-config-open 'keys)
              (setq buf (current-buffer))
              (erase-buffer)
              (insert "(:layers ((emacs editing)))\n")
              (save-buffer)
              (should (= applied 1))
              (should-not (drgnx-config-problem 'keys))
              (should-not drgnx-keys--session-layers)                     ; the file is the authority now
              ;; drgnx's own writes apply what they write themselves: the listener stays out
              (drgnx-config-set 'keys :unbind '(keys-sheet))
              (should (= applied 1)))
          (when (buffer-live-p buf) (with-current-buffer buf (set-buffer-modified-p nil)) (kill-buffer buf)))
        (drgnx-keys-unload-function)
        (should-not (memq #'drgnx-keys--config-changed drgnx-config-changed-functions))))))

;;;; The definition

(ert-deftest drgnx-keys-eld/the-forms-the-guide-teaches-still-read ()
  ;; A file written before the config layer must keep working: the shapes docs/guide/keys.md shows all fit the schema.
  (drgnx-test-with-config
    (dolist (text '("(:layers ((emacs editing) (vscode app window)) :bind ((palette \"C-c p\") (line-numbers \"C-c l\" \"<f9>\") (open-file \"C-c f\" :map (org . org-mode-map))) :unbind (keys-sheet))\n"
                    "(:bind ((palette \"C-c p\" :mac \"s-p\") (quit :none \"reason\" :mac \"s-q\") (menu \"C-c m\" :mac ())))\n"
                    "(:bind ((toggle-panel \"C-`\" :everywhere \"C-j\") (x \"C-c x\" :map org-mode-map)))\n"
                    "(:layers ((vscode app editing window)) :mac-option characters :tty-fallback ((\"C-S-p\" . \"M-Z\")))\n"
                    "(:mac-option meta :pending-layers ((vim app editing window)))\n"
                    "(:version 1 :layers ((emacs app editing window)))\n"
                    ";; only a comment\n"
                    "()\n"
                    "(:bind nil :unbind nil)\n"))
      (drgnx-keys-eld-test--put text)
      (drgnx-config-reread 'keys)
      (should (equal (list text nil) (list text (drgnx-config-problem 'keys)))))))

(ert-deftest drgnx-keys-eld/an-absent-file-is-the-default-stack ()
  (drgnx-test-with-config
    (should (equal (drgnx-keys-read-user) '(:layers nil)))
    (should-not (plist-get (drgnx-keys-read-user) :bind))
    (should-not (file-exists-p (drgnx-keys-file)))))

(ert-deftest drgnx-keys-eld/each-mistake-is-a-problem-naming-the-file ()
  (drgnx-test-with-config
    (dolist (text '("(:bind ((palette \"C-c p\")" "(:layers foo)" "(:layers ((vscode . app)))" "(:bind foo)"
                    "(:bind ((palette . \"C-c p\")))" "(:bind ((palette \"C-c p\" :map \"org-mode-map\")))"
                    "(:bind ((palette))) " "(:unbind palette)" "(:unbind (a \"b\"))" "(:layers ((vscode apps)))"
                    "(:mac-option 7)" "(:pending-layers foo)" "(:bind ((palette \"C-c p\" :mac 7)))"))
      (drgnx-keys-eld-test--put text)
      (let ((drgnx-keys-problems nil))
        (should (equal (list text (plist-get (drgnx-keys-eld-test--user) :layers)) (list text nil)))
        (should (equal (list text t) (list text (and (seq-find (lambda (p) (string-search "keys.eld" p)) drgnx-keys-problems)
                                                     t))))))))

;;;; The fallback

(ert-deftest drgnx-keys-eld/a-mistake-uses-the-last-good-profile-not-another ()
  (drgnx-test-with-config
    (drgnx-keys-eld-test--put "(:layers ((emacs editing) (vscode app window)) :bind ((palette \"C-c p\")))\n")
    (should (equal (plist-get (drgnx-keys-eld-test--user) :layers) '((emacs editing) (vscode app window))))
    (drgnx-keys-eld-test--put "(:layers ((vscode app editing window)))\n")           ; a later good file: the last good one
    (should (equal (plist-get (drgnx-keys-eld-test--user) :layers) drgnx-keys-eld-test--other-stack))
    (drgnx-keys-eld-test--put "(:layers ((vscode app editing window)) :bind ((palette)))\n")      ; a mistake
    (let* ((drgnx-keys-problems nil) (user (drgnx-keys-eld-test--user)))
      (should (equal (plist-get user :layers) drgnx-keys-eld-test--other-stack))      ; the vscode stack, not the emacs one
      (should-not (plist-get user :bind))                                             ; and not the first file's :bind
      (should (seq-find (lambda (p) (and (string-search "keys.eld" p) (string-search "line 1" p))) drgnx-keys-problems)))
    (drgnx-keys-eld-test--put "(:layers ((emacs app editing window)))\n")             ; fixed: applied, the problem gone
    (let ((drgnx-keys-problems nil))
      (should (equal (plist-get (drgnx-keys-eld-test--user) :layers) '((emacs app editing window))))
      (should-not drgnx-keys-problems))))

(ert-deftest drgnx-keys-eld/no-last-good-gives-the-default-stack ()
  (drgnx-test-with-config
    (drgnx-keys-eld-test--put "(:layers ((emacs editing) (vscode app window)) :unbind (a . b))\n")
    (let ((user (drgnx-keys-eld-test--user)))
      (should (equal user '(:layers nil)))                                            ; apply then uses `drgnx-keys-layers'
      (should-not (plist-get user :unbind)))
    (should (drgnx-config-problem 'keys))))

(ert-deftest drgnx-keys-eld/the-file-is-never-partly-applied ()
  ;; One bad :bind entry: the valid :layers and the other entries beside it are not applied either.
  (drgnx-test-with-config
    (drgnx-keys-eld-test--put "(:layers ((emacs editing) (vscode app window)) :bind ((palette \"C-c p\") (broken)) :unbind (keys-sheet))\n")
    (let ((user (drgnx-keys-eld-test--user)))
      (should-not (plist-get user :layers))
      (should-not (plist-get user :bind))
      (should-not (plist-get user :unbind)))
    (should (string-search ":bind" (plist-get (drgnx-config-problem 'keys) :text)))))

;;;; Writers

(ert-deftest drgnx-keys-eld/a-symlinked-keys-eld-stays-a-symlink ()
  (drgnx-test-with-config
    (drgnx-keys-eld-test--editor
      (let ((real (expand-file-name "real-keys.eld" drgnx-test-config-root)))
        (make-directory (file-name-directory (drgnx-keys-file)) t)
        (write-region drgnx-keys-eld-test--sample nil real nil 'silent)
        (make-symbolic-link real (drgnx-keys-file))
        (drgnx-keys--save-key :mac-option 'meta)
        (should (file-symlink-p (drgnx-keys-file)))
        (drgnx-keys-edit-bind 'open-file "C-c f")
        (should (file-symlink-p (drgnx-keys-file)))
        (let ((text (with-temp-buffer (insert-file-contents real) (buffer-string))))
          (should (string-search "open-file" text))
          (should (string-search ":mac-option meta" text))
          (should (string-search ";; my keys, hand written" text)))
        (drgnx-keys-edit-undo)
        (should (file-symlink-p (drgnx-keys-file)))
        (should (string-search ":mac-option meta" (with-temp-buffer (insert-file-contents real) (buffer-string))))))))

(ert-deftest drgnx-keys-eld/choose-profile-keeps-comments-and-binds ()
  (drgnx-test-with-config
    (drgnx-keys-eld-test--put drgnx-keys-eld-test--sample)
    (let ((prepared nil) (used nil))
      (cl-letf (((symbol-function 'drgnx-modal-prepare) (lambda (layers &rest _) (setq prepared layers) 'ready))
                ((symbol-function 'drgnx-keys-use) (lambda (layers &rest _) (setq used layers))))
        (drgnx-keys-choose-profile "VS Code"))
      (should (equal prepared drgnx-keys-eld-test--other-stack))
      (should (equal used drgnx-keys-eld-test--other-stack)))
    (let ((text (drgnx-keys-eld-test--text)))
      (should (equal text (replace-regexp-in-string "((emacs editing) (vscode app window))"
                                                    "((vscode app editing window))"
                                                    drgnx-keys-eld-test--sample t t)))
      (should (string-search ":future-key 42" text)))
    (let ((user (drgnx-keys-eld-test--user)))
      (should (equal (plist-get user :layers) drgnx-keys-eld-test--other-stack))
      (should (equal (plist-get user :bind) '((palette "C-c p") (line-numbers "C-c l" "<f9>")))))))

(ert-deftest drgnx-keys-eld/choosing-a-profile-with-a-mistake-changes-nothing ()
  (drgnx-test-with-config
    (let ((text "(:layers ((emacs editing)) :bind ((broken)))  ; mine\n") (called nil))
      (drgnx-keys-eld-test--put text)
      (cl-letf (((symbol-function 'drgnx-modal-prepare) (lambda (&rest _) (setq called t) 'ready))
                ((symbol-function 'drgnx-keys-use) (lambda (&rest _) (setq called t))))
        (let ((err (should-error (drgnx-keys-choose-profile "VS Code") :type 'drgnx-config-refused)))
          (should (string-search "keys.eld has a mistake at line 1" (cadr err)))))
      (should-not called)
      (should (equal (drgnx-keys-eld-test--text) text)))))

(ert-deftest drgnx-keys-eld/pending-layers-set-and-unset-keep-the-rest ()
  (drgnx-test-with-config
    (drgnx-keys-eld-test--put drgnx-keys-eld-test--sample)
    (cl-letf (((symbol-function 'drgnx-modal--write-report) #'ignore))
      (drgnx-keys--save-key :pending-layers '((vim app editing window)))
      (let ((text (drgnx-keys-eld-test--text)))
        (should (string-search ":pending-layers ((vim app editing window))" text))
        (should (string-search ";; a note" text))
        (should (string-search ":future-key 42" text)))
      (should (equal (drgnx-modal--pending) '((vim app editing window))))
      (drgnx-modal--forget-pending)
      (should (equal (drgnx-keys-eld-test--text) drgnx-keys-eld-test--sample))        ; byte for byte as it was
      (should-not (drgnx-modal--pending))
      (let ((before (drgnx-keys-eld-test--text)))                                     ; nothing pending: nothing written
        (drgnx-modal--forget-pending)
        (should (equal (drgnx-keys-eld-test--text) before))))))

(ert-deftest drgnx-keys-eld/saving-a-key-into-a-file-with-a-mistake-is-refused ()
  (drgnx-test-with-config
    (let ((text "(:layers ((emacs editing)) :bind ((broken))) ;; mine\n"))
      (drgnx-keys-eld-test--put text)
      (should-error (drgnx-keys--save-key :mac-option 'meta) :type 'drgnx-config-refused)
      (should (equal (drgnx-keys-eld-test--text) text)))))

;;;; The editor

(ert-deftest drgnx-keys-eld/the-editor-refuses-text-with-a-mistake ()
  (drgnx-test-with-config
    (drgnx-keys-eld-test--editor
      ;; the layer: text that does not fit the schema is refused, naming the line, and the file keeps its bytes
      (drgnx-keys-eld-test--put drgnx-keys-eld-test--sample)
      (let ((err (should-error (drgnx-config-write-text 'keys "(:layers ((emacs editing))\n :bind ((palette)))\n")
                               :type 'drgnx-config-refused)))
        (should (string-search "mistake at line 1" (cadr err)))
        (should (string-search ":bind" (cadr err))))
      (should-error (drgnx-config-write-text 'keys "(:bind ((palette \"C-c p\")") :type 'drgnx-config-refused)
      (should (equal (drgnx-keys-eld-test--text) drgnx-keys-eld-test--sample))
      ;; the editor: a file whose rest has a mistake the editor's own check misses is not rewritten
      (let ((text "(:mac-option 7)\n"))
        (drgnx-keys-eld-test--put text)
        (let ((err (should-error (drgnx-keys-edit-bind 'palette "C-c p") :type 'drgnx-config-refused)))
          (should (string-search "mistake at line 1" (cadr err))))
        (should (equal (drgnx-keys-eld-test--text) text))
        (should-not (file-exists-p (concat (drgnx-keys-file) ".undo")))
        (should (= applied 0))))))

(ert-deftest drgnx-keys-eld/the-editor-refuses-a-file-changed-meanwhile ()
  (drgnx-test-with-config
    (drgnx-keys-eld-test--editor
      ;; the layer: the stamp seen when the editor read the file
      (drgnx-keys-eld-test--put drgnx-keys-eld-test--sample)
      (let* ((stamp (drgnx-file-stamp (drgnx-keys-file)))
             (later (concat drgnx-keys-eld-test--sample ";; edited by hand\n")))
        (drgnx-keys-eld-test--put later)
        (let ((err (should-error (drgnx-config-write-text 'keys ";; mine\n(:bind ((a \"C-c a\")))\n" :expect-stamp stamp)
                                 :type 'drgnx-config-refused)))
          (should (string-search "changed since you opened it" (cadr err))))
        (should (equal (drgnx-keys-eld-test--text) later)))
      ;; a file that was absent when the editor looked, and is there now
      (let ((err (should-error (drgnx-config-write-text 'keys "(:bind nil)\n" :expect-stamp nil) :type 'drgnx-config-refused)))
        (should (string-search "changed since you opened it" (cadr err))))
      ;; the editor: another session writes keys.eld between its read and its write
      (drgnx-keys-eld-test--put drgnx-keys-eld-test--sample)
      (let ((theirs (concat drgnx-keys-eld-test--sample ";; another session\n")))
        (cl-letf* ((orig (symbol-function 'drgnx-keys-edit--check))
                   ((symbol-function 'drgnx-keys-edit--check)
                    (lambda (text)
                      (when (string-search ":layers" text) (drgnx-keys-eld-test--put theirs))   ; after the read, before the write
                      (funcall orig text))))
          (let ((err (should-error (drgnx-keys-edit-bind 'open-file "C-c f") :type 'drgnx-config-refused)))
            (should (string-search "changed since you opened it" (cadr err)))))
        (should (equal (drgnx-keys-eld-test--text) theirs))
        (should-not (file-exists-p (concat (drgnx-keys-file) ".undo")))
        (should (= applied 0))))))

(ert-deftest drgnx-keys-eld/write-text-writes-exactly-the-text-and-applies-it ()
  (drgnx-test-with-config
    (let ((seen nil) (text ";; mine, exactly\n(:layers ((emacs editing))   :bind ((a \"C-c a\")))\n"))
      (add-hook 'drgnx-config-changed-functions (lambda (name) (push name seen)))
      (should (equal (plist-get (drgnx-config-write-text 'keys text :expect-stamp nil) :layers) '((emacs editing))))
      (should (equal (drgnx-keys-eld-test--text) text))                               ; spacing and comment kept
      (should (equal seen '(keys)))
      (should (equal (plist-get (drgnx-keys-read-user) :bind) '((a "C-c a"))))
      (should (= (file-modes (drgnx-keys-file)) #o644))
      (should-not (directory-files (drgnx-user-dir) nil "lock"))                      ; the lock is released
      ;; a comment-only text is a file too
      (drgnx-config-write-text 'keys ";; empty now\n" :expect-stamp (drgnx-file-stamp (drgnx-keys-file)))
      (should (equal (drgnx-keys-eld-test--text) ";; empty now\n"))
      (should (equal (drgnx-keys-read-user) '(:layers nil))))))

(ert-deftest drgnx-keys-eld/write-text-never-overwrites-what-it-should-not ()
  (drgnx-test-with-config
    ;; a file with a mistake, no stamp: refused like every writer; with the stamp the editor saw, it may fix it
    (let ((broken "(:bind ((palette)))  ; mine\n"))
      (drgnx-keys-eld-test--put broken)
      (should-error (drgnx-config-write-text 'keys "(:bind nil)\n") :type 'drgnx-config-refused)
      (should (equal (drgnx-keys-eld-test--text) broken))
      (drgnx-config-write-text 'keys "(:bind nil)\n" :expect-stamp (drgnx-file-stamp (drgnx-keys-file)))
      (should (equal (drgnx-keys-eld-test--text) "(:bind nil)\n")))
    ;; a file a newer drgnx wrote, with or without the stamp: refused
    (let ((newer "(:version 99 :layers ((emacs editing)))\n"))
      (drgnx-keys-eld-test--put newer)
      (should-error (drgnx-config-write-text 'keys "(:bind nil)\n") :type 'drgnx-config-refused)
      (should-error (drgnx-config-write-text 'keys "(:bind nil)\n" :expect-stamp (drgnx-file-stamp (drgnx-keys-file)))
                    :type 'drgnx-config-refused)
      (should (equal (drgnx-keys-eld-test--text) newer))
      ;; and text in a newer format is not written either
      (should-error (drgnx-config-write-text 'keys "(:version 99)\n") :type 'drgnx-config-refused))
    ;; over the size limit
    (should-error (drgnx-config-write-text 'keys (concat "(:unbind (" (mapconcat #'identity (make-list 230000 "aaaa") " ") "))"))
                  :type 'drgnx-config-refused)))

(ert-deftest drgnx-keys-eld/the-undo-copy-is-a-data-file-and-undo-writes-through-the-layer ()
  (drgnx-test-with-config
    (drgnx-keys-eld-test--editor
      (drgnx-keys-eld-test--put drgnx-keys-eld-test--sample)
      (drgnx-keys-edit-bind 'open-file "C-c f")
      (let ((saved (plist-get (drgnx-file-read (concat (drgnx-keys-file) ".undo")) :data)))
        (should (equal (plist-get saved :old) drgnx-keys-eld-test--sample))
        (should (string-search "open-file" (plist-get saved :new))))
      (drgnx-keys-edit-undo)
      (should (equal (drgnx-keys-eld-test--text) drgnx-keys-eld-test--sample))
      (should (equal (plist-get (drgnx-keys-read-user) :bind) '((palette "C-c p") (line-numbers "C-c l" "<f9>")))))))

(provide 'keys-eld-test)
;;; keys-eld-test.el ends here
