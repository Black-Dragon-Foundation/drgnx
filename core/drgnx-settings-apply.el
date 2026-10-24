;;; drgnx-settings-apply.el --- Settings: the applier (theme drgnx, the winner rule) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 8: settings.el applied through theme `drgnx' after the packages are active and before
;; custom.el — pushed only where drgnx's layer is Emacs's winner, stored in place otherwise — and per-variable
;; teardown (docs/develop/settings.md, "The applier rule"; the design's §4.2).
;; - `drgnx-settings-winner-p' decides from Emacs's own data (`theme-value', the default value), never provenance.
;; - `drgnx-settings-push' applies a winner with `custom-theme-set-variables'; a loser is stored where drgnx's entry
;;   stands, never with `custom-push-theme' (which would move it to the front).
;; - `drgnx-settings-teardown' removes drgnx's entry and recalculates only while the value is still drgnx's.
;; - `drgnx-settings-apply-global' reads settings.el (its last good copy per setting when it fails), checks each
;;   entry and pushes it.  `drgnx-init' calls it at start, in safe mode with :owned-only; it never signals.
;; - Settings: Turn Off / Turn On Package Settings tear down or push again every entry drgnx does not own.
;; Theme `drgnx' is never disabled.  Nothing here prompts.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-setting)
(require 'drgnx-settings-file)
(require 'drgnx-settings-described)

(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))
(declare-function drgnx-notice-clear "drgnx-notice" (source &optional id))
(declare-function drgnx-settings-resolve-entry "drgnx-settings-resolve" (var entry))
(declare-function drgnx-settings-resolve-apply "drgnx-settings-resolve" (var))
(declare-function drgnx-settings-claims "drgnx-settings-resolve" (var))

;; Emacs's own (custom.el, preloaded) and provenance's: bound dynamically here.
(defvar custom--inhibit-theme-enable)
(defvar drgnx-settings-prov-applying)

(defconst drgnx-settings-theme 'drgnx
  "The custom theme that holds drgnx's layers (settings.el, and the modules' choices): never disabled.")

(defvar drgnx-settings-package-settings-off nil
  "Non-nil while Settings: Turn Off Package Settings holds (this session): only drgnx's own entries of settings.el
apply.  The environment variable DRGNX_PACKAGE_SETTINGS=off (drgnx bisect's step) has the same effect.")

(defun drgnx-settings-own-only-p ()
  "Non-nil while only drgnx's own entries of settings.el apply (design §4.2): safe mode (DRGNX_SAFE), Settings: Turn
Off Package Settings (`drgnx-settings-package-settings-off') or DRGNX_PACKAGE_SETTINGS=off.  The global entries and
the language overrides both follow it."
  (or (and (getenv "DRGNX_SAFE") t) drgnx-settings-package-settings-off
      (equal (getenv "DRGNX_PACKAGE_SETTINGS") "off")))

