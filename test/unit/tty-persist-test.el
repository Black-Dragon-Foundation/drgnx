;;; tty-persist-test.el --- batch tests: a terminal window neither saves nor restores the layout -*- lexical-binding: t -*-
;; Batch Emacs has one frame, on the initial terminal.  A real terminal window is told apart by its terminal's
;; name, so these tests make that frame look like one by stubbing `terminal-name'; a second, graphical frame
;; cannot exist in batch, so it is a symbol and `select-frame' records the frames the code selects.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-persist)

(defconst tty-persist-test--message "Layouts are saved and restored from graphical windows")

(defmacro tty-persist-test--with (dir &rest body)
  "BODY with DIR a temp directory, `drgnx-persist-file' in it, and the selected frame looking like a terminal
window (its terminal is \"/dev/pts/9\").  `messages' collects what `message' says, `selected' the frames
`select-frame' was asked for (newest first)."
  (declare (indent 1))
  `(let* ((,dir (file-name-as-directory (make-temp-file "drgnx-tty-persist" t)))
          (drgnx-persist-file (expand-file-name "state.eld" ,dir))
          (drgnx-persist--pending nil) messages selected)
     (unwind-protect
         (cl-letf (((symbol-function 'terminal-name) (lambda (&optional _) "/dev/pts/9"))
                   ((symbol-function 'message)
                    (lambda (fmt &rest args) (push (apply #'format fmt args) messages) nil))
                   ;; what persist says is a notice (Task 20): its text is collected like a message
                   ((symbol-function 'drgnx-notify) (lambda (_source _severity text &rest _) (push text messages) nil))
                   ((symbol-function 'select-frame-set-input-focus) #'ignore))
           ,@body)
       (delete-directory ,dir t))))

(defun tty-persist-test--write (file state)
  (with-temp-file file (prin1 state (current-buffer)))
  (set-file-times file (time-subtract (current-time) 3600)))     ; an hour ago: a rewrite shows

(defun tty-persist-test--bytes (file)
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(ert-deftest drgnx-persist/a-terminal-frame-neither-saves-nor-restores ()
  (tty-persist-test--with dir
    (let ((state '(:version 2 :frames ((:role main :left (:shown t :view explorer) :groups ((:tabs nil))))))
          (restored 0))
      (tty-persist-test--write drgnx-persist-file state)
      (let ((bytes (tty-persist-test--bytes drgnx-persist-file))
            (mtime (file-attribute-modification-time (file-attributes drgnx-persist-file))))
        (should-not (drgnx-persist-save))
        (should (equal messages (list tty-persist-test--message)))
        (should-not (drgnx-persist-save (expand-file-name "other.eld" dir)))      ; nor to another file
        (should-not (file-exists-p (expand-file-name "other.eld" dir)))
        (setq messages nil)
        (cl-letf (((symbol-function 'drgnx-persist--restore-frame) (lambda (_st) (cl-incf restored))))
          (should-not (drgnx-persist-restore)))           ; no graphical frame to restore into
        (should (= restored 0))
        (should (equal messages (list tty-persist-test--message)))
        (drgnx-persist--on-exit)                          ; Emacs exiting in a terminal
        (should (equal (tty-persist-test--bytes drgnx-persist-file) bytes))
        (should (equal (file-attribute-modification-time (file-attributes drgnx-persist-file)) mtime))))))

(ert-deftest drgnx-persist/a-terminal-restore-goes-into-the-graphical-window ()
  ;; the user's ruling (2026-10-18): Restore Workbench Layout typed in a terminal window, while a graphical window
  ;; is open, restores into that window and says so in the terminal; the terminal frame's layout is not touched, and
  ;; focus stays where it is (the user may be over SSH, or in the terminal on purpose)
  (tty-persist-test--with dir
    (tty-persist-test--write drgnx-persist-file '(:version 2 :frames ((:role main :groups ((:tabs nil))))))
    (let (restored-in focused)
      (cl-letf (((symbol-function 'drgnx-persist--gui-frame) (lambda () 'gui-frame))
                ((symbol-function 'select-frame-set-input-focus) (lambda (f &rest _) (push f focused)))
                ((symbol-function 'select-frame) (lambda (f &optional _) (push f selected) f))
                ((symbol-function 'frame-live-p) (lambda (f) (and f t)))
                ((symbol-function 'set-frame-parameter) #'ignore)
                ((symbol-function 'drgnx-persist--restore-frame)
                 (lambda (_st) (setq restored-in (car selected)) t)))
        (should (drgnx-persist-restore))
        (should (eq restored-in 'gui-frame))
        (should-not focused)
        (should (equal messages '("Restored into the graphical window")))))))

(ert-deftest drgnx-persist/restore-from-a-terminal-frame ()
  ;; Question 1 (the user, 2026-10-18): the store says which frame is the graphical one; the layout goes into it,
  ;; the terminal frame is not touched, focus stays, and the echo area says where it went.  With none, the command
  ;; says it works only in a graphical window.
  (tty-persist-test--with dir
    (tty-persist-test--write drgnx-persist-file '(:version 2 :frames ((:role main :groups ((:tabs nil))))))
    (let (restored-in focused)
      (cl-letf (((symbol-function 'drgnx-state-frame-kind) (lambda (f) (if (eq f 'gui-frame) 'gui 'tty)))
                ((symbol-function 'frame-list) (lambda () (list (selected-frame) 'gui-frame)))
                ((symbol-function 'select-frame-set-input-focus) (lambda (f &rest _) (push f focused)))
                ((symbol-function 'select-frame) (lambda (f &optional _) (push f selected) f))
                ((symbol-function 'frame-live-p) (lambda (f) (and f t)))
                ((symbol-function 'frame-parameter) (lambda (&rest _) nil))
                ((symbol-function 'set-frame-parameter) #'ignore)
                ((symbol-function 'drgnx-state-sync) #'ignore)
                ((symbol-function 'drgnx-persist--restore-frame)
                 (lambda (_st) (setq restored-in (car selected)) t)))
        (should (drgnx-persist-restore))
        (should (eq restored-in 'gui-frame))
        (should-not focused)
        (should (equal messages '("Restored into the graphical window")))
        (setq messages nil restored-in nil)
        (cl-letf (((symbol-function 'frame-list) (lambda () (list (selected-frame)))))
          (should-not (drgnx-persist-restore)))
        (should-not restored-in)
        (should (equal messages (list tty-persist-test--message)))))))

(defmacro tty-persist-test--with-home (dir &rest body)
  "Like `tty-persist-test--with', but the selected frame is on the initial terminal (batch Emacs's, a daemon's
first; the store calls it `initial'), so no terminal guard applies."
  (declare (indent 1))
  `(let* ((,dir (file-name-as-directory (make-temp-file "drgnx-tty-persist" t)))
          (drgnx-persist-file (expand-file-name "state.eld" ,dir))
          (drgnx-persist--pending nil) messages selected)
     (unwind-protect
         (cl-letf (((symbol-function 'message)
                    (lambda (fmt &rest args) (push (apply #'format fmt args) messages) nil))
                   ((symbol-function 'drgnx-notify) (lambda (_source _severity text &rest _) (push text messages) nil))
                   ((symbol-function 'drgnx-state-frame-kind) (lambda (f) (and (framep f) 'initial)))
                   ((symbol-function 'select-frame-set-input-focus) #'ignore))
           ,@body)
       (delete-directory ,dir t))))

(ert-deftest drgnx-persist/a-job-window-restores-onto-the-graphical-display ()
  ;; M9b4-16: the function that rebuilds the window runs with the graphical frame selected, so the window is made
  ;; on that display, never laid out over a text frame.
  (tty-persist-test--with-home dir
    (let (rebuilt-in)
      (tty-persist-test--write drgnx-persist-file '(:version 2 :frames ((:role custom :restore (tty-persist-test--rebuild "j1")))))
      (cl-letf (((symbol-function 'tty-persist-test--rebuild) (lambda (&rest _) (setq rebuilt-in (car selected)) nil))
                ((symbol-function 'drgnx-persist--gui-frame) (lambda () 'gui-frame))
                ((symbol-function 'select-frame) (lambda (f &optional _) (push f selected) f))
                ((symbol-function 'frame-live-p) (lambda (f) (and f t))))
        (should (drgnx-persist-restore))
        (should (eq rebuilt-in 'gui-frame))
        (should-not messages)))))

(ert-deftest drgnx-persist/a-job-window-without-a-graphical-display-is-skipped ()
  ;; no graphical frame: the window is not laid out over the frame there is, and the message says why
  (tty-persist-test--with-home dir
    (let ((rebuilt 0))
      (tty-persist-test--write drgnx-persist-file '(:version 2 :frames ((:role custom :restore (tty-persist-test--rebuild "j1")))))
      (cl-letf (((symbol-function 'tty-persist-test--rebuild) (lambda (&rest _) (cl-incf rebuilt) nil)))
        (should (drgnx-persist-restore))
        (should (= rebuilt 0))
        (should (equal messages '("a window was not restored: no graphical display")))))))

(ert-deftest drgnx-persist/the-graphical-frame-is-never-a-child-frame ()
  (cl-letf (((symbol-function 'frame-list) (lambda () (list (selected-frame) 'top)))
            ((symbol-function 'drgnx-state-frame-kind) (lambda (f) (if (eq f 'top) 'gui 'child))))
    (should (eq (drgnx-persist--gui-frame) 'top))))

(ert-deftest drgnx-persist/the-last-graphical-window-closing-still-saves-from-a-terminal-selection ()
  ;; a client closing its last graphical windows saves them all, though a terminal window is the selected frame
  (tty-persist-test--with dir
    (let (saved (drgnx-persist--saved-at-exit nil))
      (cl-letf (((symbol-function 'drgnx-state-frame-kind) (lambda (f) (and (eq f 'gui-frame) 'gui)))
                ((symbol-function 'frame-live-p) (lambda (f) (and f t)))
                ((symbol-function 'frame-list) (lambda () '(gui-frame)))
                ((symbol-function 'frame-parameter) (lambda (_f p) (and (eq p 'client) 'proc)))
                ((symbol-function 'drgnx-persist--frames) (lambda () '(gui-frame)))
                ((symbol-function 'drgnx-persist-state) (lambda (f) (push f saved) (list :role 'main))))
        (drgnx-persist--before-client-delete 'proc)
        (should (equal saved '(gui-frame)))
        (should (file-exists-p drgnx-persist-file))
        (should-not messages)))))

;;; tty-persist-test.el ends here
