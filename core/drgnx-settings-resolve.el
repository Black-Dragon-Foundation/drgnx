;;; drgnx-settings-resolve.el --- Settings: module claims and the resolver -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 9 (design §4.2, row C26): a module's choices are claims (layer G1), resolved with the
;; entry of settings.el (layer G2) by the setting's `:merge', and the result goes through the applier
;; (`drgnx-settings-push'), so modules stop overriding Customize and settings.el.
;; - `drgnx-settings-claim' / `drgnx-settings-unclaim' record a claim: a whole value (`drgnx-module-set'), one alist
;;   key (`drgnx-module-alist-put') or one list element (`add-to-list' in a setup).
;; - `drgnx-settings-resolve' merges them with the G2 entry: `replace', `alist', `append' or `lower-only'.
;; - `drgnx-settings-resolve-apply' puts the result into Emacs through theme `drgnx'.
;; - Settings: Keep Module Entries gives an entry that replaced modules' entries `:merge alist'.
;; Which route a claim takes: an option (a standard value, or void) with a value claim, a settings.el entry or a
;; value in theme `drgnx' goes through the theme; a key or element claim with none of those, and anything on a plain
;; `defvar', is changed directly by the helper, as before (docs/develop/settings.md, "Module claims").

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-setting)
(require 'drgnx-settings-file)
(require 'drgnx-settings-apply)
(require 'drgnx-modules-record)

(defvar drgnx-settings--claims (make-hash-table :test 'eq)
  "VAR → its modules' claims, oldest first: (MODULE KIND DATUM).  KIND `value' (DATUM the whole value), `key' (DATUM
\(KEY . VALUE), one alist key) or `element' (DATUM one list element).")

(defvar drgnx-settings-resolve--before (make-hash-table :test 'eq)
  "VAR → (HAD . OLD) when its first claim was made: whether it was bound, and its value then.  A variable with no
standard value goes back to it when its last claim goes.")

(defvar drgnx-settings-resolve--last (make-hash-table :test 'eq)
  "VAR → its default value right after the claims last changed it: what drgnx's modules left there.")

;;;; Claims

(defun drgnx-settings-claim (var module kind datum)
  "Record MODULE's claim on VAR (an alias is resolved) and return it.
KIND is `value' (DATUM the whole value, `drgnx-module-set'), `key' (DATUM (KEY . VALUE), `drgnx-module-alist-put') or
`element' (DATUM one element, `add-to-list').  Nothing changes in Emacs: `drgnx-settings-resolve-apply' does that."
  (unless (memq kind '(value key element)) (error "drgnx-settings-claim: unknown kind %S" kind))
  (let ((var (indirect-variable var)) (claim (list module kind datum)))
    (unless (gethash var drgnx-settings--claims)
      (puthash var (cons (default-boundp var) (and (default-boundp var) (default-value var)))
               drgnx-settings-resolve--before))
    (puthash var (append (gethash var drgnx-settings--claims) (list claim)) drgnx-settings--claims)
    claim))

(defun drgnx-settings-unclaim (var module kind datum)
  "Drop MODULE's newest claim on VAR of KIND and DATUM (`drgnx-settings-claim'); non-nil when there was one.
Nothing changes in Emacs: `drgnx-settings-resolve-apply' does that."
  (let* ((var (indirect-variable var))
         (claims (gethash var drgnx-settings--claims))
         (claim (car (last (cl-remove-if-not (lambda (c) (equal c (list module kind datum))) claims)))))
    (when claim
      (let ((rest (remq claim claims)))
        (if rest (puthash var rest drgnx-settings--claims) (remhash var drgnx-settings--claims)))
      t)))

(defun drgnx-settings-claims (var)
  "VAR's claims, oldest first: (MODULE KIND DATUM)."
  (copy-sequence (gethash (indirect-variable var) drgnx-settings--claims)))

(defun drgnx-settings-claim-modules (var)
  "The modules that claim VAR, oldest claim first, each once."
  (delete-dups (mapcar #'car (gethash (indirect-variable var) drgnx-settings--claims))))

;;;; The resolver

(defun drgnx-settings-resolve--entry (var)
  "VAR's top-level entry of settings.el that the last apply pushed, or nil."
  (cdr (assq var drgnx-settings-apply--entries)))

(defun drgnx-settings-resolve--option-p (var)
  "Non-nil when VAR can go through theme `drgnx': it has a standard value (a `defcustom', or a built-in variable
Customize knows), or it is void (its package is not loaded yet)."
  (let ((var (indirect-variable var)))
    (or (get var 'standard-value) (not (default-boundp var)))))

(defun drgnx-settings-resolve--value-route-p (var)
  "Non-nil when a value claim on VAR goes through theme `drgnx': VAR is an option, or the theme holds it already
\(a void variable that a claim set)."
  (let ((var (indirect-variable var)))
    (or (drgnx-settings-resolve--option-p var) (and (assq drgnx-settings-theme (get var 'theme-value)) t))))

(defun drgnx-settings-resolve--theme-p (var)
  "Non-nil when VAR's claims resolve through theme `drgnx': the theme holds VAR already, or VAR is an option with a
value claim or a settings.el entry.  Otherwise the helpers change it directly."
  (let ((var (indirect-variable var)))
    (or (and (assq drgnx-settings-theme (get var 'theme-value)) t)
        (and (drgnx-settings-resolve--option-p var)
             (or (drgnx-settings-resolve--entry var)
                 (cl-some (lambda (c) (eq (nth 1 c) 'value)) (gethash var drgnx-settings--claims)))
             t))))

(defun drgnx-settings-resolve--base (var)
  "The value under VAR's key and element claims: what Emacs gives without theme `drgnx' (another theme's value, else
the standard value, else the value before the first claim) when the theme holds VAR, else VAR's value now."
  (let ((tv (get var 'theme-value)))
    (if (not (assq drgnx-settings-theme tv))
        (and (default-boundp var) (default-value var))
      (let ((other (cl-find-if-not (lambda (e) (eq (car e) drgnx-settings-theme)) tv))
            (sv (get var 'standard-value)))
        (cond (other (drgnx-settings--value (cadr other)))
              (sv (drgnx-settings--value (car sv)))
              (t (cdr (gethash var drgnx-settings-resolve--before))))))))

(defun drgnx-settings-resolve--put (value claim)
  "VALUE with CLAIM's key or element in it: a key replaces the cell of an `equal' key or goes first; an element
goes first unless it is a member (as `add-to-list')."
  (pcase (nth 1 claim)
    ('key (let* ((datum (nth 2 claim)) (cell (and (listp value) (assoc (car datum) value))))
            (if cell (mapcar (lambda (c) (if (eq c cell) datum c)) value) (cons datum value))))
    ('element (if (and (listp value) (member (nth 2 claim) value)) value (cons (nth 2 claim) value)))
    (_ value)))

(defun drgnx-settings-resolve--g1 (var claims)
  "G1: the newest value claim (else `drgnx-settings-resolve--base'), with the key and element claims put in."
  (let* ((values (cl-remove-if-not (lambda (c) (eq (nth 1 c) 'value)) claims))
         (value (if values (nth 2 (car (last values))) (drgnx-settings-resolve--base var))))
    (dolist (c claims) (setq value (drgnx-settings-resolve--put value c)))
    value))

(defun drgnx-settings-resolve--items (claims)
  "The modules' entries or elements in CLAIMS, oldest first: a value claim's elements, a key claim's cell, an
element."
  (apply #'append (mapcar (lambda (c) (pcase (nth 1 c)
                                        ('value (and (proper-list-p (nth 2 c)) (nth 2 c)))
                                        (_ (list (nth 2 c)))))
                          claims)))

(defun drgnx-settings-resolve--merge (var claims entry)
  "CLAIMS of VAR resolved with ENTRY (settings.el's, or nil): (VALUE . REPLACED); see `drgnx-settings-resolve'."
  (if (not entry)
      (cons (drgnx-settings-resolve--g1 var claims) nil)
    (let ((g2 (drgnx-settings-entry-value entry))
          (merge (or (drgnx-settings-entry-merge entry) (plist-get (drgnx-setting-meta var) :merge) 'replace)))
      (pcase merge
        ('alist
         (let ((seen nil) (keep nil))
           (dolist (item (reverse (drgnx-settings-resolve--items claims)))   ; the newest claim of a key wins
             (let ((key (if (consp item) (car item) item)))
               (unless (or (member key seen) (and (listp g2) (if (consp item) (assoc key g2) (member item g2))))
                 (push key seen)
                 (push item keep))))
           (cons (append g2 keep) nil)))
        ('append
         (let ((items (delete-dups (drgnx-settings-resolve--items claims))))
           (cons (append items (cl-remove-if (lambda (x) (member x items)) (and (listp g2) g2))) nil)))
        ('lower-only
         (let* ((values (cl-remove-if-not (lambda (c) (eq (nth 1 c) 'value)) claims))
                (g1 (and values (nth 2 (car (last values))))))
           (cons (if (and (numberp g1) (numberp g2)) (min g1 g2) g2) nil)))
        (_ (let ((replaced nil))
             (dolist (c claims)
               (let ((cell (assq (car c) replaced)))
                 (if cell (setcdr cell (append (cdr cell) (list (nth 2 c))))
                   (setq replaced (append replaced (list (list (car c) (nth 2 c))))))))
             (cons g2 replaced)))))))

(defun drgnx-settings-resolve (var)
  "VAR's modules' claims (G1) resolved with its settings.el entry (G2): (VALUE . REPLACED).
The merge is the entry's own `:merge', else the setting's (`drgnx-setting-meta'):
- `replace' (the default): G2's value; REPLACED lists what it replaced, ((MODULE DATUM…)…);
- `alist': G2's entries, then the modules' keys G2 does not have (the newest claim of a key wins);
- `append': the modules' elements, then G2's;
- `lower-only': the lower of the newest value claim and G2, when both are numbers; else G2.
With no G2 entry, VALUE is G1: the newest value claim, or the value under the claims, with every key and element
claim put in; REPLACED is nil.  Pure: `drgnx-settings-resolve-apply' puts it into Emacs."
  (let ((var (indirect-variable var)))
    (drgnx-settings-resolve--merge var (gethash var drgnx-settings--claims) (drgnx-settings-resolve--entry var))))

;;;; Into Emacs

(defun drgnx-settings-resolve--note (var)
  "Remember VAR's value now as what its claims left there (only while it has claims)."
  (let ((var (indirect-variable var)))
    (when (and (gethash var drgnx-settings--claims) (default-boundp var))
      (puthash var (default-value var) drgnx-settings-resolve--last))))

(defun drgnx-settings-resolve--ours-p (var)
  "Non-nil when VAR's value is what its claims last left there."
  (and (default-boundp var)
       (equal (default-value var) (gethash var drgnx-settings-resolve--last 'drgnx-settings-resolve--none))))

(defun drgnx-settings-resolve--adopt (var)
  "When only drgnx's modules changed VAR since (its value is what their direct changes left, and no theme but `drgnx'
holds it), make that value drgnx's entry, so that the push that follows decides as the winner."
  (when (and (drgnx-settings-resolve--ours-p var)
             (cl-every (lambda (e) (eq (car e) drgnx-settings-theme)) (get var 'theme-value))
             (not (drgnx-settings-winner-p var)))
    (let ((exp (custom-quote (default-value var))))
      (drgnx-settings--theme)
      (put var 'theme-value (list (list drgnx-settings-theme exp)))
      (drgnx-settings--theme-setting var exp))))

(defun drgnx-settings-resolve--forget (var)
  "Forget VAR's first value and last value once it has no claims."
  (unless (gethash var drgnx-settings--claims)
    (remhash var drgnx-settings-resolve--before)
    (remhash var drgnx-settings-resolve--last)))

(defun drgnx-settings-resolve--drop (var)
  "Take drgnx's value of VAR away now that nothing in drgnx holds it.  While the value is still drgnx's, VAR goes
back to what is left (other themes, the standard value) or, with none, to its value before the first claim (void
again if it was); otherwise someone set it since, and it stays."
  (when-let* ((own (assq drgnx-settings-theme (get var 'theme-value))))
    (let ((ours (or (drgnx-settings-resolve--ours-p var)
                    (and (default-boundp var) (equal (default-value var) (drgnx-settings--value (cadr own))))))
          (before (gethash var drgnx-settings-resolve--before)))
      (custom-push-theme 'theme-value var drgnx-settings-theme 'reset)
      (when ours
        (cond ((or (get var 'theme-value) (get var 'standard-value)) (custom-theme-recalc-variable var))
              ((car before) (funcall (or (get var 'custom-set) #'set-default) var (cdr before)))
              (before (makunbound var))))
      (unless (get var 'theme-value) (put var 'saved-value nil)))))

(defun drgnx-settings-resolve-apply (var)
  "Put VAR's resolved value (`drgnx-settings-resolve') into Emacs now, through `drgnx-settings-push'.
Returns `applied' or `stored' (the push's answer), `dropped' when nothing in drgnx holds VAR any more (its value in
theme `drgnx' taken away, `drgnx-settings-resolve--drop'), or nil when VAR does not go through the theme (a key or
element claim with no settings.el entry, a plain `defvar'): the helpers change those directly.  A void VAR whose
value applies is set at once, as `drgnx-module-set' always did; its `defcustom' keeps the value.  The safety net of
a running setup records nothing of it (the claim's undo is the record).  Never prompts."
  (let* ((var (indirect-variable var))
         (claims (gethash var drgnx-settings--claims))
         (entry (drgnx-settings-resolve--entry var)))
    (prog1
        (cond
         ((not (drgnx-settings-resolve--theme-p var)) nil)
         ((not (or claims entry))
          (drgnx-modules--quietly (drgnx-settings-resolve--drop var))
          'dropped)
         (t (let ((value (car (drgnx-settings-resolve--merge var claims entry))))
              (drgnx-settings-resolve--adopt var)
              (let ((r (drgnx-modules--quietly
                         (let ((r (drgnx-settings-push var value)))
                           (when (and (eq r 'applied) (not entry) (not (default-boundp var)))
                             (funcall (or (get var 'custom-set) #'set-default) var value))
                           r))))
                (when (eq r 'applied) (drgnx-settings-resolve--note var))
                r))))
      (drgnx-settings-resolve--forget var))))

(defun drgnx-settings-resolve-entry (var entry)
  "The value settings.el's ENTRY for VAR is pushed with: ENTRY's value resolved with the modules' claims on VAR
\(`drgnx-settings-resolve').  When only those modules changed VAR, their value first becomes drgnx's entry, so that
the push decides as the winner (a G2 entry added while modules had changed VAR directly)."
  (let* ((var (indirect-variable var)) (claims (gethash var drgnx-settings--claims)))
    (if (not claims)
        (drgnx-settings-entry-value entry)
      (drgnx-settings-resolve--adopt var)
      (car (drgnx-settings-resolve--merge var claims entry)))))

(defun drgnx-settings-resolve--direct-value (var)
  "(VALUE) when VAR has claims, no value in theme `drgnx', and its value is what they left there; else nil.
Provenance explains such a value as the modules'."
  (let ((var (indirect-variable var)))
    (and (gethash var drgnx-settings--claims)
         (not (assq drgnx-settings-theme (get var 'theme-value)))
         (drgnx-settings-resolve--ours-p var)
         (list (default-value var)))))

;;;; Settings: Keep Module Entries

(defun drgnx-settings-resolve--replacing ()
  "The variables whose settings.el entry replaces modules' entries now (a `replace' merge with claims), by name."
  (let (vars)
    (maphash (lambda (var _) (when (cdr (drgnx-settings-resolve var)) (push var vars))) drgnx-settings--claims)
    (sort vars (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

(defun drgnx-settings-keep-module-entries (var)
  "Keep the modules' entries of VAR beside your value in settings.el: the entry gets `:merge alist' (design §4.2).
Your entries win per key and the modules' other keys stay.  It applies at once."
  (interactive
   (let ((vars (drgnx-settings-resolve--replacing)))
     (unless vars (user-error "No value in Settings replaces a module's entries"))
     (list (intern (completing-read "Keep module entries of: " (mapcar #'symbol-name vars) nil t)))))
  (let* ((var (indirect-variable var))
         (file (drgnx-config-file 'settings))
         (doc (drgnx-settings-file-read file 'drgnx-settings))
         (top (lambda (doc) (cl-find-if (lambda (e) (and (eq (drgnx-settings-entry-var e) var)
                                                         (null (drgnx-settings-entry-scope e))))
                                        (drgnx-settings-doc-entries doc))))
         (entry (funcall top doc)))
    (unless entry (user-error "settings.el has no value for %s" var))
    (let ((new (funcall top (drgnx-settings-file-put file 'drgnx-settings nil var (drgnx-settings-entry-value entry)
                                                     :merge 'alist))))
      (setf (alist-get var drgnx-settings-apply--entries) new)
      (let ((r (drgnx-settings-resolve-apply var)))
        (when (called-interactively-p 'interactive)
          (message "%s keeps the modules' entries (%s)" var
                   (if (eq r 'stored) "saved; your Lisp or Customize sets it now" "applied")))
        r))))

(provide 'drgnx-settings-resolve)
;;; drgnx-settings-resolve.el ends here
