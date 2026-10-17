;;; wb-persist-test.el --- batch tests: the workbench survives a restart -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-persist)

(defmacro drgnx-persist-test--with (dir &rest body)
  "BODY with rules and chrome on, a dock section, one editor window, files in DIR, a state file."
  (declare (indent 1))
  `(let* ((,dir (file-name-as-directory (make-temp-file "drgnx-persist" t)))
          (drgnx-persist-file (expand-file-name "state.eld" ,dir))
          (drgnx-wb--sections nil) (drgnx-signal--editor-window nil) (display-buffer-alist nil))
     (delete-other-windows)
     (dolist (p '(drgnx-tabs)) (set-window-parameter (selected-window) p nil))
     (set-window-prev-buffers (selected-window) nil)
     (dolist (p '(drgnx-wb-areas drgnx-wb-panel-px drgnx-wb-right-px drgnx-wb-dock-px)) (set-frame-parameter nil p nil))
     (drgnx-wb-define-section 'top :slot 0 :title "TOP" :buffer (lambda () (get-buffer-create "*drgnx-test-top*")))
     (drgnx-rules-mode 1)
     (drgnx-chrome-mode 1)
     (unwind-protect (progn ,@body)
       (drgnx-chrome-mode -1)
       (drgnx-rules-mode -1)
       (drgnx-wb-area-hide 'panel)
       (drgnx-wb-hide-sidebar)
       (delete-other-windows)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p ,dir (buffer-file-name b))) (kill-buffer b)))
       (when (get-buffer "*drgnx-test-top*") (kill-buffer "*drgnx-test-top*"))
       (delete-directory ,dir t))))

(defun drgnx-persist-test--file (dir name)
  (let ((f (expand-file-name name dir))) (write-region "x\n" nil f nil 'silent) (find-file-noselect f)))

(defun drgnx-persist-test--layout ()
  "What a restore must bring back: per group its tab files and shown file; dock and panel."
  (list (mapcar (lambda (g) (list (mapcar #'buffer-file-name (drgnx-chrome-tabs g)) (buffer-file-name (window-buffer g))))
                (drgnx-groups-list))
        (drgnx-wb-sidebar-showing-p)
        (and (drgnx-wb-area-window 'panel) (drgnx-wb-area-tab 'panel))))

(defun drgnx-persist-test--reset ()
  (drgnx-wb-area-hide 'panel)
  (drgnx-wb-hide-sidebar)
  (delete-other-windows)
  (switch-to-buffer "*scratch*")
  (dolist (p '(drgnx-tabs)) (set-window-parameter (selected-window) p nil))
  (set-window-prev-buffers (selected-window) nil))

(ert-deftest drgnx-persist/a-round-trip-brings-the-layout-back ()
  (drgnx-persist-test--with dir
    (switch-to-buffer (drgnx-persist-test--file dir "a.txt"))
    (switch-to-buffer (drgnx-persist-test--file dir "b.txt"))
    (drgnx-chrome-apply nil t)
    (drgnx-groups-split-right)
    (switch-to-buffer (drgnx-persist-test--file dir "c.txt"))
    (drgnx-chrome-apply nil t)
    (drgnx-wb-show-sidebar)
    (drgnx-wb-area-show 'panel 'results)
    (let ((before (drgnx-persist-test--layout)))
      (drgnx-persist-save)
      (drgnx-persist-test--reset)
      (should-not (equal before (drgnx-persist-test--layout)))
      (drgnx-persist-restore)
      (should (equal before (drgnx-persist-test--layout))))))

(ert-deftest drgnx-persist/missing-files-are-skipped ()
  (drgnx-persist-test--with dir
    (let ((a (drgnx-persist-test--file dir "a.txt")) (gone (drgnx-persist-test--file dir "gone.txt")))
      (switch-to-buffer a) (drgnx-chrome-apply nil t) (switch-to-buffer gone) (drgnx-chrome-apply nil t)
      (drgnx-persist-save)
      (drgnx-persist-test--reset)
      (kill-buffer gone)
      (delete-file (expand-file-name "gone.txt" dir))
      (drgnx-persist-restore)
      (should (equal (mapcar #'buffer-file-name (drgnx-chrome-tabs (car (drgnx-groups-list))))
                     (list (expand-file-name "a.txt" dir)))))))

(ert-deftest drgnx-persist/an-unknown-version-is-ignored ()
  (drgnx-persist-test--with dir
    (with-temp-file drgnx-persist-file (prin1 '(:version 99 :left (:shown t)) (current-buffer)))
    (should-not (drgnx-persist-restore))
    (should-not (drgnx-wb-sidebar-showing-p))))

(ert-deftest drgnx-persist/sizes-are-clamped-to-the-frame ()
  (drgnx-persist-test--with dir
    (with-temp-file drgnx-persist-file
      (prin1 `(:version 1 :left (:shown t :px 100000) :panel (:shown t :px 100000 :tab output) :right (:shown nil)
                        :groups nil :main nil)
             (current-buffer)))
    (drgnx-persist-restore)
    (let ((w (window-pixel-width (drgnx-wb-section-window 'top))))
      (should (< w (frame-pixel-width)))
      (should (>= w (* 0.45 (frame-pixel-width)))))      ; clamped to half the frame, not left at the default
    (should (< (window-pixel-height (drgnx-wb-area-window 'panel)) (frame-pixel-height)))))

(ert-deftest drgnx-persist/a-fresh-emacs-keeps-the-group-tree ()
  ;; I2: after a restart no saved file is visited yet; a top/bottom split must stay top/bottom.
  (drgnx-persist-test--with dir
    (switch-to-buffer (drgnx-persist-test--file dir "a.txt")) (drgnx-chrome-apply nil t)
    (drgnx-groups-split-down)
    (switch-to-buffer (drgnx-persist-test--file dir "b.txt")) (drgnx-chrome-apply nil t)
    (drgnx-persist-save)
    (drgnx-persist-test--reset)
    (dolist (b (buffer-list)) (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b))) (kill-buffer b)))
    (drgnx-persist-restore)
    (let ((g (drgnx-groups-list)))
      (should (= 2 (length g)))
      (should (= (window-pixel-left (car g)) (window-pixel-left (cadr g))))     ; stacked, not side by side
      (should (equal (buffer-file-name (window-buffer (cadr g))) (expand-file-name "b.txt" dir))))))

(ert-deftest drgnx-persist/a-small-frame-gets-what-fits ()
  ;; I3: nine saved groups, an 80-column frame: no error, the docks still come back.
  (drgnx-persist-test--with dir
    (with-temp-file drgnx-persist-file
      (prin1 `(:version 1 :left (:shown t :px 20) :panel (:shown nil) :right (:shown nil) :main nil
                        :groups ,(make-list 9 '(:tabs nil :shown nil)))
             (current-buffer)))
    (should (drgnx-persist-restore))
    (should (drgnx-wb-sidebar-showing-p))))

(ert-deftest drgnx-persist/the-graphical-frame-is-restored-and-saved ()
  ;; I4: a daemon's first client frame is made inside `make-frame', before it is selected; the
  ;; restore and the save on closing the last graphical frame use that frame.
  (drgnx-persist-test--with dir
    (let ((f (selected-frame)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional x) (eq (or x (selected-frame)) f))))
        (should (eq (drgnx-persist--gui-frame) f))
        (drgnx-persist--on-delete-frame f)
        (should (file-exists-p drgnx-persist-file)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil)))
        (should-not (drgnx-persist--gui-frame))))))

(ert-deftest drgnx-persist/tabs-load-lazily-and-safely ()
  ;; I5: at start only each group's shown file is visited; the other tabs follow at idle, in
  ;; order; remote tabs are never touched (no connection, no password prompt).
  (drgnx-persist-test--with dir
    (with-temp-file drgnx-persist-file
      (prin1 `(:version 1 :left (:shown nil) :panel (:shown nil) :right (:shown nil) :main nil
                        :groups ((:tabs (,(expand-file-name "a.txt" dir) "/ssh:nobody@example.invalid:/x"
                                         ,(expand-file-name "b.txt" dir) ,(expand-file-name "c.txt" dir))
                                        :shown ,(expand-file-name "b.txt" dir))))
             (current-buffer)))
    (dolist (n '("a.txt" "b.txt" "c.txt")) (write-region "x\n" nil (expand-file-name n dir) nil 'silent))
    (cl-letf (((symbol-function 'file-remote-p) (lambda (f &rest _) (and (stringp f) (string-prefix-p "/ssh:" f))))
              ((symbol-function 'tramp-file-name-handler) (lambda (&rest _) (error "touched a remote file"))))
      (drgnx-persist-restore)
      (should-not (get-file-buffer (expand-file-name "a.txt" dir)))
      (should (equal (mapcar #'buffer-file-name (drgnx-chrome-tabs (car (drgnx-groups-list))))
                     (list (expand-file-name "b.txt" dir))))
      (drgnx-persist-save)                              ; saved before the tabs were visited: none lost
      (should (= 4 (length (plist-get (car (plist-get (car (plist-get (drgnx-persist--read drgnx-persist-file) :frames)) :groups)) :tabs))))
      (while (drgnx-persist--visit-pending))
      (should (equal (mapcar #'buffer-file-name (drgnx-chrome-tabs (car (drgnx-groups-list))))
                     (mapcar (lambda (n) (expand-file-name n dir)) '("a.txt" "b.txt" "c.txt")))))))

(ert-deftest drgnx-persist/custom-frames-restore-by-their-function ()
  ;; a window that rebuilds itself (a job window) is saved as its function and restored by calling it
  (let ((called nil) (file (make-temp-file "drgnx-persist" nil ".eld")))
    (unwind-protect
        (progn
          (set-frame-parameter nil 'drgnx-persist-restore '(drgnx-persist-test--rebuild "j1"))
          (should (equal (drgnx-persist-state) '(:role custom :restore (drgnx-persist-test--rebuild "j1"))))
          (set-frame-parameter nil 'drgnx-persist-restore nil)
          (with-temp-file file
            (prin1 (list :version 2 :frames (list (drgnx-persist-state) '(:role custom :restore (drgnx-persist-test--rebuild "j1"))
                                                  '(:role custom :restore (drgnx-persist-test--gone 1))))
                   (current-buffer)))
          (cl-letf (((symbol-function 'drgnx-persist-test--rebuild) (lambda (&rest args) (push args called))))
            (drgnx-persist-restore file))
          (should (equal called '(("j1")))))
      (set-frame-parameter nil 'drgnx-persist-restore nil)
      (delete-file file))))

(ert-deftest drgnx-persist/the-file-lists-every-window ()
  ;; Format 2: one entry per window (the main one first); format 1 files (one window) still restore.
  (drgnx-persist-test--with dir
    (switch-to-buffer (drgnx-persist-test--file dir "a.txt")) (drgnx-chrome-apply nil t)
    (drgnx-persist-save)
    (let ((state (drgnx-persist--read drgnx-persist-file)))
      (should (eql 2 (plist-get state :version)))
      (should (= 1 (length (plist-get state :frames))))
      (should (plist-get (car (plist-get state :frames)) :groups)))))
