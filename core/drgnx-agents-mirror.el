;;; drgnx-agents-mirror.el --- The editing Emacs's mirrors of the hub's agent sessions -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Agent sessions held by the hub (drgnx-hub.el) keep working when this Emacs closes; here they are mirrors: the
;; same `drgnx-agent-session' struct, its `remote' slot the hub's id, filled from the hub's `agent' and
;; `agent-entries' events, so the Agents tab shows and drives them like local ones (actions on a mirror go to the
;; hub: `drgnx-agents--remote').  A new Emacs reattaches with `drgnx-agents-mirror-sync': the transcript is
;; fetched once, and events numbered after it are applied on top (events that arrive while it is fetched wait).
;; Never blocks: every call to the hub here is asynchronous.  See docs/develop/hub.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-agents)
(require 'drgnx-hub)

(defvar drgnx-agents-mirror--fetching (make-hash-table :test #'equal)
  "Hub id → events that came while its transcript was being fetched (newest first).")
(defvar drgnx-agents-mirror--seq (make-hash-table :test #'equal) "Hub id → the last change number applied.")

(defun drgnx-agents-mirror--find (id) (seq-find (lambda (s) (equal (drgnx-agent-session-remote s) id)) drgnx-agents--sessions))

(defconst drgnx-agents-mirror--slots
  '(name profile cwd task job status via mode queue paused permissions reviews usage commands capabilities exit stderr)
  "The session slots a hub snapshot fills (its keys are the slot names).")

(defun drgnx-agents-mirror--fetching-p (id) (not (eq (gethash id drgnx-agents-mirror--fetching :none) :none)))

(defun drgnx-agents-mirror--apply-snapshot (snap)
  "Make (or update) the mirror of SNAP (a hub snapshot); returns (MIRROR . NEW-P)."
  (let* ((id (plist-get snap :id)) (m (drgnx-agents-mirror--find id)) (new (not m)))
    (unless m
      (setq m (drgnx-agents--make :remote id :id id))
      (push m drgnx-agents--sessions))
    (dolist (slot drgnx-agents-mirror--slots)
      (setf (cl-struct-slot-value 'drgnx-agent-session slot m) (plist-get snap (intern (concat ":" (symbol-name slot))))))
    (cons m new)))

(defun drgnx-agents-mirror--apply-entries (m entries)
  "Put ENTRIES ((INDEX LISP)…, as the hub's JSON arrays arrive) into mirror M's transcript."
  (let ((v (vconcat (drgnx-agent-session-entries m))))
    (mapc (lambda (pair)
            (let ((i (elt pair 0)) (e (car (read-from-string (elt pair 1)))))
              (when (>= i (length v)) (setq v (vconcat v (make-vector (- (1+ i) (length v)) nil))))
              (aset v i e)))
          entries)
    (setf (drgnx-agent-session-entries m) (append v nil))))

(defun drgnx-agents-mirror--fetch (m)
  "Fetch mirror M's whole transcript; then apply the events that came meanwhile and are newer."
  (let ((id (drgnx-agent-session-remote m)))
    (puthash id nil drgnx-agents-mirror--fetching)
    (drgnx-hub-call "agents/get" (list :id id)
                    (lambda (r _err)
                      (let ((waiting (gethash id drgnx-agents-mirror--fetching)) (seq (or (plist-get r :seq) 0)))
                        (remhash id drgnx-agents-mirror--fetching)
                        (when r
                          (drgnx-agents-mirror--apply-snapshot (car (read-from-string (plist-get r :lisp))))
                          (setf (drgnx-agent-session-entries m) (car (read-from-string (plist-get r :entries))))
                          (puthash id seq drgnx-agents-mirror--seq))
                        (dolist (ev (reverse waiting)) (drgnx-agents-mirror--event (car ev) (cdr ev)))
                        (drgnx-agents--changed m))))))

(defun drgnx-agents-mirror--event (event data)
  "An event from the hub (`drgnx-hub-event-functions')."
  (when (member event '("agent" "agent-entries"))
    (let ((id (plist-get data :id)) (seq (or (plist-get data :seq) 0)))
      (cond
       ;; a transcript on its way: the event waits for it
       ((drgnx-agents-mirror--fetching-p id)
        (puthash id (cons (cons event data) (gethash id drgnx-agents-mirror--fetching)) drgnx-agents-mirror--fetching))
       ;; older than what the mirror has
       ((and (gethash id drgnx-agents-mirror--seq) (<= seq (gethash id drgnx-agents-mirror--seq))
             (equal event "agent-entries")))
       ((equal event "agent")
        (pcase-let ((`(,m . ,new) (drgnx-agents-mirror--apply-snapshot (car (read-from-string (plist-get data :lisp))))))
          (if new (drgnx-agents-mirror--fetch m)
            (drgnx-agents--changed m))))
       ((equal event "agent-entries")
        (when-let* ((m (drgnx-agents-mirror--find id)))
          (drgnx-agents-mirror--apply-entries m (plist-get data :entries))
          (puthash id seq drgnx-agents-mirror--seq)
          (drgnx-agents--changed m)))))))

(defun drgnx-agents-mirror-sync ()
  "Mirror the hub's agent sessions here, and keep them current.  Asynchronous; never starts a hub."
  (add-hook 'drgnx-hub-event-functions #'drgnx-agents-mirror--event)
  (drgnx-hub-connect)
  (drgnx-hub-call "agents/list" nil
                  (lambda (r _err)
                    (mapc (lambda (lisp)
                            (pcase-let ((`(,m . ,_) (drgnx-agents-mirror--apply-snapshot (car (read-from-string lisp)))))
                              (drgnx-agents-mirror--fetch m)))
                          (plist-get r :sessions)))))

(defun drgnx-agents-mirror-stop ()
  "Stop mirroring (the mirrors stay as they are)."
  (remove-hook 'drgnx-hub-event-functions #'drgnx-agents-mirror--event)
  (clrhash drgnx-agents-mirror--fetching)
  (clrhash drgnx-agents-mirror--seq))

(provide 'drgnx-agents-mirror)
;;; drgnx-agents-mirror.el ends here
