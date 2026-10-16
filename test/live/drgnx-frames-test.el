;;; drgnx-frames-test.el --- live: several windows (frames) in a GUI session (config=drgnx) -*- lexical-binding: t -*-
;; Frames need a graphical session: batch Emacs cannot make them.
(require 'ert)
(require 'drgnx-ui)

(defmacro drgnx-frames-test--with (sess &rest body)
  "BODY with SESS a session whose editor shows README.md of a fixture project; `kx-f1' is its frame."
  (declare (indent 1))
  `(let* ((root (make-temp-file "drgnx-frames" t))
          (project (file-name-as-directory (expand-file-name "project" root)))
          (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
          (s (progn
               (dolist (f '("README.md" "a.txt" "b.txt")) (make-directory project t)
                       (write-region (format "%s\n" f) nil (expand-file-name f project) nil 'silent))
               (drgnx-ui-start "drgnx" "1400x800" 30)))
          (,sess (drgnx-ui-own-session (plist-get s :name))))
     (unwind-protect
         (progn
           (drgnx-ui-call ,sess (format "(progn (defvar kx-f1 (selected-frame)) (defvar kx-f2 nil) (defvar kx-dir %S)
                                                (find-file (expand-file-name \"README.md\" kx-dir))
                                                (drgnx-explorer-set-roots (list kx-dir))
                                                (drgnx-uitest--json (list :ok t)))" project))
           (drgnx-ui-measure ,sess nil)
           ,@body)
       (drgnx-ui-stop (plist-get s :name))
       (delete-directory root t))))

(defun drgnx-frames-test--eval (sess form)
  "FORM's value (any Lisp value, printed) from the session."
  (car (read-from-string
        (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json (list :v (prin1-to-string %s)))" form)) :v))))

(defconst drgnx-frames-test--geometry
  "(mapcar #'window-pixel-edges (window-list kx-f1 'nomini))")

(ert-deftest drgnx-frames/a-new-window-is-editor-only ()
  (drgnx-frames-test--with sess
    (drgnx-ui-measure sess (list (list :keys "C-b")))
    (let ((g1 (drgnx-frames-test--eval sess drgnx-frames-test--geometry)))
      (drgnx-frames-test--eval sess "(progn (setq kx-f2 (make-frame)) t)")
      (drgnx-ui-measure sess nil)
      (should (equal (drgnx-frames-test--eval sess "(list (drgnx-frame-role kx-f1) (drgnx-frame-role kx-f2))") '(main aux)))
      (should (equal (drgnx-frames-test--eval sess "(length (drgnx-wb--dock-windows kx-f2))") 0))
      (should (> (drgnx-frames-test--eval sess "(window-tab-line-height (frame-first-window kx-f2))") 0))
      ;; The sidebar of the second window, help shown from it: frame 1 does not move (RF2).
      (drgnx-frames-test--eval sess "(progn (select-frame-set-input-focus kx-f2) t)")
      (drgnx-ui-measure sess (list (list :keys "C-b")))
      (drgnx-frames-test--eval sess "(with-selected-frame kx-f2 (describe-function 'car) t)")
      (drgnx-ui-measure sess nil)
      (should (> (drgnx-frames-test--eval sess "(length (drgnx-wb--dock-windows kx-f2))") 0))
      (should (drgnx-frames-test--eval sess "(eq (window-frame (drgnx-wb-area-window 'panel kx-f2)) kx-f2)"))
      (should-not (drgnx-frames-test--eval sess "(drgnx-wb-area-window 'panel kx-f1)"))
      (should (equal (drgnx-frames-test--eval sess drgnx-frames-test--geometry) g1))
      ;; Closing it (RF1): frame 1 does not move, frame 1 is still the main window.
      (drgnx-frames-test--eval sess "(progn (delete-frame kx-f2) t)")
      (drgnx-ui-measure sess nil)
      (should (equal (drgnx-frames-test--eval sess drgnx-frames-test--geometry) g1))
      (should (eq (drgnx-frames-test--eval sess "(drgnx-frame-role kx-f1)") 'main)))))

(ert-deftest drgnx-frames/editors-and-groups-move-to-new-windows ()
  (drgnx-frames-test--with sess
    ;; Move Editor to New Window: README leaves frame 1's tabs.
    (drgnx-frames-test--eval sess "(progn (find-file (expand-file-name \"a.txt\" kx-dir)) (drgnx-chrome-apply nil t) t)")
    (drgnx-frames-test--eval sess "(progn (drgnx-frames-move-editor) (setq kx-f2 (selected-frame)) t)")
    (drgnx-ui-measure sess nil)
    (should (equal (drgnx-frames-test--eval sess "(mapcar #'buffer-name (drgnx-chrome-tabs (frame-first-window kx-f2)))") '("a.txt")))
    (should-not (member "a.txt" (drgnx-frames-test--eval sess "(with-selected-frame kx-f1 (mapcar #'buffer-name (drgnx-chrome-tabs (car (drgnx-groups-list)))))")))
    ;; Open in New Window: the same buffer in both; closing its tab in one keeps it in the other (RF4).
    (drgnx-frames-test--eval sess "(progn (select-frame-set-input-focus kx-f1) (drgnx-frames-open-editor) t)")
    (drgnx-ui-measure sess nil)
    (should (= 3 (drgnx-frames-test--eval sess "(length (frame-list))")))
    (drgnx-frames-test--eval sess "(progn (drgnx-chrome-close-tab) t)")
    (should (member "README.md" (drgnx-frames-test--eval sess "(with-selected-frame kx-f1 (mapcar #'buffer-name (drgnx-chrome-tabs (car (drgnx-groups-list)))))")))
    ;; Move Editor Group to New Window: frame 1's second group (b.txt) moves with its tabs.
    (drgnx-frames-test--eval sess "(progn (select-frame-set-input-focus kx-f1) (drgnx-groups-split-right) (find-file (expand-file-name \"b.txt\" kx-dir)) (drgnx-chrome-apply nil t) t)")
    (drgnx-frames-test--eval sess "(progn (drgnx-frames-move-group) t)")
    (drgnx-ui-measure sess nil)
    (should (= 1 (drgnx-frames-test--eval sess "(length (drgnx-groups-list kx-f1))")))
    (should (member "b.txt" (drgnx-frames-test--eval sess "(mapcar #'buffer-name (drgnx-chrome-tabs (frame-first-window (selected-frame))))")))))

(ert-deftest drgnx-frames/each-window-lists-its-own-buffers ()
  (drgnx-frames-test--with sess
    (drgnx-frames-test--eval sess "(progn (find-file (expand-file-name \"a.txt\" kx-dir)) (drgnx-chrome-apply nil t) (drgnx-frames-move-editor) (setq kx-f2 (selected-frame)) (drgnx-chrome-apply kx-f2 t) t)")
    (drgnx-ui-measure sess nil)
    (should (equal (drgnx-frames-test--eval sess "(mapcar #'buffer-name (drgnx-frame-buffers kx-f2))") '("a.txt")))
    (should-not (member "a.txt" (drgnx-frames-test--eval sess "(mapcar #'buffer-name (drgnx-frame-buffers kx-f1))")))
    (should (member "README.md" (drgnx-frames-test--eval sess "(mapcar #'buffer-name (drgnx-frame-buffers kx-f1))")))
    ;; The Buffers panel lists the selected window's buffers; the toggle lists all.
    (drgnx-frames-test--eval sess "(progn (select-frame-set-input-focus kx-f2) (drgnx-wb-show-sidebar) (drgnx-buffers--refresh) t)")
    (should-not (member "README.md" (drgnx-frames-test--eval sess "(mapcar #'buffer-name (drgnx-buffers--shown))")))
    (drgnx-frames-test--eval sess "(progn (drgnx-buffers-toggle-all-windows) t)")
    (should (member "README.md" (drgnx-frames-test--eval sess "(mapcar #'buffer-name (drgnx-buffers--shown))")))))

(ert-deftest drgnx-frames/every-window-survives-a-restart ()
  ;; Session A: a second window with a.txt; it exits (saved). Session B restores both windows.
  (let* ((root (make-temp-file "drgnx-frames-restart" t))
         (file (expand-file-name "workbench.eld" root))
         (project (file-name-as-directory (expand-file-name "project" root)))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment)))
    (dolist (f '("README.md" "a.txt")) (make-directory project t)
            (write-region "x\n" nil (expand-file-name f project) nil 'silent))
    (unwind-protect
        (let* ((s (drgnx-ui-start "drgnx" "1400x800" 30)) (sess (drgnx-ui-own-session (plist-get s :name))))
          (drgnx-ui-call sess (format "(progn (setq drgnx-persist-file %S)
                                         (find-file %S) (drgnx-chrome-apply nil t)
                                         (find-file %S) (drgnx-chrome-apply nil t)
                                         (drgnx-frames-move-editor)
                                         (drgnx-uitest--json (list :ok t)))"
                                      file (expand-file-name "README.md" project) (expand-file-name "a.txt" project)))
          (drgnx-ui-measure sess nil)
          (drgnx-ui-stop (plist-get s :name))
          (should (= 2 (length (plist-get (with-temp-buffer (insert-file-contents file) (read (current-buffer))) :frames))))
          (let* ((s2 (drgnx-ui-start "drgnx" "1400x800" 30)) (sess2 (drgnx-ui-own-session (plist-get s2 :name))))
            (unwind-protect
                (progn
                  (drgnx-ui-call sess2 (format "(progn (setq drgnx-persist-file %S) (drgnx-persist-restore) (drgnx-uitest--json (list :ok t)))" file))
                  (drgnx-ui-measure sess2 nil)
                  (should (equal (drgnx-frames-test--eval sess2 "(length (seq-remove #'frame-parent (frame-list)))") 2))
                  (should (member "a.txt" (drgnx-frames-test--eval
                                           sess2 "(mapcar #'buffer-name (seq-mapcat (lambda (f) (drgnx-chrome-tabs (frame-first-window f))) (seq-remove (lambda (f) (eq f (selected-frame))) (frame-list))))"))))
              (drgnx-ui-stop (plist-get s2 :name)))))
      (delete-directory root t))))
