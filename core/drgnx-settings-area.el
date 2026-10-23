;;; drgnx-settings-area.el --- Settings: the writers of the areas that folded in (keys, modules, session) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 16 (docs/develop/settings.md, "Keys, modules, large files and session").  The Keyboard
;; Shortcuts editor, Preferences: Modules, the colour theme, the key profile and the keep-running choice used to write
;; their own files.  They write settings.el now, through the settings writer (`drgnx-settings-file-put'): only the
;; entry that changes, comments and layout stay.  Each change then applies at once (`drgnx-settings-apply-global',
;; idempotent), and a taken-away entry goes through the resolver (`drgnx-settings-resolve-apply'), so a variable that
;; carries module claims keeps them.  Nothing here prompts.

;;; Code:
(require 'cl-lib)
(require 'drgnx-file)
(require 'drgnx-config)
(require 'drgnx-setting)
(require 'drgnx-settings-file)
(require 'drgnx-settings-apply)
(require 'drgnx-settings-resolve)

(defun drgnx-settings-area--file () (drgnx-config-file 'settings))

(defun drgnx-settings-area-ensure-writable (&optional vars)
  "Signal `drgnx-settings-refused' when settings.el has a mistake or was written by a newer drgnx; else nil.
With VARS, a `user-error' too when the entry of one of them is a value its setting refuses (a writer would not
rewrite it).  Nothing is changed."
  (let* ((file (drgnx-settings-area--file)) (doc (drgnx-settings-file-read file 'drgnx-settings)))
    (when (drgnx-settings-doc-failed doc) (drgnx-settings-file--base doc file 'drgnx-settings))
    (dolist (var vars)
      (when-let* ((e (drgnx-settings-area--entry doc var))
                  (problem (and (get var 'standard-value) (drgnx-setting-check var (drgnx-settings-entry-value e)))))
        (user-error "%s does not fit (%s) — fix it first (it was not changed)" var (cdr problem))))
    nil))

(defun drgnx-settings-area--entry (doc var)
  "VAR's top-level entry in DOC, or nil."
  (cl-find-if (lambda (e) (and (eq (drgnx-settings-entry-var e) var) (null (drgnx-settings-entry-scope e))))
              (drgnx-settings-doc-entries doc)))

(defun drgnx-settings-area-fresh (vars)
  "The values VARS have by settings.el as it is on disk now: an alist (VAR . VALUE).
An entry of the file gives the value; a variable with no entry gives its current default value (nil when void), so a
writer decides a change from the file, not from what this Emacs applied long ago."
  (let ((doc (drgnx-settings-file-read (drgnx-settings-area--file) 'drgnx-settings)))
    (mapcar (lambda (var)
              (let ((e (and (not (drgnx-settings-doc-failed doc)) (drgnx-settings-area--entry doc var))))
                (cons var (cond (e (drgnx-settings-entry-value e))
                                ((default-boundp var) (default-value var))))))
            vars)))

(defvar drgnx-settings-area--cache nil
  "(STAMP . ((VAR . VALUE)…)): settings.el's top-level entries as last read for `drgnx-settings-area-values'.  One
entry, replaced when the file's stamp changes.")

(defun drgnx-settings-area--file-values ()
  "settings.el's top-level entries as ((VAR . VALUE)…), read again only when the file's stamp changed."
  (let* ((file (drgnx-settings-area--file)) (stamp (drgnx-file-stamp file)))
    (unless (equal stamp (car drgnx-settings-area--cache))
      (let ((doc (drgnx-settings-file-read file 'drgnx-settings)))
        (setq drgnx-settings-area--cache
              (cons stamp (unless (drgnx-settings-doc-failed doc)
                            (cl-loop for e in (drgnx-settings-doc-entries doc)
                                     unless (or (drgnx-settings-entry-scope e) (keywordp (drgnx-settings-entry-var e)))
                                     collect (cons (drgnx-settings-entry-var e) (drgnx-settings-entry-value e))))))))
    (cdr drgnx-settings-area--cache)))

(defun drgnx-settings-area-values (vars)
  "The values VARS have in this process: an alist (VAR . VALUE).
Their current default values, which settings.el's entries set once `drgnx-settings-apply-global' ran.  In a process
that has not applied settings.el (a batch command such as `drgnx sync' or `drgnx onboard': nothing applied, no entry
pushed), a variable still at its standard value takes the file's entry instead, so the reading is the same everywhere.
Never signals."
  (let* ((unapplied (null drgnx-settings-apply--entries))
         (file-values (and (or unapplied (cl-some (lambda (var) (not (default-boundp var))) vars))
                           (condition-case nil (drgnx-settings-area--file-values) (error nil)))))
    (mapcar (lambda (var)
              (let ((cell (let ((c (assq var file-values)))      ; an entry the setting refuses is not used (as the applier)
                            (and c (not (and (get var 'standard-value) (drgnx-setting-check var (cdr c)))) c))))
                (cons var (cond ((and cell (not (default-boundp var))) (cdr cell))         ; not declared yet: the file's
                                ((and cell unapplied (custom--standard-value-p var (default-value var))) (cdr cell))
                                ((default-boundp var) (default-value var))))))
            vars)))

(defun drgnx-settings-area-has-entry-p (var)
  "Non-nil when settings.el has a top-level entry for VAR now."
  (let ((doc (drgnx-settings-file-read (drgnx-settings-area--file) 'drgnx-settings)))
    (and (not (drgnx-settings-doc-failed doc)) (drgnx-settings-area--entry doc var) t)))

(defun drgnx-settings-area--apply ()
  "Apply settings.el after a write.  In a process that has not applied it (a batch command) only drgnx's own settings."
  (drgnx-settings-apply-global :owned-only (null drgnx-settings-apply--entries)))

(defun drgnx-settings-area-update (vars fn &optional always)
  "Change VARS in settings.el in one read-modify-write, under the file's lock, and apply what changed.
\(funcall FN CURRENT) runs on a fresh read: CURRENT is an alist (VAR . VALUE) of VARS (an entry's value, else the
variable's default value) and FN gives the alist of the values to have (only the variables it names).  A value that
differs is written, its entry replaced where it stands or a new one at its sorted place; with ALWAYS, a variable with
no entry is written whatever its value.  Comments and the other entries stay.  FN may signal: nothing is written.
Signals `drgnx-settings-refused' (a `user-error') for a file with a mistake or a newer one, a value that is not data,
or a busy lock, and leaves the file as it was.  Returns the variables written, in FN's order."
  (let ((changed nil))
    (drgnx-settings-file--write
     (drgnx-settings-area--file) 'drgnx-settings
     (lambda (base-doc)
       (let* ((entry (lambda (doc var) (drgnx-settings-area--entry doc var)))
              (current (mapcar (lambda (var)
                                 (let ((e (funcall entry base-doc var)))
                                   (cons var (cond (e (drgnx-settings-entry-value e))
                                                   ((default-boundp var) (default-value var))))))
                               vars))
              (wanted (funcall fn current))
              (writes (cl-loop for (var . value) in wanted
                               when (or (not (equal value (cdr (assq var current))))
                                        (and always (not (funcall entry base-doc var))))
                               collect (cons var value))))
         (dolist (w writes)
           (when-let* ((why (drgnx-settings-file--why-not (cdr w))))
             (drgnx-settings-file--refuse
              (format "%s was not changed: the value of %s is not data a settings file can hold: %s"
                      (drgnx-settings-file--shown (drgnx-settings-area--file)) (car w) why))))
         (when writes
           (setq changed writes)
           ;; one variable at a time, each on the text the last left (positions move)
           (dolist (w writes)
             (let* ((doc (drgnx-settings-file-parse (buffer-substring-no-properties (point-min) (point-max))
                                                    'drgnx-settings))
                    (e (funcall entry doc (car w)))
                    (dups (drgnx-settings-file--dups doc (car w) nil)))
               (drgnx-settings-file--apply
                (cons (if e (let ((beg (drgnx-settings-entry-beg e)))
                              (list beg (drgnx-settings-entry-end e)
                                    (drgnx-settings-file--entry-text (car w) (cdr w) (drgnx-settings-entry-merge e)
                                                                     (drgnx-settings-file--column beg))))
                        (drgnx-settings-file--new-edit nil (car w) (cdr w) nil))
                      (mapcar (lambda (d) (drgnx-settings-file--delete-edit (plist-get d :beg) (plist-get d :end)))
                              dups)))))
           (buffer-substring-no-properties (point-min) (point-max)))))
     (lambda (_old new)
       (cl-loop for w in changed
                for e = (drgnx-settings-area--entry new (car w))
                unless (and e (equal (drgnx-settings-entry-value e) (cdr w)))
                return (format "%s does not read as the new value" (car w)))))
    (when changed (drgnx-settings-area--apply))
    (mapcar #'car changed)))

(defun drgnx-settings-area-set (changes)
  "Write CHANGES, an alist (VAR . VALUE), into settings.el and apply them: the variables written, in order.
A value equal to the one the file gives is not written again, but a variable with no entry gets one
\(`drgnx-settings-area-update', with ALWAYS)."
  (drgnx-settings-area-update (mapcar #'car changes) (lambda (_) changes) t))

(defun drgnx-settings-area-unset (var)
  "Take VAR's entry out of settings.el and let go of drgnx's value: non-nil when there was an entry.
The value goes through the resolver (`drgnx-settings-resolve-apply'): modules' claims on VAR stay, the rest returns
to what Emacs gives without drgnx's entry."
  (when (drgnx-settings-area-has-entry-p var)
    (drgnx-settings-file-remove (drgnx-settings-area--file) 'drgnx-settings nil var)
    (drgnx-settings-area--apply)            ; the applied entries no longer hold VAR
    (drgnx-settings-resolve-apply var)
    t))

(provide 'drgnx-settings-area)
;;; drgnx-settings-area.el ends here
