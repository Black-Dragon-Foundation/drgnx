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

;;;; Applying, switching, keys.eld

(defmacro drgnx-keys-test--live (&rest body)
  "BODY with the core commands, fresh drgnx-keys state and a temp config dir; every binding is undone after."
  `(drgnx-keys-test--with-core-commands
    (let* ((dir (make-temp-file "drgnx-keys" t))
           (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir) (concat "XDG_STATE_HOME=" dir "/state"))
                                        process-environment))
           (drgnx-keys--applied nil) (drgnx-keys--session-layers nil) (drgnx-keys-profiles nil)
           (drgnx-keys-problems nil) (drgnx-keys-last nil))
      (unwind-protect (progn ,@body)
        (drgnx-keys--restore)
        (delete-directory dir t)))))

(defun drgnx-keys-test--write-user (form)
  (make-directory (drgnx-user-dir) t)
  (with-temp-file (expand-file-name "keys.eld" (drgnx-user-dir)) (prin1 form (current-buffer))))

(ert-deftest drgnx-keys/switching-rebinds-and-restores-emacs ()
  (let ((before (copy-keymap global-map)))
    (drgnx-keys-test--live
     (drgnx-keys-use '((vscode app editing window)))
     (should (eq (keymap-lookup global-map "C-o") #'find-file))
     (should (eq (keymap-lookup global-map "C-k C-s") #'drgnx-surfaces-cheatsheet))
     (should (eq (keymap-lookup global-map "<f1>") #'drgnx-palette))
     (drgnx-keys-use '((emacs app editing window)))
     (should (eq (keymap-lookup global-map "C-o") #'open-line))
     (should (eq (keymap-lookup global-map "C-k") #'kill-line))
     (should (keymapp (keymap-lookup global-map "<f1>")))
     (should (eq (keymap-lookup global-map "C-h C-k") #'drgnx-surfaces-cheatsheet))
     (drgnx-keys-use '((vscode app editing window)))
     (should (eq (keymap-lookup global-map "C-o") #'find-file)))
    ;; Everything drgnx bound is gone again (the menu bar keeps the generated menus).
    (cl-flet ((strip (m) (let ((c (copy-keymap m))) (define-key c [menu-bar] nil) c)))
      (should (equal (strip global-map) (strip before))))))

(ert-deftest drgnx-keys/a-binding-changed-by-someone-else-is-kept ()
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (keymap-set global-map "C-o" #'ignore)
   (unwind-protect
       (progn (drgnx-keys-use '((emacs app editing window)))
              (should (eq (keymap-lookup global-map "C-o") #'ignore)))
     (keymap-set global-map "C-o" #'open-line))))

(defvar drgnx-keys-test-late-map (make-sparse-keymap))

(ert-deftest drgnx-keys/deferred-bindings-of-an-old-setup-never-apply ()
  (drgnx-keys-test--live
   (drgnx-keys-test--write-user '(:bind ((open-file "C-c f" :map (drgnx-keys-test-feature-a . drgnx-keys-test-late-map)))))
   (drgnx-keys-apply)
   (should-not (eq (keymap-lookup drgnx-keys-test-late-map "C-c f") #'find-file))
   (drgnx-keys-test--write-user '(:bind ((save-file "C-c s" :map (drgnx-keys-test-feature-b . drgnx-keys-test-late-map)))))
   (drgnx-keys-apply)
   (provide 'drgnx-keys-test-feature-a)
   (should-not (eq (keymap-lookup drgnx-keys-test-late-map "C-c f") #'find-file))
   (provide 'drgnx-keys-test-feature-b)
   (should (eq (keymap-lookup drgnx-keys-test-late-map "C-c s") #'save-buffer))))

(defun drgnx-keys-test--menu-keys (title)
  "The :keys shown for the menu-bar item TITLE under View."
  (let (found)
    (map-keymap (lambda (_ item)
                  (when (and (eq (car-safe item) 'menu-item) (equal (nth 1 item) title))
                    (setq found (plist-get (nthcdr 3 item) :keys))))
                (keymap-lookup global-map "<menu-bar> <View>"))
    found))

(ert-deftest drgnx-keys/a-keys-eld-override-shows-on-every-surface ()
  (drgnx-keys-test--live
   (drgnx-keys-test--write-user '(:bind ((palette "C-c p"))))
   (drgnx-keys-apply)
   (should (eq (keymap-lookup global-map "C-c p") #'drgnx-palette))
   (should (null (keymap-lookup global-map "C-S-p")))
   (should (equal (drgnx-surfaces-key (drgnx-commands-get 'palette)) "C-c p"))
   (should (seq-find (lambda (r) (and (equal (nth 2 r) "Command Palette") (equal (nth 1 r) "C-c p")))
                     (drgnx-surfaces-sheet-rows)))
   (drgnx-surfaces-build-menus)
   (should (equal (drgnx-keys-test--menu-keys "Command Palette") "C-c p"))
   (let (annotation)
     (cl-letf (((symbol-function 'completing-read)
                (lambda (_prompt table &rest _)
                  (setq annotation (funcall (alist-get 'annotation-function (cdr (funcall table "" nil 'metadata)))
                                            "View: Command Palette"))
                  "")))
       (drgnx-palette))
     (should (string-search "C-c p" annotation)))))

(ert-deftest drgnx-keys/a-broken-keys-eld-is-a-problem-not-an-error ()
  (drgnx-keys-test--live
   (make-directory (drgnx-user-dir) t)
   (with-temp-file (expand-file-name "keys.eld" (drgnx-user-dir)) (insert "(:bind ((palette \"C-c p\")"))
   (drgnx-keys-apply)
   (should (seq-find (lambda (p) (string-search "keys.eld" p)) (plist-get drgnx-keys-last :problems)))
   (should (eq (keymap-lookup global-map "C-o") #'find-file))))

(ert-deftest drgnx-keys/keyboard-profile-command-switches-and-saves ()
  (drgnx-keys-test--live
   (drgnx-keys-test--write-user '(:bind ((line-numbers "C-c l"))))
   (drgnx-keys-apply)
   (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Emacs editing + VS Code app keys")))
     (call-interactively #'drgnx-keys-choose-profile))
   (let ((saved (with-temp-buffer (insert-file-contents (expand-file-name "keys.eld" (drgnx-user-dir)))
                                  (read (current-buffer)))))
     (should (equal (plist-get saved :layers) '((emacs editing) (vscode app window))))
     (should (equal (plist-get saved :bind) '((line-numbers "C-c l")))))
   (should (equal (plist-get drgnx-keys-last :layers) '((emacs editing) (vscode app window))))
   (should (drgnx-keys-test--conflict drgnx-keys-last "C-o"))))

;;;; The report

(ert-deftest drgnx-keys/conflicts-on-the-sheet-and-in-the-report-file ()
  (let* ((state (make-temp-file "drgnx-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment)))
    (unwind-protect
        (drgnx-keys-test--live
         (drgnx-keys-test--write-user '(:layers ((emacs editing) (vscode app window)) :bind ((nope "C-c n"))))
         (drgnx-keys-apply)
         (let ((report (with-temp-buffer (insert-file-contents (expand-file-name "keys-report.eld" (drgnx-state-dir)))
                                         (read (current-buffer)))))
           (should (equal (plist-get report :layers) '((emacs editing) (vscode app window))))
           (should (seq-find (lambda (s) (string-match-p "\\`C-o .*Open File.*vscode.*open-line.*emacs" s))
                             (plist-get report :conflicts)))
           (should (seq-find (lambda (s) (string-search "nope" s)) (plist-get report :problems))))
         (drgnx-surfaces-cheatsheet)
         (with-current-buffer "*drgnx keys*"
           (should (string-search "Key conflicts" (buffer-string)))
           (should (string-match-p "C-o .*Open File" (buffer-string)))
           (should (string-search "keys.eld: no command nope" (buffer-string))))
         (kill-buffer "*drgnx keys*"))
      (delete-directory state t))))

