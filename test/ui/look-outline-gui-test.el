;;; look-outline-gui-test.el --- GUI tests: the Outline's empty state (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; Pattern D: every picture is taken after `drgnx-test-wait-presented'.  The Outline is shown in a sidebar-wide
;; window on the left of a bare frame, the editor on the right holds a buffer without an index.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-look-outline--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-look-outline--repo)))
(require 'drgnx)
(require 'drgnx-color)
(require 'drgnx-outline)
(load (expand-file-name "modules/ui/drgnx-look-fonts" drgnx-ui-look-outline--repo) nil t)
(load (expand-file-name "modules/ui/drgnx-look-density" drgnx-ui-look-outline--repo) nil t)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-look-outline--repo) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)

(defun drgnx-ui-look-outline--wait-for (re what)
  "Wait until the Outline's buffer, its rows from the hub drawn, holds RE (WHAT names it in a failure)."
  (drgnx-test-wait (lambda () (when-let* ((b (get-buffer drgnx-outline-buffer-name)))
                                (with-current-buffer b (drgnx-view-draw-now nil) (string-match-p re (buffer-string)))))
                   :secs 10 :what what))

(drgnx-look-gui-deftest drgnx-ui-look-outline/the-empty-state-is-whole-and-quiet ()
  "Pattern D: a file without an outline shows an icon and \"No outline for this file\" in the muted text, whole (not
scrolled sideways, not cut at the right), and never as the selected row: no fill or ring before or around it, also
when a row of the file before was selected (its selection must not outlive its row).  The hub builds the Outline's
rows: the row runs with one (`drgnx-test-with-ratatoskr') and waits for its rows after each refresh."
  (skip-unless (display-graphic-p))
  (drgnx-uitest-bare-frame)
  (delete-other-windows)
  (mapc #'disable-theme custom-enabled-themes)
  (load-theme 'drgnx-dark t)
  (drgnx-test-with-ratatoskr (make-temp-file "duio" t)
    (let* ((code (generate-new-buffer "outline-code"))
           (src (generate-new-buffer "outline-src"))
           (side (selected-window))
           (editor (split-window side (drgnx-px 248 (selected-frame)) 'right t))
           ;; the Outline's state, fresh (wb-outline-test's fixture binds the same)
           (drgnx-outline--source nil) (drgnx-outline--sent :none) (drgnx-outline--reveal nil)
           (drgnx-outline--mark nil) (drgnx-outline--waiting nil))
      (unwind-protect
          (cl-letf (((symbol-function 'drgnx-wb-editor-window) (lambda (&rest _) editor)))
            (drgnx-look-density-on)
            (with-current-buffer code
              (insert "(defun alpha () 1)\n(defun beta () 2)\n(defun gamma () 3)\n") (emacs-lisp-mode))
            (with-current-buffer src (insert "nothing to index here\n") (fundamental-mode))
            (set-window-parameter side 'drgnx-role 'dock)
            (drgnx-outline-setup)
            (set-window-buffer side (drgnx-outline--buffer))
            ;; as in the scene: the Outline lists a file's definitions, one of them selected (a click on its row)
            (set-window-buffer editor code)
            (drgnx-view-env-update drgnx-outline-hub-view)
            (drgnx-outline-refresh)
            (drgnx-ui-look-outline--wait-for "\\S-" "the first file's rows")
            (drgnx-test-wait-presented)
            (with-selected-window side (goto-char (point-min)) (forward-line 2) (drgnx-wb-selection-sync))
            (drgnx-test-wait-presented)
            ;; then the editor shows a file without an outline
            (set-window-buffer editor src)
            (drgnx-outline-refresh)
            (drgnx-ui-look-outline--wait-for "No outline for this file" "the notice")
            (drgnx-test-wait-presented)
            (with-current-buffer drgnx-outline-buffer-name
              (goto-char (point-min))
              (let* ((text (text-property-search-forward 'face 'drgnx-text-muted
                                                         (lambda (v f) (memq v (ensure-list f)))))
                     (beg (and text (prop-match-beginning text)))
                     (eol (save-excursion (goto-char (point-min)) (pos-eol))))
                (should (string-match-p "No outline for this file" (buffer-string)))
                (should beg)                                   ; the muted text
                (should (= 0 (window-hscroll side)))
                (let ((last (pos-visible-in-window-p (1- eol) side t)))   ; its last letter inside the window
                  (should last)
                  (should (< (car last) (window-body-width side t))))
                (should-not (seq-find (lambda (o) (and (overlay-get o 'drgnx-row-selected) (overlay-buffer o)
                                                       (< (overlay-start o) (overlay-end o))))
                                      (overlays-in (point-min) (point-max))))
                ;; no block before the icon: the row's left edge is the panel's colour
                (let* ((snap (drgnx-uitest-snapshot)) (s (drgnx-uitest-device-scale (selected-frame)))
                       (e (window-body-pixel-edges side))
                       (y (round (* s (+ (nth 1 e) (/ (line-pixel-height) 2)))))
                       (panel (mapcar (lambda (c) (round (/ c 257.0)))
                                      (color-values (face-background 'drgnx-surface-panel nil t))))
                       (px (cdr (drgnx-uitest-pixel snap (round (* s (+ (nth 0 e) 3))) y))))
                  (should (cl-every (lambda (p c) (<= (abs (- p c)) 6)) px panel))))))
        (drgnx-outline--watch nil)
        (remove-hook 'drgnx-fold-changed-hook #'drgnx-outline--folds-changed)   ; `drgnx-outline-setup's
        (drgnx-look-density-off)
        (when (window-live-p editor) (delete-window editor))
        (set-window-parameter side 'drgnx-role nil)
        (mapc #'disable-theme custom-enabled-themes)
        (when (get-buffer drgnx-outline-buffer-name) (kill-buffer drgnx-outline-buffer-name))
        (kill-buffer src)
        (kill-buffer code)))))

;;; look-outline-gui-test.el ends here
