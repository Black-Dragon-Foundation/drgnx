;;; mod-cockpit-edits-test.el --- batch tests: each agent's edits as a live diff (accept, revert by request, comment on a line) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'filenotify)
(require 'drgnx)
(require 'drgnx-agents)
(load (expand-file-name "test/fixtures/cockpit-fixture" drgnx-dir) nil t)   ; a project, a job, worktrees, events
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)   ; virtual time
(load (expand-file-name "modules/tools/drgnx-cockpit" drgnx-dir) nil t)

(defconst drgnx-cockpit-edits-test--ext "ext:claude-code:42"
  "The fixture's outside agent: README changed and new.txt added in its own worktree WT-A, both reported.")

(defun drgnx-cockpit-edits-test--keys (buffer)
  "BUFFER's pane's four timer keys: the tick, the listing's turn, the flush and the check."
  (mapcar (lambda (k) (cons k buffer)) '(cockpit-edits-tick cockpit-edits-turn cockpit-edits-flush cockpit-edits-check)))

(defun drgnx-cockpit-edits-test--settled-p (buffer)
  "Whether BUFFER's pane has listed and diffed everything, with nothing on its way."
  (with-current-buffer buffer
    (and drgnx-cockpit-edits--loaded (not drgnx-cockpit-edits--busy)
         (not (drgnx-timer-active-p (cons 'cockpit-edits-tick buffer)))
         (not (drgnx-timer-active-p (cons 'cockpit-edits-turn buffer)))
         (zerop (hash-table-count drgnx-cockpit-edits--dirty)) (not drgnx-cockpit-edits--list-dirty))))

(defun drgnx-cockpit-edits-test--settle (buffer)
  (should (drgnx-cockpit-fixture-wait (lambda () (drgnx-cockpit-edits-test--settled-p buffer)))))

(defun drgnx-cockpit-edits-test--tmp (root)
  "A temp folder inside the fixture's ROOT (made): tests never put the pane's folder in the real one."
  (let ((d (concat root "tmp/"))) (make-directory d t) d))

(defmacro drgnx-cockpit-edits-test--with (agent &rest body)
  "BODY in the cockpit fixture with AGENT's edits pane E shown in the selected window and loaded; the hub's sessions
the fixture's (SESSIONS); NOTIFIED counts the hub told of a message.  File watches are recorded in WATCHES (descriptor → (DIR CALLBACK)), never real ones: in
batch Emacs a real watch's events wait in an input queue nobody reads, and while one waits no process sentinel runs.
The pane is killed after, and must leave no timer or watch behind.  A fresh workbench state store has the panes'
subscriptions (`drgnx-cockpit-edits--subscribe'): a test that shows or hides E calls `drgnx-state-sync' after, and
`drgnx-state--deliver-idle' when no pane event says it (`windows-changed' is on the `idle' lane)."
  (declare (indent 1))
  `(drgnx-cockpit-fixture-with
     (drgnx-test-with-state
       (drgnx-cockpit-edits--subscribe)
       (let ((drgnx-cockpit-edits--draws 0) (drgnx-cockpit-edits-check-interval 3600) (drgnx-cockpit-edits--list-every 0)
             (drgnx-cockpit-edits--last nil) (config (current-window-configuration))
             (temporary-file-directory (drgnx-cockpit-edits-test--tmp root))
             (watches (make-hash-table)) (watch-n 0) (notified 0))
         (cl-letf (((symbol-function 'drgnx-cockpit-sessions) (lambda () sessions))
                   ((symbol-function 'drgnx-cockpit-edits--notify-hub) (lambda () (cl-incf notified)))
                   ((symbol-function 'file-notify-add-watch) (lambda (dir _flags cb) (puthash (cl-incf watch-n) (list dir cb) watches) watch-n))
                   ((symbol-function 'file-notify-rm-watch) (lambda (d) (remhash d watches)))
                   ((symbol-function 'file-notify-valid-p) (lambda (d) (and (gethash d watches) t))))
           (let ((e (drgnx-cockpit-edits-buffer ,agent)))
             (unwind-protect
                 (save-window-excursion
                   (delete-other-windows)
                   (set-window-buffer (selected-window) e)
                   (drgnx-state-sync) (drgnx-state--deliver-idle) ; the store sees it shown: it follows its agent
                   (set-buffer e)
                   (drgnx-cockpit-edits-test--settle e)
                   ,@body)
               (let ((own (buffer-local-value 'drgnx-cockpit-edits--neutral e)))
                 (kill-buffer e)
                 (should-not (file-exists-p own))                     ; its own folder went with it
                 (dolist (k (drgnx-cockpit-edits-test--keys e)) (should-not (drgnx-timer-active-p k)))   ; the buffer owned them
                 (should (zerop (hash-table-count watches))))
               (set-window-configuration config))))))))

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
    (should (eq buffer-undo-list t))                                  ; a generated buffer: no undo
    (should (equal drgnx-cockpit-edits--files '("README" "new.txt")))
    ;; FILE +A −B per file, its diff below
    (should (string-match-p "\\`README \\+1 [−-]0\\'" (drgnx-cockpit-edits-test--header "README")))
    (should (string-match-p "\\`new\\.txt \\+1 [−-]0  new\\'" (drgnx-cockpit-edits-test--header "new.txt")))
    (drgnx-cockpit-edits-test--goto "README" "+more")
    (drgnx-cockpit-edits-test--goto "new.txt" "+new")
    (should (string-match-p "2 files changed" (car header-line-format)))
    ;; the header's parts keep their faces under the diff colours; diff lines get diff-mode's faces
    (drgnx-cockpit-edits-test--goto "README")
    (should (eq (get-text-property (point) 'drgnx-cockpit-edits-face) 'drgnx-cockpit-edits-file))
    (font-lock-ensure)
    (should (eq (get-text-property (point) 'face) 'drgnx-cockpit-edits-file))
    (should (eq (get-text-property (+ (point) 7) 'face) 'drgnx-cockpit-edits-added))
    (should (eq (save-excursion (drgnx-cockpit-edits-test--goto "README" "+more") (get-text-property (point) 'face)) 'diff-added))
    (should (eq (save-excursion (drgnx-cockpit-edits-test--goto "README" "@@") (get-text-property (point) 'face)) 'diff-hunk-header))
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
    (should-not (drgnx-timer-active-p (cons 'cockpit-edits-tick (current-buffer))))
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
  ;; virtual time: the 50 writes take 0.9 virtual seconds, whatever the machine does with them
  (drgnx-test-with-clock ()
    (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
      (let ((drgnx-cockpit-edits-delay 0.3) (drgnx-cockpit-edits--list-every 1.5)
            (windows (window-list)))
        ;; point in README's "+more" line, two characters in; the window starting at README's header
        (drgnx-cockpit-edits-test--goto "README" "+more")
        (forward-char 2)
        (let* ((start (save-excursion (drgnx-cockpit-edits-test--goto "README") (point)))
               (line (count-lines start (line-beginning-position)))
               (draws drgnx-cockpit-edits--draws))
          (set-window-start (selected-window) start)
          ;; the agent writes README 50 times in a second; the folder's watch says so each time, and of a file the pane
          ;; does not list (a lock or temp file) too, whose listing waits for its turn
          (setq drgnx-cockpit-edits--listed-at (float-time))
          (let ((watch (drgnx-cockpit-edits-test--watch watches wt-a)))
            (dotimes (i 50)
              (drgnx-cockpit-fixture-write (concat wt-a "README") (format "readme\n%s\nmore\n" i))
              (funcall watch (list 1 'changed (concat wt-a "README")))
              (funcall watch (list 1 'created (concat wt-a ".#README")))
              (drgnx-test-advance 0.018)
              ;; a diff in flight finishes in real time, which costs no virtual time: the 0.3 s tick counts only the test's steps
              (let ((until (+ (drgnx-test-real-time) 20)))
                (while (and drgnx-cockpit-edits--busy (< (drgnx-test-real-time) until))
                  (funcall drgnx-test--accept nil 0.005))
                (when drgnx-cockpit-edits--busy
                  (ert-fail (format "diff still in flight after 20 s real time (write %d)" i))))))
          (drgnx-cockpit-edits-test--settle e)
          ;; one redraw per 0.3 s, not one per write, and not held back by the listing: 3 or 4 in all
          (should (<= 3 (- drgnx-cockpit-edits--draws draws) 4))
          (should (string-search "\n+49\n" (buffer-string)))                ; the last write shows
          (should (string-match-p "\\`README \\+2 " (drgnx-cockpit-edits-test--header "README")))
          ;; no window moved; point and scroll stay on the same file, line and column (the line now reads +49)
          (should (equal (window-list) windows))
          (should (= (window-start) (save-excursion (drgnx-cockpit-edits-test--goto "README") (point))))
          (should (= line (count-lines (window-start) (line-beginning-position))))
          (should (equal (buffer-substring-no-properties (line-beginning-position) (point)) "+4")))))))

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
      ;; the agent changes README again: the header says so; the mark keeps the hash accepted (the gate compares)
      (drgnx-cockpit-fixture-write (concat wt-a "README") "readme\nmore\nagain\n")
      (drgnx-cockpit-edits-test--notify wt-a "README")
      (drgnx-cockpit-edits-test--settle e)
      (let ((mark (cdr (assoc "README" (drgnx-coord-review-marks ext)))))
        (should (equal (plist-get mark :state) "accepted"))
        (should-not (equal (plist-get mark :hash) (plist-get (gethash "README" drgnx-cockpit-edits--info) :hash))))
      (should (string-match-p "0 accepted" (car header-line-format)))
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
          (drgnx-cockpit-edits-comment "README" 1 "two")
          (setf (drgnx-agent-session-mode s) 'steer (drgnx-agent-session-status s) 'exited)
          (drgnx-cockpit-edits-comment "README" 1 "three"))
        (should (equal sent '("[comment] README:1: one")))
        (should (equal (mapcar (lambda (m) (plist-get m :text)) (last (drgnx-coord-inbox ext) 2))
                       '("[comment] README:1: two" "[comment] README:1: three")))
        (should (= 3 notified))))))

(ert-deftest drgnx-cockpit-edits/the-pane-is-never-cloned ()
  ;; a clone would share the pane's timers and watches: killing it would stop the original's updates
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (let ((n (length (buffer-list))))
      (should-error (clone-buffer))
      (should-error (clone-indirect-buffer nil nil))
      (should (= n (length (buffer-list))))
      (should (drgnx-timer-active-p (cons 'cockpit-edits-check (current-buffer)))))))

(defun drgnx-cockpit-edits-test--hide (e)
  "Show *scratch* where the pane E was, and let the store see it."
  (dolist (w (get-buffer-window-list e nil t)) (set-window-buffer w (get-buffer-create "*scratch*")))
  (drgnx-state-sync) (drgnx-state--deliver-idle))

(ert-deftest drgnx-cockpit-edits/a-hidden-pane-keeps-no-timer ()
  ;; shown, the pane looks at the store every few seconds; hidden (another buffer in its window), it keeps no timer
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (should (drgnx-timer-active-p (cons 'cockpit-edits-check e)))
    (drgnx-cockpit-edits--schedule 3600)                                 ; a tick on its way, as after a write
    (drgnx-cockpit-edits-test--hide e)
    (should-not (seq-filter #'drgnx-timer-active-p (drgnx-cockpit-edits-test--keys e)))
    (should-not (seq-find (lambda (p) (eq (nth 1 p) e)) (drgnx-timer-pending)))))

(ert-deftest drgnx-cockpit-edits/hidden-edits-keep-no-watches ()
  ;; M12f-C6-1: a hidden pane's file watches go; they come back when it shows
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (should (gethash wt-a drgnx-cockpit-edits--watches))
    (should (> (hash-table-count watches) 0))
    (drgnx-cockpit-edits-test--hide e)
    (should (zerop (hash-table-count watches)))
    (should (zerop (hash-table-count drgnx-cockpit-edits--watches)))
    (set-window-buffer (selected-window) e)
    (drgnx-state-sync) (drgnx-state--deliver-idle)
    (drgnx-cockpit-edits-test--settle e)
    (should (gethash wt-a drgnx-cockpit-edits--watches))
    (should (= (hash-table-count watches) (hash-table-count drgnx-cockpit-edits--watches)))))

(ert-deftest drgnx-cockpit-edits/following-walks-only-the-panes ()
  ;; ST-T24-1: a window change looks at the edits panes the module keeps, never at every buffer
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (should (memq e drgnx-cockpit-edits--buffers))
    (dolist (w (get-buffer-window-list e nil t)) (set-window-buffer w (get-buffer-create "*scratch*")))
    (drgnx-state-sync)
    (cl-letf (((symbol-function 'buffer-list) (lambda (&rest _) (ert-fail "Every buffer was looked at"))))
      (drgnx-state--deliver-idle))
    (should-not (seq-filter #'drgnx-timer-active-p (drgnx-cockpit-edits-test--keys e)))
    (should (zerop (hash-table-count watches)))))

(ert-deftest drgnx-cockpit-edits/showing-starts-it-again ()
  ;; hidden while the agent writes a new file and reports it (no watch, no check sees it): shown again as its pane,
  ;; its check runs, the changes are listed again (the new file shows) and their folders watched again
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (drgnx-cockpit-edits-test--hide e)
    (drgnx-cockpit-fixture-write (concat wt-a "docs/while-hidden.md") "hidden\n")
    (drgnx-coord-event-add :agent drgnx-cockpit-edits-test--ext :kind "edit" :summary "1 file"
                           :data (list :root (directory-file-name wt-a) :paths '("docs/while-hidden.md")))
    (should-not (seq-filter #'drgnx-timer-active-p (drgnx-cockpit-edits-test--keys e)))
    (drgnx-cockpit-fixture-show-pane 'agent-edits e 'editor)
    (should (drgnx-timer-active-p (cons 'cockpit-edits-check e)))
    (drgnx-cockpit-edits-test--settle e)
    (should (member "docs/while-hidden.md" drgnx-cockpit-edits--files))
    (drgnx-cockpit-edits-test--goto "docs/while-hidden.md" "+hidden")
    (should (gethash (concat wt-a "docs/") drgnx-cockpit-edits--watches))
    ;; its pane hidden (the store's `pane-hidden', on the `now' lane): no timer and no watch at once
    (drgnx-cockpit-fixture-hide-pane (selected-window))
    (should-not (seq-filter #'drgnx-timer-active-p (drgnx-cockpit-edits-test--keys e)))
    (should (zerop (hash-table-count watches)))))

(ert-deftest drgnx-cockpit-edits/a-patch-keeps-each-window-on-its-hunk ()
  ;; two windows on the pane, one in README's hunk, one in new.txt's; README's grows above new.txt's section: each
  ;; window stays in its hunk at the same offset, and no window is added, closed or selected
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (let* ((w1 (selected-window)) (w2 (split-window w1 nil 'below)))
      (set-window-buffer w2 e)
      (drgnx-state-sync)
      (set-window-point w1 (save-excursion (drgnx-cockpit-edits-test--goto "README" "+more") (+ (point) 2)))
      (set-window-start w2 (save-excursion (drgnx-cockpit-edits-test--goto "new.txt") (point)))
      (set-window-point w2 (save-excursion (drgnx-cockpit-edits-test--goto "new.txt" "+new") (1+ (point))))
      (let ((before (window-start w2)) (windows (window-list)))
        (drgnx-cockpit-fixture-write (concat wt-a "README") "readme\none\ntwo\nmore\n")
        (drgnx-cockpit-edits-test--notify wt-a "README")
        (drgnx-cockpit-edits-test--settle e)
        (should (string-search "\n+two\n" (buffer-string)))
        (should (equal (window-list) windows))
        (should (eq (selected-window) w1))
        ;; new.txt's section moved down; its window followed it
        (should (> (window-start w2) before))
        (should (= (window-start w2) (save-excursion (drgnx-cockpit-edits-test--goto "new.txt") (point))))
        (should (= (window-point w2) (1+ (save-excursion (drgnx-cockpit-edits-test--goto "new.txt" "+new") (point)))))
        ;; README's window: its hunk, the same offset from the hunk's `@@' line
        (should (equal (drgnx-cockpit-edits--row-at (window-point w1)) (cons "README" 1)))
        (should (= (- (window-point w1) (save-excursion (drgnx-cockpit-edits-test--goto "README" "@@") (point)))
                   (+ 2 (length "@@ -1 +1,2 @@\n readme\n"))))))))

(ert-deftest drgnx-cockpit-edits/a-listing-waiting-for-its-turn-never-holds-a-touch-back ()
  ;; the turn has a timer of its own, so a tick asked for meanwhile is not behind it; a second ask moves the turn
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (let ((tick (cons 'cockpit-edits-tick e)) (turn (cons 'cockpit-edits-turn e)))
      (drgnx-cockpit-edits--schedule-turn 3600)
      (drgnx-cockpit-edits--schedule 0.2)
      (should (drgnx-timer-active-p turn))
      (should (drgnx-timer-active-p tick))
      (should (= 1 (cl-count turn (drgnx-timer-pending) :key #'car :test #'equal)))
      (drgnx-cockpit-edits--schedule-turn 3600)
      (should (= 1 (cl-count turn (drgnx-timer-pending) :key #'car :test #'equal)))
      (drgnx-timer-cancel turn)
      (drgnx-timer-cancel tick))))

(ert-deftest drgnx-cockpit-edits/diff-commands-by-name-and-g-change-no-file ()
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (let ((status (drgnx-cockpit-fixture-git wt-a "status" "--porcelain"))
          (readme (lambda () (with-temp-buffer (insert-file-contents (concat wt-a "README")) (buffer-string)))))
      ;; M-x diff-apply-hunk in the pane: it finds no file of the agent's from the pane's own folder (and the user is
      ;; asked for one, here refused)
      (drgnx-cockpit-edits-test--goto "README" "+more")
      (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) (error "Asked for a file")))
                ((symbol-function 'yes-or-no-p) #'always) ((symbol-function 'y-or-n-p) #'always))
        (ignore-errors (call-interactively #'diff-apply-hunk))
        (ignore-errors (call-interactively #'diff-apply-buffer)))
      (should (equal (funcall readme) "readme\nmore\n"))
      (should (equal status (drgnx-cockpit-fixture-git wt-a "status" "--porcelain")))
      ;; g lists the changes again, and only that: no question, no file touched, the same files shown
      (set-buffer e)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (ert-fail "Asked")))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) (ert-fail "Asked"))))
        (revert-buffer)
        (should drgnx-cockpit-edits--list-dirty)
        (drgnx-cockpit-edits-test--settle e))
      (should (equal drgnx-cockpit-edits--files '("README" "new.txt")))
      (should (equal (funcall readme) "readme\nmore\n"))
      (should (equal status (drgnx-cockpit-fixture-git wt-a "status" "--porcelain"))))))

(ert-deftest drgnx-cockpit-edits/the-graph-opens-an-agents-edits ()
  (drgnx-cockpit-fixture-with
    (let ((drgnx-cockpit-graph-current-filter nil)
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
                (should (equal (buffer-file-name (window-buffer (selected-window))) (file-truename plan))))   ; by its true name
            (kill-buffer g)))))))

(ert-deftest drgnx-cockpit-edits/keys-in-every-profile ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil) (kinds nil))
    (cl-letf (((symbol-function 'drgnx-pane-define-kind) (lambda (kind &rest props) (push (cons kind props) kinds))))
      (drgnx-cockpit-fixture-after-setup
        ;; the panes hear from the workbench state store when they show, are hidden (at once), or swap buffers in one
        ;; window (once Emacs is idle: never inside redisplay)
        (should (memq #'drgnx-cockpit-edits--pane-shown (alist-get 'pane-shown drgnx-state--now)))
        (should (memq #'drgnx-cockpit-edits--pane-hidden (alist-get 'pane-hidden drgnx-state--now)))
        (should (memq #'drgnx-cockpit-edits--windows-changed (alist-get 'windows-changed drgnx-state--idle)))))
    (should (eq (plist-get (alist-get 'agent-edits kinds) :home) 'editor))
    (pcase-dolist (`(,id ,fn) '((cockpit-accept-file drgnx-cockpit-edits-accept-file)
                                (cockpit-revert-file drgnx-cockpit-edits-revert-file)
                                (cockpit-comment drgnx-cockpit-edits-comment)
                                (cockpit-edits-next-file drgnx-cockpit-edits-next-file)
                                (cockpit-edits-previous-file drgnx-cockpit-edits-previous-file)
                                (cockpit-edits-visit drgnx-cockpit-edits-visit)
                                (cockpit-edits-next-hunk drgnx-cockpit-edits-next-hunk)
                                (cockpit-edits-previous-hunk drgnx-cockpit-edits-previous-hunk)))
      (should (eq (drgnx-cmd-command (drgnx-commands-get id)) fn))
      (should (eq (drgnx-cmd-map (drgnx-commands-get id)) 'drgnx-cockpit-edits-mode-map))))
  (should (eq (alist-get 'task (eval (car (get 'drgnx-cockpit-open-functions 'standard-value)) t)) 'drgnx-cockpit-edits-open-task))
  (should (eq (alist-get 'agent (eval (car (get 'drgnx-cockpit-open-functions 'standard-value)) t)) 'drgnx-cockpit-edits-open-agent))
  (dolist (profile '("vscode" "emacs" "vim"))
    (let ((bind (plist-get (with-temp-buffer (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
                                             (read (current-buffer)))
                           :bind)))
      (dolist (row '((cockpit-accept-file "a") (cockpit-revert-file "r") (cockpit-comment "c")
                     (cockpit-edits-next-file "n") (cockpit-edits-previous-file "p") (cockpit-edits-visit "RET")
                     (cockpit-edits-next-hunk "TAB") (cockpit-edits-previous-hunk "<backtab>")))
        (should (equal (assq (car row) bind) row))))))

(ert-deftest drgnx-cockpit-edits/a-native-session-is-never-reverted-here ()
  ;; a chat session stopped in a linked worktree (the user may work there): a request, never a question
  (drgnx-cockpit-fixture-with
    (let ((drgnx-cockpit-edits--last nil) (temporary-file-directory (drgnx-cockpit-edits-test--tmp root)) (ledger (concat wt-b ".superpowers/sdd/p/progress.md")))
      (drgnx-coord-agent-register :id "s-9" :name "chat" :cwd (directory-file-name wt-b))
      (cl-letf (((symbol-function 'drgnx-cockpit-sessions) (lambda () sessions))   ; s-9 is not among them: "stopped"
                ((symbol-function 'drgnx-cockpit-edits--notify-hub) #'ignore)
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) (ert-fail "Asked"))))
        (with-current-buffer (drgnx-cockpit-edits-buffer "s-9")
          (unwind-protect
              (progn (should (eq (plist-get (drgnx-cockpit-edits--read-source) :kind) 'native))
                     (drgnx-cockpit-edits-revert-file ".superpowers/sdd/p/progress.md"))
            (kill-buffer))))
      (should (file-exists-p ledger))
      (should (equal (mapcar (lambda (m) (plist-get m :text)) (drgnx-coord-inbox "s-9"))
                     '("[revert] please undo your changes to .superpowers/sdd/p/progress.md"))))))

(ert-deftest drgnx-cockpit-edits/revert-queues-unless-stopped-in-its-own-worktree ()
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (let ((ext drgnx-cockpit-edits-test--ext) (main-status (drgnx-cockpit-fixture-git repo "status" "--porcelain"))
          (inbox (lambda (id) (mapcar (lambda (m) (plist-get m :text)) (drgnx-coord-inbox id))))
          (readme (lambda () (with-temp-buffer (insert-file-contents (concat wt-a "README")) (buffer-string)))))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (ert-fail "Asked")))
                ((symbol-function 'drgnx-agents-stop) (lambda (&rest _) (ert-fail "Stopped an agent"))))
        ;; running: a queued request, the file untouched
        (drgnx-cockpit-edits-test--goto "README" "+more")
        (call-interactively #'drgnx-cockpit-edits-revert-file)
        (should (equal (funcall inbox ext) '("[revert] please undo your changes to README")))
        (should (equal (funcall readme) "readme\nmore\n"))
        (should (plist-get (plist-get (car (last (drgnx-coord-events :agent ext :kinds '("revert")))) :data) :requested))
        (should (= 1 notified))
        ;; an outside agent that says it stopped, in the worktree it registered: still only a request — its worktree may
        ;; be the user's own, and a stop event proves nothing
        (drgnx-coord-event-add :agent ext :kind "stop" :summary "stopped")
        (drgnx-cockpit-edits-test--goto "README" "+more")
        (call-interactively #'drgnx-cockpit-edits-revert-file)
        (drgnx-cockpit-edits-test--goto "new.txt")
        (call-interactively #'drgnx-cockpit-edits-revert-file)
        (should (equal (funcall inbox ext) '("[revert] please undo your changes to README" "[revert] please undo your changes to README"
                                             "[revert] please undo your changes to new.txt")))
        (should (equal (funcall readme) "readme\nmore\n"))
        (should (file-exists-p (concat wt-a "new.txt"))))
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
      (should (equal main-status (drgnx-cockpit-fixture-git repo "status" "--porcelain"))))))   ; main's checkout untouched

(defmacro drgnx-cockpit-edits-test--job (&rest body)
  "BODY in the cockpit fixture with jx#2's task worktree TREE made as drgnx makes it (`.claude/worktrees/jx-2' on
job/jx-2, from job/jx), README changed and n2.txt new there, and s-1's edits buffer current (not shown).  s-1 is gone
from the hub's list; its session here is MIRROR (nil: none; set it).  Questions go to ASKED and get ANSWER (t);
NOTIFIED counts the hub told; (INBOX) is s-1's messages; (SLURP FILE) a file's text."
  (declare (indent 0))
  `(drgnx-cockpit-fixture-with
     (let ((drgnx-cockpit-edits--last nil) (temporary-file-directory (drgnx-cockpit-edits-test--tmp root))
           (asked nil) (answer t) (mirror nil) (notified 0))
       (drgnx-cockpit-fixture-git repo "branch" "job/jx" "main")
       (drgnx-cockpit-fixture-git repo "worktree" "add" "-q" "-b" "job/jx-2" tree "job/jx")
       (drgnx-cockpit-fixture-write (concat tree "README") "readme\nby the job\n")
       (drgnx-cockpit-fixture-write (concat tree "n2.txt") "new\n")
       (cl-flet ((inbox () (mapcar (lambda (m) (plist-get m :text)) (drgnx-coord-inbox "s-1")))
                 (slurp (file) (and (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)))))
         (ignore #'inbox #'slurp)
         (cl-letf (((symbol-function 'drgnx-cockpit-sessions) (lambda () (cdr sessions)))
                   ((symbol-function 'drgnx-agents-sessions) (lambda () (and mirror (list mirror))))
                   ((symbol-function 'drgnx-cockpit-edits--notify-hub) (lambda () (cl-incf notified)))
                   ((symbol-function 'yes-or-no-p) (lambda (prompt) (push prompt asked) answer)))
           (with-current-buffer (drgnx-cockpit-edits-buffer "s-1")
             (unwind-protect (progn ,@body) (kill-buffer))))))))

(ert-deftest drgnx-cockpit-edits/revert-direct-asks-first ()
  (drgnx-cockpit-edits-test--job
    (setq mirror (drgnx-agents--make :id "m-1" :remote "s-1" :name "claude · jx#2" :status 'exited) answer nil)
    (drgnx-coord-force-status "jx#2" "done" "s-1")
    (drgnx-cockpit-edits-revert-file "README")
    (should (string-match-p "\\`Put README back as " (car asked)))
    (should (equal (slurp (concat tree "README")) "readme\nby the job\n"))
    (should-not (inbox))                                                  ; no request queued instead
    (should-not (drgnx-coord-events :agent "s-1" :kinds '("revert")))))

(ert-deftest drgnx-cockpit-edits/a-job-worktree-is-reverted-only-when-its-agent-is-known-stopped ()
  (drgnx-cockpit-edits-test--job
    ;; no session of it here: absence proves nothing — a request
    (drgnx-coord-force-status "jx#2" "done" "s-1")
    (drgnx-cockpit-edits-revert-file "README")
    ;; its mirror exited, but its task is still running: a request
    (drgnx-coord-force-status "jx#2" "running" "s-1")
    (setq mirror (drgnx-agents--make :id "m-1" :remote "s-1" :name "claude · jx#2" :status 'exited))
    (drgnx-cockpit-edits-revert-file "README")
    ;; exited and done, but another agent registered its cwd in the worktree: a request
    (drgnx-coord-force-status "jx#2" "done" "s-1")
    (drgnx-coord-agent-register :id "ext:zed:9" :kind "zed" :cwd (concat tree "sub"))
    (drgnx-cockpit-edits-revert-file "README")
    (drgnx-coord-agent-register :id "ext:zed:9" :clear '(:cwd))
    (should-not asked)
    (should (equal (inbox) (make-list 3 "[revert] please undo your changes to README")))
    (should (= 3 notified))
    ;; exited, done, alone: put back in its worktree, after the exact question
    (drgnx-cockpit-edits-revert-file "README")
    (drgnx-cockpit-edits-revert-file "n2.txt")
    (let ((wt (abbreviate-file-name (directory-file-name tree))))
      (should (equal (reverse asked)
                     (list (format "Put README back as %s has it, in %s, discarding the agent's changes? " (substring sha 0 8) wt)
                           (format "Delete new file n2.txt in %s (the agent's own worktree)? " wt)))))
    (should (equal (slurp (concat tree "README")) "readme\n"))
    (should-not (file-exists-p (concat tree "n2.txt")))
    (should (= 3 (length (inbox))))
    (should (equal (slurp (concat repo "README")) "readme\n"))))

(ert-deftest drgnx-cockpit-edits/a-job-folder-must-be-its-worktrees-top-on-its-branch ()
  (drgnx-cockpit-edits-test--job
    (setq mirror (drgnx-agents--make :id "m-1" :remote "s-1" :name "claude · jx#2" :status 'exited))
    (drgnx-coord-force-status "jx#2" "done" "s-1")
    ;; the task worktree on another branch than the job's: a request
    (drgnx-cockpit-fixture-git tree "checkout" "-q" "-b" "elsewhere")
    (drgnx-cockpit-edits-revert-file "README")
    (drgnx-cockpit-fixture-git tree "checkout" "-q" "job/jx-2")
    ;; the folder is no worktree's top (a plain folder inside another worktree): a request
    (let ((top (file-name-directory (directory-file-name tree))) (moved (concat (directory-file-name tree) "-real")))
      (rename-file tree moved)
      (make-directory tree)
      (drgnx-cockpit-fixture-write (concat tree "README") "readme\nby the job\n")
      (with-temp-file (concat top ".git") (insert-file-contents (concat moved "/.git")))   ; .claude/worktrees/ looks linked
      (drgnx-cockpit-edits-revert-file "README")
      (delete-file (concat top ".git")))
    (should-not asked)
    (should (equal (inbox) (make-list 2 "[revert] please undo your changes to README")))
    (should (equal (slurp (concat tree "README")) "readme\nby the job\n"))))

(ert-deftest drgnx-cockpit-edits/a-revert-checks-again-after-the-question ()
  (drgnx-cockpit-edits-test--job
    (setq mirror (drgnx-agents--make :id "m-1" :remote "s-1" :name "claude · jx#2" :status 'exited))
    (drgnx-coord-force-status "jx#2" "done" "s-1")
    ;; while the question waits, the task is taken up again: a request instead, the file kept
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (prompt) (push prompt asked) (drgnx-coord-force-status "jx#2" "running" "s-1") t)))
      (drgnx-cockpit-edits-revert-file "README"))
    (should (= 1 (length asked)))
    (should (equal (slurp (concat tree "README")) "readme\nby the job\n"))
    (should (equal (inbox) '("[revert] please undo your changes to README")))
    ;; another agent comes to work in it (through a link to it: true names count)
    (drgnx-coord-force-status "jx#2" "done" "s-1")
    (let ((link (concat root "link-to-tree")))
      (make-symbolic-link (directory-file-name tree) link)
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (prompt) (push prompt asked) (drgnx-coord-agent-register :id "ext:zed:9" :kind "zed" :cwd link) t)))
        (drgnx-cockpit-edits-revert-file "n2.txt")))
    (should (= 2 (length asked)))
    (should (file-exists-p (concat tree "n2.txt")))
    (should (equal (inbox) '("[revert] please undo your changes to README" "[revert] please undo your changes to n2.txt")))
    ;; and from then on it is a request without a question
    (drgnx-cockpit-edits-revert-file "README")
    (should (= 2 (length asked)))))

(ert-deftest drgnx-cockpit-edits/a-git-failure-never-deletes ()
  (drgnx-cockpit-edits-test--job
    (setq mirror (drgnx-agents--make :id "m-1" :remote "s-1" :name "claude · jx#2" :status 'exited))
    (drgnx-coord-force-status "jx#2" "done" "s-1")
    (drgnx-coord-agent-register :id "s-1" :base "0000000000000000000000000000000000000001")   ; no such commit
    (should-error (drgnx-cockpit-edits-revert-file "n2.txt") :type 'error)
    (should-error (drgnx-cockpit-edits-revert-file "README") :type 'error)
    (should-not asked)                                                   ; it failed before asking anything
    (should (file-exists-p (concat tree "n2.txt")))
    (should (equal (slurp (concat tree "README")) "readme\nby the job\n"))
    (should-not (drgnx-coord-events :agent "s-1" :kinds '("revert")))))

(ert-deftest drgnx-cockpit-edits/the-pane-is-no-diff-or-patch-buffer ()
  (drgnx-cockpit-edits-test--with drgnx-cockpit-edits-test--ext
    (let ((readme (lambda () (with-temp-buffer (insert-file-contents (concat wt-a "README")) (buffer-string))))
          (agent-path-p (lambda (x) (and (stringp x) (string-prefix-p (file-truename wt-a) (file-truename x))))))
      ;; text in special-mode, in a neutral folder; the agent's folder only in its own variable
      (should (derived-mode-p 'special-mode))
      (should-not (derived-mode-p 'diff-mode))
      (should (equal default-directory drgnx-cockpit-edits--neutral))
      (should (string-prefix-p temporary-file-directory default-directory))   ; under the fixture's temp folder
      (should (null (directory-files default-directory nil directory-files-no-dot-files-regexp)))
      (should (= #o700 (file-modes default-directory)))
      (should-not (funcall agent-path-p default-directory))
      (should (equal (plist-get drgnx-cockpit-edits--source :dir) wt-a))
      ;; its map: its own commands over special-mode's, nothing else
      (let ((special nil) (cmds nil))
        (cl-labels ((walk (map fn) (map-keymap (lambda (_ b)
                                                 (cond ((keymapp b) (walk b fn))
                                                       ((eq (car-safe b) 'menu-item)
                                                        (if (keymapp (nth 2 b)) (walk (nth 2 b) fn) (funcall fn (nth 2 b))))
                                                       ((symbolp b) (funcall fn b))))
                                               map)))
          (walk special-mode-map (lambda (c) (push c special)))
          (walk drgnx-cockpit-edits-mode-map (lambda (c) (push c cmds))))
        (should-not (keymapp (lookup-key drgnx-cockpit-edits-mode-map [menu-bar Diff])))
        (dolist (c (delete-dups cmds))
          (should (or (null c) (memq c special) (string-prefix-p "drgnx-cockpit-edits" (symbol-name c))))))
      ;; no other mode: M-x diff-mode (or any) is refused, the pane stays as it is
      (should-error (diff-mode) :type 'user-error)
      (should-error (fundamental-mode) :type 'user-error)
      (should (eq major-mode 'drgnx-cockpit-edits-mode))
      (should (equal drgnx-cockpit-edits--files '("README" "new.txt")))
      ;; VC finds nothing of the agent's here: C-x v u changes no file
      (drgnx-cockpit-edits-test--goto "README" "+more")
      (let ((fileset (condition-case nil (vc-deduce-fileset t) (error nil))))
        (should-not (seq-some agent-path-p (cadr fileset))))
      (cl-letf (((symbol-function 'yes-or-no-p) #'always) ((symbol-function 'y-or-n-p) #'always))
        (ignore-errors (call-interactively #'vc-revert)))
      (should (equal (funcall readme) "readme\nmore\n"))
      (should (equal (drgnx-cockpit-fixture-git wt-a "status" "--porcelain") "M README\n?? new.txt"))
      ;; ediff-patch-file has no file of the agent's to patch: it asks, from the neutral folder
      (require 'ediff)
      (let ((asked nil))
        (cl-letf (((symbol-function 'read-file-name) (lambda (&rest a) (push a asked) (error "Asked for a file"))))
          (ignore-errors (ediff-patch-file nil (current-buffer))))
        (should asked)
        (should-not (seq-some (lambda (a) (seq-some agent-path-p (cdr a))) asked)))
      (should (equal (funcall readme) "readme\nmore\n"))
      ;; RET opens the file, from the agent's folder, at the line the diff line stands for
      (set-buffer e)
      (drgnx-cockpit-edits-test--goto "README" "+more")
      (let ((pane (current-buffer)) (b nil))
        (save-window-excursion
          (setq b (drgnx-cockpit-edits-visit))
          (should (equal (buffer-file-name b) (file-truename (concat wt-a "README"))))   ; by its true name
          (should (= 2 (with-current-buffer b (line-number-at-pos)))))
        (kill-buffer b)
        (set-buffer pane))
      ;; TAB and S-TAB move by hunk
      (goto-char (point-min))
      (drgnx-cockpit-edits-next-hunk)
      (should (looking-at "@@ -1 \\+1,2 @@"))
      (drgnx-cockpit-edits-next-hunk)
      (should (looking-at "@@ -0,0 \\+1 @@"))
      (drgnx-cockpit-edits-previous-hunk)
      (should (looking-at "@@ -1 \\+1,2 @@"))
      (should-error (drgnx-cockpit-edits-previous-hunk) :type 'user-error))))

(ert-deftest drgnx-cockpit-edits/a-silent-worktree-takes-no-messages-and-shows-first-writes ()
  (drgnx-cockpit-edits-test--with (concat "silent:" (directory-file-name wt-b))
    ;; nobody reads messages there: said, nothing queued
    (should-error (drgnx-cockpit-edits-comment "b.txt" 1 "hi") :type 'user-error)
    (should-error (drgnx-cockpit-edits-revert-file "b.txt") :type 'user-error)
    (should (file-exists-p (concat wt-b "b.txt")))
    (should-not (drgnx-coord-events :kinds '("comment" "revert")))
    (should (string-match-p "a accept [·|] r revert [·|] c comment [·|] n/p files" (car header-line-format)))
    (let ((drgnx-cockpit-edits-check-interval 2)
          (check (lambda () (drgnx-cockpit-edits--check e) (drgnx-cockpit-edits-test--settle e))))
      ;; not its time yet: the check only looks at the store
      (setq drgnx-cockpit-edits--quiet-next (+ (float-time) 60))
      (drgnx-cockpit-edits--check e)
      (should-not drgnx-cockpit-edits--list-dirty)
      ;; a first write in a folder with no changes yet (nobody watches it) shows at the check's next listing, without g
      (drgnx-cockpit-fixture-write (concat wt-b "fresh/dir/f.txt") "f\n")
      (setq drgnx-cockpit-edits--quiet-next 0)
      (funcall check)
      (should (member "fresh/dir/f.txt" drgnx-cockpit-edits--files))
      (should-not drgnx-cockpit-edits--quiet-gap)                       ; it found something: the usual pace
      ;; listings that find nothing space out: 4, 8, then 10 s at most
      (dolist (gap '(4 8 10 10))
        (setq drgnx-cockpit-edits--quiet-next 0)
        (funcall check)
        (should (equal drgnx-cockpit-edits--quiet-gap gap))
        (should (> drgnx-cockpit-edits--quiet-next (+ (float-time) gap -1))))
      ;; any change heard of resets it
      (drgnx-cockpit-edits-test--notify wt-b "b.txt")
      (should-not drgnx-cockpit-edits--quiet-gap)
      (should (<= drgnx-cockpit-edits--quiet-next (+ (float-time) 2))))))

(load (expand-file-name "test/fixtures/handler-trap" drgnx-dir) nil t)

(ert-deftest drgnx-cockpit-edits/an-agents-folder-through-a-link-runs-no-file-name-handler ()
  ;; another agent's folder is the agent's to name: a link to a remote one is never inside, and never reaches Tramp
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-edits-links" t))) (wt (concat root "wt/")))
    (unwind-protect
        (progn
          (make-directory wt)
          (drgnx-test-hostile-paths wt)
          (drgnx-test-with-handler-trap
            (dolist (name '("abs-ssh" "abs-sudo" "up-ssh" "up-sudo" "gz" "gpg"))
              (should-not (drgnx-cockpit-edits--inside-p wt (concat wt name))))
            (should (drgnx-cockpit-edits--inside-p wt (concat wt "n.gz")))
            (should-not drgnx-test-handler-calls)))
      (delete-directory root t))))

(ert-deftest drgnx-cockpit-edits/a-file-is-opened-by-the-name-it-was-checked-by ()
  ;; a link out through `ssh:host:' and back into the agent's folder passes `drgnx-cockpit--file-ok' (resolved with no
  ;; handler, it is a regular file inside); opening the agent's name as written then made `find-file-noselect' follow
  ;; it with handlers on, into Tramp
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-edits-back" t))) (wt (concat root "wt/")))
    (unwind-protect
        (let* ((paths (progn (make-directory wt) (drgnx-test-hostile-paths wt))) (real (file-truename (plist-get paths :real))))
          (drgnx-test-with-handler-trap
            (let ((b (drgnx-test-visit 'cockpit "back" wt)))
              (unwind-protect (should (equal (buffer-file-name b) real)) (kill-buffer b)))
            (should-not drgnx-test-handler-calls)))
      (delete-directory root t))))

(ert-deftest drgnx-cockpit-edits/visiting-a-link-out-through-a-remote-name-never-loads-tramp ()
  ;; end to end, in an Emacs of its own (-Q, Tramp's handlers as shipped; reaching Tramp fails): every command that
  ;; opens an agent's or a model's name opens the linked file, and Tramp, jka-compr and EasyPG stay unloaded
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-edits-child" t))) (wt (concat root "wt/")))
    (unwind-protect
        (let* ((paths (progn (make-directory wt) (drgnx-test-hostile-paths wt)))
               (form `(progn
                        (with-eval-after-load 'tramp
                          (advice-add 'tramp-file-name-handler :override (lambda (&rest _) (error "Tramp was reached"))))
                        (load ,(expand-file-name "test/fixtures/handler-trap" drgnx-dir) nil t)
                        (require 'drgnx-review) (require 'drgnx-cockpit-edits) (require 'drgnx-diff) (require 'drgnx-work-ui)
                        (require 'drgnx-cockpit)
                        (let* ((loaded (lambda () (list (featurep 'tramp) (featurep 'jka-compr) (featurep 'epa-file))))
                               (before (funcall loaded))
                               (opened (mapcar (lambda (how)
                                                 (condition-case err
                                                     (let ((b (drgnx-test-visit how "back" ,wt)))
                                                       (prog1 (buffer-file-name b) (kill-buffer b)))
                                                   (error (error-message-string err))))
                                               '(review cockpit diff work work-graph cockpit-graph))))
                          (prin1 (list before opened (funcall loaded))))))
               (out (with-temp-buffer
                      (call-process (expand-file-name invocation-name invocation-directory) nil '(t nil) nil
                                    "-Q" "--batch" "-L" (expand-file-name "core" drgnx-dir) "-L" (expand-file-name "wb" drgnx-dir)
                                    "-L" (expand-file-name "modules/tools" drgnx-dir) "-L" (expand-file-name "modules/ui" drgnx-dir)
                                    "--eval" (prin1-to-string form))
                      (buffer-string)))
               (result (car (read-from-string out))))
          (should (equal (nth 0 result) '(nil nil nil)))
          (should (equal (nth 1 result) (make-list 6 (file-truename (plist-get paths :real)))))
          (should (equal (nth 2 result) '(nil nil nil))))
      (delete-directory root t))))

(ert-deftest drgnx-cockpit-edits/an-agents-names-are-watched-and-placed-with-no-file-name-handler ()
  ;; the folders of the agent's changed files, and the paths of its edit events, are its names: `a.zip/' reached
  ;; tramp-archive (gvfs mounts the agent's archive)
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-edits-watch" t))) (wt (concat root "wt/")))
    (unwind-protect
        (with-temp-buffer
          (make-directory (concat wt "a.zip") t)
          (setq drgnx-cockpit-edits--source (list :dir wt) drgnx-cockpit-edits--files '("a.zip/y")
                drgnx-cockpit-edits--watches (make-hash-table :test #'equal))
          (unwind-protect
              (drgnx-test-with-handler-trap
                (drgnx-cockpit-edits--update-watches)
                (should (equal (drgnx-cockpit-edits--event-paths (list :data (list :paths (list "a.zip/y" (concat wt "a.zip/z")))))
                               '("a.zip/y" "a.zip/z")))
                (should-not drgnx-test-handler-calls))
            (maphash (lambda (_ w) (ignore-errors (file-notify-rm-watch w))) drgnx-cockpit-edits--watches)))
      (delete-directory root t))))

;;; mod-cockpit-edits-test.el ends here
