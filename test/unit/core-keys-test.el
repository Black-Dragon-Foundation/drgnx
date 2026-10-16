;;; core-keys-test.el --- batch tests: key profiles, layers and conflicts -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)

(defconst drgnx-keys-test--profiles
  (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))
  "The shipped profiles.")

(defconst drgnx-keys-test--defaults (copy-keymap global-map)
  "Emacs' own bindings, as `drgnx-keys' snapshots them.")

(defmacro drgnx-keys-test--with-core-commands (&rest body)
  "BODY with a registry holding the core commands (core + core/basics), nothing else."
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (drgnx-commands-problems nil) (drgnx-modules--table nil) (drgnx-modules--report nil)
         (ring-bell-function ring-bell-function) (use-dialog-box use-dialog-box)
         (use-short-answers use-short-answers) (inhibit-startup-screen inhibit-startup-screen))
     (drgnx--core-commands)
     (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
     (drgnx-modules-run 'startup)
     ,@body))

(defun drgnx-keys-test--resolve (layers &rest args)
  (drgnx-keys-test--with-core-commands
   (apply #'drgnx-keys-resolve :commands (drgnx-commands-all) :profiles drgnx-keys-test--profiles
          :layers layers :defaults drgnx-keys-test--defaults args)))

(defun drgnx-keys-test--keys (r id)
  "Keys resolution R binds command ID to."
  (mapcar (lambda (b) (plist-get b :key))
          (seq-filter (lambda (b) (eq (plist-get b :id) id)) (plist-get r :bindings))))

(defun drgnx-keys-test--conflict (r key)
  (seq-find (lambda (c) (equal (plist-get c :key) key)) (plist-get r :conflicts)))

