;;; drgnx-notice-desktop.el --- Desktop notifications for what waits on you: once each, while no drgnx frame has focus -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The desktop route of the notice model (drgnx-notice.el).  `drgnx-notice-desktop-take' says whether a thing
;; waiting on you (an attention item) goes to the desktop: once per id, while `drgnx-notice-desktop-mode' is on, no
;; drgnx frame has focus and the platform has a backend.  The echo route (Task 7) asks it for each new item; nothing
;; else sends.  A taken item is queued and sent off the caller, from the layer timer `notice-desktop', each send
;; under `with-demoted-errors'.  The ids already sent are pruned to the union of the sets on every set change, so a
;; thing that stops waiting and starts again notifies again.  Backends: macOS `osascript' (a process with a fixed
;; script, the text only as its arguments), elsewhere the freedesktop Notify method over D-Bus, sent asynchronously
;; with no reply awaited; else a message.  Never a prompt, never a wait.  Core: it requires nothing in wb/ or
;; modules/.  See docs/guide/notices.md and docs/develop/core.md, "Notices".

;;; Code:
(require 'drgnx-guard)
(require 'drgnx-notice)
(require 'drgnx-frame-kind)
(require 'drgnx-timer)

(declare-function dbus-call-method-asynchronously "dbus")
(defvar notifications-application-name)
(defvar notifications-application-icon)
(defvar drgnx-notice-desktop-mode)

(defcustom drgnx-notice-desktop t
  "Non-nil: a new thing waiting on you is a desktop notification while no drgnx window has focus."
  :type 'boolean :group 'drgnx)

(defvar drgnx-notice-desktop--seen (make-hash-table :test #'equal)
  "Attention ids already sent to the desktop.  Pruned to the union of the sets after each set change: bounded by
what waits on you now.")

(defvar drgnx-notice-desktop--queue nil "(TITLE . BODY) of the notifications to send, newest first.")

(defvar drgnx-notice-desktop--backend :unknown
  "The desktop backend: `osascript', `dbus' or nil; `:unknown' until `drgnx-notice-desktop--available-p' asks.")

;;;; Backends

