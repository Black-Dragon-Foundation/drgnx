;;; drgnx-debug-origin.el --- Where did this come from? The origin trail -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The editor's half of the origin trail (docs/guide/debugging.md; docs/develop/debugging.md, "Where did this come
;; from?").  At a recorded stop, Alt-click a name (or `debug-origin') asks the hub where its value came from: the hub
;; replays the run to the stop under a tracer and sends the trail as `debug-origin' events, a level per replay.  The
;; card is the hub's rows; a link opens as a past stop: the file as it ran, the link's line marked, its operands' values.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'thingatpt)
(require 'drgnx-faces)
(require 'drgnx-timer)
(require 'drgnx-debug-timeline (expand-file-name "drgnx-debug-timeline" (file-name-directory (macroexp-file-name))))

(declare-function drgnx-hub-call "drgnx-hub-client")
(defvar drgnx-hub-event-functions)

(defconst drgnx-debug-origin-buffer "*drgnx-debug origin*" "The origin trail's card.")

(defvar drgnx-debug-origin--id nil "The trail the card follows (its id).")
(defvar drgnx-debug-origin--run nil "Its run and stop: (RUN . STOP).")
(defvar drgnx-debug-origin--links nil "Its links (the newest event's), by index.")
(defvar drgnx-debug-origin--rows nil "The card's newest rows (the hub's), drawn soon.")

(defvar drgnx-debug-origin-card-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-1] #'drgnx-debug-origin-click)
    m)
  "The card's mouse: a click on a link opens it.  Its keys come from the key profiles (`:map
drgnx-debug-origin-card-mode-map').")

(define-derived-mode drgnx-debug-origin-card-mode special-mode "Origin"
  "The origin trail of a value at a recorded stop."
  :group 'drgnx
  (setq-local truncate-lines t)
  (buffer-disable-undo))

