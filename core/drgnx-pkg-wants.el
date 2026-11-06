;;; drgnx-pkg-wants.el --- Packages: the queue of clicks and what a removal may take -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What the user asked for in the Extensions view, before and after a sync runs it.  A click is an entry in the queue
;; file `<state>/extensions/pending.eld', (:next N :entries (ENTRY…)), an entry (:ticket N :add NAME [:version V]) or
;; (:ticket N :remove NAME); `drgnx sync --pending' takes the whole queue under the sync lock and runs it as one sync.
;; The ticket counter only grows, so a ticket is never given twice.  The wants themselves live in the lock (`:wanted
;; user' on an entry, written by `drgnx sync' in the same write as the install: core/drgnx-pkg.el).  A removal runs
;; `drgnx-pkg-removal-plan' first: a package something else still asks for is refused, with the reason.  These run in
;; the batch sync and in the editor alike: no prompt, and the editor's writes never wait (`:timeout 0').  See
;; docs/guide/packages.md, "What you asked for" and "The queue".

;;; Code:
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-file)

(declare-function drgnx-pkg--module-specs "drgnx-pkg" (dir))
(declare-function drgnx-pkg--packages-eld "drgnx-pkg" (&optional fresh))
(declare-function drgnx-pkg--read-file "drgnx-pkg" (file))
(declare-function drgnx-pkg-read-lock "drgnx-pkg" ())
(declare-function drgnx-pkg-wanted-file "drgnx-pkg-activate" ())
(declare-function drgnx-module-disabled-p "drgnx-modules" (module &optional default))
(defvar drgnx-dir)

;;;; The queue

(defun drgnx-pkg-pending-file ()
  "The queue of clicks not yet run: <state>/extensions/pending.eld."
  (expand-file-name "extensions/pending.eld" (drgnx-state-dir)))

(defun drgnx-pkg--pending-update (fn timeout)
  "Change the queue under its lock with FN (the plist (:next N :entries …), never nil) within TIMEOUT seconds.
A queue that does not read is copied aside and starts again empty; `drgnx-file-busy' passes up."
  (make-directory (file-name-directory (drgnx-pkg-pending-file)) t)
  (drgnx-file-update (drgnx-pkg-pending-file)
                     (lambda (data) (funcall fn (if (plist-member data :next) data (list :next 1 :entries nil))))
                     :on-unreadable 'backup :timeout timeout :pretty t :header ";; drgnx: clicks not yet run (drgnx sync --pending)"))

(defun drgnx-pkg-pending-add (entry)
  "Queue ENTRY, (:add NAME [:version V]) or (:remove NAME); its ticket.  Never waits: a queue another process holds is
`drgnx-file-busy' (try again)."
  (let (ticket)
    (drgnx-pkg--pending-update
     (lambda (q)
       (setq ticket (plist-get q :next))
       (list :next (1+ ticket) :entries (append (plist-get q :entries) (list (cons :ticket (cons ticket entry))))))
     0)
    ticket))

(defun drgnx-pkg-pending-cancel (ticket)
  "Take TICKET out of the queue; t when it was still there (no sync had taken it).
Never waits, as `drgnx-pkg-pending-add'."
  (let (found)
    (drgnx-pkg--pending-update
     (lambda (q)
       (let ((left (seq-remove (lambda (e) (and (eql (plist-get e :ticket) ticket) (setq found t))) (plist-get q :entries))))
         (if found (list :next (plist-get q :next) :entries left) q)))
     0)
    found))

(defun drgnx-pkg-pending-take ()
  "The queued entries, in their order, and the queue emptied (its ticket counter kept).  Called holding the sync lock."
  (let (taken)
    (drgnx-pkg--pending-update
     (lambda (q) (setq taken (plist-get q :entries)) (if taken (list :next (plist-get q :next) :entries nil) q))
     1.0)
    taken))

;;;; What a removal may take

(defun drgnx-pkg--hand-installed-p (entry)
  "Is the lock ENTRY (a plist) a package installed by hand or seeded: no hash, and no commit for a Git one?"
  (not (or (plist-get entry :sha256) (and (eq (plist-get entry :kind) 'git) (plist-get entry :commit)))))

(defun drgnx-pkg-removal-plan (names &optional modules-dir)
  "What removing NAMES (symbols) may do: (:remove NAMES… :refused ((NAME . WHY)…)).  A name is refused while another
source still asks for it — WHY is \"module M needs it\" (an enabled module of MODULES-DIR, default drgnx's modules/),
\"packages.eld lists it\", \"config.el asks for it (:ensure)\" or \"needed by P\" (a package of the lock not being
removed requires it).  A name that is not installed is no change.  Reads; changes nothing."
  (let* ((eld (drgnx-pkg--packages-eld t))
         (modules (seq-remove (lambda (m) (drgnx-module-disabled-p (car m) (plist-get (cdr m) :default)))
                              (drgnx-pkg--module-specs (or modules-dir (expand-file-name "modules" drgnx-dir)))))
         (ensured (ignore-errors (drgnx-pkg--read-file (drgnx-pkg-wanted-file))))
         (lock (drgnx-pkg-read-lock))
         refused)
    (dolist (name names)
      (let ((why (cond ((when-let* ((m (seq-find (lambda (m) (memq name (plist-get (cdr m) :packages))) modules)))
                          (format "module %s needs it" (car m))))
                       ((or (memq name (plist-get eld :packages)) (assq name (plist-get eld :git))) "packages.eld lists it")
                       ((memq name ensured) "config.el asks for it (:ensure)")
                       ((when-let* ((p (seq-find (lambda (e) (and (not (memq (car e) names))
                                                                  (assq name (plist-get (cdr e) :requires))))
                                                 lock)))
                          (format "needed by %s" (car p)))))))
        (when why (push (cons name why) refused))))
    (list :remove (seq-remove (lambda (n) (assq n refused)) names) :refused (nreverse refused))))

(provide 'drgnx-pkg-wants)
;;; drgnx-pkg-wants.el ends here
