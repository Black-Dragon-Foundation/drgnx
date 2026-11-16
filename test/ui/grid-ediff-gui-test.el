;;; grid-ediff-gui-test.el --- GUI tests: ediff lays out inside one tile of the grid (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Two editor tiles side by side and the right dock's tile on a graphical frame, the grid backend on: ediff (and magit's
;; ediff, when magit is installed) puts its windows, the control window too, inside the editor tile it starts from; the
;; other tiles keep their edges, no frame is made, and quitting leaves the frame's windows as they were.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-grid-ediff--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-grid-ediff--repo)))
(defvar drgnx-dir)
(setq drgnx-dir (or (bound-and-true-p drgnx-dir) drgnx-ui-grid-ediff--repo))
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-ui-grid-ediff--repo) nil t)
(require 'drgnx-groups)
(require 'ediff)

(defvar ediff-control-buffer)

(defun drgnx-ui-grid-ediff--inside-p (edges outer)
  "Non-nil when pixel EDGES lie inside OUTER."
  (and (>= (nth 0 edges) (nth 0 outer)) (>= (nth 1 edges) (nth 1 outer))
       (<= (nth 2 edges) (nth 2 outer)) (<= (nth 3 edges) (nth 3 outer))))

(defun drgnx-ui-grid-ediff--check (start)
  "Run START (a function that starts an ediff session from the selected editor tile) and check the layout, then quit.
On a frame of its own, deleted after: the grid's frame parameters stay off the session's frame."
  (unless (display-graphic-p) (ert-skip "needs a graphical frame"))
  (let ((frame (make-frame '((width . 160) (height . 50)))))
    (unwind-protect
        (with-selected-frame frame
          (drgnx-ui-grid-ediff--on-frame start))
      (delete-frame frame))))

(defun drgnx-ui-grid-ediff--settled (window)
  "WINDOW's pixel edges once the window manager's answers to the frame's size are in (the same at two redisplays)."
  (let ((last nil))
    (drgnx-test-wait (lambda () (redisplay t) (prog1 (equal last (window-pixel-edges window))
                                                (setq last (window-pixel-edges window))))
                     :secs 10 :what "the frame's size")
    last))

(defun drgnx-ui-grid-ediff--on-frame (start)
  (drgnx-grid-test--with
    (let* ((ediff-window-setup-function #'drgnx-grid-ediff-setup)
           (left (selected-window))
           (right (drgnx-groups-split-right))
           (chat (drgnx-pane-show 'g-chat))
           (frames (frame-list))
           (outer (progn (select-window left) (drgnx-ui-grid-ediff--settled left)))
           (others (mapcar (lambda (w) (cons w (window-pixel-edges w))) (list right chat)))
           (before (window-list nil 'nomini))
           (control nil))
      (funcall start)
      (redisplay t)
      (setq control (seq-find (lambda (b) (with-current-buffer b (derived-mode-p 'ediff-mode))) (buffer-list)))
      (should control)
      (should (equal (frame-list) frames))                          ; no frame for ediff
      (let ((added (seq-difference (window-list nil 'nomini) before)))
        (should (>= (length added) 2))                              ; B and the control window, at least
        (dolist (w (cons left added))
          (should (drgnx-ui-grid-ediff--inside-p (window-pixel-edges w) outer)))
        (should (get-buffer-window control))
        (should (memq (get-buffer-window control) (cons left added))))
      (pcase-dolist (`(,w . ,edges) others)                         ; the other tiles did not move
        (should (equal (window-pixel-edges w) edges)))
      (with-current-buffer control (ediff-really-quit nil))
      (redisplay t)
      (should (equal (window-list nil 'nomini) before))
      (should (equal (window-pixel-edges left) outer))
      (pcase-dolist (`(,w . ,edges) others) (should (equal (window-pixel-edges w) edges))))))

(ert-deftest drgnx-ui-grid-ediff/ediff-stays-in-one-tile ()
  (let ((a (with-current-buffer (get-buffer-create "*g-ediff-a*") (erase-buffer) (insert "one\ntwo\nthree\n")
                                (current-buffer)))
        (b (with-current-buffer (get-buffer-create "*g-ediff-b*") (erase-buffer) (insert "one\n2\nthree\n")
                                (current-buffer))))
    (unwind-protect
        (drgnx-ui-grid-ediff--check (lambda () (ediff-buffers a b)))
      (kill-buffer a) (kill-buffer b))))

(ert-deftest drgnx-ui-grid-ediff/magit-ediff-stays-in-one-tile ()
  (skip-unless (and (display-graphic-p) (executable-find "git") (require 'magit nil t)))
  (let* ((dir (file-name-as-directory (make-temp-file "drgnx-grid-ediff" t)))
         (file (expand-file-name "a.txt" dir))
         (default-directory dir)
         (process-environment (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@example.invalid"
                                        "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@example.invalid")
                                      process-environment)))
    (unwind-protect
        (progn
          (write-region "one\ntwo\nthree\n" nil file nil 'silent)
          (dolist (args '(("init" "-q") ("add" "a.txt") ("commit" "-q" "-m" "a")))
            (should (eql 0 (apply #'call-process "git" nil nil nil args))))
          (write-region "one\n2\nthree\n" nil file nil 'silent)
          (with-current-buffer (find-file-noselect file)
            (set-window-buffer (selected-window) (current-buffer))
            (drgnx-ui-grid-ediff--check (lambda () (magit-ediff-compare "HEAD" nil "a.txt" "a.txt")))))
      (dolist (b (buffer-list))
        (when-let* ((f (buffer-file-name b))) (when (string-prefix-p dir f) (kill-buffer b))))
      (delete-directory dir t))))
