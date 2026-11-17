;;; work-selection-frames-gui-test.el --- GUI test: what needs you is one count in every frame (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; Two frames, each with the drawn title row; one mock agent asks permission (its hub call is the outside service:
;; here the attention event the hub sends).  Both pills say so.  The ask is settled while frame A is the selected
;; frame; on the next redisplay frame B's pill is gone too, with no command run in B.  The strip of the Work map
;; draws from the same count (the hub's `needs-you' list follows the hub's attention event).

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-work-selection-frames--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-work-selection-frames--repo)))
(require 'drgnx)
(require 'drgnx-state)
(require 'drgnx-agents)
(require 'drgnx-wb)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-work-selection-frames--repo) nil t)
(dolist (m '("ui/drgnx-face" "ui/drgnx-statusbar" "ui/drgnx-menubar" "ui/drgnx-topline"))
  (load (expand-file-name (concat "modules/" m) drgnx-ui-work-selection-frames--repo) nil t))

(defvar drgnx-face-title-bar)
(declare-function drgnx-topline--line "drgnx-topline" ())
(declare-function drgnx-topline-setup "drgnx-topline" ())
(declare-function drgnx-topline--off "drgnx-topline" ())
(declare-function drgnx-face--apply-title "drgnx-face" (frame))
(declare-function drgnx-agents--take-attention "drgnx-agents" (data))

(defun drgnx-ui-work-selection-frames--pill-p (frame)
  "Whether FRAME's title row, drawn now, has the needs-you pill."
  (with-selected-frame frame
    (drgnx-memo-forget 'topline)
    (and (assq 'drgnx-topline-attention (drgnx-topline--line)) t)))

(ert-deftest work-selection-frames/settle-in-one-frame-clears-both ()
  "An ask waiting on you shows in both frames' pills; settling it with frame A selected clears frame B's pill on the
next redisplay."
  (skip-unless (display-graphic-p))
  (let* ((a (drgnx-uitest-root-frame)) (b nil) (was drgnx-face-title-bar) (sessions drgnx-agents--sessions))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-face--drawn-wanted-p) (lambda (_f) (eq drgnx-face-title-bar 'drgnx))))
          (setq b (make-frame '((width . 80) (height . 20) (title . "drgnx-work-selection-b"))))
          (setq drgnx-face-title-bar 'drgnx)
          (dolist (f (list a b)) (drgnx-face--apply-title f))
          (drgnx-topline-setup)
          (push (drgnx-agents--make :name "fix-explorer" :id "s1" :remote "r1") drgnx-agents--sessions)
          (drgnx-agents--take-attention
           (list :at_work 1 :items (vector (list :session "s1" :id 7 :text "claude · fix-explorer wants to run a command"))))
          (dolist (f (list a b)) (should (drgnx-ui-work-selection-frames--pill-p f)))
          ;; settled with A selected
          (select-frame-set-input-focus a)
          (drgnx-agents--take-attention (list :at_work 0 :items (vector)))
          (redisplay t)
          (should (= 0 (drgnx-needs-you-count)))
          (should-not (drgnx-ui-work-selection-frames--pill-p a))
          (should-not (drgnx-ui-work-selection-frames--pill-p b)))
      (when (frame-live-p b) (delete-frame b t))
      (drgnx-topline--off)
      (setq drgnx-agents--sessions sessions)
      (drgnx-agents--take-attention (list :at_work 0 :items (vector)))
      (setq drgnx-face-title-bar was)
      (cl-letf (((symbol-function 'drgnx-face--drawn-wanted-p) #'ignore)) (drgnx-face--apply-title a)))))

(provide 'work-selection-frames-gui-test)
;;; work-selection-frames-gui-test.el ends here
