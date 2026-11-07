;;; terminal-keys-test.el --- batch tests: which keys reach drgnx in a terminal, which the shell -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'drgnx)
(require 'seq)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defvar drgnx-surfaces-cheatsheet-sections)
(defvar drgnx-terminal-skip-shell-keys)
(defvar drgnx-term--queue)
(declare-function drgnx-term-mode "drgnx-term")

(defmacro drgnx-terminal-keys-test--live (layers &rest body)
  "BODY with LAYERS (evaluated) applied and the startup modules (the terminal among them) set up; keys restored after."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "drgnx-tkeys" t))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir) (concat "XDG_STATE_HOME=" dir "/state"))
                                       process-environment))
          (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
          (drgnx-keys--applied nil) (drgnx-keys--session-layers nil) (drgnx-keys-profiles nil)
          (drgnx-keys-problems nil) (drgnx-keys-last nil)
          (ring-bell-function ring-bell-function) (use-dialog-box use-dialog-box)
          (use-short-answers use-short-answers) (inhibit-startup-screen inhibit-startup-screen)
          (drgnx-surfaces-cheatsheet-sections (bound-and-true-p drgnx-surfaces-cheatsheet-sections)))
     (unwind-protect
         (progn
           (drgnx--core-commands)
           ;; every startup module, set up and torn down after (what they hooked into goes with them)
           (drgnx-test-with-modules nil :stages '(startup)
                                    (drgnx-keys-use ,layers)
                                    ,@body))
       (drgnx-keys--restore)
       (delete-directory dir t))))

