;;; large-files-test.el --- batch tests: large files — the config, its project file, the decision, the answers -*- lexical-binding: t -*-
;; Every test that reads the config runs under `drgnx-test-with-config' and sets the module up and tears it down
;; (`drgnx-test-with-modules' :strict t).  No large file is ever written: thresholds are fractions of a MiB.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-guard)
(require 'files)
;; loaded before a strict module run: a remote name's `file-remote-p' would load them there, and the opens below
;; load the major modes, the server and decompression
(require 'tramp)
(require 'tramp-cache)
(require 'server)
(require 'so-long)
(require 'python)
(require 'js)
(require 'treesit nil t)
(require 'eglot)                        ; an :override advice on its autoload loads it
(require 'jka-compr)
(require 'display-line-numbers)
(require 'hl-line)
(require 'warnings)
(require 'drgnx-large-file)
(require 'drgnx-persist)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/editor/drgnx-large-files" drgnx-dir) nil t)
;; the status bar is loaded first: the module's segment is defined in its setup when the bar is there
(load (expand-file-name "modules/ui/drgnx-face" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-statusbar" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-dir) nil t)   ; Replace skips a raw buffer
;; a Python mode's first run registers an `eval-after-load' of grep (Emacs 31): here, not in a strict body
(let ((python-indent-guess-indent-offset nil)) (with-temp-buffer (python-mode)))

(defvar drgnx-large-files-chunk-open-function)
(defvar drgnx-large-file-mode)
(defvar drgnx-large-files--header)
(defvar drgnx-chrome-mode)
(defvar drgnx-chrome-header-tail)
(defvar revert-buffer-internal-hook)    ; files.el only declares it

(defmacro drgnx-large-files-test--with (&rest body)
  "BODY with the module editor/large-files set up, in a fresh config folder; torn down after, strictly."
  (declare (indent 0) (debug t))
  `(drgnx-test-with-config
     (drgnx-test-with-modules '(editor/large-files) :strict t
                              ,@body)))

(defun drgnx-large-files-test--project (text)
  "A fresh project folder (under the test's config root) whose .drgnx/large-files.eld holds TEXT; its name."
  (let ((root (file-name-as-directory (make-temp-file (expand-file-name "proj" drgnx-test-config-root) t))))
    (make-directory (expand-file-name "sub" root) t)
    (drgnx-test-config-put 'large-files-project text root)
    root))

;;;; The decision

(ert-deftest drgnx-large-files/decide-table ()
  ;; :ask-above 16 KiB, :chunks-above 64 KiB; sizes below, between and above them
  (let ((th '(:ask-above 16384 :chunks-above 65536 :chunk-size 32768))
        (sizes '(1000 32768 131072))
        ;; (HOW REMEMBERED CHUNKS-OK BELOW BETWEEN ABOVE)
        (rows '((command nil    t   pass (ask . lean) (ask . chunks))
                (command nil    nil pass (ask . lean) (ask . raw))
                (command lean   t   pass lean lean)
                (command lean   nil pass lean lean)
                (command raw    t   pass raw raw)
                (command raw    nil pass raw raw)
                (command chunks t   pass chunks chunks)
                (command chunks nil pass raw raw)
                (auto    nil    t   pass chunks chunks)
                (auto    nil    nil pass raw raw)
                (auto    lean   t   pass lean lean)
                (auto    lean   nil pass lean lean)
                (auto    raw    t   pass raw raw)
                (auto    raw    nil pass raw raw)
                (auto    chunks t   pass chunks chunks)
                (auto    chunks nil pass raw raw)
                (whole   nil    t   pass lean lean)
                (whole   nil    nil pass lean lean)
                (whole   lean   t   pass lean lean)
                (whole   lean   nil pass lean lean)
                (whole   raw    t   pass lean lean)
                (whole   raw    nil pass lean lean)
                (whole   chunks t   pass lean lean)
                (whole   chunks nil pass lean lean))))
    (should (= (length rows) 24))
    (dolist (row rows)
      (pcase-let ((`(,how ,remembered ,ok . ,want) row))
        (cl-mapc (lambda (size expected)
                   (should (equal (list how remembered ok size
                                        (drgnx-large-files--decide size how remembered th ok))
                                  (list how remembered ok size expected))))
                 sizes want)))
    ;; exactly at a threshold is still below it
    (should (eq (drgnx-large-files--decide 16384 'command nil th t) 'pass))
    (should (equal (drgnx-large-files--decide 65536 'command nil th t) '(ask . lean)))
    ;; :ask-above nil: never ask, never lean
    (dolist (how '(command auto whole))
      (should (eq (drgnx-large-files--decide (* 1024 1048576) how 'chunks '(:ask-above nil :chunks-above 1 :chunk-size 1) t)
                  'pass)))))

(ert-deftest drgnx-large-files/how-in-context ()
  (with-temp-buffer
    (let ((this-command nil)) (should (eq (drgnx-large-files--how) 'auto)))
    (let ((this-command 'find-file)) (should (eq (drgnx-large-files--how) 'command)))
    (let ((this-command 'find-file))
      (drgnx-automatic (should (eq (drgnx-large-files--how) 'auto)))
      (let ((drgnx-guard--timer-fn 'some-timer-fn)) (should (eq (drgnx-large-files--how) 'auto)))
      (let ((inhibit-interaction t)) (should (eq (drgnx-large-files--how) 'auto)))
      ;; a preview from post-command (consult's file preview binds it)
      (let ((non-essential t)) (should (eq (drgnx-large-files--how) 'auto)))
      ;; a caller's binding wins, whatever the context
      (let ((drgnx-large-file-open 'whole)) (should (eq (drgnx-large-files--how) 'whole)))
      (let ((drgnx-large-file-open 'auto)) (should (eq (drgnx-large-files--how) 'auto)))
      (setq-local drgnx-large-file-open 'whole)
      (should (eq (drgnx-large-files--how) 'whole))
      (with-temp-buffer (should (eq (drgnx-large-files--how) 'command))))
    (let ((this-command nil) (drgnx-large-file-open 'whole))
      (should (eq (drgnx-large-files--how) 'whole)))))

(ert-deftest drgnx-large-files/sizes-are-mib-above-zero ()
  (should (drgnx-large-files--mib-p 50))
  (should (drgnx-large-files--mib-p 0.015625))
  (should-not (drgnx-large-files--mib-p 0))
  (should-not (drgnx-large-files--mib-p -1))
  (should-not (drgnx-large-files--mib-p 1.0e+INF))
  (should-not (drgnx-large-files--mib-p 0.0e+NaN))
  (should-not (drgnx-large-files--mib-p "50"))
  (should (equal (drgnx-large-files--size-text 432013312) "412 MB")))

;;;; The config and the project file

(ert-deftest drgnx-large-files/the-defaults ()
  (drgnx-large-files-test--with
    (should (equal (drgnx-large-files-thresholds (expand-file-name "a.log" drgnx-test-config-root))
                   (list :ask-above (* 50 1048576) :chunks-above (* 500 1048576) :chunk-size 1048576)))))

(defmacro drgnx-large-files-test--sizes (ask chunks size &rest body)
  "BODY with the settings `drgnx-large-files-ask-above', `-chunks-above' and `-chunk-size' (MiB) bound to ASK, CHUNKS, SIZE."
  (declare (indent 3) (debug t))
  `(let ((drgnx-large-files-ask-above ,ask) (drgnx-large-files-chunks-above ,chunks) (drgnx-large-files-chunk-size ,size))
     ,@body))

(ert-deftest drgnx-large-files/the-sizes-are-settings-read-on-use ()
  (dolist (var '(drgnx-large-files-ask-above drgnx-large-files-chunks-above drgnx-large-files-chunk-size))
    (let ((meta (drgnx-setting-meta var)))
      (should (eq (plist-get meta :scope) 'global))
      (should (eq (plist-get meta :workspace) 'data))   ; a project may lower them (Task 17); never raise is its merge
      (should-not (plist-get meta :apply))))
  (should (equal (list drgnx-large-files-ask-above drgnx-large-files-chunks-above drgnx-large-files-chunk-size)
                 '(50 500 1)))
  (should-not (drgnx-setting-check 'drgnx-large-files-ask-above nil))
  (should-not (drgnx-setting-check 'drgnx-large-files-ask-above 0.25))
  (should (drgnx-setting-check 'drgnx-large-files-ask-above 0))
  (should (drgnx-setting-check 'drgnx-large-files-chunks-above nil))
  (should (drgnx-setting-check 'drgnx-large-files-chunk-size "1")))

(ert-deftest drgnx-large-files/a-project-only-lowers ()
  (drgnx-large-files-test--with
    (drgnx-large-files-test--sizes 0.25 1 0.03125
      ;; lower: applied
      (let ((root (drgnx-large-files-test--project "(:version 1 :ask-above 0.015625 :chunks-above 0.0625)")))
        (should (equal (drgnx-large-files-thresholds (expand-file-name "sub/big.log" root))
                       '(:ask-above 16384 :chunks-above 65536 :chunk-size 32768))))
      ;; higher: ignored, one key at a time
      (let ((root (drgnx-large-files-test--project "(:version 1 :ask-above 5000 :chunks-above 0.5)")))
        (should (equal (drgnx-large-files-thresholds (expand-file-name "sub/big.log" root))
                       '(:ask-above 262144 :chunks-above 524288 :chunk-size 32768))))
      ;; outside a project: the user's
      (should (equal (drgnx-large-files-thresholds (expand-file-name "elsewhere.log" temporary-file-directory))
                     '(:ask-above 262144 :chunks-above 1048576 :chunk-size 32768))))))

(ert-deftest drgnx-large-files/a-project-nil-is-ignored ()
  (drgnx-large-files-test--with
    (let ((root (drgnx-large-files-test--project "(:version 1 :ask-above nil :chunks-above 0.0625)")))
      (should (equal (drgnx-large-files-thresholds (expand-file-name "sub/big.log" root))
                     (list :ask-above (* 50 1048576) :chunks-above 65536 :chunk-size 1048576)))
      (should-not (drgnx-config-problem 'large-files-project root)))))

(ert-deftest drgnx-large-files/a-user-nil-ignores-the-project ()
  (drgnx-large-files-test--with
    (drgnx-large-files-test--sizes nil 500 1
      (let ((root (drgnx-large-files-test--project "(:version 1 :ask-above 0.015625)")))
        (cl-letf (((symbol-function 'locate-dominating-file)
                   (lambda (&rest _) (error "The project file was looked for"))))
          (should (equal (drgnx-large-files-thresholds (expand-file-name "sub/big.log" root))
                         (list :ask-above nil :chunks-above (* 500 1048576) :chunk-size 1048576))))))))

(ert-deftest drgnx-large-files/a-project-chunk-size-is-ignored ()
  (drgnx-large-files-test--with
    (let ((root (drgnx-large-files-test--project "(:version 1 :chunk-size 0.001)")))
      (should (= (plist-get (drgnx-large-files-thresholds (expand-file-name "sub/big.log" root)) :chunk-size)
                 1048576)))))

(ert-deftest drgnx-large-files/a-malformed-project-file-is-ignored-with-one-problem ()
  (drgnx-large-files-test--with
    (let ((root (drgnx-large-files-test--project "(:version 1 :ask-above \"tiny\" :chunks-above 0.0625)"))
          (said 0))
      (cl-letf* ((orig (symbol-function 'message))
                 ((symbol-function 'message)
                  (lambda (fmt &rest args)
                    (when (and (stringp fmt) (string-search "large-files.eld" (apply #'format fmt args)))
                      (cl-incf said))
                    (apply orig fmt args))))
        (dotimes (_ 2)
          (should (equal (drgnx-large-files-thresholds (expand-file-name "sub/big.log" root))
                         (list :ask-above (* 50 1048576) :chunks-above (* 500 1048576) :chunk-size 1048576)))))
      (should (= (length (seq-filter (lambda (p) (eq (plist-get p :name) 'large-files-project))
                                     (drgnx-config-problems)))
                 1))
      (should (<= said 1)))))

(ert-deftest drgnx-large-files/the-threshold-follows-the-setting ()
  ;; settings.el changed (the live sync runs `drgnx-settings-changed-functions' with the changes): the threshold follows
  (let ((before large-file-warning-threshold))
    (drgnx-large-files-test--with
      (should (= large-file-warning-threshold (* 50 1048576)))
      (let ((drgnx-large-files-ask-above 1))
        (run-hook-with-args 'drgnx-settings-changed-functions "settings.el" '((nil drgnx-large-files-ask-above 50 1)))
        (should (= large-file-warning-threshold 1048576)))
      (let ((drgnx-large-files-ask-above nil))
        (run-hook-with-args 'drgnx-settings-changed-functions "settings.el" '((nil drgnx-large-files-ask-above 1 nil)))
        (should (null large-file-warning-threshold)))
      ;; a change of another setting leaves it alone
      (let ((drgnx-large-files-ask-above 7))
        (run-hook-with-args 'drgnx-settings-changed-functions "settings.el" '((nil drgnx-large-files-chunk-size 1 2)))
        (should (null large-file-warning-threshold))))
    (should (equal large-file-warning-threshold before))))

(ert-deftest drgnx-large-files/thresholds-read-the-project-file-once ()
  ;; your sizes are variables; one `drgnx-config-get' of the project's file when there is one, none otherwise
  (drgnx-large-files-test--with
    (let ((root (drgnx-large-files-test--project "(:version 1 :ask-above 0.015625)")) (n 0))
      (cl-letf* ((orig (symbol-function 'drgnx-config-get))
                 ((symbol-function 'drgnx-config-get) (lambda (&rest args) (cl-incf n) (apply orig args))))
        (should (equal (drgnx-large-files-thresholds (expand-file-name "sub/big.log" root))
                       (list :ask-above 16384 :chunks-above (* 500 1048576) :chunk-size 1048576)))
        (should (= n 1))
        (setq n 0)
        (drgnx-large-files-thresholds (expand-file-name "elsewhere.log" temporary-file-directory))
        (should (= n 0))))))

(ert-deftest drgnx-large-files/automatic-paths-take-only-safe-local-variables ()
  ;; every value of `enable-local-variables' that would query becomes :safe; nil, :all and :safe stay
  (dolist (c '((t . :safe) (query . :safe) (:query . :safe) (nil . nil) (:all . :all) (:safe . :safe)))
    (should (equal (cons (car c) (drgnx-large-files--never-query (car c))) c))))

;;;; The remembered answers

(ert-deftest drgnx-large-files/a-remote-name-is-its-own-key ()
  (drgnx-large-files-test--with
    (cl-letf (((symbol-function 'file-truename) (lambda (&rest _) (error "file-truename on a remote name")))
              ((symbol-function 'locate-dominating-file) (lambda (&rest _) (error "Looked for a remote project"))))
      (should (equal (drgnx-large-files--key "/ssh:host.invalid:/var/log/big.log") "/ssh:host.invalid:/var/log/big.log"))
      (drgnx-large-files-remember "/ssh:host.invalid:/var/log/big.log" 'raw)
      (should (eq (drgnx-large-files-remembered "/ssh:host.invalid:/var/log/big.log") 'raw))
      (should (= (plist-get (drgnx-large-files-thresholds "/ssh:host.invalid:/var/log/big.log") :ask-above)
                 (* 50 1048576))))
    ;; a local name is its truename: a link and its target share an answer
    (let* ((dir (file-name-as-directory (make-temp-file "drgnx-lf-key" t)))
           (target (expand-file-name "real.log" dir))
           (link (expand-file-name "link.log" dir)))
      (unwind-protect
          (progn
            (write-region "x" nil target nil 'silent)
            (make-symbolic-link target link)
            (drgnx-large-files-remember link 'lean)
            (should (eq (drgnx-large-files-remembered target) 'lean)))
        (delete-directory dir t)))))

(ert-deftest drgnx-large-files/answers-are-capped-at-256 ()
  (drgnx-large-files-test--with
    (dotimes (i 300)
      (drgnx-large-files-remember (format "/ssh:h.invalid:/f%d" i) 'chunks))
    (should (= (drgnx-cache-size 'drgnx-large-files--answers) 256))
    (should (eq (drgnx-large-files-remembered "/ssh:h.invalid:/f299") 'chunks))
    (should-not (drgnx-large-files-remembered "/ssh:h.invalid:/f0"))))

;;;; The door: opens, with tiny files (:ask-above 16 KiB, :chunks-above 64 KiB, :chunk-size 32 KiB)

(defvar drgnx-large-files-test--dir nil "The running door test's folder of generated files.")
(defvar drgnx-large-files-test--asked nil "The questions asked in the running test: (PROMPT CHOICES) or ARGS.")

(defun drgnx-large-files-test--kill (dir)
  "Kill the buffers visiting files in DIR, the chunk buffers the tests made and the warnings buffer, unasked."
  (let ((dir (file-name-as-directory (expand-file-name dir))) (kill-buffer-query-functions nil))
    (dolist (b (buffer-list))
      (let ((f (buffer-local-value 'buffer-file-name b)))
        (when (or (and f (string-prefix-p dir (expand-file-name f)))
                  (string-prefix-p "drgnx-lf-test-chunks " (buffer-name b))
                  (equal (buffer-name b) "*Warnings*"))
          (with-current-buffer b (set-buffer-modified-p nil))
          (kill-buffer b))))))

(defmacro drgnx-large-files-test--door (&rest body)
  "BODY with the module set up, the test sizes in the settings and `drgnx-large-files-test--dir' a fresh folder.
The buffers visiting its files are killed after."
  (declare (indent 0) (debug t))
  `(drgnx-large-files-test--with
     (drgnx-large-files-test--sizes 0.015625 0.0625 0.03125
       (let ((drgnx-large-files-test--dir (file-name-as-directory (make-temp-file "drgnx-lf-door" t))))
         (unwind-protect (progn ,@body)
           (drgnx-large-files-test--kill drgnx-large-files-test--dir)
           (delete-directory drgnx-large-files-test--dir t))))))

(defun drgnx-large-files-test--file (name bytes &optional one-line)
  "Write file NAME in the test folder: BYTES bytes of 64-byte lines (one line when ONE-LINE); return its name."
  (let ((file (expand-file-name name drgnx-large-files-test--dir)) (coding-system-for-write 'utf-8-unix))
    (with-temp-buffer
      (if one-line (insert (make-string bytes ?x))
        (dotimes (_ (/ bytes 64)) (insert (make-string 63 ?x) "\n")))
      (write-region nil nil file nil 'silent))
    file))

(defun drgnx-large-files-test--no-question (&rest args)
  "In place of every question while `drgnx-large-files-test--never-asks' runs: record ARGS and fail."
  (push args drgnx-large-files-test--asked)
  (error "A question was asked: %S" args))

(defmacro drgnx-large-files-test--never-asks (&rest body)
  "BODY with `drgnx-guard-mode' on and every question failing; it fails when one was asked, even if caught."
  (declare (indent 0) (debug t))
  `(let ((was drgnx-guard-mode) (drgnx-large-files-test--asked nil))
     (unless was (drgnx-guard-mode 1))
     (dolist (f '(read-multiple-choice y-or-n-p yes-or-no-p))
       (advice-add f :override #'drgnx-large-files-test--no-question '((depth . 100))))
     (unwind-protect (prog1 (progn ,@body) (should-not drgnx-large-files-test--asked))
       (dolist (f '(read-multiple-choice y-or-n-p yes-or-no-p))
         (advice-remove f #'drgnx-large-files-test--no-question))
       (unless was (drgnx-guard-mode -1)))))

(defmacro drgnx-large-files-test--answering (key &rest body)
  "BODY as a command the user gave (`this-command' `find-file') where the question answers KEY.
Each question is pushed onto `drgnx-large-files-test--asked' as (PROMPT CHOICES USE-DIALOG-BOX)."
  (declare (indent 1) (debug t))
  `(let ((drgnx-large-files-test--asked nil) (this-command 'find-file))
     (cl-letf (((symbol-function 'read-multiple-choice)
                (lambda (prompt choices &rest _)
                  (push (list prompt choices use-dialog-box) drgnx-large-files-test--asked)
                  (assq ,key choices))))
       ,@body)))

(defun drgnx-large-files-test--chunks (file size thresholds)
  "A stand-in for the chunks module: a buffer flagged `chunks' that records FILE, SIZE and THRESHOLDS."
  (with-current-buffer (generate-new-buffer (concat "drgnx-lf-test-chunks " (file-name-nondirectory file)))
    (setq drgnx-large-file 'chunks)
    (setq-local drgnx-large-files-test--chunk-args (list file size thresholds))
    (current-buffer)))

(defvar-local drgnx-large-files-test--chunk-args nil)

(defun drgnx-large-files-test--undo-on-p ()
  "Non-nil when the current buffer records undo."
  (not (eq buffer-undo-list t)))

;;;;; No question on an automatic path

(ert-deftest drgnx-large-files/a-timer-open-never-asks ()
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.log" 131072)))
      (drgnx-large-files-test--never-asks
        (let ((this-command 'find-file) (drgnx-guard--timer-fn 'some-timer))
          (with-current-buffer (find-file-noselect f)
            (should (eq drgnx-large-file 'raw))
            (should-not enable-multibyte-characters)
            (should-not (drgnx-large-files-test--undo-on-p))))))))

(ert-deftest drgnx-large-files/an-automatic-open-never-asks ()
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.log" 32768)))
      (drgnx-large-files-test--never-asks
        (let ((this-command 'find-file))
          (drgnx-automatic
           (should (eq (buffer-local-value 'drgnx-large-file (find-file-noselect f)) 'raw))))))))

(ert-deftest drgnx-large-files/a-persist-restore-never-asks ()
  ;; at start: no command runs
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.log" 131072)))
      (drgnx-large-files-test--never-asks
        (let ((this-command nil))
          (should (eq (buffer-local-value 'drgnx-large-file (drgnx-persist--visit f)) 'raw)))))))

(defun drgnx-large-files-test--serve (files nowait commands)
  "Run `server-execute' as the server's process filter does, for a fake client: FILES ((NAME) …), NOWAIT,
COMMANDS (functions, as -eval forms are run).  `this-command' is some earlier command, as it may be in a filter.
The core's advice on `server-visit-files' (`drgnx-session--visit-unasked') is on, as in drgnx.  Return the errors it
sent the client."
  (let ((proc (make-pipe-process :name "drgnx-lf-test-client" :noquery t))
        (errors nil)
        (this-command 'find-file)
        (pre-command-hook nil) (post-command-hook nil) (server-visit-hook nil) (server-switch-hook nil)
        (server-after-make-frame-hook nil) (server-client-instructions nil) (file-name-history nil))
    (unwind-protect
        (cl-letf (((symbol-function 'server-delete-client) #'ignore)
                  ((symbol-function 'server-switch-buffer) #'ignore)
                  ((symbol-function 'server-return-error) (lambda (_proc err) (push err errors))))
          (server-execute proc files nowait commands nil nil nil nil))
      (let ((buf (process-buffer proc)))      ; a pipe process without :buffer makes one of its name
        (delete-process proc)
        (when (buffer-live-p buf) (kill-buffer buf))))
    errors))

(ert-deftest drgnx-large-files/an-eval-form-from-the-server-is-automatic ()
  ;; `drgnx -t FILE' sends -e (find-file "FILE"): no file argument
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.log" 32768)) (buf nil))
      (drgnx-large-files-test--never-asks
        (should-not (drgnx-large-files-test--serve nil nil (list (lambda () (setq buf (find-file-noselect f))))))
        (should (eq (buffer-local-value 'drgnx-large-file buf) 'raw))))))

(ert-deftest drgnx-large-files/a-nowait-file-from-the-server-is-automatic ()
  ;; `drgnx open FILE': emacsclient -n FILE
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.log" 32768)))
      (drgnx-large-files-test--never-asks
        (should-not (drgnx-large-files-test--serve (list (list f)) t nil))
        (should (eq (buffer-local-value 'drgnx-large-file (get-file-buffer f)) 'raw))))))

(ert-deftest drgnx-large-files/a-waiting-file-from-the-server-is-whole ()
  ;; `drgnx open --wait FILE' (drgnx as $EDITOR): the whole file, lean
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.log" 131072)))
      (drgnx-large-files-test--never-asks
        (should-not (drgnx-large-files-test--serve (list (list f)) nil nil))
        (with-current-buffer (get-file-buffer f)
          (should (eq drgnx-large-file 'lean))
          (should drgnx-large-file-mode)
          (should enable-multibyte-characters))))))

(defun drgnx-large-files-test--grow (file bytes)
  "Write FILE (in the test folder) again with BYTES bytes, its time moved on (as a growing log's)."
  (drgnx-large-files-test--file (file-name-nondirectory file) bytes)
  (set-file-times file (time-add nil 10)))

(ert-deftest drgnx-large-files/drgnx-open-reverts-a-changed-lean-or-raw-buffer-unasked ()
  ;; `drgnx open BIG' while a lean or raw buffer holds BIG and the file grew: Emacs's `server-visit-files' reverts
  ;; the buffer with (revert-buffer t nil), which asks; here it is reverted without the question
  (drgnx-large-files-test--door
    (let* ((lean (drgnx-large-files-test--file "lean.log" 32768))
           (raw (drgnx-large-files-test--file "raw.log" 32768))
           (lb (let ((drgnx-large-file-open 'whole)) (find-file-noselect lean)))
           (rb (find-file-noselect raw)))          ; automatic: raw
      (should (eq (buffer-local-value 'drgnx-large-file rb) 'raw))
      (drgnx-large-files-test--grow lean 65536)
      (drgnx-large-files-test--grow raw 65536)
      (should-not (verify-visited-file-modtime lb))
      (drgnx-large-files-test--never-asks
        ;; bound: `revert-buffer' leaves its copy of `after-revert-hook' there (see `drgnx-large-files-test--revert')
        (let ((revert-buffer-internal-hook nil))
          (should-not (drgnx-large-files-test--serve (list (list lean) (list raw)) t nil))))
      (dolist (b (list lb rb))
        (should (= (buffer-size b) 65536))
        (should (verify-visited-file-modtime b))
        (should-not (buffer-modified-p b))))))

(ert-deftest drgnx-large-files/drgnx-open-leaves-a-modified-lean-buffer-unasked ()
  ;; unsaved changes are never reverted silently: the open leaves the buffer as it is and says so
  (drgnx-large-files-test--door
    (let* ((f (drgnx-large-files-test--file "big.log" 32768))
           (b (let ((drgnx-large-file-open 'whole)) (find-file-noselect f)))
           (said nil))
      (with-current-buffer b (goto-char (point-min)) (insert "unsaved"))
      (drgnx-large-files-test--grow f 65536)
      (cl-letf* ((orig (symbol-function 'message))
                 ((symbol-function 'message)
                  (lambda (fmt &rest args)
                    (when fmt (push (apply #'format fmt args) said))
                    (apply orig fmt args))))
        (drgnx-large-files-test--never-asks
          (should-not (drgnx-large-files-test--serve (list (list f)) t nil))))
      (with-current-buffer b
        (should (buffer-modified-p))
        (should (= (buffer-size) (+ 32768 7)))
        (should-not (verify-visited-file-modtime b)))     ; still stale: saving it asks, as a command may
      (should (member "big.log changed on disk; its buffer has unsaved changes and is left as it is" said)))))

(ert-deftest drgnx-large-files/drgnx-open-reverts-a-changed-normal-buffer-unasked ()
  ;; below `:ask-above' the module changes nothing: the core reverts it unasked, and it stays normal
  (drgnx-large-files-test--door
    (let* ((f (drgnx-large-files-test--file "small.log" 4096))
           (b (find-file-noselect f)))
      (drgnx-large-files-test--grow f 8192)
      (drgnx-large-files-test--never-asks
        (let ((revert-buffer-internal-hook nil))
          (should-not (drgnx-large-files-test--serve (list (list f)) t nil))))
      (should (eq (get-file-buffer f) b))
      (should (= (buffer-size b) 8192))
      (should-not (buffer-local-value 'drgnx-large-file b)))))

(ert-deftest drgnx-large-files/drgnx-open-leaves-a-modified-normal-buffer-that-grew-large ()
  ;; unsaved changes: never reopened, reverted or asked about, even past `:ask-above'
  (drgnx-large-files-test--door
    (let* ((f (drgnx-large-files-test--file "small.log" 4096))
           (b (find-file-noselect f))
           (said nil))
      (with-current-buffer b (goto-char (point-min)) (insert "unsaved"))
      (drgnx-large-files-test--grow f 32768)
      (cl-letf* ((orig (symbol-function 'message))
                 ((symbol-function 'message)
                  (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) said)) (apply orig fmt args))))
        (drgnx-large-files-test--never-asks
          (should-not (drgnx-large-files-test--serve (list (list f)) t nil))))
      (should (eq (get-file-buffer f) b))
      (with-current-buffer b
        (should (buffer-modified-p))
        (should (= (buffer-size) (+ 4096 7)))
        (should-not drgnx-large-file))
      (should (member "small.log changed on disk; its buffer has unsaved changes and is left as it is" said)))))

(ert-deftest drgnx-large-files/drgnx-open-reopens-a-normal-buffer-that-grew-large-unasked ()
  ;; a normal buffer whose file grew past `:ask-above' goes through the door again, as an automatic open: raw here
  ;; (chunks without the chunks module), never a question, never the whole file read into the normal buffer
  (drgnx-large-files-test--door
    (let* ((f (drgnx-large-files-test--file "grows.log" 4096))
           (b (find-file-noselect f))
           (c nil))
      (should-not (buffer-local-value 'drgnx-large-file b))
      (drgnx-large-files-test--grow f 32768)
      (drgnx-large-files-test--never-asks
        (should-not (drgnx-large-files-test--serve (list (list f)) t nil))
        (should-not (buffer-live-p b))
        (setq c (get-file-buffer f))
        (should (eq (buffer-local-value 'drgnx-large-file c) 'raw))
        ;; `drgnx -t' (an -e form): the raw buffer, after the file grew again, is reverted unasked
        (drgnx-large-files-test--grow f 65536)
        (let ((revert-buffer-internal-hook nil))     ; see `drgnx-large-files-test--revert'
          (should-not (drgnx-large-files-test--serve nil nil (list (lambda () (drgnx-session-open-file f)))))))
      (should (eq (get-file-buffer f) c))
      (should (= (buffer-size c) 65536)))))

;;;;; A command asks

(ert-deftest drgnx-large-files/a-command-open-asks-once ()
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.log" 32768)))
      (drgnx-large-files-test--answering ?n
        (let ((buf (find-file-noselect f)))
          (should (= (length drgnx-large-files-test--asked) 1))
          (pcase-let ((`(,prompt ,_choices ,dialog) (car drgnx-large-files-test--asked)))
            (should (equal prompt (format "big.log is %s: " (drgnx-large-files--size-text 32768))))
            (should-not dialog))
          (should (eq (buffer-local-value 'drgnx-large-file buf) 'lean))
          (kill-buffer buf))
        (should (eq (buffer-local-value 'drgnx-large-file (find-file-noselect f)) 'lean))
        (should (= (length drgnx-large-files-test--asked) 1))))))

(ert-deftest drgnx-large-files/quit-is-a-user-error ()
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.log" 32768)))
      (drgnx-large-files-test--answering ?q
        (should-error (find-file-noselect f) :type 'user-error)
        (should-not (get-file-buffer f))
        (should-not (drgnx-large-files-remembered f))))))

(ert-deftest drgnx-large-files/the-default-is-lean-below-chunks-above-and-chunks-above-it ()
  (drgnx-large-files-test--door
    (let ((small (drgnx-large-files-test--file "between.log" 32768))
          (big (drgnx-large-files-test--file "above.log" 131072))
          (drgnx-large-files-chunk-open-function #'drgnx-large-files-test--chunks))
      (drgnx-large-files-test--answering ?c
        (let ((buf (find-file-noselect big)))
          (should (equal (mapcar #'car (nth 1 (car drgnx-large-files-test--asked))) '(?c ?n ?r ?q)))
          (with-current-buffer buf
            (should (eq drgnx-large-file 'chunks))
            (should (equal drgnx-large-files-test--chunk-args
                           (list (expand-file-name big) 131072 (drgnx-large-files-thresholds big))))))
        (find-file-noselect small)
        (should (equal (mapcar #'car (nth 1 (car drgnx-large-files-test--asked))) '(?n ?c ?r ?q)))))))

(ert-deftest drgnx-large-files/without-chunks-the-question-has-no-c ()
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.log" 131072)))
      (drgnx-large-files-test--answering ?r
        (with-current-buffer (find-file-noselect f)
          (should (eq drgnx-large-file 'raw)))
        (should (equal (mapcar #'car (nth 1 (car drgnx-large-files-test--asked))) '(?r ?n ?q)))))))

(ert-deftest drgnx-large-files/without-chunks-automatic-is-raw ()
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.log" 131072)))
      (drgnx-large-files-test--never-asks
        (with-current-buffer (find-file-noselect f)
          (should (eq drgnx-large-file 'raw))
          (should drgnx-large-file-mode)
          (should-not buffer-auto-save-file-name))))))

(ert-deftest drgnx-large-files/a-visited-file-is-reused-without-a-question ()
  (drgnx-large-files-test--door
    (let* ((f (drgnx-large-files-test--file "big.log" 32768))
           (buf (find-file-noselect f)))          ; automatic: raw
      ;; a raw buffer: Emacs's own "revisit the file normally?" is not asked either, from a command or a timer
      (should (eq (buffer-local-value 'drgnx-large-file buf) 'raw))
      (drgnx-large-files-test--answering ?n
        (should (eq (find-file-noselect f) buf))
        (should-not drgnx-large-files-test--asked))
      (drgnx-large-files-test--never-asks
        (let ((drgnx-guard--timer-fn 'some-timer))
          (should (eq (find-file-noselect f) buf)))))))

(ert-deftest drgnx-large-files/a-raw-buffer-is-reused-raw-below-a-raised-threshold ()
  ;; :ask-above raised above the file's size: the raw buffer is still reused raw, without Emacs's "revisit normally?"
  (drgnx-large-files-test--door
    (let* ((f (drgnx-large-files-test--file "big.log" 32768))
           (buf (find-file-noselect f)))          ; automatic: raw
      (should (eq (buffer-local-value 'drgnx-large-file buf) 'raw))
      (setq drgnx-large-files-ask-above 1)            ; the door's `let' of the sizes ends with the test
      (should (= (plist-get (drgnx-large-files-thresholds f) :ask-above) 1048576))
      (drgnx-large-files-test--never-asks
        (let ((this-command 'find-file))
          (should (eq (find-file-noselect f) buf)))))))

(ert-deftest drgnx-large-files/an-unreadable-large-file-never-asks ()
  ;; not opened in a mode (unreadable): Emacs's own size question is not asked either
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "locked.log" 32768)))
      (set-file-modes f 0)
      (unwind-protect
          (progn
            (skip-unless (not (file-readable-p f)))       ; root reads it all the same
            (drgnx-large-files-test--never-asks
              (should-error (find-file-noselect f) :type 'file-error)))
        (set-file-modes f #o600)))))

(ert-deftest drgnx-large-files/an-open-reads-the-size-once ()
  ;; the header's size is the door's: no second stat (a remote file's included)
  (drgnx-large-files-test--door
    (let ((raw (drgnx-large-files-test--file "raw.log" 32768))
          (lean (drgnx-large-files-test--file "lean.log" 32768))
          (n 0))
      (cl-letf* ((orig (symbol-function 'drgnx-large-files--size))
                 ((symbol-function 'drgnx-large-files--size) (lambda (file) (cl-incf n) (funcall orig file))))
        (with-current-buffer (find-file-noselect raw)    ; automatic: raw
          (should (eq drgnx-large-file 'raw))
          (should (equal drgnx-large-files--shown-size (drgnx-large-files--size-text 32768))))
        (should (= n 1))
        (setq n 0)
        (with-current-buffer (let ((drgnx-large-file-open 'whole)) (find-file-noselect lean))
          (should (eq drgnx-large-file 'lean))
          (should (equal drgnx-large-files--shown-size (drgnx-large-files--size-text 32768))))
        (should (= n 1))))))

(ert-deftest drgnx-large-files/the-sweep-leaves-a-chunk-buffer-alone ()
  ;; undo stays on in chunks, even if `find-file-hook' ever ran in one
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.log" 131072)))
      (with-current-buffer (drgnx-large-files-test--chunks f 131072 nil)
        (setq buffer-file-name f)
        (funcall 'drgnx-editor/large-files--sweep)
        (should (eq drgnx-large-file 'chunks))
        (should-not drgnx-large-file-mode)
        (should (drgnx-large-files-test--undo-on-p))))))

(ert-deftest drgnx-large-files/replace-skips-a-raw-buffer ()
  ;; a raw buffer is unibyte: rg's columns and a multibyte replacement do not fit it
  (drgnx-large-files-test--door
    (let* ((f (drgnx-large-files-test--file "raw.log" 32768))
           (disk (with-temp-buffer (insert-file-contents-literally f) (buffer-string)))
           (buf (find-file-noselect f)))         ; automatic, without chunks: raw
      (should (eq (buffer-local-value 'drgnx-large-file buf) 'raw))
      (pcase-let ((`(,n ,skipped ,undo)
                   (drgnx-replace--apply-file f (list (list :file f :line 2 :col 0 :text "xxxx")) "yyyy")))
        (should (= n 0))
        (should-not undo)
        (should (equal (mapcar (lambda (m) (plist-get m :reason)) skipped)
                       '("open raw: Large File: Open Whole first"))))
      (should-not (buffer-modified-p buf))
      (should (equal (with-temp-buffer (insert-file-contents-literally f) (buffer-string)) disk)))))

(ert-deftest drgnx-large-files/below-the-threshold-nothing-changes ()
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "small.el" 1024)))
      (drgnx-large-files-test--answering ?q
        (with-current-buffer (find-file-noselect f)
          (should (eq major-mode 'emacs-lisp-mode))
          (should-not drgnx-large-file)
          (should-not drgnx-large-file-mode)
          (should (drgnx-large-files-test--undo-on-p)))
        (should-not drgnx-large-files-test--asked)))))

;;;;; Lean

(ert-deftest drgnx-large-files/lean-drops-the-expensive-modes ()
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.json" 32768))
          (prog-mode-hook (list #'hl-line-mode)))
      (global-display-line-numbers-mode 1)
      (unwind-protect
          (let ((drgnx-large-file-open 'whole))
            (with-current-buffer (find-file-noselect f)
              (should (eq drgnx-large-file 'lean))
              (should (derived-mode-p 'prog-mode))   ; the major mode ran
              (should-not font-lock-mode)
              (should-not display-line-numbers-mode)
              (should-not hl-line-mode)
              (should (eq buffer-undo-list t))
              (should-not buffer-auto-save-file-name)))
        (global-display-line-numbers-mode -1)))))

(ert-deftest drgnx-large-files/a-major-mode-change-stays-lean ()
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.json" 32768))
          (raw (drgnx-large-files-test--file "big.log" 32768))
          (prog-mode-hook (list #'hl-line-mode))
          (text-mode-hook (list #'hl-line-mode)))
      (global-display-line-numbers-mode 1)
      (unwind-protect
          (progn
            (with-current-buffer (let ((drgnx-large-file-open 'whole)) (find-file-noselect f))
              (should drgnx-large-file-mode)
              (emacs-lisp-mode)                       ; by hand: the swept modes come back with it
              (should (eq drgnx-large-file 'lean))
              (should drgnx-large-file-mode)
              (should-not display-line-numbers-mode)
              (should-not hl-line-mode)
              (should (eq buffer-undo-list t)))
            (with-current-buffer (find-file-noselect raw)   ; automatic: raw
              (should (eq drgnx-large-file 'raw))
              (text-mode)
              (should drgnx-large-file-mode)
              (should-not display-line-numbers-mode)
              (should-not hl-line-mode)))
        (global-display-line-numbers-mode -1)))))

(ert-deftest drgnx-large-files/lean-starts-no-parser ()
  (skip-unless (and (fboundp 'treesit-language-available-p) (treesit-language-available-p 'python)))
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.py" 32768))
          (major-mode-remap-alist '((python-mode . python-ts-mode)))
          (drgnx-large-file-open 'whole))
      (with-current-buffer (find-file-noselect f)
        (should (eq major-mode 'python-ts-mode))
        (should (eq drgnx-large-file 'lean))
        (should-not (treesit-parser-list))
        ;; still large after a revert: the major mode runs again, without a parser
        (drgnx-large-files-test--file "big.py" 65536)
        (drgnx-large-files-test--never-asks (drgnx-large-files-test--revert))
        (should (eq major-mode 'python-ts-mode))
        (should-not (treesit-parser-list)))
      (should-not (get-buffer "*Warnings*")))))

(defvar drgnx-large-files-test--eglot-calls nil)

(defun drgnx-large-files-test--eglot (&rest _)
  "In place of eglot itself: count the call."
  (push (current-buffer) drgnx-large-files-test--eglot-calls))

(ert-deftest drgnx-large-files/eglot-ensure-is-a-no-op-in-lean ()
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.el" 32768))
          (small (drgnx-large-files-test--file "small.el" 1024))
          (drgnx-large-files-test--eglot-calls nil)
          ;; a mode hook runs before the flag is set: only the open's binding tells it the file is large
          (prog-mode-hook (list #'eglot-ensure)))
      (advice-add 'eglot-ensure :override #'drgnx-large-files-test--eglot '((depth . 100)))
      (unwind-protect
          (let ((drgnx-large-file-open 'whole))
            (with-current-buffer (find-file-noselect f)
              (should (eq drgnx-large-file 'lean))
              (eglot-ensure))
            (should-not drgnx-large-files-test--eglot-calls)
            ;; a small file still gets it
            (find-file-noselect small)
            (should (= (length drgnx-large-files-test--eglot-calls) 1)))
        (advice-remove 'eglot-ensure #'drgnx-large-files-test--eglot)))))

(defvar eglot--managed-mode)

(ert-deftest drgnx-large-files/turning-lean-on-revert-drops-the-parser-and-eglot ()
  ;; auto-revert keeps the modes: a buffer that turns lean then loses its parser and eglot's management
  (skip-unless (and (fboundp 'treesit-language-available-p) (treesit-language-available-p 'python)))
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "grow.py" 1024))
          (major-mode-remap-alist '((python-mode . python-ts-mode)))
          (auto-mode-alist auto-mode-alist)       ; python-ts-mode's first run with a parser adds itself there
          (offs nil))
      (with-current-buffer (find-file-noselect f)
        (should (eq major-mode 'python-ts-mode))
        (should (treesit-parser-list nil nil t))
        (setq-local eglot--managed-mode t)
        (drgnx-large-files-test--grow f 65536)
        (cl-letf (((symbol-function 'eglot--managed-mode)
                   (lambda (&optional arg) (push arg offs) (setq eglot--managed-mode nil))))
          (drgnx-large-files-test--never-asks
            (let ((revert-buffer-internal-hook nil)) (revert-buffer t t t))))   ; as auto-revert does
        (should (eq drgnx-large-file 'lean))
        (should-not (treesit-parser-list nil nil t))
        (should (equal offs '(-1)))))))

(ert-deftest drgnx-large-files/no-line-numbers-from-the-face-module-in-lean-or-raw ()
  ;; a setting change re-applies line numbers to every buffer: never to a lean or raw one
  (drgnx-large-files-test--door
    (let ((lean (drgnx-large-files-test--file "lean.el" 32768))
          (raw (drgnx-large-files-test--file "raw.el" 32768))
          (small (drgnx-large-files-test--file "small.el" 1024)))
      (with-current-buffer (let ((drgnx-large-file-open 'whole)) (find-file-noselect lean))
        (should (derived-mode-p 'prog-mode))
        (should-not (drgnx-face--numbers-wanted-p)))
      (with-current-buffer (find-file-noselect raw)    ; automatic: raw
        (emacs-lisp-mode)
        (should (eq drgnx-large-file 'raw))
        (should-not (drgnx-face--numbers-wanted-p)))
      (with-current-buffer (find-file-noselect small)
        (should (drgnx-face--numbers-wanted-p))))))

(ert-deftest drgnx-large-files/a-compressed-file-that-expands-turns-lean ()
  (skip-unless (executable-find "gzip"))
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.txt" 32768)))
      (should (zerop (call-process "gzip" nil nil nil "-9" f)))
      (setq f (concat f ".gz"))
      (should (< (file-attribute-size (file-attributes f)) 16384))
      (drgnx-large-files-test--answering ?q
        (with-current-buffer (find-file-noselect f)
          (should (= (buffer-size) 32768))
          (should (eq drgnx-large-file 'lean))
          (should (eq buffer-undo-list t)))
        (should-not drgnx-large-files-test--asked)))))

;;;;; Revert

(defun drgnx-large-files-test--revert ()
  "Revert the current buffer from its file, unasked.  `revert-buffer' leaves its copy of `after-revert-hook' in
`revert-buffer-internal-hook''s default value: bound here, so it is not left behind."
  (let ((revert-buffer-internal-hook nil)) (revert-buffer nil t)))

(ert-deftest drgnx-large-files/shrunk-on-revert-turns-lean-off ()
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.el" 32768))
          (prog-mode-hook (list #'hl-line-mode)))
      (with-current-buffer (let ((drgnx-large-file-open 'whole)) (find-file-noselect f))
        (should (eq drgnx-large-file 'lean))
        (should-not hl-line-mode)
        (drgnx-large-files-test--file "big.el" 1024)
        (drgnx-large-files-test--never-asks (drgnx-large-files-test--revert))
        (should-not drgnx-large-file)
        (should-not drgnx-large-file-mode)
        (should (drgnx-large-files-test--undo-on-p))
        (should (eq major-mode 'emacs-lisp-mode))
        (should hl-line-mode)))))                 ; the major mode and its hooks ran again

(ert-deftest drgnx-large-files/grown-on-revert-turns-lean-silently ()
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "log.el" 1024)))
      (with-current-buffer (find-file-noselect f)
        (should-not drgnx-large-file)
        (drgnx-large-files-test--file "log.el" 32768)
        (drgnx-large-files-test--never-asks
          (let ((this-command 'revert-buffer)) (drgnx-large-files-test--revert)))
        (should (eq drgnx-large-file 'lean))
        (should drgnx-large-file-mode)
        (should (eq buffer-undo-list t))))))

(defvar drgnx-large-files-test--current nil "Whether the buffer's record of its file's time was current, per read.")

(defun drgnx-large-files-test--note-current (file-name auto-save-p)
  "In place of `revert-buffer-insert-file-contents-function': note whether the visited time is current, then read."
  (push (verify-visited-file-modtime) drgnx-large-files-test--current)
  (revert-buffer-insert-file-contents--default-function file-name auto-save-p))

(defvar drgnx-large-files-test--gates nil "(TREESIT-MAX-BUFFER-SIZE . BUFFER-SIZE) each time the major mode ran.")

(defun drgnx-large-files-test--note-gate ()
  "A mode hook: note tree-sitter's size limit against the buffer's size (a parser starts only within it)."
  (push (cons treesit-max-buffer-size (buffer-size)) drgnx-large-files-test--gates))

(ert-deftest drgnx-large-files/staying-large-on-revert-starts-no-parser ()
  (skip-unless (boundp 'treesit-max-buffer-size))
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.el" 32768))
          (emacs-lisp-mode-hook (list #'drgnx-large-files-test--note-gate))
          (drgnx-large-files-test--gates nil))
      (with-current-buffer (let ((drgnx-large-file-open 'whole)) (find-file-noselect f))
        (should (eq drgnx-large-file 'lean))
        (drgnx-large-files-test--file "big.el" 65536)
        (setq drgnx-large-files-test--gates nil)
        (drgnx-large-files-test--never-asks (drgnx-large-files-test--revert))
        (should (eq drgnx-large-file 'lean))
        (should drgnx-large-files-test--gates)       ; the revert ran the major mode again
        (dolist (g drgnx-large-files-test--gates)
          (should (< (car g) (cdr g))))))))

(ert-deftest drgnx-large-files/raw-stays-raw-on-revert ()
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.log" 131072)))
      (with-current-buffer (find-file-noselect f)
        (should (eq drgnx-large-file 'raw))
        ;; the file shrinks to a prefix of the buffer's text, and its time moves on (as an agent's log does)
        (drgnx-large-files-test--file "big.log" 1024)
        (set-file-times f (time-add nil 10))
        ;; Emacs truncates the buffer with a change that asks `ask-user-about-supersession-threat' while
        ;; the buffer's record of the file's time is stale: the revert reads with it current
        (let ((drgnx-large-files-test--current nil)
              (revert-buffer-insert-file-contents-function #'drgnx-large-files-test--note-current))
          (drgnx-large-files-test--never-asks (drgnx-large-files-test--revert))
          (should (equal drgnx-large-files-test--current '(t))))
        (should (eq drgnx-large-file 'raw))
        (should (= (buffer-size) 1024))))))

;;;;; so-long

(ert-deftest drgnx-large-files/a-long-line-triggers-so-long ()
  ;; 12 KB: longer than `so-long-threshold' (10000), under the test's :ask-above (16 KiB)
  (drgnx-large-files-test--door
    (should global-so-long-mode)
    (dolist (m '(indent-bars-mode drgnx-blame-mode drgnx-sticky-mode diff-hl-margin-mode
                                  display-line-numbers-mode diff-hl-mode))
      (should (memq m so-long-minor-modes)))
    (let ((f (drgnx-large-files-test--file "long.js" 12000 t))
          ;; so-long acts when a buffer is first displayed; a buffer nobody shows acts at once
          (so-long-invisible-buffer-function nil))
      (drgnx-large-files-test--never-asks
        (with-current-buffer (find-file-noselect f)
          (should-not drgnx-large-file)
          (should so-long-detected-p)
          (should (eq major-mode 'so-long-mode)))))))

;;;; Switching, the header line, the status bar

(defun drgnx-large-files-test--run (id)
  "Run command ID as the registry has it, as a key would."
  (call-interactively (drgnx-cmd-command (drgnx-commands-get id))))

(defmacro drgnx-large-files-test--shown (buf &rest body)
  "BODY with BUF shown in the selected window; the window's buffer is put back after."
  (declare (indent 1) (debug t))
  `(let ((old (window-buffer (selected-window))))
     (set-window-buffer (selected-window) ,buf)
     (unwind-protect (progn ,@body)
       (when (buffer-live-p old) (set-window-buffer (selected-window) old)))))

(ert-deftest drgnx-large-files/switch-refuses-a-modified-buffer ()
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.log" 32768))
          (drgnx-large-files-chunk-open-function #'drgnx-large-files-test--chunks))
      (with-current-buffer (let ((drgnx-large-file-open 'whole)) (find-file-noselect f))
        (insert "unsaved")
        (dolist (id '(large-file-open-chunks large-file-open-raw large-file-open-whole))
          (let ((err (should-error (drgnx-large-files-test--run id) :type 'user-error)))
            (should (equal (cadr err) "Save or revert big.log first: switching reopens the file"))))
        (should (buffer-modified-p))
        (should (eq drgnx-large-file 'lean))
        (should-not (drgnx-large-files-remembered f))))))

(ert-deftest drgnx-large-files/switch-to-raw-reopens-raw-and-remembers ()
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.log" 32768))
          ;; chunks can be built: an automatic open would give chunks, unless raw is remembered
          (drgnx-large-files-chunk-open-function #'drgnx-large-files-test--chunks))
      (let ((buf (let ((drgnx-large-file-open 'whole)) (find-file-noselect f))))
        (drgnx-large-files-test--shown buf
          (with-current-buffer buf
            (drgnx-large-files-test--never-asks (drgnx-large-files-test--run 'large-file-open-raw)))
          (should-not (buffer-live-p buf))
          (let ((new (window-buffer (selected-window))))       ; in the same window
            (should (equal (buffer-file-name new) (expand-file-name f)))
            (should (eq (buffer-local-value 'drgnx-large-file new) 'raw))
            (kill-buffer new))))
      (should (eq (drgnx-large-files-remembered f) 'raw))
      (drgnx-large-files-test--never-asks
        (should (eq (buffer-local-value 'drgnx-large-file (find-file-noselect f)) 'raw))))))

(ert-deftest drgnx-large-files/switch-to-whole-is-lean ()
  (drgnx-large-files-test--door
    (let* ((f (drgnx-large-files-test--file "big.log" 32768))
           (buf (find-file-noselect f)))             ; automatic: raw
      (should (eq (buffer-local-value 'drgnx-large-file buf) 'raw))
      (drgnx-large-files-test--shown buf
        (with-current-buffer buf
          (drgnx-large-files-test--never-asks (drgnx-large-files-test--run 'large-file-open-whole)))
        (with-current-buffer (window-buffer (selected-window))
          (should (equal buffer-file-name (expand-file-name f)))
          (should (eq drgnx-large-file 'lean))
          (should drgnx-large-file-mode)
          (should enable-multibyte-characters)))
      (should (eq (drgnx-large-files-remembered f) 'lean)))))

(defun drgnx-large-files-test--buttons (text)
  "The header TEXT's buttons: (LABEL MODE CLICK) each, CLICK the command its header-line click runs."
  (let ((pos 0) (out nil))
    (while (setq pos (text-property-not-all pos (length text) 'drgnx-large-files-switch nil text))
      (let ((end (next-single-property-change pos 'drgnx-large-files-switch text (length text))))
        (push (list (substring-no-properties text pos end)
                    (get-text-property pos 'drgnx-large-files-switch text)
                    (lookup-key (get-text-property pos 'local-map text) [header-line mouse-1]))
              out)
        (setq pos end)))
    (nreverse out)))

(ert-deftest drgnx-large-files/the-header-offers-the-other-modes ()
  (drgnx-large-files-test--door
    (let ((size (drgnx-large-files--size-text 32768))
          (lean (drgnx-large-files-test--file "lean.log" 32768))
          (raw (drgnx-large-files-test--file "raw.log" 32768))
          (bare (drgnx-large-files-test--file "bare.log" 32768))
          (drgnx-large-files-chunk-open-function #'drgnx-large-files-test--chunks))
      (with-current-buffer (let ((drgnx-large-file-open 'whole)) (find-file-noselect lean))
        (should (eq header-line-format 'drgnx-large-files--header))
        (should (equal (substring-no-properties drgnx-large-files--header)
                       (format " %s, lean: [Open in Chunks] [Open Raw]" size)))
        (should (equal (drgnx-large-files-test--buttons drgnx-large-files--header)
                       '(("[Open in Chunks]" chunks drgnx-large-files--header-click)
                         ("[Open Raw]" raw drgnx-large-files--header-click))))
        ;; with the workbench's chrome, after the breadcrumb
        (let ((drgnx-chrome-mode t))
          (drgnx-large-files--header-refresh)
          (should (eq drgnx-chrome-header-tail 'drgnx-large-files--header))
          (should-not (local-variable-p 'header-line-format))))
      (drgnx-large-files-remember raw 'raw)
      (with-current-buffer (find-file-noselect raw)
        (should (equal (substring-no-properties drgnx-large-files--header)
                       (format " %s, raw: [Open in Chunks] [Open Whole]" size))))
      ;; without chunks, no button for them
      (let ((drgnx-large-files-chunk-open-function nil))
        (with-current-buffer (find-file-noselect bare)
          (should (eq drgnx-large-file 'raw))
          (should (equal (substring-no-properties drgnx-large-files--header) (format " %s, raw: [Open Whole]" size)))
          ;; lean off: the header goes
          (drgnx-large-file-mode -1)
          (should-not (local-variable-p 'header-line-format))
          (should-not drgnx-large-files--header))))))

(defun drgnx-large-files-test--segment (ascii)
  "The status bar's `large-file' segment as the bar defines it, in the current buffer, on an ASCII frame or not."
  (cl-letf (((symbol-function 'drgnx-ui-ascii-frame-p) (lambda (&optional _frame) ascii)))
    (funcall (plist-get (gethash 'large-file drgnx-statusbar--segments) :fn))))

(ert-deftest drgnx-large-files/the-segment-shows-size-and-mode ()
  (drgnx-large-files-test--door
    (should (memq 'large-file drgnx-statusbar-right))
    (should (< (seq-position drgnx-statusbar-right 'large-file) (seq-position drgnx-statusbar-right 'position)))
    (let ((size (drgnx-large-files--size-text 32768)))
      (with-current-buffer (find-file-noselect (drgnx-large-files-test--file "raw.log" 32768))
        (should (equal (drgnx-large-files-test--segment nil) (concat size " · raw")))
        (should (equal (drgnx-large-files-test--segment t) (concat size " - raw"))))
      (with-current-buffer (let ((drgnx-large-file-open 'whole))
                             (find-file-noselect (drgnx-large-files-test--file "lean.log" 32768)))
        (should (equal (drgnx-large-files-test--segment nil) (concat size " · lean"))))
      (with-current-buffer (find-file-noselect (drgnx-large-files-test--file "small.log" 1024))
        (should-not (drgnx-large-files-test--segment nil))))))

(ert-deftest drgnx-large-files/the-segment-goes-with-the-module ()
  (let ((right (default-value 'drgnx-statusbar-right)))
    (drgnx-large-files-test--with
      (should (gethash 'large-file drgnx-statusbar--segments))
      (should (memq 'large-file drgnx-statusbar-right)))
    (should-not (gethash 'large-file drgnx-statusbar--segments))
    (should-not (memq 'large-file drgnx-statusbar-right))
    (should (equal (default-value 'drgnx-statusbar-right) right))))

;;;; The module

(ert-deftest drgnx-large-files/teardown-keeps-lean-buffers-major-mode ()
  (drgnx-large-files-test--door
    (let ((f (drgnx-large-files-test--file "big.el" 32768)) (said nil))
      (with-current-buffer (let ((drgnx-large-file-open 'whole)) (find-file-noselect f))
        (should (eq drgnx-large-file 'lean))
        (cl-letf* ((orig (symbol-function 'message))
                   ((symbol-function 'message)
                    (lambda (fmt &rest args)
                      (when fmt (push (apply #'format fmt args) said))
                      (apply orig fmt args))))
          (should-not (drgnx-module-teardown 'editor/large-files)))
        (should (eq major-mode 'emacs-lisp-mode))
        (should-not drgnx-large-file)
        (should-not drgnx-large-file-mode)
        (should (drgnx-large-files-test--undo-on-p))
        (should (member "Large files off: lean buffers keep their mode until you revert them" said))))))

(ert-deftest drgnx-large-files/off-on-off-leaves-nothing ()
  (let ((before large-file-warning-threshold)
        (so-long-before (default-value 'so-long-minor-modes)))
    (dotimes (_ 2)
      (drgnx-large-files-test--with
        (should-not (drgnx-config-defined-p 'large-files))        ; the old file is defined for the migration only
        (should (drgnx-config-defined-p 'large-files-project))
        (drgnx-large-files-remember "/ssh:h.invalid:/big" 'raw)
        (should (eq (drgnx-large-files-remembered "/ssh:h.invalid:/big") 'raw))
        (should (advice-member-p 'drgnx-editor/large-files--open 'find-file-noselect))
        (should (advice-member-p 'drgnx-editor/large-files--server 'server-execute))
        (should (advice-member-p 'drgnx-editor/large-files--not-large 'eglot-ensure))
        (should (advice-member-p 'drgnx-editor/large-files--no-parser 'normal-mode))
        (dolist (id '(large-file-open-chunks large-file-open-whole large-file-open-raw))
          (should (drgnx-commands-get id)))
        (should global-so-long-mode))
      (should-not (drgnx-config-defined-p 'large-files))
      (should-not (drgnx-config-defined-p 'large-files-project))
      (should (= (drgnx-cache-size 'drgnx-large-files--answers) 0))
      (should (equal large-file-warning-threshold before))
      (should-not (advice-member-p 'drgnx-editor/large-files--open 'find-file-noselect))
      (should-not (advice-member-p 'drgnx-editor/large-files--server 'server-execute))
      (should-not (advice-member-p 'drgnx-editor/large-files--not-large 'eglot-ensure))
      (should-not (advice-member-p 'drgnx-editor/large-files--no-parser 'normal-mode))
      (dolist (id '(large-file-open-chunks large-file-open-whole large-file-open-raw))
        (should-not (drgnx-commands-get id)))
      (should-not (memq 'drgnx-editor/large-files--sweep (default-value 'find-file-hook)))
      (should-not (memq 'drgnx-editor/large-files--revert (default-value 'after-revert-hook)))
      (should-not (memq 'drgnx-editor/large-files--before-revert (default-value 'before-revert-hook)))
      (should-not (memq 'drgnx-editor/large-files--major-mode (default-value 'after-change-major-mode-hook)))
      (should-not global-so-long-mode)
      (should (equal (default-value 'so-long-minor-modes) so-long-before)))))

;;; large-files-test.el ends here
