;;; drgnx-agents-follow.el --- Follow an agent in a window of its own (library of tools/agents-in-editor) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The hub's follow feed (`agents/follow', the event `agent-follow') says where an agent is: a file in its worktree and
;; a line.  This file shows it:
;; - `drgnx-agents-follow-start' opens a window on the right with the agent's file, read-only, point on its cursor.  The
;;   file is opened safely: only safe local variables (a `.dir-locals.el' an agent wrote never asks and never runs),
;;   no large-file question (a large file opens the way the large-files module decides), no language server.  When the
;;   hub says the file changed it is refreshed in place (`insert-file-contents' with REPLACE keeps point and markers
;;   where the text is unchanged), and the window recentres only when the cursor leaves its middle third.
;; - Navigation in the window detaches it ("Paused following · F resumes"); an edit key says "W takes the wheel from
;;   NAME" and does nothing else; Esc or `q' ends following and closes the window.
;; - `drgnx-agents-follow-start' with HERE follows in the window you are in, and stops on any command there.
;; Redisplay reads only the header strings built here when an event arrives.
;; See docs/guide/agents-in-the-editor.md and docs/develop/agents-editor.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-hub-client)
(require 'drgnx-large-file)
(require 'drgnx-no-prompt)
(require 'drgnx-hooks)

(declare-function drgnx-agents-editor-here--name "drgnx-agents-editor-here")
(declare-function drgnx-agents-editor-fact "drgnx-agents-editor")
(declare-function drgnx-agent-session-remote "drgnx-agents")
(declare-function drgnx-work-live-file-mode "drgnx-work-space")
(declare-function drgnx-agents-here--row-at-point "drgnx-agents-editor-here")
(defvar drgnx-work-live-file--agent)
(defvar drgnx-agent-panel--session)
(declare-function drgnx-agents-editor-line--nearest "drgnx-agents-editor-line")
(declare-function drgnx-agents-editor-line--symbol "drgnx-agents-editor-line")
(declare-function drgnx-agents-editor-frame "drgnx-agents-editor")
(declare-function drgnx-agents-editor-watched-buffers "drgnx-agents-editor")
(declare-function drgnx-agents-editor-draw--apply "drgnx-agents-editor-draw")
(declare-function drgnx-agent-panel-open "drgnx-agent-panel")
(declare-function drgnx-hub--call-on "drgnx-hub-client")
(defvar drgnx-hub--events)
(defvar drgnx-agents-editor-followed)
(defvar drgnx-agents-editor-line--entries)
(defvar drgnx-hub-event-functions)
(defvar drgnx-hub-connected-functions)

(defvar drgnx-agents-follow--session nil "The hub session id followed, or nil.")
(defvar drgnx-agents-follow--view nil "The follow window's view id at the hub, or nil.")
(defvar drgnx-agents-follow--window nil "The window that shows the followed agent's file.")
(defvar drgnx-agents-follow--here nil "Non-nil while following in the window you work in (it stops on any command there).")
(defvar drgnx-agents-follow--detached nil "Non-nil while you have taken the window somewhere else (`F' resumes).")
(defvar drgnx-agents-follow--finished nil "Non-nil once the followed agent's turn ended.")
(defvar drgnx-agents-follow--last nil "The last `agent-follow' data (a plist).")
(defvar drgnx-agents-follow--own nil "The buffers this file opened for following (killed with the follow when unmodified).")
(defvar drgnx-agents-follow--count 0)
(defvar-local drgnx-agents-follow--was-read-only nil "The buffer's read-only state before `drgnx-agents-follow-mode'.")

;;;; The follow buffer's mode

