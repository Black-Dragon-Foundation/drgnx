;;; mod-tty-frames-test.el --- batch tests: ui/terminal — what a terminal frame can do, the terminal report -*- lexical-binding: t -*-
;; Batch Emacs has no terminal to ask: terminals, their parameters and the query are stubbed; the tty tier
;; (test/tty/frames-test.el) runs the real thing.
(require 'ert)
(require 'drgnx)
(load (expand-file-name "modules/ui/drgnx-tty-frames" drgnx-dir) nil t)

(defvar drgnx-tty-frames-test--term 'kx-a "The terminal `frame-terminal' answers in these tests.")

(defmacro drgnx-tty-frames-test--terminal (params env &rest body)
  "BODY with the fake terminal kx-a holding PARAMS (an alist), every frame's client environment ENV (\"K=V\"
strings; the real frame is not touched), an empty cache and no terminal to ask: `asked' counts the questions.
`drgnx-tty-frames-test--term' names the terminal of the selected frame."
  (declare (indent 2))
  `(let ((table (make-hash-table :test #'equal))
         (drgnx-tty-frames--cache (make-hash-table :test #'equal))
         (drgnx-tty-frames-test--term 'kx-a)
         (real-frame-parameter (symbol-function 'frame-parameter))
         (asked 0))
     (pcase-dolist (`(,k . ,v) ,params) (puthash (cons 'kx-a k) v table))
     (cl-letf (((symbol-function 'frame-parameter)
                (lambda (f p) (if (eq p 'environment) ,env (funcall real-frame-parameter f p))))
               ((symbol-function 'frame-terminal) (lambda (&optional _) drgnx-tty-frames-test--term))
               ((symbol-function 'terminal-name) (lambda (&optional term) (symbol-name term)))
               ((symbol-function 'terminal-live-p) (lambda (_term) t))
               ((symbol-function 'terminal-parameter)
                (lambda (term p) (gethash (cons (or term drgnx-tty-frames-test--term) p) table)))
               ((symbol-function 'set-terminal-parameter)
                (lambda (term p v) (puthash (cons (or term drgnx-tty-frames-test--term) p) v table)))
               ((symbol-function 'drgnx-tty-frames--ask) (lambda (_frame) (setq asked (1+ asked)) nil))
               ((symbol-function 'display-color-cells) (lambda (&optional _) 256)))
       ,@body)))

(defmacro drgnx-tty-frames-test--state (&rest body)
  "BODY with the state dir (XDG_STATE_HOME) a temp dir, `state'."
  `(let* ((state (make-temp-file "drgnx-tty-frames" t))
          (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment)))
     (unwind-protect (progn ,@body)
       (delete-directory state t))))

(defun drgnx-tty-frames-test--report ()
  (with-temp-buffer
    (insert-file-contents (drgnx-tty-frames--report-file))
    (read (current-buffer))))

(ert-deftest drgnx-tty-frames/caps-of-a-modify-other-keys-terminal ()
  ;; xterm.el turned modifyOtherKeys on (its set string is among the terminal's mode strings)
  (drgnx-tty-frames-test--terminal '((tty-mode-set-strings . ("\e[?2004h" "\e[>4;1m"))) '("TERM=xterm-256color" "XTERM_VERSION=XTerm(397)")
    (let ((caps (drgnx-tty-frame-caps)))
      (should (eq (plist-get caps :keys) 'mok))
      (should (eq (plist-get caps :id) 'xterm))
      (should (eq (plist-get caps :colors) 256))
      (should (equal (terminal-parameter nil 'drgnx-tty-caps) caps))))
  ;; without it, and without kkp, the terminal is legacy; the client's environment names it, not the daemon's
  (drgnx-tty-frames-test--terminal nil '("TERM=xterm-256color" "VTE_VERSION=8000")
    (let ((caps (drgnx-tty-frame-caps)))
      (should (eq (plist-get caps :keys) 'legacy))
      (should (eq (plist-get caps :id) 'vte))))
  ;; Task 5's module marks the terminal when kkp is on
  (drgnx-tty-frames-test--terminal '((drgnx-tty-kkp . t) (tty-mode-set-strings . ("\e[>4;1m"))) '("TERM=xterm-kitty")
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'kkp))))

(ert-deftest drgnx-tty-frames/only-the-identity-is-cached ()
  ;; two terminals of one kind: asked once, but each has its own keys and colours, read again on every call
  (drgnx-tty-frames-test--terminal '((tty-mode-set-strings . ("\e[>4;1m"))) '("TERM=xterm-kitty")
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'mok))
    (let ((drgnx-tty-frames-test--term 'kx-b))
      (cl-letf (((symbol-function 'display-color-cells) (lambda (&optional _) 16777216)))
        (let ((caps (drgnx-tty-frame-caps)))
          (should (eq (plist-get caps :id) 'kitty))
          (should (eq (plist-get caps :keys) 'legacy))
          (should (eq (plist-get caps :colors) 16777216)))))
    (should (= asked 1))
    ;; kkp turned on later (Task 5): the same terminal's caps follow
    (set-terminal-parameter nil 'drgnx-tty-kkp t)
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'kkp))
    (should (= asked 1))))

(ert-deftest drgnx-tty-frames/a-late-version-answer-is-picked-up ()
  ;; the answer came after the 0.2 s wait: xterm.el's handler stored it; the next look reads it, asking nothing
  (drgnx-tty-frames-test--terminal nil '("TERM=xterm-256color")
    (should (equal (plist-get (drgnx-tty-frame-caps) :id) 'unknown))
    (set-terminal-parameter nil 'drgnx-tty-xtversion "\eP>|WezTerm 20240203\e\\")
    (let ((caps (drgnx-tty-frame-caps)))
      (should (eq (plist-get caps :id) 'wezterm))
      (should (equal (plist-get caps :version) "20240203")))
    (should (= asked 1))))

(ert-deftest drgnx-tty-frames/the-report-lists-what-this-terminal-cannot-send ()
  (drgnx-tty-frames-test--state
   (let* ((vscode (alist-get 'vscode (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))))
          (drgnx-keys-last (list :layers '((vscode app editing window))
                                 :bindings (mapcan (lambda (e) (mapcar (lambda (k) (list :id (car e) :key k))
                                                                       (seq-take-while #'stringp (cdr e))))
                                                   (plist-get vscode :bind)))))
     (cl-letf (((symbol-function 'drgnx-tty-frame-caps)
                (lambda (&optional _) '(:id vte :outer nil :version "8000" :keys legacy :osc52 nil :colors 256
                                            :mouse t))))
       (drgnx-tty-frames-write-report (selected-frame))
       (let* ((report (drgnx-tty-frames-test--report))
              (entry (cdr (car (plist-get report :terminals))))
              (unsendable (plist-get entry :unsendable)))
         (should (= (length (plist-get report :terminals)) 1))
         (should (eq (plist-get (plist-get entry :caps) :keys) 'legacy))
         (should (stringp (plist-get entry :seen)))
         (should (member "C-S-p" unsendable))
         (should (member "C-`" unsendable))
         (should-not (member "C-p" unsendable))
         ;; a second report of the same terminal replaces its entry
         (drgnx-tty-frames-write-report (selected-frame))
         (should (= (length (plist-get (drgnx-tty-frames-test--report) :terminals)) 1)))))))

(ert-deftest drgnx-tty-frames/kkp-later-rewrites-the-report ()
  ;; Task 5 turns kkp on after the terminal's setup: refreshing the report says so, and C-S-p is sendable then
  (drgnx-tty-frames-test--state
   (drgnx-tty-frames-test--terminal nil '("TERM=xterm-kitty")
     (let ((drgnx-keys-last '(:bindings ((:id palette :key "C-S-p")))))
       (drgnx-tty-frames-write-report (selected-frame))
       (should (equal (plist-get (cdr (assoc "kx-a" (plist-get (drgnx-tty-frames-test--report) :terminals))) :unsendable)
                      '("C-S-p")))
       (set-terminal-parameter nil 'drgnx-tty-kkp t)
       (drgnx-tty-frames-refresh-report (selected-frame))
       (let ((entry (cdr (assoc "kx-a" (plist-get (drgnx-tty-frames-test--report) :terminals)))))
         (should (eq (plist-get (plist-get entry :caps) :keys) 'kkp))
         (should-not (plist-get entry :unsendable)))))))

(ert-deftest drgnx-tty-frames/the-report-is-written-past-a-lock-and-a-corrupt-file ()
  ;; another Emacs's lock on the report, or a broken report, never makes a daemon hook ask or fail
  (drgnx-tty-frames-test--state
   (drgnx-tty-frames-test--terminal nil '("TERM=xterm-kitty")
     (let* ((file (drgnx-tty-frames--report-file))
            (lock (expand-file-name (concat ".#" (file-name-nondirectory file)) (file-name-directory file))))
       (make-directory (file-name-directory file) t)
       (write-region "(:terminals 5)\n" nil file nil 'silent)
       (make-symbolic-link "someone@elsewhere.example.4242:1700000000" lock)
       (cl-letf (((symbol-function 'ask-user-about-lock) (lambda (&rest _) (error "Asked about a lock")))
                 ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Asked")))
                 ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "Asked"))))
         (drgnx-tty-frames-write-report (selected-frame)))
       (should (equal (mapcar #'car (plist-get (drgnx-tty-frames-test--report) :terminals)) '("kx-a")))
       ;; only the report and the planted lock: no temporary file is left behind
       (should (equal (sort (directory-files (file-name-directory file) nil "\\`[^.]\\|\\`\\.#") #'string<)
                      (sort (list (file-name-nondirectory lock) (file-name-nondirectory file)) #'string<)))))))

(ert-deftest drgnx-tty-frames/toggle-mouse-is-in-every-profile ()
  (dolist (profile '("vscode" "emacs" "vim"))
    (should (string-search "(terminal-toggle-mouse "
                           (with-temp-buffer
                             (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
                             (buffer-string))))))

(ert-deftest drgnx-tty-frames/toggle-mouse-saves-only-when-run-interactively ()
  (let (saved set (drgnx-tty-mouse t))
    (cl-letf (((symbol-function 'customize-save-variable) (lambda (sym val &rest _) (push (list sym val) saved)))
              ((symbol-function 'customize-set-variable) (lambda (sym val &rest _) (push (list sym val) set)))
              ((symbol-function 'message) #'ignore))
      (drgnx-tty-frames-toggle-mouse)
      (should (equal set '((drgnx-tty-mouse nil))))
      (should-not saved)
      (call-interactively #'drgnx-tty-frames-toggle-mouse)
      (should (equal saved '((drgnx-tty-mouse nil)))))))

(ert-deftest drgnx-tty-frames/the-mouse-is-never-turned-on-without-a-terminal-frame ()
  ;; batch Emacs has no terminal frame: a graphical session never gets xterm-mouse-mode from this module
  (let ((xterm-mouse-mode nil) (drgnx-tty-mouse t))
    (drgnx-tty-frames-mouse-apply)
    (should-not xterm-mouse-mode)))
