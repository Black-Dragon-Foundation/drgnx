;;; drgnx-notice-echo.el --- The echo rule: what interrupts you, at most one line per 2 s, and one line for startup -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The echo route of the notice model (drgnx-notice.el).  It follows `drgnx-notice-functions' and says a notice in
;; the echo area only when the rule wants it: a `fail' event or condition, once, when new; an `info' or `warn' one
;; only with `:echo t'; a new thing waiting on you unless the desktop took it (`drgnx-notice-desktop-take');
;; `:echo nil' never.  Lines are paced (`drgnx-notice-echo-interval'; the rest merge into one line), never shown over
;; a command's message, while a command runs or while the minibuffer is active: they wait for the end of the next
;; command whose message is gone.  Nothing in batch, nothing before startup is over (one line then sums up the failed
;; modules), and a daemon holds its lines until a client frame exists.  The only thing on `post-command-hook' is one
;; flag test.  Core: it requires nothing in wb/ or modules/.  See docs/guide/notices.md and docs/develop/core.md,
;; "Notices".

;;; Code:
(require 'cl-lib)
(require 'drgnx-notice)
(require 'drgnx-notice-desktop)
(require 'drgnx-registry)
(require 'drgnx-surfaces)
(require 'drgnx-frame-kind)
(require 'drgnx-timer)

(defvar server-after-make-frame-hook)

(defcustom drgnx-notice-echo-interval 2
  "Seconds between two notice lines in the echo area; what comes meanwhile is merged into one line."
  :type 'number :group 'drgnx)

(defconst drgnx-notice--echo-max 50
  "How many lines may wait (a daemon with no client frame holds them); past it the oldest go.")

(defvar drgnx-notice--echo-pending nil
  "The lines not yet shown, oldest first: (KIND . DATA), KIND `problem' or `waiting' with DATA the notice, or
`line' with DATA the finished text.")

(defvar drgnx-notice--echo-last nil "The time (`drgnx-timer-now') of the last line shown, nil before the first.")

(defvar drgnx-notice--echo-text nil
  "The last line shown.  It is in the echo area until something replaces it; it is not a command's message.")

(defvar drgnx-notice--echo-waiting nil
  "Non-nil when a line waits for the end of a command (the only thing `drgnx-notice--post-command' tests).")

(defvar drgnx-notice--started nil
  "Nil until startup is over (`emacs-startup-hook', or a daemon's first client frame); no line before.")

;;;; Texts

(defun drgnx-notice--echo-command-id (notice)
  "The registry id or command symbol of NOTICE's `:command' (the function of a (FN . ARGS) form)."
  (let ((c (plist-get notice :command))) (if (consp c) (car c) c)))

(defun drgnx-notice--echo-suffix (notice)
  "\" — TITLE (KEY)\" for NOTICE's command when the registry titles it; KEY is left out when it has none."
  (let* ((id (drgnx-notice--echo-command-id notice))
         (cmd (and id (drgnx-commands-get id)))
         (title (and cmd (drgnx-cmd-title cmd))))
    (when title
      (let ((key (drgnx-surfaces-key-label id :short t)))
        (format " — %s%s" title (if key (format " (%s)" key) ""))))))