(defvar drgnx-agents-follow-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [remap self-insert-command] #'drgnx-agents-follow-edit-hint)
    (define-key m [remap newline] #'drgnx-agents-follow-edit-hint)
    (define-key m [remap delete-char] #'drgnx-agents-follow-edit-hint)
    (define-key m [remap delete-backward-char] #'drgnx-agents-follow-edit-hint)
    (define-key m [remap kill-line] #'drgnx-agents-follow-edit-hint)
    (define-key m [remap kill-word] #'drgnx-agents-follow-edit-hint)
    (define-key m [remap backward-kill-word] #'drgnx-agents-follow-edit-hint)
    (define-key m [remap kill-region] #'drgnx-agents-follow-edit-hint)
    (define-key m [remap yank] #'drgnx-agents-follow-edit-hint)
    (define-key m [remap undo] #'drgnx-agents-follow-edit-hint)
    (define-key m [remap open-line] #'drgnx-agents-follow-edit-hint)
    (define-key m [remap indent-for-tab-command] #'drgnx-agents-follow-edit-hint)
    m)
  "Keys of a followed agent's file: an edit key only says how to take the wheel.  The key profiles bind the commands
\(`agents-follow-resume', `agents-follow-stop', `agents-follow-panel', `agents-follow-wheel').")

(define-minor-mode drgnx-agents-follow-mode
  "A file followed in a follow window: read-only until you hold the wheel; navigation detaches the follow."
  :lighter " follow" :keymap drgnx-agents-follow-mode-map
  (if drgnx-agents-follow-mode
      (progn (setq drgnx-agents-follow--was-read-only buffer-read-only buffer-read-only t)
             (add-hook 'post-command-hook #'drgnx-agents-follow--after-command nil t))
    (remove-hook 'post-command-hook #'drgnx-agents-follow--after-command t)
    (setq buffer-read-only drgnx-agents-follow--was-read-only)))

(defconst drgnx-agents-follow--own-commands
  '(drgnx-agents-follow-edit-hint drgnx-agents-follow-resume drgnx-agents-follow-stop drgnx-agents-follow-panel
                                  drgnx-agents-follow-wheel)
  "The commands of the follow window that are not navigation.")

(defun drgnx-agents-follow--after-command ()
  "`post-command-hook' of a follow buffer: any command that is not the window's own detaches the follow."
  (when (and drgnx-agents-follow--session (not drgnx-agents-follow--detached)
             (eq (selected-window) drgnx-agents-follow--window)
             (not (memq this-command drgnx-agents-follow--own-commands)))
    (setq drgnx-agents-follow--detached t)
    (drgnx-agents-follow--header)))

(defun drgnx-agents-follow--here-after-command ()
  "`post-command-hook' while following in your own window: any command in it ends the follow."
  (when (and drgnx-agents-follow--session (eq (selected-window) drgnx-agents-follow--window)
             (not (eq this-command 'drgnx-agents-follow-here-command)))
    (drgnx-agents-follow-stop)))

(defun drgnx-agents-follow--name ()
  (drgnx-agents-editor-here--name drgnx-agents-follow--session))

(defun drgnx-agents-follow-edit-hint ()
  "In a followed file an edit key does not edit: say how to take the wheel.  Once you hold the wheel it edits."
  (interactive)
  (if (and buffer-read-only drgnx-agents-follow--session)
      (message "W takes the wheel from %s" (drgnx-agents-follow--name))
    (call-interactively (or this-original-command 'self-insert-command))))

;;;; Opening and refreshing

(defun drgnx-agents-follow--open (file)
  "The buffer visiting FILE for following.  Only safe local variables apply (nothing asks, no `eval' runs), a large
file is opened the way the large-files module decides without asking, and no language server starts.  A buffer you
already have is used as it is."
  (or (get-file-buffer file)
      (let ((enable-local-variables :safe) (enable-local-eval nil) (large-file-warning-threshold nil)
            (drgnx-large-file-open 'auto))
        (cl-letf (((symbol-function 'eglot-ensure) #'ignore))
          (let ((buffer (find-file-noselect file t)))
            (push buffer drgnx-agents-follow--own)
            buffer)))))

(defun drgnx-agents-follow--refresh (buffer file)
  "BUFFER reads FILE again, in place: point and markers stay where the text is unchanged."
  (with-current-buffer buffer
    (unless (or (buffer-modified-p) (memq drgnx-large-file '(chunks)))
      (let ((inhibit-read-only t))
        ;; the file did change on disk, that is why we read it: the modtime is current before the read, or it asks
        (set-visited-file-modtime)
        (insert-file-contents file nil nil nil t)
        (set-visited-file-modtime)
        (set-buffer-modified-p nil)))))

(defun drgnx-agents-follow--pos (buffer line col)
  "The position of LINE and COL (1-based; either may be nil) in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (when line (forward-line (1- line)))
      (when (and col (> col 1)) (forward-char (min (1- col) (- (pos-eol) (point)))))
      (point))))

(defun drgnx-agents-follow--show (buffer)
  "Show BUFFER in the follow window, made when there is none."
  (let ((w drgnx-agents-follow--window))
    (cond ((window-live-p w) (unless (eq (window-buffer w) buffer) (set-window-buffer w buffer)))
          (t (setq w (display-buffer buffer '((display-buffer-in-side-window display-buffer-pop-up-window)
                                              (side . right) (window-width . 0.4))))
             (setq drgnx-agents-follow--window w)))
    w))

(defun drgnx-agents-follow--moved (data)
  "The hub says where the followed agent is now (DATA, an `agent-follow' event)."
  (setq drgnx-agents-follow--last data drgnx-agents-follow--finished nil)
  (when-let* ((file (plist-get data :file)))
    (let* ((window drgnx-agents-follow--window)
           (current (and (window-live-p window) (window-buffer window)))
           (same (and current (equal (buffer-file-name current) file)))
           (buffer (if same current (and (not drgnx-agents-follow--detached) (drgnx-agents-follow--open file)))))
      (when buffer
        (when (and (plist-get data :changed) (buffer-file-name buffer)) (drgnx-agents-follow--refresh buffer file))
        (unless drgnx-agents-follow--detached
          (when (and (not drgnx-agents-follow--here) (memq buffer drgnx-agents-follow--own)
                     (not (buffer-local-value 'drgnx-agents-follow-mode buffer)))
            (with-current-buffer buffer (drgnx-agents-follow-mode 1)))
          (let* ((w (drgnx-agents-follow--show buffer))
                 (pos (drgnx-agents-follow--pos buffer (plist-get data :line) (plist-get data :col))))
            (with-current-buffer buffer (goto-char pos))
            (set-window-point w pos)
            (drgnx-agents-follow--recentre w pos))))))
  (drgnx-agents-follow--header))

(defun drgnx-agents-follow--recentre (window pos)
  "Scroll WINDOW so POS shows, but only when POS has left the window's middle third."
  (let* ((h (window-body-height window))
         (rel (with-current-buffer (window-buffer window)
                (count-lines (window-start window) pos))))
    (unless (and (pos-visible-in-window-p pos window) (>= rel (/ h 3)) (< rel (* 2 (/ h 3))))
      (set-window-start window (with-current-buffer (window-buffer window)
                                 (save-excursion (goto-char pos) (forward-line (- (/ h 2))) (point)))))))

;;;; The probe

(defun drgnx-agents-follow-probe (file n)
  "Time N follow moves of the followed agent through FILE, and one refresh of it: (MOVES . REFRESH), milliseconds.
The probe for `agents-follow-tick' (a follow move 2 ms; a 3,000-line refresh reported, 8 ms at most); the verdict
waits for the gate.  The follow must be started (`drgnx-agents-follow-start') and its window shown."
  (let (moves)
    (dotimes (i n)
      (let ((data (list :file file :line (1+ (mod i 3000)) :col 1 :mode "read")))
        (push (* 1000 (car (benchmark-run 1 (drgnx-agents-follow--moved data)))) moves)))
    (let ((buffer (drgnx-agents-follow--open file)))
      (cons (nreverse moves)
            (* 1000 (car (benchmark-run 1 (drgnx-agents-follow--refresh buffer file))))))))

;;;; The header

(defconst drgnx-agents-follow--modes
  '(("listed" . "searching") ("read" . "reading") ("pending" . "about to edit") ("write" . "writing") ("edit" . "editing"))
  "The feed's mode → the words of the header.")

(defun drgnx-agents-follow--header ()
  "Set the follow window's header line from the last move: built here, shown by redisplay as a plain string."
  (when (window-live-p drgnx-agents-follow--window)
    (let* ((d drgnx-agents-follow--last) (name (drgnx-agents-follow--name))
           (mode (or (cdr (assoc (plist-get d :mode) drgnx-agents-follow--modes)) "here"))
           (buffer (window-buffer drgnx-agents-follow--window))
           (sym (and d (plist-get d :line) (fboundp 'drgnx-agents-editor-line--symbol)
                     (drgnx-agents-editor-line--symbol buffer (drgnx-agents-follow--pos buffer (plist-get d :line) nil))))
           (why (or (plist-get d :plan_entry) (plist-get d :step_title)))
           (text (cond (drgnx-agents-follow--detached "Paused following · F resumes")
                       (drgnx-agents-follow--finished (format "%s finished · o panel · q close" name))
                       (t (format "Following %s · %s%s%s   Esc stop · W take the wheel · o panel" name mode
                                  (if sym (concat " " sym) "")
                                  (if (and why (not (string-empty-p why)))
                                      (format " — '%s'" (truncate-string-to-width why 60 nil nil "…"))
                                    ""))))))
      (set-window-parameter drgnx-agents-follow--window 'header-line-format
                            (replace-regexp-in-string "%" "%%" (concat " " text) t t)))))

;;;; Starting and stopping

(defun drgnx-agents-follow--send (method params)
  "Ask the hub METHOD with PARAMS on the subscribed connection: the follow feed goes to the connection that asked for it."
  (if (process-live-p drgnx-hub--events)
      (drgnx-hub--call-on drgnx-hub--events method params #'ignore)
    (drgnx-hub-call method params #'ignore)))

(defun drgnx-agents-follow--tags ()
  "The followed agent's name tag is on, or off: draw the watched buffers again."
  (dolist (b (drgnx-agents-editor-watched-buffers))
    (when-let* ((f (drgnx-agents-editor-frame b))) (drgnx-agents-editor-draw--apply b f))))

(defun drgnx-agents-follow-start (session &optional here)
  "Follow hub SESSION in a window on the right, or with HERE in the window you work in.  Another agent switches it."
  (when drgnx-agents-follow--session (drgnx-agents-follow-stop))
  (setq drgnx-agents-follow--session session
        drgnx-agents-follow--view (format "follow:%d" (cl-incf drgnx-agents-follow--count))
        drgnx-agents-follow--here here
        drgnx-agents-follow--detached nil drgnx-agents-follow--finished nil drgnx-agents-follow--last nil
        drgnx-agents-follow--window (and here (selected-window))
        drgnx-agents-editor-followed session)
  (when here (add-hook 'post-command-hook #'drgnx-agents-follow--here-after-command))
  (drgnx-agents-follow--call)
  (drgnx-agents-follow--tags))

(defun drgnx-agents-follow--call ()
  (when drgnx-agents-follow--session
    (condition-case nil
        (drgnx-agents-follow--send "agents/follow"
                                   (list :view drgnx-agents-follow--view :session drgnx-agents-follow--session))
      (error nil))))

(defun drgnx-agents-follow-stop ()
  "End following: tell the hub, close the window and the files this opened, let the name tag go."
  (interactive)
  (when drgnx-agents-follow--session
    (condition-case nil
        (drgnx-agents-follow--send "agents/unfollow" (list :view drgnx-agents-follow--view))
      (error nil)))
  (remove-hook 'post-command-hook #'drgnx-agents-follow--here-after-command)
  (when (window-live-p drgnx-agents-follow--window)
    (set-window-parameter drgnx-agents-follow--window 'header-line-format nil)
    (unless (or drgnx-agents-follow--here (not (window-deletable-p drgnx-agents-follow--window)))
      (delete-window drgnx-agents-follow--window)))
  (dolist (b drgnx-agents-follow--own)
    (when (buffer-live-p b)
      (with-current-buffer b (when drgnx-agents-follow-mode (drgnx-agents-follow-mode -1)))
      (unless (or (buffer-modified-p b) (get-buffer-window-list b nil t)) (kill-buffer b))))
  (setq drgnx-agents-follow--session nil drgnx-agents-follow--view nil drgnx-agents-follow--window nil
        drgnx-agents-follow--here nil drgnx-agents-follow--detached nil drgnx-agents-follow--finished nil
        drgnx-agents-follow--last nil drgnx-agents-follow--own nil
        drgnx-agents-editor-followed nil)
  (drgnx-agents-follow--tags))

(defun drgnx-agents-follow-resume ()
  "Follow the agent again: jump to where it is."
  (interactive)
  (unless drgnx-agents-follow--session (user-error "Not following an agent"))
  (setq drgnx-agents-follow--detached nil)
  (when-let* ((d drgnx-agents-follow--last)) (drgnx-agents-follow--moved d))
  (drgnx-agents-follow--header))

(declare-function drgnx-agent-panel-huddle-of "drgnx-agent-panel-huddle")
(declare-function drgnx-agent-panel-huddle-open-thread "drgnx-agent-panel-huddle")

(defun drgnx-agents-follow-panel ()
  "Open the followed agent's panel, or the huddle it is in when one is open (a conflict range's hover says so)."
  (interactive)
  (unless drgnx-agents-follow--session (user-error "Not following an agent"))
  (if (fboundp 'drgnx-agent-panel-open)
      (if-let* ((rec (and (fboundp 'drgnx-agent-panel-huddle-of)
                          (drgnx-agent-panel-huddle-of drgnx-agents-follow--session))))
          (drgnx-agent-panel-huddle-open-thread rec)
        (drgnx-agent-panel-open drgnx-agents-follow--session))
    (user-error "The agent panel is not loaded")))

(defun drgnx-agents-follow--session-at-point ()
  "The session of the agent nearest point in this buffer."
  (or (and (boundp 'drgnx-agents-editor-line--entries)
           (nth 2 (drgnx-agents-editor-line--nearest drgnx-agents-editor-line--entries (point))))
      (user-error "No agent here")))

(defun drgnx-agents-follow-here-command ()
  "Follow the agent nearest point in the window you are in; any command there stops it."
  (interactive)
  (drgnx-agents-follow-start (drgnx-agents-follow--session-at-point) t))

;;;; Take and give the wheel

(defvar drgnx-agents-follow--wheel (make-hash-table :test 'equal)
  "Session id → (:state stopping|held :buffers (BUFFER…)): the wheels this editor is taking or holds.  Bounded by the
sessions you took a wheel of; an entry goes when the hub says the wheel is free.")
(defvar drgnx-agents-follow--unsaved nil "The files the last `wheel-save' could not save.")

(defun drgnx-agents-follow--held-p (session)
  (or (eq (plist-get (gethash session drgnx-agents-follow--wheel) :state) 'held)
      (equal (drgnx-agents-editor-fact session :held_by) "user")))

(defun drgnx-agents-follow--wheel-session ()
  "The session whose wheel a wheel key means here: the followed file's, a live file's, the panel's, a who-is-here row's."
  (or (and (bound-and-true-p drgnx-agents-follow-mode) drgnx-agents-follow--session)
      (and (bound-and-true-p drgnx-work-live-file--agent) (drgnx-agent-session-remote drgnx-work-live-file--agent))
      (and (derived-mode-p 'drgnx-agent-panel-mode) drgnx-agent-panel--session)
      (and (derived-mode-p 'drgnx-agents-here-mode) (car (drgnx-agents-here--row-at-point)))
      drgnx-agents-follow--session
      (user-error "No agent to take the wheel from here")))

(defun drgnx-agents-take-wheel (&optional session)
  "Take the wheel of SESSION (default: the agent of this file, follow window, panel or who-is-here row): it stops after
its current step, this buffer stays read-only until the hub says it is held, then it is yours.  While you hold it,
this gives the wheel back."
  (interactive)
  (let ((sid (or session (drgnx-agents-follow--wheel-session))))
    (if (drgnx-agents-follow--held-p sid)
        (drgnx-agents-give-wheel sid)
      (let ((buffers (delete-dups (delq nil (list (current-buffer)
                                                  (and (window-live-p drgnx-agents-follow--window)
                                                       (equal sid drgnx-agents-follow--session)
                                                       (window-buffer drgnx-agents-follow--window)))))))
        (puthash sid (list :state 'stopping :buffers buffers) drgnx-agents-follow--wheel)
        (condition-case err
            (drgnx-agents-follow--ask "agents/wheel/take" (list :id sid)
                                      (lambda (error)
                                        (when error
                                          (remhash sid drgnx-agents-follow--wheel)
                                          (message "The wheel was not taken: %s" error))))
          (error (remhash sid drgnx-agents-follow--wheel)
                 (user-error "The wheel was not taken: %s" (error-message-string err))))
        (message "Stopping after %s…"
                 (or (and (equal sid drgnx-agents-follow--session) (plist-get drgnx-agents-follow--last :step_title))
                     "its current step"))))))

(defun drgnx-agents-give-wheel (&optional session)
  "Give SESSION's wheel back: an agent in a worktree of its own first has this editor save that worktree's buffers
\(without asking); the hub then sends it your edits.  A chat's worktree is your checkout, so nothing is saved."
  (interactive)
  (let ((sid (or session (drgnx-agents-follow--wheel-session))))
    (drgnx-agents-follow--ask
     "agents/wheel/give" (list :id sid)
     (lambda (error)
       (if error
           (message "The wheel was not given back: %s%s" error
                    (if drgnx-agents-follow--unsaved
                        (format " (not saved: %s)" (mapconcat #'file-name-nondirectory drgnx-agents-follow--unsaved ", "))
                      ""))
         (setq drgnx-agents-follow--unsaved nil)
         (message "You gave %s's wheel back" (drgnx-agents-editor-here--name sid)))))))

(defun drgnx-agents-follow-wheel ()
  "`W' in the follow window: take the followed agent's wheel, or give it back."
  (interactive)
  (drgnx-agents-take-wheel drgnx-agents-follow--session))

(defun drgnx-agents-follow--ask (method params fn)
  "Ask the hub METHOD with PARAMS; FN gets the error text, or nil.  Not on the subscribed connection: a give waits for
the editor's `agents/wheel/saved', which comes in on that one and would queue behind it."
  (drgnx-hub-call method params (lambda (_result error) (funcall fn error))))

(defun drgnx-agents-follow--editable (buffer editable)
  "BUFFER becomes editable (EDITABLE) or read-only again, the way its mode keeps it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (cond ((bound-and-true-p drgnx-agents-follow-mode) (setq buffer-read-only (not editable)))
            ((and (boundp 'drgnx-work-live-file--agent) drgnx-work-live-file--agent (fboundp 'drgnx-work-live-file-mode))
             (if editable
                 (progn (when (bound-and-true-p drgnx-work-live-file-mode) (drgnx-work-live-file-mode -1))
                        (setq buffer-read-only nil))
               (drgnx-work-live-file-mode 1)))
            (t (setq buffer-read-only (not editable)))))))

(defun drgnx-agents-follow--wheel-event (data)
  "The hub's word on a wheel (`agent-wheel'): held, the buffers you took it from become yours; free, they lock again."
  (let* ((sid (plist-get data :id)) (entry (gethash sid drgnx-agents-follow--wheel)))
    (pcase (plist-get data :state)
      ("held"
       (puthash sid (list :state 'held :buffers (plist-get entry :buffers)) drgnx-agents-follow--wheel)
       (dolist (b (plist-get entry :buffers)) (drgnx-agents-follow--editable b t))
       (message "You hold %s's wheel · W gives it back" (drgnx-agents-editor-here--name sid)))
      ("free"
       (dolist (b (plist-get entry :buffers)) (drgnx-agents-follow--editable b nil))
       (remhash sid drgnx-agents-follow--wheel)))))

(defun drgnx-agents-follow--wheel-save (data)
  "The hub gives the wheel of an agent in a worktree of its own back: save that worktree's modified buffers inside
`drgnx-with-no-prompts', and answer with the files that stayed unsaved."
  (let ((worktree (file-name-as-directory (plist-get data :worktree))) unsaved)
    (dolist (b (buffer-list))
      (let ((file (buffer-file-name b)))
        (when (and file (string-prefix-p worktree file) (buffer-modified-p b))
          (with-current-buffer b
            (let ((why (drgnx-with-no-prompts (save-buffer))))
              (when (or why (buffer-modified-p)) (push file unsaved)))))))
    (setq drgnx-agents-follow--unsaved (nreverse unsaved))
    (condition-case nil
        (drgnx-agents-follow--send "agents/wheel/saved"
                                   (list :req (plist-get data :req) :unsaved (vconcat drgnx-agents-follow--unsaved)))
      (error nil))))

;;;; The feed

(defun drgnx-agents-follow--event (event data)
  "An event from the hub (`drgnx-hub-event-functions')."
  (pcase event
    ("agent-follow"
     (when (and drgnx-agents-follow--view (equal (plist-get data :view) drgnx-agents-follow--view))
       (drgnx-agents-follow--moved data)))
    ("agent"
     (when (and drgnx-agents-follow--session (equal (plist-get data :id) drgnx-agents-follow--session))
       (let ((status (plist-get (plist-get data :session) :status)))
         (setq drgnx-agents-follow--finished (and (member status '("idle" "exited")) t))
         (drgnx-agents-follow--header))))
    ("agent-wheel" (drgnx-agents-follow--wheel-event data))
    ("wheel-save" (drgnx-agents-follow--wheel-save data))))

;;;; Setup

(defun drgnx-agents-follow--frame-replaced (old new)
  "`drgnx-frame-replaced-functions': following goes on in the follow window's counterpart in NEW."
  (when (and (window-live-p drgnx-agents-follow--window) (eq (window-frame drgnx-agents-follow--window) old))
    (setq drgnx-agents-follow--window (drgnx-frame-replaced-window drgnx-agents-follow--window new))))

(defun drgnx-agents-follow-setup ()
  "The follow window's and the wheel's commands and events.  Called by the module's setup."
  (drgnx-module-hook 'drgnx-frame-replaced-functions follow-frame-replaced (old new)
    :module 'tools/agents-in-editor
    (drgnx-agents-follow--frame-replaced old new))
  (drgnx-module-hook 'drgnx-hub-event-functions follow-event (event data)
    :module 'tools/agents-in-editor
    (drgnx-agents-follow--event event data))
  (drgnx-module-hook 'drgnx-hub-connected-functions follow-reconnect ()
    :module 'tools/agents-in-editor
    (drgnx-agents-follow--call))
  (drgnx-command-define 'agents-follow-here :category "Agents" :title "Follow in This Window"
                        :command #'drgnx-agents-follow-here-command
                        :doc "Follow the agent nearest point in the window you work in; any command there stops it")
  (drgnx-command-define 'agents-take-wheel :category "Agents" :title "Take the Wheel from the Agent"
                        :command #'drgnx-agents-take-wheel
                        :doc "The agent stops after its current step and its file becomes yours; again, it gives the wheel back")
  (drgnx-command-define 'agents-give-wheel :category "Agents" :title "Give the Wheel Back"
                        :command #'drgnx-agents-give-wheel
                        :doc "Save the agent's worktree buffers and give the wheel back with your edits")
  (let ((in-follow (lambda () (bound-and-true-p drgnx-agents-follow-mode))))
    (pcase-dolist (`(,id ,title ,fn ,doc)
                   '((agents-follow-resume "Resume Following" drgnx-agents-follow-resume "Jump to the agent and follow it again")
                     (agents-follow-stop "Stop Following" drgnx-agents-follow-stop "End following and close the window")
                     (agents-follow-panel "Open the Followed Agent's Panel" drgnx-agents-follow-panel "The panel of the agent you follow")
                     (agents-follow-wheel "Take or Give Back the Wheel" drgnx-agents-follow-wheel
                                          "Take the followed agent's wheel, or give it back")))
      (drgnx-command-define id :category "Agents" :title title :command fn :doc doc
                            :map 'drgnx-agents-follow-mode-map :when in-follow))))

(defun drgnx-agents-follow-teardown ()
  "End following, forget the wheels."
  (drgnx-agents-follow-stop)
  (clrhash drgnx-agents-follow--wheel)
  (setq drgnx-agents-follow--unsaved nil))

(provide 'drgnx-agents-follow)
;;; drgnx-agents-follow.el ends here
