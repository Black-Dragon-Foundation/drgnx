;;; mod-lang-packs-test.el --- batch tests: the lang/packs module — active packs applied, nothing prompts, the hint once -*- lexical-binding: t -*-
;; test-class: cond
(require 'ert)
(require 'drgnx)
(require 'drgnx-packs)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/pkg-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/lang/drgnx-lang-packs" drgnx-dir) nil t)
(defvar treesit-extra-load-path)
(defvar treesit-auto-install-grammar)

(defmacro drgnx-lang-packs-test--with (root &rest body)
  "BODY in a sandbox with built-in packs `pyx' (a python-like pack, mode `python-ts-mode', grammar pyx) and `plain'
\(no grammar), and no grammar available unless a test says so (each test file runs in an Emacs of its own, and a module's remaps
go with its teardown)."
  (declare (indent 1))
  `(drgnx-pkg-test--with ,root
     (let ((drgnx-packs-dir (concat ,root "packs/")) (drgnx-packs--manifests nil)
           (drgnx-lang-packs--hinted nil) (drgnx-lang-packs--pinned nil))
       (make-directory (concat ,root "packs/pyx") t)
       (with-temp-file (concat ,root "packs/pyx/pack.eld")
         (prin1 (list :pack "pyx" :schema 1 :version "1" :name "Pyx" :summary "s" :license "MIT"
                      :files '(:extensions ("pyx") :mode-regexp "\\.pyx\\'")
                      :grammars (list (list :name 'pyx :repo "https://example.org/x" :commit (make-string 40 ?a)
                                            :tree-sha256 (make-string 64 ?b) :src "src" :required t))
                      :mode '(:ts python-ts-mode :builtin t :classic python-mode))
                (current-buffer)))
       (cl-letf (((symbol-function 'treesit-language-available-p) (lambda (&rest _) nil))
                 ((symbol-function 'read-string) (lambda (&rest _) (error "Prompted")))
                 ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "Prompted")))
                 ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Prompted"))))
         ,@body))))

(defun drgnx-lang-packs-test--install-pyx (root)
  "Make pyx installed: its grammar folder with a library, the lock and active.eld."
  (let* ((dir (drgnx-packs-grammar-dir 'pyx (make-string 40 ?a))))
    (make-directory dir t)
    (write-region "x" nil (expand-file-name "libtree-sitter-pyx.so" dir) nil 'silent)
    (drgnx-packs--write-lock (list (list 'pyx :commit "c" :wanted 'user))
                             (list (list 'pyx :commit (make-string 40 ?a) :owner "pyx")))
    (drgnx-packs-derive-active)
    (ignore root)))

(ert-deftest drgnx-lang-packs/nothing-is-applied-without-an-installed-pack ()
  (drgnx-lang-packs-test--with root
    (drgnx-test-with-modules '(lang/packs) :strict t
                             (should-not (alist-get 'python-mode major-mode-remap-alist)))))

(ert-deftest drgnx-lang-packs/an-installed-pack-with-a-loading-grammar-remaps-its-mode ()
  ;; the module fixture gives each run its own state folder, so the pack is installed inside it and applied by a refresh
  (drgnx-lang-packs-test--with root
    (cl-letf (((symbol-function 'treesit-language-available-p) (lambda (lang &rest _) (eq lang 'pyx))))
      (drgnx-test-with-modules '(lang/packs) :strict t
                               (drgnx-lang-packs-test--install-pyx root)
                               (drgnx-lang-packs-refresh)
                               (should (eq (alist-get 'python-mode major-mode-remap-alist) 'python-ts-mode))
                               (should (eq (cdr (assoc "\\.pyx\\'" auto-mode-alist)) 'python-ts-mode))
                               (should (equal (car treesit-extra-load-path) (drgnx-packs-grammar-dir 'pyx (make-string 40 ?a))))
                               (should (eq treesit-auto-install-grammar 'never)))
      ;; turned off: every door is closed again
      (should-not (alist-get 'python-mode major-mode-remap-alist))
      (should-not (assoc "\\.pyx\\'" auto-mode-alist)))))

(ert-deftest drgnx-lang-packs/a-mode-is-not-remapped-while-a-required-grammar-is-missing-and-nothing-is-asked ()
  (drgnx-lang-packs-test--with root
    (drgnx-test-with-modules '(lang/packs) :strict t     ; the grammar does not load: no remap, no question
                             (drgnx-lang-packs-test--install-pyx root)
                             (drgnx-lang-packs-refresh)
                             (should-not (alist-get 'python-mode major-mode-remap-alist))
                             (should-not (assoc "\\.pyx\\'" auto-mode-alist)))))

(ert-deftest drgnx-lang-packs/a-grammar-in-use-keeps-its-folder-first-after-an-update ()
  (drgnx-lang-packs-test--with root
    (cl-letf (((symbol-function 'treesit-language-available-p) (lambda (lang &rest _) (eq lang 'pyx))))
      (drgnx-test-with-modules '(lang/packs) :strict t
                               (drgnx-lang-packs-test--install-pyx root)
                               (drgnx-lang-packs-refresh)
                               (let ((old (drgnx-packs-grammar-dir 'pyx (make-string 40 ?a))) (new (drgnx-packs-grammar-dir 'pyx (make-string 40 ?f))))
                                 (should (equal (car treesit-extra-load-path) old))
                                 (drgnx-lang-packs--note-parser 'pyx)                   ; a parser is made: this session uses OLD
                                 (should (equal (cdr (assq 'pyx drgnx-lang-packs--pinned)) old))
                                 ;; an update builds the new commit and activates it
                                 (make-directory new t)
                                 (write-region "y" nil (expand-file-name "libtree-sitter-pyx.so" new) nil 'silent)
                                 (drgnx-packs--write-lock (list (list 'pyx :commit "c" :wanted 'user))
                                                          (list (list 'pyx :commit (make-string 40 ?f) :owner "pyx")))
                                 (drgnx-packs-derive-active)
                                 (drgnx-lang-packs-refresh)
                                 (should (equal (car treesit-extra-load-path) old))
                                 (should (member new treesit-extra-load-path)))))))

(ert-deftest drgnx-lang-packs/a-missing-pack-is-a-hint-once-and-never-a-prompt ()
  (drgnx-lang-packs-test--with root
    (let ((messages nil))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (dolist (n '("a.pyx" "b.pyx"))
          (with-temp-buffer
            (setq buffer-file-name (expand-file-name n temporary-file-directory))
            (drgnx-lang-packs--hint)
            (set-buffer-modified-p nil))))
      (should (= 1 (seq-count (lambda (m) (string-search "Install Language Support" m)) messages)))
      (should (string-search "Pyx" (car messages))))))

(ert-deftest drgnx-lang-packs/an-installed-pack-is-not-hinted ()
  (drgnx-lang-packs-test--with root
    (drgnx-lang-packs-test--install-pyx root)
    (let ((messages nil))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (with-temp-buffer (setq buffer-file-name (expand-file-name "a.pyx" temporary-file-directory))
                          (drgnx-lang-packs--hint) (set-buffer-modified-p nil)))
      (should-not messages))))

(ert-deftest drgnx-lang-packs/install-is-a-job-that-syncs-the-pack ()
  (drgnx-lang-packs-test--with root
    (let ((started nil))
      (cl-letf (((symbol-function 'drgnx-exec-start)
                 (lambda (name command &rest keys) (setq started (list name command)) (funcall (plist-get keys :callback) "J1" nil) nil))
                ((symbol-function 'drgnx-lang-packs--watch) #'ignore))
        (drgnx-lang-packs-install '("pyx")))
      (should (equal (car started) "packs"))
      (should (equal (cdr (cadr started)) '("packs" "sync" "--add" "pyx"))))))

(ert-deftest drgnx-lang-packs/after-the-job-open-buffers-switch ()
  (drgnx-lang-packs-test--with root
    (let ((b (get-buffer-create "sw.pyx")) (switched nil))
      (unwind-protect
          (with-current-buffer b
            (setq buffer-file-name (expand-file-name "sw.pyx" temporary-file-directory))
            (cl-letf (((symbol-function 'treesit-language-available-p) (lambda (lang &rest _) (eq lang 'pyx)))
                      ((symbol-function 'python-ts-mode) (lambda () (setq switched (current-buffer)))))
              (drgnx-test-with-modules '(lang/packs) :strict t
                                       (drgnx-lang-packs-test--install-pyx root)
                                       (drgnx-lang-packs-refresh)))
            (should (eq switched b)))
        (with-current-buffer b (set-buffer-modified-p nil))
        (kill-buffer b)))))

;;;; What the formatting module reads

(ert-deftest drgnx-lang-packs/the-formatting-lists-come-from-the-packs ()
  (let ((drgnx-packs-dir nil) (drgnx-packs--manifests nil))
    (dolist (m '(go-mode go-ts-mode rust-mode rust-ts-mode terraform-mode dart-mode zig-mode elixir-mode elixir-ts-mode))
      (should (memq m (drgnx-packs-format-modes))))
    (should-not (memq 'python-mode (drgnx-packs-format-modes)))
    (dolist (f '(".prettierrc" ".clang-format" "ruff.toml" "biome.json" "stylua.toml" ".rubocop.yml" ".php-cs-fixer.php" ".scalafmt.conf"))
      (should (member f (drgnx-packs-format-config-files))))))

;;; mod-lang-packs-test.el ends here
