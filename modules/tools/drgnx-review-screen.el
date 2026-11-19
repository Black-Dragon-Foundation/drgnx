;;; drgnx-review-screen.el --- The review screen: one change, its effect on tasks, its reasons, the actions (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The hub builds the screen's rows (`review-screen/subscribe', runtime/crates/drgnx-ratatoskr/src/view/review_screen.rs):
;; what changed since the last version, the effect on the tasks under way, the reason of each change, then the buttons.
;; This library is the buffer they land in and what its keys do.  `a' accepts the hunk at point (a `review/mark' of that
;; hunk), `D' rejects it (the hunk is marked pending and the agent is told, queued), `A' accepts every hunk of every
;; file, `r' opens a text input and steers the agent through `agents/send' (never a cancel).  Nothing here merges or
;; pushes: those stay on their cards.  The screen is the kind `review-screen' of the layouts' Review preset.
;; Loaded by tools/work-space (drgnx-work-space.el); defines no module.  See docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-view-patch-attach "drgnx-view")
(declare-function drgnx-view-env-register "drgnx-view-env")
(declare-function drgnx-view-env-unregister "drgnx-view-env")
(declare-function drgnx-wb-rows-setup "drgnx-wb")
(declare-function drgnx-ui-kit-text-input "drgnx-ui-kit")
(declare-function drgnx-work-code-one-line "drgnx-work-code")
(defvar drgnx-hub--events)
(defvar drgnx-work-review-mode-map)

(defconst drgnx-review-screen-kind 'review-screen "The kind the layouts' Review preset fills.")

(defvar-local drgnx-review-screen--view nil "The hub view id of this screen.")
(defvar-local drgnx-review-screen--params nil "What `review-screen/subscribe' was given (:session or :doc, :from).")
(defvar-local drgnx-review-screen--session nil "The agent session whose code this screen reviews, or nil (a document).")

