;;; drgnx-save-ask.el --- Save / Don't Save / Cancel: the one question about unsaved changes -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-save-ask' asks what to do with a file's unsaved changes before it closes, as VS Code does: Save, Don't Save
;; or Cancel.  It is no command (the commands that close call it), and it asks only where somebody can answer: in
;; batch, under `inhibit-interaction', in a timer, in `drgnx-automatic' code or on the daemon's own terminal the
;; answer is Cancel at once, so nothing is lost and nothing waits.  `drgnx-save-ask-discard' carries out Don't Save
;; and keeps the text it drops in `drgnx-close-discarded'.  See docs/develop/core.md, "Unsaved changes on close".

;;; Code:
(require 'drgnx-frame-kind)
(declare-function drgnx-guard-automatic-p "drgnx-guard")

(defvar drgnx-close-discarded nil
  "What Don't Save dropped, newest first, at most five: plists (:file FILE :text TEXT :time TIME).
A mis-click is not fatal: (plist-get (car drgnx-close-discarded) :text) is the text as it was.")

(defun drgnx-save-ask-can-ask-p ()
  "Non-nil when a question can be answered: an Emacs with a user, not an automatic path (`drgnx-guard'), not the
daemon's own terminal."
  (and (not noninteractive) (not inhibit-interaction)
       (not (and (fboundp 'drgnx-guard-automatic-p) (drgnx-guard-automatic-p)))
       (not (and (daemonp) (eq (drgnx-state-frame-kind (selected-frame)) 'initial)))))

(defun drgnx-save-ask (name)
  "Ask whether to save the changes to NAME (a file's buffer name) before it closes: `save', `discard' (Don't Save)
or `cancel'.  s, d and c answer; Escape and C-g cancel.  A close clicked with the mouse asks in a dialog where the
frame can show one.  Where nobody can answer (`drgnx-save-ask-can-ask-p') the answer is `cancel', unasked."
  (if (not (drgnx-save-ask-can-ask-p))
      'cancel
    (let ((prompt (format "Do you want to save the changes you made to %s?  (s) Save  (d) Don't Save  (c) Cancel "
                          name)))
      (condition-case nil
          (if (and (consp last-nonmenu-event) use-dialog-box (display-popup-menus-p))
              (or (x-popup-dialog t (list (format "Do you want to save the changes you made to %s?" name)
                                          '("Save" . save) '("Don't Save" . discard) '("Cancel" . cancel)))
                  'cancel)
            (let (answer)
              (while (not answer)
                (let ((key (read-event prompt)))
                  (setq answer (pcase key
                                 ((or ?s ?S) 'save)
                                 ((or ?d ?D) 'discard)
                                 ((or ?c ?C ?\e 'escape ?\C-g) 'cancel)
                                 ((pred characterp) (ding) nil)))))
              (message nil)
              answer))
        (quit 'cancel)))))

(defun drgnx-save-ask-discard (buffer)
  "Don't Save: kill BUFFER without asking again, its text kept first in `drgnx-close-discarded'."
  (with-current-buffer buffer
    (push (list :file buffer-file-name :text (buffer-substring-no-properties (point-min) (point-max))
                :time (current-time))
          drgnx-close-discarded)
    (setq drgnx-close-discarded (take 5 drgnx-close-discarded))
    (set-buffer-modified-p nil))
  (let ((name (buffer-name buffer)))
    (kill-buffer buffer)
    (message "Discarded the changes to %s (kept in `drgnx-close-discarded')" name)))

(provide 'drgnx-save-ask)
;;; drgnx-save-ask.el ends here
