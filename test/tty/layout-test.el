;;; layout-test.el --- tty tier: the workbench's docks by terminal size -*- lexical-binding: t -*-
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.
(require 'ert)
(require 'drgnx-tty-session)

(defconst drgnx-tty-layout-test--state
  '(list (frame-width) (frame-height)
         (let ((w (car (drgnx-wb--dock-windows)))) (and w (window-total-width w)))
         (let ((w (drgnx-wb-area-window 'panel))) (and w (window-total-height w)))
         (and (drgnx-wb-area-window 'right) t))
  "A form, in the inner Emacs: (COLUMNS LINES SIDEBAR-WIDTH PANEL-HEIGHT RIGHT-DOCK-SHOWING).")

(defun drgnx-tty-layout-test--ready (sess)
  "Wait until SESS's frame has been laid out (the layout has seen its size)."
  (drgnx-tty-session-wait-screen sess "\\*scratch\\* ×" 20)
  (drgnx-tty-session-wait sess '(frame-parameter nil 'drgnx-tty-layout-size) 10))

(defun drgnx-tty-layout-test--resize (sess size)
  "Resize SESS's terminal to SIZE and wait until the frame has the new width and the layout has seen it."
  (drgnx-tty-session-resize sess size)
  (let ((cols (string-to-number (car (split-string size "x")))))
    (drgnx-tty-session-wait sess `(and (= (frame-width) ,cols)
                                       (= (car (frame-parameter nil 'drgnx-tty-layout-size)) ,cols)))))

(defun drgnx-tty-layout-test--state (sess)
  (drgnx-tty-session-eval sess drgnx-tty-layout-test--state))

(ert-deftest drgnx-tty-layout/80x24-starts-with-the-editor-alone ()
  (drgnx-tty-session-with (s :size "80x24")
    (drgnx-tty-layout-test--ready s)
    (should (equal (nthcdr 2 (drgnx-tty-layout-test--state s)) '(nil nil nil)))
    (drgnx-tty-session-quiet s)
    (should-not (drgnx-tty-session-find s "EXPLORER"))))

(ert-deftest drgnx-tty-layout/120x40-starts-with-the-sidebar-and-panel ()
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-layout-test--ready s)
    (drgnx-tty-session-wait-screen s "EXPLORER")
    (pcase-let ((`(,_c ,_l ,dock ,panel ,right) (drgnx-tty-layout-test--state s)))
      (should dock)
      (should panel)
      ;; the right dock stays hidden, as in a graphical window
      (should-not right))))

(ert-deftest drgnx-tty-layout/a-daemon-client-starts-the-same ()
  (drgnx-tty-session-with (s :daemon t :size "120x40")
    (drgnx-tty-session-wait-screen s "\\*scratch\\* ×" 20)
    (drgnx-tty-session-wait-screen s "EXPLORER")
    (should (cadddr (drgnx-tty-session-eval
                     s `(with-selected-frame (car (seq-filter (lambda (f) (frame-parameter f 'client)) (frame-list)))
                          ,drgnx-tty-layout-test--state))))))

(ert-deftest drgnx-tty-layout/docks-are-fractions-of-the-terminal ()
  (drgnx-tty-session-with (s :size "160x50")
    (drgnx-tty-layout-test--ready s)
    (drgnx-tty-session-wait s '(drgnx-wb--dock-windows))
    (drgnx-tty-session-eval s '(progn (drgnx-wb-area-show 'right) t))
    (pcase-let ((`(,cols ,lines ,dock ,panel ,_) (drgnx-tty-layout-test--state s)))
      (should (= dock (round (* 0.25 cols))))
      (should (= dock 40))
      (should (= panel (round (* 0.30 lines))))
      (should (= panel 15)))
    (should (= (drgnx-tty-session-eval s '(window-total-width (drgnx-wb-area-window 'right))) 48))
    ;; a narrower terminal: the shown docks follow
    (drgnx-tty-layout-test--resize s "100x50")
    (drgnx-tty-session-wait s '(= (window-total-width (car (drgnx-wb--dock-windows))) 25))
    (should (= (drgnx-tty-session-eval s '(window-total-width (drgnx-wb-area-window 'right))) 30))))

(ert-deftest drgnx-tty-layout/growing-shows-what-the-size-hid ()
  (drgnx-tty-session-with (s :size "80x24")
    (drgnx-tty-layout-test--ready s)
    (should (equal (nthcdr 2 (drgnx-tty-layout-test--state s)) '(nil nil nil)))
    ;; room for the sidebar, not for the panel
    (drgnx-tty-layout-test--resize s "120x24")
    (drgnx-tty-session-wait s '(drgnx-wb--dock-windows))
    (should-not (nth 3 (drgnx-tty-layout-test--state s)))
    ;; room for both
    (drgnx-tty-layout-test--resize s "120x40")
    (drgnx-tty-session-wait s '(drgnx-wb-area-window 'panel))
    (drgnx-tty-session-wait-screen s "EXPLORER")))

(ert-deftest drgnx-tty-layout/growing-never-reopens-what-you-closed ()
  (drgnx-tty-session-with (s :size "80x24" :keys 'vscode)
    (drgnx-tty-layout-test--ready s)
    (drgnx-tty-session-key s "C-b" 'legacy)                ; open the sidebar …
    (drgnx-tty-session-wait s '(drgnx-wb--dock-windows))
    (drgnx-tty-session-key s "C-b" 'legacy)                ; … and close it
    (drgnx-tty-session-wait s '(not (drgnx-wb--dock-windows)))
    (drgnx-tty-layout-test--resize s "120x40")
    ;; the panel, which you did not touch, comes; the sidebar stays closed
    (drgnx-tty-session-wait s '(drgnx-wb-area-window 'panel))
    (should-not (drgnx-tty-session-eval s '(and (drgnx-wb--dock-windows) t)))))

(ert-deftest drgnx-tty-layout/shrinking-never-closes-a-dock-you-opened ()
  (drgnx-tty-session-with (s :size "80x24" :keys 'vscode)
    (drgnx-tty-layout-test--ready s)
    (drgnx-tty-session-key s "C-b" 'legacy)
    (drgnx-tty-session-wait s '(drgnx-wb--dock-windows))
    (drgnx-tty-session-wait-screen s "EXPLORER")
    (drgnx-tty-layout-test--resize s "70x20")
    (drgnx-tty-session-quiet s)
    ;; still open, at 25% of 70 columns but never under 20
    (should (equal (drgnx-tty-session-eval s '(let ((w (car (drgnx-wb--dock-windows)))) (and w (window-total-width w))))
                   20))
    (drgnx-tty-session-wait-screen s "EXPLORER")))

(ert-deftest drgnx-tty-layout/a-tiny-terminal-keeps-the-editor ()
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-layout-test--ready s)
    (drgnx-tty-session-wait s '(and (drgnx-wb--dock-windows) (drgnx-wb-area-window 'panel)))
    (let ((buffer (drgnx-tty-session-eval s '(buffer-name (window-buffer (drgnx-wb-editor-window)))))
          (before (drgnx-tty-layout-test--state s)))
      (drgnx-tty-layout-test--resize s "30x8")
      (drgnx-tty-session-quiet s)
      ;; the editor is still there, with its buffer, and nothing went wrong
      (should (equal (drgnx-tty-session-eval s '(buffer-name (window-buffer (drgnx-wb-editor-window)))) buffer))
      (should (drgnx-tty-session-eval s '(window-live-p (drgnx-wb-editor-window))))
      (should-not (drgnx-tty-session-eval
                   s '(with-current-buffer "*Messages*"
                        (save-excursion (goto-char (point-min))
                                        (re-search-forward "[Ee]rror\\|too small\\|Wrong type" nil t)))))
      (drgnx-tty-layout-test--resize s "120x40")
      (drgnx-tty-session-wait s '(and (drgnx-wb--dock-windows) (drgnx-wb-area-window 'panel)))
      ;; the docks are back, at their sizes
      (should (equal (drgnx-tty-session-wait s `(let ((st ,drgnx-tty-layout-test--state))
                                                  (and (nth 2 st) (nth 3 st) st)))
                     before))
      (should (equal (drgnx-tty-session-eval s '(buffer-name (window-buffer (drgnx-wb-editor-window)))) buffer))
      (drgnx-tty-session-wait-screen s "EXPLORER"))))

(ert-deftest drgnx-tty-layout/sets-no-breadcrumb-below-30-lines ()
  (drgnx-tty-session-with (s :size "80x24")
    (drgnx-tty-layout-test--ready s)
    (should (eq (drgnx-tty-session-eval s '(frame-parameter nil 'drgnx-chrome-breadcrumb)) 'off))
    (drgnx-tty-layout-test--resize s "120x40")
    (should (drgnx-tty-session-wait s '(null (frame-parameter nil 'drgnx-chrome-breadcrumb)) 5))))

(ert-deftest drgnx-tty-layout/a-short-terminal-shows-nothing-until-it-has-room ()
  ;; wide enough for the sidebar by its setting, too few lines for anything
  (drgnx-tty-session-with (s :size "80x24")
    (drgnx-tty-layout-test--ready s)
    (drgnx-tty-layout-test--resize s "130x8")
    (drgnx-tty-session-quiet s)
    (should (equal (nthcdr 2 (drgnx-tty-layout-test--state s)) '(nil nil nil)))
    (should (drgnx-tty-session-eval s '(window-live-p (drgnx-wb-editor-window))))
    (drgnx-tty-layout-test--resize s "130x40")
    (drgnx-tty-session-wait s '(and (drgnx-wb--dock-windows) (drgnx-wb-area-window 'panel)))))
