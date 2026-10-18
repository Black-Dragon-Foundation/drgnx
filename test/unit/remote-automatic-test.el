;;; remote-automatic-test.el --- batch tests: nothing automatic touches a remote -*- lexical-binding: t -*-
;; The binding rule (M2-6): TRAMP stays on for what the user starts, but no timer, hook, background check, file
;; watch, VC / diff-hl, Flymake, the Explorer, link or compile output touches a remote name.  The TRAMP method
;; `drgnx-mock' (test/fixtures/tramp-mock.el) logs in with a local sh and counts what would leave the machine.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-registry)
(require 'drgnx-modules)
(require 'drgnx-explorer)
(require 'drgnx-signal)
(require 'drgnx-buffers)
(require 'drgnx-outline)
(require 'drgnx-git)
(require 'eglot)
(require 'python)
(require 'autorevert)
(require 'flymake)
(load (expand-file-name "test/fixtures/tramp-mock" drgnx-dir) nil t)
(load (expand-file-name "modules/lang/drgnx-lang" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-remote" drgnx-dir) nil t)
(load (expand-file-name "modules/extra/drgnx-blame" drgnx-dir) nil t)
(load (expand-file-name "modules/editor/drgnx-sticky" drgnx-dir) nil t)
(load (expand-file-name "modules/extra/drgnx-hunks" drgnx-dir) nil t)

(defconst drgnx-remote-auto--elpa (expand-file-name (or (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa"))
  "The user's ELPA, read-only, where diff-hl is when installed.")

(defvar drgnx-remote-auto--clock 0)

(defun drgnx-remote-auto--write (file text)
  "Write FILE and give its folder a new modification time (a same-second change would look unchanged)."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert text))
  (set-file-times (file-name-directory file) (time-add (current-time) (cl-incf drgnx-remote-auto--clock 10))))

(defmacro drgnx-remote-auto--with (&rest body)
  "BODY with the mock method set up, `root' the mock-remote name of a temp folder holding `app.py' and `sub/x.txt',
`ldir' a local folder holding `l.py', no server programs for any mode, and everything closed afterwards."
  (declare (indent 0))
  `(let* ((base (file-name-as-directory (make-temp-file "drgnx-auto" t)))
          (rdir (expand-file-name "remote/" base))
          (ldir (expand-file-name "local/" base))
          (process-environment (cons "DRGNX_NO_LANGUAGE_SERVERS" process-environment))
          (eglot-server-programs nil)
          (create-lockfiles nil)
          (drgnx-wb--sections nil) (drgnx-signal--editor-window nil) (drgnx-explorer--pressed nil)
          (drgnx-explorer--selection nil) (drgnx-explorer--anchor nil) (drgnx-explorer--focused-before nil)
          (drgnx-explorer-compact-folders nil)
          (drgnx-explorer--cache (make-hash-table :test #'equal))
          (drgnx-explorer--expanded (make-hash-table :test #'equal))
          (drgnx-explorer--dirty nil)
          (drgnx-remote--roots nil)
          (drgnx-lang--remote-servers (make-hash-table :test #'equal))
          (drgnx-lang--remote-wanted (make-hash-table :test #'equal))
          (drgnx-lang--remote-hinted nil)
          (drgnx-lang--remote-pending nil)
          (drgnx-lang--user-command nil)
          (drgnx-remote-may-prompt nil)
          (global-mode-string nil)
          (signal-was-on drgnx-signal-mode)
          (root nil))
     (drgnx-remote-auto--write (expand-file-name "app.py" rdir) "def f():\n    return 1\n")
     (drgnx-remote-auto--write (expand-file-name "sub/x.txt" rdir) "x\n")
     (drgnx-remote-auto--write (expand-file-name "l.py" ldir) "def g():\n    return 2\n")
     (drgnx-tramp-mock-setup)
     (setq root (file-name-as-directory (expand-file-name (drgnx-tramp-mock-name rdir))))
     (drgnx-lang--install-eglot-guards)                           ; the production guards, as the lang module's setup puts them
     (unwind-protect (progn ,@body)
       (drgnx-lang--teardown-eglot-guards)
       (remove-hook 'prog-mode-hook #'drgnx-lang--maybe-eglot)
       (remove-hook 'prog-mode-hook #'drgnx-sticky--maybe)
       (unless signal-was-on (drgnx-signal-mode -1))
       (ignore-errors (drgnx-remote--teardown))
       (drgnx-wb-hide-sidebar)
       (delete-other-windows)
       (drgnx-explorer-set-roots nil)
       (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
       (when (get-buffer drgnx-buffers-buffer-name) (kill-buffer drgnx-buffers-buffer-name))
       (when (boundp 'eglot--servers-by-project)
         (maphash (lambda (_ servers) (dolist (s servers) (ignore-errors (eglot-shutdown s nil 1 t))))
                  eglot--servers-by-project))
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (or (file-remote-p (buffer-file-name b)) (string-prefix-p base (buffer-file-name b))))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (drgnx-tramp-mock-teardown)
       (delete-directory base t))))

;; the stage's name is in the failure: (STAGE SENDS) against (STAGE 0)
(defun drgnx-remote-auto--none (stage)
  (should (equal (list stage drgnx-tramp-mock-sends) (list stage 0))))

(defun drgnx-remote-auto--row-names ()
  (mapcar #'cadr (drgnx-remote-auto--rows)))

(defun drgnx-remote-auto--rows ()
  "The Explorer's rows as (DEPTH NAME) lists."
  (with-current-buffer drgnx-explorer-buffer-name
    (save-excursion
      (goto-char (point-min))
      (let (rows)
        (while (not (eobp))
          (when-let* ((v (drgnx-explorer--row-data (point))))   ; the data, not the node: the placeholder has no node
            (push (list (aref v 1) (file-name-nondirectory (directory-file-name (aref v 0)))) rows))
          (forward-line 1))
        (nreverse rows)))))

;;;; Every automatic path, counted

(ert-deftest drgnx-remote/automatic-paths-never-reach-the-remote ()
  (drgnx-remote-auto--with
    (let (rbuf lbuf)
      ;; what the user did: opened the folder, listed it, expanded a subfolder, opened a file and edited it
      (delete-other-windows)
      (drgnx-signal-mode 1)
      (drgnx-explorer-setup)
      (drgnx-buffers-setup)
      (drgnx-outline-setup)
      (drgnx-remote--setup)
      (add-hook 'prog-mode-hook #'drgnx-lang--maybe-eglot)
      (add-hook 'prog-mode-hook #'drgnx-sticky--maybe)
      (drgnx-wb-show-sidebar)
      (drgnx-explorer-set-roots (list root ldir))
      (should (member "app.py" (drgnx-remote-auto--row-names)))
      (with-current-buffer drgnx-explorer-buffer-name        ; Toggle on the folder row, the user's command
        (goto-char (point-min)) (re-search-forward "sub") (beginning-of-line)
        (drgnx-explorer-toggle))
      (should (member "x.txt" (drgnx-remote-auto--row-names)))
      (setq rbuf (find-file-noselect (concat root "app.py")))
      (setq lbuf (find-file-noselect (expand-file-name "l.py" ldir)))
      (switch-to-buffer rbuf)
      (with-current-buffer rbuf
        ;; nothing turns these on by itself for a remote file
        (should-not (or flymake-mode auto-revert-mode (bound-and-true-p diff-hl-mode) drgnx-blame-mode))
        (drgnx-blame--maybe)
        (should-not drgnx-blame-mode)
        (goto-char (point-max)) (insert "# edited\n")
        (auto-revert-mode 1)
        (flymake-mode 1)
        (drgnx-sticky-mode 1)
        (drgnx-blame-mode 1))
      (with-current-buffer lbuf (goto-char (point-max)) (insert "# edited\n"))
      (should (buffer-modified-p rbuf))
      (should (> drgnx-tramp-mock-sends 0))                       ; the user's own work did use the remote
      (ignore-errors (when (timerp drgnx-explorer--git-timer) (cancel-timer drgnx-explorer--git-timer)))
      (setq drgnx-explorer--git-timer nil)
      ;; from here on, only automatic paths; TRAMP's attribute cache would hide a call (the mock keeps it for ever)
      (setq drgnx-tramp-mock-sends 0 remote-file-name-inhibit-cache t)
      ;; 1. every pending timer, as the timer loop runs it (idle ones too)
      (dolist (timer (append (copy-sequence timer-list) (copy-sequence timer-idle-list)))
        (condition-case nil (timer-event-handler timer) (error nil)))
      (drgnx-remote-auto--none 'timers)
      ;; 2. the bus edges and the git edge, then the idle flush they arm
      (drgnx-signal--emit 'editor-changed rbuf)
      (drgnx-signal--emit 'modified-changed (list rbuf lbuf))
      (drgnx-signal--emit 'buffer-set-changed (list rbuf lbuf))
      (drgnx-signal-post 'tabs-changed)
      (drgnx-signal--flush)
      (run-hook-with-args 'drgnx-git-changed-functions (directory-file-name ldir))
      (run-hook-with-args 'drgnx-git-changed-functions root)
      (drgnx-remote-auto--none 'bus-and-git-edges)
      ;; 3. the hooks of a buffer list change, a window change, a major-mode change (eglot's hook), focus
      (run-hooks 'buffer-list-update-hook)
      (run-hook-with-args 'window-buffer-change-functions (selected-frame))
      (run-hook-with-args 'window-selection-change-functions (selected-frame))
      (when (boundp 'after-focus-change-function) (ignore-errors (funcall after-focus-change-function)))
      (drgnx-remote-auto--none 'window-and-focus-hooks)
      ;; a major-mode change: drgnx's prog-mode hooks (language server, sticky scroll) and eglot's own hook, which
      ;; the lang module's advice keeps from asking a remote buffer's project (40 sends without it)
      (should (memq 'eglot--maybe-activate-editing-mode after-change-major-mode-hook))
      (with-current-buffer rbuf (python-mode))
      (drgnx-remote-auto--none 'major-mode-change)
      ;; 4. a local save and its hooks (blame, VC, the bus)
      (with-current-buffer lbuf (save-buffer) (run-hooks 'after-save-hook))
      (drgnx-remote-auto--none 'local-save)
      ;; 5. the Explorer redrawn from a timer, a file event of a shown local folder, a git status of every root
      (drgnx-explorer--render)
      (drgnx-explorer--file-event (list 'desc 'created (expand-file-name "new.py" ldir)) (directory-file-name ldir))
      (drgnx-explorer--apply-file-events)
      (drgnx-explorer--git-refresh)
      (drgnx-git-refresh-tree (list root ldir))
      (drgnx-remote-auto--none 'explorer-redraw)
      ;; 6. the mode line of the remote buffer and the global one (the status segment), redrawn
      (with-current-buffer rbuf
        (force-mode-line-update t)
        (format-mode-line mode-line-format)
        (format-mode-line header-line-format)
        (format-mode-line global-mode-string)
        (drgnx-remote-segment))
      (redisplay t)
      (drgnx-remote-auto--none 'mode-line)
      ;; 7. the idle time passes: the timers the work above armed run too
      (accept-process-output nil 0.3)
      (dolist (timer (append (copy-sequence timer-list) (copy-sequence timer-idle-list)))
        (condition-case nil (timer-event-handler timer) (error nil)))
      (drgnx-remote-auto--none 'idle-time))))

;;;; Eglot's own major-mode hook

(ert-deftest drgnx-remote/eglots-major-mode-hook-stays-away-from-the-remote ()
  "`eglot--maybe-activate-editing-mode', eglot's `after-change-major-mode-hook' function, asks `project-current' of
