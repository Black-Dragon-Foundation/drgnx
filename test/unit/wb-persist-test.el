;;; wb-persist-test.el --- batch tests: the workbench survives a restart -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-persist)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

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
       (drgnx-timer-cancel 'persist-visit)
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

;;;; The other tabs, on the clock fixture

(defun drgnx-persist-test--five (dir)
  "Write five files in DIR and a state file with them as one group's tabs (the second shown); return the files."
  (let ((files (mapcar (lambda (n) (expand-file-name n dir)) '("a.txt" "b.txt" "c.txt" "d.txt" "e.txt"))))
    (dolist (f files) (write-region "x\n" nil f nil 'silent))
    (with-temp-file drgnx-persist-file
      (prin1 `(:version 1 :left (:shown nil) :panel (:shown nil) :right (:shown nil) :main nil
                        :groups ((:tabs ,files :shown ,(nth 1 files))))
             (current-buffer)))
    files))

(defun drgnx-persist-test--tabs ()
  (mapcar #'buffer-file-name (drgnx-chrome-tabs (car (drgnx-groups-list)))))

(ert-deftest drgnx-persist/other-tabs-open-in-one-pause ()
  ;; B2: a repeating idle timer runs once per pause, so the other tabs came one per pause.  The layer's idle steps
  ;; open them all in the first pause, in order, and leave no timer.
  (drgnx-persist-test--with dir
    (drgnx-test-with-clock ()
      (let ((files (drgnx-persist-test--five dir)))
        (drgnx-persist-restore)
        (should (= 1 (length (drgnx-persist-test--tabs))))
        (should (drgnx-timer-active-p 'persist-visit))
        (drgnx-test-idle 3)
        (should (equal (drgnx-persist-test--tabs) files))
        (should-not (drgnx-timer-active-p 'persist-visit))
        (should-not timer-idle-list)))))

(ert-deftest drgnx-persist/typing-stops-the-visits-until-the-next-pause ()
  (drgnx-persist-test--with dir
    (drgnx-test-with-clock ()
      (let ((files (drgnx-persist-test--five dir)) (visited 0))
        (drgnx-persist-restore)
        (cl-letf* ((visit (symbol-function 'drgnx-persist--visit))
                   ((symbol-function 'drgnx-persist--visit)
                    (lambda (f) (cl-incf visited) (funcall visit f)))
                   ((symbol-function 'drgnx-timer--input-pending-p) (lambda () (> visited 0))))
          (drgnx-test-idle 3))                          ; you type after the first visit
        (should (= 2 (length (drgnx-persist-test--tabs))))
        (should (drgnx-timer-active-p 'persist-visit))
        (drgnx-test-idle 3)                             ; the next pause: the rest
        (should (equal (drgnx-persist-test--tabs) files))
        (should-not (drgnx-timer-active-p 'persist-visit))))))

(ert-deftest drgnx-persist/persist-mode-off-stops-the-visits ()
  (drgnx-persist-test--with dir
    (drgnx-test-with-clock ()
      (drgnx-persist-test--five dir)
      (drgnx-persist-restore)
      (should (drgnx-timer-active-p 'persist-visit))
      (let ((drgnx-persist-mode t)) (drgnx-persist-mode -1))
      (should-not (drgnx-timer-active-p 'persist-visit))
      (drgnx-test-idle 3)
      (should (= 1 (length (drgnx-persist-test--tabs)))))))

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
          (cl-letf (((symbol-function 'drgnx-persist-test--rebuild) (lambda (&rest args) (push args called)))
                    ((symbol-function 'drgnx-persist--gui-frame) #'selected-frame))   ; a job window needs a graphical display
            (drgnx-persist-restore file))
          (should (equal called '(("j1")))))
      (set-frame-parameter nil 'drgnx-persist-restore nil)
      (delete-file file))))

(ert-deftest drgnx-persist/custom-frame-keeps-its-geometry ()
  ;; M9b4-9: a window that rebuilds itself comes back where and how big it was: pixel left, top, width, height,
  ;; applied to the frame the rebuilding function returns.
  (let ((frame (selected-frame)) placed sized (file (make-temp-file "drgnx-persist" nil ".eld")))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                    ((symbol-function 'frame-edges) (lambda (&rest _) '(10 20 810 620)))
                    ((symbol-function 'frame-pixel-width) (lambda (&rest _) 800))       ; the native size is not what is kept:
                    ((symbol-function 'frame-pixel-height) (lambda (&rest _) 600))      ; `set-frame-size' sets the text area
                    ((symbol-function 'frame-text-width) (lambda (&rest _) 790))
                    ((symbol-function 'frame-text-height) (lambda (&rest _) 590)))
            (set-frame-parameter nil 'drgnx-persist-restore '(drgnx-persist-test--rebuild "j1"))
            (should (equal (drgnx-persist-state)
                           '(:role custom :restore (drgnx-persist-test--rebuild "j1") :geometry (10 20 790 590)))))
          (set-frame-parameter nil 'drgnx-persist-restore nil)
          (with-temp-file file
            (prin1 (list :version 2 :frames (list (drgnx-persist-state)
                                                  '(:role custom :restore (drgnx-persist-test--rebuild "j1") :geometry (30 40 700 500))
                                                  '(:role custom :restore (drgnx-persist-test--rebuild "j2") :geometry (1 2 "junk" 4))))
                   (current-buffer)))
          (cl-letf (((symbol-function 'drgnx-persist-test--rebuild) (lambda (&rest _) frame))
                    ((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                    ((symbol-function 'select-frame-set-input-focus) #'ignore)
                    ((symbol-function 'display-monitor-attributes-list) (lambda (&optional _) '(((workarea 0 0 1920 1080)))))
                    ((symbol-function 'set-frame-position) (lambda (f x y) (push (list f x y) placed)))
                    ((symbol-function 'set-frame-size) (lambda (f w h &optional pixelwise) (push (list f w h pixelwise) sized))))
            (drgnx-persist-restore file))
          (should (equal placed (list (list frame 30 40))))        ; the junk geometry is ignored
          (should (equal sized (list (list frame 700 500 t)))))
      (set-frame-parameter nil 'drgnx-persist-restore nil)
      (delete-file file))))

(defmacro drgnx-persist-test--with-monitors (areas &rest body)
  "BODY with the display's monitors having the work AREAS ((X Y WIDTH HEIGHT)…); `placed' and `sized' collect what
`drgnx-persist--place-frame' does to a frame."
  (declare (indent 1))
  `(let (placed sized)
     (cl-letf (((symbol-function 'display-monitor-attributes-list)
                (lambda (&optional _) (mapcar (lambda (a) (list (cons 'workarea a))) ,areas)))
               ((symbol-function 'set-frame-position) (lambda (f x y) (push (list x y) placed)))
               ((symbol-function 'set-frame-size) (lambda (f w h &optional pixelwise) (push (list w h pixelwise) sized))))
       ,@body)))

(ert-deftest drgnx-persist/a-saved-position-is-used-only-where-a-monitor-is ()
  ;; I4: a monitor that was unplugged leaves a position nobody can reach; the window manager places the window
  ;; then, and a size is never bigger than the work area.
  (drgnx-persist-test--with-monitors '((0 0 1920 1080) (1920 0 1280 1024))
    (drgnx-persist--place-frame (selected-frame) '(2000 40 700 500))                ; on the second monitor
    (should (equal placed '((2000 40)))) (should (equal sized '((700 500 t))))
    (setq placed nil sized nil)
    (drgnx-persist--place-frame (selected-frame) '(5000 40 700 500))                ; on none
    (should-not placed) (should (equal sized '((700 500 t))))
    (setq placed nil sized nil)
    (drgnx-persist--place-frame (selected-frame) '(100 50 4000 3000))               ; too big for its monitor
    (should (equal placed '((100 50)))) (should (equal sized '((1820 1030 t))))     ; the work area less the offset
    (setq placed nil sized nil)
    (drgnx-persist--place-frame (selected-frame) '(-300 20 700 500))                ; left of everything
    (should-not placed)))

(ert-deftest drgnx-persist/a-closed-job-window-never-replaces-the-workbench-save ()
  ;; M2: closing a window that rebuilds itself, as the last graphical one, must not write a file holding only it
  (drgnx-persist-test--with dir
    (let ((f (selected-frame)))
      (set-frame-parameter f 'drgnx-persist-restore '(ignore))
      (unwind-protect
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t)))
            (drgnx-persist--on-delete-frame f)
            (should-not (file-exists-p drgnx-persist-file)))
        (set-frame-parameter f 'drgnx-persist-restore nil)))))

(ert-deftest drgnx-persist/a-file-of-only-job-windows-leaves-the-selected-frame-alone ()
  (drgnx-persist-test--with dir
    (let ((rebuilt 0) (restored 0) (role (frame-parameter nil 'drgnx-frame-role)))
      (with-temp-file drgnx-persist-file
        (prin1 '(:version 2 :frames ((:role custom :restore (drgnx-persist-test--rebuild "j1")))) (current-buffer)))
      (unwind-protect
          (progn
            (set-frame-parameter nil 'drgnx-frame-role 'aux)     ; whatever role earlier tests left: it must stay
            (cl-letf (((symbol-function 'drgnx-persist-test--rebuild) (lambda (&rest _) (cl-incf rebuilt) nil))
                      ((symbol-function 'drgnx-persist--gui-frame) #'selected-frame)
                      ((symbol-function 'drgnx-persist--restore-frame) (lambda (_st) (cl-incf restored)))
                      ((symbol-function 'select-frame-set-input-focus) #'ignore))
              (drgnx-persist-restore))
            (should (= rebuilt 1))
            (should (= restored 0))
            (should (eq (frame-parameter nil 'drgnx-frame-role) 'aux)))
        (set-frame-parameter nil 'drgnx-frame-role role)))))

(ert-deftest drgnx-persist/the-file-lists-every-window ()
  ;; Format 2: one entry per window (the main one first); format 1 files (one window) still restore.
  (drgnx-persist-test--with dir
    (switch-to-buffer (drgnx-persist-test--file dir "a.txt")) (drgnx-chrome-apply nil t)
    (drgnx-persist-save)
    (let ((state (drgnx-persist--read drgnx-persist-file)))
      (should (eql 2 (plist-get state :version)))
      (should (= 1 (length (plist-get state :frames))))
      (should (plist-get (car (plist-get state :frames)) :groups)))))

;;; Reopening: a daemon that keeps running restores whenever its first window opens after none.

(defmacro drgnx-persist-test--graphical (&rest body)
  "BODY with the selected frame the only graphical one and not yet restored."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
             ((symbol-function 'select-frame-set-input-focus) #'ignore)   ; a batch frame has no window system
             ((symbol-function 'frame-list) (lambda () (list (selected-frame)))))
     (set-frame-parameter nil 'drgnx-persist-restored nil)
     (unwind-protect (progn ,@body)
       (set-frame-parameter nil 'drgnx-persist-restored nil))))

(ert-deftest drgnx-persist/the-first-window-after-none-restores ()
  (drgnx-persist-test--with dir
    (drgnx-persist-test--graphical
      (let ((calls 0) (drgnx-persist-restore-on-start t))
        (cl-letf (((symbol-function 'drgnx-persist-restore) (lambda (&rest _) (cl-incf calls) t)))
          (drgnx-persist--on-delete-frame (selected-frame))        ; the last window closes: state saved
          (should (file-exists-p drgnx-persist-file))
          (drgnx-persist--on-new-frame (selected-frame))           ; a new window opens
          (should (= 1 calls))
          (drgnx-persist--on-new-frame)                            ; the hook gives no argument: the selected frame
          (should (= 1 calls)))))))                                ; once per opening

(ert-deftest drgnx-persist/a-first-start-restore-is-not-repeated ()
  ;; A daemon's first `emacsclient -c' runs the first-frame hook and then `server-after-make-frame-hook'.
  (drgnx-persist-test--with dir
    (drgnx-persist-test--graphical
      (let ((calls 0) (drgnx-persist-restore-on-start t))
        (cl-letf (((symbol-function 'drgnx-persist-restore) (lambda (&rest _) (cl-incf calls) t)))
          (drgnx-persist--on-start)
          (drgnx-persist--on-new-frame (selected-frame))
          (should (= 1 calls)))))))

(ert-deftest drgnx-persist/a-daemons-first-client-window-restores-after-the-server-shows-its-buffer ()
  ;; The first-frame stage runs inside `make-frame'; a client that asked for no file then gets *scratch*
  ;; in its selected window (server-execute) — so a client's window is restored from
  ;; `server-after-make-frame-hook', which runs after that, once.
  (drgnx-persist-test--with dir
    (drgnx-persist-test--graphical
      (let ((calls 0) (drgnx-persist-restore-on-start t))
        (cl-letf (((symbol-function 'drgnx-persist-restore) (lambda (&rest _) (cl-incf calls) t)))
          (set-frame-parameter nil 'client 'nowait)
          (unwind-protect
              (progn
                (drgnx-persist--on-start)
                (should (= 0 calls))
                (should-not (frame-parameter nil 'drgnx-persist-restored))
                (drgnx-persist--on-new-frame)
                (drgnx-persist--on-new-frame)
                (should (= 1 calls)))
            (set-frame-parameter nil 'client nil)))))))

(ert-deftest drgnx-persist/a-second-window-does-not-restore ()
  (drgnx-persist-test--with dir
    (drgnx-persist-test--graphical
      (let ((calls 0) (other (make-symbol "other-frame")) (drgnx-persist-restore-on-start t))
        (cl-letf (((symbol-function 'drgnx-persist-restore) (lambda (&rest _) (cl-incf calls) t))
                  ((symbol-function 'frame-parent) (lambda (&optional _) nil))
                  ((symbol-function 'frame-list) (lambda () (list (selected-frame) other))))
          (drgnx-persist--on-new-frame (selected-frame))
          (should (= 0 calls)))
        (cl-letf (((symbol-function 'drgnx-persist-restore) (lambda (&rest _) (cl-incf calls) t)) ; a terminal client
                  ((symbol-function 'display-graphic-p) (lambda (&optional _) nil)))
          (drgnx-persist--on-new-frame (selected-frame))
          (should (= 0 calls)))
        (let ((drgnx-persist-restore-on-start nil))
          (cl-letf (((symbol-function 'drgnx-persist-restore) (lambda (&rest _) (cl-incf calls) t)))
            (drgnx-persist--on-new-frame (selected-frame))
            (should (= 0 calls))))))))

(ert-deftest drgnx-persist/the-reopened-window-gets-what-the-last-close-saved ()
  (drgnx-persist-test--with dir
    (drgnx-persist-test--graphical
      (switch-to-buffer (drgnx-persist-test--file dir "a.txt"))
      (drgnx-chrome-apply nil t)
      (drgnx-groups-split-right)
      (switch-to-buffer (drgnx-persist-test--file dir "b.txt"))
      (drgnx-chrome-apply nil t)
      (drgnx-wb-show-sidebar)
      (let ((before (drgnx-persist-test--layout)))
        (drgnx-persist--on-delete-frame (selected-frame))
        (drgnx-persist-test--reset)
        (should-not (equal before (drgnx-persist-test--layout)))
        (drgnx-persist--on-new-frame (selected-frame))
        (should (equal before (drgnx-persist-test--layout)))))))

(ert-deftest drgnx-persist/a-requested-file-ends-up-in-front ()
  ;; The after-restore functions run once per restore, with the frame, after the layout is back: what
  ;; they show (the client's buffer) is not undone.
  (drgnx-persist-test--with dir
    (drgnx-persist-test--graphical
      (switch-to-buffer (drgnx-persist-test--file dir "a.txt"))
      (drgnx-chrome-apply nil t)
      (drgnx-persist--on-delete-frame (selected-frame))
      (drgnx-persist-test--reset)
      (let* ((asked (drgnx-persist-test--file dir "asked.txt")) seen told
             (drgnx-persist-after-restore-functions
              (list (lambda (frame)
                      (push (list frame (mapcar #'buffer-file-name (drgnx-chrome-tabs (car (drgnx-groups-list))))) seen)
                      (error "a failing function must not stop the others"))
                    (lambda (frame) (with-selected-frame frame (switch-to-buffer asked))))))
        (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) told))))
          (drgnx-persist--on-new-frame (selected-frame)))
        (should (equal seen (list (list (selected-frame) (list (expand-file-name "a.txt" dir))))))
        (should (cl-some (lambda (m) (string-search "after-restore function" m)) told))   ; said, not raised or logged
        (should (eq (window-buffer (selected-window)) asked))))))

(ert-deftest drgnx-persist/extras-a-bad-result-costs-only-its-own-keys ()
  ;; A state function returning a buffer, a non-list or an odd list is skipped (and said once); the
  ;; others' keys are saved and workbench.eld stays readable.
  (drgnx-persist-test--with dir
    (let* ((drgnx-persist--extra-reported nil) (told nil)
           (drgnx-persist-state-functions
            (list (lambda () (list :a 1))
                  (lambda () (list :buf (current-buffer)))
                  (lambda () 'junk)
                  (lambda () (list :odd))
                  (lambda () (error "boom"))
                  (lambda () (list :b 2)))))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) told))))
        (drgnx-persist-save)
        (drgnx-persist-save))
      (let ((extra (plist-get (car (plist-get (drgnx-persist--read drgnx-persist-file) :frames)) :extra)))
        (should (equal extra '(:a 1 :b 2))))
      (should (= 4 (length told)))                      ; each bad function once, not once per save
      (should (string-match-p "state function" (car told))))))

(ert-deftest drgnx-persist/extras-a-users-print-length-does-not-let-a-buffer-pass ()
  ;; With `print-length' set, a buffer inside a list would print as "(… …)" and look readable; the file would then hold it.
  (drgnx-persist-test--with dir
    (let ((drgnx-persist--extra-reported nil) (print-length 1) (print-level 1)
          (drgnx-persist-state-functions
           (list (lambda () (list :a 1))
                 (lambda () (list :buf (list 1 2 (current-buffer))))
                 (lambda () (list :b 2)))))
      (cl-letf (((symbol-function 'message) #'ignore))
        (drgnx-persist-save))
      (should (equal (plist-get (car (plist-get (drgnx-persist--read drgnx-persist-file) :frames)) :extra) '(:a 1 :b 2))))))
