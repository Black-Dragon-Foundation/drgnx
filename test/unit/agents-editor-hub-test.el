;;; agents-editor-hub-test.el --- batch tests: following an agent and the wheel against a real hub -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The hub runs as its own process; this Emacs plays the editor inside the delivery gate (`drgnx-test-gated').  The
;; agent is `ratatoskr-mock acp --as claude' (beside the hub's binary): what it did is a condition the test sees after
;; each release of the hub's lines (the helpers of agents-mirror-test.el), never a deadline.  Skipped without the hub.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-modules)
(require 'drgnx-agents)
(require 'drgnx-hub-client)
(load (expand-file-name "test/unit/agents-mirror-test" drgnx-dir) nil t)   ; its helpers and the hub fixtures
(load (expand-file-name "modules/tools/drgnx-agents-editor" drgnx-dir) nil t)   ; it loads the follow code
(load (expand-file-name "modules/tools/drgnx-agents-editor-here" drgnx-dir) nil t)   ; who is here, and its huddle keys
(defvar drgnx-hub-event-functions)
(defvar drgnx-agents-follow--session)
(defvar drgnx-agents-follow--view)
(defvar drgnx-agents-follow--window)
(declare-function drgnx-agents-follow-start "drgnx-agents-follow")
(declare-function drgnx-agents-follow-stop "drgnx-agents-follow")
(declare-function drgnx-agents-follow--event "drgnx-agents-follow")
(declare-function drgnx-agents-editor-here-show "drgnx-agents-editor-here")
(declare-function drgnx-agents-here-mark "drgnx-agents-editor-here")
(declare-function drgnx-agents-here-huddle "drgnx-agents-editor-here")

(defmacro drgnx-agents-editor-hub-test--with (&rest body)
  "BODY with a gated hub whose profile \"asks\" is the mock Claude, the follow code listening to the hub's events and
this Emacs connected; `dir' is a folder with `a.txt' (twelve lines) inside the hub's root.  The module's own setup is
not used: the module fixture moves the config, and the hub's socket with it."
  (declare (indent 0))
  `(drgnx-agents-mirror-test--with '()
     (drgnx-agents-mirror-test--asking root)
     (save-window-excursion
       (delete-other-windows)
       (add-hook 'drgnx-hub-event-functions #'drgnx-agents-follow--event)
       (let* ((dir (file-name-as-directory (expand-file-name "work" root)))
              (file (expand-file-name "a.txt" dir)))
         (unwind-protect
             (progn
               (make-directory dir t)
               (write-region (mapconcat (lambda (i) (format "line %d\n" i)) (number-sequence 1 12) "") nil file nil 'silent)
               (drgnx-agents-mirror-sync)
               ,@body)
           (remove-hook 'drgnx-hub-event-functions #'drgnx-agents-follow--event)
           (drgnx-agents-follow-stop)
           (when-let* ((b (get-file-buffer file))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))))))

(defun drgnx-agents-editor-hub-test--start(dir &optional role)
  "Start the mock Claude in DIR (as ROLE, default worker); its session id, once its mirror is idle."
  (let ((id (plist-get (drgnx-agents-mirror-test--ask
                        "agents/start" (list :profile "asks" :role (or role "worker") :cwd (directory-file-name dir)))
                       :id)))
    (drgnx-agents-mirror-test--settle (lambda () (drgnx-agents-mirror-test--idle-mirror id)) "the new session's mirror, idle")
    id))

(defun drgnx-agents-editor-hub-test--line (window)
  (and (window-live-p window) (with-current-buffer (window-buffer window) (line-number-at-pos (window-point window) t))))

(ert-deftest drgnx-agents-editor-hub/follow-moves-with-the-agent ()
  (drgnx-agents-editor-hub-test--with
    (let ((id (drgnx-agents-editor-hub-test--start dir)))
      (drgnx-agents-follow-start id)
      (drgnx-agents-mirror-test--ask "agents/send" (list :id id :text (format "provider:read %s 7" file)))
      (drgnx-agents-mirror-test--settle
       (lambda () (equal 7 (drgnx-agents-editor-hub-test--line drgnx-agents-follow--window)))
       "the follow window on line 7 of the agent's file")
      (should (equal file (buffer-file-name (window-buffer drgnx-agents-follow--window))))
      (should (window-parameter drgnx-agents-follow--window 'header-line-format)))))

(ert-deftest drgnx-agents-editor-hub/follow-here-stops-on-navigation ()
  (drgnx-agents-editor-hub-test--with
    (let ((id (drgnx-agents-editor-hub-test--start dir)) (here (selected-window)) (view nil))
      (drgnx-agents-follow-start id t)
      (setq view drgnx-agents-follow--view)
      (drgnx-agents-mirror-test--ask "agents/send" (list :id id :text (format "provider:read %s 5" file)))
      (drgnx-agents-mirror-test--settle
       (lambda () (equal 5 (drgnx-agents-editor-hub-test--line here))) "the user's window on line 5 of the agent's file")
      (should (eq here drgnx-agents-follow--window))
      ;; any command in the window ends the follow, at the hub too
      (with-current-buffer (window-buffer here)
        (forward-line 1)
        (let ((this-command 'next-line)) (run-hooks 'post-command-hook)))
      (should-not drgnx-agents-follow--session)
      (should (memq (drgnx-agents-mirror-test--ask "agents/unfollow" (list :view view)) '(nil :json-false))))))

;;;; The wheel

(defvar drgnx-agents-follow--wheel)
(defvar drgnx-agents-follow--unsaved)
(declare-function drgnx-agents-take-wheel "drgnx-agents-follow")
(declare-function drgnx-agents-give-wheel "drgnx-agents-follow")
(declare-function drgnx-agents-follow--wheel-save "drgnx-agents-follow")

(defun drgnx-agents-editor-hub-test--held-p (id)
  (eq 'held (plist-get (gethash id drgnx-agents-follow--wheel) :state)))

(defun drgnx-agents-editor-hub-test--take(id buffer)
  "Take ID's wheel from BUFFER and wait for the hub's `held'."
  (with-current-buffer buffer (drgnx-agents-take-wheel id))
  (drgnx-agents-mirror-test--settle (lambda () (drgnx-agents-editor-hub-test--held-p id)) "the wheel held")
  (should-not (buffer-local-value 'buffer-read-only buffer)))

;; The hub's request sequencer serves one request at a time, so a real give (which waits for this editor's
;; `agents/wheel/saved') cannot be driven through the gate: the editor's answer would queue behind the give.  The take
;; goes through the real hub; the hub's `wheel-save' event is fed to the editor as the hub sends it, and the editor's
;; answer is recorded (the conformance row `wheel/give-with-and-without-edits' drives the real round trip).
(defun drgnx-agents-editor-hub-test--wheel-save (id dir)
  "Feed `wheel-save' for ID in DIR; the params of the editor's answer."
  (let (answer)
    (cl-letf (((symbol-function 'drgnx-agents-follow--send) (lambda (_method params) (setq answer params))))
      (drgnx-agents-follow--event "wheel-save" (list :req 7 :id id :worktree (directory-file-name dir))))
    answer))

(ert-deftest drgnx-agents-editor-hub/give-saves-without-prompting ()
  (drgnx-agents-editor-hub-test--with
    (let* ((id (drgnx-agents-editor-hub-test--start dir)) (buf (find-file-noselect file)) (require-final-newline 'ask) answer)
      (unwind-protect
          (progn
            (drgnx-agents-editor-hub-test--take id buf)
            ;; no final newline and `require-final-newline' `ask': a plain save would ask
            (with-current-buffer buf (goto-char (point-max)) (delete-char -1) (insert "\nedited by you"))
            (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (error "asked a question"))))
              (setq answer (drgnx-agents-editor-hub-test--wheel-save id dir)))
            (should (equal (list :req 7 :unsaved []) answer))
            (should-not (buffer-modified-p buf))
            (should (string-search "edited by you" (with-temp-buffer (insert-file-contents file) (buffer-string)))))
        (kill-buffer buf)))))

(ert-deftest drgnx-agents-editor-hub/give-on-a-chat-saves-nothing ()
  (drgnx-agents-editor-hub-test--with
    (let* ((id (drgnx-agents-editor-hub-test--start dir "chat")) (buf (find-file-noselect file)) (saves 0)
           (orig (symbol-function 'drgnx-agents-follow--wheel-save)))
      (unwind-protect
          (progn
            (drgnx-agents-editor-hub-test--take id buf)
            (with-current-buffer buf (goto-char (point-max)) (insert "unsaved edit\n"))
            (cl-letf (((symbol-function 'drgnx-agents-follow--wheel-save) (lambda (data) (cl-incf saves) (funcall orig data))))
              (drgnx-agents-give-wheel id)
              (drgnx-agents-mirror-test--settle (lambda () (null (gethash id drgnx-agents-follow--wheel))) "the wheel given back"))
            (should (= 0 saves))
            (should (buffer-modified-p buf))
            (should-not (string-search "unsaved edit" (with-temp-buffer (insert-file-contents file) (buffer-string)))))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)))))

(ert-deftest drgnx-agents-editor-hub/give-refused-lists-unsaved-buffers ()
  (drgnx-agents-editor-hub-test--with
    (let* ((id (drgnx-agents-editor-hub-test--start dir)) (buf (find-file-noselect file)) (said nil) answer)
      (unwind-protect
          (progn
            (with-current-buffer buf (goto-char (point-max)) (insert "mine\n"))
            ;; the file changed on disk behind the buffer: saving would ask about it, so it is not saved and is listed
            (set-file-times file (time-convert 4000000000 'list))
            (setq answer (drgnx-agents-editor-hub-test--wheel-save id dir))
            (should (equal (list :req 7 :unsaved (vector file)) answer))
            (should (buffer-modified-p buf))
            ;; the hub refuses a give of a wheel that is not held; the message carries the list
            (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
              (drgnx-agents-give-wheel id)
              (drgnx-agents-mirror-test--settle
               (lambda () (cl-some (lambda (s) (string-match-p "was not given back.*not saved: a\\.txt" s)) said))
               "the refusal naming the unsaved buffer")))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)))))

(ert-deftest drgnx-agents-editor-hub/the-interim-save-hook-is-gone ()
  (load (expand-file-name "modules/tools/drgnx-work-space" drgnx-dir) nil t)
  (should-not (fboundp 'drgnx-work-live-file--saved)))

(ert-deftest drgnx-agents-editor-hub/start-a-huddle-from-two-rows ()
  ;; two marked rows of the who-is-here list reach the real hub's `agents/huddle/start'; its record opens the thread
  (drgnx-agents-editor-hub-test--with
    (let* ((a (drgnx-agents-editor-hub-test--start dir)) (b (drgnx-agents-editor-hub-test--start dir)) opened buf)
      (cl-letf (((symbol-function 'drgnx-agent-panel-huddle-open-thread) (lambda (rec) (setq opened rec))))
        (unwind-protect
            (progn
              (setq buf (drgnx-agents-editor-here-show (list (list a 1 "edit" file 3) (list b 2 "edit" file 4))))
              (with-current-buffer buf
                (goto-char (point-min))
                (drgnx-agents-here-mark)
                (forward-line 1)
                (drgnx-agents-here-mark)
                (drgnx-agents-here-huddle))
              (drgnx-agents-mirror-test--settle (lambda () opened) "the huddle's record from the hub")
              (should (equal (sort (list a b) #'string<) (sort (append (plist-get opened :participants) nil) #'string<)))
              (should (member (plist-get opened :state) '("asked" "open"))))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(provide 'agents-editor-hub-test)
;;; agents-editor-hub-test.el ends here
