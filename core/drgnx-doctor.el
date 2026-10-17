;;; drgnx-doctor.el --- Is this machine ready for drgnx? -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx doctor' runs these checks in batch, inside the Emacs drgnx will use, so every
;; answer is about that Emacs.  A check is a function of a facts plist (gathered once by
;; `drgnx-doctor-facts', injected in tests) returning (STATUS DETAIL FIX), STATUS one of
;; `ok', `warn', `fail' or `info'.  Any `fail' makes the doctor exit 1.  Modules will add
;; their own checks with `drgnx-doctor-define' (M4).  See docs/guide/install.md.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defconst drgnx-doctor-install-hint
  "run the installer: curl -fsSL https://raw.githubusercontent.com/Black-Dragon-Foundation/drgnx/main/install.sh | bash  (see docs/guide/install.md)"
  "How to get a suitable Emacs.")

(defconst drgnx-doctor-cves-fixed-in-31.2
  "TRAMP command injection via crafted file names, Flymake running code from edited files, read-symbol-shorthands code execution on opening a file"
  "Known security issues in Emacs up to 31.1, fixed in 31.2 (not released as of 2026-10-16).")

(defvar drgnx-doctor--checks nil "Alist NAME → plist (:group :doc :check :dev), in definition order.")

(cl-defun drgnx-doctor-define (name &key group doc check dev)
  "Define check NAME in GROUP with DOC; CHECK maps facts to (STATUS DETAIL FIX).
DEV non-nil: only run for `drgnx doctor --dev' (tools for developing drgnx)."
  (let ((entry (list :group group :doc doc :check check :dev dev)))
    (if (assq name drgnx-doctor--checks)
        (setf (alist-get name drgnx-doctor--checks) entry)
      (setq drgnx-doctor--checks (append drgnx-doctor--checks (list (cons name entry))))))
  name)

(defun drgnx-doctor-check (name facts)
  "Run check NAME on FACTS; return (STATUS DETAIL FIX)."
  (funcall (plist-get (alist-get name drgnx-doctor--checks) :check) facts))

;;;; Facts

