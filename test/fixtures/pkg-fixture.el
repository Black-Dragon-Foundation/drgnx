;;; pkg-fixture.el --- for package tests outside pkg-test.el: archives as local dirs, a sandbox -*- lexical-binding: t -*-
;; The same helpers as pkg-test.el's (a test file cannot load another: ERT refuses tests defined twice).
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-pkg)

(defun drgnx-pkg-test--package (dir name version &optional requires body)
  "Write the single-file package NAME-VERSION.el into archive DIR; return its archive-contents entry."
  (write-region (format ";;; %s.el --- fixture %s  -*- lexical-binding: t -*-\n;; Version: %s\n;; Package-Requires: %S\n;;; Code:\n%s\n(defun %s-hello () %S)\n(provide '%s)\n;;; %s.el ends here\n"
                        name name version (cons '(emacs "29.1") (mapcar (lambda (r) (list (car r) (cadr r))) requires))
                        (or body "") name version name name)
                nil (expand-file-name (format "%s-%s.el" name version) dir) nil 'silent)
  (cons name (vector (version-to-list version)
                     (cons '(emacs (29 1)) (mapcar (lambda (r) (list (car r) (version-to-list (cadr r)))) requires))
                     (format "fixture %s" name) 'single nil)))

(defun drgnx-pkg-test--archive (dir packages)
  "Make DIR a package archive holding PACKAGES: (NAME VERSION [REQUIRES [BODY]])…"
  (make-directory dir t)
  (dolist (f (directory-files dir t "\\.el\\'")) (delete-file f))
  (let ((entries (mapcar (lambda (p) (apply #'drgnx-pkg-test--package dir p)) packages)))
    (with-temp-file (expand-file-name "archive-contents" dir)
      (prin1 (cons 1 entries) (current-buffer))))
  (file-name-as-directory dir))

(defmacro drgnx-pkg-test--with (root &rest body)
  "BODY with ROOT a temp dir and every drgnx and package.el location inside it."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-pkg" t)))
          (process-environment (append (list (concat "DRGNX_DATA_DIR=" ,root "data")
                                             (concat "DRGNX_CONFIG_DIR=" ,root "config")
                                             (concat "XDG_CACHE_HOME=" ,root "cache")
                                             (concat "XDG_STATE_HOME=" ,root "state"))
                                       process-environment))
          (drgnx-modules--state nil)
          (drgnx-pkg-shipped-lock (concat ,root "shipped.lock.eld"))   ; never the checkout's etc/
          (drgnx-pkg-native-compile nil)
          (package-check-signature nil)
          (package-alist nil) (package-archive-contents nil) (package-activated-list nil)
          (package--initialized nil) (package-user-dir (expand-file-name "unused-elpa" ,root))
          (package-quickstart nil) (package-quickstart-file (expand-file-name "other-emacs/package-quickstart.el" ,root))
          (load-path load-path) (features features))
     (make-directory (concat ,root "config") t)
     (unwind-protect (progn ,@body)
       (delete-directory ,root t))))

(defun drgnx-pkg-test--write (file data)
  (make-directory (file-name-directory file) t)
  (with-temp-file file (prin1 data (current-buffer))))

(defun drgnx-pkg-test--installed ()
  (sort (seq-filter (lambda (d) (not (string-prefix-p "." d)))
                    (seq-filter (lambda (d) (file-directory-p (expand-file-name d (drgnx-elpa-dir))))
                                (directory-files (drgnx-elpa-dir))))
        #'string<))

(defun drgnx-pkg-test--sync (root &rest args)
  "drgnx-pkg-sync with ROOT's (empty) modules dir and ARGS."
  (make-directory (concat root "mods") t)
  (apply #'drgnx-pkg-sync :modules-dir (concat root "mods") args))

(defun drgnx-pkg-test--bytes (file)
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(defun drgnx-pkg-test--entry (arch name version &optional requires)
  "The lock entry of the archive ARCH's file NAME-VERSION.el (REQUIRES: ((NAME VERSION)…))."
  (let ((file (format "%s-%s.el" name version)))
    (cons name (list :version version :archive "fx" :kind 'single :file file
                     :sha256 (secure-hash 'sha256 (drgnx-pkg-test--bytes (concat arch file)))
                     :requires requires :summary (format "fixture %s" name)))))

(provide 'pkg-fixture)
;;; pkg-fixture.el ends here
