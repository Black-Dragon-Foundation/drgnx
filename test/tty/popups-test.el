;;; popups-test.el --- tty tier: popups in terminal windows (child frames on 31.1, the bottom lane on 30.2) -*- lexical-binding: t -*-
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.  The inner Emacs
;; is whatever `emacs' is on PATH: 30.2 on the host (no tty child frames), 31.1 in the f45 container.  A test that
;; needs one of them says `skip-unless' on the inner Emacs's own `(featurep 'tty-child-frames)'.
(require 'ert)
(require 'seq)
(require 'drgnx-tty-session)

;;;; Helpers

(defconst drgnx-tty-popups-test--windows
  '(mapcar (lambda (w) (list (buffer-name (window-buffer w)) (window-edges w)))
           (window-list (selected-frame) 'nomini))
  "A form, in the inner Emacs: every window of the selected frame with its buffer and edges.")

(defconst drgnx-tty-popups-test--state
  `(list :frames (length (frame-list)) :windows ,drgnx-tty-popups-test--windows)
  "A form, in the inner Emacs: how many frames there are, and every window with its buffer and edges.")

(defun drgnx-tty-popups-test--key (sess key)
  "Send KEY (`kbd' syntax) to SESS as a legacy terminal does."
  (drgnx-tty-session-key sess key 'legacy))

(defun drgnx-tty-popups-test--ready (sess &optional close)
  "Wait until SESS shows the workbench: the *scratch* tab with its CLOSE mark (default: ×; a UTF-8 terminal
keeps the glyph)."
  (drgnx-tty-session-wait-screen sess (concat "\\*scratch\\* " (or close "×")) 20))

(defun drgnx-tty-popups-test--child-frames-p (sess)
  (drgnx-tty-session-eval sess '(and (featurep 'tty-child-frames) t)))