(defun drgnx-doctor--native-compiles ()
  "t if this Emacs can natively compile a function, else the error as a string."
  (condition-case err
      (progn (native-compile '(lambda () 1)) t)
    (error (error-message-string err))))

(declare-function drgnx-pkg-status "drgnx-pkg")

(declare-function drgnx-work-db-file "drgnx-work-db")
(declare-function drgnx-work-nodes "drgnx-work-db")

(defun drgnx-doctor--work-plans ()
  "How many plans the work tracker knows (nil: it has not scanned yet)."
  (ignore-errors
    (require 'drgnx-work-db)
    (when (file-exists-p (drgnx-work-db-file)) (length (drgnx-work-nodes 'plan)))))

(defun drgnx-doctor-facts ()
  "Facts about the running Emacs and this machine."
  (let ((native (and (fboundp 'native-comp-available-p) (native-comp-available-p))))
    (list :version emacs-version
          :native-available native
          :native-compiles (if native (drgnx-doctor--native-compiles) "not built with native compilation")
          :treesit (and (fboundp 'treesit-available-p) (treesit-available-p))
          :gui (cond ((featurep 'pgtk) 'pgtk) ((featurep 'ns) 'ns) ((featurep 'x) 'x)
                     ((string-match-p "\\(PGTK\\|X11\\|NS\\)" system-configuration-features)
                      (intern (downcase (match-string 1 system-configuration-features)))))
          :git (and (executable-find "git") t)
          :mutter (and (executable-find "mutter") t)
          :dbus-run-session (and (executable-find "dbus-run-session") t)
          :magick (and (executable-find "magick") t)
          :pgtk-emacs (or (featurep 'pgtk) (and (executable-find "emacs-pgtk") t))
          :keys-report (drgnx-doctor--keys-report)
          :modules-report (drgnx-doctor--state-file "modules-report.eld")
          :onboarding (drgnx-doctor--state-file "onboarding.eld")
          :packages (condition-case err (progn (require 'drgnx-pkg) (drgnx-pkg-status))
                      (error (list :error (error-message-string err))))
          :sqlite (and (fboundp 'sqlite-available-p) (sqlite-available-p))
          :svg (image-type-available-p 'svg)
          :work-plans (drgnx-doctor--work-plans))))

(defun drgnx-doctor--state-file (name)
  "The .eld file NAME the last drgnx session wrote in the state dir, read, or nil."
  (let ((file (expand-file-name (concat "drgnx/" name) (or (getenv "XDG_STATE_HOME") "~/.local/state"))))
    (when (file-readable-p file)
      (ignore-errors (with-temp-buffer (insert-file-contents file) (read (current-buffer)))))))

(defun drgnx-doctor--keys-report ()
  "The key report the last drgnx session wrote (keys-report.eld in the state dir), or nil."
  (let ((file (expand-file-name "drgnx/keys-report.eld" (or (getenv "XDG_STATE_HOME") "~/.local/state"))))
    (when (file-readable-p file)
      (ignore-errors (with-temp-buffer (insert-file-contents file) (read (current-buffer)))))))

;;;; Checks

(defun drgnx-doctor--version< (a b) (version< a b))

(drgnx-doctor-define 'emacs-version :group "Emacs" :doc "GNU Emacs 31.1 or newer (30.2 still works)"
  :check (lambda (f)
           (let ((v (plist-get f :version)))
             (cond ((not (drgnx-doctor--version< v "31.1")) (list 'ok (format "Emacs %s" v) nil))
                   ((not (drgnx-doctor--version< v "30.2"))
                    (list 'warn (format "Emacs %s works, 31.1 is recommended" v) drgnx-doctor-install-hint))
                   (t (list 'fail (format "Emacs %s is too old (30.2 or newer needed)" v) drgnx-doctor-install-hint))))))

(drgnx-doctor-define 'native-compilation :group "Emacs" :doc "Native compilation works (drgnx's speed depends on it)"
  :check (lambda (f)
           (let ((c (plist-get f :native-compiles)))
             (cond ((not (plist-get f :native-available))
                    (list 'fail "this Emacs was built without native compilation" drgnx-doctor-install-hint))
                   ((eq c t) (list 'ok "native compilation works" nil))
                   (t (list 'fail (format "native compilation is built in but fails: %s" c)
                            (concat "install your distribution's libgccjit, or " drgnx-doctor-install-hint)))))))

(drgnx-doctor-define 'tree-sitter :group "Emacs" :doc "Tree-sitter support (syntax-aware editing)"
  :check (lambda (f)
           (if (plist-get f :treesit) (list 'ok "tree-sitter available" nil)
             (list 'warn "this Emacs has no tree-sitter support" drgnx-doctor-install-hint))))

(drgnx-doctor-define 'gui :group "Emacs" :doc "A graphical build (pgtk on Wayland, X11 or macOS)"
  :check (lambda (f)
           (if-let* ((g (plist-get f :gui))) (list 'ok (format "graphical build (%s)" g) nil)
             (list 'warn "terminal-only Emacs: drgnx's workbench needs a graphical build" drgnx-doctor-install-hint))))

(drgnx-doctor-define 'security :group "Emacs" :doc "Known security issues of this Emacs version"
  :check (lambda (f)
           (if (drgnx-doctor--version< (plist-get f :version) "31.2")
               (list 'warn (format "Emacs up to 31.1 has known issues fixed in 31.2: %s" drgnx-doctor-cves-fixed-in-31.2)
                     "update to 31.2 when it is released; until then avoid opening untrusted files and remote paths")
             (list 'ok "no known issues for this version" nil))))

(drgnx-doctor-define 'git :group "Tools" :doc "git (installing and updating drgnx)"
  :check (lambda (f)
           (if (plist-get f :git) (list 'ok "git found" nil)
             (list 'warn "git not found" "install git with your package manager"))))

(drgnx-doctor-define 'modules :group "drgnx" :doc "Modules that failed or wait for packages (from the last session)"
  :check (lambda (f)
           (let* ((r (plist-get f :modules-report))
                  (failed (seq-filter (lambda (m) (eq (plist-get (cdr m) :status) 'failed)) r))
                  (waiting (seq-filter (lambda (m) (eq (plist-get (cdr m) :status) 'missing-packages)) r))
                  (problems (seq-filter (lambda (m) (plist-get (cdr m) :problems)) r)))
             (cond ((null r) (list 'info "no module report yet — start drgnx once" nil))
                   (failed (list 'fail (mapconcat (lambda (m) (format "%s: %s" (car m) (plist-get (cdr m) :error))) failed "; ")
                                 "see Preferences: Modules; turn the module off there or report the error"))
                   (waiting (list 'warn (format "waiting for packages: %s"
                                                (mapconcat (lambda (m) (format "%s (%s)" (car m)
                                                                              (mapconcat #'symbol-name (plist-get (cdr m) :missing) " ")))
                                                           waiting ", "))
                                  "drgnx sync installs them (M5); until then these modules stay off"))
                   (problems (list 'warn (mapconcat (lambda (m) (format "%s: %s" (car m) (string-join (plist-get (cdr m) :problems) "; ")))
                                                    problems "; ")
                                   "see the module's documentation"))
                   (t (list 'ok (format "%d modules ok" (length r)) nil))))))

(drgnx-doctor-define 'packages :group "drgnx" :doc "The packages drgnx needs are installed (drgnx sync), with a lock"
  :check (lambda (f)
           (let* ((p (plist-get f :packages))
                  (missing (seq-difference (plist-get p :manifest) (plist-get p :installed))))
             (cond ((plist-get p :error) (list 'fail (plist-get p :error) "fix or remove the file named; drgnx sync rewrites the lock"))
                   (missing (list 'warn (format "not installed: %s" (mapconcat #'symbol-name missing " "))
                                  "drgnx sync installs them (their modules wait until then)"))
                   ((and (plist-get p :manifest) (not (plist-get p :lock)))
                    (list 'warn "no lock (drgnx.lock.eld)" "drgnx sync writes it; commit it with your configuration"))
                   ((null (plist-get p :manifest)) (list 'ok "no packages needed" nil))
                   (t (list 'ok (format "%d packages installed, locked; %d generations"
                                        (length (plist-get p :installed)) (plist-get p :generations))
                            nil))))))

(drgnx-doctor-define 'onboarding :group "drgnx" :doc "The onboarding steps (drgnx onboard, Help → Welcome)"
  :check (lambda (f)
           (let* ((s (plist-get f :onboarding))
                  (failed (seq-filter (lambda (e) (eq (plist-get (cdr e) :status) 'fail)) s)))
             (cond ((null s) (list 'info "not run yet" "drgnx onboard (or Help → Welcome in drgnx)"))
                   (failed (list 'warn (format "steps that failed: %s" (mapconcat (lambda (e) (symbol-name (car e))) failed " "))
                                 "run them again from Help → Welcome, or drgnx onboard --step ID"))
                   (t (list 'ok (format "%d steps done" (length s)) nil))))))

(drgnx-doctor-define 'work :group "drgnx" :doc "The work tracker (SQLite in Emacs; SVG for its graph)"
  :check (lambda (f)
           (cond ((not (plist-get f :sqlite)) (list 'fail "this Emacs has no SQLite: the work tracker is off" "use an Emacs built with SQLite (the installer's does)"))
                 ((null (plist-get f :work-plans)) (list 'info "nothing scanned yet" "drgnx work scan (or Show Work)"))
                 ((not (plist-get f :svg)) (list 'warn (format "%d plans tracked; this Emacs cannot show SVG: no Work graph" (plist-get f :work-plans))
                                                drgnx-doctor-install-hint))
                 (t (list 'ok (format "%d plans tracked" (plist-get f :work-plans)) nil)))))

(drgnx-doctor-define 'key-conflicts :group "drgnx" :doc "Key profile conflicts and keys.eld problems (from the last session)"
  :check (lambda (f)
           (let* ((r (plist-get f :keys-report)) (conflicts (plist-get r :conflicts)) (problems (plist-get r :problems)))
             (cond ((null r) (list 'info "no key report yet — start drgnx once" nil))
                   (problems (list 'warn (format "%d key problem%s: %s" (length problems) (if (cdr problems) "s" "")
                                                 (string-join problems "; "))
                                   "fix ~/.config/drgnx/keys.eld (docs/guide/keys.md)"))
                   (conflicts (list 'info (format "%d key conflicts, resolved by layer order (%s): %s" (length conflicts)
                                                  (mapconcat (lambda (l) (symbol-name (car l))) (plist-get r :layers) " < ")
                                                  (string-join (seq-take conflicts 3) "; "))
                                    "see Keyboard Shortcuts › Key conflicts; change them in keys.eld (docs/guide/keys.md)"))
                   (t (list 'ok (format "no key conflicts (%s)"
                                        (mapconcat (lambda (l) (symbol-name (car l))) (plist-get r :layers) " < "))
                            nil))))))

(dolist (tool '((ui-mutter :mutter "mutter" "the headless compositor of drgnx test --ui")
                (ui-dbus :dbus-run-session "dbus-run-session" "a private D-Bus per test session")
                (ui-magick :magick "magick" "ImageMagick 7: screenshot compositing")
                (ui-pgtk :pgtk-emacs "a pgtk Emacs (emacs-pgtk)" "the GUI Emacs of harness sessions")))
  (pcase-let ((`(,name ,key ,bin ,why) tool))
    (drgnx-doctor-define name :group "Development" :dev t :doc (format "%s (%s)" bin why)
      :check (lambda (f)
               (if (plist-get f key) (list 'ok (format "%s found" bin) nil)
                 (list 'warn (format "%s not found (%s)" bin why) (format "install %s" bin)))))))

;;;; Running and reporting

(defun drgnx-doctor-run (facts &optional dev)
  "Results (plists :name :group :status :detail :fix) of every check on FACTS; DEV adds dev checks."
  (cl-loop for (name . spec) in drgnx-doctor--checks
           when (or dev (not (plist-get spec :dev)))
           collect (pcase-let ((`(,status ,detail ,fix)
                                (condition-case err (funcall (plist-get spec :check) facts)
                                  (error (list 'fail (format "the check itself failed: %s" (error-message-string err)) nil)))))
                     (list :name name :group (plist-get spec :group) :status status :detail detail :fix fix))))

(defun drgnx-doctor-format (results)
  "RESULTS as text: one line per check, the fix indented below anything not ok."
  (mapconcat (lambda (r)
               (concat (format "%-5s %-20s %s" (upcase (if (eq (plist-get r :status) 'ok) "ok" (symbol-name (plist-get r :status))))
                               (plist-get r :name) (plist-get r :detail))
                       (if (and (plist-get r :fix) (not (eq (plist-get r :status) 'ok)))
                           (format "\n      fix: %s" (plist-get r :fix)) "")))
             results "\n"))

(defun drgnx-doctor-json (results)
  (decode-coding-string
   (json-serialize (vconcat (mapcar (lambda (r) (list :name (symbol-name (plist-get r :name)) :group (plist-get r :group)
                                                      :status (symbol-name (plist-get r :status))
                                                      :detail (plist-get r :detail) :fix (or (plist-get r :fix) :null)))
                                    results)))
   'utf-8))

(defun drgnx-doctor-exit-code (results)
  (if (seq-some (lambda (r) (eq (plist-get r :status) 'fail)) results) 1 0))

(defun drgnx-doctor-cli ()
  "Batch entry: `drgnx doctor [--json] [--dev]'."
  (let* ((args (prog1 command-line-args-left (setq command-line-args-left nil)))
         (results (drgnx-doctor-run (drgnx-doctor-facts) (member "--dev" args))))
    (princ (if (member "--json" args) (drgnx-doctor-json results) (drgnx-doctor-format results)))
    (terpri)
    (kill-emacs (drgnx-doctor-exit-code results))))

(provide 'drgnx-doctor)
;;; drgnx-doctor.el ends here
