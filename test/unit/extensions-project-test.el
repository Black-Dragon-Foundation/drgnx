;;; extensions-project-test.el --- a package's file modes and buffer modes off in one project -*- lexical-binding: t -*-
;; test-class: det
;; Pure: buffers visiting files under two temp project roots P and Q, in a temp config, state and cache folder; the
;; modes index is built from fixture autoloads files (read as data) in a temp packages folder; fixture major and minor
;; modes stand for the packages' own.  No process, no timer.  See docs/guide/extensions.md, "In one project".
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(require 'drgnx-settings-workspace)
(require 'drgnx-extensions-index)
(load (expand-file-name "modules/tools/drgnx-extensions-project" drgnx-dir) nil t)

(define-derived-mode drgnx-ext-fx-rust-mode prog-mode "FxRust" "The fixture package fx-rust's major mode.")
(define-derived-mode drgnx-ext-fx-rust-ts-mode prog-mode "FxRustTS" "Another package's mode for the same files.")
(define-derived-mode drgnx-ext-fx-other-mode prog-mode "FxOther" "A mode `major-mode-remap-alist' may name.")
(define-minor-mode drgnx-ext-fx-lint-mode "The fixture package fx-rust's buffer minor mode." :lighter " FxLint")

(defconst drgnx-ext-project-test--autoloads
  '(("fx-rust-1.0" . "(add-to-list 'load-path (directory-file-name (or (file-name-directory #$) (car load-path))))
(add-to-list 'auto-mode-alist '(\"\\\\.fxrs\\\\'\" . drgnx-ext-fx-rust-mode))
(autoload 'drgnx-ext-fx-rust-mode \"fx-rust\" \"Major mode.\n\n(fn)\" t)
(autoload 'drgnx-ext-fx-lint-mode \"fx-rust\" \"Minor mode.\n\n(fn &optional ARG)\" t)
(register-definition-prefixes \"fx-rust\" '(\"drgnx-ext-fx-\"))
")
    ("fx-git-1.0" . "(add-to-list 'auto-mode-alist '(\"/fx-rebase-todo\\\\'\" . drgnx-ext-fx-rebase-mode))
(autoload 'drgnx-ext-fx-rebase-mode \"fx-git\" \"Major mode.\n\n(fn)\" t)
(defvar global-drgnx-ext-fx-git-file-mode nil \"Global minor mode.\")
(custom-autoload 'global-drgnx-ext-fx-git-file-mode \"fx-git\" nil)
(autoload 'global-drgnx-ext-fx-git-file-mode \"fx-git\" \"Global minor mode.\n\n(fn &optional ARG)\" t)
(define-key global-map (kbd \"C-x g\") #'drgnx-ext-fx-git-status)
(add-hook 'find-file-hook #'drgnx-ext-fx-git-check)
")
    ("fx-lib-1.0" . "(autoload 'drgnx-ext-fx-lib-do \"fx-lib\" \"Do it.\n\n(fn X)\")
"))
  "Fixture packages' autoloads files: a narrow one, a magit-like global one, and one that adds no mode.")

(defvar drgnx-ext-project-test--p nil "The project P (a truename ending in a slash).")
(defvar drgnx-ext-project-test--q nil "The project Q.")
(defvar drgnx-ext-project-test--buffers nil "The buffers a test opened.")

(defun drgnx-ext-project-test--elpa (root)
  "A packages folder under ROOT holding the fixture autoloads files; its name."
  (let ((elpa (expand-file-name "elpa/" root)))
    (pcase-dolist (`(,dir . ,text) drgnx-ext-project-test--autoloads)
      (make-directory (expand-file-name dir elpa) t)
      (write-region text nil (expand-file-name (format "%s/%s-autoloads.el" dir (car (drgnx-pkg--dir-package dir))) elpa)
                    nil 'silent))
    elpa))

(defmacro drgnx-ext-project-test--with (&rest body)
  "BODY in a temp config, state and cache folder with the projects P and Q beside it, fresh workspace caches, the
fixture modes on `auto-mode-alist' (fx-rust's entry first) and the modes index built; buffers opened are killed and
the per-project parts set back after."
  (declare (indent 0) (debug t))
  `(drgnx-test-with-config
     (let* ((process-environment (cons (concat "XDG_CACHE_HOME=" drgnx-test-config-root "cache") process-environment))
            (drgnx-settings-workspace--docs (make-hash-table :test 'equal))
            (drgnx-settings-workspace--seen (make-hash-table :test 'equal))
            (drgnx-settings-workspace--usable-memo (make-hash-table :test 'equal))
            (drgnx-ext-project-test--p (progn (make-directory (expand-file-name "P" drgnx-test-config-root) t)
                                              (file-name-as-directory (file-truename (expand-file-name "P" drgnx-test-config-root)))))
            (drgnx-ext-project-test--q (progn (make-directory (expand-file-name "Q" drgnx-test-config-root) t)
                                              (file-name-as-directory (file-truename (expand-file-name "Q" drgnx-test-config-root)))))
            (drgnx-ext-project-test--buffers nil)
            (auto-mode-alist (append '(("\\.fxrs\\'" . drgnx-ext-fx-rust-mode) ("\\.fxrs\\'" . drgnx-ext-fx-rust-ts-mode)
                                       ("\\.fxtxt\\'" . text-mode))
                                     auto-mode-alist))
            (text-mode-hook (list #'drgnx-ext-fx-lint-mode))
            (inhibit-interaction t))
       (drgnx-extensions-index-build (drgnx-ext-project-test--elpa drgnx-test-config-root))
       (unwind-protect (progn ,@body)
         (drgnx-extensions-project-teardown)
         (mapc (lambda (b) (when (buffer-live-p b) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
               drgnx-ext-project-test--buffers)))))

(defun drgnx-ext-project-test--open (root name)
  "Visit the file NAME under ROOT (made empty first): its buffer."
  (let ((file (expand-file-name name root)))
    (unless (file-exists-p file) (write-region "" nil file nil 'silent))
    (let ((b (find-file-noselect file)))
      (push b drgnx-ext-project-test--buffers)
      b)))

(defun drgnx-ext-project-test--mode (buffer) (buffer-local-value 'major-mode buffer))

(defun drgnx-ext-project-test--off (root)
  "Turn fx-rust off in ROOT as the details page does."
  (drgnx-extensions-project-setup)
  (drgnx-extensions-project-set 'fx-rust root t))

(defun drgnx-ext-project-test--installed ()
  (list (and (advice-member-p #'drgnx-extensions-project--remap 'major-mode-remap) t)
        (and (memq #'drgnx-extensions-project--minor-off after-change-major-mode-hook) t)))

;;;; Modes

(ert-deftest drgnx-extensions-project/a-file-mode-falls-back-in-that-project-only ()
  (drgnx-ext-project-test--with
    (drgnx-ext-project-test--off drgnx-ext-project-test--p)
    (should (drgnx-extensions-project-off-p 'fx-rust drgnx-ext-project-test--p))
    (should-not (drgnx-extensions-project-off-p 'fx-rust drgnx-ext-project-test--q))
    (should (eq (drgnx-ext-project-test--mode (drgnx-ext-project-test--open drgnx-ext-project-test--p "a.fxrs"))
                'drgnx-ext-fx-rust-ts-mode))
    (should (eq (drgnx-ext-project-test--mode (drgnx-ext-project-test--open drgnx-ext-project-test--q "a.fxrs"))
                'drgnx-ext-fx-rust-mode))
    ;; in a subfolder of P too
    (make-directory (expand-file-name "src" drgnx-ext-project-test--p) t)
    (should (eq (drgnx-ext-project-test--mode (drgnx-ext-project-test--open drgnx-ext-project-test--p "src/b.fxrs"))
                'drgnx-ext-fx-rust-ts-mode))))

(ert-deftest drgnx-extensions-project/a-buffer-minor-mode-is-off-there ()
  (drgnx-ext-project-test--with
    (drgnx-ext-project-test--off drgnx-ext-project-test--p)
    (should-not (buffer-local-value 'drgnx-ext-fx-lint-mode
                                    (drgnx-ext-project-test--open drgnx-ext-project-test--p "notes.fxtxt")))
    (should (buffer-local-value 'drgnx-ext-fx-lint-mode
                                (drgnx-ext-project-test--open drgnx-ext-project-test--q "notes.fxtxt")))))

(ert-deftest drgnx-extensions-project/only-file-buffers-of-that-project ()
  (drgnx-ext-project-test--with
    (drgnx-ext-project-test--off drgnx-ext-project-test--p)
    (with-temp-buffer                                   ; a buffer in P that visits no file
      (setq default-directory drgnx-ext-project-test--p)
      (set-auto-mode-0 'drgnx-ext-fx-rust-mode)
      (should (eq major-mode 'drgnx-ext-fx-rust-mode))
      (text-mode)
      (should drgnx-ext-fx-lint-mode))
    (with-current-buffer (get-buffer-create "*scratch*")
      (let ((mode major-mode))
        (drgnx-ext-fx-lint-mode 1)
        (run-hooks 'after-change-major-mode-hook)
        (should (eq major-mode mode))
        (should drgnx-ext-fx-lint-mode)
        (drgnx-ext-fx-lint-mode -1)))))

(ert-deftest drgnx-extensions-project/other-remap-callers-are-untouched ()
  (drgnx-ext-project-test--with
    (drgnx-ext-project-test--off drgnx-ext-project-test--p)
    (with-temp-buffer
      (setq default-directory drgnx-ext-project-test--p)
      (should (eq (major-mode-remap 'drgnx-ext-fx-rust-mode) 'drgnx-ext-fx-rust-mode))
      (let ((major-mode-remap-alist '((drgnx-ext-fx-rust-mode . drgnx-ext-fx-other-mode))))
        (should (eq (major-mode-remap 'drgnx-ext-fx-rust-mode) 'drgnx-ext-fx-other-mode))))
    (with-current-buffer (drgnx-ext-project-test--open drgnx-ext-project-test--p "c.fxrs")
      (should (eq (major-mode-remap 'text-mode) 'text-mode)))))

;;;; Which packages can be off

(ert-deftest drgnx-extensions-project/a-global-package-has-no-toggle ()
  (drgnx-ext-project-test--with
    (drgnx-extensions-project-setup)
    (should (eq (drgnx-extensions-project-scope 'fx-git) 'global))
    (should (equal (drgnx-extensions-project-describe 'fx-git drgnx-ext-project-test--p)
                   "On in every project: it changes Emacs as a whole"))
    (let ((err (should-error (drgnx-extensions-project-toggle 'fx-git drgnx-ext-project-test--p) :type 'user-error)))
      (should (string-search "On in every project: it changes Emacs as a whole" (cadr err))))
    (should-not (drgnx-extensions-project-off-p 'fx-git drgnx-ext-project-test--p))
    (should (equal (drgnx-ext-project-test--installed) '(nil nil)))))

(ert-deftest drgnx-extensions-project/index-classifies-by-autoloads ()
  (drgnx-ext-project-test--with
    (let ((index (drgnx-extensions-index-read)))
      (should (equal (mapcar (lambda (e) (cons (car e) (plist-get (cdr e) :scope))) index)
                     '((fx-git . global) (fx-lib . none) (fx-rust . narrow))))
      (should (equal (plist-get (alist-get 'fx-rust index) :auto) '(("\\.fxrs\\'" . drgnx-ext-fx-rust-mode))))
      (should (equal (plist-get (alist-get 'fx-rust index) :minor) '(drgnx-ext-fx-lint-mode)))
      (should (equal (drgnx-extensions-index-counts index) '(:narrow 1 :global 1 :none 1)))
      ;; nothing of the autoloads ran
      (should-not (fboundp 'drgnx-ext-fx-lib-do))
      (should-not (boundp 'global-drgnx-ext-fx-git-file-mode))
      (should-not (memq 'drgnx-ext-fx-git-check find-file-hook)))))

(ert-deftest drgnx-extensions-project/nothing-installed-while-nothing-is-off ()
  (drgnx-ext-project-test--with
    (drgnx-extensions-project-setup)
    (should (equal (drgnx-ext-project-test--installed) '(nil nil)))
    (drgnx-extensions-project-set 'fx-rust drgnx-ext-project-test--p t)
    (should (equal (drgnx-ext-project-test--installed) '(t t)))
    (drgnx-extensions-project-set 'fx-rust drgnx-ext-project-test--p nil)
    (should (equal (drgnx-ext-project-test--installed) '(nil nil)))
    (should (eq (drgnx-ext-project-test--mode (drgnx-ext-project-test--open drgnx-ext-project-test--p "d.fxrs"))
                'drgnx-ext-fx-rust-mode))))

(ert-deftest drgnx-extensions-project/the-module-off-removes-both ()
  (drgnx-ext-project-test--with
    (let ((file (expand-file-name "drgnx-fake-ext-project.el" drgnx-test-config-root)))
      (write-region "(drgnx-module-define 'test/ext-project :setup #'drgnx-extensions-project-setup
  :teardown #'drgnx-extensions-project-teardown)\n" nil file nil 'silent)
      (drgnx-test-with-modules (list file) :strict t
                               (should (eq (plist-get (alist-get 'test/ext-project (drgnx-modules-report)) :status) 'ok))
                               (drgnx-extensions-project-set 'fx-rust drgnx-ext-project-test--p t)
                               (should (equal (drgnx-ext-project-test--installed) '(t t))))
      (should (equal (drgnx-ext-project-test--installed) '(nil nil)))
      (should-not (memq #'drgnx-extensions-project--changed drgnx-settings-changed-functions)))))

(ert-deftest drgnx-extensions-project/an-agent-cannot-set-it ()
  (require 'drgnx-settings-agents)
  (should (eq (plist-get (drgnx-setting-meta 'drgnx-packages-off) :agents) 'never))
  (should (eq (plist-get (drgnx-setting-meta 'drgnx-packages-off) :scope) 'project))
  (should (string-search "never an agent's" (drgnx-settings-agents--denied 'drgnx-packages-off))))

(ert-deftest drgnx-extensions-project/the-doctor-finds-a-miss ()
  (drgnx-ext-project-test--with
    (require 'drgnx-doctor)
    (drgnx-extensions-project-setup)
    (let ((b (drgnx-ext-project-test--open drgnx-ext-project-test--p "e.fxrs")))
      (should (eq (drgnx-ext-project-test--mode b) 'drgnx-ext-fx-rust-mode))
      (should (eq (car (drgnx-doctor-check 'package-modes-off (list :package-modes-off (drgnx-doctor--package-modes-off))))
                  'ok))
      ;; the setting written behind the view's back (a hand edit): the open buffer keeps fx-rust's mode
      (require 'drgnx-settings-page)
      (drgnx-settings-workspace-file drgnx-ext-project-test--p t)
      (drgnx-settings-editors-commit 'drgnx-packages-off 'workspace drgnx-ext-project-test--p '(fx-rust))
      (drgnx-extensions-project-refresh)
      (should (equal (drgnx-extensions-project-misses) (list (list (buffer-name b) 'fx-rust 'drgnx-ext-fx-rust-mode))))
      (let ((r (drgnx-doctor-check 'package-modes-off (list :package-modes-off (drgnx-doctor--package-modes-off)))))
        (should (eq (car r) 'warn))
        (should (string-search "e.fxrs" (nth 1 r))))
      (with-current-buffer b (normal-mode))
      (should-not (drgnx-extensions-project-misses)))))

;;; extensions-project-test.el ends here
