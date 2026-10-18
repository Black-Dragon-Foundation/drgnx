;;; modal-choose-test.el --- batch tests: choosing a modal key stack (onboarding, Keyboard Profile…), evil missing -*- lexical-binding: t -*-
;; A temp configuration (config, data, state, home); evil is not installed here.  The tests that load evil are in
;; test/unit/isolated/modal-choose-isolated.el, each run in its own Emacs by the test of the same name below
;; (docs/develop/harness.md, "Modal tests").
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-modal-choose nil t)
(load (expand-file-name "test/fixtures/modal-elpa" drgnx-dir) nil t)

(defvar drgnx-onboard--restart-needed)
(defvar drgnx-agents-request-functions)
(defvar drgnx-agents-changed-functions)
(defvar drgnx-wb--areas)
(defvar drgnx-layouts-pane-fillers)
(defvar drgnx-layouts-shapes)
(defvar drgnx-persist-state-functions)
(defvar drgnx-persist-after-restore-functions)
(declare-function drgnx-modal-apply-pending "drgnx-modal-choose")

(defconst drgnx-modal-choose-test--vim '((vim app editing window)))
(defconst drgnx-modal-choose-test--vscode '((vscode app editing window)))

(defun drgnx-modal-choose-test--file (name) (expand-file-name name (drgnx-user-dir)))

(defun drgnx-modal-choose-test--write (name text)
  (with-temp-file (drgnx-modal-choose-test--file name) (insert text)))

(defun drgnx-modal-choose-test--text (name)
  (and (file-exists-p (drgnx-modal-choose-test--file name))
       (with-temp-buffer (insert-file-contents (drgnx-modal-choose-test--file name)) (buffer-string))))

(defun drgnx-modal-choose-test--read (name)
  (and (file-exists-p (drgnx-modal-choose-test--file name)) (car (read-from-string (drgnx-modal-choose-test--text name)))))

(defmacro drgnx-modal-choose-test--with (&rest body)
  "BODY in a temp configuration: keys.eld with the VS Code stack and a comment, no modules.eld, the core commands
registered and the keys applied, no engine registered.  Skipped where evil can be loaded."
  (declare (indent 0))
  `(progn
     (skip-unless (not (or (featurep 'evil) (locate-library "evil"))))
     (let* ((dir (file-name-as-directory (make-temp-file "drgnx-modal-choose" t)))
            (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir "config") (concat "DRGNX_DATA_DIR=" dir "data")
                                               (concat "XDG_STATE_HOME=" dir "state") (concat "HOME=" dir "home"))
                                         process-environment))
            (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
            (drgnx-commands-problems nil) (drgnx-modules--table nil) (drgnx-modules--report nil)
            (drgnx-modules--state nil) (drgnx-modal-engines nil) (drgnx-modal-running nil)
            (drgnx-keys--applied nil) (drgnx-keys-profiles nil) (drgnx-keys-problems nil) (drgnx-keys-last nil)
            (drgnx-keys--session-layers nil) (drgnx-onboard--restart-needed nil))
       (make-directory (concat dir "config") t)
       (make-directory (concat dir "home") t)
       (drgnx-modal-choose-test--write "keys.eld" ";; my keys\n(:layers ((vscode app editing window)))\n")
       (unwind-protect
           (progn (drgnx--core-commands)
                  (drgnx-keys-apply)
                  ,@body)
         (drgnx-keys--restore)
         (delete-directory dir t)))))

(ert-deftest drgnx-modal-choose/non-interactive-records-pending ()
  ;; `drgnx onboard --non-interactive --keys Vim' without evil: editor/evil on, the stack waits in keys.eld, nothing asked.
  (drgnx-modal-choose-test--with
    (delete-file (expand-file-name "keys-report.eld" (drgnx-state-dir)))
    (let ((asked 0))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (cl-incf asked) t))
                ((symbol-function 'drgnx-onboard--sync-job) (lambda () (ert-fail "drgnx sync ran"))))
        (let ((r (car (drgnx-onboard-run :only '(look-and-keys) :non-interactive t :options '(:keys "Vim")))))
          (should (= asked 0))
          (should (string-match-p "keys: Vim needs drgnx sync" (nth 2 r))))))
    (let ((user (drgnx-modal-choose-test--read "keys.eld")))
      (should (equal (plist-get user :layers) drgnx-modal-choose-test--vscode))
      (should (equal (plist-get user :pending-layers) drgnx-modal-choose-test--vim)))
    (should (equal (plist-get (drgnx-modal-choose-test--read "modules.eld") :enabled) '(editor/evil)))
    ;; the key report was written then (no apply ran)
    (should (file-exists-p (expand-file-name "keys-report.eld" (drgnx-state-dir))))
    ;; a start without evil: nothing switches, nothing is asked, the pending stack stays
    (let ((inhibit-interaction t)) (should-not (drgnx-modal-apply-pending)))
    (should (equal (plist-get (drgnx-modal-choose-test--read "keys.eld") :pending-layers) drgnx-modal-choose-test--vim))
    (should (equal (plist-get drgnx-keys-last :layers) drgnx-modal-choose-test--vscode))))

(ert-deftest drgnx-modal-choose/declined-keeps-the-stack ()
  (drgnx-modal-choose-test--with
    (let ((keys (drgnx-modal-choose-test--text "keys.eld")) (asked nil) (noninteractive nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (q) (push q asked) nil))
                ((symbol-function 'drgnx-onboard--sync-job) (lambda () (ert-fail "drgnx sync ran"))))
        (drgnx-keys-choose-profile "Vim" t))
      (should (= (length asked) 1))
      (should (string-match-p "evil" (car asked)))                ; it says what it installs
      (should (equal (drgnx-modal-choose-test--text "keys.eld") keys))
      (should-not (drgnx-modal-choose-test--text "modules.eld"))
      (should (equal (plist-get drgnx-keys-last :layers) drgnx-modal-choose-test--vscode)))))

(ert-deftest drgnx-modal-choose/going-back-turns-the-module-off ()
  (drgnx-modal-choose-test--with
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (ert-fail "asked"))))
      (drgnx-keys-choose-profile "Vim")                        ; from code, not the command: it waits for drgnx sync
      (should (memq 'editor/evil (plist-get (drgnx-modal-choose-test--read "modules.eld") :enabled)))
      (should (equal (plist-get drgnx-keys-last :layers) drgnx-modal-choose-test--vscode))
      (drgnx-keys-choose-profile "VS Code"))
    (should-not (memq 'editor/evil (plist-get (drgnx-modal-choose-test--read "modules.eld") :enabled)))
    (let ((user (drgnx-modal-choose-test--read "keys.eld")))
      (should-not (plist-member user :pending-layers))
      (should (equal (plist-get user :layers) drgnx-modal-choose-test--vscode)))
    (should (string-prefix-p ";; my keys\n" (drgnx-modal-choose-test--text "keys.eld")))))

(ert-deftest drgnx-modal-choose/a-vim-stack-without-evil-stays-usable ()
  ;; keys.eld names the Vim stack, editor/evil is on, evil is not installed: the start goes on, the module waits,
  ;; the palette and the Leader Menu keep their keys.
  (drgnx-modal-choose-test--with
    (drgnx-modal-choose-test--write "keys.eld" "(:layers ((vim app editing window)))\n")
    (drgnx-modal-choose-test--write "modules.eld" "(:version 1 :enabled (editor/evil))\n")
    (setq drgnx-modules--state nil)
    (let ((doctor 0)
          (find-file-hook find-file-hook)
          (drgnx-agents-request-functions (bound-and-true-p drgnx-agents-request-functions))
          (drgnx-agents-changed-functions (bound-and-true-p drgnx-agents-changed-functions))
          (drgnx-wb--areas (copy-tree (bound-and-true-p drgnx-wb--areas)))
          (drgnx-layouts-pane-fillers (copy-tree (bound-and-true-p drgnx-layouts-pane-fillers)))
          (drgnx-layouts-shapes (copy-tree (bound-and-true-p drgnx-layouts-shapes)))
          (drgnx-persist-state-functions (bound-and-true-p drgnx-persist-state-functions))
          (drgnx-persist-after-restore-functions (bound-and-true-p drgnx-persist-after-restore-functions))
          (ring-bell-function ring-bell-function) (use-dialog-box use-dialog-box)
          (use-short-answers use-short-answers) (inhibit-startup-screen inhibit-startup-screen))
      (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
      (cl-letf (((symbol-function 'drgnx-evil-doctor) (lambda () (cl-incf doctor) nil)))
        (drgnx-modules-run 'startup)
        (drgnx-keys-apply)
        (let ((inhibit-interaction t)) (drgnx-modal-apply-pending)))
      (should (eq (plist-get (alist-get 'editor/evil drgnx-modules--report) :status) 'missing-packages))
      (should (= doctor 0))
      (should-not (seq-filter (lambda (m) (eq (plist-get (cdr m) :status) 'failed)) drgnx-modules--report))
      (should-not (seq-find (lambda (p) (string-match-p "could not be applied" p)) (plist-get drgnx-keys-last :problems)))
      (should (equal (plist-get drgnx-keys-last :layers) drgnx-modal-choose-test--vim))
      (should-not drgnx-modal-running)
      (should (eq (keymap-lookup global-map "C-S-p") #'drgnx-palette))
      (should (eq (keymap-lookup global-map "<f1>") #'drgnx-palette))
      (should (eq (keymap-lookup global-map "M-SPC") #'drgnx-modal-leader-menu)))))

(ert-deftest drgnx-modal-choose/onboarding-keys-on-a-mac-say-there-are-no-clashes ()
  ;; The Keys question: the presets, VS Code preselected; on a Mac a help line above it.  Return keeps a pending stack.
  (drgnx-modal-choose-test--with
    (dolist (platform '(linux macos))
      (let ((asked nil))
        (cl-letf (((symbol-function 'drgnx-platform) (lambda () platform))
                  ((symbol-function 'drgnx-onboard--packages-to-install) #'ignore)
                  ((symbol-function 'completing-read)
                   (lambda (prompt _c &optional _p _r _i _h def &rest _) (push (cons prompt def) asked) (car (ensure-list def)))))
          (drgnx-onboard--look-step '(:interactive t :options (:preset full-ai :theme modus-vivendi))))
        (let ((keys (seq-find (lambda (q) (string-match-p "^Keys (" (car q))) asked)))
          (should (equal (cdr keys) "VS Code"))
          (should (string-search "Vim editing + VS Code app keys" (car keys)))
          (should (eq (and (string-search "With VS Code app keys on a Mac, Vim keeps Ctrl and VS Code uses Cmd: no clashes\nKeys ("
                                          (car keys))
                           t)
                      (eq platform 'macos))))))
    ;; a stack waiting for drgnx sync is the default: Return keeps it waiting
    (drgnx-keys-choose-profile "Vim")
    (let ((asked nil))
      (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux))
                ((symbol-function 'drgnx-onboard--packages-to-install) #'ignore)
                ((symbol-function 'y-or-n-p) (lambda (&rest _) (ert-fail "asked in batch")))
                ((symbol-function 'completing-read)
                 (lambda (prompt _c &optional _p _r _i _h def &rest _) (push (cons prompt def) asked) (car (ensure-list def)))))
        (should (string-match-p "keys: Vim needs drgnx sync"
                                (cadr (drgnx-onboard--look-step '(:interactive t :options (:preset full-ai :theme modus-vivendi)))))))
      (should (equal (cdr (seq-find (lambda (q) (string-match-p "^Keys (" (car q))) asked)) "Vim"))
      (should (equal (plist-get (drgnx-modal-choose-test--read "keys.eld") :pending-layers) drgnx-modal-choose-test--vim)))))

;;;; With evil: each in its own Emacs

(defconst drgnx-modal-choose-test--isolated "test/unit/isolated/modal-choose-isolated.el")

(ert-deftest drgnx-modal-choose/interactive-asks-once-and-switches-after-the-engine-loads ()
  (should (null (drgnx-modal-test-isolated-result
                 drgnx-modal-choose-test--isolated
                 "^drgnx-modal-choose/interactive-asks-once-and-switches-after-the-engine-loads\\'"))))

(ert-deftest drgnx-modal-choose/installed-engine-switches-without-asking ()
  (should (null (drgnx-modal-test-isolated-result
                 drgnx-modal-choose-test--isolated "^drgnx-modal-choose/installed-engine-switches-without-asking\\'"))))

(ert-deftest drgnx-modal-choose/pending-applies-at-the-next-start ()
  (should (null (drgnx-modal-test-isolated-result
                 drgnx-modal-choose-test--isolated "^drgnx-modal-choose/pending-applies-at-the-next-start\\'"))))

(provide 'modal-choose-test)
;;; modal-choose-test.el ends here
