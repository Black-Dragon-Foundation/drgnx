;;; switcher-gui-test.el --- GUI test: the tile switcher's cards (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Switch Tile on a frame of its own with three tiles: each tile gets a card, a child frame centred on it, its letter
;; first; closing hides the cards (they stay in the pool).  Run at each scale (ui1, ui2).

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-switcher--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-switcher--repo)))
(defvar drgnx-dir)
(setq drgnx-dir (or (bound-and-true-p drgnx-dir) drgnx-ui-switcher--repo))
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-ui-switcher--repo) nil t)
(require 'drgnx-groups)
(require 'drgnx-grid-ops)
(require 'drgnx-switcher)

(ert-deftest drgnx-ui-switcher/cards-centre-on-tiles ()
  (skip-unless (display-graphic-p))
  (let ((frames (frame-list)) (selected (selected-frame))
        (frame (make-frame '((width . 160) (height . 50)))))
    (unwind-protect
        (with-selected-frame frame
          (drgnx-grid-test--with
            (drgnx-test-wait (lambda () (redisplay t) (frame-visible-p frame)) :secs 10 :what "the frame mapped")
            (drgnx-groups-split-right)
            (drgnx-groups-split-down)
            (redisplay t)
            (unwind-protect
                (progn
                  (drgnx-switcher-open)
                  (let ((mine (seq-filter (lambda (it) (eq (plist-get it :frame) frame))
                                          (plist-get drgnx-switcher--state :items))))
                    (should (= 3 (length mine)))
                    (drgnx-test-wait (lambda () (redisplay t)
                                       (seq-every-p (lambda (e) (frame-visible-p (car e)))
                                                    (seq-filter (lambda (e) (eq (frame-parent (car e)) frame))
                                                                drgnx-switcher--pool)))
                                     :secs 10 :what "the cards shown")
                    (dolist (it mine)
                      (let* ((card (seq-find (lambda (e) (and (frame-visible-p (car e)) (eq (frame-parent (car e)) frame)
                                                              (with-current-buffer (cdr e)
                                                                (goto-char (point-min))
                                                                (skip-chars-forward " ")
                                                                (eq (char-after) (plist-get it :letter)))))
                                             drgnx-switcher--pool))
                             (e (plist-get it :local))
                             (pos (frame-position (car card))))
                        (should card)
                        (should (<= (abs (- (+ (car pos) (/ (frame-pixel-width (car card)) 2)) (/ (+ (nth 0 e) (nth 2 e)) 2))) 2))
                        (should (<= (abs (- (+ (cdr pos) (/ (frame-pixel-height (car card)) 2)) (/ (+ (nth 1 e) (nth 3 e)) 2))) 2))))))
              (drgnx-switcher-close))
            (should-not (seq-some (lambda (e) (frame-visible-p (car e))) drgnx-switcher--pool))))
      (drgnx-switcher-delete-pool)
      (dolist (f (frame-list)) (unless (memq f frames) (delete-frame f t)))
      (when (frame-live-p selected) (select-frame selected)))))

(provide 'switcher-gui-test)
;;; switcher-gui-test.el ends here
