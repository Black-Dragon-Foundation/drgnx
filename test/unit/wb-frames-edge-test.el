;;; wb-frames-edge-test.el --- batch tests: each window's buffers, on synthetic frames -*- lexical-binding: t -*-
;; Batch Emacs has one frame: the frames here are symbols; each owns real windows of the one frame
;; (`drgnx-groups-list' is stubbed), whose tabs are real `drgnx-tabs' window parameters.
(require 'ert)
(require 'drgnx-frames)
(require 'drgnx-chrome)

(defmacro drgnx-frames-edge--with (&rest body)
  "BODY with `a' … `e' user buffers (all in `bufs'), windows `w1' `w2' `w3', and three synthetic
frames: `main' (w1, tabs a b), `aux' (w2, tabs c b), `hidden' (w3, tabs d; not a workbench window)."
  (declare (indent 0))
  `(let* ((bufs (cl-loop for i below 5
                         collect (with-current-buffer (generate-new-buffer (format "drgnx-fr-%d" i))
                                   (setq buffer-file-name (format "/nonexistent/drgnx-fr-%d" i))
                                   (current-buffer))))
          (a (nth 0 bufs)) (b (nth 1 bufs)) (c (nth 2 bufs)) (d (nth 3 bufs)) (e (nth 4 bufs))
          (w1 (progn (delete-other-windows) (selected-window)))
          (w2 (split-window w1 nil 'right)) (w3 (split-window w2 nil 'right))
          (groups (list (cons 'main (list w1)) (cons 'aux (list w2)) (cons 'hidden (list w3)))))
     (ignore e)
     (set-window-parameter w1 'drgnx-tabs (list a b))
     (set-window-parameter w2 'drgnx-tabs (list c b c))      ; a buffer twice: listed once
     (set-window-parameter w3 'drgnx-tabs (list d))
     (unwind-protect
         (cl-letf (((symbol-function 'frame-list) (lambda () '(aux hidden main)))   ; newest first
                   ((symbol-function 'drgnx-frames--workbench-p) (lambda (f) (memq f '(main aux))))
                   ((symbol-function 'drgnx-frame-role) (lambda (&optional f) (if (eq f 'main) 'main 'aux)))
                   ((symbol-function 'drgnx-groups-list) (lambda (&optional f) (alist-get f groups))))
           ,@body)
       (dolist (w (list w1 w2 w3)) (set-window-parameter w 'drgnx-tabs nil))
       (delete-other-windows)
       (dolist (x bufs)
         (when (buffer-live-p x) (with-current-buffer x (setq buffer-file-name nil)) (kill-buffer x))))))

(defun drgnx-frames-edge--ours (list bufs) (seq-filter (lambda (x) (memq x bufs)) list))

(ert-deftest drgnx-frames/an-aux-window-has-its-tabs ()
  (drgnx-frames-edge--with
    (should (equal (drgnx-frame-buffers 'aux) (list c b)))))

(ert-deftest drgnx-frames/the-main-window-also-has-files-that-are-a-tab-nowhere ()
  ;; a b: its tabs; d: a tab only in a window that is not a workbench window; e: a tab nowhere.
  ;; c: a tab in the aux window — not the main window's.
  (drgnx-frames-edge--with
    (let ((main (drgnx-frames-edge--ours (drgnx-frame-buffers 'main) bufs)))
      (should (equal (seq-take main 2) (list a b)))      ; its tabs first, in order
      (should (memq d main))
      (should (memq e main))
      (should-not (memq c main))
      (should (= (length main) 4)))))                     ; b once

(ert-deftest drgnx-frames/killing-a-buffer-removes-it-from-every-window ()
  (drgnx-frames-edge--with
    (kill-buffer b)
    (should (equal (drgnx-frame-buffers 'aux) (list c)))
    (should-not (memq b (drgnx-frame-buffers 'main)))
    (should (equal (drgnx-chrome-tabs w1) (list a)))
    (should (equal (drgnx-chrome-tabs w2) (list c c)))))

(ert-deftest drgnx-frames/switch-buffer-lists-this-windows-buffers-first-and-drops-none ()
  ;; DEFERRED M3e-2: C-x b is sorted, not filtered: the window's buffers first, every other buffer after,
  ;; each part in the order Emacs gave.
  (let ((mine (generate-new-buffer "frames-mine")) (other (generate-new-buffer "frames-other"))
        (also (generate-new-buffer "frames-also")))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-frame-buffers) (lambda (&optional _) (list also mine))))
          (should (equal (drgnx-frames--order (list "frames-other" "frames-mine" "frames-zzz" "frames-also"))
                         '("frames-mine" "frames-also" "frames-other" "frames-zzz")))
          (let* ((table (drgnx-frames--buffer-table))
                 (meta (completion-metadata "" table nil)))
            (should (eq (completion-metadata-get meta 'display-sort-function) #'drgnx-frames--order))
            (should (eq (completion-metadata-get meta 'category) 'buffer))
            ;; nothing is filtered out
            (dolist (b (list mine other also)) (should (member (buffer-name b) (all-completions "" table))))
            (should (equal (all-completions "frames-m" table) '("frames-mine")))))
      (mapc #'kill-buffer (list mine other also)))))

(ert-deftest drgnx-frames/the-mode-sets-read-buffer-function-unless-the-user-has-one ()
  (let ((was drgnx-frames-mode))
    (unwind-protect
        (progn
          (let ((read-buffer-function nil))
            (drgnx-frames-mode 1)
            (should (eq read-buffer-function #'drgnx-frames-read-buffer))
            (drgnx-frames-mode -1)
            (should-not read-buffer-function))
          (let ((read-buffer-function #'ignore))
            (drgnx-frames-mode 1)
            (should (eq read-buffer-function #'ignore))        ; the user's own stays
            (drgnx-frames-mode -1)
            (should (eq read-buffer-function #'ignore))))
      (drgnx-frames-mode (if was 1 -1)))))

(provide 'wb-frames-edge-test)
;;; wb-frames-edge-test.el ends here
