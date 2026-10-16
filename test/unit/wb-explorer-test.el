;;; wb-explorer-test.el --- batch tests: the Explorer -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-explorer)

(defun drgnx-explorer-test--tree (root paths)
  "Create PATHS under ROOT (a trailing / makes a directory)."
  (dolist (p paths)
    (let ((f (expand-file-name p root)))
      (if (string-suffix-p "/" p) (make-directory f t)
        (make-directory (file-name-directory f) t)
        (write-region "" nil f nil 'silent)))))

(defmacro drgnx-explorer-test--with (root &rest body)
  "BODY with a fixture ROOT, the Explorer rooted there, shown in the dock of a one-editor layout."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-explorer" t)))
          (drgnx-wb--sections nil) (drgnx-signal--editor-window nil) (drgnx-explorer--pressed nil))
     (unwind-protect
         (progn
           (drgnx-explorer-test--tree ,root '("README.md" "docs/guide.md" "src/app/main.py" "src/app/util.py"
                                               "src/app/deep/a/b/c/leaf.txt" "tests/test_main.py"))
           (delete-other-windows)
           (drgnx-explorer-setup)
           (drgnx-explorer-set-roots (list ,root))
           ,@body)
       (drgnx-wb-hide-sidebar)
       (delete-other-windows)
       (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
       (delete-directory ,root t))))

(defun drgnx-explorer-test--rows ()
  "The Explorer's rows as (DEPTH NAME) lists."
  (with-current-buffer drgnx-explorer-buffer-name
    (save-excursion
      (goto-char (point-min))
      (let (rows)
        (while (not (eobp))
          (when-let* ((node (get-text-property (point) 'drgnx-node)))
            (push (list (get-text-property (point) 'drgnx-depth)
                        (file-name-nondirectory (directory-file-name node)))
                  rows))
          (forward-line 1))
        (nreverse rows)))))

(defun drgnx-explorer-test--goto (name)
  "Point (in the Explorer buffer) to the row of NAME; return the position."
  (with-current-buffer drgnx-explorer-buffer-name
    (goto-char (point-min))
    (while (and (not (eobp))
                (not (equal name (file-name-nondirectory (directory-file-name (or (get-text-property (point) 'drgnx-node) ""))))))
      (forward-line 1))
    (point)))

(ert-deftest drgnx-explorer/children-sorted-and-filtered ()
  (let ((root (make-temp-file "drgnx-explorer" t)))
    (unwind-protect
        (progn
          (drgnx-explorer-test--tree root '("b.txt" "a.txt" "file10" "file2" "Zdir/" "beta/" ".git/" "B2.md"))
          (should (equal (mapcar #'car (drgnx-explorer-children root))
                         '("beta" "Zdir" "a.txt" "b.txt" "B2.md" "file2" "file10")))
          (should (equal (mapcar #'cdr (drgnx-explorer-children root)) '(t t nil nil nil nil nil))))
      (delete-directory root t))))

(ert-deftest drgnx-explorer/root-and-first-level ()
  (drgnx-explorer-test--with root
    (should (equal (drgnx-explorer-test--rows)
                   `((0 ,(file-name-nondirectory (directory-file-name root)))
                     (1 "docs") (1 "src") (1 "tests") (1 "README.md"))))))

(ert-deftest drgnx-explorer/expand-and-collapse-in-place ()
  (drgnx-explorer-test--with root
    (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "src"))
    (should (equal (seq-take (cddr (drgnx-explorer-test--rows)) 3) '((1 "src") (2 "app") (1 "tests"))))
    (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "app"))
    (should (member '(3 "main.py") (drgnx-explorer-test--rows)))
    ;; Collapsing src hides app's rows; expanding src again shows app still expanded.
    (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "src"))
    (should-not (member '(3 "main.py") (drgnx-explorer-test--rows)))
    (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "src"))
    (should (member '(3 "main.py") (drgnx-explorer-test--rows)))
    (with-current-buffer drgnx-explorer-buffer-name
      (goto-char (drgnx-explorer-test--goto "src"))
      (should (string-search "▾" (buffer-substring (pos-bol) (pos-eol))))
      (goto-char (drgnx-explorer-test--goto "docs"))
      (should (string-search "▸" (buffer-substring (pos-bol) (pos-eol)))))))

(ert-deftest drgnx-explorer/reveal-expands-ancestors ()
  (drgnx-explorer-test--with root
    (drgnx-wb-show-sidebar)
    (let ((w (drgnx-wb-section-window 'explorer)))
      (should (drgnx-explorer-reveal (expand-file-name "src/app/deep/a/b/c/leaf.txt" root) w))
      (should (member '(7 "leaf.txt") (drgnx-explorer-test--rows)))
      (should (equal (with-current-buffer drgnx-explorer-buffer-name (get-text-property (window-point w) 'drgnx-node))
                     (expand-file-name "src/app/deep/a/b/c/leaf.txt" root)))
      ;; Outside the roots: nothing changes.
      (let ((rows (drgnx-explorer-test--rows)))
        (should-not (drgnx-explorer-reveal "/etc/hosts" w))
        (should (equal rows (drgnx-explorer-test--rows)))))))

(ert-deftest drgnx-explorer/the-follower-never-moves-a-busy-explorer ()
  (drgnx-explorer-test--with root
    (drgnx-wb-show-sidebar)
    (let* ((w (drgnx-wb-section-window 'explorer))
           (main (find-file-noselect (expand-file-name "src/app/main.py" root)))
           (on-main (lambda () (equal (with-current-buffer drgnx-explorer-buffer-name
                                        (get-text-property (window-point w) 'drgnx-node))
                                      (buffer-file-name main)))))
      (unwind-protect
          (progn
            ;; The Explorer is selected (the user is in it): no reveal.
            (select-window w)
            (drgnx-explorer--follow main)
            (should-not (funcall on-main))
            (drgnx-wb-focus-editor)
            ;; A mouse button is down in the Explorer: no reveal.
            (setq drgnx-explorer--pressed t)
            (drgnx-explorer--follow main)
            (should-not (funcall on-main))
            (setq drgnx-explorer--pressed nil)
            ;; Otherwise the editor's file is revealed, without selecting the Explorer.
            (drgnx-explorer--follow main)
            (should (funcall on-main))
            (should-not (eq (selected-window) w)))
        (kill-buffer main)))))

(ert-deftest drgnx-explorer/reveal-keeps-the-view-when-the-row-is-visible ()
  (drgnx-explorer-test--with root
    (drgnx-wb-show-sidebar)
    (let* ((w (drgnx-wb-section-window 'explorer)) (start (window-start w)))
      (drgnx-explorer-reveal (expand-file-name "README.md" root) w)
      (should (= start (window-start w))))))

(ert-deftest drgnx-explorer/a-big-folder-expands-fast ()
  (drgnx-explorer-test--with root
    (let ((big (expand-file-name "big" root)))
      (make-directory big)
      (dotimes (i 5000) (write-region "" nil (expand-file-name (format "f%04d.txt" i) big) nil 'silent))
      (drgnx-explorer-refresh)
      (let ((t0 (float-time)))
        (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "big"))
        (should (< (- (float-time) t0) 0.5)))     ; batch, generous; the GUI budget is in test/bench
      (should (= 5000 (seq-count (lambda (r) (= (car r) 2)) (drgnx-explorer-test--rows)))))))

(ert-deftest drgnx-explorer/showing-the-sidebar-reveals-the-editors-file ()
  (drgnx-explorer-test--with root
    (let ((main (find-file-noselect (expand-file-name "src/app/main.py" root))))
      (unwind-protect
          (progn
            (switch-to-buffer main)
            (drgnx-wb-show-sidebar)
            (let ((w (drgnx-wb-section-window 'explorer)))
              (should (equal (with-current-buffer drgnx-explorer-buffer-name (get-text-property (window-point w) 'drgnx-node))
                             (buffer-file-name main)))
              (should-not (eq (selected-window) w))))
        (kill-buffer main)))))