(defmacro drgnx-terminal-keys-test--term-buffer (&rest body)
  "BODY in a temporary terminal buffer (no hub, no worker: what it sends waits in its queue)."
  `(with-temp-buffer (drgnx-term-mode) ,@body))

(defun drgnx-terminal-keys-test--bound-to (key)
  (key-binding (kbd key)))

(ert-deftest drgnx-terminal-keys/vscode-split ()
  (drgnx-terminal-keys-test--live '((vscode app editing window))
    (let* ((split (drgnx-terminal-key-split)) (to-drgnx (plist-get split :to-drgnx)) (to-shell (plist-get split :to-shell)))
      (dolist (k '("C-S-p" "<f1>" "C-`" "C-c c")) (should (member k to-drgnx)))
      ;; VS Code's commandsToSkipShell: C-p (Quick Open), C-b (sidebar), C-k (every chord), C-f (Find) are drgnx's
      (dolist (k '("C-p" "C-b" "C-k C-r" "C-k C-o" "C-f"))
        (should (member k to-drgnx))
        (should-not (member k to-shell)))
      (should to-shell)
      (dolist (k to-shell)
        (let ((ev (aref (key-parse k) 0)))
          (should (integerp ev))
          (should (<= 0 (logand ev (lognot #x8000000)) 127))))
      ;; readline's editing keys that drgnx binds stay with the shell
      (dolist (k '("C-w" "C-s" "C-n")) (should (member k to-shell)))
      ;; the terminal's reserved keys are drgnx's, not the shell's
      (dolist (k to-drgnx) (should-not (member k to-shell))))))

(ert-deftest drgnx-terminal-keys/the-skip-list-is-the-users ()
  (drgnx-terminal-keys-test--live '((vscode app editing window))
    (let ((drgnx-terminal-skip-shell-keys nil))
      (drgnx-term-apply-keys)
      (should (member "C-p" (plist-get (drgnx-terminal-key-split) :to-shell)))
      (should (member "C-k C-r" (plist-get (drgnx-terminal-key-split) :to-shell)))
      (drgnx-terminal-keys-test--term-buffer
       (should (eq (drgnx-terminal-keys-test--bound-to "C-p") #'drgnx-term-send-event))
       (should (eq (drgnx-terminal-keys-test--bound-to "C-k") #'drgnx-term-send-event))))
    ;; a chord prefix is one "C-k chords" line when its keys go to the shell
    (let ((drgnx-terminal-skip-shell-keys nil))
      (let ((lines (cdr (drgnx-terminal-cheatsheet-section))))
        (should (seq-find (lambda (l) (string-prefix-p "C-k chords goes to the shell (outside the terminal" l)) lines))
        (should-not (seq-find (lambda (l) (string-prefix-p "C-k C-r" l)) lines))))
    (drgnx-term-apply-keys)))

(ert-deftest drgnx-terminal-keys/the-skip-list-leaves-the-emacs-and-vim-profiles-alone ()
  (dolist (layers '(((emacs app editing window)) ((vim app editing window))))
    (drgnx-terminal-keys-test--live layers
      (drgnx-terminal-keys-test--term-buffer
       (dolist (k '("C-p" "C-b" "C-k" "C-f"))
         (should (eq (drgnx-terminal-keys-test--bound-to k) #'drgnx-term-send-event)))))))

(ert-deftest drgnx-terminal-keys/app-keys-work-in-a-terminal-buffer ()
  (drgnx-terminal-keys-test--live '((vscode app editing window))
    (drgnx-terminal-keys-test--term-buffer
     (should (eq (drgnx-terminal-keys-test--bound-to "C-S-p") #'drgnx-palette))
     (should (eq (drgnx-terminal-keys-test--bound-to "C-a") #'drgnx-term-send-event))
     (should (eq (drgnx-terminal-keys-test--bound-to "C-w") #'drgnx-term-send-event))
     (should (eq (drgnx-terminal-keys-test--bound-to "C-b") (drgnx-cmd-command (drgnx-commands-get 'toggle-sidebar))))
     (should (eq (drgnx-terminal-keys-test--bound-to "C-f") (drgnx-cmd-command (drgnx-commands-get 'terminal-find))))
     (should (eq (drgnx-terminal-keys-test--bound-to "C-S-c")
                 (drgnx-cmd-command (drgnx-commands-get 'terminal-copy))))
     (should (eq (drgnx-terminal-keys-test--bound-to "C-S-v")
                 (drgnx-cmd-command (drgnx-commands-get 'terminal-paste)))))))

(ert-deftest drgnx-terminal-keys/c-p-follows-the-profile ()
  (drgnx-terminal-keys-test--live '((vscode app editing window))
    (drgnx-terminal-keys-test--term-buffer
     (should (eq (drgnx-terminal-keys-test--bound-to "C-p") (drgnx-cmd-command (drgnx-commands-get 'go-quick-open))))))
  (dolist (layers '(((emacs app editing window)) ((vim app editing window))))
    (drgnx-terminal-keys-test--live layers
      (should-not (member "C-p" (plist-get (drgnx-terminal-key-split) :to-drgnx)))
      (drgnx-terminal-keys-test--term-buffer
       (should (eq (drgnx-terminal-keys-test--bound-to "C-p") #'drgnx-term-send-event))))))

(ert-deftest drgnx-terminal-keys/emacs-profile-sends-control-keys-but-the-reserved ()
  (drgnx-terminal-keys-test--live '((emacs app editing window))
    (drgnx-terminal-keys-test--term-buffer
     (should (eq (drgnx-terminal-keys-test--bound-to "C-a") #'drgnx-term-send-event))
     (should (eq (drgnx-terminal-keys-test--bound-to "C-p") #'drgnx-term-send-event))
     (should (eq (drgnx-terminal-keys-test--bound-to "M-f") #'drgnx-term-send-event))
     (dolist (k '("C-x" "C-g" "C-h" "C-u" "M-x" "C-c"))
       (should-not (eq (drgnx-terminal-keys-test--bound-to k) #'drgnx-term-send-event))))))

(ert-deftest drgnx-terminal-keys/a-profile-switch-recomputes ()
  (drgnx-terminal-keys-test--live '((vscode app editing window))
    (should (member "C-p" (plist-get (drgnx-terminal-key-split) :to-drgnx)))
    (drgnx-terminal-keys-test--term-buffer
     (should (eq (drgnx-terminal-keys-test--bound-to "C-p") (drgnx-cmd-command (drgnx-commands-get 'go-quick-open)))))
    (drgnx-keys-use '((emacs app editing window)))
    (should-not (member "C-p" (plist-get (drgnx-terminal-key-split) :to-drgnx)))
    (drgnx-terminal-keys-test--term-buffer
     (should (eq (drgnx-terminal-keys-test--bound-to "C-p") #'drgnx-term-send-event)))
    (drgnx-keys-use '((vscode app editing window)))
    (drgnx-terminal-keys-test--term-buffer
     (should (eq (drgnx-terminal-keys-test--bound-to "C-p") (drgnx-cmd-command (drgnx-commands-get 'go-quick-open)))))))

(ert-deftest drgnx-terminal-keys/the-sheet-says-where-keys-go ()
  (drgnx-terminal-keys-test--live '((vscode app editing window))
    (unwind-protect
        (progn
          (drgnx-surfaces-cheatsheet)
          (with-current-buffer "*drgnx keys*"
            (let ((text (buffer-string)))
              (should (string-match-p "^In the terminal$" text))
              (should (string-match-p "Reach drgnx: .*C-p" text))
              (should (string-match-p "^  C-w goes to the shell (Close Tab: outside the terminal, or the palette)$" text))
              ;; chords are one entry, not one line each
              (should (string-match-p "Reach drgnx: .*C-k chords" text))
              (should (string-match-p "Reach drgnx: .*C-c chords" text))
              (should-not (string-match-p "C-k C-r" (substring text (string-match "^In the terminal$" text))))
              (should-not (string-match-p "^  C-p goes to the shell" text))
              (should-not (string-match-p "^  C-c c goes to the shell" text))
              ;; once, also when the sheet is shown again
              (should (= 1 (with-temp-buffer (insert text) (how-many "^In the terminal$" (point-min)))))))
          (drgnx-keys-use '((emacs app editing window)))
          (drgnx-surfaces-cheatsheet)
          (with-current-buffer "*drgnx keys*"
            (should (string-match-p "^In the terminal$" (buffer-string)))
            (should-not (string-match-p "Reach drgnx: .*C-p" (buffer-string)))))
      (when (get-buffer "*drgnx keys*") (kill-buffer "*drgnx keys*")))))

(ert-deftest drgnx-terminal-keys/copy-and-paste ()
  (drgnx-terminal-keys-test--live '((vscode app editing window))
    (let ((kill-ring nil))
      (drgnx-terminal-keys-test--term-buffer
       (let ((inhibit-read-only t)) (insert "say hello there"))
       (set-mark 5) (goto-char 10) (activate-mark)
       (call-interactively (key-binding (kbd "C-S-c")))
       (should (equal (car kill-ring) "hello"))
       (should-not (region-active-p))
       ;; no region: nothing happens
       (call-interactively (key-binding (kbd "C-S-c")))
       (should (equal kill-ring '("hello")))
       ;; the hub is away: the paste waits in the terminal's queue
       (call-interactively (key-binding (kbd "C-S-v")))
       (should (equal (car drgnx-term--queue) '("term/paste" :text "hello")))))))

(ert-deftest drgnx-terminal-keys/copy-and-paste-only-in-a-terminal ()
  (drgnx-terminal-keys-test--live '((vscode app editing window))
    (with-temp-buffer
      (should-not (drgnx-commands-available-p (drgnx-commands-get 'terminal-copy)))
      (should-not (drgnx-commands-available-p (drgnx-commands-get 'terminal-paste))))
    (drgnx-terminal-keys-test--term-buffer
     (should (drgnx-commands-available-p (drgnx-commands-get 'terminal-copy)))
     (should (drgnx-commands-available-p (drgnx-commands-get 'terminal-paste))))))

(ert-deftest drgnx-terminal-keys/the-emacs-profile-says-how-the-terminal-copies-and-pastes ()
  ;; C-y pastes the kill ring; copying is copy mode's M-w
  (let ((bind (plist-get (alist-get 'emacs (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))) :bind)))
    (should (equal (assq 'terminal-paste bind) '(terminal-paste "C-y" :map (drgnx-term . drgnx-term-mode-map))))
    (should (equal (assq 'terminal-copy bind) '(terminal-copy :none "Copy Mode (C-c C-e), then M-w")))))
