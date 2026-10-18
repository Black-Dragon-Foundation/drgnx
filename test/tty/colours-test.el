;;; colours-test.el --- tty tier: colours in terminal windows (true colour from the client, no invisible face, states without colour) -*- lexical-binding: t -*-
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.  The colour depth
;; of a client is chosen by its own environment (TERM, COLORTERM), as a user's terminal does.
(require 'ert)
(require 'drgnx-tty-session)

(defconst drgnx-tty-colours-test--clients
  '(seq-filter (lambda (f) (and (frame-live-p f) (frame-parameter f 'client))) (frame-list))
  "A form, in the inner daemon: its client frames, newest first.")

(defun drgnx-tty-colours-test--in-client (sess form)
  "FORM's value in SESS's daemon with its newest client frame selected."
  (drgnx-tty-session-eval sess `(with-selected-frame (car ,drgnx-tty-colours-test--clients) ,form)))

(defun drgnx-tty-colours-test--cells (sess)
  "The colours the newest client frame of SESS shows."
  (drgnx-tty-session-eval sess `(display-color-cells (car ,drgnx-tty-colours-test--clients))))

(defun drgnx-tty-colours-test--types (sess)
  "The terminal types of SESS's client frames, newest first."
  (drgnx-tty-session-eval sess `(mapcar (lambda (f) (tty-type (frame-terminal f))) ,drgnx-tty-colours-test--clients)))

(defun drgnx-tty-colours-test--setting (sess value)
  "Set `drgnx-tty-true-colour' to VALUE in SESS's daemon."
  (drgnx-tty-session-eval sess `(progn (setq drgnx-tty-true-colour ',value) t)))

(ert-deftest drgnx-tty-colours/colorterm-from-the-client ()
  ;; the daemon has no COLORTERM: each client's own decides, and one never changes another.  The session's
  ;; terminal is tmux-256color, which is not a known true-colour terminal: the setting says to go by COLORTERM.
  (drgnx-tty-session-with (s :daemon t)
    (should-not (drgnx-tty-session-eval s '(getenv "COLORTERM")))
    (drgnx-tty-colours-test--setting s t)
    (let ((a (drgnx-tty-session-client s :env '("COLORTERM=truecolor"))))
      (should (= (drgnx-tty-colours-test--cells s) 16777216))
      (let ((b (drgnx-tty-session-client s)))
        (should (= (drgnx-tty-colours-test--cells s) 256))
        (should (equal (drgnx-tty-session-eval
                        s `(mapcar (lambda (f) (display-color-cells f)) ,drgnx-tty-colours-test--clients))
                       '(256 16777216 256)))      ; B, A, and the session's own first client
        ;; a tmux-256color client with COLORTERM=truecolor is a tmux-direct frame, the others keep their TERM
        (should (equal (drgnx-tty-colours-test--types s) '("tmux-256color" "tmux-direct" "tmux-256color")))
        (should (drgnx-tty-session-find b "\\*scratch\\*"))
        (should (drgnx-tty-session-find a "\\*scratch\\*"))))))

