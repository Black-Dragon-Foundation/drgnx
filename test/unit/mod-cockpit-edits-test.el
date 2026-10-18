;;; mod-cockpit-edits-test.el --- batch tests: each agent's edits as a live diff (accept, revert by request, comment on a line) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'filenotify)
(require 'drgnx)
(require 'drgnx-agents)
(load (expand-file-name "test/fixtures/cockpit-fixture" drgnx-dir) nil t)   ; a project, a job, worktrees, events
(load (expand-file-name "modules/tools/drgnx-cockpit" drgnx-dir) nil t)

(defconst drgnx-cockpit-edits-test--ext "ext:claude-code:42"
  "The fixture's outside agent: README changed and new.txt added in its own worktree WT-A, both reported.")

(defun drgnx-cockpit-edits-test--settled-p (buffer)
  "Whether BUFFER's pane has listed and diffed everything, with nothing on its way."
  (with-current-buffer buffer
    (and drgnx-cockpit-edits--loaded (not drgnx-cockpit-edits--busy) (not (timerp drgnx-cockpit-edits--timer))
         (zerop (hash-table-count drgnx-cockpit-edits--dirty)) (not drgnx-cockpit-edits--list-dirty))))

(defun drgnx-cockpit-edits-test--settle (buffer)
  (should (drgnx-cockpit-fixture-wait (lambda () (drgnx-cockpit-edits-test--settled-p buffer)))))

(defmacro drgnx-cockpit-edits-test--with (agent &rest body)
  "BODY in the cockpit fixture with AGENT's edits pane E shown in the selected window and loaded; the hub's sessions
the fixture's (SESSIONS).  File watches are recorded in WATCHES (descriptor → (DIR CALLBACK)), never real ones: in
batch Emacs a real watch's events wait in an input queue nobody reads, and while one waits no process sentinel runs.
The pane is killed after, and must leave no timer or watch behind."
  (declare (indent 1))
  `(drgnx-cockpit-fixture-with
     (let ((drgnx-cockpit-edits--draws 0) (drgnx-cockpit-edits-check-interval 3600) (drgnx-cockpit-edits--list-every 0)
           (drgnx-cockpit-edits--last nil) (config (current-window-configuration))
           (watches (make-hash-table)) (watch-n 0))
       (cl-letf (((symbol-function 'drgnx-cockpit-sessions) (lambda () sessions))
                 ((symbol-function 'file-notify-add-watch) (lambda (dir _flags cb) (puthash (cl-incf watch-n) (list dir cb) watches) watch-n))
                 ((symbol-function 'file-notify-rm-watch) (lambda (d) (remhash d watches)))
                 ((symbol-function 'file-notify-valid-p) (lambda (d) (and (gethash d watches) t))))
         (let ((e (drgnx-cockpit-edits-buffer ,agent)))
           (unwind-protect
               (save-window-excursion
                 (delete-other-windows)
                 (set-window-buffer (selected-window) e)
                 (set-buffer e)
                 (drgnx-cockpit-edits-test--settle e)
                 ,@body)
             (let ((timers (with-current-buffer e (list drgnx-cockpit-edits--timer drgnx-cockpit-edits--check-timer))))
               (kill-buffer e)
               (dolist (tm timers) (should-not (and (timerp tm) (memq tm timer-list))))   ; the buffer owned them
               (should (zerop (hash-table-count watches))))
             (set-window-configuration config)))))))

(defun drgnx-cockpit-edits-test--watch (watches dir)
  "The callback of the watch on DIR in WATCHES."
  (let ((cb nil))
    (maphash (lambda (_ w) (when (equal (car w) dir) (setq cb (cadr w)))) watches)
    (should cb)
    cb))

(defun drgnx-cockpit-edits-test--goto (file &optional text)
  "Point on FILE's header line, or on the first line of its section that starts with TEXT."
  (goto-char (point-min))
  (let ((m (text-property-search-forward 'drgnx-cockpit-edits-file file #'equal)))
    (should m)
    (goto-char (prop-match-beginning m))
    (when text
      (should (re-search-forward (concat "^" (regexp-quote text)) (prop-match-end m) t))
      (goto-char (line-beginning-position)))))

(defun drgnx-cockpit-edits-test--header (file)
  "FILE's header line, as text."
  (save-excursion (drgnx-cockpit-edits-test--goto file) (buffer-substring-no-properties (point) (line-end-position))))

(defun drgnx-cockpit-edits-test--notify (dir file &optional action)
  "What a file watch says when FILE (relative to DIR) is written: delivered to the selected pane at once."
  (drgnx-cockpit-edits--notified (current-buffer) (list nil (or action 'changed) (expand-file-name file dir))))

(ert-deftest drgnx-cockpit-edits/lists-changed-files-with-counts ()
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (should (derived-mode-p 'diff-mode))
    (should (eq buffer-undo-list t))                                  ; a generated buffer: no undo
    (should (equal drgnx-cockpit-edits--files '("README" "new.txt")))
    ;; FILE +A −B per file, its diff below
    (should (string-match-p "\\`README \\+1 [−-]0\\'" (drgnx-cockpit-edits-test--header "README")))
    (should (string-match-p "\\`new\\.txt \\+1 [−-]0  new\\'" (drgnx-cockpit-edits-test--header "new.txt")))
    (drgnx-cockpit-edits-test--goto "README" "+more")
    (drgnx-cockpit-edits-test--goto "new.txt" "+new")
    (should (string-match-p "2 files changed" (car header-line-format)))
    ;; the header's parts keep their faces under diff-mode's
    (drgnx-cockpit-edits-test--goto "README")
    (should (eq (get-text-property (point) 'drgnx-cockpit-edits-face) 'drgnx-cockpit-edits-file))
    (font-lock-ensure)
    (should (eq (get-text-property (point) 'face) 'drgnx-cockpit-edits-file))
    (should (eq (get-text-property (+ (point) 7) 'face) 'drgnx-cockpit-edits-added))
    ;; n and p move by file
    (goto-char (point-min))
    (drgnx-cockpit-edits-next-file)
    (should (equal (drgnx-cockpit-edits-test--header "new.txt") (buffer-substring-no-properties (point) (line-end-position))))
    (drgnx-cockpit-edits-previous-file)
    (should (= (point) (point-min)))
    ;; a file the agent reports from another process (its MCP server): listed at the next look at the store
    (drgnx-cockpit-fixture-write (concat wt-a "docs/later.md") "later\n")
    (drgnx-coord-event-add :agent drgnx-cockpit-edits-test--ext :kind "edit" :summary "1 file"
                           :data (list :root (directory-file-name wt-a) :paths '("docs/later.md")))
    (drgnx-cockpit-edits--look)
    (drgnx-cockpit-edits-test--settle e)
    (should (equal drgnx-cockpit-edits--files '("README" "new.txt" "docs/later.md")))
    (drgnx-cockpit-edits-test--goto "docs/later.md" "+later")
    ;; it is watched: its folder too (and a write in .git, or outside the folder, is nothing)
    (should (gethash (concat wt-a "docs/") drgnx-cockpit-edits--watches))
    (drgnx-cockpit-edits-test--watch watches (concat wt-a "docs/"))
    (drgnx-cockpit-edits-test--notify wt-a ".git/index")
    (drgnx-cockpit-edits-test--notify repo "README")
    (should-not (timerp drgnx-cockpit-edits--timer))
    ;; nothing here is ever remote: a remote agent folder is an error line, no git, no watch
    (let ((src (list :dir "/ssh:host:/w/" :base "main")))
      (cl-letf (((symbol-function 'drgnx-cockpit-edit-source) (lambda (&rest _) src))
                ((symbol-function 'make-process) (lambda (&rest _) (error "A process ran")))
                ((symbol-function 'file-notify-add-watch) (lambda (&rest _) (error "A remote folder was watched"))))
        (drgnx-cockpit-edits--refresh)
        (drgnx-cockpit-edits-test--settle e)
        (should (string-match-p "remote" (buffer-string)))
        (should (null drgnx-cockpit-edits--files))))))

(ert-deftest drgnx-cockpit-edits/a-burst-of-writes-is-one-redraw ()
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (let ((drgnx-cockpit-edits-delay 0.3) (drgnx-cockpit-edits--list-every 1.5)
          (windows (window-list)))
      ;; point in README's "+more" line, two characters in; the window starting at README's header
      (drgnx-cockpit-edits-test--goto "README" "+more")
      (forward-char 2)
      (let* ((start (save-excursion (drgnx-cockpit-edits-test--goto "README") (point)))
             (line (count-lines start (line-beginning-position)))
             (draws drgnx-cockpit-edits--draws) (t0 (float-time)))
        (set-window-start (selected-window) start)
        ;; the agent writes README 50 times in a second; the folder's watch says so each time, and of a file the pane
        ;; does not list (a lock or temp file) too, whose listing waits for its turn
        (setq drgnx-cockpit-edits--listed-at (float-time))
        (let ((watch (drgnx-cockpit-edits-test--watch watches wt-a)))
          (dotimes (i 50)
            (drgnx-cockpit-fixture-write (concat wt-a "README") (format "readme\n%s\nmore\n" i))
            (funcall watch (list 1 'changed (concat wt-a "README")))
            (funcall watch (list 1 'created (concat wt-a ".#README")))
            (accept-process-output nil 0.018)))
        (should (< (- (float-time) t0) 1.2))
        (drgnx-cockpit-edits-test--settle e)
        ;; one redraw per 0.3 s, not one per write, and not held back by the listing: 3 or 4 in all
        (should (<= 3 (- drgnx-cockpit-edits--draws draws) 4))
        (should (string-search "\n+49\n" (buffer-string)))                ; the last write shows
        (should (string-match-p "\\`README \\+2 " (drgnx-cockpit-edits-test--header "README")))
        ;; no window moved; point and scroll stay on the same file, line and column (the line now reads +49)
        (should (equal (window-list) windows))
        (should (= (window-start) (save-excursion (drgnx-cockpit-edits-test--goto "README") (point))))
        (should (= line (count-lines (window-start) (line-beginning-position))))
        (should (equal (buffer-substring-no-properties (line-beginning-position) (point)) "+4"))))))

(ert-deftest drgnx-cockpit-edits/accept-marks-and-a-change-unmarks ()
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (let ((ext drgnx-cockpit-edits-test--ext))
      (drgnx-cockpit-edits-test--goto "README" "+more")
      (call-interactively #'drgnx-cockpit-edits-accept-file)
      (let ((mark (cdr (assoc "README" (drgnx-coord-review-marks ext)))))
        (should (equal (plist-get mark :state) "accepted"))
        (should (equal (plist-get mark :hash) (plist-get (gethash "README" drgnx-cockpit-edits--info) :hash))))
      (should (string-match-p "accepted\\'" (drgnx-cockpit-edits-test--header "README")))
      (should-not (string-match-p "accepted" (drgnx-cockpit-edits-test--header "new.txt")))
      (should (string-match-p "1 accepted" (car header-line-format)))
      (should (equal (plist-get (plist-get (car (drgnx-coord-events :agent ext :kinds '("accept"))) :data) :path) "README"))
      ;; the agent changes README again: pending, and the header says so
      (drgnx-cockpit-fixture-write (concat wt-a "README") "readme\nmore\nagain\n")
      (drgnx-cockpit-edits-test--notify wt-a "README")
      (drgnx-cockpit-edits-test--settle e)
      (should (equal (plist-get (cdr (assoc "README" (drgnx-coord-review-marks ext))) :state) "pending"))
      (should (string-match-p "changed since accepted\\'" (drgnx-cockpit-edits-test--header "README")))
      ;; a diff that does not show cannot be accepted
      (puthash "new.txt" (plist-put (gethash "new.txt" drgnx-cockpit-edits--info) :hash nil) drgnx-cockpit-edits--info)
      (should-error (drgnx-cockpit-edits-accept-file "new.txt") :type 'user-error))))

(ert-deftest drgnx-cockpit-edits/accept-never-merges ()
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (let ((heads (list (drgnx-cockpit-fixture-git repo "rev-parse" "main") (drgnx-cockpit-fixture-git wt-a "rev-parse" "HEAD")))
          (status (drgnx-cockpit-fixture-git wt-a "status" "--porcelain")))
      (cl-letf (((symbol-function 'drgnx-job--merge) (lambda (&rest _) (ert-fail "Accept merged")))
                ((symbol-function 'drgnx-hub-call) (lambda (method &rest _) (ert-fail (format "Accept asked the hub: %s" method)))))
        (dolist (f '("README" "new.txt"))
          (drgnx-cockpit-edits-test--goto f)
          (call-interactively #'drgnx-cockpit-edits-accept-file)))
      (should (equal (mapcar (lambda (m) (plist-get (cdr m) :state)) (drgnx-coord-review-marks drgnx-cockpit-edits-test--ext))
                     '("accepted" "accepted")))
      ;; no commit, no merge, the files as they were
      (should (equal heads (list (drgnx-cockpit-fixture-git repo "rev-parse" "main") (drgnx-cockpit-fixture-git wt-a "rev-parse" "HEAD"))))
      (should (equal status (drgnx-cockpit-fixture-git wt-a "status" "--porcelain")))
      (should (equal (drgnx-cockpit-fixture-git wt-a "show" ":README") "readme")))))

(ert-deftest drgnx-cockpit-edits/revert-queues-unless-stopped-in-its-own-worktree ()
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (let ((ext drgnx-cockpit-edits-test--ext) (main-status (drgnx-cockpit-fixture-git repo "status" "--porcelain"))
          (inbox (lambda (id) (mapcar (lambda (m) (plist-get m :text)) (drgnx-coord-inbox id)))))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (ert-fail "Asked")))
                ((symbol-function 'drgnx-agents-stop) (lambda (&rest _) (ert-fail "Stopped an agent"))))
        ;; running: a queued request, the file untouched
        (drgnx-cockpit-edits-test--goto "README" "+more")
        (call-interactively #'drgnx-cockpit-edits-revert-file)
        (should (equal (funcall inbox ext) '("[revert] please undo your changes to README")))
        (should (equal (with-temp-buffer (insert-file-contents (concat wt-a "README")) (buffer-string)) "readme\nmore\n"))
        (should (plist-get (plist-get (car (last (drgnx-coord-events :agent ext :kinds '("revert")))) :data) :requested)))
      ;; a session in this Emacs set to interrupt: queued all the same — never a cancel
      (let* ((s (drgnx-agents--make :id "s-2" :name "chat" :cwd repo :status 'busy :mode 'interrupt))
             (sent nil))
        (cl-letf (((symbol-function 'drgnx-agents-sessions) (lambda () (list s)))
                  ((symbol-function 'drgnx-agents-send) (lambda (s text) (push (list text (drgnx-agent-session-mode s)) sent)))
                  ((symbol-function 'drgnx-agents-stop) (lambda (&rest _) (ert-fail "Stopped an agent")))
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) (ert-fail "Asked"))))
          (with-current-buffer (drgnx-cockpit-edits-buffer "s-2")
            (unwind-protect
                ;; s-2 works in the main checkout: never reverted there, stopped or not
                (dolist (live (list sessions (list (car sessions))))
                  (cl-letf (((symbol-function 'drgnx-cockpit-sessions) (lambda () live)))
                    (drgnx-cockpit-edits-revert-file "README")))
              (kill-buffer)))
          (should (equal sent '(("[revert] please undo your changes to README" queue)
                                ("[revert] please undo your changes to README" queue))))
          (should (eq (drgnx-agent-session-mode s) 'interrupt))))
      ;; stopped in its own worktree: reverted there, after asking
      (drgnx-coord-event-add :agent ext :kind "stop" :summary "stopped")
      (let ((asked nil))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (prompt) (push prompt asked) t)))
          (drgnx-cockpit-edits-test--goto "README" "+more")
          (call-interactively #'drgnx-cockpit-edits-revert-file)
          (drgnx-cockpit-edits-test--goto "new.txt")
          (call-interactively #'drgnx-cockpit-edits-revert-file))
        (should (= 2 (length asked))))
      (should (equal (with-temp-buffer (insert-file-contents (concat wt-a "README")) (buffer-string)) "readme\n"))
      (should-not (file-exists-p (concat wt-a "new.txt")))
      (should (= 1 (length (funcall inbox ext))))                       ; nothing more queued
      (should (seq-every-p (lambda (ev) (plist-get (plist-get ev :data) :direct))
                           (cdr (drgnx-coord-events :agent ext :kinds '("revert")))))
      (should (equal main-status (drgnx-cockpit-fixture-git repo "status" "--porcelain")))   ; main's checkout untouched
      ;; the pane follows: nothing left to show
      (drgnx-cockpit-edits-test--settle e)
      (should (null drgnx-cockpit-edits--files))
      (should (string-match-p "No changes" (buffer-string))))))

(ert-deftest drgnx-cockpit-edits/revert-direct-asks-first ()
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (let ((ext drgnx-cockpit-edits-test--ext) (asked nil))
      (drgnx-coord-event-add :agent ext :kind "stop" :summary "stopped")
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (prompt) (push prompt asked) nil)))
        (drgnx-cockpit-edits-test--goto "README")
        (call-interactively #'drgnx-cockpit-edits-revert-file))
      (should (string-match-p "README" (car asked)))
      (should (equal (with-temp-buffer (insert-file-contents (concat wt-a "README")) (buffer-string)) "readme\nmore\n"))
      (should-not (drgnx-coord-inbox ext))                               ; no request queued instead
      (should-not (drgnx-coord-events :agent ext :kinds '("revert"))))))

(ert-deftest drgnx-cockpit-edits/comment-queues-a-message ()
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (let ((ext drgnx-cockpit-edits-test--ext))
      (cl-letf (((symbol-function 'read-string) (lambda (prompt &rest _) (should (string-match-p "README:2" prompt)) "  name it better "))
                ((symbol-function 'drgnx-agents-stop) (lambda (&rest _) (ert-fail "Stopped an agent"))))
        (drgnx-cockpit-edits-test--goto "README" "+more")
        (call-interactively #'drgnx-cockpit-edits-comment))
      (should (equal (mapcar (lambda (m) (plist-get m :text)) (drgnx-coord-inbox ext)) '("[comment] README:2: name it better")))
      (let ((ev (car (drgnx-coord-events :agent ext :kinds '("comment")))))
        (should (equal (plist-get (plist-get ev :data) :line) 2))
        (should (equal (plist-get (plist-get ev :data) :path) "README")))
      ;; the line a diff line stands for: context and added lines count, removed ones do not
      (should (= 1 (progn (drgnx-cockpit-edits-test--goto "README" " readme") (drgnx-cockpit-edits--line-here))))
      (should (= 1 (progn (drgnx-cockpit-edits-test--goto "README") (drgnx-cockpit-edits--line-here))))
      ;; a hub session (mirrored here): agents/send unless it is set to interrupt, then the store's queue
      (let* ((s (drgnx-agents--make :id "m-1" :remote ext :name "mirror" :status 'busy :mode 'steer)) (sent nil))
        (cl-letf (((symbol-function 'drgnx-agents-sessions) (lambda () (list s)))
                  ((symbol-function 'drgnx-agents-send) (lambda (_s text) (push text sent))))
          (drgnx-cockpit-edits-comment "README" 1 "one")
          (setf (drgnx-agent-session-mode s) 'interrupt)
          (drgnx-cockpit-edits-comment "README" 1 "two"))
        (should (equal sent '("[comment] README:1: one")))
        (should (equal (plist-get (car (last (drgnx-coord-inbox ext))) :text) "[comment] README:1: two"))))))

(ert-deftest drgnx-cockpit-edits/the-graph-opens-an-agents-edits ()
  (drgnx-cockpit-fixture-with
    (let ((drgnx-cockpit-graph-current-filter nil) (drgnx-cockpit--timer nil) (drgnx-cockpit--check-timer nil)
          (drgnx-cockpit--silent nil) (drgnx-cockpit--silent-n 0) (drgnx-cockpit--silent-at (float-time))
          (drgnx-cockpit--silent-running nil) (drgnx-cockpit-edits--last nil) (shown nil))
      (cl-letf (((symbol-function 'drgnx-cockpit-sessions) (lambda () sessions))
                ((symbol-function 'drgnx-cockpit-edits-show) (lambda (agent) (push agent shown))))
        (let ((g (drgnx-cockpit-graph-buffer)))
          (unwind-protect
              (save-window-excursion
                (set-window-buffer (selected-window) g)
                (drgnx-cockpit-graph-redraw t)
                ;; a task an agent works on: that agent's edits; an agent: its own; a task nobody works on: its plan
                (drgnx-cockpit-graph-open-node (format "task:%s#2" plan))
                (drgnx-cockpit-graph-open-node "agent:ext:claude-code:42")
                (should (equal (mapcar (lambda (a) (if (consp a) (plist-get a :id) a)) shown) '("ext:claude-code:42" "s-1")))
                (should (equal (plist-get (car shown) :worktree) (directory-file-name wt-a)))   ; the model's agent
                (drgnx-cockpit-graph-open-node (format "task:%s#1" plan))
                (should (= 2 (length shown)))
                (should (equal (buffer-file-name (window-buffer (selected-window))) plan)))
            (kill-buffer g)))))))

(ert-deftest drgnx-cockpit-edits/keys-in-every-profile ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil) (kinds nil))
    (cl-letf (((symbol-function 'drgnx-pane-define-kind) (lambda (kind &rest props) (push (cons kind props) kinds))))
      (funcall (plist-get (alist-get 'tools/cockpit drgnx-modules--table) :setup)))
    (should (eq (plist-get (alist-get 'agent-edits kinds) :home) 'editor))
    (pcase-dolist (`(,id ,fn) '((cockpit-accept-file drgnx-cockpit-edits-accept-file)
                                (cockpit-revert-file drgnx-cockpit-edits-revert-file)
                                (cockpit-comment drgnx-cockpit-edits-comment)
                                (cockpit-edits-next-file drgnx-cockpit-edits-next-file)
                                (cockpit-edits-previous-file drgnx-cockpit-edits-previous-file)))
      (should (eq (drgnx-cmd-command (drgnx-commands-get id)) fn))
      (should (eq (drgnx-cmd-map (drgnx-commands-get id)) 'drgnx-cockpit-edits-mode-map))))
  (should (eq (alist-get 'task (eval (car (get 'drgnx-cockpit-open-functions 'standard-value)) t)) 'drgnx-cockpit-edits-open-task))
  (should (eq (alist-get 'agent (eval (car (get 'drgnx-cockpit-open-functions 'standard-value)) t)) 'drgnx-cockpit-edits-open-agent))
  (dolist (profile '("vscode" "emacs" "vim"))
    (let ((bind (plist-get (with-temp-buffer (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
                                             (read (current-buffer)))
                           :bind)))
      (dolist (row '((cockpit-accept-file "a") (cockpit-revert-file "r") (cockpit-comment "c")
                     (cockpit-edits-next-file "n") (cockpit-edits-previous-file "p")))
        (should (equal (assq (car row) bind) row))))))

;;; mod-cockpit-edits-test.el ends here
