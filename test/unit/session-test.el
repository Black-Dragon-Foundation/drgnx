;;; session-test.el --- batch tests: closing the last window, quitting, the keep-running choice -*- lexical-binding: t -*-
;; Frames, `kill-emacs', `delete-frame' and `save-some-buffers' are stubs; session.eld lives in a temp config dir.
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-session)
(require 'drgnx-explorer)
(require 'project)
(defvar server-client-instructions)

(defmacro drgnx-session-test--with (spec &rest body)
  "BODY with the stubs SPEC asks for, in a temp config dir.
SPEC: (:keep-running BOOL :daemon BOOL :windows LIST :save FN :unsaved LIST :confirm BOOL :processes LIST)
— :windows the frames that count as windows, :unsaved the file buffers still changed after the save, :processes
what `process-list' returns.  Binds KILLED (non-nil once `kill-emacs' ran), DELETED (frames deleted), SAVED (calls
of `save-some-buffers'), ASKED (confirmations) and EVENTS (newest first: `save', then each question's text)."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "drgnx-session-test" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" dir) process-environment))
          (drgnx-keep-running ,(plist-get spec :keep-running))
          (killed nil) (deleted nil) (saved 0) (asked 0) (events nil))
     (unwind-protect
         (cl-letf (((symbol-function 'daemonp) (lambda () ,(plist-get spec :daemon)))
                   ((symbol-function 'drgnx-session--windows) (lambda () ,(plist-get spec :windows)))
                   ((symbol-function 'select-frame-set-input-focus) #'ignore)
                   ((symbol-function 'kill-emacs) (lambda (&rest _) (setq killed t)))
                   ((symbol-function 'delete-frame) (lambda (&optional f _force) (push f deleted)))
                   ((symbol-function 'save-some-buffers)
                    (lambda (&rest _) (cl-incf saved) (push 'save events) (funcall (or ,(plist-get spec :save) #'ignore))))
                   ((symbol-function 'drgnx-session--unsaved-buffers) (lambda () ,(plist-get spec :unsaved)))
                   ((symbol-function 'process-list) (lambda () ,(plist-get spec :processes)))
                   ((symbol-function 'yes-or-no-p)
                    (lambda (prompt) (cl-incf asked) (push prompt events) ,(plist-get spec :confirm))))
           (ignore killed deleted saved asked events)
           ,@body)
       (delete-directory dir t))))

(ert-deftest drgnx-session/quit-mode-closing-the-last-window-quits ()
  (drgnx-session-test--with (:keep-running nil :daemon t :windows (list (selected-frame)) :save (lambda () t))
    (drgnx-session-close-frame)
    (should (= saved 1))
    (should killed)
    (should-not deleted)))

(ert-deftest drgnx-session/keep-running-closing-the-last-window-stays ()
  (drgnx-session-test--with (:keep-running t :daemon t :windows (list (selected-frame)))
    (drgnx-session-close-frame)
    (should-not killed)
    (should (= saved 0))
    (should (equal deleted (list (selected-frame))))))

(ert-deftest drgnx-session/another-window-open-just-closes-this-one ()
  (drgnx-session-test--with (:keep-running nil :daemon t :windows (list (selected-frame) 'f2))
    (drgnx-session-close-frame)
    (should-not killed)
    (should (equal deleted (list (selected-frame))))))

(ert-deftest drgnx-session/the-last-window-of-an-emacs-without-a-daemon-quits-in-either-mode ()
  ;; Without a daemon there is nothing to keep running once the last window is gone.
  (drgnx-session-test--with (:keep-running t :daemon nil :windows (list (selected-frame)))
    (drgnx-session-close-frame)
    (should killed)
    (should-not deleted)))

(ert-deftest drgnx-session/the-close-button-closes-the-window-it-belongs-to ()
  ;; The title bar's close button: a `delete-frame' event naming its frame.
  (drgnx-session-test--with (:keep-running t :daemon t :windows (list 'f1 'f2))
    (drgnx-session-close-frame (list 'delete-frame (list 'f2)))
    (should (equal deleted '(f2)))
    (let ((server-client-instructions t))
      (drgnx-session-setup)
      (should-not server-client-instructions))      ; no "When done with a buffer, type C-x 5 0" in every emacsclient frame
    (should (eq (lookup-key special-event-map [delete-frame]) #'drgnx-session-close-frame))))

(ert-deftest drgnx-session/unsaved-work-is-never-lost ()
  ;; C-g in the save question: drgnx stays, the window stays.
  (drgnx-session-test--with (:keep-running nil :daemon t :windows (list (selected-frame)) :save (lambda () (signal 'quit nil)))
    (should (eq 'quit (condition-case nil (progn (drgnx-session-close-frame) 'ran) (quit 'quit))))
    (should-not killed)
    (should-not deleted))
  ;; An error while saving (a read-only directory): the same.
  (drgnx-session-test--with (:keep-running nil :daemon t :windows (list 'f1) :save (lambda () (error "Disk full")))
    (should-error (drgnx-session-quit))
    (should-not killed))
  ;; A file kept unsaved, then "no" to quitting without it: drgnx stays.
  (drgnx-session-test--with (:keep-running nil :daemon t :windows (list 'f1) :unsaved (list 'buf) :confirm nil)
    (drgnx-session-quit)
    (should (= asked 1))
    (should-not killed))
  ;; …"yes": quits.
  (drgnx-session-test--with (:keep-running nil :daemon t :windows (list 'f1) :unsaved (list 'buf) :confirm t)
    (drgnx-session-quit)
    (should killed))
  ;; Everything saved: no extra question.
  (drgnx-session-test--with (:keep-running nil :daemon t :windows (list 'f1))
    (drgnx-session-quit)
    (should (= asked 0))
    (should killed)))

;; M12a-28: the programs a quit would stop are asked about, once.
(ert-deftest drgnx-session/quit-asks-once-for-running-processes ()
  (let ((p (make-process :name "drgnx-session-test-sleep" :command '("sleep" "30") :noquery nil))
        (q (make-process :name "drgnx-session-test-quiet" :command '("sleep" "30") :noquery t))
        (r (make-process :name "drgnx-session-test-second" :command '("sleep" "30") :noquery nil)))
    (unwind-protect
        (progn
          ;; "no": asked once, and drgnx stays
          (drgnx-session-test--with (:keep-running nil :daemon t :windows (list 'f1) :processes (list p q) :confirm nil)
            (drgnx-session-quit)
            (should (= saved 1))
            (should (= asked 1))
            (should (string-match-p "\\`1 program is still running (drgnx-session-test-sleep)" (car events)))
            (should-not killed))
          ;; "yes": asked once, quits
          (drgnx-session-test--with (:keep-running nil :daemon t :windows (list 'f1) :processes (list p q) :confirm t)
            (drgnx-session-quit)
            (should (= saved 1))
            (should (= asked 1))
            (should killed))
          ;; a process that does not ask on exit does not count
          (drgnx-session-test--with (:keep-running nil :daemon t :windows (list 'f1) :processes (list q) :confirm nil)
            (drgnx-session-quit)
            (should (= saved 1))
            (should (= asked 0))
            (should killed))
          ;; unsaved changes and a running program, the first "no": that ends it, the programs are not asked about
          (drgnx-session-test--with (:keep-running nil :daemon t :windows (list 'f1) :unsaved (list 'buf)
                                                   :processes (list p) :confirm nil)
            (should-not (drgnx-session-quit-confirm))
            (should (= saved 1))
            (should (= asked 1))
            (should (string-match-p "not saved" (car events))))
          ;; both "yes": save, then the changes question, then the programs question; then it quits
          (drgnx-session-test--with (:keep-running nil :daemon t :windows (list 'f1) :unsaved (list 'buf)
                                                   :processes (list p q r) :confirm t)
            (drgnx-session-quit)
            (should (= saved 1))
            (should (= asked 2))
            (should killed)
            (let ((order (reverse events)))
              (should (eq (nth 0 order) 'save))
              (should (string-match-p "not saved; quit and lose" (nth 1 order)))
              (should (string-match-p "\\`2 programs are still running" (nth 2 order))))))
      (delete-process p)
      (delete-process q)
      (delete-process r))))

;; M12a-33: a changed *scratch* is not a buffer whose changes would be lost.
(ert-deftest drgnx-session/scratch-is-not-offered ()
  (let ((scratch (get-buffer-create "*scratch*"))
        (untitled (generate-new-buffer "Untitled-session-test")))
    (unwind-protect
        (progn
          (with-current-buffer scratch (insert "typed in scratch"))
          (with-current-buffer untitled (setq buffer-offer-save t) (insert "typed"))
          (should (buffer-modified-p scratch))
          (should (memq untitled (drgnx-session--unsaved-buffers)))
          (should-not (memq scratch (drgnx-session--unsaved-buffers))))
      (with-current-buffer scratch (erase-buffer) (set-buffer-modified-p nil))
      (kill-buffer untitled))))

(ert-deftest drgnx-session/the-choice-is-remembered ()
  (drgnx-session-test--with (:keep-running t)
    (drgnx-session-set-keep-running nil)
    (should-not drgnx-keep-running)
    (let ((data (with-temp-buffer (insert-file-contents (expand-file-name "session.eld" dir)) (read (current-buffer)))))
      (should (plist-member data :keep-running))
      (should-not (plist-get data :keep-running)))
    (setq drgnx-keep-running t)
    (drgnx-session-load)                      ; what the next start does
    (should-not drgnx-keep-running)
    (drgnx-session-set-keep-running t)
    (setq drgnx-keep-running nil)
    (drgnx-session-load)
    (should (eq drgnx-keep-running t))
    ;; no file, or a broken one: the default stays
    (delete-file (expand-file-name "session.eld" dir))
    (drgnx-config-reread 'session)            ; the config layer reads session.eld once per start
    (drgnx-session-load)
    (should (eq drgnx-keep-running t))
    (write-region "(:keep-running" nil (expand-file-name "session.eld" dir))
    (drgnx-config-reread 'session)
    (drgnx-session-load)
    (should (eq drgnx-keep-running t))))

(ert-deftest drgnx-session/the-preference-toggles-and-says-so ()
  (drgnx-session-test--with (:keep-running t)
    (let ((msg (drgnx-session-toggle-keep-running)))
      (should-not drgnx-keep-running)
      (should (string-match-p "quits" msg)))
    (let ((msg (drgnx-session-toggle-keep-running)))
      (should drgnx-keep-running)
      (should (string-match-p "keeps running" msg)))))

(ert-deftest drgnx-session/commands-are-registered ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (drgnx-session-register-commands)
    (should (equal (drgnx-commands-label (drgnx-commands-get 'quit)) "File: Quit drgnx"))
    (should (eq (drgnx-cmd-command (drgnx-commands-get 'quit)) #'drgnx-session-quit))
    (should (equal (drgnx-commands-label (drgnx-commands-get 'preferences-keep-running))
                   "Preferences: Keep drgnx Running in the Background"))))

(ert-deftest drgnx-session/open-folder-asks-for-the-folder ()
  ;; File → Open Folder…: the folder chosen opens as with `drgnx DIR'.  Only the command asks: bin/drgnx's call never does.
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (drgnx-explorer-buffer-name " *drgnx-session-test-explorer*")
        (dir (file-name-as-directory (make-temp-file "drgnx-session-open" t)))
        roots asked)
    (unwind-protect
        (cl-letf (((symbol-function 'read-directory-name) (lambda (&rest _) (setq asked t) dir))
                  ((symbol-function 'drgnx-session-raise) #'ignore)
                  ((symbol-function 'drgnx-explorer-roots) (lambda () nil))
                  ((symbol-function 'drgnx-explorer-set-roots) (lambda (r) (setq roots r)))
                  ((symbol-function 'drgnx-explorer-focus) #'ignore))
          (get-buffer-create drgnx-explorer-buffer-name)
          (drgnx-session-register-commands)
          (should (equal (drgnx-commands-label (drgnx-commands-get 'open-folder)) "File: Open Folder…"))
          (call-interactively (drgnx-cmd-command (drgnx-commands-get 'open-folder)))
          (should asked)
          (should (equal roots (list dir)))
          (setq asked nil)
          (drgnx-session-open-folder dir)
          (should-not asked))
      (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
      (delete-directory dir t))))

(ert-deftest drgnx-session/a-folder-opened-in-a-terminal-frame-opens-there ()
  ;; `drgnx -t DIR' (and Open Folder… typed in a terminal window) runs in the client's terminal frame: the
  ;; graphical window is neither raised nor focused, and the Explorer is focused in the terminal frame.  On the
  ;; initial terminal (batch Emacs's, a daemon's own frame: bin/drgnx's graphical path) it still raises.
  (let ((drgnx-explorer-buffer-name " *drgnx-session-test-explorer*")
        (dir (file-name-as-directory (make-temp-file "drgnx-session-open" t)))
        (term "/dev/pts/3") (raised 0) focused-in roots)
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-session-raise) (lambda () (cl-incf raised)))
                  ((symbol-function 'terminal-name) (lambda (&optional _) term))
                  ((symbol-function 'drgnx-explorer-roots) (lambda () nil))
                  ((symbol-function 'drgnx-explorer-set-roots) (lambda (r) (setq roots r)))
                  ((symbol-function 'drgnx-explorer-focus) (lambda () (setq focused-in (selected-frame)))))
          (get-buffer-create drgnx-explorer-buffer-name)
          (should-not (display-graphic-p))
          (should (drgnx-session-open-folder dir))
          (should (= raised 0))
          (should (eq focused-in (selected-frame)))
          (should (equal roots (list dir)))
          (setq term "initial_terminal")
          (let ((noninteractive nil))   ; batch Emacs's initial terminal is a `tty' workbench; a daemon's is `initial'
            (drgnx-session-open-folder dir))
          (should (= raised 1)))
      (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
      (delete-directory dir t))))

(ert-deftest drgnx-session/no-window-in-batch ()
  ;; A daemon's own terminal frame is not a window (batch Emacs counts as a terminal workbench, so the test says it
  ;; is not batch: the classifier then calls the frame `initial').
  (let ((noninteractive nil))
    (should-not (drgnx-session-gui-frame-p))
    (should-not (drgnx-session--windows))))

(defun drgnx-session-test--repo (root name file)
  "A git repo NAME under ROOT holding FILE; its directory."
  (let ((dir (file-name-as-directory (expand-file-name name root))))
    (make-directory dir t)
    (let ((default-directory dir)) (call-process "git" nil nil nil "init" "-q"))
    (write-region "x = 1\n" nil (expand-file-name file dir) nil 'silent)
    dir))

(ert-deftest drgnx-session/opening-a-folder-makes-it-the-project ()
  ;; The real Explorer in a one-editor layout.  After `drgnx DIR' quick open and project search (which follow the
  ;; selected window's buffer) work in DIR's project — also when a file of another project was in front.
  (drgnx-test-with-state
    (let* ((root (file-name-as-directory (make-temp-file "drgnx-session-folder" t)))
           (a (drgnx-session-test--repo root "projA" "a.py"))
           (b (drgnx-session-test--repo root "My Project" "café.py"))
           (project-list-file (expand-file-name "projects" root))
           (drgnx-wb--sections nil) (drgnx-explorer--roots nil)
           (raised 0) buf)
      (unwind-protect
          (cl-letf (((symbol-function 'drgnx-session-raise) (lambda () (cl-incf raised))))
            (delete-other-windows)
            (drgnx-explorer-setup)
            (setq buf (find-file-noselect (expand-file-name "a.py" a)))
            (switch-to-buffer buf)                    ; project A's file in front, as after a restore
            (let ((noninteractive nil))         ; as a daemon's initial frame: bin/drgnx's graphical path raises
              (drgnx-session-open-folder (directory-file-name b)))
            (should (= raised 1))
            (with-current-buffer (window-buffer (selected-window))
              (should (equal (buffer-name) drgnx-explorer-buffer-name))   ; the Explorer is selected
              (let ((p (project-current nil)))
                (should p)
                (should (equal (expand-file-name (project-root p)) b))
                (should (member (expand-file-name "café.py" b) (project-files p)))))
            (should (drgnx-wb-sidebar-showing-p))
            ;; the other folder: first now, the first one stays
            (drgnx-session-open-folder a)
            (should (equal (drgnx-explorer-roots) (list a b)))
            (with-current-buffer (window-buffer (selected-window))
              (should (equal (expand-file-name (project-root (project-current nil))) a))))
        (when (buffer-live-p buf) (kill-buffer buf))
        (drgnx-wb-hide-sidebar)
        (delete-other-windows)
        (drgnx-explorer-set-roots nil)
        (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
        (delete-directory root t)))))

(ert-deftest drgnx-session/an-unsaved-untitled-buffer-is-offered-and-never-lost ()
  ;; Nothing of drgnx-session stubbed: the real `save-some-buffers' offers New Untitled's buffer (its question,
  ;; `map-y-or-n-p', records the buffers and declines), the buffer still counts as unsaved, "no" keeps drgnx.
  (load (expand-file-name "modules/core/drgnx-basics" drgnx-dir) nil t)
  (let ((u (drgnx-basics-new-untitled)) offered killed (asked 0))
    (unwind-protect
        (progn
          (with-current-buffer u (insert "typed, never saved"))
          (cl-letf (((symbol-function 'map-y-or-n-p) (lambda (_prompter _actor list &rest _) (setq offered list) 0))
                    ((symbol-function 'yes-or-no-p) (lambda (&rest _) (cl-incf asked) nil))
                    ((symbol-function 'kill-emacs) (lambda (&rest _) (setq killed t))))
            (drgnx-session-quit))
          (should (memq u offered))
          (should (memq u (drgnx-session--unsaved-buffers)))
          (should (= asked 1))
          (should-not killed)
          (should (buffer-live-p u)))
      (with-current-buffer u (set-buffer-modified-p nil))
      (kill-buffer u))))

(ert-deftest drgnx-session/the-server-starts-only-where-drgnx-path-should-reach-it ()
  (require 'server)
  (let (started)
    (cl-letf (((symbol-function 'server-start) (lambda (&rest _) (setq started server-name)))
              ((symbol-function 'server-running-p) (lambda (&rest _) nil))
              ((symbol-function 'daemonp) #'ignore))
      (let ((server-name "server") (server-process nil) (initial-window-system 'x) (process-environment process-environment))
        (setenv "DRGNX_UI_RUN") (setenv "DRGNX_SAFE")
        (drgnx-session-start-server)          ; batch Emacs: never
        (should-not started)
        (let ((noninteractive nil))
          (drgnx-session-start-server)
          (should (equal started "drgnx"))
          (setq started nil)
          (cl-letf (((symbol-function 'server-running-p) (lambda (&rest _) t)))   ; another drgnx has the name
            (drgnx-session-start-server))
          (should-not started)
          (setenv "DRGNX_SAFE" "1")
          (drgnx-session-start-server)
          (should-not started))))))


(ert-deftest drgnx-session/running-programs-refreshes-terminal-query-flags-first ()
  ;; A terminal's flag is set by its module (a shell asks, an idle prompt does not); the quit question asks the module
  ;; to bring the flags up to date first — when the module is there.
  (let ((p (make-process :name "drgnx-session-test-term" :command '("sleep" "30") :noquery t)))
    (unwind-protect
        (progn
          (should-not (memq p (drgnx-session--running-programs)))                  ; no terminal module: as it was
          (cl-letf (((symbol-function 'drgnx-terminal-eat-refresh-query-flags)
                     (lambda () (set-process-query-on-exit-flag p t))))
            (should (memq p (drgnx-session--running-programs)))))
      (delete-process p))))

(ert-deftest drgnx-session/a-failing-terminal-refresh-does-not-stop-the-quit-question ()
  (let ((p (make-process :name "drgnx-session-test-term2" :command '("sleep" "30") :noquery nil)))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-terminal-eat-refresh-query-flags) (lambda () (error "eat is gone"))))
          (should (memq p (drgnx-session--running-programs))))
      (delete-process p))))


(ert-deftest drgnx-session/windows-ask-the-classifier ()
  ;; the frames that count as windows are the visible workbench frames (gui or tty), whatever else the frame list holds
  (let ((kinds '((kx-gui . gui) (kx-tty . tty) (kx-initial . initial) (kx-child . child) (kx-other . other)
                 (kx-hidden . tty))))
    (cl-letf (((symbol-function 'frame-list) (lambda () '(kx-hidden kx-other kx-child kx-initial kx-tty kx-gui)))
              ((symbol-function 'drgnx-state-frame-kind) (lambda (f) (cdr (assq f kinds))))
              ((symbol-function 'frame-visible-p) (lambda (f) (not (eq f 'kx-hidden)))))
      (should (equal (drgnx-session--windows) '(kx-tty kx-gui))))))

;;;; `drgnx open' never asks about a file that changed on disk (editor/large-files off: not set up here)

(require 'server)
(require 'drgnx-guard)

(defvar drgnx-session-test--asked nil "The questions asked while `drgnx-session-test--never-asks' runs.")

(defun drgnx-session-test--no-question (&rest args)
  "In place of every question while `drgnx-session-test--never-asks' runs: record ARGS and fail."
  (push args drgnx-session-test--asked)
  (error "A question was asked: %S" args))

(defmacro drgnx-session-test--never-asks (&rest body)
  "BODY with `drgnx-guard-mode' on and every question failing; it fails when one was asked, even if caught."
  (declare (indent 0) (debug t))
  `(let ((was drgnx-guard-mode) (drgnx-session-test--asked nil))
     (unless was (drgnx-guard-mode 1))
     (dolist (f '(read-multiple-choice y-or-n-p yes-or-no-p))
       (advice-add f :override #'drgnx-session-test--no-question '((depth . 100))))
     (unwind-protect (prog1 (progn ,@body) (should-not drgnx-session-test--asked))
       (dolist (f '(read-multiple-choice y-or-n-p yes-or-no-p))
         (advice-remove f #'drgnx-session-test--no-question))
       (unless was (drgnx-guard-mode -1)))))

(defun drgnx-session-test--serve (files nowait commands)
  "Run `server-execute' as the server's process filter does, for a fake client: FILES ((NAME) …), NOWAIT,
COMMANDS (functions, as -eval forms are run).  Return the errors it sent the client."
  (let ((proc (make-pipe-process :name "drgnx-session-test-client" :noquery t))
        (errors nil)
        (this-command 'find-file)
        (pre-command-hook nil) (post-command-hook nil) (server-visit-hook nil) (server-switch-hook nil)
        (server-after-make-frame-hook nil) (server-client-instructions nil) (file-name-history nil))
    (unwind-protect
        (cl-letf (((symbol-function 'server-delete-client) #'ignore)
                  ((symbol-function 'server-switch-buffer) #'ignore)
                  ((symbol-function 'server-return-error) (lambda (_proc err) (push err errors))))
          (server-execute proc files nowait commands nil nil nil nil))
      (let ((buf (process-buffer proc)))
        (delete-process proc)
        (when (buffer-live-p buf) (kill-buffer buf))))
    errors))

(defmacro drgnx-session-test--changed (bindings &rest body)
  "BODY with each (VAR NAME TEXT NEW [EDIT]) of BINDINGS: VAR a buffer visiting file NAME (a temp folder) holding
TEXT (EDIT inserted at its end: unsaved changes), the file then written again with NEW, its time moved on (it
changed on disk).  The buffers and folder go after."
  (declare (indent 1))
  `(let* ((dir (file-name-as-directory (make-temp-file "drgnx-session-open" t)))
          (kill-buffer-query-functions nil)
          ,@(mapcar (lambda (b)
                      `(,(car b) (let ((f (expand-file-name ,(nth 1 b) dir)))
                                   (write-region ,(nth 2 b) nil f nil 'silent)
                                   (prog1 (find-file-noselect f)
                                     (when ,(nth 4 b)
                                       (with-current-buffer (get-file-buffer f)
                                         (goto-char (point-max))
                                         (insert ,(nth 4 b))))
                                     (write-region ,(nth 3 b) nil f nil 'silent)
                                     (set-file-times f (time-add nil 10))))))
                    bindings))
     (unwind-protect (progn ,@body)
       (dolist (b (buffer-list))
         (when (string-prefix-p dir (or (buffer-local-value 'buffer-file-name b) ""))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (delete-directory dir t))))

(ert-deftest drgnx-session/loading-advises-the-servers-visit ()
  ;; the core is never turned off: the advice is there as soon as drgnx-session is (drgnx requires it)
  (should (advice-member-p #'drgnx-session--visit-unasked 'server-visit-files)))

(ert-deftest drgnx-session/drgnx-open-reverts-a-changed-file-unasked ()
  ;; `drgnx open a.txt' while an unmodified buffer holds it and the file changed: Emacs's `server-visit-files'
  ;; reverts it with (revert-buffer t nil), which asks "Revert buffer from file …?"; drgnx reverts it unasked
  (should-not (advice-member-p 'drgnx-editor/large-files--server 'server-execute))
  (drgnx-session-test--changed ((b "a.txt" "one\n" "two\n"))
    (drgnx-session-test--never-asks
      (should-not (drgnx-session-test--serve (list (list (buffer-file-name b))) t nil)))
    (with-current-buffer b
      (should (equal (buffer-string) "two\n"))
      (should (verify-visited-file-modtime b))
      (should-not (buffer-modified-p)))))

(ert-deftest drgnx-session/drgnx-open-t-reverts-a-changed-file-unasked ()
  ;; `drgnx -t a.txt' sends -e (drgnx-session-open-file "a.txt"): `find-file' would ask "Reread from disk?"
  (drgnx-session-test--changed ((b "a.txt" "one\n" "two\n"))
    (drgnx-session-test--never-asks
      (should-not (drgnx-session-test--serve
                   nil nil (list (lambda () (should (eq (drgnx-session-open-file (buffer-file-name b)) b)))))))
    (should (equal (with-current-buffer b (buffer-string)) "two\n"))))

(ert-deftest drgnx-session/drgnx-open-leaves-a-modified-changed-file-and-says-so ()
  ;; unsaved changes are never reverted silently, nor asked about: left as they are, the echo area says so
  (drgnx-session-test--changed ((b "a.txt" "one\n" "two\n" "mine\n"))
    (let ((said nil))
      (cl-letf* ((orig (symbol-function 'message))
                 ((symbol-function 'message)
                  (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) said)) (apply orig fmt args))))
        (drgnx-session-test--never-asks
          (should-not (drgnx-session-test--serve (list (list (buffer-file-name b))) t nil))
          (should-not (drgnx-session-test--serve
                       nil nil (list (lambda () (drgnx-session-open-file (buffer-file-name b))))))))
      (with-current-buffer b
        (should (equal (buffer-string) "one\nmine\n"))
        (should (buffer-modified-p))
        (should-not (verify-visited-file-modtime b)))   ; still stale: saving it asks, as a command may
      (should (= 2 (cl-count "a.txt changed on disk; its buffer has unsaved changes and is left as it is"
                             said :test #'equal))))))

(ert-deftest drgnx-session/drgnx-open-reverts-a-file-that-grew-large-unasked ()
  ;; without editor/large-files a file that grew past Emacs's own large-file threshold is reverted as any other
  (let ((large-file-warning-threshold 1000))
    (drgnx-session-test--changed ((b "big.log" "one\n" (make-string 4000 ?x)))
      (drgnx-session-test--never-asks
        (should-not (drgnx-session-test--serve (list (list (buffer-file-name b))) t nil)))
      (should (= (buffer-size b) 4000)))))

;;; session-test.el ends here
