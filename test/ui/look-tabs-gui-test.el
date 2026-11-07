;;; look-tabs-gui-test.el --- GUI tests: tabs join the editor, the close mark appears on hover (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; Pattern D: every picture is taken after `drgnx-test-wait-presented'.  The hover row moves a real pointer
;; (`drgnx-uitest-pointer-set': sway only), so it skips elsewhere and the integration's sway pass must report it
;; passed.  The tabs are put on a window by their parameters, through chrome's own setter.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-look-tabs--repo               ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-look-tabs--repo)))
(require 'drgnx)
(require 'drgnx-color)
(require 'drgnx-chrome)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-look-tabs--repo) nil t)

(defmacro drgnx-ui-look-tabs--with (&rest body)
  "BODY in a bare frame with one window showing the buffer `b', whose tab line holds the tabs `a' and `b' (b is
shown), under the dark theme.  Everything undone after."
  (declare (indent 0))
  `(let ((a (get-buffer-create "*look-tabs-a*")) (b (get-buffer-create "*look-tabs-b*")))
     (drgnx-uitest-bare-frame)
     (delete-other-windows)
     (switch-to-buffer b)
     (set-window-parameter (selected-window) 'drgnx-tabs (list a b))
     (mapc #'disable-theme custom-enabled-themes)
     (load-theme 'drgnx-dark t)
     (drgnx-chrome--set (selected-window) 'tab-line-format (drgnx-chrome--tab-line (selected-window)))
     (unwind-protect
         (progn (drgnx-test-wait-presented) ,@body)
       (mapc #'disable-theme custom-enabled-themes)
       (set-window-parameter (selected-window) 'tab-line-format nil)
       (set-window-parameter (selected-window) 'drgnx-tabs nil)
       (kill-buffer a) (kill-buffer b))))

(defun drgnx-ui-look-tabs--rgb (name)
  (mapcar (lambda (c) (round (* 255 c))) (drgnx-color-rgb (drgnx-look-token name 'dark))))

(defun drgnx-ui-look-tabs--close-at-p (w buffer x y)
  "Non-nil when the tab-line pixel X, Y of window W (counted from its top left corner) is BUFFER's close mark."
  (let* ((p (posn-at-x-y x y w t)) (s (and p (posn-string p))))
    (and s (stringp (car s))
         (eq (get-text-property (cdr s) 'drgnx-buffer (car s)) buffer)
         (equal (get-text-property (cdr s) 'help-echo (car s)) "Close this tab"))))

(defun drgnx-ui-look-tabs--origin ()
  "Where the focused sway window's client area starts in the layout, (X . Y): sway draws its own title bar above it."
  (let ((json (with-temp-buffer
                (call-process "swaymsg" nil t nil "-t" "get_tree")
                (goto-char (point-min))
                (json-parse-buffer :object-type 'alist :array-type 'list)))
        found)
    (cl-labels ((walk (n)
                  (when (eq (alist-get 'focused n) t) (setq found n))
                  (dolist (c (append (alist-get 'nodes n) (alist-get 'floating_nodes n))) (walk c))))
      (walk json))
    (let ((rect (alist-get 'rect found)) (win (alist-get 'window_rect found)))
      (cons (+ (alist-get 'x rect) (alist-get 'x win)) (+ (alist-get 'y rect) (alist-get 'y win))))))

(defun drgnx-ui-look-tabs--near (px rgb)
  (cl-every (lambda (a b) (<= (abs (- a b)) 2)) (cdr px) rgb))

(ert-deftest drgnx-ui-look-tabs/active-tab-joins-the-editor ()
  "Pattern D: the shown tab is on the `editor' colour down to the text: a pixel in its last row and a pixel of the
text area just below the tab line are both the `editor' token, and the tab line's empty part is `panel'."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-tabs--with
    (set-window-parameter (selected-window) 'drgnx-tabs (list (window-buffer)))        ; the shown tab alone, at the left
    (drgnx-chrome--set (selected-window) 'tab-line-format (drgnx-chrome--tab-line (selected-window)))
    (drgnx-test-wait-presented)
    (let* ((w (selected-window)) (s (drgnx-uitest-device-scale (selected-frame))) (edges (window-pixel-edges w))
           (top (round (* s (nth 1 edges)))) (h (window-tab-line-height w))
           (snap (drgnx-uitest-snapshot))
           (x (round (* s (+ (nth 0 edges) 4)))))
      (should (> h 0))
      (should (drgnx-ui-look-tabs--near (drgnx-uitest-pixel snap x (+ top h -2)) (drgnx-ui-look-tabs--rgb 'editor)))
      (should (drgnx-ui-look-tabs--near (drgnx-uitest-pixel snap x (+ top h 2)) (drgnx-ui-look-tabs--rgb 'editor)))
      (should (drgnx-ui-look-tabs--near (drgnx-uitest-pixel snap (- (round (* s (nth 2 edges))) 40) (+ top 2))
                                        (drgnx-ui-look-tabs--rgb 'panel))))))

(ert-deftest drgnx-ui-look-tabs/hover-reveals-the-close ()
  "Pattern D (sway): the close mark of a tab that is not shown is drawn in the tab's own background until the pointer
is on the tab, then in a foreground colour, and again in the background after the pointer leaves."
  (skip-unless (display-graphic-p))
  (skip-unless (eq t (drgnx-uitest-pointer-set 0 0)))
  (drgnx-ui-look-tabs--with
    (let* ((w (selected-window)) (s (drgnx-uitest-device-scale (selected-frame))) (edges (window-pixel-edges w))
           (a (car (window-parameter w 'drgnx-tabs)))
           (y (/ (window-tab-line-height w) 2))
           (xs (seq-filter (lambda (x) (drgnx-ui-look-tabs--close-at-p w a x y)) (number-sequence 0 (window-pixel-width w))))
           (x0 (car xs)) (x1 (car (last xs)))
           (px-y (round (* s (+ (nth 1 edges) y)))) (px-x0 (round (* s (+ (nth 0 edges) x0))))
           (px-x1 (round (* s (+ (nth 0 edges) x1))))
           (fg (drgnx-ui-look-tabs--rgb 'fg))
           (cell-has-fg (lambda ()
                          (let ((snap (drgnx-uitest-snapshot)) found)
                            (cl-loop for x from px-x0 to px-x1
                                     do (cl-loop for yy from (- px-y 4) to (+ px-y 4)
                                                 do (when (cl-every (lambda (p c) (<= (abs (- p c)) 24))
                                                                    (cdr (drgnx-uitest-pixel snap x yy)) fg)
                                                      (setq found t))))
                            found))))
      (should xs)
      (should-not (funcall cell-has-fg))
      (let ((origin (drgnx-ui-look-tabs--origin)))
        (should (eq t (drgnx-uitest-pointer-set (+ (car origin) (round (/ (+ px-x0 px-x1) 2.0 s)))
                                                (+ (cdr origin) (round (/ px-y s))))))
        (drgnx-uitest-run nil)                  ; the motion reaches the command loop, which lights the tab
        (drgnx-test-wait-presented)
        ;; Headless sway moves its cursor but the frame may never get the pointer-enter event: then there is no
        ;; hover to see, and the row says so (a skip, listed in the report) instead of failing on a missing event.
        (skip-unless (cadr (mouse-pixel-position)))
        (should (funcall cell-has-fg))
        (should (eq t (drgnx-uitest-pointer-set (+ (car origin) (round (/ (nth 2 edges) 2.0)))
                                                (+ (cdr origin) (round (/ (nth 3 edges) 2.0)))))))
      (drgnx-uitest-run nil)
      (drgnx-test-wait-presented)
      (should-not (funcall cell-has-fg)))))

(provide 'look-tabs-gui-test)
;;; look-tabs-gui-test.el ends here
