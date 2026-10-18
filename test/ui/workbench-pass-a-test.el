;;; workbench-pass-a-test.el --- GUI tests: C-x b's order, the gio trash fallback, compact folders (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; DEFERRED A-40: three fixes of pass A that only batch tests had seen.  Here they run on real frames with real keys,
;; clicks and processes: (1) C-x b lists the window's buffers first (M3e-2); (2) trashing on tmpfs falls back to the Emacs
;; trash and keeps the buffers until the file is gone (M3b-15); (3) a chain of open single folders is one row (M3b-1).
;; Every folder is a temp dir; the trash is a temp HOME's (never ~); the failing `gio' is a script in a temp dir.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-uitest)

(defconst drgnx-pass-a-ui-test--repo                        ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-pass-a-ui-test--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-pass-a-ui-test--repo))
(require 'drgnx)
(require 'drgnx-wb)
(require 'drgnx-area)
(require 'drgnx-groups)
(require 'drgnx-rules)
(require 'drgnx-frames)
(require 'drgnx-explorer)

(defun drgnx-pass-a-ui-test--wait (pred &optional secs)
  "Wait (SECS, default 15) until PRED holds; `sit-for' runs the process sentinels from this timer-started test (`accept-process-output' does not).  PRED's last value."
  (let ((deadline (+ (float-time) (or secs 15))))
    (while (and (not (funcall pred)) (< (float-time) deadline)) (sit-for 0.05)))
  (funcall pred))

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

(defmacro drgnx-pass-a-ui-test--with-explorer (root dir show &rest body)
  "BODY with ROOT bound to the Explorer's root, the temp directory DIR (a function of nothing returning it).
SHOW non-nil: the sidebar is open in the root frame, whose window layout is restored after."
  (declare (indent 3))
  `(let* ((,root (file-name-as-directory (funcall ,dir)))
          (frame (drgnx-uitest-root-frame))
          (config (with-selected-frame frame (current-window-configuration)))
          (drgnx-wb--sections nil) (drgnx-signal--editor-window nil) (drgnx-explorer--pressed nil)
          (drgnx-explorer--selection nil) (drgnx-explorer--anchor nil) (drgnx-explorer--focused-before nil)
          (drgnx-explorer--roots nil) (_cleared (drgnx-cache--clear 'explorer-listing))
          (drgnx-explorer--expanded (make-hash-table :test #'equal)))
     (unwind-protect
         (with-selected-frame frame
           (delete-other-windows)
           (drgnx-explorer-setup)
           (drgnx-explorer-set-roots (list ,root))
           (when ,show (drgnx-wb-show-sidebar) (redisplay t))
           ,@body)
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

(defun drgnx-pass-a-ui-test--rows ()
  "The Explorer's rows below the root, as (DEPTH TEXT): the text the row shows, without its chevron."
  (with-current-buffer drgnx-explorer-buffer-name
    (save-excursion
      (goto-char (point-min))
      (let (rows)
        (while (not (eobp))
          (when-let* ((depth (drgnx-explorer-depth-at (point))) ((> depth 0)))
            (push (list depth (string-trim (replace-regexp-in-string "\\`[│ ]*[▸▾]?" "" (buffer-substring-no-properties (pos-bol) (pos-eol)))))
                  rows))
          (forward-line 1))
        (nreverse rows)))))

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
          (should (equal (drgnx-pass-a-ui-test--rows) '((1 "docs") (1 "src") (1 "README.md"))))
          ;; each click opens the folder shown last, and the next folder joins its row
          (drgnx-pass-a-ui-test--click "src")
          (should (equal (drgnx-pass-a-ui-test--rows) '((1 "docs") (1 "src/app") (1 "README.md"))))
          (drgnx-pass-a-ui-test--click "src/app")
          (should (equal (drgnx-pass-a-ui-test--rows) '((1 "docs") (1 "src/app/deep") (1 "README.md"))))
          (drgnx-pass-a-ui-test--click "src/app/deep")
          (should (equal (drgnx-pass-a-ui-test--rows) '((1 "docs") (1 "src/app/deep/a") (1 "README.md"))))
          (redisplay t)
          (should (drgnx-uitest-target-xy drgnx-explorer-buffer-name "src/app/deep/a"))   ; it is on screen, as one line
          ;; the last folder opens: its file is a row below the one chain row
          (drgnx-pass-a-ui-test--click "src/app/deep/a")
          (should (equal (drgnx-pass-a-ui-test--rows) '((1 "docs") (1 "src/app/deep/a") (2 "leaf.txt") (1 "README.md"))))
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
  "Delete PATH from the Explorer as the Delete command does (the prompt answered yes)."
  (with-current-buffer (drgnx-explorer--buffer)
    (goto-char (or (drgnx-explorer--row-pos path) (error "No row for %s" path)))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (drgnx-explorer-delete))))

(defun drgnx-pass-a-ui-test--gio-running-p ()
  (seq-some (lambda (p) (and (string-prefix-p "drgnx-gio-trash" (process-name p)) (process-live-p p))) (process-list)))

(ert-deftest drgnx-ui-pass-a/a-failing-gio-falls-back-and-the-buffer-stays-until-then ()
  (drgnx-pass-a-ui-test--with-temp-home home
    (let* ((shm (drgnx-pass-a-ui-test--shm-dir)) (bin (make-temp-file "drgnx-pass-a-bin" t)))
      (unwind-protect
          (drgnx-pass-a-ui-test--with-explorer root (lambda () shm) nil
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
              (should-not (member "notes.txt" (mapcar #'cadr (drgnx-pass-a-ui-test--rows))))))
        (drgnx-pass-a-ui-test--kill-visiting (expand-file-name "notes.txt" shm))
        (delete-directory bin t)))))

(ert-deftest drgnx-ui-pass-a/when-gio-and-the-fallback-both-fail-the-buffer-and-file-stay ()
  (drgnx-pass-a-ui-test--with-temp-home home
    (let* ((shm (drgnx-pass-a-ui-test--shm-dir)) (bin (make-temp-file "drgnx-pass-a-bin" t)))
      (ignore home)
      (unwind-protect
          (drgnx-pass-a-ui-test--with-explorer root (lambda () shm) nil
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
          (drgnx-pass-a-ui-test--with-explorer root (lambda () shm) nil
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
