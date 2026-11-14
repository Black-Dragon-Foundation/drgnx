;;; drgnx-debug-investigation.el --- Debugging: a partner agent's investigation -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The editor's half of debugging with an agent (docs/guide/debugging.md, "Debugging with an agent"; the hub's
;; `debug/agent.rs').  An agent debugs beside you through the hub's `debug_*' tools, under the permissions matrix's
;; `debug.*' rows.  Its probes and breakpoints carry its session (`:agent'), and the breakpoint column and the probe
;; column ring them.  The hub sends `debug-investigation' as the agent works:
;; - a hypothesis (open, confirmed, rejected) with its evidence: the **Investigation** buffer lists them by project;
;; - a fix, sent only after it passed its predicate in a fresh fork: **Review Fix** shows each file's diff against your
;;   buffer, the hypothesis and its evidence; **Accept Fix** puts the agent's text into your buffers as the agent's
;;   change in the edit history (undoable, not saved).  Reverting stays yours: undo, or the history.
;; **Explain** asks the agent to write the story of its investigation in its chat.
;; Nothing here prompts from an event: a fix's arrival only says so in the echo area.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'diff)
(require 'drgnx-history)
(declare-function drgnx-hub-call-sync "drgnx-hub-client")
(declare-function drgnx-debug-timeline--take "drgnx-debug-timeline")
(defvar nidhogg-history-origin)

(defgroup drgnx-debug-investigation nil "Debugging with an agent." :group 'drgnx)

;; `drgnx-debug-agent-ring' (the agent's colour) is the gutter's.
(defface drgnx-debug-hypothesis-open '((t :inherit drgnx-status-warn))
  "An open hypothesis." :group 'drgnx-debug-investigation)
(defface drgnx-debug-hypothesis-confirmed '((t :inherit drgnx-status-ok))
  "A confirmed hypothesis." :group 'drgnx-debug-investigation)
(defface drgnx-debug-hypothesis-rejected '((t :inherit drgnx-text-disabled))
  "A rejected hypothesis." :group 'drgnx-debug-investigation)

(defconst drgnx-debug-investigation-buffer "*Debug Investigation*")

(defvar drgnx-debug-investigation--hypotheses nil
  "The hypotheses the hub sent, newest first: plists :root :id :title :state :evidence :agent.  At most 200.")

(defvar drgnx-debug-investigation--fixes nil
  "The fixes the hub offered, newest first: plists :root :hypothesis :run :agent :files (plists :path :text).  At
most 20.")

(defun drgnx-debug-investigation--put-hypothesis (root h)
  "Keep hypothesis H (of ROOT): it replaces the one with its id."
  (let ((h (plist-put (copy-sequence h) :root root)))
    (setq drgnx-debug-investigation--hypotheses
          (seq-take (cons h (seq-remove (lambda (o) (equal (plist-get o :id) (plist-get h :id)))
                                        drgnx-debug-investigation--hypotheses))
                    200))))

(defun drgnx-debug-investigation--event (event data)
  "`drgnx-hub-event-functions': the agent's investigation (`debug-investigation') and its probes (`debug-probes')."
  (pcase event
    ("debug-probes" (drgnx-debug-timeline--take data))
    ("debug-investigation"
     (let ((root (plist-get data :root)))
       (when-let* ((h (plist-get data :hypothesis))) (drgnx-debug-investigation--put-hypothesis root h))
       (when-let* ((f (plist-get data :fix)))
         (setq drgnx-debug-investigation--fixes
               (seq-take (cons (plist-put (copy-sequence f) :root root)
                               (seq-remove (lambda (o) (equal (plist-get o :hypothesis) (plist-get f :hypothesis)))
                                           drgnx-debug-investigation--fixes))
                         20))
         (message "An agent's fix for %s passed in a fresh fork: Review Fix" (plist-get f :hypothesis)))
       (when (get-buffer drgnx-debug-investigation-buffer) (drgnx-debug-investigation--render))))))

;;;; The Investigation buffer

(define-derived-mode drgnx-debug-investigation-mode special-mode "Investigation"
  "An agent's hypotheses and fixes."
  (buffer-disable-undo))

(defun drgnx-debug-investigation--state-face (state)
  (pcase state
    ("confirmed" 'drgnx-debug-hypothesis-confirmed) ("rejected" 'drgnx-debug-hypothesis-rejected)
    (_ 'drgnx-debug-hypothesis-open)))

(defun drgnx-debug-investigation--render ()
  "The Investigation buffer, drawn again."
  (with-current-buffer (get-buffer-create drgnx-debug-investigation-buffer)
    (unless (derived-mode-p 'drgnx-debug-investigation-mode) (drgnx-debug-investigation-mode))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize "Investigation" 'face 'bold) "\n")
      (if (null drgnx-debug-investigation--hypotheses)
          (insert "No hypotheses yet: ask an agent to debug this with you.\n")
        (dolist (state '("open" "confirmed" "rejected"))
          (let ((hs (seq-filter (lambda (h) (equal (plist-get h :state) state))
                                drgnx-debug-investigation--hypotheses)))
            (when hs
              (insert "\n" (propertize (capitalize state) 'face (drgnx-debug-investigation--state-face state)) "\n")
              (dolist (h hs)
                (insert (format "  %s  " (plist-get h :id))
                        (propertize (or (plist-get h :title) "") 'face (drgnx-debug-investigation--state-face state))
                        "  " (propertize (or (plist-get h :agent) "") 'face 'drgnx-debug-agent-ring) "\n")
                (seq-doseq (e (plist-get h :evidence)) (insert "      " e "\n")))))))
      (when drgnx-debug-investigation--fixes
        (insert "\n" (propertize "Fixes (passed in a fresh fork)" 'face 'bold) "\n")
        (dolist (f drgnx-debug-investigation--fixes)
          (insert (format "  %s: %d file(s), run %s: Review Fix\n" (plist-get f :hypothesis)
                          (length (plist-get f :files)) (plist-get f :run)))))
      (goto-char (point-min)))
    (current-buffer)))

(defun drgnx-debug-investigation-show ()
  "The agent's investigation: its hypotheses with their evidence, and the fixes it offers."
  (interactive)
  (pop-to-buffer (drgnx-debug-investigation--render)))

;;;; Explain

(defun drgnx-debug-investigation--agents ()
  "The agent sessions with a hypothesis, newest first."
  (delete-dups (delq nil (mapcar (lambda (h) (plist-get h :agent)) drgnx-debug-investigation--hypotheses))))

(defun drgnx-debug-investigation-explain (agent)
  "Ask AGENT (the session investigating) to write the story of its investigation in its chat."
  (interactive
   (let ((all (drgnx-debug-investigation--agents)))
     (list (cond ((null all) (user-error "No agent is investigating"))
                 ((null (cdr all)) (car all))
                 (t (completing-read "Agent: " all nil t))))))
  (drgnx-hub-call-sync "agents/send"
                       (list :id agent
                             :text (concat "Explain your debugging investigation so far: each hypothesis, the "
                                           "evidence for and against it (stops, probe hits, forks), and what you "
                                           "would try next.")))
  (message "Asked %s to explain its investigation in its chat" agent))

;;;; The fix card

(defun drgnx-debug-investigation--fix (hypothesis)
  "The fix offered for HYPOTHESIS, or an error."
  (or (seq-find (lambda (f) (equal (plist-get f :hypothesis) hypothesis)) drgnx-debug-investigation--fixes)
      (user-error "No fix is offered for %s" hypothesis)))

(defun drgnx-debug-investigation--read-fix ()
  "A hypothesis with a fix: the newest, or asked among them with a prefix argument."
  (let ((all (mapcar (lambda (f) (plist-get f :hypothesis)) drgnx-debug-investigation--fixes)))
    (cond ((null all) (user-error "No fix is offered"))
          ((or (null (cdr all)) (not current-prefix-arg)) (car all))
          (t (completing-read "Fix for: " all nil t)))))

(defun drgnx-debug-investigation--diff (file text)
  "The diff of FILE (as its buffer has it, or on disk) against TEXT."
  (let ((mine (or (find-buffer-visiting file) (find-file-noselect file)))
        (theirs (generate-new-buffer " *fix*" t)))
    (unwind-protect
        (with-temp-buffer
          (with-current-buffer theirs (insert text))
          (diff-no-select mine theirs nil t (current-buffer))
          (buffer-string))
      (kill-buffer theirs))))

(defun drgnx-debug-investigation-review-fix (hypothesis)
  "The fix offered for HYPOTHESIS as a card: its hypothesis and evidence, then each file's diff against yours."
  (interactive (list (drgnx-debug-investigation--read-fix)))
  (let* ((f (drgnx-debug-investigation--fix hypothesis))
         (h (seq-find (lambda (h) (equal (plist-get h :id) hypothesis)) drgnx-debug-investigation--hypotheses))
         (root (plist-get f :root)))
    (with-current-buffer (get-buffer-create (format "*Debug Fix: %s*" hypothesis))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "Fix for %s" (or (plist-get h :title) hypothesis)) 'face 'bold) "\n"
                (format "By %s; passed in a fresh fork of run %s.\n"
                        (propertize (or (plist-get f :agent) "an agent") 'face 'drgnx-debug-agent-ring)
                        (plist-get f :run)))
        (seq-doseq (e (plist-get h :evidence)) (insert "  " e "\n"))
        (insert "Accept Fix puts it in your buffers as the agent's change (undoable, not saved).\n")
        (seq-doseq (file (plist-get f :files))
          (insert "\n" (drgnx-debug-investigation--diff (expand-file-name (plist-get file :path) root)
                                                        (plist-get file :text)))))
      (special-mode)
      (goto-char (point-min))
      (pop-to-buffer (current-buffer)))))

(defun drgnx-debug-investigation-accept-fix (hypothesis)
  "Put the fix offered for HYPOTHESIS into your buffers, recorded in the edit history as the agent's change (undoable,
not saved)."
  (interactive (list (drgnx-debug-investigation--read-fix)))
  (let* ((f (drgnx-debug-investigation--fix hypothesis))
         (origin (format "agent:%s#fix-%s" (plist-get f :agent) hypothesis)))
    (seq-doseq (file (plist-get f :files))
      (with-current-buffer (find-file-noselect (expand-file-name (plist-get file :path) (plist-get f :root)))
        (let ((new (generate-new-buffer " *fix*" t)))
          (unwind-protect
              (progn (with-current-buffer new (insert (plist-get file :text)))
                     (drgnx-history-with-origin origin
                       (replace-region-contents (point-min) (point-max) new)))
            (kill-buffer new)))))
    (setq drgnx-debug-investigation--fixes
          (seq-remove (lambda (o) (equal (plist-get o :hypothesis) hypothesis)) drgnx-debug-investigation--fixes))
    (message "The fix for %s is in your buffers (not saved)" hypothesis)))

(provide 'drgnx-debug-investigation)
;;; drgnx-debug-investigation.el ends here
