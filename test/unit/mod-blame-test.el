;;; mod-blame-test.el --- batch tests: inline blame — the current line's author, age and subject, from the hub -*- lexical-binding: t -*-
;; test-class: cond
;; The blame text itself (author, age, subject, the cut to the room, agents' lines, the empty last line) is the hub's:
;; `editor::marks::blame_text' and `Hub::blame_line' with their Rust tests.  Lisp asks once per line change at idle,
;; with the line's position and the columns it has room for, and draws what comes back.
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/git-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/scripted-process" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/extra/drgnx-blame" drgnx-dir) nil t)

(defun drgnx-blame-test--shown ()
  "The blame text shown in this buffer, or nil."
  (and drgnx-blame--overlay (overlay-buffer drgnx-blame--overlay)
       (let ((s (overlay-get drgnx-blame--overlay 'after-string))) (and s (substring-no-properties s)))))

(defvar drgnx-blame-test--asked nil "The questions `drgnx-history-ask' got: (METHOD BUFFER PARAMS), newest first.")
(defvar drgnx-blame-test--waiting nil "The callbacks of the questions not answered yet, oldest first.")
(defvar drgnx-blame-test--answer nil "What the canned hub answers, or `error'; nil: the history does not track the buffer.")

(defun drgnx-blame-test--canned ()
  "The hub's answer for the line asked about: line 1 is Ada's, line 2 Bob's (the line number is the one the position
starts: \"one\\ntwo\\n\")."
  (list :text "Ada, 3 days ago · Start" :sha "1111111111111111111111111111111111111111" :time 1700000000))

(defun drgnx-blame-test--deliver (&optional result)
  "The hub answers the oldest question (RESULT, else the canned answer)."
  (let ((cb (pop drgnx-blame-test--waiting)))
    (if (eq drgnx-blame-test--answer 'error) (funcall cb nil "no such path")
      (funcall cb (or result drgnx-blame-test--answer) nil))))

(defmacro drgnx-blame-test--with-history (&rest body)
  "BODY visiting a.txt of a repo (\"one\\ntwo\\n\"), the hub answering `git/blame/line' with the canned answer when
`drgnx-blame-test--deliver' says so; `drgnx-blame-test--asked' records the questions."
  (declare (indent 0))
  `(drgnx-git-test-with-repo
     (drgnx-git-test-write repo "a.txt" "one\ntwo\n")
     (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "Start")
     (let ((drgnx-blame-test--asked nil) (drgnx-blame-test--waiting nil)
           (drgnx-blame-test--answer (drgnx-blame-test--canned)))
       (cl-letf (((symbol-function 'drgnx-history-ask)
                  (lambda (buffer method callback &optional params)
                    (when drgnx-blame-test--answer
                      (push (list method buffer params) drgnx-blame-test--asked)
                      (setq drgnx-blame-test--waiting (append drgnx-blame-test--waiting (list callback)))
                      t))))
         (with-current-buffer (find-file-noselect (expand-file-name "a.txt" repo))
           (drgnx-blame-mode 1)
           ,@body)))))

(ert-deftest drgnx-blame/the-hub-is-asked-for-the-line-by-position-and-room ()
  (drgnx-blame-test--with-history
    (set-window-buffer (selected-window) (current-buffer))
    (goto-char (point-min)) (forward-line 1)
    (cl-letf (((symbol-function 'drgnx-blame--room) (lambda () 57)))
      (drgnx-blame--update))
    (should (= (length drgnx-blame-test--asked) 1))
    (let ((q (car drgnx-blame-test--asked)))
      (should (equal (car q) "git/blame/line"))
      (should (equal (nth 2 q) (list :pos 5 :width 57))))   ; the start of line 2, the columns left
    (should-not (drgnx-blame-test--shown))                  ; the answer is on its way
    (drgnx-blame-test--deliver (list :text "Bob, 1 day ago · Add two" :sha "2" :time 5))
    (should (equal (string-trim (drgnx-blame-test--shown)) "Bob, 1 day ago · Add two"))
    (should (eq (get-text-property (1- (length (overlay-get drgnx-blame--overlay 'after-string)))
                                   'face (overlay-get drgnx-blame--overlay 'after-string))
                'drgnx-blame))
    (should (= (overlay-start drgnx-blame--overlay) (line-end-position)))))

(ert-deftest drgnx-blame/no-line-is-counted-and-no-edit-is-followed ()
  (drgnx-blame-test--with-history
    (should-not (memq #'drgnx-blame--after-change after-change-functions))
    (should-not (memq #'drgnx-blame--before-change before-change-functions))
    (cl-letf (((symbol-function 'line-number-at-pos) (lambda (&rest _) (error "counted a line"))))
      (goto-char (point-min))
      (drgnx-blame--update)
      (drgnx-blame-test--deliver)
      (should (drgnx-blame-test--shown)))))

(ert-deftest drgnx-blame/typing-and-staying-on-a-line-asks-nothing-more ()
  (drgnx-blame-test--with-history
    (set-window-buffer (selected-window) (current-buffer))   ; the idle tick looks at the selected window's buffer
    (drgnx-blame--update) (drgnx-blame-test--deliver)
    (dotimes (_ 5) (insert "x"))
    (drgnx-blame--tick)
    (should (= (length drgnx-blame-test--asked) 1))
    (forward-line 1)                                        ; a new line: one more question
    (drgnx-blame--follow)
    (drgnx-blame--tick)
    (should (= (length drgnx-blame-test--asked) 2))))

(ert-deftest drgnx-blame/an-answer-for-a-line-point-left-is-not-drawn ()
  (drgnx-blame-test--with-history
    (goto-char (point-min))
    (drgnx-blame--update)
    (forward-line 1)
    (drgnx-blame-test--deliver)
    (should-not (drgnx-blame-test--shown))))

(ert-deftest drgnx-blame/one-question-at-a-time-and-a-forgotten-one-is-not-taken ()
  (drgnx-blame-test--with-history
    (drgnx-blame--update) (drgnx-blame--update)
    (should (= (length drgnx-blame-test--asked) 1))
    (drgnx-blame-mode -1)                                   ; the answer comes after the mode went
    (drgnx-blame-test--deliver)
    (should-not (drgnx-blame-test--shown))))

(ert-deftest drgnx-blame/room-is-what-the-window-has-left ()
  ;; batch: no pixel position, so the column count decides (frame 80 wide)
  (with-temp-buffer
    (set-window-buffer (selected-window) (current-buffer))
    (insert "short\n" (make-string 70 ?x) "\n" (make-string 79 ?y))
    (goto-char (point-min))
    (let ((w (window-body-width)))
      (should (= (drgnx-blame--room) (- w 5 drgnx-blame--gap 1)))
      (forward-line 1)
      (should (= (drgnx-blame--room) (- w 70 drgnx-blame--gap 1)))
      (forward-line 1)
      (should (<= (drgnx-blame--room) 0)))))

;; the window is resized: the hub is asked again for the line on show, with the new room (the fit is the hub's)
(ert-deftest drgnx-blame/resize-asks-again-with-the-new-room ()
  (drgnx-blame-test--with-history
    (set-window-buffer (selected-window) (current-buffer))
    (goto-char (point-min))
    (let ((room 60))
      (cl-letf (((symbol-function 'drgnx-blame--room) (lambda () room)))
        (drgnx-blame--update)
        (drgnx-blame-test--deliver)
        (setq room 30)
        (with-temp-buffer (drgnx-blame--resized (selected-window)))   ; hook: another buffer is current
        (should (= (length drgnx-blame-test--asked) 2))
        (should (equal (nth 2 (car drgnx-blame-test--asked)) (list :pos 1 :width 30)))
        (forward-line 1)                                     ; point left the line: not this line's blame to refit
        (drgnx-blame--resized (selected-window))
        (should (= (length drgnx-blame-test--asked) 2))))
    (should (memq #'drgnx-blame--resized window-size-change-functions))
    (drgnx-blame-mode -1)
    (should-not (memq #'drgnx-blame--resized window-size-change-functions))))

(ert-deftest drgnx-blame/no-text-shows-nothing-and-asks-no-more ()
  (drgnx-blame-test--with-history
    (goto-char (point-min))
    (drgnx-blame--update)
    (drgnx-blame-test--deliver (list :sha "1" :time 5))      ; no room, or no blame: the hub sends no text
    (should-not (drgnx-blame-test--shown))
    (should drgnx-blame--bol)                               ; answered, only not shown
    (drgnx-blame--tick)
    (should (= (length drgnx-blame-test--asked) 1))))

(ert-deftest drgnx-blame/inline-values-hold-the-line ()
  (drgnx-blame-test--with-history
    (goto-char (point-min))
    (overlay-put (make-overlay (line-beginning-position) (line-end-position)) 'drgnx-blame-yield t)
    (drgnx-blame--update) (drgnx-blame-test--deliver)
    (should-not (drgnx-blame-test--shown))))

(ert-deftest drgnx-blame/leaving-the-line-hides-the-blame ()
  (drgnx-blame-test--with-history
    (goto-char (point-min))
    (drgnx-blame--update) (drgnx-blame-test--deliver)
    (should (drgnx-blame-test--shown))
    (forward-line 1)
    (drgnx-blame--follow)
    (should-not (drgnx-blame-test--shown))))

(ert-deftest drgnx-blame/a-file-the-hub-refuses-is-not-asked-again ()
  (drgnx-blame-test--with-history
    (setq drgnx-blame-test--answer 'error)
    (drgnx-blame--update) (drgnx-blame-test--deliver)
    (should drgnx-blame--off)
    (drgnx-blame--update)
    (should (= (length drgnx-blame-test--asked) 1))
    (should-not (drgnx-blame-test--shown))
    (drgnx-blame-mode -1) (drgnx-blame-mode 1)               ; turned on again: asked again
    (should-not drgnx-blame--off)))

(ert-deftest drgnx-blame/a-buffer-the-history-does-not-track-is-quiet-and-tried-again ()
  (drgnx-blame-test--with-history
    (setq drgnx-blame-test--answer nil)                      ; no registration yet, or no hub
    (drgnx-blame--update) (drgnx-blame--update)
    (should-not drgnx-blame--off)
    (should-not drgnx-blame--request)
    (should-not (drgnx-blame-test--shown))
    (setq drgnx-blame-test--answer (drgnx-blame-test--canned))
    (drgnx-blame--update)
    (should drgnx-blame--request)))

(ert-deftest drgnx-blame/odd-buffers-stay-quiet ()
  (drgnx-git-test-with-repo
    (drgnx-git-test-write repo "a.txt" "one\n")
    (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "Start")
    (drgnx-git-test-write repo "new.txt" "x\n")
    (with-current-buffer (find-file-noselect (expand-file-name "new.txt" repo))
      (drgnx-blame--maybe)
      (should-not drgnx-blame-mode))                         ; not a tracked file: not turned on
    (with-current-buffer (find-file-noselect (expand-file-name "a.txt" repo))
      (drgnx-blame--maybe)
      (should drgnx-blame-mode)))                            ; a tracked file: on
  ;; outside git, and a remote file: never on
  (let ((dir (make-temp-file "drgnx-blame" t)))
    (unwind-protect
        (with-current-buffer (find-file-noselect (expand-file-name "f.txt" dir))
          (drgnx-blame--maybe)
          (should-not drgnx-blame-mode)
          (kill-buffer))
      (delete-directory dir t)))
  (with-temp-buffer
    (setq buffer-file-name "/ssh:host:/x.txt")
    (cl-letf (((symbol-function 'file-remote-p) (lambda (&rest _) "/ssh:host:"))
              ((symbol-function 'vc-backend) (lambda (&rest _) (error "Never asked for a remote file"))))
      (drgnx-blame--maybe)
      (should-not drgnx-blame-mode))
    (setq buffer-file-name nil)))

(ert-deftest drgnx-blame/show-commit-of-line ()
  (drgnx-blame-test--with-history
    (let ((shown nil))
      (cl-letf (((symbol-function 'drgnx-diff-show) (lambda (source &rest _) (setq shown source))))
        (goto-char (point-min)) (forward-line 1)
        (should-error (drgnx-blame-show-commit) :type 'user-error)      ; no answer yet
        (drgnx-blame--update)
        (drgnx-blame-test--deliver (list :text "Bob, 1 day ago · Add two" :sha "2222222222222222222222222222222222222222" :time 5))
        (drgnx-blame-show-commit)
        (should (equal shown (list 'commit "2222222222222222222222222222222222222222")))
        ;; not committed: the hub names no time
        (setq drgnx-blame--bol nil)
        (drgnx-blame--update)
        (drgnx-blame-test--deliver (list :text "You · Uncommitted changes" :sha (make-string 40 ?0)))
        (should-error (drgnx-blame-show-commit) :type 'user-error)))))

(ert-deftest drgnx-blame/timer-cancelled ()
  ;; M11b-12: the one idle timer lives while some buffer has inline blame, not for the rest of the session
  (dolist (b (buffer-list)) (with-current-buffer b (when (bound-and-true-p drgnx-blame-mode) (drgnx-blame-mode -1))))
  (should-not (drgnx-timer-active-p 'blame-tick))
  (drgnx-blame-test--with-history
    (let ((first (current-buffer)) (second (progn (drgnx-git-test-write repo "b.txt" "b\n") (find-file-noselect (expand-file-name "b.txt" repo)))))
      (with-current-buffer second (drgnx-blame-mode 1))
      (should (drgnx-timer-active-p 'blame-tick))
      (drgnx-blame-mode -1)                                  ; one buffer still has it
      (should (drgnx-timer-active-p 'blame-tick))
      (with-current-buffer second (drgnx-blame-mode -1))     ; the last one
      (should-not (drgnx-timer-active-p 'blame-tick))
      ;; on again, then the last buffer killed
      (drgnx-blame-mode 1)
      (should (drgnx-timer-active-p 'blame-tick))
      (kill-buffer first)
      (should-not (drgnx-timer-active-p 'blame-tick))
      (kill-buffer second))))

(ert-deftest drgnx-blame/quiet-in-a-large-file-buffer ()
  ;; the flag editor/large-files sets (by hand here): blame stays off, and git is not even asked about the file
  (require 'drgnx-large-file)
  (with-temp-buffer
    (setq buffer-file-name (expand-file-name "big.txt" temporary-file-directory))
    (setq-local drgnx-large-file 'lean)
    (cl-letf (((symbol-function 'vc-backend) (lambda (&rest _) (error "Never asked for a large file"))))
      (drgnx-blame--maybe)
      (should-not drgnx-blame-mode))
    (setq buffer-file-name nil)))

;;; mod-blame-test.el ends here
