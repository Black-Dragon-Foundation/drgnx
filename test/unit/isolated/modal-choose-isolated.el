;;; modal-choose-isolated.el --- batch tests (own Emacs, test/unit/modal-choose-test.el): choosing a Vim stack with evil -*- lexical-binding: t -*-
;; Needs the real evil: DRGNX_MODAL_ELPA (docs/develop/harness.md, "Modal tests"); without it these tests skip (but
;; the one without evil).  Each runs in a fresh Emacs (one test per process: evil, once loaded, cannot be unloaded,
;; and the startup modules leave their hooks behind), in a temp configuration with the shipped modules' startup stage
;; run.  The sync and the question are stubbed.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-modal-choose nil t)
(load (expand-file-name "test/fixtures/modal-elpa" drgnx-dir) nil t)

(declare-function drgnx-evil-stop "drgnx-evil")
(declare-function drgnx-modal-prepare "drgnx-modal-choose")
(declare-function drgnx-modal-apply-pending "drgnx-modal-choose")

(defconst drgnx-modal-choose-test--vim '((vim app editing window)))

(load (expand-file-name "test/fixtures/areas-fixture" drgnx-dir) nil t)

;; keys.eld and modules.eld are settings now: "keys.eld" is the keys settings, "modules.eld" the module settings.
(defun drgnx-modal-choose-test--write (name text)
  (drgnx-test-areas-put-old (intern (string-remove-suffix ".eld" name)) text))

(defun drgnx-modal-choose-test--read (name)
  (drgnx-test-areas-old-plist (intern (string-remove-suffix ".eld" name))))

(defmacro drgnx-modal-choose-isolated--with (keys modules on-path &rest body)
  "BODY in a temp configuration with KEYS as keys.eld and MODULES as modules.eld (strings, nil: none), the core
commands and the startup modules run, the keys applied.  ON-PATH: t, evil's packages on `load-path' from the start;
nil, BODY puts them there (`load-path' is restored after); `none', a test without evil (skipped where evil loads).
Skipped without evil otherwise."
  (declare (indent 3))
  `(let ((dirs (drgnx-modal-test-evil-dirs)))
     (if (eq ,on-path 'none)
         (skip-unless (not (or (featurep 'evil) (locate-library "evil"))))
       (unless dirs (ert-skip "evil not installed: see docs/develop/harness.md \"Modal tests\"")))
     (let* ((dir (file-name-as-directory (make-temp-file "drgnx-modal-choose" t)))
            (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir "config") (concat "DRGNX_DATA_DIR=" dir "data")
                                               (concat "XDG_STATE_HOME=" dir "state") (concat "HOME=" dir "home"))
                                         process-environment))
            (load-path (if (eq ,on-path t) (append dirs load-path) load-path))
            (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
            (drgnx-modules--table nil) (drgnx-modules--report nil)
            (drgnx-modules--state nil) (drgnx-modal-engines nil) (drgnx-modal-running nil)
            (drgnx-keys--applied nil) (drgnx-keys-profiles nil) (drgnx-keys-problems nil) (drgnx-keys-last nil)
            (drgnx-keys--session-layers nil)
            (emulation-mode-map-alists emulation-mode-map-alists)
            (mode-line-saved (default-value 'mode-line-format)))
       (make-directory (concat dir "config") t)
       (make-directory (concat dir "home") t)
       (when ,keys (drgnx-modal-choose-test--write "keys.eld" ,keys))          ; as settings.el's entries
       (when ,modules (drgnx-modal-choose-test--write "modules.eld" ,modules))
       (unwind-protect
           (progn
             (drgnx--core-commands)
             (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
             (drgnx-modules-run 'startup)
             (drgnx-keys-apply)
             ,@body)
         (when (fboundp 'drgnx-evil-stop) (drgnx-evil-stop))
         (drgnx-keys--restore)
         (setq-default mode-line-format mode-line-saved)
         (delete-directory dir t)))))

(defmacro drgnx-modal-choose-test--no-prompts (&rest body)
  "BODY with every prompt but `y-or-n-p' failing the test (`noninteractive' is nil around the interactive path)."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'read-from-minibuffer) (lambda (&rest _) (ert-fail "read-from-minibuffer")))
             ((symbol-function 'read-key) (lambda (&rest _) (ert-fail "read-key")))
             ((symbol-function 'yes-or-no-p) (lambda (&rest _) (ert-fail "yes-or-no-p")))
             ((symbol-function 'completing-read) (lambda (&rest _) (ert-fail "completing-read"))))
     ,@body))

(defconst drgnx-modal-choose-test--vscode-keys "(:layers ((vscode app editing window)))\n")

(ert-deftest drgnx-modal-choose/interactive-asks-once-and-switches-after-the-engine-loads ()
  ;; evil is not installed: one question saying what it installs, then drgnx sync (with editor/evil on), then the
  ;; engine runs, and only then keys.eld gets the Vim stack.
  (drgnx-modal-choose-isolated--with drgnx-modal-choose-test--vscode-keys nil nil
    (should-not (locate-library "evil"))
    (should-not (featurep 'evil))
    (let ((order nil) (noninteractive nil))
      (drgnx-modal-choose-test--no-prompts
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (q) (push (list 'asked q) order) t))
                  ((symbol-function 'drgnx-onboard--sync-job)
                   (lambda ()
                     (push (list 'sync (plist-get (drgnx-modal-choose-test--read "modules.eld") :enabled)) order)
                     (setq load-path (append dirs load-path))   ; what drgnx sync installed
                     'ok))
                  ((symbol-function 'drgnx-keys--save-key)
                   (let ((orig (symbol-function 'drgnx-keys--save-key)))
                     (lambda (key data &rest rest)
                       (push (list 'save key data drgnx-modal-running) order)
                       (apply orig key data rest)))))
          (drgnx-keys-choose-profile "Vim" t)))
      (setq order (reverse order))
      (should (equal (mapcar #'car order) '(asked sync save)))
      (should (string-match-p "evil" (nth 1 (nth 0 order))))
      (should (equal (nth 1 (nth 1 order)) '(editor/evil)))
      (should (equal (cdr (nth 2 order)) (list :layers drgnx-modal-choose-test--vim 'evil)))
      (should (eq drgnx-modal-running 'evil))
      (should (equal (plist-get (drgnx-modal-choose-test--read "keys.eld") :layers) drgnx-modal-choose-test--vim))
      (should (equal (plist-get drgnx-keys-last :layers) drgnx-modal-choose-test--vim)))))

(ert-deftest drgnx-modal-choose/installed-engine-switches-without-asking ()
  ;; evil installed, editor/evil off: no question, the module turned on and run now, the stack switched.
  (drgnx-modal-choose-isolated--with drgnx-modal-choose-test--vscode-keys nil t
    (should (eq (plist-get (alist-get 'editor/evil drgnx-modules--report) :status) 'disabled))
    ;; a session that runs no modules (drgnx safe): the keys never become Vim's, the module stays off
    (let ((drgnx-modules--table nil) (noninteractive nil))
      (drgnx-modal-choose-test--no-prompts
        (should (equal (drgnx-modal-prepare drgnx-modal-choose-test--vim t)
                       '(fail "modules are off in this session (drgnx safe)" nil)))))
    (should-not (drgnx-modal-choose-test--read "modules.eld"))
    (let ((results nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (ert-fail "asked")))
                ((symbol-function 'drgnx-onboard--sync-job) (lambda () (ert-fail "drgnx sync ran"))))
        (advice-add 'drgnx-modal-prepare :filter-return (lambda (r) (push r results) r) '((name . drgnx-modal-choose-test)))
        (unwind-protect (drgnx-keys-choose-profile "Vim" t)
          (advice-remove 'drgnx-modal-prepare 'drgnx-modal-choose-test)))
      (should (equal results '(started))))
    (should (eq drgnx-modal-running 'evil))
    (should (memq 'editor/evil (plist-get (drgnx-modal-choose-test--read "modules.eld") :enabled)))
    (should (equal (plist-get (drgnx-modal-choose-test--read "keys.eld") :layers) drgnx-modal-choose-test--vim))
    ;; chosen again: the engine runs, so it is ready at once
    (should (eq (drgnx-modal-prepare drgnx-modal-choose-test--vim t) 'ready))))

(ert-deftest drgnx-modal-choose/pending-applies-at-the-next-start ()
  ;; keys.eld has a pending Vim stack, editor/evil is on and evil is now installed: the start switches, never asking.
  (drgnx-modal-choose-isolated--with
      ";; my keys\n(:layers ((vscode app editing window)) :pending-layers ((vim app editing window)))\n"
      "(:version 1 :enabled (editor/evil))\n" t
    (should (eq (plist-get (alist-get 'editor/evil drgnx-modules--report) :status) 'ok))
    (should-not drgnx-modal-running)
    (let ((inhibit-interaction t)) (drgnx-modal-apply-pending))
    (should (eq drgnx-modal-running 'evil))
    (should (equal (plist-get drgnx-keys-last :layers) drgnx-modal-choose-test--vim))
    (let ((user (drgnx-modal-choose-test--read "keys.eld")))
      (should (equal (plist-get user :layers) drgnx-modal-choose-test--vim))
      (should-not (plist-member user :pending-layers)))
    ;; once done, a second start does nothing
    (let ((inhibit-interaction t)) (should-not (drgnx-modal-apply-pending)))))

;;;; Without evil

(ert-deftest drgnx-modal-choose/a-vim-stack-without-evil-stays-usable ()
  ;; keys.eld names the Vim stack, editor/evil is on, evil is not installed: the start goes on, the module waits,
  ;; the palette and the Leader Menu keep their keys — Linux's (on a Mac the palette is Cmd+Shift+P: keys/vim.eld).
  (let* ((doctor 0) (count (lambda (&rest _) (cl-incf doctor))))
    ;; advice, not a stub: loading the module file defines the function again (the advice stays)
    (advice-add 'drgnx-evil-doctor :before count)
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux)))
          (drgnx-modal-choose-isolated--with "(:layers ((vim app editing window)))\n" "(:version 1 :enabled (editor/evil))\n" 'none
            (let ((inhibit-interaction t)) (drgnx-modal-apply-pending))
            (should (eq (plist-get (alist-get 'editor/evil drgnx-modules--report) :status) 'missing-packages))
            (should (= doctor 0))
            (should-not (seq-filter (lambda (m) (eq (plist-get (cdr m) :status) 'failed)) drgnx-modules--report))
            (should-not (seq-find (lambda (p) (string-match-p "could not be applied" p)) (plist-get drgnx-keys-last :problems)))
            (should (equal (plist-get drgnx-keys-last :layers) drgnx-modal-choose-test--vim))
            (should-not drgnx-modal-running)
            (should (eq (keymap-lookup global-map "C-S-p") #'drgnx-palette))
            (should (eq (keymap-lookup global-map "<f1>") #'drgnx-palette))
            (should (eq (keymap-lookup global-map "M-SPC") #'drgnx-modal-leader-menu))))
      (advice-remove 'drgnx-evil-doctor count))))

(provide 'modal-choose-isolated)
;;; modal-choose-isolated.el ends here
