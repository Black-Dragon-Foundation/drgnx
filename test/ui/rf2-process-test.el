;;; rf2-process-test.el --- GUI tests: a process finishing in another window moves no other window (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; RF2: output from a process (a compilation ending) must not scroll, resize or refocus the windows the user is in.
;; The finish comes from a real process while the recorder runs, not from a command.
(require 'ert)
(require 'compile)
(require 'drgnx-uitest)

(defun drgnx-rf2-test--text-buffer (name lines)
  "A buffer NAME of LINES numbered lines."
  (with-current-buffer (get-buffer-create name)
    (erase-buffer)
    (dotimes (i lines) (insert (format "line %d of %s\n" (1+ i) name)))
    (current-buffer)))

(defun drgnx-rf2-test--sig (w)
  "What the user sees of window W: its buffer, edges, start and point."
  (list (buffer-name (window-buffer w)) (window-pixel-edges w) (window-start w) (window-point w)))

(defun drgnx-rf2-test--finish-compilation (shown)
  "Run a compilation that ends while two editor windows hold the user's attention; return (A-BEFORE B-BEFORE REPORT A B C).
SHOWN non-nil: its buffer is displayed in a third window C beforehand."
  (delete-other-windows)
  (let* ((a (selected-window))
         (_ (progn (set-window-buffer a (drgnx-rf2-test--text-buffer "*rf2 a*" 300))
                   (with-current-buffer "*rf2 a*" (goto-char (point-min)) (forward-line 80) (set-window-point a (point)))
                   (set-window-start a (with-current-buffer "*rf2 a*" (save-excursion (goto-char (point-min)) (forward-line 70) (point))))))
         (b (split-window-right))
         (_b (progn (set-window-buffer b (drgnx-rf2-test--text-buffer "*rf2 b*" 300))
                    (with-current-buffer "*rf2 b*" (goto-char (point-min)) (forward-line 120) (set-window-point b (point)))
                    (set-window-start b (with-current-buffer "*rf2 b*" (save-excursion (goto-char (point-min)) (forward-line 110) (point))))))
         (c (and shown (split-window-below nil b))))
    (when c (set-window-buffer c (get-buffer-create "*compilation*")))
    (select-window a)
    (redisplay t)
    (let ((compilation-ask-about-save nil)
          (compilation-scroll-output nil)
          (default-directory temporary-file-directory)
          (before-a (drgnx-rf2-test--sig a))
          (before-b (drgnx-rf2-test--sig b))
          proc)
      ;; `compile' itself displays its buffer when it starts, in some other window (stock Emacs).  That is
      ;; setup, not the finish under test: out of sight, it must not be shown at all.
      (setq proc (get-buffer-process
                  (let ((display-buffer-alist (if shown display-buffer-alist
                                                (cons '("\\*compilation\\*" (display-buffer-no-window) (allow-no-window . t))
                                                      display-buffer-alist))))
                    (compile "sleep 0.6; echo done"))))
      (drgnx-uitest-measure-begin)
      (while (process-live-p proc) (sit-for 0.05))
      (sit-for 0.4)                      ; the sentinel's output and the redisplay after it
      (list before-a before-b (drgnx-uitest-measure-end) a b c))))

(defun drgnx-rf2-test--clean ()
  (delete-other-windows)
  (dolist (n '("*rf2 a*" "*rf2 b*" "*compilation*"))
    (when-let* ((buf (get-buffer n)))
      (when-let* ((p (get-buffer-process buf))) (delete-process p))
      (kill-buffer buf))))

(ert-deftest drgnx-ui-rf2/a-compilation-finishing-in-another-window-moves-no-other-window ()
  (unwind-protect
      (pcase-let ((`(,before-a ,before-b ,r ,a ,b ,c) (drgnx-rf2-test--finish-compilation t)))
        (should (equal (drgnx-rf2-test--sig a) before-a))
        (should (equal (drgnx-rf2-test--sig b) before-b))
        (should (eq (selected-window) a))
        (should (equal (buffer-name (window-buffer c)) "*compilation*"))
        (should (with-current-buffer "*compilation*" (string-search "finished" (buffer-string))))
        (should (= (plist-get r :layout_changes) 0))
        ;; Only the window showing the output may change.
        (should (cl-subsetp (append (plist-get r :collateral) nil) (list (drgnx-uitest-window-id c)) :test #'equal)))
    (drgnx-rf2-test--clean)))

(ert-deftest drgnx-ui-rf2/a-compilation-finishing-out-of-sight-moves-no-window ()
  (unwind-protect
      (pcase-let ((`(,before-a ,before-b ,r ,a ,b ,_) (drgnx-rf2-test--finish-compilation nil)))
        (should (equal (drgnx-rf2-test--sig a) before-a))
        (should (equal (drgnx-rf2-test--sig b) before-b))
        (should (eq (selected-window) a))
        (should (= (length (window-list nil 'nomini)) 2))
        (should (= (plist-get r :layout_changes) 0))
        (should (= (plist-get r :collateral_moves) 0)))
    (drgnx-rf2-test--clean)))

;;; rf2-process-test.el ends here
