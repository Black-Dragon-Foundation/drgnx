;;; agents-editor-draw-test.el --- agents drawn in the buffer: cursors, ring rows, tags -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  Frames are fed to the module as the hub's events would be; the hub's calls are recorded.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agents-in-editor))

(declare-function drgnx-agents-editor-sync-windows "drgnx-agents-editor")
(declare-function drgnx-agents-editor-draw--scrolled "drgnx-agents-editor-draw")
(declare-function drgnx-agent-identity-clear "drgnx-agent-identity")
(declare-function drgnx-decor-cursor-overlay "drgnx-decor")
(declare-function drgnx-decor-cursor-label-state "drgnx-decor")
(defvar drgnx-agents-tags)
(defvar drgnx-agents-editor-draw--tag-overlays)

(defvar drgnx-agents-editor-draw-test--version 0)

(defmacro drgnx-agents-editor-draw-test--with (lines &rest body)
  "BODY in a window that shows a file buffer of LINES lines, with the module on; the buffer is `buf'."
  (declare (indent 1))
  `(let ((dir (make-temp-file "agents-draw" t)) (drgnx-agents-editor-draw-test--version 0))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) 1)))
           (drgnx-test-with-clock ()
             (drgnx-test-with-modules '(tools/agents-in-editor)
               (save-window-excursion
                 (delete-other-windows)
                 (let ((buf (find-file-noselect (expand-file-name "a.txt" dir))))
                   (unwind-protect
                       (progn
                         (with-current-buffer buf
                           (insert (mapconcat (lambda (i) (format "line %d" i)) (number-sequence 1 ,lines) "\n"))
                           (set-buffer-modified-p nil))
                         (set-window-buffer (selected-window) buf)
                         (drgnx-agents-editor-sync-windows)
                         ,@body)
                     (kill-buffer buf)))))))
       (delete-directory dir t))))

(defun drgnx-agents-editor-draw-test--frame (buf agents)
  "Feed BUF's watch the full frame of AGENTS."
  (drgnx-agents-editor--event
   "agent-buffer" (list :view (buffer-local-value 'drgnx-agents-editor--view buf) :full t
                        :version (cl-incf drgnx-agents-editor-draw-test--version) :agents agents)))

(defun drgnx-agents-editor-draw-test--bars (buf)
  (with-current-buffer buf (seq-filter (lambda (o) (overlay-get o 'drgnx-decor-cursor)) (overlays-in (point-min) (point-max)))))

(defun drgnx-agents-editor-draw-test--rings (buf)
  (with-current-buffer buf (seq-filter (lambda (o) (overlay-get o 'drgnx-agents-editor-ring)) (overlays-in (point-min) (point-max)))))

(defun drgnx-agents-editor-draw-test--agent (ord mode line &rest more)
  (append (list :ordinal ord :session (format "s%d" ord) :handle (format "Agent%d" ord) :mode mode :line line
                :line_end (or (plist-get more :line_end) line) :col 0)
          more))

(ert-deftest drgnx-agents-editor/one-bar-and-one-ring-per-agent ()
  (drgnx-agents-editor-draw-test--with 30
    (dotimes (_ 2)
      (drgnx-agents-editor-draw-test--frame
       buf (list (drgnx-agents-editor-draw-test--agent 1 "editing" 3)
                 (drgnx-agents-editor-draw-test--agent 2 "reading" 5 :line_end 8))))
    (should (= 1 (length (drgnx-agents-editor-draw-test--bars buf))))
    (should (= 4 (length (cl-remove-if-not (lambda (o) (overlay-buffer o)) (drgnx-agents-editor-draw-test--rings buf)))))
    ;; an agent that left takes its bar away
    (drgnx-agents-editor-draw-test--frame buf (list (drgnx-agents-editor-draw-test--agent 2 "reading" 5 :line_end 8)))
    (should-not (drgnx-agents-editor-draw-test--bars buf))))

(ert-deftest drgnx-agents-editor/a-move-reuses-the-overlay ()
  (drgnx-agents-editor-draw-test--with 30
    (drgnx-agents-editor-draw-test--frame buf (list (drgnx-agents-editor-draw-test--agent 1 "editing" 3)))
    (let ((ov (car (drgnx-agents-editor-draw-test--bars buf))))
      (drgnx-agents-editor-draw-test--frame buf (list (drgnx-agents-editor-draw-test--agent 1 "editing" 6)))
      (should (eq ov (car (drgnx-agents-editor-draw-test--bars buf))))
      (should (= 6 (with-current-buffer buf (line-number-at-pos (overlay-start ov))))))))

(ert-deftest drgnx-agents-editor/cursors-are-re-put-at-theme-load ()
  (drgnx-agents-editor-draw-test--with 30
    (drgnx-agents-editor-draw-test--frame buf (list (drgnx-agents-editor-draw-test--agent 1 "editing" 3)))
    (let ((ov (car (drgnx-agents-editor-draw-test--bars buf))))
      (drgnx-agent-identity-clear)
      (let ((new (drgnx-agents-editor-draw-test--bars buf)))
        (should (= 1 (length new)))
        (should-not (eq ov (car new)))
        (should-not (overlay-buffer ov))))))

(ert-deftest drgnx-agents-editor/ring-rows-only-for-visible-rows ()
  (drgnx-agents-editor-draw-test--with 400
    (drgnx-agents-editor-draw-test--frame buf (list (drgnx-agents-editor-draw-test--agent 1 "reading" 1 :line_end 300)))
    (let* ((win (selected-window)) (max-rows (1+ (window-body-height win))))
      (cl-flet ((live () (cl-remove-if-not #'overlay-buffer (drgnx-agents-editor-draw-test--rings buf))))
        (should (<= 1 (length (live)) max-rows))
        (with-current-buffer buf (goto-char (point-min)) (forward-line 199) (set-window-start win (point)))
        (drgnx-agents-editor-draw--scrolled win (window-start win))
        (should (<= 1 (length (live)) max-rows))
        (dolist (o (live))
          (should (<= 200 (with-current-buffer buf (line-number-at-pos (overlay-start o))) (+ 200 max-rows))))
        ;; scrolled past the range: no row has an overlay
        (with-current-buffer buf (goto-char (point-min)) (forward-line 349) (set-window-start win (point)))
        (drgnx-agents-editor-draw--scrolled win (window-start win))
        (should-not (live))))))

(ert-deftest drgnx-agents-editor/projected-draws-no-bar ()
  (drgnx-agents-editor-draw-test--with 30
    (drgnx-agents-editor-draw-test--frame
     buf (list (drgnx-agents-editor-draw-test--agent 1 "editing" 4 :projected '(:worktree_label "rp-df-hub"))))
    (should-not (drgnx-agents-editor-draw-test--bars buf))
    (should-not (cl-remove-if-not #'overlay-buffer (drgnx-agents-editor-draw-test--rings buf)))
    (let ((tag (with-current-buffer buf (car drgnx-agents-editor-draw--tag-overlays))))
      (should tag)
      (should (string-match-p "editing in rp-df-hub" (overlay-get (cdr tag) 'after-string)))
      (should (= 4 (with-current-buffer buf (line-number-at-pos (overlay-start (cdr tag)))))))))

(ert-deftest drgnx-agents-editor/tags-stay-on-for-a-shared-colour ()
  (drgnx-agents-editor-draw-test--with 30
    ;; agents 1 and 7 share a colour; agent 2 does not
    (drgnx-agents-editor-draw-test--frame
     buf (list (drgnx-agents-editor-draw-test--agent 1 "editing" 3) (drgnx-agents-editor-draw-test--agent 7 "editing" 5)
               (drgnx-agents-editor-draw-test--agent 2 "editing" 7)))
    (should (eq 'always (drgnx-decor-cursor-label-state buf 1)))
    (should (eq 'always (drgnx-decor-cursor-label-state buf 7)))
    (should-not (eq 'always (drgnx-decor-cursor-label-state buf 2)))))

(ert-deftest drgnx-agents-editor/flat-gui-names-in-help-echo ()
  (drgnx-agents-editor-draw-test--with 30
    (cl-letf (((symbol-function 'drgnx-decor--glitnir-p) (lambda () nil)))
      (drgnx-agents-editor-draw-test--frame buf (list (drgnx-agents-editor-draw-test--agent 1 "editing" 3)))
      (should (string-match-p "Agent1 · editing" (overlay-get (car (drgnx-agents-editor-draw-test--bars buf)) 'help-echo))))))

(ert-deftest drgnx-agents-editor/terminal-bar-is-inverse-video ()
  (drgnx-agents-editor-draw-test--with 30
    (cl-letf (((symbol-function 'drgnx-decor--glitnir-p) (lambda () nil))
              ((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
      (drgnx-agents-editor-draw-test--frame buf (list (drgnx-agents-editor-draw-test--agent 1 "editing" 3)))
      (should (plist-get (overlay-get (car (drgnx-agents-editor-draw-test--bars buf)) 'face) :inverse-video)))))

(ert-deftest drgnx-agents-editor/tag-timing-follows-the-setting ()
  (drgnx-agents-editor-draw-test--with 30
    (let ((agents (list (drgnx-agents-editor-draw-test--agent 1 "editing" 3))))
      (dolist (case '((activity . timed) (always . always) (never . nil)))
        (let ((drgnx-agents-tags (car case)))
          (drgnx-agents-editor-draw--tags-apply)
          (drgnx-agents-editor-draw-test--frame buf agents)
          (drgnx-agents-editor-draw-test--frame buf (list (drgnx-agents-editor-draw-test--agent 1 "editing" 5)))
          (let ((state (drgnx-decor-cursor-label-state buf 1)))
            (pcase (cdr case)
              ('timed (should (numberp state)) (drgnx-test-advance 2.5)
                      (should-not (drgnx-decor-cursor-label-state buf 1)))
              ('always (should (eq 'always state)))
              ('nil (should-not state)))))))))

(provide 'agents-editor-draw-test)
;;; agents-editor-draw-test.el ends here
