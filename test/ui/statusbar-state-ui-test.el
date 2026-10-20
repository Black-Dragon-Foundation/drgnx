;;; statusbar-state-ui-test.el --- GUI tests: the status bar follows the store's editor window (run by `drgnx test --ui') -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-statusbar-state-ui-test--repo               ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-statusbar-state-ui-test--repo)))
(dolist (m '("ui/drgnx-face" "ui/drgnx-statusbar"))
  (load (expand-file-name (concat "modules/" m) drgnx-statusbar-state-ui-test--repo) nil t))
(require 'drgnx-state)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-statusbar-state-ui-test--repo) nil t)   ; `drgnx-test-wait'

(defmacro drgnx-statusbar-state-ui-test--with (drawn &rest body)
  "BODY with two probe segments (full: `fprobe', compact: `cprobe') that record in the hash table DRAWN, per window,
which bar redisplay drew for it, the store on, the bus's idle flush out of reach (so only the `now' lane can have
moved the bar), and the status bar mode on; the session's modes and variables come back after."
  (declare (indent 1))
  `(let ((,drawn (make-hash-table :test #'eq))
         (state-was (bound-and-true-p drgnx-state-mode)) (statusbar-was (bound-and-true-p drgnx-statusbar-mode))
         (drgnx-signal-delay 3600)
         (drgnx-statusbar--segments (make-hash-table :test #'eq))
         (drgnx-statusbar--errors nil)
         (drgnx-statusbar--memo (make-hash-table :test #'eq :weakness 'key))
         (drgnx-statusbar-left '(fprobe))
         (drgnx-statusbar-right nil)
         (drgnx-statusbar-compact '(cprobe)))
     (drgnx-statusbar-define-segment 'fprobe :fn (lambda () (puthash (drgnx-statusbar-source-window) 'full ,drawn) "F"))
     (drgnx-statusbar-define-segment 'cprobe :fn (lambda () (puthash (drgnx-statusbar-source-window) 'compact ,drawn) "C"))
     (unwind-protect (progn ,@body)
       (drgnx-statusbar-mode (if statusbar-was 1 -1))
       (drgnx-state-mode (if state-was 1 -1)))))

(ert-deftest drgnx-statusbar-ui/c-x-o-in-one-buffer-moves-the-bar-on-the-first-redraw ()
  ;; Two windows on one buffer: no buffer changes, only the window.  The first redisplay after `C-x o' draws the
  ;; full bar in the window that is now the editor, with no idle pause in between (the flush delay is an hour).
  (let ((buf (get-buffer-create "*drgnx-statusbar-state*")) (dir (make-temp-file "drgnx-sb-state" t)))
    (with-current-buffer buf (emacs-lisp-mode) (insert "(a)\n(b)\n"))
    (with-selected-frame (drgnx-uitest-root-frame)
      (delete-other-windows)
      (switch-to-buffer buf)
      (let* ((w1 (selected-window)) (w2 (split-window-right)))
        (set-window-buffer w2 buf)
        (unwind-protect
            (drgnx-statusbar-state-ui-test--with drawn
              (cl-letf (((symbol-function 'drgnx-chrome-apply) #'ignore))
                (drgnx-state-mode 1)
                (drgnx-statusbar-mode 1))
              (dolist (w (list w1 w2)) (set-window-parameter w 'mode-line-format drgnx-statusbar--host))
              (should (eq w1 (drgnx-state-editor-window)))
              (redisplay t)
              (should (eq (gethash w1 drawn) 'full))
              (should (eq (gethash w2 drawn) 'compact))
              (clrhash drawn)
              (should (eq (plist-get (drgnx-uitest-run (drgnx-uitest-key-events "C-x o")) :settled) t))
              (should (eq (selected-window) w2))
              (should (eq (drgnx-state-editor-window) w2))
              (should (eq (gethash w2 drawn) 'full))
              (should (eq (gethash w1 drawn) 'compact))
              (should (string-match-p "F" (format-mode-line drgnx-statusbar--host nil w2)))
              (should-not (string-match-p "F" (format-mode-line drgnx-statusbar--host nil w1)))
              ;; and back: the return trip moves both bars again on its first redraw
              (clrhash drawn)
              (should (eq (plist-get (drgnx-uitest-run (drgnx-uitest-key-events "C-x o")) :settled) t))
              (should (eq (selected-window) w1))
              (should (eq (drgnx-state-editor-window) w1))
              (should (eq (gethash w1 drawn) 'full))
              (should (eq (gethash w2 drawn) 'compact))
              (should (string-match-p "F" (format-mode-line drgnx-statusbar--host nil w1)))
              (should-not (string-match-p "F" (format-mode-line drgnx-statusbar--host nil w2)))
              ;; what is on the screen after that one redisplay
              (should (> (file-attribute-size (file-attributes (plist-get (drgnx-uitest-capture dir) :root))) 0)))
          (dolist (w (list w1 w2)) (when (window-live-p w) (set-window-parameter w 'mode-line-format nil)))
          (delete-other-windows)
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf)
          (delete-directory dir t))))))

(ert-deftest drgnx-statusbar-ui/each-frame-has-its-own-full-bar ()
  ;; Two frames, two windows each: the full bar is in each frame's own editor window, not only in the selected
  ;; frame's.  The second frame's editor window is its second window.
  (let* ((buf (get-buffer-create "*drgnx-statusbar-frames*"))
         (root (drgnx-uitest-root-frame))         ; before the second frame exists: it may become the "first" one
         (aux (make-frame '((name . "drgnx statusbar aux") (width . 80) (height . 20)))))
    ;; the compositor maps a new frame when it gets to it (pgtk under mutter: after `make-frame' returned), and
    ;; redisplay skips a frame that is not mapped yet: its bars would never be drawn
    (drgnx-test-wait (lambda () (eq (frame-visible-p aux) t)) :secs 10 :what "the second frame is mapped")
    (with-current-buffer buf (emacs-lisp-mode) (insert "(a)\n(b)\n"))
    (with-selected-frame root
      (delete-other-windows)
      (switch-to-buffer buf)
      (let* ((r1 (selected-window)) (r2 (split-window-right)) a1 a2)
        (set-window-buffer r2 buf)
        (unwind-protect
            (drgnx-statusbar-state-ui-test--with drawn
              (with-selected-frame aux
                (delete-other-windows)
                (setq a1 (selected-window) a2 (split-window-right))
                (set-window-buffer a1 buf)
                (set-window-buffer a2 buf))
              (cl-letf (((symbol-function 'drgnx-chrome-apply) #'ignore))
                (drgnx-state-mode 1)
                (drgnx-statusbar-mode 1))
              (drgnx-state-sync)
              (with-selected-frame aux (select-window a2))
              (drgnx-state-sync aux)
              (dolist (w (list r1 r2 a1 a2)) (set-window-parameter w 'mode-line-format drgnx-statusbar--host))
              (should (eq (drgnx-state-editor-window (window-frame r1)) r1))
              (should (eq (drgnx-state-editor-window aux) a2))
              (force-mode-line-update t)
              (clrhash drawn)
              (should (eq (frame-visible-p aux) t))
              (should (window-live-p a1))
              (redisplay t)
              (should (eq (gethash r1 drawn) 'full))
              (should (eq (gethash r2 drawn) 'compact))
              (should (eq (gethash a1 drawn) 'compact))
              (should (eq (gethash a2 drawn) 'full)))
          (dolist (w (list r1 r2)) (when (window-live-p w) (set-window-parameter w 'mode-line-format nil)))
          (when (frame-live-p aux) (delete-frame aux t))
          (delete-other-windows)
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

;;; statusbar-state-ui-test.el ends here
