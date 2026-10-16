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
          (when-let* ((node (drgnx-explorer-node-at (point))))
            (push (list (drgnx-explorer-depth-at (point))
                        (file-name-nondirectory (directory-file-name node)))
                  rows))
          (forward-line 1))
        (nreverse rows)))))

(defun drgnx-explorer-test--goto (name)
  "Point (in the Explorer buffer) to the row of NAME; return the position."
  (with-current-buffer drgnx-explorer-buffer-name
    (goto-char (point-min))
    (while (and (not (eobp))
                (not (equal name (file-name-nondirectory (directory-file-name (or (drgnx-explorer-node-at (point)) ""))))))
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
      (should (equal (with-current-buffer drgnx-explorer-buffer-name (drgnx-explorer-node-at (window-point w)))
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
                                        (drgnx-explorer-node-at (window-point w)))
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
              (should (equal (with-current-buffer drgnx-explorer-buffer-name (drgnx-explorer-node-at (window-point w)))
                             (buffer-file-name main)))
              (should-not (eq (selected-window) w))))
        (kill-buffer main)))))

(defun drgnx-test--allocated (fn)
  "Bytes FN allocates (conses, vectors, strings, intervals), from `memory-use-counts'."
  (let ((m0 (memory-use-counts)))
    (funcall fn)
    (let ((m1 (memory-use-counts)))
      (+ (* 16 (- (nth 0 m1) (nth 0 m0))) (* 8 (- (nth 2 m1) (nth 2 m0))) (- (nth 4 m1) (nth 4 m0))
         (* 56 (- (nth 5 m1) (nth 5 m0)))))))

(ert-deftest drgnx-explorer/expanding-allocates-little ()
  ;; Garbage is what makes a GUI session pause (a full GC there takes ~15 ms): 5000 rows must
  ;; allocate under 3 MB (a row: its text, a face for the name, one vector of row data).
  (drgnx-explorer-test--with root
    (let ((big (expand-file-name "big" root)))
      (make-directory big)
      (dotimes (i 5000) (write-region "" nil (expand-file-name (format "f%04d.txt" i) big) nil 'silent))
      (drgnx-explorer-refresh)
      (drgnx-explorer-children big)                         ; listing cached: measure the rows
      (let ((bytes (drgnx-test--allocated (lambda () (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "big"))))))
        (should (< bytes (* 3 1024 1024)))))))

;;;; Review fixes

(ert-deftest drgnx-explorer/a-newline-in-a-name-keeps-rows-in-step ()
  (drgnx-explorer-test--with root
    (let ((odd (expand-file-name "zz" root)))
      (make-directory odd)
      (dolist (n '("a.txt" "b\nevil.txt" "c.txt" "d.txt")) (write-region "" nil (expand-file-name n odd) nil 'silent))
      (drgnx-explorer-refresh)
      (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "zz"))
      (with-current-buffer drgnx-explorer-buffer-name
        (should (= (count-lines (point-min) (point-max)) (length drgnx-explorer--rows)))
        (goto-char (point-min))
        (search-forward "c.txt")
        (should (equal (drgnx-explorer-node-at (point)) (expand-file-name "c.txt" odd)))
        (search-forward "d.txt")
        (should (equal (drgnx-explorer-node-at (point)) (expand-file-name "d.txt" odd)))))))

