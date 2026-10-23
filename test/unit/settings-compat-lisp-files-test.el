;;; settings-compat-lisp-files-test.el --- design §15's row C15, in a child Emacs -*- lexical-binding: t -*-
;; Row C15 (unified-settings Task 29): an existing ~/.old/init.el added as a Lisp file, with lisp/ and an
;; early-init.el beside it; once plain, once with :emacs-dir.  Each case runs in a child Emacs under a temp HOME
;; (test/settings-child.el).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(defconst drgnx-settings-compat-lisp-files--init
  "(defvar sat-c15-dir nil)
(defvar sat-c15-helper nil)
(setq sat-c15-dir user-emacs-directory)
(defvar sat-c15-seq nil)
(push (quote init) sat-c15-seq)
(setq custom-file (expand-file-name \"c.el\" user-emacs-directory))
(let ((h (locate-user-emacs-file \"lisp/h.el\"))) (when (file-exists-p h) (load h nil t t)))
"
  "~/.old/init.el: uses user-emacs-directory, moves custom-file, loads its lisp/h.el.")

(defconst drgnx-settings-compat-lisp-files--files
  `(("~/.old/init.el" . ,drgnx-settings-compat-lisp-files--init)
    ("~/.old/lisp/h.el" . "(setq sat-c15-helper t)\n")
    ("~/.old/early-init.el" . "(defvar sat-c15-seq nil) (push (quote early) sat-c15-seq)\n"))
  "The files of the row.")

(defun drgnx-settings-compat-lisp-files--run (forms &optional files)
  "FORMS' values in a child with the row's files (and FILES), after `drgnx-settings-apply-global'."
  (let* ((start '((progn (drgnx-settings-apply-global) (defvar sat-c15-dir) (defvar sat-c15-helper) (defvar sat-c15-seq) (setq sat-c15-seq nil) t)))
         (r (drgnx-settings-test-child (append start forms)
                                       :files (append files drgnx-settings-compat-lisp-files--files))))
    (should (equal (plist-get r :error) nil))
    (nthcdr (length start) (plist-get r :values))))

(ert-deftest drgnx-settings-compat/c15-an-existing-init-el-plain ()
  (let ((r (car (drgnx-settings-compat-lisp-files--run
                 '((let ((plan (drgnx-user-lisp-add-plan (expand-file-name "~/.old/init.el"))))
                     (drgnx-user-lisp-add (expand-file-name "~/.old/init.el"))
                     (list (mapcar (lambda (f) (plist-get f :kind)) (plist-get plan :findings))
                           (and (plist-get plan :early-init) t)
                           (equal sat-c15-dir user-emacs-directory)   ; not rebound by default
                           sat-c15-helper)))))))
    (should (memq 'custom-file (nth 0 r)))
    (should (memq 'emacs-dir-use (nth 0 r)))
    (should (nth 1 r))                       ; the early-init.el beside it is offered
    (should (nth 2 r))                       ; it loaded, with drgnx's user-emacs-directory
    (should-not (nth 3 r))))                 ; so its lisp/ was not found

(ert-deftest drgnx-settings-compat/c15-with-emacs-dir-and-an-early-file ()
  ;; :emacs-dir finds its lisp/; the early file (listed, :early t) loads in the early loader, before the rest.
  (let ((r (car (drgnx-settings-compat-lisp-files--run
                 '((progn
                     (drgnx-user-lisp-load-early)
                     (let ((early (copy-sequence sat-c15-seq)))
                       (drgnx-user-lisp-load-all)
                       (list early sat-c15-helper (equal sat-c15-dir (expand-file-name "~/.old/"))))))
                 `(("settings.el" . "(drgnx-settings :version 1\n (drgnx-user-lisp-files '((\"~/.old/early-init.el\" :early t) (\"~/.old/init.el\" :emacs-dir \"~/.old/\"))))\n"))))))
    (should (equal r '((early) t t)))))

;;; settings-compat-lisp-files-test.el ends here
