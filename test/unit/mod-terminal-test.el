;;; mod-terminal-test.el --- batch tests: New Terminal's environment and its eshell fallback -*- lexical-binding: t -*-
;; test-class: cond
(require 'ert)
(require 'drgnx)
(require 'server)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-terminal" drgnx-dir) nil t)

(ert-deftest drgnx-terminal/a-remote-folder-and-windows-get-eshell ()
  ;; a remote folder no terminal reaches gets eshell, and a notice naming its method
  (let ((opened nil) (started nil) (told nil))
    (cl-letf (((symbol-function 'drgnx-notify) (lambda (_s _sev text &rest _) (push text told)))
              ((symbol-function 'drgnx-terminal-new-eshell) (lambda (&optional dir) (push dir opened) nil))
              ((symbol-function 'drgnx-term-start) (lambda (dir) (push dir started) nil))
              ((symbol-function 'drgnx-term-usable-p) (lambda (dir) (not (file-remote-p dir))))
              ((symbol-function 'file-remote-p) (lambda (f &optional id &rest _)
                                                  (and (string-prefix-p "/ssh:" f) (if (eq id 'method) "ssh" "/ssh:h:")))))
      (drgnx-terminal-new "/ssh:h:/tmp/")
      (drgnx-terminal-new "/tmp/")
      (should (equal opened '("/ssh:h:/tmp/")))
      (should (equal started '("/tmp/")))
      (should (equal told '("No terminal reaches ssh folders: eshell instead"))))))

(ert-deftest drgnx-terminal/the-environment-names-this-server ()
  (let* ((dir (make-temp-file "drgnx-srv" t)) (server-socket-dir dir) (server-name "drgnx-term-test")
         (server-use-tcp nil) (server-process nil) (server-clients nil))
    (unwind-protect
        (progn
          (server-start)
          (let ((sock (expand-file-name "drgnx-term-test" dir)) (env (drgnx-terminal-environment)))
            (should (equal (drgnx-terminal-server-socket) sock))
            (should (= 4 (length env)))
            (dolist (e env) (should (string-search sock e)))
            (should (equal (car env) (concat "DRGNX_SERVER_NAME=" sock)))
            (dolist (var '("EDITOR=" "VISUAL=" "GIT_EDITOR="))
              (should (seq-find (lambda (e) (string-match-p (concat "\\`" var ".*emacsclient\\S-* -s ") e)) env)))
            (let ((git (seq-find (lambda (e) (string-prefix-p "GIT_EDITOR=" e)) env)))
              (should-not (string-match-p " -[ctn]\\b" git)))))
      (ignore-errors (server-force-delete))
      (delete-directory dir t))))

(provide 'mod-terminal-test)
;;; mod-terminal-test.el ends here