(ert-deftest drgnx-tty-colours/the-setting-decides-which-clients-are-swapped ()
  (drgnx-tty-session-with (s :daemon t)
    ;; known (the default): a terminal drgnx knows has true colour (kitty) is; an unknown one and tmux are not
    (should (eq (drgnx-tty-session-eval s 'drgnx-tty-true-colour) 'known))
    (drgnx-tty-session-client s :env '("TERM=xterm-256color" "COLORTERM=truecolor" "KITTY_WINDOW_ID=1"))
    (should (= (drgnx-tty-colours-test--cells s) 16777216))
    (drgnx-tty-session-client s :env '("TERM=xterm-256color" "COLORTERM=truecolor"))
    (should (= (drgnx-tty-colours-test--cells s) 256))
    (drgnx-tty-session-client s :env '("COLORTERM=truecolor"))
    (should (= (drgnx-tty-colours-test--cells s) 256))
    (should (equal (cl-subseq (drgnx-tty-colours-test--types s) 0 3) '("tmux-256color" "xterm-256color" "xterm-direct")))
    ;; nil: never
    (drgnx-tty-colours-test--setting s nil)
    (drgnx-tty-session-client s :env '("TERM=xterm-256color" "COLORTERM=truecolor" "KITTY_WINDOW_ID=1"))
    (should (= (drgnx-tty-colours-test--cells s) 256))))

(ert-deftest drgnx-tty-colours/colorterm-24bit-is-true-colour ()
  ;; Emacs reads COLORTERM=truecolor only; 24bit means the same to the terminal
  (drgnx-tty-session-with (s :daemon t)
    (drgnx-tty-colours-test--setting s t)
    (drgnx-tty-session-client s :env '("TERM=xterm-256color" "COLORTERM=24bit"))
    (should (= (drgnx-tty-colours-test--cells s) 16777216))
    ;; the client's environment still says what it said
    (should (equal (drgnx-tty-colours-test--in-client s '(getenv "COLORTERM" (selected-frame))) "24bit"))
    ;; nothing else is promoted: no COLORTERM, another value, or a terminal that says 8 colours
    (drgnx-tty-session-client s :env '("TERM=xterm-256color" "COLORTERM=yes"))
    (should (= (drgnx-tty-colours-test--cells s) 256))
    (drgnx-tty-session-client s :env '("TERM=xterm"))
    (should (= (drgnx-tty-colours-test--cells s) 8))
    (drgnx-tty-session-client s :env '("TERM=xterm" "COLORTERM=24bit"))
    (should (= (drgnx-tty-colours-test--cells s) 16777216))))

;;;; No face is invisible

(defconst drgnx-tty-colours-test--invisible
  '(let ((resolve (lambda (face attr)
                    (let ((c (face-attribute face attr nil t)))
                      (if (and (stringp c) (not (string-prefix-p "unspecified" c))) c
                        (let ((d (face-attribute 'default attr nil)))
                          (if (and (stringp d) (not (string-prefix-p "unspecified" d))) d
                            ;; the terminal's own colours: light on dark, dark on light
                            (if (eq (eq (frame-parameter nil 'background-mode) 'dark) (eq attr :foreground))
                                "white" "black")))))))
         (seen 0) bad)
     (dolist (theme '(nil modus-vivendi))
       (mapc #'disable-theme custom-enabled-themes)
       (when theme (load-theme theme t))
       (dolist (f (face-list))
         (when (string-prefix-p "drgnx-" (symbol-name f))
           (cl-incf seen)
           (let* ((fg (funcall resolve f :foreground)) (bg (funcall resolve f :background))
                  (afg (car (tty-color-approximate (tty-color-values fg))))
                  (abg (car (tty-color-approximate (tty-color-values bg)))))
             (when (equal afg abg) (push (list theme f fg bg afg) bad))))))
     (mapc #'disable-theme custom-enabled-themes)
     (list seen (nreverse bad)))
  "A form, in the inner daemon, in a terminal frame: how many drgnx faces it looked at, and those whose
foreground and background are the same colour on this terminal, in the default theme and in modus-vivendi.")

(ert-deftest drgnx-tty-colours/no-face-is-invisible ()
  (drgnx-tty-session-with (s :daemon t)
    (pcase-dolist (`(,cells ,env) '((8 ("TERM=xterm"))
                                    (256 ("TERM=xterm-256color"))
                                    (16777216 ("TERM=xterm-256color" "COLORTERM=truecolor" "KITTY_WINDOW_ID=1"))))
      (drgnx-tty-session-client s :env env)
      (should (= (drgnx-tty-colours-test--cells s) cells))
      ;; the faces the groups of states are made of are loaded, so the check is not empty
      (should (drgnx-tty-colours-test--in-client
               s '(seq-every-p #'facep '(drgnx-git-modified drgnx-review-critical drgnx-chrome-tab
                                                            drgnx-work-ui-stale drgnx-explorer-file))))
      (pcase-let ((`(,seen ,bad) (drgnx-tty-colours-test--in-client s drgnx-tty-colours-test--invisible)))
        (should (> seen 25))
        (should (equal (cons cells bad) (list cells)))))))

;;;; States without colour

(defun drgnx-tty-colours-test--git-fixture (sess)
  "A repository in SESS's run directory with a modified, an added and an untracked file, in the Explorer."
  (let ((dir (expand-file-name "repo" (plist-get sess :run))))
    (make-directory dir t)
    (let ((default-directory dir))
      (dolist (args '(("init" "-q") ("config" "user.email" "t@example.org") ("config" "user.name" "t")))
        (apply #'call-process "git" nil nil nil args))
      (with-temp-file (expand-file-name "mod.txt" dir) (insert "one\n"))
      (call-process "git" nil nil nil "add" "mod.txt")
      (call-process "git" nil nil nil "commit" "-q" "-m" "first")
      (with-temp-file (expand-file-name "mod.txt" dir) (insert "two\n"))
      (with-temp-file (expand-file-name "new.txt" dir) (insert "x\n"))
      (call-process "git" nil nil nil "add" "new.txt")
      (with-temp-file (expand-file-name "loose.txt" dir) (insert "y\n")))
    (drgnx-tty-session-eval sess `(progn (drgnx-explorer-set-roots (list ,dir)) (drgnx-wb-show-sidebar) t))
    dir))

(defconst drgnx-tty-colours-test--attributes
  '(:weight :slant :underline :overline :strike-through :box :inverse-video)
  "The face attributes that tell without colour.")

(ert-deftest drgnx-tty-colours/states-are-told-apart-without-colour ()
  (drgnx-tty-session-with (s :daemon t :size "120x40")
    (let ((c (drgnx-tty-session-client s :env '("TERM=xterm"))))
      (should (= (drgnx-tty-colours-test--cells s) 8))
      (drgnx-tty-session-wait-screen c "\\*scratch\\* ×" 20)
      ;; the table is there and names the four groups
      (should (equal (drgnx-tty-colours-test--in-client s '(mapcar #'car drgnx-tty-frames-state-faces))
                     '(git review tabs work)))
      ;; git: the letter sits in the row, M for a changed file, A for an added one, U for an untracked one
      (drgnx-tty-colours-test--in-client s '(progn (drgnx-wb-show-sidebar) t))
      (drgnx-tty-colours-test--git-fixture s)
      (drgnx-tty-session-wait-screen c "mod\\.txt +M")
      (drgnx-tty-session-wait-screen c "new\\.txt +A")
      (drgnx-tty-session-wait-screen c "loose\\.txt +U")
      ;; review: the severity is a word in the line, whatever its colour
      (should (equal (drgnx-tty-colours-test--in-client
                      s '(let ((drgnx-review--runs (make-hash-table :test #'equal))
                               (drgnx-review--current "s"))
                           (puthash "s" (list :root default-directory :branch "b" :base "main" :head "h" :result (list :verdict 'fail
                                                                                                                       :findings (mapcar (lambda (sev) (list :path "a.el" :line 1 :severity sev :text "x"))
                                                                                                                                         '("critical" "important" "minor"))))
                                    drgnx-review--runs)
                           (drgnx-review-refresh)
                           (with-current-buffer (drgnx-review--buffer)
                             (seq-filter (lambda (w) (string-match-p (concat "^" w " ") (buffer-string)))
                                         '("critical" "important" "minor")))))
                     '("critical" "important" "minor")))
      ;; the tabs: the shown tab differs from the others in an attribute that is not a colour
      (should (drgnx-tty-colours-test--in-client
               s `(seq-some (lambda (a)
                              (not (equal (face-attribute 'drgnx-chrome-tab a nil t)
                                          (face-attribute 'drgnx-chrome-tab-current a nil t))))
                            ',drgnx-tty-colours-test--attributes)))
      ;; work: the label says what a node is
      (should (equal (drgnx-tty-colours-test--in-client
                      s '(list (string-match-p "\\`⚠ Task 1: t  (its commits are on no branch)"
                                               (drgnx-work-ui--line '(:kind task :ord 1 :title "t" :stale t)))
                               (string-match-p "\\`☑ t" (drgnx-work-ui--line '(:kind step :title "t" :status "done")))
                               (string-match-p "\\`☐ t" (drgnx-work-ui--line '(:kind step :title "t")))
                               (string-match-p "\\`✓ TODO t" (drgnx-work-ui--line '(:kind todo :title "t" :status "done")))
                               (string-match-p "\\`○ TODO t" (drgnx-work-ui--line '(:kind todo :title "t")))))
                     '(0 0 0 0 0)))
      ;; ignored files have no letter: their face differs from the default in an attribute that is not a colour
      (should (equal (drgnx-tty-colours-test--in-client
                      s `(mapcar (lambda (f)
                                   (seq-some (lambda (a)
                                               (not (equal (face-attribute f a nil t) (face-attribute 'default a nil t))))
                                             ',drgnx-tty-colours-test--attributes))
                                 (plist-get (alist-get 'git drgnx-tty-frames-state-faces) :attribute-faces)))
                     '(t)))
      ;; and every face of the table is a face
      (should (drgnx-tty-colours-test--in-client
               s '(seq-every-p (lambda (g) (seq-every-p #'facep (plist-get (cdr g) :faces))) drgnx-tty-frames-state-faces))))))

;;;; Images

(ert-deftest drgnx-tty-colours/the-work-graph-says-it-cannot-show-here ()
  (drgnx-tty-session-with (s :daemon t)
    (drgnx-tty-session-client s)
    (let ((r (drgnx-tty-colours-test--in-client
              s '(condition-case err (progn (call-interactively #'drgnx-work-ui-graph) 'shown)
                   (user-error (cadr err))
                   (error (list 'error err))))))
      (should (stringp r))
      (should (string-match-p "needs a graphical frame" r))
      (should (string-match-p "Work tab shows the same tree" r)))
    ;; no graph buffer was made on the way
    (should-not (drgnx-tty-session-eval s '(and (get-buffer "*work graph*") t)))))

(provide 'drgnx-tty-colours-test)
;;; colours-test.el ends here
