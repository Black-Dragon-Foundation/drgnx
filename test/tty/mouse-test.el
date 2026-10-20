;;; mouse-test.el --- tty tier: the mouse in terminal windows (SGR reports in, Emacs's state out) -*- lexical-binding: t -*-
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.  Positions
;; come from the screen (`drgnx-tty-session-find'), never computed from Emacs's idea of the layout.
(require 'ert)
(require 'drgnx-tty-session)

(defun drgnx-tty-mouse-test--project (sess)
  "Make the fixture project in SESS's run directory (a.txt, b.txt, src/c.el), show it in the Explorer and
a.txt in the editor, wait until both are on the screen.  Returns the project directory."
  (let ((dir (expand-file-name "project" (plist-get sess :run))))
    (make-directory (expand-file-name "src" dir) t)
    (with-temp-file (expand-file-name "a.txt" dir) (insert "alpha beta gamma\nsecond line\n"))
    (with-temp-file (expand-file-name "b.txt" dir)
      (dotimes (i 300) (insert (format "line %d\n" (1+ i)))))
    (with-temp-file (expand-file-name "src/c.el" dir) (insert "(defun c () 1)\n"))
    (drgnx-tty-session-wait-screen sess "\\*scratch\\* ×" 20)
    (drgnx-tty-session-eval sess `(progn (drgnx-explorer-set-roots (list ,dir))
                                         (drgnx-wb-show-sidebar)
                                         (drgnx-wb-show-in-editor (find-file-noselect ,(expand-file-name "a.txt" dir)) t)
                                         t))
    (drgnx-tty-session-wait-screen sess "EXPLORER")
    (drgnx-tty-session-wait-screen sess "alpha beta gamma")
    (drgnx-tty-session-wait-screen sess "b\\.txt")
    dir))

(defun drgnx-tty-mouse-test--click-on (sess regexp &rest args)
  "Click at the first match of REGEXP on SESS's screen, ARGS (:dx N :mods … :double …) as `drgnx-tty-session-click'."
  (let* ((pos (drgnx-tty-session-wait-screen sess regexp))
         (dx (or (plist-get args :dx) 0)))
    (drgnx-tty-session-send sess (drgnx-tty-session--click-bytes (+ (car pos) dx) (cdr pos)
                                                                 :mods (plist-get args :mods)
                                                                 :double (plist-get args :double)))))

(defconst drgnx-tty-mouse-test--editor-buffer
  '(buffer-name (window-buffer (drgnx-wb-editor-window)))
  "A form, in the inner Emacs: the name of the editor window's buffer.")

;;;; Text

