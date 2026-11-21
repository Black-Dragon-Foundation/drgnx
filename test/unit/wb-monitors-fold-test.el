;;; wb-monitors-fold-test.el --- batch tests: a window on a monitor that goes away folds into the main one -*- lexical-binding: t -*-
;; test-class: det
;; When a monitor goes away, each auxiliary window on it folds into the main window (its tabs and tool panes join the
;; main window's, its place is kept); when the monitor comes back, the window comes back.  Batch cannot make a second
;; frame, so the rows that fold a live window are GUI rows (test/ui/monitors-fold-gui-test.el); these fold a saved
;; window and check the debounce.  The monitors are faked in each test (`display-monitor-attributes-list').
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-dir) nil t)
(require 'drgnx-grid-frames)
(require 'drgnx-monitors)

(defun drgnx-monitors-fold-test--monitors (&rest names)
  "Monitors called NAMES, side by side, as `display-monitor-attributes-list' lists them."
  (let ((x 0))
    (mapcar (lambda (n) (prog1 (list (cons 'name n) (cons 'geometry (list x 0 1920 1080))
                                     (cons 'workarea (list x 0 1920 1080)))
                          (setq x (+ x 1920))))
            names)))

(defmacro drgnx-monitors-fold-test--with (names &rest body)
  "BODY on the grid fixture with the selected frame the main one, monitors NAMES (`monitors': set it to change them),
nothing folded, an empty stack and a temp HOME."
  (declare (indent 1))
  `(let* ((home (make-temp-file "drgnx-monitors-fold" t))
          (process-environment (append (list (concat "HOME=" home) (concat "XDG_STATE_HOME=" home "/state"))
                                       process-environment))
          (monitors (apply #'drgnx-monitors-fold-test--monitors ,names))
          (drgnx-grid--stack nil) (drgnx-monitors--folded nil) (drgnx-monitors--fold-seen nil)
          (main (selected-frame)))
     (unwind-protect
         (cl-letf (((symbol-function 'display-monitor-attributes-list) (lambda (&rest _) monitors)))
           (drgnx-grid-test--with
             (set-frame-parameter main 'drgnx-frame-role 'main)
             (set-window-parameter nil 'drgnx-tabs (list (window-buffer)))
             ,@body))
       (drgnx-timer-cancel 'monitors-fold)
       (set-frame-parameter main 'drgnx-frame-role nil)
       (set-frame-parameter main 'drgnx-monitor nil)
       (delete-directory home t))))

(ert-deftest drgnx-monitors/a-flicker-does-not-fold ()
  ;; a dock unplugged and plugged back within the second: nothing folds (the check waits for the changes to settle)
  (drgnx-monitors-fold-test--with '("A" "B")
    (let ((folded nil))
      (set-frame-parameter main 'drgnx-monitor (list :name "B"))
      (cl-letf (((symbol-function 'drgnx-frame-role) (lambda (&optional _) 'aux))   ; the window on B is an aux one
                ((symbol-function 'drgnx-monitors--fold) (lambda (key &rest _) (push key folded))))
        (setq monitors (drgnx-monitors-fold-test--monitors "A"))
        (drgnx-monitors--monitors-changed)
        (should-not folded)
        (setq monitors (drgnx-monitors-fold-test--monitors "A" "B"))
        (drgnx-monitors--monitors-changed)
        (should (drgnx-timer-active-p 'monitors-fold))
        (drgnx-monitors--fold-settle)                     ; the debounce's run, a second after the last change
        (should-not folded)
        ;; gone for good: the settled check folds it, once
        (setq monitors (drgnx-monitors-fold-test--monitors "A"))
        (drgnx-monitors--monitors-changed)
        (drgnx-monitors--fold-settle)
        (should (equal folded '((:name "B"))))))))

(ert-deftest drgnx-monitors/restore-with-a-missing-monitor-folds ()
  ;; a layout naming a window on a monitor that is not there: no window is made; its tabs go to the main window's
  ;; editor, its place is kept for when the monitor returns
  (drgnx-monitors-fold-test--with '("A")
    (let* ((x (get-buffer-create "*drgnx-fold-x*")) (y (get-buffer-create "*drgnx-fold-y*"))
           (snap (drgnx-grid-snapshot 'restore))
           (aux (list :id 99 :role 'aux :monitor (list :name "B") :geometry (list 1940 20 800 600)
                      :tree (list 'editor :id 1 :tabs (list "*drgnx-fold-x*" "*drgnx-fold-y*") :shown "*drgnx-fold-y*"
                                  :point 1 :start 1)
                      :full nil))
           (frames (length (frame-list))))
      (unwind-protect
          (progn
            (plist-put snap :frames (append (plist-get snap :frames) (list aux)))
            (should (drgnx-grid-restore snap))
            (should (= frames (length (frame-list))))
            (let ((tabs (window-parameter (car (drgnx-grid-tiles main 'editor)) 'drgnx-tabs)))
              (should (memq x tabs))
              (should (memq y tabs)))
            (let ((entry (car (alist-get '(:name "B") drgnx-monitors--folded nil nil #'equal))))
              (should (eql 99 (plist-get (plist-get entry :snap) :id)))
              (should (equal (plist-get entry :tabs) '("*drgnx-fold-x*" "*drgnx-fold-y*")))))
        (kill-buffer x)
        (kill-buffer y)))))

(ert-deftest drgnx-monitors/folded-windows-are-saved-with-the-main-one ()
  ;; the folded windows survive a restart: the main window's saved extras hold them, and its restore takes them back
  (drgnx-monitors-fold-test--with '("A")
    (let ((entry (list :snap (list :id 7 :role 'aux :monitor (list :name "B") :tree (list 'editor :id 1 :tabs nil
                                                                                          :shown "*scratch*")
                                   :full nil)
                       :tabs nil :kinds nil)))
      (setq drgnx-monitors--folded (list (list (list :name "B") entry)))
      (let ((saved (plist-get (drgnx-monitors--state) :monitors-folded)))
        (should (equal saved drgnx-monitors--folded))
        (setq drgnx-monitors--folded nil)
        (set-frame-parameter main 'drgnx-persist-extra (list :monitors-folded saved))
        (unwind-protect (drgnx-monitors--place-restored main)
          (set-frame-parameter main 'drgnx-persist-extra nil))
        (should (equal drgnx-monitors--folded saved))
        ;; junk is not taken
        (setq drgnx-monitors--folded nil)
        (set-frame-parameter main 'drgnx-persist-extra (list :monitors-folded '((x . 3) "y")))
        (unwind-protect (drgnx-monitors--place-restored main)
          (set-frame-parameter main 'drgnx-persist-extra nil))
        (should-not drgnx-monitors--folded)))))

(provide 'wb-monitors-fold-test)
;;; wb-monitors-fold-test.el ends here
