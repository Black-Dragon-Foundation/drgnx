;;; drgnx-live.el --- Module tools/live: the Live view of an agent's browser (dormant until a later update) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; drgnx no longer starts a browser for agents: agents' browsers run inside their sandboxes
;; (docs/guide/agent-browser.md).  The Live view opens and says that watching comes with a later update.
;; Its CDP screencast client (tabs, frames, Take Over) is kept as it was, frozen, until that update
;; replaces it; nothing in the product connects it now.
;; See docs/guide/live.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-paths)
(require 'drgnx-modal)
(require 'drgnx-timer)
(require 'drgnx-memo)
(require 'drgnx-state)

(declare-function websocket-open "websocket")
(declare-function websocket-send-text "websocket")
(declare-function websocket-close "websocket")
(declare-function websocket-openp "websocket")
(declare-function websocket-frame-text "websocket")
;; only in an Emacs with image support (Homebrew's terminal Emacs has none): each call is in `ignore-errors'
(declare-function image-flush "image.c" (spec &optional frame))
(declare-function evil-emacs-state "evil-states")
(declare-function evil-change-to-previous-state "evil-core")

(defvar drgnx-live-frame-interval 0.1 "Seconds between two drawn frames at most (about 10 a second); frames between are dropped.")
(defconst drgnx-live-buffer-name "*drgnx live*")
(defconst drgnx-live--dormant-text
  "Watching an agent's browser arrives with a later drgnx update; agents' browsers now run inside their sandboxes (docs/guide/agent-browser.md)"
  "What the Live view says while it has nothing to watch.")

;;;; The connection (in the Live view's buffer)

(defvar-local drgnx-live--ws nil "The websocket to the browser.")
(defvar-local drgnx-live--endpoint nil "The browser this view watches: (:port :ws).")
(defvar-local drgnx-live--next-id 0)
(defvar-local drgnx-live--callbacks nil "Request id → function of the result.")
(defvar-local drgnx-live--targets nil "The browser's pages: target plists, in order.")
(defvar-local drgnx-live--target nil "The watched page's targetId.")
(defvar-local drgnx-live--session nil "The flat CDP session on the watched page.")

(drgnx-epoch-define 'live-tabs :per 'buffer
                    :doc "Raised in a Live view when its tabs, the watched tab or taking over change (the header shows them).")
(drgnx-memo-define live-header :on buffer :keys ((drgnx-epoch 'live-tabs object))
                   :doc "A Live view's header line, built again only when its tabs, the watched tab or driving change.")

(defun drgnx-live--tabs-changed ()
  "The tabs, the watched tab or driving changed in this buffer: the header is built again."
  (drgnx-epoch-bump 'live-tabs (current-buffer)))
(defvar-local drgnx-live--status nil "What the view says about the connection (a string), or nil.")
(defvar-local drgnx-live--closing nil "Non-nil while the view closes its own connection.")
(defvar-local drgnx-live--pending nil "The newest frame not yet drawn (see `drgnx-live--on-frame').")
(defvar-local drgnx-live--meta nil "The shown frame's metadata (page size in CSS pixels).")
(defvar-local drgnx-live--image nil "The shown image.")
(defvar-local drgnx-live--drawn 0 "Frames drawn.")
(defvar-local drgnx-live--dropped 0 "Frames replaced by a newer one before they were drawn.")
(defvar-local drgnx-live--ready nil "Non-nil once the browser listed its pages (a page created later is a new tab).")
(defvar-local drgnx-live--paused nil "Non-nil while the screencast is stopped because no window shows the view.")
(defvar-local drgnx-live--max-width nil "The width in pixels the screencast was asked for (the view's window's).")

(defun drgnx-live--send (method &optional params session callback)
  "Send METHOD with PARAMS (on flat SESSION); CALLBACK gets the result.  Nothing when the connection is gone."
  (when (and drgnx-live--ws (websocket-openp drgnx-live--ws))
    (let ((id (cl-incf drgnx-live--next-id)))
      (when callback (push (cons id callback) drgnx-live--callbacks))
      (websocket-send-text drgnx-live--ws
                           (json-serialize (append (list :id id :method method :params (or params (make-hash-table)))
                                                   (and session (list :sessionId session)))))
      id)))

(defun drgnx-live--in (buf fn &rest args)
  "Call FN with ARGS in BUF while it lives (websocket callbacks)."
  (when (buffer-live-p buf) (with-current-buffer buf (apply fn args))))

(defun drgnx-live--open (buf endpoint)
  "Connect BUF's view to the browser at ENDPOINT (:port :ws).  Says why when it cannot; never waits for it."
  (require 'websocket)
  (with-current-buffer buf
    (drgnx-live--disconnect)
    (setq drgnx-live--endpoint endpoint drgnx-live--targets nil drgnx-live--target nil drgnx-live--session nil
          drgnx-live--callbacks nil drgnx-live--pending nil drgnx-live--meta nil drgnx-live--drawn 0 drgnx-live--dropped 0
          drgnx-live--ready nil drgnx-live--paused nil
          drgnx-live--status (format "Connecting to the browser for agents (127.0.0.1:%d)…" (plist-get endpoint :port)))
    (drgnx-live--tabs-changed)
    (drgnx-live--render-notes)
    (condition-case err
        (setq drgnx-live--ws
              (websocket-open (plist-get endpoint :ws)
                              :on-open (lambda (_ws) (drgnx-live--in buf #'drgnx-live--opened))
                              :on-message (lambda (_ws frame) (drgnx-live--in buf #'drgnx-live--message (websocket-frame-text frame)))
                              :on-close (lambda (_ws) (drgnx-live--in buf #'drgnx-live--closed))
                              :on-error (lambda (_ws _type e) (drgnx-live--in buf #'drgnx-live--say (format "Live: %s" (error-message-string e))))))
      (error
       (drgnx-live--say (if (string-match-p "refused" (error-message-string err))
                            (format "Live: 127.0.0.1:%d refused the connection: no browser is listening there"
                                    (plist-get endpoint :port))
                          (format "Live: cannot reach the browser at 127.0.0.1:%d: %s" (plist-get endpoint :port) (error-message-string err))))))))

(defun drgnx-live--say (text)
  "Show TEXT as the view's status, and in the echo area."
  (setq drgnx-live--status text)
  (drgnx-live--render-notes)
  (message "%s" text))

(defun drgnx-live--disconnect ()
  (when drgnx-live--ws
    (let ((drgnx-live--closing t) (ws drgnx-live--ws))
      (setq drgnx-live--ws nil)
      (ignore-errors (websocket-close ws))))
  (drgnx-timer-cancel (cons 'live-draw (current-buffer)))
  (drgnx-timer-cancel (cons 'live-notes (current-buffer)))
  (when drgnx-live--image (ignore-errors (image-flush drgnx-live--image t)) (setq drgnx-live--image nil)))

(defun drgnx-live--opened ()
  (setq drgnx-live--status nil)
  (drgnx-live--send "Target.setDiscoverTargets" '(:discover t))
  (drgnx-live--send "Target.getTargets" nil nil
                    (lambda (r)
                      ;; the pages Chrome announced as discovery started are these: one attach, to the first
                      (setq drgnx-live--targets (seq-filter #'drgnx-live--page-p (append (plist-get r :targetInfos) nil))
                            drgnx-live--ready t)
                      (drgnx-live--tabs-changed)
                      (cond (drgnx-live--target)
                            (drgnx-live--targets (drgnx-live--watch (plist-get (car drgnx-live--targets) :targetId)))
                            (t (drgnx-live--say "Live: the browser has no page open yet")))
                      (drgnx-live--render-notes))))

(defun drgnx-live--closed ()
  (unless drgnx-live--closing
    (setq drgnx-live--ws nil)
    (drgnx-live--say "Live: the browser closed the connection (it exited or was stopped); g connects again")))

(defun drgnx-live--page-p (target) (equal (plist-get target :type) "page"))

(defvar-local drgnx-live--seen-window nil
  "The window of the last state-store event about this view (`drgnx-live--shown-again', `drgnx-live--resized').")

(defun drgnx-live--window ()
  "The window showing the view: the one the store last reported while it still shows the view, else the first
window the store records as showing it (any frame), else nil."
  (let ((buf (current-buffer)) (found nil))
    (if (and (window-live-p drgnx-live--seen-window) (eq (window-buffer drgnx-live--seen-window) buf))
        drgnx-live--seen-window
      (dolist (f (drgnx-state-frames))
        (dolist (w (drgnx-state-windows f))
          (when (and (not found) (eq (window-buffer w) buf)) (setq found w))))
      found)))

(defun drgnx-live--watch (target-id)
  "Screencast the page TARGET-ID (instead of the one watched)."
  (when drgnx-live--session
    (drgnx-live--send "Page.stopScreencast" nil drgnx-live--session)
    (drgnx-live--send "Target.detachFromTarget" (list :sessionId drgnx-live--session)))
  (setq drgnx-live--target target-id drgnx-live--session nil)
  (drgnx-live--tabs-changed)
  (let ((buf (current-buffer)))
    (drgnx-live--send "Target.attachToTarget" (list :targetId target-id :flatten t) nil
                      (lambda (r)
                        (drgnx-live--in buf (lambda ()
                                              (when (equal drgnx-live--target target-id)
                                                (setq drgnx-live--session (plist-get r :sessionId))
                                                (drgnx-live--start-screencast)))))))
  (force-mode-line-update))

(defun drgnx-live--start-screencast ()
  "Screencast the watched page: jpeg, quality 60, as wide as the view's window."
  (setq drgnx-live--paused nil
        drgnx-live--max-width (let ((w (drgnx-live--window))) (if w (window-body-width w t) 1280)))
  (drgnx-live--send "Page.startScreencast" (list :format "jpeg" :quality 60 :maxWidth drgnx-live--max-width)
                    drgnx-live--session))

(defun drgnx-live--follow-width ()
  "The screencast starts again as wide as the view's window is now, so the browser scales the page once instead
of Emacs scaling every frame it draws."
  (when-let* ((w (drgnx-live--window)))
    (when (and drgnx-live--session (not drgnx-live--paused) drgnx-live--max-width
               (/= (window-body-width w t) drgnx-live--max-width))
      (drgnx-live--send "Page.stopScreencast" nil drgnx-live--session)
      (drgnx-live--start-screencast))))

(defun drgnx-live--view-windows (data)
  "One window for each Live view that DATA (a state-store event) concerns: the window the event names when it
shows a view, and the frame's other windows showing a view.  The frame's windows too, because the store hands an
idle subscriber one event for each frame and kind, the last one: a divider moved between two editor windows
reports one of them."
  (let ((out nil) (seen nil)
        (named (or (plist-get data :windows) (list (plist-get data :window))))
        (frame (plist-get data :frame)))
    (dolist (w (if (frame-live-p frame) (append named (drgnx-state-windows frame)) named))
      (when (window-live-p w)
        (let ((buf (window-buffer w)))
          (when (and (not (memq buf seen)) (eq 'drgnx-live-mode (buffer-local-value 'major-mode buf)))
            (push buf seen)
            (push w out)))))
    (nreverse out)))

(defun drgnx-live--resized (data)
  "A window of the view changed size (`pane-resized'): the screencast follows its width."
  (dolist (w (drgnx-live--view-windows data))
    (with-current-buffer (window-buffer w)
      (setq drgnx-live--seen-window w)
      (drgnx-live--follow-width))))

(defun drgnx-live--shown-again (data)
  "The view is in a window again (`windows-changed'): its screencast resumes, or follows the width of the window
it is in now."
  (dolist (w (drgnx-live--view-windows data))
    (with-current-buffer (window-buffer w)
      (setq drgnx-live--seen-window w)
      (if (and drgnx-live--paused drgnx-live--session) (drgnx-live--start-screencast) (drgnx-live--follow-width)))))

(defun drgnx-live--message (text)
  "One message from the browser: an answer or an event."
  (if-let* ((frame (drgnx-live--peek-frame text)))
      (drgnx-live--on-frame frame)
    (drgnx-live--parsed-message text)))

(defun drgnx-live--peek-frame (text)
  "TEXT, a screencast frame's message, read without the JSON parser: (:session S :id N :text TEXT :start B :end E
:meta-json M) — the flat session, the frame's id, where its base64 data is in TEXT, its metadata's JSON.  Nil for any
other message, and for one this cannot read safely (an escape inside the data): the parser reads those.  A busy page
sends a frame of ~150 kB many times a second; only the one drawn is decoded (`drgnx-live--frame-data')."
  (when-let* (((string-search "\"method\":\"Page.screencastFrame\"" text))   ; base64 has no quote: never inside the data
              (b (string-search "\"data\":\"" text))
              (start (+ b 8))
              (end (string-search "\"" text start))
              ((let ((bs (string-search "\\" text start))) (or (null bs) (> bs end))))
              (rest (concat (substring text 0 b) (substring text end)))
              (session (and (string-match "\"sessionId\":\"\\([^\"]*\\)\"" rest) (match-string 1 rest)))
              (id (and (string-match "\"sessionId\":\\([0-9]+\\)" rest) (string-to-number (match-string 1 rest)))))
    (list :session session :id id :text text :start start :end end
          :meta-json (and (string-match "\"metadata\":\\({[^{}]*}\\)" rest) (match-string 1 rest)))))

(defun drgnx-live--frame-data (frame)
  "FRAME's image bytes (decoded only now: for the frame that is drawn)."
  (base64-decode-string (or (plist-get frame :data)
                            (substring (plist-get frame :text) (plist-get frame :start) (plist-get frame :end)))))

(defun drgnx-live--frame-meta (frame)
  "FRAME's metadata, a plist (page size in CSS pixels)."
  (or (plist-get frame :meta)
      (and (plist-get frame :meta-json)
           (json-parse-string (plist-get frame :meta-json) :object-type 'plist :null-object nil :false-object nil))))

(defun drgnx-live--on-frame (frame)
  "A screencast FRAME (`drgnx-live--peek-frame' or parsed): acknowledged at once (the browser sends the next one);
only the newest waits to be drawn."
  (when (equal (plist-get frame :session) drgnx-live--session)
    (drgnx-live--send "Page.screencastFrameAck" (list :sessionId (plist-get frame :id)) (plist-get frame :session))
    (when drgnx-live--pending (cl-incf drgnx-live--dropped))
    (setq drgnx-live--pending frame)
    (drgnx-live--schedule-draw)))

(defun drgnx-live--parsed-message (text)
  "One message from the browser, through the JSON parser: an answer or an event."
  (let* ((msg (json-parse-string text :object-type 'plist :null-object nil :false-object nil))
         (id (plist-get msg :id)))
    (if id
        (when-let* ((cb (alist-get id drgnx-live--callbacks)))
          (setq drgnx-live--callbacks (assq-delete-all id drgnx-live--callbacks))
          (unless (plist-get msg :error) (funcall cb (plist-get msg :result))))
      (drgnx-live--event (plist-get msg :method) (plist-get msg :params) (plist-get msg :sessionId)))))

(defun drgnx-live--event (method params session)
  (pcase method
    ("Page.screencastFrame"
     (drgnx-live--on-frame (list :session session :id (plist-get params :sessionId)
                                 :data (plist-get params :data) :meta (plist-get params :metadata))))
    ("Target.targetCreated"
     (let ((info (plist-get params :targetInfo)))
       ;; Chrome announces the pages it has as discovery starts: those are listed, not watched; a page created
       ;; later is a new tab, where the agent works
       (when (and (drgnx-live--page-p info)
                  (not (seq-find (lambda (tg) (equal (plist-get tg :targetId) (plist-get info :targetId))) drgnx-live--targets)))
         (setq drgnx-live--targets (append drgnx-live--targets (list info)))
         (drgnx-live--tabs-changed)
         (when drgnx-live--ready (drgnx-live--watch (plist-get info :targetId))))))
    ("Target.targetInfoChanged"
     (let ((info (plist-get params :targetInfo)))
       (setq drgnx-live--targets (mapcar (lambda (tg) (if (equal (plist-get tg :targetId) (plist-get info :targetId)) info tg))
                                         drgnx-live--targets))
       (drgnx-live--tabs-changed)
       (drgnx-live--schedule-notes)
       (force-mode-line-update)))
    ("Target.targetDestroyed"
     (let ((id (plist-get params :targetId)))
       (setq drgnx-live--targets (seq-remove (lambda (tg) (equal (plist-get tg :targetId) id)) drgnx-live--targets))
       (when (equal id drgnx-live--target)
         (setq drgnx-live--session nil)
         (if drgnx-live--targets (drgnx-live--watch (plist-get (car drgnx-live--targets) :targetId))
           (setq drgnx-live--target nil)))
       (drgnx-live--tabs-changed)
       (force-mode-line-update)))))

;;;; Drawing

(defun drgnx-live--schedule-draw ()
  "Draw the pending frame from a timer: off the input path, at most once per `drgnx-live-frame-interval'."
  (drgnx-timer-soon (cons 'live-draw (current-buffer)) 0 #'drgnx-live--draw
                    :min-interval drgnx-live-frame-interval :owner (current-buffer)))

(defun drgnx-live--draw ()
  (when-let* ((frame drgnx-live--pending))
    (setq drgnx-live--pending nil)
    (if (not (drgnx-live--window))
        ;; nobody sees the view: no frames until a window shows it again (`drgnx-live--shown-again')
        (unless drgnx-live--paused
          (setq drgnx-live--paused t)
          (drgnx-live--send "Page.stopScreencast" nil drgnx-live--session))
      (drgnx-live--follow-width)                        ; the window changed size meanwhile: frames as wide as it
      (drgnx-live--draw-frame frame))))

(defun drgnx-live--draw-frame (frame)
  "Show FRAME (see `drgnx-live--on-frame')."
  (setq drgnx-live--meta (drgnx-live--frame-meta frame))
  (let* ((w (drgnx-live--window))
         (old drgnx-live--image)
         (img (create-image (drgnx-live--frame-data frame) 'jpeg t
                            :max-width (if w (window-body-width w t) 1280)))
         (inhibit-read-only t))
    (put-text-property (point-min) (1+ (point-min)) 'display img)
    (setq drgnx-live--image img)
    (cl-incf drgnx-live--drawn)
    ;; an old frame's pixels stay in no cache; the first frame ends the wait the notes mention
    (if old (ignore-errors (image-flush old t)) (drgnx-live--render-notes))))

(defun drgnx-live--schedule-notes ()
  (drgnx-timer-soon (cons 'live-notes (current-buffer)) 0.3 #'drgnx-live--render-notes :owner (current-buffer)))

(defun drgnx-live--render-notes ()
  "The text below the page: the connection's state."
  (let ((inhibit-read-only t))
    (save-excursion
      (when (= (point-min) (point-max)) (insert " \n"))
      (delete-region (+ 2 (point-min)) (point-max))
      (goto-char (point-max))
      (let ((lines (append (and drgnx-live--status (list drgnx-live--status))
                           (and (not drgnx-live--status) (not drgnx-live--image) (list "Waiting for the page's first frame…")))))
        (dolist (l lines) (insert "\n" l))))))

;;;; The view

(defun drgnx-live--header ()
  "The tabs (the watched one in bold), its URL, and DRIVING while you have taken over: the memo `live-header',
built again only when `live-tabs' was bumped (the tabs, the watched tab or driving changed)."
  (drgnx-memo live-header (current-buffer)
              (let ((current (seq-find (lambda (tg) (equal (plist-get tg :targetId) drgnx-live--target)) drgnx-live--targets)))
                (concat " Live  "
                        (mapconcat (lambda (tg)
                                     (let ((title (truncate-string-to-width (let ((x (plist-get tg :title))) (if (and x (not (string-empty-p x))) x (or (plist-get tg :url) "")))
                                                                            24 nil nil "…")))
                                       (if (eq tg current) (propertize title 'face 'bold) title)))
                                   drgnx-live--targets "  │  ")
                        (if current (concat "   " (propertize (or (plist-get current :url) "") 'face 'link)) "")
                        (if (bound-and-true-p drgnx-live-driving-mode)
                            (propertize "   DRIVING — your clicks and keys go to the page" 'face 'warning)
                          "")))))

(defvar drgnx-live-mode-map (make-sparse-keymap) "Keys in the Live view (Live: Take Over / Hand Back).")

(define-derived-mode drgnx-live-mode special-mode "Live"
  "The Live view of an agent's browser (dormant until a later update; docs/guide/live.md)."
  (setq-local header-line-format '(:eval (drgnx-live--header)))
  (setq-local revert-buffer-function (lambda (&rest _) (drgnx-live--say drgnx-live--dormant-text)))
  (setq-local cursor-type nil)
  (add-hook 'kill-buffer-hook #'drgnx-live--killed nil t))

(defun drgnx-live--killed ()
  "The view is closing: the agents hear the user is not driving any more, the connection goes."
  (when (bound-and-true-p drgnx-live-driving-mode) (drgnx-live--drive nil))
  (drgnx-live--disconnect))

(defun drgnx-live-view ()
  "Open the Live view, which says that watching an agent's browser comes with a later update."
  (interactive)
  (let ((buf (get-buffer-create drgnx-live-buffer-name)))
    (with-current-buffer buf (unless (derived-mode-p 'drgnx-live-mode) (drgnx-live-mode)))
    (pop-to-buffer buf)
    (with-current-buffer buf (drgnx-live--say drgnx-live--dormant-text))
    buf))

;;;; Taking over

(defconst drgnx-live--keys
  '((13 "Enter" 13 "\r") (return "Enter" 13 "\r") (9 "Tab" 9) (tab "Tab" 9) (127 "Backspace" 8) (backspace "Backspace" 8)
    (delete "Delete" 46) (escape "Escape" 27) (left "ArrowLeft" 37) (up "ArrowUp" 38) (right "ArrowRight" 39)
    (down "ArrowDown" 40) (home "Home" 36) (end "End" 35) (prior "PageUp" 33) (next "PageDown" 34))
  "Emacs event → CDP key, Windows key code and the text it types.")

(defvar drgnx-live-driving-map
  (let ((m (make-sparse-keymap)))
    (dotimes (i 95) (define-key m (string (+ 32 i)) #'drgnx-live-key))
    (define-key m [remap self-insert-command] #'drgnx-live-key)
    (dolist (k '("RET" "TAB" "DEL" "<return>" "<tab>" "<backspace>" "<delete>" "<escape>" "<left>" "<up>" "<right>"
                 "<down>" "<home>" "<end>" "<prior>" "<next>"))
      (define-key m (kbd k) #'drgnx-live-key))
    (dolist (k '("<down-mouse-1>" "<mouse-1>" "<drag-mouse-1>" "<double-down-mouse-1>" "<double-mouse-1>"
                 "<down-mouse-2>" "<mouse-2>" "<down-mouse-3>" "<mouse-3>" "<wheel-up>" "<wheel-down>" "<mouse-4>" "<mouse-5>"))
      (define-key m (kbd k) #'drgnx-live-mouse))
    m)
  "While you drive: printable keys, RET, TAB, Backspace, Delete, Escape, arrows, Home/End, PgUp/PgDn and the mouse
go to the page; other keys (C-…, M-…) stay Emacs's.")

(define-minor-mode drgnx-live-driving-mode
  "Your clicks, scrolling and typing in the Live view go to the page.
Under Vim keys the view's leader and panel keys are off meanwhile (`drgnx-modal-keys-off'), so SPC, j and k reach
the page; evil's own keys are out of the way in its emacs state."
  :lighter " Driving" :keymap drgnx-live-driving-map
  (setq drgnx-modal-keys-off drgnx-live-driving-mode)
  (when (bound-and-true-p evil-local-mode)
    (if drgnx-live-driving-mode (evil-emacs-state) (evil-change-to-previous-state)))
  (drgnx-modal-set-state drgnx-modal-state)
  (drgnx-live--tabs-changed)
  (force-mode-line-update))

(defun drgnx-live--page-xy (posn)
  "POSN's position on the page in CSS pixels, scaled back from the image as shown; nil off the image."
  (let* ((xy (posn-object-x-y posn)) (wh (posn-object-width-height posn))
         (meta drgnx-live--meta))
    (when (and (posn-image posn) xy wh meta (> (car wh) 0) (> (cdr wh) 0))
      (cons (round (* (car xy) (/ (float (plist-get meta :deviceWidth)) (car wh))))
            (round (* (cdr xy) (/ (float (plist-get meta :deviceHeight)) (cdr wh))))))))

(defun drgnx-live-mouse (event)
  "Send the mouse EVENT to the page, while you drive."
  (interactive "e")
  (let* ((mods (event-modifiers event))
         ;; a drag ends where the mouse was let go: it moves there, then is released there
         (xy (and drgnx-live-driving-mode (drgnx-live--page-xy (if (memq 'drag mods) (event-end event) (event-start event))))))
    (when xy
      (let* ((type (event-basic-type event))
             (button (pcase type ('mouse-2 "middle") ('mouse-3 "right") (_ "left")))
             (base (list :x (car xy) :y (cdr xy))))
        (when (memq 'drag mods)
          (drgnx-live--send "Input.dispatchMouseEvent"
                            (append (list :type "mouseMoved" :button button :buttons (pcase button ("left" 1) ("right" 2) (_ 4))) base)
                            drgnx-live--session))
        (drgnx-live--send
         "Input.dispatchMouseEvent"
         (if (memq type '(wheel-up wheel-down mouse-4 mouse-5))
             (append (list :type "mouseWheel" :deltaX 0 :deltaY (if (memq type '(wheel-down mouse-5)) 100 -100)) base)
           (append (list :type (if (memq 'down mods) "mousePressed" "mouseReleased") :button button
                         :clickCount (cond ((memq 'triple mods) 3) ((memq 'double mods) 2) (t 1)))
                   base))
         drgnx-live--session)))))

(defun drgnx-live-key ()
  "Send the key just typed to the page, while you drive."
  (interactive)
  (when drgnx-live-driving-mode
    (let* ((e last-command-event) (special (assoc e drgnx-live--keys)))
      (pcase-let ((`(,key ,code ,text) (cond (special (cdr special))
                                             ((characterp e) (list (string e) nil (string e))))))
        (when key
          (drgnx-live--send "Input.dispatchKeyEvent"
                            (append (list :type "keyDown" :key key) (and code (list :windowsVirtualKeyCode code))
                                    (and text (list :text text)))
                            drgnx-live--session)
          (drgnx-live--send "Input.dispatchKeyEvent"
                            (append (list :type "keyUp" :key key) (and code (list :windowsVirtualKeyCode code)))
                            drgnx-live--session))))))

(defun drgnx-live-take-over ()
  "Take over the page in the Live view (your input goes to it, the agent is told to wait), or hand it back."
  (interactive)
  (let ((buf (or (and (derived-mode-p 'drgnx-live-mode) (current-buffer)) (get-buffer drgnx-live-buffer-name)
                 (user-error "Live: open the Live view first (Live: Watch Agents' Browser)"))))
    (with-current-buffer buf
      (drgnx-live--drive (not drgnx-live-driving-mode))
      (message (if drgnx-live-driving-mode "Live: you are driving the page (Take Over / Hand Back gives it back)"
                 "Live: the page is the agent's again")))))

(defun drgnx-live--drive (on)
  "Start driving the page in this view (ON), or stop."
  (drgnx-live-driving-mode (if on 1 -1)))

;;;; Module

(defun drgnx-live--define-commands ()
  (pcase-dolist (`(,id ,title ,fn ,doc)
                 '((live-view "Watch Agents' Browser" drgnx-live-view "The Live view of an agent's browser (arrives with a later update)")
                   (live-take-over "Take Over / Hand Back" drgnx-live-take-over
                                   "Your clicks and keys go to the page, or hand it back")))
    (drgnx-command-define id :category "Live" :title title :command fn :doc doc :scope 'window
                          :map (and (eq id 'live-take-over) '(drgnx-live . drgnx-live-mode-map)))))

(defun drgnx-live--subscribe ()
  "The view follows its window through the state store: shown again, resized (idle lane, owned by the module)."
  (drgnx-state-subscribe 'windows-changed #'drgnx-live--shown-again)
  (drgnx-state-subscribe 'pane-resized #'drgnx-live--resized))

(defun drgnx-live--setup ()
  "Follow the view's window through the store, define the commands."
  (drgnx-live--subscribe)
  (drgnx-memo-activate 'live-header)
  (drgnx-live--define-commands))

(drgnx-module-define 'tools/live
                     :doc "Live: the view of an agent's browser (dormant until a later update)."
                     :stage 'idle :packages '(websocket)
                     :setup #'drgnx-live--setup)

(provide 'drgnx-live)
;;; drgnx-live.el ends here
