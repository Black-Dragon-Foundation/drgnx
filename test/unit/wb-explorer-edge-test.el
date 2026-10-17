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

;;; wb-explorer-edge-test.el ends here