(defun drgnx-debug-origin--stop ()
  "The recorded stop asked about: (RUN . STOP), from the past stop shown here or the strip's newest, or a user error."
  (let ((past (or drgnx-debug-timeline--past
                  (when-let* ((b (get-buffer drgnx-debug-timeline-past-buffer)))
                    (buffer-local-value 'drgnx-debug-timeline--past b)))))
    (cond (past (cons (plist-get past :run) (plist-get (plist-get past :stop) :index)))
          ((and drgnx-debug-timeline--run drgnx-debug-timeline--stops)
           (cons drgnx-debug-timeline--run (plist-get (car (last drgnx-debug-timeline--stops)) :index)))
          (t (user-error "Open a recorded stop first (Show Stop Timeline)")))))

(defun drgnx-debug-origin--expr-at (pos)
  "The name or dotted path at POS (`item.reserve' on either part), or nil."
  (save-excursion
    (goto-char pos)
    (let ((chars "[:alnum:]_."))
      (skip-chars-backward chars)
      (let ((start (point)))
        (skip-chars-forward chars)
        (let ((s (string-trim (buffer-substring-no-properties start (point)) "\\.+" "\\.+")))
          (and (string-match-p "\\`[[:alpha:]_][[:alnum:]_]*\\(\\.[[:alpha:]_][[:alnum:]_]*\\)*\\'" s) s))))))

(defun drgnx-debug-origin (expr)
  "Where did EXPR's value at the recorded stop come from?  The trail opens in a card, a level per replay."
  (interactive (list (or (drgnx-debug-origin--expr-at (point)) (read-string "Where did this come from: "))))
  (pcase-let ((`(,run . ,stop) (drgnx-debug-origin--stop)))
    (drgnx-hub-call "debug/origin" (list :run run :stop stop :expr expr)
                    (lambda (result error)
                      (if error (message "Origin: %s" (or (plist-get error :message) error))
                        (setq drgnx-debug-origin--id (plist-get result :origin)
                              drgnx-debug-origin--run (cons run stop) drgnx-debug-origin--links nil
                              drgnx-debug-origin--rows
                              (vector (list :key "head" :text (format "Where did %s come from? · replaying" expr))))
                        (drgnx-debug-origin--render)
                        (display-buffer drgnx-debug-origin-buffer))))))

(defun drgnx-debug-origin-click-value (event)
  "Alt-click: where did the value under EVENT come from?"
  (interactive "e")
  (let* ((end (event-end event)) (pos (posn-point end)))
    (with-current-buffer (window-buffer (posn-window end))
      (let ((expr (and pos (drgnx-debug-origin--expr-at pos))))
        (if expr (drgnx-debug-origin expr) (message "No name there"))))))

(defun drgnx-debug-origin--render ()
  "Insert the card's rows in its buffer."
  (with-current-buffer (get-buffer-create drgnx-debug-origin-buffer)
    (unless (derived-mode-p 'drgnx-debug-origin-card-mode) (drgnx-debug-origin-card-mode))
    (let ((inhibit-read-only t) (at (point)))
      (erase-buffer)
      (seq-doseq (row drgnx-debug-origin--rows)
        (insert (drgnx-debug-timeline--row-string row) "\n"))
      (goto-char (min at (point-max))))))

(defun drgnx-debug-origin--event (event data)
  "`drgnx-hub-event-functions': the trail the card follows has a new level (`debug-origin')."
  (when (and (equal event "debug-origin") drgnx-debug-origin--id
             (equal (plist-get data :origin) drgnx-debug-origin--id))
    (when-let* ((links (plist-get data :links))) (setq drgnx-debug-origin--links (append links nil)))
    (when-let* ((rows (plist-get data :rows))) (setq drgnx-debug-origin--rows rows))
    (drgnx-timer-soon 'debug-origin 0.05 #'drgnx-debug-origin--render :min-interval 0.1)))

(defun drgnx-debug-origin--past (link past)
  "PAST (`debug/run/stop''s answer for LINK's file) as LINK's moment: its line marked, its operands as the variables."
  (let ((stop (plist-get past :stop)))
    ;; the new :stop and :capture come first, so `plist-get' finds them before PAST's own
    (append (list :stop (plist-put (copy-sequence stop) :line (plist-get link :line))
                  :capture (list :scopes
                                 (vector (list :scope (list :name (format "At %s" (plist-get link :target)))
                                               :variables
                                               (vconcat
                                                (cons (list :name (plist-get link :target)
                                                            :value (or (plist-get link :value) "?"))
                                                      (mapcar (lambda (o) (list :name (aref o 0) :value (aref o 1)))
                                                              (plist-get link :operands))))))))
            past)))

(defun drgnx-debug-origin-open (index)
  "Open link INDEX of the trail as it ran: the file from the launch snapshot, the line, the values."
  (interactive (list (or (get-text-property (point) 'drgnx-debug-origin-link) (user-error "No link here"))))
  (let ((link (nth index drgnx-debug-origin--links)))
    (unless link (user-error "No link %s" index))
    (drgnx-hub-call "debug/run/stop" (list :run (car drgnx-debug-origin--run) :stop (cdr drgnx-debug-origin--run)
                                           :file (plist-get link :path))
                    (lambda (result error)
                      (if error (message "Origin: %s" (or (plist-get error :message) error))
                        (let ((b (drgnx-debug-timeline--show-past (drgnx-debug-origin--past link result))))
                          (display-buffer b '((display-buffer-reuse-window display-buffer-use-some-window)))
                          (when-let* ((w (get-buffer-window b)))
                            (with-selected-window w
                              (goto-char (point-min))
                              (forward-line (1- (plist-get link :line)))))))))))

(defun drgnx-debug-origin-open-at-point ()
  "Open the trail's link at point."
  (interactive)
  (drgnx-debug-origin-open (or (get-text-property (point) 'drgnx-debug-origin-link) (user-error "No link here"))))

(defun drgnx-debug-origin-click (event)
  "Open the link under EVENT."
  (interactive "e")
  (let ((pos (posn-point (event-end event))))
    (when pos (goto-char pos) (drgnx-debug-origin-open-at-point))))

(define-minor-mode drgnx-debug-origin-events-mode
  "The origin trail in the editor: the hub's `debug-origin' events draw the card."
  :global t :group 'drgnx
  (if drgnx-debug-origin-events-mode
      (add-hook 'drgnx-hub-event-functions #'drgnx-debug-origin--event)
    (remove-hook 'drgnx-hub-event-functions #'drgnx-debug-origin--event)
    (drgnx-timer-cancel 'debug-origin)
    (when-let* ((b (get-buffer drgnx-debug-origin-buffer))) (kill-buffer b))
    (setq drgnx-debug-origin--id nil drgnx-debug-origin--run nil drgnx-debug-origin--links nil
          drgnx-debug-origin--rows nil)))

(defconst drgnx-debug-origin-commands
  '((debug-origin "Where Did This Come From?" drgnx-debug-origin "The trail of the value at point, at the recorded stop")
    (debug-origin-open "Open Origin Link" drgnx-debug-origin-open-at-point "Open the trail's link at point as it ran"))
  "The commands of the origin trail: (ID TITLE FUNCTION DOC).")

(provide 'drgnx-debug-origin)
;;; drgnx-debug-origin.el ends here
