;;; core-keys-test.el --- batch tests: key profiles, layers and conflicts -*- lexical-binding: t -*-
(require 'ert)
(defvar features)                                      ; bound dynamically below
(require 'drgnx)

(defconst drgnx-keys-test--profiles
  (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))
  "The shipped profiles.")

(defconst drgnx-keys-test--defaults (copy-keymap global-map)
  "Emacs' own bindings, as `drgnx-keys' snapshots them.")

(defvar drgnx-keys-test--later-stages nil
  "Non-nil: `drgnx-keys-test--with-core-commands' also sets up the idle, first-frame, first-file and first-input modules.")

(defvar drgnx-agents-request-functions)
(defvar drgnx-agents-changed-functions)
(defvar drgnx-wb--areas)
(defvar drgnx-layouts-pane-fillers)
(defvar drgnx-layouts-shapes)
(defvar drgnx-persist-state-functions)
(defvar drgnx-persist-after-restore-functions)

(defmacro drgnx-keys-test--with-core-commands (&rest body)
  "BODY with a registry holding the core commands (core + core/basics) and the two replace commands
that took VS Code's C-S-h and F2 (the rest of the replace module is not modelled here), nothing else — and with
`drgnx-keys-test--later-stages', the commands of the later stages' modules whose packages need nothing installed.
What those modules hook into (find-file, the agents, the panel tabs, the layouts' pane fillers, the persist hooks)
is undone after BODY."
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (drgnx-commands-problems nil) (drgnx-modules--table nil) (drgnx-modules--report nil)
         (find-file-hook find-file-hook)
         (drgnx-agents-request-functions (bound-and-true-p drgnx-agents-request-functions))
         (drgnx-agents-changed-functions (bound-and-true-p drgnx-agents-changed-functions))
         (drgnx-wb--areas (copy-tree (bound-and-true-p drgnx-wb--areas)))
         (drgnx-layouts-pane-fillers (copy-tree (bound-and-true-p drgnx-layouts-pane-fillers)))
         (drgnx-layouts-shapes (copy-tree (bound-and-true-p drgnx-layouts-shapes)))
         (drgnx-persist-state-functions (bound-and-true-p drgnx-persist-state-functions))
         (drgnx-persist-after-restore-functions (bound-and-true-p drgnx-persist-after-restore-functions))
         (ring-bell-function ring-bell-function) (use-dialog-box use-dialog-box)
         (use-short-answers use-short-answers) (inhibit-startup-screen inhibit-startup-screen))
     (drgnx--core-commands)
     (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
     (drgnx-modules-run 'startup)
     (drgnx-command-define 'replace-in-files :category "Search" :title "Replace in Files" :command #'ignore :doc "test")
     (drgnx-command-define 'rename-symbol :category "Search" :title "Rename Symbol" :command #'ignore :doc "test")
     (when drgnx-keys-test--later-stages
       ;; A module that needs a package (magit, avy, websocket, …) stays out whatever this machine has installed.
       ;; (Another test file's packages cannot be loaded here: each file runs in an Emacs of its own.)
       (cl-letf (((symbol-function 'locate-library) (lambda (&rest _) nil)))
         (dolist (stage (cdr drgnx-modules-stages)) (drgnx-modules-run stage))))
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
    (should (eq (plist-get (drgnx-keys-test--conflict r "C-k C-r") :kind) 'prefix))
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

(ert-deftest drgnx-keys/vim-commands-are-on-the-leader-map ()
  (let ((r (drgnx-keys-test--resolve '((vim app editing window)))))
    (should (equal (drgnx-keys-test--keys r 'open-file) '("SPC f f")))
    (should (equal (plist-get (seq-find (lambda (b) (eq (plist-get b :id) 'open-file)) (plist-get r :bindings)) :map)
                   'drgnx-modal-leader-map))))

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
    (should (equal (drgnx-keys-test--keys r 'keys-sheet) '("s-k s-r"))))
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
     (should (eq (keymap-lookup global-map "C-k C-r") #'drgnx-surfaces-cheatsheet))
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
                    'drgnx-modal-leader-map)))))

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
       (dolist (key '("SPC" "SPC SPC" "SPC f f"))      ; nil, a too-long key (1) or an empty prefix map: no command
         (should-not (commandp (keymap-lookup evil-normal-state-map key))))))))

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
     (should (string-search "C-k C-r" (car lines)))
     (should (string-search (format "%d keys" (length per-key)) (car lines)))
     (should (seq-find (lambda (l) (string-prefix-p "<f1> " l)) (drgnx-keys-conflict-lines))))
   (let (said)
     (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
       (drgnx-keys-choose-profile "VS Code"))
     (should (string-search (format "%d conflict" (length (drgnx-keys-conflict-lines))) said)))))

;;;; Keys that work in every mode (M3c-1)

(ert-deftest drgnx-keys/everywhere-key-beats-mode-maps ()
  ;; `:everywhere KEYS' on an entry also puts the keys in an override keymap on `emulation-mode-map-alists':
  ;; C-j is lisp-interaction mode's (eval-print-last-sexp) otherwise.  Re-applying without the flag removes it.
  (drgnx-keys-test--live
   (let ((panel (drgnx-cmd-command (drgnx-commands-get 'toggle-panel))))
     (with-temp-buffer
       (lisp-interaction-mode)
       (drgnx-keys-test--write-user '(:layers ((emacs app editing window)) :bind ((toggle-panel "C-c j" :everywhere "C-j"))))
       (drgnx-keys-apply)
       (should (null (plist-get drgnx-keys-last :problems)))
       (should (eq (key-binding (kbd "C-j")) panel))
       (should (eq (key-binding (kbd "C-c j")) panel))
       (should (eq (keymap-lookup global-map "C-j") panel))
       (should (memq 'drgnx-keys--everywhere-alist emulation-mode-map-alists))
       ;; not in the minibuffer, where C-j means something else: the layer steps aside, the local map answers
       (cl-letf (((symbol-function 'minibufferp) (lambda (&rest _) t)))
         (should (eq (key-binding (kbd "C-j")) 'eval-print-last-sexp)))
       (should (eq (plist-get (car (seq-filter (lambda (b) (equal (plist-get b :key) "C-j")) (plist-get drgnx-keys-last :bindings)))
                              :everywhere)
                   t))
       ;; Applying again with the flag keeps one layer, not two.
       (drgnx-keys-apply)
       (should (= 1 (length (seq-filter (lambda (m) (eq m 'drgnx-keys--everywhere-alist)) emulation-mode-map-alists))))
       ;; Without the flag the mode's key is back, and the override layer is gone.
       (drgnx-keys-test--write-user '(:layers ((emacs app editing window)) :bind ((toggle-panel "C-c j"))))
       (drgnx-keys-apply)
       (should (eq (key-binding (kbd "C-j")) 'eval-print-last-sexp))
       (should-not (memq 'drgnx-keys--everywhere-alist emulation-mode-map-alists))
       (should (equal (cdr drgnx-keys--everywhere-map) nil))))))

(ert-deftest drgnx-keys/vscode-c-j-toggles-the-panel-in-every-mode ()
  ;; VS Code's Toggle Panel (C-j) is not shadowed by lisp-interaction or Org mode; the Emacs profile leaves it alone.
  (drgnx-keys-test--live
   (let ((panel (drgnx-cmd-command (drgnx-commands-get 'toggle-panel))))
     (drgnx-keys-use '((vscode app editing window)))
     (with-temp-buffer
       (lisp-interaction-mode)
       (should (eq (key-binding (kbd "C-j")) panel))
       (drgnx-keys-use '((emacs app editing window)))
       (should (eq (key-binding (kbd "C-j")) 'eval-print-last-sexp))
       (should-not (memq 'drgnx-keys--everywhere-alist emulation-mode-map-alists)))
     (with-temp-buffer
       (require 'org)
       (org-mode)
       (drgnx-keys-use '((vscode app editing window)))
       (should (eq (key-binding (kbd "C-j")) panel))))))

(ert-deftest drgnx-keys/everywhere-is-a-valid-entry-option ()
  (should-not (drgnx-keys--entry-error '(toggle-panel "C-`" :everywhere "C-j")))
  (should-not (drgnx-keys--entry-error '(toggle-panel "C-`" :everywhere ("C-j" "C-M-j") :mac "s-j")))
  (should (drgnx-keys--entry-error '(toggle-panel "C-`" :everywhere 5)))
  (should (drgnx-keys--entry-error '(toggle-panel "C-`" :everywhere))))

(ert-deftest drgnx-keys/everywhere-keys-follow-mac-like-the-others ()
  ;; On macOS they become Cmd keys; an entry's own :mac replaces them with the others.
  (let ((profiles '((p :mac-cmd t :bind ((toggle-panel "C-`" :everywhere "C-j") (palette "C-p" :everywhere "C-i" :mac "s-p"))))))
    (should (equal (drgnx-keys--entry '(toggle-panel "C-`" :everywhere "C-j") (cdar profiles) 'macos)
                   '(:keys ("s-`" "s-j") :everywhere ("s-j") :map nil :profile-map nil)))
    (should (equal (drgnx-keys--entry '(palette "C-p" :everywhere "C-i" :mac "s-p") (cdar profiles) 'macos)
                   '(:keys ("s-p") :map nil :profile-map nil)))
    (should (equal (plist-get (drgnx-keys--entry '(toggle-panel "C-`" :everywhere "C-j") (cdar profiles) 'linux) :everywhere)
                   '("C-j")))))

(ert-deftest drgnx-keys/everywhere-entry-needs-one-stroke-keys ()
  ;; A key alone is an entry (m2); a chord would make its first key a prefix in every mode and in the minibuffer (m3).
  (should-not (drgnx-keys--entry-error '(toggle-panel :everywhere "C-j")))
  (should (drgnx-keys--entry-error '(toggle-panel "C-`" :everywhere "C-k j")))
  (should (drgnx-keys--entry-error '(toggle-panel "C-`" :everywhere ("C-j" "C-k j"))))
  (should (drgnx-keys--entry-error '(toggle-panel))))

(ert-deftest drgnx-keys/everywhere-in-a-mode-map-is-a-problem ()
  ;; The override layer is global: an :everywhere key bound in a mode keymap says so instead of leaking out.
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window))
                                     :user '(:bind ((toggle-panel "C-`" :everywhere "C-j" :map org-mode-map))))))
    (should (seq-find (lambda (p) (string-search ":everywhere" p)) (plist-get r :problems)))
    (should-not (seq-find (lambda (b) (plist-get b :everywhere)) (plist-get r :bindings)))))

(ert-deftest drgnx-keys/user-mode-map-key-beats-everywhere ()
  ;; I1: keys.eld binds C-j in a mode map: that wins there, the profile's global C-j stays, and the sheet says so.
  (drgnx-keys-test--live
   (drgnx-keys-test--write-user '(:bind ((palette "C-j" :map lisp-interaction-mode-map))))
   (drgnx-keys-use '((vscode app editing window)))
   (let ((palette (drgnx-cmd-command (drgnx-commands-get 'palette)))
         (panel (drgnx-cmd-command (drgnx-commands-get 'toggle-panel)))
         (c (drgnx-keys-test--conflict drgnx-keys-last "C-j")))
     (with-temp-buffer
       (lisp-interaction-mode)
       (should (eq (key-binding (kbd "C-j")) palette)))
     (with-temp-buffer
       (fundamental-mode)
       (should (eq (key-binding (kbd "C-j")) panel)))
     (should-not (memq 'drgnx-keys--everywhere-alist emulation-mode-map-alists))
     (should c)
     (should (eq (plist-get c :kind) 'same-key))
     (should (eq (plist-get (plist-get c :winner) :id) 'palette))
     (should (eq (plist-get (car (plist-get c :losers)) :id) 'toggle-panel)))))

(ert-deftest drgnx-keys/everywhere-beats-a-lower-mode-map-key-and-says-so ()
  ;; The profile's rank above a lower layer's mode-map key: the override stays, and the shadowing is a conflict.
  (let* ((profiles '((a :bind ((palette "C-j" :map lisp-interaction-mode-map)))
                     (b :bind ((toggle-panel "C-`" :everywhere "C-j")))))
         (r (drgnx-keys-test--with-core-commands
             (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles profiles :defaults drgnx-keys-test--defaults
                                 :layers '((a app editing window) (b app editing window))))))
    (should (seq-find (lambda (b) (plist-get b :everywhere)) (plist-get r :bindings)))
    (should (eq (plist-get (plist-get (drgnx-keys-test--conflict r "C-j") :winner) :id) 'toggle-panel))))

(ert-deftest drgnx-keys/everywhere-only-where-the-profile-owns-editing ()
  ;; I2: a stack whose editing keys come from another profile keeps that profile's C-j in modes; Toggle Panel's
  ;; C-j is then the global binding only.  The pure VS Code stack has it everywhere.
  (cl-flet ((everywhere (layers) (seq-find (lambda (b) (plist-get b :everywhere))
                                           (plist-get (drgnx-keys-test--resolve layers) :bindings))))
    (should (everywhere '((vscode app editing window))))
    (dolist (layers '(((emacs editing) (vscode app window)) ((vim editing) (vscode app window))))
      (should-not (everywhere layers))
      (should (member "C-j" (drgnx-keys-test--keys (drgnx-keys-test--resolve layers) 'toggle-panel))))
    ;; an editing layer above the VS Code keys keeps C-j altogether (as before)
    (should-not (everywhere '((vscode app window) (emacs editing)))))
  (drgnx-keys-test--live
   (with-temp-buffer
     (lisp-interaction-mode)
     (drgnx-keys-use '((emacs editing) (vscode app window)))
     (should (eq (key-binding (kbd "C-j")) 'eval-print-last-sexp))
     (should-not (memq 'drgnx-keys--everywhere-alist emulation-mode-map-alists))
     (should (eq (keymap-lookup global-map "C-j") (drgnx-cmd-command (drgnx-commands-get 'toggle-panel)))))))

(ert-deftest drgnx-keys/restore-removes-the-everywhere-layer ()
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (should (memq 'drgnx-keys--everywhere-alist emulation-mode-map-alists))
   (should (cdr drgnx-keys--everywhere-map))
   (drgnx-keys--restore)
   (should-not (memq 'drgnx-keys--everywhere-alist emulation-mode-map-alists))
   (should-not (cdr drgnx-keys--everywhere-map))
   (should-not drgnx-keys--everywhere-on)))

;;;; macOS (M12a)

(defun drgnx-keys-test--on (r key &optional global)
  "The ids resolution R binds to KEY, in any keymap (with GLOBAL, in the global keymap)."
  (mapcar (lambda (b) (plist-get b :id))
          (seq-filter (lambda (b) (and (equal (drgnx-keys--parse (plist-get b :key)) (drgnx-keys--parse key))
                                       (not (and global (plist-get b :map)))))
                      (plist-get r :bindings))))

(defconst drgnx-keys-test--ns-defaults
  '(("s-," customize) ("s-'" next-window-any-frame) ("s-`" other-frame) ("s-~" ns-prev-frame) ("s-:" ispell)
    ("s-?" info) ("s-^" kill-some-buffers) ("s-&" kill-current-buffer) ("s-C" ns-popup-color-panel) ("s-D" dired)
    ("s-E" edit-abbrevs) ("s-L" shell-command) ("s-M" manual-entry) ("s-S" ns-write-file-using-panel)
    ("s-a" mark-whole-buffer) ("s-c" ns-copy-including-secondary) ("s-d" isearch-repeat-backward)
    ("s-e" isearch-yank-kill) ("s-f" isearch-forward) ("s-F" isearch-backward) ("s-g" isearch-repeat-forward)
    ("s-h" ns-do-hide-emacs) ("s-H" ns-do-hide-others) ("s-j" exchange-point-and-mark) ("s-k" kill-current-buffer)
    ("s-l" goto-line) ("s-m" iconify-frame) ("s-n" make-frame) ("s-o" ns-open-file-using-panel) ("s-p" ns-print-buffer)
    ("s-q" save-buffers-kill-emacs) ("s-s" save-buffer) ("s-t" menu-set-font) ("s-u" revert-buffer) ("s-v" yank)
    ("s-w" delete-frame) ("s-x" kill-region) ("s-y" ns-paste-secondary) ("s-z" undo) ("s-+" text-scale-adjust)
    ("s-=" text-scale-adjust) ("s--" text-scale-adjust) ("s-0" text-scale-adjust) ("s-|" shell-command-on-region)
    ("s-<right>" move-end-of-line) ("s-<left>" move-beginning-of-line) ("<home>" beginning-of-buffer)
    ("<end>" end-of-buffer))
  "The global keys Emacs' term/ns-win.el binds on macOS (Emacs 30), which a Linux test cannot load.")

(defun drgnx-keys-test--ns-global ()
  "Emacs' global keymap as it is on macOS: the Linux defaults plus ns-win's keys."
  (let ((m (copy-keymap drgnx-keys-test--defaults)))
    (pcase-dolist (`(,key ,cmd) drgnx-keys-test--ns-defaults) (keymap-set m key cmd))
    m))

(ert-deftest drgnx-keys/vscode-on-macos-matches-vscode ()
  ;; VS Code's own macOS keys where they are not its Linux key with Ctrl → Cmd; every key valid.
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window)) :platform 'macos)))
    (pcase-dolist (`(,id ,key) '((toggle-panel "C-`") (terminal-new "C-S-`") (go-recent "C-<tab>") (go-back "C--")
                                 (go-forward "C-_") (next-tab "M-s-<right>") (previous-tab "M-s-<left>")
                                 (file-close-window "s-W") (move-editor-to-next-group "C-s-<right>")
                                 (edit-expand "C-S-s-<right>") (edit-shrink "C-S-s-<left>")
                                 (explorer-copy-path "M-s-c") (explorer-reveal-externally "M-s-r") (quit "s-q")
                                 (preferences "s-,") (palette "s-P") (edit-select-all "s-a") (save-all "M-s-s")
                                 (scm-view "C-S-g") (edit-fold "M-s-[") (edit-unfold "M-s-]") (close-tab "s-w")
                                 (org-capture "C-c c") (explorer-copy-relative-path "M-s-C")
                                 (toggle-right-dock "M-s-b") (explorer-delete "s-<backspace>")))
      (should (equal (list id key t) (list id key (and (member key (drgnx-keys-test--keys r id)) t)))))
    (should-not (drgnx-keys-test--keys r 'preferences-modules))   ; s-, is Settings, as in VS Code
    (should (null (plist-get r :problems)))))

(ert-deftest drgnx-keys/vscode-on-macos-has-mac-text-editing ()
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window)) :platform 'macos)))
    (pcase-dolist (`(,key ,id) '(("s-<left>" edit-line-start) ("s-<right>" edit-line-end) ("s-<up>" edit-buffer-start)
                                 ("s-<down>" edit-buffer-end) ("M-<left>" edit-word-left) ("M-<right>" edit-word-right)
                                 ("M-<backspace>" edit-delete-word-back) ("s-<backspace>" edit-delete-line-back)))
      ;; In the global keymap (the Explorer's s-<backspace> deletes a file, Tab-accept's s-<right> a word)
      (should (equal (list key (list id)) (list key (drgnx-keys-test--on r key t)))))))

(ert-deftest drgnx-keys/vscode-on-macos-leaves-the-system-keys ()
  ;; Hide, minimise, next window, Spotlight and the app switcher are macOS'.
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window)) :platform 'macos)))
    (dolist (key '("s-h" "s-m" "s-`" "s-SPC" "s-<tab>"))
      (should (equal (list key nil) (list key (drgnx-keys-test--on r key)))))))

(ert-deftest drgnx-keys/cmd-shift-letters-are-what-ns-sends ()
  ;; GNU Emacs on macOS sends Cmd+Shift+P as s-P, never S-s-p (which no key press would reach: s-P unbound
  ;; is read as s-p, Quick Open).  Shift stays on named keys.
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window)) :platform 'macos)))
    (pcase-dolist (`(,id ,key) '((palette "s-P") (edit-redo "s-Z") (replace-in-files "s-H") (file-close-window "s-W")
                                 (explorer-copy-relative-path "M-s-C") (file-save-as "s-S")
                                 (edit-expand "C-S-s-<right>") (edit-line-above "S-s-<return>")))
      (should (equal (list id key t) (list id key (and (member key (drgnx-keys-test--keys r id)) t)))))
    (should-not (seq-find (lambda (b) (string-match-p "S-s-[a-z]\\(?: \\|\\'\\)" (plist-get b :key))) (plist-get r :bindings))))
  ;; keys.eld's :mac keys too.
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window)) :platform 'macos
                                     :user '(:bind ((line-numbers "C-c l" :mac "S-s-y"))))))
    (should (equal (drgnx-keys-test--keys r 'line-numbers) '("s-Y"))))
  (should (equal (drgnx-keys--mac-cmd "C-M-S-c") "M-s-C"))
  (should (equal (drgnx-keys--mac-cmd "C-S-x" t) "C-S-x"))
  (should (equal (drgnx-keys--mac-cmd "C-S-s-x" t) "C-s-X"))
  (should (equal (drgnx-keys--mac-cmd "C-k C-S-p") "s-k s-P"))
  ;; M12a-26: the letter check does not depend on `case-fold-search' (a capital is not a lower-case letter)
  (dolist (key '("C-S-X" "C-S-x" "S-s-X" "C-M-S-c"))
    (should (equal (let ((case-fold-search t)) (drgnx-keys--mac-cmd key))
                   (let ((case-fold-search nil)) (drgnx-keys--mac-cmd key))))))

(ert-deftest drgnx-keys/vscode-on-macos-has-no-conflicts ()
  ;; Against Emacs' macOS defaults (ns-win's s- keys): no two commands on one key, no problem, and the
  ;; only conflicts are the deliberate prefixes Linux has too — VS Code's Cmd+K chords over s-k, F1, F2.
  (let* ((r (drgnx-keys-test--with-core-commands
             (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles drgnx-keys-test--profiles
                                 :layers '((vscode app editing window)) :platform 'macos
                                 :defaults (drgnx-keys-test--ns-global))))
         (drgnx-keys-last r))
    (should (null (plist-get r :problems)))
    (should-not (seq-find (lambda (c) (not (eq (plist-get c :kind) 'prefix))) (plist-get r :conflicts)))
    (should (equal (sort (mapcar (lambda (l) (car (split-string l))) (drgnx-keys-conflict-lines)) #'string<)
                   '("<f1>" "<f2>" "s-k")))
    (should (string-search "kill-current-buffer (s-k)" (seq-find (lambda (l) (string-prefix-p "s-k " l))
                                                                 (drgnx-keys-conflict-lines))))
    ;; The ns-win keys VS Code takes over, on purpose (Cmd+Shift+letter included: s-S Save As, s-H Replace
    ;; in Project, …); the others stay Emacs' (s-c, s-v, s-x, s-z …).
    (should (equal (sort (seq-filter (lambda (key) (seq-find (lambda (b) (and (null (plist-get b :map))
                                                                              (equal (plist-get b :key) key)))
                                                             (plist-get r :bindings)))
                                     (mapcar #'car drgnx-keys-test--ns-defaults))
                         #'string<)
                   (sort (list "<end>" "<home>" "s-'" "s-+" "s-," "s--" "s-0" "s-<left>" "s-<right>" "s-=" "s-a"
                               "s-f" "s-l" "s-n" "s-o" "s-p" "s-q" "s-s" "s-t" "s-w" "s-S" "s-H" "s-M" "s-F"
                               "s-E")
                         #'string<)))
    ;; and s-L, Select All Occurrences — the extra/mc module's command, not in this registry
    (let ((vscode (alist-get 'vscode drgnx-keys-test--profiles)))
      (should (equal (plist-get (drgnx-keys--entry (assq 'edit-all-occurrences (plist-get vscode :bind)) vscode 'macos) :keys)
                     '("s-L"))))))

(defconst drgnx-keys-test--linux-snapshot
  '((open-folder "C-k C-o" nil) (palette "C-S-p" nil) (palette "<f1>" nil) (keys-sheet "C-k C-r" nil) (preferences-modules "C-," nil)
    (modules-toggle "RET" drgnx-modules-list-mode-map) (keyboard-profile "C-k C-p" nil) (open-file "C-o" nil)
    (save-file "C-s" nil) (file-save-as "C-S-s" nil) (file-new "C-n" nil) (file-reopen-tab "C-S-t" nil)
    (file-new-window "C-S-n" nil) (file-close-window "C-q" nil) (view-escape "<escape>" nil)
    (toggle-panel "C-`" nil) (toggle-panel "M-j" nil) (toggle-panel "C-j" nil) (toggle-right-dock "C-M-b" nil)
    (split-editor-right "C-\\" nil) (split-editor-down "C-k C-\\" nil) (close-group-editors "C-k w" nil)
    (focus-group-1 "C-1" nil) (focus-group-1 "M-1" nil) (focus-group-2 "C-2" nil) (focus-group-2 "M-2" nil)
    (focus-group-3 "C-3" nil) (focus-group-3 "M-3" nil) (move-editor-to-next-group "C-M-<right>" nil)
    (open-editor-in-new-window "C-k o" nil) (view-panel-next "M-`" nil) (help-mode-menu "C-'" nil)
    (close-tab "C-w" nil) (close-tab "C-<f4>" nil) (next-tab "C-<next>" nil) (previous-tab "C-<prior>" nil)
    (toggle-sidebar "C-b" nil) (dock-back "<escape>" drgnx-wb-dock-map)
    (explorer-next "<down>" drgnx-explorer-mode-map) (explorer-previous "<up>" drgnx-explorer-mode-map)
    (explorer-expand "<right>" drgnx-explorer-mode-map) (explorer-collapse "<left>" drgnx-explorer-mode-map)
    (explorer-open "RET" drgnx-explorer-mode-map) (explorer-preview "SPC" drgnx-explorer-mode-map)
    (explorer-select-down "S-<down>" drgnx-explorer-mode-map) (explorer-select-up "S-<up>" drgnx-explorer-mode-map)
    (explorer-mark "C-SPC" drgnx-explorer-mode-map) (explorer-find "C-M-f" drgnx-explorer-mode-map)
    (explorer-rename "<f2>" drgnx-explorer-mode-map) (explorer-delete "<delete>" drgnx-explorer-mode-map)
    (explorer-delete-permanently "S-<delete>" drgnx-explorer-mode-map) (explorer-copy "C-c" drgnx-explorer-mode-map)
    (explorer-cut "C-x" drgnx-explorer-mode-map) (explorer-paste "C-v" drgnx-explorer-mode-map)
    (explorer-copy-path "M-S-c" drgnx-explorer-mode-map)
    (explorer-copy-relative-path "C-M-S-c" drgnx-explorer-mode-map)
    (explorer-reveal-externally "M-S-r" drgnx-explorer-mode-map) (focus-outline "C-M-o" nil)
    (outline-open "RET" drgnx-outline-mode-map) (save-all "C-k s" nil) (close-saved "C-k u" nil)
    (close-all "C-k C-w" nil) (focus-buffers "C-k e" nil) (focus-buffers "C-S-b" nil)
    (buffers-next "<down>" drgnx-buffers-mode-map) (buffers-previous "<up>" drgnx-buffers-mode-map)
    (buffers-open "RET" drgnx-buffers-mode-map) (buffers-close "<delete>" drgnx-buffers-mode-map)
    (buffers-filter "C-M-f" drgnx-buffers-mode-map) (edit-fold "C-{" nil) (edit-unfold "C-}" nil)
    (edit-expand "M-S-<right>" nil) (edit-shrink "M-S-<left>" nil) (edit-select-all "C-S-a" nil)
    (edit-select-line "C-l" nil) (edit-redo "C-S-z" nil) (edit-comment "C-/" nil) (edit-delete-line "C-S-k" nil)
    (edit-move-up "M-<up>" nil) (edit-move-down "M-<down>" nil) (edit-duplicate "M-S-<down>" nil)
    (edit-line-below "C-<return>" nil) (edit-line-above "C-S-<return>" nil) (go-back "M-<left>" nil)
    (go-forward "M-<right>" nil) (code-definition "<f12>" nil) (code-references "S-<f12>" nil)
    (code-hover "C-S-SPC" nil) (code-quick-fix "C-." nil) (code-problems "C-S-m" nil)
    (org-capture "C-c c" nil) (org-agenda "C-c a" nil) (go-quick-open "C-p" nil)
    (go-symbol "C-S-o" nil) (go-symbol-project "C-t" nil) (go-recent "C-<tab>" nil) (search-file "C-f" nil)
    (search-semantic "C-k C-f" nil) (terminal-new "C-S-`" nil) (scm-view "C-S-g" nil)
    (view-zen "C-k z" nil)
    (view-zen "<f11>" nil) (view-zoom-in "C-=" nil) (view-zoom-in "C-+" nil) (view-zoom-out "C--" nil)
    (view-zoom-reset "C-0" nil) (agents-view "C-k a" nil) (agents-stop "C-c C-c" drgnx-agents-transcript-mode-map)
    (agents-deliver "C-c C-d" drgnx-agents-transcript-mode-map) (agents-open "RET" drgnx-agents-list-mode-map)
    (agents-reply "RET" drgnx-agents-transcript-mode-map)
    (agents-review-done "C-c C-c" drgnx-agents-review-mode-map)
    (agents-review-reject "C-c C-k" drgnx-agents-review-mode-map)
    (ai-accept-word "C-<right>" drgnx-ai-ghost-showing-map) (ai-dismiss "C-g" drgnx-ai-ghost-showing-map)
    (ai-tab "TAB" drgnx-ai-ghost-mode-map) (ai-edit "C-k C-e" nil)
    (ai-edit-apply-hunk "C-c C-a" drgnx-ai-edit-review-mode-map)
    (ai-edit-done "C-c C-c" drgnx-ai-edit-review-mode-map) (ai-edit-reject "C-c C-k" drgnx-ai-edit-review-mode-map)
    (work-view "C-k t" nil) (work-open "RET" drgnx-work-mode-map) (work-toggle "TAB" drgnx-work-mode-map)
    (work-refresh "g" drgnx-work-mode-map) (work-filter "f" drgnx-work-mode-map)
    (work-hide-merged "m" drgnx-work-mode-map)
    (diff-toggle-layout "s" drgnx-diff-mode-map) (diff-toggle-file "TAB" drgnx-diff-mode-map)
    (diff-next-file "n" drgnx-diff-mode-map) (diff-prev-file "p" drgnx-diff-mode-map)
    (diff-visit "RET" drgnx-diff-mode-map) (review-visit "RET" drgnx-review-mode-map)
    (review-show-diff "d" drgnx-review-mode-map))
  "The VS Code profile's resolved keys on Linux before M12a gave it its macOS keys: (ID KEY MAP).
The commands of modules that need no installed package are in it, the later stages' too (diff, review).")

(ert-deftest drgnx-keys/the-later-stages-leave-no-global-hooks-or-pane-fillers ()
  ;; Setting the modules up for the snapshot must not stay: a registered browser pane made the next layouts test
  ;; open a third editor group, the persist hooks changed every later restore.
  (require 'drgnx-persist)
  (let ((fillers (copy-tree (bound-and-true-p drgnx-layouts-pane-fillers)))
        (shapes (copy-tree (bound-and-true-p drgnx-layouts-shapes)))
        (state-fns (copy-sequence drgnx-persist-state-functions))
        (after-fns (copy-sequence drgnx-persist-after-restore-functions))
        (drgnx-keys-test--later-stages t))
    (drgnx-keys-test--with-core-commands (ignore))
    (should (equal (bound-and-true-p drgnx-layouts-pane-fillers) fillers))
    (should (equal (bound-and-true-p drgnx-layouts-shapes) shapes))
    (should (equal drgnx-persist-state-functions state-fns))
    (should (equal drgnx-persist-after-restore-functions after-fns))))

(ert-deftest drgnx-keys/linux-is-unchanged ()
  ;; The macOS work changes nothing on Linux but the keys of the commands it added — and the views
  ;; that took C-S-e, C-S-f, C-S-h and F2 (see `drgnx-keys/views-took-their-keys').
  (let* ((new '(view-explorer view-search replace-in-files rename-symbol   ; M12a's views took four of the keys
                              ;; the later stages' modules from M11c-1: replace, layouts, browser, shortcuts
                              replace-in-file replace-all replace-this replace-next replace-prev replace-bar-close
                              layout-next browser-go keyboard-shortcuts shortcuts-change shortcuts-add shortcuts-filter
                              shortcuts-record-filter shortcuts-conflicts shortcuts-no-key shortcuts-changed
                              shortcuts-undo shortcuts-reset shortcuts-reset-all shortcuts-profile
                              quit preferences edit-line-start edit-line-end edit-buffer-start edit-buffer-end edit-word-left
                              edit-word-right edit-delete-word-back edit-delete-line-back))
         (drgnx-keys-test--later-stages t)
         (r (drgnx-keys-test--resolve '((vscode app editing window)) :platform 'linux)))
    (should (equal (mapcar (lambda (b) (list (plist-get b :id) (plist-get b :key) (plist-get b :map)))
                           (seq-remove (lambda (b) (memq (plist-get b :id) new)) (plist-get r :bindings)))
                   drgnx-keys-test--linux-snapshot))
    (should (equal (drgnx-keys-test--keys r 'edit-line-start) '("<home>")))
    (should (equal (drgnx-keys-test--keys r 'edit-word-left) '("C-<left>")))
    (should-not (drgnx-keys-test--keys r 'quit))
    (should-not (drgnx-keys-test--keys r 'preferences))))

(ert-deftest drgnx-keys/views-took-their-keys ()
  ;; After M12a: VS Code's C-S-e / C-S-f / C-S-h / F2 and Vim's SPC s r / SPC c R belong to the new views.
  (let ((vscode (drgnx-keys-test--resolve '((vscode app editing window)) :platform 'linux))
        (vim (drgnx-keys-test--resolve '((vim app editing window)) :platform 'linux)))
    (pcase-dolist (`(,id . ,key) '((view-explorer . "C-S-e") (view-search . "C-S-f")
                                   (replace-in-files . "C-S-h") (rename-symbol . "<f2>")))
      (should (equal (drgnx-keys-test--keys vscode id) (list key))))
    (dolist (id '(focus-explorer search-project search-replace code-rename))
      (should-not (drgnx-keys-test--keys vscode id)))
    (should (equal (drgnx-keys-test--keys vim 'replace-in-files) '("SPC s r")))
    (should (equal (drgnx-keys-test--keys vim 'rename-symbol) '("SPC c R")))
    (dolist (id '(search-replace code-rename)) (should-not (drgnx-keys-test--keys vim id)))))

(defvar drgnx-keys-test--cmd-mod 'meta)
(defvar drgnx-keys-test--alt-mod 'alt)
(defvar drgnx-keys-test--right-alt-mod 'left)

(ert-deftest drgnx-keys/vscode-on-macos-sets-the-modifiers ()
  ;; Cmd is s-, left Option is Meta, right Option types characters — and another profile gets them back.
  (let ((drgnx-keys--mac-modifiers '((drgnx-keys-test--cmd-mod . super) (drgnx-keys-test--alt-mod . meta)
                                     (drgnx-keys-test--right-alt-mod . none) (drgnx-keys-test--unbound . none)))
        (drgnx-keys--saved-modifiers nil)
        (drgnx-keys-test--cmd-mod 'meta) (drgnx-keys-test--alt-mod 'alt) (drgnx-keys-test--right-alt-mod 'left))
    (drgnx-keys-test--live
     (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos)))
       (drgnx-keys-use '((vscode app editing window)))
       (should (equal (list drgnx-keys-test--cmd-mod drgnx-keys-test--alt-mod drgnx-keys-test--right-alt-mod)
                      '(super meta none)))
       (should-not (boundp 'drgnx-keys-test--unbound))            ; only the variables this Emacs has
       (drgnx-keys-use '((vscode app editing window)))           ; again: what it found first is kept
       (drgnx-keys-use '((emacs app editing window)))
       (should (equal (list drgnx-keys-test--cmd-mod drgnx-keys-test--alt-mod drgnx-keys-test--right-alt-mod)
                      '(meta alt left)))
       (drgnx-keys-use '((emacs editing) (vscode app window)))   ; VS Code's Cmd keys: Cmd is s- again
       (should (eq drgnx-keys-test--cmd-mod 'super)))
     (drgnx-keys-use '((emacs app editing window))))
    ;; On Linux nothing changes.
    (drgnx-keys-test--live
     (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux)))
       (drgnx-keys-use '((vscode app editing window)))
       (should (eq drgnx-keys-test--cmd-mod 'meta))))))

(ert-deftest drgnx-keys/option-that-types-characters-keeps-its-word-keys ()
  ;; German, French … layouts type @ # { [ with Option: the left Option then types characters for ordinary keys
  ;; and stays Meta for function keys (←/→) and the mouse — a key setting in keys.eld, applied with VS Code's keys.
  (let ((drgnx-keys--mac-modifiers '((drgnx-keys-test--cmd-mod . super) (drgnx-keys-test--alt-mod . meta)
                                     (drgnx-keys-test--right-alt-mod . none)))
        (drgnx-keys--mac-option-variables '(drgnx-keys-test--alt-mod))
        (drgnx-keys--saved-modifiers nil)
        (drgnx-keys-test--cmd-mod 'meta) (drgnx-keys-test--alt-mod 'alt) (drgnx-keys-test--right-alt-mod 'left))
    (drgnx-keys-test--live
     (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos)))
       (drgnx-keys-use '((vscode app editing window)) t)
       (should (eq drgnx-keys-test--alt-mod 'meta))                      ; not chosen: Meta, as before
       (drgnx-keys-set-mac-option 'characters)
       (should (equal drgnx-keys-test--alt-mod '(:ordinary none :function meta :mouse meta)))
       (should (eq drgnx-keys-test--right-alt-mod 'none))
       (let ((user (drgnx-keys-read-user)))                               ; saved beside the layers
         (should (eq (plist-get user :mac-option) 'characters))
         (should (equal (plist-get user :layers) '((vscode app editing window)))))
       (drgnx-keys-use '((vscode app editing window)) t)                 ; the layers saved again: the setting stays
       (should (eq (plist-get (drgnx-keys-read-user) :mac-option) 'characters))
       (should (equal drgnx-keys-test--alt-mod '(:ordinary none :function meta :mouse meta)))
       (drgnx-keys-set-mac-option 'meta)
       (should (eq drgnx-keys-test--alt-mod 'meta))
       (drgnx-keys-use '((emacs app editing window)))
       (should (eq drgnx-keys-test--alt-mod 'alt))))))                   ; another profile: what was there

(ert-deftest drgnx-keys/platform-names-the-system ()
  (should (eq (let ((system-type 'darwin)) (drgnx-platform)) 'macos))
  (should (eq (let ((system-type 'gnu/linux)) (drgnx-platform)) 'linux))
  (should (eq (let ((system-type 'darwin)) (drgnx-keys-platform)) 'macos)))
