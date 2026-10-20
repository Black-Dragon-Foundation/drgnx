;;; mixed-test.el --- tty tier: one daemon, a graphical window and a terminal window — a popup stays in its own -*- lexical-binding: t -*-
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs).  The daemon is a GUI harness session (headless
;; compositor, config drgnx) with one graphical frame; the terminal window is `emacsclient -t' on its socket in a
;; private tmux server of the tty tier.  Skipped where the GUI harness cannot run (no mutter).
(require 'ert)
(require 'seq)
(require 'drgnx-ui)
(require 'drgnx-tty-session)

(defconst drgnx-tty-mixed-test--state
  '(let ((gui (seq-find (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list)))
         (tty (seq-find (lambda (f) (and (not (display-graphic-p f)) (not (frame-parent f)) (frame-parameter f 'client))) (frame-list))))
     (list :gui (list (frame-pixel-width gui) (frame-pixel-height gui)
                      (mapcar (lambda (w) (list (buffer-name (window-buffer w)) (window-pixel-edges w)))
                              (window-list gui 'nomini)))
           :tty (list (frame-width tty) (frame-height tty)
                      (mapcar (lambda (w) (list (buffer-name (window-buffer w)) (window-edges w)))
                              (window-list tty 'nomini)))
           :transient (let ((w (get-buffer-window " *transient*" t)))
                        (and w (if (eq (window-frame w) gui) 'gui 'tty)))))
  "A form, in the daemon: the graphical frame's and the terminal frame's windows with buffers and edges, and
which frame (`gui' or `tty') shows the transient menu, if any.")

(defun drgnx-tty-mixed-test--wait (gui form &optional timeout)
  "FORM's value in the daemon once it is non-nil (polled for TIMEOUT s, default 10); else fail with FORM and the state."
  (let ((deadline (+ (float-time) (or timeout 10))) v)
    (while (not (setq v (drgnx-tty-session-eval gui form 5)))
      (when (> (float-time) deadline)
        (ert-fail (format "%S stayed nil for %ss; the daemon's windows: %S" form (or timeout 10)
                          (ignore-errors (drgnx-tty-session-eval gui drgnx-tty-mixed-test--state)))))
      (sleep-for 0.05))
    v))

(defun drgnx-tty-mixed-test--state (gui)
  (drgnx-tty-session-eval gui drgnx-tty-mixed-test--state))

(defmacro drgnx-tty-mixed-test--with (spec &rest body)
  "Run BODY with (nth 0 SPEC) the daemon's session and (nth 1 SPEC) the terminal window's tmux session: a graphical
frame and an `emacsclient -t' client of one daemon.  Both are stopped afterwards."
  (declare (indent 1))
  `(progn
     (skip-unless (executable-find "mutter"))
     (let* ((root (make-temp-file "drgnx-mixed" t))
            (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
            (,(nth 0 spec) (drgnx-ui-start "drgnx" nil 60 t))
            (,(nth 1 spec) nil))
       (unwind-protect
           (progn
             (should (eql 0 (plist-get (drgnx-ui-new-frame ,(nth 0 spec)) :exit)))
             (setq ,(nth 1 spec)
                   (drgnx-tty-session-start
                    :size "100x30"
                    :command (format "%s -a false -t -s %s; echo \"[emacsclient exited $?]\"; sh"
                                     (drgnx-ui--emacsclient) (shell-quote-argument (plist-get ,(nth 0 spec) :socket)))))
             (drgnx-tty-session-wait-screen ,(nth 1 spec) "\\*scratch\\*" 30)
             (drgnx-tty-session-wait ,(nth 0 spec) '(seq-some (lambda (f) (and (frame-parameter f 'client) (not (display-graphic-p f)))) (frame-list)) 30)
             ,@body)
         (when ,(nth 1 spec) (drgnx-tty-session-stop ,(nth 1 spec)))
         (drgnx-ui-stop (plist-get ,(nth 0 spec) :name))
         (delete-directory root t)))))

(defun drgnx-tty-mixed-test--transient (gui)
  "A one-key transient on <f9> in the daemon."
  (should (drgnx-tty-session-eval
           gui '(progn (require 'transient)
                       (transient-define-prefix drgnx-tty-mixed-tr () [("a" "Do A" ignore)])
                       (keymap-global-set "<f9>" #'drgnx-tty-mixed-tr)
                       (eq (key-binding (kbd "<f9>")) 'drgnx-tty-mixed-tr)))))

(defconst drgnx-tty-mixed-test--gui-frame
  '(seq-find (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list))
  "A form, in the daemon: the graphical frame.")

(defconst drgnx-tty-mixed-test--tty-frame
  '(seq-find (lambda (f) (and (not (display-graphic-p f)) (not (frame-parent f)) (frame-parameter f 'client))) (frame-list))
  "A form, in the daemon: the terminal client's frame.")

