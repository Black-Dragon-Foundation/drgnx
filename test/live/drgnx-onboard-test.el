;;; drgnx-onboard-test.el --- live: onboarding in a fresh GUI session (config=drgnx) -*- lexical-binding: t -*-
;; The M6 exit: a fresh session with fixture repos completes onboarding non-interactively with no
;; failed step and no failing doctor check; the board file is not created; the Welcome
;; list opens in the editor; running it again changes nothing.
(require 'ert)
(require 'drgnx-ui)

(defun drgnx-live-ob--q (sess form)
  (car (read-from-string (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json (list :v (prin1-to-string %s)))" form) 120) :v))))

(defun drgnx-live-ob--repo (dir todo)
  (make-directory dir t)
  (let ((default-directory (file-name-as-directory dir)))
    (call-process "git" nil nil nil "init" "-q")
    (when todo (write-region todo nil "TODO.md" nil 'silent))))

(defun drgnx-live-ob--ratatoskr (root)
  "A Ratatoskr in ROOT for the session, as an install has one: a script that answers `doctor --json' with a healthy
report (the doctor fails without one); its name."
  (let ((bin (concat root "ratatoskr")))
    (with-temp-file bin
      (insert "#!/bin/sh\necho '{\"binary\":{\"path\":\"" bin "\",\"commit\":null,\"test_hooks\":false},\"running\":null,"
              "\"socket_dir\":{\"path\":\"/run/ratatoskr\",\"mode\":\"0700\",\"ok\":true},\"job_agents\":\"none\"}'\n"))
    (set-file-modes bin #o755)
    bin))

(ert-deftest drgnx-live/onboarding-in-a-fresh-session ()
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-onboard-live" t)))
         (ws (concat root "ws/"))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root "ui") process-environment)))
    (drgnx-live-ob--repo (concat ws "alpha") "- [ ] first thing\n- [ ] second thing\n")
    (drgnx-live-ob--repo (concat ws "beta") nil)
    (let* ((s (drgnx-ui-start "drgnx" "1400x800" 30)) (sess (drgnx-ui-own-session (plist-get s :name)))
           (run (format "(drgnx-onboard-run :non-interactive t :options '(:preset ide :roots (%S) :todos t))" ws)))
      (unwind-protect
          (progn
            (drgnx-live-ob--q sess (format "(progn (setq org-directory %S drgnx-projects-gryphn-file %S) (setenv \"DRGNX_RATATOSKR_BIN\" %S))"
                                           (concat root "org/") (concat root "no-gryphn.tsv") (drgnx-live-ob--ratatoskr root)))
            (let ((r (drgnx-live-ob--q sess run)))
              (should (equal (seq-filter (lambda (x) (eq (cadr x) 'fail)) r) nil))
              (should (memq 'projects (mapcar #'car r))))
            ;; non-interactive never writes the user's board
            (progn
              (should-not (file-exists-p (concat root "org/board.org")))
              ;; Welcome: in the editor, never an unrouted window
              (drgnx-live-ob--q sess "(progn (drgnx-onboard-welcome) t)")
              (drgnx-ui-measure sess nil)
              (should (equal (drgnx-live-ob--q sess "(list (buffer-name (window-buffer (selected-window))) (drgnx-signal-editor-window-p (selected-window)) (length drgnx-wb-unrouted))")
                             '("*drgnx Welcome*" t 0)))
              ;; again: nothing changes
              (drgnx-live-ob--q sess run)
              (should-not (file-exists-p (concat root "org/board.org")))))
        (drgnx-ui-stop (plist-get s :name))
        (delete-directory root t)))))

;;; drgnx-onboard-test.el ends here