(defun drgnx-notice--echo-show-notices ()
  "\" — Show Notices (KEY)\", KEY the key of the Notices list when it has one."
  (let ((key (drgnx-surfaces-key-label 'notices :short t)))
    (format " — Show Notices%s" (if key (format " (%s)" key) ""))))

(defun drgnx-notice--echo-one (entry)
  "The line for the one pending ENTRY."
  (let ((data (cdr entry)))
    (pcase (car entry)
      ('line data)
      ('waiting (format "drgnx: waiting on you: %s%s" (plist-get data :text) (or (drgnx-notice--echo-suffix data) "")))
      (_ (format "drgnx: %s%s" (plist-get data :text) (or (drgnx-notice--echo-suffix data) ""))))))

(defun drgnx-notice--echo-line (entries)
  "One line for the pending ENTRIES: the entry's own line for one, else the sum of the problems and the things
waiting on you."
  (if (null (cdr entries))
      (drgnx-notice--echo-one (car entries))
    (let ((waiting 0) (problems 0))
      (dolist (e entries) (if (eq (car e) 'waiting) (setq waiting (1+ waiting)) (setq problems (1+ problems))))
      (concat (cond ((zerop waiting) (format "drgnx: %d new problems" problems))
                    ((zerop problems) (format "drgnx: %d new things wait on you" waiting))
                    (t (format "drgnx: %d new problems and %d things waiting on you" problems waiting)))
              (drgnx-notice--echo-show-notices)))))

;;;; Showing, pacing, waiting

(defun drgnx-notice--client-frame-p ()
  "Non-nil when a frame other than the initial terminal's exists."
  (let ((found nil))
    (dolist (f (frame-list))
      (unless (eq (drgnx-state-frame-kind f) 'initial) (setq found t)))
    found))

(defun drgnx-notice--can-echo-p ()
  "Non-nil when a line may be shown: not in batch, and a daemon only once a client frame exists.  The seam tests stub."
  (and (not noninteractive) (or (not (daemonp)) (drgnx-notice--client-frame-p))))

(defun drgnx-notice--echo-busy-p ()
  "Non-nil when a line must wait: the minibuffer is active, a command is running, or the echo area holds a message
that is not our own last line."
  (or (active-minibuffer-window)
      this-command
      (let ((m (current-message))) (and m (not (equal m drgnx-notice--echo-text))))))

(defun drgnx-notice--echo-show ()
  "Show the pending lines as one line."
  (let ((line (drgnx-notice--echo-line drgnx-notice--echo-pending)))
    (setq drgnx-notice--echo-pending nil drgnx-notice--echo-waiting nil
          drgnx-notice--echo-last (drgnx-timer-now) drgnx-notice--echo-text line)
    (drgnx-timer-cancel 'notice-echo)
    (let ((message-truncate-lines t)) (message "%s" line))))

(defun drgnx-notice--echo-try ()
  "Show the pending lines if the rule allows it now; else leave them waiting for the timer or the next command."
  (when drgnx-notice--echo-pending
    (let ((remaining (and drgnx-notice--echo-last
                          (- (+ drgnx-notice--echo-last drgnx-notice-echo-interval) (drgnx-timer-now)))))
      (cond ((not (drgnx-notice--can-echo-p)) (setq drgnx-notice--echo-waiting nil))   ; held for a client frame
            ((and remaining (> remaining 0.001))
             (setq drgnx-notice--echo-waiting nil)
             (drgnx-timer-start 'notice-echo remaining #'drgnx-notice--echo-flush :owner :core))
            ((drgnx-notice--echo-busy-p) (setq drgnx-notice--echo-waiting t))
            (t (drgnx-notice--echo-show))))))

(defun drgnx-notice--echo-flush ()
  "The timer `notice-echo': no command runs between commands, so `this-command' (the last one's) does not count."
  (let ((this-command nil)) (drgnx-notice--echo-try)))

(defun drgnx-notice--post-command ()
  "`post-command-hook': the only cost on every command is the test of one flag."
  (when drgnx-notice--echo-waiting
    (let ((this-command nil)) (drgnx-notice--echo-try))))

(defun drgnx-notice--echo-enqueue (kind data)
  "Add a line of KIND for DATA; keep at most `drgnx-notice--echo-max'; try to show."
  (setq drgnx-notice--echo-pending (nconc drgnx-notice--echo-pending (list (cons kind data))))
  (let ((over (- (length drgnx-notice--echo-pending) drgnx-notice--echo-max)))
    (when (> over 0) (setq drgnx-notice--echo-pending (nthcdr over drgnx-notice--echo-pending))))
  (drgnx-notice--echo-try))

;;;; The rule

(defun drgnx-notice--echo-wanted-p (notice)
  "Non-nil when an event or condition NOTICE is echoed: `:echo' says so, else only a `fail' one."
  (let ((echo (plist-member notice :echo)))
    (if echo (and (cadr echo) t) (eq (plist-get notice :severity) 'fail))))

(defun drgnx-notice--echo-attention (item)
  "A new attention ITEM: the desktop may take it; the echo shows it unless it did (`:echo t' shows it anyway).
Neither before startup is over: what waits then is old (left from an earlier session), and the bar counts it."
  (let* ((echo (plist-member item :echo)) (on (and echo (cadr echo))))
    (when (and drgnx-notice--started (not (and echo (not on))))
      (let ((taken (drgnx-notice-desktop-take item)))
        (when (or on (not taken))
          (drgnx-notice--echo-enqueue 'waiting item))))))

(defun drgnx-notice--echo-change (change)
  "`drgnx-notice-functions': queue a line for what the rule wants."
  (pcase (plist-get change :op)
    ('post (let ((n (plist-get change :notice)))
             (when (and drgnx-notice--started n (drgnx-notice--echo-wanted-p n))
               (drgnx-notice--echo-enqueue 'problem n))))
    ('set (dolist (id (plist-get change :added))
            (let ((item (gethash id drgnx-notice--union)))
              (when item (drgnx-notice--echo-attention item)))))))

;;;; Startup

(defun drgnx-notice--module-name-p (notice)
  "Non-nil when NOTICE is a condition of source `modules' about a module (its id is the module's name)."
  (let ((id (plist-get notice :id)))
    (and (eq (plist-get notice :source) 'modules) id (or (symbolp id) (stringp id)) (not (memq id '(more unknown))))))

(defun drgnx-notice--startup-line ()
  "The one line that sums up the `fail' conditions present now, or nil when there are none."
  (let ((fails (reverse (drgnx-notices :life 'condition :severity 'fail))))   ; oldest first
    (when fails
      (let ((n (length fails)))
        (concat
         (cond
          ((cl-every #'drgnx-notice--module-name-p fails)
           (let* ((names (mapcar (lambda (f) (format "%s" (plist-get f :id))) fails))
                  (shown (mapconcat #'identity (seq-take names 3) ", ")))
             (format "drgnx: %d module%s did not start (%s%s)" n (if (= n 1) "" "s") shown
                     (if (> n 3) (format ", and %d more" (- n 3)) ""))))
          ((= n 1) (format "drgnx: %s" (plist-get (car fails) :text)))
          (t (format "drgnx: %d problems at startup" n)))
         (drgnx-notice--echo-show-notices))))))

(defun drgnx-notice--startup-done ()
  "Startup is over: lines may come now, and one sums up the failures there are."
  (setq drgnx-notice--started t)
  (let ((line (drgnx-notice--startup-line)))
    (when line (drgnx-notice--echo-enqueue 'line line))))

(defun drgnx-notice--startup-hook ()
  "`emacs-startup-hook': startup is over, unless this is a daemon with no client frame (its first one ends it)."
  (when (and (not drgnx-notice--started) (drgnx-notice--can-echo-p))
    (drgnx-notice--startup-done)))

(defun drgnx-notice--server-frame ()
  "`server-after-make-frame-hook': a client frame exists, so held lines go; the first one also ends startup."
  (when (drgnx-notice--can-echo-p)
    (if drgnx-notice--started (drgnx-notice--echo-try) (drgnx-notice--startup-done))))

;;;; The mode

(define-minor-mode drgnx-notice-echo-mode
  "Say failures and new things waiting on you in the echo area: at most one line per `drgnx-notice-echo-interval'.
Never over a command's message, in the minibuffer, in batch or during startup.  Turned on after startup it works at
once."
  :global t :group 'drgnx
  (if drgnx-notice-echo-mode
      (progn
        (add-hook 'drgnx-notice-functions #'drgnx-notice--echo-change)
        (add-hook 'post-command-hook #'drgnx-notice--post-command 90)
        (add-hook 'emacs-startup-hook #'drgnx-notice--startup-hook 90)
        (add-hook 'server-after-make-frame-hook #'drgnx-notice--server-frame)
        (when (and after-init-time (drgnx-notice--can-echo-p)) (setq drgnx-notice--started t)))
    (remove-hook 'drgnx-notice-functions #'drgnx-notice--echo-change)
    (remove-hook 'post-command-hook #'drgnx-notice--post-command)
    (remove-hook 'emacs-startup-hook #'drgnx-notice--startup-hook)
    (remove-hook 'server-after-make-frame-hook #'drgnx-notice--server-frame)
    (drgnx-timer-cancel 'notice-echo)
    (setq drgnx-notice--echo-pending nil drgnx-notice--echo-waiting nil drgnx-notice--echo-text nil
          drgnx-notice--started nil)))

(provide 'drgnx-notice-echo)
;;; drgnx-notice-echo.el ends here
