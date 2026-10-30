;;; mod-markdown-test.el --- batch tests: Markdown — GFM for READMEs, a preview, Mermaid through mmdc as a job -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)

(defconst drgnx-markdown-test--elpa (expand-file-name (or (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa")))

(defun drgnx-markdown-test--available-p ()
  (and (file-directory-p drgnx-markdown-test--elpa) (directory-files drgnx-markdown-test--elpa nil "\\`markdown-mode-[0-9]")))

(defmacro drgnx-markdown-test--with (&rest body)
  "BODY with markdown-mode from the user's ELPA, the module set up and, after, turned off (strictly), drgnx's cache in a temp dir."
  (declare (indent 0))
  `(progn
     (skip-unless (drgnx-markdown-test--available-p))
     (let* ((load-path (append load-path (seq-filter #'file-directory-p (directory-files drgnx-markdown-test--elpa t "\\`markdown-mode-"))))
            (tmp (file-name-as-directory (make-temp-file "drgnx-md" t)))
            (process-environment (cons (concat "XDG_CACHE_HOME=" tmp "cache") process-environment)))
       (unwind-protect
           (drgnx-test-with-modules '(lang/markdown) :strict t
                                    (clrhash drgnx-markdown--drawing) (clrhash drgnx-markdown--failed)   ; each test's diagrams its own
                                    (unwind-protect (progn ,@body)
                                      (dolist (b (buffer-list))
                                        (when (or (string-prefix-p "*markdown preview" (buffer-name b))
                                                  (equal (buffer-name b) " *string-pixel-width*")   ; shr's work buffer
                                                  (string-prefix-p " *work*" (buffer-name b))      ; Emacs 31's pooled work buffer (`with-work-buffer')
                                                  (and (buffer-file-name b) (string-prefix-p tmp (buffer-file-name b))))
                                          (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))))
         (delete-directory tmp t)))))

(defun drgnx-markdown-test--wait (pred &optional secs)
  (drgnx-test-wait pred :secs (max 30 (or secs 0)) :what "the preview's condition"))

(defconst drgnx-markdown-test--doc "# Title\n\nSome *text*.\n\n```mermaid\ngraph TD; A-->B\n```\n")

(ert-deftest drgnx-markdown/readme-is-gfm ()
  (drgnx-markdown-test--with
    (let ((f (concat tmp "README.md")) (g (concat tmp "notes.md")))
      (write-region "# R\n" nil f nil 'silent) (write-region "# N\n" nil g nil 'silent)
      (with-current-buffer (find-file-noselect f) (should (eq major-mode 'gfm-mode)))
      (with-current-buffer (find-file-noselect g) (should (eq major-mode 'markdown-mode))
                           (should markdown-fontify-code-blocks-natively) (should markdown-enable-math)))))

(defcustom drgnx-markdown-test-fake-option 'standard "A stand-in for a package's option." :type 'symbol)
(defcustom drgnx-markdown-test-fake-other 'standard "A second stand-in." :type 'symbol)

(ert-deftest drgnx-markdown/an-option-the-user-set-is-left-alone ()
  ;; the module loaded here: without markdown-mode (CI) no earlier test of this file has loaded it
  (drgnx-test-with-modules '(lang/markdown)
    (let ((drgnx-markdown-test-fake-option 'user) (drgnx-markdown-test-fake-other 'standard))
      (drgnx-markdown--set-option 'drgnx-markdown-test-fake-option 'module)
      (drgnx-markdown--set-option 'drgnx-markdown-test-fake-other 'module)
      (should (eq drgnx-markdown-test-fake-option 'user))
      (should (eq drgnx-markdown-test-fake-other 'module)))))

(ert-deftest drgnx-markdown/turned-off-the-options-and-file-modes-are-back ()
  (skip-unless (drgnx-markdown-test--available-p))
  (let ((load-path (append load-path (seq-filter #'file-directory-p (directory-files drgnx-markdown-test--elpa t "\\`markdown-mode-")))))
    (require 'markdown-mode)
    (let ((math markdown-enable-math) (modes auto-mode-alist))
      (drgnx-test-with-modules '(lang/markdown) :strict t
                               (should (eq markdown-enable-math t))
                               (should (eq (cdr (assoc "/README\\.md\\'" auto-mode-alist)) 'gfm-mode)))
      (should (eq markdown-enable-math math))
      (should (equal auto-mode-alist modes)))))

(ert-deftest drgnx-markdown/preview-without-a-program-uses-view-mode ()
  (drgnx-markdown-test--with
    (cl-letf (((symbol-function 'drgnx-markdown--program) (lambda () nil)))
      (with-temp-buffer
        (markdown-mode) (insert "# Hello\n")
        (let ((p (drgnx-markdown-preview)))
          (should (eq (buffer-local-value 'major-mode p) 'markdown-view-mode))
          (should (string-search "Hello" (with-current-buffer p (buffer-string)))))))))

(ert-deftest drgnx-markdown/mermaid-is-a-job-when-mmdc-is-there ()
  (drgnx-markdown-test--with
    (let ((jobs nil))
      (cl-letf (((symbol-function 'executable-find) (lambda (p &rest _) (and (equal p "mmdc") "/usr/bin/mmdc")))
                ((symbol-function 'drgnx-jobs-start) (lambda (name cmd &rest _) (push (cons name cmd) jobs) "J"))
                ((symbol-function 'drgnx-markdown--watch) #'ignore))
        (let* ((src (drgnx-markdown--with-diagrams drgnx-markdown-test--doc))
               (job (car jobs)) (png (nth (1+ (seq-position (cdr job) "-o")) (cdr job))))
          (should (equal (car job) "mermaid"))
          (should (member "-i" (cdr job)))
          (should (string-prefix-p (drgnx-markdown--diagram-dir) png))
          (should (string-search "```mermaid" src))                       ; not drawn yet: the block as it is
          ;; drawn: the next preview shows the picture and starts nothing
          (make-directory (file-name-directory png) t)
          (write-region "png" nil png nil 'silent)
          (let ((again (drgnx-markdown--with-diagrams drgnx-markdown-test--doc)))
            (should (= 1 (length jobs)))
            (should (string-search (concat "![diagram](file://" png ")") again))   ; a URL shr can fetch
            (should-not (string-search "```mermaid" again))))))))

(ert-deftest drgnx-markdown/without-mmdc-diagrams-stay-code ()
  (drgnx-markdown-test--with
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil))
              ((symbol-function 'drgnx-jobs-start) (lambda (&rest _) (error "No job without mmdc"))))
      (should (equal (drgnx-markdown--with-diagrams drgnx-markdown-test--doc) drgnx-markdown-test--doc)))))

(ert-deftest drgnx-markdown/preview-through-pandoc ()
  (skip-unless (and (executable-find "pandoc") (fboundp 'libxml-parse-html-region)))
  (drgnx-markdown-test--with
    (with-temp-buffer
      (markdown-mode) (insert "# Title\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
      (let ((p (drgnx-markdown-preview)))
        (should (drgnx-markdown-test--wait (lambda () (string-search "Title" (with-current-buffer p (buffer-string))))))   ; in the background
        (with-current-buffer p
          (should-not (string-search "# Title" (buffer-string)))       ; rendered, not the source
          (should (eq major-mode 'special-mode)))))))

(ert-deftest drgnx-markdown/a-diagram-that-fails-is-not-drawn-again ()
  (drgnx-markdown-test--with
    (let ((jobs 0))
      (cl-letf (((symbol-function 'executable-find) (lambda (p &rest _) (and (equal p "mmdc") "/usr/bin/mmdc")))
                ((symbol-function 'drgnx-jobs-start) (lambda (&rest _) (cl-incf jobs) "J"))
                ((symbol-function 'drgnx-markdown--watch) #'ignore))
        (drgnx-markdown--with-diagrams drgnx-markdown-test--doc)
        (should (= jobs 1))
        (drgnx-markdown--drawn (car (hash-table-keys drgnx-markdown--drawing)) 1)   ; mmdc failed
        (should (equal (drgnx-markdown--with-diagrams drgnx-markdown-test--doc) drgnx-markdown-test--doc))
        (should (= jobs 1))))))

(ert-deftest drgnx-markdown/the-preview-is-made-in-the-background-without-stderr ()
  (drgnx-markdown-test--with
    (let ((drgnx-markdown-programs '(("sh" "-c" "cat >/dev/null; sleep 0.3; echo '<p>made</p>'; echo WARNING >&2"))))
      (with-temp-buffer
        (markdown-mode) (insert "# Hello\n")
        (let* ((p (drgnx-markdown-preview)))
          (should-not (string-search "made" (with-current-buffer p (buffer-string))))   ; it did not wait for the program
          (should (drgnx-markdown-test--wait (lambda () (string-search "made" (with-current-buffer p (buffer-string))))))
          (should-not (string-search "WARNING" (with-current-buffer p (buffer-string)))))))))

(ert-deftest drgnx-markdown/the-preview-key-is-local-to-markdown-mode ()
  ;; M11a-1: the command carries the keymap, so the VS Code profile's C-S-v binds in markdown-mode-map, not globally.
  (drgnx-markdown-test--with
    (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
      (drgnx-markdown--define-command)
      (let* ((profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir)))
             (r (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles profiles :layers '((vscode app editing window))
                                    :defaults (copy-keymap global-map)))
             (b (seq-find (lambda (b) (eq (plist-get b :id) 'markdown-preview)) (plist-get r :bindings))))
        (should (equal (plist-get b :key) "C-S-v"))
        (should (equal (plist-get b :map) '(markdown-mode . markdown-mode-map)))))))

(ert-deftest drgnx-markdown/saves-in-a-row-render-once-after-a-pause ()
  (drgnx-markdown-test--with
    (drgnx-test-with-clock ()
      (let ((rendered nil) (a (generate-new-buffer " md-a")) (drgnx-markdown--pending nil))
        (unwind-protect
            (cl-letf (((symbol-function 'drgnx-markdown--render) (lambda (src prev) (push (cons src prev) rendered))))
              (with-current-buffer a (setq-local drgnx-markdown--source a))
              (dotimes (_ 3) (with-current-buffer a (drgnx-markdown--after-save)))
              (should (drgnx-timer-active-p 'markdown-render))
              (drgnx-test-advance 5)
              (should-not rendered)                                   ; idle time, not wall time
              (drgnx-test-idle 0.2)
              (should (= 1 (length rendered)))
              (should-not drgnx-markdown--pending)
              ;; a later save is scheduled again (a timer that once died never blocks it)
              (with-current-buffer a (drgnx-markdown--after-save))
              (drgnx-test-idle 0.2)
              (should (= 2 (length rendered))))
          (kill-buffer a))))))

(ert-deftest drgnx-markdown/a-diagram-job-is-watched-until-it-ends-or-ten-minutes ()
  (drgnx-markdown-test--with
    (drgnx-test-with-clock ()
      (let ((job (list :status 'running)) (drawn nil))
        (cl-letf (((symbol-function 'drgnx-jobs-get) (lambda (_id) job))
                  ((symbol-function 'drgnx-markdown--drawn) (lambda (hash exit) (push (list hash exit) drawn))))
          (drgnx-markdown--watch "J1" "h1")
          (drgnx-markdown--watch "J2" "h2")
          (drgnx-test-advance 4)
          (should-not drawn)
          (setq job (list :status 'exited :exit 0))
          (drgnx-test-advance 2)
          (should (equal (sort (mapcar #'car drawn) #'string<) '("h1" "h2")))
          (should (equal (mapcar #'cadr drawn) '(0 0)))
          (should-not (drgnx-timer-active-p '(markdown-watch . "J1"))))
        ;; a job that never ends: after ten minutes the diagram stays code
        (setq job (list :status 'running) drawn nil)
        (cl-letf (((symbol-function 'drgnx-jobs-get) (lambda (_id) job))
                  ((symbol-function 'drgnx-markdown--drawn) (lambda (hash exit) (push (list hash exit) drawn))))
          (drgnx-markdown--watch "J3" "h3")
          (drgnx-test-advance 598)
          (should-not drawn)
          (drgnx-test-advance 4)
          (should (equal drawn '(("h3" 1))))
          (should-not (drgnx-timer-active-p '(markdown-watch . "J3"))))))))

;;; mod-markdown-test.el ends here