(ert-deftest drgnx-tty-mouse/click-in-text-moves-point ()
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-mouse-test--project s)
    (drgnx-tty-mouse-test--click-on s "gamma" :dx 2)
    (should (equal (drgnx-tty-session-wait s '(with-current-buffer "a.txt" (and (> (point) 1) (point)))) 14))
    ;; the click selected the editor window too
    (should (drgnx-tty-session-eval s '(eq (selected-window) (drgnx-wb-editor-window))))))

(ert-deftest drgnx-tty-mouse/double-click-selects-a-word ()
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-mouse-test--project s)
    (drgnx-tty-mouse-test--click-on s "beta" :dx 1 :double t)
    (should (equal (drgnx-tty-session-wait s '(with-current-buffer "a.txt"
                                                (and (use-region-p) (buffer-substring-no-properties (region-beginning) (region-end)))))
                   "beta"))))

(ert-deftest drgnx-tty-mouse/wheel-scrolls ()
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-mouse-test--project s)
    (drgnx-tty-session-eval s '(progn (drgnx-wb-show-in-editor (find-file-noselect (expand-file-name "b.txt" (file-name-directory (buffer-file-name (get-buffer "a.txt"))))) t) t))
    (drgnx-tty-session-wait-screen s "line 3\\b")
    (let* ((step (drgnx-tty-session-eval s '(let ((a mouse-wheel-scroll-amount)) (if (consp a) (car a) a))))
           (start (lambda () (drgnx-tty-session-eval s '(with-selected-window (drgnx-wb-editor-window)
                                                          (line-number-at-pos (window-start)))))))
      (should (= (funcall start) 1))
      (let ((pos (drgnx-tty-session-find s "line 3\\b")))
        (drgnx-tty-session-wheel s (car pos) (cdr pos) 'down))
      (should (= (drgnx-tty-session-wait s `(with-selected-window (drgnx-wb-editor-window)
                                              (let ((n (line-number-at-pos (window-start)))) (and (> n 1) n))))
                 (1+ step))))))

;;;; Dividers

(ert-deftest drgnx-tty-mouse/dragging-the-divider-resizes-the-sidebar ()
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-mouse-test--project s)
    (let* ((width (lambda () (drgnx-tty-session-eval s '(window-total-width (car (drgnx-wb--dock-windows))))))
           (before (funcall width))
           (border (drgnx-tty-session-eval s '(nth 2 (window-edges (car (drgnx-wb--dock-windows))))))
           (row 10))
      ;; the border is the character right of the dock's text, on the screen
      (should (string-match-p "|" (nth (1- row) (split-string (drgnx-tty-session-screen s) "\n"))))
      (drgnx-tty-session-drag s (cons border row) (cons (+ border 6) row))
      (should (= (drgnx-tty-session-wait s `(let ((w (window-total-width (car (drgnx-wb--dock-windows)))))
                                              (and (/= w ,before) w)))
                 (+ before 6))))))

;;;; The Explorer

(ert-deftest drgnx-tty-mouse/explorer-click-opens-a-file ()
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-mouse-test--project s)
    (drgnx-tty-mouse-test--click-on s "^  b\\.txt")
    (should (equal (drgnx-tty-session-wait s `(and (equal ,drgnx-tty-mouse-test--editor-buffer "b.txt") t)) t))))

(ert-deftest drgnx-tty-mouse/explorer-ctrl-click-toggles-selection ()
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-mouse-test--project s)
    ;; A Ctrl-click selects from the focused row: that is a.txt only once the follower revealed it, on the bus's idle
    ;; flush (wb/drgnx-signal.el).  Clicks sent before it start from the PROJECT row and select it too.
    (drgnx-tty-session-wait s '(let ((w (drgnx-wb-section-window 'explorer)))
                                 (equal (with-current-buffer (window-buffer w) (drgnx-explorer-node-at (window-point w)))
                                        (buffer-file-name (get-buffer "a.txt")))))
    (drgnx-tty-mouse-test--click-on s "^  a\\.txt" :mods '(control))
    (drgnx-tty-mouse-test--click-on s "^  b\\.txt" :mods '(control))
    (should (equal (drgnx-tty-session-wait
                    s '(with-current-buffer (window-buffer (drgnx-wb-section-window 'explorer))
                         (and (= (length drgnx-explorer--selection) 2)
                              (mapcar #'file-name-nondirectory drgnx-explorer--selection))))
                   '("a.txt" "b.txt")))
    ;; a Ctrl-click on a selected row takes it out
    (drgnx-tty-mouse-test--click-on s "^  a\\.txt" :mods '(control))
    (should (equal (drgnx-tty-session-wait
                    s '(with-current-buffer (window-buffer (drgnx-wb-section-window 'explorer))
                         (and (= (length drgnx-explorer--selection) 1)
                              (mapcar #'file-name-nondirectory drgnx-explorer--selection))))
                   '("b.txt")))
    ;; and nothing was opened by the Ctrl-clicks
    (should (equal (drgnx-tty-session-eval s drgnx-tty-mouse-test--editor-buffer) "a.txt"))))

;;;; Tabs, breadcrumb, status bar

(defun drgnx-tty-mouse-test--two-tabs (sess)
  "a.txt then b.txt in the editor, so both are tabs; wait for both on the tab line.
a.txt is a tab only once the bus's idle flush noted it (a buffer replaced before that is a preview): wait for its
tab before b.txt replaces it.  Tabs are apart by a gap of spaces (wb/drgnx-chrome.el)."
  (drgnx-tty-session-wait-screen sess "a\\.txt ×")
  (drgnx-tty-session-eval sess '(let ((dir (file-name-directory (buffer-file-name (get-buffer "a.txt")))))
                                  (drgnx-wb-show-in-editor (find-file-noselect (expand-file-name "b.txt" dir)) t)
                                  t))
  (drgnx-tty-session-wait-screen sess "a\\.txt × +b\\.txt ×"))

(ert-deftest drgnx-tty-mouse/tab-line-click-selects-a-tab ()
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-mouse-test--project s)
    (drgnx-tty-mouse-test--two-tabs s)
    (should (equal (drgnx-tty-session-eval s drgnx-tty-mouse-test--editor-buffer) "b.txt"))
    (drgnx-tty-mouse-test--click-on s "a\\.txt ×" :dx 1)
    (should (equal (drgnx-tty-session-wait s `(and (equal ,drgnx-tty-mouse-test--editor-buffer "a.txt") t)) t))))

(ert-deftest drgnx-tty-mouse/tab-close-click-closes-it ()
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-mouse-test--project s)
    (drgnx-tty-mouse-test--two-tabs s)
    ;; the × of the shown tab (b.txt)
    (drgnx-tty-mouse-test--click-on s "b\\.txt ×" :dx 6)
    (should (equal (drgnx-tty-session-wait
                    s '(let ((tabs (mapcar #'buffer-name (drgnx-chrome-tabs (drgnx-wb-editor-window)))))
                         (and (not (member "b.txt" tabs)) tabs)))
                   (drgnx-tty-session-eval s '(mapcar #'buffer-name (drgnx-chrome-tabs (drgnx-wb-editor-window))))))
    (should (equal (drgnx-tty-session-eval s drgnx-tty-mouse-test--editor-buffer) "a.txt"))
    (should-not (drgnx-tty-session-find s "b\\.txt ×"))))

