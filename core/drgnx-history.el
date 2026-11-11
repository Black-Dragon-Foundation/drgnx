;;; drgnx-history.el --- the editor tracks project buffers and drains Nidhogg's changes to the hub -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The edit history's editor side (docs/develop/history.md, "The editor").  A file buffer inside a git project is
;; registered with the hub (`history/register'); Nidhogg's change hook (`--with-nidhogg-history') then records every
;; change to its text in a ring, and a timer (`history-drain', every `drgnx-history-drain-interval' s, doing work
;; only while `nidhogg-history-pending-p') hands the ring to the hub as `history/batch'es: the user's keystrokes beside
;; the agents' and the outside world's.  A batch carries the hash of the buffer's whole text; when the hub's document
;; differs it answers `resync' and the whole text goes (`history/resync').
;; - Typing costs this file nothing: the hook is Nidhogg's (a branch for an untracked buffer), and the drain runs
;;   off the command loop on a timer.  The hash is the drain's cost: Nidhogg hashes the buffer's text (`nidhogg-buffer-sha256'),
;;   and a large buffer's copy is hashed on a worker thread (`nidhogg-buffer-sha256-async'): its batches go when it lands.
;; - `drgnx-history-with-origin' marks the changes its body makes as someone else's (a revert, a merge, git); Emacs's own
;;   undo of them runs outside it and is the user's change.
;; - Without the Nidhogg primitives the mode stays off.  Nothing here prompts or waits; a lost hub drops the
;;   registrations and the next connection registers the buffers again.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-timer)
(require 'drgnx-large-file)

(declare-function drgnx-hub-call "drgnx-hub-client" (method params callback &rest keys))
(declare-function nidhogg-history-track "nidhogg-history" (buffer on))
(declare-function nidhogg-history-drain "nidhogg-history" (buffer))
(declare-function nidhogg-history-pending-p "nidhogg-history" ())
(declare-function nidhogg-buffer-sha256 "nidhogg-blk" (buffer))
(declare-function nidhogg-buffer-sha256-async "nidhogg-blk" (buffer callback))
(defvar nidhogg-history-origin)
(defvar drgnx-hub--client)
(defvar drgnx-hub-connected-functions)
(defvar drgnx-hub-disconnect-functions)

(defvar drgnx-history-batch-max (* 1024 1024)
  "Most bytes of inserted text one `history/batch' carries (the hub refuses more); a larger change is split.")

(defvar drgnx-history-drain-interval 0.1
  "Seconds between looks at Nidhogg's ring while some buffer is tracked.")

(defvar drgnx-history-large-size (* 256 1024)
  "Characters from which a buffer's ring is drained only while Emacs is idle (`drgnx-history--due-p').")

(defvar drgnx-history-idle-delay 0.3
  "Seconds of idleness before a large buffer's ring is drained.")

(defvar drgnx-history-drained-functions nil
  "Abnormal hook run after each drain that sent changes, with (BUFFER COUNTER CHANGES): the buffer, how many drains
of it have sent changes (1 for the first: the buffer's version, which each batch carries), and the changes sent, in
the hub's shape.  CHANGES is `resync' when the buffer's changes since the last drain went unsent (Nidhogg's ring lost
some, or the whole text went instead): a gap, counted as a drain of its own.  A listener that signals is ignored; with
no listener the drain does nothing more.")

(cl-defstruct (drgnx-history--st (:constructor drgnx-history--st-make))
  "A tracked buffer: ID (the hub's name for it), REGISTERED (the hub answered tracked), LAST (the hub's last answer
to a batch: `ok', `resync', or `resynced' once the text went), RESYNCING (a `history/resync' is out), DRAINS (the
drains that sent changes), HASHING (a large buffer's text is being hashed on a worker: its ring waits), ROOT and
PATH (the project's folder and the file in it, as `history/register' got them)."
  id registered last resyncing (drains 0) hashing root path)

(defvar drgnx-history--buffers (make-hash-table :test 'eq :weakness 'key)
  "Buffer → `drgnx-history--st'.  Weak on the buffer; entries go with `kill-buffer-hook' and the mode's teardown.")

(defvar drgnx-history--next-id 0)

(defun drgnx-history--primitives-p ()
  "Whether this Emacs has Nidhogg's change hook."
  (and (fboundp 'nidhogg-history-track) (fboundp 'nidhogg-history-drain) (fboundp 'nidhogg-history-pending-p)
       (fboundp 'nidhogg-buffer-sha256) (fboundp 'nidhogg-buffer-sha256-async)))

(defun drgnx-history--connected-p ()
  "Whether this Emacs has a live connection to the hub (a hook never opens one)."
  (and (boundp 'drgnx-hub--client) (process-live-p drgnx-hub--client)))

(defun drgnx-history--send (method params callback)
  "Ask the hub METHOD with PARAMS (CALLBACK gets RESULT and ERROR); non-nil when sent.  Never opens a connection."
  (and (drgnx-history--connected-p)
       (condition-case nil (progn (drgnx-hub-call method params callback) t)
         (error nil))))

;;;; The changes

(defun drgnx-history--origin (origin)
  "ORIGIN (nil, a symbol or a string) as the hub's string, nil for the user."
  (cond ((null origin) nil) ((symbolp origin) (symbol-name origin)) (t origin)))

(defun drgnx-history--changes (drained)
  "DRAINED (Nidhogg's (START OLD-LEN INSERTED TIME ORIGIN) list) as the hub's changes: plists with START 0-based."
  (mapcar (lambda (c)
            (let ((origin (drgnx-history--origin (nth 4 c))))
              (append (list :start (1- (nth 0 c)) :old_len (nth 1 c) :inserted (nth 2 c))
                      (and origin (list :origin origin)))))
          drained))

(defun drgnx-history--pieces (change max)
  "CHANGE as one change, or as several in order when it inserts more than MAX bytes.  The first replaces what
CHANGE replaces; the others insert after it.  A piece is at most MAX/4 characters, so at most MAX bytes."
  (let* ((text (plist-get change :inserted)) (n (length text)) (step (max 1 (/ max 4))))
    (if (<= (string-bytes text) max)
        (list change)
      (let ((pieces nil) (at 0))
        (while (< at n)
          (let ((end (min n (+ at step))))
            (push (cl-list* :start (+ (plist-get change :start) at) :old_len (if (= at 0) (plist-get change :old_len) 0)
                            :inserted (substring text at end)
                            (and (plist-get change :origin) (list :origin (plist-get change :origin))))
                  pieces)
            (setq at end)))
        (nreverse pieces)))))

(defun drgnx-history--batches (changes max)
  "CHANGES (`drgnx-history--changes') in lists that each insert at most MAX bytes, in order; a change that alone
inserts more is split (`drgnx-history--pieces')."
  (let ((batches nil) (cur nil) (size 0))
    (dolist (c changes)
      (dolist (p (drgnx-history--pieces c max))
        (let ((bytes (string-bytes (plist-get p :inserted))))
          (when (and cur (> (+ size bytes) max))
            (push (nreverse cur) batches) (setq cur nil size 0))
          (push p cur) (setq size (+ size bytes)))))
    (when cur (push (nreverse cur) batches))
    (nreverse batches)))

(defmacro drgnx-history-with-origin (origin &rest body)
  "Run BODY with its changes to tracked buffers recorded as ORIGIN's (a string such as \"external:git\" or
\"agent:SESSION#STEP\"), not the user's.  Emacs's undo of them, run later, is the user's."
  (declare (indent 1) (debug t))
  `(let ((nidhogg-history-origin ,origin)) ,@body))

;;;; Tracking

(defun drgnx-history-tracked-p (&optional buffer)
  "Non-nil when BUFFER (default the current one) is registered with the hub: an indirect buffer is its base's."
  (let* ((b (or buffer (current-buffer))) (st (gethash (or (buffer-base-buffer b) b) drgnx-history--buffers)))
    (and st (drgnx-history--st-registered st) t)))

(defun drgnx-history-ask (buffer method callback &optional params)
  "Ask the hub METHOD about BUFFER's file (`:path' and `:worktree_root' are the params, PARAMS a plist more), BUFFER's
text first handed to
the hub when it is small enough to drain at once, so the hub reads what BUFFER holds.  CALLBACK gets (RESULT ERROR).
Non-nil when the question went; nil when the history does not track BUFFER or no hub is connected.  Never prompts or
waits."
  (let ((st (gethash buffer drgnx-history--buffers)))
    (when (and st (drgnx-history--st-registered st) (drgnx-history--st-root st) (drgnx-history--connected-p))
      (when (< (buffer-size buffer) drgnx-history-large-size)
        (drgnx-history-drain-now buffer))
      (drgnx-history--send method (append (list :path (drgnx-history--st-path st) :worktree_root (drgnx-history--st-root st))
                                          params)
                           callback))))

(defun drgnx-history-last-result (&optional buffer)
  "The hub's last answer about BUFFER's batches: `ok', `resync', or `resynced'; nil before any."
  (let ((st (gethash (or buffer (current-buffer)) drgnx-history--buffers)))
    (and st (drgnx-history--st-last st))))

(defun drgnx-history--candidate (buffer)
  "(ROOT . PATH) for BUFFER when it should be registered: a live, unregistered, non-indirect buffer visiting a local
file inside a git project; else nil.  ROOT is the project's folder, PATH relative to it."
  (when (and (buffer-live-p buffer) (not (buffer-base-buffer buffer)) (not (gethash buffer drgnx-history--buffers))
             (not (drgnx-large-file-p buffer)))
    (let ((file (buffer-local-value 'buffer-file-name buffer)))
      (when (and file (not (file-remote-p file)))
        (let ((root (locate-dominating-file file ".git")))
          (when root
            (cons (directory-file-name (expand-file-name root)) (file-relative-name file root))))))))

(defun drgnx-history--ensure-timer ()
  "The drain timer, running while a buffer is tracked."
  (unless (drgnx-timer-active-p 'history-drain)
    (drgnx-timer-start 'history-drain drgnx-history-drain-interval #'drgnx-history--drain
                       :repeat drgnx-history-drain-interval :owner :core)))

(defun drgnx-history--forget (buffer)
  "Stop tracking BUFFER: Nidhogg's recording, the entry, and the timer when it was the last."
  (when (gethash buffer drgnx-history--buffers)
    (remhash buffer drgnx-history--buffers)
    (when (buffer-live-p buffer) (ignore-errors (nidhogg-history-track buffer nil))))
  (when (zerop (hash-table-count drgnx-history--buffers)) (drgnx-timer-cancel 'history-drain)))

(defun drgnx-history--adopt (buffer id)
  "BUFFER is registered under ID: Nidhogg records its changes, and the drain runs."
  (when (nidhogg-history-track buffer t)
    (puthash buffer (drgnx-history--st-make :id id :registered t) drgnx-history--buffers)
    (drgnx-history--ensure-timer)))

(defun drgnx-history--registered (buffer id result err)
  "The hub's answer RESULT (or ERR) to registering BUFFER as ID."
  (let ((st (gethash buffer drgnx-history--buffers)))
    (when (and st (equal (drgnx-history--st-id st) id))
      (if (or err (not (plist-get result :tracked)))
          (drgnx-history--forget buffer)
        (setf (drgnx-history--st-registered st) t)
        ;; the hub's text is the file on disk: a buffer changed before this answer is sent whole
        (when (buffer-modified-p buffer) (drgnx-history--resync buffer st))))))

(defun drgnx-history--register (buffer root path)
  "Register BUFFER (file PATH in the project at ROOT) with the hub; Nidhogg records from now on."
  (let* ((id (format "%d-%d" (emacs-pid) (cl-incf drgnx-history--next-id)))
         (params (list :path path :worktree_root root :buffer_id id)))
    (when (drgnx-history--send "history/register" params
                               (lambda (result err) (drgnx-history--registered buffer id result err)))
      (when (nidhogg-history-track buffer t)
        (puthash buffer (drgnx-history--st-make :id id :root root :path path) drgnx-history--buffers)
        (drgnx-history--ensure-timer)))))

(defun drgnx-history--maybe-register (&optional buffer)
  "Register BUFFER (default the current one) when it is a candidate and the hub is connected."
  (let* ((b (or buffer (current-buffer))) (c (and (drgnx-history--connected-p) (drgnx-history--candidate b))))
    (when c (drgnx-history--register b (car c) (cdr c)))))

(defun drgnx-history--found ()
  "`find-file-hook': register the visited file."
  (drgnx-history--maybe-register))

(defun drgnx-history--killed ()
  "`kill-buffer-hook': the hub stops expecting the buffer."
  (let ((st (gethash (current-buffer) drgnx-history--buffers)))
    (when st
      (drgnx-history--send "history/unregister" (list :buffer_id (drgnx-history--st-id st)) #'ignore)
      (drgnx-history--forget (current-buffer)))))

(defun drgnx-history--hub-gone ()
  "The hub went: its registrations are gone with it; the next connection registers the buffers again."
  (let ((all nil)) (maphash (lambda (b _) (push b all)) drgnx-history--buffers)
       (mapc #'drgnx-history--forget all)))

(defun drgnx-history--hub-connected ()
  "A hub connected: register the file buffers."
  (dolist (b (buffer-list)) (drgnx-history--maybe-register b)))

(defun drgnx-history--auto-revert (fn &rest args)
  "Around `auto-revert-handler': the text a revert reads from disk is the world's, not the user's."
  (drgnx-history-with-origin "external:disk" (apply fn args)))

;;;; The drain

(defun drgnx-history--gap (buffer st)
  "BUFFER's changes since its last drain went unsent: a drain of its own, told to the listeners as `resync'."
  (cl-incf (drgnx-history--st-drains st))
  (when drgnx-history-drained-functions (drgnx-history--tell buffer st 'resync)))

(defun drgnx-history--resync (buffer st)
  "Send BUFFER's whole text; what the ring holds is part of it, so it is dropped (a gap for the listeners)."
  (unless (drgnx-history--st-resyncing st)
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (nidhogg-history-drain buffer)
        (setf (drgnx-history--st-resyncing st) t
              (drgnx-history--st-hashing st) nil)         ; a hash on its way is of text this one replaces
        (drgnx-history--gap buffer st)
        (unless (drgnx-history--send "history/resync"
                                     (list :buffer_id (drgnx-history--st-id st)
                                           :text (buffer-substring-no-properties (point-min) (point-max))
                                           :version (drgnx-history--st-drains st))
                                     (lambda (_result err)
                                       (setf (drgnx-history--st-resyncing st) nil)
                                       (if err (drgnx-history--forget buffer)
                                         (setf (drgnx-history--st-last st) 'resynced))))
          (drgnx-history--forget buffer))))))

(defun drgnx-history--batch-replied (buffer st result err)
  "The hub's answer to the last batch of a drain."
  (cond (err (drgnx-history--forget buffer))
        ((plist-get result :resync)
         (setf (drgnx-history--st-last st) 'resync)
         (drgnx-history--resync buffer st))
        ((not (drgnx-history--st-resyncing st)) (setf (drgnx-history--st-last st) 'ok))))

(defun drgnx-history--idle-time ()
  "How long Emacs has been idle (`current-idle-time'), or nil."
  (current-idle-time))

(defun drgnx-history--due-p (buffer)
  "Whether BUFFER's ring may go now: a small buffer always; a large one only after Emacs has been idle for
`drgnx-history-idle-delay', because the hub checks every batch against the hash of the buffer's whole text, which
costs the buffer's size in copying (the hash itself runs on a worker) and must not sit between two keystrokes.  The
changes wait in the ring."
  (or (< (buffer-size buffer) drgnx-history-large-size)
      (let ((idle (drgnx-history--idle-time)))
        (and idle (>= (float-time idle) drgnx-history-idle-delay)))))

(defun drgnx-history--send-batches (buffer st changes hash)
  "Send CHANGES, drained from BUFFER's ring, with HASH of the text they lead to; tell the listeners once they went."
  (let* ((batches (drgnx-history--batches changes drgnx-history-batch-max))
         (id (drgnx-history--st-id st)) (sent t)
         (version (1+ (drgnx-history--st-drains st))))
    (while batches
      (let* ((batch (pop batches)) (lastp (null batches)))
        (unless (drgnx-history--send "history/batch"
                                     (list :buffer_id id :changes batch :region_hash hash :version version)
                                     (if lastp (lambda (r e) (drgnx-history--batch-replied buffer st r e)) #'ignore))
          (setq batches nil sent nil)
          (drgnx-history--forget buffer))))
    (when sent
      (cl-incf (drgnx-history--st-drains st))
      (when drgnx-history-drained-functions (drgnx-history--tell buffer st changes)))))

(defun drgnx-history--hashed (buffer st token changes hash)
  "A worker's HASH of BUFFER's text at a drain has landed: send that drain's CHANGES, unless the buffer went or the
whole text went instead meanwhile (`drgnx-history--resync' drops TOKEN)."
  (when (eq (drgnx-history--st-hashing st) token)
    (setf (drgnx-history--st-hashing st) nil)
    (when (and (buffer-live-p buffer) (eq (gethash buffer drgnx-history--buffers) st))
      (condition-case nil
          (drgnx-history--send-batches buffer st changes hash)
        (error (drgnx-history--forget buffer))))))

(defun drgnx-history--drain-buffer (buffer st &optional now)
  "Hand BUFFER's ring to the hub.  The hash of a large buffer's text is made on a worker and the batches go when it
lands, its ring waiting meanwhile; NOW (a caller that needs the batches gone when this returns) and a small buffer
hash at once."
  (unless (drgnx-history--st-hashing st)
    (let ((drained (nidhogg-history-drain buffer)))
      (cond ((null drained))
            ((eq drained 'resync) (drgnx-history--resync buffer st))
            ((drgnx-history--st-resyncing st) (drgnx-history--gap buffer st))  ; the text on its way includes these
            (t (let ((changes (drgnx-history--changes drained)))
                 (if (or now (< (buffer-size buffer) drgnx-history-large-size))
                     (drgnx-history--send-batches buffer st changes (nidhogg-buffer-sha256 buffer))
                   (let ((token (list 'hashing)))
                     (setf (drgnx-history--st-hashing st) token)
                     (nidhogg-buffer-sha256-async
                      buffer (lambda (hash) (drgnx-history--hashed buffer st token changes hash)))))))))))

(defun drgnx-history--tell (buffer st changes)
  "Tell `drgnx-history-drained-functions' that BUFFER's CHANGES went; a listener that signals is skipped."
  (dolist (fn drgnx-history-drained-functions)
    (condition-case nil (funcall fn buffer (drgnx-history--st-drains st) changes) (error nil))))

(defun drgnx-history-drain-now (&optional buffer)
  "Hand BUFFER's (default the current one) ring to the hub now, its listeners told, and return its drain counter:
the version of its text from then on.  Nil when the history does not track it.  Never prompts, waits or signals."
  (let* ((b (or buffer (current-buffer))) (st (gethash b drgnx-history--buffers)))
    (when (and st (drgnx-history--st-registered st))
      (condition-case nil (drgnx-history--drain-buffer b st t) (error (drgnx-history--forget b)))
      (and (eq (gethash b drgnx-history--buffers) st) (drgnx-history--st-drains st)))))

(defun drgnx-history-resyncing-p ()
  "Whether some buffer's whole text is on its way to the hub (`history/resync')."
  (catch 'yes
    (maphash (lambda (_b st) (when (drgnx-history--st-resyncing st) (throw 'yes t))) drgnx-history--buffers)
    nil))

(defun drgnx-history--drain ()
  "The `history-drain' timer: when Nidhogg's rings hold changes, send them.  Never prompts, waits or signals."
  (when (nidhogg-history-pending-p)
    (let ((all nil))
      (maphash (lambda (b st) (when (drgnx-history--st-registered st) (push (cons b st) all)))
               drgnx-history--buffers)
      (dolist (e all)
        (when (gethash (car e) drgnx-history--buffers)
          (condition-case nil
              (cond ((drgnx-large-file-p (car e))      ; a revert turned it into a large file: no producer
                     (drgnx-history--send "history/unregister" (list :buffer_id (drgnx-history--st-id (cdr e))) #'ignore)
                     (drgnx-history--forget (car e)))
                    ((drgnx-history--due-p (car e)) (drgnx-history--drain-buffer (car e) (cdr e))))
            (error (drgnx-history--forget (car e)))))))))

;;;; The mode

(define-minor-mode drgnx-history-mode
  "Track project file buffers and send their changes to the hub's edit history.
Stays off in an Emacs without Nidhogg's change hook."
  :global t :group 'drgnx
  (cond ((and drgnx-history-mode (not (drgnx-history--primitives-p)))
         (setq drgnx-history-mode nil))
        (drgnx-history-mode
         (add-hook 'find-file-hook #'drgnx-history--found)
         (add-hook 'kill-buffer-hook #'drgnx-history--killed)
         (add-hook 'drgnx-hub-connected-functions #'drgnx-history--hub-connected)
         (add-hook 'drgnx-hub-disconnect-functions #'drgnx-history--hub-gone)
         (advice-add 'auto-revert-handler :around #'drgnx-history--auto-revert)
         (drgnx-history--hub-connected))
        (t
         (remove-hook 'find-file-hook #'drgnx-history--found)
         (remove-hook 'kill-buffer-hook #'drgnx-history--killed)
         (remove-hook 'drgnx-hub-connected-functions #'drgnx-history--hub-connected)
         (remove-hook 'drgnx-hub-disconnect-functions #'drgnx-history--hub-gone)
         (advice-remove 'auto-revert-handler #'drgnx-history--auto-revert)
         (let ((all nil))
           (maphash (lambda (b st)
                      (drgnx-history--send "history/unregister" (list :buffer_id (drgnx-history--st-id st)) #'ignore)
                      (push b all))
                    drgnx-history--buffers)
           (mapc #'drgnx-history--forget all))
         (drgnx-timer-cancel 'history-drain))))

(provide 'drgnx-history)
;;; drgnx-history.el ends here
