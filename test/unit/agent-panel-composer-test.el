;;; agent-panel-composer-test.el --- the agent panel's composer: an input buffer under the transcript -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  No hub: the panel is fed snapshots by hand, and the hub client's calls are recorded.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(require 'drgnx-modal)
(require 'drgnx-history-revert)          ; Fork's library, loaded first so a stub of it is not replaced mid-test
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agent-panel))

(declare-function drgnx-agent-panel-buffer "drgnx-agent-panel")
(declare-function drgnx-agent-panel--take-snapshot "drgnx-agent-panel")
(declare-function drgnx-agent-panel--composer-of "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel--main-of "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-composer--field-end "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-composer--field-text "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-composer--clicked "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-composer-newline "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-composer-back "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-compose "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-send "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-pause "drgnx-agent-panel-composer")
(declare-function drgnx-history-fork-here "drgnx-history-revert")
(defvar drgnx-agent-panel--session)
(defvar drgnx-agent-panel--snap)
(defvar drgnx-agent-panel--steps)
(defvar drgnx-agent-panel--loading)
(defvar drgnx-agent-panel-composer-placeholder)
(defvar drgnx-agent-panel-composer-mode-map)

(defvar drgnx-agent-panel-composer-test--calls nil)

(defmacro drgnx-agent-panel-composer-test--with (&rest body)
  "BODY with the module set up, the hub's calls recorded in `drgnx-agent-panel-composer-test--calls' (METHOD . PARAMS),
panel \"s1\" as `buf' (idle, model opus, mode default) and its composer as `comp'."
  (declare (indent 0))
  `(let ((drgnx-agent-panel-composer-test--calls nil) buf comp)
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params _cb &rest _) (push (cons method params) drgnx-agent-panel-composer-test--calls) 1)))
       (drgnx-test-with-modules '(tools/agent-panel)
         (save-window-excursion
           (unwind-protect
               (progn (setq buf (drgnx-agent-panel-buffer "s1"))
                      (with-current-buffer buf
                        (drgnx-agent-panel--take-snapshot (list :id "s1" :status "idle" :model "opus" :mode "default")))
                      (setq comp (drgnx-agent-panel--composer-of buf))
                      (setq drgnx-agent-panel-composer-test--calls nil)
                      ,@body)
             (when (buffer-live-p buf) (kill-buffer buf))))))))

(defun drgnx-agent-panel-composer-test--bar (comp)
  "COMP's bar: the text after the field."
  (with-current-buffer comp
    (buffer-substring-no-properties (drgnx-agent-panel-composer--field-end) (point-max))))

(defun drgnx-agent-panel-composer-test--command (comp)
  "A command run in COMP as the command loop runs it: the state comes in before, goes back after."
  (lambda (fn)
    (with-current-buffer comp
      (run-hooks 'pre-command-hook)
      (prog1 (call-interactively fn) (run-hooks 'post-command-hook)))))

(defun drgnx-agent-panel-composer-test--click (comp text)
  "Click the bar's button that shows TEXT in COMP (shown in the selected window), from another buffer."
  (let* ((pos (with-current-buffer comp
                (save-excursion (goto-char (drgnx-agent-panel-composer--field-end)) (search-forward text) (match-beginning 0))))
         (w (progn (set-window-buffer (selected-window) comp) (selected-window))))
    (with-temp-buffer                   ; the click comes while another buffer is current
      (drgnx-agent-panel-composer--clicked (list 'mouse-1 (list w pos '(0 . 0) 0))))))

(ert-deftest drgnx-agent-panel-composer/typing-goes-in-the-field-and-the-bar-stays ()
  "Typing inserts text in the input field; the chips and buttons line under it is read-only and survives edits of the
field that empty it."
  (drgnx-agent-panel-composer-test--with
    (with-current-buffer comp
      (should (derived-mode-p 'drgnx-agent-panel-composer-mode))
      (should (eq buf (drgnx-agent-panel--main-of comp)))
      (let ((bar (drgnx-agent-panel-composer-test--bar comp)))
        (should (string-search "opus" bar))
        (should (string-search "Fork" bar))
        (goto-char (point-min))
        (insert "fix the test")
        (goto-char (drgnx-agent-panel-composer--field-end))
        (insert " now")                ; at the field's end, right before the bar
        (should (equal "fix the test now" (drgnx-agent-panel-composer--field-text)))
        (should (equal bar (drgnx-agent-panel-composer-test--bar comp)))
        ;; the bar takes no typing and no deletion
        (goto-char (1+ (drgnx-agent-panel-composer--field-end)))
        (should-error (insert "x") :type 'text-read-only)
        (should-error (delete-region (point-min) (point-max)) :type 'text-read-only)
        (should (equal bar (drgnx-agent-panel-composer-test--bar comp)))
        ;; emptying the field leaves the bar as it was
        (delete-region (point-min) (drgnx-agent-panel-composer--field-end))
        (should (equal "" (drgnx-agent-panel-composer--field-text)))
        (should (equal bar (drgnx-agent-panel-composer-test--bar comp)))
        (goto-char (point-min))
        (insert "again")
        (should (equal "again" (drgnx-agent-panel-composer--field-text)))))))

(ert-deftest drgnx-agent-panel-composer/send-queues-the-field-and-empties-it ()
  "`agents-panel-send' (RET) sends the field's text through the hub's queue, as the minibuffer did, and empties the
field; a mode that would cancel the turn is refused and the draft stays."
  (drgnx-agent-panel-composer-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-snapshot (list :id "s1" :status "busy" :mode "queue")))
    (with-current-buffer comp
      (insert " go on \nand test it ")
      (funcall (drgnx-agent-panel-composer-test--command comp) #'drgnx-agent-panel-send)
      (should (equal '(("agents/send" :id "s1" :text "go on \nand test it")) drgnx-agent-panel-composer-test--calls))
      (should (equal "" (drgnx-agent-panel-composer--field-text)))
      (setq drgnx-agent-panel-composer-test--calls nil)
      (with-current-buffer buf
        (drgnx-agent-panel--take-snapshot (list :id "s1" :status "busy" :mode "interrupt")))
      (insert "stop now")
      (should-error (funcall (drgnx-agent-panel-composer-test--command comp) #'drgnx-agent-panel-send) :type 'user-error)
      (should-not drgnx-agent-panel-composer-test--calls)
      (should (equal "stop now" (drgnx-agent-panel-composer--field-text))))
    ;; from the transcript, the command sends the composer's draft too
    (with-current-buffer buf
      (drgnx-agent-panel--take-snapshot (list :id "s1" :status "idle" :mode "queue"))
      (funcall (drgnx-agent-panel-composer-test--command buf) #'drgnx-agent-panel-send))
    (should (equal '(("agents/send" :id "s1" :text "stop now")) drgnx-agent-panel-composer-test--calls))))

(ert-deftest drgnx-agent-panel-composer/a-newline-key-breaks-the-line-and-sends-nothing ()
  (drgnx-agent-panel-composer-test--with
    (with-current-buffer comp
      (insert "one")
      (funcall (drgnx-agent-panel-composer-test--command comp) #'drgnx-agent-panel-composer-newline)
      (insert "two")
      (should (equal "one\ntwo" (drgnx-agent-panel-composer--field-text)))
      (should-not drgnx-agent-panel-composer-test--calls))))

(ert-deftest drgnx-agent-panel-composer/an-empty-field-shows-the-placeholder-and-sends-nothing ()
  (drgnx-agent-panel-composer-test--with
    (with-current-buffer comp
      (cl-flet ((shown () (seq-some (lambda (ov) (let ((s (overlay-get ov 'before-string)))
                                                   (and s (string-search "Steer the agent… (@ file, / command)" s))))
                                    (overlays-in (point-min) (point-max)))))
        (should (equal "Steer the agent… (@ file, / command)" drgnx-agent-panel-composer-placeholder))
        (should (shown))
        (insert "x")
        (should-not (shown))
        (delete-region (point-min) (drgnx-agent-panel-composer--field-end))
        (should (shown))
        ;; empty, or only blanks: nothing goes to the agent
        (funcall (drgnx-agent-panel-composer-test--command comp) #'drgnx-agent-panel-send)
        (insert "  \n ")
        (funcall (drgnx-agent-panel-composer-test--command comp) #'drgnx-agent-panel-send)
        (should-not drgnx-agent-panel-composer-test--calls)))))

(ert-deftest drgnx-agent-panel-composer/at-and-slash-complete-through-the-capf ()
  (let ((dir (make-temp-file "composer-cwd" t)))
    (unwind-protect
        (drgnx-agent-panel-composer-test--with
          (write-region "" nil (expand-file-name "alpha.el" dir))
          (with-current-buffer buf
            (drgnx-agent-panel--take-snapshot (list :id "s1" :status "idle" :cwd dir :commands (vector "compact" "review"))))
          (with-current-buffer comp
            (run-hooks 'pre-command-hook)
            (cl-flet ((cands (text)
                        (delete-region (point-min) (drgnx-agent-panel-composer--field-end))
                        (goto-char (point-min))
                        (insert text)
                        (when-let* ((r (run-hook-with-args-until-success 'completion-at-point-functions)))
                          (all-completions (buffer-substring-no-properties (nth 0 r) (nth 1 r)) (nth 2 r)))))
              (should (member "alpha.el" (cands "look at @al")))
              (should (member "compact" (cands "/co")))
              (should-not (member "compact" (cands "then /co"))))))
      (delete-directory dir t))))

(ert-deftest drgnx-agent-panel-composer/the-bars-buttons-run-their-commands-on-the-session ()
  "A click on the model, mode, Pair, Fork, pause and send buttons runs its command on the session's state, whatever
buffer is current; by key, a command run in the composer works on the session as in the transcript."
  (drgnx-agent-panel-composer-test--with
    (drgnx-command-define 'agents-pair :category "Agents" :title "Pair" :command (lambda () (interactive) (push '(paired) drgnx-agent-panel-composer-test--calls)) :doc "test")
    (unwind-protect
        (let (forked)
          (with-current-buffer buf
            (puthash 7 (list :seq 7) drgnx-agent-panel--steps)
            (drgnx-agent-panel--take-snapshot (list :id "s1" :status "idle" :model "opus" :mode "default")))
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "sonnet"))
                    ((symbol-function 'drgnx-history-fork-here) (lambda (sid seq) (setq forked (list sid seq)))))
            (drgnx-agent-panel-composer-test--click comp "opus")
            (should (equal '("agents/config" :id "s1" :option "model" :value "sonnet") (car drgnx-agent-panel-composer-test--calls)))
            (drgnx-agent-panel-composer-test--click comp "default")
            (should (equal '("agents/explain" :id "s1" :item "mode") (car drgnx-agent-panel-composer-test--calls)))
            (drgnx-agent-panel-composer-test--click comp "Pair")
            (should (equal '(paired) (car drgnx-agent-panel-composer-test--calls)))
            (drgnx-agent-panel-composer-test--click comp "Fork")
            (should (equal '("s1" 7) forked))
            (drgnx-agent-panel-composer-test--click comp (drgnx-face-glyph 'pause))
            (should (equal '("agents/pause" :id "s1") (car drgnx-agent-panel-composer-test--calls)))
            (with-current-buffer comp (goto-char (point-min)) (insert "ship it"))
            (drgnx-agent-panel-composer-test--click comp (drgnx-face-glyph 'arrow-up))
            (should (equal '("agents/send" :id "s1" :text "ship it") (car drgnx-agent-panel-composer-test--calls)))
            ;; by key in the composer
            (setq drgnx-agent-panel-composer-test--calls nil)
            (funcall (drgnx-agent-panel-composer-test--command comp) #'drgnx-agent-panel-pause)
            (should (equal '(("agents/pause" :id "s1")) drgnx-agent-panel-composer-test--calls))))
      (drgnx-command-undefine 'agents-pair))))

(ert-deftest drgnx-agent-panel-composer/shares-the-panels-state-both-ways ()
  "The composer is a state twin of the panel's buffer: a new snapshot redraws its bar and keeps the draft, and what a
command in it changes of the state goes back to the panel."
  (drgnx-agent-panel-composer-test--with
    (with-current-buffer comp (insert "draft"))
    (with-current-buffer buf (drgnx-agent-panel--take-snapshot (list :id "s1" :status "idle" :model "sonnet")))
    (should (string-search "sonnet" (drgnx-agent-panel-composer-test--bar comp)))
    (should-not (string-search "opus" (drgnx-agent-panel-composer-test--bar comp)))
    (should (equal "draft" (with-current-buffer comp (drgnx-agent-panel-composer--field-text))))
    (with-current-buffer comp
      (run-hooks 'pre-command-hook)
      (should (equal "s1" drgnx-agent-panel--session))
      (setq drgnx-agent-panel--loading 'by-the-composer)
      (run-hooks 'post-command-hook))
    (should (eq 'by-the-composer (buffer-local-value 'drgnx-agent-panel--loading buf)))
    ;; the panel's later snapshot is not taken back by a command in the composer that did not change it
    (with-current-buffer buf (drgnx-agent-panel--take-snapshot (list :id "s1" :status "busy" :model "sonnet")))
    (with-current-buffer comp (run-hooks 'post-command-hook))
    (should (equal "busy" (plist-get (buffer-local-value 'drgnx-agent-panel--snap buf) :status)))))

(ert-deftest drgnx-agent-panel-composer/focus-and-back ()
  "`s' (`agents-panel-compose') in the transcript puts point in the composer's field; the back key returns to the
transcript."
  (drgnx-agent-panel-composer-test--with
    (delete-other-windows)
    (set-window-buffer (selected-window) buf)
    (let ((tw (selected-window)) (cw (split-window nil nil 'below)))
      (set-window-buffer cw comp)
      (with-current-buffer comp (insert "half"))
      (set-buffer buf)
      (drgnx-agent-panel-compose)
      (should (eq cw (selected-window)))
      (should (eq comp (current-buffer)))
      (should (= (point) (drgnx-agent-panel-composer--field-end)))
      (drgnx-agent-panel-composer-back)
      (should (eq tw (selected-window))))))

(ert-deftest drgnx-agent-panel-composer/starts-in-insert-state-and-goes-with-the-panel ()
  "A modal engine starts the composer in insert state; killing the panel's buffer kills its composer."
  (drgnx-agent-panel-composer-test--with
    (should (memq 'drgnx-agent-panel-composer-mode drgnx-modal-input-modes))
    (with-current-buffer comp (should (eq 'insert (drgnx-modal-initial-state))))
    (should (eq comp (drgnx-agent-panel--composer-of buf)))   ; one per panel
    (kill-buffer buf)
    (should-not (buffer-live-p comp))))

(ert-deftest drgnx-agent-panel-composer/the-module-off-takes-its-mode-out-of-the-input-modes ()
  (drgnx-test-with-modules '(tools/agent-panel) (ignore))
  (should-not (memq 'drgnx-agent-panel-composer-mode drgnx-modal-input-modes)))

;;; agent-panel-composer-test.el ends here
