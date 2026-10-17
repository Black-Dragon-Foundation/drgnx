;;; core-user-config-test.el --- batch tests: the user's config.el -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)

(defmacro drgnx-user-config-test--with (dir &rest body)
  "BODY with DRGNX_CONFIG_DIR a temp directory DIR."
  (declare (indent 1))
  `(let* ((,dir (make-temp-file "drgnx-cfg" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" ,dir) process-environment)))
     (unwind-protect (progn ,@body) (delete-directory ,dir t))))

(defvar drgnx-user-config-test--ran nil)

(ert-deftest drgnx-user-config/config-el-is-loaded-when-it-exists ()
  (drgnx-user-config-test--with dir
    (should (equal (drgnx-user-config-file) (expand-file-name "config.el" dir)))
    (setq drgnx-user-config-test--ran nil)
    (drgnx--load-user-config)                    ; none yet: nothing happens
    (should-not drgnx-user-config-test--ran)
    (write-region "(setq drgnx-user-config-test--ran 'yes)\n" nil (drgnx-user-config-file) nil 'silent)
    (drgnx--load-user-config)
    (should (eq drgnx-user-config-test--ran 'yes))))

(ert-deftest drgnx-user-config/an-error-is-said-never-raised ()
  (drgnx-user-config-test--with dir
    (write-region "(setq drgnx-user-config-test--ran 'before)\n(error \"kx-broken\")\n(setq drgnx-user-config-test--ran 'after)\n"
                  nil (drgnx-user-config-file) nil 'silent)
    (let (said)
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
        (drgnx--load-user-config))
      (should (eq drgnx-user-config-test--ran 'before))
      (should (seq-some (lambda (m) (string-match-p "config\\.el.*kx-broken" m)) said)))))

(ert-deftest drgnx-user-config/open-makes-it-from-a-template ()
  (drgnx-user-config-test--with dir
    (let ((process-environment (cons (concat "DRGNX_CONFIG_DIR=" dir "/sub") process-environment)))
      (unwind-protect
          (progn
            (drgnx-open-user-config)
            (should (equal (buffer-file-name) (drgnx-user-config-file)))
            (should (file-exists-p (drgnx-user-config-file)))
            (should (string-match-p "lexical-binding: t" (buffer-string)))
            (write-region "(setq x 1)\n" nil (drgnx-user-config-file) nil 'silent)
            (kill-buffer)
            (drgnx-open-user-config)                 ; an existing file is never overwritten
            (should (equal (buffer-string) "(setq x 1)\n")))
        (when (buffer-file-name) (kill-buffer))))))

(ert-deftest drgnx-user-config/the-command-is-registered ()
  (drgnx--core-commands)
  (should (drgnx-commands-get 'preferences-user-config)))
