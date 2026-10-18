;;; drgnx-keys-edit.el --- Writing keys.eld: bind, unbind, reset, undo -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The writer behind the Keyboard Shortcuts editor (docs/guide/shortcuts.md).  It changes the entries of
;; keys.eld's `:bind' and `:unbind' lists one at a time and touches nothing else: comments, `:layers', the
;; other entries and the layout stay as the user wrote them.  A file that does not read as a keys.eld is
;; reported and never written.  Every write keeps the previous and the new text in keys.eld.undo for one
;; `drgnx-keys-edit-undo' (refused when keys.eld has changed since) and applies the keys at once.  See docs/guide/keys.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-keys)
(require 'drgnx-tty-fallback)

(defconst drgnx-keys-edit--header
  ";; drgnx keys (docs/guide/keys.md): :layers — profile stack, :bind — (ID KEY… [:map M]),\n;; :unbind — (ID…)\n"
  "The comment a new keys.eld starts with.")

(defun drgnx-keys-edit--undo-file ()
  "keys.eld.undo: the text before and after the last change made here, as (:old TEXT-or-:absent :new TEXT)."
  (concat (drgnx-keys-file) ".undo"))

;;;; Reading and writing the text

(defun drgnx-keys-edit--check (text)
  "Why TEXT is not a keys.eld (an empty plist, or one with proper lists as :bind and :unbind); nil if it is."
  (condition-case err
      (with-temp-buffer
        (insert text)
        (set-syntax-table emacs-lisp-mode-syntax-table)
        (goto-char (point-min))
        (forward-comment (buffer-size))
        (if (eobp)
            nil
          (let ((form (read (current-buffer))))
            (cond ((not (and (consp form) (proper-list-p form) (cl-evenp (length form)) (keywordp (car form))))
                   "it is not a plist like (:layers … :bind … :unbind …)")
                  ;; plain lists only: '(…) or #'(…) would read as the symbol `quote' / `function' (and be wiped)
                  ((not (and (proper-list-p (plist-get form :bind))
                             (seq-every-p (lambda (e) (and (consp e) (symbolp (car e)) (proper-list-p e))) (plist-get form :bind))))
                   ":bind is not a plain list of (ID KEY…) entries (no quote); fix it by hand")
                  ((not (and (proper-list-p (plist-get form :unbind)) (seq-every-p #'symbolp (plist-get form :unbind))))
                   ":unbind is not a plain list of command ids (no quote); fix it by hand")))))
    (error (format "it cannot be read (%s)" (error-message-string err)))))

