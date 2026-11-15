;;; workbench-pass-a-test.el --- GUI tests: C-x b's order, the gio trash fallback, compact folders (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; DEFERRED A-40: three fixes of pass A that only batch tests had seen.  Here they run on real frames with real keys,
;; clicks and processes: (1) C-x b lists the window's buffers first (M3e-2); (2) trashing on tmpfs falls back to the Emacs
;; trash and keeps the buffers until the file is gone (M3b-15); (3) a chain of open single folders is one row (M3b-1).
;; Every folder is a temp dir; the trash is a temp HOME's (never ~); the failing `gio' is a script in a temp dir.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-pass-a-ui-test--repo                        ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-pass-a-ui-test--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-pass-a-ui-test--repo))
(add-to-list 'load-path (expand-file-name "harness" drgnx-pass-a-ui-test--repo))
(load (expand-file-name "test/fixtures/rows-demo-fixture" drgnx-pass-a-ui-test--repo) nil t)
(require 'drgnx)
(require 'drgnx-wb)
(require 'drgnx-area)
(require 'drgnx-groups)
(require 'drgnx-rules)
(require 'drgnx-frames)
(require 'drgnx-explorer)
(declare-function nidhogg-view-get "nidhogg-views" (h what &optional arg arg2))

(defun drgnx-pass-a-ui-test--wait (pred &optional secs)
  "Wait (SECS, default 15) until PRED holds; `drgnx-test-wait' runs the process sentinels and timers.  PRED's value, nil
at the deadline (the caller says what is off)."
  (ignore-error ert-test-failed (drgnx-test-wait pred :secs (or secs 15))))

(defun drgnx-pass-a-ui-test--shot (dir name)
  "Capture the root frame into DIR and keep it as NAME in the session's temp dir; print where."
  (let ((shot (plist-get (drgnx-uitest-capture dir) :root)) (out (expand-file-name name temporary-file-directory)))
    (should (file-exists-p shot))
    (copy-file shot out t)
    (message "pass-a screenshot: %s" out)
    out))

;;;; (1) C-x b: this window's buffers first (M3e-2)

(ert-deftest drgnx-ui-pass-a/c-x-b-lists-the-windows-buffers-first ()
  ;; A second window has three tabs (it shows the first, which C-x b leaves out); another buffer is in no tab.  The names are chosen so that the alphabet alone would
  ;; put the stranger first.  The keys go through the real command loop of that window, and the completions are read from
  ;; the *Completions* buffer the minibuffer shows.
  (let* ((was drgnx-frames-mode) (read-buffer-function nil) (completion-category-overrides nil)
         (shown (generate-new-buffer "gui-zshown")) (mine1 (generate-new-buffer "gui-zmine-1")) (mine2 (generate-new-buffer "gui-zmine-2"))
         (stranger (generate-new-buffer "gui-aother"))
         (aux (make-frame '((name . "drgnx pass-a aux") (width . 100) (height . 24))))
         (listed nil) (grab (lambda ()
                              (when-let* ((b (get-buffer "*Completions*")))
                                (setq listed (with-current-buffer b (buffer-substring-no-properties (point-min) (point-max))))))))
    (unwind-protect
        (progn
          (drgnx-frames-mode 1)
          (with-selected-frame aux
            (let ((w (frame-first-window aux)))
              (set-window-buffer w shown)
              (set-window-parameter w 'drgnx-tabs (list shown mine1 mine2)))
            (should (eq (drgnx-frame-role aux) 'aux))
            (should (equal (drgnx-frame-buffers aux) (list shown mine1 mine2)))   ; the premise: three buffers are this window's
            (add-hook 'minibuffer-exit-hook grab -90)
            (drgnx-test-wait-stages)
            (unwind-protect
                (drgnx-uitest-run (drgnx-uitest-key-events "C-x b TAB C-g"))
              (remove-hook 'minibuffer-exit-hook grab)))
          (unless listed (ert-fail "no *Completions* buffer was shown"))
          (let ((p1 (string-search "gui-zmine-1" listed)) (p2 (string-search "gui-zmine-2" listed))
                (po (string-search "gui-aother" listed)) (pm (string-search "*Messages*" listed)))
            (unless (and p1 p2 po) (ert-fail (format "*Completions* was %S" listed)))   ; sorted, never filtered: the stranger is a candidate
            (should (< p1 p2 po))
            (should (and pm (< p2 pm))))                       ; …and so is every other buffer, after this window's
          (message "pass-a C-x b: %S" (split-string listed "[ \n]+" t)))
      (drgnx-frames-mode (if was 1 -1))
      (when (frame-live-p aux) (delete-frame aux))
      (mapc #'kill-buffer (list shown mine1 mine2 stranger)))))

;;;; The Explorer on a real frame, rooted in a temp dir
;; With Sjá (Nidhogg's line) the hub lists the folders (`drgnx-explorer--hub-lists-p'): the Explorer is a hub-fed view
;; whose rows come from a real hub (`drgnx-rows-demo-with', a test-hooks build) some time after each change, so every
;; row of these tests waits for the rows it expects; and the hub draws a view only where a window shows it, so the
;; Explorer is shown (SHOW) in every row.  Without Sjá the Explorer lists in Lisp, at once.

(defun drgnx-pass-a-ui-test--hub-p ()
  "Whether the Explorer is to be the hub's view here: this Emacs has Sjá."
  (fboundp 'nidhogg-view--call))

(defmacro drgnx-pass-a-ui-test--with-explorer (root dir show &rest body)
  "BODY with ROOT bound to the Explorer's root, the temp directory DIR (a function of nothing returning it).
SHOW non-nil: the sidebar is open in the root frame, whose window layout is restored after.  With Sjá, a real hub
lists the folders and the Explorer is its view (BODY fails at once otherwise)."
  (declare (indent 3))
  `(let* ((,root (file-name-as-directory (funcall ,dir)))
          (frame (drgnx-uitest-root-frame))
          (config (with-selected-frame frame (current-window-configuration)))
          (drgnx-wb--sections nil) (drgnx-explorer--pressed nil)
          (drgnx-explorer--selection nil) (drgnx-explorer--anchor nil) (drgnx-explorer--focused-before nil)
          (drgnx-explorer--roots nil) (_cleared (drgnx-cache--clear 'explorer-listing))
          (drgnx-explorer--hub-view nil) (drgnx-explorer--window-asker nil)
          (drgnx-explorer--expanded (make-hash-table :test #'equal))
          (run (lambda ()
                 (with-selected-frame frame
                   (delete-other-windows)
                   (drgnx-explorer-setup)
                   (drgnx-explorer-set-roots (list ,root))
                   (when ,show (drgnx-wb-show-sidebar) (redisplay t))
                   (when (drgnx-pass-a-ui-test--hub-p)
                     (with-current-buffer (drgnx-explorer--buffer) (drgnx-explorer--render))   ; attaches, subscribes
                     (unless (drgnx-explorer--rows-p) (ert-fail "with Sjá the Explorer is not the hub's view"))
                     (drgnx-view-env-update drgnx-explorer-hub-view-name))
                   ,@body))))
     (unwind-protect
         (if (drgnx-pass-a-ui-test--hub-p) (drgnx-rows-demo-with (funcall run)) (funcall run))
       (with-selected-frame frame
         (when ,show (ignore-errors (drgnx-wb-hide-sidebar)))
         (delete-other-windows)
         (ignore-errors (set-window-configuration config)))
       (drgnx-explorer-set-roots nil)                         ; its watches go
       (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
       (delete-directory ,root t))))

(defun drgnx-pass-a-ui-test--tree (root paths)
  "Create PATHS under ROOT (a trailing / makes a directory)."
  (dolist (p paths)
    (let ((f (expand-file-name p root)))
      (if (string-suffix-p "/" p) (make-directory f t)
        (make-directory (file-name-directory f) t)
        (write-region "" nil f nil 'silent)))))

;;;; (3) A chain of open single folders is one row (M3b-1)

(defun drgnx-pass-a-ui-test--depth (pos)
  "The depth of the Explorer's row at POS (0 for a root), or nil off a row.  On the hub's view, the row's ancestors
in the model (a joined chain of folders is one node, the last folder's)."
  (if (drgnx-explorer--rows-p)
      (when-let* ((id (drgnx-explorer-node-at pos)) (h (drgnx-view-patch-handle drgnx-view-patch)))
        (let ((d 0)) (while (setq id (nidhogg-view-get h 'parent id)) (setq d (1+ d))) d))
    (drgnx-explorer-depth-at pos)))

(defun drgnx-pass-a-ui-test--rows ()
  "The Explorer's rows below the root, as (DEPTH TEXT): the text the row shows, without its chevron."
  (with-current-buffer drgnx-explorer-buffer-name
    (save-excursion
      (goto-char (point-min))
      (let (rows)
        (while (not (eobp))
          (when-let* ((depth (drgnx-pass-a-ui-test--depth (point))) ((> depth 0)))
            (push (list depth (string-trim (replace-regexp-in-string "\\`[│ ]*[▸▾]?" "" (buffer-substring-no-properties (pos-bol) (pos-eol)))))
                  rows))
          (forward-line 1))
        (nreverse rows)))))

(defun drgnx-pass-a-ui-test--rows-are (want)
  "The Explorer's rows (`drgnx-pass-a-ui-test--rows') become WANT: waited for (the hub's come later), then checked."
  (drgnx-pass-a-ui-test--wait (lambda () (equal (drgnx-pass-a-ui-test--rows) want)))
  (should (equal (drgnx-pass-a-ui-test--rows) want)))

(defun drgnx-pass-a-ui-test--row-shown (path)
  "Wait until the Explorer has a row for PATH; fail if it does not come."
  (unless (drgnx-pass-a-ui-test--wait (lambda () (with-current-buffer (drgnx-explorer--buffer) (drgnx-explorer--row-start path))))
    (ert-fail (list "no row for" path :rows (drgnx-pass-a-ui-test--rows)))))

(defun drgnx-pass-a-ui-test--click (text)
  "Click the row showing TEXT in the Explorer window, as a person would; wait until it settles."
  (let ((xy (drgnx-uitest-target-xy drgnx-explorer-buffer-name text)))
    (should (eq (plist-get (drgnx-uitest-run (drgnx-uitest-click-events (drgnx-uitest-posn (car xy) (cdr xy)))) :settled) t))))

(ert-deftest drgnx-ui-pass-a/a-chain-of-single-folders-is-one-row ()
  (let ((shots (make-temp-file "drgnx-pass-a-shot" t)))
    (unwind-protect
        (drgnx-pass-a-ui-test--with-explorer root (lambda () (make-temp-file "drgnx-pass-a-compact" t)) t
          (drgnx-pass-a-ui-test--tree root '("README.md" "docs/guide.md" "src/app/deep/a/leaf.txt"))
          (drgnx-explorer-refresh)
          (redisplay t)
          (should drgnx-explorer-compact-folders)
          (drgnx-pass-a-ui-test--rows-are '((1 "docs") (1 "src") (1 "README.md")))
          ;; each click opens the folder shown last, and the next folder joins its row
          (drgnx-pass-a-ui-test--click "src")
          (drgnx-pass-a-ui-test--rows-are '((1 "docs") (1 "src/app") (1 "README.md")))
          (drgnx-pass-a-ui-test--click "src/app")
          (drgnx-pass-a-ui-test--rows-are '((1 "docs") (1 "src/app/deep") (1 "README.md")))
          (drgnx-pass-a-ui-test--click "src/app/deep")
          (drgnx-pass-a-ui-test--rows-are '((1 "docs") (1 "src/app/deep/a") (1 "README.md")))
          (redisplay t)
          (should (drgnx-uitest-target-xy drgnx-explorer-buffer-name "src/app/deep/a"))   ; it is on screen, as one line
          ;; the last folder opens: its file is a row below the one chain row
          (drgnx-pass-a-ui-test--click "src/app/deep/a")
          (drgnx-pass-a-ui-test--rows-are '((1 "docs") (1 "src/app/deep/a") (2 "leaf.txt") (1 "README.md")))
          (drgnx-pass-a-ui-test--shot shots "pass-a-compact-folders.png"))
      (delete-directory shots t))))

;;;; (2) Trashing across devices: gio, then the Emacs trash, buffers kept until the file is gone (M3b-15)

(defconst drgnx-pass-a-ui-test--shm "/dev/shm/" "Another filesystem than the temp HOME's, where one is (Linux: tmpfs).")

(defun drgnx-pass-a-ui-test--shm-dir ()
  "A new temp directory on tmpfs; skips the test where there is none, or it is the temp HOME's filesystem."
  (unless (file-writable-p drgnx-pass-a-ui-test--shm) (ert-skip "no tmpfs at /dev/shm"))
  (when (equal (file-attribute-device-number (file-attributes drgnx-pass-a-ui-test--shm 'integer))
               (file-attribute-device-number (file-attributes temporary-file-directory 'integer)))
    (ert-skip "/dev/shm is the temp directory's filesystem"))
  (make-temp-file (concat drgnx-pass-a-ui-test--shm "drgnx-pass-a-") t))

(defmacro drgnx-pass-a-ui-test--with-temp-home (home &rest body)
  "BODY with HOME (a temp dir on the session's filesystem) as the home and the data home: the trash is there, not in ~."
  (declare (indent 1))
  `(let* ((,home (file-name-as-directory (make-temp-file "drgnx-pass-a-home" t)))
          (default-directory (expand-file-name default-directory)) ; absolute before HOME changes: "~/x" would mean the temp home
          (process-environment (append (list (concat "HOME=" ,home)
                                             (concat "XDG_DATA_HOME=" (expand-file-name ".local/share" ,home)))
                                       process-environment))
          (abbreviated-home-dir nil) (trash-directory nil))
     (unwind-protect (progn ,@body) (delete-directory ,home t))))

(defun drgnx-pass-a-ui-test--fake-gio (dir &optional gated)
  "A `gio' in DIR that says it cannot find a trash directory (as it does on tmpfs) and fails.
GATED: it first waits until the file `go' exists in DIR (the test makes it), so \"gio is still running\" is a fact
of the test's own making, not a race with a delay."
  (let ((script (expand-file-name "gio" dir)))
    (with-temp-file script
      (insert (format "#!/bin/sh\n%secho \"gio: Unable to find or create trash directory for $3\" >&2\nexit 1\n"
                      (if gated (format "while [ ! -e '%s' ]; do sleep 0.1; done\n" (expand-file-name "go" dir)) ""))))
    (set-file-modes script #o755)
    (concat (file-name-as-directory dir) "gio")))

(defun drgnx-pass-a-ui-test--kill-visiting (file)
  "Kill the buffer visiting FILE, if there is one (the file may be gone by now)."
  (when-let* ((b (find-buffer-visiting file)))
    (let ((kill-buffer-query-functions nil)) (kill-buffer b))))

(defun drgnx-pass-a-ui-test--delete (path)
  "Delete PATH from the Explorer as the Delete command does on its row (the prompt answered yes), once the row is there."
  (drgnx-pass-a-ui-test--row-shown path)
  (with-current-buffer (drgnx-explorer--buffer)
    (goto-char (drgnx-explorer--row-start path))
    (should (equal (drgnx-explorer-node-at (point)) path))           ; the command acts on this row's file
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (drgnx-explorer-delete))))

(defun drgnx-pass-a-ui-test--gio-running-p ()
  (seq-some (lambda (p) (and (string-prefix-p "drgnx-gio-trash" (process-name p)) (process-live-p p))) (process-list)))

(ert-deftest drgnx-ui-pass-a/a-failing-gio-falls-back-and-the-buffer-stays-until-then ()
  (drgnx-pass-a-ui-test--with-temp-home home
    (let* ((shm (drgnx-pass-a-ui-test--shm-dir)) (bin (make-temp-file "drgnx-pass-a-bin" t)))
      (unwind-protect
          (drgnx-pass-a-ui-test--with-explorer root (lambda () shm) t
            (drgnx-pass-a-ui-test--fake-gio bin t)
            (let* ((exec-path (cons bin exec-path))
                   (process-environment (cons (concat "PATH=" bin ":" (getenv "PATH")) process-environment))
                   (file (expand-file-name "notes.txt" root)) (buf nil))
              (should (equal (executable-find "gio") (expand-file-name "gio" bin)))
              (write-region "keep me\n" nil file nil 'silent)
              (should (drgnx-explorer--trash-cross-device-p file))   ; the premise: gio's case
              (drgnx-explorer-refresh)
              (setq buf (find-file-noselect file))
              (drgnx-pass-a-ui-test--delete file)
              ;; gio is still running (it waits for the `go' file): nothing has happened to the file or its buffer
              (unless (drgnx-pass-a-ui-test--gio-running-p)
                (ert-fail (format "no gio: file %s buffer %s procs %S home-trash %S trash-directory %S cross %S"
                                  (file-exists-p file) (buffer-live-p buf) (mapcar #'process-name (process-list))
                                  (ignore-errors (directory-files-recursively home "notes"))
                                  trash-directory (drgnx-explorer--trash-cross-device-p file))))
              (should (file-exists-p file))
              (should (buffer-live-p buf))
              (write-region "" nil (expand-file-name "go" bin) nil 'silent)   ; let gio fail now
              ;; gio fails: the Emacs trash takes the file across the filesystems, and only then the buffer goes
              (should (drgnx-pass-a-ui-test--wait (lambda () (not (buffer-live-p buf)))))
              (should-not (file-exists-p file))
              (should (directory-files (expand-file-name ".local/share/Trash/files" home) nil "notes\\.txt"))
              (drgnx-pass-a-ui-test--wait (lambda () (not (member "notes.txt" (mapcar #'cadr (drgnx-pass-a-ui-test--rows))))))
              (should-not (member "notes.txt" (mapcar #'cadr (drgnx-pass-a-ui-test--rows))))))
        (drgnx-pass-a-ui-test--kill-visiting (expand-file-name "notes.txt" shm))
        (delete-directory bin t)))))

(ert-deftest drgnx-ui-pass-a/when-gio-and-the-fallback-both-fail-the-buffer-and-file-stay ()
  (drgnx-pass-a-ui-test--with-temp-home home
    (let* ((shm (drgnx-pass-a-ui-test--shm-dir)) (bin (make-temp-file "drgnx-pass-a-bin" t)))
      (ignore home)
      (unwind-protect
          (drgnx-pass-a-ui-test--with-explorer root (lambda () shm) t
            (drgnx-pass-a-ui-test--fake-gio bin)
            (let* ((exec-path (cons bin exec-path))
                   (process-environment (cons (concat "PATH=" bin ":" (getenv "PATH")) process-environment))
                   (file (expand-file-name "unsaved.txt" root)) (buf nil) (said nil))
              (write-region "on disk\n" nil file nil 'silent)
              (drgnx-explorer-refresh)
              (setq buf (find-file-noselect file))
              (cl-letf (((symbol-function 'drgnx-explorer--trash-sync) (lambda (_) (error "Trash is full")))
                        ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
                (drgnx-pass-a-ui-test--delete file)
                (should (drgnx-pass-a-ui-test--wait (lambda () (not (drgnx-pass-a-ui-test--gio-running-p)))))
                (unless (drgnx-pass-a-ui-test--wait (lambda () (seq-some (lambda (s) (string-search "Could not move unsaved.txt" s)) said)))
                  (ert-fail (format "no message; said %S, file %s, buffer %s" said (file-exists-p file) (buffer-live-p buf)))))
              (should (file-exists-p file))
              (should (buffer-live-p buf))
              (should (seq-some (lambda (s) (string-search "Unable to find or create trash directory" s)) said))))
        (drgnx-pass-a-ui-test--kill-visiting (expand-file-name "unsaved.txt" shm))
        (delete-directory bin t)))))

(ert-deftest drgnx-ui-pass-a/the-real-gio-on-tmpfs-ends-with-the-file-in-the-trash-and-its-buffer-closed ()
  ;; Whatever this machine's gio does with tmpfs (trash it in a per-mount directory, or refuse and fall back), the file
  ;; ends in a trash and the buffer goes.  The home is a temp one, so gio's home trash is not ~'s.
  (unless (executable-find "gio") (ert-skip "no gio"))
  (drgnx-pass-a-ui-test--with-temp-home home
    (let* ((shm (drgnx-pass-a-ui-test--shm-dir))
           (mount-trash (expand-file-name (format ".Trash-%d" (user-uid)) drgnx-pass-a-ui-test--shm))
           (had-mount-trash (file-exists-p mount-trash))
           (before (and had-mount-trash (directory-files-recursively mount-trash "real"))))
      (unwind-protect
          (drgnx-pass-a-ui-test--with-explorer root (lambda () shm) t
            (let* ((file (expand-file-name "real.txt" root)) (buf nil))
              (write-region "x\n" nil file nil 'silent)
              (drgnx-explorer-refresh)
              (setq buf (find-file-noselect file))
              (drgnx-pass-a-ui-test--delete file)
              (should (drgnx-pass-a-ui-test--wait (lambda () (and (not (buffer-live-p buf)) (not (drgnx-pass-a-ui-test--gio-running-p))))))
              (should-not (file-exists-p file))
              (let ((in-home (directory-files (expand-file-name ".local/share/Trash/files" home) nil "real\\.txt")))
                (message "pass-a real gio on tmpfs: the file went to %s" (if in-home "the Emacs trash (gio refused)" "gio's per-mount trash"))
                (should (or in-home (and (file-directory-p mount-trash) (directory-files-recursively mount-trash "real\\.txt")))))))
        (drgnx-pass-a-ui-test--kill-visiting (expand-file-name "real.txt" shm))
        (if (not had-mount-trash)
            (ignore-errors (delete-directory mount-trash t))
          ;; a trash that was there already: only what this test put in it goes
          (dolist (f (ignore-errors (directory-files-recursively mount-trash "real")))
            (unless (member f before) (ignore-errors (delete-file f)))))))))

;;; workbench-pass-a-test.el ends here