(defun drgnx-tty-mixed-test--in-gui (gui form)
  "FORM's value in the daemon with the graphical frame selected.  The harness types into a graphical frame by
queueing events, which a daemon with a terminal client reads for the terminal last used — so the graphical
window is driven by calls, the terminal window by real keys."
  (drgnx-tty-session-eval gui `(with-selected-frame ,drgnx-tty-mixed-test--gui-frame ,form)))

(ert-deftest drgnx-tty-mixed/a-popup-stays-in-its-own-window ()
  ;; a transient in the graphical window never touches the terminal window, and the other way round
  (drgnx-tty-mixed-test--with (gui tty)
    (drgnx-tty-mixed-test--transient gui)
    (let ((before (drgnx-tty-mixed-test--state gui)))
      ;; in the graphical window
      (drgnx-tty-mixed-test--in-gui gui '(progn (call-interactively #'drgnx-tty-mixed-tr) t))
      (drgnx-tty-mixed-test--wait gui '(and (get-buffer-window " *transient*" t) t))
      (let ((during (drgnx-tty-mixed-test--state gui)))
        (should (eq (plist-get during :transient) 'gui))
        (should (equal (plist-get during :tty) (plist-get before :tty)))
        (should-not (equal (plist-get during :gui) (plist-get before :gui))))
      (drgnx-tty-mixed-test--in-gui gui '(progn (transient--emergency-exit) t))
      (drgnx-tty-mixed-test--wait gui '(null (get-buffer-window " *transient*" t)))
      (should (equal (drgnx-tty-mixed-test--state gui) before))
      ;; in the terminal window
      (drgnx-tty-session-key tty "<f9>" 'legacy)
      (drgnx-tty-mixed-test--wait gui '(and (get-buffer-window " *transient*" t) t))
      (let ((during (drgnx-tty-mixed-test--state gui)))
        (should (eq (plist-get during :transient) 'tty))
        (should (equal (plist-get during :gui) (plist-get before :gui)))
        (should-not (equal (plist-get during :tty) (plist-get before :tty))))
      (drgnx-tty-session-key tty "C-g" 'legacy)
      (drgnx-tty-mixed-test--wait gui '(null (get-buffer-window " *transient*" t)))
      (should (equal (drgnx-tty-mixed-test--state gui) before)))))

(defun drgnx-tty-mixed-test--corfu-dirs ()
  "The corfu and compat directories, or the test is skipped saying how to supply them."
  (drgnx-tty-session-require-packages '(corfu compat)))

(ert-deftest drgnx-tty-mixed/corfu-s-popup-belongs-to-its-frame ()
  ;; the child frame's parent is the frame typed in — the terminal's, then the graphical one's
  (let ((dirs (drgnx-tty-mixed-test--corfu-dirs)))
    (drgnx-tty-mixed-test--with (gui tty)
      (let ((a (expand-file-name "a.el" (plist-get tty :run))) (b (expand-file-name "b.el" (plist-get tty :run))))
        (should (drgnx-tty-session-eval
                 gui `(progn (dolist (d ',dirs) (add-to-list 'load-path d))
                             (require 'corfu)
                             (setq corfu-auto t corfu-auto-delay 0.1 corfu-auto-prefix 2)
                             (global-corfu-mode 1)
                             (let ((gui (seq-find (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list)))
                                   (tty (seq-find (lambda (f) (and (not (display-graphic-p f)) (not (frame-parent f)) (frame-parameter f 'client))) (frame-list))))
                               (with-selected-frame tty
                                 (drgnx-wb-show-in-editor (find-file-noselect ,a) t) (emacs-lisp-mode) (corfu-mode 1))
                               (with-selected-frame gui
                                 (drgnx-wb-show-in-editor (find-file-noselect ,b) t) (emacs-lisp-mode) (corfu-mode 1)))
                             t)))
        (let ((visible-child '(seq-find (lambda (f) (and (frame-parent f) (frame-visible-p f))) (frame-list)))
              (parent-kind '(let ((f (seq-find (lambda (f) (and (frame-parent f) (frame-visible-p f))) (frame-list))))
                              (and f (if (display-graphic-p (frame-parent f)) 'gui 'tty)))))
          ;; typed in the terminal window
          (drgnx-tty-session-send tty "(with-")
          (drgnx-tty-mixed-test--wait gui `(and ,visible-child t) 10)
          (should (eq (drgnx-tty-session-eval gui parent-kind) 'tty))
          (should (drgnx-tty-session-eval gui '(eq (frame-parent (seq-find (lambda (f) (and (frame-parent f) (frame-visible-p f))) (frame-list)))
                                                   (seq-find (lambda (f) (and (not (display-graphic-p f)) (not (frame-parent f)) (frame-parameter f 'client))) (frame-list)))))
          (drgnx-tty-session-key tty "C-g" 'legacy)
          (drgnx-tty-mixed-test--wait gui `(null ,visible-child) 10)
          ;; completion started in the graphical window
          (drgnx-tty-mixed-test--in-gui
           gui `(progn (with-current-buffer (window-buffer (selected-window)) (insert "(with-") (corfu-auto--complete-deferred)) t))
          (drgnx-tty-mixed-test--wait gui `(and ,visible-child t))
          (should (eq (drgnx-tty-session-eval gui parent-kind) 'gui))
          (should (drgnx-tty-session-eval gui `(eq (frame-parent ,visible-child) ,drgnx-tty-mixed-test--gui-frame))))))))

;;; mixed-test.el ends here
