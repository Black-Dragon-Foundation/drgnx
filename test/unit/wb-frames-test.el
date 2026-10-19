;;; wb-frames-test.el --- batch tests: frame roles, saving every window, the bus's frame edges -*- lexical-binding: t -*-
;; Batch Emacs has one frame: frame lists are mocked here; real frames are tested live.
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-frames)
(require 'drgnx-persist)

(defvar drgnx-frames-test--synced nil "The frames `drgnx-state-sync' was asked about, newest first.")

(defmacro drgnx-frames-test--fake (frames &rest body)
  "BODY with `frame-list' answering FRAMES (newest first, as Emacs does) and every frame graphical,
visible, without parent.  The classifier answers from those (`child', `gui' or `tty'); `drgnx-state-sync'
only notes the frame in `drgnx-frames-test--synced' (the frames are symbols)."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'frame-list) (lambda () ,frames))
             ((symbol-function 'frame-live-p) (lambda (f) (memq f ,frames)))
             ((symbol-function 'display-graphic-p) (lambda (&optional _) t))
             ((symbol-function 'frame-visible-p) (lambda (_) t))
             ((symbol-function 'frame-parent) (lambda (&optional _) nil))
             ((symbol-function 'drgnx-state-frame-kind)
              (lambda (f) (and (memq f ,frames) (cond ((frame-parent f) 'child) ((display-graphic-p f) 'gui) (t 'tty)))))
             ((symbol-function 'drgnx-state-sync) (lambda (&optional f) (push f drgnx-frames-test--synced) nil)))
     ,@body))

(ert-deftest drgnx-frames/main-is-the-selected-or-oldest-frame-never-a-child ()
  ;; C1: `frame-list' is newest first; a child frame (posframe) is never main.
  (let* ((old (selected-frame)) (params (make-hash-table)))
    (cl-letf (((symbol-function 'frame-parameter) (lambda (f p) (and (eq p 'drgnx-frame-role) (gethash f params))))
              ((symbol-function 'set-frame-parameter) (lambda (f p v) (when (eq p 'drgnx-frame-role) (puthash f v params)))))
      (drgnx-frames-test--fake (list 'newest 'child old)
        (cl-letf (((symbol-function 'frame-parent) (lambda (&optional f) (and (eq f 'child) old)))
                  ((symbol-function 'selected-frame) (lambda () 'child)))
          (drgnx-frames-mark-main)
          (should (eq (gethash old params) 'main))     ; not the child, not the newest
          (should-not (gethash 'newest params)))))))

(ert-deftest drgnx-frames/the-restored-home-window-is-main ()
  ;; C1: restoring puts the main layout in the selected frame and makes it the main window.
  (let* ((dir (make-temp-file "drgnx-frames" t)) (drgnx-persist-file (expand-file-name "s.eld" dir)))
    (unwind-protect
        (progn
          (set-frame-parameter nil 'drgnx-frame-role nil)
          (with-temp-file drgnx-persist-file
            (prin1 '(:version 2 :frames ((:role main :left (:shown nil) :panel (:shown nil) :right (:shown nil)
                                                :main nil :groups nil)))
                   (current-buffer)))
          (drgnx-persist-restore)
          (should (eq (frame-parameter nil 'drgnx-frame-role) 'main)))
      (delete-directory dir t))))

(ert-deftest drgnx-frames/invisible-frames-are-not-windows ()
  ;; A daemon's hidden frames are not windows of the workbench (Buffers panel scope, saving).
  (cl-letf (((symbol-function 'frame-visible-p) (lambda (_) nil)))
    (should-not (drgnx-frames--workbench-p (selected-frame)))))

(ert-deftest drgnx-frames/a-closing-client-saves-every-window ()
  ;; I1: `server-delete-client' deletes a daemon client's frames one by one; save them all first.
  (let* ((dir (make-temp-file "drgnx-frames" t)) (drgnx-persist-file (expand-file-name "s.eld" dir))
         (drgnx-persist--saved-at-exit nil))
    (unwind-protect
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t)))
          (set-frame-parameter nil 'client 'kx-proc)
          (drgnx-persist--before-client-delete 'kx-proc)
          (should (file-exists-p drgnx-persist-file))
          (should drgnx-persist--saved-at-exit)
          (delete-file drgnx-persist-file)
          (drgnx-persist--on-delete-frame (selected-frame))     ; the frames go: no second, partial save
          (should-not (file-exists-p drgnx-persist-file)))
      (set-frame-parameter nil 'client nil)
      (delete-directory dir t))))

(ert-deftest drgnx-frames/the-bus-tells-when-the-window-or-tabs-change ()
  ;; I2: switching to another frame, or a tab set changing, re-renders frame-scoped lists.
  (drgnx-test-with-state
    (let ((seen nil) (was-on drgnx-signal-mode))
      (unwind-protect
          (progn
            (drgnx-signal-mode 1)                       ; the bus listens to the store's `selected-changed'
            (drgnx-signal-subscribe 'frame-changed (lambda (_) (push 'frame seen)))
            (drgnx-signal-subscribe 'tabs-changed (lambda (_) (push 'tabs seen)))
            (drgnx-signal--flush)
            (setq seen nil)
            (drgnx-state--emit 'selected-changed (list :frame (selected-frame) :window (selected-window)
                                                       :old-window nil :old-frame 'another))
            (drgnx-signal--flush)
            (should (memq 'frame seen))
            (drgnx-signal-post 'tabs-changed)
            (drgnx-signal--flush)
            (should (memq 'tabs seen)))
        (unless was-on (drgnx-signal-mode -1))))))

(defmacro drgnx-frames-test--terminal (daemon terminal &rest body)
  "BODY with every frame a visible, parentless text frame on a terminal named TERMINAL; `daemonp' DAEMON."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'daemonp) (lambda () ,daemon))
             (noninteractive nil)         ; the classifier counts the initial terminal as a workbench in batch
             ((symbol-function 'display-graphic-p) (lambda (&optional _) nil))
             ((symbol-function 'frame-visible-p) (lambda (_) t))
             ((symbol-function 'frame-parent) (lambda (&optional _) nil))
             ((symbol-function 'frame-terminal) (lambda (&optional _) 'kx-terminal))
             ((symbol-function 'terminal-name) (lambda (&optional _) ,terminal)))
     ,@body))

(ert-deftest drgnx-frames/a-daemon-s-client-terminal-frame-is-a-workbench ()
  ;; `emacsclient -t' (and `emacs -nw') get the workbench: a text frame is a window like a graphical one
  (drgnx-frames-test--terminal "drgnx" "/dev/pts/3"
    (should (drgnx-frames--workbench-p (selected-frame))))
  (drgnx-frames-test--terminal nil "/dev/tty"
    (should (drgnx-frames--workbench-p (selected-frame)))))

(ert-deftest drgnx-frames/the-daemon-s-initial-frame-is-not ()
  ;; the daemon's own frame (F1, on its initial terminal) is nobody's window
  (drgnx-frames-test--terminal "drgnx" "initial_terminal"
    (should-not (drgnx-frames--workbench-p (selected-frame)))))

(ert-deftest drgnx-frames/a-new-terminal-frame-is-main-unless-a-child-or-the-daemon-s ()
  ;; after-make-frame-functions: a client's terminal frame becomes main when none is; a child frame, or one on
  ;; the daemon's initial terminal, never does
  (let ((params (make-hash-table)) (parent nil) (terminal "/dev/pts/3"))
    (cl-letf (((symbol-function 'frame-parameter) (lambda (f p) (and (eq p 'drgnx-frame-role) (gethash f params))))
              ((symbol-function 'set-frame-parameter) (lambda (f p v) (when (eq p 'drgnx-frame-role) (puthash f v params)))))
      (drgnx-frames-test--terminal "drgnx" terminal
        (cl-letf (((symbol-function 'frame-list) (lambda () '(kx-new)))
                  ((symbol-function 'frame-live-p) (lambda (f) (eq f 'kx-new)))
                  ((symbol-function 'frame-parent) (lambda (&optional _) parent))
                  ;; the real classifier on a symbol frame: what `drgnx-state-frame-kind' says of a text frame
                  ((symbol-function 'drgnx-state-frame-kind)
                   (lambda (f)
                     (cond ((not (eq f 'kx-new)) nil) (parent 'child)
                           ((equal terminal "initial_terminal") 'initial) (t 'tty))))
                  ((symbol-function 'drgnx-state-sync) #'ignore))
          (setq parent 'kx-parent)
          (drgnx-frames--made 'kx-new)
          (should-not (gethash 'kx-new params))
          (setq parent nil terminal "initial_terminal")
          (drgnx-frames--made 'kx-new)
          (should-not (gethash 'kx-new params))
          (setq terminal "/dev/pts/3")
          (drgnx-frames--made 'kx-new)
          (should (eq (gethash 'kx-new params) 'main)))))))

(ert-deftest drgnx-frames/the-first-graphical-window-takes-main-from-a-terminal-one ()
  ;; the daemon's first client was a terminal, so its frame became main; the first graphical window then becomes
  ;; main (its buffer list has the files that are a tab nowhere; persist saves it as main), without a restore
  (let ((params (make-hash-table)) (drgnx-frames-mode nil) (drgnx-first-gui-frame-hook nil)
        (after-make-frame-functions nil) (delete-frame-functions nil)
        (completion-category-overrides nil))
    (puthash 'kx-tty 'main params)
    (cl-letf (((symbol-function 'frame-parameter) (lambda (f p) (and (eq p 'drgnx-frame-role) (gethash f params))))
              ((symbol-function 'set-frame-parameter) (lambda (f p v) (when (eq p 'drgnx-frame-role) (puthash f v params)))))
      (drgnx-frames-test--fake (list 'kx-gui 'kx-tty)
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional f) (eq f 'kx-gui))))
          (drgnx-frames-mode 1)
          (unwind-protect
              (progn
                (run-hooks 'drgnx-first-gui-frame-hook)
                (should (eq (gethash 'kx-gui params) 'main))
                (should-not (eq (gethash 'kx-tty params) 'main))
                ;; a graphical main window stays main
                (puthash 'kx-gui 'main params)
                (run-hooks 'drgnx-first-gui-frame-hook)
                (should (eq (gethash 'kx-gui params) 'main)))
            (drgnx-frames-mode -1)))))))

(ert-deftest drgnx-frames/an-editor-frame-is-never-main ()
  ;; an EDITOR frame (`emacsclient -t FILE', role `editor') is kept for one file: the next window is main
  (let ((params (make-hash-table)))
    (puthash 'kx-editor 'editor params)
    (cl-letf (((symbol-function 'frame-parameter) (lambda (f p) (and (eq p 'drgnx-frame-role) (gethash f params))))
              ((symbol-function 'set-frame-parameter) (lambda (f p v) (when (eq p 'drgnx-frame-role) (puthash f v params)))))
      (drgnx-frames-test--fake (list 'kx-later 'kx-editor)
        (drgnx-frames-mark-main)
        (should (eq (gethash 'kx-later params) 'main))
        (should (eq (gethash 'kx-editor params) 'editor))
        (should (eq (drgnx-frame-role 'kx-editor) 'aux))
        ;; the main window closes: the editor frame does not take over
        (clrhash params)
        (puthash 'kx-editor 'editor params)
        (puthash 'kx-later 'main params)
        (cl-letf (((symbol-function 'drgnx-signal-post) #'ignore))
          (drgnx-frames--deleted 'kx-later))
        (should (eq (gethash 'kx-editor params) 'editor))))))

;;;; The classifier (Task 16)

(ert-deftest drgnx-frames/predicates-ask-the-classifier ()
  ;; what a frame is comes from `drgnx-state-frame-kind' alone: gui and tty frames are workbench frames, children,
  ;; the daemon's initial frame and minibuffer-only frames are not; a hidden frame is not a window; an EDITOR frame
  ;; is a window but never a candidate for main
  (let ((frame (selected-frame)) (kind nil) (asked 0) (role (frame-parameter nil 'drgnx-frame-role)))
    (cl-letf (((symbol-function 'drgnx-state-frame-kind) (lambda (_f) (cl-incf asked) kind))
              ((symbol-function 'frame-visible-p) (lambda (_f) t)))
      (unwind-protect
          (progn
            (set-frame-parameter frame 'drgnx-frame-role nil)
            (dolist (case '((gui . t) (tty . t) (child . nil) (initial . nil) (other . nil) (nil . nil)))
              (setq kind (car case))
              (should (eq (and (drgnx-frames--workbench-p frame) t) (cdr case)))
              (should (eq (and (drgnx-frames--candidate-p frame) t) (cdr case))))
            (should (> asked 0))
            (setq kind 'gui)
            (set-frame-parameter frame 'drgnx-frame-role 'editor)
            (should (drgnx-frames--workbench-p frame))
            (should-not (drgnx-frames--candidate-p frame))
            (set-frame-parameter frame 'drgnx-frame-role 'main)
            (should (drgnx-frames--candidate-p frame))
            (cl-letf (((symbol-function 'frame-visible-p) (lambda (_f) nil)))
              (should-not (drgnx-frames--workbench-p frame))))
        (set-frame-parameter frame 'drgnx-frame-role role)))))

(ert-deftest drgnx-frames/a-role-written-is-seen-at-once ()
  ;; the store compares `drgnx-frame-role' only when it observes: the writers observe the frame themselves
  (drgnx-test-with-state
    (let* ((frame (selected-frame)) (role (frame-parameter frame 'drgnx-frame-role)))
      (unwind-protect
          (progn
            (set-frame-parameter frame 'drgnx-frame-role nil)
            (drgnx-state-sync frame)
            (should-not (drgnx-state-main-frame))
            (drgnx-frames-mark-main frame)
            (should (eq (drgnx-state-main-frame) frame)))     ; no sync of ours in between
        (set-frame-parameter frame 'drgnx-frame-role role))))
  ;; the same for the frames the other writers touch: the next main window, and the terminal frame that gives up
  (let ((params (make-hash-table)))
    (cl-letf (((symbol-function 'frame-parameter) (lambda (f p) (and (eq p 'drgnx-frame-role) (gethash f params))))
              ((symbol-function 'set-frame-parameter) (lambda (f p v) (when (eq p 'drgnx-frame-role) (puthash f v params))))
              ((symbol-function 'drgnx-signal-post) #'ignore))
      (drgnx-frames-test--fake (list 'kx-next 'kx-main)
        (setq drgnx-frames-test--synced nil)
        (puthash 'kx-main 'main params)
        (drgnx-frames--deleted 'kx-main)
        (should (eq (gethash 'kx-next params) 'main))
        (should (memq 'kx-next drgnx-frames-test--synced)))
      (drgnx-frames-test--fake (list 'kx-gui 'kx-tty)
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional f) (eq f 'kx-gui))))
          (clrhash params)
          (setq drgnx-frames-test--synced nil)
          (puthash 'kx-tty 'main params)
          (drgnx-frames--first-gui)
          (should-not (gethash 'kx-tty params))
          (should (eq (gethash 'kx-gui params) 'main))
          (should (memq 'kx-tty drgnx-frames-test--synced))
          (should (memq 'kx-gui drgnx-frames-test--synced)))))))
