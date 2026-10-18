;;; compat-gryphn-test.el --- batch tests: external modules and the gryphn shim -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(require 'drgnx-compat-gryphn)

(defmacro drgnx-ext-test--with (dir &rest body)
  "BODY with a fresh registry and module report, a user config dir, and DIR for external code."
  (declare (indent 1))
  `(let* ((,dir (make-temp-file "drgnx-ext" t)) (cfg (make-temp-file "drgnx-cfg" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
          (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
          (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
          (drgnx-keys-profiles (copy-tree drgnx-keys-profiles)) (load-path load-path))
     (unwind-protect (progn ,@body) (delete-directory ,dir t) (delete-directory cfg t))))

(ert-deftest drgnx-compat/gryphn-commands-land-in-the-registry ()
  (drgnx-ext-test--with dir
    (gryphn-command-define 'kx-board :title "Show Board" :category "Board" :command #'ignore :key "<f5>" :doc "d")
    (let ((c (drgnx-commands-get 'kx-board)))
      (should c)
      (should (equal (drgnx-cmd-title c) "Show Board")))
    (should (assq 'kx-board (plist-get (alist-get 'vscode drgnx-keys-profiles) :bind)))))

(ert-deftest drgnx-compat/gryphn-key-joins-every-profile ()
  ;; M4-7: no profile forgets a command — vscode and emacs bind the key, vim leaves it to the palette
  (drgnx-ext-test--with dir
    (gryphn-command-define 'kx-board :title "Show Board" :category "Board" :command #'ignore :key "<f5>")
    (gryphn-command-define 'kx-mapped :title "Mapped" :category "Board" :command #'ignore :key "x" :map 'kx-board-map)
    (gryphn-command-define 'kx-keyless :title "Keyless" :category "Board" :command #'ignore)
    (let ((bind (lambda (p) (plist-get (alist-get p drgnx-keys-profiles) :bind))))
      (dolist (p '(vscode emacs))
        (should (equal (assq 'kx-board (funcall bind p)) '(kx-board "<f5>")))
        (should (equal (assq 'kx-mapped (funcall bind p)) '(kx-mapped "x" :map kx-board-map)))
        (should-not (assq 'kx-keyless (funcall bind p))))
      (should (equal (cadr (assq 'kx-board (funcall bind 'vim))) :none))
      (should (equal (cadr (assq 'kx-mapped (funcall bind 'vim))) :none))
      (should-not (assq 'kx-keyless (funcall bind 'vim))))))

(ert-deftest drgnx-compat/external-modules-load-and-report ()
  (drgnx-ext-test--with dir
    (write-region "(require 'gryphn-commands)\n(gryphn-command-define 'kx-ext :title \"Ext\" :category \"X\" :command #'ignore)\n(provide 'kx-good)\n"
                  nil (expand-file-name "kx-good.el" dir) nil 'silent)
    (write-region "(error \"broken on purpose\")\n" nil (expand-file-name "kx-bad.el" dir) nil 'silent)
    (drgnx-modules-write-state
     `(:version 1 :external ((:name kx :path ,dir :features (kx-good kx-bad))
                             (:name gone :path "/nonexistent/drgnx-ext" :features (whatever)))))
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
      (drgnx-modules-write-state `(:version 1 :external ((:name gryphn :path ,path :features (gryphn-org gryphn-run gryphn-agents gryphn-search)))))
      (drgnx-modules-load-external)
      (dolist (f '(gryphn-org gryphn-run gryphn-agents gryphn-search))
        (let ((r (alist-get (intern (format "external/gryphn/%s" f)) (drgnx-modules-report))))
          ;; ok, or waiting for a package it would otherwise have installed (never installed)
          (should (memq (plist-get r :status) '(ok missing-packages)))
          (should (eq (eq (plist-get r :status) 'missing-packages) (and (plist-get r :missing) t)))))
      (should (drgnx-commands-get 'board-view))
      (should (drgnx-commands-get 'board-dispatch)))))
