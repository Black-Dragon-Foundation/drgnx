;;; palette-modes-test.el --- batch tests: the palette's commands mode and files mode (audit P1-P3) -*- lexical-binding: t -*-
;; test-class: det

;; The 2026-11-16 UI/UX audit: the palette listed context-only commands everywhere (P3), mixed files and agents into
;; the commands with onboarding steps first (P2), and Quick Open was another, older popup (P1).  As in VS Code:
;; Ctrl+Shift+P lists the commands that can run here, recently used first, then the rest by name; Ctrl+P is the same
;; palette listing the project's files.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-palette)
(require 'project)

(define-derived-mode palette-modes-test-mode special-mode "PM" "A view whose commands are context-only.")
(defvar palette-modes-test-mode-map)

(defun palette-modes-test--click (event) (interactive "e") (ignore event))

(defmacro palette-modes-test--registry (&rest body)
  "BODY with an empty registry and an empty palette history."
  (declare (indent 0))
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (drgnx-palette--history nil))
     ,@body))

(ert-deftest palette-modes/a-views-commands-are-listed-only-in-that-view ()
  "P3: a command keyed in a mode's map (`:map') is offered only where that map is active; global ones everywhere."
  (palette-modes-test--registry
    (drgnx-command-define 'everywhere :title "Everywhere" :category "Test" :command #'ignore)
    (drgnx-command-define 'in-view :title "In the View" :category "Test" :command #'ignore
                          :map 'palette-modes-test-mode-map)
    (with-temp-buffer
      (fundamental-mode)
      (should (equal (mapcar #'car (drgnx-palette-candidates)) '("Test: Everywhere"))))
    (with-temp-buffer
      (palette-modes-test-mode)
      (should (equal (sort (mapcar #'car (drgnx-palette-candidates)) #'string<)
                     '("Test: Everywhere" "Test: In the View"))))))

(ert-deftest palette-modes/a-prefix-map-under-the-global-map-is-everywhere ()
  "P3: a keymap reached from the global map through a prefix key counts as active (it is a global map's part)."
  (palette-modes-test--registry
    (defvar palette-modes-test--prefix-map (make-sparse-keymap))
    (let ((was (current-global-map)) (global (make-sparse-keymap)))
      (set-keymap-parent global was)
      (define-key global (kbd "C-c 9") palette-modes-test--prefix-map)
      (drgnx-command-define 'pre :title "Prefixed" :category "Test" :command #'ignore :map 'palette-modes-test--prefix-map)
      (should-not (drgnx-palette-candidates))           ; not reachable yet
      (use-global-map global)
      (unwind-protect (should (equal (mapcar #'car (drgnx-palette-candidates)) '("Test: Prefixed")))
        (use-global-map was)))))

(ert-deftest palette-modes/mouse-handlers-are-never-listed ()
  "P3: a command that needs a mouse event (\"Panel Header: Click\") cannot run from the palette."
  (palette-modes-test--registry
    (drgnx-command-define 'click :title "Header: Click" :category "Test" :command #'palette-modes-test--click)
    (drgnx-command-define 'plain :title "Plain" :category "Test" :command #'ignore)
    (should (equal (mapcar #'car (drgnx-palette-candidates)) '("Test: Plain")))))

(ert-deftest palette-modes/commands-mode-has-no-files ()
  "P2: the command palette lists commands, never the project's files (Quick Open does)."
  (let ((dir (file-name-as-directory (make-temp-file "palette-modes" t))))
    (unwind-protect
        (let ((default-directory dir) (project-vc-extra-root-markers '(".project")) seen)
          (write-region "" nil (expand-file-name ".project" dir) nil 'silent)
          (write-region "" nil (expand-file-name "README.md" dir) nil 'silent)
          (palette-modes-test--registry
            (drgnx-command-define 'a :title "Alpha" :category "Test" :command #'ignore)
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_p table &rest _) (setq seen (all-completions "" table)) "")))
              (drgnx-palette))
            (should (member "Test: Alpha" seen))
            (should-not (seq-find (lambda (l) (string-prefix-p "File: " l)) seen))))
      (delete-directory dir t))))

(ert-deftest palette-modes/with-nothing-typed-recent-first-then-by-name ()
  "P2: with nothing typed, the commands run lately come first (newest first), then every other command by its label,
not in the order the modules defined them (onboarding's steps came first)."
  (palette-modes-test--registry
    (drgnx-command-define 'z :title "Zeta" :category "Onboarding" :command #'ignore)
    (drgnx-command-define 'b :title "Beta" :category "Test" :command #'ignore)
    (drgnx-command-define 'a :title "Alpha" :category "Test" :command #'ignore)
    (drgnx-command-define 'c :title "Gamma" :category "Edit" :command #'ignore)
    (let ((drgnx-palette--history (list (list 'b 200) (list 'z 100))))
      (should (equal (mapcar #'car (drgnx-palette-candidates))
                     '("Test: Beta" "Onboarding: Zeta" "Edit: Gamma" "Test: Alpha"))))))

(ert-deftest palette-modes/typed-words-are-marked-in-picked-rows ()
  "P2: in a row Sjá picked, the typed words show in the match face (no completion style marks them)."
  (should (fboundp 'drgnx-palette--mark-typed))
  (let ((s (funcall 'drgnx-palette--mark-typed "> Run Tests in This File" "te fi")))
    (should (memq 'drgnx-palette-match (ensure-list (get-text-property (string-search "Te" s) 'face s))))
    (should (memq 'drgnx-palette-match (ensure-list (get-text-property (string-search "Fi" s) 'face s))))
    (should-not (get-text-property (string-search "Run" s) 'face s))))

(require 'drgnx-quick-open)

(ert-deftest palette-modes/quick-open-is-the-palettes-files-mode ()
  "P1: Quick Open without the hub lists the project's files in category `drgnx-file' (the palette's float), each row
the palette's: the file icon, the name, the folder; never `project-find-file''s plain list (marginalia's ls columns)."
  (let ((dir (file-name-as-directory (make-temp-file "palette-modes" t))) seen meta opened)
    (unwind-protect
        (let ((default-directory dir) (project-vc-extra-root-markers '(".project")))
          (make-directory (expand-file-name "core" dir))
          (dolist (f '(".project" "README.md" "core/a.el")) (write-region "" nil (expand-file-name f dir) nil 'silent))
          (cl-letf (((symbol-function 'drgnx-quick-open--hub-p) #'ignore)
                    ((symbol-function 'project-find-file) (lambda () (interactive) (error "Not the palette")))
                    ((symbol-function 'find-file) (lambda (f &rest _) (setq opened f)))
                    ((symbol-function 'completing-read)
                     (lambda (_p table &rest _)
                       (setq seen (all-completions "" table) meta (funcall table "" nil 'metadata))
                       "core/a.el")))
            (drgnx-quick-open))
          (should (equal (completion-metadata-get meta 'category) 'drgnx-file))
          (should (member "core/a.el" seen))
          (should (equal opened (expand-file-name "core/a.el" dir)))
          (pcase-let ((`((,shown ,_ ,annot)) (funcall (completion-metadata-get meta 'affixation-function) '("core/a.el"))))
            (should (string-suffix-p " a.el" (substring-no-properties shown)))
            (should (string-match-p "core" (substring-no-properties annot)))))
      (delete-directory dir t))))

(ert-deftest palette-modes/tab-previews-in-the-files-mode ()
  "P1: Tab in Quick Open shows the row's file, as the palette's footer says; the row's file is under the root."
  (should (eq (lookup-key (bound-and-true-p drgnx-quick-open-minibuffer-map) (kbd "TAB")) 'drgnx-palette-preview))
  (let ((drgnx-palette--file-rows nil) (drgnx-palette--file-root "/r/"))
    (should (equal (drgnx-palette--file "core/a.el") "/r/core/a.el"))))

(provide 'palette-modes-test)
;;; palette-modes-test.el ends here
