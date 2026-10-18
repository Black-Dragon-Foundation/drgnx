;;; state-test.el --- tty tier: the workbench state store sees changes made outside commands, per frame -*- lexical-binding: t -*-
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.
(require 'ert)
(require 'drgnx-tty-session)

(defconst drgnx-state-tty-test--listen
  '(progn
     (require 'drgnx-state)
     (defvar drgnx-state-tty-test--log nil "(EVENT . DATA) delivered, newest first.")
     (defvar drgnx-state-tty-test--commands 0 "Commands run since the log was cleared.")
     (defun drgnx-state-tty-test--count () (setq drgnx-state-tty-test--commands (1+ drgnx-state-tty-test--commands)))
     (dolist (event '(windows-changed pane-shown frame-resized editor-changed))
       (let ((event event))
         (defalias (intern (format "drgnx-state-tty-test--on-%s" event))
           (lambda (data) (push (cons event data) drgnx-state-tty-test--log)))
         (drgnx-state-subscribe event (intern (format "drgnx-state-tty-test--on-%s" event)) :lane 'now)))
     (add-hook 'pre-command-hook #'drgnx-state-tty-test--count)
     (drgnx-state-mode 1)
     (setq drgnx-state-tty-test--log nil drgnx-state-tty-test--commands 0)
     t)
  "A form, in the inner Emacs: the store on, a recorder on the `now' lane of four events, a command counter.")

(defconst drgnx-state-tty-test--split
  '(progn
     (defun drgnx-state-tty-test--split ()
       "A timer's split: a dock section appears, with no command run."
       (display-buffer-in-side-window
        (get-buffer-create " *st-notes*")
        '((side . left) (slot . 0) (window-width . 20)
          (window-parameters . ((drgnx-role . dock) (drgnx-section . st-notes))))))
     (run-with-timer 0.2 nil #'drgnx-state-tty-test--split)
     t)
  "A form, in the inner Emacs: split from a timer.")

(ert-deftest drgnx-state-tty/a-timer-split-is-seen ()
  ;; Batch Emacs has no redisplay; here the split reaches the store from `window-state-change-functions', before
  ;; the frame is drawn, with no command and no `drgnx-state-sync'.
  (drgnx-tty-session-with (s :size "120x40")
    (should (drgnx-tty-session-eval s drgnx-state-tty-test--listen))
    (should (drgnx-tty-session-eval s drgnx-state-tty-test--split))
    (should (drgnx-tty-session-wait s '(assq 'pane-shown drgnx-state-tty-test--log) 10))
    (should (equal (drgnx-tty-session-eval
                    s '(list (and (assq 'windows-changed drgnx-state-tty-test--log) t)
                             (plist-get (cdr (assq 'pane-shown drgnx-state-tty-test--log)) :kind)
                             (plist-get (cdr (assq 'pane-shown drgnx-state-tty-test--log)) :cause)
                             drgnx-state-tty-test--commands
                             (and (drgnx-state-pane-window 'st-notes) t)))
                   '(t st-notes other 0 t)))))

(defconst drgnx-state-tty-test--clients
  '(seq-filter (lambda (f) (and (frame-live-p f) (frame-parameter f 'client))) (frame-list))
  "A form, in the inner daemon: its client frames, newest first.")

(ert-deftest drgnx-state-tty/frame-resized-and-per-frame-editors ()
  ;; Two clients of one daemon: each frame has its own record and MRU editor; a client's terminal resized
  ;; is that frame's `frame-resized'.  Batch Emacs can neither make a second frame nor resize one.
  (drgnx-tty-session-with (s :daemon t :size "120x40")
    (should (drgnx-tty-session-eval s `(progn (defvar drgnx-state-tty-test--a (car ,drgnx-state-tty-test--clients)) t)))
    (let ((b (drgnx-tty-session-client s)))
      (should (drgnx-tty-session-eval
               s `(progn (defvar drgnx-state-tty-test--b (car ,drgnx-state-tty-test--clients))
                         (not (eq drgnx-state-tty-test--a drgnx-state-tty-test--b)))))
      (should (drgnx-tty-session-eval s drgnx-state-tty-test--listen))
      (should (equal (drgnx-tty-session-eval s '(length (drgnx-state-frames 'tty))) 2))
      ;; frame A gets a second editor window, selected there; B is not touched
      (should (drgnx-tty-session-eval
               s '(with-selected-frame drgnx-state-tty-test--a
                    (select-window (split-window (drgnx-state-editor-window drgnx-state-tty-test--a) nil 'right)) t)))
      (should (drgnx-tty-session-wait
               s '(seq-find (lambda (e) (and (eq (car e) 'editor-changed)
                                             (eq (plist-get (cdr e) :frame) drgnx-state-tty-test--a)))
                            drgnx-state-tty-test--log)
               10))
      (should (equal (drgnx-tty-session-eval
                      s '(list (eq (drgnx-state-editor-window drgnx-state-tty-test--a)
                                   (frame-selected-window drgnx-state-tty-test--a))
                               (eq (window-frame (drgnx-state-editor-window drgnx-state-tty-test--b))
                                   drgnx-state-tty-test--b)
                               (seq-some (lambda (e) (and (eq (car e) 'editor-changed)
                                                          (eq (plist-get (cdr e) :frame) drgnx-state-tty-test--b)))
                                         drgnx-state-tty-test--log)))
                     '(t t nil)))
      ;; B's terminal shrinks: B's frame-resized, with its old and new size
      (drgnx-tty-session-resize b "100x30")
      (should (drgnx-tty-session-wait
               s '(seq-find (lambda (e) (and (eq (car e) 'frame-resized)
                                             (eq (plist-get (cdr e) :frame) drgnx-state-tty-test--b)))
                            drgnx-state-tty-test--log)
               10))
      (should (equal (drgnx-tty-session-eval
                      s '(let ((d (cdr (seq-find (lambda (e) (eq (car e) 'frame-resized)) drgnx-state-tty-test--log))))
                           (list (plist-get (plist-get d :new) :cols)
                                 (> (plist-get (plist-get d :old) :cols) (plist-get (plist-get d :new) :cols))
                                 (seq-some (lambda (e) (and (eq (car e) 'frame-resized)
                                                            (eq (plist-get (cdr e) :frame) drgnx-state-tty-test--a)))
                                           drgnx-state-tty-test--log))))
                     '(100 t nil))))))

;;; state-test.el ends here
