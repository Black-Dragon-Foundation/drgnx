;;; pkg-child-fixture.el --- loaded by a batch `drgnx sync' child of a package test: its sandbox and its hooks -*- lexical-binding: t -*-
;; A test runs the package CLI as bin/drgnx does (`emacs --batch -Q -L core -l drgnx-pkg -f drgnx-pkg-cli -- ARGS'), with
;; this file loaded before `drgnx-pkg-cli' (pkg-fixture.el's `drgnx-pkg-child-command').  Everything comes from the
;; environment the test gives the child:
;;   DRGNX_TEST_MODULES_DIR  where the modules are read from (the test's own, not drgnx's modules/)
;;   DRGNX_TEST_SHIPPED      the shipped lock (never the checkout's etc/drgnx.lock.eld)
;;   DRGNX_TEST_NATIVE       non-empty: compile to native code (when this Emacs can); else no native step at all
;;   DRGNX_TEST_ANNOUNCE     states the child announces and parks at (handshake-fixture.el), separated by spaces:
;;                           `wait' and `held' (the sync lock: `drgnx-pkg--after-lock-function'), `native' (the first
;;                           native compilation: `drgnx-pkg--step-function')
;;   DRGNX_TEST_STEP_LOG     a directory: each step of a `--progress' run is logged there (`drgnx-pkg-child--log')
;;   DRGNX_TEST_SIGNED_DIRS  non-empty: an archive that is a directory counts as one that signs, as a URL archive does
;;   DRGNX_TEST_GPG          the gpg program (`epg-gpg-program'), e.g. one that is not there(require 'drgnx-pkg)
(require 'drgnx-handshake-fixture (expand-file-name "handshake-fixture" (file-name-directory (or load-file-name (macroexp-file-name)))))

(defvar drgnx-pkg-child--announce (split-string (or (getenv "DRGNX_TEST_ANNOUNCE") "") " " t)
  "The states this child announces, each once.")

(defun drgnx-pkg-child--state (state)
  "Announce STATE (a symbol) and park when the test asked for it; each state once."
  (when (member (symbol-name state) drgnx-pkg-child--announce)
    (setq drgnx-pkg-child--announce (delete (symbol-name state) drgnx-pkg-child--announce))
    (drgnx-test-child-announce (symbol-name state))))

(defvar drgnx-pkg-child--steps 0 "The steps logged so far.")

(defun drgnx-pkg-child--log (step)
  "Log STEP into DRGNX_TEST_STEP_LOG, when set: NNN-STEP.json is the progress file as the step left it, NNN-STEP.plan
the plan file then (when there is one), NNN-STEP.elpa the package directories then and NNN-STEP.gens the generations."
  (when-let* ((dir (getenv "DRGNX_TEST_STEP_LOG")) (file (bound-and-true-p drgnx-pkg--progress-file)))
    (make-directory dir t)
    (let ((base (expand-file-name (format "%03d-%s" (setq drgnx-pkg-child--steps (1+ drgnx-pkg-child--steps)) step) dir))
          (elpa (drgnx-elpa-dir)) (gens (drgnx-generations-dir)))
      (copy-file file (concat base ".json") t)
      (when (file-exists-p (concat file ".plan.json")) (copy-file (concat file ".plan.json") (concat base ".plan") t))
      (with-temp-file (concat base ".elpa")
        (prin1 (and (file-directory-p elpa)
                    (sort (seq-filter (lambda (d) (file-directory-p (expand-file-name d elpa))) (directory-files elpa nil "\\`[^.]"))
                          #'string<))
               (current-buffer)))
      (with-temp-file (concat base ".gens")
        (prin1 (and (file-directory-p gens)
                    (sort (mapcar #'string-to-number (directory-files gens nil "\\`[0-9]+\\'")) #'<))
               (current-buffer))))))

(defun drgnx-pkg-child--step (step &rest _plist)
  "`drgnx-pkg--step-function' of the child: STEP is logged, and may be a state to announce."
  (drgnx-pkg-child--log step)
  (drgnx-pkg-child--state step))

(defun drgnx-pkg-child--modules-dir (args)
  "ARGS of `drgnx-pkg--module-specs' with the test's modules directory."
  (cons (getenv "DRGNX_TEST_MODULES_DIR") (cdr args)))

(when (getenv "DRGNX_TEST_MODULES_DIR")
  (advice-add 'drgnx-pkg--module-specs :filter-args #'drgnx-pkg-child--modules-dir))
(setq drgnx-pkg-shipped-lock (getenv "DRGNX_TEST_SHIPPED"))
(setq drgnx-pkg-native-compile (and (getenv "DRGNX_TEST_NATIVE") (fboundp 'native-comp-available-p) (native-comp-available-p)))
(when (getenv "DRGNX_TEST_SIGNED_DIRS")
  (advice-add 'drgnx-pkg--directory-archive-p :override #'ignore))
(when (getenv "DRGNX_TEST_GPG")
  (require 'epg-config)
  (setq epg-gpg-program (getenv "DRGNX_TEST_GPG")))
(setq drgnx-pkg--after-lock-function #'drgnx-pkg-child--state)
(setq drgnx-pkg--step-function #'drgnx-pkg-child--step)

(provide 'pkg-child-fixture)
;;; pkg-child-fixture.el ends here
