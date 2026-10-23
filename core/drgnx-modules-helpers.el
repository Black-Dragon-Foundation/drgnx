;;; drgnx-modules-helpers.el --- Options, alist keys, face specs and remaps that undo themselves -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A module's setup changes global state in a few ways a hook or advice helper does not cover.
;; Each function here makes the change and pushes its own undo (`drgnx-modules-push-undo'); the
;; undo changes nothing unless the state is still what this module set, so it never removes what
;; someone else (the user, a theme, another module) put there since.  Outside a setup they only
;; make the change.  See docs/develop/core.md, "Modules".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-modules-record)
(require 'drgnx-settings-resolve)

(defun drgnx-module--set-option (var value)
  "Set the default value of VAR to VALUE through its custom setter, else `set-default'.
Quietly: a setter that adds a hook or turns a global mode on is undone by the claim, not by the safety net."
  (drgnx-modules--quietly (funcall (or (get var 'custom-set) #'set-default) var value)))

;;; Claims: two modules may change the same target

(defvar drgnx-module--claims (make-hash-table :test 'equal)
  "Target → list of boxes (OLD), newest first: who changed it and what each found there.
A target is (option VAR), (alist VAR KEY), (face FACE) or (key MAP-SYMBOL KEY).")

(defun drgnx-module--claim (target old)
  "Claim TARGET, which held OLD; return the box that stands for the claim."
  (let ((box (list old)))
    (push box (gethash target drgnx-module--claims))
    box))

(defun drgnx-module--release (target box ours-p restore)
  "Give up BOX's claim on TARGET (the undo of a helper).
The newest claim restores: when (funcall OURS-P) says the state is still what it set, it calls
RESTORE with the old state in the box.  An older claim, released while newer ones stand, leaves the
live state alone and hands its old state to the claim just above it, so the target ends where it
started whichever module is torn down first."
  (let* ((stack (gethash target drgnx-module--claims))
         (tail (memq box stack)))
    (when tail
      (if (eq tail stack)
          (progn
            (if (cdr stack) (puthash target (cdr stack) drgnx-module--claims) (remhash target drgnx-module--claims))
            (when (funcall ours-p) (funcall restore (car box))))
        (let ((above stack))
          (while (not (eq (cdr above) tail)) (setq above (cdr above)))
          (setcar (car above) (car box))
          (setcdr above (cdr tail)))))))

;;; Helpers

(defun drgnx-module-set (var value)
  "Set option VAR to VALUE as the module's claim; the module's undo drops the claim.
In a setup, an option (a `defcustom', a built-in option, or a variable not loaded yet) is
claimed for the module (`drgnx-settings-claim') and resolved with settings.el
\(`drgnx-settings-resolve-apply'): the value goes through theme `drgnx' and applies only where
drgnx's layer is Emacs's winner, so Customize, `use-package :custom' and your Lisp keep theirs,
and a settings.el entry wins over it by the setting's `:merge'.  The undo drops the claim and
resolves again: another module's claim takes over, else the option goes back to the layer below
\(or unbound again, if it was) while its value is still the one drgnx left there.

A plain variable (bound, no standard value) is set directly: through VAR's custom `:set'
function when it has one (else `set-default'), both ways.  Its undo runs only while VAR's
default value is still the one this call set; a list that is stored by reference and changed
in place later still counts as ours, so the undo overwrites that change.  Two modules that set
the same VAR may be torn down in either order."
  (let ((rec (drgnx-modules--recording-p)))
    (if (and rec (drgnx-settings-resolve--value-route-p var))
        (let ((module drgnx-modules--current))
          (drgnx-settings-claim var module 'value value)
          (drgnx-modules-push-undo                 ; first: a setter that fails rolls the claim back too
           (format "option %s" var)
           (lambda ()
             (drgnx-settings-unclaim var module 'value value)
             (drgnx-settings-resolve-apply var)))
          (drgnx-settings-resolve-apply var))
      (let* ((had (and rec (default-boundp var)))
             (old (and had (default-value var))))
        (drgnx-module--set-option var value)
        (when rec
          (let* ((ours (default-value var))   ; what a setter stored, which may differ from VALUE
                 (target (list 'option var))
                 (box (drgnx-module--claim target (cons had old)))
                 (module drgnx-modules--current))
            (drgnx-settings-claim var module 'value value)
            (drgnx-settings-resolve--note var)
            (drgnx-modules-push-undo
             (format "option %s" var)
             (lambda ()
               (drgnx-module--release
                target box
                (lambda () (and (default-boundp var) (equal (default-value var) ours)))
                (lambda (prev)
                  (if (car prev) (drgnx-module--set-option var (cdr prev)) (makunbound var))))
               (drgnx-settings-unclaim var module 'value value)
               (drgnx-settings-resolve--forget var)
               (drgnx-settings-resolve--note var)))))))))

(defun drgnx-module-alist-put (var key value)
  "Set KEY to VALUE in the alist that is VAR's default value; the module's undo puts it back.
KEY is compared with `equal' (an `auto-mode-alist' key is a string).  The alist is replaced,
never mutated, and stored through VAR's custom `:set' function when it has one.  VAR need not be
bound yet (the alist is then empty).  The undo puts the old entry back, or removes KEY when there
was none, only while KEY still holds VALUE.  Two modules that put the same KEY may be torn down in
either order.
In a setup the key is also the module's claim (`drgnx-settings-claim').  When settings.el has an
entry for VAR (or theme `drgnx' holds VAR), the claim is resolved with it by the setting's
`:merge' instead (`drgnx-settings-resolve-apply': `replace' leaves the key out and lists it as
replaced, `alist' keeps it beside settings.el's keys), and the undo drops the claim and resolves
again."
  (let* ((rec (drgnx-modules--recording-p))
         (module drgnx-modules--current)
         (new (cons key value)))
    (if (and rec (drgnx-settings-resolve--theme-p var))
        (progn
          (drgnx-settings-claim var module 'key new)
          (drgnx-modules-push-undo                 ; first: a setter that fails rolls the claim back too
           (format "alist %s key %S" var key)
           (lambda ()
             (drgnx-settings-unclaim var module 'key new)
             (drgnx-settings-resolve-apply var)))
          (drgnx-settings-resolve-apply var))
      (let* ((alist (and (default-boundp var) (default-value var)))
             (old (assoc key alist)))
        (drgnx-module--set-option var (if old
                                          (mapcar (lambda (cell) (if (eq cell old) new cell)) alist)
                                        (cons new alist)))
        (when rec
          (let* ((target (list 'alist var key))
                 (box (drgnx-module--claim target old)))
            (drgnx-settings-claim var module 'key new)
            (drgnx-settings-resolve--note var)
            (drgnx-modules-push-undo
             (format "alist %s key %S" var key)
             (lambda ()
               (if (drgnx-settings-resolve--theme-p var)
                   ;; settings.el holds VAR now: the resolved value has no direct change of ours to put back
                   (drgnx-module--release target box #'ignore #'ignore)
                 (drgnx-module--release
                  target box
                  (lambda ()
                    (let ((cell (and (default-boundp var) (assoc key (default-value var)))))
                      (and cell (equal (cdr cell) value))))
                  (lambda (prev)
                    (let* ((alist (default-value var)) (cell (assoc key alist)))
                      (drgnx-module--set-option var (if prev
                                                        (mapcar (lambda (c) (if (eq c cell) prev c)) alist)
                                                      (remq cell alist)))))))
               (drgnx-settings-unclaim var module 'key new)
               (drgnx-settings-resolve-apply var)
               (drgnx-settings-resolve--note var)))))))))

(defun drgnx-module-face-spec (face spec)
  "Give FACE the default spec SPEC (`face-defface-spec'); the module's undo puts the old one back.
The undo runs only while the face's default spec is still SPEC, so a spec changed since, and
what the user customized or a theme set (kept apart from the default spec), stay.  Note that
`face-spec-set' recalculates the face: an attribute set directly with `set-face-attribute' is
wiped.  Two modules that set the same FACE may be torn down in either order."
  (let ((rec (drgnx-modules--recording-p))
        (old (get face 'face-defface-spec)))
    (drgnx-modules--quietly (face-spec-set face spec 'face-defface-spec))
    (when rec
      (let* ((target (list 'face face))
             (box (drgnx-module--claim target old)))
        (drgnx-modules-push-undo
         (format "face %s" face)
         (lambda ()
           (drgnx-module--release
            target box
            (lambda () (equal (get face 'face-defface-spec) spec))
            (lambda (prev) (drgnx-modules--quietly (face-spec-set face prev 'face-defface-spec))))))))))

(defconst drgnx-module--pointer-event-regexp
  "\\`\\(?:[ACHMSs]-\\)*\\(?:down-\\|drag-\\|double-\\|triple-\\)?\\(?:mouse\\|wheel\\)-"
  "Matches the name of a mouse or wheel event symbol (mouse-1, C-down-mouse-3, wheel-up).")

(defconst drgnx-module--chrome-prefixes
  '(remap menu-bar tool-bar tab-bar tab-line header-line mode-line vertical-scroll-bar
          horizontal-scroll-bar left-fringe right-fringe)
  "First events of a key that is not typed: remaps and the parts of the frame and window chrome.")

(defun drgnx-module--chrome-key-p (key)
  "Non-nil if KEY, a vector, is a remap or a mouse/chrome event, not a typed key."
  (and (vectorp key) (> (length key) 0)
       (or (memq (aref key 0) drgnx-module--chrome-prefixes)
           (let ((last (aref key (1- (length key)))))
             (and (symbolp last) (string-match-p drgnx-module--pointer-event-regexp (symbol-name last)))))))

(defun drgnx-module--own-binding (map key)
  "The binding of KEY in MAP itself, ignoring its parent keymap; nil if none."
  (let ((parent (keymap-parent map)))
    (set-keymap-parent map nil)
    (unwind-protect (let ((b (lookup-key map key))) (and (not (numberp b)) b))
      (set-keymap-parent map parent))))

(defun drgnx-module-define-key (map-symbol key def)
  "Bind KEY to DEF in the keymap that is the value of MAP-SYMBOL; the module's undo puts back the old binding.
For remaps (`[remap CMD]') and mouse and chrome events (`[mode-line mouse-1]', `[menu-bar ...]')
only: keyboard keys come from the profiles (`keys/*.eld'), so a keyboard key signals an error.
The map object is changed in place, never rebound.  The undo runs only while KEY still holds DEF
in the map, and removes the entry when the map had none.  Two modules that bind the same KEY may
be torn down in either order."
  (let ((map (and (boundp map-symbol) (symbol-value map-symbol))))
    (unless (keymapp map) (error "%S is not a keymap variable" map-symbol))
    (unless (drgnx-module--chrome-key-p key)
      (error "Keyboard key %S: bind it through the key profiles; helpers take remaps and mouse/chrome events" key))
    (let ((rec (drgnx-modules--recording-p))
          (old (drgnx-module--own-binding map key)))
      (define-key map key def)
      (when rec
        (let* ((target (list 'key map-symbol key))
               (box (drgnx-module--claim target old)))
          (drgnx-modules-push-undo
           (format "key %S in %s" key map-symbol)
           (lambda ()
             (drgnx-module--release
              target box
              (lambda () (equal (drgnx-module--own-binding map key) def))
              (lambda (prev) (define-key map key prev (null prev)))))))))))

;;; Hooks and advice: named functions, paired with their removal


(defvar drgnx-module--releasers (make-hash-table :test 'equal)
  "(MODULE . TARGET) → the release functions of that module's live claims, newest first.
MODULE is the one whose setup made the claim (`drgnx-modules--current').
`drgnx-module-unhook' and `drgnx-module-unadvise' run them to undo early.")

(defun drgnx-module--paired-add (target label present-p add remove)
  "Run ADD, claim TARGET for the module whose setup runs and push the undo that runs REMOVE when no claim is left.
PRESENT-P: whether the addition is there already (the claim remembers it, so a function that was
on the hook before stays).  Outside a setup this only runs ADD.  The undo can also run early
\(`drgnx-module--paired-remove'); it runs once."
  (let* ((rec (drgnx-modules--recording-p))
         (old (and rec (funcall present-p))))
    (drgnx-modules--quietly (funcall add))
    (when rec
      (let* ((box (drgnx-module--claim target old))
             (key (cons drgnx-modules--current target))
             (done nil)
             (release nil))
        (setq release
              (lambda ()
                (unless done
                  (setq done t)
                  (if-let* ((rest (delq release (gethash key drgnx-module--releasers))))
                      (puthash key rest drgnx-module--releasers)
                    (remhash key drgnx-module--releasers))
                  (drgnx-module--release target box (lambda () t)
                                         (lambda (prev) (unless prev (funcall remove)))))))
        (push release (gethash key drgnx-module--releasers))
        (drgnx-modules-push-undo label release)))))

(defun drgnx-module--paired-remove (module target remove)
  "Undo the additions at TARGET of the module whose setup runs (else MODULE) now.
When it made none, run REMOVE unless another claim stands."
  (let ((releasers (gethash (cons (or drgnx-modules--current module) target) drgnx-module--releasers)))
    (if releasers
        (dolist (release (copy-sequence releasers)) (funcall release))
      (unless (gethash target drgnx-module--claims) (funcall remove)))))

(defun drgnx-module--hook-add (hook fn depth)
  "Add FN to HOOK (each, when a list) with DEPTH; see `drgnx-module--paired-add'."
  (dolist (h (if (listp hook) hook (list hook)))
    (drgnx-module--paired-add
     (list 'hook h fn) (format "hook %s %s" h fn)
     (lambda () (and (default-boundp h) (memq fn (default-value h)) t))
     (lambda () (add-hook h fn depth))
     (lambda () (remove-hook h fn)))))

(defun drgnx-module--hook-remove (hook fn module)
  "Remove FN from HOOK (each, when a list) for MODULE now."
  (dolist (h (if (listp hook) hook (list hook)))
    (drgnx-module--paired-remove module (list 'hook h fn) (lambda () (remove-hook h fn)))))

(defun drgnx-module--advice-add (symbol how fn)
  "Advise SYMBOL with FN, named by it (the name is module-qualified); see `drgnx-module--paired-add'."
  (drgnx-module--paired-add
   (list 'advice symbol fn) (format "advice %s %s" symbol fn)
   (lambda () (and (advice-member-p fn symbol) t))
   (lambda () (advice-add symbol how fn `((name . ,fn))))
   (lambda () (advice-remove symbol fn))))

(defun drgnx-module--advice-remove (symbol fn module)
  "Remove FN from SYMBOL's advice for MODULE now."
  (drgnx-module--paired-remove module (list 'advice symbol fn) (lambda () (advice-remove symbol fn))))

(defvar drgnx-module--file-scans (make-hash-table :test 'equal)
  "File → (MTIME MODULE . NAMES): what a scan of the file found; renewed when the file's mtime changes.")

(defun drgnx-module--parse (body)
  "Split BODY into leading `:module' and `:depth' pairs and the rest: (OPTIONS . REST).
OPTIONS is a plist; a `:module' value loses its quote."
  (let (opts)
    (while (memq (car-safe body) '(:module :depth))
      (setq opts (plist-put opts (car body) (cadr body)) body (cddr body)))
    (when (eq (car-safe (plist-get opts :module)) 'quote)
      (setq opts (plist-put opts :module (cadr (plist-get opts :module)))))
    (cons opts body)))

(defun drgnx-module--scan-forms (form module acc)
  "Collect into ACC (a cons holding a list, newest first) the function name of each hook or advice macro
call in FORM that is MODULE's; return ACC."
  (when (consp form)
    (let* ((kind (car form))
           (name (and (memq kind '(drgnx-module-hook drgnx-module-advice))
                      (nth (if (eq kind 'drgnx-module-hook) 2 3) form))))
      (when (and name (symbolp name))
        (let* ((opts (car (drgnx-module--parse (nthcdr (if (eq kind 'drgnx-module-hook) 4 5) form))))
               (m (or (plist-get opts :module) module)))
          (when (eq m module) (push (drgnx-module--function-name m name) (car acc))))))
    (while (consp form)
      (drgnx-module--scan-forms (car form) module acc)
      (setq form (cdr form))))
  acc)

(defun drgnx-module--scan (file)
  "What FILE's forms say: (MTIME MODULE . FUNCTIONS) where MODULE is its `drgnx-module-define' (nil
when none) and FUNCTIONS the names its hook and advice macros define for that module.  Read, never
run; cached by mtime."
  (let ((mtime (file-attribute-modification-time (file-attributes file)))
        (hit (gethash file drgnx-module--file-scans)))
    (if (and hit (equal (car hit) mtime))
        hit
      (let ((forms nil) (module nil))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (condition-case nil
              (while t (push (read (current-buffer)) forms))
            (error nil)))                 ; end of file, or a form the reader cannot take: stop there
        (setq forms (nreverse forms))
        (dolist (f forms)
          (when (and (not module) (eq (car-safe f) 'drgnx-module-define))
            (let ((n (cadr f)))
              (setq module (if (eq (car-safe n) 'quote) (cadr n) n)))))
        (let ((acc (list nil)))
          (when module (drgnx-module--scan-forms forms module acc))
          (puthash file (cl-list* mtime module (car acc)) drgnx-module--file-scans))))))

(defun drgnx-module--file ()
  "The file being loaded or compiled, or nil."
  (or (macroexp-file-name) (bound-and-true-p byte-compile-current-file) load-file-name buffer-file-name))

(defun drgnx-module--file-module ()
  "The module the file being loaded or compiled defines (`drgnx-module-define'), else an error."
  (let* ((file (drgnx-module--file))
         (module (and file (file-readable-p file) (cadr (drgnx-module--scan file)))))
    (or module
        (error "Cannot tell the module of %s: give `:module NAME' (the file has no drgnx-module-define)" file))))

(defun drgnx-module--function-name (module name)
  "The symbol `drgnx-MODULE--NAME', the named function a helper defines."
  (unless (and name (symbolp name))
    (error "A hook or advice NAME is a plain symbol, not %S" name))
  (intern (format "drgnx-%s--%s" module name)))

(defun drgnx-module--unique-function (module name)
  "The function `drgnx-MODULE--NAME'; an error when this module's file uses NAME for two helpers."
  (let* ((fn (drgnx-module--function-name module name))
         (file (drgnx-module--file))
         (scan (and file (file-readable-p file) (drgnx-module--scan file))))
    (when (and scan (eq (cadr scan) module) (> (seq-count (lambda (f) (eq f fn)) (cddr scan)) 1))
      (error "%s is defined by more than one hook or advice helper in %s: give each a NAME of its own" fn file))
    fn))

(defun drgnx-module--resolve (body)
  "Parse BODY's leading options: (MODULE OPTIONS . REST), MODULE defaulting to the file's."
  (let ((parsed (drgnx-module--parse body)))
    (cl-list* (or (plist-get (car parsed) :module) (drgnx-module--file-module)) (car parsed) (cdr parsed))))

(defmacro drgnx-module-hook (hook name arglist &rest body)
  "Define `drgnx-<module>--NAME' as (lambda ARGLIST BODY...) and add it to HOOK; the undo removes it.
HOOK is evaluated: a hook symbol, or a list of them.  The module is the one the file's
`drgnx-module-define' names, or `:module NAME' (a symbol) first in BODY; `:depth N' there is
passed to `add-hook'.  Running it again changes nothing.  The undo removes the function only when
no other claim on it stands (two modules adding the same function tear down in either order), and
keeps it when it was on the hook before.  NAME is used once per module file (an error otherwise).
`drgnx-module-unhook' removes it early."
  (declare (indent 3) (debug (form symbolp sexp body)))
  (pcase-let* ((`(,module ,opts . ,rest) (drgnx-module--resolve body))
               (fn (drgnx-module--unique-function module name)))
    `(progn (defun ,fn ,arglist ,@rest)
            (drgnx-module--hook-add ,hook ',fn ,(plist-get opts :depth)))))

(defmacro drgnx-module-unhook (hook name &rest options)
  "Remove the function `drgnx-module-hook' defined as NAME from HOOK (each, when a list) now.
OPTIONS: `:module NAME' as for `drgnx-module-hook'.  The module's own claim is dropped, so its
teardown has nothing left to do; another module's claim keeps the function on the hook."
  (declare (indent 2) (debug (form symbolp &rest sexp)))
  (pcase-let ((`(,module ,_opts . ,rest) (drgnx-module--resolve options)))
    (when rest (error "drgnx-module-unhook: only :module may follow NAME, not %S" rest))
    `(drgnx-module--hook-remove ,hook ',(drgnx-module--function-name module name) ',module)))

(defmacro drgnx-module-advice (symbol how name arglist &rest body)
  "Define `drgnx-<module>--NAME' as (lambda ARGLIST BODY...) and advise SYMBOL with it, HOW.
SYMBOL and HOW are evaluated.  The advice is named by the function (`advice-add' name property), so
equal NAMEs of two modules do not replace each other.  `:depth' is refused.  Module, claims and
undo as for `drgnx-module-hook'; `drgnx-module-unadvise' removes it early."
  (declare (indent 4) (debug (form form symbolp sexp body)))
  (pcase-let* ((`(,module ,opts . ,rest) (drgnx-module--resolve body))
               (fn (drgnx-module--unique-function module name)))
    (when (plist-member opts :depth) (error "drgnx-module-advice takes no :depth (use `advice-add' props yourself)"))
    `(progn (defun ,fn ,arglist ,@rest)
            (drgnx-module--advice-add ,symbol ,how ',fn))))

(defmacro drgnx-module-unadvise (symbol name &rest options)
  "Remove the advice `drgnx-module-advice' defined as NAME from SYMBOL now.
OPTIONS: `:module NAME'.  See `drgnx-module-unhook'."
  (declare (indent 2) (debug (form symbolp &rest sexp)))
  (pcase-let ((`(,module ,_opts . ,rest) (drgnx-module--resolve options)))
    (when rest (error "drgnx-module-unadvise: only :module may follow NAME, not %S" rest))
    `(drgnx-module--advice-remove ,symbol ',(drgnx-module--function-name module name) ',module)))

(provide 'drgnx-modules-helpers)
;;; drgnx-modules-helpers.el ends here
