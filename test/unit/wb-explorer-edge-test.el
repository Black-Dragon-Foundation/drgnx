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
          (drgnx-explorer--clipboard nil)
          (drgnx-explorer-compact-folders nil))     ; one row per folder; the joined rows have their own tests
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

;;;; M3a-1, M3b-16: a held button

(ert-deftest drgnx-explorer-edge/a-release-that-went-elsewhere-ends-the-hold ()
  ;; M3a-1: the release came with a modifier (M-<mouse-1>) or in another window: another command
  ;; read it, so the Explorer's press is over — live updates resume.
  (drgnx-explorer-edge--with root
    (drgnx-wb-show-sidebar)
    (let ((num-input-keys 10))
      (drgnx-explorer-edge--press (drgnx-wb-section-window 'explorer))
      (write-region "" nil (expand-file-name "held.txt" root) nil 'silent)
      (drgnx-explorer--file-event (list 'desc 'created (expand-file-name "held.txt" root)) (directory-file-name root))
      (drgnx-explorer--apply-file-events)
      (should-not (member '(1 "held.txt") (drgnx-explorer-edge--rows)))   ; still held: rows stay
      (setq num-input-keys 11)                                           ; another key sequence was read
      (drgnx-explorer--apply-file-events)
      (should (member '(1 "held.txt") (drgnx-explorer-edge--rows))))))

(ert-deftest drgnx-explorer-edge/losing-focus-ends-both-panels-presses ()
  ;; M3b-16: focus lost mid-press (Wayland): the release never comes.
  (drgnx-explorer-edge--with root
    (let ((drgnx-signal--subscribers nil) (drgnx-buffers--pressed nil) (drgnx-buffers--pending nil))
      (drgnx-buffers-setup)
      (drgnx-wb-show-sidebar)
      (drgnx-explorer-edge--press (drgnx-wb-section-window 'explorer))
      (setq drgnx-buffers--pressed t)
      (cl-letf (((symbol-function 'frame-focus-state) (lambda (&rest _) t)))
        (funcall after-focus-change-function))                ; focus moved within Emacs: still held
      (should drgnx-explorer--pressed)
      (should drgnx-buffers--pressed)
      (cl-letf (((symbol-function 'frame-focus-state) (lambda (&rest _) nil)))
        (funcall after-focus-change-function))                ; Emacs lost focus
      (should-not drgnx-explorer--pressed)
      (should-not drgnx-buffers--pressed))
    (when (get-buffer drgnx-buffers-buffer-name) (kill-buffer drgnx-buffers-buffer-name))))

;;; wb-explorer-edge-test.el ends here

;;;; M3b-14: deleting a file closes the buffers visiting it

(ert-deftest drgnx-explorer-edge/delete-closes-unmodified-visiting-buffers ()
  (drgnx-explorer-edge--with root
    (with-current-buffer (drgnx-explorer-edge--at "docs") (drgnx-explorer-toggle-at (point)))
    (let* ((clean (find-file-noselect (expand-file-name "docs/guide.md" root)))
           (dirty (find-file-noselect (expand-file-name "README.md" root)))
           (other (find-file-noselect (expand-file-name "tests/test_main.py" root)))
           (said nil))
      (unwind-protect
          (progn
            (with-current-buffer dirty (insert "unsaved"))
            (drgnx-explorer-edge--select "docs" "README.md")
            (drgnx-explorer-edge--answering '(t)
              (cl-letf (((symbol-function 'message) (lambda (fmt &rest a) (push (apply #'format fmt a) said))))
                (with-current-buffer drgnx-explorer-buffer-name (drgnx-explorer-delete))))
            (should-not (buffer-live-p clean))             ; inside the deleted folder, unmodified
            (should (buffer-live-p other))                 ; not deleted
            (should (buffer-live-p dirty))                 ; modified: kept, and said so
            (should (seq-find (lambda (m) (string-match-p "README\\.md.*unsaved\\|unsaved.*README\\.md" m)) said)))
        (with-current-buffer dirty (set-buffer-modified-p nil))
        (dolist (b (list clean dirty other)) (when (buffer-live-p b) (kill-buffer b)))))))

;;;; M3b-15: the trash on another device is gio's, in the background

(defmacro drgnx-explorer-edge--gio (&rest body)
  "BODY with a cross-device trash handled by a stubbed gio: `started' collects make-process arguments,
`said' the messages, `synced' the paths the Emacs trash was asked for (it only records)."
  (declare (indent 0))
  `(let ((started nil) (said nil) (synced nil))
     (cl-letf (((symbol-function 'drgnx-explorer--trash-cross-device-p) (lambda (_p) t))
               ((symbol-function 'executable-find) (lambda (c &rest _) (and (equal c "gio") "/usr/bin/gio")))
               ((symbol-function 'message) (lambda (fmt &rest a) (push (apply #'format fmt a) said)))
               ((symbol-function 'drgnx-explorer--trash-sync) (lambda (p) (push p synced)))
               ((symbol-function 'make-process) (lambda (&rest args) (push args started) 'proc)))
       ,@body)))

(defun drgnx-explorer-edge--gio-ends (started event &optional output)
  "End the gio process of STARTED's newest entry with EVENT, after it wrote OUTPUT."
  (let ((buf (plist-get (car started) :buffer)))
    (when (and output (buffer-live-p buf)) (with-current-buffer buf (insert output)))
    (funcall (plist-get (car started) :sentinel) 'proc event)))

(ert-deftest drgnx-explorer-edge/trash-on-another-device-is-an-async-gio-trash ()
  (drgnx-explorer-edge--with root
    (let ((file (expand-file-name "README.md" root)) (trash-directory nil)
          (clean (find-file-noselect (expand-file-name "README.md" root))))
      (drgnx-explorer-edge--gio
        (drgnx-explorer-edge--answering '(t)
          (let ((trash-directory nil))
            (with-current-buffer (drgnx-explorer-edge--at "README.md") (drgnx-explorer-delete))))
        (should (= 1 (length started)))
        (should (equal (plist-get (car started) :command) (list "gio" "trash" "--" file)))
        (should (file-exists-p file))                     ; nothing was copied or deleted synchronously
        (should (buffer-live-p clean))                    ; and nothing is said to be gone before gio is
        (drgnx-explorer-edge--gio-ends started "finished\n")
        (should-not (buffer-live-p clean))                ; closed when gio succeeded
        (should-not synced))))
  ;; permanently: no gio; same device: the Emacs trash
  (dolist (case '((t . nil) (nil . nil)))
    (drgnx-explorer-edge--with root
      (let ((started nil))
        (drgnx-explorer-edge--answering '(t)
          (cl-letf (((symbol-function 'drgnx-explorer--trash-cross-device-p) (lambda (_p) (car case)))
                    ((symbol-function 'executable-find) (lambda (&rest _) "/usr/bin/gio"))
                    ((symbol-function 'make-process) (lambda (&rest args) (push args started) 'proc)))
            (with-current-buffer (drgnx-explorer-edge--at "README.md") (drgnx-explorer-delete (car case)))))
        (should-not started)
        (should-not (file-exists-p (expand-file-name "README.md" root)))))))

(ert-deftest drgnx-explorer-edge/a-failed-gio-falls-back-to-the-emacs-trash ()
  ;; review F2a, b: gio refuses some cross-device cases (tmpfs); the file then goes the Emacs way,
  ;; and only when that fails too is there a message, with gio's own words
  (drgnx-explorer-edge--with root
    (let ((file (expand-file-name "README.md" root)) (dirty (find-file-noselect (expand-file-name "README.md" root))))
      (with-current-buffer dirty (insert "unsaved"))
      (unwind-protect
          (drgnx-explorer-edge--gio
            (drgnx-explorer-edge--answering '(t)
              (let ((trash-directory nil))
                (with-current-buffer (drgnx-explorer-edge--at "README.md") (drgnx-explorer-delete))))
            (should-not (seq-find (lambda (m) (string-match-p "deleted" m)) said))   ; nothing yet
            (drgnx-explorer-edge--gio-ends started "exited abnormally with code 1\n"
                                           "Trashing on system internal mounts is not supported\n")
            (should (equal synced (list file)))                                    ; the fallback
            (should-not (seq-find (lambda (m) (string-match-p "Could not" m)) said))
            (should (seq-find (lambda (m) (string-match-p "README\\.md.*unsaved" m)) said)))  ; success: now said
        (with-current-buffer dirty (set-buffer-modified-p nil))
        (kill-buffer dirty))))
  (drgnx-explorer-edge--with root
    (let ((file (expand-file-name "README.md" root)) (clean (find-file-noselect (expand-file-name "README.md" root))))
      (drgnx-explorer-edge--gio
        (cl-letf (((symbol-function 'drgnx-explorer--trash-sync) (lambda (_p) (error "No trash here"))))
          (drgnx-explorer-edge--answering '(t)
            (let ((trash-directory nil))
              (with-current-buffer (drgnx-explorer-edge--at "README.md") (drgnx-explorer-delete))))
          (drgnx-explorer-edge--gio-ends started "exited abnormally with code 1\n"
                                         "Trashing on system internal mounts is not supported\n"))
        (should (file-exists-p file))
        (should (buffer-live-p clean))                    ; the file is still there: so is its buffer
        (should (seq-find (lambda (m) (string-match-p "Could not.*README\\.md.*internal mounts" m)) said))
        (kill-buffer clean)))))

(ert-deftest drgnx-explorer-edge/a-set-trash-directory-is-not-gios ()
  ;; review F2c: gio ignores `trash-directory'; when the user set one, Emacs' trash is the only one that honours it
  (drgnx-explorer-edge--with root
    (drgnx-explorer-edge--gio
      (drgnx-explorer-edge--answering '(t)                 ; binds `trash-directory' to a temp dir
        (with-current-buffer (drgnx-explorer-edge--at "README.md") (drgnx-explorer-delete))
        (should-not started)
        (should-not (file-exists-p (expand-file-name "README.md" root)))
        (should (directory-files trash nil "README" t))))))

(ert-deftest drgnx-explorer-edge/the-gio-sentinel-leaves-a-collapsed-folder-collapsed ()
  ;; review F2d: the sentinel refreshes the folder if it is shown; it never re-expands one
  (drgnx-explorer-edge--with root
    (let ((shown nil) (refreshed nil))
      (drgnx-explorer-edge--gio
        (drgnx-explorer-edge--answering '(t)
          (let ((trash-directory nil))
            (with-current-buffer (drgnx-explorer-edge--at "README.md") (drgnx-explorer-delete))))
        (cl-letf (((symbol-function 'drgnx-explorer--show-folder) (lambda (d) (push d shown)))
                  ((symbol-function 'drgnx-explorer--refresh-dir) (lambda (d) (push d refreshed))))
          (drgnx-explorer-edge--gio-ends started "finished\n"))
        (should-not shown)
        (should (equal refreshed (list (directory-file-name root))))))))

(ert-deftest drgnx-explorer-edge/trash-device-test-compares-device-numbers ()
  (let ((dir (make-temp-file "drgnx-dev" t)))
    (unwind-protect
        (let ((trash-directory (expand-file-name "trash" dir)))      ; not created yet: its parent's device counts
          (should-not (drgnx-explorer--trash-cross-device-p (expand-file-name "x" dir)))
          ;; every call another device (`file-attributes', not the inlined `file-attribute-device-number': a compiled
          ;; drgnx-explorer never calls the latter)
          (cl-letf (((symbol-function 'file-attributes)
                     (let ((n 0)) (lambda (&rest _) (let ((a (make-list 12 nil))) (setf (nth 11 a) (cl-incf n)) a)))))
            (should (drgnx-explorer--trash-cross-device-p (expand-file-name "x" dir))))
          (should-not (drgnx-explorer--trash-cross-device-p "/ssh:nohost.invalid:/x")))
      (delete-directory dir t))))

;;;; M3b-17: reveal in the file manager, and watches

(ert-deftest drgnx-explorer-edge/reveal-externally-on-each-system ()
  (drgnx-explorer-edge--with root
    (let ((calls nil) (file (expand-file-name "README.md" root)))
      (cl-letf (((symbol-function 'call-process) (lambda (&rest a) (push a calls) 0)))
        (with-current-buffer (drgnx-explorer-edge--at "README.md")
          (let ((system-type 'windows-nt)) (drgnx-explorer-reveal-externally))
          (should (equal (car calls)
                         (list "explorer.exe" nil 0 nil (concat "/select," (subst-char-in-string ?/ ?\\ file)))))
          (let ((system-type 'darwin)) (drgnx-explorer-reveal-externally))
          (should (equal (car calls) (list "open" nil 0 nil "-R" file)))
          (let ((system-type 'gnu/linux)) (drgnx-explorer-reveal-externally))
          (should (equal (car calls) (list "xdg-open" nil 0 nil (directory-file-name root)))))))))

(ert-deftest drgnx-explorer-edge/reveal-externally-refuses-a-remote-path ()
  (drgnx-explorer-edge--with root
    (cl-letf (((symbol-function 'call-process) (lambda (&rest _) (error "must not run")))
              ((symbol-function 'drgnx-explorer--node) (lambda () "/ssh:nohost.invalid:/srv/x.txt")))
      (should-error (drgnx-explorer-reveal-externally) :type 'user-error))))

(ert-deftest drgnx-explorer-edge/remote-folders-are-never-watched ()
  ;; a file-notify watch on a TRAMP folder starts a remote process, which blocks: only local folders are watched
  (drgnx-explorer-edge--with root
    (let ((watched nil) (remote "/ssh:nohost.invalid:/srv"))
      (drgnx-explorer--unwatch-all)
      (cl-letf (((symbol-function 'drgnx-explorer--shown-folders) (lambda () (list remote (directory-file-name root))))
                ((symbol-function 'file-notify-add-watch) (lambda (d &rest _) (push d watched) 'desc))
                ((symbol-function 'file-notify-valid-p) (lambda (&rest _) t))
                ((symbol-function 'file-notify-rm-watch) #'ignore))
        (drgnx-explorer--sync-watches)
        (should (equal watched (list (directory-file-name root))))
        (should (eq 'none (gethash remote drgnx-explorer--watches)))
        (drgnx-explorer--unwatch-all)))))

;;;; M3b-1: compact folders, only for chains already listed

(defun drgnx-explorer-edge--names ()
  "The Explorer's rows as (DEPTH SHOWN-NAME) lists."
  (with-current-buffer drgnx-explorer-buffer-name
    (mapcar (lambda (v) (list (aref v 1) (aref v 0))) (cdr (append drgnx-explorer--rows nil)))))

(defmacro drgnx-explorer-edge--with-compact (root &rest body)
  "Like `drgnx-explorer-edge--with', with folders joined (the option is on)."
  (declare (indent 1))
  `(drgnx-explorer-edge--with ,root
     (setq drgnx-explorer-compact-folders t)
     (drgnx-explorer-refresh)
     ,@body))

(defmacro drgnx-explorer-edge--counting (var &rest body)
  "BODY with VAR collecting the folders `drgnx-explorer-children' really read from disk."
  (declare (indent 1))
  `(let ((,var nil)
         (orig (symbol-function 'directory-files-and-attributes)))
     (cl-letf (((symbol-function 'directory-files-and-attributes)
                (lambda (dir &rest a) (push (directory-file-name dir) ,var) (apply orig dir a))))
       ,@body)))

(ert-deftest drgnx-explorer-edge/compact-folders-follow-listings-already-read ()
  (drgnx-explorer-edge--with-compact root
    (drgnx-explorer-edge--tree root '("pkg/a/b/c.txt" "pkg/a/b/d.txt"))
    (drgnx-explorer-refresh)
    (let ((pkg (expand-file-name "pkg" root)))
      ;; closed: nothing is read for it, the row is plain
      (should (member '(1 "pkg") (drgnx-explorer-edge--names)))
      (drgnx-explorer-edge--counting read
        ;; opening pkg reads pkg only: its one subfolder a joins the row, a is not read (it is closed)
        (with-current-buffer (drgnx-explorer-edge--at "pkg") (drgnx-explorer-toggle-at (point)))
        (should (equal read (list pkg)))
        (should (member '(1 "pkg/a") (drgnx-explorer-edge--names)))
        (should-not (member '(1 "pkg") (drgnx-explorer-edge--names)))
        (should (equal (with-current-buffer (drgnx-explorer-edge--at "a") (drgnx-explorer-node-at (point)))
                       (expand-file-name "pkg/a" root))))
      ;; opening a (the row's folder) reads a, and b — its only subfolder — joins the row
      (with-current-buffer (drgnx-explorer-edge--at "a") (drgnx-explorer-toggle-at (point)))
      (should (member '(1 "pkg/a/b") (drgnx-explorer-edge--names)))
      ;; opening b: two files below the row
      (with-current-buffer (drgnx-explorer-edge--at "b") (drgnx-explorer-toggle-at (point)))
      (should (equal (seq-filter (lambda (r) (> (car r) 0)) (drgnx-explorer-edge--names))
                     '((1 "docs") (1 "pkg/a/b") (2 "c.txt") (2 "d.txt") (1 "src") (1 "tests") (1 "README.md"))))
      ;; closing b leaves the chain
      (with-current-buffer (drgnx-explorer-edge--at "b") (drgnx-explorer-toggle-at (point)))
      (should (member '(1 "pkg/a/b") (drgnx-explorer-edge--names)))
      (should-not (member '(2 "c.txt") (drgnx-explorer-edge--names))))))

(ert-deftest drgnx-explorer-edge/a-folder-with-a-sibling-or-a-file-is-not-compact ()
  (drgnx-explorer-edge--with-compact root
    (with-current-buffer (drgnx-explorer-edge--at "docs") (drgnx-explorer-toggle-at (point)))   ; guide.md and sub/
    (should (member '(1 "docs") (drgnx-explorer-edge--names)))
    (should (member '(2 "sub") (drgnx-explorer-edge--names)))
    (with-current-buffer (drgnx-explorer-edge--at "src") (drgnx-explorer-toggle-at (point)))    ; app/ alone
    (should (member '(1 "src/app") (drgnx-explorer-edge--names)))
    ;; … until it gets a sibling (a file event, here by hand): src and app are two rows again
    (write-region "" nil (expand-file-name "src/extra.txt" root) nil 'silent)
    (with-current-buffer drgnx-explorer-buffer-name (drgnx-explorer--refresh-dir (expand-file-name "src" root)))
    (should (member '(1 "src") (drgnx-explorer-edge--names)))
    (should (member '(2 "app") (drgnx-explorer-edge--names)))
    ;; and merges again when the sibling goes
    (delete-file (expand-file-name "src/extra.txt" root))
    (with-current-buffer drgnx-explorer-buffer-name (drgnx-explorer--refresh-dir (expand-file-name "src" root)))
    (should (member '(1 "src/app") (drgnx-explorer-edge--names)))))

(ert-deftest drgnx-explorer-edge/reveal-and-watches-see-through-a-compact-row ()
  (drgnx-explorer-edge--with-compact root
    (drgnx-explorer-edge--tree root '("pkg/a/b/c.txt"))
    (drgnx-explorer-refresh)
    (let ((file (expand-file-name "pkg/a/b/c.txt" root)))
      (should (drgnx-explorer-reveal file))
      (should (member '(1 "pkg/a/b") (drgnx-explorer-edge--names)))
      (should (member '(2 "c.txt") (drgnx-explorer-edge--names)))
      (with-current-buffer drgnx-explorer-buffer-name
        (should (equal (drgnx-explorer-node-at (drgnx-explorer--row-pos file)) file))
        ;; every folder of the chain is watched: a new file in pkg/a breaks the chain
        (let ((shown (drgnx-explorer--shown-folders)))
          (dolist (d '("pkg" "pkg/a" "pkg/a/b")) (should (member (expand-file-name d root) shown)))))
      (write-region "" nil (expand-file-name "pkg/a/x.txt" root) nil 'silent)
      (with-current-buffer drgnx-explorer-buffer-name (drgnx-explorer--refresh-dir (expand-file-name "pkg/a" root)))
      (should (member '(1 "pkg/a") (drgnx-explorer-edge--names)))
      (should (member '(2 "b") (drgnx-explorer-edge--names)))
      (should (member '(3 "c.txt") (drgnx-explorer-edge--names))))))
