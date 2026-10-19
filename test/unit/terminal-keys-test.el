;;; terminal-keys-test.el --- batch tests: which keys reach drgnx in a terminal, which the shell -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(require 'seq)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defvar eat-semi-char-non-bound-keys)
(defvar eat-semi-char-mode-map)
(defvar eat--semi-char-mode)
(defvar drgnx-terminal--eat-default-non-bound)
(defvar drgnx-surfaces-cheatsheet-sections)
(defvar drgnx-terminal-skip-shell-keys)
(declare-function eat-mode "eat")
(declare-function eat-yank "eat")

(defconst drgnx-terminal-keys-test--elpa (expand-file-name (or (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa"))
  "The user's ELPA, read-only, for eat (the runner passes it as DRGNX_USER_ELPA).")

(defun drgnx-terminal-keys-test--eat-dir ()
  (and (file-directory-p drgnx-terminal-keys-test--elpa)
       (car (directory-files drgnx-terminal-keys-test--elpa t "\\`eat-[0-9.]+\\'"))))

(defmacro drgnx-terminal-keys-test--live (layers &rest body)
  "BODY with LAYERS (evaluated) applied, the terminal modules run and eat loaded; keys, eat's map and its settings restored after."
  (declare (indent 1))
  `(let ((eat-dir (drgnx-terminal-keys-test--eat-dir)))
     (unless eat-dir
       (ert-skip "eat is not installed: run drgnx sync (a temp elpa for tests: set DRGNX_USER_ELPA to a directory holding eat-0.9.4/)"))
     (let* ((load-path (cons eat-dir load-path))
            (_ (require 'eat))   ; before the let-bindings of its variables
            (dir (make-temp-file "drgnx-tkeys" t))
            (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir) (concat "XDG_STATE_HOME=" dir "/state"))
                                         process-environment))
            (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil) (drgnx-commands-problems nil)
            (drgnx-keys--applied nil) (drgnx-keys--session-layers nil) (drgnx-keys-profiles nil)
            (drgnx-keys-problems nil) (drgnx-keys-last nil)
            (ring-bell-function ring-bell-function) (use-dialog-box use-dialog-box)
            (use-short-answers use-short-answers) (inhibit-startup-screen inhibit-startup-screen)
            (drgnx-surfaces-cheatsheet-sections (bound-and-true-p drgnx-surfaces-cheatsheet-sections))
            (eat-semi-char-non-bound-keys (and (featurep 'eat) eat-semi-char-non-bound-keys))
            (eat-semi-char-mode-map (and (featurep 'eat) eat-semi-char-mode-map))
            (minor-mode-map-alist (mapcar #'copy-sequence minor-mode-map-alist))
            (drgnx-terminal--eat-default-non-bound nil))
       (unwind-protect
           (progn
             (drgnx--core-commands)
             ;; every startup module, set up and torn down after (what they hooked into goes with them)
             (drgnx-test-with-modules nil :stages '(startup)
                                      (drgnx-keys-use ,layers)
                                      ,@body))
         (drgnx-keys--restore)
         (delete-directory dir t)))))

(defmacro drgnx-terminal-keys-test--eat-buffer (&rest body)
  "BODY in a temporary eat buffer in semi-char mode (no shell process)."
  `(with-temp-buffer (eat-mode) (eat--semi-char-mode 1) ,@body))

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
      ;; eat's own reserved keys are drgnx's, not the shell's
      (dolist (k to-drgnx) (should-not (member k to-shell))))))

(ert-deftest drgnx-terminal-keys/the-skip-list-is-the-users ()
  (drgnx-terminal-keys-test--live '((vscode app editing window))
    (let ((drgnx-terminal-skip-shell-keys nil))
      (drgnx-terminal-apply-keys)
      (should (member "C-p" (plist-get (drgnx-terminal-key-split) :to-shell)))
      (should (member "C-k C-r" (plist-get (drgnx-terminal-key-split) :to-shell)))
      (should (eq (cdr (assq 'eat--semi-char-mode minor-mode-map-alist)) eat-semi-char-mode-map))
      (drgnx-terminal-keys-test--eat-buffer
       (should (eq (drgnx-terminal-keys-test--bound-to "C-p") #'eat-self-input))
       (should (eq (drgnx-terminal-keys-test--bound-to "C-k") #'eat-self-input))))
    ;; a chord prefix is one "C-k chords" line when its keys go to the shell
    (let ((drgnx-terminal-skip-shell-keys nil))
      (let ((lines (cdr (drgnx-terminal-cheatsheet-section))))
        (should (seq-find (lambda (l) (string-prefix-p "C-k chords goes to the shell (outside the terminal" l)) lines))
        (should-not (seq-find (lambda (l) (string-prefix-p "C-k C-r" l)) lines))))))

(ert-deftest drgnx-terminal-keys/the-skip-list-leaves-the-emacs-and-vim-profiles-alone ()
  (dolist (layers '(((emacs app editing window)) ((vim app editing window))))
    (drgnx-terminal-keys-test--live layers
      (drgnx-terminal-keys-test--eat-buffer
       (dolist (k '("C-p" "C-b" "C-k" "C-f"))
         (should (eq (drgnx-terminal-keys-test--bound-to k) #'eat-self-input)))))))

(ert-deftest drgnx-terminal-keys/app-keys-work-in-a-terminal-buffer ()
  (drgnx-terminal-keys-test--live '((vscode app editing window))
    (drgnx-terminal-keys-test--eat-buffer
     (should (eq (drgnx-terminal-keys-test--bound-to "C-S-p") #'drgnx-palette))
     (should (eq (drgnx-terminal-keys-test--bound-to "C-a") #'eat-self-input))
     (should (eq (drgnx-terminal-keys-test--bound-to "C-w") #'eat-self-input))
     (should (eq (drgnx-terminal-keys-test--bound-to "C-b") (drgnx-cmd-command (drgnx-commands-get 'toggle-sidebar))))
     (should (eq (drgnx-terminal-keys-test--bound-to "C-S-c")
                 (drgnx-cmd-command (drgnx-commands-get 'terminal-copy))))
     (should (eq (drgnx-terminal-keys-test--bound-to "C-S-v")
                 (drgnx-cmd-command (drgnx-commands-get 'terminal-paste)))))))

(ert-deftest drgnx-terminal-keys/c-p-follows-the-profile ()
  (drgnx-terminal-keys-test--live '((vscode app editing window))
    (drgnx-terminal-keys-test--eat-buffer
     (should (eq (drgnx-terminal-keys-test--bound-to "C-p") (drgnx-cmd-command (drgnx-commands-get 'go-quick-open))))))
  (dolist (layers '(((emacs app editing window)) ((vim app editing window))))
    (drgnx-terminal-keys-test--live layers
      (should-not (member "C-p" (plist-get (drgnx-terminal-key-split) :to-drgnx)))
      (drgnx-terminal-keys-test--eat-buffer
       (should (eq (drgnx-terminal-keys-test--bound-to "C-p") #'eat-self-input))))))

(ert-deftest drgnx-terminal-keys/emacs-profile-keeps-eats-defaults ()
  (drgnx-terminal-keys-test--live '((emacs app editing window))
    (should (equal eat-semi-char-non-bound-keys drgnx-terminal--eat-default-non-bound))
    (should (member [?\C-x] eat-semi-char-non-bound-keys))
    (drgnx-terminal-keys-test--eat-buffer
     (should (eq (drgnx-terminal-keys-test--bound-to "C-a") #'eat-self-input))
     (should (eq (drgnx-terminal-keys-test--bound-to "C-p") #'eat-self-input)))))

(ert-deftest drgnx-terminal-keys/a-profile-switch-recomputes ()
  (drgnx-terminal-keys-test--live '((vscode app editing window))
    (should (member "C-p" (plist-get (drgnx-terminal-key-split) :to-drgnx)))
    (should (member [?\C-p] eat-semi-char-non-bound-keys))
    (should (eq (cdr (assq 'eat--semi-char-mode minor-mode-map-alist)) eat-semi-char-mode-map))
    (drgnx-keys-use '((emacs app editing window)))
    (should-not (member "C-p" (plist-get (drgnx-terminal-key-split) :to-drgnx)))
    (should-not (member [?\C-p] eat-semi-char-non-bound-keys))
    (should (equal eat-semi-char-non-bound-keys drgnx-terminal--eat-default-non-bound))
    (should (eq (cdr (assq 'eat--semi-char-mode minor-mode-map-alist)) eat-semi-char-mode-map))
    (drgnx-keys-use '((vscode app editing window)))
    (should (member [?\C-p] eat-semi-char-non-bound-keys))
    (should (eq (cdr (assq 'eat--semi-char-mode minor-mode-map-alist)) eat-semi-char-mode-map))
    (drgnx-terminal-keys-test--eat-buffer
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
    (let ((kill-ring nil) (pasted 0))
      (drgnx-terminal-keys-test--eat-buffer
       (let ((inhibit-read-only t)) (insert "say hello there"))
       (set-mark 5) (goto-char 10) (activate-mark)
       (call-interactively (key-binding (kbd "C-S-c")))
       (should (equal (car kill-ring) "hello"))
       (should-not (region-active-p))
       ;; no region: nothing happens
       (call-interactively (key-binding (kbd "C-S-c")))
       (should (equal kill-ring '("hello")))
       (cl-letf (((symbol-function 'eat-yank) (lambda (&optional _) (interactive) (cl-incf pasted))))
         (call-interactively (key-binding (kbd "C-S-v"))))
       (should (= pasted 1))))))

(ert-deftest drgnx-terminal-keys/copy-and-paste-only-in-a-terminal ()
  (drgnx-terminal-keys-test--live '((vscode app editing window))
    (with-temp-buffer
      (should-not (drgnx-commands-available-p (drgnx-commands-get 'terminal-copy)))
      (should-not (drgnx-commands-available-p (drgnx-commands-get 'terminal-paste))))
    (drgnx-terminal-keys-test--eat-buffer
     (should (drgnx-commands-available-p (drgnx-commands-get 'terminal-copy)))
     (should (drgnx-commands-available-p (drgnx-commands-get 'terminal-paste))))))

(ert-deftest drgnx-terminal-keys/the-emacs-profile-says-how-eat-copies-and-pastes ()
  ;; semi-char mode sends M-w to the shell: copying is eat's Emacs mode first
  (let ((bind (plist-get (alist-get 'emacs (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))) :bind)))
    (should (equal (assq 'terminal-paste bind) '(terminal-paste :none "C-y (eat's own)")))
    (should (equal (assq 'terminal-copy bind) '(terminal-copy :none "C-c C-e, then M-w (eat's Emacs mode)")))))
