;;; core-keys-test.el --- batch tests: key profiles, layers and conflicts -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/areas-fixture" drgnx-dir) nil t)

(defconst drgnx-keys-test--profiles
  (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))
  "The shipped profiles.")

(defconst drgnx-keys-test--defaults (copy-keymap global-map)
  "Emacs' own bindings, as `drgnx-keys' snapshots them.")

(defvar drgnx-keys-test--later-stages nil
  "Non-nil: `drgnx-keys-test--with-core-commands' also sets up the idle, first-frame, first-file and first-input modules.")

(defvar drgnx-keys-test--strict nil
  "Non-nil: `drgnx-keys-test--with-core-commands' fails when the modules leave state behind after their teardown.")

(defvar drgnx-layouts-pane-fillers)
(defvar drgnx-layouts-shapes)
(defvar drgnx-persist-state-functions)
(defvar drgnx-persist-after-restore-functions)

(defmacro drgnx-keys-test--with-core-commands (&rest body)
  "BODY with a registry holding the core commands (core + core/basics) and the two replace commands
that took VS Code's C-S-h and F2 (the rest of the replace module is not modelled here), nothing else — and with
`drgnx-keys-test--later-stages', the commands of the later stages' modules whose packages need nothing installed.
The modules are set up by `drgnx-test-with-modules' and torn down after BODY, what they hooked into with them."
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         ;; the trust guards add drgnx's folders to `trusted-content' and turning them off leaves them there
         (trusted-content trusted-content))
     (drgnx--core-commands)
     (drgnx-command-define 'replace-in-files :category "Search" :title "Replace in Files" :command #'ignore :doc "test")
     (drgnx-command-define 'rename-symbol :category "Search" :title "Rename Symbol" :command #'ignore :doc "test")
     ;; A module that needs a package (magit, avy, websocket, …) stays out whatever this machine has installed.
     (drgnx-test-with-modules nil
       :stages (if drgnx-keys-test--later-stages drgnx-modules-stages '(startup))
       :packages (if drgnx-keys-test--later-stages 'hidden nil)
       :strict drgnx-keys-test--strict
       ,@body)))

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
  ;; The mixed preset puts Vim last: Vim's C-o wins in normal, visual and motion state, and VS Code's Open File
  ;; keeps C-o (insert state, panels) next to its leader key.
  (let* ((r (drgnx-keys-test--resolve '((vscode app window) (vim editing))))
         (c (drgnx-keys-test--conflict r "C-o")))
    (should (eq (plist-get c :kind) 'claim))
    (should (equal (plist-get c :states) '(normal visual motion)))
    (should (equal (plist-get (plist-get c :winner) :claim) "Jump Back"))
    (should (equal (plist-get (car (plist-get c :losers)) :id) 'open-file))
    (should (equal (drgnx-keys-test--keys r 'open-file) '("C-o" "SPC f f")))))

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
  "BODY with the core commands, fresh drgnx-keys state and a temp config dir, on Linux (macOS profiles bind other
keys); every binding is undone after."
  `(drgnx-keys-test--with-core-commands
    (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux)))
      (drgnx-test-with-areas
        (let* ((drgnx-keys--session-layers nil) (drgnx-keys-profiles nil)
               (drgnx-keys-problems nil) (drgnx-keys-last nil))
          (unwind-protect (progn ,@body)
            (drgnx-keys-forget-yours)
            (drgnx-keys--restore)))))))

(defmacro drgnx-keys-test--as-you (&rest body)
  "BODY as a keyboard command of yours (M-: say): its global writes are yours (`drgnx-keys--yours-p')."
  `(let ((this-command 'eval-expression)) ,@body))

(defun drgnx-keys-test--write-user (form)
  "settings.el holds the entries the old keys.eld plist FORM maps to; nothing is applied (as in a batch command)."
  (make-directory (drgnx-user-dir) t)
  (drgnx-test-areas-put-old 'keys (prin1-to-string form)))

(ert-deftest drgnx-keys/switching-rebinds-and-restores-emacs ()
  (let ((before (copy-keymap global-map)))
    (drgnx-keys-test--live
     (drgnx-keys-use '((vscode app editing window)))
     (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file))
     (should (eq (keymap-lookup (current-global-map) "C-k C-r") #'drgnx-surfaces-cheatsheet))
     (should (eq (keymap-lookup (current-global-map) "<f1>") #'drgnx-palette))
     (drgnx-keys-use '((emacs app editing window)))
     (should (eq (keymap-lookup (current-global-map) "C-o") #'open-line))
     (should (eq (keymap-lookup (current-global-map) "C-k") #'kill-line))
     (should (keymapp (keymap-lookup (current-global-map) "<f1>")))
     (should (eq (keymap-lookup (current-global-map) "C-h C-k") #'drgnx-surfaces-cheatsheet))
     (drgnx-keys-use '((vscode app editing window)))
     (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file)))
    ;; Everything drgnx bound is gone again (the menu bar keeps the generated menus).
    (cl-flet ((strip (m) (let ((c (copy-keymap m))) (define-key c [menu-bar] nil) c)))
      (should (equal (strip global-map) (strip before))))))

(defmacro drgnx-keys-test--with-feature-file (feature &rest body)
  "BODY with FILE bound to a temp Lisp file that provides FEATURE; the feature and its after-load entries gone after."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "drgnx-keys-al" t)) (file (expand-file-name (format "%s.el" ,feature) dir)))
     (unwind-protect
         (progn (with-temp-file file (insert (format "(provide '%s)\n" ,feature))) ,@body)
       (setq features (delq ,feature features)
             after-load-alist (seq-remove (lambda (e) (eq (car e) ,feature)) after-load-alist))
       (delete-directory dir t))))

(ert-deftest drgnx-keys/after-load-a-packages-body-is-not-yours ()
  "A package's after-load body runs once its file has loaded, after `load' unbound `load-file-name': loaded by a
command of yours, it is the package's all the same.  Its global write lands in `global-map', under the profile's key."
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (drgnx-keys-test--with-feature-file 'drgnx-keys-test-al-pkg
     (unwind-protect
         (progn
           (let ((this-command nil))                ; registered by a package (no command, no file of yours)
             (with-eval-after-load 'drgnx-keys-test-al-pkg (keymap-global-set "C-o" #'ignore)))
           (drgnx-keys-test--as-you (load file nil t))   ; M-x load-file: a command of yours loads it
           (should (eq (keymap-lookup global-map "C-o") #'ignore))
           (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file))
           (should-not (gethash "C-o" drgnx-keys--yours)))
       (let ((this-command nil)) (keymap-set global-map "C-o" #'open-line))))))

(ert-deftest drgnx-keys/after-load-your-body-is-yours ()
  "An after-load body you registered is yours when it runs, whoever loads the file (a timer, an autoload)."
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (drgnx-keys-test--with-feature-file 'drgnx-keys-test-al-mine
     (drgnx-keys-test--as-you
      (with-eval-after-load 'drgnx-keys-test-al-mine (keymap-global-set "C-o" #'ignore)))
     (let ((this-command nil)) (load file nil t))
     (should (eq (keymap-lookup (current-global-map) "C-o") #'ignore))
     (should (eq (keymap-lookup global-map "C-o") #'open-line)))))

(defun drgnx-keys-test--user-file (name text)
  "A Lisp file NAME of yours (in your config dir) holding TEXT; its name."
  (let ((f (expand-file-name name (drgnx-user-dir))))
    (make-directory (file-name-directory f) t)
    (with-temp-file f (insert ";;; -*- lexical-binding: t -*-\n" text))
    f))

(ert-deftest drgnx-keys/yours-a-file-of-yours-loaded-later-is-yours ()
  "A Lisp file of yours is yours whatever loads it (M-x load-file, a timer), not only at startup; the key records
the file."
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (let ((f (drgnx-keys-test--user-file "kx-later.el" "(keymap-global-set \"C-o\" #'ignore)\n")))
     (let ((this-command nil)) (load f nil t t))
     (should (eq (keymap-lookup (current-global-map) "C-o") #'ignore))
     (should (eq (keymap-lookup global-map "C-o") #'open-line))
     (should (equal (cdr (gethash "C-o" drgnx-keys--yours)) (file-name-sans-extension (file-truename f)))))))

(ert-deftest drgnx-keys/yours-a-reload-forgets-only-that-files-keys ()
  "Loading a file of yours again forgets the keys it bound last time (one it no longer binds is the profile's again);
a key you bound by command stays."
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (let ((f (drgnx-keys-test--user-file "kx-reload.el" "(keymap-global-set \"C-o\" #'ignore)\n"))
         (load (lambda (f) (let ((this-command nil)) (drgnx-settings-prov--call-with-load f (lambda () (load f nil t t)))))))
     (funcall load f)
     (drgnx-keys-test--as-you (keymap-global-set "C-c y" #'ignore))
     (should (eq (keymap-lookup (current-global-map) "C-o") #'ignore))
     (drgnx-keys-test--user-file "kx-reload.el" "(keymap-global-set \"C-c x\" #'ignore)\n")
     (funcall load f)
     (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file))
     (should (eq (keymap-lookup (current-global-map) "C-c x") #'ignore))
     (should (eq (keymap-lookup (current-global-map) "C-c y") #'ignore))
     (should-not (gethash "C-o" drgnx-keys--yours)))))

(ert-deftest drgnx-keys/yours-a-timer-in-a-commands-wait-is-not-yours ()
  "A timer that runs inside a command's wait (`sit-for') is not you: its global write is a package's."
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (unwind-protect
       (let ((tm (timer-create)))
         (timer-set-time tm (time-add nil 100))
         (timer-set-function tm (lambda () (keymap-global-set "C-o" #'ignore)))
         ;; as `sit-for' would run it, a command current; the handler runs only a queued timer, so queue it in a
         ;; `timer-list' of its own (nothing real is scheduled)
         (let ((timer-list (list tm))) (drgnx-keys-test--as-you (timer-event-handler tm)))
         (should (eq (keymap-lookup global-map "C-o") #'ignore))
         (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file))
         (should-not (gethash "C-o" drgnx-keys--yours)))
     (let ((this-command nil)) (keymap-set global-map "C-o" #'open-line)))))

(ert-deftest drgnx-keys/yours-a-process-filter-in-a-commands-wait-is-not-yours ()
  "A process filter or sentinel that runs inside a command's wait is not you: Emacs binds `last-nonmenu-event' to t
around it (as here), and its global write is a package's."
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (unwind-protect
       (progn
         (drgnx-keys-test--as-you
          (let ((last-nonmenu-event t)) (funcall (lambda (_proc _out) (keymap-global-set "C-o" #'ignore)) nil "")))
         (should (eq (keymap-lookup global-map "C-o") #'ignore))
         (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file))
         (should-not (gethash "C-o" drgnx-keys--yours)))
     (let ((this-command nil)) (keymap-set global-map "C-o" #'open-line)))))

(ert-deftest drgnx-keys/yours-load-file-again-forgets-the-keys-it-no-longer-binds ()
  "M-x load-file of a file of yours a second time: a key it no longer binds is the profile's again; one it binds
again stays yours."
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (let ((f (drgnx-keys-test--user-file "kx-loadfile.el"
                                        "(keymap-global-set \"C-o\" #'ignore)\n(keymap-global-set \"C-c x\" #'ignore)\n")))
     (let ((this-command nil)) (load-file f))
     (should (eq (keymap-lookup (current-global-map) "C-o") #'ignore))
     (drgnx-keys-test--user-file "kx-loadfile.el" "(keymap-global-set \"C-c x\" #'ignore)\n")
     (let ((this-command nil)) (load-file f))
     (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file))
     (should-not (gethash "C-o" drgnx-keys--yours))
     (should (eq (keymap-lookup (current-global-map) "C-c x") #'ignore))
     (should (gethash "C-c x" drgnx-keys--yours)))))

(ert-deftest drgnx-keys/yours-a-config-reload-forgets-the-keys-of-a-file-it-loads ()
  "config.el loads another file of yours with a plain `load': when config.el loads again, a key the other file no
longer binds is the profile's again."
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (let* ((sub (drgnx-keys-test--user-file "lisp/kx-sub.el" "(keymap-global-set \"C-o\" #'ignore)\n"))
          (cfg (drgnx-keys-test--user-file "kx-cfg.el" (format "(load %S nil t t)\n" sub)))
          (load (lambda () (let ((this-command nil))
                             (drgnx-settings-prov--call-with-load cfg (lambda () (load cfg nil t t)))))))
     (funcall load)
     (should (eq (keymap-lookup (current-global-map) "C-o") #'ignore))
     (drgnx-keys-test--user-file "lisp/kx-sub.el" ";; the key went\n")
     (setq drgnx-keys--stale nil)
     (funcall load)
     (should drgnx-keys--stale)                            ; the sheet settles before it reads
     (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file))
     (should-not (gethash "C-o" drgnx-keys--yours)))))

(ert-deftest drgnx-keys/yours-an-after-load-body-belongs-to-the-file-that-registered-it ()
  "Your after-load body that runs while another file of yours loads (it requires the package) is the registering
file's, not the loading one's: reloading the loading file without the `require' keeps the key."
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (let* ((dir (make-temp-file "kx-pkg" t))
          (load-path (cons dir load-path))
          (f (drgnx-keys-test--user-file "kx-reg.el" "(with-eval-after-load 'kx-pkg (keymap-global-set \"C-o\" #'ignore))\n"))
          (g (drgnx-keys-test--user-file "kx-req.el" "(require 'kx-pkg)\n")))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "kx-pkg.el" dir) (insert "(provide 'kx-pkg)\n"))
           (let ((this-command nil)) (load f nil t t) (load g nil t t))
           (should (equal (cdr (gethash "C-o" drgnx-keys--yours)) (file-name-sans-extension (file-truename f))))
           (should-not (gethash (file-name-sans-extension (file-truename f)) drgnx-keys--loading)) ; not F's own load
           (drgnx-keys-test--user-file "kx-req.el" ";; no require now\n")
           (let ((this-command nil)) (load g nil t t))
           (should (eq (keymap-lookup (current-global-map) "C-o") #'ignore)))
       (setq features (delq 'kx-pkg features)
             after-load-alist (seq-remove (lambda (e) (equal (car e) 'kx-pkg)) after-load-alist))
       (delete-directory dir t)))))

(ert-deftest drgnx-keys/yours-a-failed-load-leaves-no-list-for-the-next ()
  "A load of your file that stops with an error keeps its keys; when the file then loads without them, they go (the
failed load's keys are not taken for the new load's)."
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (let ((f (drgnx-keys-test--user-file "kx-fail.el" "(keymap-global-set \"C-o\" #'ignore)\n(error \"boom\")\n")))
     (let ((this-command nil)) (ignore-errors (load f nil t t)))
     (should (eq (keymap-lookup (current-global-map) "C-o") #'ignore))
     (drgnx-keys-test--user-file "kx-fail.el" ";; fixed: no key now\n")
     (let ((this-command nil)) (load f nil t t))
     (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file))
     (should-not (gethash "C-o" drgnx-keys--yours)))))

(ert-deftest drgnx-keys/yours-a-load-with-no-keys-of-yours-reads-no-file ()
  "With no key of yours recorded, a load that ends asks nothing of the file system (no truename): tramp loading for a
remote name, say, is no business of the keys."
  (let ((drgnx-keys--yours (make-hash-table :test #'equal)) (drgnx-keys--yours-in-maps (make-hash-table :test #'equal))
        (drgnx-keys--loading (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'file-truename) (lambda (&rest _) (error "Asked for a truename"))))
      (drgnx-keys--loaded "/ssh:host.invalid:/no/such/file.el"))))

(ert-deftest drgnx-keys/yours-a-load-of-a-file-not-yours-reads-no-file ()
  "With keys of yours recorded, a load whose name is none of your files' (a remote name, a package's library) asks
nothing of the file system; your keys stay."
  (let ((drgnx-keys--yours (make-hash-table :test #'equal)) (drgnx-keys--yours-in-maps (make-hash-table :test #'equal))
        (drgnx-keys--loading (make-hash-table :test #'equal)) (drgnx-keys--source-names (make-hash-table :test #'equal)))
    (puthash "C-c z" (cons #'ignore "/tmp/kx-dir/kx-mine") drgnx-keys--yours)
    (puthash "kx-mine" t drgnx-keys--source-names)
    (cl-letf (((symbol-function 'file-truename) (lambda (&rest _) (error "Asked for a truename"))))
      (drgnx-keys--loaded "/ssh:host.invalid:/no/such/other.el")
      (drgnx-keys--loaded "/usr/share/emacs/lisp/other.elc"))
    (should (gethash "C-c z" drgnx-keys--yours))))

(ert-deftest drgnx-keys/yours-a-native-load-records-the-source ()
  "A file of yours loaded natively compiled (its .eln found for its .elc) records the source, so a reload of the .el
forgets its keys."
  (skip-unless (native-comp-available-p))
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (let* ((eln (make-temp-file "kx-eln" t))
          (native-comp-eln-load-path (cons eln native-comp-eln-load-path))
          (native-comp-jit-compilation nil)
          (f (drgnx-keys-test--user-file "kx-native.el"
                                         "(defun kx-native-probe () 1)\n(keymap-global-set \"C-o\" #'ignore)\n")))
     (unwind-protect
         (progn
           (byte-compile-file f)
           (native-compile f)
           (let ((this-command nil)) (load (file-name-sans-extension f) nil t))
           (should (native-comp-function-p (symbol-function 'kx-native-probe)))   ; the .eln ran
           (should (equal (cdr (gethash "C-o" drgnx-keys--yours)) (file-name-sans-extension (file-truename f)))))
       (delete-directory eln t)))))

(ert-deftest drgnx-keys/a-binding-changed-by-someone-else-is-kept ()
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (keymap-set global-map "C-o" #'ignore)
   (unwind-protect
       (progn (drgnx-keys-use '((emacs app editing window)))
              (should (eq (keymap-lookup (current-global-map) "C-o") #'ignore)))
     (keymap-set global-map "C-o" #'open-line))))

(ert-deftest drgnx-keys/your-own-global-binding-survives-a-later-apply ()
  "A key the profile claims, bound by you in the global map (config.el's `keymap-global-set', which loads after the
modules' first stage), stays yours through every later apply (each module stage ends with one): it is reported as
your own binding, kept.  Unset with REMOVE (handed back), the profile's key comes back at once."
  (drgnx-keys-test--live
   (progn
     (drgnx-keys-use '((vscode app editing window)))
     (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file))
     (drgnx-keys-test--as-you (keymap-global-set "C-o" #'ignore))
     (should (eq (keymap-lookup (current-global-map) "C-o") #'ignore))   ; at once, no apply between
     (unwind-protect
         (progn
           (drgnx-keys-apply)                       ; a module stage ends
           (should (eq (keymap-lookup (current-global-map) "C-o") #'ignore))
           (drgnx-keys-apply)
           (should (eq (keymap-lookup (current-global-map) "C-o") #'ignore))
           (let ((c (drgnx-keys-test--conflict drgnx-keys-last "C-o")))
             (should c)
             (should (equal "your own binding, kept" (plist-get (plist-get c :winner) :layer)))))
       (drgnx-keys-test--as-you (keymap-global-unset "C-o" t)))
     (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file))
     (drgnx-keys-apply)
     (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file))
     (should (eq (keymap-lookup global-map "C-o") #'open-line)))))   ; drgnx never wrote global-map

;;; One verdict (T10): the sheet says what `key-binding' answers.

(defun drgnx-keys-test--sheet-disagreements ()
  "What the sheet says that `key-binding' (in a plain buffer) does not: each conflict's :verdict against the key's
binding, and each command's first global key against the command.  A list of (KEY SHEET-SAYS KEY-BINDING-SAYS)."
  (let (bad)
    (cl-flet ((got (key) (let ((b (with-temp-buffer (key-binding (key-parse key) nil t)))) (and (not (numberp b)) b))))
      (dolist (c (plist-get drgnx-keys-last :conflicts))
        (when-let* ((v (plist-get c :verdict)))
          (let ((says (drgnx-keys--def-text (got (plist-get c :key)))))
            (unless (equal v says) (push (list (plist-get c :key) v says) bad)))))
      (dolist (cmd (drgnx-commands-all))
        (pcase-dolist (`(,key . ,map) (drgnx-cmd-bound cmd))
          ;; a minor mode's map over the global one (tab-bar-mode's C-<tab>) is the foreign layer's business (T6/T8)
          (when (and (eq (cdr (drgnx-commands--keymap-spec map)) 'global-map)
                     (not (cl-some (lambda (m) (lookup-key m (key-parse key) t)) (current-minor-mode-maps))))
            (unless (equal (drgnx-keys--def-text (drgnx-cmd-command cmd)) (drgnx-keys--def-text (got key)))
              (push (list key (drgnx-cmd-id cmd) (drgnx-keys--def-text (got key))) bad))))))
    (nreverse bad)))

(ert-deftest drgnx-keys/the-sheet-says-what-key-binding-answers ()
  "A key of yours (a command, a lambda, an unbind, a command on a prefix of profile keys) is the top layer of the
resolver: its conflict is the only line for the key, the verdict equals `key-binding', and the sheet prints a lambda
as \"a lambda\", never its body."
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (should-not (drgnx-keys-test--sheet-disagreements))
   (let ((n0 (length (seq-filter (lambda (c) (plist-get c :verdict)) (plist-get drgnx-keys-last :conflicts)))))
     (should (> n0 3))                         ; the profile's own claims over Emacs's: not vacuous
     (drgnx-keys-test--as-you
      (keymap-global-set "C-o" #'ignore)       ; a command over the profile's find-file
      (keymap-global-set "C-s" (lambda () (interactive) (message "a closure body that must not print")))
      (keymap-global-set "C-S-p" nil)          ; unbound by you: nothing, the profile's key steps aside
      (keymap-global-set "C-k" #'ignore))      ; a command on the profile's C-k prefix: C-k C-r is unreachable
     (drgnx-keys-apply)
     (should-not (drgnx-keys-test--sheet-disagreements))
     (let* ((verdicts (mapcar (lambda (c) (cons (plist-get c :key) (plist-get c :verdict)))
                              (plist-get drgnx-keys-last :conflicts))))
       (should (equal (alist-get "C-o" verdicts nil nil #'equal) "ignore"))
       (should (equal (alist-get "C-s" verdicts nil nil #'equal) "a lambda"))
       (should (equal (alist-get "C-S-p" verdicts nil nil #'equal) "nothing"))
       (should (equal (alist-get "C-k C-r" verdicts nil nil #'equal) "nothing")))
     (let ((lines (drgnx-keys-conflict-lines)))
       (should-not (seq-find (lambda (l) (string-match-p "closure body\\|(lambda\\|#\\[" l)) lines))
       (should (seq-find (lambda (l) (string-match-p "\\`C-s .*a lambda" l)) lines))
       ;; one line per key
       (dolist (k '("C-o" "C-s" "C-S-p" "C-k C-r"))
         (should (= 1 (length (seq-filter (lambda (l) (string-prefix-p (concat k " ") l)) lines)))))))))

;;; T11: reloads, readers

(ert-deftest drgnx-keys/a-config-reload-clears-only-config-entries ()
  "Reloading config.el forgets the keys it bound (the profile's come back on them, then it binds what it still says);
a key you bound from the keyboard stays: Emacs keeps those for the session."
  (drgnx-keys-test--live
   (let ((file (expand-file-name "config.el" (drgnx-user-dir))))
     (make-directory (drgnx-user-dir) t)
     (drgnx-keys-use '((vscode app editing window)))
     (with-temp-file file (insert ";;; -*- lexical-binding: t -*-\n(keymap-global-set \"C-o\" #'ignore)\n(keymap-global-set \"C-s\" #'ignore)\n"))
     (drgnx--load-user-config file)
     (drgnx-keys-test--as-you (keymap-global-set "C-c y" #'ignore))
     (should (eq (keymap-lookup (current-global-map) "C-o") #'ignore))
     ;; the file now binds only C-s
     (with-temp-file file (insert ";;; -*- lexical-binding: t -*-\n(keymap-global-set \"C-s\" #'ignore)\n"))
     (drgnx--load-user-config file)
     (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file))   ; its line is gone: the profile's key
     (should (eq (keymap-lookup (current-global-map) "C-s") #'ignore))
     (should (eq (keymap-lookup (current-global-map) "C-c y") #'ignore))     ; interactive: stays
     (drgnx-keys-apply)
     (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file))
     (should (eq (keymap-lookup (current-global-map) "C-c y") #'ignore))
     (should-not (gethash "C-o" drgnx-keys--yours))
     (should (stringp (cdr (gethash "C-s" drgnx-keys--yours)))))))

(ert-deftest drgnx-keys/a-hook-writes-your-key-only-inside-drgnx-keys-mine ()
  "A write from a hook function is no scope of yours: it is a package's, under the profile's key.  Inside
`drgnx-keys-mine' it is yours, also while some other file loads."
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (let ((this-command nil) (load-file-name "/tmp/some-package.el"))
     (keymap-global-set "C-o" #'ignore)                     ; the hook as it is: a package's
     (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file))
     (should-not (gethash "C-o" drgnx-keys--yours))
     (drgnx-keys-mine (keymap-global-set "C-o" #'ignore))   ; with the macro: yours
     (should (eq (keymap-lookup (current-global-map) "C-o") #'ignore))
     (should (gethash "C-o" drgnx-keys--yours))
     (drgnx-keys-apply)
     (should (eq (keymap-lookup (current-global-map) "C-o") #'ignore)))
   (keymap-set global-map "C-o" #'open-line)))

(ert-deftest drgnx-keys/a-package-loaded-inside-a-scope-of-yours-binds-as-the-package ()
  "A package required inside `drgnx-keys-mine', or inside an after-load body you registered, binds its global keys as
a package: below the profile's, not yours (the file rule judges a file loaded inside a scope)."
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (let* ((dir (make-temp-file "kx-scope" t)) (load-path (cons dir load-path)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "kx-in-mine.el" dir)
             (insert "(keymap-global-set \"C-o\" #'ignore)\n(provide 'kx-in-mine)\n"))
           (with-temp-file (expand-file-name "kx-in-body.el" dir)
             (insert "(keymap-global-set \"C-o\" #'ignore)\n(provide 'kx-in-body)\n"))
           (with-temp-file (expand-file-name "kx-trigger.el" dir) (insert "(provide 'kx-trigger)\n"))
           (let ((this-command nil)) (drgnx-keys-mine (require 'kx-in-mine)))
           (should-not (gethash "C-o" drgnx-keys--yours))
           (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file))
           (drgnx-keys-test--as-you (with-eval-after-load 'kx-trigger (require 'kx-in-body)))
           (let ((this-command nil)) (require 'kx-trigger))
           (should (featurep 'kx-in-body))
           (should-not (gethash "C-o" drgnx-keys--yours))
           (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file)))
       (setq features (seq-difference features '(kx-in-mine kx-in-body kx-trigger))
             after-load-alist (seq-remove (lambda (e) (equal (car e) 'kx-trigger)) after-load-alist))
       (keymap-set global-map "C-o" #'open-line)
       (delete-directory dir t)))))

(ert-deftest drgnx-keys/emacs-code-that-reads-global-map-sees-the-composed-one ()
  "comint's C-d, message's TAB and the tutorial read the variable `global-map' as the global binding: under the
composed map they run with it bound to the current global map, so the profile's keys are seen there."
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (should (eq (lookup-key global-map (kbd "C-o")) #'open-line))
   (should (eq (drgnx-keys--with-live-global-map (lambda () (lookup-key global-map (kbd "C-o")))) #'find-file))
   (dolist (f '(comint-delchar-or-maybe-eof comint-insert-input message-tab tutorial--find-changed-keys isearchb))
     (should (advice-member-p #'drgnx-keys--with-live-global-map f)))))

(ert-deftest drgnx-keys/the-reader-advice-binds-global-map-only-while-the-composed-map-is-current ()
  "Under another current global map (`read-key''s) the readers see `global-map' as it is."
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (let ((other (make-sparse-keymap)) (g (current-global-map)))
     (unwind-protect
         (progn (use-global-map other)
                (should (eq (drgnx-keys--with-live-global-map (lambda () global-map)) (default-value 'global-map))))
       (use-global-map g)))))

(ert-deftest drgnx-keys/the-reader-advice-binds-global-map-only-while-the-redirect-is-on ()
  "With the redirect off (a write to the bound `global-map' would land in the composed map), the readers see
`global-map' as it is, even under the composed map."
  (skip-unless (drgnx-keys-redirect-available-p))
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (should (eq (current-global-map) drgnx-keys--global-map))
   (let ((nidhogg-define-key-redirect-function nil))
     (should (eq (drgnx-keys--with-live-global-map (lambda () global-map)) (default-value 'global-map))))))

(ert-deftest drgnx-keys/comint-c-d-away-from-the-prompt-runs-the-profiles-command ()
  "A real call: `comint-delchar-or-maybe-eof' with no process falls back to the global binding of the key, which is
the profile's (yours here), not `global-map''s `delete-char'."
  (require 'comint)
  (drgnx-keys-test--live
   (drgnx-keys-use '((vscode app editing window)))
   (let (ran)
     (defalias 'drgnx-keys-test--c-d #'(lambda () (interactive) (setq ran t)))
     (drgnx-keys-test--as-you (keymap-global-set "C-d" #'drgnx-keys-test--c-d))
     (with-temp-buffer
       (comint-mode)
       (set--this-command-keys (kbd "C-d"))
       (comint-delchar-or-maybe-eof))
     (should ran))))

(ert-deftest drgnx-keys/the-keys-core-owns-its-advices ()
  "The advices (those that record yours, the timer and load scopes, the readers) and the reload rule on
`after-load-functions' are all removed by the uninstall, and come back."
  (let ((all (drgnx-keys--advices)))
    (should (>= (length all) 10))
    (should (assq 'timer-event-handler all))
    (should (assq 'load all))
    (unwind-protect
        (progn (drgnx-keys--uninstall-redirect)
               (pcase-dolist (`(,sym ,_ ,fn) all) (should-not (advice-member-p fn sym)))
               (should-not (memq #'drgnx-keys--loaded after-load-functions)))
      (drgnx-keys--install-redirect))
    (pcase-dolist (`(,sym ,_ ,fn) all) (should (advice-member-p fn sym)))
    (should (memq #'drgnx-keys--loaded after-load-functions))))

(ert-deftest drgnx-keys/macos-cmd-keys-beat-ns-win-and-menus-find-them ()
  "On macOS the profile's Cmd keys (s-) sit above `global-map', where ns-win binds its own; the menus' key text comes
from `where-is-internal' over the active maps (keyboard.c's menu items), which see the composed global map."
  (drgnx-keys-test--live
   (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos)))
     (drgnx-keys-use '((vscode app editing window)))
     (let ((n 0))
       (dolist (b (plist-get drgnx-keys-last :bindings))
         (when (and (string-prefix-p "s-" (plist-get b :key)) (null (plist-get b :map)))
           (let ((cmd (drgnx-cmd-command (drgnx-commands-get (plist-get b :id)))))
             (cl-incf n)
             (should (eq (keymap-lookup (current-global-map) (plist-get b :key)) cmd))
             (when (symbolp cmd)
               (should (member (plist-get b :key) (mapcar #'key-description (where-is-internal cmd nil))))))))
       (should (> n 5))))))

(ert-deftest drgnx-keys/your-own-binding-before-the-first-apply-is-kept ()
  "A key the profile claims that you bound in the global map before drgnx applied any keys is kept as well."
  (drgnx-keys-test--live
   (progn
     (drgnx-keys-test--as-you (keymap-global-set "C-o" #'ignore))
     (should (eq (keymap-lookup global-map "C-o") #'open-line))   ; into your map, not Emacs's
     (drgnx-keys-use '((vscode app editing window)))
     (should (eq (keymap-lookup (current-global-map) "C-o") #'ignore)))))

(ert-deftest drgnx-keys/your-own-binding-in-a-mode-map-survives-a-later-apply ()
  "A profile key in a mode map that you rebound after drgnx bound it stays yours through later applies."
  (drgnx-keys-test--live
   (let* ((b (seq-find (lambda (b)
                         (let ((sym (cdr (drgnx-commands--keymap-spec (plist-get b :map)))))
                           (and (not (eq sym 'global-map)) (boundp sym) (keymapp (symbol-value sym))
                                (not (plist-get b :also)))))
                       (plist-get (drgnx-keys-test--resolve '((vscode app editing window))) :bindings)))
          (sym (cdr (drgnx-commands--keymap-spec (plist-get b :map))))
          (key (plist-get b :key))
          (prev (drgnx-keys--lookup (symbol-value sym) key)))
     (should b)
     (drgnx-keys-use '((vscode app editing window)))
     (keymap-set (symbol-value sym) key #'ignore)
     (unwind-protect
         (progn (drgnx-keys-apply)
                (should (eq (drgnx-keys--lookup (symbol-value sym) key) #'ignore))
                (drgnx-keys-apply)
                (should (eq (drgnx-keys--lookup (symbol-value sym) key) #'ignore)))
       (if prev (keymap-set (symbol-value sym) key prev) (keymap-unset (symbol-value sym) key t))))))

(ert-deftest drgnx-keys/the-vscode-profile-indents-with-spaces ()
  "VS Code's default is spaces (M12f-AF-3): the profile sets `indent-tabs-mode' nil, the other profiles leave it."
  (drgnx-keys-test--live
   (let ((orig (default-value 'indent-tabs-mode)))
     (unwind-protect
         (progn
           (setq-default indent-tabs-mode t)
           (drgnx-keys-use '((emacs app editing window)))
           (should (default-value 'indent-tabs-mode))
           (drgnx-keys-use '((vscode app editing window)))
           (should-not (default-value 'indent-tabs-mode))
           (drgnx-keys-use '((emacs app editing window)))
           (should (default-value 'indent-tabs-mode)))
       (setq-default indent-tabs-mode orig)))))

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
                (keymap-lookup (current-global-map) "<menu-bar> <View>"))
    found))

(ert-deftest drgnx-keys/a-keys-eld-override-shows-on-every-surface ()
  (drgnx-keys-test--live
   (drgnx-keys-test--write-user '(:bind ((palette "C-c p"))))
   (drgnx-keys-apply)
   (should (eq (keymap-lookup (current-global-map) "C-c p") #'drgnx-palette))
   (should (null (keymap-lookup (current-global-map) "C-S-p")))
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
     (should (string-search "Ctrl C p" (string-join (split-string annotation) " "))))))   ; the key as keycaps

(ert-deftest drgnx-keys/a-broken-settings-el-is-not-an-error ()
  ;; the default stack applies; the applier (not the keys) says what is wrong with the file
  (drgnx-keys-test--live
   (drgnx-test-areas-put "(drgnx-settings :version 1 (drgnx-keys-bind ((palette \"C-c p\")")
   (should (drgnx-keys-apply))
   (should (eq (keymap-lookup (current-global-map) "C-o") #'find-file))))

(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)

(ert-deftest drgnx-notice-core/keys-problems-are-warn-conditions ()
  (drgnx-notice-test-with-model
    (drgnx-keys-test--live
     (drgnx-keys-test--write-user '(:bind ((nope "C-c n"))))
     (drgnx-keys-apply)
     (let ((problems (plist-get drgnx-keys-last :problems))
           (ns (drgnx-notices :source 'keys)))
       (should problems)
       (should (= (length ns) (length (delete-dups (copy-sequence problems)))))
       (dolist (n ns)
         (should (eq (plist-get n :severity) 'warn))
         (should (eq (plist-get n :life) 'condition))
         (should (member (plist-get n :id) problems))
         (should (equal (plist-get n :id) (plist-get n :text))))
       (should-not (drgnx-notices :source 'keys :severity 'fail))))))

(ert-deftest drgnx-notice-core/a-second-apply-replaces-them ()
  (drgnx-notice-test-with-model
    (drgnx-keys-test--live
     (drgnx-keys-test--write-user '(:bind ((nope "C-c n"))))
     (drgnx-keys-apply)
     (should (drgnx-notices :source 'keys))
     (delete-file (drgnx-config-file 'settings))
     (drgnx-keys-apply)
     (should-not (plist-get drgnx-keys-last :problems))
     (should-not (drgnx-notices :source 'keys)))))

(ert-deftest drgnx-keys/keyboard-profile-command-switches-and-saves ()
  (drgnx-keys-test--live
   (drgnx-keys-test--write-user '(:bind ((line-numbers "C-c l"))))
   (drgnx-keys-apply)
   (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Emacs editing + VS Code app keys")))
     (call-interactively #'drgnx-keys-choose-profile))
   (let ((saved (drgnx-test-areas-old-plist 'keys)))
     (should (equal (plist-get saved :layers) '((emacs editing) (vscode app window))))
     (should (equal (plist-get saved :bind) '((line-numbers "C-c l")))))
   (should (equal (plist-get drgnx-keys-last :layers) '((emacs editing) (vscode app window))))
   (should (drgnx-keys-test--conflict drgnx-keys-last "C-o"))))

;;;; The report

(ert-deftest drgnx-keys/the-report-has-no-problems ()
  ;; problems are the notices of source `keys' (key-problems in the doctor); keys-report.eld keeps conflicts and :modal
  (let* ((state (make-temp-file "drgnx-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment)))
    (unwind-protect
        (drgnx-keys-test--live
         (drgnx-keys-test--write-user '(:bind ((nope "C-c n"))))
         (drgnx-keys-apply)
         (should (plist-get drgnx-keys-last :problems))
         (let ((report (with-temp-buffer (insert-file-contents (expand-file-name "keys-report.eld" (drgnx-state-dir)))
                                         (read (current-buffer)))))
           (should-not (plist-member report :problems))
           (should (plist-member report :conflicts))
           (should (plist-member report :modal)))
         (let ((n (seq-find (lambda (n) (string-search "nope" (plist-get n :text))) (drgnx-notices :source 'keys))))
           (should n)
           (should (string-search "settings.el" (plist-get n :fix)))))
      (delete-directory state t))))

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
           (should-not (plist-member report :problems)))
         (drgnx-surfaces-cheatsheet)
         (with-current-buffer "*drgnx keys*"
           (should (string-search "Key conflicts" (buffer-string)))
           (should (string-match-p "C-o .*Open File" (buffer-string)))
           (should (string-search "settings.el: no command nope" (buffer-string))))
         (kill-buffer "*drgnx keys*"))
      (delete-directory state t))))

;;;; Review fixes

(ert-deftest drgnx-keys/no-settings-mistake-breaks-apply ()
  ;; Startup (drgnx-init → drgnx-keys-apply) must survive any value of the keys settings: one the setting refuses is
  ;; not used (the applier says so), and the default stack applies.
  (dolist (form '((:bind (palette "C-c p")) (:layers foo) (:bind foo)
                  (:bind ((palette "C-c p" :map "org-mode-map")))
                  (:bind ((palette "C-c p" :map 5))) (:unbind palette) (:layers ((vscode apps))) (:layers ((vscode)))
                  (:bind ((palette C-c))) (:bind ((palette))) (:bind ((palette "C-c p" :map (org-mode-map))))
                  (:bind ((palette "C-c p" :mac 7)))))
    (drgnx-keys-test--live
     (drgnx-keys-test--write-user form)
     (should (equal (list form :ok) (list form (and (drgnx-keys-apply) :ok))))
     ;; The default stack still applies.
     (should (equal (list form #'find-file) (list form (keymap-lookup (current-global-map) "C-o" nil t)))))))

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
       (should (eq (keymap-lookup (current-global-map) "C-o" nil t) #'open-line))
       (should (eq (keymap-lookup (current-global-map) "C-k" nil t) #'kill-line)))
    (keymap-unset global-map "<remap> <find-file>" t)))

(ert-deftest drgnx-keys/modules-add-to-the-shipped-profiles ()
  (drgnx-keys-test--live
   (drgnx-command-define 'test-git :title "Git" :category "Test" :command #'drgnx-keys-test--other)
   (drgnx-keys-define 'vscode '((test-git "C-c g")))
   (drgnx-keys-define 'vim '((test-git "SPC g g")))
   (drgnx-keys-apply)
   (should (eq (keymap-lookup (current-global-map) "C-S-p" nil t) #'drgnx-palette))
   (should (eq (keymap-lookup (current-global-map) "C-c g" nil t) #'drgnx-keys-test--other))
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

(ert-deftest drgnx-keys/an-empty-settings-el-is-fine ()
  (drgnx-keys-test--live
   (drgnx-test-areas-put ";; my settings, later\n(drgnx-settings :version 1)\n")
   (drgnx-keys-apply)
   (should (null (plist-get drgnx-keys-last :problems)))
   (drgnx-keys-choose-profile "Emacs")
   (should (string-search ";; my settings, later" (drgnx-test-areas-text)))
   (should (equal (plist-get (drgnx-keys-read-user) :layers) '((emacs app editing window))))))

(ert-deftest drgnx-keys/keyboard-profile-keeps-comments ()
  (drgnx-keys-test--live
   (drgnx-test-areas-put
    ";; my keys\n(drgnx-settings\n :version 1\n ;; palette on C-c p\n (drgnx-keys-bind ((palette \"C-c p\")))\n (drgnx-keys-layers ((vscode app editing window)))) ; was VS Code\n")
   (drgnx-keys-choose-profile "Emacs")
   (let ((text (drgnx-test-areas-text)))
     (should (string-search ";; my keys" text))
     (should (string-search ";; palette on C-c p" text)))
   (let ((user (drgnx-keys-read-user)))
     (should (equal (plist-get user :layers) '((emacs app editing window))))
     (should (equal (plist-get user :bind) '((palette "C-c p")))))))

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
     (should (seq-find (lambda (p) (string-search "drgnx-keys-test-no-such-map" p)) (plist-get drgnx-keys-last :problems)))
     (should-not (plist-member report :problems))
     ;; the doctor's source for problems: the late one is a notice too
     (should (seq-find (lambda (n) (string-search "drgnx-keys-test-no-such-map" (plist-get n :text)))
                       (drgnx-notices :source 'keys)))
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
       (should (eq (keymap-lookup (current-global-map) "C-j") panel))
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

(ert-deftest drgnx-keys/vscode-ctrl-tab-beats-the-tab-bar ()
  ;; F14: the top line is `tab-bar-mode', which, turned on before the keys are bound, binds C-<tab> to `tab-next' in its
  ;; own keymap (`tab-bar--define-keys': unless the global map has it), ahead of the global map: C-<tab> went to a
  ;; next tab-bar tab there is none of, and did nothing.  VS Code's C-<tab> (the recent editors) is a key that works in
  ;; every mode.
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window)))))
    (should (seq-find (lambda (b) (and (eq (plist-get b :id) 'go-recent) (equal (plist-get b :key) "C-<tab>")
                                       (plist-get b :everywhere)))
                      (plist-get r :bindings)))))

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
    (should-not (seq-find (lambda (b) (and (plist-get b :everywhere) (eq (plist-get b :id) 'toggle-panel)))
                          (plist-get r :bindings)))))

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
     (should-not (keymap-lookup drgnx-keys--everywhere-map "C-j"))   ; C-<tab> keeps the layer (F14)
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
     (should (eq (keymap-lookup (current-global-map) "C-j") (drgnx-cmd-command (drgnx-commands-get 'toggle-panel)))))))

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
  "The global keys Emacs' term/ns-win.el binds on macOS, which a Linux test cannot load.")

(defun drgnx-keys-test--ns-global ()
  "Emacs' global keymap as it is on macOS: the Linux defaults plus ns-win's keys."
  (let ((m (copy-keymap drgnx-keys-test--defaults)))
    (pcase-dolist (`(,key ,cmd) drgnx-keys-test--ns-defaults) (keymap-set m key cmd))
    m))

(ert-deftest drgnx-keys/vscode-on-macos-matches-vscode ()
  ;; VS Code's own macOS keys where they are not its Linux key with Ctrl → Cmd; every key valid.
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window)) :platform 'macos)))
    (pcase-dolist (`(,id ,key) '((terminal-toggle "C-`") (toggle-panel "M-j") (terminal-new "C-S-`") (go-recent "C-<tab>") (go-back "C--")
                                 (go-forward "C-_") (next-tab "M-s-<right>") (previous-tab "M-s-<left>")
                                 (file-close-window "s-W") (move-editor-to-next-group "C-s-<right>")
                                 (edit-expand "C-S-s-<right>") (edit-shrink "C-S-s-<left>")
                                 (explorer-copy-path "M-s-c") (explorer-reveal-externally "M-s-r") (quit "s-q")
                                 (preferences-settings "s-,") (palette "s-P") (edit-select-all "s-a") (save-all "M-s-s")
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

(ert-deftest drgnx-keys/vscode-undo-is-c-z ()
  ;; Undo had no key in the VS Code profile: C-z was Emacs' `suspend-frame' (on Wayland it minimises the window) and
  ;; C-/ is Toggle Comment.  VS Code's undo is C-z (Cmd+Z on a Mac); C-y stays Emacs' yank (the profile keeps it).
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window)))))
    (should (member "C-z" (drgnx-keys-test--keys r 'edit-undo)))
    (should (member "C-S-z" (drgnx-keys-test--keys r 'edit-redo)))
    (should-not (drgnx-keys-test--on r "C-y")))
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window)) :platform 'macos)))
    (should (member "s-z" (drgnx-keys-test--keys r 'edit-undo)))))

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
    ;; in Project, …), s-v, Paste (M12b: it replaces the selection), and s-z, Undo; the others stay Emacs'.  s-c and
    ;; s-x are bound only while text is selected (the region map), so Emacs' own stay without a selection.
    (should (equal (sort (seq-filter (lambda (key) (seq-find (lambda (b) (and (null (plist-get b :map))
                                                                              (equal (plist-get b :key) key)))
                                                             (plist-get r :bindings)))
                                     (mapcar #'car drgnx-keys-test--ns-defaults))
                         #'string<)
                   (sort (list "<end>" "<home>" "s-'" "s-+" "s-," "s--" "s-0" "s-<left>" "s-<right>" "s-=" "s-a"
                               "s-f" "s-l" "s-n" "s-o" "s-p" "s-q" "s-s" "s-t" "s-v" "s-w" "s-z" "s-S" "s-H" "s-M"
                               "s-F" "s-E")
                         #'string<)))
    ;; and s-L, Select All Occurrences — the extra/mc module's command, not in this registry
    (let ((vscode (alist-get 'vscode drgnx-keys-test--profiles)))
      (should (equal (plist-get (drgnx-keys--entry (assq 'edit-all-occurrences (plist-get vscode :bind)) vscode 'macos) :keys)
                     '("s-L"))))))

(defconst drgnx-keys-test--linux-snapshot
  '((open-folder "C-k C-o" nil) (palette "C-S-p" nil) (palette "<f1>" nil) (keys-sheet "C-k C-r" nil)
    (modules-toggle "RET" drgnx-modules-list-mode-map) (keyboard-profile "C-k C-p" nil) (open-file "C-o" nil)
    (save-file "C-s" nil) (file-save-as "C-S-s" nil) (file-new "C-n" nil) (file-reopen-tab "C-S-t" nil)
    (file-new-window "C-S-n" nil) (file-close-window "C-q" nil) (view-escape "<escape>" nil)
    (toggle-panel "M-j" nil) (toggle-panel "C-j" nil) (toggle-right-dock "C-M-b" nil)
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
    (code-hover "C-S-SPC" nil) (code-quick-fix "C-." nil) (code-problems "C-S-m" nil) (notebook-run-cell "C-<return>" drgnx-notebook-mode-map) (notebook-run-and-advance "S-<return>" drgnx-notebook-mode-map) (notebook-run-all "C-k n r" drgnx-notebook-mode-map) (notebook-run-above "C-k n u" drgnx-notebook-mode-map) (notebook-run-below "C-k n d" drgnx-notebook-mode-map) (notebook-interrupt "C-k n i" drgnx-notebook-mode-map) (notebook-restart "C-k n k" drgnx-notebook-mode-map) (notebook-restart-run-all "C-k n K" drgnx-notebook-mode-map) (notebook-add-below "C-k n b" drgnx-notebook-mode-map) (notebook-add-above "C-k n a" drgnx-notebook-mode-map) (notebook-cut-cell "C-k n x" drgnx-notebook-mode-map) (notebook-copy-cell "C-k n c" drgnx-notebook-mode-map) (notebook-paste-cell "C-k n v" drgnx-notebook-mode-map) (notebook-delete-cell "C-k n D" drgnx-notebook-mode-map) (notebook-move-up "C-k n <up>" drgnx-notebook-mode-map) (notebook-move-down "C-k n <down>" drgnx-notebook-mode-map) (notebook-cell-menu "C-k n ." drgnx-notebook-mode-map) (notebook-split-cell "C-k n s" drgnx-notebook-mode-map) (notebook-merge-cell "C-k n m" drgnx-notebook-mode-map) (notebook-change-type "C-k n t" drgnx-notebook-mode-map) (notebook-clear-outputs "C-k n o" drgnx-notebook-mode-map) (notebook-select-kernel "C-k n e" drgnx-notebook-mode-map) (notebook-open-output "C-k n O" drgnx-notebook-mode-map) (notebook-outline "C-k n j" drgnx-notebook-mode-map) (notebook-kernel-log "C-k n L" drgnx-notebook-mode-map) (notebook-outline-visit "RET" drgnx-notebook-outline-mode-map) (notebook-output-later "M-n" drgnx-notebook-output-mode-map) (notebook-output-earlier "M-p" drgnx-notebook-output-mode-map) (notebook-copy-output "C-k n y" drgnx-notebook-mode-map) (notebook-toggle-outputs "C-k n h" drgnx-notebook-mode-map)
    (org-capture "C-c c" nil) (org-agenda "C-c a" nil) (scm-view "C-S-g" nil) (go-quick-open "C-p" nil)
    (go-symbol "C-S-o" nil) (go-symbol-project "C-t" nil) (go-recent "C-<tab>" nil) (search-file "C-f" nil)
    (search-semantic "C-k C-f" nil) (terminal-new "C-S-`" nil)
    (view-zen "C-k z" nil)
    (view-zen "<f11>" nil) (view-zoom-in "C-=" nil) (view-zoom-in "C-+" nil) (view-zoom-out "C--" nil)
    (view-zoom-reset "C-0" nil) (decor-activate "RET" drgnx-decor-button-map)
    (ai-accept-word "C-<right>" drgnx-ai-ghost-showing-map) (ai-dismiss "C-g" drgnx-ai-ghost-showing-map)
    (ai-tab "TAB" drgnx-ai-ghost-mode-map) (ai-edit "C-k C-e" nil)
    (ai-edit-apply-hunk "C-c C-a" drgnx-ai-edit-review-mode-map)
    (ai-edit-done "C-c C-c" drgnx-ai-edit-review-mode-map) (ai-edit-reject "C-c C-k" drgnx-ai-edit-review-mode-map)
    (work-take-wheel "W" drgnx-work-live-file-mode-map) (work-files "e" drgnx-work-map-mode-map)
    (work-diffs "d" drgnx-work-map-mode-map) (work-diff-quit "q" drgnx-work-diff-mode-map)
    (work-diff-accept-hunk "a" drgnx-work-diff-mode-map) (work-diff-reject-hunk "D" drgnx-work-diff-mode-map)
    (work-job-log "l" drgnx-work-detail-mode-map) (work-who-is-here "C-k h" nil) (work-left "<left>" drgnx-work-lens-map) (work-right "<right>" drgnx-work-lens-map)
    (work-why "<up>" drgnx-work-lens-map) (work-touches "<down>" drgnx-work-lens-map)
    (work-back "M-<left>" drgnx-work-lens-map) (work-forward "M-<right>" drgnx-work-lens-map)
    (work-next-agent "TAB" drgnx-work-lens-map) (work-previous-agent "<backtab>" drgnx-work-lens-map)
    (work-open "RET" drgnx-work-lens-map) (work-open-beside "S-<return>" drgnx-work-lens-map)
    (work-view-map "m" drgnx-work-lens-map) (work-view-board "b" drgnx-work-lens-map)
    (work-view-flow "F" drgnx-work-lens-map) (work-flow-evidence "e" drgnx-work-flow-mode-map)
    (work-flow-rules "R" drgnx-work-flow-mode-map) (work-flow-run-red "r" drgnx-work-flow-mode-map)
    (work-flow-tell-agent "s" drgnx-work-flow-mode-map) (work-flow-waive "w" drgnx-work-flow-mode-map)
    (work-view-timeline "t" drgnx-work-lens-map) (work-trail "r" drgnx-work-lens-map) (work-steer "s" drgnx-work-lens-map)
    (work-pause "p" drgnx-work-lens-map) (work-resume "u" drgnx-work-lens-map) (work-stop "x" drgnx-work-lens-map)
    (work-keys-sheet "?" drgnx-work-lens-map) (work-review "v" drgnx-work-lens-map)
    (work-second-reviewer "V" drgnx-work-lens-map) (work-review-accept "a" drgnx-work-review-mode-map)
    (work-review-reject "D" drgnx-work-review-mode-map) (work-conclusion-steps "l" drgnx-work-trail-mode-map)
    (work-step-conclusions "L" drgnx-work-trail-mode-map) (work-needs-you-here-next "n" drgnx-work-map-mode-map)
    (work-needs-you-here-previous "N" drgnx-work-map-mode-map) (work-focus "f" drgnx-work-map-mode-map)
    (work-overlaps "o" drgnx-work-map-mode-map) (work-expand-layers "0" drgnx-work-map-mode-map)
    (work-show-finished "." drgnx-work-map-mode-map) (work-search "/" drgnx-work-map-mode-map)
    (work-escape "<escape>" drgnx-work-map-mode-map) (work-needs-you-next "C-k n" nil)
    (work-needs-you-1 "g 1" drgnx-work-lens-map) (work-needs-you-2 "g 2" drgnx-work-lens-map)
    (work-needs-you-3 "g 3" drgnx-work-lens-map) (work-needs-you-4 "g 4" drgnx-work-lens-map)
    (work-needs-you-5 "g 5" drgnx-work-lens-map) (work-needs-you-6 "g 6" drgnx-work-lens-map)
    (work-needs-you-7 "g 7" drgnx-work-lens-map) (work-needs-you-8 "g 8" drgnx-work-lens-map)
    (work-needs-you-9 "g 9" drgnx-work-lens-map) (work-collapse-layer-1 "1" drgnx-work-map-mode-map)
    (work-collapse-layer-2 "2" drgnx-work-map-mode-map) (work-collapse-layer-3 "3" drgnx-work-map-mode-map)
    (work-collapse-layer-4 "4" drgnx-work-map-mode-map) (work-collapse-layer-5 "5" drgnx-work-map-mode-map)
    (work-collapse-layer-6 "6" drgnx-work-map-mode-map) (work-view "C-k t" nil) (work-outline "O" drgnx-work-map-mode-map)
    (diff-toggle-layout "s" drgnx-diff-mode-map) (diff-toggle-file "TAB" drgnx-diff-mode-map)
    (diff-next-file "n" drgnx-diff-mode-map) (diff-prev-file "p" drgnx-diff-mode-map)
    (diff-visit "RET" drgnx-diff-mode-map) (review-visit "RET" drgnx-review-mode-map)
    (review-show-diff "d" drgnx-review-mode-map))
  "The VS Code profile's resolved keys on Linux before M12a gave it its macOS keys: (ID KEY MAP).
The commands of modules that need no installed package are in it, the later stages' too (diff, review).")

(ert-deftest drgnx-keys/the-later-stages-leave-no-global-hooks-or-pane-fillers ()
  ;; Setting the modules up for the snapshot must not stay: a registered browser pane made the next layouts test
  ;; open a third editor group, the persist hooks changed every later restore.  The registries' libraries load
  ;; first: run alone, the snapshot would otherwise be taken before layouts' defvars give the built-ins.
  (require 'drgnx-persist)
  (require 'drgnx-layouts (expand-file-name "modules/tools/drgnx-layouts" drgnx-dir))
  (let ((fillers (copy-tree (bound-and-true-p drgnx-layouts-pane-fillers)))
        (shapes (copy-tree (bound-and-true-p drgnx-layouts-shapes)))
        (state-fns (copy-sequence drgnx-persist-state-functions))
        (after-fns (copy-sequence drgnx-persist-after-restore-functions))
        (drgnx-keys-test--later-stages t)
        (drgnx-keys-test--strict t))
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
                              replace-next-file replace-prev-file ; the Search view's file moves (sja-complete S1)
                              search-mode-next ; the Search view's mode chip
                              search-scope-next search-scope-changed search-scope-branch ; its scope chips
                              search-history-prev search-history-next search-save search-run-saved ; its history
                              search-preview-file search-preview-keep search-preview-drop ; its preview tile
                              search-sheet-confirm search-sheet-cancel search-sheet-next search-sheet-previous ; the sheet
                              search-edit-results search-edit-save search-edit-delete-line ; Edit Results
                              search-to-agent search-handoff-send search-handoff-cancel ; Ask an Agent
                              search-handoff-next-who search-handoff-hidden
                              search-group-next ; the grouping control
                              layout-next browser-go keyboard-shortcuts shortcuts-change shortcuts-add shortcuts-filter
                              shortcuts-record-filter shortcuts-conflicts shortcuts-no-key shortcuts-changed
                              shortcuts-undo shortcuts-reset shortcuts-reset-all shortcuts-profile
                              ;; M11c-2's Agent settings page and its key in the Agents list
                              agent-settings-here agent-settings-refresh agent-settings-test agent-settings-test-all
                              agent-settings-add agent-settings-edit agent-settings-remove agent-settings-toggle
                              agent-settings-new-skill agent-settings-open-file agent-settings-other
                              agent-settings-openrouter agent-settings-report
                              ;; P9's plugins page: keys in its own page map only
                              plugins-refresh plugins-approve plugins-disable plugins-project-toggle
                              shortcuts-tty-fallback  ; M12b's terminal fallback in the Shortcuts editor
                              terminal-copy terminal-paste terminal-find terminal-copy-mode ; drgnx's terminal's own map
                              terminal-find-next terminal-find-previous ; its copy mode's
                              agents-panel-next-tool agents-panel-previous-tool agents-panel-next-change ; the panel's moves
                              agents-panel-previous-change agents-panel-next-prompt agents-panel-previous-prompt
                              ;; the Extensions list: its open key and its own keys
                              extensions-open extensions-search extensions-details extensions-install extensions-update
                              extensions-update-all extensions-uninstall extensions-toggle-project extensions-refresh
                              extensions-cancel extensions-show-log
                              extensions-trust-install extensions-trust-cancel ; the trust card's own keys
                              quit preferences edit-line-start edit-line-end edit-buffer-start edit-buffer-end edit-word-left
                              edit-word-right edit-delete-word-back edit-delete-line-back edit-copy edit-cut edit-paste
                              code-next-problem code-previous-problem ; M12d: F8 / S-F8
                              quick-help quick-help-close             ; M12f's quick help
                              close-pane                              ; M12f's Esc and q in a pane
                              settings-lisp-files-open           ; settings Task 28: RET on the Lisp files page
                              edit-undo                          ; Undo on C-z
                              settings-lisp-files-toggle settings-add-lisp-file   ; settings Task 29: t and a there
                              ;; settings Task 26: the Settings page took C-, from Modules, and its own keys
                              preferences-settings settings-page-tab settings-page-group settings-page-search
                              settings-page-reset settings-page-history settings-page-open-source settings-page-convert
                              agents-follow       ; part 3: the agent line's follow key
                              agents-here-follow agents-here-panel agents-here-quit   ; part 3: the who-is-here list
                              agents-follow-here agents-follow-resume agents-follow-stop agents-follow-panel   ; part 3: the follow window
                              agents-follow-wheel agents-take-wheel agents-give-wheel   ; part 3: the wheel
                              agents-panel agents-panel-toggle agents-panel-older agents-panel-toggle-type
                              agents-panel-preset-1 agents-panel-preset-2 agents-panel-preset-3 agents-panel-make-default
                              agents-panel-send agents-panel-stop agents-panel-pause agents-panel-resume
                              agents-panel-edit-queued agents-panel-drop-queued agents-panel-pair
                              agents-panel-accept agents-panel-reject agents-panel-allow agents-panel-always
                              agents-panel-pin agents-panel-ledger
                              agents-panel-output-search agents-panel-output-open agents-panel-output-more
                              agents-panel-revert-here agents-panel-fork-here
                              agents-panel-chip agents-panel-revoke-always agents-panel-act
                              agents-panel-start agents-panel-move agents-panel-compact agents-panel-mode agents-panel-model
                              agents-panel-compose agents-panel-newline agents-panel-back   ; the composer as an input buffer
                              agents-here-mark agents-here-huddle agents-huddle agents-huddle-send agents-huddle-open
                              work-huddle agents-view agents-open   ; part 3: the agent panel (its list) and H on a map overlap
                              sessions-search sessions-open sessions-resume sessions-resume-in-terminal
                              sessions-rescan ; Past Sessions' list and transcripts
                              ;; extra/debug needs no package now (the hub is its client), so it sets up here too
                              debug-start debug-breakpoint debug-breakpoint-conditional debug-logpoint
                              debug-breakpoint-enable debug-run-to-cursor debug-step-over debug-step-in debug-step-out
                              debug-stop debug-timeline-back debug-timeline-forward debug-timeline-open ; recorded runs' maps
                              debug-bisect-act ; the bisect card's RET
                              debug-share-cancel ; the Send Run card's Esc
                              debug-origin-open ; the origin card's RET
                              debug-restart debug-pause ; the toolbar's
                              debug-view debug-view-next debug-view-previous debug-view-expand debug-view-collapse
                              debug-view-activate debug-view-filter debug-set-value debug-copy-value debug-watch-remove
                              debug-watch-move-up debug-watch-move-down ; Run and Debug
                              debug-console debug-console-history-previous debug-console-history-next ; the console
                              debug-memory-next debug-memory-previous debug-memory-write ; the memory view
                              debug-heap-select ; the heap graph's RET
                              scm-open scm-stage scm-unstage scm-discard scm-toggle ; the Source Control view's own
                              scm-commit-message ; its commit box's Ctrl+Enter
                              menu-bar-open-file menu-bar-open-edit menu-bar-open-selection menu-bar-open-view
                              menu-bar-open-go menu-bar-open-run menu-bar-open-terminal menu-bar-open-help ; Alt+letter
                              debug-disassembly-toggle-breakpoint ; the disassembly view
                              debug-inline-breakpoint ; Shift+F9, as in VS Code
                              debug-run-no-debug ; Run Without Debugging's C-F5
                              inbox-open inbox-next inbox-previous inbox-press inbox-escape ; the inbox
                              terminal-toggle))   ; C-` is Toggle Terminal, as in VS Code (the panel keeps M-j)
         (drgnx-keys-test--later-stages t)
         (r (drgnx-keys-test--resolve '((vscode app editing window)) :platform 'linux)))
    (should (equal (mapcar (lambda (b) (list (plist-get b :id) (plist-get b :key) (plist-get b :map)))
                           (seq-remove (lambda (b) (memq (plist-get b :id) new)) (plist-get r :bindings)))
                   drgnx-keys-test--linux-snapshot))
    (should (equal (drgnx-keys-test--keys r 'edit-line-start) '("<home>")))
    (should (equal (drgnx-keys-test--keys r 'edit-word-left) '("C-<left>")))
    (should-not (drgnx-keys-test--keys r 'quit))
    (should-not (drgnx-keys-test--keys r 'preferences))))

(ert-deftest drgnx-keys/run-and-debug-keys-in-every-profile ()
  "The Run and Debug view's row keys are in all three profiles, in the view's own map."
  (let ((drgnx-keys-test--later-stages t))
    (pcase-dolist (`(,profile ,next ,expand ,set) '((vscode "<down>" "<right>" "<f2>") (emacs "n" "<right>" "e")
                                                    (vim "j" "l" "c")))
      (let ((r (drgnx-keys-test--resolve `((,profile app editing window)) :platform 'linux)))
        (should (member next (drgnx-keys-test--keys r 'debug-view-next)))
        (should (member expand (drgnx-keys-test--keys r 'debug-view-expand)))
        (should (member set (drgnx-keys-test--keys r 'debug-set-value)))
        (should (eq 'drgnx-debug-view-mode-map
                    (plist-get (seq-find (lambda (b) (eq (plist-get b :id) 'debug-view-next)) (plist-get r :bindings))
                               :map)))))))

(ert-deftest drgnx-keys/agent-composer-keys-in-every-profile ()
  "The agent panel's composer, in its own map: RET sends, S-RET breaks the line (C-j too in Emacs), and a key goes
back to the transcript; in the panel `s' (and Vim's `i') puts point in the composer."
  (let ((drgnx-keys-test--later-stages t))
    (pcase-dolist (`(,profile ,newline ,back ,compose)
                   '((vscode ("S-<return>") ("<escape>") ("s")) (emacs ("S-<return>" "C-j") ("C-c C-k") ("s"))
                     (vim ("S-<return>") ("<escape>") ("s" "i"))))
      (let ((r (drgnx-keys-test--resolve `((,profile app editing window)) :platform 'linux)))
        (cl-flet ((map-of (id) (plist-get (seq-find (lambda (b) (eq (plist-get b :id) id)) (plist-get r :bindings)) :map)))
          (should (equal (list profile '("RET")) (list profile (drgnx-keys-test--keys r 'agents-panel-send))))
          (should (equal (list profile newline) (list profile (drgnx-keys-test--keys r 'agents-panel-newline))))
          (should (equal (list profile back) (list profile (drgnx-keys-test--keys r 'agents-panel-back))))
          (should (equal (list profile compose) (list profile (drgnx-keys-test--keys r 'agents-panel-compose))))
          (dolist (id '(agents-panel-send agents-panel-newline agents-panel-back))
            (should (eq 'drgnx-agent-panel-composer-mode-map (map-of id))))
          (should (eq 'drgnx-agent-panel-mode-map (map-of 'agents-panel-compose)))
          (should-not (seq-find (lambda (c) (memq (plist-get c :map) '(drgnx-agent-panel-composer-mode-map
                                                                       drgnx-agent-panel-mode-map)))
                                (plist-get r :conflicts))))))))

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

;;;; A key in its own keymap (`:key-map')

(ert-deftest drgnx-keys/key-map-gives-one-key-its-own-keymap ()
  ;; One entry, two places: M-p in the view's map, C-p in the Find field's insert-state map.
  (should-not (drgnx-keys--entry-error '(open-file "M-p" "C-p" :map a-map :key-map (("C-p" (feat . b-map))))))
  (should (string-search "not one of the entry's keys"
                         (drgnx-keys--entry-error '(open-file "M-p" :key-map (("C-p" b-map))))))
  (should (string-search "is not (KEY MAP)" (drgnx-keys--entry-error '(open-file "M-p" :key-map (("M-p"))))))
  (should (drgnx-keys--entry-error '(open-file "M-p" :key-map "C-p")))
  (let ((a (drgnx-keys--entry '(open-file "M-p" "C-p" :map a-map :key-map (("C-p" (feat . b-map)))) nil 'linux)))
    (should (eq (drgnx-keys-entry-map a "M-p") 'a-map))
    (should (equal (drgnx-keys-entry-map a "C-p") '(feat . b-map))))
  ;; on macOS the key is turned as the others are; :mac's own keys take the entry's :map
  (let ((a (drgnx-keys--entry '(open-file "C-p" :key-map (("C-p" b-map))) '(:mac-cmd t) 'macos)))
    (should (equal (plist-get a :keys) '("s-p")))
    (should (eq (drgnx-keys-entry-map a "s-p") 'b-map)))
  (let ((r (drgnx-keys-test--resolve '((vscode app editing window))
                                     :user '(:bind ((open-file "C-c o" "C-c O" :map a-map
                                                               :key-map (("C-c O" drgnx-keys-test-late-map))))))))
    (should (equal (mapcar (lambda (b) (list (plist-get b :key) (plist-get b :map)))
                           (seq-filter (lambda (b) (eq (plist-get b :id) 'open-file)) (plist-get r :bindings)))
                   '(("C-c o" a-map) ("C-c O" drgnx-keys-test-late-map))))))

(defun drgnx-keys-test--placed (r id)
  "The keys resolution R binds command ID to, each with its keymap symbol: ((KEY MAPSYM)…)."
  (mapcar (lambda (b) (list (plist-get b :key) (cdr (drgnx-commands--keymap-spec (plist-get b :map)))))
          (seq-filter (lambda (b) (eq (plist-get b :id) id)) (plist-get r :bindings))))

(ert-deftest drgnx-keys/vim-search-keys-in-their-states ()
  ;; Spec §7: Vim's i (normal state) in the Search view, d d and Z Q in Edit Results, C-p / C-n in the Find field's
  ;; insert state beside the view's M-p / M-n; each in its own state map, none in a conflict.
  (let* ((drgnx-keys-test--later-stages t)
         (r (drgnx-keys-test--resolve '((vim app editing window)) :platform 'linux)))
    (should (equal (drgnx-keys-test--placed r 'search-edit-results)
                   '(("C-c C-e" drgnx-replace-keys-map) ("i" drgnx-replace-normal-state-map))))
    (should (equal (drgnx-keys-test--placed r 'search-edit-delete-line)
                   '(("C-c C-d" drgnx-search-edit-keys-map) ("d d" drgnx-search-edit-normal-state-map))))
    (should (equal (drgnx-keys-test--placed r 'search-edit-abort)
                   '(("C-c C-k" drgnx-search-edit-keys-map) ("Z Q" drgnx-search-edit-normal-state-map))))
    (should (equal (drgnx-keys-test--placed r 'search-history-prev)
                   '(("M-p" drgnx-replace-keys-map) ("C-p" drgnx-replace-find-insert-state-map))))
    (should (equal (drgnx-keys-test--placed r 'search-history-next)
                   '(("M-n" drgnx-replace-keys-map) ("C-n" drgnx-replace-find-insert-state-map))))
    (dolist (key '("i" "d d" "Z Q" "C-p" "C-n"))
      (should-not (seq-find (lambda (c) (and (equal (plist-get c :key) key)
                                             (string-prefix-p "drgnx-" (format "%s" (plist-get c :map)))))
                            (plist-get r :conflicts))))))

(ert-deftest drgnx-keys/a-views-state-keys-show-with-their-state ()
  ;; The sheet and the cheat sheet: the first key, then the keys of a view's state map with the state.
  (should (equal (drgnx-modal-where 'drgnx-replace-normal-state-map) "normal state"))
  (should (equal (drgnx-modal-where '(drgnx-replace . drgnx-replace-find-insert-state-map)) "insert state"))
  (should-not (drgnx-modal-where 'drgnx-replace-keys-map))
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (drgnx-command-define 'search-history-prev :category "Search" :title "Previous Search" :command #'ignore :doc "test")
    (let ((c (drgnx-commands-get 'search-history-prev)))
      (setf (drgnx-cmd-bound c) '(("M-p" drgnx-replace . drgnx-replace-keys-map)
                                  ("C-p" drgnx-replace . drgnx-replace-find-insert-state-map)))
      (should (equal (drgnx-surfaces--sheet-key c t) "M-p (in drgnx-replace-keys), C-p (insert state)")))))