(defun drgnx-notice-desktop--available-p ()
  "The backend this Emacs has, asked once: `osascript' on macOS when it is found; `dbus' elsewhere but Windows when
Emacs has D-Bus and a session bus address; else nil."
  (when (eq drgnx-notice-desktop--backend :unknown)
    (setq drgnx-notice-desktop--backend
          (cond ((eq system-type 'darwin) (and (executable-find "osascript") 'osascript))
                ((eq system-type 'windows-nt) nil)
                ((and (featurep 'dbusbind) (require 'notifications nil t) (getenv "DBUS_SESSION_BUS_ADDRESS")) 'dbus))))
  drgnx-notice-desktop--backend)

(defun drgnx-notice-desktop-send (title body)
  "Tell the user TITLE and BODY where the platform has a notification.  macOS: `osascript' (a process that never
waits; a fixed script, the text only as arguments to it: nothing of it is script, no shell); a failed one says so.
Elsewhere: the freedesktop Notify method over D-Bus, asynchronously, no reply awaited (a hung notification server
cannot hold Emacs).  Else a message.  Never a prompt."
  (pcase (drgnx-notice-desktop--available-p)
    ('osascript
     (make-process :name "drgnx-notify" :noquery t :connection-type 'pipe
                   :command (list "osascript" "-e" "on run argv"
                                  "-e" "display notification (item 1 of argv) with title (item 2 of argv)"
                                  "-e" "end run" "--"
                                  (replace-regexp-in-string "[\n\r]+" " " body) (replace-regexp-in-string "[\n\r]+" " " title))
                   :sentinel (lambda (p _event)
                               (when (and (memq (process-status p) '(exit signal)) (/= 0 (process-exit-status p)))
                                 (message "drgnx: the macOS notification failed (%s — %s)" title body)))))
    ('dbus
     (dbus-call-method-asynchronously :session "org.freedesktop.Notifications" "/org/freedesktop/Notifications"
                                      "org.freedesktop.Notifications" "Notify" nil
                                      :string notifications-application-name :uint32 0
                                      :string notifications-application-icon :string title :string body
                                      '(:array) '(:array :signature "{sv}") :int32 -1))
    (_ (message "%s — %s" title body))))

;;;; The route

(defun drgnx-notice-desktop--focus-p ()
  "Non-nil when a drgnx frame has focus: a live frame, not the initial terminal's, whose focus state is t."
  (let ((frames (frame-list)) (found nil))
    (while (and frames (not found))
      (let ((f (car frames)))
        (when (and (eq (frame-focus-state f) t) (not (eq (drgnx-state-frame-kind f) 'initial))) (setq found t)))
      (setq frames (cdr frames)))
    found))

(defun drgnx-notice-desktop--title (source)
  "\"drgnx: \" and SOURCE's title (its name when it has none)."
  (format "drgnx: %s" (or (plist-get (gethash source drgnx-notice--sources) :title) source)))

(defun drgnx-notice-desktop-take (item)
  "Non-nil when ITEM (an attention notice, as `drgnx-needs-you-items' gives it) goes to the desktop: the route is
on (`drgnx-notice-desktop-mode', `drgnx-notice-desktop'), ITEM's `:echo' is not nil, its id was not sent yet, no
drgnx frame has focus and a backend is there.  Then its id is marked sent and the notification queued; it is sent
off the caller (the timer `notice-desktop'), so this is safe inside `drgnx-notice-functions'."
  (let ((id (plist-get item :id)) (echo (plist-member item :echo)))
    (when (and drgnx-notice-desktop drgnx-notice-desktop-mode
               (or (null echo) (cadr echo))
               (not (gethash id drgnx-notice-desktop--seen))
               (not (drgnx-notice-desktop--focus-p))
               (drgnx-notice-desktop--available-p))
      (puthash id t drgnx-notice-desktop--seen)
      (push (cons (drgnx-notice-desktop--title (plist-get item :source)) (plist-get item :text))
            drgnx-notice-desktop--queue)
      (drgnx-timer-start 'notice-desktop 0 #'drgnx-notice-desktop--flush :owner :core)
      t)))

(defun drgnx-notice-desktop--flush ()
  "Send the queued notifications, oldest first; a failed send is a message and the rest still go."
  (let ((queue (nreverse drgnx-notice-desktop--queue)))
    (setq drgnx-notice-desktop--queue nil)
    (drgnx-automatic
     (dolist (n queue)
       (with-demoted-errors "drgnx: desktop notification failed: %S"
         (drgnx-notice-desktop-send (car n) (cdr n)))))))

(defun drgnx-notice-desktop--prune-all ()
  "Forget the sent ids that wait on you no more (not in the union)."
  (let ((gone nil))
    (maphash (lambda (id _) (unless (gethash id drgnx-notice--union) (push id gone))) drgnx-notice-desktop--seen)
    (dolist (id gone) (remhash id drgnx-notice-desktop--seen))))

(defun drgnx-notice-desktop--prune (change)
  "`drgnx-notice-functions': after a set change that removed ids, forget the sent ids no longer in the union."
  (when (and (memq (plist-get change :op) '(set unknown undefine)) (plist-get change :removed))
    (drgnx-notice-desktop--prune-all)))

(define-minor-mode drgnx-notice-desktop-mode
  "Desktop notifications for the things waiting on you: each once, while no drgnx frame has focus.
On, it follows the notice model to forget what waits no more; `drgnx-notice-desktop' nil keeps it silent."
  :global t :group 'drgnx
  (if drgnx-notice-desktop-mode
      (progn (add-hook 'drgnx-notice-functions #'drgnx-notice-desktop--prune)
             (drgnx-notice-desktop--prune-all))
    (remove-hook 'drgnx-notice-functions #'drgnx-notice-desktop--prune)
    (setq drgnx-notice-desktop--queue nil)
    (drgnx-timer-cancel 'notice-desktop)))

(provide 'drgnx-notice-desktop)
;;; drgnx-notice-desktop.el ends here
