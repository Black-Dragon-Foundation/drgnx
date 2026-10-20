;;; mod-blame-test.el --- batch tests: inline blame — the current line's author, age and subject -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/git-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/scripted-process" drgnx-dir) nil t)
(load (expand-file-name "modules/extra/drgnx-blame" drgnx-dir) nil t)

(defconst drgnx-blame-test--committed
  "abcdef0123456789abcdef0123456789abcdef01 2 2 1
author Bob
author-mail <bob@t.invalid>
author-time 1700000000
author-tz +0000
committer Bob
committer-mail <bob@t.invalid>
committer-time 1700000000
committer-tz +0000
summary Add two
filename a.txt
\ttwo
")

(defconst drgnx-blame-test--uncommitted
  "0000000000000000000000000000000000000000 1 1 1
author Not Committed Yet
author-mail <not.committed.yet>
author-time 1700000100
author-tz +0000
summary Version of a.txt from a.txt
filename a.txt
\tnew
")

(defun drgnx-blame-test--shown ()
  "The blame text shown in this buffer, or nil."
  (and drgnx-blame--overlay (overlay-buffer drgnx-blame--overlay)
       (let ((s (overlay-get drgnx-blame--overlay 'after-string))) (and s (substring-no-properties s)))))

(defun drgnx-blame-test--wait-for (pred)
  (let ((deadline (+ (float-time) 5))) (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.05)))
  (funcall pred))

(defun drgnx-blame-test--live ()
  (seq-count (lambda (p) (and (process-live-p p) (eq (process-type p) 'real) (string-prefix-p "drgnx-blame" (process-name p)))) (process-list)))

(defmacro drgnx-blame-test--with-history (&rest body)
  "BODY visiting a.txt of a repo: line 1 by Ada (\"Start\"), line 2 by Bob (\"Add two\")."
  (declare (indent 0))
  `(drgnx-git-test-with-repo
     (drgnx-git-test-write repo "a.txt" "one\n")
     (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "Start")
     (drgnx-git-test-write repo "a.txt" "one\ntwo\n")
     (drgnx-git-test repo "commit" "-q" "-a" "-m" "Add two" "--author=Bob <bob@t.invalid>")
     (with-current-buffer (find-file-noselect (expand-file-name "a.txt" repo))
       (drgnx-blame-mode 1)
       ,@body)))

(ert-deftest drgnx-blame/parse-porcelain ()
  (should (equal (drgnx-blame--parse drgnx-blame-test--committed)
                 '(:sha "abcdef0123456789abcdef0123456789abcdef01" :author "Bob" :time 1700000000 :summary "Add two")))
  (let ((u (drgnx-blame--parse drgnx-blame-test--uncommitted)))
    (should (equal (plist-get u :author) "You"))
    (should (equal (plist-get u :summary) "Uncommitted changes")))
  (should-not (drgnx-blame--parse "")))

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
        (should (= (string-width (drgnx-blame-test--shown)) (+ 3 60)))
        (setq room 30)
        (with-temp-buffer (drgnx-blame--resized (selected-window)))   ; hook: another buffer is current
        (should (= (string-width (drgnx-blame-test--shown)) (+ 3 30)))
        (setq room 10)
        (drgnx-blame--resized (selected-window))
        (should-not (drgnx-blame-test--shown))
        (setq room 50)
        (drgnx-blame--resized (selected-window))
        (should (= (string-width (drgnx-blame-test--shown)) (+ 3 50)))
        (forward-line 1)                                      ; point left the line: not this line's blame to refit
        (setq room 25)
        (drgnx-blame--resized (selected-window))
        (should (= (string-width (drgnx-blame-test--shown)) (+ 3 50)))))
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
    (should (drgnx-blame-test--wait-for (lambda () (string-search "Bob" (or (drgnx-blame-test--shown) "")))))
    (should (string-search "Add two" (drgnx-blame-test--shown)))
    (should (= (overlay-start drgnx-blame--overlay) (line-end-position)))
    (forward-line -1)                                       ; leaving the line hides it
    (drgnx-blame--follow)
    (should-not (drgnx-blame-test--shown))))

(ert-deftest drgnx-blame/unsaved-lines-are-uncommitted ()
  (drgnx-blame-test--with-history
    (goto-char (point-min)) (insert "new\n")
    (goto-char (point-min))
    (drgnx-blame--update)
    (should (drgnx-blame-test--wait-for (lambda () (equal (string-trim (or (drgnx-blame-test--shown) "")) "You · Uncommitted changes"))))
    (forward-line 2)                                        ; "two", now line 3
    (drgnx-blame--update)
    (should (drgnx-blame-test--wait-for (lambda () (string-search "Bob" (or (drgnx-blame-test--shown) "")))))))

(ert-deftest drgnx-blame/one-git-at-a-time ()
  (drgnx-blame-test--with-history
    (insert (mapconcat (lambda (i) (format "l%d\n" i)) (number-sequence 1 5) ""))
    (goto-char (point-min))
    (dotimes (_ 5) (drgnx-blame--update) (forward-line 1))
    (should (<= (drgnx-blame-test--live) 1))
    (drgnx-blame-test--wait-for (lambda () (= 0 (drgnx-blame-test--live))))))

(ert-deftest drgnx-blame/odd-buffers-stay-quiet ()
  (drgnx-git-test-with-repo
    (drgnx-git-test-write repo "a.txt" "one\n")
    (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "Start")
    ;; untracked: one try, then never again in that buffer
    (drgnx-git-test-write repo "new.txt" "x\n")
    (with-current-buffer (find-file-noselect (expand-file-name "new.txt" repo))
      (drgnx-blame--maybe)
      (should-not drgnx-blame-mode)                           ; not a tracked file: not turned on
      (drgnx-blame-mode 1)                                    ; on by hand: git refuses once
      (drgnx-blame--update)
      (should (drgnx-blame-test--wait-for (lambda () drgnx-blame--off)))
      (drgnx-blame--update)
      (should (= 0 (drgnx-blame-test--live)))
      (should-not (drgnx-blame-test--shown)))
    ;; a tracked file: on
    (with-current-buffer (find-file-noselect (expand-file-name "a.txt" repo))
      (drgnx-blame--maybe)
      (should drgnx-blame-mode)))
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

(ert-deftest drgnx-blame/a-git-that-ends-before-its-input-is-no-error ()
  ;; git refuses an untracked file at once: it may have ended before the request sends its EOF (A-44)
  (drgnx-git-test-with-repo
    (drgnx-git-test-write repo "a.txt" "one\n")
    (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "Start")
    (drgnx-git-test-write repo "new.txt" "x\n")
    (with-current-buffer (find-file-noselect (expand-file-name "new.txt" repo))
      (unwind-protect
          (progn
            (drgnx-blame-mode 1)
            (drgnx-test-with-exit-before-read (drgnx-blame--update))
            (should (drgnx-blame-test--wait-for (lambda () (null drgnx-blame--proc))))
            (should (= 0 (drgnx-blame-test--live))))
        (drgnx-blame-mode -1)
        (kill-buffer)))))

(ert-deftest drgnx-blame/show-commit-of-line ()
  (drgnx-blame-test--with-history
    (let ((shown nil) (sha (drgnx-git-test repo "rev-parse" "HEAD")))
      (cl-letf (((symbol-function 'drgnx-diff-show) (lambda (source &rest _) (setq shown source))))
        (goto-char (point-min)) (forward-line 1)
        (drgnx-blame-show-commit)
        (should (equal shown (list 'commit sha)))
        (goto-char (point-min)) (insert "new\n") (goto-char (point-min))
        (should-error (drgnx-blame-show-commit) :type 'user-error)))))

;; review fixes (M11b final review)
(ert-deftest drgnx-blame/never-switches-itself-off ()
  ;; C2: the empty line after the last newline, a request replaced, the mode turned off mid-request: blame goes on
  (drgnx-blame-test--with-history
    (goto-char (point-max))
    (drgnx-blame--update)
    (drgnx-blame-test--wait-for (lambda () (= 0 (drgnx-blame-test--live))))
    (should-not drgnx-blame--off)
    (goto-char (point-min))
    (drgnx-blame--update) (forward-line 1) (drgnx-blame--update)   ; the first is replaced
    (should (drgnx-blame-test--wait-for (lambda () (string-search "Bob" (or (drgnx-blame-test--shown) "")))))
    (should-not drgnx-blame--off)
    (goto-char (point-min)) (drgnx-blame--forget)
    (drgnx-blame--update) (drgnx-blame-mode -1) (drgnx-blame-mode 1)
    (drgnx-blame--update)
    (should (drgnx-blame-test--wait-for (lambda () (string-search "Ada" (or (drgnx-blame-test--shown) "")))))))

(ert-deftest drgnx-blame/crlf-files-line-up ()
  ;; I1: a committed CRLF file, unmodified and modified
  (drgnx-git-test-with-repo
    (let ((coding-system-for-write 'binary)) (drgnx-git-test-write repo "w.txt" "one\r\ntwo\r\n"))
    (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "Windows lines")
    (with-current-buffer (find-file-noselect (expand-file-name "w.txt" repo))
      (should (eq (coding-system-eol-type buffer-file-coding-system) 1))
      (drgnx-blame-mode 1)
      (goto-char (point-min)) (forward-line 1)
      (drgnx-blame--update)
      (should (drgnx-blame-test--wait-for (lambda () (string-search "Windows lines" (or (drgnx-blame-test--shown) "")))))
      (goto-char (point-min)) (insert "new\n") (forward-line 1)
      (drgnx-blame--update)
      (should (drgnx-blame-test--wait-for (lambda () (string-search "Windows lines" (or (drgnx-blame-test--shown) ""))))))))

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

;;; mod-blame-test.el ends here
