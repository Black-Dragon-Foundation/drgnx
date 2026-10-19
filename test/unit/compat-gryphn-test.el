;;; compat-gryphn-test.el --- batch tests: external modules and the gryphn shim -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(require 'drgnx-compat-gryphn)

(defmacro drgnx-ext-test--with (dir &rest body)
  "BODY with a fresh registry and module report, a user config dir, and DIR for external code."
  (declare (indent 1))
  `(let* ((,dir (make-temp-file "drgnx-ext" t)) (cfg (make-temp-file "drgnx-cfg" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
          (drgnx-modules--table nil) (drgnx-modules--report nil)
          (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
          (drgnx-keys-profiles (copy-tree drgnx-keys-profiles)) (load-path load-path))
     (unwind-protect (progn ,@body) (delete-directory ,dir t) (delete-directory cfg t))))

(ert-deftest drgnx-compat/gryphn-commands-land-in-the-registry ()
  (drgnx-ext-test--with dir
    (gryphn-command-define 'kx-board :title "Show Board" :category "Board" :command #'ignore :key "<f19>" :doc "d")
    (let ((c (drgnx-commands-get 'kx-board)))
      (should c)
      (should (equal (drgnx-cmd-title c) "Show Board")))
    (should (assq 'kx-board (plist-get (alist-get 'vscode drgnx-keys-profiles) :bind)))))

(ert-deftest drgnx-compat/gryphn-key-joins-every-profile ()
  ;; M4-7: no profile forgets a command — vscode and emacs bind the key, vim leaves it to the palette
  (drgnx-ext-test--with dir
    (gryphn-command-define 'kx-board :title "Show Board" :category "Board" :command #'ignore :key "<f19>")
    (gryphn-command-define 'kx-mapped :title "Mapped" :category "Board" :command #'ignore :key "<f20>" :map 'kx-board-map)
    (gryphn-command-define 'kx-keyless :title "Keyless" :category "Board" :command #'ignore)
    (let ((bind (lambda (p) (plist-get (alist-get p drgnx-keys-profiles) :bind))))
      (dolist (p '(vscode emacs))
        (should (equal (assq 'kx-board (funcall bind p)) '(kx-board "<f19>")))
        (should (equal (assq 'kx-mapped (funcall bind p)) '(kx-mapped "<f20>" :map kx-board-map)))
        (should-not (assq 'kx-keyless (funcall bind p))))
      (should (equal (cadr (assq 'kx-board (funcall bind 'vim))) :none))
      (should (equal (cadr (assq 'kx-mapped (funcall bind 'vim))) :none))
      (should-not (assq 'kx-keyless (funcall bind 'vim))))))

(ert-deftest drgnx-compat/a-gryphn-key-never-replaces-a-shipped-entry ()
  ;; I1: gryphn's ids are drgnx's; the shipped Emacs and Vim entries stay, and Emacs' own keys are not taken
  (drgnx-ext-test--with dir
    (setq drgnx-keys-profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir)))
    (let* ((entry (lambda (p id) (assq id (plist-get (alist-get p drgnx-keys-profiles) :bind))))
           (before (mapcar (lambda (p) (copy-tree (plist-get (alist-get p drgnx-keys-profiles) :bind))) '(vscode emacs vim))))
      (should (equal (funcall entry 'emacs 'go-quick-open) '(go-quick-open :none "C-x p f (stock)")))
      (should (equal (funcall entry 'vim 'go-quick-open) '(go-quick-open "SPC f p")))
      (gryphn-command-define 'go-quick-open :title "Quick Open" :category "Go" :command #'ignore :key "C-p")
      (gryphn-command-define 'kx-sidebar :title "Toggle Sidebar" :category "View" :command #'ignore :key "C-b")
      (should (equal (funcall entry 'emacs 'go-quick-open) '(go-quick-open :none "C-x p f (stock)")))
      (should (equal (funcall entry 'vim 'go-quick-open) '(go-quick-open "SPC f p")))
      (should (equal (funcall entry 'vscode 'go-quick-open) '(go-quick-open "C-p")))           ; shipped, the same
      (should-not (funcall entry 'emacs 'kx-sidebar))                                             ; C-b is backward-char
      (should-not (funcall entry 'vscode 'kx-sidebar))                                         ; vscode's toggle-sidebar has C-b
      (should (equal (funcall entry 'vim 'kx-sidebar) '(kx-sidebar :none "the palette")))
      ;; a key another entry of the profile already binds is not taken either
      (let ((taken (cadr (seq-find (lambda (e) (stringp (cadr e))) (plist-get (alist-get 'emacs drgnx-keys-profiles) :bind)))))
        (gryphn-command-define 'kx-clash :title "Clash" :category "X" :command #'ignore :key taken)
        (should-not (funcall entry 'emacs 'kx-clash)))
      ;; and the shipped entries are all still there, unchanged
      (cl-mapc (lambda (p old) (dolist (e old) (should (equal e (funcall entry p (car e))))))
               '(vscode emacs vim) before))))

(defun drgnx-compat-test--drgnx-view-explorer () "drgnx's View: Explorer, in the tests." (interactive))

(ert-deftest drgnx-compat/a-gryphn-id-drgnx-has-gets-a-prefix ()
  ;; gryphn's view-explorer (Toggle Sidebar, C-b) never replaces drgnx's View: Explorer: it is gryphn/view-explorer,
  ;; with its key where drgnx's profile does not own it, said once; gryphn's own ids keep theirs when loaded again.
  (drgnx-ext-test--with dir
    (setq drgnx-keys-profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir)))
    (drgnx-command-define 'view-explorer :category "View" :title "View: Explorer" :command #'drgnx-compat-test--drgnx-view-explorer)
    (write-region (concat "(require 'gryphn-commands)\n"
                          "(gryphn-command-define 'view-explorer :title \"Toggle Sidebar\" :category \"View\" :command #'ignore :key \"C-b\")\n"
                          "(gryphn-command-define 'kx-board :title \"Show Board\" :category \"Board\" :command #'ignore :key \"<f19>\")\n")
                  nil (expand-file-name "kx-fake-gryphn.el" dir) nil 'silent)
    (let ((said nil) (drgnx-compat-gryphn--renamed nil))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
        (load (expand-file-name "kx-fake-gryphn.el" dir) nil t)
        (load (expand-file-name "kx-fake-gryphn.el" dir) nil t))      ; loaded again: nothing new
      (should (eq (drgnx-cmd-command (drgnx-commands-get 'view-explorer)) #'drgnx-compat-test--drgnx-view-explorer))
      (should (equal (drgnx-cmd-title (drgnx-commands-get 'gryphn/view-explorer)) "Toggle Sidebar"))
      (should-not (drgnx-commands-get 'gryphn/gryphn/view-explorer))
      (should (drgnx-commands-get 'kx-board))                       ; an id drgnx does not have stays as it is
      (should-not (drgnx-commands-get 'gryphn/kx-board))
      (should (= 1 (length (seq-filter (lambda (m) (string-search "gryphn/view-explorer" m)) said))))
      (let ((entry (lambda (p id) (assq id (plist-get (alist-get p drgnx-keys-profiles) :bind)))))
        (should (equal (cadr (funcall entry 'vscode 'view-explorer)) "C-S-e"))   ; drgnx's entries untouched
        (should-not (funcall entry 'vscode 'gryphn/view-explorer))            ; C-b is VS Code's Toggle Sidebar
        (should-not (funcall entry 'emacs 'gryphn/view-explorer))             ; C-b is backward-char
        (should (equal (funcall entry 'vim 'gryphn/view-explorer) '(gryphn/view-explorer :none "the palette")))))))

(ert-deftest drgnx-compat/external-modules-load-and-report ()
  (drgnx-ext-test--with dir
    (write-region "(require 'gryphn-commands)\n(gryphn-command-define 'kx-ext :title \"Ext\" :category \"X\" :command #'ignore)\n(provide 'kx-good)\n"
                  nil (expand-file-name "kx-good.el" dir) nil 'silent)
    (write-region "(error \"broken on purpose\")\n" nil (expand-file-name "kx-bad.el" dir) nil 'silent)
    (drgnx-modules-update-state
     (lambda (_)
       `(:external ((:name kx :path ,dir :features (kx-good kx-bad))
                    (:name gone :path "/nonexistent/drgnx-ext" :features (whatever))))))
    (drgnx-modules-load-external)
    (should (drgnx-commands-get 'kx-ext))
    (should (eq (plist-get (alist-get 'external/kx/kx-good (drgnx-modules-report)) :status) 'ok))
    (should (eq (plist-get (alist-get 'external/kx/kx-bad (drgnx-modules-report)) :status) 'failed))
    (should (eq (plist-get (alist-get 'external/gone (drgnx-modules-report)) :status) 'failed))))

(ert-deftest drgnx-compat/the-real-gryphn-board-loads ()
  ;; Read-only: a gryphn checkout named by $DRGNX_GRYPHN_DIR.
  (let ((path (getenv "DRGNX_GRYPHN_DIR")))
    (skip-unless (and path (file-directory-p path)))
    (drgnx-ext-test--with dir
      (drgnx-modules-update-state (lambda (_) `(:external ((:name gryphn :path ,path :features (gryphn-org gryphn-run gryphn-agents gryphn-search))))))
      (drgnx-modules-load-external)
      (dolist (f '(gryphn-org gryphn-run gryphn-agents gryphn-search))
        (let ((r (alist-get (intern (format "external/gryphn/%s" f)) (drgnx-modules-report))))
          ;; ok, or waiting for a package it would otherwise have installed (never installed)
          (should (memq (plist-get r :status) '(ok missing-packages)))
          (should (eq (eq (plist-get r :status) 'missing-packages) (and (plist-get r :missing) t)))))
      (should (drgnx-commands-get 'board-view))
      (should (drgnx-commands-get 'board-dispatch)))))