(defun drgnx-keys-edit--write-file (file text)
  "Replace FILE by TEXT (as UTF-8) through a temp file, so a stale buffer is never asked about.  A symlink FILE
is written through, so it stays a link; FILE keeps its permissions (a new one gets the default ones)."
  (let* ((file (file-truename file))
         (modes (or (file-modes file) (default-file-modes)))
         (tmp (progn (make-directory (file-name-directory file) t)
                     (make-temp-file (expand-file-name ".keys-" (file-name-directory file))))))
    (condition-case err
        (progn (let ((coding-system-for-write 'utf-8-unix)) (with-temp-file tmp (insert text)))
               (set-file-modes tmp modes)
               (rename-file tmp file t))
      (error (ignore-errors (delete-file tmp)) (signal (car err) (cdr err))))))

;;;; Editing the text in a buffer (point-min, emacs-lisp syntax)

(defun drgnx-keys-edit--open (&optional create)
  "Go inside the plist form and return its start; with CREATE add `()' after the comments if there is none,
else return nil when there is none."
  (goto-char (point-min))
  (forward-comment (buffer-size))
  (when (and (eobp) create)
    (unless (bolp) (insert "\n"))
    (insert "()\n")
    (goto-char (point-min))
    (forward-comment (buffer-size)))
  (unless (eobp) (prog1 (point) (down-list 1))))

(defun drgnx-keys-edit--value (key)
  "The (BEG . END) of KEY's value in the top-level plist, or nil.  Point goes anywhere."
  (let ((start (drgnx-keys-edit--open)) found)
    (while (and start (not found) (progn (forward-comment (buffer-size)) (not (eq (char-after) ?\)))))
      (let ((k (read (current-buffer))))
        (forward-comment (buffer-size))
        (let ((beg (point)))
          (forward-sexp 1)
          (when (eq k key) (setq found (cons beg (point)))))))
    found))

(defun drgnx-keys-edit--ensure-list (key)
  "Make KEY's value a list (adding KEY, or turning a literal `nil' into `()'); return the (BEG . END) of
that list.  Any other value is a `user-error': it is never replaced."
  (or (when-let* ((v (drgnx-keys-edit--value key)))
        (cond ((eq (char-after (car v)) ?\() v)
              ((equal (buffer-substring (car v) (cdr v)) "nil")
               (goto-char (car v))
               (delete-region (car v) (cdr v))
               (insert "()")
               (cons (car v) (point)))
              (t (user-error "keys.eld: %s is not a plain list; fix it by hand — nothing was changed" key))))
      (let* ((start (drgnx-keys-edit--open t)) (close (1- (scan-sexps start 1))))
        (goto-char close)
        (let ((empty (save-excursion (skip-chars-backward " \t\n") (= (point) (1+ start)))))
          (if (and (not empty) (save-excursion (skip-chars-backward " \t") (bolp)))
              (progn (beginning-of-line) (insert (format " %s ()\n" key)))   ; the paren has its own line
            (insert (if empty "" "\n ") (format "%s ()" key))))
        (drgnx-keys-edit--value key))))

(defun drgnx-keys-edit--elements (key)
  "The elements of KEY's list: ((BEG END FORM)… ) in file order, and the position of the closing paren."
  (when-let* ((v (drgnx-keys-edit--value key)))
    (when (eq (char-after (car v)) ?\()
      (goto-char (car v))
      (down-list 1)
      (let (elems)
        (while (progn (forward-comment (buffer-size)) (not (eq (char-after) ?\))))
          (let ((beg (point)))
            (forward-sexp 1)
            (push (list beg (point) (car (read-from-string (buffer-substring beg (point))))) elems)))
        (cons (nreverse elems) (point))))))

(defun drgnx-keys-edit--element-id (form) (if (consp form) (car form) form))

(defun drgnx-keys-edit--delete-element (beg end)
  "Delete the element BEG..END of a list: its own line with its trailing comment, else just the element."
  (goto-char end)
  (skip-chars-forward " \t")
  (when (eq (char-after) ?\;) (end-of-line))
  (let ((rest-blank (or (eolp) (eobp)))
        (own-line (save-excursion (goto-char beg) (skip-chars-backward " \t") (bolp)))
        (after (point)))
    (cond ((and rest-blank own-line)
           (delete-region (save-excursion (goto-char beg) (line-beginning-position)) (min (point-max) (1+ after))))
          (rest-blank (delete-region beg after))
          (t (goto-char end) (skip-chars-forward " \t") (delete-region beg (point))))))

(defun drgnx-keys-edit--remove (key id)
  "Remove the elements of KEY's list for ID (all of them with ID nil), last first."
  (dolist (e (reverse (car (drgnx-keys-edit--elements key))))
    (when (or (null id) (eq (drgnx-keys-edit--element-id (nth 2 e)) id))
      (drgnx-keys-edit--delete-element (nth 0 e) (nth 1 e)))))

(defun drgnx-keys-edit--same-id-p (a b)
  "Whether the list elements' ids A and B are the same: command ids (symbols) by identity, chords (key
strings) as keys."
  (if (and (stringp a) (stringp b)) (drgnx-keys-edit--same-key-p a b) (eq a b)))

(defun drgnx-keys-edit--put (key id text)
  "Make TEXT (an element) the one for ID in KEY's list: replace the first, drop other copies, or add at the end."
  (drgnx-keys-edit--ensure-list key)
  (let* ((found (seq-filter (lambda (e) (drgnx-keys-edit--same-id-p (drgnx-keys-edit--element-id (nth 2 e)) id))
                            (car (drgnx-keys-edit--elements key)))))
    (if found
        (progn (dolist (e (reverse (cdr found))) (drgnx-keys-edit--delete-element (nth 0 e) (nth 1 e)))
               (let ((e (car found)))
                 (goto-char (nth 0 e)) (delete-region (nth 0 e) (nth 1 e)) (insert text)))
      (pcase-let ((`(,elems . ,close) (drgnx-keys-edit--elements key)))
        (goto-char close)
        (cond ((null elems) (insert text))
              ((save-excursion (skip-chars-backward " \t") (bolp))
               (let ((col (save-excursion (goto-char (nth 0 (car elems))) (current-column))))
                 (beginning-of-line) (insert (make-string col ?\s) text "\n")))
              (t (let ((col (save-excursion (goto-char (nth 0 (car elems))) (current-column))))
                   (insert "\n" (make-string col ?\s) text))))))))