(ert-deftest drgnx-tty-mouse/a-breadcrumb-click-is-delivered ()
  ;; event delivery only: drgnx binds no breadcrumb click; the test's own handler sees it arrive as a
  ;; header-line click in the editor window (nothing binds it, but the
  ;; terminal's event must reach Emacs as one, and the editor must stay as it was)
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-mouse-test--project s)
    (drgnx-tty-session-eval s '(progn (setq drgnx-tty-mouse-test--last nil)
                                      (define-key global-map [header-line down-mouse-1] #'ignore)
                                      (define-key global-map [header-line mouse-1]
                                                  (lambda (e) (interactive "e")
                                                    (setq drgnx-tty-mouse-test--last
                                                          (list (posn-area (event-start e)) (window-buffer (posn-window (event-start e)))))))
                                      t))
    (drgnx-tty-mouse-test--click-on s "project › a\\.txt" :dx 3)
    (should (equal (drgnx-tty-session-wait s '(and drgnx-tty-mouse-test--last
                                                   (list (car drgnx-tty-mouse-test--last)
                                                         (buffer-name (cadr drgnx-tty-mouse-test--last)))))
                   '(header-line "a.txt")))))

(ert-deftest drgnx-tty-mouse/status-bar-click ()
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-mouse-test--project s)
    (drgnx-tty-session-eval
     s '(progn (defvar drgnx-tty-mouse-test--clicked nil)
               (defun drgnx-tty-mouse-test--hit () (interactive) (setq drgnx-tty-mouse-test--clicked t))
               (with-current-buffer "a.txt"
                 (setq-local mode-line-format
                             (list " [CLICK-ME] "
                                   (propertize "[ITEM]" 'mouse-face 'mode-line-highlight
                                               'local-map (let ((m (make-sparse-keymap)))
                                                            (define-key m [mode-line mouse-1] #'drgnx-tty-mouse-test--hit)
                                                            m)))))
               (drgnx-chrome-apply (selected-frame) t)
               t))
    (drgnx-tty-session-wait-screen s "\\[ITEM\\]")
    (should-not (drgnx-tty-session-eval s 'drgnx-tty-mouse-test--clicked))
    (drgnx-tty-mouse-test--click-on s "\\[ITEM\\]" :dx 2)
    (should (drgnx-tty-session-wait s 'drgnx-tty-mouse-test--clicked))))

;;;; The menu bar

(ert-deftest drgnx-tty-mouse/the-menu-bar-opens-the-tty-menu ()
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-mouse-test--project s)
    (drgnx-tty-session-eval s '(progn (defvar drgnx-tty-mouse-test--ran nil)
                                      (defun drgnx-tty-mouse-test--item () (interactive) (setq drgnx-tty-mouse-test--ran t))
                                      (define-key global-map [menu-bar file drgnx-test-item]
                                                  '(menu-item "Mouse Test Item" drgnx-tty-mouse-test--item))
                                      t))
    ;; drgnx hides the menu bar by default (`drgnx-face-menu-bar'): this person has brought it back
    (drgnx-tty-session-eval s '(progn (customize-set-variable 'drgnx-face-menu-bar t) t))
    ;; the menu bar is the first row of the frame; the click opens a tty menu (modal) with the new item on top
    (should (= (cdr (drgnx-tty-session-wait-screen s "File +Edit")) 1))
    (should-not (drgnx-tty-session-find s "Mouse Test Item"))
    (drgnx-tty-mouse-test--click-on s "File")
    (drgnx-tty-session-wait-screen s "Mouse Test Item")
    (should-not (drgnx-tty-session-eval s 'drgnx-tty-mouse-test--ran))
    (drgnx-tty-session-key s "RET")
    (should (drgnx-tty-session-eval s 'drgnx-tty-mouse-test--ran))))

;;;; The setting

(defun drgnx-tty-mouse-test--flag (sess want)
  "The pane's SGR mouse flag once it is WANT (waits up to 5 s), else the flag it has."
  (let ((deadline (+ (float-time) 5)))
    (while (and (/= want (plist-get (drgnx-tty-session-pane-flags sess) :mouse-sgr)) (< (float-time) deadline))
      (sleep-for 0.05))
    (plist-get (drgnx-tty-session-pane-flags sess) :mouse-sgr)))

(ert-deftest drgnx-tty-mouse/off-by-setting ()
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-mouse-test--project s)
    (should (eq (drgnx-tty-mouse-test--flag s 1) 1))
    (drgnx-tty-session-eval s '(progn (customize-set-variable 'drgnx-tty-mouse nil) t))
    (should (eq (drgnx-tty-mouse-test--flag s 0) 0))
    (drgnx-tty-session-eval s '(progn (customize-set-variable 'drgnx-tty-mouse t) t))
    (should (eq (drgnx-tty-mouse-test--flag s 1) 1))))

(ert-deftest drgnx-tty-mouse/a-daemon-client-gets-the-mouse ()
  ;; the client's terminal asks for mouse reports; the daemon's own initial terminal is no terminal to ask
  (drgnx-tty-session-with (s :daemon t :size "120x40")
    (drgnx-tty-session-wait-screen s "\\*scratch\\* ×" 20)
    (should (eq (drgnx-tty-mouse-test--flag s 1) 1))
    (drgnx-tty-session-eval s '(progn (customize-set-variable 'drgnx-tty-mouse nil) t))
    (should (eq (drgnx-tty-mouse-test--flag s 0) 0))))

;;;; Each terminal's mouse strings stay its own

(defconst drgnx-tty-mouse-test--clients
  '(seq-filter (lambda (f) (and (frame-live-p f) (frame-parameter f 'client))) (frame-list))
  "A form, in the inner daemon: its client frames, newest first.")

(defconst drgnx-tty-mouse-test--strings
  `(let ((on (xterm-mouse-tracking-enable-sequence)) (off (xterm-mouse-tracking-disable-sequence)))
     (mapcar (lambda (f) (let ((term (frame-terminal f)))
                           (list (seq-count (lambda (s) (equal s on)) (terminal-parameter term 'tty-mode-set-strings))
                                 (seq-count (lambda (s) (equal s off)) (terminal-parameter term 'tty-mode-reset-strings)))))
             ,drgnx-tty-mouse-test--clients))
  "A form: for each client's terminal, how many mouse enable strings it re-sends on resume and disable strings
on suspend or exit.")

(ert-deftest drgnx-tty-mouse/toggling-keeps-each-terminal-s-strings-on-itself ()
  ;; Emacs stores a terminal's enable and disable strings on the selected terminal: toggled from one client,
  ;; the other's must still be its own, once each, and none when off (a resume must not turn it back on)
  (drgnx-tty-session-with (s :daemon t :size "120x40")
    (let ((c (drgnx-tty-session-client s)))
      (should (eq (drgnx-tty-mouse-test--flag c 1) 1))
      (should (equal (drgnx-tty-session-eval s drgnx-tty-mouse-test--strings) '((1 1) (1 1))))
      (drgnx-tty-session-eval s `(with-selected-frame (car (last ,drgnx-tty-mouse-test--clients))
                                   (customize-set-variable 'drgnx-tty-mouse nil) t))
      (should (eq (drgnx-tty-mouse-test--flag c 0) 0))
      (should (eq (drgnx-tty-mouse-test--flag s 0) 0))
      (should (equal (drgnx-tty-session-eval s drgnx-tty-mouse-test--strings) '((0 0) (0 0))))
      (drgnx-tty-session-eval s `(with-selected-frame (car (last ,drgnx-tty-mouse-test--clients))
                                   (customize-set-variable 'drgnx-tty-mouse t) t))
      (should (eq (drgnx-tty-mouse-test--flag c 1) 1))
      (should (equal (drgnx-tty-session-eval s drgnx-tty-mouse-test--strings) '((1 1) (1 1)))))))

(ert-deftest drgnx-tty-mouse/a-client-that-exits-gives-its-terminal-the-mouse-back ()
  (drgnx-tty-session-with (s :daemon t :size "120x40")
    (let ((c (drgnx-tty-session-client s)))
      (should (eq (drgnx-tty-mouse-test--flag c 1) 1))
      ;; toggled from the other client first, so its strings were set from another terminal
      (drgnx-tty-session-eval s `(with-selected-frame (car (last ,drgnx-tty-mouse-test--clients))
                                   (customize-set-variable 'drgnx-tty-mouse nil)
                                   (customize-set-variable 'drgnx-tty-mouse t) t))
      (should (eq (drgnx-tty-mouse-test--flag c 1) 1))
      (drgnx-tty-session-eval s `(progn (delete-frame (car ,drgnx-tty-mouse-test--clients)) t))
      (drgnx-tty-session-wait-screen c "\\[emacsclient exited")
      (should (eq (drgnx-tty-mouse-test--flag c 0) 0)))))

;;; mouse-test.el ends here
