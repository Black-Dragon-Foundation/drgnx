;;; look-open-hover-gui-test.el --- GUI test: a hovered Open row's ● becomes its close button (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; Pattern D (sway, Nidhogg's mouse sensors): the dock's Open section with one file that has unsaved changes.  The
;; compositor's pointer moves onto its row, then off: the row's sensor makes it the hovered row and back.  Writes the
;; dock at rest and hovered to the session's evidence folder when there is one (the look crops).

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-look-open-hover--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-look-open-hover--repo)))
(require 'drgnx)
(require 'drgnx-state)
(require 'drgnx-buffers)
(require 'drgnx-explorer)
(load (expand-file-name "modules/ui/drgnx-look-fonts" drgnx-ui-look-open-hover--repo) nil t)
(load (expand-file-name "modules/ui/drgnx-look-density" drgnx-ui-look-open-hover--repo) nil t)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-look-open-hover--repo) nil t)

(defun drgnx-ui-look-open-hover--origin ()
  "Where the focused sway window's client area starts in the layout, (X . Y)."
  (let ((json (with-temp-buffer
                (call-process "swaymsg" nil t nil "-t" "get_tree")
                (goto-char (point-min))
                (json-parse-buffer :object-type 'alist :array-type 'list)))
        found)
    (cl-labels ((walk (n)
                  (when (eq (alist-get 'focused n) t) (setq found n))
                  (mapc #'walk (alist-get 'nodes n))
                  (mapc #'walk (alist-get 'floating_nodes n))))
      (walk json))
    (let ((r (alist-get 'rect found)) (w (alist-get 'window_rect found)))
      (cons (+ (alist-get 'x r) (alist-get 'x w)) (+ (alist-get 'y r) (alist-get 'y w))))))

(defun drgnx-ui-look-open-hover--shot (name)
  "Copy the frame's picture to the evidence folder as NAME-s<scale>.png, when the session has one."
  (when-let* ((dir (getenv "DRGNX_UI_EVIDENCE")) ((file-directory-p dir)))
    (copy-file (plist-get (drgnx-uitest-capture (make-temp-file "open-hover" t)) :root)
               (expand-file-name (format "%s-s%s.png" name (drgnx-pixels-scale)) dir) t)))

(defun drgnx-ui-look-open-hover--settle ()
  (drgnx-uitest-run nil)
  (drgnx-signal--flush)
  (drgnx-test-wait-presented))

(drgnx-look-gui-deftest drgnx-ui-look-open-hover/the-pointer-on-a-row-turns-its-dot-into-the-close ()
  "A file with unsaved changes in the Open section: the pointer on its row makes it the hovered row (× in place of ●),
and off the row, not."
  (skip-unless (display-graphic-p))
  (skip-unless (boundp 'mouse-sensor-enabled))
  (skip-unless (eq t (drgnx-uitest-pointer-set 0 0)))
  (let* ((root (drgnx-uitest-root-frame))
         (dir (file-name-as-directory (make-temp-file "look-open-hover" t)))
         (config (with-selected-frame root (current-window-configuration)))
         (drgnx-wb--sections nil) (drgnx-buffers--order nil) (drgnx-buffers--signature nil)
         (drgnx-explorer--roots (list dir)) opened dirty)
    (unwind-protect
        (with-selected-frame root
          (delete-other-windows)
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme 'drgnx-dark t)
          (drgnx-look-density-on)
          (drgnx-state-mode 1)
          (let ((drgnx-modules--current 'look-open-hover-row) (drgnx-modules--setup-load load-file-name))
            (drgnx-buffers-setup)
            (drgnx-explorer-setup))
          (dolist (n '("a.txt" "b.txt" "c.txt"))
            (let ((f (expand-file-name n dir)))
              (write-region "x\n" nil f nil 'silent)
              (push (find-file-noselect f) opened)))
          (setq dirty (car opened))
          (with-current-buffer dirty (insert "changed "))
          (drgnx-signal--flush)
          (drgnx-wb-show-sidebar)
          (drgnx-ui-look-open-hover--settle)
          (drgnx-ui-look-open-hover--settle)
          (let* ((open (get-buffer-window drgnx-buffers-buffer-name root))
                 (row (with-current-buffer drgnx-buffers-buffer-name (drgnx-buffers--row-pos dirty)))
                 (y (cdr (posn-x-y (posn-at-point row open))))
                 (edges (window-inside-pixel-edges open))
                 (h (with-current-buffer drgnx-buffers-buffer-name (line-pixel-height)))
                 (origin (drgnx-ui-look-open-hover--origin))
                 (s (with-selected-frame root (drgnx-pixels-scale))))   ; a Lisp pixel is a device pixel; sway takes logical ones
            (should row)
            (drgnx-ui-look-open-hover--shot "open-rest")
            (should-not (buffer-local-value 'drgnx-buffers--hovered (window-buffer open)))
            (should (eq t (drgnx-uitest-pointer-set (+ (car origin) (round (/ (+ (nth 0 edges) (nth 2 edges)) 2.0 s)))
                                                    (+ (cdr origin) (round (/ (+ (nth 1 edges) y (/ h 2.0)) s))))))
            (drgnx-ui-look-open-hover--settle)
            ;; headless sway may never give the frame the pointer: then there is no hover to see (a listed skip)
            (skip-unless (cadr (mouse-pixel-position)))
            (should (eq dirty (buffer-local-value 'drgnx-buffers--hovered (window-buffer open))))
            (drgnx-ui-look-open-hover--shot "open-hovered")
            ;; a clean row hovered at the same x (its tail): the tint reaches the row's first glyph too, left of its
            ;; icon (LOOK-FIX-OPEN-HOVER-TINT-1: the row and its tail are one lit run)
            (let* ((pos2 (with-current-buffer drgnx-buffers-buffer-name (drgnx-buffers--row-pos (cadr opened))))
                   (xy2 (posn-x-y (posn-at-point pos2 open)))
                   (bol-x (car (posn-x-y (posn-at-point (with-current-buffer drgnx-buffers-buffer-name
                                                          (save-excursion (goto-char pos2) (pos-bol)))
                                                        open))))
                   (px (lambda () (cdr (drgnx-uitest-pixel (drgnx-uitest-snapshot)
                                                           (round (+ (nth 0 edges) bol-x 2))
                                                           (round (+ (nth 1 edges) (cdr xy2) (/ h 2.0)))))))
                   (rest (funcall px)))
              (should (eq t (drgnx-uitest-pointer-set (+ (car origin) (round (/ (+ (nth 0 edges) (nth 2 edges)) 2.0 s)))
                                                      (+ (cdr origin) (round (/ (+ (nth 1 edges) (cdr xy2) (/ h 2.0)) s))))))
              (drgnx-ui-look-open-hover--settle)
              (drgnx-ui-look-open-hover--shot "open-hovered-clean")
              (should-not (equal rest (funcall px))))
            (should (eq t (drgnx-uitest-pointer-set (+ (car origin) (round (/ (frame-pixel-width root) s)) -40)
                                                    (+ (cdr origin) (round (/ (frame-pixel-height root) 2.0 s))))))
            (drgnx-ui-look-open-hover--settle)
            (should-not (buffer-local-value 'drgnx-buffers--hovered (window-buffer open)))))
      (drgnx-wb-hide-sidebar)
      (dolist (u (alist-get 'look-open-hover-row drgnx-modules--stacks)) (funcall (cdr u)))
      (setf (alist-get 'look-open-hover-row drgnx-modules--stacks nil t) nil)
      (drgnx-state-mode -1)
      (drgnx-look-density-off)
      (mapc #'disable-theme custom-enabled-themes)
      (with-selected-frame root (set-window-configuration config))
      (dolist (b opened) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))
      (dolist (b (list drgnx-buffers-buffer-name drgnx-explorer-buffer-name)) (when (get-buffer b) (kill-buffer b)))
      (delete-directory dir t))))

(provide 'look-open-hover-gui-test)
;;; look-open-hover-gui-test.el ends here
