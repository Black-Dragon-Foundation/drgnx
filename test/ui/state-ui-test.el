;;; state-ui-test.el --- GUI tests: the workbench state store moves nothing; minibuffer-only frames (run by `drgnx test --ui') -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-ui-state-test--repo                          ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-ui-state-test--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-ui-state-test--repo))
(require 'drgnx-state)

(defvar drgnx-ui-state-test--seen nil "Events a `now' subscriber got, newest first.")

(defconst drgnx-ui-state-test--events
  '(frame-added frame-kind frame-resized windows-changed groups-changed pane-hidden pane-shown pane-resized
                selected-changed editor-changed))

(dolist (event drgnx-ui-state-test--events)
  (let ((event event))
    (defalias (intern (format "drgnx-ui-state-test--on-%s" event))
      (lambda (_data) (push event drgnx-ui-state-test--seen)))))

(defun drgnx-ui-state-test--popup ()
  "A timer shows a popup lane at the bottom (the timer's own split, not the store's)."
  (display-buffer-in-side-window (get-buffer-create "*drgnx-state-popup*")
                                 '((side . bottom) (slot . 0) (window-height . 6)
                                   (window-parameters . ((drgnx-popup . (:borrowed nil)))))))

(defun drgnx-ui-state-test--store-violations (since)
  "The jank guard's entries after the first SINCE that the store (a `drgnx-state-' function) caused."
  (seq-filter (lambda (v) (string-match-p "\\_<drgnx-state-" (format "%s" (plist-get v :timer))))
              (butlast drgnx-jank-guard-log since)))

(ert-deftest drgnx-state-ui/the-observer-never-moves-a-window ()
  ;; The store on, `now' subscribers on every event: splits, `C-x o', a popup from a timer, a frame resize.
  (let* ((root (drgnx-uitest-root-frame))
         (config (with-selected-frame root (current-window-configuration)))
         (size (list (frame-pixel-width root) (frame-pixel-height root)))
         (since (length drgnx-jank-guard-log)))
    (setq drgnx-ui-state-test--seen nil)
    (dolist (event drgnx-ui-state-test--events)
      (drgnx-state-subscribe event (intern (format "drgnx-ui-state-test--on-%s" event)) :lane 'now))
    (unwind-protect
        (progn
          (drgnx-state-mode 1)
          (with-selected-frame root (delete-other-windows))
          (let ((r (drgnx-uitest-run (drgnx-uitest-key-events "C-x 3 C-x 2 C-x o C-x o C-x o"))))
            (should (eq t (plist-get r :settled))))
          (run-with-timer 0.05 nil #'drgnx-ui-state-test--popup)
          (drgnx-uitest-run (drgnx-uitest-key-events "C-n"))
          (should (seq-find (lambda (w) (window-parameter w 'drgnx-popup)) (window-list root 'nomini)))
          (set-frame-size root (- (car size) 120) (- (cadr size) 80) t)
          (drgnx-uitest-run (drgnx-uitest-key-events "C-x o"))
          (dolist (e '(windows-changed groups-changed selected-changed editor-changed pane-resized))
            (should (memq e drgnx-ui-state-test--seen)))
          (should-not (drgnx-ui-state-test--store-violations since)))
      (drgnx-state-mode -1)
      (dolist (event drgnx-ui-state-test--events)
        (drgnx-state-unsubscribe event (intern (format "drgnx-ui-state-test--on-%s" event))))
      (set-frame-size root (car size) (cadr size) t)
      (with-selected-frame root (set-window-configuration config))
      (when (get-buffer "*drgnx-state-popup*") (kill-buffer "*drgnx-state-popup*")))))

(ert-deftest drgnx-state-ui/a-minibuffer-only-frame-is-no-workbench-frame ()
  ;; Batch Emacs makes no second frame; the unit test only stubs `frame-root-window'.
  (let ((mini (make-frame '((minibuffer . only) (visibility . nil)))) (borrower nil))
    (unwind-protect
        (progn
          (should (eq 'other (drgnx-state-frame-kind mini)))
          (should-not (drgnx-state-workbench-frame-p mini))
          (should-not (drgnx-state-sync mini))
          (should-not (gethash mini drgnx-state--frames))
          ;; a frame that borrows that minibuffer is a workbench frame: its minibuffer window is not its root
          (setq borrower (make-frame `((minibuffer . ,(minibuffer-window mini)) (visibility . nil))))
          (should (eq (minibuffer-window mini) (minibuffer-window borrower)))
          (should (eq 'gui (drgnx-state-frame-kind borrower)))
          (should (drgnx-state-workbench-frame-p borrower)))
      (when (frame-live-p borrower) (delete-frame borrower t))
      (when (frame-live-p mini) (delete-frame mini t)))))

;;; state-ui-test.el ends here
