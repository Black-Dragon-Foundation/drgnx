;;; agent-panel-composer-gui-test.el --- GUI tests: the agent panel's composer under the transcript (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; A real hub and a mock agent (test/fixtures/panel-replay-fixture.el, a short turn) and the panel open in the right
;; area.  Run at each scale (s1, s2): the composer is the area's window below the transcript, fitted to its lines; a
;; five-line draft grows it, a long one stops at 45% of the area; a click in the transcript and the profile's "focus
;; composer" key put point at the end of the composer's message.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-agent-panel-composer--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-agent-panel-composer--repo)))
(load (expand-file-name "test/fixtures/rows-demo-fixture" drgnx-ui-agent-panel-composer--repo) nil t)
(require 'drgnx-keys)

(defvar drgnx-panel-replay-prefix)
(defvar drgnx-agent-panel-mode-map)
(defvar drgnx-view)
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
(declare-function drgnx-view-row-start "drgnx-view" (view key))
(declare-function drgnx-agent-panel--composer-of "drgnx-agent-panel-composer" (buffer))
(declare-function drgnx-agent-panel-composer--field-end "drgnx-agent-panel-composer" ())
(declare-function drgnx-agent-panel-compose "drgnx-agent-panel-composer" ())
(declare-function drgnx-keys-use "drgnx-keys" (layers &optional save))
(declare-function drgnx-keys--restore "drgnx-keys" ())

(defun drgnx-ui-agent-panel-composer--settle (area)
  "Let redisplay, the size-change functions and the store's idle calls run until AREA's companions stop moving (a
header line's height is known after the first redisplay; at most 5 rounds)."
  (let ((edges nil) (n 0))
    (while (and (< n 5)
                (not (equal edges (setq edges (mapcar #'window-pixel-edges
                                                      (seq-filter (lambda (w) (and (eq area (window-parameter w 'drgnx-role))
                                                                                   (window-parameter w 'drgnx-area-part)))
                                                                  (window-list nil 'nomini)))))))
      (setq n (1+ n))
      (drgnx-uitest-run (drgnx-uitest-key-events "C-l"))
      (drgnx-test-wait-presented))))

(defun drgnx-ui-agent-panel-composer--fitted (w)
  "Window W's body against its text's pixel height: (BODY TEXT)."
  (list (window-body-height w t)
        (cdr (window-text-pixel-size w (with-current-buffer (window-buffer w) (point-min))
                                     (with-current-buffer (window-buffer w) (point-max))))))

(ert-deftest drgnx-ui-agent-panel-composer/below-the-transcript-fitted-and-focused-by-its-key ()
  (skip-unless (display-graphic-p))
  (load (expand-file-name "test/fixtures/panel-replay-fixture" drgnx-ui-agent-panel-composer--repo) nil t)
  (let* ((load-path (cons (expand-file-name "modules/tools" drgnx-ui-agent-panel-composer--repo) load-path))
         (drgnx-view-patch--buffers (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
         (drgnx-view-env--views (make-hash-table :test #'equal)) (drgnx-view-env--sent (make-hash-table :test #'equal))
         (drgnx-view-env--glyphs (make-hash-table :test #'equal)) (drgnx-view-env--hooked nil)
         (drgnx-panel-replay-prefix 3) (panel nil))
    (unwind-protect
        (save-window-excursion
          (setq panel (drgnx-panel-replay-up (drgnx-rows-demo--bin)))
          (let* ((tw (get-buffer-window panel)) (area (window-parameter tw 'drgnx-role))
                 (comp (drgnx-agent-panel--composer-of panel))
                 (cw (progn (drgnx-ui-agent-panel-composer--settle area) (get-buffer-window comp))))
            ;; the composer is the area's window right below the transcript, its width
            (should (window-live-p cw))
            (should (eq 'below (window-parameter cw 'drgnx-area-part)))
            (should (eq area (window-parameter cw 'drgnx-role)))
            (should (= (nth 3 (window-pixel-edges tw)) (nth 1 (window-pixel-edges cw))))
            (should (= (window-pixel-width tw) (window-pixel-width cw)))
            ;; fitted to its lines (the empty message and the bar), to the pixel
            (should (apply #'= (drgnx-ui-agent-panel-composer--fitted cw)))
            ;; a five-line draft grows it, still fitted
            (let ((was (window-body-height cw t)))
              (with-current-buffer comp (goto-char (point-min)) (insert "one\ntwo\nthree\nfour\nfive"))
              (drgnx-ui-agent-panel-composer--settle area)
              (should (> (window-body-height cw t) was))
              (should (apply #'= (drgnx-ui-agent-panel-composer--fitted cw))))
            ;; a draft longer than the area stops at 45% of it
            (with-current-buffer comp
              (goto-char (point-min))
              (insert (mapconcat (lambda (i) (format "line %d" i)) (number-sequence 1 80) "\n") "\n"))
            (drgnx-ui-agent-panel-composer--settle area)
            (let ((total (+ (window-pixel-height tw) (window-pixel-height cw))))
              (should (<= (window-pixel-height cw) (* 0.45 total)))
              (should (> (window-pixel-height cw) (* 0.3 total))))
            (with-current-buffer comp (delete-region (point-min) (drgnx-agent-panel-composer--field-end)) (insert "half"))
            (drgnx-ui-agent-panel-composer--settle area)
            (should (apply #'= (drgnx-ui-agent-panel-composer--fitted cw)))
            ;; in each profile without a modal engine: a click in the transcript, then the profile's key: point at the
            ;; end of the message
            (dolist (profile '(vscode emacs))
              (drgnx-keys-use `((,profile app editing window)))
              (let* ((key (where-is-internal #'drgnx-agent-panel-compose (list drgnx-agent-panel-mode-map) t))
                     (pos (window-start tw))   ; a row of the transcript (Sjá's, the hub's) that the window shows
                     (posn (posn-at-point pos tw)))
                (should (equal (list profile "s") (list profile (and key (key-description key)))))
                (should posn)
                (select-window (frame-first-window))
                (with-current-buffer comp (goto-char (point-min)))
                (drgnx-uitest-run (append (drgnx-uitest-click-events posn) (listify-key-sequence key)))
                (should (equal (list profile cw) (list profile (selected-window))))
                (should (eq comp (window-buffer (selected-window))))
                (should (= (window-point cw) (with-current-buffer comp (drgnx-agent-panel-composer--field-end))))
                (should (equal "half" (with-current-buffer comp
                                        (buffer-substring-no-properties (point-min) (window-point cw)))))))))
      (drgnx-keys--restore)
      (drgnx-panel-replay-down)
      (drgnx-view-env-teardown)
      (drgnx-view-patch-teardown))))

(provide 'agent-panel-composer-gui-test)
;;; agent-panel-composer-gui-test.el ends here
