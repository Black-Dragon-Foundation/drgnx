;;; large-files-chunks-test.el --- batch tests: large files in chunks (vlf) -*- lexical-binding: t -*-
;; vlf comes from the user's ELPA, read-only (DRGNX_USER_ELPA, else ~/.config/emacs/elpa), as
;; `drgnx-extras/with-packages-they-run' finds packages; every test that needs it skips without it.  No large file is
;; ever written: :ask-above 16 KiB, :chunks-above 64 KiB, :chunk-size 32 KiB and a file of 128 KiB.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-guard)
(require 'drgnx-large-file)
(require 'drgnx-agents)
(require 'so-long)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
;; the status bar is loaded first: editor/large-files defines its segment in its setup when the bar is there
(load (expand-file-name "modules/ui/drgnx-face" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-statusbar" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-dir) nil t)   ; Replace skips a file open in chunks

(defconst drgnx-large-files-chunks-test--vlf
  (let ((elpa (expand-file-name (or (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa"))))
    (and (file-directory-p elpa) (car (directory-files elpa t "\\`vlf-[0-9]"))))
  "vlf's folder in the user's ELPA, or nil.")

(when drgnx-large-files-chunks-test--vlf
  (add-to-list 'load-path drgnx-large-files-chunks-test--vlf)
  (require 'vlf))                       ; its top level (advice on scroll-up/down) is the library's, before any test

(defvar drgnx-large-files-chunk-open-function)
(defvar drgnx-large-file-mode)
(defvar vlf-mode)
(defvar drgnx-large-files--header)
(defvar drgnx-large-files-chunks-test--dir nil "The running test's folder of generated files.")
(defvar drgnx-large-files-chunks-test--asked nil "The questions asked in the running test.")

(defmacro drgnx-large-files-chunks-test--with (&rest body)
  "BODY with vlf found, editor/large-files and editor/large-files-chunks set up (strictly), the test sizes in
large-files.eld and `drgnx-large-files-chunks-test--dir' a fresh folder whose buffers are killed after."
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless drgnx-large-files-chunks-test--vlf)
     (drgnx-test-with-config
       (drgnx-test-with-modules '(editor/large-files editor/large-files-chunks) :strict t
                                (drgnx-test-config-put
                                 'large-files "(:version 1 :ask-above 0.015625 :chunks-above 0.0625 :chunk-size 0.03125)")
                                (let ((drgnx-large-files-chunks-test--dir
                                       (file-name-as-directory (make-temp-file "drgnx-lf-chunks" t))))
                                  (unwind-protect (progn ,@body)
                                    (drgnx-large-files-chunks-test--kill)
                                    (delete-directory drgnx-large-files-chunks-test--dir t)))))))

(defun drgnx-large-files-chunks-test--kill ()
  "Kill the buffers visiting the test folder's files, unasked."
  (let ((kill-buffer-query-functions nil))
    (dolist (b (buffer-list))
      (let ((f (buffer-local-value 'buffer-file-name b)))
        (when (and f (string-prefix-p drgnx-large-files-chunks-test--dir (expand-file-name f)))
          (with-current-buffer b (set-buffer-modified-p nil))
          (kill-buffer b))))))

(defun drgnx-large-files-chunks-test--file (name bytes)
  "Write file NAME in the test folder: BYTES bytes of 64-byte lines, each its line number (from 0); its name."
  (let ((file (expand-file-name name drgnx-large-files-chunks-test--dir)) (coding-system-for-write 'utf-8-unix))
    (with-temp-buffer
      (dotimes (i (/ bytes 64)) (insert (format "%063d\n" i)))
      (write-region nil nil file nil 'silent))
    file))

(defun drgnx-large-files-chunks-test--no-question (&rest args)
  (push args drgnx-large-files-chunks-test--asked)
  (error "A question was asked: %S" args))

(defun drgnx-large-files-chunks-test--open (file)
  "FILE opened from an automatic path (no command, `drgnx-automatic'); it fails when a question was asked."
  (let ((drgnx-large-files-chunks-test--asked nil) (this-command nil))
    (dolist (f '(read-multiple-choice y-or-n-p yes-or-no-p))
      (advice-add f :override #'drgnx-large-files-chunks-test--no-question '((depth . 100))))
    (unwind-protect (prog1 (drgnx-automatic (find-file-noselect file)) (should-not drgnx-large-files-chunks-test--asked))
      (dolist (f '(read-multiple-choice y-or-n-p yes-or-no-p))
        (advice-remove f #'drgnx-large-files-chunks-test--no-question)))))

(defun drgnx-large-files-chunks-test--first-line ()
  "The number on the chunk's first line."
  (save-excursion (goto-char (point-min)) (string-to-number (buffer-substring (point) (line-end-position)))))

(defun drgnx-large-files-chunks-test--run (id)
  "Run command ID as the registry has it, as a key would."
  (call-interactively (drgnx-cmd-command (drgnx-commands-get id))))

(defun drgnx-large-files-chunks-test--segment ()
  "The status bar's `large-file' segment as the bar defines it, in the current buffer."
  (funcall (plist-get (gethash 'large-file drgnx-statusbar--segments) :fn)))

(ert-deftest drgnx-large-files-chunks/an-automatic-open-gives-chunks-not-displayed ()
  (drgnx-large-files-chunks-test--with
    (let* ((f (drgnx-large-files-chunks-test--file "big.log" 131072))
           (shown (window-buffer (selected-window))) (current (current-buffer))
           (buf (drgnx-large-files-chunks-test--open f)))
      (should (eq (window-buffer (selected-window)) shown))
      (should (eq (current-buffer) current))
      (should-not (get-buffer-window buf t))
      (with-current-buffer buf
        (should (eq drgnx-large-file 'chunks))
        (should vlf-mode)
        (should (equal buffer-file-name (expand-file-name f))))
      ;; a second open finds the chunk buffer, without a question
      (should (eq (drgnx-large-files-chunks-test--open f) buf)))))

(ert-deftest drgnx-large-files-chunks/a-chunk-holds-chunk-size-bytes ()
  (drgnx-large-files-chunks-test--with
    (let ((f (drgnx-large-files-chunks-test--file "big.log" 131072)))
      (with-current-buffer (drgnx-large-files-chunks-test--open f)
        (should (= (buffer-size) 32768))
        (should (equal (buffer-string) (with-temp-buffer (insert-file-contents f nil 0 32768) (buffer-string))))
        (should (equal (drgnx-large-files-chunks-position) '(1 . 4)))
        (should (drgnx-large-files-chunks-p))))))

(ert-deftest drgnx-large-files-chunks/next-and-previous-move ()
  (drgnx-large-files-chunks-test--with
    (with-current-buffer (drgnx-large-files-chunks-test--open (drgnx-large-files-chunks-test--file "big.log" 131072))
      (should (= (drgnx-large-files-chunks-test--first-line) 0))
      (drgnx-large-files-chunks-test--run 'large-file-next-chunk)
      (should (equal (drgnx-large-files-chunks-position) '(2 . 4)))
      (should (= (drgnx-large-files-chunks-test--first-line) 512))   ; 32 KiB of 64-byte lines further
      (should (= (buffer-size) 32768))
      (drgnx-large-files-chunks-test--run 'large-file-previous-chunk)
      (should (equal (drgnx-large-files-chunks-position) '(1 . 4)))
      (should (= (drgnx-large-files-chunks-test--first-line) 0)))))

(ert-deftest drgnx-large-files-chunks/undo-is-on-auto-save-off ()
  (drgnx-large-files-chunks-test--with
    (with-current-buffer (drgnx-large-files-chunks-test--open (drgnx-large-files-chunks-test--file "big.log" 131072))
      (should-not drgnx-large-file-mode)             ; vlf runs no `find-file-hook': the lean sweep never sees it
      (should-not buffer-auto-save-file-name)
      (should-not (eq buffer-undo-list t))
      (goto-char (point-min))
      (insert "edit")
      (should (consp buffer-undo-list)))))

(ert-deftest drgnx-large-files-chunks/agents-never-get-the-chunk ()
  (drgnx-large-files-chunks-test--with
    (let* ((f (drgnx-large-files-chunks-test--file "big.log" 131072))
           (disk (with-temp-buffer (insert-file-contents f) (buffer-string)))
           (s (drgnx-agents--make :cwd drgnx-large-files-chunks-test--dir)))
      (with-current-buffer (drgnx-large-files-chunks-test--open f)
        (goto-char (point-min))
        (insert "CHUNK EDIT"))
      (should (equal (plist-get (plist-get (drgnx-agents--on-request s "fs/read_text_file" (list :path f) 1) :result)
                                :content)
                     disk)))))

(ert-deftest drgnx-large-files-chunks/the-header-in-a-chunk-buffer ()
  (drgnx-large-files-chunks-test--with
    (let* ((f (drgnx-large-files-chunks-test--file "big.log" 131072))
           (size (drgnx-large-files--size-text 131072))
           (buf (drgnx-large-files-chunks-test--open f)))
      (with-current-buffer buf
        (should (eq header-line-format 'drgnx-large-files--header))
        (should (equal (substring-no-properties drgnx-large-files--header)
                       (format " %s, in chunks: [Open Whole] [Open Raw]" size)))
        (cl-letf (((symbol-function 'drgnx-ui-ascii-frame-p) (lambda (&optional _frame) nil)))
          (should (equal (drgnx-large-files-chunks-test--segment) (concat size " · chunk 1/4")))
          (drgnx-large-files-chunks-test--run 'large-file-next-chunk)
          (should (equal (drgnx-large-files-chunks-test--segment) (concat size " · chunk 2/4")))))
      ;; Open Whole from the chunk buffer: lean, in the window the chunks were in
      (let ((old (window-buffer (selected-window))))
        (set-window-buffer (selected-window) buf)
        (unwind-protect
            (progn
              (with-current-buffer buf (drgnx-large-files-chunks-test--run 'large-file-open-whole))
              (should-not (buffer-live-p buf))
              (with-current-buffer (window-buffer (selected-window))
                (should (equal buffer-file-name (expand-file-name f)))
                (should (eq drgnx-large-file 'lean))
                (should (string-search ", lean: [Open in Chunks] [Open Raw]" drgnx-large-files--header))))
          (when (buffer-live-p old) (set-window-buffer (selected-window) old)))))))

(defmacro drgnx-large-files-chunks-test--never-asks (&rest body)
  "BODY with every question failing; it fails when one was asked, even if caught."
  (declare (indent 0) (debug t))
  `(let ((drgnx-large-files-chunks-test--asked nil))
     (dolist (f '(read-multiple-choice y-or-n-p yes-or-no-p))
       (advice-add f :override #'drgnx-large-files-chunks-test--no-question '((depth . 100))))
     (unwind-protect (prog1 (progn ,@body) (should-not drgnx-large-files-chunks-test--asked))
       (dolist (f '(read-multiple-choice y-or-n-p yes-or-no-p))
         (advice-remove f #'drgnx-large-files-chunks-test--no-question)))))

(defun drgnx-large-files-chunks-test--disk (file)
  "FILE's bytes on disk."
  (with-temp-buffer (insert-file-contents-literally file) (buffer-string)))

(ert-deftest drgnx-large-files-chunks/replace-never-writes-a-file-open-in-chunks ()
  ;; rg's match is at the whole file's line 10; on chunk 2 the buffer's line 10 is the file's line 522, and starts
  ;; with the same ten zeros: Replace must not write there, and the row's Show must not mark it
  (drgnx-large-files-chunks-test--with
    (let* ((f (drgnx-large-files-chunks-test--file "big.log" 131072))
           (disk (drgnx-large-files-chunks-test--disk f))
           (buf (drgnx-large-files-chunks-test--open f))
           (m (list :file f :line 10 :col 0 :text "0000000000")))
      (with-current-buffer buf
        (drgnx-large-files-chunks-test--run 'large-file-next-chunk)
        (should (equal (drgnx-large-files-chunks-position) '(2 . 4))))
      (drgnx-large-files-chunks-test--never-asks
        (pcase-let ((`(,n ,skipped ,undo) (drgnx-replace--apply-file f (list m) "XXXXXXXXXX")))
          (should (= n 0))
          (should-not undo)
          (should (equal (mapcar (lambda (s) (plist-get s :reason)) skipped)
                         '("open in chunks: Large File: Open Whole first")))))
      (should-not (buffer-modified-p buf))
      (should (equal (drgnx-large-files-chunks-test--disk f) disk))
      (with-temp-buffer                     ; the Replace view
        (let ((said nil))
          (cl-letf* (((symbol-function 'drgnx-wb-show-in-editor) (lambda (_buf _select) (selected-window)))
                     (orig (symbol-function 'message))
                     ((symbol-function 'message)
                      (lambda (fmt &rest args)
                        (when fmt (push (apply #'format fmt args) said))
                        (apply orig fmt args))))
            (drgnx-replace--show-match m nil))
          (should-not drgnx-replace--shown)
          (should (member "big.log is open in chunks: Large File: Open Whole first" said)))))))

(ert-deftest drgnx-large-files-chunks/auto-save-visited-never-saves-a-chunk ()
  ;; the user's `auto-save-visited-mode' would save a modified chunk from its timer, and vlf asks when the size changed
  (drgnx-large-files-chunks-test--with
    (let* ((f (drgnx-large-files-chunks-test--file "big.log" 131072))
           (disk (drgnx-large-files-chunks-test--disk f))
           (buf (drgnx-large-files-chunks-test--open f)))
      (with-current-buffer buf (goto-char (point-min)) (insert "edit"))
      (unwind-protect
          (progn
            (auto-save-visited-mode 1)
            (drgnx-large-files-chunks-test--never-asks
              (apply (timer--function auto-save--timer) (timer--args auto-save--timer))))
        (auto-save-visited-mode -1))
      (should (buffer-modified-p buf))
      (should (equal (drgnx-large-files-chunks-test--disk f) disk)))))

(ert-deftest drgnx-large-files-chunks/off-on-off-leaves-nothing ()
  (skip-unless drgnx-large-files-chunks-test--vlf)
  (dotimes (_ 2)
    (drgnx-large-files-chunks-test--with
      (should (eq (plist-get (alist-get 'editor/large-files-chunks (drgnx-modules-report)) :status) 'ok))
      (should (eq drgnx-large-files-chunk-open-function #'drgnx-large-files-chunks-open))
      (dolist (id '(large-file-next-chunk large-file-previous-chunk large-file-go-to-line large-file-search))
        (should (drgnx-commands-get id)))
      (let ((buf (drgnx-large-files-chunks-test--open (drgnx-large-files-chunks-test--file "big.log" 131072))))
        ;; turned off, both modules leave the chunk buffer as it is: vlf's
        (drgnx-module-teardown 'editor/large-files-chunks)
        (drgnx-module-teardown 'editor/large-files)
        (should-not drgnx-large-files-chunk-open-function)
        (should-not (drgnx-commands-get 'large-file-next-chunk))
        (with-current-buffer buf
          (should vlf-mode)
          (should (eq drgnx-large-file 'chunks))
          (should-not (eq buffer-undo-list t))))))
  (should-not drgnx-large-files-chunk-open-function)
  (should-not (drgnx-commands-get 'large-file-next-chunk)))

(ert-deftest drgnx-large-files-chunks/without-vlf-the-module-waits ()
  ;; runs everywhere: vlf is hidden whether or not it is installed
  (drgnx-test-with-config
    (drgnx-test-with-modules '(editor/large-files editor/large-files-chunks) :strict t :packages hidden
                             (should (eq (plist-get (alist-get 'editor/large-files-chunks (drgnx-modules-report)) :status)
                                         'missing-packages))
                             (should (eq (plist-get (alist-get 'editor/large-files (drgnx-modules-report)) :status) 'ok))
                             (should-not drgnx-large-files-chunk-open-function)
                             (should-not (drgnx-commands-get 'large-file-next-chunk)))))

;;; large-files-chunks-test.el ends here
