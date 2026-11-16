;;; panel-tabs-gui-test.el --- GUI tests: every bottom panel tab shows something (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; Audit D2 (the user's report: "except Terminal none of the bottom bar functions work"): each tab of the panel, clicked
;; with the real pointer, shows a buffer that is not blank: Problems lists the project's problems (or says there are
;; none), Output shows a channel, Results and Help say what appears there.  Run at each scale (s1, s2).

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-panel-tabs--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-panel-tabs--repo)))
(require 'drgnx-wb)
(require 'drgnx-area)
(require 'drgnx-state)
(require 'drgnx-pixels)

(defun drgnx-ui-panel-tabs--forget-transient-clears ()
  "Take the hooks a pointer's press leaves on `pre-command-hook' (Emacs's `set-transient-map' makes an uninterned
`clear-transient-map' symbol for each), in every buffer: no keymap of ours is behind them."
  (dolist (b (cons nil (buffer-list)))
    (with-current-buffer (or b (current-buffer))
      (dolist (f (copy-sequence (if b (and (local-variable-p 'pre-command-hook) pre-command-hook)
                                  (default-value 'pre-command-hook))))
        (when (and (symbolp f) (not (intern-soft f)) (equal (symbol-name f) "clear-transient-map"))
          (remove-hook 'pre-command-hook f (and b t)))))))

(defun drgnx-ui-panel-tabs--shot (name)
  "Capture the root frame and keep it as NAME in the evidence folder (DRGNX_UI_EVIDENCE), else the temp dir."
  (redisplay t)
  (let ((shot (plist-get (drgnx-uitest-capture (make-temp-file "panel-tab-shot" t)) :root))
        (out (expand-file-name name (or (getenv "DRGNX_UI_EVIDENCE") temporary-file-directory))))
    (when (file-exists-p shot) (copy-file shot out t))))

(defun drgnx-ui-panel-tabs--point (tab)
  "Where TAB sits in the panel's tab row, as the frame's pixel (X . Y): found by asking Emacs what lies under a pixel
of the header line, across the window's width, so the font's own measure is never guessed."
  (let* ((w (drgnx-wb-area-window 'panel)) (edges (window-pixel-edges w))
         (y (+ (nth 1 edges) (/ (max 2 (window-header-line-height w)) 2))) (found nil) (x (nth 0 edges)))
    (while (and (not found) (< x (nth 2 edges)))
      (let* ((posn (posn-at-x-y x y (window-frame w))) (str (and posn (posn-string posn))))
        (when (and str (stringp (car str))
                   (equal (cdr-safe (get-text-property (cdr str) 'drgnx-tab (car str))) tab))
          (setq found (cons (+ x 6) y))))
      (setq x (+ x 4)))
    found))

(defun drgnx-ui-panel-tabs--row-tabs ()
  "The tabs in the panel's tab row now, in order."
  (let ((row (drgnx-area--tab-row 'panel)) tabs)
    (dotimes (k (length row))
      (when-let* ((spec (get-text-property k 'drgnx-tab row)))
        (unless (memq (cdr spec) tabs) (setq tabs (append tabs (list (cdr spec)))))))
    tabs))

(ert-deftest drgnx-ui-panel-tabs/every-tab-clicked-with-the-pointer-shows-something ()
  "Click each tab but Terminal in the panel's row: it becomes the shown tab and its buffer holds text.  Red first: the
Problems, Output, Results and Help tabs were blank buffers, the Debug Console's too."
  (skip-unless (drgnx-uitest-pointer-available-p))
  (let* ((root (drgnx-uitest-root-frame))
         (config (with-selected-frame root (current-window-configuration)))
         (saved (mapcar (lambda (p) (cons p (frame-parameter root p))) '(drgnx-wb-areas drgnx-wb-panel-px)))
         (main (get-buffer-create "*panel-tabs main*")) (seen nil))
    (unwind-protect
        (with-selected-frame root
          (delete-other-windows)
          (switch-to-buffer main)
          (drgnx-state-mode 1)
          (set-frame-parameter root 'drgnx-wb-areas nil)
          (set-frame-parameter root 'drgnx-wb-panel-px nil)
          (require 'drgnx-problems (expand-file-name "modules/lang/drgnx-problems" drgnx-ui-panel-tabs--repo) t)
          (drgnx-wb-area-show 'panel 'results)
          (drgnx-test-wait-presented)
          (dolist (tab (drgnx-ui-panel-tabs--row-tabs))
            (unless (eq tab 'terminal)
              ;; start from another tab, so the click has something to change
              (drgnx-wb-area-show 'panel (if (eq tab 'help) 'results 'help))
              (drgnx-test-wait-presented)
              (let ((at (drgnx-ui-panel-tabs--point tab)))
                (ert-info ((format "tab %s at %S" tab at))
                  (should at)
                  (should (drgnx-uitest-pointer-click (car at) (cdr at)
                                                      (lambda () (eq (drgnx-wb-area-tab 'panel) tab))))
                  (drgnx-test-wait-presented)
                  (drgnx-ui-panel-tabs--shot (format "panel-tab-%s-s%s.png" tab (or (getenv "DRGNX_UI_SCALE") "1")))
                  (let ((text (with-current-buffer (window-buffer (drgnx-wb-area-window 'panel))
                                (string-trim (buffer-substring-no-properties (point-min) (point-max))))))
                    (should-not (string-empty-p text))
                    (push (cons tab text) seen))))))
          (should (assq 'problems seen))
          (should (assq 'output seen))
          (should (assq 'help seen)))
      (ignore-errors (with-selected-frame root (drgnx-wb-area-hide 'panel)))
      (drgnx-state-mode -1)
      (while (read-event nil nil 0.1))
      ;; a pointer's press leaves Emacs's transient-map clearing on the hook; no keymap of ours is behind it
      (setq overriding-terminal-local-map nil)
      (drgnx-ui-panel-tabs--forget-transient-clears)
      (pcase-dolist (`(,p . ,v) saved) (set-frame-parameter root p v))
      (with-selected-frame root (set-window-configuration config))
      (kill-buffer main))))

(provide 'panel-tabs-gui-test)
;;; panel-tabs-gui-test.el ends here
