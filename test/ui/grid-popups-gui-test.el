;;; grid-popups-gui-test.el --- GUI test: popups over the grid leave no trace, on every compositor (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; A child frame (as corfu makes its own), a transient and which-key over a frame of tiles, the grid backend on: the
;; compositor gets no new top-level window to place or tile, and once each is gone every window of the frame is where it
;; was, to the pixel.  On the session's own frame, its size left to the compositor (a tiling one sizes it, and a new
;; top-level frame would make it re-tile the first); its windows are put back after.  Tagged :compositor: it runs in the real-compositor lane (mutter, sway, kwin) as in the plain tier.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-grid-popups--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-grid-popups--repo)))
(defvar drgnx-dir)
(setq drgnx-dir (or (bound-and-true-p drgnx-dir) drgnx-ui-grid-popups--repo))
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-ui-grid-popups--repo) nil t)
(require 'drgnx-rules)
(require 'drgnx-popup)
(require 'transient)
(defvar transient-display-buffer-action)

(defun drgnx-ui-grid-popups--top-level ()
  "The visible frames a compositor places: the top-level ones (a child frame is drawn inside its parent)."
  (length (seq-remove #'frame-parent (visible-frame-list))))

(defun drgnx-ui-grid-popups--settled (frame)
  "FRAME's windows' pixel edges once the compositor's answers are in (the same for half a second)."
  (let ((last nil) (since nil))
    (drgnx-test-wait (lambda ()
                       (redisplay t)
                       (let ((now (list (frame-pixel-width frame) (frame-pixel-height frame)
                                        (mapcar #'window-pixel-edges (window-list frame 'nomini)))))
                         (if (equal now last) (>= (- (drgnx-test-wait-now) since) 0.5)
                           (setq last now since (drgnx-test-wait-now))
                           nil)))
                     :secs 10 :what "the frame's size")
    last))

(ert-deftest drgnx-ui-grid-popups/popups-over-tiles-leave-no-trace ()
  "Formerly drgnx-wm/popups-under-tiling-leave-no-trace (sway only, from outside the session)."
  :tags '(:compositor)
  (unless (display-graphic-p) (ert-skip "needs a graphical frame"))
  (let ((frame (selected-frame)) (config (current-window-configuration)) (bad nil))
    (unwind-protect
        (cl-letf (((symbol-function 'set-frame-size) #'ignore))   ; the fixture's 160 × 50: the compositor's size stays
          (drgnx-grid-test--with
            (drgnx-rules-mode 1)
            (unwind-protect
                (progn
                  (drgnx-pane-show 'g-term)
                  (let ((top (drgnx-ui-grid-popups--top-level)))
                    (dolist (popup
                             (list
                              (list "child frame"
                                    (lambda ()
                                      (let ((child (make-frame `((parent-frame . ,frame) (minibuffer . ,(minibuffer-window frame))
                                                                 (visibility . nil) (left . 120) (top . 80) (width . 30)
                                                                 (height . 6) (no-accept-focus . t) (no-focus-on-map . t)
                                                                 (undecorated . t) (no-other-frame . t) (unsplittable . t)
                                                                 (child-frame-border-width . 1) (menu-bar-lines . 0)
                                                                 (tool-bar-lines . 0) (tab-bar-lines . 0)
                                                                 (vertical-scroll-bars . nil) (desktop-dont-save . t)))))
                                        (make-frame-visible child)
                                        child))
                                    #'frame-visible-p #'delete-frame)
                              (list "transient"
                                    (lambda () (display-buffer (get-buffer-create " *transient*") transient-display-buffer-action))
                                    #'window-live-p (lambda (w) (quit-window nil w)))
                              (list "which-key"
                                    (lambda () (display-buffer-in-side-window (get-buffer-create " *which-key*")
                                                                              '((side . bottom) (slot . 0))))
                                    #'window-live-p #'delete-window)))
                      (pcase-let* ((`(,name ,open ,shown-p ,close) popup)
                                   (before (drgnx-ui-grid-popups--settled frame))
                                   (it (funcall open))
                                   (shown (progn (redisplay t) (and it (funcall shown-p it) t)))
                                   (top-open (drgnx-ui-grid-popups--top-level)))
                        (funcall close it)
                        (let ((after (drgnx-ui-grid-popups--settled frame)))
                          (unless (and shown (= top-open top) (= (drgnx-ui-grid-popups--top-level) top)
                                       (equal after before))
                            (push (list name :shown shown :top-open top-open :before before :after after) bad)))))))
              (drgnx-rules-mode -1)
              ;; the popup lane keeps its floating frame for the next popup (`drgnx-popup--float-frame'): this row's own
              (when-let* ((f (frame-parameter frame 'drgnx-popup-frame)))
                (when (frame-live-p f) (delete-frame f))
                (set-frame-parameter frame 'drgnx-popup-frame nil))
              (dolist (b '(" *transient*" " *which-key*")) (when (get-buffer b) (kill-buffer b))))))
      (set-window-configuration config))
    (should-not bad)))

;;; grid-popups-gui-test.el ends here