a buffer whose major mode changed, and for a remote buffer that is about 40 TRAMP calls.  Outside a command of the
user's it is skipped for a remote buffer (nothing is asked); inside one, eglot still attaches the buffer; a local
buffer is not affected."
  (drgnx-remote-auto--with
    (let* ((b (find-file-noselect (concat root "app.py")))
           (l (find-file-noselect (expand-file-name "l.py" ldir)))
           (calls nil)
           (count (lambda (&rest _) (push (list default-directory) calls))))
      (advice-remove 'eglot--maybe-activate-editing-mode #'drgnx-lang--guard-eglot-activation)
      (advice-add 'eglot--maybe-activate-editing-mode :before count)            ; the counter sits below the guard
      (advice-add 'eglot--maybe-activate-editing-mode :around #'drgnx-lang--guard-eglot-activation)
      (unwind-protect
          (progn
            (setq remote-file-name-inhibit-cache t drgnx-tramp-mock-sends 0)
            (with-current-buffer b (python-mode))                   ; a timer, a restored session, a revert
            (should (equal (list 'eglot-hook drgnx-tramp-mock-sends) (list 'eglot-hook 0)))
            (should-not calls)
            (with-current-buffer l (python-mode))                   ; a local buffer is attached as before
            (should (= (length calls) 1))
            (let ((drgnx-lang--user-command t))                     ; the user's command visits the remote file
              (with-current-buffer b (python-mode)))
            (should (= (length calls) 2)))
        (advice-remove 'eglot--maybe-activate-editing-mode count)))))

;;;; The Explorer lists a remote folder on a command only

(ert-deftest drgnx-remote/explorer-lists-remote-only-on-command ()
  (drgnx-remote-auto--with
    (should-not drgnx-explorer--remote-reads)
    ;; never listed, no command: one placeholder row, nothing sent
    (setq drgnx-tramp-mock-sends 0)
    (should (equal (drgnx-explorer-children root) '(("(not listed — Refresh)" . nil))))
    (should (= drgnx-tramp-mock-sends 0))
    (should-not (gethash root drgnx-explorer--cache))               ; the placeholder is not remembered as a listing
    ;; the user's command lists it
    (delete-other-windows)
    (drgnx-explorer-setup)
    (drgnx-explorer-set-roots (list root))
    (setq remote-file-name-inhibit-cache t)                         ; TRAMP's cache would hide a call (the mock keeps it for ever)
    (should (> drgnx-tramp-mock-sends 0))
    (should (equal (drgnx-remote-auto--row-names) '("remote" "sub" "app.py")))
    (should-not drgnx-explorer--remote-reads)                       ; only bound during the command
    ;; the folder changes on the host; a render driven by a timer shows the cached listing, sends nothing
    (drgnx-remote-auto--write (expand-file-name "later.py" rdir) "")
    (setq drgnx-tramp-mock-sends 0)
    (drgnx-explorer--render)
    (should (= drgnx-tramp-mock-sends 0))
    (should-not (member "later.py" (drgnx-remote-auto--row-names)))
    ;; Refresh is a command: it lists again
    (drgnx-explorer-refresh)
    (should (> drgnx-tramp-mock-sends 0))
    (should (member "later.py" (drgnx-remote-auto--row-names)))
    ;; so are Toggle and Open on a folder row
    (drgnx-remote-auto--write (expand-file-name "sub/y.txt" rdir) "")
    (setq drgnx-tramp-mock-sends 0)
    (with-current-buffer drgnx-explorer-buffer-name
      (goto-char (point-min)) (re-search-forward "sub") (beginning-of-line)
      (drgnx-explorer-toggle)
      (should (> drgnx-tramp-mock-sends 0))
      (should (member "x.txt" (drgnx-remote-auto--row-names)))
      (should (member "y.txt" (drgnx-remote-auto--row-names)))
      (drgnx-explorer-toggle)                                       ; collapse
      (drgnx-remote-auto--write (expand-file-name "sub/z.txt" rdir) "")
      (setq drgnx-tramp-mock-sends 0)
      (drgnx-explorer-open)                                         ; expand again by Open
      (should (> drgnx-tramp-mock-sends 0))
      (should (member "z.txt" (drgnx-remote-auto--row-names))))))

(ert-deftest drgnx-remote/file-commands-and-find-list-the-remote-folder ()
  "New File, Rename, Delete and Paste end in `drgnx-explorer--show-folder'; Find ends by drawing the tree again."
  (drgnx-remote-auto--with
    (delete-other-windows)
    (drgnx-explorer-setup)
    (drgnx-explorer-set-roots (list root))
    (setq remote-file-name-inhibit-cache t)
    (drgnx-remote-auto--write (expand-file-name "made.py" rdir) "")
    (setq drgnx-tramp-mock-sends 0)
    (drgnx-explorer--show-folder (directory-file-name root))
    (should (> drgnx-tramp-mock-sends 0))
    (should (member "made.py" (drgnx-remote-auto--row-names)))
    (should-not drgnx-explorer--remote-reads)
    (drgnx-remote-auto--write (expand-file-name "found.py" rdir) "")
    (drgnx-explorer--find-apply "app")
    (should-not (member "made.py" (drgnx-remote-auto--row-names)))
    (setq drgnx-tramp-mock-sends 0)
    (drgnx-explorer-find-clear)                                     ; leaving Find draws the tree again
    (should (> drgnx-tramp-mock-sends 0))
    (should (member "found.py" (drgnx-remote-auto--row-names)))
    (should-not drgnx-explorer--remote-reads)))

(ert-deftest drgnx-remote/a-folder-never-listed-shows-one-row-and-refresh-lists-it ()
  (drgnx-remote-auto--with
    (delete-other-windows)
    (drgnx-explorer-setup)
    (drgnx-explorer-set-roots (list root))
    (let ((sub (concat root "sub")))
      (puthash sub t drgnx-explorer--expanded)                      ; expanded (restored, say) but never listed
      (drgnx-explorer--render)                                      ; a timer-driven render
      (should (member "(not listed — Refresh)" (drgnx-remote-auto--row-names)))
      (should-not (member "x.txt" (drgnx-remote-auto--row-names)))
      (with-current-buffer drgnx-explorer-buffer-name
        (goto-char (point-min)) (re-search-forward "not listed") (beginning-of-line)
        (should-not (drgnx-explorer-node-at (point)))               ; no file operation can act on the row
        (should-error (drgnx-explorer--targets) :type 'user-error)
        (should-error (drgnx-explorer--folder-here) :type 'user-error))
      (drgnx-explorer-refresh)
      (should (member "x.txt" (drgnx-remote-auto--row-names)))
      (should-not (member "(not listed — Refresh)" (drgnx-remote-auto--row-names)))
      ;; Enter or a click on the row lists the folder, too
      (remhash (file-name-as-directory sub) drgnx-explorer--cache)  ; forgotten again
      (drgnx-explorer--render)
      (should (member "(not listed — Refresh)" (drgnx-remote-auto--row-names)))
      (with-current-buffer drgnx-explorer-buffer-name
        (goto-char (point-min)) (re-search-forward "not listed") (beginning-of-line)
        (drgnx-explorer-open))
      (should-not (member "(not listed — Refresh)" (drgnx-remote-auto--row-names))))))

(ert-deftest drgnx-remote/a-timer-inside-a-listing-lists-nothing ()
  (drgnx-remote-auto--with
    (let ((drgnx-explorer--remote-reads t) seen)                    ; the user's listing waits for the host; a timer fires
      (drgnx-remote--timer-without-command
       (lambda (_) (setq seen (drgnx-explorer-children root))) nil)
      (should (equal seen '(("(not listed — Refresh)" . nil))))
      (should (drgnx-explorer-children root))                       ; the listing itself still lists
      (should (assoc "app.py" (drgnx-explorer-children root))))))

(ert-deftest drgnx-remote/the-default-root-asks-no-project-of-a-remote-buffer ()
  (drgnx-remote-auto--with
    (delete-other-windows)
    (drgnx-explorer-setup)
    (with-current-buffer (window-buffer (drgnx-wb-editor-window))
      (let ((default-directory root))
        (setq remote-file-name-inhibit-cache t drgnx-tramp-mock-sends 0)
        (should (equal (drgnx-explorer--default-root) (file-name-as-directory root)))
        (should (= drgnx-tramp-mock-sends 0))))))

(ert-deftest drgnx-remote/checkout-keeps-remote-listings ()
  (drgnx-remote-auto--with
    (delete-other-windows)
    (drgnx-explorer-setup)
    (drgnx-explorer-set-roots (list root ldir))
    (let ((kept (gethash root drgnx-explorer--cache)))
      (should kept)
      (should (gethash ldir drgnx-explorer--cache))
      (setq drgnx-tramp-mock-sends 0)
      ;; a checkout on a local folder: more changed folders than the splice limit, so one full pass
      (setq drgnx-explorer--dirty (cl-loop for i below (1+ drgnx-explorer--splice-limit)
                                           collect (expand-file-name (format "d%d" i) ldir)))
      (drgnx-explorer--apply-file-events)
      (should (eq (gethash root drgnx-explorer--cache) kept))       ; the remote entry stayed, the very same listing
      (should (member "app.py" (drgnx-remote-auto--row-names)))
      (should (= drgnx-tramp-mock-sends 0)))))

;;;; diff-hl

(ert-deftest drgnx-remote/diff-hl-off-for-remote ()
  (skip-unless (file-directory-p drgnx-remote-auto--elpa))
  (let ((load-path (append load-path (seq-filter #'file-directory-p (directory-files drgnx-remote-auto--elpa t "\\`[^.]"))))
        (cfg (make-temp-file "drgnx-cfg" t)))
    (unwind-protect
        (let* ((_ (require 'diff-hl))
               (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
               (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
               (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
               (default (default-value 'diff-hl-disable-on-remote)))
          (load (expand-file-name "modules/extra/drgnx-hunks" drgnx-dir) nil t)
          (unwind-protect
              (progn
                (drgnx-modules-run 'idle)
                (should (eq (plist-get (alist-get 'extra/hunks (drgnx-modules-report)) :status) 'ok))
                (should (eq diff-hl-disable-on-remote t))
                (drgnx-remote-auto--with
                  (let ((b (generate-new-buffer " *drgnx-remote-hl*")))
                    (unwind-protect
                        (progn
                          (with-current-buffer b                    ; looks like the remote file; nothing is read
                            (setq buffer-file-name (concat root "app.py") default-directory root)
                            (setq drgnx-tramp-mock-sends 0)
                            (turn-on-diff-hl-mode)
                            (should-not (bound-and-true-p diff-hl-mode)))
                          (should (= drgnx-tramp-mock-sends 0)))
                      (kill-buffer b)))))
            (when (and (boundp 'global-diff-hl-mode) global-diff-hl-mode) (global-diff-hl-mode -1))
            (setq-default diff-hl-disable-on-remote default)))
      (delete-directory cfg t))))

;;;; Pending: the link followers (pass C batch C1)

(ert-deftest drgnx-remote/links-in-tool-output-never-open-a-remote ()
  "PENDING until pass C batch C1 lands `drgnx-trust-link-ok-p': a transcript and a Work row naming a remote file
open nothing remote unless the source buffer is remote (M2-6 c)."
  (skip-unless (fboundp 'drgnx-trust-link-ok-p))
  (drgnx-remote-auto--with
    (should-not (drgnx-trust-link-ok-p (concat root "app.py")))
    (should (= drgnx-tramp-mock-sends 0))))

(provide 'remote-automatic-test)
;;; remote-automatic-test.el ends here
