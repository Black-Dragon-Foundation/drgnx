;;; onboard-next-test.el --- batch tests: the Welcome's Next button and `n' (M12a-61) -*- lexical-binding: t -*-
;; State lives in a temp dir: never ~/.local/state.
(require 'ert)
(require 'button)
(require 'drgnx-onboard)

(defmacro drgnx-onboard-next-test--with (&rest body)
  "BODY with three steps A, B, C (none runs anything) and a temp state dir."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-onboard-next" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config")
                                             (concat "XDG_STATE_HOME=" root "state")
                                             (concat "DRGNX_DATA_DIR=" root "data"))
                                       process-environment))
          (drgnx-onboard--steps nil)
          (drgnx-onboard--progress nil))
     (dolist (s '((a "A" 10) (b "B" 20) (c "C" 30)))
       (drgnx-onboard-define-step (car s) :title (nth 1 s) :order (nth 2 s) :doc "doc"
                                  :run (lambda (_) '(ok "ran"))))
     (unwind-protect
         (save-window-excursion
           (unwind-protect (progn ,@body)
             (when (get-buffer "*drgnx Welcome*") (kill-buffer "*drgnx Welcome*"))))
       (delete-directory root t))))

(defun drgnx-onboard-next-test--row (id)
  "The Welcome's text on step ID's row."
  (with-current-buffer "*drgnx Welcome*"
    (save-excursion
      (drgnx-onboard--goto-step id)
      (buffer-substring (line-beginning-position) (line-end-position)))))

(defun drgnx-onboard-next-test--message (thunk)
  "What THUNK says with `message'."
  (let (said)
    (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
      (funcall thunk))
    said))

(ert-deftest drgnx-onboard-next/a-finished-step-ends-with-a-next-button-to-the-next-not-done ()
  (drgnx-onboard-next-test--with
    (drgnx-onboard--record 'a 'ok "a done")
    (drgnx-onboard-welcome)
    (let ((row (drgnx-onboard-next-test--row 'a)))
      (should (string-suffix-p "Next: B" row))
      (should (string-match "a done" row)))
    ;; a step not run has no result, so no button
    (should-not (string-match-p "Next:" (drgnx-onboard-next-test--row 'b)))
    ;; pressing the button moves to step B; it runs nothing
    (with-current-buffer "*drgnx Welcome*"
      (drgnx-onboard--goto-step 'a)
      (end-of-line)
      (backward-char)
      (should (button-at (point)))
      (push-button)
      (should (eq (tabulated-list-get-id) 'b))
      (should-not (alist-get 'b (drgnx-onboard-state))))))

(ert-deftest drgnx-onboard-next/the-button-skips-steps-done-and-names-failed-ones ()
  (drgnx-onboard-next-test--with
    (drgnx-onboard--record 'a 'ok "a done")
    (drgnx-onboard--record 'b 'info "b done")
    (drgnx-onboard-welcome)
    (should (string-suffix-p "Next: C" (drgnx-onboard-next-test--row 'a)))
    (should (string-suffix-p "Next: C" (drgnx-onboard-next-test--row 'b)))
    ;; a failed or warned step is not done: it stays the next one
    (drgnx-onboard--record 'b 'fail "b broke")
    (drgnx-onboard--refresh-welcome)
    (should (string-suffix-p "Next: B" (drgnx-onboard-next-test--row 'a)))
    (drgnx-onboard--record 'b 'warn "b warns")
    (drgnx-onboard--refresh-welcome)
    (should (string-suffix-p "Next: B" (drgnx-onboard-next-test--row 'a)))))

(ert-deftest drgnx-onboard-next/n-moves-to-the-next-step-not-done-and-says-all-done-at-the-end ()
  (drgnx-onboard-next-test--with
    (drgnx-onboard--record 'a 'ok "a done")
    (drgnx-onboard--record 'b 'ok "b done")
    (drgnx-onboard-welcome)
    (with-current-buffer "*drgnx Welcome*"
      (should (eq (lookup-key drgnx-onboard-mode-map "n") #'drgnx-onboard-next-step))
      (drgnx-onboard--goto-step 'a)
      (drgnx-onboard-next-step)
      (should (eq (tabulated-list-get-id) 'c))          ; B is done: on to C
      (should-not (alist-get 'c (drgnx-onboard-state))) ; moving runs nothing
      ;; C is the last and the only one left: n has nowhere else to go
      (should (string-match-p "only" (drgnx-onboard-next-test--message #'drgnx-onboard-next-step)))
      (should (eq (tabulated-list-get-id) 'c))
      (drgnx-onboard--record 'c 'ok "c done")
      (drgnx-onboard--refresh-welcome)
      (should (string-match-p "all done" (drgnx-onboard-next-test--message #'drgnx-onboard-next-step)))
      (should (eq (tabulated-list-get-id) 'c)))
    (should-not (string-match-p "Next:" (drgnx-onboard-next-test--row 'c)))))

(ert-deftest drgnx-onboard-next/n-on-the-last-step-goes-back-to-one-left-undone ()
  (drgnx-onboard-next-test--with
    (drgnx-onboard--record 'a 'fail "a broke")
    (drgnx-onboard--record 'c 'ok "c done")
    (drgnx-onboard-welcome)
    (with-current-buffer "*drgnx Welcome*"
      (drgnx-onboard--goto-step 'c)
      (drgnx-onboard-next-step)
      (should (eq (tabulated-list-get-id) 'a)))))

;;; onboard-next-test.el ends here
