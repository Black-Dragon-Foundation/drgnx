;;; doctor-security-test.el --- batch tests: the doctor's security check -*- lexical-binding: t -*-
;; The check reads the facts plist (:version, :trust-guards = `drgnx-trust-guards-status'); nothing here touches
;; the machine except the one test that gathers the real guard facts (the mode is put back as it was).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-doctor)
(require 'drgnx-trust)

(defconst drgnx-doctor-security-test--on
  '(:mode t :tramp t :flymake drgnx :eglot-safe t :shorthands t :compile t :ffap t
          :enable-remote-dir-locals nil :auto-revert-remote-files nil
          :remote-file-name-inhibit-auto-save-visited t :trusted ("~/x/"))
  "A guards status with every guard on.")

(defun drgnx-doctor-security-test--check (version &rest guards)
  "The `security' result for VERSION; GUARDS (a plist) are changes to the all-on status, `none' leaves it out."
  (let ((status (if (eq (car guards) 'none) 'none
                  (let ((s (copy-sequence drgnx-doctor-security-test--on)))
                    (while guards (setq s (plist-put s (pop guards) (pop guards)))) s))))
    (drgnx-doctor-check 'security (append (list :version version)
                                          (unless (eq status 'none) (list :trust-guards status))))))

(ert-deftest drgnx-doctor-security/31.1-names-its-issues-and-says-shorthands-are-partly-fixed ()
  (let* ((r (drgnx-doctor-security-test--check "31.1")) (text (nth 1 r)))
    (dolist (id '("CVE-2026-108976" "CVE-2026-96442" "CVE-2026-96269"))
      (should (string-search id text)))
    (should (string-search "partly" text))
    ))

(ert-deftest drgnx-doctor-security/31.2-has-none ()
  (let ((r (drgnx-doctor-security-test--check "31.2")))
    (should (eq (car r) 'ok))
    (should (string-search "no known issues" (nth 1 r)))
    (should-not (string-search "CVE-" (nth 1 r)))))

(ert-deftest drgnx-doctor-security/guards-on-is-ok-and-guards-off-is-warn ()
  (dolist (v '("31.1" "31.2"))
    (let ((r (drgnx-doctor-security-test--check v)))
      (should (eq (car r) 'ok))
      (should (string-search "guards are on" (nth 1 r)))))
  (should (string-search "CVE-2026-96442" (nth 1 (drgnx-doctor-security-test--check "31.1"))))   ; still named while ok
  (dolist (case '((:mode nil "drgnx-trust-mode is off") (:tramp nil "TRAMP name guard")
                  (:flymake nil "Flymake trust check") (:eglot-safe nil "eglot is not marked safe")
                  (:shorthands nil "shorthands guard") (:compile nil "compile-output guard")
                  (:ffap nil "ffap guard") (:enable-remote-dir-locals t "enable-remote-dir-locals is on")
                  (:auto-revert-remote-files t "auto-revert-remote-files is on")
                  (:remote-file-name-inhibit-auto-save-visited nil "auto-save guard")))
    (dolist (v '("31.1" "31.2"))
      (let ((r (drgnx-doctor-security-test--check v (nth 0 case) (nth 1 case))))
        (should (eq (car r) 'warn))
        ;; the guard is named; checked on 31.2, where no issue text can say the same word
        (when (equal v "31.2") (should (string-search (nth 2 case) (nth 1 r))))
        (should (string-search "security.md" (nth 2 r)))))))

(ert-deftest drgnx-doctor-security/flymake-checked-by-emacs-or-on-load-is-fine ()
  (dolist (f '(emacs drgnx on-load))
    (should (eq (car (drgnx-doctor-security-test--check "31.1" :flymake f)) 'ok))))

(ert-deftest drgnx-doctor-security/no-guard-facts-is-judged-by-version-alone ()
  (should (eq (car (drgnx-doctor-security-test--check "31.1" 'none)) 'warn))
  (should (string-search "31.2" (nth 1 (drgnx-doctor-security-test--check "31.1" 'none))))
  (should (eq (car (drgnx-doctor-security-test--check "31.2" 'none)) 'ok)))

(ert-deftest drgnx-doctor-security/facts-hold-the-guards-this-emacs-gets ()
  ;; A bare batch doctor (drgnx's startup has not run: no commands registered) has the mode off: the facts switch it
  ;; on, read the status, and put it back, so that the answer is about the guards drgnx's startup installs.
  (let ((was drgnx-trust-mode) (drgnx-commands--table (make-hash-table :test #'eq)) (noninteractive t))
    (unwind-protect
        (progn
          (drgnx-trust-mode -1)
          (let ((f (cl-letf (((symbol-function 'drgnx-doctor--search) #'ignore)) (drgnx-doctor-facts))))
            (should (plist-get (plist-get f :trust-guards) :mode))
            (should (plist-get (plist-get f :trust-guards) :tramp))
            (should-not drgnx-trust-mode)
            (should (eq (car (drgnx-doctor-check 'security f)) 'ok))))
      (drgnx-trust-mode (if was 1 -1)))))

(ert-deftest drgnx-doctor-security/batch-with-the-mode-on-is-never-toggled ()
  (let ((was drgnx-trust-mode) (noninteractive t) (calls 0))
    (unwind-protect
        (progn
          (drgnx-trust-mode 1)
          (cl-letf* ((orig (symbol-function 'drgnx-trust-mode))
                     ((symbol-function 'drgnx-trust-mode) (lambda (&rest a) (cl-incf calls) (apply orig a))))
            (should (plist-get (drgnx-doctor--trust-guards) :mode)))
          (should (= calls 0))
          (should drgnx-trust-mode))
      (drgnx-trust-mode (if was 1 -1)))))

(ert-deftest drgnx-doctor-security/batch-after-startup-with-the-mode-off-warns ()
  ;; drgnx's startup ran (its commands are registered) and the mode is off: someone turned it off
  (let ((was drgnx-trust-mode) (noninteractive t) (drgnx-commands--table (make-hash-table :test #'eq)))
    (puthash 'trust-folder t drgnx-commands--table)
    (unwind-protect
        (progn
          (drgnx-trust-mode -1)
          (let ((g (drgnx-doctor--trust-guards)))
            (should-not (plist-get g :mode))
            (should-not drgnx-trust-mode)   ; read, not switched on
            (let ((r (drgnx-doctor-check 'security (list :version "31.2" :trust-guards g))))
              (should (eq (car r) 'warn))
              (should (string-search "drgnx-trust-mode is off" (nth 1 r))))))
      (drgnx-trust-mode (if was 1 -1)))))

(ert-deftest drgnx-doctor-security/flymake-on-load-is-not-verified-in-a-batch-check ()
  (should (string-search "not verified in a batch check" (nth 1 (drgnx-doctor-security-test--check "31.2" :flymake 'on-load))))
  (dolist (f '(emacs drgnx))
    (should-not (string-search "not verified" (nth 1 (drgnx-doctor-security-test--check "31.2" :flymake f))))))

(ert-deftest drgnx-doctor-security/the-detail-is-short ()
  (let ((r (drgnx-doctor-security-test--check "31.1")))
    (should (string-search "3 known issues" (nth 1 r)))
    (should (string-search "security.md" (nth 1 r)))
    (should (< (length (nth 1 r)) 250))))

(ert-deftest drgnx-doctor-security/live-mode-is-read-not-switched ()
  ;; interactively (`noninteractive' nil) a mode the user turned off is reported off, and stays off
  (let ((was drgnx-trust-mode) (noninteractive nil))
    (unwind-protect
        (progn
          (drgnx-trust-mode -1)
          (should-not (plist-get (drgnx-doctor--trust-guards) :mode))
          (should-not drgnx-trust-mode))
      (drgnx-trust-mode (if was 1 -1)))))

(ert-deftest drgnx-doctor-security/a-failing-probe-is-a-warning-not-a-crash ()
  (cl-letf (((symbol-function 'drgnx-trust-guards-status) (lambda () (error "boom"))))
    (let ((f (list :version "31.2" :trust-guards (drgnx-doctor--trust-guards))))
      (should (eq (car (drgnx-doctor-check 'security f)) 'warn))
      (should (string-search "boom" (nth 1 (drgnx-doctor-check 'security f)))))))

;;; doctor-security-test.el ends here
