;;; drgnx-perf-test.el --- live: the latency probe sees redisplay work -*- lexical-binding: t -*-
;; Redisplay work of 30 ms (a pre-redisplay function) must show in input latency: the probe measures key →
;; screen, not only the command.
(require 'ert)
(require 'drgnx-ui)

(ert-deftest drgnx-live/latency-includes-redisplay-work ()
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-perf-live" t)))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root "ui") process-environment))
         (s (drgnx-ui-start "drgnx" "1400x800" 30)) (sess (drgnx-ui-own-session (plist-get s :name))))
    (unwind-protect
        (progn
          (drgnx-ui-call sess (format "(progn (require 'drgnx-perf) (find-file %S)
                                         (let ((buf (current-buffer)))
                                           (add-hook 'pre-redisplay-functions (lambda (w) (when (eq (window-buffer w) buf) (sleep-for 0.03)))))
                                         (drgnx-uitest--json (list :ok t)))" (concat root "f.txt")))
          ;; under load the hook can run before f.txt is in the selected window, and the probe would count nothing:
          ;; show it there and wait for a redisplay that has run with it
          (let ((deadline (+ (float-time) 15)) shown)
            (while (and (not shown) (< (float-time) deadline))
              (setq shown (eq t (plist-get
                                 (drgnx-ui-call sess (format "(progn (switch-to-buffer (get-file-buffer %S)) (redisplay t)
                                                                (drgnx-uitest--json (list :ok (if (eq (window-buffer (selected-window))
                                                                                                      (get-file-buffer %S))
                                                                                                  t :false))))"
                                                             (concat root "f.txt") (concat root "f.txt")))
                                 :ok)))
              (unless shown (sleep-for 0.2)))
            (should shown))
          (drgnx-ui-measure sess nil)
          (drgnx-ui-call sess "(progn (drgnx-perf-begin) (drgnx-uitest--json (list :ok t)))")
          (drgnx-ui-measure sess (list (list :type "abcdef")))
          (let ((r (drgnx-ui-call sess "(drgnx-uitest--json (drgnx-perf-end))")))
            (should (>= (plist-get (plist-get r :input) :p50) 30))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))

;;; drgnx-perf-test.el ends here
