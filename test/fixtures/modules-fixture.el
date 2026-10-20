;;; modules-fixture.el --- drgnx-test-with-modules: set modules up for a test, tear them down after -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `(drgnx-test-with-modules MODULES [:stages S] [:packages hidden] [:strict t] BODY…)' runs BODY with the
;; named modules (and the modules they require) set up in a fresh module table, report and state (a temporary
;; DRGNX_CONFIG_DIR), or every shipped module of the stages in :stages.  Afterwards it turns them off through
;; the product path (`drgnx-module-teardown', last set up first, then `drgnx-modules-after-teardown-functions'),
;; so every use also tests the teardown, and puts back a snapshot of every registry variable of
;; `drgnx-modules-fingerprint-registries' taken after the module files and the libraries their setups load are
;; loaded (a library's own top-level registrations are the library's and stay).  The snapshot is copied values restored with `set' (a
;; keymap in place), never `let': binding a variable of a library that is first loaded inside BODY leaves it
;; void once the library is loaded (it is bound after, see `drgnx-test-modules/no-let-binding-trap').
;; `:strict t' fails the test, with the fingerprint diff, when the state after the teardown differs from the
;; state before the first setup, taken after the libraries the setups load are loaded (features and Emacs's own
;; lazy timers excepted).  `:packages hidden' hides third-party features during the
;; setups, for tests of a result shape (the key snapshot) that must not depend on what is installed.
;; See docs/develop/harness.md ("Tests that set modules up").

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-modules-fingerprint)

(defvar drgnx-test-modules--files nil
  "Alist module NAME → the shipped file that defines it, scanned once from modules/.")

