;;; drgnx-keys-edit.el --- Writing keys.eld: bind, unbind, reset, undo -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The writer behind the Keyboard Shortcuts editor (docs/guide/shortcuts.md).  It changes the entries of
;; keys.eld's `:bind' and `:unbind' lists one at a time and touches nothing else: comments, `:layers', the
;; other entries and the layout stay as the user wrote them.  A file that does not read as a keys.eld is
;; reported and never written.  Every write keeps the previous text for one `drgnx-keys-edit-undo' and
;; applies the keys at once.  See docs/guide/keys.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-keys)

(defvar drgnx-keys-edit--undo nil
  "How to undo the last write: nil, `absent' (keys.eld did not exist), or the text it had.")

(defconst drgnx-keys-edit--header
  ";; drgnx keys (docs/guide/keys.md): :layers — profile stack, :bind — (ID KEY… [:map M]),\n;; :unbind — (ID…)\n"
  "The comment a new keys.eld starts with.")

(defun drgnx-keys-edit--undo-file () (concat (drgnx-keys-file) ".undo"))

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
                  ((not (proper-list-p (plist-get form :bind))) ":bind is not a list")
                  ((not (proper-list-p (plist-get form :unbind))) ":unbind is not a list")))))
    (error (format "it cannot be read (%s)" (error-message-string err)))))

(defun drgnx-keys-edit--write (text)
  "Replace keys.eld by TEXT through a temp file, so a stale buffer is never asked about."
  (let* ((file (drgnx-keys-file))
         (tmp (progn (make-directory (file-name-directory file) t)
                     (make-temp-file (expand-file-name ".keys-" (file-name-directory file))))))
    (condition-case err
        (progn (with-temp-file tmp (insert text))
               (set-file-modes tmp #o644)
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
  "Make KEY's value a list (adding KEY, or turning `nil' into `()'); return the (BEG . END) of that list."
  (or (when-let* ((v (drgnx-keys-edit--value key)))
        (if (eq (char-after (car v)) ?\()
            v
          (goto-char (car v))
          (delete-region (car v) (cdr v))
          (insert "()")
          (cons (car v) (point))))
      (let* ((start (drgnx-keys-edit--open t)) (close (1- (scan-sexps start 1))))
        (goto-char close)
        (let ((empty (save-excursion (skip-chars-backward " \t\n") (= (point) (1+ start)))))
          (insert (if empty "" "\n ") (format "%s ()" key)))
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

(defun drgnx-keys-edit--put (key id text)
  "Make TEXT (an element) the one for ID in KEY's list: replace the first, drop other copies, or add at the end."
  (drgnx-keys-edit--ensure-list key)
  (let* ((found (seq-filter (lambda (e) (eq (drgnx-keys-edit--element-id (nth 2 e)) id))
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

(defun drgnx-keys-edit--entry-text (id keys map)
  (format "(%S %s%s)" id (mapconcat #'prin1-to-string keys " ") (if map (format " :map %S" map) "")))

;;;; Changing keys.eld

(defun drgnx-keys-edit--modify (fn)
  "Run FN in a buffer holding keys.eld's text (a header if there is none) and write the result.
A file that does not read, or a result that does not, is a `user-error' and nothing is written.  Keeps the
previous text for `drgnx-keys-edit-undo', applies the keys, and returns non-nil; nil when nothing changed."
  (let* ((file (drgnx-keys-file)) (existed (file-exists-p file))
         (old (if existed (with-temp-buffer (insert-file-contents file) (buffer-string)) drgnx-keys-edit--header)))
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
        (when existed (with-temp-file (drgnx-keys-edit--undo-file) (insert old)))
        (setq drgnx-keys-edit--undo (if existed old 'absent))
        (drgnx-keys-edit--write new)
        (drgnx-keys-edit--applied)
        t))))

(defun drgnx-keys-edit--applied ()
  "Apply the keys now, once they have been applied in this session."
  (when drgnx-keys-last
    (drgnx-keys-apply)
    (when (fboundp 'drgnx-surfaces-refresh) (drgnx-surfaces-refresh))))

(defun drgnx-keys-edit--keys-of (id)
  "The (KEY . MAP) pairs ID has now: its entry in keys.eld (point in that buffer), else the last resolution."
  (let ((entry (seq-find (lambda (e) (eq (drgnx-keys-edit--element-id (nth 2 e)) id))
                         (car (drgnx-keys-edit--elements :bind)))))
    (if entry
        (let* ((form (nth 2 entry)) (rest (cdr form)) keys)
          (while (stringp (car rest)) (push (pop rest) keys))
          (mapcar (lambda (k) (cons k (plist-get rest :map))) (nreverse keys)))
      (cl-loop for b in (plist-get drgnx-keys-last :bindings)
               when (eq (plist-get b :id) id) collect (cons (plist-get b :key) (plist-get b :map))))))

(defun drgnx-keys-edit--check-id (id)
  (unless (and id (symbolp id)) (user-error "%S is not a command id" id)))

(defun drgnx-keys-edit--same-key-p (a b)
  (or (equal a b) (ignore-errors (equal (key-parse a) (key-parse b)))))

;;;###autoload
(defun drgnx-keys-edit-bind (id keys &optional map)
  "Give command ID the key or keys KEYS (a string or a list of strings) in keys.eld, replacing its entry.
MAP is the keymap symbol or (FEATURE . KEYMAP) the keys belong to, nil for global.  Returns non-nil if written."
  (drgnx-keys-edit--check-id id)
  (let ((keys (ensure-list keys)))
    (unless (and keys (seq-every-p (lambda (k) (and (stringp k) (key-valid-p k))) keys))
      (user-error "%S is not a key or a list of keys" keys))
    (drgnx-keys-edit--modify
     (lambda ()
       (drgnx-keys-edit--remove :unbind id)
       (drgnx-keys-edit--put :bind id (drgnx-keys-edit--entry-text id keys map))))))

;;;###autoload
(defun drgnx-keys-edit-unbind (id key &optional map)
  "Take KEY (in MAP when given) away from command ID.
The keys ID keeps are written as its keys.eld entry; with none left ID goes into :unbind.  Returns non-nil if
written; nil when ID does not have KEY."
  (drgnx-keys-edit--check-id id)
  (drgnx-keys-edit--modify
   (lambda ()
     (let* ((now (drgnx-keys-edit--keys-of id))
            (rest (seq-remove (lambda (p) (and (drgnx-keys-edit--same-key-p (car p) key)
                                               (or (null map) (equal (cdr p) map))))
                              now)))
       (unless (= (length rest) (length now))
         (if rest
             (progn (drgnx-keys-edit--remove :unbind id)
                    (drgnx-keys-edit--put :bind id (drgnx-keys-edit--entry-text id (mapcar #'car rest) (cdr (car rest)))))
           (drgnx-keys-edit--remove :bind id)
           (drgnx-keys-edit--put :unbind id (symbol-name id))))))))

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
  "Put keys.eld back as it was before the last change made here (one step)."
  (unless drgnx-keys-edit--undo (user-error "Nothing to undo in keys.eld"))
  (if (eq drgnx-keys-edit--undo 'absent)
      (when (file-exists-p (drgnx-keys-file)) (delete-file (drgnx-keys-file)))
    (drgnx-keys-edit--write drgnx-keys-edit--undo))
  (when (file-exists-p (drgnx-keys-edit--undo-file)) (delete-file (drgnx-keys-edit--undo-file)))
  (setq drgnx-keys-edit--undo nil)
  (drgnx-keys-edit--applied)
  t)

(provide 'drgnx-keys-edit)
;;; drgnx-keys-edit.el ends here
