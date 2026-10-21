;;; drgnx-modules.el --- The module system -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A module is one file `modules/<category>/drgnx-<name>.el' with one `drgnx-module-define'.  It
;; runs in a stage — `startup', `idle' (once Emacs is idle), `first-frame', `first-file',
;; `first-input' — under its own error guard, timed.  It may require other modules, need packages
;; (it waits, reported, until they are installed: Emacs never installs anything by itself), have
;; flags, doctor checks and settings.  The user's choices live in modules.eld in the user dir
;; (`drgnx-user-dir'): disabled modules, enabled ones (those that are off until chosen), flags,
;; external modules; older formats are migrated, an unreadable file is reported and ignored.
;; Preferences: Modules lists every module with its status and turns modules on and off.  See
;; docs/guide/modules.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'tabulated-list)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-config)
(require 'drgnx-hooks)
(require 'drgnx-ui-kit)
(require 'drgnx-pkg-activate)
(require 'drgnx-notice)
(require 'drgnx-modules-record)
(require 'drgnx-timer)
(require 'drgnx-modules-helpers)

(defvar drgnx-modules--table nil "Alist NAME → plist (:doc :stage … :file), in definition order.")
(defvar drgnx-modules--report nil "Alist NAME → plist (:stage :ms :status :error :missing :problems :left).")
(defconst drgnx-modules-stages '(startup idle first-frame first-file first-input))
(defconst drgnx-modules-state-version 2
  "Format of modules.eld.  2: it holds `:enabled' (format 1 had no such field).  An older drgnx reads
a newer file as foreign (defaults, a backup before it writes) instead of dropping `:enabled'.")

(cl-defun drgnx-module-define (name &key doc stage setup requires packages flags doctor settings teardown (default 'on))
  "Define module NAME (a symbol like lang/python).
DOC: one line.  STAGE: one of `drgnx-modules-stages' (default startup).  SETUP: a function.
REQUIRES: modules that must have run.  PACKAGES: features that must be loadable (else the module
waits, reported as missing-packages).  FLAGS: the flags it understands (`drgnx-module-flag-p').
DOCTOR: a function returning problem strings.  SETTINGS: alist VARIABLE → doc.  TEARDOWN: a
function that undoes what the cleanup stack cannot see (`drgnx-module-teardown'), or `restart':
the module is not turned off while Emacs runs.  DEFAULT: `on' (the module runs unless the user
turned it off) or `off' (it stays off, with its packages, until chosen: modules.eld :enabled,
`drgnx-modules-set-enabled')."
  (unless (or (null teardown) (eq teardown 'restart) (functionp teardown))
    (error "drgnx-module-define %s: :teardown must be a function or restart, not %S" name teardown))
  (unless (memq default '(on off)) (error "drgnx-module-define %s: :default must be on or off, not %S" name default))
  (let ((entry (list :default default :doc doc :stage (or stage 'startup) :setup setup :requires requires :packages packages
                     :flags flags :doctor doctor :settings settings :teardown teardown :file load-file-name)))
    (if (assq name drgnx-modules--table)
        (setf (alist-get name drgnx-modules--table) entry)
      (setq drgnx-modules--table (append drgnx-modules--table (list (cons name entry))))))
  name)

;;;; modules.eld

(defun drgnx-modules--from-v0 (data)
  "Format 0 of modules.eld, a bare list of the disabled modules → format 1's plist."
  (list :disabled data))

(drgnx-config-define 'modules
                     :file "modules.eld" :shape 'plist :version drgnx-modules-state-version
                     :migrate '((0 . drgnx-modules--from-v0) (1 . identity))
                     :schema '(plist (:disabled (list-of symbol) "Modules you turned off")
                                     (:enabled (list-of symbol) "Modules that are off until chosen, chosen on")
                                     (:flags (alist symbol (list-of symbol)) "Module flags")
                                     (:external (list-of any) "External modules (each is checked when it loads)")
                                     (:theme symbol "The colour theme onboarding chose"))
                     :default '(:disabled nil) :reload 'start :last-good t
                     :header ";; drgnx modules: what you turned off or on, module flags, external modules (docs/guide/modules.md).\n"
                     :doc "Which modules run, their flags, external modules.")

(defun drgnx-modules--external-ok-p (e)
  (and (consp e) (keywordp (car e)) (symbolp (plist-get e :name))
       (stringp (plist-get e :path)) (listp (plist-get e :features))))

(defun drgnx-modules-read-state ()
  "The user's modules.eld as this Emacs applied it at its start (or after its own write): a plist, the default when
the file is absent or has a mistake; never an error at start.  Do not change it: it is shared."
  (drgnx-config-get 'modules))

(defun drgnx-modules-update-state (fn)
  "Change modules.eld: (FN STATE) under the file's lock, on a fresh read (STATE is nil when the file is absent), so a
change another Emacs just made is kept.  FN returns the new plist and may not move the keys the file has; only the keys
it changed are written (comments and other keys stay).  Signals `drgnx-config-refused' for a file with a mistake or one
a newer drgnx wrote, and leaves it as it was.  Returns the new state."
  (drgnx-config-update 'modules fn))

(defun drgnx-modules--put-list (state key items)
  "A copy of the plist STATE with KEY's list ITEMS; an empty list does not add a key the file has not."
  (if (or items (plist-member state key)) (plist-put (copy-sequence state) key items) state))

(defun drgnx-modules--disabled-in (state module &optional default)
  "Whether MODULE does not run by the plist STATE (a modules.eld): in :disabled, or its default (DEFAULT when
given, else the one it was defined with) is `off' and it is not in :enabled.  :disabled wins."
  (or (memq module (plist-get state :disabled))
      (and (eq (or default (if (drgnx-module-default-off-p module) 'off 'on)) 'off)
           (not (memq module (plist-get state :enabled))))))

(defun drgnx-modules--choose (state module on)
  "The plist STATE with MODULE chosen ON or off: a module that is off until chosen is in :enabled when on; one that
is on by default is in :disabled when off."
  (let* ((off-default (drgnx-module-default-off-p module))
         (enabled (plist-get state :enabled))
         (disabled (remq module (plist-get state :disabled))))
    (setq enabled (if (and off-default on)
                      (if (memq module enabled) enabled (append enabled (list module)))
                    (remq module enabled)))
    (unless (or off-default on) (setq disabled (append disabled (list module))))
    (drgnx-modules--put-list (drgnx-modules--put-list state :enabled enabled) :disabled disabled)))

(defun drgnx-module-flag-p (module flag)
  "Non-nil if the user turned FLAG on for MODULE."
  (memq flag (alist-get module (plist-get (drgnx-modules-read-state) :flags))))

(defun drgnx-module-default-off-p (module)
  "Non-nil if MODULE is defined `:default off': off until the user (or a key profile) chooses it."
  (eq (plist-get (alist-get module drgnx-modules--table) :default) 'off))

(defun drgnx-module-disabled-p (module &optional default)
  "Non-nil if MODULE does not run: in modules.eld :disabled, or its default (DEFAULT when given, else
the one it was defined with) is `off' and it is not in :enabled.  :disabled wins."
  (drgnx-modules--disabled-in (drgnx-modules-read-state) module default))

(defun drgnx-modules-set-enabled (module on)
  "Choose MODULE on or off in modules.eld.  A module that is off until chosen: ON adds it to :enabled and
takes it out of :disabled; off takes it out of :enabled.  One that is on by default: ON takes it out of
:disabled, off puts it there.  MODULE must be defined (its default is read from the table).  Returns
the new state; `drgnx-config-refused' for a file with a mistake or a newer one."
  (drgnx-modules-update-state (lambda (state) (drgnx-modules--choose state module on))))

;;;; Running

(defun drgnx-modules--notice (name status err missing problems)
  "Say module NAME's STATUS as a notice: a condition that stays until it works or is turned off."
  (pcase status
    ('failed (drgnx-notify 'modules 'fail (format "%s did not start: %s" name err) :id name :life 'condition
                           :fix "Turn it off in Preferences: Modules, or report the error"
                           :command 'preferences-modules))
    ('missing-packages (drgnx-notify 'modules 'warn (format "%s waits for packages: %s" name
                                                            (mapconcat #'symbol-name missing " "))
                                     :id name :life 'condition :fix "drgnx sync installs them"))
    ('missing-requires (drgnx-notify 'modules 'warn (format "%s needs %s, which did not start" name
                                                            (mapconcat #'symbol-name missing ", "))
                                     :id name :life 'condition))
    (_ (if (and (eq status 'ok) problems)
           (drgnx-notify 'modules 'warn (format "%s: %s" name (string-join problems "; ")) :id name :life 'condition)
         (drgnx-notice-clear 'modules name)))))

(defun drgnx-modules--notice-off ()
  "One info condition naming the modules that are off (`modules' . `off'); cleared when none is.  Off: turned off
in this session, or disabled in modules.eld though on by default (one that is off until chosen is not named)."
  (let ((off (delq nil (mapcar (lambda (r) (and (pcase (plist-get (cdr r) :status)
                                                  ('off t)
                                                  ('disabled (not (drgnx-module-default-off-p (car r)))))
                                                (car r)))
                               drgnx-modules--report))))
    (if off
        (drgnx-notify 'modules 'info (format (if (cdr off) "%d modules are off: %s" "%d module is off: %s")
                                             (length off) (mapconcat #'symbol-name (reverse off) ", "))
                      :id 'off :life 'condition :command 'preferences-modules)
      (drgnx-notice-clear 'modules 'off))))

(defun drgnx-modules--record (name stage ms status &optional err missing problems)
  (setf (alist-get name drgnx-modules--report)
        (list :stage stage :ms ms :status status :error err :missing missing :problems problems
              :left (alist-get name drgnx-modules--left)))
  (drgnx-modules--notice name status err missing problems)
  (drgnx-modules--notice-off))

(defun drgnx-modules--ok-p (name) (eq (plist-get (alist-get name drgnx-modules--report) :status) 'ok))

(defun drgnx-module-running-p (name)
  "Whether module NAME runs: its setup ran in this Emacs and went well (not disabled, missing or failed)."
  (drgnx-modules--ok-p name))

(defvar drgnx-modules-after-stage-functions nil
  "Called with the stage after its modules ran (core re-applies keys and menus after later stages).")

(defun drgnx-modules--in-order (stage)
  "The modules of STAGE, each after the modules of the stage it requires; otherwise in definition
order (a cycle keeps it, and is reported waiting)."
  (let ((todo (seq-filter (lambda (m) (eq (plist-get (cdr m) :stage) stage)) drgnx-modules--table))
        (done nil))
    (while todo
      (let ((ready (or (seq-filter (lambda (m) (not (seq-some (lambda (r) (assq r todo)) (plist-get (cdr m) :requires))))
                                   todo)
                       todo)))
        (setq done (append done ready)
              todo (seq-remove (lambda (m) (memq m ready)) todo))))
    done))

(defun drgnx-modules--run-one (name spec stage)
  "Run module NAME (SPEC) of STAGE, isolated and timed, and record it.  Non-nil if its setup ran."
  (let ((missing (seq-remove (lambda (p) (or (featurep p) (locate-library (symbol-name p))))
                             (plist-get spec :packages)))
        (unmet (seq-remove #'drgnx-modules--ok-p (plist-get spec :requires))))
    (cond
     ((drgnx-module-disabled-p name) (drgnx-modules--record name stage 0 'disabled) nil)
     (missing (drgnx-modules--record name stage 0 'missing-packages nil missing) nil)
     (unmet (drgnx-modules--record name stage 0 'missing-requires nil unmet) nil)
     (t (let* ((t0 (float-time))
               (failure (drgnx-modules--run-setup name (plist-get spec :setup)))   ; rolled back if unfinished
               (err (car failure))
               (ms (round (* 1000 (- (float-time) t0))))
               (problems (and (not err) (plist-get spec :doctor)
                              (condition-case e (funcall (plist-get spec :doctor))
                                (error (list (format "its doctor check failed: %s" (error-message-string e))))))))
          (drgnx-modules--record name stage ms (if err 'failed 'ok) err nil (append (cdr failure) problems)))
        t))))

(defun drgnx-modules-run (stage)
  "Run the setup of every module of STAGE, each isolated and timed; then (if one ran) the hooks."
  (let ((ran nil))
    (dolist (m (drgnx-modules--in-order stage))
      (when (drgnx-modules--run-one (car m) (cdr m) stage) (setq ran t)))
    (when ran (run-hook-with-args 'drgnx-modules-after-stage-functions stage))))

(defun drgnx-modules-load-directory (dir)
  "Load every module file under DIR (modules/<category>/drgnx-*.el); a file that fails to
load is reported as module <category>/<file name>, naming the library it loaded that failed."
  (dolist (file (directory-files-recursively dir "\\`drgnx-.*\\.el\\'"))
    (let ((t0 (float-time)) (inner nil))
      (condition-case e
          ;; the innermost file being loaded when the error was signalled (`handler-bind')
          (handler-bind ((error (lambda (_) (setq inner load-file-name))))
            (load (file-name-sans-extension file) nil t))   ; the .elc when `drgnx build' made one
        (error (drgnx-modules--record
                (intern (format "%s/%s" (file-name-nondirectory (directory-file-name (file-name-directory file)))
                                (file-name-base file)))
                'load (round (* 1000 (- (float-time) t0))) 'failed
                (if (and inner (not (equal (file-name-base inner) (file-name-base file))))
                    (format "%s (in %s)" (error-message-string e) (file-name-nondirectory inner))
                  (error-message-string e))))))))

(defun drgnx-modules-report () drgnx-modules--report)

(defvar use-package-ensure-function)
(declare-function package-desc-name "package")

(defvar drgnx-loading-external nil
  "Non-nil while drgnx loads the files of an external module (modules.eld :external).
The contract an external module honours (docs/guide/modules.md): code that changes what drgnx's key
profiles own -- global keymap sets, fixes for the CUA keys, popper setup -- is skipped under it:
`(unless (bound-and-true-p drgnx-loading-external) ...)'.  The binding is dynamic, so it is nil again
when the load ends, whether the feature loaded or failed.")

(defun drgnx-modules--require-external (feature)
  "Require FEATURE without letting it install or refresh anything: `use-package :ensure', :vc and
direct installs are recorded instead.  Returns (ERROR-or-nil . WANTED-PACKAGES)."
  (let* ((wanted nil)
         (want (lambda (p)
                 (let ((name (cond ((and (fboundp 'package-desc-p) (package-desc-p p)) (package-desc-name p))
                                   ((consp p) (car p))
                                   ((stringp p) (intern (file-name-base p)))
                                   (t p))))
                   (unless (and (symbolp name) (locate-library (symbol-name name)))   ; already there: nothing to do
                     (push name wanted)
                     (when (symbolp name) (drgnx-pkg-ensure name))))   ; for the next drgnx sync
                 nil)))
    (cl-letf (((symbol-function 'package-refresh-contents) #'ignore)
              ((symbol-function 'package-install) (lambda (p &rest _) (funcall want p)))
              ((symbol-function 'package-vc-install) (lambda (p &rest _) (funcall want p)))
              ((symbol-function 'package-vc-install-from-checkout) (lambda (_dir name &rest _) (funcall want name))))
      (let* ((drgnx-loading-external t)
             (use-package-ensure-function (lambda (name &rest _) (funcall want name)))
             (err (condition-case e (progn (require feature) nil) (error (error-message-string e)))))
        (cons err (delete-dups (nreverse wanted)))))))

(defun drgnx-modules-load-external ()
  "Load the external modules listed in modules.eld (:external): each feature is reported as
module external/NAME/FEATURE; a missing directory, a failing feature or a package it would install
never stops Emacs — nothing is installed (the module waits for the package, as any module does)."
  (seq-do-indexed
   (lambda (ext i)
     (let* ((ok (drgnx-modules--external-ok-p ext))
            (name (or (and (consp ext) (keywordp (car ext)) (plist-get ext :name)) (format "entry-%d" (1+ i))))
            (id (intern (format "external/%s" name)))
            (path (and ok (expand-file-name (plist-get ext :path)))))
       (cond
        ((not ok) (drgnx-modules--record id 'idle 0 'failed (format "modules.eld entry %S needs :name, :path and :features" ext)))
        ((drgnx-module-disabled-p id) (drgnx-modules--record id 'idle 0 'disabled))
        ((not (file-directory-p path)) (drgnx-modules--record id 'idle 0 'failed (format "no such directory: %s" path)))
        (t
         (require 'drgnx-compat-gryphn)          ; gryphn's command and context definitions
         (add-to-list 'load-path path t)
         (dolist (f (plist-get ext :features))
           (pcase-let* ((t0 (float-time)) (`(,err . ,wanted) (drgnx-modules--require-external f)))
             (drgnx-modules--record (intern (format "external/%s/%s" name f)) 'idle
                                    (round (* 1000 (- (float-time) t0)))
                                    (cond (wanted 'missing-packages) (err 'failed) (t 'ok)) err wanted)))))))
   (plist-get (drgnx-modules-read-state) :external)))

(defun drgnx-modules--idle-step (step)
  "One step of the idle stage (`drgnx-modules-start'): call STEP."
  (funcall step))

(defun drgnx-modules-start (dir)
  "Load the modules in DIR, run the startup stage now and the others when their moment comes."
  (drgnx-modules-load-directory dir)
  (drgnx-modules-run 'startup)
  ;; The idle stage: one idle timer per module, staggered, so input between them is handled first.  The
  ;; external modules load before them (the end of the stage re-applies keys), the last runs the stage hook.
  (let* ((ran nil)
         (steps (append (list #'drgnx-modules-load-external)
                        (mapcar (lambda (m) (lambda () (when (drgnx-modules--run-one (car m) (cdr m) 'idle) (setq ran t))))
                                (drgnx-modules--in-order 'idle))
                        (list (lambda ()
                                (when ran (run-hook-with-args 'drgnx-modules-after-stage-functions 'idle)))))))
    ;; Emacs-lifetime startup work with no module to own it: `:core'.
    (seq-do-indexed (lambda (step i)
                      (drgnx-timer-start (cons 'modules-idle-step i) (+ 1 (* 0.05 i)) #'drgnx-modules--idle-step
                                         :idle t :args (list step) :owner :core))
                    steps))
  (pcase-dolist (`(,hook . ,stage) '((drgnx-first-gui-frame-hook . first-frame) (drgnx-first-file-hook . first-file)
                                     (drgnx-first-input-hook . first-input)))
    (add-hook hook (lambda () (drgnx-modules-run stage)))))

;;;; Preferences: Modules

(defvar drgnx-modules-list-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m tabulated-list-mode-map) m)
  "Keys come from the key profiles (command `modules-toggle').")

(define-derived-mode drgnx-modules-list-mode tabulated-list-mode "Modules"
  "Every module, its status, and whether it runs at the next start."
  (setq tabulated-list-format
        `[("Module" 26 t) ("Status" 18 t)
          ("Stage" 12 ,(drgnx-modules--sort-by 2 (lambda (s) (or (seq-position drgnx-modules-stages (intern s)) 99))))
          ("ms" 5 ,(drgnx-modules--sort-by 3 (lambda (s) (if (string-empty-p s) -1 (string-to-number s)))))
          ("Next start" 32 t) ("About" 0 nil)]
        tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun drgnx-modules--sort-by (column key)
  "A sort predicate for the list: COLUMN's text through KEY (a number), compared."
  (lambda (a b) (< (funcall key (aref (cadr a) column)) (funcall key (aref (cadr b) column)))))

(defun drgnx-modules--external-about (name)
  "Where external module NAME (external/X or external/X/FEATURE) comes from: its path and features."
  (pcase-let* ((`(,_ ,x ,feature) (split-string (symbol-name name) "/"))
               (ext (seq-find (lambda (e) (and (drgnx-modules--external-ok-p e) (equal (format "%s" (plist-get e :name)) x)))
                              (plist-get (drgnx-modules-read-state) :external))))
    (cond ((not ext) "")
          (feature (format "%s from %s" feature (plist-get ext :path)))
          (t (format "%s: %s" (plist-get ext :path) (mapconcat #'symbol-name (plist-get ext :features) " "))))))

(defun drgnx-modules--next-state ()
  "The modules.eld the next start will read: the file as it is now, else (it is absent or has a mistake) what this
Emacs applied."
  (let ((r (drgnx-config-read 'modules)))
    (if (memq (plist-get r :status) '(ok migrated newer absent)) (plist-get r :data) (drgnx-modules-read-state))))

(defun drgnx-modules--entries ()
  (let ((next (drgnx-modules--next-state)))
    (mapcar (lambda (m)
              (let* ((name (car m)) (r (alist-get name drgnx-modules--report)) (st (plist-get r :status)))
                (list name (vector (symbol-name name)
                                   (pcase st ('missing-packages (drgnx-ui-status 'warn (format "needs %s" (mapconcat #'symbol-name (plist-get r :missing) " "))))
                                          ('missing-requires (drgnx-ui-status 'warn (format "needs %s" (mapconcat #'symbol-name (plist-get r :missing) " "))))
                                          ('failed (drgnx-ui-status 'fail (format "failed: %s" (plist-get r :error))))
                                          ('ok (drgnx-ui-status 'ok "ok"))
                                          ('nil "not run yet") (_ (drgnx-ui-status 'info (symbol-name st))))
                                   (symbol-name (or (plist-get (cdr m) :stage) (plist-get r :stage) 'load))
                                   (format "%s" (or (plist-get r :ms) ""))
                                   (cond ((not (or (drgnx-modules--disabled-in next name)   ; or it needs one that is: it waits for it
                                                   (seq-some (lambda (q) (drgnx-modules--disabled-in next q))
                                                             (plist-get (cdr m) :requires))))
                                          "on")
                                         ((eq st 'ok) "off at next start")   ; still running: it stays until restart
                                         ((and (drgnx-module-default-off-p name)
                                               (not (memq name (plist-get next :disabled))))
                                          "off (chosen by the key profile)")
                                         (t "off"))
                                   (concat (or (plist-get (cdr m) :doc)
                                               (if (string-prefix-p "external/" (symbol-name name)) (drgnx-modules--external-about name) ""))
                                           (if (eq st 'off) "; code stays loaded until restart" ""))))))
            ;; The table, and what only the report knows: external modules, files that failed to load.
            (append drgnx-modules--table
                    (seq-remove (lambda (r) (assq (car r) drgnx-modules--table)) (reverse drgnx-modules--report))))))

(defun drgnx-modules-list ()
  "Show every module, its status and whether it runs at the next start (\\[drgnx-modules-list-toggle] turns it on or off)."
  (interactive)
  (let ((b (get-buffer-create "*drgnx modules*")))
    (with-current-buffer b
      (drgnx-modules-list-mode)
      (setq tabulated-list-entries #'drgnx-modules--entries)
      (tabulated-list-print t))
    (when (called-interactively-p 'any) (pop-to-buffer b))
    b))

(defun drgnx-modules--refresh-list ()
  (when-let* ((b (get-buffer "*drgnx modules*"))) (with-current-buffer b (tabulated-list-print t))))

(defun drgnx-modules-toggle (module)
  "Turn MODULE off at the next start, or back on (a module that is off until chosen: in or out of :enabled).
Nothing runs or stops now (onboarding uses this)."
  (drgnx-modules-update-state            ; the direction comes from the file as it is now, not from this Emacs's copy
   (lambda (state) (drgnx-modules--choose state module (and (drgnx-modules--disabled-in state module) t))))
  (drgnx-modules--refresh-list))

(defun drgnx-modules--dependents (module)
  "The running modules that need MODULE, directly or not, the deepest first (the order to turn them off)."
  (let ((out nil))
    (dolist (m drgnx-modules--table)
      (when (and (memq module (plist-get (cdr m) :requires)) (drgnx-modules--ok-p (car m)))
        (dolist (d (append (drgnx-modules--dependents (car m)) (list (car m))))
          (unless (memq d out) (setq out (append out (list d)))))))
    out))

(cl-defun drgnx-modules-turn-off (module &key dependents)
  "Turn MODULE off now and remember it in modules.eld.  Never prompts.
Without DEPENDENTS, when running modules need MODULE nothing is done and they are returned.  With it,
they are torn down first (deepest first), then MODULE, which is written to modules.eld; the dependents
are not (they wait for MODULE at the next start).  A module that stays running until restart (defined
`:teardown \\='restart', or needed by a running one that is) is only written, whatever DEPENDENTS says: nothing
is torn down, nothing is asked, and it stops at the next start.  Returns nil, else the running dependents."
  (let* ((deps (drgnx-modules--dependents module))
         (now (not (or (drgnx-modules--restart-p module) (seq-some #'drgnx-modules--restart-p deps)))))
    (if (and now deps (not dependents)) deps
      (dolist (m (if now (append deps (list module)) (list module)))
        (let ((r (alist-get m drgnx-modules--report)))
          (cond ((not (drgnx-modules--ok-p m))
                 (when r (drgnx-modules--record m (plist-get r :stage) 0 'disabled)))   ; waiting or failed: it will not run
                (now (drgnx-module-teardown m)))))
      (drgnx-modules-set-enabled module nil)
      (when now (run-hooks 'drgnx-modules-after-teardown-functions))
      (drgnx-modules--refresh-list)
      nil)))

(defun drgnx-modules-turn-on (module)
  "Turn MODULE on: remember it in modules.eld and, when its stage has passed, run its setup now.
A module whose packages are missing or whose requirements are not running waits, reported as such; one whose
stage has not come runs when it does.  A module still running (turned off only for the next start) just stays.
Keys and menus follow the registry afterwards, whatever the stage (`drgnx-modules-after-teardown-functions')."
  (drgnx-modules-set-enabled module t)
  (let ((spec (assq module drgnx-modules--table)) (r (alist-get module drgnx-modules--report)))
    (when (and spec r (not (drgnx-modules--ok-p module)))
      (when (drgnx-modules--run-one module (cdr spec) (plist-get (cdr spec) :stage))
        (run-hooks 'drgnx-modules-after-teardown-functions))))
  (drgnx-modules--refresh-list)
  nil)

(defun drgnx-modules--say-problems (modules)
  "Say what went wrong while MODULES were turned off or on (their notices keep it too)."
  (dolist (m modules)
    (when-let* ((p (plist-get (alist-get m drgnx-modules--report) :problems)))
      (message "drgnx: %s: %s" m (mapconcat #'identity p "; ")))))

(defun drgnx-modules-list-toggle ()
  "Turn the module on this row off now, or back on (one that cannot be turned off while Emacs runs: at the next start).
When running modules need it, asks once whether to turn them off too."
  (interactive)
  (when-let* ((m (tabulated-list-get-id)))
    (if (or (drgnx-module-disabled-p m) (eq (plist-get (alist-get m drgnx-modules--report) :status) 'off))
        (progn (drgnx-modules-turn-on m) (drgnx-modules--say-problems (list m)))
      (let* ((deps (drgnx-modules-turn-off m)) (all (cons m deps)))
        (when (and deps (y-or-n-p (format "Also turn off %s? " (mapconcat #'symbol-name deps ", "))))
          (drgnx-modules-turn-off m :dependents t))
        (drgnx-modules--say-problems all)))))

(defalias 'drgnx-modules-show-report #'drgnx-modules-list)

(provide 'drgnx-modules)
;;; drgnx-modules.el ends here
