;;; mod-blame-test.el --- batch tests: inline blame — the current line's author, age and subject -*- lexical-binding: t -*-
;; test-class: cond
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

(defun drgnx-blame-test--wait-for (pred)
  (drgnx-test-wait pred :what "the blame's condition"))

(defvar drgnx-blame-test--asked nil "The questions `drgnx-history-ask' got: (METHOD . BUFFER), newest first.")
(defvar drgnx-blame-test--waiting nil "The callbacks of the questions not answered yet, oldest first.")
(defvar drgnx-blame-test--answer nil "What the canned hub answers, or `error'; nil: the history does not track the buffer.")

(defun drgnx-blame-test--canned ()
  "The hub's answer for a.txt of the fixture: line 1 by Ada (\"Start\"), line 2 by Bob (\"Add two\")."
  (list :head "h"
        :commits (list (list :sha "1111111111111111111111111111111111111111" :author "Ada" :time 1700000000 :summary "Start")
                       (list :sha "2222222222222222222222222222222222222222" :author "Bob" :time 1700000100 :summary "Add two"))
        :lines (list 0 1) :agents nil))

(defun drgnx-blame-test--deliver ()
  "The hub answers the oldest question."
  (let ((cb (pop drgnx-blame-test--waiting)))
    (if (eq drgnx-blame-test--answer 'error) (funcall cb nil "no such path") (funcall cb drgnx-blame-test--answer nil))))

(defmacro drgnx-blame-test--with-history (&rest body)
  "BODY visiting a.txt of a repo (\"one\\ntwo\\n\"), the hub answering `git/blame' with the canned answer when
`drgnx-blame-test--deliver' says so; `drgnx-blame-test--asked' counts the questions."
  (declare (indent 0))
  `(drgnx-git-test-with-repo
     (drgnx-git-test-write repo "a.txt" "one\ntwo\n")
     (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "Start")
     (let ((drgnx-blame-test--asked nil) (drgnx-blame-test--waiting nil)
           (drgnx-blame-test--answer (drgnx-blame-test--canned)))
       (cl-letf (((symbol-function 'drgnx-history-ask)
                  (lambda (buffer method callback)
                    (when drgnx-blame-test--answer
                      (push (cons method buffer) drgnx-blame-test--asked)
                      (setq drgnx-blame-test--waiting (append drgnx-blame-test--waiting (list callback)))
                      t))))
         (with-current-buffer (find-file-noselect (expand-file-name "a.txt" repo))
           (drgnx-blame-mode 1)
           ,@body)))))

(ert-deftest drgnx-blame/info-follows-the-edits-made-since-the-answer ()
  (with-temp-buffer
    (setq drgnx-blame--data (list :commits (vector '(:sha "a" :author "Ada" :time 1 :summary "A")
                                                   '(:sha "b" :author "Bob" :time 2 :summary "B"))
                                  :lines (vector 0 0 1 1 0) :agents nil))
    (let ((who (lambda (line) (plist-get (drgnx-blame--info-at line) :author))))
      (should (equal (mapcar who '(1 2 3 4 5)) '("Ada" "Ada" "Bob" "Bob" "Ada")))
      ;; a line inserted above line 3: every line from there moves down, the new one is the user's
      (push '(3 0 . 1) drgnx-blame--edits)
      (should (equal (mapcar who '(1 2 3 4 5 6)) '("Ada" "Ada" "You" "You" "Bob" "Ada")))
      ;; a character typed on the old line 1 (no newline): that line is changed, the rest holds
      (push '(1 0 . 0) drgnx-blame--edits)
      (should (equal (funcall who 1) "You"))
      (should (equal (funcall who 2) "Ada"))
      ;; line 2 and the line after it deleted (two newlines): what was below comes up
      (setq drgnx-blame--edits (list '(2 2 . 0)))
      (should (equal (mapcar who '(1 2 3)) '("Ada" "You" "Ada"))))))

(ert-deftest drgnx-blame/ago-steps ()
  (let ((now 2000000000))
    (should (equal (drgnx-blame--ago (- now 30) now) "just now"))
    (should (equal (drgnx-blame--ago (- now 90) now) "1 minute ago"))
    (should (equal (drgnx-blame--ago (- now (* 3 3600)) now) "3 hours ago"))
    (should (equal (drgnx-blame--ago (- now 86400) now) "1 day ago"))
    (should (equal (drgnx-blame--ago (- now (* 45 86400)) now) "1 month ago"))
    (should (equal (drgnx-blame--ago (- now (* 800 86400)) now) "2 years ago"))))

(ert-deftest drgnx-blame/text-is-one-short-line ()
  (let ((s (drgnx-blame--text (list :author "Bob" :time 1700000000 :summary (make-string 200 ?x)) (+ 1700000000 86400) 200)))
    (should (string-prefix-p "Bob, 1 day ago · xxx" s))
    (should (<= (string-width s) 80))
    (should (eq (get-text-property 0 'face s) 'drgnx-blame)))
  (should (equal (substring-no-properties (drgnx-blame--text '(:author "You" :summary "Uncommitted changes") 0 80))
                 "You · Uncommitted changes")))

;; UI audit #2: `now' is `float-time', so the division gave 1.2 days and "1 days ago"
(ert-deftest drgnx-blame/ago-whole-counts-for-a-float-now ()
  (let ((now 2000000000.4321))
    (should (equal (drgnx-blame--ago (- 2000000000 (+ 86400 7200)) now) "1 day ago"))
    (should (equal (drgnx-blame--ago (- 2000000000 (* 1.2 3600)) now) "1 hour ago"))
    (should (equal (drgnx-blame--ago (- 2000000000 (* 1.5 60)) now) "1 minute ago"))
    (should (equal (drgnx-blame--ago (- 2000000000 (* 1.5 86400)) now) "1 day ago"))
    (should (equal (drgnx-blame--ago (- 2000000000 (* 2.9 86400)) now) "2 days ago"))
    (should (equal (drgnx-blame--ago (- 2000000000 (* 45 86400)) now) "1 month ago"))
    (should (equal (drgnx-blame--ago (- 2000000000 (* 400 86400)) now) "1 year ago"))
    (dolist (secs '(61 3601 90000 4000000 40000000 70000000))
      (should-not (string-match-p "[.]\\|\\b1 [a-z]+s ago" (drgnx-blame--ago (- 2000000000 secs) now))))))

;; UI audit #1: the text fits the columns left after the end of the line; it never wraps
(ert-deftest drgnx-blame/text-fits-the-room-it-is-given ()
  (let* ((info (list :author "Bob" :time 1700000000 :summary "Fix the parser so that it never wraps mid-word"))
         (now (+ 1700000000 86400))
         (full (drgnx-blame--text info now 80))
         (cut (drgnx-blame--text info now 30)))
    (should (equal (substring-no-properties full) "Bob, 1 day ago · Fix the parser so that it never wraps mid-word"))
    (should (= (string-width cut) 30))
    (should (string-suffix-p "…" cut))
    (should (string-prefix-p "Bob, 1 day ago · Fix" cut))
    (should (eq (get-text-property 0 'face cut) 'drgnx-blame))
    (should (= (string-width (drgnx-blame--text info now 20)) 20))
    (should-not (drgnx-blame--text info now 19))            ; too little room: nothing, not a stump
    (should-not (drgnx-blame--text info now 0))
    (should-not (drgnx-blame--text info now -5))
    (should (<= (string-width (drgnx-blame--text (list :author "B" :time 1 :summary (make-string 300 ?x)) 2 500)) 80))))

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

;; the window is resized: the blame on show is fitted again, from what git said (no new request)
(ert-deftest drgnx-blame/resize-refits-what-is-shown ()
  (drgnx-blame-test--with-history
    (set-window-buffer (selected-window) (current-buffer))
    (goto-char (point-min))
    (let ((room 60))
      (cl-letf (((symbol-function 'drgnx-blame--room) (lambda () room)))
        (drgnx-blame--show (list :author "Ada" :time 1700000000 :summary (make-string 100 ?x)))
        (should (= (string-width (drgnx-blame-test--shown)) (+ 1 60)))
        (setq room 30)
        (with-temp-buffer (drgnx-blame--resized (selected-window)))   ; hook: another buffer is current
        (should (= (string-width (drgnx-blame-test--shown)) (+ 1 30)))
        (setq room 10)
        (drgnx-blame--resized (selected-window))
        (should-not (drgnx-blame-test--shown))
        (setq room 50)
        (drgnx-blame--resized (selected-window))
        (should (= (string-width (drgnx-blame-test--shown)) (+ 1 50)))      ; the gap is one character drawn 24 px wide
        (forward-line 1)                                     ; point left the line: not this line's blame to refit
        (setq room 25)
        (drgnx-blame--resized (selected-window))
        (should (= (string-width (drgnx-blame-test--shown)) (+ 1 50)))))
    (should (memq #'drgnx-blame--resized window-size-change-functions))
    (drgnx-blame-mode -1)
    (should-not (memq #'drgnx-blame--resized window-size-change-functions))))

(ert-deftest drgnx-blame/narrow-window-shows-nothing-and-never-wraps ()
  (drgnx-blame-test--with-history
    (set-window-buffer (selected-window) (current-buffer))
    (goto-char (point-min)) (insert (make-string 65 ?x)) (save-buffer) (goto-char (point-min))
    (let ((info (list :author "Ada" :time nil :summary "Uncommitted changes")))
      (drgnx-blame--show info)                              ; 80 - 65 - gap: under 20 columns left
      (should-not (drgnx-blame-test--shown))
      (should drgnx-blame--bol)                             ; answered, only not shown: no git again
      (goto-char (point-max)) (forward-line -1) (goto-char (line-end-position))
      (drgnx-blame--show info)
      (should (drgnx-blame-test--shown))
      (should (<= (+ (current-column) (string-width (overlay-get drgnx-blame--overlay 'after-string))) (window-body-width))))))

(ert-deftest drgnx-blame/the-current-line-shows-its-commit ()
  (drgnx-blame-test--with-history
    (goto-char (point-min)) (forward-line 1)
    (drgnx-blame--update)
    (should (= (length drgnx-blame-test--asked) 1))
    (should (equal (car (car drgnx-blame-test--asked)) "git/blame"))
    (should-not (drgnx-blame-test--shown))                  ; the answer is on its way
    (drgnx-blame-test--deliver)
    (drgnx-blame--update)
    (should (string-search "Bob" (or (drgnx-blame-test--shown) "")))
    (should (string-search "Add two" (drgnx-blame-test--shown)))
    (should (= (overlay-start drgnx-blame--overlay) (line-end-position)))
    (forward-line -1)                                       ; leaving the line hides it
    (drgnx-blame--follow)
    (should-not (drgnx-blame-test--shown))
    (drgnx-blame--update)
    (should (string-search "Ada" (drgnx-blame-test--shown)))
    (should (= (length drgnx-blame-test--asked) 1))))       ; one question for the whole file

(ert-deftest drgnx-blame/typing-asks-for-nothing-and-lines-follow-it ()
  (drgnx-blame-test--with-history
    (drgnx-blame--update)
    (drgnx-blame-test--deliver)
    (goto-char (point-min)) (insert "new\n")                ; a line above: the old ones move down
    (goto-char (point-min))
    (drgnx-blame--update)
    (should (equal (string-trim (drgnx-blame-test--shown)) "You · Uncommitted changes"))
    (forward-line 2)                                        ; "two", now line 3
    (drgnx-blame--update)
    (should (string-search "Bob" (drgnx-blame-test--shown)))
    (insert "!")                                            ; a character on it: the line is the user's now
    (drgnx-blame--hide)
    (drgnx-blame--update)
    (should (equal (string-trim (drgnx-blame-test--shown)) "You · Uncommitted changes"))
    (should (= (length drgnx-blame-test--asked) 1))))

(ert-deftest drgnx-blame/a-save-or-a-revert-asks-again ()
  (drgnx-blame-test--with-history
    (drgnx-blame--update) (drgnx-blame-test--deliver)
    (should (memq #'drgnx-blame--forget after-save-hook))
    (should (memq #'drgnx-blame--forget after-revert-hook))
    (run-hooks 'after-save-hook)
    (should-not drgnx-blame--data)
    (drgnx-blame--update)
    (should (= (length drgnx-blame-test--asked) 2))))

(ert-deftest drgnx-blame/one-question-at-a-time-and-a-forgotten-one-is-not-taken ()
  (drgnx-blame-test--with-history
    (drgnx-blame--update) (drgnx-blame--update)
    (should (= (length drgnx-blame-test--asked) 1))
    (drgnx-blame-mode -1)                                   ; the answer comes after the mode went
    (drgnx-blame-test--deliver)
    (should-not drgnx-blame--data)))

(ert-deftest drgnx-blame/lines-an-agent-wrote-say-so ()
  (drgnx-blame-test--with-history
    (setq drgnx-blame-test--answer (plist-put (drgnx-blame-test--canned) :agents (list (list :from 2 :to 2 :session "s1" :step "7"))))
    (goto-char (point-min)) (forward-line 1)
    (drgnx-blame--update) (drgnx-blame-test--deliver) (drgnx-blame--update)
    (should (string-prefix-p "agent s1" (string-trim (drgnx-blame-test--shown))))
    (goto-char (point-min)) (drgnx-blame--hide) (drgnx-blame--update)
    (should (string-search "Ada" (drgnx-blame-test--shown)))))

(ert-deftest drgnx-blame/too-many-edits-ask-again ()
  (drgnx-blame-test--with-history
    (drgnx-blame--update) (drgnx-blame-test--deliver)
    (let ((drgnx-blame-max-edits 3))
      (dotimes (_ 4) (goto-char (point-max)) (insert "x"))
      (should-not drgnx-blame--data))))

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
        (drgnx-blame--update) (drgnx-blame-test--deliver)
        (drgnx-blame-show-commit)
        (should (equal shown (list 'commit "2222222222222222222222222222222222222222")))
        (goto-char (point-min)) (insert "new\n") (goto-char (point-min))
        (should-error (drgnx-blame-show-commit) :type 'user-error)))))   ; not committed yet

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
