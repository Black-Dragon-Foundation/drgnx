;;; drgnx-keys-edit.el --- Writing the keys settings: bind, unbind, reset, undo -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The writer behind the Keyboard Shortcuts editor (docs/guide/shortcuts.md).  It changes the entries of the settings
;; `drgnx-keys-bind', `drgnx-keys-unbind' and `drgnx-keys-tty-fallback' one at a time, in settings.el, and touches
;; nothing else: comments, `drgnx-keys-layers', the other entries and the layout stay as you wrote them.  A
;; settings.el that does not read is reported and never written.  Every write keeps the previous values of what it
;; changed in the state folder for one `drgnx-keys-edit-undo' (refused when settings.el has changed since) and
;; applies the keys at once.  See docs/guide/keys.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-keys)
(require 'drgnx-tty-fallback)

(defconst drgnx-keys-edit--vars
  '((:bind . drgnx-keys-bind) (:unbind . drgnx-keys-unbind) (:tty-fallback . drgnx-keys-tty-fallback))
  "The lists the editor changes and the settings that hold them.")

(defvar drgnx-keys-edit--data nil
  "While a change is computed (`drgnx-keys-edit--modify'): the working copy, a plist (:bind LIST :unbind LIST
:tty-fallback LIST) of the three settings' values as settings.el has them now.")

(defun drgnx-keys-edit--undo-file ()
  "keys-edit.undo in the state folder: what the last change made here replaced, as (:old ALIST :new ALIST).
In :old, an element is (VAR . :absent) for a setting that had no entry and (VAR VALUE)
otherwise; in :new, (VAR . VALUE)."
  (let ((default-directory "/")) (expand-file-name "keys-edit.undo" (drgnx-state-dir))))

;;;; Editing the lists (the working copy)

(defun drgnx-keys-edit--elements (key)
  "The elements of KEY's list in the working copy."
  (plist-get drgnx-keys-edit--data key))

(defun drgnx-keys-edit--element-id (form) (if (consp form) (car form) form))

(defun drgnx-keys-edit--same-id-p (a b)
  "Whether the list elements' ids A and B are the same: command ids (symbols) by identity, chords (key
strings) as keys."
  (if (and (stringp a) (stringp b)) (drgnx-keys-edit--same-key-p a b) (eq a b)))

(defun drgnx-keys-edit--remove (key id)
  "Remove the elements of KEY's list for ID (all of them with ID nil)."
  (setf (plist-get drgnx-keys-edit--data key)
        (and id (seq-remove (lambda (e) (eq (drgnx-keys-edit--element-id e) id)) (drgnx-keys-edit--elements key)))))

(defun drgnx-keys-edit--put (key id form)
  "Make FORM (an element) the one for ID in KEY's list: replace the first, drop other copies, or add at the end."
  (let* ((elems (drgnx-keys-edit--elements key))
         (hit (seq-position elems id (lambda (e i) (drgnx-keys-edit--same-id-p (drgnx-keys-edit--element-id e) i)))))
    (setf (plist-get drgnx-keys-edit--data key)
          (if hit
              (let ((n -1))
                (delq nil (mapcar (lambda (e)
                                    (cl-incf n)
                                    (cond ((= n hit) form)
                                          ((drgnx-keys-edit--same-id-p (drgnx-keys-edit--element-id e) id) nil)
                                          (t e)))
                                  elems)))
            (append elems (list form))))))

;;;; Entries: (ID KEY… [:none [REASON]] [:map M] [:mac KEY…])

(defun drgnx-keys-edit--entry-form (id keys none opts)
  "The entry: ID, KEYS (or NONE, the `:none' part, when there are none), then the plist OPTS."
  (cons id (append (or keys none) opts)))

