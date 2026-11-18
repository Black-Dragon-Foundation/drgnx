;;; switcher-gui-test.el --- GUI test: the tile switcher's cards (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Switch Tile on a frame of its own with three tiles: each tile gets a card, a child frame centred on it, its letter
;; first; closing hides the cards (they stay in the pool); the current tile's card carries the focus ring.  Run at each
;; scale (ui1, ui2).

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
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-switcher--repo) nil t) ; drgnx-dark: the focus colour

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

(defun drgnx-ui-switcher--ring (entry)
  "The colour of card ENTRY's ring: its frame's own `child-frame-border' background."
  (face-background 'child-frame-border (car entry) t))

(ert-deftest drgnx-ui-switcher/one-card-ringed-on-the-current-tile ()
  "Each card is one popup (tiling.html's `.letter'): no kit card drawn inside it, its text fits its window (nothing cut
at the edge), and the current tile's card has the focus colour's ring, which follows the highlight."
  (skip-unless (display-graphic-p))
  (let ((frames (frame-list)) (selected (selected-frame)) (themes custom-enabled-themes)
        (frame (make-frame '((width . 160) (height . 50)))))
    (unwind-protect
        (with-selected-frame frame
          (load-theme 'drgnx-dark t)
          (drgnx-grid-test--with
            (drgnx-test-wait (lambda () (redisplay t) (frame-visible-p frame)) :secs 10 :what "the frame mapped")
            (drgnx-groups-split-right)
            (redisplay t)
            (unwind-protect
                (let* ((focus (face-foreground 'drgnx-focus-line frame t))
                       (mine (lambda () (seq-filter (lambda (e) (and (frame-visible-p (car e)) (eq (frame-parent (car e)) frame)))
                                                    drgnx-switcher--pool)))
                       (card-of (lambda (it)
                                  (seq-find (lambda (e) (with-current-buffer (cdr e)
                                                          (string-search (string (plist-get it :letter)) (buffer-string))))
                                            (funcall mine))))
                       (ringed (lambda () (mapcar (lambda (e) (equal (drgnx-ui-switcher--ring e) focus)) (funcall mine)))))
                  (should (stringp focus))
                  (drgnx-switcher-open)
                  (drgnx-test-wait (lambda () (redisplay t) (= 2 (length (funcall mine)))) :secs 10 :what "two cards")
                  (dolist (e (funcall mine))
                    (with-current-buffer (cdr e)
                      (should-not (text-property-search-forward
                                   'face nil (lambda (_ f) (let ((fs (if (listp f) f (list f))))
                                                             (seq-some (lambda (x) (and (symbolp x) (string-prefix-p "drgnx-kit-card-" (symbol-name x))))
                                                                       fs))))))
                    (let ((w (frame-root-window (car e))))
                      (should (<= (car (window-text-pixel-size w nil nil t)) (window-body-width w t)))
                      ;; each line's last character is drawn whole: nothing cut, no truncation glyph
                      (with-current-buffer (cdr e)
                        (goto-char (point-min))
                        (while (not (eobp))
                          (let ((v (pos-visible-in-window-p (1- (line-end-position)) w t)))
                            (should (and v (= 2 (length v)))))
                          (forward-line 1)))))
                  (should (equal (sort (funcall ringed) (lambda (a _) a)) '(t nil)))
                  (should (equal (drgnx-ui-switcher--ring (funcall card-of (plist-get drgnx-switcher--state :current))) focus))
                  (let ((before (plist-get drgnx-switcher--state :current)))
                    (plist-put drgnx-switcher--state :current
                               (seq-find (lambda (it) (and (eq (plist-get it :frame) frame) (not (eq it before))))
                                         (plist-get drgnx-switcher--state :items)))
                    (drgnx-switcher--draw)
                    (redisplay t)
                    (should (equal (drgnx-ui-switcher--ring (funcall card-of (plist-get drgnx-switcher--state :current))) focus))
                    (should-not (equal (drgnx-ui-switcher--ring (funcall card-of before)) focus))))
              (drgnx-switcher-close))))
      (drgnx-switcher-delete-pool)
      (mapc #'disable-theme custom-enabled-themes)
      (dolist (th (reverse themes)) (enable-theme th))
      (dolist (f (frame-list)) (unless (memq f frames) (delete-frame f t)))
      (when (frame-live-p selected) (select-frame selected)))))

(provide 'switcher-gui-test)
;;; switcher-gui-test.el ends here
