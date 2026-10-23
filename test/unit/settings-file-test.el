;;; settings-file-test.el --- batch tests: settings files read as data, written one span at a time -*- lexical-binding: t -*-
;; Every file lives in a fresh temp folder; the config-layer tests run under `drgnx-test-with-config' (config and
;; state folders under a temp root).  The concurrency test starts two batch Emacsen with this Emacs's environment and
;; waits for them under a 90 s bound.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-registry)
(require 'drgnx-settings-file)

(defconst drgnx-settings-file-test--design
  ";;; settings.el --- your settings  -*- lexical-binding: t; mode: lisp-data -*-
;; Written by drgnx Settings and by you. Kept sorted; a comment above an entry stays with it.
;; Values are data: write 80 or (a b), not '(a b). Code goes in config.el. drgnx reads this file; never load it.
(drgnx-settings
 :version 1
 (drgnx-agents-default \"claude\")
 ;; the review profile reads every project
 (drgnx-agents-profiles
  ((\"review\" :command (\"claude-agent-acp\") :mode queue :model \"opus\" :doc \"Reviews\")))
 (drgnx-keys-layers ((vscode app editing window)))
 (drgnx-trust-parents ((\"~/workspace/\")))
 (eglot-autoshutdown t)
 (fill-column 100)
 (:mode python-ts-mode
  (fill-column 88)))
"
  "Design §5.2's settings.el.")

(defconst drgnx-settings-file-test--workspace
  "(drgnx-workspace-settings
 :version 1
 (drgnx-search-exclude (\"vendor/**\" \"*.min.js\"))
 (fill-column 100)
 (:mode python-ts-mode (python-indent-offset 4))
 (:dir \"docs/\" (fill-column 72))
 (:eval (add-hook 'before-save-hook #'my-format-buffer nil t)))
"
  "Design §5.3's workspace file.")

(defmacro drgnx-settings-file-test--with-dir (var &rest body)
  "BODY with VAR bound to a fresh temp folder (with a trailing slash), deleted afterwards."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "drgnx-settings-file-test" t))))
     (unwind-protect (progn ,@body) (delete-directory ,var t))))

(defun drgnx-settings-file-test--put (file text)
  "Write TEXT to FILE as UTF-8, making its folder."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'utf-8-unix)) (write-region text nil file nil 'silent)))

(defun drgnx-settings-file-test--text (file)
  "FILE's text."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
    (buffer-string)))

(defun drgnx-settings-file-test--facts (doc)
  "DOC's entries as ((VAR SCOPE VALUE MERGE)…)."
  (mapcar (lambda (e) (list (drgnx-settings-entry-var e) (drgnx-settings-entry-scope e) (drgnx-settings-entry-value e)
                            (drgnx-settings-entry-merge e)))
          (drgnx-settings-doc-entries doc)))

(defun drgnx-settings-file-test--form (&rest lines)
  "A settings.el text: the form (drgnx-settings :version 1 LINES…), one per line."
  (concat "(drgnx-settings\n :version 1" (mapconcat (lambda (l) (concat "\n " l)) lines "") ")\n"))

(defun drgnx-settings-file-test--leftovers (dir)
  "Temp files and locks left in DIR."
  (directory-files dir nil "\\.tmp-\\|\\.lock"))

(defun drgnx-settings-file-test--put-var (file var value &rest keys)
  "Put VAR = VALUE at the top of settings.el FILE."
  (apply #'drgnx-settings-file-put file 'drgnx-settings nil var value keys))

;;;; Reading

(ert-deftest drgnx-settings-file/parses-the-design-example ()
  (let ((doc (drgnx-settings-file-parse drgnx-settings-file-test--design 'drgnx-settings)))
    (should-not (drgnx-settings-doc-failed doc))
    (should-not (drgnx-settings-doc-problems doc))
    (should (equal (drgnx-settings-doc-meta doc) '(:version 1)))
    (should (equal (drgnx-settings-file-test--facts doc)
                   '((drgnx-agents-default nil "claude" nil)
                     (drgnx-agents-profiles nil (("review" :command ("claude-agent-acp") :mode queue :model "opus"
                                                  :doc "Reviews"))
                                            nil)
                     (drgnx-keys-layers nil ((vscode app editing window)) nil)
                     (drgnx-trust-parents nil (("~/workspace/")) nil)
                     (eglot-autoshutdown nil t nil)
                     (fill-column nil 100 nil)
                     (fill-column ((:mode . python-ts-mode)) 88 nil))))
    (let ((last (car (last (drgnx-settings-doc-entries doc)))))
      (should (= (drgnx-settings-entry-line last) 15))
      (should (equal (substring drgnx-settings-file-test--design (1- (drgnx-settings-entry-beg last))
                                (1- (drgnx-settings-entry-end last)))
                     "(fill-column 88)"))))
  (let ((doc (drgnx-settings-file-parse drgnx-settings-file-test--workspace 'drgnx-workspace-settings)))
    (should-not (drgnx-settings-doc-problems doc))
    (should (equal (drgnx-settings-file-test--facts doc)
                   '((drgnx-search-exclude nil ("vendor/**" "*.min.js") nil)
                     (fill-column nil 100 nil)
                     (python-indent-offset ((:mode . python-ts-mode)) 4 nil)
                     (fill-column ((:dir . "docs/")) 72 nil)
                     (:eval nil ((add-hook 'before-save-hook #'my-format-buffer nil t)) nil))))))

(ert-deftest drgnx-settings-file/a-syntax-mistake-fails-the-file-with-line-and-column ()
  (drgnx-settings-file-test--with-dir dir
    (let ((f (expand-file-name "settings.el" dir)))
      (drgnx-settings-file-test--put f "(drgnx-settings\n :version 1\n (a 1)))\n")
      (let* ((doc (drgnx-settings-file-read f 'drgnx-settings)) (p (car (drgnx-settings-doc-problems doc))))
        (should (drgnx-settings-doc-failed doc))
        (should (= (length (drgnx-settings-doc-problems doc)) 1))
        (should (equal (list (plist-get p :file) (plist-get p :line) (plist-get p :column)) (list f 3 8)))
        (should-not (drgnx-settings-doc-entries doc)))
      ;; outside the data subset, a wrong head, no :version: each fails the whole file
      (dolist (text (list "(drgnx-settings :version 1 (a `(1)))" "(drgnx-workspace-settings :version 1 (a 1))"
                          "(drgnx-settings (a 1))" "(drgnx-settings :version \"1\" (a 1))" ";; only a comment\n" ""))
        (let ((doc (drgnx-settings-file-parse text 'drgnx-settings)))
          (should (drgnx-settings-doc-failed doc))
          (should (= (length (drgnx-settings-doc-problems doc)) 1))))
      ;; a missing file is an empty doc, not a failure
      (let ((doc (drgnx-settings-file-read (expand-file-name "none.el" dir) 'drgnx-settings)))
        (should-not (drgnx-settings-doc-failed doc))
        (should-not (drgnx-settings-doc-text doc))))))

(ert-deftest drgnx-settings-file/a-bad-entry-fails-alone ()
  (let* ((doc (drgnx-settings-file-parse
               (drgnx-settings-file-test--form "(a 1)" "(b)" "(c 1 2)" "\"str\"" "(\"x\" 1)" "(nil 1)" "(:foo 1)"
                                               "(d 4 :merge lower-only)" "(e 5)")
               'drgnx-settings))
         (problems (drgnx-settings-doc-problems doc)))
    (should-not (drgnx-settings-doc-failed doc))
    (should (equal (drgnx-settings-file-test--facts doc) '((a nil 1 nil) (d nil 4 lower-only) (e nil 5 nil))))
    (should (equal (mapcar (lambda (p) (plist-get p :line)) problems) '(4 5 6 7 8 9)))
    (should (string-match-p "unknown section :foo" (plist-get (nth 5 problems) :text)))))

(ert-deftest drgnx-settings-file/a-dotted-tail-reads-as-huginn-reads-it ()
  ;; As huginn (cases.json "dotted-tails-that-are-lists"): a tail that reads as a list joins it, a quoted one too
  ;; (`quote' then a bad entry); a section with any other tail is one problem, and the rest stands.
  (let* ((doc (drgnx-settings-file-parse
               (drgnx-settings-file-test--form "(a 1)" "(:mode m (b 2) . ((c 3)))" "(:mode n (d 4) . '(e 5))"
                                               "(:mode o (f 6) . x)" "(g 7)")
               'drgnx-settings))
         (problems (drgnx-settings-doc-problems doc)))
    (should-not (drgnx-settings-doc-failed doc))
    (should (equal (drgnx-settings-file-test--facts doc)
                   '((a nil 1 nil) (b ((:mode . m)) 2 nil) (c ((:mode . m)) 3 nil) (d ((:mode . n)) 4 nil)
                     (e ((:mode . n)) 5 nil) (g nil 7 nil))))
    (should (equal (mapcar (lambda (p) (list (plist-get p :line) (plist-get p :text))) problems)
                   '((5 "expected an entry (VARIABLE VALUE)") (6 "expected an entry (VARIABLE VALUE)"))))
    (let ((e (nth 4 (drgnx-settings-doc-entries doc))))
      (should (equal (substring (drgnx-settings-doc-text doc) (1- (drgnx-settings-entry-beg e))
                                (1- (drgnx-settings-entry-end e)))
                     "(e 5)")))))

(ert-deftest drgnx-settings-file/dir-and-eval-refused-in-the-global-file ()
  (let* ((lines '("(a 1)" "(:dir \"docs/\" (fill-column 72))" "(:eval (message \"hi\"))" "(:mode m (:mode n (x 1)))"))
         (global (drgnx-settings-file-parse (apply #'drgnx-settings-file-test--form lines) 'drgnx-settings))
         (ws (drgnx-settings-file-parse
              (replace-regexp-in-string "\\`(drgnx-settings" "(drgnx-workspace-settings"
                                        (apply #'drgnx-settings-file-test--form lines))
              'drgnx-workspace-settings)))
    (should-not (drgnx-settings-doc-failed global))
    (should (equal (drgnx-settings-file-test--facts global) '((a nil 1 nil))))
    (should (equal (mapcar (lambda (p) (plist-get p :text)) (drgnx-settings-doc-problems global))
                   '(":dir is only for workspace files" ":eval is only for workspace files"
                     ":mode cannot sit inside :mode")))
    (should (equal (drgnx-settings-file-test--facts ws)
                   '((a nil 1 nil) (fill-column ((:dir . "docs/")) 72 nil) (:eval nil ((message "hi")) nil))))
    (should (= (length (drgnx-settings-doc-problems ws)) 1))))

(ert-deftest drgnx-settings-file/limits-1mib-and-64kib ()
  (drgnx-settings-file-test--with-dir dir
    (let* ((ws-head 'drgnx-workspace-settings)
           (shared (expand-file-name "proj/.drgnx/settings.el" dir))
           (global (expand-file-name "settings.el" dir))
           (text (lambda (head n) (format "(%s\n :version 1\n (a %S))\n" head (make-string n ?x)))))
      ;; 70 KB: too big for a repository's file, fine for settings.el
      (drgnx-settings-file-test--put shared (funcall text ws-head 70000))
      (let ((doc (drgnx-settings-file-read shared ws-head)))
        (should (drgnx-settings-doc-failed doc))
        (should (equal (plist-get (car (drgnx-settings-doc-problems doc)) :text) "over 65536 bytes")))
      (drgnx-settings-file-test--put global (funcall text 'drgnx-settings 70000))
      (should-not (drgnx-settings-doc-failed (drgnx-settings-file-read global 'drgnx-settings)))
      (drgnx-settings-file-test--put global (funcall text 'drgnx-settings 1100000))
      (should (equal (plist-get (car (drgnx-settings-doc-problems (drgnx-settings-file-read global 'drgnx-settings)))
                                :text)
                     "over 1048576 bytes"))
      ;; the writer never makes a file its reader refuses
      (drgnx-settings-file-test--put shared (funcall text ws-head 60000))
      (let ((before (drgnx-settings-file-test--text shared)))
        (should-error (drgnx-settings-file-put shared ws-head nil 'b (make-string 10000 ?y)) :type 'drgnx-settings-refused)
        (should (equal (drgnx-settings-file-test--text shared) before))))))

(ert-deftest drgnx-settings-file/a-duplicate-is-a-problem-the-first-wins ()
  (drgnx-settings-file-test--with-dir dir
    (let* ((f (expand-file-name "settings.el" dir))
           (text (drgnx-settings-file-test--form "(a 1)" "(b 2)" "(a 3)" "(:mode m (a 5))")))
      (drgnx-settings-file-test--put f text)
      (let ((doc (drgnx-settings-file-read f 'drgnx-settings)))
        (should (equal (drgnx-settings-file-test--facts doc) '((a nil 1 nil) (b nil 2 nil) (a ((:mode . m)) 5 nil))))
        (should (equal (mapcar (lambda (p) (plist-get p :text)) (drgnx-settings-doc-problems doc))
                       '("a is set twice in the same place (lines 3 and 5); the first stands"))))
      ;; the writer removes the duplicate when it next writes the variable
      (let ((doc (drgnx-settings-file-test--put-var f 'a 4)))
        (should-not (drgnx-settings-doc-problems doc))
        (should (equal (drgnx-settings-file-test--text f)
                       (drgnx-settings-file-test--form "(a 4)" "(b 2)" "(:mode m (a 5))")))))))

(ert-deftest drgnx-settings-file/quote-and-function-dropped-once ()
  (drgnx-settings-file-test--with-dir dir
    (let ((f (expand-file-name "settings.el" dir)))
      (drgnx-settings-file-test--put f (drgnx-settings-file-test--form "(a '(1 2))" "(b #'car)" "(c ''x)" "(d (quote y))"))
      (should (equal (drgnx-settings-file-test--facts (drgnx-settings-file-read f 'drgnx-settings))
                     '((a nil (1 2) nil) (b nil car nil) (c nil (quote x) nil) (d nil y nil))))
      ;; the writer writes neither
      (drgnx-settings-file-test--put-var f 'e '(1 2))
      (should (string-search "\n (e (1 2)))" (drgnx-settings-file-test--text f)))
      (should-error (drgnx-settings-file-test--put-var f 'g '(quote x)) :type 'drgnx-settings-refused))))

;;;; Writing: spans, sorted places, comments

(ert-deftest drgnx-settings-file/one-entry-one-span ()
  (drgnx-settings-file-test--with-dir dir
    (let* ((f (expand-file-name "settings.el" dir))
           (old drgnx-settings-file-test--design)
           (swap (lambda (from to text) (replace-regexp-in-string (regexp-quote from) to text t t))))
      (drgnx-settings-file-test--put f old)
      (drgnx-settings-file-test--put-var f 'fill-column 120)
      (should (equal (drgnx-settings-file-test--text f) (funcall swap "(fill-column 100)" "(fill-column 120)" old)))
      (drgnx-settings-file-put f 'drgnx-settings '((:mode . python-ts-mode)) 'fill-column 90)
      (should (equal (drgnx-settings-file-test--text f)
                     (funcall swap "(fill-column 88)" "(fill-column 90)" (funcall swap "(fill-column 100)" "(fill-column 120)" old))))
      (drgnx-settings-file-test--put f old)
      (drgnx-settings-file-remove f 'drgnx-settings nil 'eglot-autoshutdown)
      (should (equal (drgnx-settings-file-test--text f) (funcall swap " (eglot-autoshutdown t)\n" "" old)))
      ;; the same value again writes nothing
      (let ((stamp (drgnx-file-stamp f)))
        (drgnx-settings-file-test--put-var f 'fill-column 100)
        (should (equal (drgnx-file-stamp f) stamp)))
      (should-not (drgnx-settings-file-test--leftovers dir)))))

(ert-deftest drgnx-settings-file/inserts-at-its-sorted-place-in-a-hand-ordered-file ()
  (drgnx-settings-file-test--with-dir dir
    (let ((f (expand-file-name "settings.el" dir)))
      (drgnx-settings-file-test--put f (drgnx-settings-file-test--form "(alpha 1)" ";; about delta" "(delta 3)" "(beta 2)"))
      ;; before the first entry whose name sorts after it, above that entry's comment
      (drgnx-settings-file-test--put-var f 'charlie 9)
      (should (equal (drgnx-settings-file-test--text f)
                     (drgnx-settings-file-test--form "(alpha 1)" "(charlie 9)" ";; about delta" "(delta 3)" "(beta 2)")))
      ;; nothing sorts after it: after the last entry
      (drgnx-settings-file-test--put-var f 'zulu 0)
      (should (equal (drgnx-settings-file-test--text f)
                     (drgnx-settings-file-test--form "(alpha 1)" "(charlie 9)" ";; about delta" "(delta 3)" "(beta 2)"
                                                     "(zulu 0)"))))))

(ert-deftest drgnx-settings-file/sections-sort-after-entries-by-kind-and-name ()
  (drgnx-settings-file-test--with-dir dir
    (let ((f (expand-file-name "proj/.drgnx/settings.el" dir)) (head 'drgnx-workspace-settings))
      (drgnx-settings-file-put f head nil 'b 1)
      (drgnx-settings-file-put f head '((:mode . z-mode)) 'x 1)
      (drgnx-settings-file-put f head '((:dir . "docs/")) 'y 2)
      (drgnx-settings-file-put f head '((:mode . a-mode)) 'x 2)
      (drgnx-settings-file-put f head nil 'a 0)
      (drgnx-settings-file-put f head '((:dir . "docs/") (:mode . m-mode)) 'w 3)
      (drgnx-settings-file-put f head nil 'c 3)
      (should (equal (drgnx-settings-file-test--text f)
                     ";; proj: drgnx workspace settings, shared with the repository  -*- mode: lisp-data -*-
(drgnx-workspace-settings
 :version 1
 (a 0)
 (b 1)
 (c 3)
 (:mode a-mode
  (x 2))
 (:mode z-mode
  (x 1))
 (:dir \"docs/\"
  (y 2)
  (:mode m-mode
   (w 3))))
"))
      ;; a section its last entry leaves goes with it
      (drgnx-settings-file-remove f head '((:dir . "docs/") (:mode . m-mode)) 'w)
      (drgnx-settings-file-remove f head '((:mode . z-mode)) 'x)
      (should (string-suffix-p " (:mode a-mode\n  (x 2))\n (:dir \"docs/\"\n  (y 2)))\n" (drgnx-settings-file-test--text f))))))

(ert-deftest drgnx-settings-file/the-writer-builds-the-design-example ()
  (drgnx-settings-file-test--with-dir dir
    (let ((f (expand-file-name "settings.el" dir)))
      (drgnx-settings-file-test--put-var f 'fill-column 100)
      (drgnx-settings-file-put f 'drgnx-settings '((:mode . python-ts-mode)) 'fill-column 88)
      (drgnx-settings-file-test--put-var f 'eglot-autoshutdown t)
      (drgnx-settings-file-test--put-var f 'drgnx-agents-default "claude")
      (drgnx-settings-file-test--put-var f 'drgnx-trust-parents '(("~/workspace/")))
      (drgnx-settings-file-test--put-var f 'drgnx-keys-layers '((vscode app editing window)))
      (drgnx-settings-file-test--put-var f 'drgnx-agents-profiles
                                         '(("review" :command ("claude-agent-acp") :mode queue :model "opus" :doc "Reviews")))
      (should (equal (drgnx-settings-file-test--text f)
                     (replace-regexp-in-string " ;; the review profile reads every project\n" ""
                                               drgnx-settings-file-test--design t t))))))

(ert-deftest drgnx-settings-file/sort-file-sorts-and-keeps-every-comment ()
  (drgnx-settings-file-test--with-dir dir
    (let ((f (expand-file-name "settings.el" dir)))
      (drgnx-settings-file-test--put f (drgnx-settings-file-test--form ";; about zeta" "(zeta 1) ; z" "(:mode b-mode"
                                                                       " (y 2)" " (x 1))" "(alpha 2)" ";; loose comment"
                                                                       "" "(:mode a-mode (k 1))"))
      (drgnx-settings-file-sort f 'drgnx-settings)
      (should (equal (drgnx-settings-file-test--text f)
                     (drgnx-settings-file-test--form "(alpha 2)" ";; about zeta" "(zeta 1) ; z" "(:mode a-mode (k 1))"
                                                     ";; loose comment" "" "(:mode b-mode" " (x 1)" " (y 2))")))
      (let ((stamp (drgnx-file-stamp f)))
        (drgnx-settings-file-sort f 'drgnx-settings)       ; sorted: nothing is written
        (should (equal (drgnx-file-stamp f) stamp))))
    (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
      (drgnx-config-register-commands)
      (let ((cmd (drgnx-commands-get 'settings-sort-file)))
        (should (equal (list (drgnx-cmd-category cmd) (drgnx-cmd-title cmd)) '("Settings" "Sort File")))
        (should (commandp (drgnx-cmd-command cmd)))))))

(ert-deftest drgnx-settings-file/comments-travel-with-their-entry ()
  (drgnx-settings-file-test--with-dir dir
    (let* ((f (expand-file-name "settings.el" dir))
           (old (drgnx-settings-file-test--form "(a 1)" ";; about b" ";; more about b" "(b 2) ; trailing b" "(c 3)")))
      (drgnx-settings-file-test--put f old)
      (drgnx-settings-file-test--put-var f 'b 5)
      (should (equal (drgnx-settings-file-test--text f) (replace-regexp-in-string "(b 2)" "(b 5)" old t t)))
      (drgnx-settings-file-remove f 'drgnx-settings nil 'b)
      (should (equal (drgnx-settings-file-test--text f) (drgnx-settings-file-test--form "(a 1)" "(c 3)")))
      (drgnx-settings-file-remove f 'drgnx-settings nil 'c)
      (should (equal (drgnx-settings-file-test--text f) (drgnx-settings-file-test--form "(a 1)"))))))

(ert-deftest drgnx-settings-file/a-comment-inside-a-replaced-value-is-lost-and-documented ()
  (drgnx-settings-file-test--with-dir dir
    (let ((f (expand-file-name "settings.el" dir)))
      (drgnx-settings-file-test--put f (drgnx-settings-file-test--form ";; kept" "(b (1 ; one" "    2)) ; kept too" "(c 1)"))
      (drgnx-settings-file-test--put-var f 'b '(3))
      (should (equal (drgnx-settings-file-test--text f)
                     (drgnx-settings-file-test--form ";; kept" "(b (3)) ; kept too" "(c 1)")))))
  (should (string-search "lost when drgnx replaces that value"
                         (drgnx-settings-file-test--text (expand-file-name "docs/guide/settings.md" drgnx-dir)))))

;;;; Printing

(ert-deftest drgnx-settings-file/printing-is-deterministic ()
  (let ((v '(("review" :command ("claude-agent-acp") :mode queue :model "opus" :doc "Reviews"))))
    (should (equal (drgnx-settings-print v 2) (drgnx-settings-print (copy-tree v) 2)))
    (should (equal (drgnx-settings-print v 2) (let ((print-quoted nil) (print-escape-newlines nil))
                                                (drgnx-settings-print v 2)))))
  (should (equal (drgnx-settings-print "a\nb" 0) "\"a\\nb\""))
  (should (equal (drgnx-settings-print "é ü" 0) "\"é ü\""))
  ;; 100 columns stay on one line; 101 break before each keyword
  (let ((at-100 (list :alpha (make-string 40 ?a) :beta (make-string 40 ?b)))
        (at-101 (list :alpha (make-string 40 ?a) :beta (make-string 41 ?b))))
    (should (= (length (drgnx-settings-print at-100 0)) 100))
    (should-not (string-search "\n" (drgnx-settings-print at-100 0)))
    (should (equal (drgnx-settings-print at-101 0)
                   (format "(:alpha %S\n :beta %S)" (make-string 40 ?a) (make-string 41 ?b)))))
  ;; an alist breaks per element; nested lists one column in
  (let ((k (make-string 50 ?k)) (w (make-string 50 ?w)))
    (should (equal (drgnx-settings-print (list (cons "a" k) (cons "b" w)) 4)
                   (format "((\"a\" . %S)\n     (\"b\" . %S))" k w)))
    (should (equal (drgnx-settings-print (list (list :x k :y 1) (list :x w :y 2)) 0)
                   (format "((:x %S :y 1)\n (:x %S :y 2))" k w)))))

(ert-deftest drgnx-settings-file/a-user-print-length-still-writes-in-full ()
  (drgnx-settings-file-test--with-dir dir
    (let ((f (expand-file-name "settings.el" dir)))
      (let ((print-length 2) (print-level 1) (print-escape-newlines nil))
        (drgnx-settings-file-test--put-var f 'x '(1 2 3 4 (5 (6)) "a\nb")))
      (should (string-search "(x (1 2 3 4 (5 (6)) \"a\\nb\"))" (drgnx-settings-file-test--text f)))
      (should (equal (drgnx-settings-file-test--facts (drgnx-settings-file-read f 'drgnx-settings))
                     '((x nil (1 2 3 4 (5 (6)) "a\nb") nil)))))))

(ert-deftest drgnx-settings-file/a-unibyte-value-is-refused ()
  (drgnx-settings-file-test--with-dir dir
    (let ((f (expand-file-name "settings.el" dir)))
      (drgnx-settings-file-test--put f (drgnx-settings-file-test--form "(a 1)"))
      (let ((before (drgnx-settings-file-test--text f)))
        (dolist (v (list (unibyte-string 233) (string-to-multibyte (unibyte-string 233)) (list 1 (unibyte-string 255))))
          (should-error (drgnx-settings-print v 0) :type 'drgnx-settings-refused)
          (should-error (drgnx-settings-file-test--put-var f 'b v) :type 'drgnx-settings-refused))
        (should (equal (drgnx-settings-file-test--text f) before))))))

(ert-deftest drgnx-settings-file/an-unprintable-value-is-refused ()
  (drgnx-settings-file-test--with-dir dir
    (let ((f (expand-file-name "settings.el" dir)) (m (point-marker)) (circular (list 1 2)))
      (setcdr (cdr circular) circular)
      (drgnx-settings-file-test--put f (drgnx-settings-file-test--form "(a 1)"))
      (let ((before (drgnx-settings-file-test--text f)))
        (unwind-protect
            (dolist (v (list (current-buffer) m (list 1 (vector m)) (propertize "x" 'face 'bold) circular))
              (should-error (drgnx-settings-file-test--put-var f 'b v) :type 'drgnx-settings-refused))
          (set-marker m nil))
        (should (equal (drgnx-settings-file-test--text f) before))))))

;;;; Refusals

(ert-deftest drgnx-settings-file/the-read-back-check-refuses-a-mismatch ()
  (drgnx-settings-file-test--with-dir dir
    (let ((f (expand-file-name "settings.el" dir)) (print (symbol-function 'drgnx-settings-print)))
      (drgnx-settings-file-test--put f (drgnx-settings-file-test--form "(a 1)"))
      (let ((before (drgnx-settings-file-test--text f)))
        (cl-letf (((symbol-function 'drgnx-settings-print)  ; a printer that drops an element
                   (lambda (v c) (funcall print (if (consp v) (cdr v) v) c))))
          (let ((err (should-error (drgnx-settings-file-test--put-var f 'b '(1 2 3)) :type 'drgnx-settings-refused)))
            (should (string-match-p "does not read back as meant" (cadr err)))))
        (should (equal (drgnx-settings-file-test--text f) before))
        (should-not (drgnx-settings-file-test--leftovers dir))))))

(ert-deftest drgnx-settings-file/a-failed-file-refuses-writes ()
  (drgnx-settings-file-test--with-dir dir
    (let ((f (expand-file-name "settings.el" dir)))
      (dolist (case '(("(drgnx-settings\n :version 1\n (a 1)))\n" . "mistake at line 3")
                      ("(drgnx-workspace-settings\n :version 1)\n" . "mistake at line 1: expected the head")))
        (drgnx-settings-file-test--put f (car case))
        (let ((err (should-error (drgnx-settings-file-test--put-var f 'b 2) :type 'drgnx-settings-refused)))
          (should (string-match-p (cdr case) (cadr err))))
        (should-error (drgnx-settings-file-remove f 'drgnx-settings nil 'a) :type 'drgnx-settings-refused)
        (should-error (drgnx-settings-file-sort f 'drgnx-settings) :type 'drgnx-settings-refused)
        (should (equal (drgnx-settings-file-test--text f) (car case))))
      ;; a file holding only comments takes the form after them
      (drgnx-settings-file-test--put f ";; mine\n")
      (drgnx-settings-file-test--put-var f 'b 2)
      (should (equal (drgnx-settings-file-test--text f) (concat ";; mine\n" (drgnx-settings-file-test--form "(b 2)")))))))

(ert-deftest drgnx-settings-file/a-newer-version-refuses-writes ()
  (drgnx-settings-file-test--with-dir dir
    (let ((f (expand-file-name "settings.el" dir)) (text "(drgnx-settings\n :version 2\n (a 1))\n"))
      (drgnx-settings-file-test--put f text)
      (should (equal (plist-get (car (drgnx-settings-doc-problems (drgnx-settings-file-read f 'drgnx-settings))) :text)
                     "version 2 was written by a newer drgnx"))
      (let ((err (should-error (drgnx-settings-file-test--put-var f 'b 2) :type 'drgnx-settings-refused)))
        (should (string-match-p "written by a newer drgnx: update drgnx here" (cadr err))))
      (should (equal (drgnx-settings-file-test--text f) text)))))

(ert-deftest drgnx-settings-file/a-modified-visiting-buffer-refuses ()
  (drgnx-settings-file-test--with-dir dir
    (let ((f (expand-file-name "settings.el" dir)) (enable-local-variables nil))
      (drgnx-settings-file-test--put f (drgnx-settings-file-test--form "(a 1)"))
      (let ((before (drgnx-settings-file-test--text f)) (buf (find-file-noselect f)))
        (unwind-protect
            (progn
              (with-current-buffer buf (goto-char (point-max)) (insert ";; an edit\n"))
              (let ((err (should-error (drgnx-settings-file-test--put-var f 'b 2) :type 'drgnx-settings-refused)))
                (should (equal (cadr err) "settings.el has unsaved edits in a buffer; save or revert it first")))
              (should (equal (drgnx-settings-file-test--text f) before)))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest drgnx-settings-file/an-unmodified-visiting-buffer-is-reverted ()
  (drgnx-settings-file-test--with-dir dir
    (let ((f (expand-file-name "settings.el" dir)) (enable-local-variables nil) (seen nil))
      (drgnx-settings-file-test--put f (drgnx-settings-file-test--form "(a 1)"))
      (let ((buf (find-file-noselect f))
            (drgnx-settings-file-written-functions
             (list (lambda (file before after)
                     (push (list file (length (drgnx-settings-doc-entries before))
                                 (length (drgnx-settings-doc-entries after)))
                           seen)))))
        (unwind-protect
            (let ((inhibit-interaction t))
              (drgnx-settings-file-test--put-var f 'b 2)
              (with-current-buffer buf
                (should (equal (buffer-string) (drgnx-settings-file-test--form "(a 1)" "(b 2)")))
                (should-not (buffer-modified-p)))
              (should (equal seen (list (list f 1 2)))))
          (kill-buffer buf))))))

;;;; The config layer and the last good copy

(ert-deftest drgnx-settings-file/the-config-layer-reads-the-settings-shape ()
  (drgnx-test-with-config
    (should (equal (file-name-nondirectory (drgnx-config-file 'settings)) "settings.el"))
    (should (eq (plist-get (drgnx-config-read 'settings) :status) 'absent))
    (dolist (case `((,(drgnx-settings-file-test--form "(a 1)") ok)
                    ("(drgnx-settings\n :version 2)\n" problem)
                    (";; only comments\n" problem)
                    ("(drgnx-workspace-settings :version 1)\n" problem)))
      (drgnx-test-config-put 'settings (car case))
      (should (eq (plist-get (drgnx-config-read 'settings) :status) (cadr case))))
    (should-error (drgnx-config-set 'settings :a 1))))

(ert-deftest drgnx-settings-file/the-state-gives-the-last-good-copy ()
  (drgnx-test-with-config
    (let ((f (drgnx-config-file 'settings)))
      (drgnx-test-config-put 'settings (drgnx-settings-file-test--form "(a 1)" "(b 2)"))
      (let ((st (drgnx-settings-file-state f 'drgnx-settings)))
        (should-not (plist-get st :problem))
        (should (equal (drgnx-settings-file-test--facts (plist-get st :last-good)) '((a nil 1 nil) (b nil 2 nil)))))
      (drgnx-test-config-put 'settings "(drgnx-settings\n :version 1\n (a 1\n")
      (let ((st (drgnx-settings-file-state f 'drgnx-settings)))
        (should (drgnx-settings-doc-failed (plist-get st :doc)))
        (should (equal (plist-get (plist-get st :problem) :file) f))
        (should (equal (drgnx-settings-file-test--facts (plist-get st :last-good)) '((a nil 1 nil) (b nil 2 nil))))
        (should (equal (drgnx-settings-doc-file (plist-get st :last-good)) (drgnx-config-last-good-file 'settings))))
      ;; a file that is not the config layer's has none
      (should-not (plist-get (drgnx-settings-file-state (expand-file-name "other/settings.el" drgnx-test-config-root)
                                                        'drgnx-settings)
                             :last-good)))))

;;;; Two writers

(ert-deftest drgnx-settings-file/two-emacsen-add-100-each ()
  (drgnx-settings-file-test--with-dir dir
    (let* ((f (expand-file-name "settings.el" dir))
           (core (file-name-directory (locate-library "drgnx-settings-file")))
           (at (+ (float-time) 2)) (outs nil)
           (start (lambda (tag)
                    (let ((b (generate-new-buffer " *drgnx-settings-file-child*" t)))
                      (push b outs)
                      (make-process
                       :name tag :buffer b :noquery t
                       :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                      "--eval" "(setq load-prefer-newer t)" "-L" core "-l" "drgnx-settings-file"
                                      "--eval"
                                      (format "(progn (setq drgnx-settings-file-lock-timeout 30)
                                                      (sleep-for (max 0 (- %f (float-time))))
                                                      (dotimes (i 100)
                                                        (drgnx-settings-file-put %S 'drgnx-settings nil (intern (format \"%s-%%03d\" i)) i))
                                                      (princ \"DONE\\n\"))"
                                              at f tag))))))
           (procs (list (funcall start "a") (funcall start "b"))))
      (let ((deadline (+ (float-time) 90)))
        (while (and (cl-some #'process-live-p procs) (< (float-time) deadline)) (accept-process-output nil 0.05)))
      (unwind-protect
          (progn
            (should (cl-every (lambda (p) (and (not (process-live-p p)) (= (process-exit-status p) 0))) procs))
            (dolist (b outs) (should (string-match-p "DONE" (with-current-buffer b (buffer-string)))))
            (let* ((doc (drgnx-settings-file-read f 'drgnx-settings))
                   (names (mapcar (lambda (e) (symbol-name (drgnx-settings-entry-var e))) (drgnx-settings-doc-entries doc))))
              (should-not (drgnx-settings-doc-problems doc))
              (should (= (length names) 200))
              (should (equal names (sort (copy-sequence names) #'string<))))
            (should-not (drgnx-settings-file-test--leftovers dir)))
        (mapc #'delete-process procs)
        (mapc #'kill-buffer outs)))))

;;; settings-file-test.el ends here
