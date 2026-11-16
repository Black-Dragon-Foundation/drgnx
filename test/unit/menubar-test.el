;;; menubar-test.el --- batch tests: the menu bar (File Edit Selection View Go Run Terminal Help) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/ui/drgnx-menubar" drgnx-dir) t t)

(defun drgnx-menubar-test-run () (interactive) nil)

(defmacro drgnx-menubar-test--with (ids &rest body)
  "BODY with a registry of its own holding a stub command for each of IDS (a list of (ID TITLE . PLIST))."
  (declare (indent 1))
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
     (dolist (spec ,ids)
       (apply #'drgnx-command-define (car spec) :title (cadr spec) :category "Test"
              :command (or (plist-get (cddr spec) :command) #'drgnx-menubar-test-run)
              (cl-loop for (k v) on (cddr spec) by #'cddr unless (eq k :command) append (list k v))))
     ,@body))

(defun drgnx-menubar-test--items (map)
  "The (KEY TITLE . PLIST) items of menu keymap MAP, separators as `--', submenus as (KEY TITLE ITEMS)."
  (let (out)
    (map-keymap (lambda (key b)
                  (when (eq (car-safe b) 'menu-item)
                    (let ((title (nth 1 b)) (def (nth 2 b)))
                      (push (cond ((string-prefix-p "--" title) '--)
                                  ((keymapp def) (list key title (drgnx-menubar-test--items def)))
                                  (t (cons key (cons title (nthcdr 3 b)))))
                            out))))
                map)
    (nreverse out)))

(ert-deftest drgnx-menubar/the-eight-menus-in-vs-codes-order ()
  (should (equal (mapcar #'car (drgnx-menubar-menus))
                 '(file edit selection view go run terminal help)))
  (should (equal (mapcar #'cadr (drgnx-menubar-menus))
                 '("File" "Edit" "Selection" "View" "Go" "Run" "Terminal" "Help"))))

(ert-deftest drgnx-menubar/every-layout-id-is-defined-somewhere ()
  "Each id of etc/menus.eld is a registry command: defined by a `drgnx-command-define' in the sources, or bound in
the VS Code profile (whose ids the key lints check against the registry)."
  (let ((text (with-temp-buffer
                (dolist (dir '("core" "wb" "modules"))
                  (dolist (f (directory-files-recursively (expand-file-name dir drgnx-dir) "\\.el\\'"))
                    (insert-file-contents f)))
                (insert-file-contents (expand-file-name "keys/vscode.eld" drgnx-dir))
                (buffer-string)))
        missing)
    (dolist (id (drgnx-menubar--layout-ids))
      (unless (string-match-p (concat "['(]" (regexp-quote (symbol-name id)) "[ )\n]") text)
        (push id missing)))
    (should-not missing)))

(ert-deftest drgnx-menubar/an-item-shows-the-profiles-key-and-follows-a-switch ()
  (drgnx-menubar-test--with '((file-new "New File") (file-new-window "New Window"))
    (setf (drgnx-cmd-bound (drgnx-commands-get 'file-new)) '(("C-n" . nil)))
    (let ((items (drgnx-menubar-test--items (drgnx-menubar-keymap 'file))))
      (should (equal (cadr (assq 'file-new items)) "New File"))
      (should (equal (plist-get (cddr (assq 'file-new items)) :keys) "C-n"))
      (should-not (equal (plist-get (cddr (assq 'file-new-window items)) :keys) "C-n")))
    ;; another profile: the next open shows its key
    (setf (drgnx-cmd-bound (drgnx-commands-get 'file-new)) '(("C-x C-n" . nil)))
    (should (equal (plist-get (cddr (assq 'file-new (drgnx-menubar-test--items (drgnx-menubar-keymap 'file)))) :keys)
                   "C-x C-n"))))

(ert-deftest drgnx-menubar/unregistered-ids-are-left-out-and-groups-are-separated ()
  (drgnx-menubar-test--with '((file-new "New File") (open-file "Open File…") (quit "Quit"))
    (let ((items (drgnx-menubar-test--items (drgnx-menubar-keymap 'file))))
      (should (equal (mapcar (lambda (i) (if (consp i) (car i) i)) items)
                     '(file-new -- open-file -- quit))))))

(ert-deftest drgnx-menubar/a-when-that-fails-disables-and-a-missing-library-hides ()
  (drgnx-menubar-test--with `((file-new "New File" :when ignore)
                              (open-file "Open File" :command ,(progn (autoload 'drgnx-menubar-test-gone "drgnx-no-such-library" nil t)
                                                                      'drgnx-menubar-test-gone)))
    (let* ((items (drgnx-menubar-test--items (drgnx-menubar-keymap 'file)))
           (new (assq 'file-new items)))
      (should new)
      (should-not (eval (plist-get (cddr new) :enable) t))
      (should-not (assq 'open-file items)))))

(ert-deftest drgnx-menubar/a-modules-menu-path-joins-its-menu ()
  (drgnx-menubar-test--with '((file-new "New File") (my-thing "My Thing" :menu ("View"))
                              (my-option "My Option" :menu ("Options")))
    (should (assq 'my-thing (drgnx-menubar-test--items (drgnx-menubar-keymap 'view))))
    (let ((prefs (seq-find (lambda (i) (and (consp i) (equal (cadr i) "Preferences")))
                           (drgnx-menubar-test--items (drgnx-menubar-keymap 'file)))))
      (should prefs)
      (should (assq 'my-option (nth 2 prefs))))))

(ert-deftest drgnx-menubar/choosing-an-item-runs-its-command ()
  (let (ran shown)
    (drgnx-menubar-test--with `((file-new "New File" :command ,(lambda () (interactive) (setq ran t))))
      (cl-letf (((symbol-function 'x-popup-menu)
                 (lambda (pos map) (setq shown (list pos map)) '(file-new))))
        (drgnx-menubar-open 'file)))
    (should shown)
    (should (keymapp (nth 1 shown)))
    (should ran)))

(ert-deftest drgnx-menubar/the-mode-puts-the-eight-menus-in-the-menu-bar-and-takes-them-out ()
  (unwind-protect
      (progn
        (drgnx-menubar-mode 1)
        (let ((bar (lookup-key (current-global-map) [menu-bar])) (ours (lookup-key drgnx-menubar-mode-map [menu-bar])))
          (ignore bar)
          (dolist (id '(file edit selection view go run terminal help-menu))   ; Help stands in Emacs's, last
            (should (lookup-key ours (vector id))))
          (dolist (id '(options buffer tools))
            (should (eq (lookup-key ours (vector id)) 'undefined)))))
    (drgnx-menubar-mode -1))
  (should-not drgnx-menubar-mode))

(ert-deftest drgnx-menubar/mnemonics-are-the-vs-code-profiles-only ()
  "Alt+F opens File in the VS Code profile; the Emacs and Vim profiles bind no menu key on Alt."
  (let ((profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))))
    (let ((bind (plist-get (alist-get 'vscode profiles) :bind)))
      ;; on macOS none: the system menu bar holds the menus there (VS Code has no mnemonics on a Mac)
      (should (equal (cdr (assq 'menu-bar-open-file bind)) '("M-f" :mac nil)))
      (should (equal (cdr (assq 'menu-bar-open-help bind)) '("M-h" :mac nil))))
    (dolist (p '(emacs vim))
      (let ((bind (plist-get (alist-get p profiles) :bind)))
        (dolist (m '(file edit selection view go run terminal help))
          (should (eq (cadr (assq (intern (format "menu-bar-open-%s" m)) bind)) :none)))))))

(ert-deftest drgnx-menubar/the-title-row-shows-the-menus-or-one-button ()
  (let ((drgnx-menubar-visibility 'classic))
    (should (equal (mapcar #'car (drgnx-menubar-title-items 200))
                   '(drgnx-topline-menu-file drgnx-topline-menu-edit drgnx-topline-menu-selection
                                             drgnx-topline-menu-view drgnx-topline-menu-go drgnx-topline-menu-run
                                             drgnx-topline-menu-terminal drgnx-topline-menu-help)))
    ;; no room for eight: one button
    (should (equal (mapcar #'car (drgnx-menubar-title-items 10)) '(drgnx-topline-menu))))
  (let ((drgnx-menubar-visibility 'compact))
    (should (equal (mapcar #'car (drgnx-menubar-title-items 200)) '(drgnx-topline-menu))))
  (dolist (v '(hidden toggle))
    (let ((drgnx-menubar-visibility v))
      (should-not (drgnx-menubar-title-items 200)))))

(provide 'menubar-test)
;;; menubar-test.el ends here