(ert-deftest drgnx-keys/every-core-command-has-an-entry-in-every-profile ()
  ;; A key, or :none with a reason — never forgotten.
  (drgnx-keys-test--with-core-commands
   (should (> (length (drgnx-commands-all)) 4))
   (pcase-dolist (`(,profile . ,spec) drgnx-keys-test--profiles)
     (dolist (c (drgnx-commands-all))
       (should (equal (list profile (drgnx-cmd-id c) t)
                      (list profile (drgnx-cmd-id c) (and (assq (drgnx-cmd-id c) (plist-get spec :bind)) t)))))))
  (should (equal (sort (mapcar #'car drgnx-keys-test--profiles) #'string<) '(emacs vim vscode))))

(ert-deftest drgnx-keys/vscode-alone ()
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window)))))
    (should (equal (drgnx-keys-test--keys r 'open-file) '("C-o")))
    (should (equal (drgnx-keys-test--keys r 'save-file) '("C-s")))
    (should (equal (drgnx-keys-test--keys r 'palette) '("C-S-p" "<f1>")))
    (should (null (drgnx-keys-test--keys r 'line-numbers)))
    ;; No emacs layer: replacing Emacs' C-o is not a conflict…
    (should-not (drgnx-keys-test--conflict r "C-o"))
    ;; …but turning a prefix into a command, or a command into a prefix, always is.
    (should (eq (plist-get (drgnx-keys-test--conflict r "<f1>") :kind) 'prefix))
    (should (eq (plist-get (drgnx-keys-test--conflict r "C-k C-s") :kind) 'prefix))
    (should (null (plist-get r :problems)))))

(ert-deftest drgnx-keys/emacs-editing-then-vscode-app ()
  (let* ((r (drgnx-keys-test--resolve '((emacs editing) (vscode app window))))
         (c (drgnx-keys-test--conflict r "C-o")))
    (should (equal (drgnx-keys-test--keys r 'open-file) '("C-o")))
    (should (eq (plist-get c :kind) 'claim))
    (should (equal (plist-get (plist-get c :winner) :id) 'open-file))
    (should (eq (plist-get (plist-get c :winner) :layer) 'vscode))
    (should (equal (plist-get (car (plist-get c :losers)) :claim) "open-line"))
    (should (eq (plist-get (car (plist-get c :losers)) :layer) 'emacs))
    (should (drgnx-keys-test--conflict r "C-s"))))

(ert-deftest drgnx-keys/later-layer-wins-even-over-a-binding ()
  ;; VS Code first, Emacs editing after it: Emacs keeps C-o and C-s; VS Code's keys are not bound.
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window) (emacs editing)))))
    (should (null (drgnx-keys-test--keys r 'open-file)))
    (should (eq (plist-get (plist-get (drgnx-keys-test--conflict r "C-o") :winner) :layer) 'emacs))
    (should (equal (plist-get (car (plist-get (drgnx-keys-test--conflict r "C-o") :losers)) :id) 'open-file))))

(ert-deftest drgnx-keys/vim-editing-then-vscode-app ()
  (let* ((r (drgnx-keys-test--resolve '((vim editing) (vscode app window))))
         (c (drgnx-keys-test--conflict r "C-o")))
    (should (eq (plist-get c :kind) 'claim))
    (should (equal (plist-get (car (plist-get c :losers)) :claim) "jump back"))
    (should (equal (drgnx-keys-test--keys r 'open-file) '("C-o")))))

(ert-deftest drgnx-keys/vim-commands-wait-for-evil ()
  (let ((r (drgnx-keys-test--resolve '((vim app editing window)))))
    (should (equal (drgnx-keys-test--keys r 'open-file) '("SPC f f")))
    (should (equal (plist-get (seq-find (lambda (b) (eq (plist-get b :id) 'open-file)) (plist-get r :bindings)) :map)
                   '(evil . evil-normal-state-map)))))

(ert-deftest drgnx-keys/user-overrides-win ()
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window))
                                     :user '(:bind ((open-file "C-c o") (save-file "C-o") (no-such-command "C-c n")
                                                    (palette "C-c <oops"))
                                             :unbind (line-numbers keys-sheet)))))
    (should (equal (drgnx-keys-test--keys r 'open-file) '("C-c o")))
    (should (null (drgnx-keys-test--keys r 'keys-sheet)))
    ;; The user's C-o for save-file meets nothing: open-file moved away.
    (should (equal (drgnx-keys-test--keys r 'save-file) '("C-o")))
    (should (seq-find (lambda (p) (string-search "no-such-command" p)) (plist-get r :problems)))
    (should (seq-find (lambda (p) (string-search "C-c <oops" p)) (plist-get r :problems)))))

(ert-deftest drgnx-keys/same-key-two-commands ()
  (let* ((r (drgnx-keys-test--resolve '((vscode app editing window)) :user '(:bind ((save-file "C-o")))))
         (c (drgnx-keys-test--conflict r "C-o")))
    ;; save-file (user) took C-o; open-file (vscode) lost it.
    (should (eq (plist-get c :kind) 'same-key))
    (should (equal (plist-get (plist-get c :winner) :id) 'save-file))
    (should (equal (plist-get (car (plist-get c :losers)) :id) 'open-file))
    (should (null (drgnx-keys-test--keys r 'open-file)))))

(ert-deftest drgnx-keys/macos-cmd ()
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window)) :platform 'macos)))
    (should (equal (drgnx-keys-test--keys r 'open-file) '("s-o")))
    (should (equal (drgnx-keys-test--keys r 'keys-sheet) '("s-k s-s"))))
  (let ((r (drgnx-keys-test--resolve '((emacs app editing window)) :platform 'macos)))
    (should (equal (drgnx-keys-test--keys r 'open-file) '("C-x C-f")))))

(ert-deftest drgnx-keys/unknown-profile-is-a-problem ()
  (let ((r (drgnx-keys-test--resolve '((sublime app) (vscode app editing window)))))
    (should (seq-find (lambda (p) (string-search "sublime" p)) (plist-get r :problems)))
    (should (equal (drgnx-keys-test--keys r 'open-file) '("C-o")))))
