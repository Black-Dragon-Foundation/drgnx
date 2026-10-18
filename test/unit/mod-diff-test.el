;;; mod-diff-test.el --- batch tests: the diff view — split or unified, folding, jumping, git in the background -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/git-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-diff" drgnx-dir) nil t)

(defconst drgnx-diff-test--two-files
  "diff --git a/src/a.el b/src/a.el
index 111..222 100644
--- a/src/a.el
+++ b/src/a.el
@@ -1,3 +1,3 @@
 one
-two
+TWO
 three
diff --git a/old.txt b/new.txt
similarity index 90%
rename from old.txt
rename to new.txt
index 333..444 100644
--- a/old.txt
+++ b/new.txt
@@ -1 +1 @@
-x
+y
")

(defconst drgnx-diff-test--pair
  "diff --git a/f b/f
--- a/f
+++ b/f
@@ -1,3 +1,2 @@
-a
-b
+c
 d
")

(defconst drgnx-diff-test--awkward
  "diff --git a/f.bin b/f.bin
index 1..2 100644
Binary files a/f.bin and b/f.bin differ
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
index 1..0000000
--- a/gone.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-a
-b
diff --git a/nl.txt b/nl.txt
--- a/nl.txt
+++ b/nl.txt
@@ -1 +1 @@
-old
\\ No newline at end of file
+new
\\ No newline at end of file
diff --git a/dir with space/f.txt b/dir with space/f.txt
new file mode 100644
--- /dev/null
+++ b/dir with space/f.txt\t
@@ -0,0 +1 @@
+hi
")

(defun drgnx-diff-test--hunk-file (path start n)
  "A diff of PATH: one hunk at new line START, N context lines with a change in the middle."
  (concat (format "diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -%d,%d +%d,%d @@\n" path path path path start n start n)
          (mapconcat (lambda (i) (if (= i (/ n 2)) (format "-old %d\n+new %d\n" i i) (format " ctx %d\n" i)))
                     (number-sequence 0 (1- n)) "")))

(defmacro drgnx-diff-test--in (text layout &rest body)
  "BODY in a diff buffer showing TEXT in LAYOUT, 120 columns wide."
  (declare (indent 2))
  `(with-temp-buffer
     (drgnx-diff-mode)
     (setq drgnx-diff--width 120 drgnx-diff-layout ,layout drgnx-diff--files (drgnx-diff-parse ,text))
     (drgnx-diff--render)
     (goto-char (point-min))
     ,@body))

(defun drgnx-diff-test--render (text layout)
  (drgnx-diff-test--in text layout (buffer-string)))

(defun drgnx-diff-test--visible ()
  "The buffer's text that is not invisible."
  (let ((out nil) (p (point-min)))
    (while (< p (point-max))
      (let ((next (next-single-char-property-change p 'invisible)))
        (unless (invisible-p p) (push (buffer-substring-no-properties p next) out))
        (setq p next)))
    (apply #'concat (nreverse out))))

(defun drgnx-diff-test--goto-line-of (index line)
  "Point to the first row whose location is new LINE of file INDEX."
  (goto-char (point-min))
  (let ((m (text-property-search-forward 'drgnx-diff-loc nil
                                         (lambda (_ loc) (and loc (= (nth 0 loc) index) (eql (nth 2 loc) line))))))
    (should m)
    (goto-char (prop-match-beginning m))))

(defun drgnx-diff-test--wait (buf)
  (let ((deadline (+ (float-time) 10)))
    (while (and (buffer-local-value 'drgnx-diff--proc buf) (< (float-time) deadline)) (accept-process-output nil 0.05))))

(ert-deftest drgnx-diff/parse-files-and-hunks ()
  (let ((files (drgnx-diff-parse drgnx-diff-test--two-files)))
    (should (= 2 (length files)))
    (should (equal (plist-get (car files) :new) "src/a.el"))
    (should (eq (plist-get (car files) :status) 'modified))
    (let ((h (car (plist-get (car files) :hunks))))
      (should (equal (list (plist-get h :old-start) (plist-get h :old-len) (plist-get h :new-start) (plist-get h :new-len)) '(1 3 1 3)))
      (should (equal (mapcar #'car (plist-get h :lines)) '(?\s ?- ?+ ?\s))))
    (should (eq (plist-get (cadr files) :status) 'renamed))
    (should (equal (list (plist-get (cadr files) :old) (plist-get (cadr files) :new)) '("old.txt" "new.txt")))))

(ert-deftest drgnx-diff/a-removed-dash-line-stays-in-its-hunk ()
  ;; SQL's "-- note" removed reads "--- note": the hunk's counts keep it a line, not a file header
  (let* ((files (drgnx-diff-parse "diff --git a/q.sql b/q.sql\n--- a/q.sql\n+++ b/q.sql\n@@ -1,2 +1,1 @@\n--- note\n select 1;\n"))
         (lines (plist-get (car (plist-get (car files) :hunks)) :lines)))
    (should (equal (plist-get (car files) :old) "q.sql"))
    (should (equal lines '((?- . "-- note") (?\s . "select 1;"))))))

(ert-deftest drgnx-diff/split-pairs-removed-and-added-lines ()
  (let ((s (drgnx-diff-test--render drgnx-diff-test--pair 'split)))
    (should (string-match-p "1 a +│ +1 c" s))
    (should (string-match-p "2 b +│ *$" s))
    (should (string-match-p "3 d +│ +2 d" s))
    (should-not (seq-some (lambda (l) (> (string-width l) 120)) (split-string s "\n")))))

(ert-deftest drgnx-diff/unified-shows-the-lines-with-their-faces ()
  (drgnx-diff-test--in drgnx-diff-test--two-files 'unified
    (should (search-forward "+TWO" nil t))
    (should (memq 'diff-added (ensure-list (get-text-property (match-beginning 0) 'face))))
    (should (search-forward "old.txt → new.txt" nil t))))

(ert-deftest drgnx-diff/toggle-keeps-the-place ()
  (drgnx-diff-test--in (concat (drgnx-diff-test--hunk-file "a.txt" 1 10) (drgnx-diff-test--hunk-file "b.txt" 30 20)) 'unified
    (drgnx-diff-test--goto-line-of 1 40)
    (drgnx-diff-toggle-layout)
    (should (eq drgnx-diff-layout 'split))
    (should (string-search " │ " (buffer-string)))
    (let ((loc (get-text-property (point) 'drgnx-diff-loc))) (should (equal (list (nth 0 loc) (nth 2 loc)) '(1 40))))
    (drgnx-diff-toggle-layout)
    (should (eq drgnx-diff-layout 'unified))
    (let ((loc (get-text-property (point) 'drgnx-diff-loc))) (should (equal (list (nth 0 loc) (nth 2 loc)) '(1 40))))))

(ert-deftest drgnx-diff/collapse-expand-and-big-files-start-folded ()
  (drgnx-diff-test--in drgnx-diff-test--two-files 'unified
    (drgnx-diff-collapse-all)
    (let ((v (drgnx-diff-test--visible)))
      (should (string-search "src/a.el" v))
      (should (string-search "new.txt" v))
      (should-not (string-search "TWO" v)))
    (drgnx-diff-expand-all)
    (should (string-search "TWO" (drgnx-diff-test--visible))))
  (let ((drgnx-diff-fold-lines 2000))
    (drgnx-diff-test--in (concat (drgnx-diff-test--hunk-file "small.txt" 1 4) (drgnx-diff-test--hunk-file "big.txt" 1 3000)) 'unified
      (should (string-search "new 2" (buffer-string)))
      (should-not (string-search "ctx 2999" (buffer-string)))        ; not even rendered
      (search-forward "big.txt")
      (drgnx-diff-toggle-file)
      (should (string-search "ctx 2999" (drgnx-diff-test--visible))))))

(ert-deftest drgnx-diff/next-and-previous-file ()
  (drgnx-diff-test--in drgnx-diff-test--two-files 'unified
    (drgnx-diff-next-file)
    (should (= 1 (nth 0 (get-text-property (point) 'drgnx-diff-loc))))
    (drgnx-diff-prev-file)
    (should (= 0 (nth 0 (get-text-property (point) 'drgnx-diff-loc))))))

(ert-deftest drgnx-diff/visit-opens-the-new-file-at-the-line ()
  (drgnx-git-test-with-repo
    (drgnx-git-test-write repo "b.txt" (mapconcat (lambda (i) (format "line %d\n" i)) (number-sequence 1 20) ""))
    (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "b")
    (drgnx-git-test-write repo "b.txt" (mapconcat (lambda (i) (format (if (= i 12) "LINE %d\n" "line %d\n") i)) (number-sequence 1 20) ""))
    (let ((buf (drgnx-diff-show 'working repo)))
      (unwind-protect
          (with-current-buffer buf
            (drgnx-diff-test--wait buf)
            (drgnx-diff-test--goto-line-of 0 12)
            (should (looking-at-p ".*LINE 12"))
            (drgnx-diff-visit)
            (should (equal (buffer-file-name) (expand-file-name "b.txt" repo)))
            (should (= (line-number-at-pos) 12)))
        (kill-buffer buf)))))

(ert-deftest drgnx-diff/awkward-files-render-and-jump ()
  (dolist (layout '(unified split))
    (let ((s (drgnx-diff-test--render drgnx-diff-test--awkward layout)))
      (dolist (h '("f.bin (binary)" "gone.txt (deleted)" "nl.txt" "dir with space/f.txt (new)"))
        (should (string-search h s)))
      (should (string-search "No newline at end of file" s))))
  (let ((root (file-name-as-directory (make-temp-file "drgnx-diff" t))))
    (unwind-protect
        (progn
          (make-directory (concat root "dir with space") t)
          (write-region "hi\n" nil (concat root "dir with space/f.txt") nil 'silent)
          (drgnx-diff-test--in drgnx-diff-test--awkward 'unified
            (setq drgnx-diff--root root)
            (search-forward "gone.txt (deleted)") (forward-line 2)
            (should (string-match-p "deleted" (cadr (should-error (drgnx-diff-visit) :type 'user-error))))
            (drgnx-diff-test--goto-line-of 3 1)
            (let ((b (current-buffer)))
              (drgnx-diff-visit)
              (should (equal (buffer-file-name) (concat root "dir with space/f.txt")))
              (kill-buffer) (set-buffer b))))
      (delete-directory root t))))

(ert-deftest drgnx-diff/sources-run-git-asynchronously ()
  (drgnx-git-test-with-repo
    (drgnx-git-test-write repo "a.txt" "one\n")
    (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "a")
    (drgnx-git-test-write repo "a.txt" "two\n")
    (let ((buf (drgnx-diff-show 'working repo)))
      (unwind-protect
          (progn
            (should (string-search "Loading…" (with-current-buffer buf (buffer-string))))
            (drgnx-diff-show 'working repo)                       ; again at once: the first git goes
            (should (<= (seq-count (lambda (p) (and (process-live-p p) (eq (process-type p) 'real) (string-prefix-p "drgnx-diff" (process-name p)))) (process-list)) 1))
            (drgnx-diff-test--wait buf)
            (should (string-search "a.txt" (with-current-buffer buf (buffer-string))))
            (should (string-search "two" (with-current-buffer buf (buffer-string)))))
        (kill-buffer buf)))
    (drgnx-git-test repo "add" "-A")
    (let ((buf (drgnx-diff-show 'staged repo)))
      (unwind-protect (progn (drgnx-diff-test--wait buf) (should (string-search "two" (with-current-buffer buf (buffer-string)))))
        (kill-buffer buf)))))

(ert-deftest drgnx-diff/default-base ()
  (drgnx-git-test-with-repo
    (drgnx-git-test-write repo "a" "a\n")
    (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "a")
    (should (equal (drgnx-diff-default-base repo) "main"))
    (drgnx-git-test repo "branch" "-m" "master")
    (should (equal (drgnx-diff-default-base repo) "master"))
    (drgnx-git-test repo "branch" "-m" "trunk")
    (should-not (drgnx-diff-default-base repo))
    (drgnx-git-test repo "update-ref" "refs/remotes/origin/main" "HEAD")
    (drgnx-git-test repo "symbolic-ref" "refs/remotes/origin/HEAD" "refs/remotes/origin/main")
    (should (equal (drgnx-diff-default-base repo) "origin/main"))))

(ert-deftest drgnx-diff/a-10k-line-diff-renders-fast ()
  :tags '(:timing)                                      ; wall-clock: a quiet machine
  (let ((text (drgnx-diff-test--hunk-file "big.txt" 1 10000)) (drgnx-diff-fold-lines most-positive-fixnum))
    (dolist (layout '(unified split))
      (let ((t0 (float-time)))
        (drgnx-diff-test--in text layout (should (string-search "ctx 9999" (buffer-string))))
        (should (< (- (float-time) t0) 0.5))))))

;; review fixes (M11b final review)
(ert-deftest drgnx-diff/view-commands-never-touch-another-buffer ()
  ;; C1: palette-only commands run from a file buffer: an error, the text kept
  (with-temp-buffer
    (emacs-lisp-mode) (insert "(keep me)")
    (dolist (cmd '(drgnx-diff-toggle-layout drgnx-diff-collapse-all drgnx-diff-expand-all drgnx-diff-toggle-file
                                            drgnx-diff-next-file drgnx-diff-prev-file drgnx-diff-visit))
      (should-error (funcall cmd) :type 'user-error)
      (should (equal (buffer-string) "(keep me)")))))

(ert-deftest drgnx-diff/prefix-settings-never-change-the-paths ()
  ;; I2: diff.mnemonicPrefix / diff.noprefix in the repository's config
  (drgnx-git-test-with-repo
    (drgnx-git-test-write repo "a.txt" "one\n")
    (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "a")
    (drgnx-git-test-write repo "a.txt" "two\n")
    (dolist (setting '(("diff.mnemonicPrefix" "true") ("diff.noprefix" "true")))
      (apply #'drgnx-git-test repo "config" setting)
      (let ((buf (drgnx-diff-show 'working repo)))
        (unwind-protect
            (progn (drgnx-diff-test--wait buf)
                   (should (equal (plist-get (car (buffer-local-value 'drgnx-diff--files buf)) :new) "a.txt")))
          (kill-buffer buf)))
      (drgnx-git-test repo "config" "--unset" (car setting)))))

;; deferred pass (M11b-1..)
(ert-deftest drgnx-diff/parse-deleted-binary-keeps-deleted ()
  (let* ((files (drgnx-diff-parse
                 (concat "diff --git a/gone.bin b/gone.bin\ndeleted file mode 100644\nindex 1..0000000\n"
                         "Binary files a/gone.bin and /dev/null differ\n"
                         "diff --git a/new.bin b/new.bin\nnew file mode 100644\nindex 0000000..1\n"
                         "Binary files /dev/null and b/new.bin differ\n")))
         (gone (car files)) (new (cadr files)))
    (should (eq (plist-get gone :status) 'deleted))
    (should (plist-get gone :binary))
    (should-not (plist-get gone :new))
    (should (equal (plist-get gone :old) "gone.bin"))
    (should (eq (plist-get new :status) 'added))
    (should (plist-get new :binary))
    (should-not (plist-get new :old))
    (let ((s (drgnx-diff-test--render (concat "diff --git a/gone.bin b/gone.bin\ndeleted file mode 100644\n"
                                              "Binary files a/gone.bin and /dev/null differ\n")
                                      'unified)))
      (should (string-search "gone.bin (deleted, binary)" s)))
    ;; a deleted binary file has no new path to open
    (drgnx-diff-test--in "diff --git a/gone.bin b/gone.bin\ndeleted file mode 100644\nBinary files a/gone.bin and /dev/null differ\n" 'unified
      (should (string-match-p "deleted" (cadr (should-error (drgnx-diff-visit) :type 'user-error)))))))

;;; mod-diff-test.el ends here
