;;; mod-clipboard-test.el --- batch tests: the editor/clipboard module (clipboard managers; M12b Task 14b) -*- lexical-binding: t -*-
;; Everything runs in a temp HOME with fake config files; the process list is stubbed, and `gsettings' is a script
;; in a temp directory that is the only directory on `exec-path' (the real one is never run).  The cut function is
;; a recorder, never the system clipboard.
(require 'ert)
(require 'drgnx)
(load (expand-file-name "modules/editor/drgnx-editing" drgnx-dir) nil t)
(load (expand-file-name "modules/editor/drgnx-clipboard" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)

(defvar x-selection-timeout)
(defvar pgtk-selection-timeout)
(defvar drgnx-clip-test--pushed nil "What the recorder cut function was given, newest first.")
(defvar drgnx-clip-test--bin nil "The temp directory that is the whole `exec-path'.")
(defvar drgnx-clip-test--home nil)

(defmacro drgnx-clip-test--env (paste-function &rest body)
  "BODY in an isolated session: temp HOME, a recorder as the cut function, PASTE-FUNCTION as the paste function,
no module state, both timeouts at the standard 0, and nothing on `exec-path' (so no gsettings).  The module is
uninstalled afterwards."
  (declare (indent 1))
  `(let* ((drgnx-clip-test--home (make-temp-file "drgnx-clip" t))
          (drgnx-clip-test--bin (expand-file-name "bin" drgnx-clip-test--home))
          (process-environment (append (list (concat "HOME=" drgnx-clip-test--home) "XDG_CONFIG_HOME")
                                       process-environment))
          (exec-path (list drgnx-clip-test--bin))
          (drgnx-clip-test--pushed nil)
          (interprogram-cut-function (lambda (text) (push text drgnx-clip-test--pushed)))
          (interprogram-paste-function ,paste-function)
          (kill-ring nil) (kill-ring-yank-pointer nil) (kill-do-not-save-duplicates nil)
          (command-error-function command-error-function)
          (pre-command-hook nil) (post-command-hook nil) (after-make-frame-functions nil)
          (select-active-regions t) (x-selection-timeout 0) (pgtk-selection-timeout 0)
          (drgnx-clipboard-kills 'region) (drgnx-clipboard-force nil)
          (drgnx-clipboard-publish-selection 'auto) (drgnx-clipboard-read-timeout 1.5)
          (drgnx-clipboard--installed nil) (drgnx-clipboard--decision nil) (drgnx-clipboard--in-command nil)
          (drgnx-clipboard--warned nil) (drgnx-clipboard--timeout-set nil)
          (drgnx-clipboard--state nil) (drgnx-clipboard--saved-regions nil)
          (drgnx-clipboard--generation 0))
     (make-directory drgnx-clip-test--bin t)
     (unwind-protect (progn ,@body)
       (drgnx-clipboard-uninstall)
       (delete-directory drgnx-clip-test--home t))))

(defun drgnx-clip-test--as (command thunk)
  "Run THUNK as one run of COMMAND (as the command loop does: `this-command' and a fresh command)."
  (let ((this-command command) (real-this-command command))
    (drgnx-clipboard--new-command)
    (unwind-protect (funcall thunk)
      (drgnx-clipboard--end-command))))

(defun drgnx-clip-test--file (relative text)
  "Write TEXT to RELATIVE under the temp HOME."
  (let ((file (expand-file-name relative drgnx-clip-test--home)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))
    file))

(defmacro drgnx-clip-test--x11 (processes &rest body)
  "BODY on an X11 frame with PROCESSES (a list of names) running."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'drgnx-clipboard--graphical-p) (lambda (&optional _f) t))
             ((symbol-function 'drgnx-clipboard--process-names) (lambda () ,processes)))
     ,@body))

(defun drgnx-clip-test--select (beg end)
  "Select BEG to END, point at END, as a Shift-arrow selection leaves it."
  (setq-local transient-mark-mode t)
  (set-mark beg)
  (goto-char end)
  (activate-mark))

;;;; Kills

(ert-deftest drgnx-clip/an-unknown-command-that-kills-reaches-the-clipboard ()
  ;; a third-party copy command (magit, embark, ...) is not on any list: it behaves as in plain Emacs
  (drgnx-clip-test--env nil
    (drgnx-clipboard-install)
    (drgnx-clip-test--as 'magit-copy-section-value (lambda () (kill-new "abc123")))
    (should (equal drgnx-clip-test--pushed '("abc123")))))

(ert-deftest drgnx-clip/a-kill-outside-a-command-reaches-the-clipboard ()
  ;; a timer, a process filter, emacsclient -e: no command is running, whatever `this-command' still says
  (drgnx-clip-test--env nil
    (drgnx-clipboard-install)
    (kill-new "from lisp")
    (let ((this-command 'kill-line) (real-this-command 'kill-line))
      (kill-new "from a timer"))
    (let ((this-command nil) (real-this-command nil))
      (kill-new "from nowhere"))
    (should (equal drgnx-clip-test--pushed '("from nowhere" "from a timer" "from lisp")))))

(ert-deftest drgnx-clip/a-kill-run-from-the-palette-is-judged-by-its-target ()
  ;; this-command is the target, the real one is the palette's
  (drgnx-clip-test--env nil
    (drgnx-clipboard-install)
    (let ((this-command 'kill-line) (real-this-command 'drgnx-palette))
      (drgnx-clipboard--new-command)
      (kill-new "x"))
    (should-not drgnx-clip-test--pushed)))

(ert-deftest drgnx-clip/drgnx-kill-commands-stay-local-through-the-command-loop ()
  ;; drgnx's own commands that kill (Delete Word Left, Delete to Line Start, Delete Line) run as themselves, not as
  ;; kill-word: each is pressed as a key and nothing may reach the clipboard; a control (kill-region) does
  (drgnx-clip-test--env nil
    (drgnx-clipboard-install)
    (save-window-excursion
      (let ((buf (generate-new-buffer " *clip-drgnx-keys*")) (map (make-sparse-keymap)))
        (keymap-set map "<f5>" #'drgnx-editing-delete-word-back)
        (keymap-set map "<f6>" #'drgnx-editing-delete-line-back)
        (keymap-set map "<f7>" #'kill-whole-line)
        (keymap-set map "<f8>" #'kill-region)
        (unwind-protect
            (progn
              (switch-to-buffer buf)
              (use-local-map map)
              (setq-local transient-mark-mode t)
              (insert "alpha beta gamma\ndelta")
              (goto-char 12)
              (execute-kbd-macro (kbd "<f5>"))
              (should (equal (car kill-ring) "beta "))
              (execute-kbd-macro (kbd "<f6>"))
              (should (equal (car kill-ring) "alpha "))
              (execute-kbd-macro (kbd "<f7>"))
              (should-not drgnx-clip-test--pushed)
              (set-mark (point-min))
              (goto-char (point-max))
              (execute-kbd-macro (kbd "<f8>"))
              (should (= (length drgnx-clip-test--pushed) 1)))
          (kill-buffer buf))))))

(ert-deftest drgnx-clip/every-drgnx-kill-command-is-in-the-denylist ()
  ;; found by grepping core, wb and modules for kill-* called on text deleted as editing
  (dolist (command '(drgnx-editing-delete-word-back drgnx-editing-delete-line-back))
    (should (memq command drgnx-clipboard-local-kills))))

(ert-deftest drgnx-clip/other-kills-stay-in-the-kill-ring ()
  (dolist (command '(kill-line kill-word backward-kill-word kill-whole-line))
    (drgnx-clip-test--env nil
      (drgnx-clipboard-install)
      (with-temp-buffer
        (insert "alpha beta\ngamma")
        (goto-char 6)
        (drgnx-clip-test--as command (lambda () (call-interactively command)))
        (should kill-ring)
        (should-not drgnx-clip-test--pushed)))))

(ert-deftest drgnx-clip/copy-and-cut-push-once ()
  (dolist (spec `((kill-region . ,(lambda () (kill-region (region-beginning) (region-end))))
                  (kill-ring-save . ,(lambda () (kill-ring-save (region-beginning) (region-end))))
                  (drgnx-editing-copy . ,#'drgnx-editing-copy)
                  (drgnx-editing-cut . ,#'drgnx-editing-cut)))
    (drgnx-clip-test--env nil
      (drgnx-clipboard-install)
      (with-temp-buffer
        (insert "alpha beta")
        (drgnx-clip-test--select 1 6)
        (drgnx-clip-test--as (car spec) (cdr spec))
        (should (equal drgnx-clip-test--pushed '("alpha")))))))

(ert-deftest drgnx-clip/one-push-per-command ()
  ;; several kills inside one command (appends) reach the clipboard once; the next command pushes again
  (drgnx-clip-test--env nil
    (drgnx-clipboard-install)
    (drgnx-clip-test--as 'kill-region (lambda () (kill-new "one") (kill-append " two" nil)))
    (should (= (length drgnx-clip-test--pushed) 1))
    (drgnx-clip-test--as 'kill-region (lambda () (kill-new "three")))
    (should (= (length drgnx-clip-test--pushed) 2))))

(ert-deftest drgnx-clip/kills-all-is-emacs-behaviour ()
  (drgnx-clip-test--env nil
    (drgnx-clipboard-install)
    (setq drgnx-clipboard-kills 'all)
    (with-temp-buffer
      (insert "alpha beta")
      (goto-char 1)
      (drgnx-clip-test--as 'kill-word (lambda () (kill-word 1) (kill-new "again")))
      (should (equal drgnx-clip-test--pushed '("again" "alpha"))))))

(ert-deftest drgnx-clip/force-pushes ()
  (drgnx-clip-test--env nil
    (drgnx-clipboard-install)
    (drgnx-clip-test--as 'kill-line (lambda () (kill-new "a path")))
    (should-not drgnx-clip-test--pushed)
    (drgnx-clip-test--as 'kill-line (lambda () (let ((drgnx-clipboard-force t)) (kill-new "a path"))))
    (should (equal drgnx-clip-test--pushed '("a path")))))

(ert-deftest drgnx-clip/the-command-loop-decides ()
  ;; real keys: C-k stays in the kill ring, C-w reaches the clipboard once
  (drgnx-clip-test--env nil
    (drgnx-clipboard-install)
    (save-window-excursion
      (let ((buf (generate-new-buffer " *clip-keys*")))
        (unwind-protect
            (progn
              (switch-to-buffer buf)
              (insert "alpha beta\ngamma")
              (setq-local transient-mark-mode t)
              (goto-char 1)
              (execute-kbd-macro (kbd "C-k"))
              (should-not drgnx-clip-test--pushed)
              (should (equal (car kill-ring) "alpha beta"))
              (set-mark 1)
              (goto-char (point-max))
              (execute-kbd-macro (kbd "C-w"))
              (should (equal drgnx-clip-test--pushed '("\ngamma"))))
          (kill-buffer buf))))))

(ert-deftest drgnx-clip/yank-prefers-a-newer-system-clipboard ()
  ;; unchanged from Emacs: the paste function's answer wins over the kill ring
  (drgnx-clip-test--env (lambda () "from another app")
    (drgnx-clipboard-install)
    (kill-new "mine")
    (with-temp-buffer (yank) (should (equal (buffer-string) "from another app")))))

;;;; The owner that does not answer

(ert-deftest drgnx-clip/a-failing-paste-falls-back-to-the-kill-ring ()
  (let ((messages nil))
    (drgnx-clip-test--env (lambda () (error "Timed out waiting for reply from selection owner"))
      (drgnx-clipboard-install)
      (kill-new "from emacs")
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (with-temp-buffer
          (yank)
          (should (equal (buffer-string) "from emacs"))
          (yank)
          (should (equal (buffer-string) "from emacsfrom emacs"))))
      (should (equal (seq-filter (lambda (m) (string-prefix-p "drgnx:" m)) messages)
                     '("drgnx: the clipboard owner didn't answer in 1.5 s; pasted from Emacs's own copies"))))))

(ert-deftest drgnx-clip/emacs-own-paste-path-reports-the-timeout-itself ()
  ;; the default paste function (`gui-selection-value') demotes the error of `gui-get-selection' to a message, so
  ;; drgnx's guard never sees it: Emacs says it, the paste comes from the kill ring, drgnx says nothing
  (let ((messages nil))
    (drgnx-clip-test--env #'gui-selection-value
      (drgnx-clipboard-install)
      (kill-new "from emacs")
      (cl-letf (((symbol-function 'gui-get-selection)
                 (lambda (&rest _) (error "Timed out waiting for reply from selection owner")))
                ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (with-temp-buffer
          (yank)
          (should (equal (buffer-string) "from emacs"))))
      (should (seq-some (lambda (m) (string-match-p "\\`gui-get-selection: .*Timed out" m)) messages))
      (should-not (seq-some (lambda (m) (string-prefix-p "drgnx:" m)) messages)))))

(ert-deftest drgnx-clip/the-timeout-is-set-only-at-the-standard-value ()
  (drgnx-clip-test--env nil
    (setq x-selection-timeout 0 pgtk-selection-timeout 3000)   ; the user chose pgtk's
    (drgnx-clipboard-install)
    (should (= x-selection-timeout 1500))
    (should (= pgtk-selection-timeout 3000))
    (drgnx-clipboard-uninstall)
    (should (= x-selection-timeout 0))
    (should (= pgtk-selection-timeout 3000)))
  ;; nil leaves them alone
  (drgnx-clip-test--env nil
    (setq drgnx-clipboard-read-timeout nil)
    (drgnx-clipboard-install)
    (should (= x-selection-timeout 0))))

;;;; Selecting

(ert-deftest drgnx-clip/klipper-syncing-turns-publishing-off ()
  (drgnx-clip-test--env nil
    (drgnx-clip-test--file ".config/klipperrc" "[General]\nKeepClipboardContents=true\nSyncClipboards=true\n")
    (drgnx-clip-test--x11 '("bash" "klipper")
      (drgnx-clipboard-install)
      (should-not select-active-regions)
      (let ((facts (drgnx-clipboard-doctor-facts)))
        (should (eq (plist-get facts :manager) 'klipper))
        (should (equal (plist-get facts :changed) '(select-active-regions)))
        (should (eq (plist-get facts :kills) 'region))
        (should (= (plist-get facts :read-timeout) 1.5))))))

(ert-deftest drgnx-clip/klipper-not-syncing-or-not-running-changes-nothing ()
  (drgnx-clip-test--env nil
    (drgnx-clip-test--file ".config/klipperrc" "[General]\nSyncClipboards=false\n")
    (drgnx-clip-test--x11 '("klipper")
      (drgnx-clipboard-install)
      (should select-active-regions)
      (should-not (plist-get (drgnx-clipboard-doctor-facts) :manager))))
  (drgnx-clip-test--env nil
    (drgnx-clip-test--file ".config/klipperrc" "[General]\nSyncClipboards=true\n")
    (drgnx-clip-test--x11 '("bash")
      (drgnx-clipboard-install)
      (should select-active-regions)))
  ;; a terminal frame is not looked at
  (drgnx-clip-test--env nil
    (drgnx-clip-test--file ".config/klipperrc" "[General]\nSyncClipboards=true\n")
    (cl-letf (((symbol-function 'drgnx-clipboard--process-names) (lambda () '("klipper"))))
      (drgnx-clipboard-install)
      (should select-active-regions))))

(ert-deftest drgnx-clip/a-manager-started-later-is-found-at-the-next-window ()
  ;; each new graphical window looks again: a manager started after the first one (log in, then start CopyQ) is
  ;; found without a restart
  (drgnx-clip-test--env nil
    (drgnx-clip-test--file ".config/copyq/copyq.conf" "[Options]\ncheck_selection=true\n")
    (let ((procs '("bash")))
      (cl-letf (((symbol-function 'drgnx-clipboard--graphical-p) (lambda (&optional _f) t))
                ((symbol-function 'drgnx-clipboard--process-names) (lambda () procs)))
        (drgnx-clipboard-install)
        (should select-active-regions)
        (setq procs '("bash" "copyq"))
        (drgnx-clipboard--frame-hook (selected-frame))
        (should-not select-active-regions)
        (should (eq (plist-get (drgnx-clipboard-doctor-facts) :manager) 'copyq))))))

(ert-deftest drgnx-clip/copyq-taking-the-selection-turns-publishing-off ()
  (drgnx-clip-test--env nil
    (drgnx-clip-test--file ".config/copyq/copyq.conf" "[Options]\ncheck_selection=true\n")
    (drgnx-clip-test--x11 '("copyq")
      (drgnx-clipboard-install)
      (should-not select-active-regions)
      (should (eq (plist-get (drgnx-clipboard-doctor-facts) :manager) 'copyq))))
  (drgnx-clip-test--env nil
    (drgnx-clip-test--file ".config/copyq/copyq.conf" "[Options]\ncopy_selection=false\ncheck_selection=false\n")
    (drgnx-clip-test--x11 '("copyq")
      (drgnx-clipboard-install)
      (should select-active-regions))))

(defun drgnx-clip-test--gsettings (script)
  "Put a fake gsettings in the temp bin directory; SCRIPT is its shell body (`$3' is the key asked)."
  (let ((file (expand-file-name "gsettings" drgnx-clip-test--bin)))
    (with-temp-file file (insert "#!/bin/sh\n" script "\n"))
    (set-file-modes file #o755)))

(defun drgnx-clip-test--wait (pred seconds)
  (drgnx-test-wait pred :secs (max 30 seconds) :what "the clipboard manager's answer"))

(ert-deftest drgnx-clip/gpaste-syncing-is-found-without-blocking ()
  (drgnx-clip-test--env nil
    (drgnx-clip-test--gsettings "echo true")
    (drgnx-clip-test--x11 '("bash")
      (drgnx-clipboard-install)                       ; the asks run in the background:
      (should select-active-regions)                  ; the answer is not known yet
      (should (drgnx-clip-test--wait (lambda () (not select-active-regions)) 3))
      (should (eq (plist-get (drgnx-clipboard-doctor-facts) :manager) 'gpaste))))
  ;; either setting alone records a selection (primary-to-history directly, synchronize-clipboards through the clipboard)
  (drgnx-clip-test--env nil
    (drgnx-clip-test--gsettings "[ \"$3\" = primary-to-history ] && echo false || echo true")
    (drgnx-clip-test--x11 '("bash")
      (drgnx-clipboard-install)
      (should (drgnx-clip-test--wait (lambda () (not select-active-regions)) 3))))
  (drgnx-clip-test--env nil
    (drgnx-clip-test--gsettings "[ \"$3\" = primary-to-history ] && echo true || echo false")
    (drgnx-clip-test--x11 '("bash")
      (drgnx-clipboard-install)
      (should (drgnx-clip-test--wait (lambda () (not select-active-regions)) 3))))
  ;; both off: not syncing
  (drgnx-clip-test--env nil
    (drgnx-clip-test--gsettings "echo false")
    (drgnx-clip-test--x11 '("bash")
      (drgnx-clipboard-install)
      (drgnx-test-pause 0.5)
      (should select-active-regions))))

(ert-deftest drgnx-clip/a-gsettings-that-hangs-is-given-up-after-a-second ()
  (drgnx-clip-test--env nil
    (drgnx-clip-test--gsettings "sleep 30; echo true")
    (drgnx-clip-test--x11 '("bash")
      (drgnx-clipboard-install)
      (should select-active-regions)                  ; the hanging ask did not block the install
      (drgnx-test-pause 1.5)
      (should select-active-regions)
      (should-not (plist-get (drgnx-clipboard-doctor-facts) :manager))
      (should-not (seq-filter (lambda (p) (string-prefix-p "drgnx-gpaste" (process-name p))) (process-list))))))

(ert-deftest drgnx-clip/the-setting-overrides-detection ()
  ;; t: published even where a manager syncs
  (drgnx-clip-test--env nil
    (setq drgnx-clipboard-publish-selection t)
    (drgnx-clip-test--file ".config/klipperrc" "[General]\nSyncClipboards=true\n")
    (drgnx-clip-test--x11 '("klipper")
      (setq select-active-regions nil)
      (drgnx-clipboard-install)
      (should select-active-regions)))
  ;; nil: never, with no manager at all
  (drgnx-clip-test--env nil
    (setq drgnx-clipboard-publish-selection nil)
    (drgnx-clip-test--x11 '("bash")
      (drgnx-clipboard-install)
      (should-not select-active-regions))))

(ert-deftest drgnx-clip/publish-t-keeps-the-users-only ()
  ;; select-active-regions `only' (selections in the active region, not mouse-drag ones) is already publishing
  (drgnx-clip-test--env nil
    (setq drgnx-clipboard-publish-selection t select-active-regions 'only)
    (drgnx-clipboard-install)
    (should (eq select-active-regions 'only))
    (should-not (plist-get (drgnx-clipboard-doctor-facts) :changed)))
  (drgnx-clip-test--env nil
    (setq drgnx-clipboard-publish-selection t select-active-regions nil)
    (drgnx-clipboard-install)
    (should (eq select-active-regions t))
    (drgnx-clipboard-uninstall)
    (should-not select-active-regions)))

(ert-deftest drgnx-clip/a-wrapper-added-on-top-does-not-leave-a-swallowing-one ()
  ;; a third party wraps the cut function after drgnx did; uninstall must take drgnx's layer out of the stack
  (drgnx-clip-test--env nil
    (let ((seen nil))
      (drgnx-clipboard-install)
      (add-function :around (default-value 'interprogram-cut-function)
                    (lambda (orig text) (push text seen) (funcall orig text))
                    '((name . third-party)))
      (drgnx-clipboard-uninstall)
      (kill-new "after")
      (should (equal seen '("after")))
      (should (equal drgnx-clip-test--pushed '("after")))))
  ;; the global value replaced by someone else: their function gets the kills, uninstall leaves it be
  (drgnx-clip-test--env nil
    (let ((mine nil))
      (drgnx-clipboard-install)
      (set-default 'interprogram-cut-function (lambda (text) (push text mine)))
      (kill-new "theirs")
      (drgnx-clipboard-uninstall)
      (kill-new "theirs 2")
      (should (equal mine '("theirs 2" "theirs"))))))

(ert-deftest drgnx-clip/a-command-that-errors-ends-the-command ()
  ;; post-command-hook does not run after an error; command-error-function does
  (drgnx-clip-test--env nil
    (drgnx-clipboard-install)
    (should (advice-function-member-p #'drgnx-clipboard--command-error (default-value 'command-error-function)))
    ;; where the variable is buffer-local (the minibuffer) the layer is not seen: said in the docs
    (drgnx-clipboard--new-command)
    (drgnx-clipboard--command-error '(error "x") "" nil)
    (let ((this-command 'kill-line))
      (kill-new "from a timer"))
    (should (equal drgnx-clip-test--pushed '("from a timer")))
    (drgnx-clipboard-uninstall)
    (should-not (advice-function-member-p #'drgnx-clipboard--command-error (default-value 'command-error-function)))))

(ert-deftest drgnx-clip/uninstall-puts-everything-back ()
  (drgnx-clip-test--env #'ignore
    (let ((cut interprogram-cut-function))
      (drgnx-clip-test--file ".config/klipperrc" "[General]\nSyncClipboards=true\n")
      (drgnx-clip-test--x11 '("klipper")
        (drgnx-clipboard-install)
        (should-not (eq interprogram-cut-function cut))
        (drgnx-clipboard-uninstall)
        (should (eq interprogram-cut-function cut))
        (should (eq interprogram-paste-function #'ignore))
        (should select-active-regions)
        (should (= x-selection-timeout 0))
        (should-not (memq #'drgnx-clipboard--new-command pre-command-hook))
        (should-not (memq #'drgnx-clipboard--end-command post-command-hook))))))

;;;; The module

(ert-deftest drgnx-clip/a-disabled-module-changes-nothing ()
  (drgnx-clip-test--env #'ignore
    (let ((cut interprogram-cut-function) (drgnx-modules--report nil)
          (spec (alist-get 'editor/clipboard drgnx-modules--table)))
      (should spec)
      (cl-letf (((symbol-function 'drgnx-module-disabled-p) (lambda (_m) t)))
        (drgnx-modules--run-one 'editor/clipboard spec 'startup))
      (should (eq interprogram-cut-function cut))
      (should (eq interprogram-paste-function #'ignore))
      (should (= x-selection-timeout 0))
      (should select-active-regions)
      (should-not pre-command-hook)
      ;; enabled, the same call installs it
      (cl-letf (((symbol-function 'drgnx-module-disabled-p) (lambda (_m) nil)))
        (drgnx-modules--run-one 'editor/clipboard spec 'startup))
      (should (advice-function-member-p #'drgnx-clipboard--cut interprogram-cut-function)))))

(ert-deftest drgnx-clipboard/turning-it-off-takes-the-wrappers-off ()
  ;; the wrappers are `add-function's on three variables, which no recorder sees: the module's teardown takes them
  ;; off, so the module turned on again puts them back (its guard is cleared too)
  (drgnx-test-with-modules '(editor/clipboard) :strict t
                           (should drgnx-clipboard--installed)
                           (should (advice-function-member-p #'drgnx-clipboard--cut (default-value 'interprogram-cut-function))))
  (should-not drgnx-clipboard--installed)
  (should-not (advice-function-member-p #'drgnx-clipboard--cut (default-value 'interprogram-cut-function)))
  (should-not (advice-function-member-p #'drgnx-clipboard--paste (default-value 'interprogram-paste-function)))
  (should-not (advice-function-member-p #'drgnx-clipboard--command-error (default-value 'command-error-function))))

(provide 'mod-clipboard-test)
;;; mod-clipboard-test.el ends here
