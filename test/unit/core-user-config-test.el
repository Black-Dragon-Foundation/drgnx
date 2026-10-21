;;; core-user-config-test.el --- batch tests: the user's config.el -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-file)
(require 'drgnx)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)

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
    (drgnx-notice-test-with-model
      (drgnx--load-user-config)
      (should (eq drgnx-user-config-test--ran 'before))
      (should (seq-some (lambda (n) (and (eq (plist-get n :source) 'config)
                                         (string-match-p "config\\.el.*kx-broken" (plist-get n :text))))
                        (drgnx-notices))))))

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

(ert-deftest drgnx-user-config/the-config-template-is-written-once ()
  (drgnx-user-config-test--with dir
    (let ((calls nil) (orig (symbol-function 'drgnx-file-write-text)))
      (unwind-protect
          (cl-letf (((symbol-function 'drgnx-file-write-text)
                     (lambda (file text &rest args) (push file calls) (apply orig file text args))))
            (drgnx-open-user-config)
            (should (equal calls (list (drgnx-user-config-file))))
            (should (string-match-p "lexical-binding: t" (buffer-string)))
            (kill-buffer)
            (drgnx-open-user-config)             ; it exists now: not written again
            (should (= (length calls) 1))
            (kill-buffer)
            (write-region "(setq x 1)\n" nil (drgnx-user-config-file) nil 'silent)
            (drgnx-open-user-config)             ; the user's own text is never replaced
            (should (= (length calls) 1))
            (should (equal (buffer-string) "(setq x 1)\n")))
        (when (buffer-file-name) (kill-buffer))))))


(ert-deftest drgnx-user-config/the-command-is-registered ()
  (drgnx--core-commands)
  (should (drgnx-commands-get 'preferences-user-config)))