(defvar drgnx-settings-apply-problems nil
  "The problems of the last apply of settings.el, in file order: plists (:file :line :column :text), with :var for
an entry that did not apply as written.  A failed file is the config layer's notice, not one of these.")

(defvar drgnx-settings-apply-durations nil
  "Seconds each push of the last apply of settings.el took (its `:set' included), as (VAR . SECONDS), in the order
applied.  `drgnx-settings-apply-slow' lists those over a millisecond.")

(defvar drgnx-settings-apply--entries nil
  "The entries of settings.el (or its last good copy) the last apply pushed: (VAR . ENTRY), in the order applied.")

;;;; The theme and the winner rule

(defun drgnx-settings--theme ()
  "Declare theme `drgnx' once: enabled, then taken out of `custom-enabled-themes', as use-package does for its own,
so that `(mapc #\\='disable-theme custom-enabled-themes)' leaves it alone."
  (unless (custom-theme-p drgnx-settings-theme)
    (custom-declare-theme drgnx-settings-theme (custom-make-theme-feature drgnx-settings-theme)
                          "drgnx's settings (settings.el) and module choices: applied only where they win.")
    (enable-theme drgnx-settings-theme)
    (setq custom-enabled-themes (remq drgnx-settings-theme custom-enabled-themes))))

(defun drgnx-settings--value (exp)
  "The value of EXP, a theme entry's or a `standard-value''s expression, or the symbol `drgnx-settings--none'."
  (condition-case nil (eval exp t) (error 'drgnx-settings--none)))

(defun drgnx-settings-winner-p (var)
  "Non-nil when drgnx's layer is Emacs's winner for VAR (design §4.2), from `theme-value' and the default value only:
1. no theme but `drgnx' has an entry in VAR's `theme-value' (no `user', `use-package', colour theme, `changed'
   stash), and
2. VAR's default value is `equal' to drgnx's entry, or, when drgnx has none yet, to the standard value.
A void VAR (its package not loaded) meets rule 2.  A bound variable with neither a drgnx entry nor a standard
value (a plain `defvar') does not."
  (let* ((var (indirect-variable var))
         (tv (get var 'theme-value))
         (own (assq drgnx-settings-theme tv)))
    (and (cl-every (lambda (e) (eq (car e) drgnx-settings-theme)) tv)
         (or (not (default-boundp var))
             (let ((cur (default-value var)))
               (if own
                   (equal cur (drgnx-settings--value (cadr own)))
                 (let ((sv (get var 'standard-value)))
                   (and sv (equal cur (drgnx-settings--value (car sv)))))))))))

;;;; Push, store, teardown

(defun drgnx-settings--theme-setting (var exp)
  "Make theme `drgnx''s `theme-settings' say EXP for VAR: its entry replaced where it stands, else added."
  (let* ((settings (get drgnx-settings-theme 'theme-settings))
         (new (list 'theme-value var drgnx-settings-theme exp))
         (cell (cl-find-if (lambda (s) (and (eq (car s) 'theme-value) (eq (cadr s) var))) settings)))
    (put drgnx-settings-theme 'theme-settings
         (if cell (mapcar (lambda (s) (if (eq s cell) new s)) settings) (cons new settings)))))

(defun drgnx-settings--store (var value)
  "Store VALUE as drgnx's value of VAR without applying it or moving drgnx's entry (design §4.2, V3, V4).
When no entry of VAR's `theme-value' holds the value now in effect (a `setq', a `setopt', a session set), that value
is first recorded as Emacs's `changed' stash at the front, as `custom-push-theme' does for a new setting; then
drgnx's entry is replaced where it stands, or appended."
  (let* ((exp (custom-quote value))
         (tv (get var 'theme-value))
         (own (assq drgnx-settings-theme tv)))
    (when (default-boundp var)
      (let ((cur (default-value var)))
        (unless (or (custom--standard-value-p var cur)
                    (cl-some (lambda (e) (equal cur (drgnx-settings--value (cadr e)))) tv))
          (let ((stash (assq 'changed tv)) (new (list 'changed (custom-quote cur))))
            (setq tv (if stash (mapcar (lambda (e) (if (eq e stash) new e)) tv) (cons new tv)))))))
    (put var 'theme-value
         (if own
             (mapcar (lambda (e) (if (eq e own) (list drgnx-settings-theme exp) e)) tv)
           (append tv (list (list drgnx-settings-theme exp)))))
    (drgnx-settings--theme-setting var exp)))

(defun drgnx-settings-push (var value)
  "Put VALUE in theme `drgnx' for VAR; `applied' or `stored'.
The winner (`drgnx-settings-winner-p') is applied with `custom-theme-set-variables' (`custom--inhibit-theme-enable'
nil): the value takes effect and its `:set' runs, at once, or at the `defcustom' of a void VAR.  A value already in
effect is recorded without calling `:set' again.  Otherwise the value is stored in place (`changed' first when
nothing holds the value in effect), nothing in Emacs changes, and `stored' says so.  Never `custom-push-theme' for a
losing store: Emacs would move the entry to the front, over your Lisp."
  (drgnx-settings--theme)
  (let ((var (indirect-variable var))
        (drgnx-settings-prov-applying t))            ; provenance: this write is drgnx's, not "changed this session"
    ;; An autoloaded option (a minor mode's variable) loads its package first, as the same entry in custom.el does
    ;; (`custom-theme-set-variables'; design R3): its `defvar' alone has no standard value to decide by.
    (unless (or (get var 'standard-value) (memq (get var 'custom-autoload) '(nil noset)))
      (custom-load-symbol var))
    (cond ((drgnx-settings-described-defvar-p var)   ; no `:set' and no standard value: drgnx's entry, then `set-default'
           (unless (get var 'drgnx-described-original)
             (put var 'drgnx-described-original (list (default-value var))))
           (drgnx-settings--store var value)
           (set-default var value)
           'applied)
          ((not (drgnx-settings-winner-p var))
           (drgnx-settings--store var value)
           'stored)
          ((and (default-boundp var) (equal (default-value var) value))
           (drgnx-settings--store var value)
           'applied)
          (t (let ((custom--inhibit-theme-enable nil))
               (custom-theme-set-variables drgnx-settings-theme (list var (custom-quote value))))
             ;; `saved-value' is Customize's (what custom.el saved): drgnx's stash there only waits for the
             ;; `defcustom' of a void VAR, which clears it too (`custom-declare-variable').
             (when (default-boundp var) (put var 'saved-value nil))
             'applied))))

(defun drgnx-settings-teardown (var)
  "Take drgnx's value of VAR away (design §4.2, V2): non-nil when drgnx had one.
Its entry leaves `theme-value' (`custom-push-theme' with `reset'); the variable is recalculated from what is left
\(`custom-theme-recalc-variable') only while its value is still `equal' to drgnx's.  Otherwise someone else set it
\(a `setq' made after drgnx's push), and it stays.  Theme `drgnx' itself is never disabled."
  (let* ((var (indirect-variable var))
         (own (assq drgnx-settings-theme (get var 'theme-value))))
    (when own
      (let ((ours (drgnx-settings--value (cadr own))))
        (custom-push-theme 'theme-value var drgnx-settings-theme 'reset)
        (unless (get var 'theme-value) (put var 'saved-value nil))   ; no stale value for a later `defcustom'
        (when (and (default-boundp var) (equal (default-value var) ours))
          (if-let* ((orig (get var 'drgnx-described-original)))   ; a described `defvar': back to what it was
              (set-default var (car orig))
            (custom-theme-recalc-variable var)))
        (put var 'drgnx-described-original nil)
        t))))

(defun drgnx-settings-let-go (var)
  "Let go of settings.el's value of VAR, whose entry the applied entries (`drgnx-settings-apply--entries') no longer
hold: non-nil when drgnx had a value.  A variable modules claim goes through the resolver
\(`drgnx-settings-resolve-apply'), so the claims' value stays; any other through `drgnx-settings-teardown'."
  (if (and (fboundp 'drgnx-settings-claims) (drgnx-settings-claims var))
      (and (drgnx-settings-resolve-apply var) t)
    (drgnx-settings-teardown var)))

;;;; Applying settings.el

(defun drgnx-settings-apply--global-entries (doc)
  "DOC's top-level entries (no `:mode' section), in file order."
  (cl-remove-if (lambda (e) (or (drgnx-settings-entry-scope e) (keywordp (drgnx-settings-entry-var e))))
                (drgnx-settings-doc-entries doc)))

(defun drgnx-settings-apply--strict-p (var)
  "Non-nil when VAR falls back to its default when its value cannot be used (`:on-error strict')."
  (eq (plist-get (drgnx-setting-meta var) :on-error) 'strict))

(defun drgnx-settings-apply--check (entry)
  "nil when ENTRY's value fits its variable (`drgnx-setting-check'), else the message.  A check that cannot run
\(a broken `:type') passes: the value goes to Emacs as custom.el's would."
  (let ((r (condition-case nil (drgnx-setting-check (drgnx-settings-entry-var entry) (drgnx-settings-entry-value entry))
             (error nil))))
    (when r
      (concat (if (car r) (format "%s: " (mapconcat (lambda (k) (format "%s" k)) (car r) "/")) "") (cdr r)))))

(defun drgnx-settings-apply--sorted (entries)
  "ENTRIES in the order Emacs applies settings: a variable after those its `:set-after' names, minor modes last."
  (if (fboundp 'custom--sort-vars)
      (mapcar (lambda (x) (nth 4 x))
              (custom--sort-vars (mapcar (lambda (e) (list (drgnx-settings-entry-var e) nil nil nil e)) entries)))
    entries))

(defun drgnx-settings--say (problems)
  "PROBLEMS as one notice condition (none: the notice goes).  Never signals."
  (condition-case err
      (cond
       ((null problems) (when (featurep 'drgnx-notice) (drgnx-notice-clear 'config 'settings-entries)))
       ((require 'drgnx-notice nil t)
        (let ((lines (mapcar (lambda (p) (format "%s:%s: %s"
                                                 (abbreviate-file-name (or (plist-get p :file) "settings.el"))
                                                 (or (plist-get p :line) "?") (plist-get p :text)))
                             problems)))
          (drgnx-notify 'config 'warn (if (cdr lines) (format "settings.el: %d entries did not apply as written"
                                                              (length lines))
                                        (car lines))
                        :id 'settings-entries :life 'condition :detail (string-join lines "\n")
                        :command 'config-open))))
    (error (message "drgnx: settings.el: %d problems (not recorded: %s)" (length problems)
                    (error-message-string err)))))

(defun drgnx-settings-apply--push-timed (var value)
  "`drgnx-settings-push' of VAR and VALUE, its time recorded in `drgnx-settings-apply-durations'; its result."
  (let ((start (float-time)))
    (prog1 (drgnx-settings-push var value)
      (push (cons var (- (float-time) start)) drgnx-settings-apply-durations))))

(defun drgnx-settings-apply--run (owned-only)
  "Apply settings.el (OWNED-ONLY: drgnx's own settings only); an alist (VAR . RESULT) in the order applied.
RESULT: `applied', `stored', `default' (torn down: a strict setting whose value could not be used), `problem' (not
applied; one problem says why) or `failed' (its push signalled)."
  (drgnx-settings--theme)
  (let* ((file (drgnx-config-file 'settings))
         (state (drgnx-settings-file-state file 'drgnx-settings))
         (doc (plist-get state :doc))
         (good (plist-get state :last-good))
         (failed (drgnx-settings-doc-failed doc))
         (good-entries (and good (drgnx-settings-apply--global-entries good)))
         (problems (unless failed
                     (mapcar (lambda (p) (append (list :file file) p)) (drgnx-settings-doc-problems doc))))
         (prev drgnx-settings-apply--entries)
         (results nil) (pushed nil))
    (setq drgnx-settings-apply-durations nil)
    (cl-labels ((problem (entry text)
                  (push (list :file file :line (drgnx-settings-entry-line entry)
                              :var (drgnx-settings-entry-var entry) :text text)
                        problems))
                (push-entry (entry)
                  (let ((var (drgnx-settings-entry-var entry)))
                    (condition-case err
                        (let ((r (drgnx-settings-apply--push-timed
                                  var (if (fboundp 'drgnx-settings-resolve-entry)   ; modules' claims merged in (Task 9)
                                          (drgnx-settings-resolve-entry var entry)
                                        (drgnx-settings-entry-value entry)))))
                          (push (cons var entry) pushed)
                          r)
                      (error (problem entry (format "%s was not applied: %s" var (error-message-string err)))
                             'failed))))
                (fall-back (entry why)
                  ;; ENTRY of settings.el cannot be used: strict → the default; else its last good value, if any:
                  ;; the one this session applied last, else the last good copy's when it checks.
                  (let* ((var (drgnx-settings-entry-var entry))
                         (old (and (not (drgnx-settings-apply--strict-p var))
                                   (or (cdr (assq var prev))
                                       (cl-find var good-entries :key #'drgnx-settings-entry-var))))
                         (old-ok (and old (not (drgnx-settings-apply--check old)))))
                    (problem entry (format "%s: %s — %s" var why
                                           (cond ((drgnx-settings-apply--strict-p var) "using its default")
                                                 (old-ok "using its last good value")
                                                 (t "not applied"))))
                    (cond ((drgnx-settings-apply--strict-p var) (drgnx-settings-teardown var) 'default)
                          (old-ok (push-entry old))
                          (t 'problem)))))
      (dolist (entry (drgnx-settings-apply--sorted (if failed good-entries
                                                     (drgnx-settings-apply--global-entries doc))))
        (let ((var (drgnx-settings-entry-var entry)))
          (when (or (not owned-only) (drgnx-setting-own-p var))
            (push (cons var
                        (cond ((and failed (drgnx-settings-apply--strict-p var))   ; the file failed: per setting
                               (drgnx-settings-teardown var) 'default)
                              (failed (let ((why (drgnx-settings-apply--check entry)))
                                        (if (not why) (push-entry entry)
                                          (problem entry (format "%s: %s — not applied" var why))
                                          'problem)))
                              (t (let ((why (drgnx-settings-apply--check entry)))
                                   (if why (fall-back entry why) (push-entry entry))))))
                  results)))))
    (setq drgnx-settings-apply--entries (nreverse pushed)
          drgnx-settings-apply-durations (nreverse drgnx-settings-apply-durations)
          drgnx-settings-apply-problems (sort problems (lambda (a b) (< (or (plist-get a :line) 0)
                                                                        (or (plist-get b :line) 0)))))
    (drgnx-settings--say drgnx-settings-apply-problems)
    (nreverse results)))

(cl-defun drgnx-settings-apply-global (&key owned-only)
  "Apply settings.el's global entries through theme `drgnx'; with OWNED-ONLY, only drgnx's own settings (safe mode).
Called at start after the packages are activated and before custom.el loads, so custom.el, `use-package :custom'
and your Lisp come later and win.  Each entry is checked (`drgnx-setting-check'); one that fails falls back alone,
by its `:on-error': `strict' to its default, else to the value this session last applied for it, else to its
value in settings.el's last good copy, with one problem naming its line.  When the file does not read, every
setting falls back the same way.  Each value goes through `drgnx-settings-push'.  In safe mode and while package
settings are off (`drgnx-settings-own-only-p'), only drgnx's own entries apply.
Returns an alist (VAR . RESULT) (see `drgnx-settings-apply--run'), or nil when the apply failed as a whole (one
message).  Never signals and never prompts: the start-up call sites have no `condition-case' of their own."
  (condition-case err
      (let ((inhibit-interaction t))
        (drgnx-settings-apply--run (or owned-only (drgnx-settings-own-only-p))))
    (error (condition-case nil
               (drgnx-settings--say (list (list :file "settings.el" :text (format "settings.el was not applied: %s"
                                                                                  (error-message-string err)))))
             (error nil))
           nil)))

(defun drgnx-settings-dormant ()
  "The entries of settings.el the last apply kept for variables nobody defines yet (a package not installed or not
loaded), as `drgnx-settings-entry's.  They wait in theme `drgnx' and apply at the variable's `defcustom'.
Information, not a problem."
  (cl-loop for (var . entry) in drgnx-settings-apply--entries
           unless (default-boundp var) collect entry))

(defun drgnx-settings-apply-slow (&optional threshold)
  "The pushes of the last apply that took longer than THRESHOLD seconds (default 1 ms): ((VAR . SECONDS)…), slowest
first."
  (sort (cl-remove-if-not (lambda (d) (> (cdr d) (or threshold 0.001))) (copy-sequence drgnx-settings-apply-durations))
        (lambda (a b) (> (cdr a) (cdr b)))))

;;;; Turn Off / Turn On Package Settings

(defun drgnx-settings-turn-off-package-settings ()
  "Take every value settings.el gives a variable drgnx does not own out of Emacs now (design §4.2).
Each goes by `drgnx-settings-let-go': back to the layer below (the modules' claims on it stay), unless your Lisp set
it since.  drgnx's own
settings (keys, agents, trust …) stay.  Until Settings: Turn On Package Settings, or the next start, only drgnx's own
entries apply."
  (interactive)
  (setq drgnx-settings-package-settings-off t)
  (let* ((n 0)
         (gone (cl-remove-if #'drgnx-setting-own-p drgnx-settings-apply--entries :key #'car)))
    (setq drgnx-settings-apply--entries (cl-remove-if-not #'drgnx-setting-own-p drgnx-settings-apply--entries
                                                          :key #'car))
    (dolist (cell gone)                 ; after the entries changed: the resolver reads them
      (when (drgnx-settings-let-go (car cell)) (cl-incf n)))
    (when (called-interactively-p 'interactive)
      (message "Package settings are off: %d taken out; drgnx's own settings stay (Settings: Turn On Package Settings)"
               n))
    n))

(defun drgnx-settings-turn-on-package-settings ()
  "Apply settings.el's entries for packages and Emacs again now, by the applier rule: a value your Lisp or Customize
set since stays, and yours is kept for when it can apply."
  (interactive)
  (setq drgnx-settings-package-settings-off nil)
  (let ((r (drgnx-settings-apply-global)))
    (when (called-interactively-p 'interactive)
      (message "Package settings are on: %d applied, %d kept behind your Lisp or Customize"
               (cl-count 'applied r :key #'cdr) (cl-count 'stored r :key #'cdr)))
    r))

(provide 'drgnx-settings-apply)
;;; drgnx-settings-apply.el ends here
