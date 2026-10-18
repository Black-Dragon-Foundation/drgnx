;;; drgnx-modules-fingerprint.el --- A fingerprint of global state, and the diff that names a leak's file -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-modules-fingerprint' reads the global state a module (or a test) can leave behind: timers, processes,
;; buffers, `features', the default values of the hooks drgnx touches, `global-mode-string', the alists a mode
;; writes into, drgnx's registries.  `drgnx-modules-fingerprint-diff' compares two fingerprints and names each
;; difference, with the file that defined the function, advice or timer function concerned (`symbol-file').
;; It is the per-test census of the runner and the check behind `:strict' in the module test helper.
;;
;; The cheap fingerprint is meant to run around every test (a fraction of a millisecond to a millisecond or two);
;; FULL adds a `mapatoms' scan of every hook variable and every advised function, for once per test file.
;; It only reads: no prompt, no display, nothing that blocks.  Batch-safe.  See docs/develop/harness.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'nadvice)
(require 'timer)
(require 'loadhist)

(defvar drgnx-keys--applied)            ; drgnx-keys, when loaded

(defvar drgnx-modules-fingerprint-hooks
  '(kill-buffer-hook kill-emacs-hook after-change-functions window-buffer-change-functions
                     window-size-change-functions window-selection-change-functions window-state-change-functions
                     window-configuration-change-hook window-state-change-hook window-setup-hook delete-frame-functions
                     after-make-frame-functions server-after-make-frame-hook emacs-startup-hook after-init-hook
                     post-command-hook pre-command-hook minibuffer-setup-hook find-file-hook after-save-hook after-revert-hook
                     prog-mode-hook tabulated-list-revert-hook context-menu-functions completion-at-point-functions
                     git-commit-setup-hook dape-active-mode-hook apheleia-inhibit-functions
                     drgnx-first-gui-frame-hook drgnx-agents-changed-functions drgnx-agents-task-functions
                     drgnx-agents-request-functions drgnx-agents-prompt-functions drgnx-agents-error-functions
                     drgnx-agents-env-functions drgnx-hub-event-functions drgnx-hub-disconnect-functions
                     drgnx-gateway-event-functions drgnx-git-changed-functions drgnx-surfaces-run-functions
                     drgnx-signal-window-functions drgnx-rules-mode-hook drgnx-persist-state-functions
                     drgnx-persist-after-restore-functions drgnx-modules-after-stage-functions drgnx-job-tick-functions
                     drgnx-job-clash-answer-functions drgnx-job-card-action-functions drgnx-job-before-review-functions
                     drgnx-ai-refused-functions drgnx-ai-probe-done-hook)
  "The hooks whose default value the cheap fingerprint reads: those drgnx adds to.
`unload-feature-special-hooks' is read as well.  A branch that adds to a hook not listed here adds the
symbol with one line; the FULL scan finds the rest.")

(defvar drgnx-modules-fingerprint-function-variables '(after-focus-change-function)
  "Function-valued variables drgnx wraps with `add-function' (read by their advice, or their value).")

(defvar drgnx-modules-fingerprint-registries
  '(drgnx-commands--table drgnx-wb--sections drgnx-wb--areas drgnx-rules--table drgnx-rules--places
                          (drgnx-signal--subscribers . :functions) drgnx-surfaces-contexts drgnx-layouts-shapes
                          drgnx-layouts-pane-fillers drgnx-config--defs drgnx-memo--watched
                          drgnx-view--types)
  "drgnx's registries whose keys the fingerprint reads: a variable that holds a hash table, an alist or a
list of conses (the key is the car).  `(VAR . :functions)' is an alist KEY → list of functions: each
function is read too.  Unbound variables are skipped.  Branches that add a registry add one line.")

;;;; Items.  A fingerprint field is a list of items (KEY . OBJ): KEY is compared with `equal', OBJ with `eql'.

(defun drgnx-modules-fingerprint--item (key detail obj)
  "The item for KEY (a list) with DETAIL, a single OBJ.  An atomic DETAIL goes into the key (so a fresh but
equal string still matches); anything else is compared as the object it is."
  (if (or (symbolp detail) (stringp detail) (numberp detail))
      (cons (append key (list detail)) obj)
    (cons key detail)))

