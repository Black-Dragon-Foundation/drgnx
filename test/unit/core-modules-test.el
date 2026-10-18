;;; core-modules-test.el --- batch tests: the module system -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-modules)

(defmacro drgnx-test--fresh-modules (&rest body)
  `(let ((drgnx-modules--table nil) (drgnx-modules--report nil)) ,@body))

(ert-deftest drgnx-modules/define-and-run-by-stage ()
  (drgnx-test--fresh-modules
   (let (ran)
     (drgnx-module-define 'test/early :doc "early" :stage 'startup :setup (lambda () (push 'early ran)))
     (drgnx-module-define 'test/late :doc "late" :stage 'idle :setup (lambda () (push 'late ran)))
     (drgnx-modules-run 'startup)
     (should (equal ran '(early)))
     (drgnx-modules-run 'idle)
     (should (equal ran '(late early))))))

(ert-deftest drgnx-modules/errors-are-isolated-and-reported ()
  (drgnx-test--fresh-modules
   (let (ran)
     (drgnx-module-define 'test/broken :doc "b" :stage 'startup :setup (lambda () (error "kaputt")))
     (drgnx-module-define 'test/fine :doc "f" :stage 'startup :setup (lambda () (setq ran t)))
     (drgnx-modules-run 'startup)
     (should ran)
     (let ((broken (alist-get 'test/broken (drgnx-modules-report))))
       (should (string-search "kaputt" (plist-get broken :error)))
       (should (integerp (plist-get broken :ms))))
     (should (eq (plist-get (alist-get 'test/fine (drgnx-modules-report)) :error) nil)))))

(ert-deftest drgnx-modules/load-directory ()
  (drgnx-test--fresh-modules
   (let ((dir (make-temp-file "drgnx-mods" t)))
     (unwind-protect
         (progn
           (make-directory (expand-file-name "test" dir))
           (write-region "(drgnx-module-define 'test/from-file :doc \"x\" :stage 'startup :setup #'ignore)\n"
                         nil (expand-file-name "test/drgnx-from-file.el" dir))
           (write-region "(error \"does not load\")\n" nil (expand-file-name "test/drgnx-bad.el" dir))
           (drgnx-modules-load-directory dir)
           (should (assq 'test/from-file drgnx-modules--table))
           (should (string-search "does not load"
                                  (plist-get (alist-get 'test/drgnx-bad (drgnx-modules-report)) :error))))
       (delete-directory dir t)))))

(ert-deftest drgnx-modules/a-built-module-runs-compiled ()
  (let ((dir (make-temp-file "drgnx-modules" t)) (drgnx-modules--table nil) (drgnx-modules--report nil))
    (unwind-protect
        (let ((f (expand-file-name "drgnx-test-compiled.el" dir)))
          (with-temp-file f
            (insert ";;; -*- lexical-binding: t -*-\n(defun drgnx-test-compiled-fn () 1)\n"))
          (byte-compile-file f)
          (let ((load-prefer-newer t)) (drgnx-modules-load-directory dir))
          (should (byte-code-function-p (symbol-function 'drgnx-test-compiled-fn))))
      (delete-directory dir t))))

;;;; M4: the full module system

(defmacro drgnx-modules-test--with-config (&rest body)
  "BODY with an empty user config dir and state dir (never the user's)."
  `(let* ((cfg (make-temp-file "drgnx-cfg" t)) (st (make-temp-file "drgnx-st" t))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" cfg) (concat "XDG_STATE_HOME=" st))
                                       process-environment))
          (drgnx-modules--table nil) (drgnx-modules--report nil))
     (unwind-protect (progn ,@body) (delete-directory cfg t) (delete-directory st t))))

(defun drgnx-modules-test--status (name) (plist-get (alist-get name (drgnx-modules-report)) :status))

