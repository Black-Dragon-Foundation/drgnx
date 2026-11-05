;;; hub-daemon-start-test.el --- live: a real drgnx daemon brings the hub up and the nightly backup runs -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The unit tests stub `drgnx-hub--ensure-running'.  Here a daemon session asks for a hub as it does after startup
;; (`drgnx-hub-ask-at-daemon-start': a timer, then the real `ratatoskr ensure'), no key handed over; the hub opens the
;; store, finds no copy for today (the session's local time is set past 03:00), and makes the nightly one.  Then the
;; key-less hub idles for a few seconds and its CPU and resident memory are read from /proc.
(require 'ert)
(require 'drgnx-ui)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-ui-repo-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-ui-repo-dir) nil t)

(defun drgnx-live-hds--q (sess form)
  (car (read-from-string (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json (list :v (prin1-to-string %s)))" form) 60) :v))))

(defun drgnx-live-hds--hub-pid ()
  "The pid of the `ratatoskr serve' process, or nil."
  (seq-find (lambda (pid)
              (let ((a (process-attributes pid)))
                (and (equal (alist-get 'comm a) "ratatoskr")
                     (string-search " serve" (or (alist-get 'args a) "")))))
            (list-system-processes)))

(defun drgnx-live-hds--cpu-ticks (pid)
  "User plus system clock ticks of PID (fields 14 and 15 of /proc/PID/stat, counted after the command's closing paren)."
  (with-temp-buffer
    (insert-file-contents (format "/proc/%d/stat" pid))
    (let ((f (split-string (substring (buffer-string) (1+ (string-search ")" (buffer-string)))))))
      (+ (string-to-number (nth 11 f)) (string-to-number (nth 12 f))))))

(defun drgnx-live-hds--rss-kb (pid)
  (with-temp-buffer
    (insert-file-contents (format "/proc/%d/status" pid))
    (re-search-forward "^VmRSS:[ \t]+\\([0-9]+\\)")
    (string-to-number (match-string 1))))

(ert-deftest drgnx-live/a-daemon-brings-the-hub-up-and-the-nightly-copy-runs ()
  (let* ((rbin (or (drgnx-test-ratatoskr-bin) (ert-skip "DRGNX_RATATOSKR_BIN is not set")))
         (root (file-name-as-directory (make-temp-file "drgnx-hub-daemon" t)))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root "ui") process-environment))
         ;; local noon, whatever the machine's zone: the catch-up rule makes a copy due at once
         (tz (let ((east (- 12 (string-to-number (format-time-string "%H" nil t)))))
               (format "LT%+d" (- (if (> east 12) (- east 24) east)))))
         (s nil) (sess nil))
    (unwind-protect
        (progn
          (setq s (drgnx-ui-start "drgnx" "1400x800" 30 t) sess (drgnx-ui-own-session (plist-get s :name)))
          (should (drgnx-live-hds--q sess (format "(progn (setenv \"DRGNX_NO_HUB_START\") (setenv \"TZ\" %S)
                                                    (setenv \"DRGNX_RATATOSKR_BIN\" %S)
                                                    (setenv \"DRGNX_HUB_PARENT_PID\" %S) (daemonp))"
                                                  tz rbin (number-to-string (emacs-pid)))))
          (should-not (drgnx-live-hds--q sess "(drgnx-hub-running-p)"))
          (drgnx-live-hds--q sess "(progn (drgnx-hub-ask-at-daemon-start) nil)")
          (drgnx-test-wait (lambda () (drgnx-live-hds--q sess "(drgnx-hub-running-p)")) :secs 60 :what "the hub comes up")
          (let ((dir (drgnx-live-hds--q sess "(expand-file-name \"backup\" (drgnx-data-dir))")))
            (drgnx-test-wait (lambda () (and (file-directory-p dir) (directory-files dir nil "\\`work-.*\\.db\\'")))
                             :secs 60 :what "the nightly copy is made"))
          (let* ((pid (or (drgnx-live-hds--hub-pid) (ert-fail "no ratatoskr serve process")))
                 (window 20) (t0 (drgnx-live-hds--cpu-ticks pid)))
            (drgnx-test-pause window "a key-less hub does no work")
            (let* ((ticks (- (drgnx-live-hds--cpu-ticks pid) t0))
                   (cpu (/ (* 100.0 (/ ticks (float (string-to-number (shell-command-to-string "getconf CLK_TCK"))))) window)))
              (message "hub idle: cpu %.2f%% over %d s, rss %d kB" cpu window (drgnx-live-hds--rss-kb pid))
              (should (< cpu 2.0)))))
      (when s (drgnx-ui-stop (plist-get s :name)))
      (delete-directory root t))))

;;; hub-daemon-start-test.el ends here
