;;; agent-panel-frames-gui-test.el --- GUI tests: the agent panel's three windows in two frames, across tabs and sessions (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; A real hub and the mock agent (test/fixtures/panel-replay-fixture.el) with the panel open in the right area.  Each
;; frame's right area has its own three windows (header, transcript, composer) on one session's three buffers; a draft
;; typed in one composer shows in the other, and a scroll in one transcript leaves the other where it was.  A tab
;; switch and back puts the three windows and the transcript's place back; a second session's panel swaps all three
;; buffers; killing the panel's buffer kills its header and composer.  They need Nidhogg's Sjá and a hub built with test
;; hooks (DRGNX_RATATOSKR_BIN).

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-agent-panel-frames--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-agent-panel-frames--repo)))
(load (expand-file-name "test/fixtures/rows-demo-fixture" drgnx-ui-agent-panel-frames--repo) nil t)

(defvar drgnx-panel-replay-prefix)
(defvar drgnx-panel-replay-project)
(defvar drgnx-panel-replay--dir)
(defvar drgnx-panel-replay--mirror)
(defvar drgnx-view-patch)
(defvar drgnx-view-patch--buffers)
(defvar drgnx-view-patch--hooked)
(defvar drgnx-view-env--views)
(defvar drgnx-view-env--sent)
(defvar drgnx-view-env--glyphs)
(defvar drgnx-view-env--hooked)
(declare-function drgnx-panel-replay-up "panel-replay-fixture" (bin &optional old))
(declare-function drgnx-panel-replay-down "panel-replay-fixture" ())
(declare-function drgnx-rows-demo--bin "rows-demo-fixture" ())
(declare-function drgnx-view-env-teardown "drgnx-view-env" ())
(declare-function drgnx-view-patch-teardown "drgnx-view" ())
(declare-function drgnx-view-key-at "drgnx-view" (pos))
(declare-function drgnx-agent-panel--composer-of "drgnx-agent-panel-composer" (buffer))
(declare-function drgnx-agent-panel--header-of "drgnx-agent-panel-header" (buffer))
(declare-function drgnx-agent-panel-open "drgnx-agent-panel" (session))
(declare-function drgnx-agents-mirror-start "drgnx-agents-mirror" (profile cwd &optional task job))
(declare-function drgnx-agents-kill "drgnx-agents" (s))
(declare-function drgnx-agent-session-remote "drgnx-agents" (s))
(declare-function drgnx-pane-show "drgnx-panes" (kind &rest args))

