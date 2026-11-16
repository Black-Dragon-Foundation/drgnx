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
  "WINDOW's pixel edges once the window manager's answers to the new frame are in: the frame's size and WINDOW's edges
the same for half a second (a window manager may give a new frame one size, then another; it need not give the size
the frame was made at)."
  (let ((last nil) (since nil) (frame (window-frame window)))
    (drgnx-test-wait (lambda ()
                       (redisplay t)
                       (let ((now (list (frame-pixel-width frame) (frame-pixel-height frame) (window-pixel-edges window))))
                         (if (equal now last) (>= (- (drgnx-test-wait-now) since) 0.5)
                           (setq last now since (drgnx-test-wait-now))
                           nil)))
                     :secs 10 :what "the frame's size")
    (nth 2 last)))

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

(defconst drgnx-ui-grid-ediff--magit-packages '(magit magit-section transient with-editor compat dash llama cond-let)
  "The packages magit loads, looked for in $DRGNX_USER_ELPA when the load path has no magit.")

(defun drgnx-ui-grid-ediff--package-dir (name elpa)
  "The newest directory of package NAME in ELPA, or nil."
  (let* ((prefix (format "%s-" name))
         (found (seq-filter (lambda (d) (and (string-match-p "\\`[0-9][0-9.]*\\'" (substring d (length prefix)))
                                             (file-directory-p (expand-file-name d elpa))))
                            (directory-files elpa nil (concat "\\`" (regexp-quote prefix))))))
    (when found
      (expand-file-name (car (last (sort found (lambda (a b) (version< (substring a (length prefix))
                                                                       (substring b (length prefix)))))))
                        elpa))))

(defun drgnx-ui-grid-ediff--magit ()
  "Load magit: from the load path, else from $DRGNX_USER_ELPA when the session has it (a GUI session does not inherit
it: `drgnx-ui-keep-env').  No magit fails the row, unless DRGNX_TEST_ALLOW_NO_MAGIT=1 says this run may go without it
\(then it skips)."
  (or (featurep 'magit)
      (require 'magit nil t)
      (when-let* ((elpa (getenv "DRGNX_USER_ELPA")) ((file-directory-p elpa)))
        (let ((load-path (append (delq nil (mapcar (lambda (n) (drgnx-ui-grid-ediff--package-dir n elpa))
                                                   drgnx-ui-grid-ediff--magit-packages))
                                 load-path)))
          (require 'magit nil t)))
      (if (equal (getenv "DRGNX_TEST_ALLOW_NO_MAGIT") "1") (ert-skip "magit not found (DRGNX_TEST_ALLOW_NO_MAGIT=1)")
        (ert-fail (format "magit not found (DRGNX_USER_ELPA %S%s): put magit on the GUI image's load path, or set DRGNX_TEST_ALLOW_NO_MAGIT=1"
                          (getenv "DRGNX_USER_ELPA")
                          (if-let* ((elpa (getenv "DRGNX_USER_ELPA")) ((file-directory-p elpa)))
                              (format ", magit there: %S" (drgnx-ui-grid-ediff--package-dir 'magit elpa))
                            ""))))))

(ert-deftest drgnx-ui-grid-ediff/magit-ediff-stays-in-one-tile ()
  (skip-unless (and (display-graphic-p) (executable-find "git")))
  (drgnx-ui-grid-ediff--magit)
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
