;;; mod-editing-test.el --- batch tests: the editor/editing and ui/look modules -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx)
(load (expand-file-name "modules/editor/drgnx-editing" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-look" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defmacro drgnx-editing-test--in (text mode &rest body)
  "BODY in a buffer with TEXT in MODE, point at the first | (removed)."
  (declare (indent 2))
  `(with-temp-buffer
     (insert ,text)
     (funcall ,mode)
     (goto-char (point-min))
     (when (search-forward "|" nil t) (delete-char -1))
     ,@body))

(ert-deftest drgnx-editing/change-case ()
  (dolist (c '(("fooBarBaz" camel "fooBarBaz") ("fooBarBaz" snake "foo_bar_baz") ("foo_bar_baz" kebab "foo-bar-baz")
               ("foo-bar-baz" camel "fooBarBaz") ("HTTPServer" snake "http_server")))
    (should (equal (drgnx-editing--convert (car c) (nth 1 c)) (nth 2 c))))
  (drgnx-editing-test--in "(setq my_var |1)" #'emacs-lisp-mode
    (goto-char 8)
    (drgnx-editing-case-camel)
    (should (equal (buffer-string) "(setq myVar 1)"))
    (drgnx-editing-case-cycle)                      ; camel → snake → kebab → camel
    (should (equal (buffer-string) "(setq my_var 1)"))
    (drgnx-editing-case-cycle)
    (should (equal (buffer-string) "(setq my-var 1)"))))

(ert-deftest drgnx-editing/fold-and-unfold ()
  (drgnx-editing-test--in "(defun f ()\n  |(list 1\n        2))\n" #'emacs-lisp-mode
    (goto-char (point-min))
    (drgnx-editing-fold)
    (should (invisible-p (line-end-position)))
    (drgnx-editing-unfold)
    (should-not (invisible-p (line-end-position)))))

(ert-deftest drgnx-editing/expand-and-shrink-selection ()
  (drgnx-editing-test--in "(a (b |cde f) g)" #'emacs-lisp-mode
    (drgnx-editing-expand)
    (should (equal (buffer-substring (region-beginning) (region-end)) "cde"))
    (drgnx-editing-expand)
    (should (equal (buffer-substring (region-beginning) (region-end)) "(b cde f)"))
    (drgnx-editing-expand)
    (should (equal (buffer-substring (region-beginning) (region-end)) "(a (b cde f) g)"))
    (drgnx-editing-shrink)
    (should (equal (buffer-substring (region-beginning) (region-end)) "(b cde f)"))))

(ert-deftest drgnx-look/the-theme-is-remembered ()
  (let* ((cfg (make-temp-file "drgnx-cfg" t)) (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
         (custom-enabled-themes custom-enabled-themes))
    (unwind-protect
        (progn
          (drgnx-look-load-theme 'modus-operandi)
          (should (memq 'modus-operandi custom-enabled-themes))
          (should (eq (drgnx-look--saved-theme) 'modus-operandi))
          (drgnx-look-load-theme 'modus-vivendi)
          (should (equal custom-enabled-themes '(modus-vivendi))))   ; one theme at a time
      (mapc #'disable-theme custom-enabled-themes)
      (delete-directory cfg t))))

(ert-deftest drgnx-look/zen-hides-and-gives-everything-back ()
  (drgnx-test-with-state
    (let ((drgnx-wb--sections nil) (drgnx-look-zen-width 40))   ; batch: 80 columns
      (delete-other-windows)
      (drgnx-wb-define-section 'top :slot 0 :title "TOP" :buffer (lambda () (get-buffer-create "*drgnx-test-top*")))
      (unwind-protect
          (progn
            (drgnx-wb-show-sidebar)
            (drgnx-look-zen)
            (should-not (drgnx-wb-sidebar-showing-p))
            (should (> (or (car (window-margins (selected-window))) 0) 0))
            (drgnx-look-zen)
            (should (drgnx-wb-sidebar-showing-p))
            (should (memq (car (window-margins (selected-window))) '(nil 0))))
        (drgnx-wb-hide-sidebar)
        (kill-buffer "*drgnx-test-top*")))))

(ert-deftest drgnx-look/zen-gives-the-panel-back ()
  ;; The panel shown before zen is shown again after it.
  (require 'drgnx-area)
  (drgnx-test-with-state
    (let ((drgnx-wb--sections nil) (display-buffer-alist nil))
      (delete-other-windows)
      (set-frame-parameter nil 'drgnx-look-zen nil)
      (unwind-protect
          (progn
            (drgnx-wb-area-show 'panel 'output)
            (drgnx-look-zen)
            (should-not (drgnx-wb-area-window 'panel))
            (drgnx-look-zen)
            (should (drgnx-wb-area-window 'panel)))
        (drgnx-wb-area-hide 'panel)))))

(ert-deftest drgnx-look/a-broken-saved-theme-leaves-color-theme ()
  ;; M4-2: the saved theme errors at start: the module still defines Color Theme (to pick another).
  (drgnx-test-with-modules '(ui/look) :strict t
                           (drgnx-modules-update-state (lambda (_) '(:theme modus-operandi)))
                           (drgnx-module-teardown 'ui/look)
                           (cl-letf (((symbol-function 'load-theme) (lambda (&rest _) (error "Theme kaputt"))))
                             (drgnx-modules--run-one 'ui/look (alist-get 'ui/look drgnx-modules--table) 'startup))
                           (should (eq (plist-get (alist-get 'ui/look (drgnx-modules-report)) :status) 'ok))
                           (should (drgnx-commands-get 'preferences-theme))))

(ert-deftest drgnx-look/turning-it-off-brings-back-the-previous-theme ()
  ;; The theme enabled before the module, and the module's own (the saved one at start, then a chosen one).
  (unwind-protect
      (progn
        (load-theme 'modus-operandi t)
        (drgnx-test-with-modules '(ui/look) :strict t
                                 (drgnx-modules-update-state (lambda (_) '(:theme modus-vivendi)))
                                 (drgnx-module-teardown 'ui/look)
                                 (should (equal custom-enabled-themes '(modus-operandi)))
                                 (drgnx-modules--run-one 'ui/look (alist-get 'ui/look drgnx-modules--table) 'startup)
                                 (should (equal custom-enabled-themes '(modus-vivendi)))
                                 (drgnx-look-load-theme 'modus-operandi-tinted)
                                 (should (equal custom-enabled-themes '(modus-operandi-tinted))))
        (should (equal custom-enabled-themes '(modus-operandi))))
    (mapc #'disable-theme custom-enabled-themes)))

(ert-deftest drgnx-look/turning-it-off-leaves-a-theme-someone-else-enabled ()
  (unwind-protect
      (progn
        (drgnx-test-with-modules '(ui/look) :strict nil
                                 (drgnx-look-load-theme 'modus-vivendi)
                                 (load-theme 'modus-operandi t))         ; the user's own, on top
        (should (equal custom-enabled-themes '(modus-operandi))))
    (mapc #'disable-theme custom-enabled-themes)))

(ert-deftest drgnx-look/turning-it-off-gives-zen-mode-back ()
  (drgnx-test-with-modules '(ui/look) :strict t
                           (set-frame-parameter nil 'drgnx-look-zen (list :on t))
                           (let ((undone nil))
                             (cl-letf (((symbol-function 'drgnx-look-zen) (lambda () (setq undone t) (set-frame-parameter nil 'drgnx-look-zen nil))))
                               (drgnx-module-teardown 'ui/look))
                             (should undone)
                             (should-not (frame-parameter nil 'drgnx-look-zen)))))

(ert-deftest drgnx-editing/the-module-sets-up-and-turns-off ()
  (drgnx-test-with-modules '(editor/editing) :strict t
                           (should (drgnx-commands-get 'edit-fold))
                           (should (memq 'drgnx-editing--region-alist emulation-mode-map-alists)))
  (should-not (memq 'drgnx-editing--region-alist emulation-mode-map-alists))
  (should-not (drgnx-commands-get 'edit-fold)))

(ert-deftest drgnx-editing/case-cycle-on-one-word-says-so ()
  ;; M4-12: a one-word symbol has nothing to cycle: said, not silent.
  (drgnx-editing-test--in "(setq fo|o 1)" #'emacs-lisp-mode
    (let ((said nil))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (drgnx-editing-case-cycle))
      (should (equal (buffer-string) "(setq foo 1)"))
      (should (string-search "nothing to cycle" (or said ""))))))
