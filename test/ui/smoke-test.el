;;; smoke-test.el --- GUI smoke tests (run by `drgnx test --ui') -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)

(ert-deftest drgnx-ui-smoke/frame-is-visible-and-graphical ()
  (let ((f (drgnx-uitest-root-frame)))
    (should (frame-visible-p f))
    (should (memq (window-system f) '(pgtk x)))
    (should (> (frame-pixel-width f) 640))))

(ert-deftest drgnx-ui-smoke/root-has-the-scale ()
  ;; DRGNX_UI_SESSION_SCALES is the session's scales (set by the harness; empty at scale 1).  GTK 3 reports the
  ;; ceiling of a fractional scale and a monitor geometry of (WxH / S) * ceiling.
  (let* ((s (string-to-number (or (car (split-string (or (getenv "DRGNX_UI_SESSION_SCALES") "") " " t)) "1")))
         (f (drgnx-uitest-root-frame)))
    (should (= (frame-scale-factor f) (ceiling s)))
    (when (/= s (ceiling s))
      (let ((geo (alist-get 'geometry (car (display-monitor-attributes-list f))))
            (size (mapcar #'string-to-number (split-string (getenv "DRGNX_UI_SESSION_SIZE") "x"))))
        (should (<= (abs (- (nth 2 geo) (* (ceiling s) (round (/ (nth 0 size) s))))) (ceiling s)))))))

(ert-deftest drgnx-ui-smoke/session-is-isolated ()
  (should (string-prefix-p (getenv "DRGNX_UI_RUN") (expand-file-name user-emacs-directory)))
  (should (null auth-sources))
  (should (equal server-name (getenv "DRGNX_UI_NAME")))
  (should-error (url-retrieve-synchronously "https://example.org")))

(ert-deftest drgnx-uitest/a-session-runs-at-drgnx-gc-settings ()
  ;; HARNESS-GC-1: the minimal configuration loaded neither init/early-init.el's GC lines nor `drgnx-gc-setup'.
  (should (featurep 'drgnx-gc))
  (should (= gc-cons-threshold drgnx-gc-cons-threshold))
  (should (<= gc-cons-percentage 0.1))
  (should drgnx-gc-mode)
  (should (drgnx-timer-active-p 'gc-idle)))
