;;; watchdog-test.el --- batch tests: drgnx's side of the stall watchdog -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-watchdog)
(require 'drgnx-gc-census)
(require 'drgnx-watchdog-doctor)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)

(defvar nidhogg-watchdog-record-functions)
(defvar features)                       ; special here, so a `let' of it is dynamic (`features' is not special in Emacs)

(defvar nidhogg-watchdog-mode)
(defvar nidhogg-watchdog-log-directory)
(defvar nidhogg-watchdog-typing-commands)
(defvar nidhogg-watchdog-package-functions)

(defmacro drgnx-watchdog-test--stubbed (&rest body)
  "BODY with a stand-in for Nidhogg's watchdog (the feature, its mode and variables), interactive, setting on.
`calls' collects the arguments the stand-in mode was called with."
  (declare (indent 0) (debug t))
  `(let ((nidhogg-watchdog-mode nil) (nidhogg-watchdog-log-directory nil) (nidhogg-watchdog-typing-commands nil)
         (nidhogg-watchdog-package-functions nil) (nidhogg-watchdog-record-functions nil) (drgnx-watchdog-mode nil) (drgnx-speed-watchdog t)
         (noninteractive nil) (calls nil))
     ;; a fresh notice model: a start defines the watchdog's notice source, which stays while drgnx runs
     (drgnx-notice-test-with-model
       (cl-letf (((symbol-function 'nidhogg-watchdog-mode)
                  (lambda (&optional arg) (push arg calls) (setq nidhogg-watchdog-mode (and arg (> arg 0)))))
                 ((symbol-function 'drgnx-watchdog-available-p) (lambda () t))
                 ((symbol-function 'drgnx-watchdog--wanted-p) (lambda () drgnx-speed-watchdog)))
         (unwind-protect (progn ,@body)
           (drgnx-watchdog-mode -1))))))

(ert-deftest drgnx-watchdog/on-by-default ()
  ;; the real watchdog: on where Nidhogg runs it (Linux); on a system where it is built in but refuses to start
  ;; (macOS) quietly off, with no error, no notice and no start error for the doctor
  (skip-unless (featurep 'nidhogg-watchdog))
  ;; a fresh notice model: the start defines the watchdog's notice source, which stays while drgnx runs
  (drgnx-notice-test-with-model
    (let ((noninteractive nil) (drgnx-speed-watchdog t) (drgnx-watchdog-start-error nil))
      (unwind-protect
          (progn (drgnx-watchdog-maybe-start)
                 (if (eq system-type 'gnu/linux)
                     (progn (should drgnx-watchdog-mode)
                            (should nidhogg-watchdog-mode))
                   (should-not drgnx-watchdog-mode)
                   (should-not nidhogg-watchdog-mode)
                   (should-not drgnx-watchdog-start-error)
                   (should-not (drgnx-notices))))
        (drgnx-watchdog-mode -1)))))

(ert-deftest drgnx-watchdog/quietly-off-where-it-cannot-run ()
  ;; macOS: the feature is built in, but Nidhogg's start signals "not on this platform yet".  Neither the start at
  ;; init, the setting's apply nor the mode itself calls it: the mode stays off, with no error, notice or prompt
  (drgnx-notice-test-with-model
    (let ((features (cons 'nidhogg-watchdog features)) (system-type 'darwin)
          (nidhogg-watchdog-mode nil) (drgnx-watchdog-mode nil) (drgnx-speed-watchdog t) (noninteractive nil)
          (drgnx-watchdog-start-error nil) (calls nil))
      (cl-letf (((symbol-function 'nidhogg-watchdog-mode)
                 (lambda (&optional arg) (push arg calls) (error "nidhogg-watchdog: not on this platform yet")))
                ((symbol-function 'drgnx-watchdog--wanted-p) (lambda () t)))
        (should-not (drgnx-watchdog-available-p))
        (drgnx-watchdog-maybe-start)
        (drgnx-watchdog--settings-apply)
        (drgnx-watchdog-mode 1)
        (should-not drgnx-watchdog-mode)
        (should-not calls)
        (should-not drgnx-watchdog-start-error)
        (should-not (drgnx-notices))))))

(ert-deftest drgnx-watchdog/settings ()
  (drgnx-watchdog-test--stubbed
    (drgnx-watchdog-maybe-start)
    (should drgnx-watchdog-mode)
    (should (equal nidhogg-watchdog-log-directory (expand-file-name "watchdog/" (drgnx-state-dir))))
    (dolist (c '(self-insert-command delete-backward-char delete-char backward-delete-char-untabify newline))
      (should (memq c nidhogg-watchdog-typing-commands)))
    (should-not (memq 'evil-ret nidhogg-watchdog-typing-commands))
    (should (memq #'drgnx-watchdog-package-of nidhogg-watchdog-package-functions))
    (should (equal calls '(1)))
    (cl-letf (((symbol-function 'featurep) (lambda (f &rest _) (eq f 'evil))))
      (should (memq 'evil-ret (drgnx-watchdog-typing-commands))))))

(ert-deftest drgnx-watchdog/package-of-names-a-string ()
  (should (equal (drgnx-watchdog-package-of (expand-file-name "core/drgnx-watchdog.el" drgnx-dir)) "drgnx"))
  (should-not (drgnx-watchdog-package-of nil)))

(ert-deftest drgnx-watchdog/off-in-batch ()
  (drgnx-watchdog-test--stubbed
    (let ((noninteractive t))
      (drgnx-watchdog-maybe-start))
    (should-not drgnx-watchdog-mode)
    (should-not calls)))

(ert-deftest drgnx-watchdog/setting-off ()
  (drgnx-watchdog-test--stubbed
    (let ((drgnx-speed-watchdog nil))
      (drgnx-watchdog-maybe-start))
    (should-not drgnx-watchdog-mode)
    (should-not calls)))

(ert-deftest drgnx-watchdog/without-the-flag ()
  (let ((drgnx-watchdog-mode nil) (noninteractive nil))
    (cl-letf (((symbol-function 'drgnx-watchdog-available-p) #'ignore))
      (drgnx-watchdog-maybe-start)
      (should-not drgnx-watchdog-mode))))

(ert-deftest drgnx-watchdog/teardown-turns-off ()
  (drgnx-watchdog-test--stubbed
    (drgnx-watchdog-maybe-start)
    (should nidhogg-watchdog-mode)
    (drgnx-watchdog-mode -1)
    (should-not nidhogg-watchdog-mode)
    (should-not (memq #'drgnx-watchdog-package-of nidhogg-watchdog-package-functions))
    (should (equal calls '(-1 1)))))

(ert-deftest drgnx-watchdog/census-hands-over ()
  "While the watchdog's mode is on, the census records nothing."
  (let ((nidhogg-watchdog-mode t) (drgnx-gc-census--ring nil) (drgnx-gc-census--start 0) (drgnx-gc-census--count 0)
        (drgnx-gc-census--dropped 0))
    (drgnx-gc-census--reset)
    (drgnx-gc-census--note)
    (should (zerop drgnx-gc-census--count))
    (setq nidhogg-watchdog-mode nil)
    (drgnx-gc-census--note)
    (should (= 1 drgnx-gc-census--count))))

(ert-deftest drgnx-watchdog/a-failed-start-is-contained ()
  ;; any error out of the start (another library claimed SIGURG, the thread would not start, …) must not escape init:
  ;; the mode is off, one notice says why, and the doctor can say it
  (drgnx-notice-test-with-model
    (drgnx-watchdog-test--stubbed
      (cl-letf (((symbol-function 'nidhogg-watchdog-mode) (lambda (&optional _) (error "Another library owns SIGURG"))))
        (drgnx-watchdog-mode 1))
      (should-not drgnx-watchdog-mode)
      (should (string-match-p "SIGURG" drgnx-watchdog-start-error))
      (should (= 1 (length (drgnx-notices))))
      (should (eq (plist-get (car (drgnx-notices)) :source) 'watchdog))
      (should-not (memq #'drgnx-watchdog-doctor-note nidhogg-watchdog-record-functions))
      (should (string-match-p "could not start: Another library owns SIGURG"
                              (nth 1 (drgnx-doctor-check 'freezes (list :watchdog (list :running nil :start-error drgnx-watchdog-start-error)))))))))

(ert-deftest drgnx-watchdog/the-record-hook-is-in-place-before-the-mode-starts ()
  ;; the mode turns hang files from an earlier session into records while it starts; the notice for a killed hang
  ;; reaches `drgnx-watchdog-doctor-note' only when that hook is already on
  (drgnx-notice-test-with-model
    (drgnx-watchdog-test--stubbed
      (let ((hooked nil))
        (cl-letf (((symbol-function 'nidhogg-watchdog-mode)
                   (lambda (&optional _) (setq hooked (memq #'drgnx-watchdog-doctor-note nidhogg-watchdog-record-functions)))))
          (drgnx-watchdog-mode 1))
        (should hooked)))))

(ert-deftest drgnx-watchdog/safe-mode-does-not-start-it ()
  ;; `drgnx safe' is how a user rules the new C code out: neither the start at init nor the setting's apply runs it
  (drgnx-watchdog-test--stubbed
    (let ((process-environment (cons "DRGNX_SAFE=1" process-environment)))
      (drgnx-watchdog-maybe-start)
      (drgnx-watchdog--settings-apply))
    (should-not drgnx-watchdog-mode)
    (should-not calls)))