(defun drgnx-test-modules--scan ()
  "Set `drgnx-test-modules--files' from a text scan of every shipped module file (nothing is loaded)."
  (let (out)
    (dolist (file (directory-files-recursively (expand-file-name "modules" drgnx-dir) "\\`drgnx-.*\\.el\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (while (re-search-forward "^(drgnx-module-define '\\([^ \n()]+\\)" nil t)
          (push (cons (intern (match-string 1)) file) out))))
    (setq drgnx-test-modules--files (nreverse out))))

(defun drgnx-test-modules--file (name)
  "The shipped file that defines module NAME."
  (or (alist-get name (or drgnx-test-modules--files (drgnx-test-modules--scan)))
      (error "No shipped module file defines %s" name)))

(defun drgnx-test-modules--load (entries)
  "Load the files of ENTRIES and, repeatedly, of the modules they require.
An entry is a module name (its shipped file) or a string, a file to load (a fake module of a test).
Returns the names of the modules ENTRIES stand for."
  (let ((todo (copy-sequence entries)) (loaded nil) (names nil))
    (while todo
      (let ((entry (pop todo)))
        (if (stringp entry)
            (let ((before drgnx-modules--table))
              (load (file-name-sans-extension entry) nil t)
              (dolist (m drgnx-modules--table)
                (unless (assq (car m) before)
                  (push (car m) names)
                  (dolist (r (plist-get (cdr m) :requires)) (push r todo)))))
          (push entry names)
          (let ((file (and (not (assq entry drgnx-modules--table)) (drgnx-test-modules--file entry))))
            (unless (or (null file) (member file loaded))
              (push file loaded)
              (load (file-name-sans-extension file) nil t)
              (dolist (m drgnx-modules--table)
                (when (equal (alist-get (car m) drgnx-test-modules--files) file)
                  (dolist (r (plist-get (cdr m) :requires)) (push r todo)))))))))
    (nreverse names)))

;;;; The registry snapshot

(defun drgnx-test-modules--copy (value)
  "A copy of VALUE, deep enough for the lists a registry holds."
  (cond ((hash-table-p value)
         (let ((copy (copy-hash-table value)))
           (maphash (lambda (k v) (puthash k (copy-tree v) copy)) value)
           copy))
        ((keymapp value) (copy-keymap value))
        (t (copy-tree value))))

(defun drgnx-test-modules--snapshot ()
  "((VAR OBJECT COPY)…) for every bound variable of `drgnx-modules-fingerprint-registries'."
  (let (snap)
    (dolist (spec drgnx-modules-fingerprint-registries)
      (let ((var (if (consp spec) (car spec) spec)))
        (when (and (boundp var) (not (assq var snap)))
          (push (list var (symbol-value var) (drgnx-test-modules--copy (symbol-value var))) snap))))
    snap))

(defun drgnx-test-modules--restore (snap)
  "Put SNAP back: a table or keymap in place (it is referenced by identity), anything else with `set'."
  (pcase-dolist (`(,var ,object ,copy) snap)
    (cond ((and (hash-table-p copy) (hash-table-p object))
           (clrhash object)
           (maphash (lambda (k v) (puthash k v object)) copy)
           (set var object))
          ((and (keymapp copy) (keymapp object))
           (setcdr object (cdr copy))
           (set var object))
          ;; unchanged: the object itself, so a fingerprint that keys entries by identity sees nothing new
          (t (set var (if (equal object copy) object copy))))))

;;;; Hiding third-party features

(defvar drgnx-test-modules--library-dir nil "Emacs's own lisp directory (found before `locate-library' is hidden).")

(defun drgnx-test-modules--library-dir ()
  (or drgnx-test-modules--library-dir
      (setq drgnx-test-modules--library-dir
            (expand-file-name
             (file-name-directory (or (locate-library "subr") (error "Cannot find Emacs's lisp directory")))))))

(defun drgnx-test-modules--third-party-p (file)
  "Non-nil when FILE is neither part of Emacs nor of drgnx."
  (and file
       (not (string-prefix-p (drgnx-test-modules--library-dir) (expand-file-name file)))
       (not (string-prefix-p (expand-file-name drgnx-dir) (expand-file-name file)))))

(defun drgnx-test-modules--hidden-features ()
  (seq-filter (lambda (f) (drgnx-test-modules--third-party-p (ignore-errors (feature-file f)))) features))

(defmacro drgnx-test-modules--hiding (hide &rest body)
  "BODY, with the third-party features out of `features' and `locate-library' blind to them when HIDE.
The features come back after (unless BODY loaded them again)."
  (declare (indent 1))
  `(if (not ,hide)
       (progn ,@body)
     (let* ((hidden (drgnx-test-modules--hidden-features))
            (orig (symbol-function 'locate-library)))
       (setq features (seq-remove (lambda (f) (memq f hidden)) features))
       (unwind-protect
           (cl-letf (((symbol-function 'locate-library)
                      (lambda (&rest args)
                        (let ((found (apply orig args)))
                          (and found (not (drgnx-test-modules--third-party-p found)) found)))))
             ,@body)
         (dolist (f (reverse hidden)) (unless (memq f features) (setq features (nconc features (list f)))))))))

;;;; What the product's after-teardown leaves behind

(defconst drgnx-test-modules--ui-variables
  '(drgnx-keys--applied drgnx-keys-last drgnx-keys--generation drgnx-keys--saved-modifiers drgnx-keys-problems
                        drgnx-surfaces--which-key-entries which-key-replacement-alist)
  "Variables `drgnx-keys-apply' and `drgnx-surfaces-refresh' (the after-teardown function) write.")

(defun drgnx-test-modules--ui-snapshot ()
  "The key and surface state that `drgnx-modules-after-teardown-functions' change."
  (list :variables (delq nil (mapcar (lambda (v) (and (boundp v) (cons v (symbol-value v))))
                                     ;; with the record of the Mac modifiers the apply saved, their values: on macOS
                                     ;; the apply sets them for VS Code's keys (`drgnx-keys--set-mac-modifiers')
                                     (append drgnx-test-modules--ui-variables
                                             (and (boundp 'drgnx-keys--mac-modifiers)
                                                  (mapcar #'car (symbol-value 'drgnx-keys--mac-modifiers))))))
        ;; `drgnx-modal-order-alists' keeps the everywhere alist in its place even while it holds no key;
        ;; `drgnx-keys--restore' (and an apply with no `:everywhere' key) takes it out
        :everywhere-at (seq-position emulation-mode-map-alists 'drgnx-keys--everywhere-alist)
        :menu-items (and (boundp 'drgnx-surfaces--menu-items) (hash-table-count drgnx-surfaces--menu-items))
        :menu-hook (default-value 'menu-bar-update-hook)
        :context-functions (default-value 'context-menu-functions)
        :context-mode (bound-and-true-p context-menu-mode)))

(defun drgnx-test-modules--ui-restore (snap)
  "Put SNAP back.  The bindings are undone with `drgnx-keys--restore' (only those still ours) when none was
applied before; when some were, the after-teardown function's re-application stays, as it would in a session.
The everywhere alist goes back in its place in `emulation-mode-map-alists' when it was there."
  (let ((variables (plist-get snap :variables)))
    (when (and (fboundp 'drgnx-keys--restore) (null (alist-get 'drgnx-keys--applied variables)))
      (drgnx-keys--restore))
    ;; the menus the registry built: with an empty registry all of them are stale, so the build retracts them
    (when (and (eql (plist-get snap :menu-items) 0) (fboundp 'drgnx-surfaces-build-menus))
      (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
        (drgnx-surfaces-build-menus)))
    (pcase-dolist (`(,var . ,value) variables) (set var value))
    (let ((at (plist-get snap :everywhere-at)))
      (when (and at (not (memq 'drgnx-keys--everywhere-alist emulation-mode-map-alists)))
        (setq emulation-mode-map-alists (append (seq-take emulation-mode-map-alists at) '(drgnx-keys--everywhere-alist)
                                                (seq-drop emulation-mode-map-alists at)))))
    (set-default 'menu-bar-update-hook (plist-get snap :menu-hook))
    (set-default 'context-menu-functions (plist-get snap :context-functions))
    (when (and (bound-and-true-p context-menu-mode) (not (plist-get snap :context-mode)))
      (context-menu-mode -1))))

;;;; What `:strict' does not count: what the libraries a setup loads, and Emacs itself, leave behind

(defun drgnx-test-modules--requires (file)
  "The features FILE (or the .el beside a .elc) `require's with a quoted name, read with the Lisp reader."
  (let ((src (concat (file-name-sans-extension file) ".el")) out)
    (when (file-readable-p src)
      (with-temp-buffer
        (insert-file-contents src)
        (cl-labels ((walk (x)
                      (when (consp x)
                        (pcase x (`(require (quote ,(and f (pred symbolp))) . ,_) (push f out)))
                        (while (consp x) (walk (car x)) (setq x (cdr x))))))
          (condition-case nil (while t (walk (read (current-buffer)))) (end-of-file nil)))))
    (delete-dups (nreverse out))))

(defun drgnx-test-modules--preload (names)
  "Load what the setups of NAMES load first, before the helper takes its snapshots: their `:packages' and the
features their files `require'.  A library's top level belongs to the library, which stays loaded (spec row 26).
Loaded here, it is in the snapshot whichever test loaded it first.  Nothing a setup does comes before the
snapshot, so no leak is hidden.  A library that cannot be found or does not load is left to the setup."
  (dolist (name names)
    (let* ((spec (alist-get name drgnx-modules--table)) (file (plist-get spec :file)))
      (dolist (f (append (plist-get spec :packages) (and file (drgnx-test-modules--requires file))))
        (unless (or (featurep f) (not (locate-library (symbol-name f))))
          (ignore-errors (require f)))))))

(defun drgnx-test-modules--without-emacs-timers (fp)
  "FP without the timers the recorder leaves alone too: those whose function drgnx does not define
\(`drgnx-modules--undoable-timer-p'), such as Emacs's own lazy singletons (undo's boundary timer…) and an ELPA
library's; the recorder lists them in `drgnx-modules--left'.  Layer timers stay: their owner ends them."
  (plist-put (copy-sequence fp) :timers
             (seq-filter (lambda (it) (drgnx-modules--undoable-timer-p (timer--function (cdr it))))
                         (plist-get fp :timers))))

;;;; Running

(defconst drgnx-test-modules--emacs-buffers
  "\\`buffer [+-] \\*\\(?:code-conversion-work\\|code-converting-work\\|tab-line-hscroll\\|jka-compr-wr-temp\\|string-pixel-width\\)\\*\\'"
  "The hidden work buffers Emacs makes for itself, the first time some code needs one, and keeps (as in
test/leaks-allowed.eld): not a module's.")

(defun drgnx-test-modules--diff-lines (before after)
  "Readable lines for what differs between the fingerprints BEFORE and AFTER, features and Emacs's own work
buffers excepted."
  (mapcar (lambda (d) (if (plist-get d :source) (format "%s (%s)" (plist-get d :what) (plist-get d :source))
                        (plist-get d :what)))
          (seq-remove (lambda (d) (or (string-prefix-p "feature " (plist-get d :what))
                                      (string-match-p drgnx-test-modules--emacs-buffers (plist-get d :what))))
                      (drgnx-modules-fingerprint-diff before after))))

(defun drgnx-test-modules--ran ()
  "The modules that are on, in the order their setups ran: by stage, each stage as `drgnx-modules-run' orders it."
  (seq-filter #'drgnx-modules--ok-p
              (mapcar #'car (apply #'append (mapcar #'drgnx-modules--in-order drgnx-modules-stages)))))

(defun drgnx-test-modules--teardown (ui)
  "Tear the modules that are on down, the last first, then run the after-teardown functions and put UI
(`drgnx-test-modules--ui-snapshot') back.  The problems, (NAME . STRINGS)."
  (let (problems)
    (dolist (name (reverse (drgnx-test-modules--ran)))
      ;; a `restart' module stays on in a session, but its record is exact: a test unwinds it all the same
      (let ((p (if (drgnx-modules--restart-p name) (drgnx-modules--unwind name) (drgnx-module-teardown name))))
        (when p (push (cons name p) problems))))
    (unwind-protect (run-hooks 'drgnx-modules-after-teardown-functions)
      (drgnx-test-modules--ui-restore ui))
    (nreverse problems)))

(defun drgnx-test-modules--closure (names)
  "NAMES and every module they require, from the loaded table."
  (let ((todo (copy-sequence names)) (out nil))
    (while todo
      (let ((n (pop todo)))
        (unless (memq n out)
          (push n out)
          (dolist (r (plist-get (alist-get n drgnx-modules--table) :requires)) (push r todo)))))
    (nreverse out)))

(defun drgnx-test-modules--run (modules opts body)
  "Run the function BODY with MODULES set up (see `drgnx-test-with-modules'); OPTS is its plist."
  (let* ((stages (plist-get opts :stages))
         (cfg (make-temp-file "drgnx-mods" t))
         (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" cfg)
                                            (concat "XDG_STATE_HOME=" cfg "/state")
                                            (concat "DRGNX_DATA_DIR=" cfg "/data"))
                                      process-environment))
         (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
         (drgnx-modules--stacks nil) (drgnx-modules--runs nil) (drgnx-modules--features nil)
         (drgnx-module--claims (make-hash-table :test 'equal))
         (drgnx-module--releasers (make-hash-table :test 'equal))
         (snap nil))
    (unwind-protect
        (drgnx-test-modules--hiding (eq (plist-get opts :packages) 'hidden)
          (let* ((named (drgnx-test-modules--load modules))
                 (_ (when stages
                      (drgnx-test-modules--load
                       (mapcar #'car (or drgnx-test-modules--files (drgnx-test-modules--scan))))))
                 (selected (drgnx-test-modules--closure
                            (append named
                                    (and stages
                                         (mapcar #'car (seq-filter (lambda (m) (memq (plist-get (cdr m) :stage) stages))
                                                                   drgnx-modules--table))))))
                 ;; the libraries' own top level (registrations too) is theirs and stays: load them, then copy
                 (_ (drgnx-test-modules--preload selected))
                 (_ (setq snap (drgnx-test-modules--snapshot)))
                 (before (drgnx-modules-fingerprint))
                 (ui (drgnx-test-modules--ui-snapshot))
                 (done nil) (problems nil) (value nil))
            ;; the product's own runner, over the selected modules only
            (setq drgnx-modules--table (seq-filter (lambda (m) (memq (car m) selected)) drgnx-modules--table))
            (unwind-protect
                (progn (dolist (stage drgnx-modules-stages) (drgnx-modules-run stage))
                       (setq value (funcall body) done t))
              (setq problems (drgnx-test-modules--teardown ui))
              ;; the test fails with the body's own error: do not lose what the teardown found
              (when (and problems (not done))
                (message "drgnx-test-with-modules: the teardown also reported %S" problems)))
            (when problems
              (ert-fail (list "modules did not tear down cleanly" problems)))
            (when (plist-get opts :strict)
              (when-let* ((lines (drgnx-test-modules--diff-lines
                                  (drgnx-test-modules--without-emacs-timers before)
                                  (drgnx-test-modules--without-emacs-timers (drgnx-modules-fingerprint)))))
                (ert-fail (cons "modules left state behind after their teardown:" lines))))
            value))
      (when snap (drgnx-test-modules--restore snap))
      (delete-directory cfg t))))

(defmacro drgnx-test-with-modules (modules &rest body)
  "Run BODY with MODULES (a list of module names, evaluated) set up and torn down after.
Keywords before BODY: `:stages' (a list of stages: every shipped module of them as well), `:packages hidden'
\(third-party features are hidden during the setups) and `:strict t' (fail with the fingerprint diff when the
state after differs from before — taken after the setups' libraries are loaded — features and Emacs's own timers
excepted).  The module table, report, state and config directory
are fresh; the registries of `drgnx-modules-fingerprint-registries' are put back after.  Returns BODY's value."
  (declare (indent 1) (debug t))
  (let (opts)
    (while (keywordp (car body))
      (let ((key (pop body)) (val (pop body)))
        (push key opts) (push (if (eq val 'hidden) ''hidden val) opts)))
    `(drgnx-test-modules--run ,modules (list ,@(nreverse opts)) (lambda () ,@body))))

;;;; Own-process tests: what cannot be undone in a process (evil, once loaded, stays)

(defun drgnx-test-modules--run-file (file selector)
  "Run the tests of FILE (relative to the checkout) chosen by SELECTOR in a fresh batch Emacs through the runner.
The child inherits this run's environment: its temp HOME and directories, DRGNX_TEST_LEAKS (it takes the census
too) and DRGNX_TEST_ELN_DIR (it compiles its trampolines into this run's directory).  Memory-capped by systemd-run
when it works.  Returns (EXIT-CODE . OUTPUT)."
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (dir (file-name-as-directory (expand-file-name drgnx-dir)))
         (args (list "--batch" "-Q" "--eval" "(setq load-prefer-newer t)"
                     "-L" (concat dir "harness") "-L" (concat dir "core") "-L" (concat dir "wb")
                     "-l" (concat dir "harness/run-ert.el") "-f" "drgnx-run-ert-batch"
                     (expand-file-name file dir)))
         (process-environment (append (list (concat "DRGNX_TEST_SELECTOR=" (prin1-to-string selector)) "DRGNX_TEST_RESULTS")
                                      process-environment))
         (cap (and (executable-find "systemd-run")
                   (zerop (call-process "systemd-run" nil nil nil "--user" "--scope" "-q" "true"))
                   '("systemd-run" "--user" "--scope" "-q" "-p" "MemoryMax=1G" "-p" "MemorySwapMax=0" "--"))))
    (with-temp-buffer
      (let ((code (apply #'call-process (if cap (car cap) emacs) nil t nil
                         (append (cdr cap) (and cap (list emacs)) args))))
        (cons code (buffer-string))))))

(defun drgnx-test-run-isolated (file selector)
  "Run FILE's tests (SELECTOR) in their own Emacs (`drgnx-test-modules--run-file'); nil when they passed, else the
child's output (its head and tail).  When the child skipped every test it ran (a package it needs is missing), the
calling test is skipped too, so the count says so.  For what a test cannot set up and tear down in this process:
`drgnx-test-with-modules' is for everything else."
  (pcase-let ((`(,code . ,out) (drgnx-test-modules--run-file file selector)))
    (cond ((not (eql code 0)) (format "exit %S\n%s" code (if (> (length out) 8000)
                                                             (concat (substring out 0 3000) "\n[…]\n" (substring out -5000))
                                                           out)))
          ((string-match-p "Ran 0 tests" out) (format "no test ran\n%s" out))
          ((and (string-match "Ran \\([0-9]+\\) tests?, 0 results as expected, 0 unexpected, \\([0-9]+\\) skipped" out)
                (equal (match-string 1 out) (match-string 2 out)))
           (ert-skip (format "all %s tests of %s skipped in their own Emacs (a package missing?)" (match-string 1 out) file)))
          (t nil))))

(provide 'modules-fixture)
;;; modules-fixture.el ends here
