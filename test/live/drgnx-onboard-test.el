;;; drgnx-onboard-test.el --- live: onboarding in a fresh GUI session (config=drgnx) -*- lexical-binding: t -*-
;; The M6 exit: a fresh session with fixture repos completes onboarding non-interactively with no
;; failed step and no failing doctor check; the board has the projects and their TODOs; the Welcome
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
            (drgnx-live-ob--q sess (format "(setq org-directory %S drgnx-projects-gryphn-file %S)"
                                           (concat root "org/") (concat root "no-gryphn.tsv")))
            (let ((r (drgnx-live-ob--q sess run)))
              (should (equal (seq-filter (lambda (x) (eq (cadr x) 'fail)) r) nil))
              (should (memq 'projects (mapcar #'car r))))
            (let ((board (with-temp-buffer (insert-file-contents (concat root "org/board.org")) (buffer-string))))
              (should (string-match-p "^\\* alpha" board))
              (should (string-match-p "^\\* beta" board))
              (should (string-match-p "^\\*\\* TODO second thing" board))
              ;; Welcome: in the editor, never an unrouted window
              (drgnx-live-ob--q sess "(progn (drgnx-onboard-welcome) t)")
              (drgnx-ui-measure sess nil)
              (should (equal (drgnx-live-ob--q sess "(list (buffer-name (window-buffer (selected-window))) (drgnx-signal-editor-window-p (selected-window)) (length drgnx-wb-unrouted))")
                             '("*drgnx Welcome*" t 0)))
              ;; again: nothing changes
              (drgnx-live-ob--q sess run)
              (should (equal (with-temp-buffer (insert-file-contents (concat root "org/board.org")) (buffer-string)) board))))
        (drgnx-ui-stop (plist-get s :name))
        (delete-directory root t)))))

;;; drgnx-onboard-test.el ends here