(ert-deftest drgnx-modules/statuses ()
  (drgnx-modules-test--with-config
   (drgnx-module-define 'test/ok :doc "ok" :setup #'ignore)
   (drgnx-module-define 'test/needs-pkg :doc "p" :packages '(drgnx-no-such-package) :setup (lambda () (error "ran")))
   (drgnx-module-define 'test/needs-mod :doc "r" :requires '(test/needs-pkg) :setup (lambda () (error "ran")))
   (drgnx-module-define 'test/off :doc "d" :setup (lambda () (error "ran")))
   (drgnx-modules-update-state (lambda (_) '(:disabled (test/off))))
   (drgnx-modules-run 'startup)
   (should (eq (drgnx-modules-test--status 'test/ok) 'ok))
   (should (eq (drgnx-modules-test--status 'test/needs-pkg) 'missing-packages))
   (should (equal (plist-get (alist-get 'test/needs-pkg (drgnx-modules-report)) :missing) '(drgnx-no-such-package)))
   (should (eq (drgnx-modules-test--status 'test/needs-mod) 'missing-requires))
   (should (eq (drgnx-modules-test--status 'test/off) 'disabled))
   ;; only a module whose setup ran and went well runs
   (should (drgnx-module-running-p 'test/ok))
   (dolist (m '(test/needs-pkg test/needs-mod test/off test/never-defined)) (should-not (drgnx-module-running-p m)))))

(ert-deftest drgnx-modules/the-new-stages-run-on-their-hooks ()
  (drgnx-modules-test--with-config
   (let (ran (drgnx-first-gui-frame-hook nil) (drgnx-first-file-hook nil) (drgnx-first-input-hook nil))
     (dolist (stage '(first-frame first-file first-input))
       (drgnx-module-define (intern (format "test/%s" stage)) :doc "s" :stage stage
                            :setup (let ((s stage)) (lambda () (push s ran)))))
     (cl-letf (((symbol-function 'run-with-idle-timer) #'ignore))   ; no timer left to fire later
       (drgnx-modules-start cfg))
     (drgnx-timer-reset)                                              ; the layer's keys for the stubbed timers
     (run-hooks 'drgnx-first-file-hook)
     (should (equal ran '(first-file)))
     (run-hooks 'drgnx-first-gui-frame-hook 'drgnx-first-input-hook)
     (should (equal (sort ran #'string<) '(first-file first-frame first-input))))))

(ert-deftest drgnx-modules/flags-come-from-the-state ()
  (drgnx-modules-test--with-config
   (drgnx-modules-update-state (lambda (_) '(:flags ((ui/popups +childframe)))))
   (should (drgnx-module-flag-p 'ui/popups '+childframe))
   (should-not (drgnx-module-flag-p 'ui/popups '+other))))

(ert-deftest drgnx-modules/old-and-broken-state-files ()
  (drgnx-modules-test--with-config
   ;; Version 0 was a bare list of disabled modules: migrated.
   (with-temp-file (expand-file-name "modules.eld" (drgnx-user-dir)) (prin1 '(lang/python ui/zen) (current-buffer)))
   (should (equal (plist-get (drgnx-modules-read-state) :disabled) '(lang/python ui/zen)))
   (should (eql (plist-get (drgnx-modules-read-state) :version) 2))
   ;; Unreadable: defaults, a message, no error.
   (with-temp-file (expand-file-name "modules.eld" (drgnx-user-dir)) (insert "(:version 1 :disabled (oops"))
   (drgnx-config-reread 'modules)
   (should (equal (plist-get (drgnx-modules-read-state) :disabled) nil))))

(ert-deftest drgnx-modules/preferences-toggle-a-module ()
  (drgnx-modules-test--with-config
   (drgnx-module-define 'test/a :doc "A module" :setup #'ignore)
   (drgnx-modules-run 'startup)
   (drgnx-modules-toggle 'test/a)
   (should (memq 'test/a (plist-get (drgnx-modules-read-state) :disabled)))
   (with-current-buffer (drgnx-modules-list)
     (should (string-search "test/a" (buffer-string)))
     (should (string-search "off at next start" (buffer-string))))
   (drgnx-modules-toggle 'test/a)
   (should-not (memq 'test/a (plist-get (drgnx-modules-read-state) :disabled)))))

(ert-deftest drgnx-modules/the-doctor-reads-the-last-session ()
  (drgnx-modules-test--with-config
   (drgnx-module-define 'test/broken :doc "b" :setup (lambda () (error "kaputt")))
   (drgnx-module-define 'test/needs-pkg :doc "p" :packages '(drgnx-no-such-package) :setup #'ignore)
   (drgnx-modules-run 'startup)
   (drgnx-modules-write-report)
   (require 'drgnx-doctor)
   (let ((r (drgnx-doctor-check 'modules (cl-letf (((symbol-function 'drgnx-doctor--search) #'ignore)) (drgnx-doctor-facts)))))
     (should (eq (car r) 'fail))
     (should (string-search "test/broken" (nth 1 r))))))

;;;; M4 review fixes

(ert-deftest drgnx-modules/a-hand-edited-mistake-never-stops-startup-and-is-never-written-over ()
  ;; I1: a typo in modules.eld never stops startup: the defaults apply, one problem says where, the file is kept.
  (drgnx-modules-test--with-config
   (let* ((file (expand-file-name "modules.eld" (drgnx-user-dir)))
          (text "(:version 1 :disabled lang/eglot :flags oops :external (gryphn (:name x)))\n"))
     (with-temp-file file (insert text))
     (let ((st (drgnx-modules-read-state)))
       (should-not (plist-get st :disabled))
       (should-not (plist-get st :external)))
     (should (drgnx-config-problem 'modules))
     (drgnx-module-define 'test/ok :doc "ok" :setup #'ignore)
     (drgnx-modules-run 'startup)
     (should (eq (drgnx-modules-test--status 'test/ok) 'ok))
     (should-not (drgnx-module-flag-p 'x '+y))
     (drgnx-modules-load-external)
     (should-error (drgnx-modules-toggle 'test/ok) :type 'drgnx-config-refused)
     (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) text)))))

(ert-deftest drgnx-modules/an-unreadable-file-is-never-replaced-by-a-toggle ()
  ;; I2: the user's unreadable (or newer) modules.eld is never replaced: the toggle refuses, no backup is needed.
  (drgnx-modules-test--with-config
   (let ((file (expand-file-name "modules.eld" (drgnx-user-dir)))
         (text "(:version 1 :external ((:name kept :path \"/x\" :features (a)))   ; typo: no closing paren"))
     (with-temp-file file (insert text))
     (drgnx-module-define 'test/a :doc "a" :setup #'ignore)
     (should-error (drgnx-modules-toggle 'test/a) :type 'drgnx-config-refused)
     (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) text))
     (should-not (directory-files (drgnx-user-dir) nil "\\`modules\\.eld\\.bak")))))

(ert-deftest drgnx-modules/the-list-shows-external-and-broken-modules ()
  ;; I3: what the report knows — external features, files that failed to load — is in the list too.
  (drgnx-modules-test--with-config
   (drgnx-modules-update-state (lambda (_) '(:external ((:name gone :path "/nonexistent/drgnx" :features (x))))))
   (drgnx-modules-load-external)
   (with-current-buffer (drgnx-modules-list)
     (should (string-search "external/gone" (buffer-string))))
   ;; …and an external module can be turned off.
   (drgnx-modules-toggle 'external/gone)
   (setq drgnx-modules--report nil)
   (drgnx-modules-load-external)
   (should (eq (plist-get (alist-get 'external/gone (drgnx-modules-report)) :status) 'disabled))))

(ert-deftest drgnx-modules/what-external-code-wants-reaches-the-manifest ()
  ;; I6 (M5 review): the packages an external module would have installed are recorded for drgnx sync.
  (drgnx-modules-test--with-config
   (let ((dir (make-temp-file "drgnx-ext" t)))
     (unwind-protect
         (progn
           (write-region "(require 'use-package)\n(use-package kx-wanted-pkg :ensure t :defer t)\n(provide 'kx-wants)\n" nil (expand-file-name "kx-wants.el" dir) nil 'silent)
           (drgnx-modules-update-state (lambda (_) `(:external ((:name kx :path ,dir :features (kx-wants))))))
           (drgnx-modules-load-external)
           (require 'drgnx-pkg-activate)
           (should (memq 'kx-wanted-pkg (with-temp-buffer (insert-file-contents (drgnx-pkg-wanted-file)) (read (current-buffer))))))
       (delete-directory dir t)))))

(ert-deftest drgnx-modules/external-code-never-installs ()
  ;; C1: gryphn's files say `use-package … :ensure t' (and :vc); loading them must not refresh
  ;; archives or install — the module waits, reported, like any module missing a package.
  (drgnx-modules-test--with-config
   (let ((dir (make-temp-file "drgnx-ext" t)) (calls nil))
     (unwind-protect
         (cl-letf (((symbol-function 'package-refresh-contents) (lambda (&rest _) (push 'refresh calls)))
                   ((symbol-function 'package-install) (lambda (&rest a) (push (cons 'install a) calls)))
                   ((symbol-function 'package-vc-install) (lambda (&rest a) (push (cons 'vc a) calls))))
           (write-region "(require 'use-package)\n(use-package kx-not-installed :ensure t :config (kx-not-installed-mode 1))\n(package-vc-install \"https://example.invalid/kx.git\")\n(provide 'kx-ensure)\n"
                         nil (expand-file-name "kx-ensure.el" dir) nil 'silent)
           (drgnx-modules-update-state (lambda (_) `(:external ((:name kx :path ,dir :features (kx-ensure))))))
           (drgnx-modules-load-external)
           (should-not calls)
           (let ((r (alist-get 'external/kx/kx-ensure (drgnx-modules-report))))
             (should (eq (plist-get r :status) 'missing-packages))
             (should (memq 'kx-not-installed (plist-get r :missing)))))
       (delete-directory dir t)))))

(ert-deftest drgnx-modules/module-doctor-checks-reach-the-doctor ()
  ;; I5: a module's :doctor problems are in the report the doctor reads.
  (drgnx-modules-test--with-config
   (drgnx-module-define 'test/doc :doc "d" :setup #'ignore :doctor (lambda () '("the example program is missing")))
   (drgnx-modules-run 'startup)
   (drgnx-modules-write-report)
   (require 'drgnx-doctor)
   (let ((r (drgnx-doctor-check 'modules (cl-letf (((symbol-function 'drgnx-doctor--search) #'ignore)) (drgnx-doctor-facts)))))
     (should (eq (car r) 'warn))
     (should (string-search "the example program is missing" (nth 1 r))))))

(ert-deftest drgnx-modules/keys-are-re-applied-only-after-a-stage-that-ran ()
  ;; Minor 1 (re-graded): re-applying keys costs ~30 ms; a stage with no module must not pay it.
  (let* ((drgnx-modules--table nil) (drgnx-modules--report nil) (seen nil)
         (drgnx-modules-after-stage-functions (list (lambda (stage) (push stage seen)))))
    (drgnx-modules-run 'first-input)
    (should-not seen)))

;;;; Deferred fixes

(ert-deftest drgnx-modules/requires-orders-a-stage ()
  ;; M4-3: a module listed before the module it requires runs after it, in the same stage.
  (drgnx-modules-test--with-config
   (let (ran)
     (drgnx-module-define 'test/top :doc "t" :requires '(test/mid) :setup (lambda () (push 'top ran)))
     (drgnx-module-define 'test/mid :doc "m" :requires '(test/base) :setup (lambda () (push 'mid ran)))
     (drgnx-module-define 'test/base :doc "b" :setup (lambda () (push 'base ran)))
     (drgnx-module-define 'test/loop :doc "l" :requires '(test/loop) :setup (lambda () (push 'loop ran)))
     (drgnx-modules-run 'startup)
     (should (equal (reverse ran) '(base mid top)))
     (should (eq (drgnx-modules-test--status 'test/top) 'ok))
     (should (eq (drgnx-modules-test--status 'test/loop) 'missing-requires)))))

(ert-deftest drgnx-modules/each-idle-module-has-its-own-idle-tick ()
  ;; M4-1: idle modules run one per idle timer, staggered, so input between them is handled; the
  ;; external modules load first, the last re-applies keys and writes the report.
  (drgnx-modules-test--with-config
   (let* ((log nil) (timers nil)
          (drgnx-modules-after-stage-functions (list (lambda (stage) (push (list 'after stage) log)))))
     (drgnx-module-define 'test/i1 :doc "1" :stage 'idle :setup (lambda () (push 'i1 log)))
     (drgnx-module-define 'test/i2 :doc "2" :stage 'idle :setup (lambda () (push 'i2 log)))
     (cl-letf (((symbol-function 'run-with-idle-timer)
                (lambda (secs repeat fn &rest args) (should-not repeat) (push (list secs fn args) timers)))
               ((symbol-function 'drgnx-modules-load-external) (lambda () (push 'external log)))
               ((symbol-function 'drgnx-modules-write-report) (lambda () (push 'report log))))
       (drgnx-modules-start cfg)
       (setq log nil timers (sort timers (lambda (a b) (< (car a) (car b)))))
       (should (= (length timers) 4))
       (should (apply #'< (mapcar #'car timers)))
       (should (= (length (drgnx-timer-pending)) 4))               ; four keys in the timer layer, owned by :core
       (should (drgnx-timer-active-p '(modules-idle-step . 0)))
       (pcase-dolist (`(,_ ,fn ,args) timers) (apply fn args) (push '| log))
       (should (equal (reverse log) '(external | i1 | i2 | (after idle) report |)))
       (should-not (drgnx-timer-pending))))))                      ; one-shots: nothing left

(ert-deftest drgnx-modules/a-load-error-names-the-file-that-failed ()
  ;; M4-9: an error inside a library the module file loads names that library, not only the module.
  (drgnx-test--fresh-modules
   (let ((dir (make-temp-file "drgnx-mods" t)) (lib (make-temp-file "drgnx-lib" t)))
     (unwind-protect
         (let ((load-path (cons lib load-path)))
           (make-directory (expand-file-name "test" dir))
           (write-region "(error \"inner kaputt\")\n" nil (expand-file-name "drgnx-test-inner-lib.el" lib))
           (write-region "(require 'drgnx-test-inner-lib)\n" nil (expand-file-name "test/drgnx-outer.el" dir))
           (write-region "(error \"direct kaputt\")\n" nil (expand-file-name "test/drgnx-direct.el" dir))
           (drgnx-modules-load-directory dir)
           (let ((outer (plist-get (alist-get 'test/drgnx-outer (drgnx-modules-report)) :error))
                 (direct (plist-get (alist-get 'test/drgnx-direct (drgnx-modules-report)) :error)))
             (should (string-search "inner kaputt" outer))
             (should (string-search "drgnx-test-inner-lib" outer))
             (should (equal direct "direct kaputt"))))
       (delete-directory dir t) (delete-directory lib t)))))

(ert-deftest drgnx-modules/an-invalid-external-entry-is-listed-and-kept ()
  ;; M4-5: an external entry without :path is listed as failed, and writing modules.eld keeps it.
  (drgnx-modules-test--with-config
   (let ((file (expand-file-name "modules.eld" (drgnx-user-dir))))
     (with-temp-file file (prin1 '(:version 1 :external ((:name nopath :features (a)))) (current-buffer)))
     (drgnx-modules-load-external)
     (let ((r (alist-get 'external/nopath (drgnx-modules-report))))
       (should (eq (plist-get r :status) 'failed))
       (should (string-search ":path" (plist-get r :error))))
     (with-current-buffer (drgnx-modules-list) (should (string-search "external/nopath" (buffer-string))))
     (drgnx-module-define 'test/a :doc "a" :setup #'ignore)
     (drgnx-modules-toggle 'test/a)
     (should (equal (plist-get (drgnx-modules-read-state) :external) '((:name nopath :features (a))))))))

(ert-deftest drgnx-modules/the-list-sorts-numbers-and-stages-and-describes-externals ()
  ;; M4-11: ms sorts as a number, Stage in stage order; an external row says where it comes from.
  (drgnx-modules-test--with-config
   (drgnx-modules-update-state (lambda (_) '(:external ((:name gone :path "/nonexistent/drgnx" :features (x y))))))
   (drgnx-modules-load-external)
   (with-current-buffer (drgnx-modules-list)
     (let ((col (lambda (name) (nth 2 (seq-find (lambda (c) (equal (car c) name)) (append tabulated-list-format nil)))))
           (row (lambda (stage ms) (list 'x (vector "m" "ok" stage ms "on" "")))))
       (should (functionp (funcall col "ms")))
       (should (funcall (funcall col "ms") (funcall row "idle" "9") (funcall row "idle" "10")))
       (should-not (funcall (funcall col "ms") (funcall row "idle" "10") (funcall row "idle" "9")))
       (should (funcall (funcall col "Stage") (funcall row "startup" "") (funcall row "idle" "")))
       (should-not (funcall (funcall col "Stage") (funcall row "first-input" "") (funcall row "idle" ""))))
     (should (string-search "/nonexistent/drgnx" (buffer-string)))
     (should-not (string-search "external module" (buffer-string))))))

;;;; modules.eld is format 2

(defun drgnx-modules-test--read-file (file)
  (with-temp-buffer (insert-file-contents file) (read (current-buffer))))

(ert-deftest drgnx-modules/a-v1-file-reads-and-is-written-as-v2 ()
  (drgnx-modules-test--with-config
   (let ((file (expand-file-name "modules.eld" (drgnx-user-dir))))
     (should (eql drgnx-modules-state-version 2))
     (with-temp-file file (prin1 '(:version 1 :disabled (ui/zen) :enabled (editor/evil) :flags ((ui/popups +childframe))) (current-buffer)))
     (let ((st (drgnx-modules-read-state)))       ; format 1 needs no change
       (should (equal (plist-get st :disabled) '(ui/zen)))
       (should (equal (plist-get st :enabled) '(editor/evil)))
       (should (equal (plist-get st :flags) '((ui/popups +childframe)))))
     (drgnx-modules-toggle 'test/a)               ; the first write after a migration: v2, the old file kept aside
     (should (eql (plist-get (drgnx-modules-test--read-file file) :version) 2))
     (should (equal (plist-get (drgnx-modules-test--read-file file) :disabled) '(ui/zen test/a)))
     (should (= (length (directory-files (drgnx-user-dir) nil "\\`modules\\.eld\\.bak")) 1)))))

(ert-deftest drgnx-modules/a-format-0-bare-list-still-reads ()
  (drgnx-modules-test--with-config
   (let ((file (expand-file-name "modules.eld" (drgnx-user-dir))))
     (with-temp-file file (prin1 '(lang/python) (current-buffer)))
     (should (equal (plist-get (drgnx-modules-read-state) :disabled) '(lang/python))))))

(ert-deftest drgnx-modules/a-v3-file-is-applied-read-only ()
  (drgnx-modules-test--with-config
   (let ((file (expand-file-name "modules.eld" (drgnx-user-dir))))
     (with-temp-file file (prin1 '(:version 3 :disabled (ui/zen) :enabled (editor/evil)) (current-buffer)))
     (let ((st (drgnx-modules-read-state)))       ; it fits the schema: applied as it is
       (should (equal (plist-get st :disabled) '(ui/zen)))
       (should (equal (plist-get st :enabled) '(editor/evil))))
     (drgnx-module-define 'test/a :doc "a" :setup #'ignore)
     (should-error (drgnx-modules-toggle 'test/a) :type 'drgnx-config-refused)
     (should (eql (plist-get (drgnx-modules-test--read-file file) :version) 3))
     (should-not (directory-files (drgnx-user-dir) nil "\\`modules\\.eld\\.bak")))))

(ert-deftest drgnx-modules/enabled-survives-a-turn-off ()
  (drgnx-modules-test--with-config
   (let ((file (expand-file-name "modules.eld" (drgnx-user-dir))))
     (with-temp-file file (prin1 '(:version 1 :enabled (editor/evil)) (current-buffer)))
     (drgnx-module-define 'test/a :doc "a" :setup #'ignore)
     (drgnx-modules-toggle 'test/a)
     (let ((written (drgnx-modules-test--read-file file)))
       (should (eql (plist-get written :version) 2))
       (should (equal (plist-get written :enabled) '(editor/evil)))
       (should (equal (plist-get written :disabled) '(test/a)))))))
