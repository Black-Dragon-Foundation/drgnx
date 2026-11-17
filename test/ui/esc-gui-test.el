;;; esc-gui-test.el --- GUI test: Esc Esc opens Switch Tile's cards (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; A frame of its own with three tiles; Esc where it cancels, then Esc again, read as the command loop reads keys
;; (through `input-decode-map' and the emulation maps): the switcher opens and every tile has its card.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-esc--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-esc--repo)))
(defvar drgnx-dir)
(setq drgnx-dir (or (bound-and-true-p drgnx-dir) drgnx-ui-esc--repo))
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-ui-esc--repo) nil t)
(require 'drgnx-groups)
(require 'drgnx-switcher)
(require 'drgnx-esc)

(defvar drgnx-ui-esc--ran nil)
(defun drgnx-ui-esc--cancel () "A cancel." (interactive) (push 'cancel drgnx-ui-esc--ran))

(defun drgnx-ui-esc--run-keys (n)
  "Read N key sequences and run their commands, with the hooks around them, as the command loop does."
  (dotimes (_ n)
    (let* ((keys (read-key-sequence-vector nil)) (cmd (key-binding keys t)))
      (setq this-command cmd last-command-event (aref keys (1- (length keys))))
      (run-hooks 'pre-command-hook)
      (when (commandp cmd) (call-interactively cmd nil keys))
      (run-hooks 'post-command-hook)
      (setq last-command this-command))))

(ert-deftest drgnx-ui-esc/double-tap-opens-cards ()
  (skip-unless (display-graphic-p))
  (let ((frames (frame-list)) (selected (selected-frame))
        (frame (make-frame '((width . 160) (height . 50))))
        (drgnx-ui-esc--ran nil)
        (drgnx-esc-cancel-commands (cons 'drgnx-ui-esc--cancel drgnx-esc-cancel-commands)))
    (unwind-protect
        (with-selected-frame frame
          (drgnx-grid-test--with
            (drgnx-test-wait (lambda () (redisplay t) (frame-visible-p frame)) :secs 10 :what "the frame mapped")
            (drgnx-groups-split-right)
            (drgnx-groups-split-down)
            (redisplay t)
            (drgnx-esc-mode 1)
            (unwind-protect
                (with-temp-buffer
                  (set-window-buffer (selected-window) (current-buffer))
                  (use-local-map (list 'keymap (cons 'escape #'drgnx-ui-esc--cancel)))
                  (setq unread-command-events (list 'escape 'escape))
                  (drgnx-ui-esc--run-keys 2)
                  (should (equal drgnx-ui-esc--ran '(cancel)))
                  (should (drgnx-switcher-open-p))
                  (let ((mine (seq-filter (lambda (it) (eq (plist-get it :frame) frame))
                                          (plist-get drgnx-switcher--state :items))))
                    (should (= 3 (length mine)))
                    (drgnx-test-wait (lambda () (redisplay t)
                                       (= 3 (seq-count (lambda (e) (and (frame-visible-p (car e)) (eq (frame-parent (car e)) frame)))
                                                       drgnx-switcher--pool)))
                                     :secs 10 :what "a card on each tile")))
              (drgnx-switcher-close)
              (drgnx-esc-mode -1))))
      (drgnx-switcher-delete-pool)
      (dolist (f (frame-list)) (unless (memq f frames) (delete-frame f t)))
      (when (frame-live-p selected) (select-frame selected)))))

(provide 'esc-gui-test)
;;; esc-gui-test.el ends here