(defmacro drgnx-ui-agent-panel-frames--with (panel prefix &rest body)
  "Run BODY with PANEL bound to the panel of a mock session whose first turn made PREFIX answers and reads, open in the
root frame's right area."
  (declare (indent 2))
  `(progn
     (skip-unless (and (display-graphic-p) (fboundp 'nidhogg-view-rows)))
     (load (expand-file-name "test/fixtures/panel-replay-fixture" drgnx-ui-agent-panel-frames--repo) nil t)
     (let* ((load-path (cons (expand-file-name "modules/tools" drgnx-ui-agent-panel-frames--repo) load-path))
            (drgnx-view-patch--buffers (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
            (drgnx-view-env--views (make-hash-table :test #'equal)) (drgnx-view-env--sent (make-hash-table :test #'equal))
            (drgnx-view-env--glyphs (make-hash-table :test #'equal)) (drgnx-view-env--hooked nil)
            (drgnx-panel-replay-prefix ,prefix) (,panel nil))
       (unwind-protect
           (save-window-excursion
             (delete-other-windows)
             (setq ,panel (drgnx-panel-replay-up (drgnx-rows-demo--bin)))
             (drgnx-ui-agent-panel-frames--settle)
             ,@body)
         (drgnx-panel-replay-down)
         (drgnx-view-env-teardown)
         (drgnx-view-patch-teardown)))))

(defun drgnx-ui-agent-panel-frames--area (&optional frame)
  "FRAME's right-area windows, top to bottom."
  (sort (seq-filter (lambda (w) (eq 'right (window-parameter w 'drgnx-role))) (window-list frame 'nomini))
        (lambda (a b) (< (nth 1 (window-pixel-edges a)) (nth 1 (window-pixel-edges b))))))

(defun drgnx-ui-agent-panel-frames--settle ()
  "Redisplay every frame and let the size-change functions and idle calls run, until no right-area window of any
frame moves (a header line's height is known after the first redisplay; at most 6 rounds)."
  (let ((edges nil) (n 0))
    (while (and (< n 6)
                (not (equal edges (setq edges (mapcar (lambda (f) (mapcar #'window-pixel-edges
                                                                          (drgnx-ui-agent-panel-frames--area f)))
                                                      (frame-list))))))
      (setq n (1+ n))
      (redisplay t)
      (drgnx-uitest-run nil)
      (drgnx-test-wait-presented))))

(defun drgnx-ui-agent-panel-frames--fitted (w)
  "Window W's body against its text's pixel height: (BODY TEXT)."
  (list (window-body-height w t)
        (cdr (window-text-pixel-size w (with-current-buffer (window-buffer w) (point-min))
                                     (with-current-buffer (window-buffer w) (point-max))))))

(defun drgnx-ui-agent-panel-frames--header (panel)
  "PANEL's header buffer, or nil while the panel has no header (`drgnx-agent-panel--header-of')."
  (and (fboundp 'drgnx-agent-panel--header-of) (drgnx-agent-panel--header-of panel)))

(defun drgnx-ui-agent-panel-frames--three (panel &optional frame what)
  "FRAME's right area as PANEL's three windows: (HEADER TRANSCRIPT COMPOSER).  Fails, naming WHAT, unless the area is
exactly the header above, PANEL in the tab's window and its composer below."
  (let* ((ws (drgnx-ui-agent-panel-frames--area frame))
         (want (list (drgnx-ui-agent-panel-frames--header panel) panel (drgnx-agent-panel--composer-of panel))))
    (unless (and (= 3 (length ws)) (equal (mapcar #'window-buffer ws) want)
                 (equal (mapcar (lambda (w) (window-parameter w 'drgnx-area-part)) ws) '(above nil below)))
      (ert-fail (list what :frame frame :want want :got (mapcar #'window-buffer ws)
                      :parts (mapcar (lambda (w) (window-parameter w 'drgnx-area-part)) ws))))
    ws))

(defun drgnx-ui-agent-panel-frames--two (panel &optional frame what)
  "FRAME's transcript and composer windows of PANEL (TRANSCRIPT COMPOSER), whatever the header: what does not wait
for the header window.  Fails, naming WHAT, when either is missing."
  (let* ((ws (drgnx-ui-agent-panel-frames--area frame))
         (tw (seq-find (lambda (w) (and (eq panel (window-buffer w)) (not (window-parameter w 'drgnx-area-part)))) ws))
         (cw (seq-find (lambda (w) (eq 'below (window-parameter w 'drgnx-area-part))) ws)))
    (unless (and tw cw (eq (window-buffer cw) (drgnx-agent-panel--composer-of panel)))
      (ert-fail (list what :frame frame :got (mapcar #'window-buffer ws))))
    (list tw cw)))

(ert-deftest drgnx-ui-agent-panel-frames/two-frames-have-their-own-windows-on-the-same-buffers ()
  "The panel shown in two frames: each right area has its own windows on the same buffers; a draft typed in one
composer shows in the other, both fitted to it; a scroll in one transcript leaves the other where it was."
  (drgnx-ui-agent-panel-frames--with panel 40
    (let* ((root (selected-frame)) (session (buffer-local-value 'drgnx-agent-panel--session panel))
           (frame (make-frame '((width . 120) (height . 40) (title . "drgnx-panel-frames")))))
      (unwind-protect
          (progn
            (with-selected-frame frame (delete-other-windows) (drgnx-agent-panel-open session))
            (select-frame-set-input-focus root)
            (drgnx-ui-agent-panel-frames--settle)
            (pcase-let ((`(,tw1 ,cw1) (drgnx-ui-agent-panel-frames--two panel root :root))
                        (`(,tw2 ,cw2) (drgnx-ui-agent-panel-frames--two panel frame :second)))
              (should-not (eq tw1 tw2))
              (should-not (eq cw1 cw2))
              ;; a draft typed in the root frame's composer: the second frame's shows it, and both are fitted to it
              (select-window cw1)
              (with-current-buffer (window-buffer cw1) (goto-char (point-min)))
              (drgnx-uitest-run (drgnx-uitest-type-events "first line"))
              (should (string-prefix-p "first line" (with-current-buffer (window-buffer cw2) (buffer-string))))
              (with-current-buffer (window-buffer cw1) (goto-char (point-min)) (insert "a\nb\nc\n"))
              (drgnx-ui-agent-panel-frames--settle)
              (should (apply #'= (drgnx-ui-agent-panel-frames--fitted cw1)))
              (should (apply #'= (drgnx-ui-agent-panel-frames--fitted cw2)))
              (should (= (window-body-height cw1 t) (window-body-height cw2 t)))
              ;; a scroll in the root frame's transcript: the second frame's stays on its row
              (let ((start2 (window-start tw2)) (key2 (with-current-buffer panel (drgnx-view-key-at (window-start tw2)))))
                (with-selected-window tw1
                  (goto-char (point-max))
                  (redisplay t)
                  (scroll-down (/ (window-body-height) 2)))
                (drgnx-ui-agent-panel-frames--settle)
                (should-not (= (window-start tw1) start2))
                (should (= start2 (window-start tw2)))
                (should (equal key2 (with-current-buffer panel (drgnx-view-key-at (window-start tw2)))))))
            ;; the header: each frame has the three windows
            (drgnx-ui-agent-panel-frames--three panel root :root-three)
            (drgnx-ui-agent-panel-frames--three panel frame :second-three))
        (delete-frame frame)))))

(ert-deftest drgnx-ui-agent-panel-frames/a-tab-switch-and-back-restores-the-windows-and-the-place ()
  "The right area switched to another tab and back: the three windows again, the transcript on the row it was on;
then the panel's buffer killed: its header and composer go with it, and no companion window is left."
  (drgnx-ui-agent-panel-frames--with panel 40
    (let ((other (get-buffer-create "*drgnx panel-frames other*")))
      (unwind-protect
          (progn
            (drgnx-wb-define-tab 'right 'panel-frames-other :title "Other")
            (pcase-let ((`(,tw ,_cw) (drgnx-ui-agent-panel-frames--two panel nil :before)))
              (with-selected-window tw
                (goto-char (point-max))
                (redisplay t)
                (scroll-down (/ (window-body-height) 2))
                (move-to-window-line 0))
              (drgnx-ui-agent-panel-frames--settle)
              (let ((key (with-current-buffer panel (drgnx-view-key-at (window-start tw))))
                    (point (window-point tw)))
                (should key)
                (drgnx-wb-area-show 'right 'panel-frames-other other)
                (drgnx-ui-agent-panel-frames--settle)
                (should (equal (list other) (mapcar #'window-buffer (drgnx-ui-agent-panel-frames--area))))
                (drgnx-pane-show 'agent-panel)
                (drgnx-ui-agent-panel-frames--settle)
                (pcase-let ((`(,tw2 ,_) (drgnx-ui-agent-panel-frames--two panel nil :back)))
                  (should (equal key (with-current-buffer panel (drgnx-view-key-at (window-start tw2)))))
                  (should (= point (window-point tw2))))))
            (drgnx-ui-agent-panel-frames--three panel nil :back-three)
            ;; killing the panel's buffer takes its header and composer
            (let ((header (drgnx-ui-agent-panel-frames--header panel)) (composer (drgnx-agent-panel--composer-of panel)))
              (kill-buffer panel)
              (drgnx-ui-agent-panel-frames--settle)
              (should-not (buffer-live-p composer))
              (should-not (buffer-live-p header))
              (should-not (seq-some (lambda (w) (window-parameter w 'drgnx-area-part))
                                    (drgnx-ui-agent-panel-frames--area)))))
        (drgnx-wb-undefine-tab 'right 'panel-frames-other)
        (kill-buffer other)))))

(ert-deftest drgnx-ui-agent-panel-frames/two-sessions-swap-all-three-buffers ()
  "Two sessions' panels: the area shows one at a time, and opening the other swaps the transcript, the header and the
composer together."
  (drgnx-ui-agent-panel-frames--with panel 3
    (let* ((s1 (buffer-local-value 'drgnx-agent-panel--session panel))
           (mirror (drgnx-agents-mirror-start "replay" (expand-file-name "project" drgnx-panel-replay--dir)))
           (panel2 nil))
      (unwind-protect
          (progn
            (should mirror)
            (setq panel2 (drgnx-agent-panel-open (drgnx-agent-session-remote mirror)))
            (drgnx-ui-agent-panel-frames--settle)
            (should-not (eq panel panel2))
            (drgnx-ui-agent-panel-frames--two panel2 nil :second-session)
            (should-not (memq panel (mapcar #'window-buffer (drgnx-ui-agent-panel-frames--area))))
            (should-not (memq (drgnx-agent-panel--composer-of panel) (mapcar #'window-buffer (drgnx-ui-agent-panel-frames--area))))
            (drgnx-agent-panel-open s1)
            (drgnx-ui-agent-panel-frames--settle)
            (drgnx-ui-agent-panel-frames--two panel nil :first-again)
            (should-not (memq (drgnx-agent-panel--composer-of panel2) (mapcar #'window-buffer (drgnx-ui-agent-panel-frames--area))))
            ;; the header: three windows each time
            (drgnx-ui-agent-panel-frames--three panel nil :first-three)
            (drgnx-agent-panel-open (drgnx-agent-session-remote mirror))
            (drgnx-ui-agent-panel-frames--settle)
            (drgnx-ui-agent-panel-frames--three panel2 nil :second-three))
        (ignore-errors (drgnx-agents-kill mirror))
        (when (buffer-live-p panel2) (kill-buffer panel2))))))

(provide 'agent-panel-frames-gui-test)
;;; agent-panel-frames-gui-test.el ends here
