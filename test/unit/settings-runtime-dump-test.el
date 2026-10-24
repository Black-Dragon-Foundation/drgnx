;;; settings-runtime-dump-test.el --- batch tests: the editor's side of the hub's settings conformance -*- lexical-binding: t -*-
;; test/conformance/settings/lisp-dump.json is what the editor reads of the shipped runtime defaults and of a
;; providers fixture, and which settings it declares `:runtime'; the hub's tests
;; (runtime/crates/drgnx-ratatoskr/src/settings/conformance.rs) hold the hub to it.  Here a child `emacs --batch -Q'
;; runs the command dump.el's header gives and must write what is committed (no drift on the editor's side).
(require 'ert)
(require 'json)
(require 'drgnx-paths)

(defun drgnx-settings-runtime-dump-test--command ()
  "The command test/conformance/settings/dump.el's header gives, on one line."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/conformance/settings/dump.el" drgnx-dir))
    (goto-char (point-min))
    (unless (re-search-forward "^;;   \\(emacs --batch -Q .*\\\\\\)\n;;     \\(.*\\)$" nil t)
      (ert-fail "dump.el's header does not give its command"))
    (concat (string-remove-suffix "\\" (match-string 1)) " " (match-string 2))))

(defun drgnx-settings-runtime-dump-test--parse (file)
  "FILE's JSON as alists and lists."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
    (json-parse-buffer :object-type 'alist :array-type 'list)))

(ert-deftest drgnx-settings-runtime-dump/committed-dump-is-current ()
  (let* ((tmp (make-temp-file "drgnx-settings-dump" nil ".json"))
         (home (make-temp-file "drgnx-settings-dump-home" t))
         (documented (drgnx-settings-runtime-dump-test--command))
         (command (replace-regexp-in-string "test/conformance/settings/lisp-dump\\.json" tmp documented t t))
         (default-directory drgnx-dir)
         (process-environment
          (append (list (concat "HOME=" home) (concat "XDG_CONFIG_HOME=" home "/config")
                        (concat "XDG_STATE_HOME=" home "/state") (concat "XDG_DATA_HOME=" home "/data")
                        (concat "XDG_CACHE_HOME=" home "/cache") (concat "DRGNX_CONFIG_DIR=" home "/config/drgnx"))
                  process-environment)))
    (should (string-search tmp command))
    (unwind-protect
        (let ((out (generate-new-buffer " *dump*")))
          (unwind-protect
              (unless (eql 0 (call-process "sh" nil out nil "-c"
                                           (replace-regexp-in-string
                                            "\\`emacs --batch -Q"
                                            (concat (shell-quote-argument (drgnx-emacs-program))
                                                    " --batch -Q --eval '(setq load-prefer-newer t)'")
                                            command t t)))
                (ert-fail (format "dump.el failed:\n%s" (with-current-buffer out (buffer-string)))))
            (kill-buffer out))
          (let ((fresh (drgnx-settings-runtime-dump-test--parse tmp))
                (committed (drgnx-settings-runtime-dump-test--parse
                            (expand-file-name "test/conformance/settings/lisp-dump.json" drgnx-dir))))
            (should (assq 'defaults fresh))
            (should (= (length (alist-get 'runtime fresh)) 20))
            (unless (equal fresh committed)
              (ert-fail (format "test/conformance/settings/lisp-dump.json is out of date; regenerate it with:\n  %s"
                                documented)))))
      (delete-file tmp)
      (delete-directory home t))))

;;; settings-runtime-dump-test.el ends here
