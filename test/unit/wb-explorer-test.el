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
          (drgnx-wb--sections nil) (drgnx-signal--editor-window nil) (drgnx-explorer--pressed nil)
          (drgnx-explorer--selection nil) (drgnx-explorer--anchor nil) (drgnx-explorer--focused-before nil)
          (drgnx-explorer-compact-folders nil))     ; one row per folder; the joined rows have their own tests
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
       (drgnx-explorer-set-roots nil)                 ; its watches go: no events from the folder's removal
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
      ;; the rows only: watching the folder is the file-notify backend's cost (kqueue, on macOS, lists the folder)
      (let ((bytes (cl-letf (((symbol-function 'drgnx-explorer--sync-watches) #'ignore))
                     (drgnx-test--allocated (lambda () (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "big")))))))
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
  :tags '(:timing)                                      ; a quiet machine: bin/drgnx check runs it alone
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

;;;; File operations (M3b)

(defmacro drgnx-explorer-test--answering (answers &rest body)
  "BODY with prompts answered from ANSWERS (strings for names, t/nil for yes-or-no); the trash in a temp dir."
  (declare (indent 1))
  `(let* ((queue ,answers) (trash (make-temp-file "drgnx-trash" t))
          (trash-directory trash))       ; delete-by-moving-to-trash keeps its default (nil): the trash must not depend on it
     (unwind-protect
         (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (pop queue)))
                   ((symbol-function 'read-from-minibuffer) (lambda (&rest _) (pop queue)))
                   ((symbol-function 'y-or-n-p) (lambda (&rest _) (pop queue)))
                   ((symbol-function 'yes-or-no-p) (lambda (&rest _) (pop queue))))
           ,@body)
       (delete-directory trash t))))

(defun drgnx-explorer-test--at (name)
  (with-current-buffer drgnx-explorer-buffer-name (goto-char (drgnx-explorer-test--goto name)) (current-buffer)))

(ert-deftest drgnx-explorer/new-file-and-folder ()
  (drgnx-explorer-test--with root
    (drgnx-explorer-test--answering '("x/y/z.txt" "fresh/")
      (with-current-buffer (drgnx-explorer-test--at "src")
        (drgnx-explorer-new-file)
        (should (file-exists-p (expand-file-name "src/x/y/z.txt" root)))
        (goto-char (drgnx-explorer-test--goto "docs"))
        (drgnx-explorer-new-file)
        (should (file-directory-p (expand-file-name "docs/fresh" root)))
        (should (member '(2 "fresh") (drgnx-explorer-test--rows)))))
    (when-let* ((b (get-file-buffer (expand-file-name "src/x/y/z.txt" root)))) (kill-buffer b))))

(ert-deftest drgnx-explorer/an-existing-name-is-never-overwritten ()
  (drgnx-explorer-test--with root
    (drgnx-explorer-test--answering '("README.md" "guide.md")
      (with-current-buffer (drgnx-explorer-test--at "README.md")
        (should-error (drgnx-explorer-new-file) :type 'user-error)
        (goto-char (drgnx-explorer-test--goto "docs"))
        (drgnx-explorer-toggle-at (point))
        (goto-char (drgnx-explorer-test--goto "guide.md"))
        (write-region "keep\n" nil (expand-file-name "docs/other.md" root) nil 'silent)
        (should-error (progn (setq queue '("other.md")) (drgnx-explorer-rename)) :type 'user-error)
        (should (equal (with-temp-buffer (insert-file-contents (expand-file-name "docs/other.md" root)) (buffer-string)) "keep\n"))))))

(ert-deftest drgnx-explorer/rename-follows-open-buffers ()
  (drgnx-explorer-test--with root
    (let ((b (find-file-noselect (expand-file-name "src/app/main.py" root))))
      (unwind-protect
          (drgnx-explorer-test--answering '("core")
            (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "src"))
            (with-current-buffer (drgnx-explorer-test--at "app")
              (drgnx-explorer-rename))
            (should (file-exists-p (expand-file-name "src/core/main.py" root)))
            (should (equal (buffer-file-name b) (expand-file-name "src/core/main.py" root)))
            (should (member '(2 "core") (drgnx-explorer-test--rows))))
        (kill-buffer b)))))

(ert-deftest drgnx-explorer/delete-goes-to-the-trash-and-hits-the-captured-row ()
  (drgnx-explorer-test--with root
    (drgnx-explorer-test--answering '(t)
      (with-current-buffer (drgnx-explorer-test--at "README.md")
        ;; While the user answers, a background refresh puts new rows above the selected one.
        (cl-letf* ((real-y (symbol-function 'y-or-n-p))
                   ((symbol-function 'y-or-n-p)
                    (lambda (&rest args)
                      (write-region "" nil (expand-file-name "AAA-first.txt" root) nil 'silent)
                      (drgnx-explorer--refresh-dir (directory-file-name root))
                      (apply real-y args))))
          (drgnx-explorer-delete))
        (should-not (file-exists-p (expand-file-name "README.md" root)))
        (should (file-exists-p (expand-file-name "AAA-first.txt" root)))
        (should (directory-files trash nil "README" t))
        (should-not (member '(1 "README.md") (drgnx-explorer-test--rows)))))))

(ert-deftest drgnx-explorer/copy-cut-paste ()
  (drgnx-explorer-test--with root
    (drgnx-explorer-test--answering nil
      (with-current-buffer (drgnx-explorer-test--at "README.md")
        (drgnx-explorer-copy)
        (drgnx-explorer-paste)                      ; into the same folder: a copy, never an overwrite
        (drgnx-explorer-paste)
        (should (file-exists-p (expand-file-name "README copy.md" root)))
        (should (file-exists-p (expand-file-name "README copy 2.md" root)))
        (goto-char (drgnx-explorer-test--goto "README copy.md"))
        (drgnx-explorer-cut)
        (goto-char (drgnx-explorer-test--goto "docs"))
        (drgnx-explorer-paste)
        (should (file-exists-p (expand-file-name "docs/README copy.md" root)))
        (should-not (file-exists-p (expand-file-name "README copy.md" root)))))))

(ert-deftest drgnx-explorer/copy-path ()
  (drgnx-explorer-test--with root
    (with-current-buffer (drgnx-explorer-test--at "README.md")
      (drgnx-explorer-copy-path)
      (should (equal (current-kill 0) (expand-file-name "README.md" root)))
      (drgnx-explorer-copy-relative-path)
      (should (equal (current-kill 0) "README.md")))))

;;;; Multi-select (M3b)

(ert-deftest drgnx-explorer/a-selection-of-several-rows ()
  (drgnx-explorer-test--with root
    (with-current-buffer (drgnx-explorer-test--at "docs")
      (drgnx-explorer-select-down)
      (drgnx-explorer-select-down)
      (should (equal (sort (mapcar #'file-name-nondirectory (drgnx-explorer--targets)) #'string<) '("docs" "src" "tests")))
      (drgnx-explorer-select-up)
      (should (equal (sort (mapcar #'file-name-nondirectory (drgnx-explorer--targets)) #'string<) '("docs" "src")))
      ;; Moving without Shift ends the multi-select.
      (drgnx-explorer-next)
      (should (equal (mapcar #'file-name-nondirectory (drgnx-explorer--targets)) '("tests"))))))

(ert-deftest drgnx-explorer/marking-rows-and-deleting-them-together ()
  (drgnx-explorer-test--with root
    (drgnx-explorer-test--answering '(t)
      (with-current-buffer (drgnx-explorer-test--at "README.md")
        (drgnx-explorer-mark)
        (goto-char (drgnx-explorer-test--goto "docs"))
        (drgnx-explorer-mark)
        (drgnx-explorer--fontify (point-min) (point-max))
        (goto-char (drgnx-explorer-test--goto "docs"))
        (should (memq 'drgnx-explorer-selected (ensure-list (get-text-property (+ (point) 2) 'face))))
        (drgnx-explorer-delete)
        (should-not (file-exists-p (expand-file-name "README.md" root)))
        (should-not (file-exists-p (expand-file-name "docs" root)))
        (should (file-exists-p (expand-file-name "tests" root)))
        (should (null drgnx-explorer--selection))))))

;;;; Find (M3b)

(ert-deftest drgnx-explorer/type-to-navigate ()
  (drgnx-explorer-test--with root
    (with-current-buffer (drgnx-explorer-test--at "docs")
      (drgnx-explorer--navigate-type ?t)
      (should (equal (file-name-nondirectory (drgnx-explorer--node)) "tests"))
      (drgnx-explorer--navigate-type ?r)                ; "tr" matches nothing: stay
      (should (equal (file-name-nondirectory (drgnx-explorer--node)) "tests"))
      (setq drgnx-explorer--typed nil)
      (drgnx-explorer--navigate-type ?R)                ; case-insensitive
      (should (equal (file-name-nondirectory (drgnx-explorer--node)) "README.md")))))

(ert-deftest drgnx-explorer/find-filters-across-collapsed-folders-and-restores ()
  (drgnx-explorer-test--with root
    (drgnx-wb-show-sidebar)
    (let ((before (drgnx-explorer-test--rows)) (w (drgnx-wb-section-window 'explorer)))
      (with-current-buffer drgnx-explorer-buffer-name (set-window-point w (drgnx-explorer-test--goto "tests")))
      (drgnx-explorer--find-apply "util")
      (should (equal (cdr (drgnx-explorer-test--rows)) '((1 "src") (2 "app") (3 "util.py"))))
      (drgnx-explorer--find-apply "MAIN")                ; case-insensitive, matches in two folders
      (should (equal (mapcar #'cadr (cdr (drgnx-explorer-test--rows))) '("src" "app" "main.py" "tests" "test_main.py")))
      (drgnx-explorer-find-clear)
      (should (equal (drgnx-explorer-test--rows) before))
      (should-not (drgnx-explorer--expanded-p (expand-file-name "src" root)))
      (with-current-buffer drgnx-explorer-buffer-name
        (should (equal (drgnx-explorer-node-at (window-point w)) (expand-file-name "tests" root)))))))

;;;; Review fixes (M3b)

(ert-deftest drgnx-explorer/find-with-a-root-inside-a-project-terminates ()
  (skip-unless (executable-find "git"))
  (let* ((proj (file-name-as-directory (make-temp-file "drgnx-proj" t)))
         (drgnx-wb--sections nil) (drgnx-signal--editor-window nil))
    (unwind-protect
        (let ((default-directory proj))
          (call-process "git" nil nil nil "init" "-q")
          (make-directory "sub") (make-directory "other")
          (write-region "" nil "sub/xmatch-in.txt" nil 'silent)
          (write-region "" nil "other/xmatch-out.txt" nil 'silent)
          (call-process "git" nil nil nil "add" "-A")
          (delete-other-windows)
          (drgnx-explorer-setup)
          (drgnx-explorer-set-roots (list (expand-file-name "sub" proj)))
          (with-timeout (5 (ert-fail "Find did not return"))
            (drgnx-explorer--find-apply "xmatch"))
          (should (equal (mapcar #'cadr (cdr (drgnx-explorer-test--rows))) '("xmatch-in.txt"))))
      (setq drgnx-explorer--find nil)
      (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
      (delete-directory proj t))))

(ert-deftest drgnx-explorer/a-stale-selection-never-retargets-an-operation ()
  ;; Operations act on the selection only while the focused row is part of it (as VS Code).
  (drgnx-explorer-test--with root
    (with-current-buffer (drgnx-explorer-test--at "docs")
      (drgnx-explorer-select-down)                    ; docs + src
      (goto-char (drgnx-explorer-test--goto "README.md"))   ; e.g. a reveal or a right-click moved point
      (should (equal (drgnx-explorer--targets) (list (expand-file-name "README.md" root))))
      (should (null drgnx-explorer--selection)))))

(ert-deftest drgnx-explorer/the-question-names-the-files ()
  (drgnx-explorer-test--with root
    (let (asked)
      (drgnx-explorer-test--answering nil
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (q) (setq asked q) nil)))
          (with-current-buffer (drgnx-explorer-test--at "docs")
            (drgnx-explorer-select-down)
            (drgnx-explorer-delete))))
      (should (string-search "docs" asked))
      (should (string-search "src" asked)))))

(ert-deftest drgnx-explorer/deleting-the-row-at-point-keeps-the-place ()
  (drgnx-explorer-test--with root
    (drgnx-explorer-test--answering '(t)
      (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "src"))
      (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "app"))
      (with-current-buffer (drgnx-explorer-test--at "util.py")
        (let ((line (line-number-at-pos)))
          (drgnx-explorer-delete)
          (should (>= (line-number-at-pos) (1- line))))))))

(ert-deftest drgnx-explorer/cut-and-paste-moves-open-buffers-too ()
  (drgnx-explorer-test--with root
    (let ((b (find-file-noselect (expand-file-name "README.md" root))))
      (unwind-protect
          (drgnx-explorer-test--answering nil
            (with-current-buffer (drgnx-explorer-test--at "README.md")
              (drgnx-explorer-cut)
              (goto-char (drgnx-explorer-test--goto "docs"))
              (drgnx-explorer-paste))
            (should (equal (buffer-file-name b) (expand-file-name "docs/README.md" root))))
        (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))))

(ert-deftest drgnx-explorer/find-mode-keeps-the-filtered-tree ()
  ;; While Find shows a filtered tree, folder clicks, the follower and new files keep it filtered.
  (drgnx-explorer-test--with root
    (drgnx-wb-show-sidebar)
    (drgnx-explorer--find-apply "main")
    (let ((rows (drgnx-explorer-test--rows)))
      (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "app"))
      (should (equal (drgnx-explorer-test--rows) rows))
      (let ((m (find-file-noselect (expand-file-name "src/app/util.py" root))))
        (unwind-protect (progn (drgnx-explorer--follow m) (should (equal (drgnx-explorer-test--rows) rows)))
          (kill-buffer m)))
      (drgnx-explorer-test--answering '("main2.py")
        (with-current-buffer (drgnx-explorer-test--at "app")
          (drgnx-explorer-new-file)))
      (should (member '(3 "main2.py") (drgnx-explorer-test--rows)))
      (should-not (member '(3 "util.py") (drgnx-explorer-test--rows))))
    (drgnx-explorer-find-clear)
    (when-let* ((b (get-file-buffer (expand-file-name "src/app/main2.py" root)))) (kill-buffer b))))

(ert-deftest drgnx-explorer/a-recreated-folder-is-watched-again ()
  (skip-unless (and (featurep 'filenotify) file-notify--library))
  (drgnx-explorer-test--with root
    (let ((docs (expand-file-name "docs" root)))
      (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "docs"))
      (delete-directory docs t)
      (make-directory docs)                            ; rm -rf docs && mkdir docs
      (let ((deadline (+ (float-time) 2))) (while (< (float-time) deadline) (read-event nil nil 0.05)))
      (write-region "" nil (expand-file-name "fresh.txt" docs) nil 'silent)
      (let ((deadline (+ (float-time) 3)))
        (while (and (< (float-time) deadline) (not (member '(2 "fresh.txt") (drgnx-explorer-test--rows))))
          (read-event nil nil 0.05)))
      (should (member '(2 "fresh.txt") (drgnx-explorer-test--rows))))))

(ert-deftest drgnx-explorer/a-storm-across-many-folders-renders-once ()
  (drgnx-explorer-test--with root
    (dotimes (i 60) (make-directory (expand-file-name (format "m%02d" i) root)))
    (drgnx-explorer-refresh)
    (dotimes (i 60) (drgnx-explorer-toggle-at (drgnx-explorer-test--goto (format "m%02d" i))))
    (let ((drgnx-explorer--relists 0) (drgnx-explorer--renders 0))
      (dotimes (i 60)
        (drgnx-explorer--file-event (list 'desc 'created "x") (expand-file-name (format "m%02d" i) root)))
      (drgnx-explorer--apply-file-events)
      (should (= drgnx-explorer--relists 0))
      (should (= drgnx-explorer--renders 1)))))

(ert-deftest drgnx-explorer/shift-click-and-ctrl-click-select-from-the-focused-row ()
  (drgnx-explorer-test--with root
    (drgnx-wb-show-sidebar)
    (let ((w (drgnx-wb-section-window 'explorer)))
      (cl-flet ((click (kind name)
                  (let* ((pos (with-current-buffer drgnx-explorer-buffer-name (drgnx-explorer-test--goto name)))
                         (posn (list w pos (cons 0 0) 0)))      ; window, position, pixel, time
                    (with-selected-window w
                      (drgnx-explorer-mouse-press (list (intern (format "%sdown-mouse-1" kind)) posn))
                      (pcase kind
                        ("" (drgnx-explorer-mouse-click (list 'mouse-1 posn)))
                        ("S-" (drgnx-explorer-mouse-range (list 'S-mouse-1 posn)))
                        ("C-" (drgnx-explorer-mouse-toggle (list 'C-mouse-1 posn))))))))
        (click "" "README.md")
        (click "S-" "tests")                       ; tests (above) .. README.md
        (should (equal (sort (mapcar #'file-name-nondirectory drgnx-explorer--selection) #'string<) '("README.md" "tests")))
        (click "" "docs")
        (click "C-" "README.md")                   ; docs + README.md
        (should (equal (sort (mapcar #'file-name-nondirectory drgnx-explorer--selection) #'string<) '("README.md" "docs")))))))

(ert-deftest drgnx-explorer/a-stale-anchor-starts-a-new-range ()
  ;; The anchor's row is gone (deleted, another root): Shift+down starts from the row at point.
  (drgnx-explorer-test--with root
    (setq drgnx-explorer--anchor (expand-file-name "gone.txt" root))
    (with-current-buffer (drgnx-explorer-test--at "docs")
      (drgnx-explorer-select-down)
      (should (equal (mapcar #'file-name-nondirectory drgnx-explorer--selection) '("docs" "src"))))
    (drgnx-explorer--clear-selection)))

(ert-deftest drgnx-explorer/collapsing-a-folder-re-lists-nothing ()
  ;; Removing our own watch sends `stopped'; that is not the folder going away.
  (skip-unless (and (featurep 'filenotify) file-notify--library))
  (drgnx-explorer-test--with root
    (let ((drgnx-explorer--relists 0) (drgnx-explorer--renders 0))
      (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "docs"))
      (drgnx-explorer-toggle-at (drgnx-explorer-test--goto "docs"))
      (let ((deadline (+ (float-time) 0.5))) (while (< (float-time) deadline) (read-event nil nil 0.05)))
      (should (= drgnx-explorer--relists 0))
      (should (= drgnx-explorer--renders 0)))))

(ert-deftest drgnx-explorer/the-follower-moves-only-its-own-window ()
  ;; I9: the follower runs from the bus's timer and moves the Explorer's window — its own — only.
  (require 'drgnx-jank-guard)
  (drgnx-explorer-test--with root
    (drgnx-wb-show-sidebar)
    (let* ((w (drgnx-wb-section-window 'explorer))
           (main (find-file-noselect (expand-file-name "src/app/main.py" root)))
           (drgnx-jank-guard-log nil) (done nil))
      (drgnx-jank-guard-enable)
      (unwind-protect
          (progn
            (drgnx-wb-focus-editor)
            (run-with-timer 0 nil (lambda () (unwind-protect (drgnx-explorer--follow main) (setq done t))))
            (while (not done) (accept-process-output nil 0.01))
            (should (equal (with-current-buffer drgnx-explorer-buffer-name (drgnx-explorer-node-at (window-point w)))
                           (buffer-file-name main)))          ; it did move the Explorer
            (should-not drgnx-jank-guard-log))
        (drgnx-jank-guard-disable)
        (kill-buffer main)))))
