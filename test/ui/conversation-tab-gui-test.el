;;; conversation-tab-gui-test.el --- GUI tests: the agent conversation as an editor tab (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; Flow Task 23.  A real hub and a mock agent (test/fixtures/panel-replay-fixture.el, a short turn) and the panel's
;; conversation shown as an editor tab: one tile beside the editor tile (the header above, the transcript, the
;; composer below), not the right dock.  The composer carries a Steer | Ask control (Ask sends `agents/send' with
;; `intent: "ask"'), the note waiting for the agent's next step above its field, its context as removable chips, and
;; a Stop button of its own that Send never calls.  Run at each scale (s1, s2).

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-conversation-tab--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-conversation-tab--repo)))
(load (expand-file-name "test/fixtures/rows-demo-fixture" drgnx-ui-conversation-tab--repo) nil t)

(defvar drgnx-panel-replay-prefix)
(defvar drgnx-view-patch--buffers)
(defvar drgnx-view-patch--hooked)
(defvar drgnx-view-env--views)
(defvar drgnx-view-env--sent)
(defvar drgnx-view-env--glyphs)
(defvar drgnx-view-env--hooked)
(defvar drgnx-agent-panel--session)
(defvar drgnx-agent-panel--snap)
(defvar drgnx-agent-panel--intent)
(defvar drgnx-agent-panel--context)
(defvar drgnx-agent-companion--head)
(defvar drgnx-grid-mode)
(declare-function drgnx-panel-replay-up "panel-replay-fixture" (bin &optional old))
(declare-function drgnx-panel-replay-down "panel-replay-fixture" ())
(declare-function drgnx-rows-demo--bin "rows-demo-fixture" ())
(declare-function drgnx-view-env-teardown "drgnx-view-env" ())
(declare-function drgnx-view-patch-teardown "drgnx-view" ())
(declare-function drgnx-agent-panel-open-tab "drgnx-agent-panel" (session))
(declare-function drgnx-agent-panel--composer-of "drgnx-agent-panel-composer" (buffer))
(declare-function drgnx-agent-panel-composer-redraw "drgnx-agent-panel-composer" ())
(declare-function drgnx-agent-panel-composer--field-end "drgnx-agent-panel-composer" ())
(declare-function drgnx-agent-panel-composer--refresh "drgnx-agent-panel-composer" ())
(declare-function drgnx-agent-panel-context-add "drgnx-agent-panel-composer" (item))
(declare-function drgnx-agent-panel-context-remove "drgnx-agent-panel-composer" (item))
(declare-function drgnx-agent-panel-intent-ask "drgnx-agent-panel-composer" ())
(declare-function drgnx-agent-panel-send "drgnx-agent-panel-composer" ())
(declare-function drgnx-agent-panel--companions "drgnx-agent-panel" (buffer))
(declare-function drgnx-agent-panel--companion-take "drgnx-agent-panel-composer" ())
(declare-function drgnx-agent-panel--companion-give "drgnx-agent-panel-composer" ())
(declare-function drgnx-grid-tool-tile-p "drgnx-grid" (window))
(declare-function drgnx-grid-editor-tile-p "drgnx-grid" (window))
(declare-function drgnx-grid--part-of "drgnx-grid" (window which))
(declare-function drgnx-grid-tiles "drgnx-grid" (&optional frame filter))

