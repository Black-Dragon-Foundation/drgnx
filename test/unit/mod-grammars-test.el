;;; mod-grammars-test.el --- batch tests: tree-sitter grammars on request — a hint, never a prompt; installs as a job -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "modules/lang/drgnx-grammars" drgnx-dir) nil t)

(defmacro drgnx-grammars-test--with (&rest body)
  "BODY with no grammar available, prompts that fail, and the hints forgotten; buffers made in it killed after."
  (declare (indent 0))
  `(let ((drgnx-grammars--hinted nil) (made nil))
     (cl-letf (((symbol-function 'treesit-language-available-p) (lambda (&rest _) nil))
               ((symbol-function 'read-string) (lambda (&rest _) (error "Prompted")))
               ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "Prompted")))
               ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Prompted"))))
       (unwind-protect (progn ,@body)
         (dolist (b made) (when (buffer-live-p b) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))))))

(defun drgnx-grammars-test--buffer (name mode)
  (with-current-buffer (get-buffer-create name)
    (setq buffer-file-name (expand-file-name name temporary-file-directory))
    (funcall mode)
    (current-buffer)))

(ert-deftest drgnx-grammars/the-language-of-a-buffer ()
  (with-temp-buffer (python-mode) (should (eq (drgnx-grammars-language) 'python)))
  (with-temp-buffer (c++-mode) (should (eq (drgnx-grammars-language) 'cpp)))
  (with-temp-buffer (sh-mode) (should (eq (drgnx-grammars-language) 'bash)))
  (with-temp-buffer (setq buffer-file-name "/x/a.tsx") (should (eq (drgnx-grammars-language) 'tsx)))
  (with-temp-buffer (fundamental-mode) (should-not (drgnx-grammars-language))))

(ert-deftest drgnx-grammars/a-missing-grammar-is-a-hint-once ()
  (drgnx-grammars-test--with
    (let ((messages nil))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (dolist (n '("a.py" "b.py"))
          (with-current-buffer (car (push (drgnx-grammars-test--buffer n #'python-mode) made))
            (drgnx-grammars--hint))))
      (should (= 1 (seq-count (lambda (m) (string-search "Install Language Support" m)) messages)))
      (should (string-search "python" (car messages))))))

(ert-deftest drgnx-grammars/install-is-a-job ()
  (drgnx-grammars-test--with
    (let ((started nil))
      (cl-letf (((symbol-function 'drgnx-jobs-start) (lambda (name command &rest _) (setq started (list name command)) "J1"))
                ((symbol-function 'drgnx-grammars--watch) #'ignore))
        (drgnx-grammars-install '(python tsx)))
      (should (equal (car started) "grammars"))
      (let ((line (format "%S" (cadr started))))
        (should (string-search "--batch" line))
        (should (string-search "tree-sitter-python" line))
        (should (string-search "tsx/src" line))
        (should (string-search (drgnx-grammars-dir) line))
        ;; --eval code is lexical: the recipes are set after treesit is loaded, never let-bound
        (should (string-match-p "(require 'treesit).*treesit-language-source-alist" line))
        (should-not (string-search "(let ((treesit-language-source-alist" line))))))

(ert-deftest drgnx-grammars/after-the-job-buffers-switch ()
  (drgnx-grammars-test--with
    (let ((b (car (push (drgnx-grammars-test--buffer "c.py" #'python-mode) made))) (switched nil))
      (cl-letf (((symbol-function 'treesit-language-available-p) (lambda (lang &rest _) (eq lang 'python)))
                ((symbol-function 'python-ts-mode) (lambda () (setq switched (current-buffer)))))
        (drgnx-grammars--installed '(python)))
      (should (eq switched b)))))

(ert-deftest drgnx-grammars/a-build-that-fails-is-a-failure ()
  ;; treesit-install-language-grammar turns its errors into warnings: the job checks the grammar loads
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-gram" t))) (bin (concat tmp "bin/"))
         (process-environment (append (list (concat "DRGNX_DATA_DIR=" tmp "data") (concat "PATH=" bin ":" (getenv "PATH")))
                                      process-environment)))
    (unwind-protect
        (progn
          (make-directory bin t)
          (write-region "#!/bin/sh\necho fake git fails >&2\nexit 1\n" nil (concat bin "git") nil 'silent)
          (set-file-modes (concat bin "git") #o755)
          (let ((cmd (drgnx-grammars--job-command '(toml))))
            (should (= 1 (apply #'call-process (car cmd) nil nil nil (cdr cmd))))))
      (delete-directory tmp t))))

(ert-deftest drgnx-grammars/emacs-own-recipes-come-first ()
  ;; Emacs 31's tree-sitter modes pin their grammars: the job loads the mode and keeps its recipe
  (let ((form (format "%S" (drgnx-grammars--job-command '(python)))))
    (should (string-search "python-ts-mode" form))
    (should (string-match-p "(unless (assq l treesit-language-source-alist)" form))))

(ert-deftest drgnx-grammars/one-buffer-that-fails-to-switch-stops-no-other ()
  (drgnx-grammars-test--with
    (let ((a (car (push (drgnx-grammars-test--buffer "x1.py" #'python-mode) made)))
          (b (car (push (drgnx-grammars-test--buffer "x2.py" #'python-mode) made))) (switched nil))
      (cl-letf (((symbol-function 'treesit-language-available-p) (lambda (lang &rest _) (eq lang 'python)))
                ((symbol-function 'python-ts-mode) (lambda () (if (eq (current-buffer) a) (error "Broken") (push (current-buffer) switched)))))
        (drgnx-grammars--installed '(python)))
      (should (memq b switched)))))


(ert-deftest drgnx-grammars/every-language-is-pinned-for-abi-14 ()
  ;; M11a-3: a known-good tag per language, so Emacs 30's tree-sitter (grammar ABI 14) loads what is built
  (dolist (e drgnx-grammars-sources)
    (should (equal (list (car e) t) (list (car e) (and (stringp (nth 2 e)) (string-match-p "\\`v[0-9]+\\.[0-9]+\\.[0-9]+\\'" (nth 2 e)) t)))))
  (dolist (l (mapcar #'car drgnx-grammars-modes))
    (should (assq l drgnx-grammars-sources))))

(ert-deftest drgnx-grammars/emacs-30-always-pins-and-emacs-31-takes-the-default-branch-with-abi-15 ()
  (let ((emacs-major-version 30))
    (dolist (abi '(14 15 nil))                                   ; Emacs 30: the pin, whatever the library
      (cl-letf (((symbol-function 'drgnx-grammars--abi) (lambda () abi)))
        (should (equal (drgnx-grammars-recipe 'python) '(python "https://github.com/tree-sitter/tree-sitter-python" "v0.23.6")))
        (should (equal (drgnx-grammars-recipe 'tsx) '(tsx "https://github.com/tree-sitter/tree-sitter-typescript" "v0.23.2" "tsx/src")))
        (should (string-search "v0.23.6" (format "%S" (drgnx-grammars--job-command '(python))))))))
  (let ((emacs-major-version 31))
    (dolist (abi '(14 nil))                                      ; Emacs 31 with a library that may be ABI 14: the pin loads
      (cl-letf (((symbol-function 'drgnx-grammars--abi) (lambda () abi)))
        (should (equal (nth 2 (drgnx-grammars-recipe 'python)) "v0.23.6"))))
    (cl-letf (((symbol-function 'drgnx-grammars--abi) (lambda () 15)))
      (should (equal (drgnx-grammars-recipe 'python) '(python "https://github.com/tree-sitter/tree-sitter-python" nil)))
      (should (equal (drgnx-grammars-recipe 'tsx) '(tsx "https://github.com/tree-sitter/tree-sitter-typescript" nil "tsx/src")))
      (should-not (string-search "v0.23.6" (format "%S" (drgnx-grammars--job-command '(python)))))))
  (should-not (drgnx-grammars-recipe 'cobol)))

;;; mod-grammars-test.el ends here
