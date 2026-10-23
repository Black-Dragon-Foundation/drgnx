;;; drgnx-settings-tidy.el --- Settings: Tidy custom.el, and en/disable-command -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 30 (design §8.4).  drgnx never writes custom.el on its own: Customize, package.el and the
;; local-variables `!' answer do, as in stock Emacs.  Two things here:
;; - Settings: Tidy custom.el works on the file, not the session: it reads custom.el's `custom-set-variables' form as
;;   data, drops the entries equal to their variable's standard value, takes the duplicates out of
;;   `package-selected-packages', removes the entries of variables nothing defines when you choose them, and prints the
;;   form as Customize prints it (sorted, one entry per line, its header comment).  `custom-save-variables' is never
;;   used: it prints the session's symbol properties, which would lose hand edits made since start and add values saved
;;   this session.  Text outside the form stays as it is.  One diff preview first; a backup beside the file; one Undo.
;;   The entries left are offered to Settings: Move into Settings… (`drgnx-settings-move-plan', kind
;;   `custom-set-variables').
;; - `en/disable-command' (novice.el: enable-command, disable-command, the "disabled command" question) writes to
;;   `user-init-file', which in drgnx is the checkout's init/init.el; the advice sends it to custom.el.
;; The doctor's `custom-file' line comes from `drgnx-settings-tidy-facts'.  See docs/guide/settings.md, "Keeping
;; custom.el tidy".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-settings-move)

(defvar read-eval)

(defconst drgnx-settings-tidy--header
  '(";; custom-set-variables was added by Custom."
    ";; If you edit it by hand, you could mess it up, so be careful."
    ";; Your init file should contain only one such instance."
    ";; If there is more than one, they won't work right.")
  "Customize's comment lines at the top of its `custom-set-variables' form (`custom-save-variables').")

(defconst drgnx-settings-tidy-undo-kept 20 "The most tidies Settings: Undo Tidy remembers (this session).")

(defvar drgnx-settings-tidy--undo nil
  "This session's tidies, newest first, at most `drgnx-settings-tidy-undo-kept': their plans (see
`drgnx-settings-tidy-plan') with `:bak', the backup of custom.el.")

;;;; Reading custom.el

(defun drgnx-settings-tidy-file ()
  "custom.el: `custom-file', else custom.el in the config dir."
  (or (bound-and-true-p custom-file) (expand-file-name "custom.el" (drgnx-user-dir))))

(defun drgnx-settings-tidy--no (reason fmt &rest args)
  "Refuse: throw (:refused REASON :why TEXT) to `drgnx-settings-tidy-plan'."
  (throw 'drgnx-settings-tidy--no (list :refused reason :why (apply #'format-message fmt args))))

(defun drgnx-settings-tidy--forms (text)
  "TEXT's top-level forms read as data (`read-eval' and `read-circle' off): ((FORM BEG END)…), BEG and END its
positions in a buffer holding TEXT.  Signals when TEXT does not read to its end."
  (with-temp-buffer
    (insert text)
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (goto-char (point-min))
    (let ((read-eval nil) (read-circle nil) (forms nil))
      (while (progn (forward-comment (buffer-size)) (not (eobp)))
        (let ((beg (point)))
          (push (list (read (current-buffer)) beg (point)) forms)))
      (nreverse forms))))

