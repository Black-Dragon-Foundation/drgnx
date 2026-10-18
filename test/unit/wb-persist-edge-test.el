;;; wb-persist-edge-test.el --- batch tests: restoring the workbench, edge cases -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-persist)

(defmacro drgnx-persist-edge-test--with (dir &rest body)
  "BODY with rules and chrome on, one editor window, files in DIR, a state file."
  (declare (indent 1))
  `(drgnx-test-with-state
     (let* ((,dir (file-name-as-directory (make-temp-file "drgnx-persist-edge" t)))
            (drgnx-persist-file (expand-file-name "state.eld" ,dir))
            (drgnx-persist--pending nil)
            (drgnx-wb--sections nil) (display-buffer-alist nil))
       (delete-other-windows)
       (set-window-parameter (selected-window) 'drgnx-tabs nil)
       (set-window-prev-buffers (selected-window) nil)
       (dolist (p '(drgnx-wb-areas drgnx-wb-panel-px drgnx-wb-right-px drgnx-wb-dock-px)) (set-frame-parameter nil p nil))
       (drgnx-rules-mode 1)
       (drgnx-chrome-mode 1)
       (unwind-protect (progn ,@body)
         (when (timerp drgnx-persist--timer) (cancel-timer drgnx-persist--timer))
         (setq drgnx-persist--timer nil)
         (drgnx-chrome-mode -1)
         (drgnx-rules-mode -1)
         (drgnx-wb-area-hide 'panel)
         (drgnx-wb-hide-sidebar)
         (delete-other-windows)
         (dolist (w (window-list)) (set-window-parameter w 'drgnx-test-crafted nil))
         (dolist (b (buffer-list))
           (when (and (buffer-file-name b) (string-prefix-p ,dir (buffer-file-name b))) (kill-buffer b)))
         (delete-directory ,dir t)))))

(ert-deftest drgnx-persist-edge/a-state-file-sets-no-window-parameters ()
  "M3d-4: the saved window tree is put back without the window parameters it carries (a crafted
file could set any)."
  (drgnx-persist-edge-test--with dir
    (let ((f (expand-file-name "a.txt" dir)))
      (write-region "x\n" nil f nil 'silent)
      (switch-to-buffer (find-file-noselect f))
      (drgnx-chrome-apply nil t)
      (set-window-parameter (selected-window) 'drgnx-test-crafted 'evil)
      (let ((window-persistent-parameters '((drgnx-test-crafted . writable))))
        (drgnx-persist-save))
      (should (string-search "drgnx-test-crafted" (with-temp-buffer (insert-file-contents drgnx-persist-file)
                                                                    (buffer-string))))
      (set-window-parameter (selected-window) 'drgnx-test-crafted nil)
      (should (drgnx-persist-restore))
      (should-not (seq-some (lambda (w) (window-parameter w 'drgnx-test-crafted)) (window-list)))
      (should (equal (buffer-file-name (window-buffer (car (drgnx-groups-list)))) f)))))

(ert-deftest drgnx-persist-edge/the-state-file-is-in-the-state-dir ()
  (let ((drgnx-persist-file nil)
        (process-environment (cons "XDG_STATE_HOME=/tmp/drgnx-persist-edge-state" process-environment)))
    (should (equal (drgnx-persist--file) (expand-file-name "workbench.eld" (drgnx-state-dir))))
    (should (equal (drgnx-persist--file) "/tmp/drgnx-persist-edge-state/drgnx/workbench.eld"))))

(ert-deftest drgnx-persist-edge/a-second-window-keeps-the-first-ones-tab-order ()
  "M3e-5: restoring a second window appends its groups' pending tabs; the first window's stay in
order (the whole shared list was reversed)."
  (drgnx-persist-edge-test--with dir
    (let ((state '(:left (:shown nil) :panel (:shown nil) :right (:shown nil) :main nil
                         :groups ((:tabs nil :shown nil) (:tabs nil :shown nil)))))
      (drgnx-persist--restore-frame state)
      (let ((first (mapcar #'car drgnx-persist--pending)))
        (should (equal first (drgnx-groups-list)))
        (drgnx-persist--restore-frame state)
        (should (= 4 (length drgnx-persist--pending)))
        (should (equal (seq-take (mapcar #'car drgnx-persist--pending) 2) first))))))

(defun drgnx-persist-edge-test--restored-order (frames)
  "The `:which' of each state in FRAMES (a list of plists), in the order the restore restored them: the selected
frame's first, then the others (each in a window of its own, stubbed here to the same frame)."
  (let (calls)
    (with-temp-file drgnx-persist-file
      (prin1 (list :version 2 :frames frames) (current-buffer)))
    (cl-letf (((symbol-function 'drgnx-persist--restore-frame)
               (lambda (st) (push (plist-get (plist-get st :extra) :which) calls)))
              ((symbol-function 'make-frame) (lambda (&rest _) (selected-frame)))
              ((symbol-function 'select-frame-set-input-focus) #'ignore))
      (should (drgnx-persist-restore)))
    (nreverse calls)))

(ert-deftest drgnx-persist-edge/role-main-goes-to-the-selected-frame ()
  "M3e-5: the state with `:role main' is restored into the selected frame wherever it stands in the file; the
others follow in order, each in a window of its own.  Without a main one, the first is."
  (drgnx-persist-edge-test--with dir
    (let ((role (frame-parameter nil (quote drgnx-frame-role))))
      (unwind-protect
          (progn
            (should (equal (drgnx-persist-edge-test--restored-order
                            (quote ((:role aux :extra (:which aux-1)) (:role main :extra (:which main)) (:role aux :extra (:which aux-2)))))
                           (quote (main aux-1 aux-2))))
            (should (eq (frame-parameter nil (quote drgnx-frame-role)) (quote main)))
            (should (equal (drgnx-persist-edge-test--restored-order
                            (quote ((:extra (:which first)) (:role aux :extra (:which second)))))
                           (quote (first second)))))
        (set-frame-parameter nil (quote drgnx-frame-role) role)))))

(ert-deftest drgnx-persist-edge/failed-restore-is-not-retried ()
  "M12a-12: a frame is marked restored before its restore runs, so a restore that fails does not run again at
the next window or hook (and the after-restore functions, which need a restored workbench, do not run)."
  (let ((calls 0) (hooked 0) (frame (selected-frame))
        (drgnx-persist-after-restore-functions (list (lambda (_f) (cl-incf hooked)))))
    (set-frame-parameter frame 'drgnx-persist-restored nil)
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-persist-restore) (lambda (&rest _) (cl-incf calls) (error "disk gone"))))
          (drgnx-persist--restore-into frame)
          (drgnx-persist--restore-into frame)
          (should (= 1 calls))
          (should (= 0 hooked)))
      (set-frame-parameter frame 'drgnx-persist-restored nil))))

(defmacro drgnx-persist-edge-test--with-frames (frames &rest body)
  "BODY with `frame-list' FRAMES, the first (the selected frame) graphical and visible; the others are symbols:
GUI-n are graphical windows, CHILD a child frame of the first, TTY a terminal one."
  (declare (indent 1))
  `(let ((first (selected-frame)) (orig-param (symbol-function 'frame-parameter)))
     (cl-letf (((symbol-function 'frame-list) (lambda () ,frames))
               ((symbol-function 'frame-live-p) (lambda (_f) t))
               ((symbol-function 'frame-visible-p) (lambda (_f) t))
               ((symbol-function 'frame-parent) (lambda (&optional f) (and (eq f 'child) first)))
               ((symbol-function 'display-graphic-p) (lambda (&optional f) (not (eq f 'tty))))
               ((symbol-function 'frame-parameter) (lambda (f p) (if (symbolp f) nil (funcall orig-param f p)))))
       ,@body)))

(ert-deftest drgnx-persist-edge/a-child-frame-does-not-block-the-last-save ()
  "M12a-13: a child frame (a posframe) is no window of the workbench: closing the last real window still saves."
  (drgnx-persist-edge-test--with dir
    (drgnx-persist-edge-test--with-frames (list first 'child)
      (drgnx-persist--on-delete-frame first))
    (should (file-exists-p drgnx-persist-file))))

(ert-deftest drgnx-persist-edge/tty-and-gui-frames-save-only-gui ()
  "M12a-16: of a terminal client's window and graphical ones, only the graphical ones are saved; the selected
graphical one comes first."
  (drgnx-persist-edge-test--with dir
    (drgnx-persist-edge-test--with-frames (list 'tty first 'gui-2)
      (should (equal (drgnx-persist--frames) (list first 'gui-2))))))

(ert-deftest drgnx-persist-edge/child-frames-are-not-saved ()
  "M12a-16: a child frame is not saved as a window."
  (drgnx-persist-edge-test--with dir
    (drgnx-persist-edge-test--with-frames (list first 'child 'gui-2)
      (should (equal (drgnx-persist--frames) (list first 'gui-2))))))

(ert-deftest drgnx-persist-edge/saved-widths-are-fitted-only-when-the-area-is-the-same-size ()
  "I3: the saved pixel widths correct a rounding of a few pixels; in a frame of another size they would be wrong
(20/20 columns coming back as 20/60), so a group further than two characters from its saved width is left as
`window-state-put' made it."
  (drgnx-persist-edge-test--with dir
    (let ((first (selected-window)))
      (drgnx-groups-split-right)
      (let* ((groups (drgnx-groups-list)) (w (window-pixel-width (car groups))))
        (should (= 2 (length groups)))
        ;; a rounding away: fitted
        (drgnx-persist--fit-groups (list (list :px (- w 1)) (list :px 10)))
        (should (= (window-pixel-width (car groups)) (- w 1)))
        ;; a different frame: left alone
        (drgnx-persist--fit-groups (list (list :px (+ w 20)) (list :px 10)))
        (should (= (window-pixel-width (car groups)) (- w 1)))
        (ignore first)))))

;;; wb-persist-edge-test.el ends here
