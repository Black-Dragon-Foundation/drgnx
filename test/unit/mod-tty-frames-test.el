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
  (drgnx-tty-frames-test--terminal '((tty-mode-set-strings . ("\e[?2004h" "\e[>4;1m")) (drgnx-tty-mok-decoded . t))
      '("TERM=xterm-256color" "XTERM_VERSION=XTerm(397)")
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
  (drgnx-tty-frames-test--terminal '((tty-mode-set-strings . ("\e[>4;1m")) (drgnx-tty-mok-decoded . t)) '("TERM=xterm-kitty")
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

(ert-deftest drgnx-tty-frames/toggle-mouse-is-a-registered-command ()
  (funcall (plist-get (alist-get 'ui/terminal drgnx-modules--table) :setup))
  (let ((c (drgnx-commands-get 'terminal-toggle-mouse)))
    (should c)
    (should (equal (list (drgnx-cmd-category c) (drgnx-cmd-title c) (drgnx-cmd-command c))
                   '("Terminal" "Toggle Mouse in Terminal Windows" drgnx-tty-frames-toggle-mouse)))))

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

;;;; Colours

(defmacro drgnx-tty-frames-test--terminfos (have &rest body)
  "BODY with only the terminal types HAVE (a list) having a true-colour terminfo, nothing cached, the daemon's own
COLORTERM unset and `drgnx-tty-true-colour' t (the terminal need not be a known one).  `asked' lists the
types `infocmp' was asked about."
  (declare (indent 1))
  `(let ((drgnx-tty-frames--direct-cache (make-hash-table :test #'equal))
         (drgnx-tty-true-colour t)
         (process-environment (cons "COLORTERM" process-environment))
         (asked nil))
     (cl-letf (((symbol-function 'drgnx-tty--command-lines)
                (lambda (command &rest _)
                  (push (car (last command)) asked)
                  (if (member (car (last command)) ,have)
                      (list "kx|term," "\tcolors#0x1000000," "\tRGB,")
                    (list "kx|term," "\tcolors#0x100,")))))
       ,@body)))

(ert-deftest drgnx-tty-frames/a-truecolor-client-gets-the-direct-terminfo ()
  (drgnx-tty-frames-test--terminfos '("xterm-direct" "tmux-direct")
    (should (equal (drgnx-tty-frames--true-colour-type "xterm-256color" '("COLORTERM=truecolor")) "xterm-direct"))
    (should (equal (drgnx-tty-frames--true-colour-type "tmux-256color" '("TERM=x" "COLORTERM=24bit")) "tmux-direct"))
    (should (equal (drgnx-tty-frames--true-colour-type "xterm-256color" '("COLORTERM=TrueColor")) "xterm-direct"))
    ;; a type without the suffix
    (should (equal (drgnx-tty-frames--true-colour-type "xterm" '("COLORTERM=truecolor")) "xterm-direct"))))

(ert-deftest drgnx-tty-frames/anything-else-is-left-as-it-is ()
  (drgnx-tty-frames-test--terminfos '("xterm-direct" "foot")
    ;; no COLORTERM, or another value
    (should (equal (drgnx-tty-frames--true-colour-type "xterm-256color" nil) "xterm-256color"))
    (should (equal (drgnx-tty-frames--true-colour-type "xterm-256color" '("COLORTERM=yes")) "xterm-256color"))
    (should (equal (drgnx-tty-frames--true-colour-type "xterm-256color" '("COLORTERM")) "xterm-256color"))
    ;; a terminfo that has true colour already is Emacs's to use
    (should (equal (drgnx-tty-frames--true-colour-type "foot" '("COLORTERM=truecolor")) "foot"))
    ;; no direct variant on this machine
    (should (equal (drgnx-tty-frames--true-colour-type "screen-256color" '("COLORTERM=truecolor")) "screen-256color"))
    ;; the daemon has COLORTERM=truecolor itself: every frame has true colour already
    (let ((process-environment (cons "COLORTERM=truecolor" process-environment)))
      (should (equal (drgnx-tty-frames--true-colour-type "xterm-256color" '("COLORTERM=truecolor")) "xterm-256color")))))

(ert-deftest drgnx-tty-frames/true-colour-means-what-emacs-means-by-it ()
  ;; term.c: the RGB flag, or setf24 and setb24 together; not Tc, not setrgbf, not a numeric RGB#
  (let ((drgnx-tty-frames--direct-cache (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'drgnx-tty--command-lines)
               (lambda (command &rest _)
                 (pcase (car (last command))
                   ("a" (list "a|x," "\tRGB,"))
                   ("b" (list "b|x," "\tsetf24=\\E[38;2m," "\tsetb24=\\E[48;2m,"))
                   ("c" (list "c|x," "\tsetf24=\\E[38;2m,"))
                   ("d" (list "d|x," "\tTc,"))
                   ("e" (list "e|x," "\tsetrgbf=\\E[38;2m,"))
                   ("f" (list "f|x," "\tRGB#8/8/8,"))
                   (_ nil)))))
      (should (drgnx-tty-frames--terminfo-true-colour-p "a"))
      (should (drgnx-tty-frames--terminfo-true-colour-p "b"))
      (dolist (type '("c" "d" "e" "f" "g"))
        (should-not (drgnx-tty-frames--terminfo-true-colour-p type))))))

(ert-deftest drgnx-tty-frames/infocmp-is-asked-once-per-type-and-through-the-bounded-runner ()
  (drgnx-tty-frames-test--terminfos '("xterm-direct")
    (dotimes (_ 3) (drgnx-tty-frames--true-colour-type "xterm-256color" '("COLORTERM=truecolor")))
    (should (equal (sort (copy-sequence asked) #'string<) '("xterm-256color" "xterm-direct")))))

(ert-deftest drgnx-tty-frames/the-runner-is-given-a-timeout-and-the-bare-command ()
  (let ((drgnx-tty-frames--direct-cache (make-hash-table :test #'equal)) seen)
    (cl-letf (((symbol-function 'drgnx-tty--command-lines) (lambda (&rest args) (setq seen args) nil)))
      (drgnx-tty-frames--terminfo-true-colour-p "xterm-256color"))
    (should (equal (car seen) '("infocmp" "-x" "-1" "xterm-256color")))
    (should (numberp (cadr seen)))))

(ert-deftest drgnx-tty-frames/no-infocmp-leaves-the-type ()
  (let ((drgnx-tty-frames--direct-cache (make-hash-table :test #'equal)) (drgnx-tty-true-colour t))
    (cl-letf (((symbol-function 'drgnx-tty--command-lines) (lambda (&rest _) nil)))
      (should (equal (drgnx-tty-frames--true-colour-type "xterm-256color" '("COLORTERM=truecolor")) "xterm-256color")))))

(ert-deftest drgnx-tty-frames/the-setting-decides-which-terminals-are-swapped ()
  (let ((env '("TERM=xterm-256color" "COLORTERM=truecolor")))
    ;; known (the default): only a terminal drgnx's table says has true colour
    (drgnx-tty-frames-test--terminfos '("xterm-direct")
      (let ((drgnx-tty-true-colour 'known))
        (should (equal (drgnx-tty-frames--true-colour-type "xterm-256color" env) "xterm-256color"))   ; unknown terminal
        (should (equal (drgnx-tty-frames--true-colour-type "xterm-256color" (cons "KITTY_WINDOW_ID=1" env)) "xterm-direct"))
        ;; Terminal.app and tmux (its outer terminal decides) are not known to have it
        (should (equal (drgnx-tty-frames--true-colour-type "xterm-256color" (cons "TERM_PROGRAM=Apple_Terminal" env))
                       "xterm-256color"))))
    ;; t: COLORTERM alone
    (drgnx-tty-frames-test--terminfos '("xterm-direct")
      (let ((drgnx-tty-true-colour t))
        (should (equal (drgnx-tty-frames--true-colour-type "xterm-256color" env) "xterm-direct"))))
    ;; nil: never, and nothing is asked
    (drgnx-tty-frames-test--terminfos '("xterm-direct")
      (let ((drgnx-tty-true-colour nil))
        (should (equal (drgnx-tty-frames--true-colour-type "xterm-256color" (cons "KITTY_WINDOW_ID=1" env)) "xterm-256color"))
        (should-not asked)))
    (should (eq (default-value 'drgnx-tty-true-colour) 'known))))

(ert-deftest drgnx-tty-frames/the-frame-is-created-with-the-direct-type ()
  (let* ((proc (make-pipe-process :name "kx-colours" :noquery t)) seen)
    (unwind-protect
        (drgnx-tty-frames-test--terminfos '("xterm-direct")
          (process-put proc 'env '("TERM=xterm-256color" "COLORTERM=truecolor"))
          (should (eq (drgnx-tty-frames--create-tty-frame (lambda (&rest args) (setq seen args) 'frame)
                                                          "/dev/pts/9" "xterm-256color" proc '((a . b)))
                      'frame))
          (should (equal seen (list "/dev/pts/9" "xterm-direct" proc '((a . b)))))
          ;; the decision itself failing creates the frame as asked
          (cl-letf (((symbol-function 'drgnx-tty-frames--true-colour-type) (lambda (&rest _) (error "Broken"))))
            (drgnx-tty-frames--create-tty-frame (lambda (&rest args) (setq seen args)) "/dev/pts/9" "xterm-256color" proc)
            (should (equal seen (list "/dev/pts/9" "xterm-256color" proc)))))
      (delete-process proc))))

(ert-deftest drgnx-tty-frames/a-direct-type-emacs-cannot-load-falls-back-to-the-asked-one ()
  ;; infocmp and Emacs's tgetent can see different terminfo databases: the client keeps its frame
  (let* ((proc (make-pipe-process :name "kx-colours" :noquery t)) tried)
    (unwind-protect
        (drgnx-tty-frames-test--terminfos '("xterm-direct")
          (process-put proc 'env '("TERM=xterm-256color" "COLORTERM=truecolor"))
          (should (eq (drgnx-tty-frames--create-tty-frame
                       (lambda (_tty type _proc)
                         (push type tried)
                         (if (equal type "xterm-direct") (error "Unknown terminal type") 'frame))
                       "/dev/pts/9" "xterm-256color" proc)
                      'frame))
          (should (equal (reverse tried) '("xterm-direct" "xterm-256color")))
          ;; an error with the type as asked is not retried, and is the caller's
          (setq tried nil)
          (should-error (drgnx-tty-frames--create-tty-frame (lambda (_tty type _proc) (push type tried) (error "No frame"))
                                                            "/dev/pts/9" "xterm-256color" proc))
          (should (equal (reverse tried) '("xterm-direct" "xterm-256color")))
          ;; a frame the failed call already made (an error in a frame hook) is not made a second time
          (setq tried nil)
          (cl-letf (((symbol-function 'frame-list) (let ((n 0)) (lambda () (if (= (cl-incf n) 1) '(f1) '(f1 f2))))))
            (should-error (drgnx-tty-frames--create-tty-frame (lambda (_tty type _proc) (push type tried) (error "Hook failed"))
                                                              "/dev/pts/9" "xterm-256color" proc)))
          (should (equal tried '("xterm-direct"))))
      (delete-process proc))))

(ert-deftest drgnx-tty-frames/true-colour-is-asked-for-once-server-is-loaded ()
  (funcall (plist-get (alist-get 'ui/terminal drgnx-modules--table) :setup))
  (require 'server)
  (should (advice-member-p #'drgnx-tty-frames--create-tty-frame 'server-create-tty-frame)))

(ert-deftest drgnx-tty-frames/a-daemon-loading-server-after-init-gets-the-advice ()
  ;; a daemon loads server.el after init: the module's setup runs before there is a function to advise
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (advised (lambda ()
                    (and (advice-member-p #'drgnx-tty-frames--create-tty-frame 'server-create-tty-frame) t)))
         (form `(progn (require 'drgnx)
                       (load ,(expand-file-name "modules/ui/drgnx-tty-frames" drgnx-dir) nil t)
                       (funcall (plist-get (alist-get 'ui/terminal drgnx-modules--table) :setup))
                       (let ((before (list (featurep 'server) (funcall ,advised))))
                         (require 'server)
                         (princ (format "%S" (list before (funcall ,advised)))))))
         (out (with-temp-buffer
                (call-process emacs nil t nil "--batch" "-Q" "-L" (expand-file-name "core" drgnx-dir)
                              "-L" (expand-file-name "wb" drgnx-dir) "-L" (expand-file-name "harness" drgnx-dir)
                              "-L" drgnx-dir "--eval" "(setq load-prefer-newer t)" "--eval" (prin1-to-string form))
                (buffer-string))))
    (should (equal out "((nil nil) t)"))))

(defun drgnx-tty-frames-test--status-column (graphic)
  "The :align-to expression of the Explorer's status letter for a modified file, with the selected frame GRAPHIC or not."
  (require 'drgnx-explorer)
  (with-temp-buffer
    (insert "  name.txt\n")
    (cl-letf (((symbol-function 'drgnx-git-status) (lambda (_) 'modified))
              ((symbol-function 'display-graphic-p) (lambda (&rest _) graphic)))
      (let ((drgnx-explorer-git t))
        (drgnx-explorer--git-decorate (point-min) (1- (point-max)) "/x/name.txt" nil 3)))
    (let ((s (overlay-get (car (overlays-in (point-min) (point-max))) 'after-string)))
      (list (plist-get (cdr (get-text-property 0 'display s)) :align-to) (substring-no-properties s)))))

(ert-deftest drgnx-tty-frames/the-git-letter-keeps-off-the-last-column-whoever-paints-it ()
  ;; a terminal window has no fringe: its last column shows the truncation `$', so a letter put at the edge
  ;; (right - 2) is lost.  The overlay is painted once into a buffer every frame shows: a graphical frame being
  ;; the selected one when it is painted must not decide.
  (should (equal (drgnx-tty-frames-test--status-column nil) '((- right 3) " M")))
  (should (equal (drgnx-tty-frames-test--status-column t) '((- right 3) " M"))))

(ert-deftest drgnx-tty-frames/ignored-files-are-told-by-more-than-colour ()
  (require 'drgnx-git)
  (should-not (equal (face-attribute 'drgnx-git-ignored :slant nil t) (face-attribute 'default :slant nil t))))

(ert-deftest drgnx-tty-frames/the-state-table-names-each-group-its-faces-and-its-cue ()
  (should (equal (mapcar #'car drgnx-tty-frames-state-faces) '(git review tabs work)))
  (pcase-dolist (`(,group . ,spec) drgnx-tty-frames-state-faces)
    (should (symbolp group))
    (should (memq (plist-get spec :cue) '(letter word attribute label)))
    (should (stringp (plist-get spec :doc)))
    (should (consp (plist-get spec :faces)))
    (dolist (f (append (plist-get spec :faces) (plist-get spec :attribute-faces)))
      (should (string-prefix-p "drgnx-" (symbol-name f))))
    (dolist (f (plist-get spec :attribute-faces))
      (should (memq f (plist-get spec :faces)))))
  ;; ignored files have no letter: their cue is an attribute
  (should (memq 'drgnx-git-ignored (plist-get (alist-get 'git drgnx-tty-frames-state-faces) :attribute-faces))))

(ert-deftest drgnx-tty-frames/every-face-of-the-state-table-is-defined ()
  (dolist (lib '(drgnx-git drgnx-chrome drgnx-review drgnx-work-ui))
    (require lib))
  (pcase-dolist (`(,_ . ,spec) drgnx-tty-frames-state-faces)
    (dolist (f (plist-get spec :faces))
      (should (facep f)))))