(defun drgnx-settings-tidy--entry (arg)
  "ARG of a `custom-set-variables' form, `(quote (VAR VALUE [NOW [REQUESTS [COMMENT]]]))', as the list (VAR VALUE NOW
REQUESTS COMMENT); nil when ARG is not an entry of that shape."
  (pcase arg
    (`(quote (,var ,value . ,rest))
     (and (symbolp var) var (not (booleanp var)) (not (keywordp var)) (proper-list-p rest) (<= (length rest) 3)
          (list var value (nth 0 rest) (nth 1 rest) (nth 2 rest))))))

(defun drgnx-settings-tidy--foreign-comment (text beg end)
  "The first comment inside BEG..END of TEXT that is not one of Customize's header lines: (LINE . COMMENT), or nil."
  (with-temp-buffer
    (insert text)
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (goto-char beg)
    (let (found)
      (while (and (not found) (re-search-forward ";" end t))
        (let ((ppss (save-excursion (syntax-ppss (1- (point))))))
          (unless (or (nth 3 ppss) (nth 4 ppss) (nth 5 ppss))
            (let ((c (string-trim (buffer-substring-no-properties (1- (point)) (line-end-position)))))
              (unless (member c drgnx-settings-tidy--header) (setq found (cons (line-number-at-pos) c))))
            (end-of-line))))
      found)))

(defun drgnx-settings-tidy--read (file)
  "FILE's `custom-set-variables' form, read as data: (:text TEXT :forms FORMS :form (FORM BEG END) :entries ENTRIES),
ENTRIES as `drgnx-settings-tidy--entry' gives them.  A refusal thrown when FILE is missing, does not read, has no
such form or more than one, an entry Tidy does not know, a variable twice, or a comment of yours inside the form
\(printed again, it would be lost)."
  (let* ((shown (abbreviate-file-name file))
         (text (or (condition-case err (drgnx-file-read-bounded file)
                     (file-error (drgnx-settings-tidy--no 'unreadable "%s cannot be read: %s" shown
                                                          (if (eq (car err) 'drgnx-file-refused) (nth 2 err)
                                                            (error-message-string err)))))
                   (drgnx-settings-tidy--no 'missing "%s does not exist: there is nothing to tidy" shown)))
         (forms (condition-case err (drgnx-settings-tidy--forms text)
                  (error (drgnx-settings-tidy--no 'unreadable "%s does not read to its end (%s): it is not changed"
                                                  shown (error-message-string err)))))
         (csv (cl-remove-if-not (lambda (f) (eq (car-safe (car f)) 'custom-set-variables)) forms)))
    (unless csv
      (drgnx-settings-tidy--no 'no-form "%s has no `custom-set-variables' form: there is nothing to tidy" shown))
    (when (cdr csv)
      (drgnx-settings-tidy--no 'several "%s has %d `custom-set-variables' forms (Customize writes one): join them by \
hand first" shown (length csv)))
    (let* ((form (car csv))
           (entries (mapcar (lambda (arg)
                              (or (drgnx-settings-tidy--entry arg)
                                  (drgnx-settings-tidy--no 'unknown-entry "%s: Tidy does not know the entry %s: it is \
not changed" shown (drgnx-settings-move--print arg))))
                            (cdr (car form)))))
      (let ((seen nil))
        (dolist (e entries)
          (when (memq (car e) seen)
            (drgnx-settings-tidy--no 'duplicate "%s sets %s twice in its `custom-set-variables' form: keep one by hand \
first" shown (car e)))
          (push (car e) seen)))
      (when-let* ((c (drgnx-settings-tidy--foreign-comment text (nth 1 form) (nth 2 form))))
        (drgnx-settings-tidy--no 'comment "%s:%d has a comment of yours inside the `custom-set-variables' form \
\(%s); printed again the form would lose it: move it above the form first" shown (car c) (cdr c)))
      (list :text text :forms forms :form form :entries entries))))

;;;; Deciding

(defun drgnx-settings-tidy--constant (exp)
  "(VALUE) when the value expression EXP needs no code to run: self-evaluating, or quoted; else nil."
  (cond ((and (eq (car-safe exp) 'quote) (consp (cdr exp)) (null (cddr exp))) (list (cadr exp)))
        ((consp exp) nil)
        ((or (keywordp exp) (booleanp exp) (not (symbolp exp))) (list exp))))

(defun drgnx-settings-tidy--default-p (entry)
  "Non-nil when ENTRY's value is its variable's standard value (the `defcustom''s, evaluated as Customize does) and
ENTRY has no comment: such an entry changes nothing."
  (pcase-let ((`(,var ,exp ,_ ,_ ,comment) entry))
    (and (null comment) (get var 'standard-value)
         (when-let* ((v (drgnx-settings-tidy--constant exp)))
           (condition-case nil (equal (car v) (eval (car (get var 'standard-value)) t))
             (error nil))))))

(defun drgnx-settings-tidy--undefined-p (var)
  "Non-nil when nothing in this Emacs defines VAR: no value, no `defcustom' (loaded or autoloaded), no `defvar'."
  (not (or (default-boundp var) (get var 'standard-value) (get var 'custom-autoload) (get var 'custom-type)
           (special-variable-p var))))

(defun drgnx-settings-tidy--dedup (entry)
  "ENTRY of `package-selected-packages' with its duplicates taken out (first ones kept): (ENTRY . DUPLICATES)."
  (let ((v (and (eq (car entry) 'package-selected-packages) (drgnx-settings-tidy--constant (nth 1 entry)))))
    (if (not (and v (proper-list-p (car v)))) (cons entry nil)
      (let* ((list (car v)) (once (delete-dups (copy-sequence list))))
        (if (= (length once) (length list)) (cons entry nil)
          (let (dups seen)
            (dolist (p list) (if (member p seen) (push p dups) (push p seen)))
            (cons (append (list (car entry) (list 'quote once)) (nthcdr 2 entry)) (nreverse dups))))))))

;;;; Printing as Customize does

(defun drgnx-settings-tidy--print (entries)
  "ENTRIES ((VAR VALUE NOW REQUESTS COMMENT)…, in order) as Customize prints its form (`custom-save-variables'):
the header comment, one entry per line, a value printed 60 characters or longer on a line of its own, indented."
  (with-temp-buffer
    (delay-mode-hooks (emacs-lisp-mode))
    (let ((print-length nil) (print-level nil) (print-circle nil) (print-quoted t) (print-escape-newlines nil)
          (print-escape-control-characters t) (print-escape-nonascii nil) (print-escape-multibyte nil)
          (print-integers-as-characters nil) (float-output-format nil))
      (insert "(custom-set-variables\n" (mapconcat (lambda (l) (concat " " l "\n")) drgnx-settings-tidy--header ""))
      (pcase-dolist (`(,var ,exp ,now ,requests ,comment) entries)
        (unless (bolp) (insert "\n"))
        (insert " '(" (prin1-to-string var) " ")
        (let ((val (prin1-to-string exp)))
          (if (< (length val) 60) (insert val)
            (newline-and-indent)
            (let ((b (point))) (insert val) (save-excursion (goto-char b) (indent-pp-sexp 1)))))
        (when (or now requests comment)
          (insert " " (prin1-to-string now))
          (when (or requests comment)
            (insert " " (prin1-to-string requests))
            (when comment (insert " " (prin1-to-string comment)))))
        (insert ")"))
      (when (bolp) (insert " "))
      (insert ")")
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun drgnx-settings-tidy--check (forms new entries)
  "Why the text NEW is not FORMS (of `drgnx-settings-tidy--forms') with only the `custom-set-variables' form changed,
now holding ENTRIES; nil when it is exactly that."
  (condition-case err
      (let ((a (mapcar #'car forms)) (b (mapcar #'car (drgnx-settings-tidy--forms new))))
        (cond ((/= (length a) (length b)) "the number of top-level forms changed")
              ((cl-loop for x in a for y in b
                        thereis (if (eq (car-safe x) 'custom-set-variables)
                                    (not (and (eq (car-safe y) 'custom-set-variables)
                                              (equal (mapcar #'drgnx-settings-tidy--entry (cdr y)) entries)))
                                  (not (equal x y))))
               "another form changed, or the new form does not hold the entries")))
    (error (format "the new text does not read (%s)" (error-message-string err)))))

(defun drgnx-settings-tidy--plan (file remove)
  "The plan of `drgnx-settings-tidy-plan' for FILE, REMOVE the variables whose entries go; a refusal thrown."
  (let* ((r (drgnx-settings-tidy--read file))
         (text (plist-get r :text)) (forms (plist-get r :forms)) (form (plist-get r :form))
         (entries (plist-get r :entries))
         (kept nil) (dropped nil) (deduped nil) (removed nil) (undefined nil))
    (dolist (var remove)
      (unless (assq var entries) (drgnx-settings-tidy--no 'not-there "custom.el has no entry for %s" var))
      (unless (drgnx-settings-tidy--undefined-p var)
        (drgnx-settings-tidy--no 'defined "%s is defined in this Emacs: Remove is for entries nothing defines" var)))
    (dolist (e entries)
      (cond ((memq (car e) remove) (push (car e) removed))
            ((drgnx-settings-tidy--default-p e) (push (car e) dropped))
            (t (pcase-let ((`(,e2 . ,dups) (drgnx-settings-tidy--dedup e)))
                 (setq deduped (append deduped dups))
                 (when (drgnx-settings-tidy--undefined-p (car e)) (push (car e) undefined))
                 (push e2 kept)))))
    (let* ((kept (sort kept (lambda (x y) (string< (symbol-name (car x)) (symbol-name (car y))))))
           (new (concat (substring text 0 (1- (nth 1 form))) (drgnx-settings-tidy--print kept)
                        (substring text (1- (nth 2 form))))))
      (when-let* ((why (drgnx-settings-tidy--check forms new kept)))
        (drgnx-settings-tidy--no 'check "the tidied %s does not check (%s): nothing was changed"
                                 (abbreviate-file-name file) why))
      (list :file file :old text :new new :changed (not (equal text new))
            :entries (mapcar #'car kept) :dropped (nreverse dropped) :deduped deduped :removed (nreverse removed)
            :undefined (nreverse undefined)))))

(cl-defun drgnx-settings-tidy-plan (&key remove file)
  "What Settings: Tidy custom.el would do now, nothing written: a plist.
FILE defaults to `drgnx-settings-tidy-file'; REMOVE lists variables nothing defines whose entries go too.  A refusal
is (:refused REASON :why TEXT), REASON one of `missing', `unreadable', `no-form', `several', `unknown-entry',
`duplicate', `comment', `not-there', `defined' or `check': a file Tidy cannot be sure of is never rewritten.
Otherwise (:file :old :new :changed :entries :dropped :deduped :removed :undefined): the file's text now and after,
whether they differ, the variables whose entries stay (sorted), those dropped as equal to their standard value, the
packages taken out of `package-selected-packages' as duplicates, the entries removed, and the entries left that
nothing in this Emacs defines."
  (let ((file (or file (drgnx-settings-tidy-file))))
    (catch 'drgnx-settings-tidy--no (drgnx-settings-tidy--plan file remove))))

(defun drgnx-settings-tidy-move-offers (plan)
  "For each entry PLAN keeps that something defines: (VAR . WHY), WHY nil when Settings: Move into Settings… can move
it now (`drgnx-settings-move-plan'), else why it cannot."
  (cl-loop for var in (plist-get plan :entries)
           unless (memq var (plist-get plan :undefined))
           collect (cons var (plist-get (drgnx-settings-move-plan var) :why))))

;;;; Carrying it out

(defun drgnx-settings-tidy--revert (file)
  "Revert a buffer visiting FILE that has no edits of its own."
  (when-let* ((b (drgnx-settings-move--visiting file)))
    (unless (buffer-modified-p b)
      (let ((inhibit-interaction t)) (ignore-errors (with-current-buffer b (revert-buffer t t t)))))))

(defun drgnx-settings-tidy-apply (plan)
  "Write PLAN of `drgnx-settings-tidy-plan' (not a refusal): the record Settings: Undo Tidy uses, nil when PLAN
changes nothing.  Under custom.el's drgnx lock (a buffer with unsaved edits of it refuses): custom.el must still be
as PLAN read it, else nothing is written; a backup beside it (`drgnx-file-backup'), then the new text, atomically."
  (when (plist-get plan :refused) (error "drgnx-settings-tidy-apply: a refused plan"))
  (when (plist-get plan :changed)
    (let ((file (plist-get plan :file)) (record (copy-sequence plan)))
      (drgnx-settings-move--with-lock
       file
       (lambda ()
         (unless (equal (drgnx-file-read-bounded file) (plist-get plan :old))
           (user-error "Settings: %s changed since the preview; nothing was changed, run Tidy custom.el again"
                       (abbreviate-file-name file)))
         (setq record (plist-put record :bak (drgnx-file-backup file)))
         (drgnx-file-write-text file (plist-get plan :new))))
      (drgnx-settings-tidy--revert file)
      (push record drgnx-settings-tidy--undo)
      (when (> (length drgnx-settings-tidy--undo) drgnx-settings-tidy-undo-kept)
        (setq drgnx-settings-tidy--undo (cl-subseq drgnx-settings-tidy--undo 0 drgnx-settings-tidy-undo-kept)))
      record)))

(defun drgnx-settings-tidy-undo ()
  "Settings: Undo Tidy: put custom.el back as it was before the last Tidy custom.el.
Refused when custom.el changed since (its backup is named); nothing is written then.  Returns the record undone."
  (interactive)
  (let* ((r (or (car drgnx-settings-tidy--undo) (user-error "Settings: there is no Tidy custom.el to undo")))
         (file (plist-get r :file)))
    (drgnx-settings-move--with-lock
     file
     (lambda ()
       (unless (equal (drgnx-file-read-bounded file) (plist-get r :new))
         (user-error "Settings: %s changed since Tidy; it was not changed (its copy from before: %s)"
                     (abbreviate-file-name file) (plist-get r :bak)))
       (drgnx-file-write-text file (plist-get r :old))))
    (pop drgnx-settings-tidy--undo)
    (drgnx-settings-tidy--revert file)
    (when (called-interactively-p 'any)
      (message "Settings: Tidy custom.el is undone: %s is as it was" (file-name-nondirectory file)))
    r))

;;;; The command

(defun drgnx-settings-tidy--names (vars)
  "VARS as a comma-separated list, or \"none\"."
  (if vars (mapconcat (lambda (v) (format "%s" v)) vars ", ") "none"))

(defun drgnx-settings-tidy--preview (plan offers)
  "Show PLAN's changes, the move OFFERS (`drgnx-settings-tidy-move-offers') and its diff in a buffer; the buffer."
  (let ((buf (get-buffer-create "*drgnx tidy custom.el*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Tidy %s\n\n" (abbreviate-file-name (plist-get plan :file)))
                (format "Dropped, equal to the default:  %s\n" (drgnx-settings-tidy--names (plist-get plan :dropped)))
                (format "Duplicates taken out of package-selected-packages:  %s\n"
                        (drgnx-settings-tidy--names (plist-get plan :deduped)))
                (format "Removed:  %s\n" (drgnx-settings-tidy--names (plist-get plan :removed)))
                (format "Nothing in this Emacs defines (kept unless you remove them):  %s\n\n"
                        (drgnx-settings-tidy--names (plist-get plan :undefined))))
        (when offers
          (insert "Settings: Move into Settings… afterwards:\n")
          (pcase-dolist (`(,var . ,why) offers)
            (insert (format "  %s: %s\n" var (if why (concat "stays: " why) "can move"))))
          (insert "\n"))
        (insert (drgnx-settings-move--diff-lines (file-name-nondirectory (plist-get plan :file))
                                                 (plist-get plan :old) (plist-get plan :new)))
        (goto-char (point-min)))
      (diff-mode)
      (setq buffer-read-only t))
    (display-buffer buf)
    buf))

(defun drgnx-settings-tidy-custom-file ()
  "Settings: Tidy custom.el: tidy the file's `custom-set-variables' form, with a diff first (design §8.4).
Drops entries equal to the default, takes duplicates out of `package-selected-packages', removes the entries of
variables nothing defines that you choose, and prints the form as Customize does; text outside the form stays.  The
entries left that can move into Settings are named.  Settings: Undo Tidy puts the file back."
  (interactive)
  (let* ((plan (drgnx-settings-tidy-plan)) (buf nil))
    (when (plist-get plan :refused) (user-error "Settings: %s" (plist-get plan :why)))
    (unwind-protect
        (let ((offers (drgnx-settings-tidy-move-offers plan)))
          (setq buf (drgnx-settings-tidy--preview plan offers))
          (when-let* ((undefined (plist-get plan :undefined))
                      (remove (completing-read-multiple
                               "Remove the entries of variables nothing defines (RET: keep them all): "
                               (mapcar #'symbol-name undefined) nil t)))
            (setq plan (drgnx-settings-tidy-plan :remove (mapcar #'intern remove)))
            (when (plist-get plan :refused) (user-error "Settings: %s" (plist-get plan :why)))
            (drgnx-settings-tidy--preview plan offers))
          (cond ((not (plist-get plan :changed)) (message "Settings: custom.el is tidy already"))
                ((y-or-n-p "Write the tidied custom.el? ")
                 (drgnx-settings-tidy-apply plan)
                 (let ((movable (cl-loop for (var . why) in offers
                                         unless (or why (memq var (plist-get plan :removed))) collect var)))
                   (message "Settings: custom.el is tidied; Settings: Undo Tidy puts it back%s"
                            (if (null movable) ""
                              (format ". Move into Settings… can take: %s" (drgnx-settings-tidy--names movable))))))))
      (when buf (quit-windows-on buf)))))

;;;; en/disable-command

(defun drgnx-settings-tidy-disable-command (fn command disable)
  "Around `en/disable-command' (FN): COMMAND's (put \\='COMMAND \\='disabled DISABLE) line goes to custom.el
\(`drgnx-settings-tidy-file'), not `user-init-file', which in drgnx is the checkout's init/init.el."
  (let ((user-init-file (drgnx-settings-tidy-file)))
    (funcall fn command disable)))

;;;; The doctor

(defun drgnx-settings-tidy-facts (&optional file)
  "custom.el's facts for the doctor's `custom-file' line (FILE, default `drgnx-settings-tidy-file'): nil when it is
missing, else (:file F :bytes N :entries N :dormant VARS :problem TEXT), VARS the entries nothing in this Emacs
defines, TEXT why the form could not be read (nil when it was, or when there is none)."
  (let* ((file (or file (drgnx-settings-tidy-file)))
         (size (file-attribute-size (file-attributes file))))
    (when size
      (let ((r (catch 'drgnx-settings-tidy--no (drgnx-settings-tidy--read file))))
        (if (plist-get r :refused)
            (list :file file :bytes size :entries 0 :dormant nil
                  :problem (and (not (eq (plist-get r :refused) 'no-form)) (plist-get r :why)))
          (let ((vars (mapcar #'car (plist-get r :entries))))
            (list :file file :bytes size :entries (length vars)
                  :dormant (cl-remove-if-not #'drgnx-settings-tidy--undefined-p vars) :problem nil)))))))

(provide 'drgnx-settings-tidy)
;;; drgnx-settings-tidy.el ends here