(defun drgnx-ui-conversation-tab--grid-off (was)
  "Give the grid back as it was: off again unless WAS, with its frame and window parameters cleared."
  (unless was (drgnx-grid-mode -1))
  (dolist (f (frame-list))
    (dolist (p '(drgnx-grid-memory drgnx-grid-next-id drgnx-grid--good drgnx-grid--docks))
      (set-frame-parameter f p nil))
    (dolist (w (window-list f 'nomini))
      (dolist (p '(drgnx-tile-id drgnx-role drgnx-pane-stack drgnx-tile-dock no-delete-other-windows delete-window))
        (set-window-parameter w p nil)))))

(defmacro drgnx-ui-conversation-tab--with (vars &rest body)
  "Run BODY with VARS, (PANEL SESSION), bound for a mock session's panel open in the right dock, the grid on."
  (declare (indent 1))
  (pcase-let ((`(,panel ,session) vars))
    `(progn
       (skip-unless (and (display-graphic-p) (fboundp 'nidhogg-view-rows)))
       (load (expand-file-name "test/fixtures/panel-replay-fixture" drgnx-ui-conversation-tab--repo) nil t)
       (let* ((load-path (cons (expand-file-name "modules/tools" drgnx-ui-conversation-tab--repo) load-path))
              (drgnx-view-patch--buffers (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
              (drgnx-view-env--views (make-hash-table :test #'equal)) (drgnx-view-env--sent (make-hash-table :test #'equal))
              (drgnx-view-env--glyphs (make-hash-table :test #'equal)) (drgnx-view-env--hooked nil)
              (drgnx-panel-replay-prefix 3) (,panel nil) (grid-was nil))
         (unwind-protect
             (save-window-excursion
               (setq ,panel (drgnx-panel-replay-up (drgnx-rows-demo--bin)))
               (require 'drgnx-grid)
               (setq grid-was drgnx-grid-mode)
               (unless drgnx-grid-mode (drgnx-grid-mode 1))
               (let ((,session (buffer-local-value 'drgnx-agent-panel--session ,panel)))
                 ,@body))
           (drgnx-ui-conversation-tab--grid-off grid-was)
           (drgnx-panel-replay-down)
           (drgnx-view-env-teardown)
           (drgnx-view-patch-teardown))))))

(defun drgnx-ui-conversation-tab--in (comp command)
  "Run COMMAND in the composer COMP as a command there runs: the panel's state copied in before it and given back after
it (the companion's pre- and post-command hooks)."
  (with-current-buffer comp
    (drgnx-agent-panel--companion-take)
    (unwind-protect (funcall command) (drgnx-agent-panel--companion-give))))

(defun drgnx-ui-conversation-tab--settle ()
  "Let redisplay and the size-change functions run."
  (dotimes (_ 3) (drgnx-uitest-run (drgnx-uitest-key-events "C-l")) (drgnx-test-wait-presented)))

(defun drgnx-ui-conversation-tab--bar-regions (comp)
  "COMP's bar commands as an alist (COMMAND . (BEG . END)) of the text each one's button covers."
  (with-current-buffer comp
    (let ((pos (point-min)) out)
      (while (< pos (point-max))
        (let* ((cmd (get-text-property pos 'drgnx-agent-composer-command))
               (end (or (next-single-property-change pos 'drgnx-agent-composer-command nil (point-max)) (point-max))))
          (when cmd (push (cons cmd (cons pos end)) out))
          (setq pos end)))
      (nreverse out))))

(ert-deftest drgnx-ui-conversation-tab/opens-from-a-task-as-an-editor-tab ()
  "`drgnx-agent-panel-open-tab' shows the conversation in a tile beside the editor tile, not in the right dock."
  (drgnx-ui-conversation-tab--with (panel session)
    (drgnx-agent-panel-open-tab session)
    (drgnx-ui-conversation-tab--settle)
    (let* ((w (get-buffer-window panel)) (editor (car (drgnx-grid-tiles nil 'editor))))
      (should (window-live-p w))
      (should (drgnx-grid-tool-tile-p w))
      (should (equal (cons 'agent-panel session) (car (window-parameter w 'drgnx-pane-stack))))
      (should-not (window-parameter w 'drgnx-tile-dock))
      (should (window-live-p editor))
      (should (>= (nth 0 (window-pixel-edges w)) (nth 2 (window-pixel-edges editor))))
      ;; one window shows the transcript: the dock gave it up
      (should (= 1 (length (get-buffer-window-list panel nil t)))))))

(ert-deftest drgnx-ui-conversation-tab/three-windows-in-the-tab ()
  "The tab is the header above, the transcript, the composer below: three windows of one tile."
  (drgnx-ui-conversation-tab--with (panel session)
    (drgnx-agent-panel-open-tab session)
    (drgnx-ui-conversation-tab--settle)
    (let* ((w (get-buffer-window panel)) (above (drgnx-grid--part-of w 'above)) (below (drgnx-grid--part-of w 'below))
           (comp (drgnx-agent-panel--composer-of panel)))
      (should (window-live-p above))
      (should (window-live-p below))
      (should (eq comp (window-buffer below)))
      (should (eq (nth 0 (drgnx-agent-panel--companions panel)) (window-buffer above)))
      (should (< (nth 3 (window-pixel-edges above)) (nth 3 (window-pixel-edges w))))
      (should (<= (nth 3 (window-pixel-edges w)) (nth 1 (window-pixel-edges below)))))))

(ert-deftest drgnx-ui-conversation-tab/queued-message-shows-above-the-field ()
  "The note waiting for the agent's next step shows above the composer's field, as \"↳ Queued for its next step: …\"."
  (drgnx-ui-conversation-tab--with (panel session)
    (drgnx-agent-panel-open-tab session)
    (let ((comp (drgnx-agent-panel--composer-of panel)))
      (with-current-buffer panel
        (setq drgnx-agent-panel--snap (plist-put (copy-sequence drgnx-agent-panel--snap) :queue (vector "fix the tests"))))
      (drgnx-agent-panel-composer-redraw)
      (drgnx-ui-conversation-tab--settle)
      ;; the composer's window holds all its text, the note, the field and the bar: no line cut off
      (let ((cw (get-buffer-window comp)))
        (should (window-live-p cw))
        (with-current-buffer comp
          ;; the note and the chips (none here) above the field, the field's line and the bar's
          (should (>= (window-body-height cw t)
                      (* (window-default-line-height cw)
                         (+ (seq-count (lambda (c) (eq c ?\n)) (overlay-get drgnx-agent-companion--head 'before-string))
                            (count-lines (point-min) (point-max))))))))
      (with-current-buffer comp
        (let ((head (overlay-get drgnx-agent-companion--head 'before-string)))
          (should (stringp head))
          (should (string-match-p "↳ Queued for its next step: fix the tests" head))
          (should (= (point-min) (overlay-start drgnx-agent-companion--head)))))
      ;; nothing queued: nothing above the field
      (with-current-buffer panel
        (setq drgnx-agent-panel--snap (plist-put (copy-sequence drgnx-agent-panel--snap) :queue (vector))))
      (drgnx-agent-panel-composer-redraw)
      (with-current-buffer comp
        (should-not (overlay-get drgnx-agent-companion--head 'before-string))))))

(ert-deftest drgnx-ui-conversation-tab/stop-is-separate-from-send ()
  "Stop is a button of its own, apart from Send, and Send never calls it: a message sent asks for `agents/send' only."
  (drgnx-ui-conversation-tab--with (panel session)
    (drgnx-agent-panel-open-tab session)
    (let* ((comp (drgnx-agent-panel--composer-of panel))
           (regions (drgnx-ui-conversation-tab--bar-regions comp))
           (stop (alist-get 'drgnx-agent-panel-stop regions)) (send (alist-get 'drgnx-agent-panel-send regions))
           (calls nil))
      (should stop)
      (should send)
      (should (< (cdr stop) (car send)))
      (should (string-match-p "Stop" (with-current-buffer comp (buffer-substring-no-properties (car stop) (cdr stop)))))
      (cl-letf (((symbol-function 'drgnx-agent-panel--ask) (lambda (method params &rest _) (push (cons method params) calls))))
        (with-current-buffer comp (goto-char (point-min)) (insert "a draft"))
        (with-current-buffer comp (drgnx-agent-panel-send)))
      (should (equal '("agents/send") (mapcar #'car calls)))
      (should-not (plist-member (cdr (car calls)) :intent)))))

(ert-deftest drgnx-ui-conversation-tab/ask-sends-the-ask-intent-once ()
  "Ask sends `agents/send' with `intent: \"ask\"' and the control goes back to Steer, the default."
  (drgnx-ui-conversation-tab--with (panel session)
    (drgnx-agent-panel-open-tab session)
    (let ((comp (drgnx-agent-panel--composer-of panel)) (calls nil))
      (drgnx-ui-conversation-tab--in comp #'drgnx-agent-panel-intent-ask)
      (should (eq 'ask (buffer-local-value 'drgnx-agent-panel--intent panel)))
      (cl-letf (((symbol-function 'drgnx-agent-panel--ask) (lambda (method params &rest _) (push (cons method params) calls))))
        (with-current-buffer comp (goto-char (point-min)) (insert "why this file?"))
        (drgnx-ui-conversation-tab--in comp #'drgnx-agent-panel-send))
      (should (equal "ask" (plist-get (cdr (car calls)) :intent)))
      (should (equal "why this file?" (plist-get (cdr (car calls)) :text)))
      (should (eq 'steer (buffer-local-value 'drgnx-agent-panel--intent panel))))))

(ert-deftest drgnx-ui-conversation-tab/a-context-item-is-a-chip-that-leaves-on-removal ()
  "A context item shows above the field as a chip (\"@ main.el\"); removing it takes the chip away."
  (drgnx-ui-conversation-tab--with (panel session)
    (drgnx-agent-panel-open-tab session)
    (let ((comp (drgnx-agent-panel--composer-of panel)) (item '(:file "src/main.el")))
      (with-current-buffer panel (drgnx-agent-panel-context-add item))
      (with-current-buffer comp
        (should (string-match-p "@ main.el" (overlay-get drgnx-agent-companion--head 'before-string))))
      (with-current-buffer panel (drgnx-agent-panel-context-remove item) (drgnx-agent-panel-composer--refresh))
      (with-current-buffer comp
        (should-not (overlay-get drgnx-agent-companion--head 'before-string))))))

(provide 'conversation-tab-gui-test)
;;; conversation-tab-gui-test.el ends here