(defun drgnx-modules-fingerprint--hook-items (hook)
  "Items for the functions in HOOK's default value."
  (when (default-boundp hook)
    (let* ((v (default-value hook))
           (fns (if (or (not (listp v)) (functionp v)) (list v) v))
           (key (list 'hook hook)) items)
      (when (proper-list-p fns)                 ; a dotted or circular list is not a hook's value
        (dolist (f fns)
          (unless (or (eq f t) (null f)) (push (cons key f) items))))
      items)))

(defun drgnx-modules-fingerprint--function-variable-items (var)
  "Items for the `add-function' advice on VAR, a function-valued variable.  Its plain value is not read: the
base function under advice is not reachable by a public function, and a value that changes when advice is added
would report one leak as two lines."
  (when (and (default-boundp var) (default-value var))
    (let ((key (list 'function-variable var)) items)
      (advice-function-mapc (lambda (f _props) (push (cons key f) items)) (default-value var))
      items)))

(defun drgnx-modules-fingerprint--alist-items (kind var)
  "Items for the alist VAR: its keys and their values (a value changed in place shows)."
  (when (boundp var)
    (let (items)
      (dolist (e (symbol-value var))
        (when (consp e)
          (push (drgnx-modules-fingerprint--item (list kind) (car e) (cdr e)) items)))
      items)))

(defun drgnx-modules-fingerprint--list-items (kind var)
  "Items for the elements of the list VAR."
  (when (boundp var)
    (let (items)
      (dolist (e (symbol-value var)) (push (cons (list kind) e) items))
      items)))

(defun drgnx-modules-fingerprint--after-load-items ()
  "Items for `after-load-alist': FILE-OR-FEATURE → each form (closures compared by identity)."
  (let (items)
    (dolist (e after-load-alist)
      (when (consp e)
        (dolist (form (cdr e))
          (push (drgnx-modules-fingerprint--item (list 'after-load) (car e) form) items))))
    items))

(defun drgnx-modules-fingerprint--registry-items (spec)
  "Items for one entry of `drgnx-modules-fingerprint-registries'."
  (let* ((var (if (consp spec) (car spec) spec))
         (functions (and (consp spec) (eq (cdr spec) :functions))))
    (when (and (boundp var) (symbol-value var))
      (let ((v (symbol-value var)) items)
        (cond
         ((hash-table-p v)
          (maphash (lambda (k _) (push (drgnx-modules-fingerprint--item (list 'registry var) k t) items)) v))
         ((listp v)
          (dolist (e v)
            (let ((k (if (consp e) (car e) e)))
              (if (and functions (consp e) (listp (cdr e)))
                  (dolist (f (cdr e))
                    (push (cons (append (list 'registry var) (list k)) f) items))
                (push (drgnx-modules-fingerprint--item (list 'registry var) k t) items))))))
        items))))

(defun drgnx-modules-fingerprint--timers ()
  (let (items)
    (dolist (tm timer-list) (push (cons '(timer) tm) items))
    (dolist (tm timer-idle-list) (push (cons '(timer idle) tm) items))
    items))

(defvar drgnx-modules-fingerprint--own nil
  "(HOOKS . FUNCTION-VARIABLES): the bound `drgnx-*' symbols ending in -hook, -hooks, -functions / -function.
Read once per Emacs (`apropos-internal', in C) and again by every FULL scan; nil until then.  A library loaded
after that, and not scanned since, is not in it (the next FULL scan adds it).")

(defvar drgnx-modules-fingerprint--names nil
  "Cache of the two name lists: (INPUTS HOOKS FUNCTION-VARIABLES), INPUTS being the lists they were made from.")

(defun drgnx-modules-fingerprint--own ()
  "`drgnx-modules-fingerprint--own', read from the obarray on first use."
  (or drgnx-modules-fingerprint--own
      (let (hooks fvars)
        (dolist (s (apropos-internal "\\`drgnx-.*\\(?:-hooks?\\|-functions?\\)\\'" #'default-boundp))
          (when (eq (indirect-variable s) s)
            (if (string-suffix-p "-function" (symbol-name s)) (push s fvars) (push s hooks))))
        (setq drgnx-modules-fingerprint--own (cons hooks fvars)))))

(defun drgnx-modules-fingerprint--names ()
  "(HOOKS . FUNCTION-VARIABLES) to read: the hand lists, `unload-feature-special-hooks' and drgnx's own.
Rebuilt only when one of its inputs is a different list."
  (let* ((own (drgnx-modules-fingerprint--own))
         (inputs (list drgnx-modules-fingerprint-hooks
                       (and (boundp 'unload-feature-special-hooks) unload-feature-special-hooks)
                       drgnx-modules-fingerprint-function-variables own)))
    (unless (and drgnx-modules-fingerprint--names
                 (cl-every #'eq inputs (car drgnx-modules-fingerprint--names)))
      (setq drgnx-modules-fingerprint--names
            (list inputs
                  (delete-dups (append (nth 0 inputs) (nth 1 inputs) (car own)))
                  (delete-dups (append (nth 2 inputs) (cdr own))))))
    (cdr drgnx-modules-fingerprint--names)))

(defun drgnx-modules-fingerprint--hook-names () (car (drgnx-modules-fingerprint--names)))
(defun drgnx-modules-fingerprint--function-variable-names () (cadr (drgnx-modules-fingerprint--names)))

(defun drgnx-modules-fingerprint--hook-name-p (name)
  (and (> (length name) 6)
       (or (string-suffix-p "-hook" name) (string-suffix-p "-hooks" name) (string-suffix-p "-functions" name))))

(defun drgnx-modules-fingerprint--scan ()
  "(:all-hooks ITEMS :advice ITEMS): every bound hook variable's default value, every `-function' variable's
value or advice, every advised function.  A variable alias is read once, under its base name; a variable
whose value is not what its name says is skipped.  About 12 ms compiled."
  (let (hooks fvars advice own-hooks own-fvars)
    (mapatoms
     (lambda (s)
       (when (fboundp s)
         (advice-mapc (lambda (f _props) (push (cons (list 'advice s) f) advice)) s))
       (when (and (default-boundp s) (eq (indirect-variable s) s))
         (let* ((name (symbol-name s)) (own (string-prefix-p "drgnx-" name)))
           (cond
            ((drgnx-modules-fingerprint--hook-name-p name)
             (when own (push s own-hooks))
             (condition-case nil
                 (setq hooks (nconc (drgnx-modules-fingerprint--hook-items s) hooks))
               (error nil)))
            ((and (> (length name) 9) (string-suffix-p "-function" name))
             (when own (push s own-fvars))
             (condition-case nil
                 (setq fvars (nconc (drgnx-modules-fingerprint--function-variable-items s) fvars))
               (error nil))))))))
    (setq drgnx-modules-fingerprint--own (cons own-hooks own-fvars))
    (list :all-hooks (nconc hooks fvars) :advice advice)))

(defun drgnx-modules-fingerprint--full-items ()
  "The `mapatoms' scan, compiled first when it is not: interpreted it costs ~110 ms (27,000 symbols, each a trip
through the evaluator), compiled ~12 ms, and compiling it takes ~8 ms once.  A built drgnx (.elc) skips that."
  (unless (compiled-function-p (symbol-function 'drgnx-modules-fingerprint--scan))
    (ignore-errors
      (let ((byte-compile-warnings nil) (inhibit-message t))
        (byte-compile 'drgnx-modules-fingerprint--scan))))
  (let* ((scan (drgnx-modules-fingerprint--scan)) (extra nil))
    ;; a listed name the scan's suffix test would not pick (a hand-listed odd one) is still read
    (dolist (h (drgnx-modules-fingerprint--hook-names))
      (unless (and (drgnx-modules-fingerprint--hook-name-p (symbol-name h)) (eq (indirect-variable h) h))
        (setq extra (nconc (ignore-errors (drgnx-modules-fingerprint--hook-items h)) extra))))
    (when extra (setq scan (plist-put scan :all-hooks (nconc extra (plist-get scan :all-hooks)))))
    scan))

(defun drgnx-modules-fingerprint (&optional full)
  "A plist of the global state a module or a test can leave behind (see this file's commentary).
Cheap: meant to run around every test.  With FULL, a `mapatoms' scan of every hook variable and every advised
function (about 12 ms): once per test file.  The diff of two full ones reads `:all-hooks', not `:hooks' and
`:function-variables' (which it contains), so a leak is one line.  Compare two with `drgnx-modules-fingerprint-diff'."
  (let (hooks fvars regs)
    (dolist (h (drgnx-modules-fingerprint--hook-names))
      (setq hooks (nconc (drgnx-modules-fingerprint--hook-items h) hooks)))
    (dolist (v (drgnx-modules-fingerprint--function-variable-names))
      (setq fvars (nconc (drgnx-modules-fingerprint--function-variable-items v) fvars)))
    (dolist (r drgnx-modules-fingerprint-registries)
      (setq regs (nconc (drgnx-modules-fingerprint--registry-items r) regs)))
    (let ((cheap
           (list :timers (drgnx-modules-fingerprint--timers)
                 :processes (mapcar (lambda (p) (cons (list 'process (process-name p)) p)) (process-list))
                 :buffers (mapcar (lambda (b) (cons (list 'buffer (buffer-name b)) b)) (buffer-list))
                 :features features
                 :hooks hooks
                 :function-variables fvars
                 :global-mode-string (drgnx-modules-fingerprint--list-items 'mode-string 'global-mode-string)
                 :auto-mode-alist (drgnx-modules-fingerprint--alist-items 'auto-mode 'auto-mode-alist)
                 :major-mode-remap-alist
                 (drgnx-modules-fingerprint--alist-items 'mode-remap 'major-mode-remap-alist)
                 :after-load-alist (drgnx-modules-fingerprint--after-load-items)
                 :emulation-mode-map-alists
                 (drgnx-modules-fingerprint--list-items 'emulation-map 'emulation-mode-map-alists)
                 :default-frame-alist
                 (drgnx-modules-fingerprint--alist-items 'frame-parameter 'default-frame-alist)
                 :global-minor-modes
                 (drgnx-modules-fingerprint--list-items 'minor-mode 'global-minor-modes)
                 :keys-applied (and (boundp 'drgnx-keys--applied) (length drgnx-keys--applied))
                 :registries regs)))
      (if full (append cheap (drgnx-modules-fingerprint--full-items)) cheap))))

;;;; The diff

(defun drgnx-modules-fingerprint--normalize-file (file)
  "FILE as a source path: the .el of a loaded .elc; relative to `drgnx-dir' when inside it."
  (when file
    (let ((f (if (string-suffix-p ".elc" file) (substring file 0 -1) file)))
      (if (and (boundp 'drgnx-dir) (stringp drgnx-dir) (file-in-directory-p f drgnx-dir))
          (file-relative-name f drgnx-dir)
        f))))

(declare-function drgnx-timer-describe "drgnx-timer")

(defun drgnx-modules-fingerprint--source (item)
  "The file that defined the function, advice, timer function or feature of ITEM, or nil."
  (let* ((kind (car (car item))) (obj (cdr item))
         (fn (pcase kind
               ('timer (and (timerp obj) (let ((d (and (fboundp 'drgnx-timer-describe) (drgnx-timer-describe obj))))
                                           (if d (plist-get d :fn) (timer--function obj)))))
               ((or 'hook 'advice 'function-variable 'registry) obj)
               (_ nil))))
    (drgnx-modules-fingerprint--normalize-file
     (cond
      ((and fn (symbolp fn) (not (eq fn t)) (not (null fn))) (symbol-file fn 'defun))
      ((eq kind 'feature) (ignore-errors (feature-file obj)))
      ((and (eq kind 'minor-mode) (symbolp obj)) (symbol-file obj 'defun))))))

(defun drgnx-modules-fingerprint--clip (x)
  (let ((s (format "%S" x)))
    (if (> (length s) 70) (concat (substring s 0 67) "...") s)))

(defun drgnx-modules-fingerprint--what (item sign)
  "A line for ITEM, SIGN being \"+\" (appeared) or \"-\" (gone)."
  (let* ((key (car item)) (kind (car key)) (obj (cdr item)))
    (pcase kind
      ('timer
       (let ((layer (and (timerp obj) (fboundp 'drgnx-timer-describe) (drgnx-timer-describe obj)))
             (fn (and (timerp obj) (timer--function obj))) (rep (and (timerp obj) (timer--repeat-delay obj))))
         (if layer                      ; every layer timer's function is `drgnx-timer--fire': name its key and owner
             (format "timer %s%S (%s) %s%s%s" sign (plist-get layer :key) (plist-get layer :owner)
                     (plist-get layer :fn) (if (cdr key) " idle" "") (if rep (format " repeat %s" rep) ""))
           (format "timer%s %s%s %s" (if (cdr key) " idle" "") sign
                   (drgnx-modules-fingerprint--clip fn) (if rep (format "repeat %s" rep) "once")))))
      ('buffer (format "buffer %s%s" sign (cadr key)))
      ('process (format "process %s%s" sign (cadr key)))
      (_                                ; KIND NAME +REST, e.g. "hook find-file-hook +my-fn"
       (let ((rest (append (mapcar (lambda (x) (format "%s" x)) (cddr key))
                           (unless (eq obj t) (list (drgnx-modules-fingerprint--clip obj))))))
         (concat (format "%s " kind) (and (cdr key) (format "%s " (cadr key)))
                 sign (mapconcat #'identity rest " ")))))))

(defun drgnx-modules-fingerprint--diff-items (before after)
  "Plists for the items only in AFTER (+) and only in BEFORE (-)."
  (cl-flet ((index (items)
              (let ((h (make-hash-table :test #'equal)))
                (dolist (it items) (push (cdr it) (gethash (car it) h)))
                h)))
    (let ((hb (index before)) (ha (index after)) out)
      (cl-flet ((scan (items other sign)
                  (dolist (it items)
                    (unless (memql (cdr it) (gethash (car it) other))
                      (push (list :what (drgnx-modules-fingerprint--what it sign)
                                  :source (drgnx-modules-fingerprint--source it))
                            out)))))
        (scan after hb "+")
        (scan before ha "-"))
      (nreverse out))))

(defun drgnx-modules-fingerprint--diff-features (before after)
  "The features provided since BEFORE: the prefix of AFTER up to BEFORE's cell, else a set difference."
  (let (added (cell after))
    (while (and cell (not (eq cell before))) (push (car cell) added) (setq cell (cdr cell)))
    (unless (or (eq cell before) (null before))        ; the old cell is not a tail: compare as sets
      (setq added (cl-set-difference after before)))
    (nreverse
     (mapcar (lambda (f)
               (list :what (format "feature +%s" f)
                     :source (drgnx-modules-fingerprint--normalize-file (ignore-errors (feature-file f)))))
             added))))

(defun drgnx-modules-fingerprint-diff (before after)
  "What differs between the fingerprints BEFORE and AFTER, as a list of plists (:what LINE :source FILE).
LINE reads like \"hook find-file-hook +drgnx-blame--maybe\" (+ appeared, - gone); FILE is where the
function, advice or timer function was defined, nil when it cannot be told (a lambda).  Fields only one
of the two fingerprints has (FULL against cheap) are skipped."
  (let (out)
    (cl-loop for (field a) on after by #'cddr
             when (and (plist-member before field)
                       ;; `:all-hooks' in both contains `:hooks' and `:function-variables'
                       (not (and (memq field '(:hooks :function-variables))
                                 (plist-member before :all-hooks) (plist-member after :all-hooks))))
             do (let ((b (plist-get before field)))
                  (setq out
                        (append
                         out
                         (pcase field
                           (:features (drgnx-modules-fingerprint--diff-features b a))
                           (:keys-applied
                            (unless (equal a b)
                              (list (list :what (format "drgnx-keys--applied length %s -> %s" b a)
                                          :source nil))))
                           (_ (drgnx-modules-fingerprint--diff-items b a)))))))
    out))

(provide 'drgnx-modules-fingerprint)
;;; drgnx-modules-fingerprint.el ends here