(ert-deftest drgnx-explorer/going-to-the-parent-is-fast ()
  (drgnx-explorer-test--with root
    (let ((big (expand-file-name "big" root)))
      (make-directory big)
      (dotimes (i 5000) (write-region "" nil (expand-file-name (format "f%04d.txt" i) big) nil 'silent))
      (drgnx-explorer-refresh)
      (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "big"))
      (with-current-buffer drgnx-explorer-buffer-name
        (goto-char (drgnx-explorer-test--goto "f4999.txt"))
        (let ((t0 (float-time)))
          (drgnx-explorer-collapse)
          (should (< (- (float-time) t0) 0.015)))
        (should (equal (drgnx-explorer-node-at (point)) big))))))

(ert-deftest drgnx-explorer/refresh-keeps-every-windows-view ()
  (drgnx-explorer-test--with root
    (let ((big (expand-file-name "big" root)))
      (make-directory big)
      (dotimes (i 300) (write-region "" nil (expand-file-name (format "f%03d.txt" i) big) nil 'silent))
      (drgnx-explorer-refresh)
      (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "big"))
      (drgnx-wb-show-sidebar)
      (let ((w (drgnx-wb-section-window 'explorer)))
        (with-current-buffer drgnx-explorer-buffer-name
          (set-window-start w (drgnx-explorer-test--goto "f200.txt"))
          (set-window-point w (drgnx-explorer-test--goto "f205.txt")))
        (drgnx-explorer-refresh)
        (with-current-buffer drgnx-explorer-buffer-name
          (should (equal (drgnx-explorer-node-at (window-start w)) (expand-file-name "f200.txt" big)))
          (should (equal (drgnx-explorer-node-at (window-point w)) (expand-file-name "f205.txt" big))))))))

(ert-deftest drgnx-explorer/a-click-never-scrolls-the-dock ()
  ;; Pressing a partly visible bottom row must not scroll (the row would move under the pointer).
  (drgnx-explorer-test--with root
    (with-current-buffer drgnx-explorer-buffer-name
      (should (= scroll-margin 0))
      (should-not make-cursor-line-fully-visible))))

;;;; Live updates (M3b)

(ert-deftest drgnx-explorer/an-external-change-appears-in-place ()
  (drgnx-explorer-test--with root
    (drgnx-wb-show-sidebar)
    (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "src"))
    (let ((w (drgnx-wb-section-window 'explorer)) (src (expand-file-name "src" root)))
      (with-current-buffer drgnx-explorer-buffer-name
        (set-window-point w (drgnx-explorer-test--goto "tests")))
      (write-region "" nil (expand-file-name "src/new.txt" root) nil 'silent)
      (delete-directory (expand-file-name "docs" root) t)
      (drgnx-explorer--file-event (list 'desc 'created (expand-file-name "src/new.txt" root)) src)
      (drgnx-explorer--file-event (list 'desc 'deleted (expand-file-name "docs" root)) (directory-file-name root))
      (drgnx-explorer--apply-file-events)
      (should (member '(2 "new.txt") (drgnx-explorer-test--rows)))
      (should-not (member '(1 "docs") (drgnx-explorer-test--rows)))
      (with-current-buffer drgnx-explorer-buffer-name
        (should (= (count-lines (point-min) (point-max)) (length drgnx-explorer--rows)))
        (should (equal (drgnx-explorer-node-at (window-point w)) (expand-file-name "tests" root)))))))

(ert-deftest drgnx-explorer/an-event-storm-relists-each-folder-once ()
  (drgnx-explorer-test--with root
    (let ((root-dir (directory-file-name root)) (drgnx-explorer--relists 0))
      (dotimes (i 1000)
        (drgnx-explorer--file-event (list 'desc 'created (expand-file-name (format "f%d" i) root)) root-dir))
      (drgnx-explorer--apply-file-events)
      (should (= drgnx-explorer--relists 1)))))

(ert-deftest drgnx-explorer/watches-follow-what-is-shown ()
  (drgnx-explorer-test--with root
    (let ((src (expand-file-name "src" root)))
      (should (gethash (directory-file-name root) drgnx-explorer--watches))
      (should-not (gethash src drgnx-explorer--watches))
      (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "src"))
      (should (gethash src drgnx-explorer--watches))
      (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "src"))
      (should-not (gethash src drgnx-explorer--watches)))))

(ert-deftest drgnx-explorer/a-real-file-event-updates-the-tree ()
  (skip-unless (and (featurep 'filenotify) file-notify--library))
  (drgnx-explorer-test--with root
    (write-region "" nil (expand-file-name "watched.txt" root) nil 'silent)
    (let ((deadline (+ (float-time) 3)))
      (while (and (< (float-time) deadline) (not (member '(1 "watched.txt") (drgnx-explorer-test--rows))))
        (read-event nil nil 0.05)))
    (should (member '(1 "watched.txt") (drgnx-explorer-test--rows)))))

(ert-deftest drgnx-explorer/no-update-while-a-button-is-held ()
  (drgnx-explorer-test--with root
    (let ((root-dir (directory-file-name root)))
      (write-region "" nil (expand-file-name "held.txt" root) nil 'silent)
      (setq drgnx-explorer--pressed t)
      (drgnx-explorer--file-event (list 'desc 'created (expand-file-name "held.txt" root)) root-dir)
      (drgnx-explorer--apply-file-events)
      (should-not (member '(1 "held.txt") (drgnx-explorer-test--rows)))
      (setq drgnx-explorer--pressed nil)
      (drgnx-explorer--apply-file-events)
      (should (member '(1 "held.txt") (drgnx-explorer-test--rows))))))
