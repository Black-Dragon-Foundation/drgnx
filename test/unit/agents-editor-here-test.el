;;; agents-editor-here-test.el --- Explorer badges, the status segment, who is here -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  The marks, badges and status are made from what the hub's model names (the model's feed is
;; editor-here-rows-test.el); the hub's calls are absorbed.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(load (expand-file-name "modules/ui/drgnx-statusbar" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agents-in-editor))

(declare-function drgnx-agents-editor-here--badge "drgnx-agents-editor-here")
(declare-function drgnx-agents-editor-here--status-of "drgnx-agents-editor-here")
(declare-function drgnx-agents-editor-here--segment "drgnx-agents-editor-here")
(declare-function drgnx-agents-editor-here-show "drgnx-agents-editor-here")
(declare-function drgnx-agents-here-follow "drgnx-agents-editor-here")
(declare-function drgnx-agents-here-panel "drgnx-agents-editor-here")
(declare-function drgnx-agents-here-quit "drgnx-agents-editor-here")
(declare-function drgnx-agents-editor--event "drgnx-agents-editor")
(declare-function drgnx-agents-editor-ordinal "drgnx-agents-editor")
(defvar drgnx-agents-editor-here--rows)
(defvar drgnx-agent-identity-sessions-function)
(defvar drgnx-agents-editor-here--badges)
(defvar drgnx-agents-editor-here--status)
(defvar drgnx-agents-editor-followed)
(defvar drgnx-statusbar-left)

(defvar drgnx-agents-editor-here-test--root nil)

(defmacro drgnx-agents-editor-here-test--with (&rest body)
  "BODY with the module on, a workspace whose one root is a temp directory (`root') and the hub's calls absorbed."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "agents-here" t)))))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) 1)))
           (drgnx-test-with-modules '(tools/agents-in-editor)
             ;; the workspace: one root (the function is the work space module's, so it is stubbed inside)
             (cl-letf (((symbol-function 'drgnx-work-space-workspace)
                        (lambda (&rest _) (list :id "workspace:000000000000" :roots (list root)))))
               ,@body)))
       (delete-directory root t))))

(defun drgnx-agents-editor-here-test--snapshot (sid ordinal &optional last-active)
  "Feed the module the hub's `agent' snapshot of SID with ORDINAL (nil: the session ended) and LAST-ACTIVE."
  (drgnx-agents-editor--event "agent" (list :id sid :session (list :id sid :ordinal ordinal :last_active (or last-active 1.0)))))