;;;; Entries: (ID KEY… [:none [REASON]] [:map M] [:mac KEY…])

(defun drgnx-keys-edit--entry-text (id keys none opts)
  "The text of an entry: ID, KEYS (or NONE, the `:none' part, when there are none), then the plist OPTS."
  (format "(%S%s%s)" id
          (mapconcat (lambda (x) (concat " " (prin1-to-string x))) (or keys none) "")
          (mapconcat (lambda (x) (concat " " (prin1-to-string x))) opts "")))

(defun drgnx-keys-edit--options (plist map mac)
  "PLIST (an entry's options) without :map and :mac, then :map MAP when non-nil, then :mac when MAC is a list
(`:absent' means the entry has none)."
  (append (cl-loop for (k v) on plist by #'cddr unless (memq k '(:map :mac)) append (list k v))
          (and map (list :map map))
          (and (listp mac) (list :mac (if (= (length mac) 1) (car mac) mac)))))

(defun drgnx-keys-edit--current (id)
  "What keys.eld (in the buffer) and the last resolution say about ID: a plist
:entry (non-nil when keys.eld has an entry), :main (its keys), :mac (the list after :mac, or `:absent'),
:none (the `:none [REASON]' part), :plist (its other options), :map (the place of its keys: the entry's :map, else the
resolved one), :keep-map (the :map to write back)."
  (let ((entry (seq-find (lambda (e) (eq (drgnx-keys-edit--element-id (nth 2 e)) id))
                         (car (drgnx-keys-edit--elements :bind)))))
    (if entry
        (let ((tail (cdr (nth 2 entry))) keys none)
          (while (stringp (car tail)) (push (pop tail) keys))
          (when (eq (car tail) :none)
            (push (pop tail) none)
            (when (stringp (car tail)) (push (pop tail) none)))
          (unless (cl-evenp (length tail))
            (user-error "%s: the entry for %s is not understood — fix it first (it was not changed)"
                        (abbreviate-file-name (drgnx-keys-file)) id))
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
           (drgnx-keys-edit--put :bind id (drgnx-keys-edit--entry-text
                                           id main none (drgnx-keys-edit--options (plist-get cur :plist) map mac))))
          (t (drgnx-keys-edit--remove :bind id)
             (drgnx-keys-edit--put :unbind id (format "%S" id))))))

;;;; Changing keys.eld

(defun drgnx-keys-edit--read (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defvar drgnx-keys-edit--step nil
  "Inside `drgnx-keys-edit-one-step': a cons (WRITTEN . OLD), OLD keys.eld's text before the step's first write.
A step inside a step shares the outer one's cons.")

(defmacro drgnx-keys-edit-one-step (&rest body)
  "Run BODY; the changes it makes to keys.eld are one step for `drgnx-keys-edit-undo'."
  (declare (indent 0))
  `(let ((drgnx-keys-edit--step (or drgnx-keys-edit--step (cons nil nil)))) ,@body))

(defun drgnx-keys-edit--undo-old (old)
  "The text undo goes back to: OLD, or inside `drgnx-keys-edit-one-step' the text before its first write."
  (let ((step drgnx-keys-edit--step))
    (cond ((null step) old)
          ((car step) (cdr step))
          (t (setcar step t) (setcdr step old) old))))

(defun drgnx-keys-edit--modify (fn)
  "Run FN in a buffer holding keys.eld's text (a header if there is none) and write the result.
A file that does not read, or a result that does not, is a `user-error' and nothing is written.  Keeps the
previous and the new text in keys.eld.undo for `drgnx-keys-edit-undo', applies the keys, and returns non-nil;
nil when nothing changed."
  (let* ((file (file-truename (drgnx-keys-file))) (existed (file-exists-p file))
         (old (if existed (drgnx-keys-edit--read file) drgnx-keys-edit--header)))
    (when-let* ((why (drgnx-keys-edit--check old)))
      (user-error "%s %s — fix it first (it was not changed)" (abbreviate-file-name file) why))
    (let ((new (with-temp-buffer
                 (insert old)
                 (set-syntax-table emacs-lisp-mode-syntax-table)
                 (funcall fn)
                 (buffer-string))))
      (unless (equal new old)
        (when-let* ((why (drgnx-keys-edit--check new)))
          (error "drgnx keys.eld writer produced a file that %s" why))
        (drgnx-keys-edit--write-file
         (drgnx-keys-edit--undo-file)
         (let ((print-length nil) (print-level nil)) (prin1-to-string (list :old (drgnx-keys-edit--undo-old (if existed old :absent)) :new new))))
        (drgnx-keys-edit--write-file file new)
        (drgnx-keys-edit--applied)
        t))))

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
  "Give command ID the key or keys KEYS (a string or a list of strings) in keys.eld, replacing its keys.
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
  "Give command ID the key KEY as well, keeping the keys it has (those of keys.eld or of the last resolution).
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
The keys ID keeps are written as its keys.eld entry (its `:mac' keys and other options stay); with none left ID
goes into :unbind.  MAP, when given, must be the place of ID's keys: its entry's `:map', else the one it resolved
to.  Returns non-nil if written; nil when ID does not have KEY."
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
terminal, not already another chord's fallback in keys.eld."
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
\"(CHORD . KEY)\" of keys.eld's `:tty-fallback', replacing the chord's earlier one.  A KEY the layer could not
use (reserved, Emacs's or the profile's, kept by the terminal, another chord's) is a `user-error' with the reason,
and nothing is written.  Returns non-nil if written."
  (drgnx-keys-edit--check-key chord)
  (drgnx-keys-edit--check-key key)
  (when-let* ((why (drgnx-keys-edit--tty-fallback-problem chord key)))
    (user-error "%s" why))
  (drgnx-keys-edit--modify
   (lambda () (drgnx-keys-edit--put :tty-fallback chord (format "(%S . %S)" chord key)))))

;;;###autoload
(defun drgnx-keys-edit-reset (id)
  "Remove ID's entries from keys.eld's :bind and :unbind, so it has the profile's keys again."
  (drgnx-keys-edit--check-id id)
  (drgnx-keys-edit--modify
   (lambda () (drgnx-keys-edit--remove :bind id) (drgnx-keys-edit--remove :unbind id))))

;;;###autoload
(defun drgnx-keys-edit-reset-all ()
  "Remove every entry from keys.eld's :bind and :unbind (:layers and comments stay)."
  (drgnx-keys-edit--modify
   (lambda () (drgnx-keys-edit--remove :bind nil) (drgnx-keys-edit--remove :unbind nil))))

;;;###autoload
(defun drgnx-keys-edit-undo ()
  "Put keys.eld back as it was before the last change made here (one step).
Refused, with nothing written, when keys.eld is no longer what that change wrote (something else changed it
since)."
  (let* ((undo (drgnx-keys-edit--undo-file))
         (saved (and (file-exists-p undo)
                     (condition-case nil (car (read-from-string (drgnx-keys-edit--read undo))) (error nil)))))
    (cond ((not (file-exists-p undo)) (user-error "Nothing to undo in keys.eld"))
          ((not (and (proper-list-p saved) (stringp (plist-get saved :new))
                     (or (stringp (plist-get saved :old)) (eq (plist-get saved :old) :absent))))
           (user-error "The undo copy %s cannot be read; keys.eld was not changed" (abbreviate-file-name undo))))
    (let* ((file (file-truename (drgnx-keys-file)))
           (now (and (file-exists-p file) (drgnx-keys-edit--read file))))
      (unless (equal now (plist-get saved :new))
        (user-error "keys.eld changed since that edit; it was not undone"))
      (if (eq (plist-get saved :old) :absent)
          (delete-file file)
        (drgnx-keys-edit--write-file file (plist-get saved :old)))
      (delete-file undo)
      (drgnx-keys-edit--applied)
      t)))

(provide 'drgnx-keys-edit)
;;; drgnx-keys-edit.el ends here