(defvar drgnx-review-screen-mode-map
  (let ((m (make-sparse-keymap)))
    (when (boundp 'drgnx-work-review-mode-map) (set-keymap-parent m drgnx-work-review-mode-map))
    m)
  "Keys of the review screen.  The key profiles bind them (`drgnx-command-define' with this map).")

(define-derived-mode drgnx-review-screen-mode special-mode "Review"
  "The review screen: what changed, the effect on tasks, the reasons, then the actions (the hub builds the rows)."
  (setq-local truncate-lines t cursor-type nil mode-line-format nil)
  (buffer-disable-undo)
  (when (fboundp 'drgnx-wb-rows-setup) (drgnx-wb-rows-setup)))

(defun drgnx-review-screen--hub-p ()
  (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events)))

(defun drgnx-review-screen--call (method params &optional then)
  "Ask the hub METHOD with PARAMS; THEN gets the result.  Nothing waits."
  (if (not (drgnx-review-screen--hub-p))
      (message "Review: the hub is not running")
    (drgnx-hub--call-on drgnx-hub--events method params
                        (lambda (result error)
                          (if error (message "Review: %s" (if (stringp error) error (plist-get error :message)))
                            (when then (funcall then result)))))))

(defun drgnx-review-screen--subscribe (&optional _view)
  "Tell the hub this buffer shows its change (at attach, and again on a reconnect)."
  (drgnx-review-screen--call "review-screen/subscribe" (cons :view (cons drgnx-review-screen--view drgnx-review-screen--params))))

(defun drgnx-review-screen-refresh ()
  "Read the change and its effects again."
  (interactive)
  (when drgnx-review-screen--view
    (drgnx-review-screen--call "review-screen/set" (list :view drgnx-review-screen--view :refresh t))))

(defun drgnx-review-screen-open (&rest args)
  "The review screen of a change, made when there is none; returns its buffer without showing it.  ARGS: :session ID
\(the code an agent's session changed) or :doc FILE with :from BLOB (a document against that text; the last commit's
when none)."
  (let* ((id (or (plist-get args :session) (plist-get args :doc)))
         (view (concat "review/" (if (stringp id) (md5 id) "none")))
         (name (format "*Review: %s*" (if (plist-get args :doc) (file-name-nondirectory (plist-get args :doc)) id))))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (drgnx-review-screen-mode)
          (setq drgnx-review-screen--view view
                drgnx-review-screen--params (cl-loop for (k v) on args by #'cddr when v append (list k v))
                drgnx-review-screen--session (plist-get args :session))
          (if (not (fboundp 'nidhogg-view--call))
              (let ((inhibit-read-only t))
                (insert (propertize "  The review screen needs drgnx's own Emacs (Nidhogg).\n" 'face 'shadow)))
            (drgnx-view-patch-attach view "unshown" :sja t)
            (require 'drgnx-view-env)
            (drgnx-view-env-register view (current-buffer) #'drgnx-review-screen--subscribe)
            (drgnx-review-screen--subscribe))
          (current-buffer)))))

(defun drgnx-review-screen-show ()
  "The review screen of the selected agent's code, in this window."
  (interactive)
  (let ((sid (and (fboundp 'drgnx-work-trail--agent-sid) (drgnx-work-trail--agent-sid))))
    (unless sid (user-error "Select an agent to review its work"))
    (pop-to-buffer-same-window (drgnx-review-screen-open :session sid))))

(defun drgnx-review-screen-teardown ()
  "The screens' buffers go, and the hub forgets their views."
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when (derived-mode-p 'drgnx-review-screen-mode)
        (when (drgnx-review-screen--hub-p)
          (drgnx-review-screen--call "review-screen/close" (list :view drgnx-review-screen--view)))
        (when (fboundp 'drgnx-view-env-unregister) (drgnx-view-env-unregister drgnx-review-screen--view))
        (kill-buffer b)))))

;;;; Hunks: accept, reject

(defun drgnx-review-screen--hunk-at-point ()
  "The `drgnx-review-hunk' plist (:path :index :hash :session) of the row at point, or nil."
  (get-text-property (pos-bol) 'drgnx-review-hunk))

(defun drgnx-review-screen--hunks ()
  "Every distinct hunk of the screen, in order."
  (let (out seen (pos (point-min)))
    (while (< pos (point-max))
      (let ((h (get-text-property pos 'drgnx-review-hunk)))
        (when (and h (not (member (list (plist-get h :path) (plist-get h :index)) seen)))
          (push (list (plist-get h :path) (plist-get h :index)) seen)
          (push h out)))
      (setq pos (or (next-single-property-change pos 'drgnx-review-hunk) (point-max))))
    (nreverse out)))

(defun drgnx-review-screen--mark (session hunk state)
  "A `review/mark' of HUNK (a plist of its row) for SESSION in STATE, under the path `PATH#INDEX'."
  (let ((path (plist-get hunk :path)))
    (drgnx-hub-call "review/mark"
                    (list :agent session :path (format "%s#%d" path (plist-get hunk :index)) :state state
                          :hash (plist-get hunk :hash)
                          :event (list :kind (if (equal state "accepted") "accept" "reject")
                                       :summary (format "you %s hunk %d of %s" (if (equal state "accepted") "accepted" "rejected")
                                                        (plist-get hunk :index) path)
                                       :data (list :by "user" :path path :hash (plist-get hunk :hash))))
                    #'ignore)))

(defun drgnx-review-screen-accept-hunk ()
  "Accept the hunk at point: a review mark for that hunk."
  (interactive)
  (let ((h (or (drgnx-review-screen--hunk-at-point) (user-error "Point is not on a hunk")))
        (session (or drgnx-review-screen--session (user-error "This change has no agent to mark"))))
    (drgnx-review-screen--mark session h "accepted")
    (message "Review: hunk %d of %s accepted; nothing is merged" (plist-get h :index) (plist-get h :path))))

(defun drgnx-review-screen-reject-hunk ()
  "Reject the hunk at point: it is marked pending and the agent is told, in a queued message (never a cancel)."
  (interactive)
  (let ((h (or (drgnx-review-screen--hunk-at-point) (user-error "Point is not on a hunk")))
        (session (or drgnx-review-screen--session (user-error "This change has no agent to tell"))))
    (drgnx-review-screen--mark session h "pending")
    (drgnx-hub-call "agents/send"
                    (list :id session
                          :text (format "I reject hunk %d of your change to %s. Please take it back and tell me what you changed instead."
                                        (plist-get h :index) (drgnx-work-code-one-line (plist-get h :path))))
                    #'ignore)
    (message "Review: hunk %d of %s is marked pending and the agent has been told" (plist-get h :index) (plist-get h :path))))

(defun drgnx-review-screen-accept ()
  "Accept: every hunk of every file, each as its own review mark.  Nothing is merged or pushed."
  (interactive)
  (let ((session drgnx-review-screen--session) (hunks (drgnx-review-screen--hunks)))
    (unless session (user-error "This change has no agent to mark"))
    (unless hunks (user-error "Nothing changed here to accept"))
    (dolist (h hunks) (drgnx-review-screen--mark session h "accepted"))
    (message "Review: %d hunk%s accepted; a merge goes through its card" (length hunks) (if (= 1 (length hunks)) "" "s"))))

;;;; Request changes

(defvar-local drgnx-review-request--session nil "The session the open request goes to.")

(defvar drgnx-review-request-mode-map (make-sparse-keymap)
  "Keys of the request input (the key profiles bind them: send and cancel).")

(define-derived-mode drgnx-review-request-mode text-mode "Request changes"
  "The text input of a request for changes: what you write steers the agent through `agents/send'."
  (setq-local header-line-format nil))

(defun drgnx-review-screen-request-changes ()
  "Open a text input for what you want changed; C-c C-c steers the agent with it (queued, never a cancel)."
  (interactive)
  (let ((session (or drgnx-review-screen--session (user-error "This change has no agent to steer"))))
    (with-current-buffer (get-buffer-create "*Request changes*")
      (drgnx-review-request-mode)
      (setq drgnx-review-request--session session)
      (when (fboundp 'drgnx-ui-kit-text-input)
        (let ((lines (drgnx-ui-kit-text-input "What should change?" 'single nil (window-width) 'header-line t)))
          (setq header-line-format (concat (car (car lines)) (cdr (car lines))))))
      (pop-to-buffer (current-buffer)))))

(defun drgnx-review-request-send ()
  "Send the text to the agent as a steer: `agents/send' queues it; the agent is not cancelled."
  (interactive)
  (let ((text (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
    (when (string-empty-p text) (user-error "Write what should change first"))
    (drgnx-hub-call "agents/send"
                    (list :id drgnx-review-request--session
                          :text (format "Changes requested on your work: %s" (drgnx-work-code-one-line text)))
                    #'ignore)
    (message "Review: your request was sent to the agent")
    (quit-window t)))

(defun drgnx-review-request-cancel ()
  "Drop the request."
  (interactive)
  (quit-window t))

(provide 'drgnx-review-screen)
;;; drgnx-review-screen.el ends here
