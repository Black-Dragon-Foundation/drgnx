;;; agents-ui-test.el --- batch tests: transcripts, the Agents list, edit review -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-agents-ui" drgnx-dir) nil t)

(defconst drgnx-agents-ui-test--mock (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir))

(defun drgnx-agents-ui-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 10))) v)
    (while (and (not (setq v (funcall pred))) (< (float-time) deadline)) (accept-process-output nil 0.02))
    v))

(ert-deftest drgnx-agents-ui/a-transcript-shows-turns-tools-plans-and-what-waits ()
  (let ((s (drgnx-agents--make :name "mock · x" :status 'busy :queue '("later")
                               :entries (list '(:type user :text "do it")
                                              '(:type thought :text "hmm")
                                              (list :type 'tool :id "task1" :title "Task: explore" :status "completed"
                                                    :children (list '(:type tool :id "c1" :title "Grep" :status "completed")))
                                              '(:type plan :entries ((:content "Read" :status "completed") (:content "Test" :status "pending")))
                                              '(:type agent :text "Done."))
                               :permissions (list '(:id 7 :title "Run make" :options ((:optionId "a" :name "Allow") (:optionId "r" :name "Reject")))))))
    (with-temp-buffer
      (drgnx-agents-ui-render s)
      (let ((text (buffer-string)))
        (dolist (want '("▸ do it" "… hmm" "⚙ Task: explore [completed]" "  ⚙ Grep [completed]" "☑ Read" "☐ Test" "Done."
                        "? Run make" "[Allow]" "[Reject]" "working…" "1 queued"))
          (should (string-search want text)))))))

(ert-deftest drgnx-agents-ui/the-list-has-sessions-and-jobs ()
  (let* ((root (make-temp-file "drgnx-ui-jobs" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" root) process-environment))
         (drgnx-agents--sessions (list (drgnx-agents--make :name "mock · p" :status 'idle :queue '("a" "b") :paused t :via 'gateway))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "drgnx/jobs/20261017-000000-1" root) t)
          (with-temp-file (expand-file-name "drgnx/jobs/20261017-000000-1/job.eld" root)
            (prin1 '(:id "20261017-000000-1" :name "index" :launcher detached) (current-buffer)))
          (write-region "0" nil (expand-file-name "drgnx/jobs/20261017-000000-1/exit" root) nil 'silent)
          (let ((rows (mapcar #'cadr (drgnx-agents-ui--entries))))
            (should (equal (aref (car rows) 4) "gateway"))                 ; how its traffic goes
            (should (equal (aref (car rows) 5) "2 queued (paused)"))
            (should (equal (aref (cadr rows) 0) "job: index"))
            (should (equal (aref (cadr rows) 1) "exited"))))
      (delete-directory root t))))

(ert-deftest drgnx-agents-ui/last-active-column ()
  ;; Like Zed's agent list: how long ago each agent acted, from what the UI saw change.
  (let* ((now (drgnx-agents--make :id "n" :name "now" :status 'busy))
         (mins (drgnx-agents--make :id "m" :name "mins" :status 'idle))
         (hours (drgnx-agents--make :id "h" :name "hours" :status 'idle))
         (days (drgnx-agents--make :id "d" :name "days" :status 'idle))
         (never (drgnx-agents--make :id "x" :name "never" :status 'starting))
         (drgnx-agents--sessions (list now mins hours days never))
         (drgnx-agents-ui--last (make-hash-table :test #'eq :weakness 'key))
         (drgnx-agents-ui--jobs-cache (cons 1.0e+INF nil)))    ; no job directory is read
    (drgnx-agents-ui--changed now)                               ; what the UI hears records the time
    (should (numberp (drgnx-agents-ui-last-active now)))
    (puthash mins (- (float-time) 330) drgnx-agents-ui--last)
    (puthash hours (- (float-time) 7300) drgnx-agents-ui--last)
    (puthash days (- (float-time) (* 3 86400) 50) drgnx-agents-ui--last)
    (let ((last (mapcar (lambda (e) (aref (cadr e) 2)) (drgnx-agents-ui--entries))))
      (should (string-match-p "\\`[0-9]s\\'" (nth 0 last)))
      (should (equal (cdr last) '("5m" "2h" "3d" ""))))
    (should (equal (mapcar #'drgnx-agents-ui--ago '(0 59 60 3599 3600 86399 86400)) '("0s" "59s" "1m" "59m" "1h" "23h" "1d")))
    (with-current-buffer (drgnx-agents-ui-list-buffer)
      (unwind-protect (should (equal (car (aref tabulated-list-format 2)) "Last"))
        (kill-buffer)))))

(ert-deftest drgnx-agents-ui/an-agent-edit-is-reviewed-hunk-by-hunk ()
  ;; The agent proposes two changes (first line, a new last line); the user takes the first only.
  (let* ((dir (make-temp-file "drgnx-review" t))
         (file (expand-file-name "f.txt" dir))
         (drgnx-agents-profiles
          (list (list "mock" :command (list "sh" (expand-file-name "test/fixtures/mock-acp-stdin.sh" drgnx-dir) (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-l" drgnx-agents-ui-test--mock))))
         (drgnx-agents--sessions nil)
         (drgnx-agents-changed-functions nil))
    (write-region (mapconcat (lambda (i) (format "line %d" i)) (number-sequence 1 12) "\n") nil file nil 'silent)
    (write-region "\n" nil file t 'silent)
    (let ((s (drgnx-agents-start "mock" dir)))
      (unwind-protect
          (progn
            (should (drgnx-agents-ui-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle))))
            (drgnx-agents-send s (concat "write " file))
            (should (drgnx-agents-ui-test--wait (lambda () (drgnx-agent-session-reviews s))))
            (let ((b (drgnx-agents-ui-review s (car (drgnx-agent-session-reviews s)))))
              (with-current-buffer b
                (goto-char (point-min))
                (diff-hunk-next)
                (let ((inhibit-interaction t)) (diff-apply-hunk))   ; the first hunk only
                (drgnx-agents-ui-review-done)))
            (should (drgnx-agents-ui-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle))))
            (should (member "write done" (mapcar (lambda (e) (plist-get e :text))
                                                 (seq-filter (lambda (e) (eq (plist-get e :type) 'agent)) (drgnx-agent-session-entries s)))))
            (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
              (should (string-prefix-p "CHANGED line 1\n" text))
              (should-not (string-search "ADDED LINE" text))))
        (drgnx-agents-kill s)
        (when-let* ((b (find-buffer-visiting file))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))
        (delete-directory dir t)))))

(ert-deftest drgnx-agents-ui/every-command-is-registered ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (funcall (plist-get (alist-get 'tools/agents drgnx-modules--table) :setup))
    (dolist (id '(agents-view agents-new agents-send agents-stop agents-deliver agents-take-over agents-answer jobs-log jobs-stop agents-open agents-reply agents-review-done agents-review-reject
                              agents-new-durable))
      (should (drgnx-commands-get id)))))

(ert-deftest drgnx-agents-ui/hub-sessions-are-mirrored-only-when-a-hub-runs ()
  ;; at idle: never a wait (no ping), never a hub started — only a socket that is there is connected to
  (require 'drgnx-agents-mirror)
  (let* ((root (make-temp-file "drgnx-ui-mirror" t))
         (process-environment (append (list (concat "DRGNX_DATA_DIR=" root "/data") (concat "XDG_STATE_HOME=" root "/state")
                                            "XDG_RUNTIME_DIR")
                                      process-environment))
         (synced 0) (started 0))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-agents-mirror-sync) (lambda () (cl-incf synced)))
                  ((symbol-function 'drgnx-hub-ensure) (lambda () (cl-incf started)))
                  ((symbol-function 'drgnx-hub-running-p) (lambda () (error "no ping at idle"))))
          (drgnx-agents-ui--maybe-mirror)
          (should (= synced 0))
          (make-directory (file-name-directory (drgnx-hub-socket)) t)
          (write-region "" nil (drgnx-hub-socket) nil 'silent)
          (drgnx-agents-ui--maybe-mirror)
          (should (= synced 1))
          (should (= started 0)))
      (delete-directory root t))))

;;;; Review fixes (M7 final review)

(defmacro drgnx-agents-ui-test--reviewing (file content &rest body)
  "BODY with REVIEW the review buffer of an agent's proposed CONTENT for FILE (a fake session;
answers recorded in ANSWERS)."
  (declare (indent 2))
  `(let* ((answers nil)
          (s (drgnx-agents--make :name "fake" :cwd (file-name-directory ,file)))
          (item (list :id 5 :path ,file :content ,content)))
     (setf (drgnx-agent-session-reviews s) (list item))
     (cl-letf (((symbol-function 'drgnx-acp-respond) (lambda (_c id r &optional err) (push (list id r err) answers))))
       (let ((review (drgnx-agents-ui-review s item)))
         ,@body))))

(defun drgnx-agents-ui-test--lines (n) (concat (mapconcat (lambda (i) (format "line %d" i)) (number-sequence 1 n) "\n") "\n"))

(ert-deftest drgnx-agents-ui/reject-leaves-the-file-as-it-was ()
  ;; I2: hunks applied while reviewing are applied to a copy; Reject writes nothing.
  (let* ((dir (make-temp-file "drgnx-rev" t)) (f (expand-file-name "f.txt" dir)) (orig (drgnx-agents-ui-test--lines 12)))
    (write-region orig nil f nil 'silent)
    (drgnx-agents-ui-test--reviewing f (concat "CHANGED " (substring orig 0))
      (with-current-buffer review (goto-char (point-min)) (diff-hunk-next) (diff-apply-hunk) (drgnx-agents-ui-review-reject))
      (should (equal (with-temp-buffer (insert-file-contents f) (buffer-string)) orig))
      (should (nth 2 (car answers))))                                   ; the agent hears it was rejected
    (delete-directory dir t)))

(ert-deftest drgnx-agents-ui/an-agent-can-create-a-file-through-review ()
  ;; I1: a new file is written where the agent asked, not to a temp file.
  (let* ((dir (make-temp-file "drgnx-rev" t)) (f (expand-file-name "new/made.txt" dir)))
    (drgnx-agents-ui-test--reviewing f "hello\n"
      (with-current-buffer review (goto-char (point-min)) (diff-hunk-next) (diff-apply-hunk) (drgnx-agents-ui-review-done))
      (should (equal (with-temp-buffer (insert-file-contents f) (buffer-string)) "hello\n"))
      (should (equal (car answers) '(5 nil nil))))
    (delete-directory dir t)))

(ert-deftest drgnx-agents-ui/unsaved-edits-of-the-file-are-never-mixed-in ()
  (let* ((dir (make-temp-file "drgnx-rev" t)) (f (expand-file-name "f.txt" dir)))
    (write-region "a\n" nil f nil 'silent)
    (let ((b (find-file-noselect f)))
      (unwind-protect
          (progn
            (with-current-buffer b (goto-char (point-max)) (insert "mine\n"))
            (drgnx-agents-ui-test--reviewing f "b\n"
              (with-current-buffer review (should-error (drgnx-agents-ui-review-done) :type 'user-error))
              (should (equal (with-temp-buffer (insert-file-contents f) (buffer-string)) "a\n"))))
        (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
    (delete-directory dir t)))

(ert-deftest drgnx-agents-ui/closing-a-review-rejects-it ()
  (let* ((dir (make-temp-file "drgnx-rev" t)) (f (expand-file-name "f.txt" dir)))
    (write-region "a\n" nil f nil 'silent)
    (drgnx-agents-ui-test--reviewing f "b\n"
      (kill-buffer review)
      (should (nth 2 (car answers)))
      (should-not (drgnx-agent-session-reviews s)))
    (delete-directory dir t)))

(ert-deftest drgnx-agents-ui/a-transcript-has-stop-deliver-commands-and-queue-controls ()
  (let ((s (drgnx-agents--make :name "x" :status 'busy :queue '("one" "two") :paused nil
                               :commands '((:name "compact" :description "c") (:name "review" :description "r")))))
    (with-temp-buffer
      (drgnx-agents-ui-render s)
      (let ((text (buffer-string)))
        (dolist (want '("[Stop]" "/compact" "/review" "one [×]" "two [×]")) (should (string-search want text)))))
    (setf (drgnx-agent-session-status s) 'idle (drgnx-agent-session-paused s) t)
    (with-temp-buffer (drgnx-agents-ui-render s) (should (string-search "[Deliver]" (buffer-string))))))

(ert-deftest drgnx-agents-ui/the-list-reads-jobs-at-most-every-few-seconds ()
  ;; I9: the list redraws often while an agent streams; jobs are read on a slower cadence.
  (let ((calls 0) (drgnx-agents-ui--jobs-cache nil) (drgnx-agents--sessions nil))
    (cl-letf (((symbol-function 'drgnx-jobs-list) (lambda () (setq calls (1+ calls)) nil)))
      (drgnx-agents-ui--entries) (drgnx-agents-ui--entries) (drgnx-agents-ui--entries)
      (should (= calls 1)))))

(defun drgnx-agents-ui-test--fires ()
  "How many idle timers on the list are the timer layer's."
  (let ((n 0)) (dolist (tm timer-idle-list n) (when (eq (timer--function tm) #'drgnx-timer--fire) (setq n (1+ n))))))

(ert-deftest drgnx-agents-ui/the-mirror-timer-has-an-owner ()
  ;; B1: the 30 s repeat belongs to the module's setup, so a second setup (or a reload) cannot stack another.
  (let* ((state (make-temp-file "drgnx-agents-ui-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
         (drgnx-modules--table (list (assq 'tools/agents drgnx-modules--table)))
         (drgnx-modules--report nil) (drgnx-modules--stacks nil) (drgnx-modules--runs nil) (drgnx-modules--features nil)
         (setup (plist-get (cdar drgnx-modules--table) :setup)))
    (unwind-protect
        (drgnx-test-with-clock (:allow-pending t)
          (dotimes (_ 3)
            (should-not (drgnx-modules--run-setup 'tools/agents setup))
            (drgnx-modules--record 'tools/agents 'startup 0 'ok)
            (should (drgnx-timer-active-p 'agents-ui-mirror))
            (should (drgnx-timer-active-p 'agents-ui-mirror-first))     ; the first look, 3 s into the first pause
            (should (drgnx-timer-active-p 'agents-ui-tick))             ; the list's 30 s tick is the layer's, too
            (should (= 2 (drgnx-agents-ui-test--fires)))
            (should-not (drgnx-module-teardown 'tools/agents))
            (should-not (drgnx-timer-active-p 'agents-ui-mirror))
            (should-not (drgnx-timer-active-p 'agents-ui-tick))
            (should (= 0 (drgnx-agents-ui-test--fires)))
            (should (= 0 (drgnx-timer-cancel-owner 'tools/agents))))
          ;; the 30 s idle repeat is unchanged: once per pause
          (should-not (drgnx-modules--run-setup 'tools/agents setup))
          (let ((idle (seq-find (lambda (tm) (and (eq (timer--function tm) #'drgnx-timer--fire) (timer--repeat-delay tm)))
                                timer-idle-list)))
            (should idle)
            (should (= 30 (float-time (timer--time idle))))
            (should (timer--repeat-delay idle)))
          (drgnx-module-teardown 'tools/agents)
          (mapc #'cancel-timer (append timer-list timer-idle-list)))
      (delete-directory state t))))

;;;; The transcript on a view (PERF-H1): what streams in is appended to its row, never drawn whole

(load (expand-file-name "test/fixtures/view-fixture" drgnx-dir) nil t)

(defvar drgnx-agents-ui-test--n 0 "Makes each test's session name (and so its transcript buffer) new.")

(defmacro drgnx-agents-ui-test--with-transcript (spec &rest body)
  "SPEC: (S BUFFER VIEW &rest SESSION-ARGS).  BODY on the virtual clock with tools/agents set up (torn down after),
S a session made with SESSION-ARGS (no agent runs), BUFFER its transcript, drawn and shown in the only window and
current, VIEW its view."
  (declare (indent 1))
  (let ((s (nth 0 spec)) (buffer (nth 1 spec)) (view (nth 2 spec)))
    `(let* ((state (make-temp-file "drgnx-agents-ui-state" t))
            (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
            (drgnx-modules--table (list (assq 'tools/agents drgnx-modules--table)))
            (drgnx-modules--report nil) (drgnx-modules--stacks nil) (drgnx-modules--runs nil) (drgnx-modules--features nil)
            (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
            (drgnx-agents-ui--last (make-hash-table :test #'eq :weakness 'key))
            (drgnx-view--deadline nil)
            (config (current-window-configuration))
            (,s (drgnx-agents--make :name (format "view-test %d" (cl-incf drgnx-agents-ui-test--n)) ,@(nthcdr 3 spec)))
            (,buffer nil) (,view nil))
       (unwind-protect
           (drgnx-test-with-clock (:allow-pending t)
             (should-not (drgnx-modules--run-setup 'tools/agents (plist-get (cdar drgnx-modules--table) :setup)))
             (drgnx-modules--record 'tools/agents 'startup 0 'ok)
             (delete-other-windows)
             (setq ,buffer (drgnx-agents-ui-transcript-buffer ,s))
             (set-window-buffer (selected-window) ,buffer)
             (should (drgnx-view-type-p 'agent-transcript))
             (setq ,view (buffer-local-value 'drgnx-view ,buffer))
             (should (drgnx-view-p ,view))
             (with-current-buffer ,buffer ,@body))
         (drgnx-module-teardown 'tools/agents)
         (set-window-configuration config)
         (when (buffer-live-p ,buffer) (kill-buffer ,buffer))
         (delete-directory state t)))))

(defun drgnx-agents-ui-test--chunk (s text)
  "What the agent's process filter does with an `agent_message_chunk' of TEXT for S."
  (drgnx-agents--update s (list :sessionUpdate "agent_message_chunk" :content (list :type "text" :text text))))

(defun drgnx-agents-ui-test--draw ()
  "Let the view's timer draw (its throttle is 0.1 s)."
  (drgnx-test-advance 0.2))

(defun drgnx-agents-ui-test--fresh (s)
  "Session S's transcript rendered fresh, without properties."
  (with-temp-buffer (drgnx-agents-ui-render s) (buffer-substring-no-properties (point-min) (point-max))))

(defun drgnx-agents-ui-test--text (buffer)
  (with-current-buffer buffer (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max)))))

(defun drgnx-agents-ui-test--stat (view name) (plist-get (drgnx-view-stats view) name))

(defun drgnx-agents-ui-test--compile ()
  "Byte-compile the view library's and this module's functions in place: an interpreted call conses."
  (drgnx-view-test--compile-library)
  (mapatoms (lambda (s)
              (when (and (fboundp s) (string-prefix-p "drgnx-agents-ui-" (symbol-name s))
                         (not (string-prefix-p "drgnx-agents-ui-test" (symbol-name s)))
                         (functionp (symbol-function s)) (not (compiled-function-p (symbol-function s))))
                (let ((byte-compile-warnings nil)) (byte-compile s))))))

(ert-deftest drgnx-agents-ui/thousand-chunks-insert-only-their-text ()
  (drgnx-agents-ui-test--with-transcript (s b v :status 'busy
                                            :entries (list (list :type 'user :text "go") (list :type 'agent :text "Start. ")))
    (let ((drawn (drgnx-agents-ui-test--stat v :rows-drawn)) (grown (drgnx-agents-ui-test--stat v :rows-grown))
          (before (drgnx-agents-ui-test--text b)))
      (drgnx-agents-ui-test--chunk s (make-string 100 ?a))
      (should (equal before (drgnx-agents-ui-test--text b)))           ; the filter's hook only marks
      (drgnx-agents-ui-test--draw)
      (dotimes (i 999)
        (drgnx-agents-ui-test--chunk s (make-string 100 (+ ?a (% (1+ i) 26))))
        (drgnx-agents-ui-test--draw))
      (should (= drawn (drgnx-agents-ui-test--stat v :rows-drawn)))    ; no row rendered again
      (should (= 1000 (- (drgnx-agents-ui-test--stat v :rows-grown) grown)))
      (should (equal (drgnx-agents-ui-test--fresh s) (drgnx-agents-ui-test--text b)))
      (should-not (drgnx-view--check v))
      (should (eq t buffer-undo-list)))))

(defun drgnx-agents-ui-test--grow-alloc (size)
  "What one draw that grows a SIZE-character `agent' entry by 100 characters allocates (byte-compiled; the least of
three runs after two warm ones)."
  (let (best)
    (drgnx-agents-ui-test--with-transcript (s b v :status 'busy
                                              :entries (list (list :type 'agent :text (concat "é" (make-string size ?a)))))
      (drgnx-agents-ui-test--compile)
      (let ((e (car (drgnx-agent-session-entries s))))
        (dotimes (i 5)
          (drgnx-agents--append-text s 'agent (make-string 100 ?b))
          (drgnx-view-touch v)
          (let* ((a (memory-use-counts)) (_ (drgnx-view-draw-now v)) (z (memory-use-counts))
                 (d (apply #'+ (cl-mapcar #'- z a))))
            (when (>= i 2) (setq best (if best (min best d) d)))))
        (should (equal (drgnx-agents-ui-test--fresh s) (drgnx-agents-ui-test--text b)))))
    best))

(ert-deftest drgnx-agents-ui/grow-allocation-is-independent-of-size ()
  (let ((small (drgnx-agents-ui-test--grow-alloc 4096)) (big (drgnx-agents-ui-test--grow-alloc 409600)))
    (message "grow draw allocation: 4 kB entry %d, 400 kB entry %d" small big)
    (should (<= big (ceiling (* 1.25 small))))))

(ert-deftest drgnx-agents-ui/a-hidden-transcript-costs-nothing ()
  (drgnx-agents-ui-test--with-transcript (s b v :status 'busy :entries (list (list :type 'agent :text "a")))
    (let ((other (get-buffer-create " *drgnx-agents-ui-other*"))
          (drawn (drgnx-agents-ui-test--stat v :rows-drawn)) (grown (drgnx-agents-ui-test--stat v :rows-grown)))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) other)
            (dotimes (_ 100)                                           ; 50 a second
              (drgnx-agents-ui-test--chunk s (make-string 100 ?y))
              (drgnx-test-advance 0.02))
            (should (= drawn (drgnx-agents-ui-test--stat v :rows-drawn)))
            (should (= grown (drgnx-agents-ui-test--stat v :rows-grown)))
            (should (> (drgnx-agents-ui-test--stat v :stale-skips) 0))
            (drgnx-agents-ui-test--compile)
            (should (= 0 (drgnx-view-test--alloc (lambda () (drgnx-view--draw-buffer b)))))
            ;; shown again: one catch-up draw
            (set-window-buffer (selected-window) b)
            (drgnx-view--buffer-shown (selected-window))                 ; what redisplay runs
            (let ((slices (drgnx-agents-ui-test--stat v :slices)))
              (drgnx-agents-ui-test--draw)
              (should (= (1+ slices) (drgnx-agents-ui-test--stat v :slices)))
              (should (= 1 (- (drgnx-agents-ui-test--stat v :rows-grown) grown)))
              (should (= drawn (drgnx-agents-ui-test--stat v :rows-drawn)))
              (should (equal (drgnx-agents-ui-test--fresh s) (drgnx-agents-ui-test--text b)))))
        (kill-buffer other)))))

(ert-deftest drgnx-agents-ui/a-tool-status-change-redraws-one-row ()
  (drgnx-agents-ui-test--with-transcript (s b v :status 'busy
                                            :entries (list (list :type 'user :text "go")
                                                           (list :type 'tool :id "t1" :title "Task" :status "pending")
                                                           (list :type 'agent :text "hm")))
    (let ((drawn (drgnx-agents-ui-test--stat v :rows-drawn)))
      ;; the entry changes in place (the list of entries is the same): its row, and only it, is drawn again
      (drgnx-agents--update s '(:sessionUpdate "tool_call_update" :toolCallId "t1" :status "completed"))
      (drgnx-agents-ui-test--draw)
      (should (= 1 (- (drgnx-agents-ui-test--stat v :rows-drawn) drawn)))
      (should (string-search "⚙ Task [completed]" (drgnx-agents-ui-test--text b)))
      ;; a subagent's call, then its status: the parent's row each time
      (drgnx-agents--update s '(:sessionUpdate "tool_call" :toolCallId "c1" :title "Grep" :status "pending"
                                               :_meta (:parentToolCallId "t1")))
      (drgnx-agents-ui-test--draw)
      (should (= 2 (- (drgnx-agents-ui-test--stat v :rows-drawn) drawn)))
      (drgnx-agents--update s '(:sessionUpdate "tool_call_update" :toolCallId "c1" :status "completed"))
      (drgnx-agents-ui-test--draw)
      (should (= 3 (- (drgnx-agents-ui-test--stat v :rows-drawn) drawn)))
      (should (string-search "  ⚙ Grep [completed]" (drgnx-agents-ui-test--text b)))
      (should (equal (drgnx-agents-ui-test--fresh s) (drgnx-agents-ui-test--text b))))))

(ert-deftest drgnx-agents-ui/a-permission-adds-and-removes-a-footer-row ()
  (drgnx-agents-ui-test--with-transcript (s b v :status 'busy :entries (list (list :type 'agent :text "a")))
    (let ((rows (drgnx-view-row-count v)) (drawn (drgnx-agents-ui-test--stat v :rows-drawn))
          (removed (drgnx-agents-ui-test--stat v :removed))
          (p (list :id 7 :title "Run make" :options '((:optionId "a" :name "Allow")))))
      (setf (drgnx-agent-session-permissions s) (list p))
      (drgnx-agents--changed s)
      (drgnx-agents-ui-test--draw)
      (should (= (1+ rows) (drgnx-view-row-count v)))
      (should (= 1 (- (drgnx-agents-ui-test--stat v :rows-drawn) drawn)))
      (should (string-search "? Run make  [Allow]" (drgnx-agents-ui-test--text b)))
      (should (equal (drgnx-agents-ui-test--fresh s) (drgnx-agents-ui-test--text b)))
      (setf (drgnx-agent-session-permissions s) nil)                   ; answered
      (drgnx-agents--changed s)
      (drgnx-agents-ui-test--draw)
      (should (= rows (drgnx-view-row-count v)))
      (should (= 1 (- (drgnx-agents-ui-test--stat v :rows-drawn) drawn)))
      (should (= 1 (- (drgnx-agents-ui-test--stat v :removed) removed)))
      (should (equal (drgnx-agents-ui-test--fresh s) (drgnx-agents-ui-test--text b))))))

(ert-deftest drgnx-agents-ui/answering-the-second-permission-removes-its-row ()
  ;; `delq' of an item that is not first keeps the list's head: only its length tells
  (drgnx-agents-ui-test--with-transcript (s b v :status 'busy :entries (list (list :type 'agent :text "a")))
    (let ((p1 (list :id 7 :title "Run make" :options '((:optionId "a" :name "Allow"))))
          (p2 (list :id 8 :title "Run tests" :options '((:optionId "a" :name "Allow"))))
          (r1 (list :id 9 :path "/tmp/a.txt" :content "x\n")) (r2 (list :id 10 :path "/tmp/b.txt" :content "y\n")))
      (setf (drgnx-agent-session-permissions s) (list p1 p2) (drgnx-agent-session-reviews s) (list r1 r2))
      (drgnx-agents--changed s)
      (drgnx-agents-ui-test--draw)
      (should (string-search "? Run tests" (drgnx-agents-ui-test--text b)))
      (let ((removed (drgnx-agents-ui-test--stat v :removed)))
        (cl-letf (((symbol-function 'drgnx-acp-respond) #'ignore))
          (drgnx-agents-answer-permission s p2 "a")
          (drgnx-agents-ui-test--draw)
          (should (= 1 (- (drgnx-agents-ui-test--stat v :removed) removed)))
          (should-not (string-search "Run tests" (drgnx-agents-ui-test--text b)))
          (drgnx-agents-finish-review s r2 t)
          (drgnx-agents-ui-test--draw))
        (should (= 2 (- (drgnx-agents-ui-test--stat v :removed) removed)))
        (should-not (string-search "b.txt" (drgnx-agents-ui-test--text b)))
        (should (equal (drgnx-agents-ui-test--fresh s) (drgnx-agents-ui-test--text b)))))))

(ert-deftest drgnx-agents-ui/an-edited-queued-message-is-redrawn ()
  ;; `drgnx-agents-requeue' replaces the text in place: the queue is the same list
  (drgnx-agents-ui-test--with-transcript (s b v :status 'busy :queue (list "one" "two")
                                            :entries (list (list :type 'agent :text "a")))
    (should (string-search "  two [×]" (drgnx-agents-ui-test--text b)))
    (drgnx-agents-requeue s 1 "TWO, edited")
    (drgnx-agents-ui-test--draw)
    (should (string-search "  TWO, edited [×]" (drgnx-agents-ui-test--text b)))
    (should (equal (drgnx-agents-ui-test--fresh s) (drgnx-agents-ui-test--text b)))))

(ert-deftest drgnx-agents-ui/a-steer-removed-from-the-entries-removes-its-row ()
  (drgnx-agents-ui-test--with-transcript (s b v :status 'busy
                                            :entries (list (list :type 'user :text "go") (list :type 'agent :text "a")))
    (let ((steer (list :type 'user :text "also this" :steer t)))
      (drgnx-agents--add s steer)
      (drgnx-agents--changed s)
      (drgnx-agents-ui-test--draw)
      (should (string-search "↪ also this" (drgnx-agents-ui-test--text b)))
      (let ((removed (drgnx-agents-ui-test--stat v :removed)) (head (drgnx-agent-session-entries s)))
        ;; as a refused steer does (drgnx-agents.el): `delq' keeps the list's head, only its length changes
        (setf (drgnx-agent-session-entries s) (delq steer (drgnx-agent-session-entries s)))
        (should (eq head (drgnx-agent-session-entries s)))
        (drgnx-agents--changed s)
        (drgnx-agents-ui-test--draw)
        (should (= 1 (- (drgnx-agents-ui-test--stat v :removed) removed)))
        (should-not (string-search "also this" (drgnx-agents-ui-test--text b)))
        (should (equal (drgnx-agents-ui-test--fresh s) (drgnx-agents-ui-test--text b)))))))

(ert-deftest drgnx-agents-ui/the-tail-is-followed ()
  (drgnx-agents-ui-test--with-transcript (s b v :status 'busy :entries (list (list :type 'agent :text "a")))
    (goto-char (point-max))
    (set-window-point (selected-window) (point-max))
    (dotimes (_ 5) (drgnx-agents-ui-test--chunk s "more text\n") (drgnx-agents-ui-test--draw))
    (drgnx-agents--update s '(:sessionUpdate "tool_call" :toolCallId "t9" :title "Read" :status "pending"))
    (drgnx-agents-ui-test--chunk s "after the tool")
    (drgnx-agents-ui-test--draw)
    (should (string-search "after the tool" (drgnx-agents-ui-test--text b)))
    (should (= (point) (point-max)))
    (should (= (window-point (selected-window)) (point-max)))))

(ert-deftest drgnx-agents-ui/a-reader-scrolled-up-stays-put ()
  (drgnx-agents-ui-test--with-transcript (s b v :status 'busy
                                            :entries (list (list :type 'user :text "go")
                                                           (list :type 'agent :text "line\nline\nline\n" :done t)
                                                           (list :type 'agent :text "b")))
    (let* ((e (nth 1 (drgnx-agent-session-entries s))) (start (drgnx-view-row-start v e)))
      (set-window-start (selected-window) start)
      (goto-char (+ start 3))
      (set-window-point (selected-window) (+ start 3))
      (dotimes (_ 10) (drgnx-agents-ui-test--chunk s (make-string 100 ?z)) (drgnx-agents-ui-test--draw))
      ;; and a row above it: the agent's commands come
      (drgnx-agents--update s '(:sessionUpdate "available_commands_update" :availableCommands ((:name "compact"))))
      (drgnx-agents-ui-test--draw)
      (should (> (drgnx-view-row-start v e) start))
      (should (= (window-start (selected-window)) (drgnx-view-row-start v e)))
      (should (= (window-point (selected-window)) (+ (drgnx-view-row-start v e) 3)))
      (should (equal (drgnx-agents-ui-test--fresh s) (drgnx-agents-ui-test--text b))))))

(ert-deftest drgnx-agents-ui/g-redraws-now ()
  (drgnx-agents-ui-test--with-transcript (s b v :status 'busy :entries (list (list :type 'agent :text "a")))
    (let ((other (get-buffer-create " *drgnx-agents-ui-other*")))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) other)                  ; hidden: `g' draws anyway
            (plist-put (car (drgnx-agent-session-entries s)) :text "a and more")   ; no hook ran
            (setf (drgnx-agent-session-status s) 'idle)
            (revert-buffer)
            (should (equal "a and more\n\n" (drgnx-agents-ui-test--text b)))
            (should (equal (drgnx-agents-ui-test--fresh s) (drgnx-agents-ui-test--text b)))
            (should-not (drgnx-view-pending-p v)))
        (kill-buffer other)))))

;;;; The Agents list on a view: updated in place from its SYNC, drawn only while shown

(defmacro drgnx-agents-ui-test--with-list (spec &rest body)
  "SPEC: (SESSIONS BUFFER).  BODY on the virtual clock with tools/agents set up (torn down after), the sessions
\(`drgnx-agents--sessions') made from SESSIONS (a list of (NAME . ARGS)), BUFFER the Agents list, drawn and shown in
the only window and current.  The hub mirror does nothing."
  (declare (indent 1))
  (let ((names (nth 0 spec)) (buffer (nth 1 spec)))
    `(let* ((state (make-temp-file "drgnx-agents-ui-state" t))
            (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
            (drgnx-modules--table (list (assq 'tools/agents drgnx-modules--table)))
            (drgnx-modules--report nil) (drgnx-modules--stacks nil) (drgnx-modules--runs nil) (drgnx-modules--features nil)
            (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
            (drgnx-agents-ui--last (make-hash-table :test #'eq :weakness 'key))
            (drgnx-agents-ui--jobs-cache (cons 1.0e+INF nil))
            (drgnx-agents--sessions (mapcar (lambda (e) (apply #'drgnx-agents--make :name (car e) (cdr e))) ,names))
            (drgnx-view--deadline nil)
            (config (current-window-configuration))
            (,buffer nil))
       (unwind-protect
           (cl-letf (((symbol-function 'drgnx-agents-ui--maybe-mirror) #'ignore))
             (drgnx-test-with-clock (:allow-pending t)
               (should-not (drgnx-modules--run-setup 'tools/agents (plist-get (cdar drgnx-modules--table) :setup)))
               (drgnx-modules--record 'tools/agents 'startup 0 'ok)
               (delete-other-windows)
               (setq ,buffer (drgnx-agents-ui-list-buffer))
               (set-window-buffer (selected-window) ,buffer)
               (should (drgnx-view-p (buffer-local-value 'drgnx-view ,buffer)))
               (with-current-buffer ,buffer ,@body)))
         (drgnx-module-teardown 'tools/agents)
         (set-window-configuration config)
         (when (buffer-live-p ,buffer) (kill-buffer ,buffer))
         (delete-directory state t)))))

(defun drgnx-agents-ui-test--line-of (session)
  "The start of SESSION's line in the current Agents list."
  (save-excursion (goto-char (point-min))
                  (let (found)
                    (while (and (not found) (not (eobp)))
                      (if (eq (get-text-property (point) 'tabulated-list-id) session) (setq found (point)) (forward-line 1)))
                    found)))

(defun drgnx-agents-ui-test--body ()
  "The current Agents list without its first line (the column titles)."
  (buffer-substring (overlay-end tabulated-list--header-overlay) (point-max)))

(defun drgnx-agents-ui-test--set-status (s status)
  "What the agent's process filter does when S changes status."
  (setf (drgnx-agent-session-status s) status)
  (run-hook-with-args 'drgnx-agents-changed-functions s))

(ert-deftest drgnx-agents-ui/the-list-updates-in-place ()
  (drgnx-agents-ui-test--with-list ('(("a" :status idle) ("b" :status idle) ("c" :status idle)) b)
    (let* ((v drgnx-view) (sa (nth 0 drgnx-agents--sessions)) (sb (nth 1 drgnx-agents--sessions))
           (sc (nth 2 drgnx-agents--sessions))
           (entry (lambda (s) (get-text-property (drgnx-agents-ui-test--line-of s) 'tabulated-list-entry)))
           (a (funcall entry sa)) (bb (funcall entry sb)) (c (funcall entry sc)))
      (should (string-match-p "\\`a +idle" (drgnx-agents-ui-test--body)))
      (should (= 3 (length (split-string (string-trim-right (drgnx-agents-ui-test--body)) "\n"))))
      (drgnx-agents-ui-test--set-status sb 'busy)
      (should (drgnx-view-pending-p v))
      (should (string-match-p "b +idle" (buffer-string)))             ; marked: nothing drawn yet
      (drgnx-test-advance 0.2)
      (should (string-match-p "b +busy" (buffer-string)))
      (should (string-match-p "a +idle" (buffer-string)))
      ;; the lines of the other sessions are the same objects, not drawn again
      (should (eq a (funcall entry sa)))
      (should (eq c (funcall entry sc)))
      (should-not (eq bb (funcall entry sb)))
      (should (= 3 (length (split-string (string-trim-right (drgnx-agents-ui-test--body)) "\n"))))
      (should-not (drgnx-view--check v)))))

(ert-deftest drgnx-agents-ui/the-list-keeps-each-window-on-its-session ()
  (drgnx-agents-ui-test--with-list ('(("a" :status idle) ("b" :status idle) ("c" :status idle)) b)
    (let* ((w1 (split-window)) (w2 (split-window)) (sa (nth 0 drgnx-agents--sessions))
           (sb (nth 1 drgnx-agents--sessions)) (sc (nth 2 drgnx-agents--sessions)))
      (set-window-buffer w1 b)
      (set-window-buffer w2 b)
      (set-window-point w1 (+ 3 (drgnx-agents-ui-test--line-of sb)))
      (set-window-point w2 (drgnx-agents-ui-test--line-of sc))
      (goto-char (drgnx-agents-ui-test--line-of sa))     ; the selected window's point
      ;; a new session joins at the head: every line moves down; and one ages
      (let ((new (drgnx-agents--make :name "new" :status 'idle)))
        (push new drgnx-agents--sessions)
        (puthash sb (- (float-time) 400) drgnx-agents-ui--last)
        (run-hook-with-args 'drgnx-agents-changed-functions new))
      (drgnx-test-advance 0.2)
      (should (string-match-p "\\`new" (drgnx-agents-ui-test--body)))
      (should (string-match-p "6m" (buffer-string)))
      (should (= (window-point w1) (+ 3 (drgnx-agents-ui-test--line-of sb))))
      (should (= (window-point w2) (drgnx-agents-ui-test--line-of sc)))
      (should (= (point) (drgnx-agents-ui-test--line-of sa))))))

(ert-deftest drgnx-agents-ui/the-list-follows-removals-and-reorders ()
  (drgnx-agents-ui-test--with-list ('(("a" :status idle) ("b" :status idle) ("c" :status idle) ("d" :status idle)) b)
    (let* ((v drgnx-view) (all drgnx-agents--sessions) (sa (nth 0 all)) (sb (nth 1 all)) (sc (nth 2 all))
           (sd (nth 3 all)) (c-line (get-text-property (drgnx-agents-ui-test--line-of sc) 'tabulated-list-entry))
           (names (lambda () (mapcar (lambda (l) (car (split-string l))) (split-string (string-trim-right (drgnx-agents-ui-test--body)) "\n")))))
      (should (equal '("a" "b" "c" "d") (funcall names)))
      ;; b goes: the other lines are not touched
      (setq drgnx-agents--sessions (list sa sc sd))
      (run-hook-with-args 'drgnx-agents-changed-functions sb)
      (drgnx-test-advance 0.2)
      (should (equal '("a" "c" "d") (funcall names)))
      (should (eq c-line (get-text-property (drgnx-agents-ui-test--line-of sc) 'tabulated-list-entry)))
      (should-not (buffer-modified-p))
      ;; d moves to the front (the lines between are printed again, in the new order)
      (setq drgnx-agents--sessions (list sd sa sc))
      (run-hook-with-args 'drgnx-agents-changed-functions sd)
      (drgnx-test-advance 0.2)
      (should (equal '("d" "a" "c") (funcall names)))
      (should-not (buffer-modified-p))
      (should-not (drgnx-view--check v))
      ;; and everything goes
      (setq drgnx-agents--sessions nil)
      (run-hook-with-args 'drgnx-agents-changed-functions sa)
      (drgnx-test-advance 0.2)
      (should (string-prefix-p "No agent sessions yet" (drgnx-agents-ui-test--body))))))

(ert-deftest drgnx-agents-ui/a-hidden-list-prints-nothing ()
  (drgnx-agents-ui-test--with-list ('(("a" :status idle) ("b" :status idle)) b)
    (let* ((v drgnx-view) (sb (nth 1 drgnx-agents--sessions)) (other (get-buffer-create " *drgnx-agents-ui-other*"))
           (text (buffer-string)) (tick (buffer-modified-tick)))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) other)
            (drgnx-agents-ui-test--set-status sb 'busy)
            (drgnx-test-advance 0.2)
            (should (equal text (buffer-string)))
            (should (= tick (buffer-modified-tick)))
            (should (drgnx-view--stale v))
            (drgnx-test-advance 30)                           ; the 30 s tick prints nothing either
            (should (= tick (buffer-modified-tick)))
            (should (= 0 (drgnx-view-test--alloc (lambda () (drgnx-view--draw-buffer b)))))
            ;; shown again: the list is drawn
            (set-window-buffer (selected-window) b)
            (drgnx-view--buffer-shown (selected-window))      ; what redisplay runs
            (drgnx-test-advance 0.2)
            (should (string-match-p "b +busy" (buffer-string))))
        (kill-buffer other)))))

(ert-deftest drgnx-agents-ui/last-ages-on-a-30-second-tick ()
  ;; The tick is the layer's (key `agents-ui-tick', the module's); it marks the list's view, which prints only
  ;; while shown, each window on its row.
  (drgnx-agents-ui-test--with-list ('(("a" :status idle) ("b" :status idle)) b)
    (let ((sb (nth 1 drgnx-agents--sessions)))
      (should (drgnx-timer-active-p 'agents-ui-tick))
      (puthash sb (- (float-time) 20) drgnx-agents-ui--last)
      (set-window-point (selected-window) (drgnx-agents-ui-test--line-of sb))
      (drgnx-test-advance 20)                                 ; 40 s old now, but nothing marked the list yet
      (should (string-match-p "\\`a +idle" (drgnx-agents-ui-test--body)))
      (drgnx-test-advance 15)                                 ; the tick at 30 s
      (should (string-match-p "b +idle +[345][0-9]s" (buffer-string)))
      (should (= (window-point) (drgnx-agents-ui-test--line-of sb))))))

;;;; The column titles are the first line; an empty list says how to start

(ert-deftest drgnx-agents-ui/the-column-titles-are-the-first-line ()
  (drgnx-agents-ui-test--with-list ('(("a" :status idle) ("b" :status idle)) b)
    (let ((titles (buffer-substring (point-min) (overlay-end tabulated-list--header-overlay))))
      (should-not header-line-format)                        ; the dock's tab strip has the header line
      (should (string-match-p "\\` Name Status Last Ctx Via Waiting \n\\'" titles))
      (should (eq 'drgnx-agents-ui-header (overlay-get tabulated-list--header-overlay 'face)))
      (should (eq 'header-line (face-attribute 'drgnx-agents-ui-header :inherit nil)))   ; the theme's face
      (should-not (get-text-property (point-min) 'tabulated-list-id))
      (should (>= (point) (overlay-end tabulated-list--header-overlay)))   ; the cursor is on a session, not the titles
      (should (>= (window-point) (overlay-end tabulated-list--header-overlay)))
      ;; the updater keeps the titles through every kind of update, and never takes them for a session line
      (let ((sa (nth 0 drgnx-agents--sessions)) (sb (nth 1 drgnx-agents--sessions)))
        (drgnx-agents-ui-test--set-status sb 'busy)
        (drgnx-test-advance 0.2)
        (should (string-prefix-p titles (buffer-string)))
        (should (string-match-p "b +busy" (drgnx-agents-ui-test--body)))
        (setq drgnx-agents--sessions (list sb sa))             ; a reorder
        (run-hook-with-args 'drgnx-agents-changed-functions sa)
        (drgnx-test-advance 0.2)
        (should (string-prefix-p titles (buffer-string)))
        (should (string-match-p "\\`b +busy.*\na +idle" (drgnx-agents-ui-test--body)))
        (should (= 1 (how-many "^ Name " (point-min) (point-max))))
        (setq drgnx-agents--sessions nil)                      ; all gone
        (run-hook-with-args 'drgnx-agents-changed-functions sa)
        (drgnx-test-advance 0.2)
        (should (string-prefix-p titles (buffer-string)))
        (should-not (drgnx-view--check drgnx-view))
        (should-not (buffer-modified-p))))))

(ert-deftest drgnx-agents-ui/an-empty-list-says-how-to-start ()
  (cl-letf (((symbol-function 'drgnx-agents-ui--claude-needs) #'ignore))
    (drgnx-agents-ui-test--with-list (nil b)
      (let ((body (drgnx-agents-ui-test--body)))
        (should (string-match-p "No agent sessions yet" (replace-regexp-in-string "\n" " " body)))
        (should (string-match-p "New Agent Session…" (replace-regexp-in-string "\n" " " body)))
        (should (string-match-p "palette" body))
        (should-not (string-match-p "Claude needs" body))
        ;; printing again with the same state changes nothing
        (let ((tick (buffer-modified-tick)))
          (drgnx-view-touch drgnx-view)
          (drgnx-test-advance 0.2)
          (should (= tick (buffer-modified-tick))))
        ;; a session replaces the hint; none again brings it back
        (setq drgnx-agents--sessions (list (drgnx-agents--make :name "a" :status 'idle)))
        (run-hook-with-args 'drgnx-agents-changed-functions (car drgnx-agents--sessions))
        (drgnx-test-advance 0.2)
        (should-not (string-search "No agent sessions" (buffer-string)))
        (should (string-match-p "\\`a +idle +[0-9]+s +\n\\'" (drgnx-agents-ui-test--body)))
        (setq drgnx-agents--sessions nil)
        (drgnx-view-touch drgnx-view)
        (drgnx-test-advance 0.2)
        (should (string-search "No agent sessions" (buffer-string)))))))

(ert-deftest drgnx-agents-ui/the-empty-hint-names-the-key-and-what-claude-needs ()
  (cl-letf (((symbol-function 'drgnx-agents-ui--new-key) (lambda () "C-c a n"))
            ((symbol-function 'drgnx-agents-ui--claude-needs) (lambda () "Claude needs its adapter, claude-agent-acp: install it.")))
    (drgnx-agents-ui-test--with-list (nil b)
      (let ((flat (replace-regexp-in-string "\n" " " (drgnx-agents-ui-test--body))))
        (should (string-search "(C-c a n, or the palette)" flat))
        (should (string-search "Claude needs its adapter" flat))
        (dolist (l (split-string (drgnx-agents-ui-test--body) "\n" t)) (should (<= (length l) 40))))))
  ;; the claude need: only when claude is the default profile and its adapter is missing or too old
  (cl-letf (((symbol-function 'drgnx-agents-default-profile) (lambda () "claude"))
            ((symbol-function 'drgnx-agents-claude-adapter) (lambda () nil)))
    (should (string-match-p "adapter, claude-agent-acp" (drgnx-agents-ui--claude-needs))))
  (cl-letf (((symbol-function 'drgnx-agents-default-profile) (lambda () "claude"))
            ((symbol-function 'drgnx-agents-claude-adapter) (lambda () '(:name "x")))
            ((symbol-function 'drgnx-agents-adapter-problem) (lambda (_a) '("old" . "fix"))))
    (should (string-match-p "needs updating" (drgnx-agents-ui--claude-needs))))
  (cl-letf (((symbol-function 'drgnx-agents-default-profile) (lambda () "claude"))
            ((symbol-function 'drgnx-agents-claude-adapter) (lambda () '(:name "x")))
            ((symbol-function 'drgnx-agents-adapter-problem) #'ignore))
    (should-not (drgnx-agents-ui--claude-needs)))
  (cl-letf (((symbol-function 'drgnx-agents-default-profile) (lambda () "other"))
            ((symbol-function 'drgnx-agents-profile) (lambda (_n) '("other" :command ("some-agent"))))
            ((symbol-function 'drgnx-agents-claude-adapter) (lambda () nil)))
    (should-not (drgnx-agents-ui--claude-needs))))

;;; agents-ui-test.el ends here
