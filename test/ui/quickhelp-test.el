;;; quickhelp-test.el --- GUI tests: quick help — a card beside the symbol, never over its line (run by `drgnx test --ui') -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-quickhelp-ui-test--repo                     ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb"))                ; ui/face needs wb's drgnx-chrome, ui/look its drgnx-wb
  (add-to-list 'load-path (expand-file-name d drgnx-quickhelp-ui-test--repo)))
(dolist (m '("ui/drgnx-face" "ui/drgnx-quickhelp"))
  (load (expand-file-name (concat "modules/" m) drgnx-quickhelp-ui-test--repo) nil t))

(defun drgnx-quickhelp-ui-test--line-at (x y root)
  "The (WINDOW . LINE) of the root frame's text at pixel X, Y, or nil (Emacs's own hit test)."
  (let* ((posn (posn-at-x-y x y root)) (w (posn-window posn)) (p (posn-point posn)))
    (when (and (windowp w) p (null (posn-area posn)))
      (cons w (with-current-buffer (window-buffer w) (line-number-at-pos p))))))

(ert-deftest drgnx-ui-quickhelp/a-card-beside-the-symbol ()
  (let* ((root (drgnx-uitest-root-frame)) (dir (make-temp-file "drgnx-quickhelp-shot" t))
         (buf (generate-new-buffer "quickhelp-fixture.el")))
    (unwind-protect
        (with-selected-frame root
          (delete-other-windows)
          (switch-to-buffer buf)
          (dotimes (i 60) (insert (format "(defun fixture-%d (x) \"A function.\" (car (cdr x)))\n" i)))
          (emacs-lisp-mode)
          ;; a tab line and a header line above the text, as an editor window has (the card's Y must count them)
          (setq-local tab-line-format "tabs" header-line-format "header")
          (goto-char (point-min))
          (forward-line 20)
          (search-forward "(car ")
          (backward-char 4)                       ; on `car'
          (recenter 10)
          (redisplay t)
          (let ((editor (selected-window)) (line (line-number-at-pos)))
            (call-interactively #'drgnx-quickhelp-show)
            (drgnx-test-wait #'drgnx-quickhelp-shown-p :secs 3 :what "the quick help card")
            (redisplay t) (sit-for 0.3)
            (should (drgnx-quickhelp-shown-p))
            (should (eq (selected-window) editor))              ; the card never takes the focus
            (should (= (point) (save-excursion (goto-char (point-min)) (forward-line 20) (search-forward "(car ") (- (point) 4))))
            (let* ((card drgnx-quickhelp--frame) (e (frame-edges card 'outer-edges)) (x (+ (nth 0 e) 4)))
              (should (eq (frame-parent card) root))
              (should (frame-visible-p card))
              (should (string-search "car" (with-current-buffer (window-buffer (frame-root-window card)) (buffer-string))))
              ;; no row of the card is on point's line
              (cl-loop for y from (nth 1 e) below (nth 3 e)
                       do (should-not (equal (drgnx-quickhelp-ui-test--line-at x y root) (cons editor line))))
              ;; beside it: the row just above the card (or just below) is point's line
              (should (or (equal (drgnx-quickhelp-ui-test--line-at x (1- (nth 1 e)) root) (cons editor line))
                          (equal (drgnx-quickhelp-ui-test--line-at x (1+ (nth 3 e)) root) (cons editor line))))
              ;; inside the window
              (pcase-let ((`(,l ,top ,r ,b) (window-inside-pixel-edges editor)))
                (should (>= (nth 0 e) l)) (should (<= (nth 2 e) (+ r 2)))
                (should (>= (nth 1 e) top)) (should (<= (nth 3 e) (+ b 2)))))
            (let ((shot (drgnx-uitest-capture dir)))
              (copy-file (plist-get shot :root) (expand-file-name "quickhelp-root.png" temporary-file-directory) t)
              ;; under Glitnir the card is inside the root's picture: capture reports no children
              (unless (drgnx-uitest-glitnir-p)
                (should (= (length (plist-get shot :children)) 1))
                (copy-file (plist-get (aref (plist-get shot :children) 0) :path)
                           (expand-file-name "quickhelp-card.png" temporary-file-directory) t)
                (message "quick help screenshot: %s (card at %S)" (expand-file-name "quickhelp-root.png" temporary-file-directory)
                         (list (plist-get (aref (plist-get shot :children) 0) :x) (plist-get (aref (plist-get shot :children) 0) :y)))))
            ;; typing puts it away
            (drgnx-uitest-run (list ?a))
            (should-not (drgnx-quickhelp-shown-p))
            ;; out of sight at once (moved outside the frame), unmapped once idle
            (let ((e (frame-edges drgnx-quickhelp--frame 'outer-edges)))
              (should (or (not (frame-visible-p drgnx-quickhelp--frame)) (< (nth 2 e) 0) (< (nth 3 e) 0))))
            (drgnx-quickhelp--unmap)
            (should-not (frame-visible-p drgnx-quickhelp--frame))))
      (drgnx-quickhelp-hide)
      (drgnx-quickhelp--unmap)
      (when (buffer-live-p buf) (with-current-buffer buf (set-buffer-modified-p nil)) (kill-buffer buf))
      (delete-directory dir t))))

(ert-deftest drgnx-ui-quickhelp/a-wrapped-line-stays-clear-and-the-close-mark-closes ()
  (let* ((root (drgnx-uitest-root-frame)) (buf (generate-new-buffer "quickhelp-wrapped.el")))
    (unwind-protect
        (with-selected-frame root
          (delete-other-windows)
          (switch-to-buffer buf)
          (dotimes (i 10) (insert (format "(defun fixture-%d (x) (car x))\n" i)))
          ;; one logical line wrapped over several screen rows, `car' on its first row
          (insert "(car (list \"" (mapconcat #'number-to-string (number-sequence 1 150) " ") "\"))\n")
          (dotimes (i 30) (insert (format "(defun more-%d (x) (cdr x))\n" i)))
          (emacs-lisp-mode)
          (setq truncate-lines nil)
          (goto-char (point-min))
          (forward-line 10)
          (forward-char 1)                        ; on `car'
          (recenter 3)
          (redisplay t)
          (let ((editor (selected-window)) (line (line-number-at-pos)))
            (should (> (count-screen-lines (line-beginning-position) (line-end-position)) 1))
            (call-interactively #'drgnx-quickhelp-show)
            (drgnx-test-wait #'drgnx-quickhelp-shown-p :secs 3 :what "the quick help card")
            (redisplay t) (sit-for 0.3)
            (should (drgnx-quickhelp-shown-p))
            (let* ((card drgnx-quickhelp--frame) (e (frame-edges card 'outer-edges)) (x (+ (nth 0 e) 4)))
              ;; no row of the card is on any screen row of point's (wrapped) line
              (cl-loop for y from (nth 1 e) below (nth 3 e)
                       do (should-not (equal (drgnx-quickhelp-ui-test--line-at x y root) (cons editor line))))
              ;; a click on its ✕ closes it; the editor keeps the focus and point
              (let* ((cw (frame-root-window card))
                     (p (with-current-buffer (window-buffer cw)
                          (text-property-any (point-min) (point-max) 'drgnx-quickhelp-action #'ignore)))
                     (pt (point)))
                (should p)
                (drgnx-uitest-run (drgnx-uitest-click-events (posn-at-point p cw)))
                (should-not (drgnx-quickhelp-shown-p))
                (should (eq (selected-window) editor))
                (should (= (point) pt))))))
      (drgnx-quickhelp-hide)
      (drgnx-quickhelp--unmap)
      (when (buffer-live-p buf) (with-current-buffer buf (set-buffer-modified-p nil)) (kill-buffer buf)))))

(ert-deftest drgnx-ui-quickhelp/card-has-chrome ()
  ;; Under Glitnir the card is rounded and shadowed: the corner pixel is what lies beneath, the shadow darkens the
  ;; root beside the card, and the border ring keeps the card's border colour.
  (skip-unless (drgnx-uitest-glitnir-p))
  (load (expand-file-name "modules/ui/drgnx-look" drgnx-quickhelp-ui-test--repo) nil t)
  (let* ((root (drgnx-uitest-root-frame)) (buf (generate-new-buffer "quickhelp-chrome.el")) none)
    (unwind-protect
        (with-selected-frame root
          (delete-other-windows)
          (switch-to-buffer buf)
          (dotimes (i 60) (insert (format "(defun fixture-%d (x) \"A function.\" (car (cdr x)))\n" i)))
          (emacs-lisp-mode)
          (goto-char (point-min)) (forward-line 20) (search-forward "(car ") (backward-char 4)
          (recenter 10)
          (redisplay t) (sit-for 0.3)
          (setq none (drgnx-uitest-snapshot root))
          (when (frame-live-p drgnx-quickhelp--frame)  ; an earlier test's card was made without the chrome
            (delete-frame drgnx-quickhelp--frame) (setq drgnx-quickhelp--frame nil drgnx-quickhelp--card-up nil))
          (call-interactively #'drgnx-quickhelp-show)
          (drgnx-test-wait #'drgnx-quickhelp-shown-p :secs 3 :what "the quick help card")
          (redisplay t) (sit-for 0.3)
          (should (drgnx-quickhelp-shown-p))
          (let* ((card drgnx-quickhelp--frame) (s (frame-scale-factor root))
                 (e (frame-edges card 'outer-edges)) (p (frame-edges root 'native-edges))
                 (l (round (* s (- (nth 0 e) (nth 0 p))))) (tp (round (* s (- (nth 1 e) (nth 1 p)))))
                 (r (round (* s (- (nth 2 e) (nth 0 p))))) (b (round (* s (- (nth 3 e) (nth 1 p)))))
                 (snap (drgnx-uitest-snapshot root))
                 (border (cdr (drgnx-quickhelp-colors root))))
            ;; rounded: the corner pixel is what lies beneath (the picture without the card, at most darkened by the
            ;; shadow's faint edge), not the card's border; a few pixels in along the diagonal the border is drawn
            (let ((c (nth 2 (drgnx-uitest-pixel snap l tp))) (n (nth 2 (drgnx-uitest-pixel none l tp)))
                  (in (cl-loop for i from 0 to (* 8 (ceiling s))
                               minimize (nth 2 (drgnx-uitest-pixel snap (+ l i) (+ tp i))))))
              (should (<= (- n 24) c n))
              (should (> c (+ in 40))))
            (should (drgnx-uitest-darker-p snap none (+ r 3) (/ (+ tp b) 2)))
            (let ((px (drgnx-uitest-pixel snap (/ (+ l r) 2) tp))
                  (want (mapcar (lambda (c) (/ c 256)) (color-values border))))
              (should (equal (cdr px) want)))))
      (drgnx-quickhelp-hide)
      (drgnx-quickhelp--unmap)
      (when (buffer-live-p buf) (with-current-buffer buf (set-buffer-modified-p nil)) (kill-buffer buf)))))

;;; quickhelp-test.el ends here