(defun drgnx-agents-editor-here-test--marks (s)
  "How many agent marks S holds."
  (let ((n 0) (in nil))
    (dotimes (i (length s))
      (let ((has (and (get-text-property i 'face s) t)))
        (when (and has (not in)) (cl-incf n))
        (setq in has)))
    n))

(ert-deftest drgnx-agents-editor/agents-here-segment-sits-after-jobs ()
  (let ((before (copy-sequence drgnx-statusbar-left)))
    (drgnx-agents-editor-here-test--with
      (let ((tail (memq 'jobs drgnx-statusbar-left)))
        (should tail)
        (should (eq 'agents-here (cadr tail)))
        (should (gethash 'agents-here drgnx-statusbar--segments))))
    (should (equal before drgnx-statusbar-left))
    (should-not (gethash 'agents-here drgnx-statusbar--segments))))

(ert-deftest drgnx-agents-editor/badges-overflow-to-plus-n ()
  (drgnx-agents-editor-here-test--with
    (let ((badge (drgnx-agents-editor-here--badge '(1 2 3 4) 3 t)))
      (should (string-search "+1" badge))
      (should (= 3 (drgnx-agents-editor-here-test--marks (substring badge 0 (string-search "+1" badge))))))))

(ert-deftest drgnx-agents-editor/folder-dots-per-agent ()
  (drgnx-agents-editor-here-test--with
    (should (= 2 (drgnx-agents-editor-here-test--marks (drgnx-agents-editor-here--badge '(1 2) 6 nil))))
    (should (= 1 (drgnx-agents-editor-here-test--marks (drgnx-agents-editor-here--badge '(1) 6 nil))))))

(ert-deftest drgnx-agents-editor/status-marks-overflow ()
  (drgnx-agents-editor-here-test--with
    (setq drgnx-agents-editor-here--status
          (drgnx-agents-editor-here--status-of (cl-loop for i from 1 to 10 collect (cons (format "s%d" i) i))))
    (should (string-search "+2" drgnx-agents-editor-here--status))
    (should (= 8 (drgnx-agents-editor-here-test--marks (substring drgnx-agents-editor-here--status 0
                                                                  (string-search "+2" drgnx-agents-editor-here--status)))))
    (should (equal drgnx-agents-editor-here--status (drgnx-agents-editor-here--segment)))))

(ert-deftest drgnx-agents-editor/one-agent-s-status-says-its-name-and-what-it-does ()
  "window-dark.html's `● Claude editing': one agent here shows its mark, then its name and what it does; several show
their marks alone."
  (drgnx-agents-editor-here-test--with
    (cl-letf (((symbol-function 'drgnx-agents-editor-here--name) (lambda (_sid) "Claude")))
      (let ((s (drgnx-agents-editor-here--status-of '(("s1" . 1)) '(("s1" . "edit")))))
        (should (= 1 (drgnx-agents-editor-here-test--marks s)))
        (should (string-suffix-p " Claude editing" s)))
      (should (string-suffix-p " Claude reading"
                               (drgnx-agents-editor-here--status-of '(("s1" . 1)) '(("s1" . "read")))))
      (should (string-suffix-p " Claude" (drgnx-agents-editor-here--status-of '(("s1" . 1)))))
      (should-not (string-search "Claude" (drgnx-agents-editor-here--status-of '(("s1" . 1) ("s2" . 2))
                                                                               '(("s1" . "edit") ("s2" . "read"))))))))

(ert-deftest drgnx-agents-editor/who-is-here-row-follows-on-ret ()
  ;; who is here is a small list window, one row per agent; RET on a row follows that agent (no `completing-read')
  (drgnx-agents-editor-here-test--with
    (let ((file (expand-file-name "a.el" root)) (list-buffer nil))
      (write-region "one\ntwo\nthree\nfour\n" nil file nil 'silent)
      (unwind-protect
          (save-window-excursion
            (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (error "who is here asked with completing-read"))))
              (setq list-buffer (drgnx-agents-editor-here-show (list (list "s1" 1 "edit" file 3) (list "s2" 2 "read" file 1))))
              (with-current-buffer list-buffer
                (should (derived-mode-p 'drgnx-agents-here-mode))
                (should (= 2 (count-lines (point-min) (point-max))))
                (goto-char (point-min))
                (should (string-match-p "agent s1.*edit.*a\\.el:3" (buffer-substring (pos-bol) (pos-eol))))
                (should (get-text-property (pos-bol) 'face))
                (drgnx-agents-here-follow)))
            (should (equal "s1" drgnx-agents-editor-followed))
            (with-current-buffer (window-buffer (selected-window))
              (should (equal file (buffer-file-name)))
              (should (= 3 (line-number-at-pos)))))
        (when (buffer-live-p list-buffer) (kill-buffer list-buffer))
        (when-let* ((b (get-file-buffer file))) (kill-buffer b))))))

(ert-deftest drgnx-agents-editor/who-is-here-o-opens-the-panel ()
  ;; `o' on a row opens that agent's panel, by the hub's session id
  (drgnx-agents-editor-here-test--with
    (let ((file (expand-file-name "a.el" root)) (opened nil) (list-buffer nil))
      (unwind-protect
          (save-window-excursion
            (cl-letf (((symbol-function 'drgnx-agent-panel-open) (lambda (session) (push session opened))))
              (setq list-buffer (drgnx-agents-editor-here-show (list (list "s1" 1 "edit" file 3) (list "hub-s2" 2 "read" file 1))))
              (with-current-buffer list-buffer
                (goto-char (point-min))
                (forward-line 1)
                (drgnx-agents-here-panel)))
            (should (equal '("hub-s2") opened)))
        (when (buffer-live-p list-buffer) (kill-buffer list-buffer))))))

(ert-deftest drgnx-agents-editor/who-is-here-q-closes-the-list ()
  (drgnx-agents-editor-here-test--with
    (let ((list-buffer (drgnx-agents-editor-here-show (list (list "s1" 1 "edit" (expand-file-name "a.el" root) 3)))))
      (unwind-protect
          (save-window-excursion
            (with-current-buffer list-buffer (drgnx-agents-here-quit))
            (should-not (buffer-live-p list-buffer)))
        (when (buffer-live-p list-buffer) (kill-buffer list-buffer))))))

(ert-deftest drgnx-agents-editor/ordinals-come-from-the-hubs-snapshots ()
  (drgnx-agents-editor-here-test--with
    (let ((by-ordinal (lambda (l) (sort (copy-sequence l) (lambda (a b) (< (car a) (car b)))))))
      (drgnx-agents-editor-here-test--snapshot "s1" 4 20.0)
      (drgnx-agents-editor-here-test--snapshot "s2" 2 10.0)
      ;; identity's reuse past capacity reads the live sessions and when each was last active
      (should (equal '((2 . 10.0) (4 . 20.0)) (funcall by-ordinal (funcall drgnx-agent-identity-sessions-function))))
      ;; an ended session has no ordinal any more
      (drgnx-agents-editor-here-test--snapshot "s1" nil)
      (should (equal '((2 . 10.0)) (funcall by-ordinal (funcall drgnx-agent-identity-sessions-function))))))
  (should-not drgnx-agent-identity-sessions-function))

(provide 'agents-editor-here-test)
;;; agents-editor-here-test.el ends here
