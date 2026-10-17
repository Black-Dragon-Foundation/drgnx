;;; wb-explorer-edge-test.el --- batch tests: the Explorer's edge cases (DEFERRED fix pass) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-explorer)
(require 'drgnx-buffers)
(require 'drgnx-outline)

(defun drgnx-explorer-edge--tree (root paths)
  "Create PATHS under ROOT (a trailing / makes a directory)."
  (dolist (p paths)
    (let ((f (expand-file-name p root)))
      (if (string-suffix-p "/" p) (make-directory f t)
        (make-directory (file-name-directory f) t)
        (write-region "" nil f nil 'silent)))))

(defmacro drgnx-explorer-edge--with (root &rest body)
  "BODY with a fixture ROOT and the Explorer rooted there (the dock not shown)."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-explorer" t)))
          (drgnx-wb--sections nil) (drgnx-signal--editor-window nil) (drgnx-explorer--pressed nil)
          (drgnx-explorer--selection nil) (drgnx-explorer--anchor nil) (drgnx-explorer--focused-before nil)
          (drgnx-explorer--clipboard nil))
     (unwind-protect
         (progn
           (drgnx-explorer-edge--tree ,root '("README.md" "docs/guide.md" "docs/sub/" "src/app/main.py" "tests/test_main.py"))
           (delete-other-windows)
           (drgnx-explorer-setup)
           (drgnx-explorer-set-roots (list ,root))
           ,@body)
       (setq drgnx-explorer--find nil)
       (drgnx-wb-hide-sidebar)
       (delete-other-windows)
       (drgnx-explorer-set-roots nil)
       (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
       (delete-directory ,root t))))

(defmacro drgnx-explorer-edge--answering (answers &rest body)
  "BODY with prompts answered from ANSWERS; the trash in a temp dir."
  (declare (indent 1))
  `(let* ((queue ,answers) (trash (make-temp-file "drgnx-trash" t)) (trash-directory trash))
     (unwind-protect
         (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (pop queue)))
                   ((symbol-function 'y-or-n-p) (lambda (&rest _) (pop queue)))
                   ((symbol-function 'yes-or-no-p) (lambda (&rest _) (pop queue))))
           ,@body)
       (delete-directory trash t))))

(defun drgnx-explorer-edge--rows ()
  "The Explorer's rows as (DEPTH NAME) lists."
  (with-current-buffer drgnx-explorer-buffer-name
    (save-excursion
      (goto-char (point-min))
      (let (rows)
        (while (not (eobp))
          (when-let* ((node (drgnx-explorer-node-at (point))))
            (push (list (drgnx-explorer-depth-at (point)) (file-name-nondirectory (directory-file-name node))) rows))
          (forward-line 1))
        (nreverse rows)))))

(defun drgnx-explorer-edge--at (name)
  "Put point (in the Explorer buffer) on NAME's row; return the buffer."
  (with-current-buffer drgnx-explorer-buffer-name
    (goto-char (point-min))
    (while (and (not (eobp))
                (not (equal name (file-name-nondirectory (directory-file-name (or (drgnx-explorer-node-at (point)) ""))))))
      (forward-line 1))
    (current-buffer)))

(defun drgnx-explorer-edge--press (window)
  "A press on the first row of WINDOW, as the command loop delivers it."
  (drgnx-explorer-mouse-press (list 'down-mouse-1 (list window 1 '(0 . 0) 0))))

;;;; M3a-3: a root of /

(ert-deftest drgnx-explorer-edge/a-root-of-slash-builds-clean-paths ()
  (should (equal (drgnx-explorer--path (vector "usr" 1 t "/")) "/usr"))
  (let ((drgnx-wb--sections nil) (drgnx-explorer-git nil)
        (drgnx-explorer--expanded (make-hash-table :test #'equal))
        (drgnx-explorer--children-function
         (lambda (dir) (pcase (directory-file-name dir)
                         ("/" '(("usr" . t))) ("/usr" '(("bin" . t))) ("/usr/bin" '(("ls"))) (_ nil)))))
    (cl-letf (((symbol-function 'file-notify-add-watch) (lambda (&rest _) (error "No watches here"))))
      (unwind-protect
          (progn
            (drgnx-explorer-set-roots '("/"))
            (should (drgnx-explorer-reveal "/usr/bin/ls"))
            (should (drgnx-explorer-reveal "/usr/bin/ls"))     ; a second reveal collapses nothing
            (with-current-buffer drgnx-explorer-buffer-name
              (should (equal (drgnx-explorer-node-at (point)) "/usr/bin/ls")))
            (should (drgnx-explorer--expanded-p "/usr")))
        (drgnx-explorer-set-roots nil)
        (kill-buffer drgnx-explorer-buffer-name)))))

;;;; M3a-4: set-roots renders once

(ert-deftest drgnx-explorer-edge/set-roots-renders-once ()
  (drgnx-explorer-edge--with root
    (kill-buffer drgnx-explorer-buffer-name)
    (let ((n drgnx-explorer--renders))
      (drgnx-explorer-set-roots (list root))
      (should (= (1+ n) drgnx-explorer--renders)))))

;;;; M3a-6: dock buffers are internal

(ert-deftest drgnx-explorer-edge/dock-buffers-are-internal ()
  (dolist (name (list drgnx-explorer-buffer-name drgnx-buffers-buffer-name drgnx-outline-buffer-name))
    (should (string-prefix-p " " name)))
  ;; The Explorer's kill hook still runs (no inhibit-buffer-hooks): its watches go with it.
  (skip-unless (and (featurep 'filenotify) file-notify--library))
  (drgnx-explorer-edge--with root
    (should (> (hash-table-count drgnx-explorer--watches) 0))
    (kill-buffer drgnx-explorer-buffer-name)
    (should (= (hash-table-count drgnx-explorer--watches) 0))))

;;;; M3a-7: narrowing, quits

(ert-deftest drgnx-explorer-edge/narrowing-keeps-rows-in-step ()
  (drgnx-explorer-edge--with root
    (with-current-buffer drgnx-explorer-buffer-name
      (let ((tests (expand-file-name "tests" root)))
        (goto-char (point-min))
        (forward-line 2)
        (narrow-to-region (point) (point-max))
        (unwind-protect
            (should (equal (drgnx-explorer-node-at (drgnx-explorer--row-pos tests)) tests))
          (widen))))))

(ert-deftest drgnx-explorer-edge/a-quit-never-splits-an-expand ()
  (drgnx-explorer-edge--with root
    (let* ((seen 'unset)
           (drgnx-explorer--children-function (lambda (dir) (setq seen inhibit-quit) (drgnx-explorer-children dir))))
      (with-current-buffer (drgnx-explorer-edge--at "src")
        (drgnx-explorer-toggle-at (point)))
      (should (eq seen t)))))

;;;; M3a-11: remote files

(ert-deftest drgnx-explorer-edge/the-follower-skips-remote-files ()
  (drgnx-explorer-edge--with root
    (drgnx-wb-show-sidebar)
    (let ((revealed nil))
      (with-temp-buffer
        (setq buffer-file-name "/ssh:nohost.invalid:/srv/x.txt")
        (cl-letf (((symbol-function 'drgnx-explorer-reveal) (lambda (&rest _) (setq revealed t))))
          (drgnx-explorer--follow (current-buffer)))
        (setq buffer-file-name nil))
      (should-not revealed))))

;;;; M3b-4: a parent and its child together

(defun drgnx-explorer-edge--select (&rest names)
  (with-current-buffer drgnx-explorer-buffer-name
    (dolist (n names) (drgnx-explorer-edge--at n) (drgnx-explorer-mark))
    (drgnx-explorer-edge--at (car names))))

(ert-deftest drgnx-explorer-edge/deleting-a-folder-and-a-file-inside-it ()
  (drgnx-explorer-edge--with root
    (with-current-buffer (drgnx-explorer-edge--at "docs") (drgnx-explorer-toggle-at (point)))
    (drgnx-explorer-edge--select "docs" "guide.md")
    (drgnx-explorer-edge--answering '(t)
      (with-current-buffer drgnx-explorer-buffer-name (drgnx-explorer-delete)))
    (should-not (file-exists-p (expand-file-name "docs" root)))
    (should-not (member '(1 "docs") (drgnx-explorer-edge--rows)))))

(ert-deftest drgnx-explorer-edge/a-refused-move-moves-nothing ()
  (drgnx-explorer-edge--with root
    (drgnx-explorer-edge--select "README.md" "docs")
    (with-current-buffer drgnx-explorer-buffer-name
      (drgnx-explorer-cut)
      (drgnx-explorer-edge--at "docs")
      (drgnx-explorer-toggle-at (point))
      (drgnx-explorer-edge--at "sub")
      (should-error (drgnx-explorer-paste) :type 'user-error))
    (should (file-exists-p (expand-file-name "README.md" root)))
    (should-not (file-exists-p (expand-file-name "docs/sub/README.md" root)))))

(ert-deftest drgnx-explorer-edge/copying-a-folder-and-a-file-inside-it-copies-once ()
  (drgnx-explorer-edge--with root
    (with-current-buffer (drgnx-explorer-edge--at "docs") (drgnx-explorer-toggle-at (point)))
    (drgnx-explorer-edge--select "docs" "guide.md")
    (with-current-buffer drgnx-explorer-buffer-name
      (drgnx-explorer-copy)
      (drgnx-explorer-edge--at "tests")
      (drgnx-explorer-paste))
    (should (file-exists-p (expand-file-name "tests/docs/guide.md" root)))
    (should-not (file-exists-p (expand-file-name "tests/guide.md" root)))))

;;;; M3b-5: a link to a folder

(ert-deftest drgnx-explorer-edge/deleting-a-link-to-a-folder-keeps-the-folder ()
  (dolist (permanently '(t nil))
    (drgnx-explorer-edge--with root
      (make-symbolic-link (expand-file-name "src" root) (expand-file-name "link" root))
      (drgnx-explorer-refresh)
      (drgnx-explorer-edge--answering '(t)
        (with-current-buffer (drgnx-explorer-edge--at "link")
          (drgnx-explorer-delete permanently)))
      (should-not (file-symlink-p (expand-file-name "link" root)))
      (should (file-exists-p (expand-file-name "src/app/main.py" root))))))

;;;; M3b-6: Rename and New File

(ert-deftest drgnx-explorer-edge/rename-and-new-file-stay-under-the-root ()
  (drgnx-explorer-edge--with root
    (let ((outside (expand-file-name "../drgnx-outside.txt" root))
          (abs (expand-file-name "drgnx-abs.txt" temporary-file-directory)))
      (unwind-protect
          (drgnx-explorer-edge--answering (list "../drgnx-outside.txt" abs "../drgnx-outside.txt")
            (with-current-buffer (drgnx-explorer-edge--at "README.md")
              (should-error (drgnx-explorer-rename) :type 'user-error)
              (should-error (drgnx-explorer-rename) :type 'user-error)
              (should (file-exists-p (expand-file-name "README.md" root)))
              (should-error (drgnx-explorer-new-file) :type 'user-error)
              (should-not (file-exists-p outside))
              (should-not (file-exists-p abs))))
        (when (file-exists-p outside) (delete-file outside))
        (when (file-exists-p abs) (delete-file abs))))))

(ert-deftest drgnx-explorer-edge/a-case-only-rename-on-a-case-insensitive-disk ()
  (drgnx-explorer-edge--with root
    (let* ((old (expand-file-name "README.md" root)) (new (expand-file-name "readme.md" root))
           (real-exists (symbol-function 'file-exists-p)))
      (drgnx-explorer-edge--answering '("readme.md")
        ;; A case-insensitive disk: readme.md "exists" — it is README.md.
        (cl-letf (((symbol-function 'file-name-case-insensitive-p) (lambda (&rest _) t))
                  ((symbol-function 'file-exists-p)
                   (lambda (f) (funcall real-exists (if (equal (expand-file-name f) new) old f)))))
          (with-current-buffer (drgnx-explorer-edge--at "README.md")
            (drgnx-explorer-rename))))
      (should (member "readme.md" (directory-files root))))))

(ert-deftest drgnx-explorer-edge/new-file-in-new-folders-is-revealed ()
  (drgnx-explorer-edge--with root
    (let ((path (expand-file-name "src/x/y/z.txt" root)))
      (unwind-protect
          (drgnx-explorer-edge--answering '("x/y/z.txt")
            (with-current-buffer (drgnx-explorer-edge--at "src")
              (drgnx-explorer-new-file)
              (should (member '(4 "z.txt") (drgnx-explorer-edge--rows)))
              (should (equal (drgnx-explorer-node-at (point)) path))))
        (when-let* ((b (get-file-buffer path))) (kill-buffer b))))))

;;;; M3b-7: git overlays

(ert-deftest drgnx-explorer-edge/repainting-a-row-never-piles-up-overlays ()
  (drgnx-explorer-edge--with root
    (cl-letf (((symbol-function 'drgnx-git-status) (lambda (p) (and (string-suffix-p "README.md" p) 'modified))))
      (with-current-buffer (drgnx-explorer-edge--at "README.md")
        (dotimes (_ 3) (drgnx-explorer--fontify (pos-bol) (pos-eol)))
        (should (= 1 (seq-count (lambda (o) (overlay-get o 'drgnx-git)) (overlays-in (point-min) (point-max)))))))))

;;;; M3b-10: a watch that failed

(ert-deftest drgnx-explorer-edge/a-failed-watch-is-tried-again ()
  (skip-unless (and (featurep 'filenotify) file-notify--library))
  (drgnx-explorer-edge--with root
    (with-current-buffer drgnx-explorer-buffer-name
      (drgnx-explorer--unwatch-all)
      (cl-letf (((symbol-function 'file-notify-add-watch) (lambda (&rest _) (error "Too many watches"))))
        (drgnx-explorer--sync-watches))
      (should (eq (gethash (directory-file-name root) drgnx-explorer--watches) 'none))
      (drgnx-explorer--sync-watches)                    ; the limit was raised, or watches freed
      (should (file-notify-valid-p (gethash (directory-file-name root) drgnx-explorer--watches))))))

;;;; M3b-12: Find and the Explorer's end

(ert-deftest drgnx-explorer-edge/killing-the-explorer-ends-find ()
  (drgnx-explorer-edge--with root
    (drgnx-explorer--find-apply "main")
    (kill-buffer drgnx-explorer-buffer-name)
    (should-not drgnx-explorer--find)
    (drgnx-explorer--apply-file-events)
    (should-not drgnx-explorer--event-timer)))          ; the 0.15 s poll stops

(ert-deftest drgnx-explorer-edge/new-roots-drop-the-find-title ()
  (drgnx-explorer-edge--with root
    (drgnx-wb-show-sidebar)
    (drgnx-explorer--find-apply "main")
    (drgnx-explorer-set-roots (list root))
    (should (equal (window-parameter (drgnx-wb-section-window 'explorer) 'header-line-format) " EXPLORER"))))

;;; wb-explorer-edge-test.el ends here