;;;; Review fixes

(ert-deftest drgnx-keys/no-keys-eld-mistake-breaks-apply ()
  ;; Startup (drgnx-init → drgnx-keys-apply) must survive any keys.eld; each mistake is a problem.
  (dolist (form '((:bind (palette "C-c p")) (:layers foo) (:layers ((vscode . app))) (:bind foo)
                  (:bind ((palette . "C-c p"))) (:bind ((palette "C-c p" :map "org-mode-map")))
                  (:bind ((palette "C-c p" :map 5))) (:unbind palette) (:layers ((vscode apps))) (:layers ((vscode)))
                  (:bind ((palette C-c))) (:bind ((palette))) (:bind ((palette "C-c p" :map (org-mode-map))))
                  (:bind ((palette "C-c p" :mac 7)))))
    (drgnx-keys-test--live
     (drgnx-keys-test--write-user form)
     (should (equal (list form :ok) (list form (and (drgnx-keys-apply) :ok))))
     (should (equal (list form t) (list form (and (seq-find (lambda (p) (string-search "keys.eld" p))
                                                            (plist-get drgnx-keys-last :problems))
                                                  t))))
     ;; The default stack still applies.
     (should (equal (list form #'find-file) (list form (keymap-lookup global-map "C-o" nil t)))))))

(ert-deftest drgnx-keys/an-internal-error-is-a-problem-not-a-crash ()
  (drgnx-keys-test--live
   (cl-letf (((symbol-function 'drgnx-keys-resolve) (lambda (&rest _) (error "Boom"))))
     (should (drgnx-keys-apply))
     (should (seq-find (lambda (p) (string-search "Boom" p)) (plist-get drgnx-keys-last :problems))))))

(defun drgnx-keys-test--other () (interactive))

(ert-deftest drgnx-keys/remapped-commands-do-not-confuse-switching ()
  ;; A global remap of find-file (helm, counsel, ido setups) and a buffer-local remap of open-line.
  (keymap-set global-map "<remap> <find-file>" #'drgnx-keys-test--other)
  (unwind-protect
      (drgnx-keys-test--live
       (with-temp-buffer
         (let ((local (make-sparse-keymap)))
           (keymap-set local "<remap> <open-line>" #'drgnx-keys-test--other)
           (keymap-set local "<remap> <kill-line>" #'drgnx-keys-test--other)
           (use-local-map local)
           (drgnx-keys-use '((vscode app editing window)))
           (drgnx-keys-use '((emacs app editing window)))))
       (should (eq (keymap-lookup global-map "C-o" nil t) #'open-line))
       (should (eq (keymap-lookup global-map "C-k" nil t) #'kill-line)))
    (keymap-unset global-map "<remap> <find-file>" t)))

(ert-deftest drgnx-keys/modules-add-to-the-shipped-profiles ()
  (drgnx-keys-test--live
   (drgnx-command-define 'test-git :title "Git" :category "Test" :command #'drgnx-keys-test--other)
   (drgnx-keys-define 'vscode '((test-git "C-c g")))
   (drgnx-keys-define 'vim '((test-git "SPC g g")))
   (drgnx-keys-apply)
   (should (eq (keymap-lookup global-map "C-S-p" nil t) #'drgnx-palette))
   (should (eq (keymap-lookup global-map "C-c g" nil t) #'drgnx-keys-test--other))
   (let ((r (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles drgnx-keys-profiles
                                :layers '((vim app editing window)) :defaults drgnx-keys-test--defaults)))
     (should (equal (plist-get (seq-find (lambda (b) (eq (plist-get b :id) 'test-git)) (plist-get r :bindings)) :map)
                    '(evil . evil-normal-state-map))))))

(ert-deftest drgnx-keys/prefix-clashes-between-drgnx-bindings ()
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window)) :user '(:bind ((line-numbers "C-k"))))))
    (should (eq (plist-get (drgnx-keys-test--conflict r "C-k") :kind) 'prefix))
    (should (equal (drgnx-keys-test--keys r 'line-numbers) '("C-k")))
    (should (null (drgnx-keys-test--keys r 'keys-sheet)))
    (should (null (drgnx-keys-test--keys r 'keyboard-profile))))
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window)) :user '(:bind ((line-numbers "C-o C-l"))))))
    (should (eq (plist-get (drgnx-keys-test--conflict r "C-o C-l") :kind) 'prefix))
    (should (null (drgnx-keys-test--keys r 'open-file)))))

(defvar drgnx-keys-test-rv-map (let ((m (make-sparse-keymap))) (keymap-set m "C-c C-c" #'ignore) m))

(ert-deftest drgnx-keys/prefix-checks-in-mode-keymaps ()
  (drgnx-keys-test--live
   (drgnx-keys-test--write-user '(:bind ((palette "C-c C-c x" :map drgnx-keys-test-rv-map))))
   (unwind-protect
       (progn
         (drgnx-keys-apply)
         (let ((c (drgnx-keys-test--conflict drgnx-keys-last "C-c C-c x")))
           (should (eq (plist-get c :kind) 'prefix))
           (should (eq (plist-get c :map) 'drgnx-keys-test-rv-map))))
     (drgnx-keys--restore)
     (should (eq (keymap-lookup drgnx-keys-test-rv-map "C-c C-c") #'ignore)))))

(ert-deftest drgnx-keys/which-key-labels-follow-switches ()
  (skip-unless (require 'which-key nil t))
  (let ((which-key-replacement-alist which-key-replacement-alist)
        (after-load-alist after-load-alist) (features features))
    (defvar evil-normal-state-map)
    (let ((evil-normal-state-map (make-sparse-keymap)))
      (drgnx-keys-test--live
       (drgnx-keys-use '((vim app editing window)))
       (drgnx-keys-use '((vscode app editing window)))
       (drgnx-keys-use '((emacs app editing window)))
       (let ((titles (mapcar (lambda (e) (cdr-safe (cdr e))) which-key-replacement-alist)))
         ;; Exactly the active labels: Open File… for C-x C-f, once, none left from VS Code's C-o.
         (should (= 1 (seq-count (lambda (tt) (equal tt "Open File…")) titles)))
         (should-not (seq-find (lambda (e) (and (equal (cdr-safe (cdr e)) "Open File…")
                                                (string-match-p (or (car-safe (car e)) "\\`\\'") "C-o")))
                               which-key-replacement-alist)))
       ;; evil arriving later gets neither stale bindings nor stale labels.
       (provide 'evil)
       (should (null (keymap-lookup evil-normal-state-map "SPC")))))))

(ert-deftest drgnx-keys/claims-are-against-emacs-not-drgnx ()
  (drgnx-keys-test--live
   (drgnx-keys-use '((emacs app editing window)))
   (drgnx-keys-test--write-user '(:bind ((line-numbers "C-h C-k"))))
   (drgnx-keys-apply)
   (should-not (seq-find (lambda (c) (and (equal (plist-get c :key) "C-h C-k") (eq (plist-get c :kind) 'claim)))
                         (plist-get drgnx-keys-last :conflicts)))))

(ert-deftest drgnx-keys/an-empty-keys-eld-is-fine ()
  (drgnx-keys-test--live
   (make-directory (drgnx-user-dir) t)
   (with-temp-file (drgnx-keys-file) (insert ";; my keys, later\n"))
   (drgnx-keys-apply)
   (should (null (plist-get drgnx-keys-last :problems)))
   (drgnx-keys-choose-profile "Emacs")
   (should (string-search ";; my keys, later" (with-temp-buffer (insert-file-contents (drgnx-keys-file)) (buffer-string))))
   (should (equal (plist-get (drgnx-keys-read-user) :layers) '((emacs app editing window))))))

(ert-deftest drgnx-keys/keyboard-profile-keeps-comments ()
  (drgnx-keys-test--live
   (make-directory (drgnx-user-dir) t)
   (with-temp-file (drgnx-keys-file)
     (insert ";; my keys\n(:layers ((vscode app editing window)) ; was VS Code\n :bind ((palette \"C-c p\")) ; palette on C-c p\n)\n"))
   (drgnx-keys-choose-profile "Emacs")
   (let ((text (with-temp-buffer (insert-file-contents (drgnx-keys-file)) (buffer-string))))
     (should (string-search ";; my keys" text))
     (should (string-search "; palette on C-c p" text)))
   (should (equal (drgnx-keys-read-user) '(:layers ((emacs app editing window)) :bind ((palette "C-c p")))))))

(ert-deftest drgnx-keys/a-commands-own-keymap-beats-the-profiles ()
  ;; Mode-local commands (the Explorer's) stay in their mode's keymap in the Vim profile too.
  (drgnx-keys-test--with-core-commands
   (drgnx-command-define 'test-local :title "Local" :category "Test" :command #'ignore :map 'drgnx-keys-test-rv-map)
   (let ((r (drgnx-keys-resolve :commands (drgnx-commands-all)
                                :profiles '((vim :map (evil . evil-normal-state-map) :bind ((test-local "j") (open-file "SPC f f"))))
                                :layers '((vim app editing window)) :defaults drgnx-keys-test--defaults)))
     (should (eq (plist-get (seq-find (lambda (b) (eq (plist-get b :id) 'test-local)) (plist-get r :bindings)) :map)
                 'drgnx-keys-test-rv-map))
     (should (equal (plist-get (seq-find (lambda (b) (eq (plist-get b :id) 'open-file)) (plist-get r :bindings)) :map)
                    '(evil . evil-normal-state-map))))))

(defvar drgnx-keys-test-mode-map (make-sparse-keymap))

(ert-deftest drgnx-keys/an-unbound-prefix-is-no-conflict ()
  ;; Vim's "g o" in a mode keymap where g is unbound: nothing is replaced, nothing to report.
  (drgnx-keys-test--with-core-commands
   (drgnx-command-define 'test-go :title "Go" :category "Test" :command #'ignore :map 'drgnx-keys-test-mode-map)
   (let ((r (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles '((vim :bind ((test-go "g o"))))
                                :layers '((vim app editing window)) :defaults drgnx-keys-test--defaults
                                :maps (lambda (m) (symbol-value m)))))
     (should-not (drgnx-keys-test--conflict r "g o")))))

(ert-deftest drgnx-keys/buffers-panel-has-a-right-click-menu ()
  ;; The keys tables say "right-click" for these; the menu must exist.
  (drgnx-keys-test--with-core-commands
   (should (assq 'buffers drgnx-surfaces-contexts))
   (dolist (id '(buffers-open buffers-close buffers-close-others save-all))
     (should (memq 'buffers (ensure-list (drgnx-cmd-context (drgnx-commands-get id))))))))

(ert-deftest drgnx-keys/emacs-profile-keeps-stock-save-some-buffers ()
  ;; Save All saves without asking; C-x s is Emacs' asking save — not rebound in the Emacs profile.
  (let ((r (drgnx-keys-test--resolve '((emacs app editing window)))))
    (should-not (drgnx-keys-test--keys r 'save-all))))

;;;; Deferred fixes

(defvar drgnx-keys-test-late-prefix-map (let ((m (make-sparse-keymap))) (keymap-set m "C-c" #'drgnx-keys-test--other) m))

(ert-deftest drgnx-keys/a-late-binding-reaches-the-sheet-and-the-report ()
  ;; M2.6-1: a binding made when its keymap's feature loads later — failing, or lifting a prefix —
  ;; is in drgnx-keys-last (the key sheet) and in keys-report.eld, not only in drgnx-keys-problems.
  (drgnx-keys-test--live
   (drgnx-keys-test--write-user '(:bind ((open-file "C-c f" :map (drgnx-keys-test-feature-c . drgnx-keys-test-no-such-map))
                                         (save-file "C-c s" :map (drgnx-keys-test-feature-d . drgnx-keys-test-late-prefix-map)))))
   (drgnx-keys-apply)
   (should-not (seq-find (lambda (p) (string-search "drgnx-keys-test-no-such-map" p)) (plist-get drgnx-keys-last :problems)))
   (provide 'drgnx-keys-test-feature-c)
   (provide 'drgnx-keys-test-feature-d)
   (let ((report (with-temp-buffer (insert-file-contents (expand-file-name "keys-report.eld" (drgnx-state-dir)))
                                   (read (current-buffer)))))
     (dolist (problems (list (plist-get drgnx-keys-last :problems) (plist-get report :problems)))
       (should (seq-find (lambda (p) (string-search "drgnx-keys-test-no-such-map" p)) problems)))
     (should (eq (plist-get (drgnx-keys-test--conflict drgnx-keys-last "C-c s") :kind) 'prefix))
     (should (seq-find (lambda (s) (string-match-p "\\`C-c s .*drgnx-keys-test--other" s)) (plist-get report :conflicts))))))

(ert-deftest drgnx-keys/keyboard-profile-empty-answer-keeps-the-current-one ()
  ;; M2.6-2: RET on an empty answer is the current profile, not `:layers nil'; an unknown name is an error.
  (drgnx-keys-test--live
   (drgnx-keys-test--write-user '(:layers ((emacs app editing window))))
   (drgnx-keys-apply)
   (cl-letf (((symbol-function 'completing-read)      ; RET at once: the default, as completing-read does
              (lambda (_prompt _coll &optional _pred _req _init _hist def &rest _) (or (car (ensure-list def)) ""))))
     (call-interactively #'drgnx-keys-choose-profile))
   (should (equal (plist-get (drgnx-keys-read-user) :layers) '((emacs app editing window))))
   (should-error (drgnx-keys-choose-profile "") :type 'user-error)
   (should-error (drgnx-keys-choose-profile "Sublime") :type 'user-error)
   (should (equal (plist-get (drgnx-keys-read-user) :layers) '((emacs app editing window))))))

(ert-deftest drgnx-keys/one-key-written-two-ways-is-one-key ()
  ;; M2.6-7: "TAB" and "C-i" are the same key: two commands on them conflict, and a claim on one meets the other.
  (drgnx-keys-test--with-core-commands
   (let ((r (drgnx-keys-resolve :commands (drgnx-commands-all) :defaults drgnx-keys-test--defaults
                                :profiles '((a :bind ((open-file "TAB"))) (b :bind ((save-file "C-i"))))
                                :layers '((a app editing window) (b app editing window)))))
     (should (eq (plist-get (seq-find (lambda (c) (member (plist-get c :key) '("TAB" "C-i"))) (plist-get r :conflicts)) :kind)
                 'same-key))
     (should (equal (drgnx-keys-test--keys r 'save-file) '("C-i")))
     (should-not (drgnx-keys-test--keys r 'open-file))))
  (drgnx-keys-test--with-core-commands
   (let ((r (drgnx-keys-resolve :commands (drgnx-commands-all) :defaults drgnx-keys-test--defaults
                                :profiles '((a :bind () :claims ((app "C-i" "indent the C-i way")))
                                            (b :bind ((save-file "TAB"))))
                                :layers '((a app editing window) (b app editing window)))))
     (should (seq-find (lambda (c) (and (eq (plist-get c :kind) 'claim)
                                        (equal (plist-get (car (plist-get c :losers)) :claim) "indent the C-i way")))
                       (plist-get r :conflicts))))))

(ert-deftest drgnx-keys/prefix-conflicts-over-one-command-are-one-line ()
  ;; M3b-3: VS Code's C-k chords each replace kill-line: one line for them all on the sheet, in the
  ;; report and in the count; the resolver still has one conflict per key.
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (let* ((per-key (seq-filter (lambda (c) (string-prefix-p "C-k " (plist-get c :key))) (plist-get drgnx-keys-last :conflicts)))
          (lines (seq-filter (lambda (l) (string-search "kill-line" l)) (drgnx-keys-conflict-lines))))
     (should (> (length per-key) 3))
     (should (= (length lines) 1))
     (should (string-prefix-p "C-k " (car lines)))
     (should (string-search "Keyboard Shortcuts" (car lines)))
     (should (string-search "C-k C-s" (car lines)))
     (should (string-search (format "%d keys" (length per-key)) (car lines)))
     (should (seq-find (lambda (l) (string-prefix-p "<f1> " l)) (drgnx-keys-conflict-lines))))
   (let (said)
     (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
       (drgnx-keys-choose-profile "VS Code"))
     (should (string-search (format "%d conflict" (length (drgnx-keys-conflict-lines))) said)))))