(defun drgnx-keys-edit--options (plist map mac)
  "PLIST (an entry's options) without :map and :mac, then :map MAP when non-nil, then :mac when MAC is a list
(`:absent' means the entry has none)."
  (append (cl-loop for (k v) on plist by #'cddr unless (memq k '(:map :mac)) append (list k v))
          (and map (list :map map))
          (and (listp mac) (list :mac (if (= (length mac) 1) (car mac) mac)))))

(defun drgnx-keys-edit--current (id)
  "What the :bind list and the last resolution say about ID: a plist
:entry (non-nil when :bind has an entry), :main (its keys), :mac (the list after :mac, or `:absent'),
:none (the `:none [REASON]' part), :plist (its other options), :map (the place of its keys: the entry's :map, else the
resolved one), :keep-map (the :map to write back)."
  (let ((entry (seq-find (lambda (e) (eq (drgnx-keys-edit--element-id e) id)) (drgnx-keys-edit--elements :bind))))
    (if entry
        (let ((tail (cdr entry)) keys none)
          (while (stringp (car tail)) (push (pop tail) keys))
          (when (eq (car tail) :none)
            (push (pop tail) none)
            (when (stringp (car tail)) (push (pop tail) none)))
          (unless (cl-evenp (length tail))
            (user-error "drgnx-keys-bind: the entry for %s is not understood — fix it first (it was not changed)" id))
          (list :entry t :main (nreverse keys) :none (nreverse none)
                :mac (if (plist-member tail :mac) (ensure-list (plist-get tail :mac)) :absent)
                :plist tail :keep-map (plist-get tail :map)
                :map (or (plist-get tail :map) (plist-get (car (drgnx-keys-edit--resolved id)) :map))))
      (let ((b (drgnx-keys-edit--resolved id)))
        (list :main (mapcar (lambda (x) (plist-get x :key)) b) :mac :absent
              :map (plist-get (car b) :map) :keep-map (plist-get (car b) :map))))))

(defun drgnx-keys-edit--write-map (cur)
  "The :map to write for the entry CUR describes: its own, else (with no entry) the one its keys resolved to."
  (if (plist-get cur :entry) (plist-get cur :keep-map) (plist-get cur :map)))

(defun drgnx-keys-edit--resolved (id)
  (seq-filter (lambda (b) (eq (plist-get b :id) id)) (plist-get drgnx-keys-last :bindings)))

(defun drgnx-keys-edit--commit (id cur main mac map)
  "Write ID's entry with keys MAIN, :mac list MAC and place MAP; with no key left, put ID in :unbind."
  (let ((none (or (plist-get cur :none) (list :none))))
    (cond ((or main (consp mac))
           (drgnx-keys-edit--remove :unbind id)
           (drgnx-keys-edit--put :bind id (drgnx-keys-edit--entry-form
                                           id main none (drgnx-keys-edit--options (plist-get cur :plist) map mac))))
          (t (drgnx-keys-edit--remove :bind id)
             (drgnx-keys-edit--put :unbind id id)))))

;;;; Changing the settings

(defun drgnx-keys-edit--read (file)
  "FILE's text, decoded as UTF-8 as it is written."
  (with-temp-buffer (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file)) (buffer-string)))

(defvar drgnx-keys-edit--step nil
  "Inside `drgnx-keys-edit-one-step': a cons (WRITTEN . OLD), OLD what the settings were before the step's first write
\(the undo's :old).  A step inside a step shares the outer one's cons.")

(defmacro drgnx-keys-edit-one-step (&rest body)
  "Run BODY; the changes it makes to the keys settings are one step for `drgnx-keys-edit-undo'."
  (declare (indent 0))
  `(let ((drgnx-keys-edit--step (or drgnx-keys-edit--step (cons nil nil)))) ,@body))

(defun drgnx-keys-edit--undo-old (old)
  "The undo's :old for a write that replaced OLD (an alist): OLD, or inside `drgnx-keys-edit-one-step' what the
settings were before its first write (settings of OLD that it had not seen join it)."
  (let ((step drgnx-keys-edit--step))
    (if (null step) old
      (setcar step t)
      (dolist (o old) (unless (assq (car o) (cdr step)) (setcdr step (append (cdr step) (list o)))))
      (cdr step))))

(defun drgnx-keys-edit--modify (fn)
  "Run FN on the working copy of the three lists (`drgnx-keys-edit--data') and write what it changed into settings.el.
Keeps what the write replaced in the state folder for `drgnx-keys-edit-undo', applies the keys, and returns non-nil;
nil when nothing changed.  A settings.el that does not read is a `user-error' (`drgnx-settings-refused') and
nothing is written; so is a result that does not fit its setting (`drgnx-setting-check')."
  (let ((old nil))
    (drgnx-settings-area-update
     (mapcar #'cdr drgnx-keys-edit--vars)
     (lambda (current)                ; under the file's lock, on a fresh read
       (pcase-dolist (`(,var . ,value) current)       ; a list the setting refuses is not rewritten: fix it first
         (when-let* ((problem (drgnx-setting-check var value)))
           (user-error "%s does not fit (%s) — fix it first (it was not changed)" var (cdr problem))))
       (let* ((old-data (cl-loop for (key . var) in drgnx-keys-edit--vars append (list key (cdr (assq var current)))))
              (drgnx-keys-edit--data (copy-tree old-data)))
         (funcall fn)
         (let ((wanted (cl-loop for (key . var) in drgnx-keys-edit--vars
                                collect (cons var (plist-get drgnx-keys-edit--data key)))))
           (pcase-dolist (`(,var . ,value) wanted)
             (unless (equal value (cdr (assq var current)))
               (when-let* ((problem (drgnx-setting-check var value)))
                 (user-error "%s does not fit (%s) — fix it first (it was not changed)" var (cdr problem)))
               (push (cons var (if (drgnx-settings-area-has-entry-p var) (list (cdr (assq var current))) :absent)) old)))
           wanted))))
    (when old
      (let ((kept (drgnx-keys-edit--undo-old (nreverse old))))
        (drgnx-file-write (drgnx-keys-edit--undo-file)
                          (list :old kept :new (drgnx-settings-area-fresh (mapcar #'car kept)))))
      (drgnx-keys-edit--applied)
      t)))

(defun drgnx-keys-edit--applied ()
  "Apply the keys now, once they have been applied in this session."
  (when drgnx-keys-last
    (drgnx-keys-apply)
    (when (fboundp 'drgnx-surfaces-refresh) (drgnx-surfaces-refresh))))

(defun drgnx-keys-edit--check-id (id)
  (unless (and id (symbolp id)) (user-error "%S is not a command id" id)))

(defun drgnx-keys-edit--check-key (key)
  (unless (and (stringp key) (key-valid-p key)) (user-error "%S is not a key" key)))

(defun drgnx-keys-edit--same-key-p (a b)
  (or (equal a b) (ignore-errors (equal (key-parse a) (key-parse b)))))

(defun drgnx-keys-edit--mac-slot-p (cur)
  "Non-nil if on this machine ID's keys are the entry's :mac keys (macOS, and the entry has :mac)."
  (and (eq (drgnx-platform) 'macos) (listp (plist-get cur :mac))))

(defun drgnx-keys-edit--change (id map compute)
  "Change ID's keys: COMPUTE gets (MAIN MAC) and returns (MAIN MAC) or nil for no change.
MAP, when given, must be the place of ID's keys (the editor's \"where\")."
  (drgnx-keys-edit--modify
   (lambda ()
     (let ((cur (drgnx-keys-edit--current id)))
       (when (or (null map) (equal map (plist-get cur :map)))
         (when-let* ((new (funcall compute (plist-get cur :main) (plist-get cur :mac))))
           (drgnx-keys-edit--commit id cur (car new) (cadr new) (drgnx-keys-edit--write-map cur))))))))

(defun drgnx-keys-edit--without (keys key) (seq-remove (lambda (k) (drgnx-keys-edit--same-key-p k key)) keys))

(defun drgnx-keys-edit--has (keys key) (seq-some (lambda (k) (drgnx-keys-edit--same-key-p k key)) keys))

;;;###autoload
(defun drgnx-keys-edit-bind (id keys &optional map)
  "Give command ID the key or keys KEYS (a string or a list of strings) in `drgnx-keys-bind', replacing its keys.
On macOS, for an entry that has a `:mac' list, the :mac keys are replaced instead.  Its other options (`:mac' on
other systems, a `:none' reason) are kept.  MAP is the keymap symbol or (FEATURE . KEYMAP) the keys belong to, nil
for global.  Returns non-nil if written."
  (drgnx-keys-edit--check-id id)
  (let ((keys (ensure-list keys)))
    (unless keys (user-error "%S is not a key or a list of keys" keys))
    (mapc #'drgnx-keys-edit--check-key keys)
    (drgnx-keys-edit--modify
     (lambda ()
       (let ((cur (drgnx-keys-edit--current id)))
         (if (drgnx-keys-edit--mac-slot-p cur)
             (drgnx-keys-edit--commit id cur (plist-get cur :main) keys map)
           (drgnx-keys-edit--commit id cur keys (plist-get cur :mac) map)))))))

;;;###autoload
(defun drgnx-keys-edit-add (id key &optional map)
  "Give command ID the key KEY as well, keeping the keys it has (those of `drgnx-keys-bind' or of the last resolution).
MAP is the place of its keys (see `drgnx-keys-edit-unbind'); for a command with no keys yet it is the place of KEY.
Returns non-nil if written, nil when ID has KEY already."
  (drgnx-keys-edit--check-id id)
  (drgnx-keys-edit--check-key key)
  (drgnx-keys-edit--modify
   (lambda ()
     (let ((cur (drgnx-keys-edit--current id)))
       (unless (and (plist-get cur :map) map (not (equal map (plist-get cur :map))))
         (let ((main (plist-get cur :main)) (mac (plist-get cur :mac)))
           (unless (or (drgnx-keys-edit--has main key) (and (listp mac) (drgnx-keys-edit--has mac key)))
             (if (drgnx-keys-edit--mac-slot-p cur)
                 (setq mac (append mac (list key)))
               (setq main (append main (list key))))
             (drgnx-keys-edit--commit id cur main mac (or (drgnx-keys-edit--write-map cur) map)))))))))

;;;###autoload
(defun drgnx-keys-edit-replace (id old-key new-key &optional map)
  "Give command ID NEW-KEY in place of OLD-KEY, keeping its other keys, in one write (one undo step).
MAP is the place of the keys (see `drgnx-keys-edit-unbind').  Returns non-nil if written, nil when ID does not
have OLD-KEY."
  (drgnx-keys-edit--check-id id)
  (drgnx-keys-edit--check-key new-key)
  (drgnx-keys-edit--change
   id map
   (lambda (main mac)
     (cl-flet ((swap (keys) (delete-dups
                             (mapcar (lambda (k) (if (drgnx-keys-edit--same-key-p k old-key) new-key k)) keys))))
       (when (or (drgnx-keys-edit--has main old-key) (and (listp mac) (drgnx-keys-edit--has mac old-key)))
         (list (swap main) (if (listp mac) (swap mac) mac)))))))

;;;###autoload
(defun drgnx-keys-edit-unbind (id key &optional map)
  "Take KEY away from command ID.
The keys ID keeps are written as its `drgnx-keys-bind' entry (its `:mac' keys and other options stay); with none left
ID goes into `drgnx-keys-unbind'.  MAP, when given, must be the place of ID's keys: its entry's `:map', else the one
it resolved to.  Returns non-nil if written; nil when ID does not have KEY."
  (drgnx-keys-edit--check-id id)
  (drgnx-keys-edit--change
   id map
   (lambda (main mac)
     (let ((main2 (drgnx-keys-edit--without main key)) (mac2 (if (listp mac) (drgnx-keys-edit--without mac key) mac)))
       (unless (and (equal main main2) (equal mac mac2)) (list main2 mac2))))))

;;;; The terminal fallback

(defun drgnx-keys-edit--tty-fallback-problem (chord key)
  "Why KEY (an Alt+Shift key, \"M-Z\") cannot be the fallback of CHORD in a legacy terminal, or nil when it can:
CHORD must be one the active key profile has and a legacy terminal cannot send; KEY goes through the layer's own
checks (`drgnx-tty-fallback--why-not'): not reserved, not Emacs's or the profile's, not kept by the selected
terminal, not already another chord's fallback in `drgnx-keys-tty-fallback'."
  (let* ((keys (drgnx-tty-fallback--profile-keys))
         (needed (drgnx-tty-fallback-chords keys))
         (frame (selected-frame))
         (caps (and (not (display-graphic-p frame)) (terminal-parameter (frame-terminal frame) 'drgnx-tty-caps)))
         (takes (plist-get (and caps (drgnx-tty-terminal (plist-get caps :id))) :takes))
         (taken (seq-filter (lambda (o) (and (consp o) (stringp (car o)) (stringp (cdr o))
                                             (not (drgnx-keys-edit--same-key-p (car o) chord))))
                            (drgnx-tty-fallback--overrides))))
    (if (not (seq-some (lambda (c) (drgnx-keys-edit--same-key-p c chord)) needed))
        (format "%s needs no fallback: the profile has no such key, or a plain terminal sends it" chord)
      (drgnx-tty-fallback--why-not key (or (bound-and-true-p drgnx-keys--defaults) global-map) keys takes taken))))

;;;###autoload
(defun drgnx-keys-edit-set-tty-fallback (chord key)
  "Make KEY (Alt plus a character, \"M-Z\") the key a legacy terminal sends for CHORD (\"C-S-p\"): the entry
\"(CHORD . KEY)\" of `drgnx-keys-tty-fallback', replacing the chord's earlier one.  A KEY the layer could not
use (reserved, Emacs's or the profile's, kept by the terminal, another chord's) is a `user-error' with the reason,
and nothing is written.  Returns non-nil if written."
  (drgnx-keys-edit--check-key chord)
  (drgnx-keys-edit--check-key key)
  (when-let* ((why (drgnx-keys-edit--tty-fallback-problem chord key)))
    (user-error "%s" why))
  (drgnx-keys-edit--modify
   (lambda () (drgnx-keys-edit--put :tty-fallback chord (cons chord key)))))

;;;###autoload
(defun drgnx-keys-edit-reset (id)
  "Remove ID's entries from `drgnx-keys-bind' and `drgnx-keys-unbind', so it has the profile's keys again."
  (drgnx-keys-edit--check-id id)
  (drgnx-keys-edit--modify
   (lambda () (drgnx-keys-edit--remove :bind id) (drgnx-keys-edit--remove :unbind id))))

;;;###autoload
(defun drgnx-keys-edit-reset-all ()
  "Remove every entry from `drgnx-keys-bind' and `drgnx-keys-unbind' (`drgnx-keys-layers' and comments stay)."
  (drgnx-keys-edit--modify
   (lambda () (drgnx-keys-edit--remove :bind nil) (drgnx-keys-edit--remove :unbind nil))))

;;;###autoload
(defun drgnx-keys-edit-undo ()
  "Put the keys settings back as they were before the last change made here (one step).
A setting that had no entry gets none again, through the resolver.  Refused, with nothing written, when settings.el
no longer holds what that change wrote (something else changed it since)."
  (let* ((undo (drgnx-keys-edit--undo-file))
         (saved (and (file-exists-p undo)
                     (condition-case nil (car (read-from-string (drgnx-keys-edit--read undo))) (error nil)))))
    (cond ((not (file-exists-p undo)) (user-error "Nothing to undo in the keys settings"))
          ((not (and saved (proper-list-p saved) (consp (plist-get saved :old)) (proper-list-p (plist-get saved :new))
                     (seq-every-p (lambda (o) (and (consp o) (rassq (car o) drgnx-keys-edit--vars))) (plist-get saved :old))))
           (user-error "The undo copy %s cannot be read; the keys settings were not changed" (abbreviate-file-name undo))))
    (drgnx-settings-area-ensure-writable)
    (let ((new (plist-get saved :new)))
      (unless (equal (drgnx-settings-area-fresh (mapcar #'car new)) new)
        (user-error "settings.el changed since that edit; it was not undone"))
      (pcase-dolist (`(,var . ,old) (plist-get saved :old))
        (if (eq old :absent)
            (drgnx-settings-area-unset var)
          (drgnx-settings-area-set (list (cons var (car old))))))
      (delete-file undo)
      (drgnx-keys-edit--applied)
      t)))

(provide 'drgnx-keys-edit)
;;; drgnx-keys-edit.el ends here