(defun drgnx-tty-popups-test--corfu-dirs ()
  "The corfu and compat directories (the version etc/drgnx.lock.eld pins, when there), read-only; the test is
skipped, saying how to supply them, when they are not there."
  (drgnx-tty-session-require-packages '(corfu compat)))

(defun drgnx-tty-popups-test--round (sess open shown close)
  "OPEN a popup (a function), wait until SHOWN (a form) holds in the inner Emacs, then CLOSE it.  Opened, the
screen and the windows' edges differ from before; closed, every window has its buffer and edges again and the
frame count is what it was."
  (let* ((before (drgnx-tty-session-eval sess drgnx-tty-popups-test--state))
         (screen-before (drgnx-tty-session-quiet sess)))
    (funcall open)
    (drgnx-tty-session-wait sess shown 10)
    (let ((screen-open (drgnx-tty-session-quiet sess))
          (open-state (drgnx-tty-session-eval sess drgnx-tty-popups-test--state)))
      (should-not (equal screen-before screen-open))
      (should-not (equal (plist-get before :windows) (plist-get open-state :windows))))
    (funcall close)
    (drgnx-tty-session-wait sess `(equal ',(plist-get before :windows) ,drgnx-tty-popups-test--windows) 10)
    (should (equal (plist-get before :frames)
                   (plist-get (drgnx-tty-session-eval sess drgnx-tty-popups-test--state) :frames)))
    (should (equal (plist-get before :windows)
                   (plist-get (drgnx-tty-session-eval sess drgnx-tty-popups-test--state) :windows)))))

(defmacro drgnx-tty-popups-test--with (spec &rest body)
  "Like `drgnx-tty-session-with', then wait for the workbench."
  (declare (indent 1))
  `(drgnx-tty-session-with ,spec
     (drgnx-tty-popups-test--ready ,(car spec))
     ,@body))

;;;; The popups drgnx owns or routes (wb/drgnx-rules.el): each shows, and leaves no trace

(defun drgnx-tty-popups-test--transient (s)
  "Define a one-key transient on <f9> in SESS and open it by that key."
  (should (drgnx-tty-session-eval
           s '(progn (require 'transient)
                     (transient-define-prefix drgnx-tty-popups-test-tr () [("a" "Do A" ignore)])
                     (keymap-global-set "<f9>" #'drgnx-tty-popups-test-tr)
                     (eq (key-binding (kbd "<f9>")) 'drgnx-tty-popups-test-tr)))))

(ert-deftest drgnx-tty-popups/transient-shows-and-leaves-no-trace ()
  (drgnx-tty-popups-test--with (s :size "80x24")
    (drgnx-tty-popups-test--transient s)
    (drgnx-tty-popups-test--round s (lambda () (drgnx-tty-popups-test--key s "<f9>"))
                                  '(and (get-buffer-window " *transient*") t)
                                  (lambda () (drgnx-tty-popups-test--key s "C-g")))))

(ert-deftest drgnx-tty-popups/which-key-shows-and-leaves-no-trace ()
  (drgnx-tty-popups-test--with (s :size "80x24")
    (drgnx-tty-session-eval s '(progn (require 'which-key) (setq which-key-idle-delay 0.1) (which-key-mode 1) t))
    (drgnx-tty-popups-test--round s (lambda () (drgnx-tty-popups-test--key s "C-x"))
                                  '(and (get-buffer-window " *which-key*") t)
                                  (lambda () (drgnx-tty-popups-test--key s "C-g")))))

(defun drgnx-tty-popups-test--m-x (s text)
  "M-x, then TEXT typed at the prompt."
  (drgnx-tty-popups-test--key s "M-x")
  (drgnx-tty-session-wait s '(> (minibuffer-depth) 0) 10)
  (drgnx-tty-session-send s text))

(ert-deftest drgnx-tty-popups/completions-shows-and-leaves-no-trace ()
  (drgnx-tty-popups-test--with (s :size "80x24")
    (drgnx-tty-popups-test--round
     s (lambda () (drgnx-tty-popups-test--m-x s "describe-") (drgnx-tty-popups-test--key s "TAB"))
     '(and (get-buffer-window "*Completions*") t)
     (lambda () (drgnx-tty-popups-test--key s "C-g")))
    ;; the minibuffer is gone with it
    (should (eql 0 (drgnx-tty-session-eval s '(minibuffer-depth))))))

(ert-deftest drgnx-tty-popups/help-from-the-minibuffer-shows-and-leaves-no-trace ()
  ;; C-h f at the M-x prompt: *Help* shows in the panel and the minibuffer keeps the focus; C-g ends the prompt and
  ;; Toggle Panel hides the panel again
  (drgnx-tty-popups-test--with (s :size "80x24")
    (drgnx-tty-popups-test--round
     s (lambda ()
         (drgnx-tty-popups-test--key s "M-x")
         (drgnx-tty-session-wait s '(> (minibuffer-depth) 0) 10)
         (drgnx-tty-popups-test--key s "C-h")
         (drgnx-tty-session-send s "f")
         (drgnx-tty-session-wait s '(> (minibuffer-depth) 1) 10)
         (drgnx-tty-session-send s "car")
         (drgnx-tty-popups-test--key s "RET"))
     '(and (get-buffer-window "*Help*") (> (minibuffer-depth) 0) t)
     (lambda ()
       (drgnx-tty-popups-test--key s "C-g")
       (drgnx-tty-session-wait s '(eql 0 (minibuffer-depth)) 10)
       (drgnx-tty-session-eval s '(progn (drgnx-wb-area-hide 'panel) t))))))

(ert-deftest drgnx-tty-popups/calendar-shows-and-leaves-no-trace ()
  (drgnx-tty-popups-test--with (s :size "80x24")
    (drgnx-tty-popups-test--round
     s (lambda () (drgnx-tty-popups-test--m-x s "calendar") (drgnx-tty-popups-test--key s "RET"))
     '(and (get-buffer-window "*Calendar*") t)
     (lambda () (drgnx-tty-popups-test--key s "q")))))

;;;; Completion as you type

(defun drgnx-tty-popups-test--corfu (s dirs)
  "Load corfu (DIRS: its directory and compat's) in SESS's Emacs, completion as you type on, and visit an Emacs
Lisp file in the editor."
  (drgnx-tty-session-eval
   s `(progn (dolist (d ',dirs) (add-to-list 'load-path d))
             (require 'corfu)
             (setq corfu-auto t corfu-auto-delay 0.1 corfu-auto-prefix 2)
             (global-corfu-mode 1)
             (drgnx-wb-show-in-editor (find-file-noselect ,(expand-file-name "x.el" (plist-get s :run))) t)
             (emacs-lisp-mode)
             (corfu-mode 1)
             (and corfu-mode t))))

(defconst drgnx-tty-popups-test--child-frames-of-selected
  '(seq-filter (lambda (f) (and (eq (frame-parent f) (selected-frame)) (frame-visible-p f))) (frame-list))
  "A form, in the inner Emacs: the visible child frames of the selected frame.")

(ert-deftest drgnx-tty-popups/completion-as-you-type ()
  ;; 31.1: corfu's popup is a child frame of the selected frame, hidden by C-g.  30.2: no child frames, so the
  ;; candidates show in *Completions* in the popup lane, nothing is inserted, and C-g removes them.
  (let ((dirs (drgnx-tty-popups-test--corfu-dirs)))
    (drgnx-tty-popups-test--with (s :size "100x30")
      (should (drgnx-tty-popups-test--corfu s dirs))
      (let ((child-frames (drgnx-tty-popups-test--child-frames-p s)))
        (drgnx-tty-session-send s "(with-")
        (if child-frames
            (progn
              (drgnx-tty-session-wait s `(and ,drgnx-tty-popups-test--child-frames-of-selected t) 10)
              (drgnx-tty-popups-test--key s "C-g")
              (drgnx-tty-session-wait s `(null ,drgnx-tty-popups-test--child-frames-of-selected) 10))
          (drgnx-tty-session-wait s '(let ((w (get-buffer-window "*Completions*")))
                                       (and w (window-parameter w 'drgnx-popup) t))
                                  10)
          (should (equal (drgnx-tty-session-eval s '(with-current-buffer "x.el" (buffer-string))) "(with-"))
          (should (eql 1 (drgnx-tty-session-eval s '(length (frame-list)))))
          (drgnx-tty-popups-test--key s "C-g")
          (drgnx-tty-session-wait s '(null (get-buffer-window "*Completions*")) 10))
        (should (equal (drgnx-tty-session-eval s '(with-current-buffer "x.el" (buffer-string))) "(with-"))))))

(ert-deftest drgnx-tty-popups/completion-as-you-type-follows-what-is-typed ()
  ;; the list in the lane is refreshed as the word grows, and goes when the word ends (30.2 only)
  (let ((dirs (drgnx-tty-popups-test--corfu-dirs)))
    (drgnx-tty-popups-test--with (s :size "100x30")
      (skip-when (drgnx-tty-popups-test--child-frames-p s))
      (should (drgnx-tty-popups-test--corfu s dirs))
      (drgnx-tty-session-send s "(with-")
      (drgnx-tty-session-wait s '(and (get-buffer-window "*Completions*") t) 10)
      (drgnx-tty-session-send s "temp-b")
      (drgnx-tty-session-wait s '(with-current-buffer "*Completions*"
                                   (save-excursion
                                     (goto-char (point-min))
                                     (and (search-forward "with-temp-buffer" nil t)
                                          (progn (goto-char (point-min)) (not (search-forward "with-mutex" nil t))))))
                              10)
      (drgnx-tty-session-send s " ")
      (drgnx-tty-session-wait s '(null (get-buffer-window "*Completions*")) 10))))

(ert-deftest drgnx-tty-popups/completion-as-you-type-can-be-turned-off ()
  ;; 30.2: `drgnx-tty-popups-auto-completions' nil leaves a terminal window without the list (corfu-auto stays on)
  (let ((dirs (drgnx-tty-popups-test--corfu-dirs)))
    (drgnx-tty-popups-test--with (s :size "100x30")
      (skip-when (drgnx-tty-popups-test--child-frames-p s))
      (should (drgnx-tty-popups-test--corfu s dirs))
      (drgnx-tty-session-eval s '(progn (setq drgnx-tty-popups-auto-completions nil) t))
      (drgnx-tty-session-send s "(with-")
      (sleep-for 1)
      (should-not (drgnx-tty-session-eval s '(and (get-buffer-window "*Completions*") t)))
      (should (drgnx-tty-session-eval s '(with-current-buffer "x.el" corfu-auto))))))

;;;; The cursor line stays visible

(ert-deftest drgnx-tty-popups/the-cursor-line-stays-visible ()
  ;; 80x24, point on the last line of the editor: each popup opens without taking that line off the screen
  (drgnx-tty-popups-test--with (s :size "80x24")
    (let ((file (expand-file-name "big.txt" (plist-get s :run))))
      (with-temp-file file (dotimes (i 200) (insert (format "line %d\n" (1+ i)))))
      (drgnx-tty-session-eval s `(progn (drgnx-wb-show-in-editor (find-file-noselect ,file) t)
                                        (goto-char (point-max)) (forward-line -1) (recenter -1)
                                        (let ((w (get-buffer-window (current-buffer))))
                                          (and w (window-live-p w) t))))
      (drgnx-tty-session-wait-screen s "line 200")
      (drgnx-tty-popups-test--transient s)
      (drgnx-tty-session-eval s '(progn (require 'which-key) (setq which-key-idle-delay 0.1) (which-key-mode 1) t))
      (let ((visible '(let ((w (get-buffer-window "big.txt")))
                        (and w (progn (redisplay t) (pos-visible-in-window-p (window-point w) w)) t))))
        (should (drgnx-tty-session-eval s visible))
        ;; the probe tells: the first line of the file is off the screen
        (should-not (drgnx-tty-session-eval s '(let ((w (get-buffer-window "big.txt"))) (pos-visible-in-window-p (point-min) w))))
        (dolist (popup `(("transient" ,(lambda () (drgnx-tty-popups-test--key s "<f9>")) (get-buffer-window " *transient*")
                          ,(lambda () (drgnx-tty-popups-test--key s "C-g")))
                         ("which-key" ,(lambda () (drgnx-tty-popups-test--key s "C-x")) (get-buffer-window " *which-key*")
                          ,(lambda () (drgnx-tty-popups-test--key s "C-g")))
                         ("completions" ,(lambda () (drgnx-tty-popups-test--m-x s "describe-") (drgnx-tty-popups-test--key s "TAB"))
                          (get-buffer-window "*Completions*") ,(lambda () (drgnx-tty-popups-test--key s "C-g")))
                         ("calendar" ,(lambda () (drgnx-tty-popups-test--m-x s "calendar") (drgnx-tty-popups-test--key s "RET"))
                          (get-buffer-window "*Calendar*") ,(lambda () (drgnx-tty-popups-test--key s "q")))))
          (pcase-let ((`(,name ,open ,shown ,close) popup))
            (funcall open)
            (drgnx-tty-session-wait s `(and ,shown t) 10)
            (drgnx-tty-session-quiet s)
            (should (eq (drgnx-tty-session-eval s visible) t))
            (ignore name)
            (funcall close)
            (drgnx-tty-session-wait s `(null ,shown) 10)
            (drgnx-tty-session-quiet s)))))))

;;;; Borders

(defun drgnx-tty-popups-test--bordered-child (s)
  "Show a decorated child frame (as a package that wants a border makes) in SESS's Emacs."
  (should (drgnx-tty-session-eval
           s '(let ((f (make-frame (list (cons 'parent-frame (selected-frame)) '(left . 8) '(top . 3) '(width . 12)
                                         '(height . 3) '(minibuffer . nil) '(menu-bar-lines . 0) '(tab-bar-lines . 0)))))
                (with-current-buffer (get-buffer-create "*pop*") (erase-buffer) (insert "alpha\nbeta"))
                (set-window-buffer (frame-root-window f) "*pop*")
                (make-frame-visible f)
                (and (frame-parent f) t)))))

(ert-deftest drgnx-tty-popups/borders-are-box-drawing ()
  ;; 31.1, a UTF-8 terminal: a child frame's border is ┌ ─ ┐ │ └ ┘
  (drgnx-tty-popups-test--with (s :size "80x24")
    (skip-unless (drgnx-tty-popups-test--child-frames-p s))
    (drgnx-tty-popups-test--bordered-child s)
    (let ((screen (drgnx-tty-session-wait-screen s (string #x250c #x2500 #x2500))))
      (ignore screen)
      (let ((text (drgnx-tty-session-screen s)))
        (dolist (c '(#x2510 #x2514 #x2518 #x2502))
          (should (string-match-p (string c) text)))
        (should-not (string-match-p "[+][-]+[+]" text))))))

;;;; A terminal that does not write UTF-8 gets ASCII

(ert-deftest drgnx-tty-popups/a-c-locale-gets-ascii ()
  ;; LANG=C: the terminal does not write UTF-8.  The tab line, the breadcrumb, the Explorer and the docks' headers
  ;; show ASCII marks (x for ×, * for ●, > for › ▸, v for ▾) — no `?' and no \uXXXX escapes — and, on 31.1, so does
  ;; a child frame's border (+ - |)
  ;; 31 lines: the menu bar takes one, and a frame under 30 lines has no breadcrumb (ui/terminal-layout)
  (drgnx-tty-session-with (s :size "100x31" :env '("LANG=C" "LC_ALL=C"))
    (drgnx-tty-popups-test--ready s "x")
    (should (drgnx-tty-session-eval s '(drgnx-tty-popups-ascii-p)))
    (should (drgnx-tty-session-eval s '(and (memq 'drgnx-tty-popups--pre-redisplay pre-redisplay-functions) t)))
    (let ((dir (expand-file-name "project" (plist-get s :run))))
      (make-directory (expand-file-name "src" dir) t)
      (with-temp-file (expand-file-name "a.txt" dir) (insert "alpha\n"))
      (with-temp-file (expand-file-name "src/c.el" dir) (insert "(x)\n"))
      (drgnx-tty-session-eval s `(progn (drgnx-explorer-set-roots (list ,dir))
                                        (drgnx-wb-show-sidebar)
                                        (drgnx-wb-show-in-editor (find-file-noselect ,(expand-file-name "a.txt" dir)) t)
                                        (with-current-buffer "a.txt" (insert "z"))
                                        t))
      (drgnx-tty-session-wait-screen s "a\\.txt \\* x")                ; tab: name, changed mark, close mark
      (drgnx-tty-session-wait-screen s "^v PROJECT")                   ; Explorer: open root
      (drgnx-tty-session-wait-screen s "^> src")                       ; …closed folder
      (drgnx-tty-session-wait-screen s "| [a-z]+ > [a-zA-Z0-9.-]+ > ")  ; breadcrumb (cut off at the window's edge)
      (when (drgnx-tty-popups-test--child-frames-p s)
        (drgnx-tty-popups-test--bordered-child s)
        (drgnx-tty-session-wait-screen s "[+]-----"))
      (let ((screen (drgnx-tty-session-quiet s)))
        (should-not (string-match-p "\\\\u[0-9A-F]\\{4\\}" screen))
        (should-not (string-match-p "[?]" screen))
        (should-not (string-match-p "[^[:ascii:]]" screen))))))

(ert-deftest drgnx-tty-popups/a-c-locale-client-leaves-the-utf-8-one-alone ()
  ;; one daemon, two terminals: the client started with LANG=C gets ASCII marks (the curved quotes of the scratch
  ;; text too), the first client keeps its glyphs
  (drgnx-tty-session-with (s :daemon t :size "100x30")
    (drgnx-tty-popups-test--ready s)
    (let ((c (drgnx-tty-session-client s :env '("LANG=C" "LC_ALL=C"))))
      (drgnx-tty-popups-test--ready c "x")
      (let ((screen (drgnx-tty-session-quiet c)))
        (should-not (string-match-p "\\\\u[0-9A-F]\\{4\\}" screen))
        (should-not (string-match-p "[^[:ascii:]]" screen)))
      (should (drgnx-tty-session-find s "\\*scratch\\* ×"))
      (should-not (string-match-p "\\\\u[0-9A-F]\\{4\\}" (drgnx-tty-session-screen s)))
      ;; the ASCII hooks are there while that client is, and go with it
      (should (drgnx-tty-session-eval s '(and (memq 'drgnx-tty-popups--pre-redisplay pre-redisplay-functions) t)))
      (drgnx-tty-session-eval s '(progn (delete-frame (seq-find (lambda (f) (frame-parameter f 'drgnx-tty-ascii)) (frame-list))) t))
      (drgnx-tty-session-wait s '(not (memq 'drgnx-tty-popups--pre-redisplay pre-redisplay-functions)) 10)
      (should-not (drgnx-tty-session-eval s '(advice-member-p #'drgnx-tty-popups--chrome-set 'drgnx-chrome--set))))))

(ert-deftest drgnx-tty-popups/a-utf-8-terminal-keeps-its-glyphs ()
  (drgnx-tty-popups-test--with (s :size "100x30")
    (should-not (drgnx-tty-session-eval s '(drgnx-tty-popups-ascii-p)))
    (should-not (drgnx-tty-session-eval s '(frame-parameter nil 'drgnx-tty-ascii)))
    (should-not (drgnx-tty-session-eval s '(window-display-table (selected-window))))
    ;; …and pays nothing for the ASCII machinery
    (should-not (drgnx-tty-session-eval s '(or (memq 'drgnx-tty-popups--pre-redisplay pre-redisplay-functions)
                                               (memq 'drgnx-tty-popups--windows-changed window-configuration-change-hook)
                                               (advice-member-p #'drgnx-tty-popups--chrome-set 'drgnx-chrome--set))))
    (should (drgnx-tty-session-find s "\\*scratch\\* ×"))))

;;; popups-test.el ends here
