;;; drgnx-keys-test.el --- live: key profiles in a drgnx session (config=drgnx) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ui)

(ert-deftest drgnx-live/key-profiles-switch-without-restart ()
  ;; Real key presses in a headless GUI session: C-o is VS Code's Open File by default; after
  ;; switching to the Emacs profile the same key is Emacs' open-line again.
  (let* ((root (make-temp-file "drgnx-keys" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (drgnx-ui-start "drgnx" nil 30))
         (sess (drgnx-ui-own-session (plist-get s :name)))
         (scratch-size "(progn (switch-to-buffer \"*scratch*\") (drgnx-uitest--json (list :size (buffer-size))))"))
    (unwind-protect
        (progn
          (drgnx-ui-measure sess (list (list :keys "C-o")))
          (should (string-prefix-p "Find file" (plist-get (drgnx-ui-call sess "(drgnx-uitest-api-boot-status)") :prompt)))
          (drgnx-ui-measure sess (list (list :keys "C-g")))
          (drgnx-ui-call sess "(progn (drgnx-keys-use '((emacs app editing window))) (drgnx-uitest--json (list :ok t)))")
          (let ((before (plist-get (drgnx-ui-call sess scratch-size) :size)))
            (drgnx-ui-measure sess (list (list :keys "C-o")))
            (should (eq (plist-get (drgnx-ui-call sess "(drgnx-uitest-api-boot-status)") :prompt) :null))
            (should (= (plist-get (drgnx-ui-call sess scratch-size) :size) (1+ before))))
          ;; The key sheet follows: Open File now shows C-x C-f, and the report names the stack.
          (should (equal (plist-get (drgnx-ui-call sess "(drgnx-uitest--json (list :key (drgnx-surfaces-key (drgnx-commands-get 'open-file))))") :key)
                         "C-x C-f"))
          (should (file-exists-p (expand-file-name "state/drgnx/keys-report.eld" (plist-get sess :run)))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))
