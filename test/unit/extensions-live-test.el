;;; extensions-live-test.el --- a running session takes new packages at once and keeps a consistent old set -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Each test runs two real children in one package sandbox (pkg-fixture.el), against an archive that is a local
;; directory: a drgnx session (live-session-fixture.el: it activates the packages as drgnx does at startup and
;; evaluates what the test sends, announcing `ready-N' after each form) and the package CLI as an Extensions job runs it,
;; with `--progress', parked at its plan step (pkg-child-fixture.el).  The test waits for each announcement, never a
;; fixed pause: the session repoints at the plan step, the child swaps, the session settles on the done object.
;; See docs/guide/extensions.md, "When a restart is needed".
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-pkg)
(load (expand-file-name "test/fixtures/pkg-fixture" drgnx-dir) nil t)

(declare-function drgnx-test-child-await "handshake-fixture")
(declare-function drgnx-test-child-go "handshake-fixture")
(declare-function drgnx-test-child-start "handshake-fixture")
(declare-function drgnx-test-wait-ended "wait-fixture")

;;;; The session child

(defun drgnx-extensions-live-test--session (root)
  "Start a drgnx session in ROOT's sandbox; it is parked once it has activated its packages."
  (require 'drgnx-handshake-fixture (expand-file-name "test/fixtures/handshake-fixture" drgnx-dir))
  (require 'drgnx-wait-fixture (expand-file-name "test/fixtures/wait-fixture" drgnx-dir))
  (let ((dir (concat root "session/")))
    (make-directory dir t)
    (let* ((process-environment (drgnx-pkg-child-env root (list (concat "DRGNX_TEST_SESSION_DIR=" dir))))
           (default-directory root)
           (p (drgnx-test-child-start
               :name "drgnx-live-session"
               :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                              "--eval" "(setq load-prefer-newer t)"
                              "-L" (expand-file-name "core" drgnx-dir) "-L" (expand-file-name "modules/tools" drgnx-dir)
                              "-l" (expand-file-name "test/fixtures/live-session-fixture.el" drgnx-dir)))))
      (set-process-filter p #'drgnx-pkg-child--filter)
      (process-put p :dir dir)
      (process-put p :n 0)
      (drgnx-test-child-await p "ready-0" :secs 120)
      p)))

(defun drgnx-extensions-live-test--eval (s form)
  "Evaluate FORM in the session S: its value.  An error there fails the test with its message."
  (let* ((n (1+ (process-get s :n))) (dir (process-get s :dir)))
    (with-temp-file (format "%sin-%d.el" dir n)
      (let ((print-length nil) (print-level nil)) (prin1 form (current-buffer))))
    (process-put s :n n)
    (drgnx-test-child-go s)
    (drgnx-test-child-await s (format "ready-%d" n) :secs 120)
    (let ((out (with-temp-buffer (insert-file-contents (format "%sout-%d.eld" dir n)) (read (current-buffer)))))
      (when (plist-member out :error)
        (ert-fail (list 'session-error (plist-get out :error) form)))
      (plist-get out :ok))))

(defun drgnx-extensions-live-test--end (s)
  "End the session S with `kill-emacs' and wait for it to exit."
  (let ((dir (process-get s :dir)) (n (1+ (process-get s :n))))
    (with-temp-file (format "%sin-%d.el" dir n) (prin1 '(kill-emacs 0) (current-buffer)))
    (drgnx-test-child-go s)
    (drgnx-test-wait-ended (list s) :secs 60 :what "the session to exit")))

(defun drgnx-extensions-live-test--json (file)
  (json-parse-string (drgnx-pkg-test--bytes file) :object-type 'plist :array-type 'list))

(defun drgnx-extensions-live-test--job (s root args &optional at-plan)
  "Run the package CLI with ARGS as an Extensions job does, with the session S taking part: the child parks at its
plan step, S repoints (`drgnx-extensions-live-plan' of the plan file), AT-PLAN (a function, or nil) runs, the child
goes on to its end and S settles (`drgnx-extensions-live-after' of the done object).  The child's exit status."
  (let ((progress (concat root "progress/p.json")))
    (dolist (f (list progress (concat progress ".plan.json"))) (when (file-exists-p f) (delete-file f)))
    (let ((p (drgnx-pkg-child-start root (append args (list "--progress" progress)) '("plan"))))
      (drgnx-test-child-await p "plan" :secs 300)
      (drgnx-extensions-live-test--eval
       s `(drgnx-extensions-live-plan ',(drgnx-extensions-live-test--json (concat progress ".plan.json"))))
      (when at-plan (funcall at-plan))
      (drgnx-test-child-go p)
      (drgnx-test-wait-ended (list p) :secs 600 :what "the job's sync to end")
      (drgnx-extensions-live-test--eval s `(drgnx-extensions-live-after ',(drgnx-extensions-live-test--json progress)))
      (process-exit-status p))))

(defun drgnx-extensions-live-test--entries (s root)
  "The session S's `load-path' entries under ROOT's data directory, relative to it (\"elpa/fa-1.0\"), sorted."
  (sort (mapcar (lambda (e) (file-relative-name e (concat root "data/")))
                (drgnx-extensions-live-test--eval
                 s `(seq-filter (lambda (e) (string-prefix-p ,(concat root "data/") (expand-file-name e))) load-path)))
        #'string<))

(defun drgnx-extensions-live-test--all-there (s root)
  "Whether every package directory of the session S's `load-path' exists."
  (drgnx-extensions-live-test--eval
   s `(seq-every-p #'file-directory-p
                   (seq-filter (lambda (e) (string-prefix-p ,(concat root "data/") (expand-file-name e))) load-path))))

(defun drgnx-extensions-live-test--pending (s)
  (drgnx-extensions-live-test--eval s '(drgnx-extensions-live-restart-pending)))

(defun drgnx-extensions-live-test--archive (root packages)
  (drgnx-pkg-test--archive (concat root "arch") packages))

(defun drgnx-extensions-live-test--sync (root &rest args)
  (should (eql (car (drgnx-pkg-child-run root args)) 0)))

(defun drgnx-extensions-live-test--by-hand (root name version)
  "A package NAME-VERSION installed by hand into ROOT's packages directory (no generation has it): its directory."
  (let ((dir (format "%sdata/elpa/%s-%s/" root name version)))
    (make-directory dir t)
    (write-region (format "(define-package \"%s\" \"%s\" \"by hand\" nil)\n" name version) nil
                  (format "%s%s-pkg.el" dir name) nil 'silent)
    (write-region (format "(defun %s-hello () %S)\n(provide '%s)\n" name version name) nil (format "%s%s.el" dir name) nil 'silent)
    (directory-file-name dir)))

(defun drgnx-extensions-live-test--activate-by-hand (s dir name)
  "Activate the package NAME in DIR in the session S, as an install the user ran there does."
  (drgnx-extensions-live-test--eval s `(progn (add-to-list 'load-path ,dir) (push ',name package-activated-list) t)))

(defun drgnx-extensions-live-test--in-use-file (root s)
  (format "%sstate/drgnx/elpa-in-use/%d.eld" root (process-id s)))

;;;; New packages and updates

(ert-deftest drgnx-extensions-live/a-new-package-works-at-once ()
  ;; handshake: the session parks after each form, the job's child at its plan step
  (drgnx-pkg-child-with root
    (drgnx-extensions-live-test--archive root '((fa "1.0") (fb "1.0" nil ";;;###autoload\n(defun fb-cmd () (interactive) 'fb-ran)")))
    (drgnx-pkg-child-want root)
    (drgnx-extensions-live-test--sync root "sync" "--add" "fa")
    (let ((s (drgnx-extensions-live-test--session root)))
      (should-not (drgnx-extensions-live-test--eval s '(fboundp 'fb-cmd)))
      (should (eql (drgnx-extensions-live-test--job s root '("sync" "--add" "fb")) 0))
      (should (equal (drgnx-extensions-live-test--eval s '(list (autoloadp (symbol-function 'fb-cmd))
                                                                (and (memq 'fb package-activated-list) t)))
                     '(t t)))
      (should (equal (drgnx-extensions-live-test--eval s '(list (require 'fb) (fb-cmd))) '(fb fb-ran)))
      (should-not (drgnx-extensions-live-test--pending s))
      (drgnx-extensions-live-test--end s))))

(ert-deftest drgnx-extensions-live/an-unloaded-update-loads-the-new-version ()
  ;; handshake: the session parks after each form, the job's child at its plan step
  (drgnx-pkg-child-with root
    (drgnx-extensions-live-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (drgnx-extensions-live-test--sync root "sync" "--add" "fa")
    (let ((s (drgnx-extensions-live-test--session root)))
      (drgnx-extensions-live-test--eval s '(drgnx-extensions-live-before '(fa)))   ; the view, before it starts the job
      (should (equal (drgnx-extensions-live-test--entries s root) '("generations/1/elpa/fa-1.0")))
      (drgnx-extensions-live-test--archive root '((fa "1.1")))
      (should (eql (drgnx-extensions-live-test--job s root '("upgrade")) 0))
      (should (equal (drgnx-extensions-live-test--eval s '(progn (require 'fa) (fa-hello))) "1.1"))
      (should (equal (drgnx-extensions-live-test--entries s root) '("elpa/fa-1.1")))
      (should-not (drgnx-extensions-live-test--pending s))
      (should-not (file-exists-p (drgnx-extensions-live-test--in-use-file root s)))
      (drgnx-extensions-live-test--end s))))

(ert-deftest drgnx-extensions-live/a-loaded-update-keeps-the-old-and-marks-restart ()
  ;; handshake: the session parks after each form, the job's child at its plan step
  (drgnx-pkg-child-with root
    (drgnx-extensions-live-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (drgnx-extensions-live-test--sync root "sync" "--add" "fa")
    (let ((s (drgnx-extensions-live-test--session root)))
      (should (equal (drgnx-extensions-live-test--eval s '(progn (require 'fa) (fa-hello))) "1.0"))
      (drgnx-extensions-live-test--archive root '((fa "1.1")))
      (should (eql (drgnx-extensions-live-test--job s root '("upgrade")) 0))
      (should (equal (drgnx-extensions-live-test--eval s '(fa-hello)) "1.0"))
      (should (equal (drgnx-extensions-live-test--entries s root) '("generations/2/elpa/fa-1.0")))   ; before upgrade
      (should (equal (drgnx-extensions-live-test--pending s) '((fa . "Restart to use 1.1 (1.0 is running)"))))
      (drgnx-extensions-live-test--end s))))

(ert-deftest drgnx-extensions-live/lazy-load-after-upgrade-finds-the-old-copy ()
  ;; handshake: the session parks after each form, the job's child at its plan step
  (drgnx-pkg-child-with root
    (drgnx-extensions-live-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (drgnx-extensions-live-test--sync root "sync" "--add" "fa")
    ;; a second file of fa 1.0, which fa 1.1 does not have
    (write-region "(defun fa-extra-version () \"1.0\")\n(provide 'fa-extra)\n" nil
                  (concat root "data/elpa/fa-1.0/fa-extra.el") nil 'silent)
    (let ((s (drgnx-extensions-live-test--session root)))
      (drgnx-extensions-live-test--eval s '(require 'fa))
      (drgnx-extensions-live-test--archive root '((fa "1.1")))
      (should (eql (drgnx-extensions-live-test--job s root '("upgrade")) 0))
      (should (equal (drgnx-pkg-child-elpa root) '("fa-1.1")))
      (should (equal (drgnx-extensions-live-test--eval s '(progn (require 'fa-extra) (fa-extra-version))) "1.0"))
      (should (string-prefix-p (concat root "data/generations/2/elpa/fa-1.0/")
                               (drgnx-extensions-live-test--eval s '(symbol-file 'fa-extra-version))))
      (drgnx-extensions-live-test--end s))))

(ert-deftest drgnx-extensions-live/rollback-and-restore-keep-the-set-loadable ()
  ;; handshake: the session parks after each form, each job's child at its plan step
  (drgnx-pkg-child-with root
    (drgnx-extensions-live-test--archive root '((fa "1.0") (fb "1.0")))
    (drgnx-pkg-child-want root)
    (drgnx-extensions-live-test--sync root "sync" "--add" "fa" "fb")      ; generation 1
    (let ((s (drgnx-extensions-live-test--session root)))
      (drgnx-extensions-live-test--eval s '(require 'fa))
      (drgnx-extensions-live-test--archive root '((fa "1.1") (fb "1.0")))
      (should (eql (drgnx-extensions-live-test--job s root '("upgrade")) 0))
      (should (drgnx-extensions-live-test--all-there s root))
      ;; the rollback brings fa 1.0 back to elpa/: the session points at it again, nothing to restart for
      (should (eql (drgnx-extensions-live-test--job s root '("rollback" "1")) 0))
      (should (drgnx-extensions-live-test--all-there s root))
      (should (equal (drgnx-extensions-live-test--entries s root) '("elpa/fa-1.0" "elpa/fb-1.0")))
      (should-not (drgnx-extensions-live-test--pending s))
      ;; an upgrade whose smoke test fails is restored: the session ends where it began
      (drgnx-extensions-live-test--archive root '((fa "2.0" nil "(error \"fa 2.0 is broken\")") (fb "1.0")))
      (should (eql (drgnx-extensions-live-test--job s root '("upgrade")) 1))
      (should (equal (drgnx-extensions-live-test--entries s root) '("elpa/fa-1.0" "elpa/fb-1.0")))
      ;; a removal: fb's directory goes, the session's copy is the generation's
      (should (eql (drgnx-extensions-live-test--job s root '("sync" "--remove" "fb")) 0))
      (should (drgnx-extensions-live-test--all-there s root))
      (should (equal (drgnx-extensions-live-test--eval s '(progn (require 'fb) (fb-hello))) "1.0"))
      (should (equal (drgnx-extensions-live-test--eval s '(fa-hello)) "1.0"))
      (drgnx-extensions-live-test--end s))))

(ert-deftest drgnx-extensions-live/the-in-use-file-names-the-generation ()
  ;; handshake: the session parks after each form; it exits on `kill-emacs' and the test waits for its end
  (drgnx-pkg-child-with root
    (drgnx-extensions-live-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (drgnx-extensions-live-test--sync root "sync" "--add" "fa")
    (let ((s (drgnx-extensions-live-test--session root)))
      (should-not (file-exists-p (drgnx-extensions-live-test--in-use-file root s)))
      (drgnx-extensions-live-test--eval s '(require 'fa))
      (drgnx-extensions-live-test--archive root '((fa "1.1")))
      (should (eql (drgnx-extensions-live-test--job s root '("upgrade")) 0))
      (let ((data (with-temp-buffer (insert-file-contents (drgnx-extensions-live-test--in-use-file root s))
                                    (read (current-buffer)))))
        (should (eql (plist-get data :pid) (process-id s)))
        (should (equal (plist-get data :generations) '(2))))
      (should (equal (drgnx-pkg-generations-in-use) '(2)))
      (drgnx-extensions-live-test--end s)
      (should-not (file-exists-p (drgnx-extensions-live-test--in-use-file root s))))))

(ert-deftest drgnx-extensions-live/a-gone-directory-marks-restart-now ()
  ;; handshake: the session parks after each form, the job's child at its plan step
  (drgnx-pkg-child-with root
    (drgnx-extensions-live-test--archive root '((fa "1.0") (fb "1.0")))
    (drgnx-pkg-child-want root)
    (drgnx-extensions-live-test--sync root "sync" "--add" "fa")
    (let* ((dir (drgnx-extensions-live-test--by-hand root "fh" "1.0"))
           (s (drgnx-extensions-live-test--session root)))
      (drgnx-extensions-live-test--activate-by-hand s dir 'fh)
      (delete-directory dir t)                                             ; by hand, too: no generation has it
      (should (eql (drgnx-extensions-live-test--job s root '("sync" "--add" "fb")) 0))
      (should (equal (drgnx-extensions-live-test--pending s) '((fh . "files of fh 1.0 are gone: restart drgnx"))))
      (drgnx-extensions-live-test--end s))))

(ert-deftest drgnx-extensions-live/a-waiting-module-runs-after-its-package ()
  ;; handshake: the session parks after each form, the job's child at its plan step
  (drgnx-pkg-child-with root
    (drgnx-extensions-live-test--archive root '((fa "1.0") (fb "1.0")))
    (drgnx-pkg-child-want root)
    (drgnx-extensions-live-test--sync root "sync" "--add" "fa")
    (let ((s (drgnx-extensions-live-test--session root)))
      (should (eq (drgnx-extensions-live-test--eval
                   s '(progn (require 'drgnx-modules)
                             (defvar drgnx-live-test-ran nil)
                             (defun drgnx-live-test-setup () (setq drgnx-live-test-ran t))
                             (drgnx-module-define 'test/wants-fb :packages '(fb) :setup #'drgnx-live-test-setup)
                             (drgnx-modules-run 'startup)
                             (plist-get (alist-get 'test/wants-fb (drgnx-modules-report)) :status)))
                  'missing-packages))
      (should (eql (drgnx-extensions-live-test--job s root '("sync" "--add" "fb")) 0))
      (should (equal (drgnx-extensions-live-test--eval
                      s '(list (plist-get (alist-get 'test/wants-fb (drgnx-modules-report)) :status) drgnx-live-test-ran))
                     '(ok t)))
      (drgnx-extensions-live-test--end s))))

(ert-deftest drgnx-extensions-live/the-lock-and-quickstart-never-see-an-old-version ()
  ;; handshake: the session parks after each form, the job's child at its plan step
  (drgnx-pkg-child-with root
    (drgnx-extensions-live-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (drgnx-extensions-live-test--sync root "sync" "--add" "fa")
    (let ((s (drgnx-extensions-live-test--session root)))
      (drgnx-extensions-live-test--eval s '(require 'fa))
      (drgnx-extensions-live-test--archive root '((fa "1.1")))
      (should (eql (drgnx-extensions-live-test--job s root '("upgrade")) 0))
      (should (equal (drgnx-extensions-live-test--eval s '(fa-hello)) "1.0"))   ; the session runs the old one
      (should (equal (drgnx-pkg-child-elpa root) '("fa-1.1")))
      (should (equal (plist-get (alist-get 'fa (drgnx-pkg-child-lock root)) :version) "1.1"))
      (let ((qs (with-temp-buffer (insert-file-contents (concat root "data/elpa/drgnx-quickstart.el")) (buffer-string))))
        (should (string-search "fa-1.1" qs))
        (should-not (string-search "fa-1.0" qs)))
      (drgnx-extensions-live-test--end s))))

;;;; The repoint rule

(ert-deftest drgnx-extensions-live/subdirectories-are-repointed-too ()
  ;; handshake: the session parks after each form, the job's child at its plan step, where the test reads load-path
  (drgnx-pkg-child-with root
    (drgnx-extensions-live-test--archive
     root '((fa "1.0" nil ";;;###autoload\n(add-to-list 'load-path (expand-file-name \"lisp\" (file-name-directory (or load-file-name default-directory))))")))
    (drgnx-pkg-child-want root)
    (drgnx-extensions-live-test--sync root "sync" "--add" "fa")
    (make-directory (concat root "data/elpa/fa-1.0/lisp") t)
    (write-region "(provide 'fa-sub)\n" nil (concat root "data/elpa/fa-1.0/lisp/fa-sub.el") nil 'silent)
    (let ((s (drgnx-extensions-live-test--session root)) (seen nil))
      (should (equal (sort (drgnx-extensions-live-test--entries s root) #'string<) '("elpa/fa-1.0" "elpa/fa-1.0/lisp")))
      (drgnx-extensions-live-test--eval s '(require 'fa))
      (drgnx-extensions-live-test--archive root '((fa "1.1")))
      (should (eql (drgnx-extensions-live-test--job
                    s root '("upgrade") (lambda () (setq seen (drgnx-extensions-live-test--entries s root))))
                   0))
      (should (equal (sort seen #'string<) '("generations/2/elpa/fa-1.0" "generations/2/elpa/fa-1.0/lisp")))
      (should (eq (drgnx-extensions-live-test--eval s '(require 'fa-sub)) 'fa-sub))
      (drgnx-extensions-live-test--end s))))

(ert-deftest drgnx-extensions-live/no-copy-no-repoint ()
  ;; handshake: the session parks after each form, the job's child at its plan step, where the test looks
  (drgnx-pkg-child-with root
    (drgnx-extensions-live-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (drgnx-extensions-live-test--sync root "sync" "--add" "fa")              ; generation 1, without fh
    (let* ((dir (drgnx-extensions-live-test--by-hand root "fh" "1.0"))
           (s (drgnx-extensions-live-test--session root))
           (seen nil) (marks nil))
      (drgnx-extensions-live-test--activate-by-hand s dir 'fh)
      (should (eql (drgnx-extensions-live-test--job
                    s root '("sync" "--prune")
                    (lambda () (setq seen (drgnx-extensions-live-test--entries s root)
                                     marks (drgnx-extensions-live-test--pending s))))
                   0))
      (should (member "elpa/fh-1.0" seen))
      (should-not (seq-some (lambda (e) (string-prefix-p "generations/" e)) seen))
      (should (string-match-p "restart drgnx" (alist-get 'fh marks)))
      (drgnx-extensions-live-test--end s))))

(ert-deftest drgnx-extensions-live/a-failed-job-points-back ()
  ;; handshake: the session parks after each form, the job's child at its plan step, where the test looks
  (drgnx-pkg-child-with root
    (drgnx-extensions-live-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (drgnx-extensions-live-test--sync root "sync" "--add" "fa")
    (let ((s (drgnx-extensions-live-test--session root)) (seen nil))
      (drgnx-extensions-live-test--archive root '((fa "2.0" nil "(error \"fa 2.0 is broken\")")))
      (should (eql (drgnx-extensions-live-test--job
                    s root '("upgrade") (lambda () (setq seen (drgnx-extensions-live-test--entries s root))))
                   1))
      (should (equal seen '("generations/2/elpa/fa-1.0")))
      (should (equal (drgnx-extensions-live-test--entries s root) '("elpa/fa-1.0")))
      (should-not (file-exists-p (drgnx-extensions-live-test--in-use-file root s)))
      (should-not (drgnx-extensions-live-test--pending s))
      (drgnx-extensions-live-test--end s))))

(ert-deftest drgnx-extensions-live/a-prune-keeps-the-set-loadable ()
  ;; handshake: the session parks after each form, each job's child at its plan step
  (drgnx-pkg-child-with root
    (drgnx-extensions-live-test--archive root '((fd "1.0") (fa "1.0" ((fd "1.0")))))
    (drgnx-pkg-child-want root)
    (drgnx-extensions-live-test--sync root "sync" "--add" "fa")
    (let ((s (drgnx-extensions-live-test--session root)))
      (drgnx-extensions-live-test--eval s '(require 'fa))
      (drgnx-extensions-live-test--archive root '((fd "1.0") (fa "1.1")))   ; fa no longer needs fd
      (should (eql (drgnx-extensions-live-test--job s root '("upgrade")) 0))
      (should (eql (drgnx-extensions-live-test--job s root '("sync" "--prune")) 0))
      (should (equal (drgnx-pkg-child-elpa root) '("fa-1.1")))
      (should (drgnx-extensions-live-test--all-there s root))
      (should (equal (drgnx-extensions-live-test--eval s '(progn (require 'fd) (fd-hello))) "1.0"))
      (drgnx-extensions-live-test--end s))))

(ert-deftest drgnx-extensions-live/remove-of-a-loaded-package-says-restart-to-finish ()
  ;; handshake: the session parks after each form, the job's child at its plan step
  (drgnx-pkg-child-with root
    (drgnx-extensions-live-test--archive root '((fa "1.0") (fb "1.0")))
    (drgnx-pkg-child-want root)
    (drgnx-extensions-live-test--sync root "sync" "--add" "fa" "fb")
    (let ((s (drgnx-extensions-live-test--session root)))
      (drgnx-extensions-live-test--eval s '(require 'fb))
      (should (eql (drgnx-extensions-live-test--job s root '("sync" "--remove" "fb")) 0))
      (should (equal (drgnx-pkg-child-elpa root) '("fa-1.0")))
      (should (equal (drgnx-extensions-live-test--pending s) '((fb . "Restart to finish removing"))))
      (should (equal (drgnx-extensions-live-test--eval s '(fb-hello)) "1.0"))
      (drgnx-extensions-live-test--end s))))

;;; extensions-live-test.el ends here
