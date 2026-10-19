;;; wb-persist-file-test.el --- batch tests: workbench.eld is written and read through drgnx-file -*- lexical-binding: t -*-
;; Every file lives in a fresh temp folder (never the user's state dir).  `drgnx-persist-state' is stubbed with a small
;; plist where the layout itself is not the point.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-persist)
(require 'drgnx-file)

(defmacro drgnx-persist-file-test--with (var &rest body)
  "BODY with VAR a fresh temp folder, `drgnx-persist-file' in it, one stub frame state, and `message' collected
into `msgs' (a list, newest first)."
  (declare (indent 1))
  `(let* ((,var (file-name-as-directory (make-temp-file "drgnx-persist-file" t)))
          (drgnx-persist-file (expand-file-name "workbench.eld" ,var))
          (msgs nil))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-persist-state) (lambda (&optional _f) (list :role 'main :main '(leaf))))
                   ((symbol-function 'drgnx-state-frame-kind) (lambda (f) (and (framep f) 'gui))))   ; batch's frame, as a window
           (cl-letf (((symbol-function 'message)
                      (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) msgs)) nil)))
             ,@body))
       (delete-directory ,var t))))

(defun drgnx-persist-file-test--put (file text)
  (let ((coding-system-for-write 'utf-8-unix)) (write-region text nil file nil 'silent)))

(defun drgnx-persist-file-test--bytes (file)
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(defun drgnx-persist-file-test--backups (dir)
  (directory-files dir t "\\.bak-"))

(ert-deftest drgnx-persist-file/the-format-is-unchanged ()
  "Store Task 15 relies on it: `(:version 2 :frames (STATE…))', printed whole, readable by a plain `read'."
  (drgnx-persist-file-test--with dir
    (should (equal (drgnx-persist-save drgnx-persist-file (list (selected-frame))) drgnx-persist-file))
    (let ((want '(:version 2 :frames ((:role main :main (leaf))))))
      (should (equal (with-temp-buffer (insert-file-contents drgnx-persist-file) (read (current-buffer))) want))
      (should (equal (drgnx-persist-file-test--bytes drgnx-persist-file) (concat (prin1-to-string want) "\n")))
      (should (equal (drgnx-persist--read drgnx-persist-file) want)))))

(ert-deftest drgnx-persist-file/a-file-written-by-the-old-writer-is-read ()
  "Compatibility: a file `prin1'ed with no trailing newline (the old writer), real window state in it, reads back."
  (drgnx-persist-file-test--with dir
    (delete-other-windows)
    (let* ((state (list :version 2 :frames (list (list :role 'main :left '(:shown nil :px 300)
                                                       :main (window-state-get (window-main-window) t)
                                                       :groups '((:tabs ("/a/b.txt") :shown "/a/b.txt" :px 80))
                                                       :extra '(:layout x))))))
      (drgnx-persist-file-test--put drgnx-persist-file (prin1-to-string state))
      (should (equal (drgnx-persist--read drgnx-persist-file) state))
      (should-not msgs))))

(ert-deftest drgnx-persist-file/exit-save-is-atomic ()
  "A save that fails at the rename keeps the old bytes, leaves no temp file, and is one message, not a signal."
  (drgnx-persist-file-test--with dir
    (drgnx-persist-save drgnx-persist-file (list (selected-frame)))
    (let ((before (drgnx-persist-file-test--bytes drgnx-persist-file)))
      (cl-letf (((symbol-function 'drgnx-persist-state) (lambda (&optional _f) (list :role 'main :main '(changed))))
                ((symbol-function 'drgnx-persist--gui-frame) (lambda () (selected-frame)))
                ((symbol-function 'rename-file) (lambda (&rest _) (signal 'file-error '("Renaming" "boom")))))
        (drgnx-persist--on-exit))
      (should (equal (drgnx-persist-file-test--bytes drgnx-persist-file) before))
      (should-not (directory-files dir nil "\\.tmp-"))
      (should-not (directory-files dir nil "\\.lock"))
      (should (= 1 (length msgs)))
      (should (string-match-p "workbench\\.eld not saved" (car msgs))))))

(ert-deftest drgnx-persist-file/a-newer-file-is-never-overwritten ()
  (drgnx-persist-file-test--with dir
    (let ((text "(:version 3 :frames nil :future (a b c))\n"))
      (drgnx-persist-file-test--put drgnx-persist-file text)
      (should-not (drgnx-persist-save drgnx-persist-file (list (selected-frame))))
      (should (equal (drgnx-persist-file-test--bytes drgnx-persist-file) text))
      (should (equal msgs '("workbench.eld was written by a newer drgnx: not saved")))
      (should-not (drgnx-persist-file-test--backups dir))
      ;; the exit hook, too
      (setq msgs nil)
      (cl-letf (((symbol-function 'drgnx-persist--gui-frame) (lambda () (selected-frame))))
        (drgnx-persist--on-exit))
      (should (equal (drgnx-persist-file-test--bytes drgnx-persist-file) text))
      (should (equal msgs '("workbench.eld was written by a newer drgnx: not saved"))))))

(ert-deftest drgnx-persist-file/a-newer-file-is-not-restored-either ()
  (drgnx-persist-file-test--with dir
    (drgnx-persist-file-test--put drgnx-persist-file "(:version 3 :frames ((:role main)))\n")
    (should-not (drgnx-persist-restore drgnx-persist-file))
    (should (cl-some (lambda (m) (string-match-p "format 3" m)) msgs))))

(ert-deftest drgnx-persist-file/an-unreadable-file-is-backed-up-at-the-next-save ()
  (drgnx-persist-file-test--with dir
    (let ((bad "(:version 2 :frames ((:role main)\n"))        ; a missing paren
      (drgnx-persist-file-test--put drgnx-persist-file bad)
      ;; the read: no restore, one message, the file untouched
      (should-not (drgnx-persist-restore drgnx-persist-file))
      (should (= 1 (length msgs)))
      (should (string-match-p "workbench\\.eld" (car msgs)))
      (should (equal (drgnx-persist-file-test--bytes drgnx-persist-file) bad))
      (should-not (drgnx-persist-file-test--backups dir))
      ;; the save: the bytes go to a backup, then the file is the new state
      (should (drgnx-persist-save drgnx-persist-file (list (selected-frame))))
      (let ((baks (drgnx-persist-file-test--backups dir)))
        (should (= 1 (length baks)))
        (should (equal (drgnx-persist-file-test--bytes (car baks)) bad)))
      (should (equal (plist-get (drgnx-persist--read drgnx-persist-file) :version) 2)))))

(ert-deftest drgnx-persist-file/crafted-depth-or-objects-are-refused-at-read ()
  (drgnx-persist-file-test--with dir
    (let ((deep (concat (make-string 200 ?\() (make-string 200 ?\))))
          (crafted '("#s(foo bar)" "#1=(a . #1#)" "(:version 2) (more)" "#.(+ 1 2)"
                     "(:version 2 :frames (#<buffer x>))" "(:version 2 :x #(\"a\" 0 1 (face bold)))"))
          (big (concat "(:version 2 :frames nil :pad \"" (make-string 4194400 ?x) "\")")))
      (dolist (text (append (list deep big) crafted))
        (drgnx-persist-file-test--put drgnx-persist-file text)
        (setq msgs nil)
        (should-not (drgnx-persist--read drgnx-persist-file))
        (should-not (drgnx-persist-restore drgnx-persist-file))
        (should msgs)
        (should (equal (drgnx-persist-file-test--bytes drgnx-persist-file) (encode-coding-string text 'utf-8-unix)))))))

(ert-deftest drgnx-persist-file/a-missing-or-empty-file-is-silent ()
  (drgnx-persist-file-test--with dir
    (should-not (drgnx-persist--read drgnx-persist-file))
    (drgnx-persist-file-test--put drgnx-persist-file "")
    (should-not (drgnx-persist--read drgnx-persist-file))
    (should-not msgs)))

(ert-deftest drgnx-persist-file/a-busy-lock-at-exit-is-a-message ()
  "Another drgnx holds the lock: the exit hook waits at most the default 1 s (the seams make that instant), then
says so; nothing is signalled and the file is not touched."
  (drgnx-persist-file-test--with dir
    (drgnx-persist-save drgnx-persist-file (list (selected-frame)))
    (let ((before (drgnx-persist-file-test--bytes drgnx-persist-file))
          (lock (expand-file-name ".workbench.eld.lock" dir))
          (clock 1000.0))
      (make-directory lock)
      (drgnx-persist-file-test--put
       (expand-file-name "owner" lock)
       (prin1-to-string (list :pid (emacs-pid) :host (system-name) :started (drgnx-file--pid-start (emacs-pid))
                              :time clock)))
      (cl-letf (((symbol-function 'drgnx-persist--gui-frame) (lambda () (selected-frame)))
                ((symbol-function 'drgnx-file--now) (lambda () clock))
                ((symbol-function 'drgnx-file--sleep) (lambda (s) (cl-incf clock s)))
                ((symbol-function 'drgnx-persist-state) (lambda (&optional _f) (list :role 'main :main '(changed)))))
        (drgnx-persist--on-exit))
      (should (equal (drgnx-persist-file-test--bytes drgnx-persist-file) before))
      (should (= 1 (length msgs)))
      (should (string-match-p "not saved" (car msgs))))))

(ert-deftest drgnx-persist-file/a-propertized-extra-never-fails-the-save ()
  "A state function's value with text properties is saved without them; one with something unprintable costs only
its own keys, with one message naming it."
  (drgnx-persist-file-test--with dir
    (let* ((drgnx-persist--extra-reported nil)
           (props (lambda () (list :mine (propertize "x" 'face 'bold) :list (list (propertize "y" 'a 1))
                                   :vec (vector (propertize "z" 'b 2)) :dotted (cons 1 (propertize "w" 'c 3)))))
           (bad (lambda () (list :hash (make-hash-table))))
           (ok (lambda () (list :other 1)))
           (drgnx-persist-state-functions (list props bad ok)))
      (cl-letf (((symbol-function 'drgnx-persist-state)
                 (lambda (&optional _f) (list :role 'main :main '(leaf) :extra (drgnx-persist--extra)))))
        (should (drgnx-persist-save drgnx-persist-file (list (selected-frame)))))
      (let ((extra (plist-get (car (plist-get (drgnx-persist--read drgnx-persist-file) :frames)) :extra)))
        (should (equal extra (list :mine "x" :list '("y") :vec ["z"] :dotted '(1 . "w") :other 1)))
        (should-not (text-properties-at 0 (plist-get extra :mine))))
      (should (= 1 (length msgs)))
      (should (string-match-p "state function .*left out" (car msgs))))))

(provide 'wb-persist-file-test)
;;; wb-persist-file-test.el ends here
