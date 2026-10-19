;;; mod-start-test.el --- batch tests: the start page in an empty editor (M12f A9) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'server)
(require 'drgnx)
(require 'drgnx-chrome)
(load (expand-file-name "modules/ui/drgnx-face" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-start" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(defvar drgnx-signal--timer)
(defvar drgnx-signal--subscribers)
(defvar drgnx-persist-after-restore-functions)
(defvar drgnx-first-gui-frame-hook)
(defvar drgnx-start--after-file)

(defvar drgnx-start-test--ran nil "The stub commands that ran (newest first).")
(dolist (id '(files palette keys folder graph))
  (defalias (intern (format "drgnx-start-test-%s" id))
    (let ((id id)) (lambda () (interactive) (push id drgnx-start-test--ran)))))

(defun drgnx-start-test--bind (profile)
  "Give the three key commands the keys the real PROFILE file (`keys/PROFILE.eld') gives them."
  (let ((entries (plist-get (alist-get profile (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))) :bind)))
    (dolist (id '(go-quick-open palette keys-sheet))
      (let ((keys (cdr (assq id entries))))
        (setf (drgnx-cmd-bound (drgnx-commands-get id))
              (unless (eq (car keys) :none) (mapcar (lambda (k) (cons k nil)) keys)))))))

(defun drgnx-start-test--fresh-scratch ()
  "`*scratch*' as Emacs starts it: empty, not modified (the tests share it)."
  (with-current-buffer (get-scratch-buffer-create) (erase-buffer) (set-buffer-modified-p nil)))

(defmacro drgnx-start-test--with (profile &rest body)
  "BODY with a registry of its own holding the commands the page names (keys as PROFILE binds the three), a state
directory in a temp dir, the persist/server/signal hooks kept away from the rest of the process, and the selected
window showing `*scratch*'.  `y-or-n-p' and every `read-*' fail: nothing here may ask."
  (declare (indent 1))
  `(drgnx-test-with-state
     (let* ((tmp (make-temp-file "drgnx-start-" t))
            (process-environment (cons (concat "XDG_STATE_HOME=" tmp) process-environment))
            (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
            (drgnx-start-test--ran nil)
            (drgnx-persist-after-restore-functions nil) (drgnx-first-gui-frame-hook nil)
            (server-after-make-frame-hook nil) (window-setup-hook nil)
            (drgnx-start--after-file nil)
            (drgnx-signal--timer (timer-create))             ; a timer already armed: nothing is scheduled
            (drgnx-modules--runs (list (list 'ui/face 'ui/face)))   ; ui/face is on: its timers start
            (old (window-buffer (selected-window))))
       (cl-letf (((symbol-function 'drgnx-face--ascii-frame-p) (lambda (_frame) nil))   ; the batch terminal is not UTF-8
                 ((symbol-function 'drgnx-onboard--welcome-due-p) (lambda () nil))      ; no first-run Welcome in the way
                 ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "asked y-or-n-p")))
                 ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "asked yes-or-no-p")))
                 ((symbol-function 'read-string) (lambda (&rest _) (error "asked read-string")))
                 ((symbol-function 'read-from-minibuffer) (lambda (&rest _) (error "asked read-from-minibuffer")))
                 ((symbol-function 'completing-read) (lambda (&rest _) (error "asked completing-read")))
                 ((symbol-function 'read-directory-name) (lambda (&rest _) (error "asked read-directory-name")))
                 ((symbol-function 'read-file-name) (lambda (&rest _) (error "asked read-file-name")))
                 ((symbol-function 'read-key) (lambda (&rest _) (error "asked read-key")))
                 ((symbol-function 'read-char) (lambda (&rest _) (error "asked read-char"))))
         (drgnx-command-define 'go-quick-open :title "Quick Open" :category "Go" :command #'drgnx-start-test-files)
         (drgnx-command-define 'palette :title "Command Palette" :category "View" :command #'drgnx-start-test-palette)
         (drgnx-command-define 'keys-sheet :title "Keys" :category "Help" :command #'drgnx-start-test-keys)
         (drgnx-command-define 'open-folder :title "Open Folder…" :category "File" :command #'drgnx-start-test-folder)
         (drgnx-command-define 'work-graph :title "Show Work as Graph" :category "Work" :command #'drgnx-start-test-graph)
         (drgnx-start-test--bind ,profile)
         (drgnx-start-test--fresh-scratch)
         (set-window-buffer (selected-window) (get-scratch-buffer-create))
         (unwind-protect (progn ,@body)
           (drgnx-start-test--fresh-scratch)
           (when-let* ((b (get-buffer "*drgnx start*"))) (kill-buffer b))
           (set-window-buffer (selected-window) old)
           (delete-directory tmp t))))))

(defun drgnx-start-test--text ()
  "The start page as plain text."
  (with-current-buffer "*drgnx start*" (buffer-substring-no-properties (point-min) (point-max))))

(defun drgnx-start-test--press (label)
  "Press the button labelled LABEL in the start page."
  (with-current-buffer "*drgnx start*"
    (goto-char (point-min))
    (let ((b (cl-loop for pos = (next-button (point)) then (next-button (button-end pos))
                      while pos when (string= (button-label pos) label) return pos)))
      (should b)
      (push-button (button-start b)))))

(ert-deftest drgnx-start/shown-in-an-empty-editor ()
  (drgnx-start-test--with 'vscode
    (let ((windows (window-list)) (selected (selected-window)))
      (drgnx-start-maybe-show)
      (should (equal (buffer-name (window-buffer selected)) "*drgnx start*"))
      (should (eq (buffer-local-value 'major-mode (get-buffer "*drgnx start*")) 'drgnx-start-mode))
      (should (provided-mode-derived-p 'drgnx-start-mode 'special-mode))
      (with-current-buffer "*drgnx start*"                    ; TAB walks the buttons, q is special-mode's
        (should (eq (key-binding (kbd "TAB")) 'forward-button))
        (should (eq (key-binding (kbd "q")) 'quit-window)))
      (should (equal windows (window-list)))               ; never split
      (should (eq selected (selected-window)))
      ;; what drgnx is, in two lines, and the buttons
      (let ((text (drgnx-start-test--text)))
        (should (string-match-p "drgnx" text))
        (should (string-match-p "Open a Folder…" text))
        (should (string-match-p "Open the Work Graph" text))
        (should (string-match-p "All Keys" text))
        (should (string-match-p "Don't show this again" text)))
      ;; each button runs its command
      (drgnx-start-test--press "Open a Folder…")
      (drgnx-start-test--press "Open the Work Graph")
      (drgnx-start-test--press "All Keys")
      (should (equal (reverse drgnx-start-test--ran) '(folder graph keys))))))

(ert-deftest drgnx-start/not-over-a-file ()
  (drgnx-start-test--with 'vscode
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name "x.el" temporary-file-directory))
      (set-window-buffer (selected-window) (current-buffer))
      (drgnx-start-maybe-show)
      (should (eq (window-buffer (selected-window)) (current-buffer)))
      (should-not (get-buffer "*drgnx start*"))
      (set-window-buffer (selected-window) (get-scratch-buffer-create)))))

(ert-deftest drgnx-start/only-the-most-recent-editor-window-and-never-selects-another ()
  (drgnx-start-test--with 'vscode
    (let* ((w1 (selected-window)) (w2 (split-window w1)))
      (unwind-protect
          (progn (set-window-buffer w2 (get-scratch-buffer-create))
                 (drgnx-test-use-editor w2)                  ; w1 is selected, w2 is the editor used last
                 (drgnx-start-maybe-show)
                 (should (equal (buffer-name (window-buffer w2)) "*drgnx start*"))
                 (should (eq (selected-window) w1))
                 (should (= 2 (length (window-list)))))
        (delete-window w2)))))

(defun drgnx-start-test--remote-handler (op &rest args)
  "A file name handler for names on a host that does not exist: only what Tramp answers without a connection (an
absolute local name expanded against a remote folder) passes; everything else, \"~\" included, is an error."
  (if (and (eq op 'expand-file-name) (stringp (car args)) (not (string-prefix-p "~" (car args))))
      (let ((inhibit-file-name-handlers (cons 'drgnx-start-test--remote-handler inhibit-file-name-handlers))
            (inhibit-file-name-operation op))
        (apply op args))
    (error "touched a remote file: %s %S" op args)))

(ert-deftest drgnx-start/a-remote-scratch-is-only-read ()
  (drgnx-start-test--with 'vscode
    (with-current-buffer (get-scratch-buffer-create)
      ;; the state directory comes from ~ here (no XDG_STATE_HOME), as it does for most users
      (let ((default-directory "/ssh:nowhere.invalid:/tmp/")
            (process-environment (cons (concat "HOME=" tmp)
                                       (seq-remove (lambda (s) (string-prefix-p "XDG_STATE_HOME=" s)) process-environment)))
            (file-name-handler-alist (cons (cons "\\`/ssh:" #'drgnx-start-test--remote-handler) file-name-handler-alist)))
        (drgnx-start-maybe-show)
        (should (equal (buffer-name (window-buffer (selected-window))) "*drgnx start*"))
        (should-not (file-remote-p (buffer-local-value 'default-directory (get-buffer "*drgnx start*"))))
        (should (string-prefix-p tmp (drgnx-face-state-file)))))))

(ert-deftest drgnx-start/dismissed-stays-dismissed ()
  (drgnx-start-test--with 'vscode
    (drgnx-start-maybe-show)
    (drgnx-start-test--press "Don't show this again")
    (should-not (get-buffer "*drgnx start*"))                 ; gone from the window
    (should-not (equal (buffer-name (window-buffer (selected-window))) "*drgnx start*"))
    ;; written to the state dir, which is the temp one
    (should (plist-get (drgnx-face-state-read) :start-dismissed))
    (should (string-prefix-p tmp (drgnx-face-state-file)))
    (should (file-exists-p (expand-file-name "face.eld" (drgnx-state-dir))))
    ;; a new frame, a restart: an empty editor again, and the page stays away
    (set-window-buffer (selected-window) (get-scratch-buffer-create))
    (drgnx-start-maybe-show)
    (should-not (get-buffer "*drgnx start*"))
    (should (equal (buffer-name (window-buffer (selected-window))) "*scratch*"))
    ;; the command still shows it on request
    (drgnx-start-show)
    (should (equal (buffer-name (window-buffer (selected-window))) "*drgnx start*"))))

(ert-deftest drgnx-start/dismissing-keeps-what-else-the-state-file-holds ()
  (drgnx-start-test--with 'vscode
    (drgnx-face-state-write '(:variant dark :gtk-theme "Adwaita"))
    (drgnx-start-maybe-show)
    (drgnx-start-test--press "Don't show this again")
    (let ((state (drgnx-face-state-read)))
      (should (eq (plist-get state :variant) 'dark))
      (should (equal (plist-get state :gtk-theme) "Adwaita"))
      (should (plist-get state :start-dismissed)))))

(ert-deftest drgnx-start/keys-follow-the-profile ()
  (drgnx-start-test--with 'vscode
    (drgnx-start-maybe-show)
    (let ((text (drgnx-start-test--text)))
      (should (string-match-p "C-p" text))
      (should (string-match-p "C-S-p" text))
      (should (string-match-p "C-k C-r" text)))
    (drgnx-start-test--bind 'emacs)                           ; the profile changed: the page follows when shown again
    (set-window-buffer (selected-window) (get-scratch-buffer-create))
    (drgnx-start-maybe-show)
    (let ((text (drgnx-start-test--text)))
      (should (string-match-p "C-S-p" text))
      (should (string-match-p "C-h C-k" text))
      (should-not (string-match-p "C-k C-r" text)))))

(ert-deftest drgnx-start/never-asks-anything ()
  (drgnx-start-test--with 'vscode
    (let ((noninteractive nil))
      ;; every way in runs with `y-or-n-p' and the `read-*' functions failing
      (drgnx-start-maybe-show)
      (should (equal (buffer-name (window-buffer (selected-window))) "*drgnx start*"))
      (set-window-buffer (selected-window) (get-scratch-buffer-create))
      (with-temp-buffer (setq buffer-file-name (expand-file-name "x.el" temporary-file-directory))
                        (drgnx-start--on-editor-changed (current-buffer)))   ; the last file was shown, then closed
      (drgnx-start--on-editor-changed (get-scratch-buffer-create))
      (should (equal (buffer-name (window-buffer (selected-window))) "*drgnx start*"))
      (set-window-buffer (selected-window) (get-scratch-buffer-create))
      (drgnx-start--first-frame-run)
      (should (equal (buffer-name (window-buffer (selected-window))) "*drgnx start*"))
      (set-window-buffer (selected-window) (get-scratch-buffer-create))
      ;; as the hooks the module adds run them
      (drgnx-start-setup)
      (run-hook-with-args 'drgnx-persist-after-restore-functions (selected-frame))
      (should (equal (buffer-name (window-buffer (selected-window))) "*drgnx start*"))
      (set-window-buffer (selected-window) (get-scratch-buffer-create))
      (run-hooks 'server-after-make-frame-hook)
      (should (equal (buffer-name (window-buffer (selected-window))) "*drgnx start*"))
      ;; an unreadable state file is no reason to ask or to fail: the page shows
      (set-window-buffer (selected-window) (get-scratch-buffer-create))
      (make-directory (drgnx-state-dir) t)
      (with-temp-file (drgnx-face-state-file) (insert "(:start-dismissed"))
      (drgnx-start-maybe-show)
      (should (equal (buffer-name (window-buffer (selected-window))) "*drgnx start*")))))

(ert-deftest drgnx-start/the-last-file-closing-brings-it-back ()
  (drgnx-start-test--with 'vscode
    (let ((noninteractive nil))
      (drgnx-start-setup)
      (should (memq #'drgnx-start--on-editor-changed (alist-get 'editor-changed drgnx-signal--subscribers)))
      (with-temp-buffer                                       ; a file is shown: the editor changed to it
        (setq buffer-file-name (expand-file-name "x.el" temporary-file-directory))
        (set-window-buffer (selected-window) (current-buffer))
        (drgnx-start--on-editor-changed (current-buffer))
        (should (eq (window-buffer (selected-window)) (current-buffer)))
        (set-window-buffer (selected-window) (get-scratch-buffer-create)))   ; it closed: *scratch* is what is left
      (drgnx-start--on-editor-changed (get-scratch-buffer-create))
      (should (equal (buffer-name (window-buffer (selected-window))) "*drgnx start*")))))

(defun drgnx-start-test--shown-p ()
  "Non-nil when the selected window shows the start page."
  (equal (buffer-name (window-buffer (selected-window))) "*drgnx start*"))

(ert-deftest drgnx-start/a-typed-scratch-keeps-the-page-away ()
  (drgnx-start-test--with 'vscode
    (let ((noninteractive nil) (scratch (get-scratch-buffer-create)))
      (with-current-buffer scratch (insert "(+ 1 2)"))        ; the user's own text
      ;; the startup path
      (drgnx-start--first-frame-run)
      (drgnx-start-maybe-show)
      (should (eq (window-buffer (selected-window)) scratch))
      ;; the last-file-closed path
      (with-temp-buffer (setq buffer-file-name (expand-file-name "x.el" temporary-file-directory))
                        (drgnx-start--on-editor-changed (current-buffer)))
      (drgnx-start--on-editor-changed scratch)
      (should (eq (window-buffer (selected-window)) scratch))
      ;; erased, it is empty again; and drgnx's initial text, even modified, still counts as untouched
      (with-current-buffer scratch (erase-buffer) (set-buffer-modified-p nil))
      (drgnx-start-maybe-show)
      (should (drgnx-start-test--shown-p))
      (set-window-buffer (selected-window) scratch)
      (let ((initial-scratch-message ";; hello \\[save-buffer]"))
        (with-current-buffer scratch
          (erase-buffer) (insert (substitute-command-keys initial-scratch-message)) (set-buffer-modified-p t))
        (drgnx-start-maybe-show)
        (should (drgnx-start-test--shown-p))))))

(ert-deftest drgnx-start/another-file-tab-still-open-does-nothing ()
  (drgnx-start-test--with 'vscode
    (let ((noninteractive nil) (w (selected-window)))
      (with-temp-buffer
        (setq buffer-file-name (expand-file-name "x.el" temporary-file-directory))
        (let ((file (current-buffer)))
          (set-window-parameter w 'drgnx-tabs (list file))
          (drgnx-start--on-editor-changed file)               ; a file was shown
          (set-window-buffer w (get-scratch-buffer-create))   ; a tab closed, another file tab is left
          (drgnx-start--on-editor-changed (get-scratch-buffer-create))
          (should-not (drgnx-start-test--shown-p))
          (set-window-parameter w 'drgnx-tabs nil))))))

(ert-deftest drgnx-start/going-to-scratch-by-hand-does-nothing ()
  (drgnx-start-test--with 'vscode
    (let ((noninteractive nil))
      (drgnx-start--on-editor-changed (get-buffer-create "*Messages*"))   ; from a buffer that is no file
      (drgnx-start--on-editor-changed (get-scratch-buffer-create))
      (should-not (drgnx-start-test--shown-p))
      (should-not (get-buffer "*drgnx start*")))))

(ert-deftest drgnx-start/the-page-shows-when-the-first-run-welcome-closes ()
  "On a first run the Welcome takes the editor; the person the page is for sees it when they close the Welcome."
  (drgnx-start-test--with 'vscode
    (let ((noninteractive nil) (welcome (get-buffer-create "*drgnx Welcome*")))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) welcome)
            (drgnx-start--on-editor-changed welcome)          ; the Welcome is the editor
            (kill-buffer welcome)                             ; closed: the window shows *scratch* again
            (set-window-buffer (selected-window) (get-scratch-buffer-create))
            (drgnx-start--on-editor-changed (get-scratch-buffer-create))
            (should (drgnx-start-test--shown-p)))
        (when (buffer-live-p welcome) (kill-buffer welcome))))))

(ert-deftest drgnx-start/the-welcome-comes-first ()
  (drgnx-start-test--with 'vscode
    (cl-letf (((symbol-function 'drgnx-onboard--welcome-due-p) (lambda () t)))
      (drgnx-start-maybe-show)
      (should-not (drgnx-start-test--shown-p))
      (should-not (get-buffer "*drgnx start*")))
    (cl-letf (((symbol-function 'drgnx-onboard--welcome-due-p) (lambda () nil)))   ; it ran: the page may show
      (drgnx-start-maybe-show)
      (should (drgnx-start-test--shown-p)))))

(ert-deftest drgnx-start/a-dedicated-window-and-a-child-frame-are-skipped ()
  (drgnx-start-test--with 'vscode
    (let ((w (selected-window)))
      (set-window-dedicated-p w t)
      (unwind-protect (progn (drgnx-start-maybe-show) (should-not (drgnx-start-test--shown-p)))
        (set-window-dedicated-p w nil)))
    (cl-letf (((symbol-function 'frame-parent) (lambda (&optional _frame) (selected-frame))))
      (drgnx-start-maybe-show)
      (should-not (drgnx-start-test--shown-p)))
    (drgnx-start-maybe-show)                                  ; neither: it shows
    (should (drgnx-start-test--shown-p))))

(ert-deftest drgnx-start/setup-is-idempotent-and-teardown-removes-it ()
  (drgnx-start-test--with 'vscode
    (drgnx-start-setup)
    (drgnx-start-setup)
    (should (= 1 (cl-count #'drgnx-start-maybe-show drgnx-persist-after-restore-functions)))
    (should (= 1 (cl-count #'drgnx-start-maybe-show server-after-make-frame-hook)))
    (should (= 1 (cl-count #'drgnx-start--on-first-frame drgnx-first-gui-frame-hook)))
    (should (= 1 (cl-count #'drgnx-start--on-first-frame window-setup-hook)))
    (should (= 1 (cl-count #'drgnx-start--on-editor-changed (alist-get 'editor-changed drgnx-signal--subscribers))))
    (should (drgnx-commands-get 'start-page))
    (drgnx-start--on-first-frame)                             ; batch: no timer
    (should-not (drgnx-timer-active-p 'start-first-frame))
    (let ((noninteractive nil))                               ; an owned, single timer
      (drgnx-start--on-first-frame)
      (drgnx-start--on-first-frame)
      (should (equal (seq-filter (lambda (e) (eq (car e) 'start-first-frame)) (drgnx-timer-pending))
                     '((start-first-frame ui/face start))))
      (should (= 1 (cl-count #'drgnx-timer--fire timer-idle-list :key #'timer--function))))
    (should (= 1 (drgnx-timer-cancel-owner 'ui/face)))        ; the module's run ends: the timer goes
    (drgnx-start-teardown)
    (should-not (memq #'drgnx-start-maybe-show drgnx-persist-after-restore-functions))
    (should-not (memq #'drgnx-start-maybe-show server-after-make-frame-hook))
    (should-not (memq #'drgnx-start--on-first-frame drgnx-first-gui-frame-hook))
    (should-not (memq #'drgnx-start--on-first-frame window-setup-hook))
    (should-not (memq #'drgnx-start--on-editor-changed (alist-get 'editor-changed drgnx-signal--subscribers)))))

(ert-deftest drgnx-start/a-transient-tab ()
  ;; the default of the setting names the page
  (let ((default (eval (car (get 'drgnx-chrome-transient-tabs 'standard-value)) t)))
    (should (string-match-p default "*drgnx start*"))
    (should (string-match-p default "*scratch*"))
    (should-not (string-match-p default "init.el")))
  ;; and the tab goes when the window shows something else
  (drgnx-start-test--with 'vscode
    (let ((drgnx-chrome-transient-tabs (eval (car (get 'drgnx-chrome-transient-tabs 'standard-value)) t))
          (w (selected-window)))
      (drgnx-start-maybe-show)
      (drgnx-chrome--note w)
      (should (memq (get-buffer "*drgnx start*") (drgnx-chrome-tabs w)))   ; a tab while shown
      (with-temp-buffer
        (set-window-buffer w (current-buffer))
        (drgnx-chrome--note w)
        (should-not (memq (get-buffer "*drgnx start*") (drgnx-chrome-tabs w)))
        (set-window-parameter w 'drgnx-tabs nil)))))

(provide 'mod-start-test)
;;; mod-start-test.el ends here
