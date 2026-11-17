;;; grid-scales-gui-test.el --- GUI test: the grid's sizes when a window's scale changes (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; A window moved to a monitor of another scale keeps its tiles' shares.  The move is the session's own mutter putting
;; its monitor at another scale (`gdctl set', as scale-move-test.el does: every frame on it changes scale, as a frame
;; moved to another monitor does); other compositors skip.  Each row starts at 1.25 and puts the session's scale back
;; at the end.  Every size is read after the frame took the new scale and `drgnx-test-wait-presented'.
;; Shares, not logical pixels: the window keeps its frame pixels across the change (Nidhogg's shell), so its logical
;; size, and every tile's, shrinks by the scales' ratio; what the grid keeps is each tile's part of it.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-grid-scales--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-grid-scales--repo)))
(defvar drgnx-dir)
(setq drgnx-dir (or (bound-and-true-p drgnx-dir) drgnx-ui-grid-scales--repo))
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-ui-grid-scales--repo) nil t)
(require 'drgnx-grid-frames)

(defun drgnx-ui-grid-scales--gdctl (scale)
  "Put the session's one monitor (Meta-0, primary) at SCALE through mutter's display config; non-nil when it took."
  (and (executable-find "gdctl")
       (eq 0 (call-process "gdctl" nil nil nil "set" "--logical-monitor" "--primary" "--monitor" "Meta-0"
                           "--scale" (number-to-string scale)))))

(defun drgnx-ui-grid-scales--scale (scale)
  "The monitor at SCALE, the selected frame at it, the scale's special event read (the scale hooks run where input is
read, as in the command loop) and the frame presented."
  (let ((f (selected-frame)))
    (should (drgnx-ui-grid-scales--gdctl scale))
    (drgnx-ui-grid-scales--at f scale)))

(defun drgnx-ui-grid-scales--at (frame scale)
  "Wait for FRAME at SCALE, then read the scale's special event and wait for FRAME presented."
  (drgnx-test-wait (lambda () (redisplay t) (< (abs (- (frame-scale-factor frame) scale)) 0.001))
                   :secs 10 :what (list "the window at scale" scale))
  (dotimes (_ 5) (read-event nil nil 0.02))
  (drgnx-test-wait-presented :frame frame))

(defmacro drgnx-ui-grid-scales--with (&rest body)
  "BODY on a frame of its own at scale 1.25 with the grid fixture and `drgnx-grid-mode' on; the session's scale, the
frames BODY made and the mode as they were after."
  (declare (indent 0))
  `(let ((s0 (and (display-graphic-p) (fboundp 'frame-scale-factor) (frame-scale-factor)))
         (frames (frame-list)))
     ;; only mutter takes a `gdctl set'
     (skip-unless (and s0 (drgnx-ui-grid-scales--gdctl 1.25)))
     (let ((frame (make-frame '((width . 160) (height . 50)))))
       (unwind-protect
           (with-selected-frame frame
             (drgnx-ui-grid-scales--scale 1.25)
             (drgnx-grid-test--with
               (let ((was drgnx-grid-mode))
                 (unless was (drgnx-grid-mode 1))
                 (unwind-protect (progn (drgnx-test-wait-presented) ,@body)
                   (unless was (drgnx-grid-mode -1))))))
         (dolist (f (frame-list)) (unless (memq f frames) (delete-frame f t)))
         (when (drgnx-ui-grid-scales--gdctl s0)
           (drgnx-ui-grid-scales--at (selected-frame) s0))))))

(defun drgnx-ui-grid-scales--shares (tree)
  "TREE's nodes in order as (TYPE ID SHARE), the root's share nil."
  (cons (list (car tree) (plist-get (cdr tree) :id) (plist-get (cdr tree) :share))
        (and (memq (car tree) '(row col)) (mapcan #'drgnx-ui-grid-scales--shares (nthcdr 5 tree)))))

(defun drgnx-ui-grid-scales--same-shares (before after)
  "AFTER is BEFORE's arrangement, each node's share within 0.005 of BEFORE's."
  (let ((b (drgnx-ui-grid-scales--shares before)) (a (drgnx-ui-grid-scales--shares after)))
    (should (equal (mapcar (lambda (n) (list (car n) (cadr n))) a) (mapcar (lambda (n) (list (car n) (cadr n))) b)))
    ;; a failure shows both lists
    (should-not (and (cl-loop for (_ _ sb) in b for (_ _ sa) in a
                              thereis (if sb (>= (abs (- sa sb)) 0.005) sa))
                     (list :before b :after a)))))

(defun drgnx-ui-grid-scales--tiled (frame)
  "FRAME (selected) with the Tree on the left and the Term at the bottom beside its editor, presented."
  (with-selected-frame frame
    (drgnx-grid-show 'g-tree)
    (drgnx-grid-show 'g-term)
    (drgnx-test-wait-presented :frame frame)))

(ert-deftest drgnx-ui-grid-scales/a-frame-moved-to-scale-2-keeps-shares ()
  "1.25 → 2: the side bar and the bottom tile keep their share of the window, not their pixels."
  (drgnx-ui-grid-scales--with
    (drgnx-ui-grid-scales--tiled (selected-frame))
    (let ((before (drgnx-grid-tree)))
      (should (= 3 (length (drgnx-grid-tree-leaves before))))
      (drgnx-ui-grid-scales--scale 2)
      (drgnx-ui-grid-scales--same-shares before (drgnx-grid-tree)))))

(ert-deftest drgnx-ui-grid-scales/a-torn-out-tile-on-the-other-monitor-keeps-its-logical-size ()
  "A tile torn out into a window of its own, a side bar beside it there: that window at 2 keeps its shares."
  (drgnx-ui-grid-scales--with
    (drgnx-ui-grid-scales--tiled (selected-frame))
    (let ((new (drgnx-grid-move-to-new-frame (get-buffer-window " *drgnx g-term*"))))
      (drgnx-test-wait (lambda () (redisplay t) (frame-visible-p new)) :secs 10 :what "the new window mapped")
      (with-selected-frame new (drgnx-grid-show 'g-tree))
      (drgnx-test-wait-presented :frame new)
      (let ((before (drgnx-grid-tree new)))
        (should (= 2 (length (drgnx-grid-tree-leaves before))))
        (drgnx-ui-grid-scales--scale 2)
        (drgnx-ui-grid-scales--at new 2)
        (drgnx-ui-grid-scales--same-shares before (drgnx-grid-tree new))))))

(ert-deftest drgnx-ui-grid-scales/other-frames-untouched ()
  "One window's scale changes (its UI scale, then the scale hooks for it alone): another window's tiles keep their
windows and pixels, and its last good arrangement is not taken again."
  (drgnx-ui-grid-scales--with
    (let* ((a (selected-frame)) (b (make-frame '((width . 120) (height . 40)))))
      (drgnx-test-wait (lambda () (redisplay t) (frame-visible-p b)) :secs 10 :what "the second window mapped")
      (drgnx-ui-grid-scales--tiled a)
      (with-selected-frame b (drgnx-grid-test--reset))
      (drgnx-ui-grid-scales--tiled b)
      (let ((edges (mapcar (lambda (w) (cons w (window-pixel-edges w))) (window-list b 'nomini)))
            (good (frame-parameter b 'drgnx-grid--good))
            (before (drgnx-grid-tree a)))
        (unwind-protect
            (progn
              (drgnx-pixels-set-ui-scale a 1.5)
              (run-hook-with-args 'nidhogg-frame-scale-change-functions a)
              (drgnx-test-wait-presented)
              (drgnx-ui-grid-scales--same-shares before (drgnx-grid-tree a)))
          (drgnx-pixels-set-ui-scale a 1))
        (should (eq good (frame-parameter b 'drgnx-grid--good)))
        (should (equal edges (mapcar (lambda (w) (cons w (window-pixel-edges w))) (window-list b 'nomini))))))))

(provide 'grid-scales-gui-test)
;;; grid-scales-gui-test.el ends here
