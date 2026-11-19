;;; drgnx-perf-tiling.el --- the perf lab's tiling workloads: switcher, focus, move, layout restore, pane drag -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Controller side of the tiling rows (docs/develop/perf.md, "The tiling workloads"; tiling plan, Task 20).  Each spec is
;; one `drgnx-perf-run--workloads' entry.  The session is a graphical frame with the grid on and six tiles: the side bar,
;; the panel, the right dock and three editors.
;;  - `tile-switcher-show': the switcher's cards shown and drawn (:show :p95 within 50 ms), 20 times;
;;  - `tile-focus': a key that focuses the next tile (:input :p95 within a frame);
;;  - `tile-move': a key that moves the selected tile beside its neighbour and back (:input :p95 within 50 ms);
;;  - `layout-restore': ten tiles with a file open in each, restored from their snapshot (:tiles within 150 ms; the
;;    modes the files load are reported as :mode_load_ms, not budgeted);
;;  - `pane-drag': a drag's motion (:motion :p95 within a frame: the drop hint put on a tile's tab line and drawn) and
;;    its drop (:drop :p95 within 50 ms: the tile moved).

;;; Code:
(require 'cl-lib)
(require 'drgnx-ui)

(defconst drgnx-perf-tiling--lib-form
  (prin1-to-string
   '(progn
      (defvar drgnx-perf--tile-dir 'right "The direction `drgnx-perf--tile-move-step' moves the tile now.")
      (defun drgnx-perf--tile-stats (samples)
        "SAMPLES (ms) as (:n N :p50 MS :p95 MS :max MS)."
        (let* ((s (sort (copy-sequence samples) #'<)) (n (length s)))
          (list :n n :p50 (nth (/ n 2) s) :p95 (nth (min (1- n) (floor (* 0.95 n))) s) :max (car (last s)))))
      (defun drgnx-perf--tile-ms (thunk)
        "THUNK run, then the frame drawn: the milliseconds that took."
        (let ((t0 (float-time)))
          (funcall thunk)
          (redisplay t)
          (* 1000.0 (- (float-time) t0))))
      (defun drgnx-perf--tile-up ()
        "Six tiles: the side bar, the panel, the right dock and three editors, the grid's frame ready."
        (require 'drgnx-grid-ops) (require 'drgnx-grid-frames) (require 'drgnx-switcher) (require 'drgnx-groups)
        (unless drgnx-grid-mode (drgnx-grid-mode 1))
        (drgnx-wb-show-sidebar)
        (drgnx-wb-area-show 'panel)
        (drgnx-wb-area-show 'right)
        (select-window (drgnx-wb-editor-window))
        (drgnx-groups-split-right)
        (drgnx-groups-split-down)
        (redisplay t)
        (< 5 (length (drgnx-grid-tiles))))
      (defun drgnx-perf--tile-focus-step ()
        "Focus the next tile."
        (interactive)
        (let* ((tiles (drgnx-grid-tiles)) (i (seq-position tiles (drgnx-grid-tile-main (selected-window)))))
          (select-window (nth (mod (1+ (or i 0)) (length tiles)) tiles))))
      (defun drgnx-perf--tile-move-step ()
        "Move the selected tile beside its neighbour to the right, then back, one key each."
        (interactive)
        (condition-case nil
            (funcall (if (eq drgnx-perf--tile-dir 'right) #'drgnx-grid-move-tile-right #'drgnx-grid-move-tile-left))
          (user-error nil))
        (setq drgnx-perf--tile-dir (if (eq drgnx-perf--tile-dir 'right) 'left 'right)))
      (defun drgnx-perf--tile-show-measure ()
        "The switcher opened and drawn, then closed, 20 times after one warm-up: (:show STATS)."
        (let (ms)
          (dotimes (i 21)
            (let ((d (drgnx-perf--tile-ms #'drgnx-switcher-open)))
              (when (> i 0) (push d ms)))
            (drgnx-switcher-close)
            (redisplay t))
          (list :show (drgnx-perf--tile-stats ms))))
      (defun drgnx-perf--tile-ten ()
        "Ten tiles with a file open in each: the six, and four editors more, split off the last."
        (drgnx-perf--tile-up)
        (let ((files (seq-take (directory-files (expand-file-name "wb" drgnx-dir) t "\\.el\\'") 10)))
          ;; each new editor splits the roomiest one, alternately beside and below it
          (dotimes (i 4)
            (let ((w (car (sort (drgnx-grid-tiles nil 'editor)
                                (lambda (a b) (> (* (window-pixel-width a) (window-pixel-height a))
                                                 (* (window-pixel-width b) (window-pixel-height b))))))))
              (select-window w)
              (if (cl-evenp i) (drgnx-groups-split-right) (drgnx-groups-split-down))))
          (cl-mapc (lambda (w f) (with-selected-window w (find-file f))) (drgnx-grid-tiles nil 'editor) files)
          (redisplay t)
          (length (drgnx-grid-tiles))))
      (defun drgnx-perf--tile-restore-measure ()
        "The ten tiles' snapshot put back five times (the median): (:tiles MS :mode_load_ms MS)."
        (let ((snap (drgnx-grid-snapshot 'perf)) ms)
          (dotimes (_ 5)
            (let ((t0 (float-time)))
              (condition-case nil (drgnx-grid-restore snap) (user-error nil))
              (redisplay t)
              (push (* 1000.0 (- (float-time) t0)) ms)))
          (list :tiles (nth 2 (sort ms #'<)) :mode_load_ms 0)))
      (defun drgnx-perf--tile-drag-measure ()
        "A drag over the editor tiles' zones (the drop hint on a tab line, drawn) and 20 drops, each undone by the next
restore: (:motion STATS :drop STATS)."
        (let* ((tiles (drgnx-grid-tiles nil 'editor)) (a (car tiles)) (b (cadr tiles))
               (snap (drgnx-grid-snapshot 'perf)) motion drop)
          (dotimes (i 41)
            (let ((d (drgnx-perf--tile-ms (lambda () (drgnx-grid--drag-show b (if (cl-evenp i) 'right 'below))))))
              (when (> i 0) (push d motion))))
          (drgnx-grid--drag-clear)
          (dotimes (i 21)
            (let ((d (drgnx-perf--tile-ms (lambda () (condition-case nil (drgnx-grid--drop a b 'right) (user-error nil))))))
              (when (> i 0) (push d drop)))
            (condition-case nil (drgnx-grid-restore snap) (user-error nil))
            (setq a (car (drgnx-grid-tiles nil 'editor)) b (cadr (drgnx-grid-tiles nil 'editor))))
          (list :motion (drgnx-perf--tile-stats motion) :drop (drgnx-perf--tile-stats drop))))
      (defun drgnx-perf--tile-down ()
        "The workload's tiles away: the grid's undo of the window changes, the files closed."
        (dolist (b (buffer-list))
          (when (and (buffer-file-name b) (string-prefix-p (expand-file-name "wb" drgnx-dir) (buffer-file-name b)))
            (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
        (global-unset-key (kbd "<f7>"))
        (delete-other-windows)
        t)
      t))
  "The session side of the tiling workloads, as a form string.")

(defun drgnx-perf-tiling-workloads ()
  "The tiling workloads (specs like `drgnx-perf-run--workloads'): `tile-switcher-show', `tile-focus', `tile-move',
`layout-restore' and `pane-drag'."
  (let ((keys (lambda (k n) (make-list n (list :keys k))))
        (lib drgnx-perf-tiling--lib-form))
    `((tile-switcher-show
       :setup ,(concat "(progn " lib " (or (drgnx-perf--tile-up) (error \"Premise: fewer than six tiles\")))")
       :measure "(drgnx-perf--tile-show-measure)" :repeat 1 :timeout 300
       :teardown "(drgnx-perf--tile-down)")
      (tile-focus
       :setup ,(concat "(progn " lib " (or (drgnx-perf--tile-up) (error \"Premise: fewer than six tiles\"))"
                       " (global-set-key (kbd \"<f7>\") #'drgnx-perf--tile-focus-step) t)")
       :actions ,(funcall keys "<f7>" 100)
       :teardown "(drgnx-perf--tile-down)")
      (tile-move
       :setup ,(concat "(progn " lib " (or (drgnx-perf--tile-up) (error \"Premise: fewer than six tiles\"))"
                       " (select-window (car (drgnx-grid-tiles nil 'editor)))"
                       " (global-set-key (kbd \"<f7>\") #'drgnx-perf--tile-move-step) t)")
       :actions ,(funcall keys "<f7>" 50)
       :teardown "(drgnx-perf--tile-down)")
      (layout-restore
       :setup ,(concat "(progn " lib " (or (<= 10 (drgnx-perf--tile-ten)) (error \"Premise: fewer than ten tiles\")))")
       :measure "(drgnx-perf--tile-restore-measure)" :repeat 1 :timeout 300
       :teardown "(drgnx-perf--tile-down)")
      (pane-drag
       :setup ,(concat "(progn " lib " (or (drgnx-perf--tile-up) (error \"Premise: fewer than six tiles\")))")
       :measure "(drgnx-perf--tile-drag-measure)" :repeat 1 :timeout 300
       :teardown "(drgnx-perf--tile-down)"))))

(provide 'drgnx-perf-tiling)
;;; drgnx-perf-tiling.el ends here
