;;; keys-eld-test.el --- batch tests: the keys settings (they were keys.eld) -*- lexical-binding: t -*-
;; Every test runs under `drgnx-test-with-areas' (temp config and state folders, settings.el not applied in the
;; process).  Keys here are fakes; nothing is bound: the tests read, write and refuse settings.el, and the editor's apply
;; and surface refresh are stubbed.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/areas-fixture" drgnx-dir) nil t)
(require 'drgnx-keys)
(require 'drgnx-keys-edit)
(require 'drgnx-modal-choose)

(defmacro drgnx-keys-eld-test--editor (&rest body)
  "BODY with the editor's apply and surface refresh stubbed (they bind keys); `applied' counts the applies."
  (declare (indent 0))
  `(let ((applied 0) (drgnx-keys-last (or drgnx-keys-last '(:bindings nil))))
     (ignore applied)
     (cl-letf (((symbol-function 'drgnx-keys-apply) (lambda () (cl-incf applied) nil))
               ((symbol-function 'drgnx-surfaces-refresh) #'ignore))
       ,@body)))

(defconst drgnx-keys-eld-test--sample
  ";; my settings, hand written\n(drgnx-settings\n :version 1\n ;; a note\n (drgnx-keys-bind ((palette \"C-c p\") (line-numbers \"C-c l\" \"<f9>\")))\n (drgnx-keys-layers ((emacs editing) (vscode app window))) ; the stack\n (drgnx-keys-unbind (keys-sheet)))\n"
  "A settings.el with comments, a stack, entries and an unbind list.")

(defconst drgnx-keys-eld-test--other-stack '((vscode app editing window)))

(defun drgnx-keys-eld-test--bindings ()
  "The :bind entries settings.el holds now."
  (cdr (assq 'drgnx-keys-bind (drgnx-settings-area-fresh '(drgnx-keys-bind)))))

;;;; Applying

(ert-deftest drgnx-keys-eld/a-change-of-the-stack-applies-the-keys-at-once ()
  ;; The `:apply' of `drgnx-keys-layers' (the idle tick after settings.el or a setq changed it): the settings are the
  ;; authority now, so a stack chosen earlier in this session no longer wins over them.
  (drgnx-test-with-areas
    (drgnx-keys-eld-test--editor
      (let ((drgnx-keys-last '(:layers nil)) (drgnx-keys--session-layers '((vim app))))
        (drgnx-keys--layers-settings-apply)
        (should (= applied 1))
        (should-not drgnx-keys--session-layers)
        (drgnx-keys--settings-apply)               ; any other keys setting: apply, the session's stack stays
        (should (= applied 2))))))

(ert-deftest drgnx-keys-eld/nothing-is-applied-before-the-keys-were-applied-once ()
  (drgnx-test-with-areas
    (drgnx-keys-eld-test--editor
      (let ((drgnx-keys-last nil))
        (drgnx-keys--settings-apply)
        (should (= applied 0))))))

