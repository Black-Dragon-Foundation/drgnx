;;; mod-replace-engine-test.el --- batch tests: the replace engine — writing matches, symbols through the server, one-step undo -*- lexical-binding: t -*-
;; test-class: cond
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/held-fixture" drgnx-dir) nil t)
(require 'eglot)
(load (expand-file-name "test/fixtures/git-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defun drgnx-replace-test--run (query)
  "QUERY's matches in the files under its root, each of the pattern in each line (`drgnx-replace--match'): (MATCHES .
\(:done)).  The hub searches the text (search/run); here only the writing is tested."
  (let* ((root (plist-get query :root)) (case (plist-get query :case)) (regexp (plist-get query :regexp))
         (text (plist-get query :text))
         (re (drgnx-replace--line-regexp query))
         (extra (when regexp (list :pattern (drgnx-replace--emacs-regexp text) :case case)))
         (matches nil))
    (dolist (file (sort (directory-files-recursively root "" nil (lambda (d) (not (equal (file-name-nondirectory d) ".git"))))
                        #'string<))
      (with-temp-buffer
        (insert-file-contents file)
        (let ((case-fold-search (not case)) (n 0))
          (dolist (line (split-string (buffer-string) "\n"))
            (setq n (1+ n))
            (let ((line (string-trim-right line "\r")) (start 0))
              (with-syntax-table drgnx-replace--syntax
                (while (and (<= start (length line)) (string-match re line start))
                  (setq matches (append matches (list (drgnx-replace--match file n line (match-beginning 0)
                                                                            (match-end 0) extra)))
                        start (max (match-end 0) (1+ (match-beginning 0)))))))))))
    (cons matches (list :done))))

(defun drgnx-replace-test--read (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun drgnx-replace-test--q (root text &rest more)
  (append more (list :root root :text text :case t)))

(ert-deftest drgnx-replace/regexp-groups-in-the-new-text ()
  (drgnx-git-test-with-repo
    (drgnx-git-test-write repo "f.txt" "Foo foo food\nfoo_bar é foo\n")
    (let ((m (car (car (drgnx-replace-test--run (drgnx-replace-test--q repo "(f)o+(d)" :regexp t))))))
      (should (equal (plist-get m :text) "food"))
      (should (equal (drgnx-replace-new-text m "\\2-\\1") "d-f")))
    ;; literal mode inserts the new text as it is
    (let ((m (car (car (drgnx-replace-test--run (drgnx-replace-test--q repo "food"))))))
      (should (equal (drgnx-replace-new-text m "\\1&") "\\1&")))))

;; Replace All, Replace This and Undo go through the hub (`search/edits', `search/apply', `search/undo'): it writes
;; closed files itself (test/conformance/search/write.jsonl, the hub's tests) and sends each file this Emacs has open
;; (`search-apply'), which `drgnx-replace-apply-edits' writes into its buffer and answers.

(defun drgnx-replace-test--apply (file tick &rest edits)
  "The answer to a `search-apply' of EDITS ((ID LINE COL END-COL OLD NEW), one line each) for FILE, TICK given."
  (drgnx-replace-apply-edits
   (list :view "s" :change 1 :path file :ttl_ms 2000 :tick tick
         :edits (vconcat (mapcar (pcase-lambda (`(,id ,line ,col ,end ,old ,new))
                                   (list :id id :line line :col col :end_line line :end_col end :old old :new new))
                                 edits)))))

(defun drgnx-replace-test--undo (file answer)
  "Put back what ANSWER (`drgnx-replace-apply-edits') wrote into FILE's buffer: its inverse edits, at its tick."
  (drgnx-replace-apply-edits (list :view "s" :change 2 :path file :ttl_ms 2000 :tick (plist-get answer :tick)
                                   :edits (plist-get answer :inverse))))

(ert-deftest drgnx-replace/an-open-file-is-written-in-its-buffer-and-saved ()
  "A `search-apply' for a file open here goes into its buffer, one undo step, saved (it held no unsaved edits); the
answer carries the inverse edits, which put it back while the buffer is as the write left it."
  (drgnx-git-test-with-repo
    (drgnx-git-test-write repo "a.txt" "x foo y\nfoo é foo\n")
    (let* ((a (expand-file-name "a.txt" repo)) (buf (find-file-noselect a))
           (r (drgnx-replace-test--apply a nil '("m:1:0" 1 2 5 "foo" "quux") '("m:1:1" 2 0 3 "foo" "q")
                                         '("m:1:2" 2 6 9 "foo" "quux"))))
      (should (equal (plist-get r :applied) ["m:1:0" "m:1:1" "m:1:2"]))
      (should (equal (plist-get r :skipped) []))
      (should (eq (plist-get r :saved) t))
      (should (equal (drgnx-replace-test--read a) "x quux y\nq é quux\n"))
      (should-not (buffer-modified-p buf))
      (should (equal (mapcar (lambda (e) (list (plist-get e :line) (plist-get e :col) (plist-get e :end_col)
                                               (plist-get e :old) (plist-get e :new)))
                             (plist-get r :inverse))
                     '((1 2 6 "quux" "foo") (2 0 1 "q" "foo") (2 4 8 "quux" "foo"))))
      ;; one undo step puts the whole file back
      (with-current-buffer buf
        (let ((last-command nil)) (undo))
        (should (equal (buffer-string) "x foo y\nfoo é foo\n"))
        (undo-boundary)                                 ; as the command loop puts after a command
        (let ((last-command nil)) (undo)))
      (should (equal (with-current-buffer buf (buffer-string)) "x quux y\nq é quux\n"))
      (with-current-buffer buf (save-buffer))
      ;; the hub's Undo: the inverse at the tick it answered, refused once the buffer was edited since
      (with-current-buffer buf (goto-char (point-max)) (insert "z") (delete-char -1))
      (let ((u (drgnx-replace-test--undo a r)))
        (should (equal (plist-get u :applied) []))
        (should (equal (plist-get (aref (plist-get u :skipped) 0) :why) "edited since the replacement")))
      (let* ((r2 (drgnx-replace-test--apply a nil '("m:2:0" 1 0 1 "x" "w")))
             (u (drgnx-replace-test--undo a r2)))
        (should (equal (plist-get u :applied) ["m:2:0"]))
        (should (equal (drgnx-replace-test--read a) "x quux y\nq é quux\n"))))))

(ert-deftest drgnx-replace/stale-edits-are-skipped-in-the-buffer ()
  "An edit whose old text is no longer where the edit set read it is skipped with why, the others go in; a buffer
whose file changed on disk is read again when it holds no edits of yours, left alone when it does; a file no buffer
visits is the hub's to write (`not_open'); of two edits that overlap the first goes in."
  (drgnx-git-test-with-repo
    (dolist (f '(("a.txt" . "foo 1\nfoo 2\n") ("c.txt" . "nope foo\n") ("d.txt" . "foo 5\n")))
      (drgnx-git-test-write repo (car f) (cdr f)))
    (let* ((file (lambda (n) (expand-file-name n repo))) (later (time-add nil 10)))
      ;; a.txt: line 1 edited in its buffer, not saved: line 2 still takes its edit, the buffer stays unsaved
      (with-current-buffer (find-file-noselect (funcall file "a.txt"))
        (goto-char (point-min)) (delete-char 3) (insert "bar"))
      (let ((r (drgnx-replace-test--apply (funcall file "a.txt") nil '("m:1" 1 0 3 "foo" "qux") '("m:2" 2 0 3 "foo" "qux"))))
        (should (equal (plist-get r :applied) ["m:2"]))
        (should (equal (plist-get (aref (plist-get r :skipped) 0) :why) "its text changed"))
        (should (eq (plist-get r :saved) :false))
        (should (equal (drgnx-replace-test--read (funcall file "a.txt")) "foo 1\nfoo 2\n"))
        (should (equal (with-current-buffer (get-file-buffer (funcall file "a.txt")) (buffer-string)) "bar 1\nqux 2\n")))
      ;; c.txt: visited, unchanged in Emacs, changed on disk: read again, then the edit is placed against it
      (find-file-noselect (funcall file "c.txt"))
      (write-region "xx nope foo\n" nil (funcall file "c.txt") nil 'silent)
      (set-file-times (funcall file "c.txt") later)
      (let ((r (drgnx-replace-test--apply (funcall file "c.txt") nil '("m:3" 1 5 8 "foo" "qux"))))
        (should (equal (plist-get r :applied) []))
        (should (equal (with-current-buffer (get-file-buffer (funcall file "c.txt")) (buffer-string)) "xx nope foo\n")))
      ;; d.txt: edited in its buffer and changed on disk: left alone
      (with-current-buffer (find-file-noselect (funcall file "d.txt")) (goto-char (point-max)) (insert "more\n"))
      (write-region "foo 5\ndisk\n" nil (funcall file "d.txt") nil 'silent)
      (set-file-times (funcall file "d.txt") later)
      (let ((r (drgnx-replace-test--apply (funcall file "d.txt") nil '("m:4" 1 0 3 "foo" "qux"))))
        (should (equal (plist-get (aref (plist-get r :skipped) 0) :why) "changed on disk and in its buffer"))
        (should (equal (drgnx-replace-test--read (funcall file "d.txt")) "foo 5\ndisk\n"))
        (should (equal (with-current-buffer (get-file-buffer (funcall file "d.txt")) (buffer-string)) "foo 5\nmore\n")))
      ;; no buffer: the hub writes it
      (should (equal (drgnx-replace-test--apply (funcall file "e.txt") nil '("m:5" 1 0 3 "foo" "qux")) '(:not_open t)))
      ;; overlapping edits: the first goes in
      (drgnx-git-test-write repo "f.txt" "aaaa\n")
      (find-file-noselect (funcall file "f.txt"))
      (let ((r (drgnx-replace-test--apply (funcall file "f.txt") nil '("m:6" 1 0 3 "aaa" "b") '("m:7" 1 1 4 "aaa" "c"))))
        (should (equal (plist-get r :applied) ["m:6"]))
        (should (equal (plist-get (aref (plist-get r :skipped) 0) :why) "overlaps another match"))
        (should (equal (drgnx-replace-test--read (funcall file "f.txt")) "ba\n"))))))

(defun drgnx-replace-test--edit (line char len new)
  (list :range (list :start (list :line line :character char) :end (list :line line :character (+ char len)))
        :newText new))

(ert-deftest drgnx-replace/symbol-edits-from-a-server ()
  (drgnx-git-test-with-repo
    (drgnx-git-test-write repo "a.el" "(defun foo () (foo))\n")
    (drgnx-git-test-write repo "b.el" "(foo)\n;; 😀 x foo\n")
    (let* ((a (expand-file-name "a.el" repo)) (b (expand-file-name "b.el" repo))
           (ua (eglot-path-to-uri a)) (ub (eglot-path-to-uri b))
           (calls nil) (reply nil)
           (run (lambda ()                 ; the server only while asking (visiting a file would start eglot)
                  (let ((got nil))
                    (with-current-buffer (find-file-noselect a)
                      (goto-char 9)                ; inside the first foo
                      (cl-letf (((symbol-function 'eglot-current-server) (lambda () 'fake-server))
                                ((symbol-function 'eglot-server-capable) (lambda (&rest f) (equal f '(:renameProvider))))
                                ((symbol-function 'eglot--signal-textDocument/didChange) #'ignore)
                                ((symbol-function 'jsonrpc-request)
                                 (lambda (server method params &rest _) (push (list server method params) calls) reply)))
                        (drgnx-replace-symbol-edits (lambda (x) (push x got)))))
                    (nreverse got)))))
      ;; `changes': uri → edits; the emoji counts as two UTF-16 units
      (setq reply (list :changes (list (intern (concat ":" ua))
                                       (vector (drgnx-replace-test--edit 0 7 3 "foo_drgnx_rename")
                                               (drgnx-replace-test--edit 0 15 3 "foo_drgnx_rename"))
                                       (intern (concat ":" ub))
                                       (vector (drgnx-replace-test--edit 0 1 3 "foo_drgnx_rename")
                                               (drgnx-replace-test--edit 1 8 3 "foo_drgnx_rename")))))
      (let* ((got (funcall run)) (ms (car got)))
        (should (eq (cadr got) :done))
        (should (equal (car (car calls)) 'fake-server))
        (should (eq (nth 1 (car calls)) :textDocument/rename))
        (let ((p (nth 2 (car calls))))
          (should (equal (plist-get p :newName) "foo_drgnx_rename"))
          (should (equal (plist-get (plist-get p :textDocument) :uri) ua))
          (should (equal (plist-get p :position) '(:line 0 :character 8))))
        (should (= (length ms) 4))
        (should (equal (mapcar (lambda (m) (list (file-name-nondirectory (plist-get m :file)) (plist-get m :line)
                                                 (plist-get m :col) (plist-get m :end) (plist-get m :text)))
                               ms)
                       '(("a.el" 1 7 10 "foo") ("a.el" 1 15 18 "foo") ("b.el" 1 1 4 "foo") ("b.el" 2 7 10 "foo"))))
        (should (equal (plist-get (nth 3 ms) :before) ";; 😀 x "))
        (should (equal (plist-get (car ms) :new) "foo_drgnx_rename"))
        (should (equal (drgnx-replace-new-text (car ms) "bar") "bar"))
        ;; and nothing was applied
        (should (equal (drgnx-replace-test--read b) "(foo)\n;; 😀 x foo\n"))
        (should-not (buffer-modified-p (get-file-buffer a)))
        ;; Replace All sends them to the hub as edits it is given (`search/edits' `edits')
        (should (equal (append (drgnx-replace--given ms "bar") nil)
                       (list (list :path a :line 1 :col 7 :end_col 10 :old "foo" :new "bar")
                             (list :path a :line 1 :col 15 :end_col 18 :old "foo" :new "bar")
                             (list :path b :line 1 :col 1 :end_col 4 :old "foo" :new "bar")
                             (list :path b :line 2 :col 7 :end_col 10 :old "foo" :new "bar")))))
      ;; `documentChanges' (preferred over `changes' when both come); resource operations are not text edits
      (setq reply (list :changes (list (intern (concat ":" ub)) (vector (drgnx-replace-test--edit 0 1 3 "nope")))
                        :documentChanges
                        (vector (list :textDocument (list :uri ua :version nil)
                                      :edits (vector (drgnx-replace-test--edit 0 7 3 "foo_drgnx_rename")))
                                (list :kind "rename" :oldUri ub :newUri (concat ub "x")))))
      (let ((ms (car (funcall run))))
        (should (equal (mapcar (lambda (m) (list (file-name-nondirectory (plist-get m :file)) (plist-get m :col))) ms)
                       '(("a.el" 7))))))))

(ert-deftest drgnx-replace/symbol-without-a-server ()
  ;; Review Focus 2: no server, a server without rename, a server that refuses — each says why, nothing else.
  (drgnx-git-test-with-repo
    (drgnx-git-test-write repo "a.el" "(foo)\n")
    (set-buffer (find-file-noselect (expand-file-name "a.el" repo)))
    (goto-char 3)
    (let ((cases `((nil t nil) (fake nil nil) (fake t refuse)))
          (reasons nil))
      (pcase-dolist (`(,server ,capable ,refuse) cases)
        (let ((got nil))
          (cl-letf (((symbol-function 'eglot-current-server) (lambda () server))
                    ((symbol-function 'eglot-server-capable) (lambda (&rest _) capable))
                    ((symbol-function 'eglot--signal-textDocument/didChange) #'ignore)
                    ((symbol-function 'jsonrpc-request)
                     (lambda (&rest _) (if refuse (signal 'jsonrpc-error '("request id=3 failed:" (jsonrpc-error-code . -32602)
                                                                           (jsonrpc-error-message . "Cannot rename this element"))) '(:changes nil)))))
            (drgnx-replace-symbol-edits (lambda (x) (push x got))))
          (setq got (nreverse got))
          (should (equal (length got) 2))
          (should (eq (car (car got)) :error))
          (should (stringp (cadr (car got))))
          (should (eq (cadr got) :done))
          (push (cadr (car got)) reasons)))
      (should (= (length (delete-dups reasons)) 3))
      (should (string-match-p "Cannot rename" (car reasons))))))

(ert-deftest drgnx-replace/symbol-edits-read-the-current-text ()
  ;; the buffer's pending edits reach the server before the rename; an edit whose text is not the name renamed (a
  ;; server that read older text) is left out, and the callback says so
  (drgnx-git-test-with-repo
    (drgnx-git-test-write repo "a.el" "(defun foo () (foo))\n")
    (let* ((a (expand-file-name "a.el" repo)) (ua (eglot-path-to-uri a)) (sent nil) (got nil)
           (reply (lambda (&rest cols)
                    (list :changes (list (intern (concat ":" ua))
                                         (apply #'vector (mapcar (lambda (c) (drgnx-replace-test--edit 0 c 3 "foo_drgnx_rename"))
                                                                 cols)))))))
      (with-current-buffer (find-file-noselect a)
        (goto-char (point-min))
        (insert "xx")                                   ; typed just now: foo is at 9 and 17
        (goto-char 12)
        (cl-letf (((symbol-function 'eglot-current-server) (lambda () 'fake-server))
                  ((symbol-function 'eglot-server-capable) (lambda (&rest _) t))
                  ((symbol-function 'eglot--signal-textDocument/didChange) (lambda () (setq sent t)))
                  ((symbol-function 'jsonrpc-request) (lambda (&rest _) (if sent (funcall reply 9 17) (funcall reply 7 15)))))
          (drgnx-replace-symbol-edits (lambda (x) (push x got)))
          (setq got (nreverse got))
          (should sent)
          (should (equal (mapcar (lambda (m) (plist-get m :col)) (car got)) '(9 17)))
          (should (eq (cadr got) :done))
          (setq got nil)
          (cl-letf (((symbol-function 'jsonrpc-request) (lambda (&rest _) (funcall reply 9 15))))
            (drgnx-replace-symbol-edits (lambda (x) (push x got))))
          (setq got (nreverse got))
          (should (equal (mapcar (lambda (m) (plist-get m :col)) (car got)) '(9)))
          (should (eq (car (nth 1 got)) :error))
          (should (eq (nth 2 got) :done)))))))

(ert-deftest drgnx-replace/unsaved-buffers-stay-unsaved ()
  "A buffer with unsaved edits gets the replacement but is not saved (as in VS Code); its inverse still puts it back."
  (drgnx-git-test-with-repo
    (drgnx-git-test-write repo "a.txt" "foo\nmine\n")
    (let* ((a (expand-file-name "a.txt" repo)) (abuf (find-file-noselect a)))
      (with-current-buffer abuf (goto-char (point-max)) (insert "unsaved\n"))
      (let ((r (drgnx-replace-test--apply a nil '("m:1" 1 0 3 "foo" "bar"))))
        (should (eq (plist-get r :saved) :false))
        (should (equal (with-current-buffer abuf (buffer-string)) "bar\nmine\nunsaved\n"))
        (should (buffer-modified-p abuf))
        (should (equal (drgnx-replace-test--read a) "foo\nmine\n"))
        (should (equal (plist-get (drgnx-replace-test--undo a r) :applied) ["m:1"]))
        (should (equal (with-current-buffer abuf (buffer-string)) "foo\nmine\nunsaved\n"))
        (should (buffer-modified-p abuf))))))

(defvar apheleia-format-after-save-in-progress)

(ert-deftest drgnx-replace/format-on-save-keeps-undo ()
  "A formatter on save (apheleia, extra/format) would rewrite the file after the write saves it, and Undo would then
skip the file: the write's and the undo's saves run without it."
  (drgnx-git-test-with-repo
    (drgnx-git-test-write repo "a.txt" "foo\n")
    (let ((a (expand-file-name "a.txt" repo)))
      (with-current-buffer (find-file-noselect a)
        (add-hook 'after-save-hook
                  (lambda ()
                    (unless (bound-and-true-p apheleia-format-after-save-in-progress)
                      (goto-char (point-max))
                      (insert ";; formatted\n")
                      (let ((apheleia-format-after-save-in-progress t)) (save-buffer))))
                  nil t))
      (let ((r (drgnx-replace-test--apply a nil '("m:1" 1 0 3 "foo" "bar"))))
        (should (equal (drgnx-replace-test--read a) "bar\n"))
        (should (equal (plist-get (drgnx-replace-test--undo a r) :applied) ["m:1"]))
        (should (equal (drgnx-replace-test--read a) "foo\n"))))))

;;; mod-replace-engine-test.el ends here