(ert-deftest drgnx-keys-eld/every-keys-setting-re-applies-the-keys ()
  (dolist (var '(drgnx-keys-layers drgnx-keys-pending-layers drgnx-keys-bind drgnx-keys-unbind drgnx-keys-mac-option
                                   drgnx-keys-tty-fallback))
    (let ((meta (drgnx-setting-meta var)))
      (should (eq (plist-get meta :agents) 'never))
      (should (eq (plist-get meta :workspace) 'never))
      (should (eq (plist-get meta :scope) 'global))
      (should (memq (plist-get meta :apply) '(drgnx-keys--settings-apply drgnx-keys--layers-settings-apply))))))

;;;; The settings

(ert-deftest drgnx-keys-eld/the-forms-the-guide-teaches-still-fit ()
  ;; The shapes docs/guide/keys.md shows all fit the settings' schemas.
  (dolist (case '((drgnx-keys-layers ((emacs editing) (vscode app window)))
                  (drgnx-keys-bind ((palette "C-c p") (line-numbers "C-c l" "<f9>") (open-file "C-c f" :map (org . org-mode-map))))
                  (drgnx-keys-bind ((palette "C-c p" :mac "s-p") (quit :none "reason" :mac "s-q") (menu "C-c m" :mac ())))
                  (drgnx-keys-bind ((toggle-panel "C-`" :everywhere "C-j") (x "C-c x" :map org-mode-map)))
                  (drgnx-keys-unbind (keys-sheet))
                  (drgnx-keys-mac-option characters)
                  (drgnx-keys-mac-option nil)
                  (drgnx-keys-tty-fallback (("C-S-p" . "M-Z")))
                  (drgnx-keys-pending-layers ((vim app editing window)))
                  (drgnx-keys-pending-layers nil)
                  (drgnx-keys-bind nil)))
    (should (equal (list case nil) (list case (drgnx-setting-check (car case) (cadr case)))))))

(ert-deftest drgnx-keys-eld/an-absent-file-is-the-default-stack ()
  (drgnx-test-with-areas
    (let ((user (drgnx-keys-read-user)))
      (should (equal (plist-get user :layers) drgnx-keys-eld-test--other-stack))
      (should-not (plist-get user :bind))
      (should-not (plist-get user :unbind))
      (should-not (plist-get user :mac-option)))
    (should-not (file-exists-p (drgnx-config-file 'settings)))))

(ert-deftest drgnx-keys-eld/each-mistake-is-a-problem-of-its-setting ()
  (dolist (case '((drgnx-keys-layers foo) (drgnx-keys-layers ((vscode . app))) (drgnx-keys-layers ((vscode apps)))
                  (drgnx-keys-bind foo) (drgnx-keys-bind ((palette . "C-c p"))) (drgnx-keys-bind ((palette)))
                  (drgnx-keys-bind ((palette "C-c p" :map "org-mode-map"))) (drgnx-keys-bind ((palette "C-c p" :mac 7)))
                  (drgnx-keys-unbind palette) (drgnx-keys-unbind (a "b"))
                  (drgnx-keys-mac-option 7) (drgnx-keys-pending-layers foo)))
    (should (equal (list case t) (list case (and (drgnx-setting-check (car case) (cadr case)) t))))))

(ert-deftest drgnx-keys-eld/the-user-keys-are-the-settings-values ()
  ;; Whatever set them: settings.el once applied, a `setq' in config.el.
  (drgnx-test-with-areas
    (let ((drgnx-keys-bind '((palette "C-c p"))) (drgnx-keys-unbind '(keys-sheet)) (drgnx-keys-mac-option 'meta)
          (drgnx-keys-tty-fallback '(("C-S-p" . "M-Z"))) (drgnx-keys-pending-layers '((vim app editing window))))
      (should (equal (drgnx-keys-read-user)
                     (list :layers drgnx-keys-eld-test--other-stack :pending-layers '((vim app editing window))
                           :bind '((palette "C-c p")) :unbind '(keys-sheet) :mac-option 'meta
                           :tty-fallback '(("C-S-p" . "M-Z"))))))))

(ert-deftest drgnx-keys-eld/a-process-that-has-not-applied-settings-el-reads-the-file ()
  ;; A batch command (`drgnx onboard'): nothing applied, the entries of the file are what the keys are.
  (drgnx-test-with-areas
    (drgnx-test-areas-put drgnx-keys-eld-test--sample)
    (let ((user (drgnx-keys-read-user)))
      (should (equal (plist-get user :layers) '((emacs editing) (vscode app window))))
      (should (equal (plist-get user :bind) '((palette "C-c p") (line-numbers "C-c l" "<f9>"))))
      (should (equal (plist-get user :unbind) '(keys-sheet))))))

;;;; Writers

(ert-deftest drgnx-keys-eld/a-symlinked-settings-el-stays-a-symlink ()
  (drgnx-test-with-areas
    (drgnx-keys-eld-test--editor
      (let ((real (expand-file-name "real-settings.el" drgnx-test-config-root)) (file (drgnx-config-file 'settings)))
        (make-directory (file-name-directory file) t)
        (write-region drgnx-keys-eld-test--sample nil real nil 'silent)
        (make-symbolic-link real file)
        (drgnx-keys--save-key :mac-option 'meta)
        (should (file-symlink-p file))
        (drgnx-keys-edit-bind 'open-file "C-c f")
        (should (file-symlink-p file))
        (let ((text (with-temp-buffer (insert-file-contents real) (buffer-string))))
          (should (string-search "open-file" text))
          (should (string-search "(drgnx-keys-mac-option meta)" text))
          (should (string-search ";; my settings, hand written" text)))
        (drgnx-keys-edit-undo)
        (should (file-symlink-p file))
        (should (string-search "(drgnx-keys-mac-option meta)" (with-temp-buffer (insert-file-contents real) (buffer-string))))))))

(ert-deftest drgnx-keys-eld/choose-profile-keeps-comments-and-binds ()
  (drgnx-test-with-areas
    (drgnx-test-areas-put drgnx-keys-eld-test--sample)
    (let ((prepared nil) (used nil))
      (cl-letf (((symbol-function 'drgnx-modal-prepare) (lambda (layers &rest _) (setq prepared layers) 'ready))
                ((symbol-function 'drgnx-keys-use) (lambda (layers &rest _) (setq used layers))))
        (drgnx-keys-choose-profile "VS Code"))
      (should (equal prepared drgnx-keys-eld-test--other-stack))
      (should (equal used drgnx-keys-eld-test--other-stack)))
    (should (equal (drgnx-test-areas-text)
                   (replace-regexp-in-string "((emacs editing) (vscode app window))" "((vscode app editing window))"
                                             drgnx-keys-eld-test--sample t t)))
    (let ((user (drgnx-keys-read-user)))
      (should (equal (plist-get user :layers) drgnx-keys-eld-test--other-stack))
      (should (equal (plist-get user :bind) '((palette "C-c p") (line-numbers "C-c l" "<f9>")))))))

(ert-deftest drgnx-keys-eld/choosing-a-profile-with-a-mistake-changes-nothing ()
  (drgnx-test-with-areas
    (let ((text "(drgnx-settings :version 1 (drgnx-keys-layers ((emacs editing)))  ; mine\n") (called nil))
      (drgnx-test-areas-put text)
      (cl-letf (((symbol-function 'drgnx-modal-prepare) (lambda (&rest _) (setq called t) 'ready))
                ((symbol-function 'drgnx-keys-use) (lambda (&rest _) (setq called t))))
        (should-error (drgnx-keys-choose-profile "VS Code") :type 'drgnx-settings-refused))
      (should-not called)
      (should (equal (drgnx-test-areas-text) text)))))

(ert-deftest drgnx-keys-eld/pending-layers-set-and-unset-keep-the-rest ()
  (drgnx-test-with-areas
    (drgnx-test-areas-put drgnx-keys-eld-test--sample)
    (cl-letf (((symbol-function 'drgnx-modal--write-report) #'ignore))
      (drgnx-keys--save-key :pending-layers '((vim app editing window)))
      (let ((text (drgnx-test-areas-text)))
        (should (string-search "(drgnx-keys-pending-layers ((vim app editing window)))" text))
        (should (string-search ";; a note" text))
        (should (string-search "(drgnx-keys-unbind (keys-sheet))" text)))
      (should (equal (drgnx-modal--pending) '((vim app editing window))))
      (drgnx-modal--forget-pending)
      (should (equal (drgnx-test-areas-text) drgnx-keys-eld-test--sample))            ; byte for byte as it was
      (should-not (drgnx-modal--pending))
      (should-not drgnx-keys-pending-layers)                                          ; and not applied any more
      (let ((before (drgnx-test-areas-text)))                                         ; nothing pending: nothing written
        (drgnx-modal--forget-pending)
        (should (equal (drgnx-test-areas-text) before))))))

(ert-deftest drgnx-keys-eld/saving-a-key-into-a-file-with-a-mistake-is-refused ()
  (drgnx-test-with-areas
    (let ((text "(drgnx-settings :version 1 (drgnx-keys-layers ((emacs editing))) ;; mine\n"))
      (drgnx-test-areas-put text)
      (should-error (drgnx-keys--save-key :mac-option 'meta) :type 'drgnx-settings-refused)
      (should (equal (drgnx-test-areas-text) text)))))

;;;; The editor

(ert-deftest drgnx-keys-eld/the-editor-refuses-a-settings-el-with-a-mistake ()
  (drgnx-test-with-areas
    (drgnx-keys-eld-test--editor
      (let ((text "(drgnx-settings :version 1 (drgnx-keys-mac-option 7)\n"))
        (drgnx-test-areas-put text)
        (let ((err (should-error (drgnx-keys-edit-bind 'palette "C-c p") :type 'drgnx-settings-refused)))
          (should (string-search "settings.el has a mistake" (cadr err))))
        (should (equal (drgnx-test-areas-text) text))
        (should-not (file-exists-p (drgnx-keys-edit--undo-file)))
        (should (= applied 0))))))

(ert-deftest drgnx-keys-eld/the-editor-writes-only-what-it-changes ()
  (drgnx-test-with-areas
    (drgnx-keys-eld-test--editor
      (drgnx-test-areas-put drgnx-keys-eld-test--sample)
      (should (drgnx-keys-edit-bind 'open-file "C-c f"))
      (should (= applied 1))
      (let ((text (drgnx-test-areas-text)))
        (should (string-search "(open-file \"C-c f\")" text))
        (should (string-search ";; a note" text))
        (should (string-search "(drgnx-keys-layers ((emacs editing) (vscode app window))) ; the stack" text))
        (should (string-search "(drgnx-keys-unbind (keys-sheet))" text)))
      (should (equal (drgnx-keys-eld-test--bindings)
                     '((palette "C-c p") (line-numbers "C-c l" "<f9>") (open-file "C-c f")))))))

(ert-deftest drgnx-keys-eld/the-undo-copy-is-a-data-file-and-undo-puts-the-settings-back ()
  (drgnx-test-with-areas
    (drgnx-keys-eld-test--editor
      (drgnx-test-areas-put drgnx-keys-eld-test--sample)
      (drgnx-keys-edit-bind 'open-file "C-c f")
      (let ((saved (plist-get (drgnx-file-read (drgnx-keys-edit--undo-file)) :data)))
        (should (equal (cdr (assq 'drgnx-keys-bind (plist-get saved :old)))
                       '(((palette "C-c p") (line-numbers "C-c l" "<f9>")))))
        (should (assq 'drgnx-keys-bind (plist-get saved :new))))
      (drgnx-keys-edit-undo)
      (should (equal (drgnx-test-areas-text) drgnx-keys-eld-test--sample))
      (should-not (file-exists-p (drgnx-keys-edit--undo-file)))
      (should (equal (plist-get (drgnx-keys-read-user) :bind) '((palette "C-c p") (line-numbers "C-c l" "<f9>")))))))

(ert-deftest drgnx-keys-eld/undo-takes-an-entry-that-was-new-away-again ()
  ;; A setting with no entry before the change has none after the undo, and its value goes back through the resolver.
  (drgnx-test-with-areas
    (drgnx-keys-eld-test--editor
      (drgnx-keys-edit-bind 'open-file "C-c f")
      (should (drgnx-settings-area-has-entry-p 'drgnx-keys-bind))
      (should (equal drgnx-keys-bind '((open-file "C-c f"))))
      (drgnx-keys-edit-undo)
      (should-not (drgnx-settings-area-has-entry-p 'drgnx-keys-bind))
      (should-not drgnx-keys-bind))))

(ert-deftest drgnx-keys-eld/undo-is-refused-when-settings-el-changed-since ()
  (drgnx-test-with-areas
    (drgnx-keys-eld-test--editor
      (drgnx-test-areas-put drgnx-keys-eld-test--sample)
      (drgnx-keys-edit-bind 'open-file "C-c f")
      (drgnx-keys--save-key :bind '((other "C-c o")))                 ; something else changes the same setting
      (let ((now (drgnx-test-areas-text)))
        (should-error (drgnx-keys-edit-undo) :type 'user-error)
        (should (equal (drgnx-test-areas-text) now))))))

(provide 'keys-eld-test)
;;; keys-eld-test.el ends here
