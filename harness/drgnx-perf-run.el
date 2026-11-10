;;; drgnx-perf-run.el --- `drgnx test --perf' and `--soak': workloads in a GUI session, budgets, history -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The controller side of the perf lab.  A workload is a setup form (run in the session), the input
;; to send (real key events through the harness) and an optional form that measures what input
;; cannot (frames, redisplay, startup, memory).  Each input workload runs three times and the median
;; of its p95 and max is kept, so one noisy run never decides.  Results are judged against
;; test/perf/budgets.eld, appended to the history (perf-history.jsonl in the harness state root) and
;; compared with the median of the last five runs.  See docs/develop/perf.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-build)
(require 'drgnx-ui)
(require 'drgnx-perf)
(require 'drgnx-perf-settings)
(require 'drgnx-perf-extensions)
(require 'drgnx-perf-workloads)
(require 'drgnx-perf-work)
(require 'drgnx-perf-agents)

(defvar drgnx-perf-run--fixture nil "The typing fixture of this run (one file, reused, deleted at the end).")

(defconst drgnx-perf-run--fixture-mark ";; drgnx-perf: the keys go on the next line"
  "The comment in `drgnx-perf-run--fixture-spot' above the line the keys go to.")

(defconst drgnx-perf-run--fixture-spot
  (concat "\n(defun drgnx-perf-fixture-spot (items)
  \"Where the perf lab types: six lists deep, so a list the keys leave open ends in here.\"
  (dolist (item items)
    (when (consp item)
      (with-temp-buffer
        (save-excursion
          (progn
            " drgnx-perf-run--fixture-mark "
            (insert (format \"%s\" item))))))))\n")
  "The form the keys go into, the same in every tree.  Where the middle of core/ falls changes with every core file:
on a line with too few lists around it, each `(let ((x' typed left a list open past its form, and Emacs Lisp's
font-lock (`lisp--el-funcall-position-p', through `forward-sexp') scanned the rest of the file at every key.")

(defun drgnx-perf-run--make-fixture ()
  "A large Emacs Lisp file — drgnx's own core three times (~140k lines) — written once per run, with
`drgnx-perf-run--fixture-spot' between two files near its middle."
  (let* ((f (make-temp-file "drgnx-perf-" nil ".el"))
         (files (directory-files (expand-file-name "core" drgnx-ui-repo-dir) t "\\.el\\'"))
         (middle (nth (/ (length files) 2) files)))
    (with-temp-file f
      (dotimes (i 3)
        (dolist (x files)
          (insert-file-contents x) (goto-char (point-max))
          (when (and (= i 1) (eq x middle)) (insert drgnx-perf-run--fixture-spot)))))
    f))

(defun drgnx-perf-run--session-size ()
  "The perf sessions' monitor size: $DRGNX_UI_SIZE (WxH) when set, else 1400x800."
  (let ((e (getenv "DRGNX_UI_SIZE"))) (if (member e '(nil "")) "1400x800" e)))

(defun drgnx-perf-run--visit-fixture-form ()
  "The form that visits the fixture and puts point where the keys go: the line under `drgnx-perf-run--fixture-mark'."
  (format "(let ((f %S)) (when-let* ((b (find-buffer-visiting f))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))
                         (find-file f) (goto-char (point-min)) (search-forward %S) (forward-line 1) t)"
          drgnx-perf-run--fixture drgnx-perf-run--fixture-mark))

(defun drgnx-perf-run--replace-setup-form ()
  "The replace-typing workload's setup: 100 files of 100 matching lines, and the session functions it uses."
  (prin1-to-string
   '(progn
      (require 'drgnx-replace)
      (unless (assq 'search drgnx-wb--sections)       ; the module sets up once Emacs is idle: maybe not yet
        (drgnx-replace--define-section)
        (drgnx-replace--define-commands))
      (defvar drgnx-perf--needles nil "The directory of the 10k matches.")
      (defvar drgnx-perf--replace-started nil "Non-nil once the first key started the search.")
      (setq drgnx-perf--needles (make-temp-file "drgnx-perf-needles" t))
      (let ((text (apply #'concat (make-list 100 "a needle in the haystack, line after line\n"))))
        (dotimes (i 100)
          (with-temp-file (expand-file-name (format "f%03d.txt" i) drgnx-perf--needles) (insert text))))
      (defun drgnx-perf--replace-view () (get-buffer drgnx-replace-buffer-name))
      (defun drgnx-perf--replace-arm ()
        "The Search view open on the needles with nothing to find; the first key typed starts the search."
        (let ((editor (selected-window)))
          (drgnx-replace--open :text "zzz-perf-nothing"
                               :origin (with-current-buffer (find-file-noselect (expand-file-name "f000.txt" drgnx-perf--needles))
                                         (point-min-marker)))
          (select-window editor))
        (setq drgnx-perf--replace-started nil drgnx-perf--slices nil)
        (advice-add 'drgnx-view--draw-buffer :around #'drgnx-perf--slice-timed)
        (drgnx-perf--passes-arm)
        (add-hook 'post-command-hook #'drgnx-perf--replace-key))
      ;; the model's cadence while the view streams (the Cadence rows of plan sja-complete D3): the redisplay passes, those
      ;; whose last hub input was a model line alone and the windows they redrew (a model the rows don't show redraws
      ;; none), the model lines, and each model's lag from its line to the drain that applied it
      (defvar drgnx-perf--cad nil "While armed: (PASSES MODEL-PASSES MODEL-WINDOWS LINES BYTES), counts since the arm.")
      (defvar drgnx-perf--cad-last nil "`model' after a model line, `other' after any other hub line, nil after a pass.")
      (defvar drgnx-perf--cad-queued nil "When the oldest model line not yet drained came (`float-time'), or nil.")
      (defvar drgnx-perf--cad-lags nil "Each drain's lag in ms: from the oldest model line it applied to the drain.")
      (defun drgnx-perf--cad-model (line)
        (setq drgnx-perf--cad-last 'model)
        (when drgnx-perf--cad
          (cl-incf (nth 3 drgnx-perf--cad))
          (cl-incf (nth 4 drgnx-perf--cad) (length line))
          (unless drgnx-perf--cad-queued (setq drgnx-perf--cad-queued (float-time)))))
      (defun drgnx-perf--cad-other (&rest _) (setq drgnx-perf--cad-last 'other))
      (defun drgnx-perf--cad-drained (_state r)
        (when (and drgnx-perf--cad drgnx-perf--cad-queued r (> (nth 0 r) 0))
          (push (* 1000 (- (float-time) drgnx-perf--cad-queued)) drgnx-perf--cad-lags)
          (setq drgnx-perf--cad-queued nil)))
      (defun drgnx-perf--cad-pass (wins)
        (when drgnx-perf--cad
          (cl-incf (car drgnx-perf--cad))
          (when (eq drgnx-perf--cad-last 'model)
            (cl-incf (nth 1 drgnx-perf--cad))
            (cl-incf (nth 2 drgnx-perf--cad) (if (listp wins) (length wins) (length (window-list-1 nil nil t))))))
        (setq drgnx-perf--cad-last nil))
      (defun drgnx-perf--passes-arm ()
        (setq drgnx-perf--cad (list 0 0 0 0 0) drgnx-perf--cad-last nil drgnx-perf--cad-queued nil drgnx-perf--cad-lags nil)
        (advice-add 'drgnx-hub--model-line :before #'drgnx-perf--cad-model)
        (advice-add 'drgnx-hub--client-line :before #'drgnx-perf--cad-other)
        (advice-add 'drgnx-view-model--drained :before #'drgnx-perf--cad-drained)
        (advice-add 'redisplay--pre-redisplay-functions :before #'drgnx-perf--cad-pass))
      (defun drgnx-perf--passes-done ()
        "The cadence counts since the arm, as measure keys (none when not armed)."
        (advice-remove 'drgnx-hub--model-line #'drgnx-perf--cad-model)
        (advice-remove 'drgnx-hub--client-line #'drgnx-perf--cad-other)
        (advice-remove 'drgnx-view-model--drained #'drgnx-perf--cad-drained)
        (advice-remove 'redisplay--pre-redisplay-functions #'drgnx-perf--cad-pass)
        (prog1 (when-let* ((c drgnx-perf--cad))
                 (list :model_lag_ms (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--cad-lags))
                       :cadence (list :passes (nth 0 c) :model_passes (nth 1 c) :model_windows (nth 2 c)
                                      :model_lines (nth 3 c) :model_bytes (nth 4 c))))
          (setq drgnx-perf--cad nil drgnx-perf--cad-lags nil)))
      (defun drgnx-perf--replace-key ()
        "After a key: the first starts the search (from a timer, as the view's own typing pause does)."
        (unless drgnx-perf--replace-started
          (setq drgnx-perf--replace-started t)
          (run-with-timer 0 nil #'drgnx-perf--replace-search)))
      (defun drgnx-perf--replace-search ()
        (with-current-buffer (drgnx-perf--replace-view)
          (drgnx-replace--fill 'find "needle")
          (drgnx-replace--search-now)))
      (defun drgnx-perf--replace-check ()
        "It listed all 10k matches (the hub sends a window of the rows and is busy a short time: no minimum of keys
typed while it streams)."
        (remove-hook 'post-command-hook #'drgnx-perf--replace-key)
        (drgnx-perf--replace-idle)
        (and (= 10000 (with-current-buffer (drgnx-perf--replace-view) (or (cdr drgnx-replace--hub-counts) 0))) t))
      (defun drgnx-perf--replace-done ()
        "The whole operation is over: all 10k matches found and the view has no work left (the `:complete-when' of the
typing workloads, whose cost from the first key to here is `:complete-kb' and `:complete-cpu_ms')."
        (and drgnx-perf--replace-started
             (when-let* ((v (drgnx-perf--replace-view)))
               (with-current-buffer v
                 (and (= 10000 (or (cdr drgnx-replace--hub-counts) 0))
                      (not (drgnx-replace--busy-p)))))))
      (defun drgnx-perf--replace-teardown ()
        (remove-hook 'post-command-hook #'drgnx-perf--replace-key)
        (advice-remove 'drgnx-view--draw-buffer #'drgnx-perf--slice-timed)
        (drgnx-perf--passes-done)
        (ignore-errors (drgnx-wb-show-view 'explorer))
        (when-let* ((v (drgnx-perf--replace-view))) (kill-buffer v))
        (dolist (b (buffer-list))
          (when (and (buffer-file-name b) (string-prefix-p drgnx-perf--needles (buffer-file-name b))) (kill-buffer b)))
        (delete-directory drgnx-perf--needles t))
      ;; each view draw is timed
      (defvar drgnx-perf--slices nil "Wall milliseconds of each `drgnx-view--draw-buffer' call since the arm.")
      (defun drgnx-perf--slice-timed (orig buffer)
        (let ((t0 (float-time)))
          (prog1 (funcall orig buffer) (push (* 1000 (- (float-time) t0)) drgnx-perf--slices))))
      (defun drgnx-perf--replace-idle ()
        "Wait until the Search view has no work left; an error if it still has after 100 s (the arm's and measure's calls allow 120).
One `accept-process-output' runs one link of the view's chain of zero-delay slices however long it waits, so while a
timer is due the wait polls without a timeout: the chain runs back to back, as in the command loop.  A 50 ms poll
gave it one 4 ms slice per poll; the wait gave up with rows left, and the command loop, which runs a zero-delay
chain without reading any socket, finished them while the harness's next call got no answer (PERF-SEED-1)."
        (let ((d (+ (float-time) 100)))
          (while (and (with-current-buffer (drgnx-perf--replace-view) (drgnx-replace--busy-p)) (< (float-time) d))
            (accept-process-output nil (if (and timer-list (not (time-less-p nil (timer--time (car timer-list))))) 0 0.05)))
          (when (with-current-buffer (drgnx-perf--replace-view) (drgnx-replace--busy-p))
            (error "The Search view still has work after 100 s"))))
      (defun drgnx-perf--retype-measure ()
        "The redraw finished: each view draw's wall time since the arm, and the model's cadence (rows path only)."
        (drgnx-perf--replace-idle)
        (advice-remove 'drgnx-view--draw-buffer #'drgnx-perf--slice-timed)
        (append (list :slice_ms (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--slices)))
                (drgnx-perf--passes-done)))
      t)))

(defun drgnx-perf-run--live-setup-form ()
  "The live-view workload's setup: websocket (from the user's packages if need be), the mock browser as the browser
for agents, the Live view open, the blank-frame count, and the session functions it uses."
  (prin1-to-string
   `(progn
      (unless (require 'websocket nil t)
        ;; the lab's $DRGNX_USER_ELPA, put in here: the session does not inherit it
        (let* ((elpa (expand-file-name (or ,(drgnx-perf-run--user-elpa) "~/.config/emacs/elpa")))
               (dir (car (last (and (file-directory-p elpa) (directory-files elpa t "\\`websocket-[0-9]"))))))
          (unless dir (error "The Live view needs the websocket package"))
          (add-to-list 'load-path dir)
          (require 'websocket)))
      (load ,(expand-file-name "test/fixtures/mock-cdp" drgnx-ui-repo-dir) nil t)
      (require 'drgnx-live)
      (require 'drgnx-exec)
      (defvar drgnx-perf--live-timer nil "Sends the frames.")
      (defvar drgnx-perf--live-message nil
        "Two frames' messages, as the browser sends them: encoded websocket frames, one after the other as the view draws
them.  Two, because a page's
frames differ: the view's last frame stays in the image cache while the next one decodes (its stand-in); identical
frames would share one cache entry, and flushing the old frame would flush the new one.")
      (setq drgnx-perf--live-message nil)
      (defvar drgnx-perf--live-width nil "The frames' width.")
      (setq drgnx-perf--live-width nil)
      (defvar drgnx-perf--live-sent 0 "How many messages the mock had received when it sent the last frame.")
      (setq drgnx-perf--live-sent 0)
      (defvar drgnx-perf--live-drawn 0 "Frames drawn when the typing began.")
      (defvar drgnx-perf--live-endpoint nil "The mock browser's endpoint (:port :ws).")
      (defun drgnx-perf--live-make-jpeg (width quality)
        "A real JPEG WIDTH pixels wide at QUALITY, base64, as Chrome sends at the view's maxWidth (ImageMagick's
built-in logo, a 1280×800 page scaled); without ImageMagick nil: the frames are then a few bytes no decoder accepts,
cheaper to draw."
        (when-let* ((magick (or (executable-find "magick") (executable-find "convert"))))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (and (eq 0 (call-process magick nil t nil "logo:" "-resize" (format "%dx%d!" width (round (* width 0.625)))
                                     "-quality" (number-to-string quality) "jpeg:-"))
                 (base64-encode-string (buffer-string) t)))))
      (let ((port (drgnx-mock-cdp-start)))
        (setq drgnx-perf--live-endpoint (list :port port :ws (format "ws://127.0.0.1:%d/devtools/browser/mock" port))))
      (defun drgnx-perf--live-view () (get-buffer drgnx-live-buffer-name))
      (defun drgnx-perf--live-frame ()
        "A frame, once the last one was acknowledged (as Chrome sends them)."
        (when (> (length drgnx-mock-cdp--received) drgnx-perf--live-sent)   ; the view answered (its ack)
          (setq drgnx-perf--live-sent (length drgnx-mock-cdp--received))
          ;; the message and its websocket frame are made once: the mock runs in this Emacs, and making them is the
          ;; browser's work, not drgnx's (websocket.el's encoder makes a list of every byte)
          ;; at the width the view asked for last, as Chrome sends them
          (let ((width (or (plist-get (plist-get (car (last (drgnx-mock-cdp-received "Page.startScreencast"))) :params) :maxWidth)
                           1280)))
            (unless (eql width drgnx-perf--live-width) (setq drgnx-perf--live-message nil drgnx-perf--live-width width)))
          (unless drgnx-perf--live-message
            (setq drgnx-perf--live-message
                  (mapcar (lambda (quality)
                            (websocket-encode-frame
                             (make-websocket-frame
                              :opcode 'text :completep t
                              :payload (encode-coding-string
                                        (json-serialize
                                         (list :method "Page.screencastFrame" :sessionId "S-T1"
                                               :params (list :data (or (drgnx-perf--live-make-jpeg drgnx-perf--live-width quality)
                                                                       (base64-encode-string (format "frame %d" quality)))
                                                             :sessionId 1
                                                             :metadata (list :deviceWidth 1280 :deviceHeight 800 :offsetTop 0 :pageScaleFactor 1
                                                                             :scrollOffsetX 0 :scrollOffsetY 0 :timestamp (float-time)))))
                                        'raw-text))
                             nil))
                          '(60 61))))
          ;; by the count of frames drawn: frames sent between two draws are the same, so the next drawn frame always
          ;; differs from the last drawn one, however many the view drops
          (let* ((view (drgnx-perf--live-view))
                 (msg (nth (% (if view (buffer-local-value 'drgnx-live--drawn view) 0) 2) drgnx-perf--live-message)))
            (dolist (ws (drgnx-mock-cdp-clients)) (process-send-string (websocket-conn ws) msg)))))
      (defun drgnx-perf--live-arm ()
        "The Live view beside the file, frames arriving."
        (let* ((editor (selected-window)) (file (window-buffer editor)))
          (unless (drgnx-perf--live-view)
            (drgnx-live-view)
            (drgnx-live--open (drgnx-perf--live-view) drgnx-perf--live-endpoint)   ; the product's view is dormant: the frozen client, on the mock
            (drgnx-mock-cdp-wait (lambda () (drgnx-mock-cdp-received "Page.startScreencast")) 10))
          (set-window-buffer editor file)               ; the view may have taken the file's window
          (unless (get-buffer-window (drgnx-perf--live-view))
            (set-window-buffer (split-window editor nil 'right) (drgnx-perf--live-view)))
          (select-window editor))
        (unless drgnx-perf--live-timer (setq drgnx-perf--live-timer (run-with-timer 0 (/ 1.0 30) #'drgnx-perf--live-frame)))
        (setq drgnx-perf--live-drawn (buffer-local-value 'drgnx-live--drawn (drgnx-perf--live-view)))
        (setq drgnx-perf--live-blank 0
              drgnx-perf--live-seen (plist-get (drgnx-perf--live-images) :deferred))
        (when (fboundp 'nidhogg-workers--test-image-timing) (nidhogg-workers--test-image-timing t))        (add-hook 'pre-redisplay-functions #'drgnx-perf--live-blank-sample)
        (advice-add 'drgnx-live--draw-frame :before #'drgnx-perf--live-blank-sample))
      ;; "No blank frame" (off-the-main-thread design §17.6): with Nidhogg's image worker a frame's decode may outlast
      ;; the redisplay's wait budget; its entry is then pending and draws the last frame's picture (the stand-in) or
      ;; nothing.  Pending entries are made only inside a redisplay, so before the next one (and before the next frame
      ;; replaces the image) the image counters tell whether the last redisplay drew a pending entry without a
      ;; stand-in; each newly deferred decode is judged once.  Without the worker nothing defers: 0.
      (defvar drgnx-perf--live-blank 0 "Redisplays that drew a frame's space with no picture.")
      (defvar drgnx-perf--live-seen 0 "The image worker's deferred count already judged.")
      (defun drgnx-perf--live-images ()
        (and (fboundp 'nidhogg-workers--test-image-info) (nidhogg-workers--test-image-info)))
      (defun drgnx-perf--live-blank-sample (&rest _)
        (when-let* ((i (drgnx-perf--live-images)))
          (when (and (> (plist-get i :deferred) (or drgnx-perf--live-seen 0))
                     (> (plist-get i :pending) (plist-get i :standing)))
            (setq drgnx-perf--live-blank (1+ drgnx-perf--live-blank)))
          (setq drgnx-perf--live-seen (plist-get i :deferred))))
      (defun drgnx-perf--live-measure ()
        (let ((i (drgnx-perf--live-images)))
          (list :live (list :blank drgnx-perf--live-blank
                            :frames (- (buffer-local-value 'drgnx-live--drawn (drgnx-perf--live-view)) drgnx-perf--live-drawn)
                            :deferred (or (plist-get i :deferred) 0)
                            :timing (and (fboundp 'nidhogg-workers--test-image-timing)
                                         (nidhogg-workers--test-image-timing))))))
      (defun drgnx-perf--live-check ()
        "Frames were drawn while the keys were typed."
        (and (>= (- (buffer-local-value 'drgnx-live--drawn (drgnx-perf--live-view)) drgnx-perf--live-drawn) 5) t))
      (defun drgnx-perf--live-teardown ()
        (remove-hook 'pre-redisplay-functions #'drgnx-perf--live-blank-sample)
        (advice-remove 'drgnx-live--draw-frame #'drgnx-perf--live-blank-sample)
        (when (timerp drgnx-perf--live-timer) (cancel-timer drgnx-perf--live-timer))
        (setq drgnx-perf--live-timer nil)
        (when-let* ((v (drgnx-perf--live-view)))
          (when-let* ((w (get-buffer-window v))) (ignore-errors (delete-window w)))
          (kill-buffer v))
        (drgnx-mock-cdp-stop)
        (setq drgnx-perf--live-endpoint nil))
      t)))

(defun drgnx-perf-run--agent-settings-setup-form ()
  "The agent-settings-open workload's setup: a Claude Code home with a 5 MB .claude.json (300 projects, 50 MCP servers)
and 200 skills, a project, and a counter of the processes the page starts; the session's HOME and CLAUDE_CONFIG_DIR
point into it until the teardown."
  (prin1-to-string
   `(progn
      (load ,(expand-file-name "modules/tools/drgnx-agent-settings" drgnx-ui-repo-dir) nil t)
      (defvar drgnx-perf--agent-dir nil "The fixture's directory, with the variables it replaced.")
      (defvar drgnx-perf--spawned 0 "Processes started since the counter was reset.")
      (defun drgnx-perf--spawn (&rest _) (setq drgnx-perf--spawned (1+ drgnx-perf--spawned)))
      (defun drgnx-perf--agent-fixture ()
        (let* ((dir (make-temp-file "drgnx-perf-agent" t)) (home (expand-file-name "claude" dir))
               (project (expand-file-name "project" dir)) (servers (make-hash-table :test #'equal))
               (projects (make-hash-table :test #'equal)) (junk (make-string 400 ?x)))
          (make-directory home t) (make-directory project t)
          (dotimes (i 50)
            (let ((s (make-hash-table :test #'equal)))
              (puthash "type" "stdio" s) (puthash "command" (format "drgnx-perf-no-such-server-%d" i) s)
              (puthash "args" (vector "--stdio") s)
              (puthash (format "server-%d" i) s servers)))
          (dotimes (i 300)
            (let ((p (make-hash-table :test #'equal)))
              (puthash "allowedTools" (vector) p) (puthash "mcpServers" (make-hash-table :test #'equal) p)
              (puthash "hasTrustDialogAccepted" t p)
              (puthash "history" (vconcat (mapcar (lambda (_) (let ((h (make-hash-table :test #'equal))) (puthash "display" junk h) h))
                                                  (make-list 40 nil)))
                       p)
              (puthash (format "/srv/perf/project-%d" i) p projects)))
          (let ((top (make-hash-table :test #'equal)))
            (puthash "numStartups" 100 top) (puthash "mcpServers" servers top) (puthash "projects" projects top)
            (with-temp-file (expand-file-name ".claude.json" home)
              (set-buffer-multibyte nil) (insert (json-serialize top))))
          (dotimes (i 200)
            (let ((f (expand-file-name (format "skills/skill-%d/SKILL.md" i) home)))
              (make-directory (file-name-directory f) t)
              (with-temp-file f (insert (format "---\nname: skill-%d\ndescription: Skill number %d\n---\n\nBody.\n" i i)))))
          dir))
      (setq drgnx-perf--agent-dir (list (drgnx-perf--agent-fixture) (getenv "HOME") (getenv "CLAUDE_CONFIG_DIR")))
      (setenv "HOME" (car drgnx-perf--agent-dir))
      (setenv "CLAUDE_CONFIG_DIR" (expand-file-name "claude" (car drgnx-perf--agent-dir)))
      (dolist (f '(make-process start-process call-process process-file call-process-region))
        (advice-add f :before #'drgnx-perf--spawn))
      t)))

(defconst drgnx-perf-run--agent-settings-measure-form
  "(let* ((root (expand-file-name \"project\" (car drgnx-perf--agent-dir))) (before (length (process-list))) (t0 (float-time)))
     (setq drgnx-perf--spawned 0)
     (pop-to-buffer (drgnx-agent-settings-open 'claude root))
     (redisplay t)
     (list :draw_ms (drgnx-perf--round (* 1000 (- (float-time) t0)))
           :processes (+ drgnx-perf--spawned (max 0 (- (length (process-list)) before)))))"
  "The agent-settings-open workload's measure: the Claude page opened and drawn; the milliseconds it took and the
processes it started.")

(defconst drgnx-perf-run--agent-settings-teardown-form
  "(progn (dolist (f '(make-process start-process call-process process-file call-process-region))
           (advice-remove f #'drgnx-perf--spawn))
         (dolist (b (buffer-list)) (when (string-prefix-p \"*agent settings: \" (buffer-name b)) (kill-buffer b)))
         (when drgnx-perf--agent-dir
           (setenv \"HOME\" (nth 1 drgnx-perf--agent-dir)) (setenv \"CLAUDE_CONFIG_DIR\" (nth 2 drgnx-perf--agent-dir))
           (delete-directory (car drgnx-perf--agent-dir) t)
           (setq drgnx-perf--agent-dir nil))
         t)"
  "The agent-settings-open workload's teardown: the page, the fixture and the variables put back.")

(defun drgnx-perf-run--remote-setup-form ()
  "The remote-typing workload's setup: a mock-method root (test/fixtures/tramp-mock.el: a real TRAMP connection to a
local sh) listed in the Explorer, remembered as a remote root, its connection opened and then killed."
  (prin1-to-string
   `(progn
      (load ,(expand-file-name "test/fixtures/tramp-mock" drgnx-ui-repo-dir) nil t)
      (load ,(expand-file-name "modules/lang/drgnx-lang" drgnx-ui-repo-dir) nil t)
      (load ,(expand-file-name "modules/tools/drgnx-remote" drgnx-ui-repo-dir) nil t)
      (defvar drgnx-perf--remote nil "(DIR ROOT ROOTS-BEFORE SETUP-DONE) of the remote-typing workload.")
      (drgnx-tramp-mock-setup)
      (let* ((dir (make-temp-file "drgnx-perf-remote" t)) (root (file-name-as-directory (drgnx-tramp-mock-name dir)))
             (before (drgnx-explorer-roots)) (setup (not (memq drgnx-remote--mode-line-entry global-mode-string))))
        (make-directory (expand-file-name "src" dir))
        (setq drgnx-perf--remote (list dir root before setup))
        (when setup (drgnx-remote--setup))
        (let ((drgnx-remote-may-prompt t) (drgnx-lang--user-command t))
          (drgnx-explorer-set-roots (cons root (remove root before)))     ; lists it: the connection opens
          (drgnx-remote--remember root))
        (let ((proc (tramp-get-connection-process (tramp-dissect-file-name root))))
          (kill-process proc)
          (let ((d (+ (float-time) 5))) (while (and (process-live-p proc) (< (float-time) d)) (accept-process-output nil 0.05))))
        (drgnx-wb-show-sidebar)
        (setq drgnx-tramp-mock-sends 0))
      t)))

(defconst drgnx-perf-run--remote-teardown-form
  "(progn (when drgnx-perf--remote
           (ignore-errors (drgnx-explorer-set-roots (nth 2 drgnx-perf--remote)))
           (setq drgnx-remote--roots nil)
           (when (nth 3 drgnx-perf--remote) (drgnx-remote--teardown))
           (ignore-errors (tramp-cleanup-all-connections))
           (drgnx-tramp-mock-teardown)
           (delete-directory (car drgnx-perf--remote) t)
           (setq drgnx-perf--remote nil))
         t)"
  "The remote-typing workload's teardown: the Explorer's folders put back, the connections closed, the mock removed.")

(defun drgnx-perf-run--index-setup-form ()
  "The typing-with-index workload's setup, as a form string: a hub of the workload (`drgnx-perf-run--hub-form'; the
session's environment starts none) indexes a git project made of the checkout's own code (the container's /src is
not a git project; Hrafn; tier 1 done before the typing starts), and the session functions the check and the
teardown use."
  (concat
   "(progn " (drgnx-perf-run--hub-form) " (drgnx-perf--hub-start nil) "
   (prin1-to-string
    `(progn
       (require 'drgnx-search)
       (unless (memq 'drgnx-tools/search--typing post-command-hook) (error "The search module (tools/search) is not on"))
       (defvar drgnx-perf--index-root nil "The indexed project, without a trailing slash.")
       (defun drgnx-perf--index-chunks ()
         "How many chunks the hub holds of the project."
         (or (plist-get (drgnx-hub-call-sync "search/status" (list :root drgnx-perf--index-root) 10) :chunks) 0))
       (setq drgnx-perf--index-root (directory-file-name (make-temp-file "drgnx-perf-index" t)))
       (dolist (dir '("core" "wb"))
         (copy-directory (expand-file-name dir ,(directory-file-name drgnx-ui-repo-dir))
                         (expand-file-name dir drgnx-perf--index-root) nil t t))
       (let ((default-directory (file-name-as-directory drgnx-perf--index-root)))
         (dolist (args '(("init" "-q") ("add" "-A")
                         ("-c" "user.name=perf" "-c" "user.email=perf@localhost" "commit" "-q" "-m" "perf")))
           (unless (zerop (apply #'call-process "git" nil nil nil args)) (error "git %S failed" args))))
       (drgnx-hub-call-sync "search/index" (list :root drgnx-perf--index-root :now t) 30)
       (let ((deadline (+ (float-time) 120)))
         (while (and (< (drgnx-perf--index-chunks) 100) (< (float-time) deadline)) (accept-process-output nil 0.5)))
       (when (< (drgnx-perf--index-chunks) 100) (error "The hub holds only %s chunks of the project" (drgnx-perf--index-chunks)))
       (defun drgnx-perf--index-check ()
         "The hub holds the index."
         (>= (drgnx-perf--index-chunks) 100))
       (defun drgnx-perf--index-teardown ()
         (drgnx-perf--hub-stop)
         (ignore-errors (delete-directory drgnx-perf--index-root t))
         t)
       t))
   ")"))

(defun drgnx-perf-run--window-switch-setup-form ()
  "The window-switch workload's setup: 3 editor groups with the dock, the panel and the right dock shown, and
the counter the check reads (a command that ends in another selected window counts one)."
  (prin1-to-string
   `(progn
      (defvar drgnx-perf--ws-count 0 "Commands that ended in a different selected window.")
      (defvar drgnx-perf--ws-last nil "The selected window after the last command.")
      (defun drgnx-perf--ws-post ()
        (let ((w (selected-window)))
          (unless (eq w drgnx-perf--ws-last)
            (setq drgnx-perf--ws-count (1+ drgnx-perf--ws-count) drgnx-perf--ws-last w))))
      (drgnx-groups-focus-2)             ; a second group if there is one, then a third if there are two
      (drgnx-groups-focus-3)
      (drgnx-wb-show-sidebar)
      (drgnx-wb-area-show 'panel)
      (drgnx-wb-area-show 'right)
      (add-hook 'post-command-hook #'drgnx-perf--ws-post 90)
      t)))

(defun drgnx-perf-run--window-switch-each-form ()
  "Before each repeat: the fixture in all three groups, group 1 selected, the counter at 0."
  (concat "(let ((groups (drgnx-groups-list)))
     (unless (= (length groups) 3) (error \"%d editor groups, not 3\" (length groups)))
     (select-window (car groups))
     " (drgnx-perf-run--visit-fixture-form) "
     (dolist (w (cdr groups)) (set-window-buffer w (current-buffer)))
     (select-window (car groups))
     (setq drgnx-perf--ws-count 0 drgnx-perf--ws-last (selected-window))
     t)"))

(defconst drgnx-perf-run--window-switch-teardown-form
  "(progn
     (remove-hook 'post-command-hook #'drgnx-perf--ws-post)
     (drgnx-wb-area-hide 'panel)
     (drgnx-wb-area-hide 'right)
     (dolist (w (cdr (drgnx-groups-list))) (when (window-live-p w) (delete-window w)))
     t)"
  "After the workload: the hook out, the areas hidden, one editor group again.")

(defun drgnx-perf-run--select (workloads)
  "WORKLOADS limited to the names in $DRGNX_PERF_WORKLOADS (space-separated; unset or empty: all), in their own
order.  A name that is no workload is an error: a typo must not run nothing and pass."
  (let ((names (split-string (or (getenv "DRGNX_PERF_WORKLOADS") "") " " t)))
    (if (null names) workloads
      (dolist (n names)
        (unless (assq (intern n) workloads) (error "DRGNX_PERF_WORKLOADS: no workload %S" n)))
      (seq-filter (lambda (w) (member (symbol-name (car w)) names)) workloads))))

(defun drgnx-perf-run--user-elpa ()
  "The package directory $DRGNX_USER_ELPA names, or nil."
  (let ((dir (getenv "DRGNX_USER_ELPA")))
    (and dir (not (string-empty-p dir)) (expand-file-name dir))))

(defun drgnx-perf-run--websocket-elpa-p ()
  "Non-nil when $DRGNX_USER_ELPA holds a websocket package (the Live view workload can then run in the container)."
  (let ((elpa (drgnx-perf-run--user-elpa)))
    (and elpa (file-directory-p elpa) (directory-files elpa nil "\\`websocket-[0-9]") t)))

(defun drgnx-perf-run--terminal-setup-form (command &rest switches)
  "The terminal workloads' setup: a hub of the workload (`drgnx-perf-run--hub-form'; its terminal worker beside it),
module tools/term run on it, and the session functions the workloads use (`drgnx-perf-run--terminal-lib-form').  The
terminal runs COMMAND with SWITCHES directly: no shell, so no shell configuration is involved."
  (concat "(progn " (drgnx-perf-run--hub-form) " (drgnx-perf--hub-start nil) "
          (drgnx-perf-run--terminal-lib-form (cons command switches) nil t) ")"))

(defun drgnx-perf-run--terminal-lib-form (argv &optional flood own-hub)
  "The terminal workloads' session side, as a form string, on the hub already connected: module tools/term run, the
functions the workloads use, and a terminal running ARGV (its program found on PATH) opened.  With FLOOD (an argv) a
second terminal runs it, shown in the panel, while the first one is typed into (`terminal-echo').  The draws of
terminal buffers are timed and their allocation counted from `drgnx-perf--term-arm' (`drgnx-perf--term-measure').
OWN-HUB: the workload started the hub (`drgnx-perf--hub-start'), and the teardown stops it."
  (prin1-to-string
   `(progn
      ;; the session's modules ran before its hub was up: run tools/term now, as it runs for a user
      (let ((spec (cdr (assq 'tools/term drgnx-modules--table))))
        (when (and spec (not (drgnx-modules--ok-p 'tools/term)))
          (drgnx-modules--run-one 'tools/term spec 'startup)))
      ;; never measure without the module and not know it
      (unless (drgnx-modules--ok-p 'tools/term)
        (error "The terminal workloads need the tools/term module to run (status %S)"
               (plist-get (cdr (assq 'tools/term (drgnx-modules-report))) :status)))
      (defvar drgnx-perf--term nil "The terminal's buffer.")
      (defvar drgnx-perf--term2 nil "The flooding terminal's buffer (`terminal-echo'), or nil.")
      (defvar drgnx-perf--term-tick 0 "The terminal buffer's modification tick when the keys began.")
      (defvar drgnx-perf--term-slices nil "Wall ms of each draw of a terminal buffer since the arm.")
      (defvar drgnx-perf--term-consed nil "kB allocated by each draw of a terminal buffer since the arm.")
      (defvar drgnx-perf--term-armed nil "(TIME CONSED) at the arm.")
      (defvar drgnx-perf--term-own-hub nil "Whether the teardown stops the hub.")
      (defvar drgnx-perf--echo-pending nil "Send times of the typed terminal's keys not drawn yet, newest first.")
      (defvar drgnx-perf--echo-ms nil "Per key since the arm: ms from its send to the next draw of the typed terminal.")
      (defun drgnx-perf--echo-sent (method _params)
        "Before `drgnx-term--send': a key or text for the typed terminal leaves now."
        (when (and (eq (current-buffer) drgnx-perf--term) (member method '("term/key" "term/input")))
          (push (float-time) drgnx-perf--echo-pending)))
      (setq drgnx-perf--term-own-hub ,own-hub)
      (defun drgnx-perf--term-live-p (&optional b)
        "Whether the terminal B (default the typed one) is open: its program runs in the hub's worker."
        (let ((b (or b drgnx-perf--term)))
          (and (buffer-live-p b) (eq (buffer-local-value 'drgnx-term--state b) 'open))))
      (defun drgnx-perf--term-start (argv)
        "A terminal running ARGV, open; its buffer."
        (let ((b (drgnx-term-start temporary-file-directory
                                   (cons (or (executable-find (car argv)) (error "No %s here" (car argv))) (cdr argv)))))
          (unless (drgnx-perf--wait 30 (lambda () (drgnx-perf--term-live-p b))) (error "The terminal did not open"))
          b))
      (defun drgnx-perf--term-open ()
        ,(if (not flood)
             `(setq drgnx-perf--term (drgnx-perf--term-start ',argv))
           ;; the Work map holds the panel: both terminals open in the editor area, the typed one above, the flood below
           `(let ((display-buffer-overriding-action '((display-buffer-same-window)))
                  (top (selected-window)))
              (setq drgnx-perf--term (drgnx-perf--term-start ',argv))
              (select-window (split-window top nil 'below))
              (setq drgnx-perf--term2 (drgnx-perf--term-start ',flood))
              (select-window top))))
      (defun drgnx-perf--term-show ()
        "The terminal in the panel (the display rules choose where), the editor window selected."
        (let ((win (selected-window)))
          (display-buffer drgnx-perf--term)
          (select-window win)))
      (defun drgnx-perf--term-slice (orig buffer)
        (if (not (eq (buffer-local-value 'major-mode buffer) 'drgnx-term-mode))
            (funcall orig buffer)
          (let ((t0 (float-time)) (c0 (drgnx-gc--consed)))
            (prog1 (funcall orig buffer)
              (let ((now (float-time)))
                (push (* 1000 (- now t0)) drgnx-perf--term-slices)
                (push (/ (- (drgnx-gc--consed) c0) 1024.0) drgnx-perf--term-consed)
                (when (eq buffer drgnx-perf--term)   ; the keys sent before this draw are on screen with it
                  (dolist (k drgnx-perf--echo-pending) (push (* 1000 (- now k)) drgnx-perf--echo-ms))
                  (setq drgnx-perf--echo-pending nil)))))))
      (defun drgnx-perf--term-arm ()
        "Start timing terminal draws and counting the session's allocation."
        (setq drgnx-perf--term-slices nil drgnx-perf--term-consed nil drgnx-perf--echo-pending nil drgnx-perf--echo-ms nil
              drgnx-perf--term-armed (list (float-time) (drgnx-gc--consed)))
        (advice-add 'drgnx-term--send :before #'drgnx-perf--echo-sent)
        (advice-add 'drgnx-view--draw-buffer :around #'drgnx-perf--term-slice))
      (defun drgnx-perf--term-measure (&rest more)
        "Since the arm: each terminal draw's wall ms (:slice_ms) and kB (:draw_kb), the session's allocation in MB/s
\(:alloc_rate), and when keys were typed into the terminal each one's ms from its send to the draw that showed it
\(:echo_ms); MORE (a plist) is added."
        (advice-remove 'drgnx-view--draw-buffer #'drgnx-perf--term-slice)
        (advice-remove 'drgnx-term--send #'drgnx-perf--echo-sent)
        (let ((secs (max 0.001 (- (float-time) (car drgnx-perf--term-armed))))
              (mb (/ (- (drgnx-gc--consed) (cadr drgnx-perf--term-armed)) 1048576.0)))
          (append (list :slice_ms (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--term-slices))
                        :draw_kb (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--term-consed))
                        :alloc_rate (drgnx-perf--round (/ mb secs)))
                  (and drgnx-perf--echo-ms (list :echo_ms (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--echo-ms))))
                  more)))
      (defun drgnx-perf--term-text-p (b text)
        "Whether TEXT is in terminal B's buffer."
        (with-current-buffer b (save-excursion (goto-char (point-min)) (and (search-forward text nil t) t))))
      (defun drgnx-perf--term-flood (bytes)
        "A file of about BYTES of numbered lines; `cat' of it in a new terminal, then a mark, timed from the start to the
mark on screen: (:wall_ms MS) and the terminal draws' rows (`drgnx-perf--term-measure')."
        (let ((file (make-temp-file "drgnx-perf-flood")) (mark "drgnx-perf-flood-done") b)
          (unwind-protect
              (progn
                (with-temp-file file
                  (let ((i 0)) (while (< (buffer-size) bytes) (insert (format "%08d the quick brown fox jumps over the lazy dog\n" (cl-incf i))))))
                (drgnx-perf--term-arm)
                (let ((t0 (float-time)))
                  (setq b (drgnx-perf--term-start (list "sh" "-c" (format "cat \"$0\"; echo %s; exec sleep 600" mark) file)))
                  (let ((win (selected-window))) (display-buffer b) (select-window win))
                  (let ((shown (or (drgnx-perf--wait 120 (lambda () (drgnx-perf--term-text-p b mark)))
                                   (error "The flood's mark did not show in 120 s"))))
                    (drgnx-perf--term-measure :wall_ms (round (* 1000 (- shown t0)))))))
            (when (buffer-live-p b) (let ((kill-buffer-query-functions nil)) (kill-buffer b)))
            (delete-file file))))
      (defvar drgnx-perf--watch-pauses nil "Ms of each collection since the watch began, newest first.")
      (defvar drgnx-perf--watch-gc-total 0.0 "`gc-elapsed' at the last collection of the watch.")
      (defun drgnx-perf--watch-gc ()
        (push (* 1000 (- gc-elapsed drgnx-perf--watch-gc-total)) drgnx-perf--watch-pauses)
        (setq drgnx-perf--watch-gc-total gc-elapsed))
      (defun drgnx-perf--term-watch (secs)
        "SECS of the typed terminal streaming output with no key typed: the one waiting here is the profiler's whole
subject, so the stream's filter, its decode and its draws are what a profile of the measure shows.  The terminal's
draws and allocation (`drgnx-perf--term-measure'), and the collections: (:gc_count N :gc_pause STATS)."
        (let ((deadline (+ (float-time) secs)))
          (setq drgnx-perf--watch-pauses nil drgnx-perf--watch-gc-total gc-elapsed)
          (drgnx-perf--term-arm)
          (add-hook 'post-gc-hook #'drgnx-perf--watch-gc)
          (unwind-protect
              (while (< (float-time) deadline) (accept-process-output nil (max 0.001 (- deadline (float-time)))))
            (remove-hook 'post-gc-hook #'drgnx-perf--watch-gc))
          (drgnx-perf--term-measure :gc_count (length drgnx-perf--watch-pauses)
                                    :gc_pause (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--watch-pauses)))))
      (defun drgnx-perf--term-backfill ()
        "`seq 1 10000' in a new terminal shown in the panel, timed until its buffer holds the 10k lines (the backfill
after the flood): the draws' rows, and the heap the full terminal adds (:heap_kb: the live Lisp objects after a
collection, against before it opened, plus its buffer's text)."
        (let ((heap (lambda ()
                      (let ((sum 0))
                        (dolist (e (garbage-collect) sum)
                          (when (and (numberp (nth 1 e)) (numberp (nth 2 e))) (setq sum (+ sum (* (nth 1 e) (nth 2 e)))))))))
              (h0 nil) b)
          (setq h0 (funcall heap))
          (unwind-protect
              (progn
                (drgnx-perf--term-arm)
                (setq b (drgnx-perf--term-start (list "sh" "-c" "seq 1 10000; exec sleep 600")))
                (let ((win (selected-window))) (display-buffer b) (select-window win))
                (unless (drgnx-perf--wait 60 (lambda () (drgnx-perf--term-text-p b "\n2\n")))
                  (error "The backfill did not reach line 1 in 60 s"))
                (let ((m (drgnx-perf--term-measure)))
                  (append m (list :lines (with-current-buffer b (count-lines (point-min) (point-max)))
                                  :heap_kb (round (/ (+ (- (funcall heap) h0) (buffer-size b)) 1024.0))))))
            (when (buffer-live-p b) (let ((kill-buffer-query-functions nil)) (kill-buffer b))))))
      (defun drgnx-perf--term-teardown ()
        (advice-remove 'drgnx-view--draw-buffer #'drgnx-perf--term-slice)
        (advice-remove 'drgnx-term--send #'drgnx-perf--echo-sent)
        (dolist (b (list drgnx-perf--term drgnx-perf--term2))
          (when (buffer-live-p b)
            (let ((kill-buffer-query-functions nil)) (kill-buffer b))))   ; term/close ends its worker
        (setq drgnx-perf--term nil drgnx-perf--term2 nil)
        (when drgnx-perf--term-own-hub (drgnx-perf--hub-stop))
        t)
      (drgnx-perf--term-open)
      t)))

(defconst drgnx-perf-run--search-window-form
  (prin1-to-string
   '(progn
      (defun drgnx-perf--sw-view () (drgnx-perf--replace-view))
      (defvar drgnx-perf--sw-lines 0 "The model lines the hub sent while the workload ran.")
      (defvar drgnx-perf--sw-arrived nil "When the first model line since it was cleared came (`float-time').")
      (defvar drgnx-perf--sw-handled 0.0 "The seconds the model lines' handler ran since it was cleared.")
      (defun drgnx-perf--sw-line (f &rest args)
        (let ((t0 (float-time)))
          (setq drgnx-perf--sw-lines (1+ drgnx-perf--sw-lines))
          (unless drgnx-perf--sw-arrived (setq drgnx-perf--sw-arrived t0))
          (prog1 (apply f args) (setq drgnx-perf--sw-handled (+ drgnx-perf--sw-handled (- (float-time) t0))))))
      (defun drgnx-perf--sw-h () (drgnx-view-patch-handle (buffer-local-value 'drgnx-view-patch (drgnx-perf--sw-view))))
      (defun drgnx-perf--sw-up ()
        "The needles grown to 300 files (30,000 matches, 30,300 entries), searched on the hub's rows path to the end:
the model's `order' is a window of the first 20,000."
        (let ((text (apply #'concat (make-list 100 "a needle in the haystack, line after line\n"))))
          (cl-loop for i from 100 below 300
                   do (with-temp-file (expand-file-name (format "f%03d.txt" i) drgnx-perf--needles) (insert text))))
        (let ((editor (selected-window)))
          (drgnx-replace--open :text "needle"
                               :origin (with-current-buffer (find-file-noselect (expand-file-name "f000.txt" drgnx-perf--needles))
                                         (point-min-marker)))
          (select-window editor))
        (with-current-buffer (drgnx-perf--sw-view) (drgnx-replace--search-now))
        (unless (drgnx-perf--wait 120 (lambda () (with-current-buffer (drgnx-perf--sw-view)
                                                   (and drgnx-view-patch (eql 30000 (cdr drgnx-replace--hub-counts))
                                                        (not (drgnx-replace--busy-p))
                                                        (equal (ignore-errors (nidhogg-view-get (drgnx-perf--sw-h) 'window "order"))
                                                               '(0 20000 30300))))))
          (error "Premise: the search did not list 30,000 matches in a 20,000 window (counts %S, window %S)"
                 (with-current-buffer (drgnx-perf--sw-view) drgnx-replace--hub-counts)
                 (ignore-errors (nidhogg-view-get (drgnx-perf--sw-h) 'window "order"))))
        t)
      (defun drgnx-perf--sw-index (h id)
        "ID's position in the whole list `order' (its window's from plus its place in the window)."
        (let ((w (nidhogg-view-get h 'window "order")) (p (cl-position id (nidhogg-view-get h 'list "order") :test #'equal)))
          (unless p (error "Premise: the selection %S is not in the window %S (counts %S, searching %S)"
                           id w drgnx-replace--hub-counts drgnx-replace--searching))
          (+ (if w (car w) 0) p)))
      (defvar drgnx-perf--sw-wire (list 0 0 nil) "(MODEL-BYTES OTHER-BYTES SIZES) of the hub's framed batches since
cleared, SIZES each model line's bytes (\"sja\" for one the reader pushed to Sjá itself), newest first.")
      (defun drgnx-perf--sw-batch (_conn batch)
        (dolist (e batch)
          (when (eq (nth 1 e) 'sja) (push "sja" (nth 2 drgnx-perf--sw-wire)))   ; pushed by the reader: no Lisp string
          (when (stringp (nth 1 e))
            (cl-incf (nth (if (eq (nth 0 e) (nth 1 e)) 0 1) drgnx-perf--sw-wire) (string-bytes (nth 1 e)))
            (when (eq (nth 0 e) (nth 1 e)) (push (string-bytes (nth 1 e)) (nth 2 drgnx-perf--sw-wire))))))
      (defun drgnx-perf--sw-consed (a b)
        "The bytes consed from `memory-use-counts' A to B: conses and floats 16 each, vector cells 8, symbols 48, string
chars 1, intervals 56, strings 32 (a 64-bit build's sizes, as `memory-report' counts them)."
        (cl-loop for x in a for y in b for size in '(16 16 8 48 1 56 32) sum (* size (- y x))))
      (defun drgnx-perf--sw-first-window ()
        "Move `order' back to the first 20,000 entries (a round before paged past them)."
        (funcall drgnx-view-patch-send-function "view/window" (list :view (drgnx-view-patch-view drgnx-view-patch)
                                                                    :list "order" :from 0))
        (unless (drgnx-perf--wait 20 (lambda () (equal (nidhogg-view-get (drgnx-perf--sw-h) 'window "order") '(0 20000 30300))))
          (error "Premise: the window did not go back to the first 20,000 (%S)"
                 (nidhogg-view-get (drgnx-perf--sw-h) 'window "order"))))
      (defun drgnx-perf--sw-measure ()
        "(:key_ms STATS :page_ms STATS :page_nogc_ms STATS :gc_pages N :pages N :page_each \"MS ...\" :line_each \"MS ...\" :gc_each \"GCS:MS ...\" :list_max N :from N :to N): 12 rounds, each from the first window and the
match 50 entries before its end, Next Match until a key stopped at the window's edge and ran again in the next window
(at most 200 keys): each key's time and each page's, the time from that key until it ran; the entries the last round
went from and to.  An error when a key went back (a wrap), a round paged no window, or Sjá held more than the window."
        (with-current-buffer (drgnx-perf--sw-view)
          (advice-add 'drgnx-hub--model-line :around #'drgnx-perf--sw-line)
          (advice-add 'drgnx-hub--client-batch :before #'drgnx-perf--sw-batch)
          ;; a new env between runs may search again (`drgnx-replace--hub-resubscribe'): its end first
          (unless (drgnx-perf--wait 120 (lambda () (and (eql 30000 (cdr drgnx-replace--hub-counts)) (not (drgnx-replace--busy-p))
                                                        (nidhogg-view-get (drgnx-perf--sw-h) 'window "order"))))
            (error "Premise: the search is not listed whole (counts %S)" drgnx-replace--hub-counts))
          (drgnx-perf--sw-first-window)
          ;; the rows grow from the first as the view scrolls (`search/grep-look'), 300 at a time, to the window's end:
          ;; every row before the start held, as before S1 (an `upto' more than 400 rows on is a block after a gap row)
          (let ((ids (nidhogg-view-get (drgnx-perf--sw-h) 'list "order")))
            (cl-loop for k from 299 below 20000 by 300
                     do (drgnx-replace--look (list :upto (nth k ids)))
                     unless (drgnx-perf--wait 30 (lambda () (> (hash-table-count (drgnx-view-patch-rows drgnx-view-patch)) k)))
                     do (error "Premise: the rows did not grow past %d (%d rows)" k
                               (hash-table-count (drgnx-view-patch-rows drgnx-view-patch)))))
          (let ((h (drgnx-perf--sw-h)) keys pages lines handled gcs clean (most 0) from at
                page-kb key-kb page-counts (key-gcs 0) wire-model wire-other wire-lines)
            (dotimes (round 12)
              (unless (zerop round) (drgnx-perf--sw-first-window))
              (let ((start (cl-find-if (lambda (id) (string-prefix-p "m:" id)) (nthcdr 19950 (nidhogg-view-get h 'list "order"))))
                    (paged nil) trace)
                (unless (and start (equal start (drgnx-view-nav 'select start)))
                  (error "Premise: no match at entry 19,950 to start from (start %S, list %d, window %S, selection %S)"
                         start (length (nidhogg-view-get h 'list "order")) (nidhogg-view-get h 'window "order")
                         (drgnx-view-nav-selection)))
                (setq from (drgnx-perf--sw-index h start) at from)
                (cl-loop repeat 200 until paged
                         do (let ((t0 (float-time)) (gc0 gcs-done) (gce0 gc-elapsed) (m0 (memory-use-counts)))
                              (setq drgnx-perf--sw-arrived nil drgnx-perf--sw-handled 0.0 drgnx-perf--sw-wire (list 0 0 nil))
                              (drgnx-replace--rows-step 1)
                              (push (* 1000 (- (float-time) t0)) keys)
                              (when (drgnx-view-nav-paging-p)
                                (let ((lines0 drgnx-perf--sw-lines))
                                  (push (* 1000 (- (or (drgnx-perf--wait 20 (lambda () (not (drgnx-view-nav-paging-p))))
                                                       (error "Premise: the window asked at %s did not come (pending %S, window %S, model lines since %d)"
                                                              (drgnx-view-nav-selection) (car drgnx-view-nav--pending)
                                                              (nidhogg-view-get h 'window "order") (- drgnx-perf--sw-lines lines0)))
                                                   t0))
                                        pages))
                                (push (* 1000 (- drgnx-perf--sw-arrived t0)) lines)
                                (push (format "%d:%.0f" (- gcs-done gc0) (* 1000 (- gc-elapsed gce0))) gcs)
                                (when (= gcs-done gc0) (push (car pages) clean))
                                (push (* 1000 drgnx-perf--sw-handled) handled)
                                (let ((m1 (memory-use-counts)))
                                  (push (/ (drgnx-perf--sw-consed m0 m1) 1024.0) page-kb)
                                  (push (cl-mapcar #'- m1 m0) page-counts)
                                  (push (/ (nth 0 drgnx-perf--sw-wire) 1024.0) wire-model)
                                  (push (/ (nth 1 drgnx-perf--sw-wire) 1024.0) wire-other)
                                  (push (mapconcat (lambda (x) (format "%s" x)) (reverse (nth 2 drgnx-perf--sw-wire)) "+") wire-lines))
                                (setq paged t))
                              (unless paged (push (/ (drgnx-perf--sw-consed m0 (memory-use-counts)) 1024.0) key-kb))
                              (cl-incf key-gcs (- gcs-done gc0))
                              (let ((i (drgnx-perf--sw-index h (drgnx-view-nav-selection))))
                                (push i trace)
                                (unless (> i at) (error "Premise: Next Match went from entry %d to %d (from %d; entries, newest first: %S)"
                                                        at i from (seq-take trace 30)))
                                (setq at i))
                              (setq most (max most (length (nidhogg-view-get h 'list "order"))))))
                (unless paged (error "Premise: round %d's 200 Next Match keys from %d paged no window (at %d)" round from at))))
            (advice-remove 'drgnx-hub--model-line #'drgnx-perf--sw-line)
            (advice-remove 'drgnx-hub--client-batch #'drgnx-perf--sw-batch)
            (when (> most 20000) (error "Premise: Sjá held %d entries, more than the window's 20,000" most))
            (list :key_ms (mapcar #'drgnx-perf--round2 (drgnx-perf-stats keys))
                  :page_ms (mapcar #'drgnx-perf--round2 (drgnx-perf-stats pages))
                  ;; the bar is judged on the pages no collection landed in; those it did are counted, never dropped
                  :page_nogc_ms (mapcar #'drgnx-perf--round2 (drgnx-perf-stats clean))
                  :gc_pages (- (length pages) (length clean))
                  :line_ms (mapcar #'drgnx-perf--round2 (drgnx-perf-stats lines))
                  :handled_ms (mapcar #'drgnx-perf--round2 (drgnx-perf-stats handled))
                  :pages (length pages)
                  :page_each (mapconcat (lambda (x) (format "%.1f" x)) (reverse pages) " ")
                  :line_each (mapconcat (lambda (x) (format "%.1f" x)) (reverse lines) " ")
                  :gc_each (string-join (reverse gcs) " ")
                  ;; what a page conses sets how often the collection lands (SJA-PAGE-GC-1): kB per page and per other
                  ;; key, the page's object counts (`memory-use-counts' order: conses floats vector-cells symbols
                  ;; string-chars intervals strings, medians), the collections the keys took, and the threshold
                  :page_kb (mapcar #'drgnx-perf--round (drgnx-perf-stats page-kb))
                  :key_kb (mapcar #'drgnx-perf--round (drgnx-perf-stats key-kb))
                  :page_counts (mapconcat (lambda (i) (format "%d" (nth i (sort (mapcar (lambda (c) (nth i c)) page-counts) #'<))))
                                          (number-sequence 0 6) " ")
                  :key_gcs key-gcs :keys (length keys)
                  ;; the framed batches' bytes per page: the model lines, and the other messages (row patches, events)
                  :page_wire_model_kb (mapcar #'drgnx-perf--round (drgnx-perf-stats wire-model))
                  :page_wire_other_kb (mapcar #'drgnx-perf--round (drgnx-perf-stats wire-other))
                  :page_model_lines (string-join (reverse wire-lines) " ")
                  :gc_threshold_kb (/ gc-cons-threshold 1024) :gc_percentage gc-cons-percentage
                  :list_max most :from from :to at))))
      t))
  "The `search-window' workload's session side (with the replace workloads' and the hub's).")

(defconst drgnx-perf-run--search-context-form
  (prin1-to-string
   '(progn
      (defvar drgnx-perf--cx nil "The running search: [START RESET FIRST DONE], `float-time's (as search-retype's).")
      (defvar drgnx-perf--cx-dir nil "The directory of the 100 Rust files of 10k matches.")
      (defun drgnx-perf--cx-up ()
        "100 Rust files, each 10 functions of 10 lines that call `needle' (10k matches, 1,000 label rows)."
        (setq drgnx-perf--cx-dir (make-temp-file "drgnx-perf-ctx" t))
        (let ((text (apply #'concat
                           (mapcar (lambda (i) (concat (format "fn f%d() {\n" i)
                                                       (apply #'concat (make-list 10 "    let x = needle(1);\n")) "}\n\n"))
                                   (number-sequence 0 9)))))
          (dotimes (i 100) (with-temp-file (expand-file-name (format "f%03d.rs" i) drgnx-perf--cx-dir) (insert text))))
        (let ((editor (selected-window)))
          (drgnx-replace--open :text "needle"
                               :origin (with-current-buffer (find-file-noselect (expand-file-name "f000.rs" drgnx-perf--cx-dir))
                                         (point-min-marker)))
          (select-window editor))
        (advice-add 'drgnx-view-apply-patch :before #'drgnx-perf--cx-patch)
        (advice-add 'drgnx-replace--rows-boxes :after #'drgnx-perf--cx-drawn)
        (advice-add 'drgnx-replace--hub-event :after #'drgnx-perf--cx-done)
        t)
      (defun drgnx-perf--cx-patch (patch)
        (when-let* ((r drgnx-perf--cx) ((null (aref r 1))) ((equal (plist-get patch :view) drgnx-replace-view))
                    ((drgnx-view-patch--reset-p patch)))
          (aset r 1 (float-time))))
      (defun drgnx-perf--cx-drawn (&rest _)
        (when-let* ((r drgnx-perf--cx) ((aref r 1)) ((null (aref r 2)))
                    ((> (hash-table-count (drgnx-view-patch-rows drgnx-view-patch)) 0)))
          (aset r 2 (float-time))))
      (defun drgnx-perf--cx-done (event data)
        (when-let* (((equal event "search-run-done")) ((equal (plist-get data :view) drgnx-replace-view))
                    ((eql 10000 (plist-get data :matches))) (r drgnx-perf--cx) ((aref r 1)) ((null (aref r 3))))
          (aset r 3 (float-time))))
      (defun drgnx-perf--cx-once (context)
        "One search of the 10k matches with `drgnx-search-context' CONTEXT: (FIRST-MS DONE-MS), from the search's start."
        (let ((drgnx-search-context context) (v (drgnx-perf--replace-view)))
          (setq drgnx-perf--cx (vector (float-time) nil nil nil))
          (with-current-buffer v (drgnx-replace--search-now))
          (unless (drgnx-perf--wait 60 (lambda () (and (aref drgnx-perf--cx 2) (aref drgnx-perf--cx 3)
                                                       (with-current-buffer v (not (drgnx-replace--busy-p))))))
            (error "Premise: the search (context %S) did not draw rows and list 10,000 matches (%S)" context drgnx-perf--cx))
          (let ((r drgnx-perf--cx))
            (list (* 1000 (- (aref r 2) (aref r 0))) (* 1000 (- (max (aref r 2) (aref r 3)) (aref r 0)))))))
      (defun drgnx-perf--cx-measure ()
        "(:on_first_ms :on_done_ms :off_first_ms :off_done_ms STATS, :first_ratio :done_ratio of the p50s): 10 searches
with context labels and 10 without, alternating, after one of each to warm up."
        (drgnx-perf--cx-once t)
        (drgnx-perf--cx-once nil)
        (let (on off)
          (dotimes (_ 10)
            (push (drgnx-perf--cx-once t) on)
            (push (drgnx-perf--cx-once nil) off))
          (let* ((st (lambda (xs i) (drgnx-perf-stats (mapcar (lambda (x) (nth i x)) xs))))
                 (p50 (lambda (s) (plist-get s :p50)))
                 (of (funcall st on 0)) (od (funcall st on 1)) (ff (funcall st off 0)) (fd (funcall st off 1)))
            (list :on_first_ms (mapcar #'drgnx-perf--round of) :on_done_ms (mapcar #'drgnx-perf--round od)
                  :off_first_ms (mapcar #'drgnx-perf--round ff) :off_done_ms (mapcar #'drgnx-perf--round fd)
                  :first_ratio (drgnx-perf--round2 (/ (funcall p50 of) (funcall p50 ff)))
                  :done_ratio (drgnx-perf--round2 (/ (funcall p50 od) (funcall p50 fd)))))))
      (defun drgnx-perf--cx-down ()
        (advice-remove 'drgnx-view-apply-patch #'drgnx-perf--cx-patch)
        (advice-remove 'drgnx-replace--rows-boxes #'drgnx-perf--cx-drawn)
        (advice-remove 'drgnx-replace--hub-event #'drgnx-perf--cx-done)
        (dolist (b (buffer-list))
          (when (and drgnx-perf--cx-dir (buffer-file-name b) (string-prefix-p drgnx-perf--cx-dir (buffer-file-name b)))
            (kill-buffer b)))
        (when drgnx-perf--cx-dir (delete-directory drgnx-perf--cx-dir t)))
      t))
  "The `search-context' workload's session side (with the replace workloads' and the hub's).")

(defconst drgnx-perf-run--search-retype-form
  (prin1-to-string
   '(progn
      (defvar drgnx-perf--rt nil
        "While armed: one record per key that changed the query, newest first: [KEY-T TEXT START RESET FIRST SETTLE]
\(`float-time's; START when its search went to the hub, RESET when the hub's reset of the rows came, FIRST when rows
of the new search were drawn, SETTLE when the search ended with all 10k matches: its end can come before its first
rows are drawn, so a key settles at the later of the two).")
      (defvar drgnx-perf--rt-key-t nil "When the running command's key came.")
      (defvar drgnx-perf--rt-text nil "The query before the running command.")
      (defun drgnx-perf--rt-pre ()
        (setq drgnx-perf--rt-key-t (float-time)
              drgnx-perf--rt-text (with-current-buffer (drgnx-perf--replace-view) (drgnx-replace--text 'find))))
      (defun drgnx-perf--rt-post ()
        (let ((text (with-current-buffer (drgnx-perf--replace-view) (drgnx-replace--text 'find))))
          (unless (equal text drgnx-perf--rt-text)
            (push (vector drgnx-perf--rt-key-t text nil nil nil nil) drgnx-perf--rt))))
      (defun drgnx-perf--rt-start (&rest _)
        (when-let* ((r (car drgnx-perf--rt)) ((null (aref r 2)))) (aset r 2 (float-time))))
      (defun drgnx-perf--rt-patch (patch)
        (when-let* ((r (car drgnx-perf--rt)) ((aref r 2)) ((null (aref r 3)))
                    ((equal (plist-get patch :view) drgnx-replace-view)) ((drgnx-view-patch--reset-p patch)))
          (aset r 3 (float-time))))
      (defun drgnx-perf--rt-drawn (&rest _)
        "After a hub patch was drawn (`drgnx-view-patch-patched-functions', in the view's buffer)."
        (when-let* ((r (car drgnx-perf--rt)) ((aref r 3)) ((null (aref r 4)))
                    ((> (hash-table-count (drgnx-view-patch-rows drgnx-view-patch)) 0)))
          (aset r 4 (float-time))))
      (defun drgnx-perf--rt-done (event data)
        (when-let* (((equal event "search-run-done")) ((equal (plist-get data :view) drgnx-replace-view))
                    ((eql 10000 (plist-get data :matches)))
                    (r (car drgnx-perf--rt)) ((aref r 3)) ((null (aref r 5))))
          (aset r 5 (float-time))))
      (defun drgnx-perf--rt-arm ()
        "The Search view listing the 10k matches of \"needle\" (the hub's rows path), point at the end of its query."
        (drgnx-replace--open :text "needle"
                             :origin (with-current-buffer (find-file-noselect (expand-file-name "f000.txt" drgnx-perf--needles))
                                       (point-min-marker)))
        (let ((v (drgnx-perf--replace-view)))
          (unless (drgnx-perf--wait 60 (lambda () (with-current-buffer v
                                                    (and drgnx-view-patch (eql 10000 (cdr drgnx-replace--hub-counts))
                                                         (not (drgnx-replace--busy-p))))))
            (error "Premise: \"needle\" did not list 10,000 matches on the rows path (counts %S)"
                   (buffer-local-value 'drgnx-replace--hub-counts v)))
          (unless (eq (window-buffer (selected-window)) v) (error "Premise: the Search view is not the selected window"))
          (goto-char (widget-field-text-end (drgnx-replace--widget 'find))))
        (setq drgnx-perf--rt nil)
        (add-hook 'pre-command-hook #'drgnx-perf--rt-pre)
        (add-hook 'post-command-hook #'drgnx-perf--rt-post)
        (advice-add 'drgnx-replace--hub-search :before #'drgnx-perf--rt-start)
        (advice-add 'drgnx-view-apply-patch :before #'drgnx-perf--rt-patch)
        (advice-add 'drgnx-replace--rows-boxes :after #'drgnx-perf--rt-drawn)
        (advice-add 'drgnx-replace--hub-event :after #'drgnx-perf--rt-done)
        t)
      (defun drgnx-perf--rt-disarm ()
        (remove-hook 'pre-command-hook #'drgnx-perf--rt-pre)
        (remove-hook 'post-command-hook #'drgnx-perf--rt-post)
        (advice-remove 'drgnx-replace--hub-search #'drgnx-perf--rt-start)
        (advice-remove 'drgnx-view-apply-patch #'drgnx-perf--rt-patch)
        (advice-remove 'drgnx-replace--rows-boxes #'drgnx-perf--rt-drawn)
        (advice-remove 'drgnx-replace--hub-event #'drgnx-perf--rt-done))
      (defun drgnx-perf--rt-measure ()
        "(:first_ms STATS :settle_ms STATS :search_first_ms STATS :keys N :settled N): per key that changed the query,
from the key to the first rows of its search drawn (the typing pause, `drgnx-replace-delay', included) and to its
search's end with all 10k matches listed (only keys whose search ended before the next key); from the search's start
to its first rows.  An error when a key's search drew no rows before the next key, or the last search did not end."
        (drgnx-perf--wait 30 (lambda () (when-let* ((r (car drgnx-perf--rt))) (aref r 5))))
        (drgnx-perf--rt-disarm)
        (let ((rs (reverse drgnx-perf--rt)) (ms (lambda (a b) (* 1000 (- b a)))))
          (when-let* ((bad (seq-find (lambda (r) (null (aref r 4))) rs)))
            (error "Premise: the search of %S drew no rows before the next key (%S)" (aref bad 1) bad))
          (unless (aref (car (last rs)) 5) (error "Premise: the last search (%S) did not end" (aref (car (last rs)) 1)))
          (list :first_ms (mapcar #'drgnx-perf--round (drgnx-perf-stats (mapcar (lambda (r) (funcall ms (aref r 0) (aref r 4))) rs)))
                :settle_ms (mapcar #'drgnx-perf--round
                                   (drgnx-perf-stats (delq nil (mapcar (lambda (r) (and (aref r 5) (funcall ms (aref r 0) (max (aref r 4) (aref r 5))))) rs))))
                :search_first_ms (mapcar #'drgnx-perf--round (drgnx-perf-stats (mapcar (lambda (r) (funcall ms (aref r 2) (aref r 4))) rs)))
                :keys (length rs) :settled (seq-count (lambda (r) (aref r 5)) rs))))
      t))
  "The `search-retype' workload's session side (with the replace workloads' and the hub's).")

(defun drgnx-perf-run--hub-form ()
  "The agent workloads' setup, as a form string: the session functions that start Ratatoskr (a test-hooks build,
$DRGNX_RATATOSKR_BIN, with `ratatoskr-mock' beside it) for the workload, give it the profile \"mock\"
\(`ratatoskr-mock acp' running a script whose n-th line is the n-th prompt's program) and follow a turn through
its transcript.  A turn is over when its `stop' entry is in the mirror: the hub sends a session's state at most
every 50 ms, so a turn can go by with no busy status in between and the status cannot tell it."
  (concat
   ;; the session's environment is the harness's allowlist: the binary's name goes in the form
   "(progn (defvar drgnx-perf--hub-bin nil \"The Ratatoskr binary.\") (setq drgnx-perf--hub-bin "
   (prin1-to-string (getenv "DRGNX_RATATOSKR_BIN")) ") "
   (prin1-to-string
    '(progn
       (require 'drgnx-agents-mirror)
       (require 'drgnx-hub-client)
       (defvar drgnx-perf--hub nil "The hub process of the workload.")
       (defvar drgnx-perf--hub-dir nil "Its folder: settings, the mock's script, the hub's data.")
       (defvar drgnx-perf--sent nil "Alist: session → how many prompts the workload sent it.")
       (defun drgnx-perf--slow ()
         "The program of a turn that lasts three seconds: ten chunks, 0.3 s apart."
         (mapconcat #'identity (cl-loop for i below 10 append (list (format "say chunk %d" i) "silent 0.3")) "\\n"))
       (defun drgnx-perf--stream ()
         "The program of a turn whose answer starts 400 kB long, then grows by 100-character chunks, 50 a second (five
every tenth of a second) for thirty seconds: the typing of six strings takes longer than ten in the container."
         (concat "say " (make-string 409599 ?a) "\\n"
                 (mapconcat #'identity
                            (cl-loop repeat 300 append (append (make-list 5 (concat "say " (make-string 99 ?a))) (list "silent 0.1")))
                            "\\n")))
       (defvar drgnx-perf--wait-on nil "The running wait's (BUFFER PRED MET): MET is when PRED first held.")
       (defun drgnx-perf--wait-check (&rest _)
         "After a hub batch or a timer: note when the running wait's predicate first held, in the wait's buffer."
         (when-let* ((w drgnx-perf--wait-on) ((not (nth 2 w))) ((buffer-live-p (nth 0 w))))
           (when (with-current-buffer (nth 0 w) (funcall (nth 1 w)))
             (setcar (nthcdr 2 w) (float-time)))))
       (defun drgnx-perf--wait (secs pred)
         "Let the session run until PRED holds (at most SECS s): when it first held (a `float-time'), or nil.
PRED is also tried after each hub batch and each timer, so the time is the change's own: the poll can see it up to
50 ms later (a timer the poll runs does not end it, nor a batch some other wait inside it took), and a span timed
at the wait's return held that."
         (let ((d (+ (float-time) secs)) (outer drgnx-perf--wait-on)
               (drgnx-perf--wait-on (list (current-buffer) pred nil)))
           (unless outer
             (advice-add 'drgnx-hub--client-batch :after #'drgnx-perf--wait-check)
             (advice-add 'timer-event-handler :after #'drgnx-perf--wait-check))
           (unwind-protect
               (progn
                 (while (and (not (nth 2 drgnx-perf--wait-on)) (not (funcall pred)) (< (float-time) d))
                   (accept-process-output nil 0.05))
                 (or (nth 2 drgnx-perf--wait-on) (and (funcall pred) (float-time))))
             (unless outer
               (advice-remove 'drgnx-hub--client-batch #'drgnx-perf--wait-check)
               (advice-remove 'timer-event-handler #'drgnx-perf--wait-check)))))
       (defun drgnx-perf--hub-start (lines)
         "Start Ratatoskr with the profile \"mock\" whose turns run LINES (the n-th prompt runs the n-th), and connect."
         (let* ((bin drgnx-perf--hub-bin)
                (mock (and bin (expand-file-name "ratatoskr-mock" (file-name-directory bin))))
                (dir (make-temp-file "drgnx-perf-hub" t))
                (script (expand-file-name "script.txt" dir)) (config (expand-file-name "config" dir)))
           (unless (and mock (file-executable-p bin) (file-executable-p mock))
             (error "The agent workloads need DRGNX_RATATOSKR_BIN (a test-hooks ratatoskr) with ratatoskr-mock beside it"))
           (setq drgnx-perf--hub-dir dir drgnx-perf--sent nil)
           (with-temp-file script (dolist (l lines) (insert l "\n")))
           (make-directory config t)
           (with-temp-file (expand-file-name "settings.el" config)
             (prin1 (list 'drgnx-settings :version 1
                          (list 'drgnx-agents-profiles
                                (list (list "mock" :command (list mock "acp" "--as" "claude" "--script" script)))))
                    (current-buffer)))
           (let ((process-environment (append (list (concat "DRGNX_CONFIG_DIR=" config) "RATATOSKR_SUPERVISOR=none"
                                                    (concat "DRGNX_DIR=" (directory-file-name drgnx-dir)))
                                              process-environment)))
             (setq drgnx-perf--hub
                   (make-process :name "ratatoskr" :noquery t :connection-type 'pipe
                                 :buffer (generate-new-buffer " *ratatoskr*")
                                 :command (list bin "serve" "--foreground" "--parent-pid" (number-to-string (emacs-pid))))))
           (unless (drgnx-perf--wait 30 #'drgnx-hub-running-p) (error "Ratatoskr did not answer a ping"))
           (drgnx-hub-connect)
           (drgnx-hub-ensure)
           t))
       (defun drgnx-perf--hub-stop ()
         "End the hub, drop its mirrors and its folder."
         (ignore-errors (drgnx-agents-mirror-stop))
         (ignore-errors (drgnx-hub-disconnect))
         (when (process-live-p drgnx-perf--hub)
           (signal-process drgnx-perf--hub 'term)
           (unless (drgnx-perf--wait 10 (lambda () (not (process-live-p drgnx-perf--hub))))
             (signal-process drgnx-perf--hub 'kill)))
         (when (and drgnx-perf--hub (buffer-live-p (process-buffer drgnx-perf--hub))) (kill-buffer (process-buffer drgnx-perf--hub)))
         (setq drgnx-perf--hub nil
               drgnx-agents--sessions (seq-remove #'drgnx-agent-session-remote drgnx-agents--sessions))
         (when drgnx-perf--hub-dir (ignore-errors (delete-directory drgnx-perf--hub-dir t)) (setq drgnx-perf--hub-dir nil))
         t)
       (defun drgnx-perf--send (s text)
         "Send TEXT to mirror S, counting it."
         (setf (alist-get s drgnx-perf--sent) (1+ (or (alist-get s drgnx-perf--sent) 0)))
         (drgnx-agents-send s text))
       (defun drgnx-perf--turns (s)
         (seq-count (lambda (e) (eq (plist-get e :type) 'stop)) (drgnx-agent-session-entries s)))
       (defun drgnx-perf--running-p (s)
         "Whether a turn S was sent has not ended (its `stop' entry is not in the mirror yet)."
         (< (drgnx-perf--turns s) (or (alist-get s drgnx-perf--sent) 0)))
       t))
   ")"))

(defvar drgnx-perf-ab-min-rounds)   ; below, with the A/B

(defun drgnx-perf-run--workloads ()
  "The workloads:(NAME :setup FORM :each FORM :actions ACTIONS :check FORM :measure FORM :teardown FORM :repeat N).
Every workload runs three times (medians are kept); :each runs before each repeat, :check after it (an
error if it does not hold).  With :actions, :measure runs after the input and its plist joins the run's."
  (let ((type (lambda (s) (list :type s))) (keys (lambda (k n) (make-list n (list :keys k))))
        (kill-fixture (format "(progn (when-let* ((b (find-buffer-visiting %S))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)) t)"
                              (or drgnx-perf-run--fixture ""))))
    `((typing :each ,(drgnx-perf-run--visit-fixture-form)
              :actions ,(make-list 6 (funcall type "(let ((x 1)) (message \"%s\" x)) ")) :teardown ,kill-fixture)
      (scrolling :each ,(concat "(progn " (drgnx-perf-run--visit-fixture-form) " (goto-char (point-min)) t)")
                 :actions ,(append (funcall keys "<next>" 30) (funcall keys "<prior>" 30)) :teardown ,kill-fixture)
      (tabs :setup ,(format "(progn (dolist (f (seq-take (directory-files %S t \"\\\\.el\\'\") 20)) (find-file f)) t)"
                            (expand-file-name "wb" drgnx-ui-repo-dir))
            :actions ,(funcall keys "C-<next>" 20)
            :teardown ,(format "(progn (dolist (b (buffer-list)) (when (and (buffer-file-name b) (string-prefix-p %S (buffer-file-name b))) (kill-buffer b))) t)"
                               (expand-file-name "wb" drgnx-ui-repo-dir)))
      (explorer :setup ,(format "(progn (drgnx-explorer-set-roots (list %S)) (drgnx-wb-show-sidebar) t)" drgnx-ui-repo-dir)
                :each "(progn (drgnx-explorer-focus) (goto-char (point-min)) (drgnx-wb-focus-editor) t)"
                ;; the root shows ~12 rows: 10 downs, each one moves
                :actions ,(append (list (list :keys "C-S-e")) (funcall keys "<down>" 10) (list (list :keys "<escape>"))))
      ;; the agent is a `ratatoskr-mock acp' in a Ratatoskr hub (the editor holds a mirror): its turn is three seconds
      (agent-typing :setup ,(concat "(progn " (drgnx-perf-run--hub-form)
                                    " (drgnx-perf--hub-start (make-list 6 (drgnx-perf--slow)))"
                                    " (setq drgnx-perf--agent (drgnx-agents-mirror-start \"mock\" temporary-file-directory))"
                                    " (drgnx-perf--wait 10 (lambda () (eq (drgnx-agent-session-status drgnx-perf--agent) 'idle)))"
                                    " (drgnx-agent-panel-list-show) t)")
                    :each ,(concat "(progn " (drgnx-perf-run--visit-fixture-form)
                                   " (drgnx-perf--wait 15 (lambda () (not (drgnx-perf--running-p drgnx-perf--agent))))"
                                   " (drgnx-perf--send drgnx-perf--agent \"slow\") t)")
                    :actions ,(make-list 2 (funcall type "(setq y 2) "))
                    :check "(drgnx-perf--running-p drgnx-perf--agent)"   ; typed while it streamed
                    :teardown ,(concat "(progn (ignore-errors (drgnx-agents-kill drgnx-perf--agent)) (drgnx-perf--hub-stop) " kill-fixture ")"))
      ;; a long code file with sticky scroll, indent guides (when installed) and smooth scrolling on
      (code-scrolling
       :setup ,(format "(progn (dolist (m '(\"editor/drgnx-sticky\" \"ui/drgnx-smooth\" \"extra/drgnx-guides\")) (load (expand-file-name (concat \"modules/\" m) %S) nil t)) (drgnx-smooth--setup) t)"
                       drgnx-ui-repo-dir)
       ;; the 12k-line fixture: 30 pages down and up never reach its end
       :each ,(concat "(progn " (drgnx-perf-run--visit-fixture-form)
                      " (goto-char (point-min)) (drgnx-sticky-mode 1) (when (require 'indent-bars nil t) (drgnx-guides--maybe)) t)")
       :actions ,(append (funcall keys "<next>" 30) (funcall keys "<prior>" 30))
       :teardown ,kill-fixture)
      ;; the diff view, split, on a 10k-line diff (built in the session: no git needed)
      (diff-scrolling
       :setup ,(format "(progn (load (expand-file-name \"modules/tools/drgnx-diff\" %S) nil t) t)" drgnx-ui-repo-dir)
       :each ,(concat "(progn (switch-to-buffer (get-buffer-create \"*diff: perf*\")) (drgnx-diff-mode)"
                      " (setq drgnx-diff-layout 'split drgnx-diff--folded nil"
                      "       drgnx-diff--files (let ((drgnx-diff-fold-lines most-positive-fixnum))"
                      "                          (drgnx-diff-parse (concat \"diff --git a/big.el b/big.el\\n--- a/big.el\\n+++ b/big.el\\n@@ -1,10000 +1,10000 @@\\n\""
                      "                            (mapconcat (lambda (i) (if (zerop (% i 7)) (format \"-(old %d)\\n+(new %d)\\n\" i i) (format \" (ctx %d)\\n\" i))) (number-sequence 1 10000) \"\")))))"
                      " (setq drgnx-diff--folded (make-vector 1 nil)) (drgnx-diff--render) (goto-char (point-min)) t)")
       :actions ,(append (funcall keys "<next>" 30) (funcall keys "<prior>" 30))
       :teardown "(progn (when (get-buffer \"*diff: perf*\") (kill-buffer \"*diff: perf*\")) t)")
      ;; ghost text on: a mock model answers every pause at once (the pause shortened so each key asks and the
      ;; next one cancels — the most work a keystroke can bring)
      (typing-with-ghost
       :setup ,(format "(progn (load %S nil t)
                       (let* ((port (+ 20000 (random 20000))) (dir (make-temp-file \"drgnx-perf-llm\" t))
                              (script (expand-file-name \"llm.eld\" dir)) (log (expand-file-name \"llm.log\" dir)))
                         ;; /api/tags: the probe (drgnx runs one once idle) finds it running
                         (with-temp-file script (prin1 '((:path \"/api/tags\" :body \"{\\\"models\\\":[{\\\"name\\\":\\\"coder\\\"}]}\")
                                                         (:path \"/api/generate\" :body \"{\\\"response\\\":\\\"(message \\\\\\\"%%s\\\\\\\" x)\\\"}\"))
                                                       (current-buffer)))
                         ;; the provider and the role as settings (their default values: what callers read); the
                         ;; session's own come back in the teardown
                         (setq drgnx-perf--llm (list :proc (drgnx-ai-test-mock-llm port script log) :dir dir :log log :delay drgnx-ai-ghost-delay
                                                     :providers (default-value 'drgnx-ai-providers) :roles (default-value 'drgnx-ai-roles))
                               drgnx-ai-ghost-delay 0.01)
                         (setq-default drgnx-ai-providers (list (list 'perf-llm :name \"Perf\" :kind 'ollama :url (format \"http://127.0.0.1:%%d\" port) :caps '(fim)))
                                       drgnx-ai-roles '((complete (perf-llm . \"coder\"))))
                         (push '(perf-llm :up t) drgnx-ai-detected))
                       t)"
                       (expand-file-name "test/fixtures/mock-llm.el" drgnx-ui-repo-dir))
       :each ,(drgnx-perf-run--visit-fixture-form)
       :actions ,(make-list 6 (funcall type "(let ((x 1)) (message \"%s\" x)) "))
       :check "(with-temp-buffer (insert-file-contents (plist-get drgnx-perf--llm :log)) (> (how-many \"POST /api/generate\") 0))"   ; it asked
       :teardown ,(concat "(progn (ignore-errors (delete-process (plist-get drgnx-perf--llm :proc)))
                       (ignore-errors (delete-directory (plist-get drgnx-perf--llm :dir) t))
                       (when drgnx-perf--llm
                         (setq-default drgnx-ai-providers (plist-get drgnx-perf--llm :providers)
                                       drgnx-ai-roles (plist-get drgnx-perf--llm :roles)))
                       (setq drgnx-ai-ghost-delay (plist-get drgnx-perf--llm :delay)
                             drgnx-ai-detected (assq-delete-all 'perf-llm drgnx-ai-detected)) "
                          kill-fixture ")"))
      ;; typing while the Search view lists 10k matches (100 files): the search starts on the first key; a hub of the
      ;; workload searches and streams the 10k matches as rows
      (replace-typing-rows
       :setup ,(concat "(progn " (drgnx-perf-run--hub-form) " (drgnx-perf--hub-start nil) " (drgnx-perf-run--replace-setup-form) ")")
       :each ,(concat "(progn " (drgnx-perf-run--visit-fixture-form) " (drgnx-perf--replace-arm) t)")
       :actions ,(make-list 2 (funcall type "(setq y 2) "))
       :measure "(drgnx-perf--retype-measure)"     ; the view draws while the 10k matches stream
       :complete-when "(drgnx-perf--replace-done)"   ; the whole operation: first key to the last row applied
       :check "(and (drgnx-perf--replace-check) (buffer-local-value 'drgnx-view-patch (drgnx-perf--replace-view)) t)"
       :teardown ,(concat "(progn (drgnx-perf--replace-teardown) (drgnx-perf--hub-stop) " kill-fixture ")"))
      ;; Next Match across the model's 20,000-entry window of a 30k-match search, on the rows path (plan sja-complete W1)
      (search-window
       :setup ,(concat "(progn " (drgnx-perf-run--hub-form) " (drgnx-perf--hub-start nil) " (drgnx-perf-run--replace-setup-form)
                       " " drgnx-perf-run--search-window-form " (drgnx-perf--sw-up))")
       :measure "(drgnx-perf--sw-measure)"
       :teardown ,(concat "(progn (drgnx-perf--replace-teardown) (drgnx-perf--hub-stop) " kill-fixture ")"))
      ;; the Search view's context label rows: 10k matches in 100 Rust files (1,000 labels), searched with the labels
      ;; and without, 10 times each: the first rows and the end with them against without (search view plan T4)
      (search-context
       :setup ,(concat "(progn " (drgnx-perf-run--hub-form) " (drgnx-perf--hub-start nil) " (drgnx-perf-run--replace-setup-form)
                       " " drgnx-perf-run--search-context-form " (drgnx-perf--cx-up))")
       :measure "(drgnx-perf--cx-measure)"
       :teardown ,(concat "(progn (drgnx-perf--cx-down) (drgnx-perf--replace-teardown) (drgnx-perf--hub-stop) " kill-fixture ")"))
      ;; retyping the Search view's query over 10k matches on the hub's rows path, a character at a time: "needle" to
      ;; "needl", "need", "needl", "needle" 25 times (100 keys, each a search of 10k matches); a pause of 0.6 s
      ;; after each key (the 0.25 s typing pause runs out, the next key may land while the rows stream) and 1.5 s after
      ;; every fourth (its search ends)
      (search-retype
       :setup ,(concat "(progn " (drgnx-perf-run--hub-form) " (drgnx-perf--hub-start nil) " (drgnx-perf-run--replace-setup-form)
                       " " drgnx-perf-run--search-retype-form ")")
       :each "(drgnx-perf--rt-arm)"
       :actions ,(apply #'append (make-list 25 '((:keys "DEL") (:pause 0.6) (:keys "DEL") (:pause 0.6)
                                                 (:type "l") (:pause 0.6) (:type "e") (:pause 1.5))))
       :measure "(drgnx-perf--rt-measure)"
       :check "(and (equal (with-current-buffer (drgnx-perf--replace-view) (drgnx-replace--text 'find)) \"needle\")
                    (eql 10000 (cdr (buffer-local-value 'drgnx-replace--hub-counts (drgnx-perf--replace-view)))))"
       :teardown ,(concat "(progn (drgnx-perf--rt-disarm) (drgnx-perf--replace-teardown) (drgnx-perf--hub-stop) " kill-fixture ")"))
      ;; typing while the Live view shows frames from a mock browser (30 a second, each once the last was acked)
      (live-view
       :setup ,(drgnx-perf-run--live-setup-form)
       :each ,(concat "(progn " (drgnx-perf-run--visit-fixture-form) " (drgnx-perf--live-arm) t)")
       :actions ,(make-list 6 (funcall type "(let ((x 1)) (message \"%s\" x)) "))
       :measure "(drgnx-perf--live-measure)"
       :check "(drgnx-perf--live-check)"
       :teardown ,(concat "(progn (drgnx-perf--live-teardown) " kill-fixture ")"))
      ;; opening the Claude Code settings page on a 5 MB .claude.json, 50 MCP servers and 200 skills: drawn, no process
      (agent-settings-open
       :setup ,(drgnx-perf-run--agent-settings-setup-form)
       :each "(progn (dolist (b (buffer-list)) (when (string-prefix-p \"*agent settings: \" (buffer-name b)) (kill-buffer b))) t)"
       :measure ,drgnx-perf-run--agent-settings-measure-form
       :teardown ,drgnx-perf-run--agent-settings-teardown-form)
      ,@(drgnx-perf-settings-workloads)
      ,@(drgnx-perf-extensions-workloads)
      ;; typing in a local file while a remote root is listed in the Explorer and its connection is dead
      (remote-typing
       :setup ,(drgnx-perf-run--remote-setup-form)
       :each ,(drgnx-perf-run--visit-fixture-form)
       :actions ,(make-list 6 (funcall type "(let ((x 1)) (message \"%s\" x)) "))
       :check ,(concat "(and (zerop drgnx-tramp-mock-sends)"                  ; nothing sent to the remote
                       " (not (process-live-p (tramp-get-connection-process (tramp-dissect-file-name (nth 1 drgnx-perf--remote)))))"
                       " t)")
       :teardown ,(concat "(progn " drgnx-perf-run--remote-teardown-form " " kill-fixture ")"))
      ;; the typing workload with the drgnx repo's search index loaded in memory and the search module on
      (typing-with-index
       :setup ,(drgnx-perf-run--index-setup-form)
       :each ,(drgnx-perf-run--visit-fixture-form)
       :actions ,(make-list 6 (funcall type "(let ((x 1)) (message \"%s\" x)) "))
       :check "(drgnx-perf--index-check)"
       :teardown ,(concat "(progn (drgnx-perf--index-teardown) " kill-fixture ")"))
      ;; C-x o ×50 across 3 editor groups showing one file, the dock, panel and right dock shown: the cost of moving
      ;; the selection, the baseline for the workbench state store's observer
      (window-switch
       :setup ,(drgnx-perf-run--window-switch-setup-form)
       :each ,(drgnx-perf-run--window-switch-each-form)
       :actions ,(make-list 50 '(:keys "C-x o"))
       :check "(and (= drgnx-perf--ws-count 50) (= (length (drgnx-groups-list)) 3) (drgnx-wb-sidebar-showing-p)
                       (drgnx-wb-area-window 'panel) (drgnx-wb-area-window 'right) t)"
       :repeat 3
       :teardown ,(concat "(progn " drgnx-perf-run--window-switch-teardown-form " " kill-fixture ")"))
      ;; typing in drgnx's terminal (cat: the tty echoes every key, the worker draws it)
      (terminal-typing
       :setup ,(drgnx-perf-run--terminal-setup-form "cat")
       :each "(progn (pop-to-buffer drgnx-perf--term) (select-window (get-buffer-window drgnx-perf--term)) t)"
       :actions ,(make-list 6 (funcall type "echo hello world 123"))
       :check "(drgnx-perf--term-live-p)"
       :teardown "(drgnx-perf--term-teardown)")
      ;; typing in the fixture while a terminal in the panel streams output (seq 1 2000, in a loop); the terminal's
      ;; draws and the session's allocation while it streams
      (terminal-output
       :setup ,(drgnx-perf-run--terminal-setup-form "sh" "-c" "while :; do seq 1 2000; done")
       :each ,(concat "(progn (drgnx-wb-focus-editor) " (drgnx-perf-run--visit-fixture-form)
                      " (drgnx-perf--term-show) (setq drgnx-perf--term-tick (buffer-chars-modified-tick drgnx-perf--term))"
                      " (drgnx-perf--term-arm) t)")
       :timers t
       :actions ,(make-list 6 (funcall type "echo hello world 123"))
       :measure "(drgnx-perf--term-measure)"
       :check "(and (drgnx-perf--term-live-p) (get-buffer-window drgnx-perf--term)
                    (> (buffer-chars-modified-tick drgnx-perf--term) drgnx-perf--term-tick) t)"   ; output streamed while typing
       :teardown ,(concat "(progn (drgnx-perf--term-teardown) " kill-fixture ")"))
      ;; `cat' of 10 MB and of 100 MB into a terminal in the panel, timed to the mark after it on screen
      (terminal-output-10mb
       :setup ,(drgnx-perf-run--terminal-setup-form "cat")
       :measure "(drgnx-perf--term-flood (* 10 1024 1024))"
       :teardown "(drgnx-perf--term-teardown)")
      (terminal-output-100mb
       :setup ,(drgnx-perf-run--terminal-setup-form "cat")
       :measure "(drgnx-perf--term-flood (* 100 1024 1024))"
       :teardown "(drgnx-perf--term-teardown)")
      ;; end to end: a key read to its echo drawn, in a terminal running `cat' while 30 mock agents stream (their
      ;; Work map shown) and a second terminal in the panel floods (seq 1 2000 in a loop); one hub carries it all
      (terminal-echo
       :setup ,(concat "(progn " (drgnx-perf-run--hub-form) " " (drgnx-perf-work--lib-form) " (drgnx-perf--work-up t) (drgnx-wb-focus-editor) "
                       (drgnx-perf-run--terminal-lib-form '("cat") '("sh" "-c" "while :; do seq 1 2000; done")) " t)")
       :each "(progn (drgnx-perf--work-premise) (select-window (get-buffer-window drgnx-perf--term)) (drgnx-perf--term-arm) t)"
       :actions ,(make-list 6 (funcall type "echo hello world 123"))
       :measure "(drgnx-perf--term-measure)"
       :check "(and (drgnx-perf--term-live-p) (drgnx-perf--term-live-p drgnx-perf--term2) (get-buffer-window drgnx-perf--term2)
                    (drgnx-perf--work-premise) t)"
       :teardown ,(concat "(progn (drgnx-perf--term-teardown) (drgnx-perf--work-down) " kill-fixture " t)"))
      ;; the same key path with nothing else running: the hop's own cost
      (terminal-echo-idle
       :setup ,(drgnx-perf-run--terminal-setup-form "cat")
       :each "(progn (pop-to-buffer drgnx-perf--term) (select-window (get-buffer-window drgnx-perf--term)) (drgnx-perf--term-arm) t)"
       :actions ,(make-list 6 (funcall type "echo hello world 123"))
       :measure "(drgnx-perf--term-measure)"
       :check "(drgnx-perf--term-live-p)"
       :teardown "(drgnx-perf--term-teardown)")
      ;; the terminal streaming (`seq 1 2000' in a loop) for 10 s with no key typed: the measure is only the wait, so a
      ;; profile of it (DRGNX_PERF_PROFILE) shows the stream's decode and draws, which a typed-key run buries
      (terminal-flood
       :setup ,(drgnx-perf-run--terminal-setup-form "sh" "-c" "while :; do seq 1 2000; done")
       :each "(progn (drgnx-perf--term-show) t)"
       :measure "(drgnx-perf--term-watch 10)"
       :check "(drgnx-perf--term-live-p)"
       :teardown "(drgnx-perf--term-teardown)")
      ;; `seq 1 10000' then the backfill of the rows that scrolled past: the draws' slices while it fills, and the heap
      ;; of the full 10k-line terminal (terminal-memory's number, recorded only)
      (terminal-backfill
       :setup ,(drgnx-perf-run--terminal-setup-form "cat")
       :measure "(drgnx-perf--term-backfill)"
       :teardown "(drgnx-perf--term-teardown)")
      ;; the off-the-main-thread workloads (§17.6): report-only until their step lands (harness/drgnx-perf-workloads.el)
      ,@(drgnx-perf-workers-workloads)
      ;; the Work space: 30 streaming mock agents, the map shown or hidden (harness/drgnx-perf-work.el)
      ,@(drgnx-perf-work-workloads (drgnx-perf-run--visit-fixture-form) kill-fixture)
      ;; the agents in the editor: five streaming mock agents, a 3,000-line file (harness/drgnx-perf-agents.el)
      ,@(drgnx-perf-agents-workloads)
      (frames :measure "(list :frame (drgnx-perf-frame-ms 5))")
      (redisplay :each ,(drgnx-perf-run--visit-fixture-form) :measure "(list :redisplay (drgnx-perf-redisplay-ms 30))" :teardown ,kill-fixture)
      (startup :daemon t)
      ;; what a user's Emacs holds: a collection, then a key and the pause after it, in which the idle collection's
      ;; timer gives the freed heap back (`drgnx-gc--idle'); RSS is read once it has
      (memory :each "(progn (garbage-collect) t)" :actions ((:keys "<down>"))
              :complete-when "(or (not (fboundp 'malloc-trim)) (eql drgnx-gc--trimmed gcs-done))"
              :measure "(list :rss_kb (drgnx-perf-rss-kb))")
      ,@(drgnx-perf-run--childframe-workloads)
      ;; last: evil cannot be unloaded from the session, so the workloads above stay as they were without it
      ,@(drgnx-perf-run--modal-workloads))))

;;;; Glitnir (the compositor): popups and the full window

(defconst drgnx-perf-run-childframe-skipped
  "perf: popup workloads skipped — set DRGNX_CHILDFRAME_ELPA (docs/develop/perf.md)"
  "The line printed when the popup workloads are left out.")

(defun drgnx-perf-run--childframe-elpa ()
  "The package directory $DRGNX_CHILDFRAME_ELPA names (the pinned posframe, corfu, eldoc-box:
`drgnx childframe-elpa'), or nil."
  (let ((dir (getenv "DRGNX_CHILDFRAME_ELPA")))
    (and dir (not (string-empty-p dir)) (expand-file-name dir))))

(defconst drgnx-perf-run--popup-setup-form
  "(progn (or (drgnx-uitest-childframe-packages) (error \"DRGNX_CHILDFRAME_ELPA lacks a pinned package\")) t)"
  "The setup of a popup workload: the pinned packages on `load-path' in the session.")

(defconst drgnx-perf-run--popup-scratch-form
  "(progn (switch-to-buffer (get-buffer-create \"*perf-popup*\")) (erase-buffer) (emacs-lisp-mode) t)"
  "A fresh Emacs Lisp buffer for a popup workload.")

(defconst drgnx-perf-run--popup-scratch-teardown
  "(when-let* ((b (get-buffer \"*perf-popup*\"))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))"
  "The popup buffer gone.")

(defun drgnx-perf-run--childframe-workloads ()
  "The popup workloads, or nil without $DRGNX_CHILDFRAME_ELPA (`drgnx-perf-run-childframe-skipped' says so), and the
full-window one (it needs no package): `popup-typing' (corfu open, 200 characters), `popup-churn' (a posframe shown,
moved and hidden 200 times; the hides are measured), `scroll-under-popup' (eldoc-box at point, 60 <next> then 60
<prior>), `scroll-full-window' (one window filling the frame, <down> x 300).  Glitnir's frame-time record joins each run
under :compose (the compose probe)."
  (let ((keys (lambda (k n) (make-list n (list :keys k))))
        (kill-fixture (format "(when-let* ((b (find-buffer-visiting %S))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))"
                              (or drgnx-perf-run--fixture "")))
        (only-window "(progn (ignore-errors (drgnx-wb-area-hide 'panel)) (ignore-errors (drgnx-wb-area-hide 'right)) (delete-other-windows) t)"))
    (append
     (when (drgnx-perf-run--childframe-elpa)
       `((popup-typing
          :setup ,(concat "(progn " drgnx-perf-run--popup-setup-form " (require 'corfu)
                           (setq corfu-auto t corfu-auto-delay 0 corfu-auto-prefix 1) (global-corfu-mode 1) t)")
          :each ,drgnx-perf-run--popup-scratch-form
          :actions ,(make-list 10 (list :type "(car (cdr (list buff "))   ; 21 characters each: 210 in all
          :check "(with-current-buffer (window-buffer (selected-window)) (and (bound-and-true-p corfu-mode) (> (buffer-size) 200)))"
          :teardown ,(concat "(progn (global-corfu-mode -1) " drgnx-perf-run--popup-scratch-teardown " t)"))
         ;; one key = one show, one move and one hide of a posframe (F9 is bound for the workload only)
         (popup-churn
          :setup ,(concat "(progn " drgnx-perf-run--popup-setup-form " (require 'posframe)
                           (defvar drgnx-perf--churn 0 \"Cycles done.\")
                           (defun drgnx-perf--churn-step ()
                             (interactive)
                             (posframe-show \" *perf-churn*\" :string \"popup\" :position (point) :border-width 1)
                             (posframe-show \" *perf-churn*\" :string \"popup\" :position (1+ (point)) :border-width 1)
                             (posframe-hide \" *perf-churn*\")
                             (setq drgnx-perf--churn (1+ drgnx-perf--churn)))
                           (global-set-key (kbd \"<f9>\") #'drgnx-perf--churn-step) t)")
          :each ,(concat "(progn " drgnx-perf-run--popup-scratch-form " (insert \"x\") (setq drgnx-perf--churn 0) t)")
          :actions ,(funcall keys "<f9>" 200)
          :check "(= drgnx-perf--churn 200)"
          :teardown ,(concat "(progn (global-unset-key (kbd \"<f9>\")) (fmakunbound 'drgnx-perf--churn-step) (posframe-delete-all) "
                             drgnx-perf-run--popup-scratch-teardown " t)"))
         ;; the fixture scrolls under an eldoc-box shown at point
         (scroll-under-popup
          :setup ,(concat "(progn " drgnx-perf-run--popup-setup-form " (require 'eldoc-box) t)")
          :each ,(concat "(progn " (drgnx-perf-run--visit-fixture-form)
                         " (goto-char (point-min)) (eldoc-box--display \"perf popup\\nunder the scroll\") t)")
          :actions ,(append (funcall keys "<next>" 60) (funcall keys "<prior>" 60))
          :check "(with-current-buffer (window-buffer (selected-window)) (> (buffer-size) 100000))"
          :teardown ,(concat "(progn (ignore-errors (eldoc-box-quit-frame)) " kill-fixture " t)"))))
     `((scroll-full-window
        :each ,(concat "(progn " only-window " " (drgnx-perf-run--visit-fixture-form) " (goto-char (point-min)) t)")
        :actions ,(funcall keys "<down>" 300)   ; C-n is File > New in the default key stack
        :check "(with-current-buffer (window-buffer (selected-window)) (> (line-number-at-pos) 250))"
        :teardown ,(concat "(progn " kill-fixture " t)"))))))

;;;; Typing, motions and the Explorer with evil (Vim keys)

(defconst drgnx-perf-run-modal-skipped
  "perf: evil workloads skipped — set DRGNX_MODAL_ELPA (docs/develop/perf.md)"
  "The line printed when the evil workloads are left out.")

(defconst drgnx-perf-run--vim-keys '((vim app editing window)) "The key stack the evil workloads run with.")
(defconst drgnx-perf-run--vscode-keys '((vscode app editing window)) "The key stack they put back.")

(defun drgnx-perf-run--modal-elpa ()
  "The package directory $DRGNX_MODAL_ELPA names (evil and what it needs, as `drgnx sync' makes it), or nil."
  (let ((dir (getenv "DRGNX_MODAL_ELPA")))
    (and dir (not (string-empty-p dir)) (expand-file-name dir))))

(defun drgnx-perf-run--modal-setup-form (elpa)
  "The setup of an evil workload: evil's directories on `load-path' in the session, the engine started, Vim keys on."
  (prin1-to-string
   `(progn
      (dolist (d (directory-files ,elpa t "\\`\\(evil\\|goto-chg\\|evil-collection\\|annalist\\)-[0-9]"))
        (add-to-list 'load-path d))
      (drgnx-modules-set-enabled 'editor/evil t)
      (unless (drgnx-modal-engine-start-now 'evil) (error "evil did not start (DRGNX_MODAL_ELPA %s)" ,elpa))
      (drgnx-keys-use ',drgnx-perf-run--vim-keys)
      t)))

(defun drgnx-perf-run--modal-teardown-form (&rest more)
  "The teardown of an evil workload: the VS Code keys back, then MORE (forms as strings)."
  (format "(progn (drgnx-keys-use '%S) %s t)" drgnx-perf-run--vscode-keys (string-join more " ")))

(defun drgnx-perf-run--modal-workloads ()
  "The workloads with evil, or nil without $DRGNX_MODAL_ELPA (`drgnx-perf-run-modal-skipped' says so)."
  (when-let* ((elpa (drgnx-perf-run--modal-elpa)))
    (let* ((setup (drgnx-perf-run--modal-setup-form elpa))
           (keys (lambda (k n) (make-list n (list :keys k))))
           (kill-fixture (format "(when-let* ((b (find-buffer-visiting %S))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))"
                                 (or drgnx-perf-run--fixture "")))
           (kill-motions "(when-let* ((b (find-buffer-visiting drgnx-perf--motions-file))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)) (delete-file drgnx-perf--motions-file)"))
      `((typing-evil :setup ,setup
                     :each ,(concat "(progn " (drgnx-perf-run--visit-fixture-form) " (evil-normal-state) t)")
                     :actions ,(append (list (list :keys "i"))
                                       (make-list 6 (list :type "(let ((x 1)) (message \"%s\" x)) "))
                                       (list (list :keys "<escape>")))
                     :check "(with-current-buffer (window-buffer (selected-window)) (and (buffer-modified-p) (eq evil-state 'normal)))" ; typed, back in normal
                     :teardown ,(drgnx-perf-run--modal-teardown-form kill-fixture))
        ;; 5000 lines of the fixture, from the middle: down, by words, by paragraphs, by half pages and back
        (motions-evil :setup ,(format "(progn %s (defvar drgnx-perf--motions-file nil) (defvar drgnx-perf--motions-start nil)
                                       (setq drgnx-perf--motions-file (make-temp-file \"drgnx-perf-motions\" nil \".el\"))
                                       (with-temp-file drgnx-perf--motions-file
                                         (insert-file-contents %S) (goto-char (point-min)) (forward-line 5000) (delete-region (point) (point-max)))
                                       t)"
                                      setup (or drgnx-perf-run--fixture ""))
                      :each "(progn (let ((f drgnx-perf--motions-file))
                                      (when-let* ((b (find-buffer-visiting f))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))
                                      (find-file f) (goto-char (/ (point-max) 2)) (forward-line 0)
                                      (setq drgnx-perf--motions-start (point)) (evil-normal-state))
                                    t)"
                      :actions ,(append (funcall keys "j" 20) (funcall keys "w" 20) (funcall keys "}" 10)
                                        (funcall keys "C-d" 5) (funcall keys "C-u" 5))
                      :check "(with-current-buffer (window-buffer (selected-window)) (and (eq evil-state 'normal) (/= (point) drgnx-perf--motions-start)))" ; moved
                      :teardown ,(drgnx-perf-run--modal-teardown-form kill-motions))
        (explorer-evil :setup ,(format "(progn %s (drgnx-explorer-set-roots (list %S)) (drgnx-wb-show-sidebar) t)" setup drgnx-ui-repo-dir)
                       :each "(progn (drgnx-explorer-focus) (goto-char (point-min)) (drgnx-wb-focus-editor) t)"
                       :actions ,(append (list (list :keys "SPC E")) (funcall keys "j" 10) (list (list :keys "<escape>")))
                       :check "(with-current-buffer \" *drgnx explorer*\" (= (line-number-at-pos) 11))" ; ten rows down, in the Explorer
                       :teardown ,(drgnx-perf-run--modal-teardown-form))))))

(defun drgnx-perf-run--relative-fails (results)
  "Lines: `typing-evil' input p95 more than 1 ms over `typing' in the same RESULTS (both measured)."
  (let ((plain (drgnx-perf--get results 'typing '(:input :p95)))
        (evil (drgnx-perf--get results 'typing-evil '(:input :p95)))
        (hidden (drgnx-perf--get results 'work-typing-hidden '(:input :p95)))
        (shown (drgnx-perf--get results 'work-typing-shown '(:input :p95)))
        (agents (drgnx-perf--get results 'agents-typing '(:input :p95)))
        (agents-none (drgnx-perf--get results 'agents-typing-none '(:input :p95)))
        (ratio (drgnx-perf--get results 'pair-typing '(:pair_applied_ratio))))
    (append
     ;; the agents in the editor: at most 1 ms over the same five agents with the module off; of the paired chat's writes at
     ;; least 80 % were applied by the editor
     (when (and (numberp agents) (numberp agents-none) (> (- agents agents-none) 1.0))
       (list (format "agents-typing input p95 %s ms is %s ms over agents-typing-none's %s ms (the agents in the editor may add at most 1 ms)"
                     (drgnx-perf--round agents) (drgnx-perf--round (- agents agents-none)) (drgnx-perf--round agents-none))))
     (when (and (numberp ratio) (< ratio 0.80))
       (list (format "pair-typing applied %s of the paired chat's writes; at least 0.80 are due" (drgnx-perf--round ratio))))
     (when (and (numberp plain) (numberp evil) (> (- evil plain) 1.0))
       (list (format "typing-evil input p95 %s ms is %s ms over typing's %s ms (evil may add at most 1 ms)"
                     (drgnx-perf--round evil) (drgnx-perf--round (- evil plain)) (drgnx-perf--round plain))))
     ;; the Work space: the map shown costs at most 1 ms over the same map hidden; with the mirror on for 30
     ;; streaming agents, at most 1 ms over typing with no agents
     (when (and (numberp hidden) (numberp shown) (> (- shown hidden) 1.0))
       (list (format "work-typing-shown input p95 %s ms is %s ms over work-typing-hidden's %s ms (the map may add at most 1 ms)"
                     (drgnx-perf--round shown) (drgnx-perf--round (- shown hidden)) (drgnx-perf--round hidden))))
     )))

(defun drgnx-perf-run--relative-note (results)
  "A line saying the 1 ms rule was not judged, when `typing-evil' was measured without `typing' in RESULTS; else nil."
  (when (and (numberp (drgnx-perf--get results 'typing-evil '(:input :p95)))
             (not (numberp (drgnx-perf--get results 'typing '(:input :p95)))))
    "perf: typing-evil's 1 ms rule not judged: typing was not measured in this run (add it to DRGNX_PERF_WORKLOADS)"))

(defun drgnx-perf-run--budgets-judged (results)
  "The budgets to judge RESULTS against: all of them, but without $DRGNX_MODAL_ELPA those of the evil workloads
that did not run.  Any other budget of a missing workload stays, so the verdict says \"not measured\" (a renamed
or misspelled workload is not lost); a run limited by $DRGNX_PERF_WORKLOADS drops them where it judges."
  (let ((no-evil (not (drgnx-perf-run--modal-elpa))))
    (seq-remove (lambda (b)
                  (and (not (assq (car b) results))
                       no-evil (memq (car b) '(typing-evil motions-evil explorer-evil))))
                (drgnx-perf-run--budgets))))

(defun drgnx-perf-run--daemon-env (tmp)
  "The environment of a measured daemon: the harness's allowlist (never tokens, never a trace or safe
mode), its own HOME and drgnx dirs under TMP."
  (append (mapcar (lambda (v) (format "%s=%s" (car v) (expand-file-name (cdr v) tmp)))
                  '(("HOME" . "home") ("DRGNX_CONFIG_DIR" . "config") ("XDG_STATE_HOME" . "state")
                    ("DRGNX_DATA_DIR" . "data") ("XDG_CACHE_HOME" . "cache") ("XDG_CONFIG_HOME" . "xdg-config")))
          (delq nil (mapcar (lambda (name) (and (getenv name) (not (member name '("HOME" "DRGNX_STARTUP_TRACE")))
                                                (concat name "=" (getenv name))))
                            (append drgnx-ui-keep-env '("XDG_RUNTIME_DIR"))))))

(defun drgnx-perf-run--client (name timeout &rest args)
  "emacsclient to daemon NAME, never starting another Emacs (-a false), at most TIMEOUT s: (EXIT . OUTPUT)."
  (with-temp-buffer
    (let ((rc (apply #'call-process "timeout" nil t nil (number-to-string timeout)
                     (or (executable-find "emacsclient") "emacsclient") "-a" "false" "-s" name args)))
      (cons rc (string-trim (buffer-string))))))

(defun drgnx-perf-run-daemon-startup (&optional runs init-dir)
  "The spec's startup measure: a drgnx daemon (isolated, temp dirs) until its server answers, RUNS (4)
times; the first warms the caches and is dropped.  A daemon that never answers is an error.
INIT-DIR: drgnx's init/ (default).  (:server_ms STATS :modules_ms N)."
  (let* ((tmp (make-temp-file "drgnx-perf-daemon" t))
         (emacs (expand-file-name invocation-name invocation-directory))
         (init-dir (and init-dir (expand-file-name init-dir)))
         (default-directory (file-name-as-directory tmp))     ; absolute: HOME is about to change
         (process-environment (drgnx-perf-run--daemon-env tmp))
         (init (or init-dir (expand-file-name "init" drgnx-ui-repo-dir)))
         times modules)
    (make-directory (expand-file-name "home" tmp) t)
    (unwind-protect
        (dotimes (i (or runs 4))
          (let* ((name (format "drgnx-perf-%d-%d" (emacs-pid) i)) (t0 (float-time))
                 (p (start-process name nil emacs (concat "--fg-daemon=" name) (concat "--init-directory=" init)))
                 (served nil))
            (unwind-protect
                (progn
                  (while (and (not served) (process-live-p p) (< (- (float-time) t0) 30))
                    (if (eql 0 (car (drgnx-perf-run--client name 2 "-e" "t"))) (setq served t) (sleep-for 0.01)))
                  (unless served (error "The daemon never answered (%s)" (if (process-live-p p) "30 s" "it exited")))
                  (when (or (> i 0) (= (or runs 4) 1)) (push (* 1000 (- (float-time) t0)) times))
                  (let ((m (drgnx-perf-run--client name 5 "-e" "(apply #'+ (mapcar (lambda (m) (or (plist-get (cdr m) :ms) 0)) (drgnx-modules-report)))")))
                    (unless (and (eql 0 (car m)) (string-match-p "\\`[0-9.]+\\'" (cdr m)))
                      (error "No module report from the daemon: %s" (cdr m)))
                    (setq modules (string-to-number (cdr m)))))
              (drgnx-perf-run--client name 3 "-e" "(kill-emacs)")
              (let ((d (+ (float-time) 5))) (while (and (process-live-p p) (< (float-time) d)) (sleep-for 0.05)))
              (when (process-live-p p) (delete-process p)))))
      (delete-directory tmp t))
    (list :server_ms (mapcar #'drgnx-perf--round (drgnx-perf-stats times)) :modules_ms modules)))

(defun drgnx-perf-run--call (sess form &optional timeout)
  "FORM (a string) in SESS, its value as JSON.  $DRGNX_PERF_WORKERS is applied first (once per session), so a
workload's `:setup' already runs under it: a connection Nidhogg would frame is framed only if the switch is on when it
opens (lsp-burst's servers), and applied at the first recording the first workload of a session ran without it."
  (drgnx-ui-call sess (format "(progn (require 'drgnx-perf) (drgnx-perf--workers-env) (drgnx-uitest--json %s))" form)
                 (or timeout 60)))

(defun drgnx-perf-run--median (runs path)
  (plist-get (drgnx-perf-stats (delq nil (mapcar (lambda (r) (let ((v r)) (dolist (k path) (setq v (plist-get v k))) (and (numberp v) v))) runs)))
             :p50))

(defun drgnx-perf-run--medians (runs)
  "One result from RUNS: every numeric value (also inside nested plists: stats, the :compose record) the median
over the runs."
  (let (out)
    (cl-loop for (k v) on (car runs) by #'cddr
             do (setq out (plist-put out k
                                     (cond ((numberp v) (drgnx-perf-run--median runs (list k)))
                                           ((and (consp v) (keywordp (car v)))
                                            (drgnx-perf-run--medians (mapcar (lambda (r) (plist-get r k)) runs)))
                                           (t v)))))
    out))

(defun drgnx-perf-run--begin-form (spec &optional audit)
  "The form that starts recording for workload SPEC: the probes, the audit when AUDIT, and the completion timer when
SPEC has `:complete-when' (a form that is true once the work the actions started is done)."
  (format "(progn %s (drgnx-perf-begin%s) %s t)" (if audit "(drgnx-perf-audit-begin)" "")
          (if (plist-get spec :timers) " t" "")
          (if-let* ((cw (plist-get spec :complete-when))) (format "(drgnx-perf-complete-begin (lambda () %s))" cw) "")))

(defconst drgnx-perf-run-complete-wait 60
  "Seconds the lab waits after a workload's actions for its `:complete-when' to hold.  The work the keys started (a
compile flood, the reparse after a paste) can outlast the keys; `:complete-ms', the digest and the check are read once
it is done, or after this wait.")

(defun drgnx-perf-run--await-complete (sess)
  "Wait until SESS's completion poll has noted `:complete-ms', at most `drgnx-perf-run-complete-wait' seconds.  The
session stays idle between the calls, so its idle poll and redisplay run as they do for a user."
  (let ((deadline (+ (float-time) drgnx-perf-run-complete-wait)))
    (while (and (not (eq t (drgnx-perf-run--call sess "(and drgnx-perf--complete (nth 2 drgnx-perf--complete) t)")))
                (< (float-time) deadline))
      (sleep-for 0.05))))

(defun drgnx-perf-run--extras (sess spec)
  "What SPEC adds to a run, read in SESS after the actions: `:complete-ms' (`:complete-when', once it holds: see
`drgnx-perf-run--await-complete') and `:digest' (the string SPEC's `:digest' form returns: buffer text and faces,
filter-call arguments or a message sequence)."
  (when (plist-get spec :complete-when) (drgnx-perf-run--await-complete sess))
  (append (and (plist-get spec :complete-when) (drgnx-perf-run--call sess "(drgnx-perf-complete-end)"))
          (and (plist-get spec :digest)
               (list :digest (plist-get (drgnx-perf-run--call sess (format "(list :digest (format \"%%s\" %s))" (plist-get spec :digest)))
                                        :digest)))))

(defvar drgnx-perf-run--profile nil
  "While a workload runs: the file its measure's profile report goes to (`drgnx-perf-run--profile-file'), or nil.")

(defun drgnx-perf-run--profile-file (name)
  "With $DRGNX_PERF_PROFILE set, where workload NAME's profile report goes: next to $DRGNX_PERF_RESULTS, as
RESULTS-NAME.profile.txt (else in the temp directory); nil without it."
  (unless (member (getenv "DRGNX_PERF_PROFILE") '(nil ""))
    (let ((results (getenv "DRGNX_PERF_RESULTS")))
      (if (member results '(nil ""))
          (expand-file-name (format "drgnx-perf-%s.profile.txt" name) temporary-file-directory)
        (format "%s-%s.profile.txt" (file-name-sans-extension results) name)))))

(defun drgnx-perf-run--profiled (form)
  "FORM (a workload's measure), run under the profilers when `drgnx-perf-run--profile' names a report
\(`drgnx-perf-profiled')."
  (if (and form drgnx-perf-run--profile)
      (format "(drgnx-perf-profiled %S (lambda () %s))" drgnx-perf-run--profile form)
    form))

(defun drgnx-perf-run-workload (sess spec &optional audit)
  "Run workload SPEC in SESS: its setup, then :repeat (3) runs, the medians of their numbers.  AUDIT:
the hook audit on (its rows under :audit).  The probes, the audit and the teardown are undone even
when a step fails.  With `drgnx-perf-run--profile', its measure runs under the profilers, and a workload with typed
actions is profiled from its first key to the end of the completion wait instead."
  (let* ((actions (plist-get spec :actions))
         (keys-profile (and actions drgnx-perf-run--profile))   ; typed keys: profiled from the first key to the end of the wait
         (measure (if keys-profile (plist-get spec :measure) (drgnx-perf-run--profiled (plist-get spec :measure)))))
    (if (plist-get spec :daemon) (drgnx-perf-run-daemon-startup)
      (unwind-protect
          (progn
            (when (plist-get spec :setup) (drgnx-perf-run--call sess (plist-get spec :setup) 120) (drgnx-ui-measure sess nil))
            (let (runs audit-rows audit-hooks)
              (dotimes (_ (or (plist-get spec :repeat) 3))
                (when (plist-get spec :each) (drgnx-perf-run--call sess (plist-get spec :each) 120) (drgnx-ui-measure sess nil))
                (if (not actions)
                    (push (drgnx-perf-run--call sess measure 120) runs)
                  (when keys-profile (drgnx-perf-run--call sess "(drgnx-perf-profile-begin)"))
                  (drgnx-perf-run--call sess (drgnx-perf-run--begin-form spec audit))
                  (drgnx-ui-measure sess actions)
                  (push (append (drgnx-perf-run--call sess "(drgnx-perf-end)")
                                (prog1 (drgnx-perf-run--extras sess spec)
                                  (when keys-profile
                                    (drgnx-perf-run--call sess (format "(drgnx-perf-profile-end %S)" drgnx-perf-run--profile))))
                                (and measure (drgnx-perf-run--call sess measure 120)))   ; what input cannot show
                        runs)
                  (when audit
                    (let ((r (drgnx-perf-run--call sess "(let ((rows (vconcat (seq-take (drgnx-perf-audit-end) 30)))) (list :rows rows :hooks (drgnx-perf-audit-hooks)))")))
                      (setq audit-rows (append audit-rows (append (plist-get r :rows) nil)))
                      (push (list :hooks (plist-get r :hooks)) audit-hooks))))
                (when (plist-get spec :check)
                  (unless (eq t (drgnx-perf-run--call sess (plist-get spec :check)))
                    (error "The workload did not do what it measures (%s)" (plist-get spec :check)))))
              (let ((r (drgnx-perf-run--medians runs)))
                (if audit
                    (plist-put (plist-put r :audit (vconcat audit-rows))
                               :hooks (plist-get (drgnx-perf-run--medians audit-hooks) :hooks))
                  r))))
        ;; never leave the probes or the audit on, nor what the workload made
        (ignore-errors (drgnx-perf-run--call sess "(progn (when drgnx-perf--audit (drgnx-perf-audit-end)) (drgnx-perf-complete-end) (drgnx-perf-end) t)"))
        (when (plist-get spec :teardown) (ignore-errors (drgnx-perf-run--call sess (plist-get spec :teardown))))))))

(defun drgnx-perf-run--budgets ()
  (with-temp-buffer (insert-file-contents (expand-file-name "test/perf/budgets.eld" drgnx-ui-repo-dir)) (read (current-buffer))))

(defun drgnx-perf-run--commit ()
  (with-temp-buffer
    (if (eql 0 (call-process "git" nil t nil "-C" drgnx-ui-repo-dir "rev-parse" "--short" "HEAD")) (string-trim (buffer-string)) "unknown")))

(defun drgnx-perf-run--table (results)
  (mapconcat (lambda (r)
               (let* ((p (cdr r)) (loaded (plist-get (plist-get p :calibration) :loaded)))
                 (format "%-13s %s" (car r)
                         (string-join
                          (delq nil (list (when-let* ((i (plist-get p :input)))
                                            (format "input p50 %s p90 %s max %s ms (n=%s)%s" (plist-get i :p50) (plist-get i :p90) (plist-get i :max) (plist-get i :n)
                                                    (if loaded " (loaded)" "")))
                                          (when-let* ((a (plist-get p :alloc))) (format "alloc p50 %s objects" (plist-get a :p50)))
                                          (when-let* ((c (plist-get p :cpu_ms))) (format "cpu p90 %s ms" (plist-get c :p90)))
                                          (when (and (plist-get p :input) (numberp (plist-get p :rows))) (format "rows %s" (plist-get p :rows)))
                                          (when (plist-get p :gc_count) (format "gc %s/%s ms (pause p90 %s)" (plist-get p :gc_count) (plist-get p :gc_ms)
                                                                                (or (plist-get (plist-get p :gc_pause) :p90) "-")))
                                          (when (plist-get p :draw_ms) (format "drawn in %s ms, %s processes started" (plist-get p :draw_ms) (plist-get p :processes)))
                                          (when-let* ((f (plist-get p :frame))) (format "frame p50 %s p90 %s ms%s" (plist-get f :p50) (plist-get f :p90) (if loaded " (loaded)" "")))
                                          (when-let* ((d (plist-get p :redisplay))) (format "redisplay p50 %s p90 %s ms%s" (plist-get d :p50) (plist-get d :p90) (if loaded " (loaded)" "")))
                                          (when-let* ((sv (plist-get p :server_ms))) (format "daemon server ready p50 %s max %s ms, modules %s ms%s" (plist-get sv :p50) (plist-get sv :max) (plist-get p :modules_ms) (if loaded " (loaded)" "")))
                                          (when (and (plist-get p :rss_kb) (not (plist-get p :input))) (format "rss %d MB" (/ (plist-get p :rss_kb) 1024)))))
                          ", "))))
             results "\n"))

(defun drgnx-perf-run--json-ready (v)
  "V (a result: plists, stats, vectors, lists) for `json-serialize': nil is null, a boolean :loaded is true or false,
any other proper list (an A/B's side order, (\"a\" \"b\" ...)) an array, a dotted pair (a Nidhogg decision count,
((AREA OUTCOME REASON) . N)) a two-element array, and any other symbol its name."
  (cond ((null v) :null)
        ((vectorp v) (vconcat (mapcar #'drgnx-perf-run--json-ready v)))
        ((and (consp v) (keywordp (car v)))
         (let (out)
           (cl-loop for (k x) on v by #'cddr
                    do (setq out (nconc out (list k (if (eq k :loaded) (if x t :false) (drgnx-perf-run--json-ready x))))))
           out))
        ((proper-list-p v) (vconcat (mapcar #'drgnx-perf-run--json-ready v)))
        ((consp v) (vector (drgnx-perf-run--json-ready (car v)) (drgnx-perf-run--json-ready (cdr v))))
        ((and (symbolp v) (not (memq v '(t :false :null)))) (symbol-name v))
        (t v)))

(defun drgnx-perf-run--write-results (file results)
  "$DRGNX_PERF_RESULTS: RESULTS (every metric, wall clock included, each workload's calibration), the Emacs
version and the commit, as JSON in FILE."
  (let ((doc (list :emacs emacs-version :commit (drgnx-perf-run--commit)
                   :results (apply #'append (mapcar (lambda (r) (list (intern (concat ":" (symbol-name (car r))))
                                                                      (drgnx-perf-run--json-ready (cdr r))))
                                                    results)))))
    (make-directory (file-name-directory (expand-file-name file)) t)
    (write-region (concat (json-serialize doc) "\n") nil file nil 'silent)))

(defconst drgnx-perf-run-workers-seeded
  '(explorer-git explorer-git-rows quick-open-typing quick-open-typing-old agents-line-motion agents-line-motion-old
                 presence-burst presence-burst-old)
  "The off-the-main-thread workloads with allocation, CPU and rows budgets (the render offload measured them).")

(defconst drgnx-perf-run-unseeded
  `(,@(mapcar (lambda (w) (cons w "report-only until the combined gate pass: allocation, CPU and rows follow its first runs on the desktop island"))
              '(agents-typing agents-typing-none agents-follow agent-panel-stream pair-typing))
    (live-view . "the container image has no websocket package")
    (typing-with-index . "the container's /src is not a git project; the workload indexes the repo")
    ,@(mapcar (lambda (w) (cons w "drgnx's terminal: its time rows are judged and its allocation rows set at the combined gate pass, on the desktop island"))
              '(terminal-typing terminal-output terminal-output-10mb terminal-output-100mb terminal-echo terminal-echo-idle
                                terminal-backfill terminal-flood))
    (memory . "its one key only opens the pause RSS is read after; RSS is its budget")
    ,@(mapcar (lambda (w) (cons w "report-only until its step lands (§17.6); no allocation, CPU or rows budget: they follow the worker's design, not today's code"))
              (seq-difference drgnx-perf-workers-names drgnx-perf-run-workers-seeded))
    ,@(mapcar (lambda (w) (cons w "the Work space's rows are time budgets on the desktop island (typing p95 and the relative +1 ms rules); allocation, CPU and rows follow once the first runs set them"))
              '(work-typing-shown work-typing-hidden))
    (view-patch . "report-only until the render offload's combined pass (its numbers on the island)")
    (work-nav-rows . "report-only until the combined pass (gates after core, editor and agents); needs Sjá's Nidhogg")
    (search-context . "its bar is a ratio of its own runs (labels against none: first rows ≤ 1.10×, end ≤ 1.15×), read from :first_ratio and :done_ratio")
    (search-retype . "its input rows are judged now; allocation, CPU and rows follow its first runs on the desktop island (the combined pass)")
    (typing-evil . "needs DRGNX_MODAL_ELPA (evil); not run in the container")
    (motions-evil . "needs DRGNX_MODAL_ELPA")
    (explorer-evil . "needs DRGNX_MODAL_ELPA")
    (popup-typing . "needs DRGNX_CHILDFRAME_ELPA and Glitnir's build; seeded by the Glitnir gate runs (Task 12)")
    (popup-churn . "needs DRGNX_CHILDFRAME_ELPA and Glitnir's build; seeded by the Glitnir gate runs (Task 12)")
    (scroll-under-popup . "needs DRGNX_CHILDFRAME_ELPA and Glitnir's build; seeded by the Glitnir gate runs (Task 12)")
    (scroll-full-window . "measured and recorded only (§9.2), until the Glitnir gate runs seed it (Task 12)"))
  "Input workloads with no allocation, CPU or rows budget yet, and why: they could not be seeded from the 31.1
container.  Seed one (budgets.eld) and take it off this list.")

(defconst drgnx-perf-run-container-skipped
  '((live-view . "the container image has no websocket package"))
  "Workloads that error in the GUI container (seen 2026-10-20, CI perf lab), and why.  In a container the lab names
them and leaves them out (as it leaves out the evil workloads without evil), so one that cannot run there does not
fail the whole run; they still run on a host.  Each is also in `drgnx-perf-run-unseeded'.")

(defun drgnx-perf-run--container-skip (workload)
  "Why WORKLOAD is left out in the container (`drgnx-perf-run-container-skipped'), or nil.  The Live view runs when
$DRGNX_USER_ELPA holds websocket (`bin/drgnx' mounts it in the perf tier)."
  (unless (and (eq workload 'live-view) (drgnx-perf-run--websocket-elpa-p))
    (cdr (assq workload drgnx-perf-run-container-skipped))))

(defconst drgnx-perf-run-hook-budget 2 "ms: any hook function's p90 (the spec), judged in the --audit pass.")
(defconst drgnx-perf-run-hook-command-budget 1.5
  "ms (p90): all the audited hook functions and timers together, per command, judged in the --audit pass.  The
plan's starting value was 4; measured (2026-10-20, typing 0.46, explorer 0.67) it is 2x the larger, rounded up.")

(defun drgnx-perf-run--hooks-fails (results)
  "Failure lines: workloads of an audit pass whose per-command hook time passes `drgnx-perf-run-hook-command-budget'."
  (delq nil (mapcar (lambda (r)
                      (let ((p90 (plist-get (plist-get (cdr r) :hooks) :p90)))
                        (when (and (numberp p90) (> p90 drgnx-perf-run-hook-command-budget))
                          (format "%s: hook functions and timers take %s ms per command (p90) > %s ms"
                                  (car r) p90 drgnx-perf-run-hook-command-budget))))
                    results)))

(defun drgnx-perf-run--check-gc (sess)
  "HARNESS-GC-1: the session must run at drgnx's GC settings (`drgnx-gc-cons-threshold'), as a user's does."
  (let* ((r (drgnx-perf-run--call sess "(list :now gc-cons-threshold :want (and (require 'drgnx-gc nil t) drgnx-gc-cons-threshold))"))
         (now (plist-get r :now)) (want (plist-get r :want)))
    (unless (and (numberp want) (eql now want))
      (error "perf: the session runs at gc-cons-threshold %s, not drgnx's %s (HARNESS-GC-1)" now want))))

(defun drgnx-perf-run (&optional audit)
  "`drgnx test --perf': every workload in one session; print, judge the gated budgets (`drgnx-perf-verdict':
allocation, CPU, rows), report the rest (`drgnx-perf-report'), print what got worse than the history (never a
failure), keep the history.  Exit code: 0 every gated budget holds, 1 a failure.  The load on the machine
never decides: allocation, CPU and rows do not move with it, and wall clock is reported with a calibration (see
docs/develop/perf.md).  AUDIT (`--audit'): the hook audit on — judged on the hook budgets only (the audit adds
its own cost to the other numbers)."
  (unless (drgnx-perf-run--modal-elpa) (princ (concat drgnx-perf-run-modal-skipped "\n")))
  (unless (drgnx-perf-run--childframe-elpa) (princ (concat drgnx-perf-run-childframe-skipped "\n")))
  (drgnx-perf-run--judged audit))

(defconst drgnx-perf-ab--settle-form
  "(progn (let ((d (+ (float-time) 180))) (while (and (fboundp 'comp--async-runnings) (boundp 'comp-files-queue)
         (or comp-files-queue (> (comp--async-runnings) 0)) (< (float-time) d)) (accept-process-output nil 0.2))) t)"
  "Wait until the session's background native compilation has drained (PERF-ELN-1: a fresh tree compiles its files
to the eln cache while it runs, and the wall clock pays for it).  A plain run waits too, before its first workload.")

(defun drgnx-perf-run--compiled (root)
  "ROOT built (`drgnx-perf-ab--build') when one of the files `drgnx build' compiles has no .elc as new as it: a
session would load it as source, and a run of sources measures the interpreter (a replay fell behind its own stream
and a draw made twice the objects; a fresh clone and a synced copy have no .elc)."
  (when-let* ((el (seq-find (lambda (el) (let ((elc (concat el "c")))
                                           (or (not (file-exists-p elc)) (file-newer-than-file-p el elc))))
                            (drgnx-build-files root))))
    (princ (format "perf: %s is not compiled: building the tree first\n" (file-relative-name el root)))
    (drgnx-perf-ab--build root)))

(defun drgnx-perf-run--judged (audit)
  "The run of `drgnx-perf-run'."
  (drgnx-perf-run--compiled drgnx-ui-repo-dir)
  (let* ((loads (list (drgnx-perf-load)))
         (drgnx-perf-run--fixture (drgnx-perf-run--make-fixture))
         (all (drgnx-perf-run--workloads)) (selected (drgnx-perf-run--select all))
         (s (drgnx-ui-start "drgnx" (drgnx-perf-run--session-size) 60)) (sess (drgnx-ui-own-session (plist-get s :name))) results)
    (unwind-protect
        (progn
          (drgnx-perf-run--check-gc sess)
          (drgnx-perf-run--call sess drgnx-perf-ab--settle-form 200)   ; the first workload must not pay for it
          (dolist (w selected)
            (if-let* ((why (and (drgnx-env-container) (drgnx-perf-run--container-skip (car w)))))
                (princ (format "perf: %s skipped in the container — %s\n" (car w) why))
              (message "perf: %s…" (car w))
              (let* ((cal (drgnx-perf-run--call sess "(drgnx-perf-calibrate)"))
                     (r (condition-case err (let ((drgnx-perf-run--profile (drgnx-perf-run--profile-file (car w))))
                                              (drgnx-perf-run-workload sess (cdr w) audit))
                          (error (list :error (error-message-string err))))))
                (push (cons (car w) (if (plist-get r :error) r (plist-put r :calibration cal))) results))
              (push (drgnx-perf-load) loads))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-file drgnx-perf-run--fixture))
    (setq results (nreverse results))
    (princ (concat (drgnx-perf-run--table results) "\n"))
    (when-let* ((file (getenv "DRGNX_PERF_RESULTS")))
      (unless (string-empty-p file) (drgnx-perf-run--write-results file results)))
    (let ((errors (seq-filter (lambda (r) (plist-get (cdr r) :error)) results)))
      (pcase-dolist (`(,w . ,p) errors) (princ (format "ERROR %s: %s\n" w (plist-get p :error))))
      (cond
       (audit
        (let ((rows (seq-mapcat (lambda (r) (append (plist-get (cdr r) :audit) nil)) results)))
          (dolist (row (seq-take (sort (copy-sequence rows) (lambda (a b) (> (plist-get a :ms) (plist-get b :ms)))) 40))
            (princ (format "audit %-40s %-34s %6s calls  p90 %6s  max %6s  total %8s ms\n" (plist-get row :fn) (plist-get row :hooks)
                           (plist-get row :calls) (plist-get row :p90) (plist-get row :max) (plist-get row :ms))))
          (dolist (r results)
            (when-let* ((h (plist-get (cdr r) :hooks)))
              (princ (format "audit %-13s per command: hooks and timers p50 %s p90 %s max %s ms\n" (car r) (plist-get h :p50) (plist-get h :p90) (plist-get h :max)))))
          (let ((fails (append (drgnx-perf-audit-verdict rows drgnx-perf-run-hook-budget) (drgnx-perf-run--hooks-fails results))))
            (dolist (f fails) (princ (format "FAIL %s\n" f)))
            (if (or fails errors) 1 (princ "perf audit: every hook function within its budget\n") 0))))
       (t
        (let* ((history (expand-file-name "perf-history.jsonl" (drgnx-ui-state-root)))
               (partial (/= (length selected) (length all)))   ; DRGNX_PERF_WORKLOADS: judge those, keep no history
               (judged (let ((all (drgnx-perf-run--budgets-judged results)))
                         (if partial (seq-filter (lambda (b) (assq (car b) results)) all) all)))
               (fails (drgnx-perf-verdict results judged))
               (worse (drgnx-perf-regressions history results)))
          (dolist (f fails) (princ (format "FAIL %s\n" f)))
          ;; wall clock is reported, never judged here: the paired A/B run at n >= 100 judges it
          (dolist (l (append (drgnx-perf-report results judged) (drgnx-perf-run--relative-fails results)))
            (princ (format "report %s\n" l)))
          (dolist (l (drgnx-perf-cal-lines results)) (princ (format "report %s\n" l)))
          (dolist (r worse) (princ (format "regression (reported, local history): %s\n" r)))
          (when-let* ((note (drgnx-perf-run--relative-note results))) (princ (concat note "\n")))
          (unless (or errors partial) (drgnx-perf-history-append history (drgnx-perf-run--commit) results (seq-max (cons 0 (delq nil loads)))))
          (princ (format "history: %s%s\n" history (cond (errors " (not written: a workload failed)")                                                         (partial " (not written: only some workloads ran)")
                                                         (t ""))))
          (if (or fails errors) 1
            (princ "perf: every gated budget holds\n") 0)))))))

(defconst drgnx-perf-run--census-form
  "(vconcat (mapcar (lambda (r) (vector (symbol-name (nth 0 r)) (symbol-name (nth 1 r)) (nth 2 r) (or (nth 3 r) :null)))
                   (and (require 'drgnx-memo nil t) (drgnx-memo-census))))"
  "Evaluated in the soak's session: `drgnx-memo-census' as an array of [NAME KIND SIZE CAP].")

(defun drgnx-perf-run--census-lines (census)
  "CENSUS (the session's reply: rows [NAME KIND SIZE CAP]) as printable lines, and the rows whose SIZE passes their CAP.
Returns (LINES . OVER): OVER is a list of strings naming each cache past its cap."
  (let (lines over)
    (seq-doseq (row census)
      (let ((name (aref row 0)) (kind (aref row 1)) (size (aref row 2)) (cap (aref row 3)))
        (push (format "  %s %s %d%s" kind name size (if (numberp cap) (format "/%d" cap) "")) lines)
        (when (and (numberp cap) (> size cap)) (push (format "%s holds %d, over its cap of %d" name size cap) over))))
    (cons (nreverse lines) (nreverse over))))

(defun drgnx-perf-soak (&optional minutes)
  "`drgnx test --soak [MINUTES]': the input workloads in a loop for MINUTES (30); memory sampled after
each round; fails when RSS grows by more than 20% from the first round or passes 400 MB, or when a cache of
`drgnx-memo-census' holds more than its cap.  The census is printed after each round."
  (let* ((minutes (max 1 (or minutes 30))) (deadline (+ (float-time) (* 60 minutes)))
         (drgnx-perf-run--fixture (drgnx-perf-run--make-fixture))
         (process-environment (cons (format "DRGNX_UI_MAX_RUNTIME=%d" (+ (* 60 minutes) 900)) process-environment))
         (s (drgnx-ui-start "drgnx" (drgnx-perf-run--session-size) 60)) (sess (drgnx-ui-own-session (plist-get s :name)))
         (loads (seq-filter (lambda (w) (plist-get (cdr w) :actions)) (drgnx-perf-run--workloads)))
         samples over live-mb)
    (unwind-protect
        (while (progn (unless samples (drgnx-perf-run--check-gc sess)) (< (float-time) deadline))
          (dolist (w loads) (ignore-errors (drgnx-perf-run-workload sess (cdr w))))   ; each cleans up after itself
          (let* ((r (drgnx-perf-run--call sess (format "(progn (garbage-collect) (list :rss_kb (drgnx-perf-rss-kb) :live_mb (drgnx-perf-live-mb) :census %s))"
                                                       drgnx-perf-run--census-form)))
                 (census (drgnx-perf-run--census-lines (plist-get r :census))))
            (setq live-mb (plist-get r :live_mb))
            (push (plist-get r :rss_kb) samples)
            (setq over (append over (cdr census)))
            (message "soak: round %d, %d MB" (length samples) (/ (car samples) 1024))
            (dolist (l (car census)) (message "%s" l))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-file drgnx-perf-run--fixture))
    (unless samples (error "The soak finished no round"))
    (let* ((rounds (reverse samples)) (first (car rounds)) (last (car samples))
           (growth (and first (> first 0) (/ (* 100.0 (- last first)) first))))
      (princ (format "soak: %d rounds in %d min; RSS %d → %d MB (%+.1f%%)\n" (length rounds) minutes (/ first 1024) (/ last 1024) growth))
      (princ (format "soak: (:heap :live_mb %s) after the last collection (reported, not gated)\n" (drgnx-perf--round live-mb)))
      (dolist (o (delete-dups over)) (princ (format "FAIL soak: %s\n" o)))
      (cond ((or (> growth 20) (> last (* 400 1024)))
             (princ "FAIL soak: memory grew more than 20% or passed 400 MB\n") 1)
            (over 1)
            (t (princ "soak: memory holds\n") 0)))))

;;;; The synthetic day: `drgnx test --day [MIN]'

(defconst drgnx-perf-day-seed "drgnx-day-1" "Seeds the order of the workloads in each steady round.")

(defconst drgnx-perf-day-workloads
  '(typing scrolling tabs explorer code-scrolling diff-scrolling window-switch)
  "The workloads of a steady round: the container-runnable input workloads that need no package, process or git
project the GUI image lacks (so not the mock-agent, Live, terminal, evil, popup, remote, ghost or index ones).")

(defconst drgnx-perf-day-files
  '("test/fixtures/day/project/main.el" "test/fixtures/day/project/util.el" "test/fixtures/day/project/README.md"
    "test/fixtures/day/org/inbox.org" "test/fixtures/day/org/projects.org"
    "test/fixtures/day/transcript.eld" "test/fixtures/day/lsp-exchange.eld" "test/fixtures/lsp-replay.el")
  "Every input of the day, relative to the checkout.")

(defun drgnx-perf-day--read (name)
  "The Lisp data of test/fixtures/day/NAME."
  (with-temp-buffer
    (insert-file-contents (expand-file-name (concat "test/fixtures/day/" name) drgnx-ui-repo-dir))
    (read (current-buffer))))

(defun drgnx-perf-day-composition ()
  "(:seed S :workloads W :files F :sha SHA): what the day is made of; SHA (12 hex) is over the seed, the workload names
and the files' contents, so two runs with the same SHA ran the same day."
  (list :seed drgnx-perf-day-seed :workloads drgnx-perf-day-workloads :files drgnx-perf-day-files
        :sha (substring
              (secure-hash 'sha1
                           (with-temp-buffer
                             (set-buffer-multibyte nil)
                             (insert drgnx-perf-day-seed (format "%S" drgnx-perf-day-workloads))
                             (dolist (f drgnx-perf-day-files)
                               (insert-file-contents-literally (expand-file-name f drgnx-ui-repo-dir))
                               (goto-char (point-max)))
                             (buffer-string)))
              0 12)))

(defconst drgnx-perf-day-rss-growth 20
  "Percent: the most the steady phase's RSS may grow from its first round to its last (a leak check).")

(defun drgnx-perf-day-verdict (rounds errors)
  "Failure lines of a day: ROUNDS (plists with :rss_kb, the steady phase's, oldest first) whose RSS grew by more than
`drgnx-perf-day-rss-growth' percent from the first to the last, and every one of ERRORS (strings: a workload that
failed).  There is no absolute cap: the soak's 400 MB is the soak's (`drgnx-perf-soak'), not the day's."
  (let* ((first (plist-get (car rounds) :rss_kb)) (last (plist-get (car (last rounds)) :rss_kb))
         (growth (and (cdr rounds) (numberp first) (> first 0) (/ (* 100.0 (- last first)) first))))
    (append (and growth (> growth drgnx-perf-day-rss-growth)
                 (list (format "day: RSS grew %.1f%% across the steady rounds (%d → %d MB), over %d%%"
                               growth (/ first 1024) (/ last 1024) drgnx-perf-day-rss-growth)))
            (mapcar (lambda (e) (format "day: %s" e)) errors))))

(defun drgnx-perf-day--fixture-repo (dir)
  "Copy the day's project and Org trees into DIR and make the project a git repository: two commits at fixed dates and
an uncommitted change, so `vc-git' has a status and a log to read."
  (copy-directory (expand-file-name "test/fixtures/day/project" drgnx-ui-repo-dir) (expand-file-name "project" dir) nil t t)
  (copy-directory (expand-file-name "test/fixtures/day/org" drgnx-ui-repo-dir) (expand-file-name "org" dir) nil t t)
  (let ((default-directory (file-name-as-directory (expand-file-name "project" dir)))
        (process-environment (append '("GIT_AUTHOR_NAME=Day" "GIT_AUTHOR_EMAIL=day@example.invalid"
                                       "GIT_COMMITTER_NAME=Day" "GIT_COMMITTER_EMAIL=day@example.invalid"
                                       "GIT_AUTHOR_DATE=2026-01-01T00:00:00Z" "GIT_COMMITTER_DATE=2026-01-01T00:00:00Z")
                                     process-environment)))
    (dolist (cmd '(("init" "-q") ("add" ".") ("commit" "-q" "-m" "The ledger")))
      (unless (eql 0 (apply #'call-process "git" nil nil nil cmd)) (error "day: git %s failed" (car cmd))))
    (write-region "\n;; a later change\n" nil "main.el" 'append 'silent)
    (dolist (cmd '(("commit" "-q" "-a" "-m" "A later change")))
      (unless (eql 0 (apply #'call-process "git" nil nil nil cmd)) (error "day: git %s failed" (car cmd))))
    (write-region "\n;; not committed\n" nil "util.el" 'append 'silent)))

(defun drgnx-perf-day--buildup-form (dir)
  "The build-up phase as one form for the session: open the day's files and Org trees, start eglot on the project
against the replay server, read the repository with `vc-git', start two transcript replays.  It returns a list of
(:step NAME :ms MS :rss_kb KB :heap_mb MB) and signals at the first step that fails."
  (prin1-to-string
   `(let* ((dir ,dir) (project (expand-file-name "project/" dir)) (stub ,(expand-file-name "test/fixtures/lsp-replay.el" drgnx-ui-repo-dir))
           (chunks ',(drgnx-perf-day--read "transcript.eld")) steps)
      (cl-flet ((step (name fn)
                  (let ((t0 (float-time)))
                    (funcall fn)
                    (push (list :step name :ms (round (* 1000 (- (float-time) t0))) :rss_kb (drgnx-perf-rss-kb)
                                :heap_mb (drgnx-perf-heap-mb))
                          steps))))
        (step "baseline" #'ignore)
        (step "files" (lambda ()
                        (dolist (f '("main.el" "util.el" "README.md")) (find-file-noselect (expand-file-name f project)))))
        (step "org" (lambda ()
                      (dolist (f '("inbox.org" "projects.org"))
                        (with-current-buffer (find-file-noselect (expand-file-name f (expand-file-name "org/" dir)))
                          (org-element-parse-buffer)))))
        (step "eglot" (lambda ()
                        (require 'eglot)
                        (with-current-buffer (find-file-noselect (expand-file-name "main.el" project))
                          (let ((eglot-server-programs
                                 (list (list 'emacs-lisp-mode (expand-file-name invocation-name invocation-directory)
                                             "--batch" "-Q" "-l" stub))))
                            (apply #'eglot (eglot--guess-contact))
                            (let ((d (+ (float-time) 30)))
                              (while (and (not (eglot-current-server)) (< (float-time) d)) (accept-process-output nil 0.1)))
                            (unless (eglot-current-server) (error "eglot did not connect to the replay server"))))))
        (step "vc-git" (lambda ()
                         (require 'vc)
                         (require 'vc-dir)
                         (with-current-buffer (find-file-noselect (expand-file-name "main.el" project))
                           (vc-git-state buffer-file-name)
                           (vc-git-print-log (list project) (get-buffer-create "*day-vc-log*") t nil 20)
                           (save-window-excursion (vc-dir project))
                           ;; wait for the log process and the status refresh to finish, not for a fixed time
                           (let* ((log (get-buffer "*day-vc-log*"))
                                  (dir (seq-find (lambda (b) (with-current-buffer b (derived-mode-p 'vc-dir-mode))) (buffer-list)))
                                  (d (+ (float-time) 30))
                                  (busy (lambda () (or (process-live-p (get-buffer-process log))
                                                       (with-current-buffer dir (vc-dir-busy))))))
                             (unless dir (error "vc-git: no vc-dir buffer"))
                             (while (and (< (float-time) d) (funcall busy)) (accept-process-output nil 0.1))
                             (when (funcall busy) (error "vc-git did not finish"))
                             (unless (> (buffer-size log) 0) (error "vc-git: the log is empty"))
                             (unless (> (buffer-size dir) 0) (error "vc-git: the status is empty"))))))
        (step "streams" (lambda ()
                          (dolist (n '("day-1" "day-2"))
                            (drgnx-perf-replay-start n chunks)))))
      (vconcat (nreverse steps)))))

(defconst drgnx-perf-day-teardown-form
  "(progn (dolist (n '(\"day-1\" \"day-2\")) (drgnx-perf-replay-stop n))
         (when (fboundp 'eglot-shutdown-all) (ignore-errors (eglot-shutdown-all)))
         t)"
  "The day's end in the session: the replays and the language server stopped.")

(defun drgnx-perf-day-liveness-fails (round before m)
  "Failure lines for steady round ROUND: a background replay (day-1, day-2) whose chunk count in M (:replays) did not
pass BEFORE (the counts a round earlier), or the project's language server gone (M's :eglot not t)."
  (let (out)
    (cl-mapc (lambda (n a b)
               (unless (and (numberp b) (> b a))
                 (push (format "round %d: replay %s stopped producing (%s chunks, %s a round before)" round n b a) out)))
             '("day-1" "day-2") before (append (plist-get m :replays) nil))
    (unless (eq (plist-get m :eglot) t) (push (format "round %d: the language server is gone" round) out))
    (nreverse out)))

(defun drgnx-perf-day--shuffle (list)
  "LIST in a random order (the generator seeded by the caller)."
  (let ((v (vconcat list)))
    (cl-loop for i from (1- (length v)) downto 1
             do (cl-rotatef (aref v i) (aref v (random (1+ i)))))
    (append v nil)))

(defun drgnx-perf-day--workload-watchdog (name result)
  "What the day keeps of workload NAME's RESULT: its stalls and the watchdog's numbers (nil for a result without)."
  (list :name (symbol-name name)
        :stalls (or (plist-get result :stalls) 0) :stalls-felt (or (plist-get result :stalls-felt) 0)
        :stall-max-ms (or (plist-get result :stall-max-ms) 0.0)
        :watchdog (or (plist-get result :watchdog) :null)))

(defun drgnx-perf-day--watchdog-read (sess)
  "The session's watchdog now (`drgnx-perf-watchdog-day-read'), with its histogram as a vector."
  (let ((r (drgnx-perf-run--call sess "(drgnx-perf-watchdog-day-read)")))
    (when-let* ((s (plist-get r :stats)) ((consp s)))
      (setq r (plist-put r :stats (plist-put (copy-sequence s) :drain (vconcat (plist-get s :drain))))))
    r))

(defun drgnx-perf-day--watchdog-interval (before after wall-s)
  "The watchdog's part of the interval from read BEFORE to read AFTER (WALL-S seconds): its counter delta, the stalls
that came with AFTER, and the monitor's CPU as a percent of the wall time.  Nil when the watchdog is off."
  (when (eq (plist-get after :on) t)
    (let ((d (drgnx-perf-watchdog-delta (plist-get before :stats) (plist-get after :stats) (plist-get after :edges)))
          (stalls (append (plist-get after :stalls) nil)))
      (append d (list :monitor-pct (drgnx-perf--round2 (if (> wall-s 0) (/ (* 100.0 (plist-get d :monitor-cpu-ms)) (* 1000.0 wall-s)) 0.0))
                      :wall-s (drgnx-perf--round wall-s) :stall-list (vconcat stalls) :felt (seq-count (lambda (s) (eq (plist-get s :felt) t)) stalls))))))

(defun drgnx-perf-day--watchdog-line (delta wall-s stalls)
  "One line on the watchdog over WALL-S seconds: DELTA (`drgnx-perf-watchdog-delta') and the STALLS it saw."
  (let* ((felt (seq-count (lambda (s) (eq (plist-get s :felt) t)) stalls))
         (sigs (let (alist)
                 (dolist (s stalls) (let ((k (if (string-empty-p (or (plist-get s :signature) "")) "unsampled" (plist-get s :signature))))
                                      (setf (alist-get k alist 0 nil #'equal) (1+ (alist-get k alist 0 nil #'equal)))))
                 (sort alist (lambda (a b) (> (cdr a) (cdr b)))))))
    (format "monitor %.2f%% of wall, drain p95 %.1f ms, max %.1f ms, missed %d of %d samples, stalls %d (%d felt)%s"
            (if (> wall-s 0) (/ (* 100.0 (plist-get delta :monitor-cpu-ms)) (* 1000.0 wall-s)) 0.0)
            (plist-get delta :drain-p95-ms) (plist-get delta :drain-max-ms) (plist-get delta :missed) (plist-get delta :samples)
            (length stalls) felt
            (if sigs (format ", top %s" (mapconcat (lambda (c) (format "%s x%d" (car c) (cdr c))) (seq-take sigs 3) ", ")) ""))))

(defun drgnx-perf-day (&optional minutes)
  "`drgnx test --day [MINUTES]': a long, mixed, deterministic session.  The build-up phase opens the day's
files and Org trees, starts eglot on the project against `test/fixtures/lsp-replay.el', reads the repository with
`vc-git' and starts two transcript replays; the steady phase then runs rounds of `drgnx-perf-day-workloads' (the order
shuffled from `drgnx-perf-day-seed') until MINUTES (30) have passed, sampling RSS and the live Lisp heap after each.
Fails when RSS grows more than `drgnx-perf-day-rss-growth' percent across the steady rounds or a workload errors
(`drgnx-perf-day-verdict'); there is no 400 MB rule.  Every line carries (:synthetic t :composition SHA :machine HOST).
Results go to $DRGNX_PERF_RESULTS."
  (let* ((minutes (max 1 (or minutes 30))) (deadline (+ (float-time) (* 60 minutes)))
         (comp (drgnx-perf-day-composition))
         (label (format "(:synthetic t :composition %s :machine %s)" (plist-get comp :sha)
                        (or (let ((m (getenv "DRGNX_PERF_MACHINE"))) (and m (not (string-empty-p m)) m)) (system-name))))
         (drgnx-perf-run--fixture (drgnx-perf-run--make-fixture))
         (dir (make-temp-file "drgnx-day" t))
         (process-environment (cons (format "DRGNX_UI_MAX_RUNTIME=%d" (+ (* 60 minutes) 1800)) process-environment))
         (s (drgnx-ui-start "drgnx" (drgnx-perf-run--session-size) 60)) (sess (drgnx-ui-own-session (plist-get s :name)))
         (all (drgnx-perf-run--workloads))
         (stamp (lambda () (format-time-string "%FT%T%z")))
         rounds steps errors phases (before '(0 0)) steady-t0 steady-from steady-iv wd-prev wd-t wd-info
         ;; the watchdog since the last call: its interval (nil when it is off), and what the read says of the build
         (wd-step (lambda ()
                    (let* ((now (float-time)) (cur (drgnx-perf-day--watchdog-read sess))
                           (iv (and wd-prev (drgnx-perf-day--watchdog-interval wd-prev cur (- now wd-t)))))
                      (setq wd-prev cur wd-t now)
                      (unless wd-info (setq wd-info cur))
                      iv))))
    (random (plist-get comp :seed))
    (unwind-protect
        (progn
          (drgnx-perf-run--check-gc sess)
          ;; the watchdog's arm applies as the session starts, so build-up is watched (or, for off, nothing is)
          (drgnx-perf-run--call sess "(progn (drgnx-perf--watchdog-env) t)")
          (setq wd-prev (drgnx-perf-day--watchdog-read sess) wd-t (float-time) wd-info wd-prev)
          (drgnx-perf-day--fixture-repo dir)
          (push (list :phase "build-up" :start (funcall stamp)) phases)
          (setq steps (append (drgnx-perf-run--call sess (drgnx-perf-day--buildup-form dir) 300) nil))
          (setf (car phases) (plist-put (car phases) :end (funcall stamp)))
          (when-let* ((iv (funcall wd-step)))
            (setf (car phases) (plist-put (car phases) :watchdog (drgnx-perf-run--json-ready iv)))
            (send-string-to-terminal (format "day: build-up watchdog: %s %s\n" (drgnx-perf-day--watchdog-line iv (plist-get iv :wall-s) (append (plist-get iv :stall-list) nil)) label)))
          (dolist (st steps)
            (send-string-to-terminal (format "day: build-up %-9s %6d ms, RSS %d MB, heap %.0f MB %s\n" (plist-get st :step) (plist-get st :ms)
                                             (/ (plist-get st :rss_kb) 1024) (plist-get st :heap_mb) label)))
          (push (list :phase "steady" :start (funcall stamp)) phases)
          (setq steady-t0 (float-time) steady-from wd-prev)
          (while (< (float-time) deadline)
            (let ((t0 (float-time)) (ran 0) wl)
              (dolist (name (drgnx-perf-day--shuffle drgnx-perf-day-workloads))
                (message "day: %s…" name)
                (let ((r (condition-case err (drgnx-perf-run-workload sess (cdr (assq name all)))
                           (error (list :error (error-message-string err))))))
                  (if (plist-get r :error)
                      (progn (message "day: %s FAILED: %s" name (plist-get r :error))
                             (push (format "%s: %s" name (plist-get r :error)) errors))
                    (push (drgnx-perf-day--workload-watchdog name r) wl)
                    (cl-incf ran))))
              (let* ((m (drgnx-perf-run--call
                         sess (format "(list :rss_kb (progn (garbage-collect) (drgnx-perf-rss-kb)) :heap_mb (drgnx-perf-heap-mb) :gcs gcs-done
                                            :replays (vector (drgnx-perf-replay-count \"day-1\") (drgnx-perf-replay-count \"day-2\"))
                                            :eglot (if (and (require 'eglot) (when-let* ((b (find-buffer-visiting %S))) (with-current-buffer b (eglot-current-server)))) t :false))"
                                      (expand-file-name "project/main.el" dir))))
                     (live (drgnx-perf-day-liveness-fails (1+ (length rounds)) before m)))
                (dolist (f live) (message "day: FAILED: %s" f))
                (setq errors (append (reverse live) errors) before (append (plist-get m :replays) nil))
                (let ((iv (funcall wd-step)))
                  (push (append m (list :workloads ran :seconds (round (- (float-time) t0))
                                        :workload_watchdog (vconcat (nreverse wl))
                                        :watchdog (drgnx-perf-run--json-ready iv)))
                        rounds)
                  (when iv
                    (send-string-to-terminal (format "day: round %d watchdog: %s %s\n" (length rounds)
                                                     (drgnx-perf-day--watchdog-line iv (plist-get iv :wall-s) (append (plist-get iv :stall-list) nil)) label))))
                (send-string-to-terminal (format "day: round %d: RSS %d MB, heap %.0f MB, %d collections, %d of %d workloads, replays %s chunks, language server %s, %d s %s\n"
                                                 (length rounds) (/ (plist-get m :rss_kb) 1024) (plist-get m :heap_mb) (plist-get m :gcs) ran
                                                 (length drgnx-perf-day-workloads) (append (plist-get m :replays) nil)
                                                 (if (eq (plist-get m :eglot) t) "up" "GONE") (round (- (float-time) t0)) label)))))
          (setf (car phases) (plist-put (car phases) :end (funcall stamp)))
          (when (and steady-from wd-prev)
            (setq steady-iv (drgnx-perf-day--watchdog-interval steady-from wd-prev (- wd-t steady-t0)))
            (setf (car phases) (plist-put (car phases) :watchdog (drgnx-perf-run--json-ready steady-iv)))))
      (ignore-errors (drgnx-perf-run--call sess drgnx-perf-day-teardown-form))
      (drgnx-ui-stop (plist-get s :name))
      (delete-file drgnx-perf-run--fixture)
      (ignore-errors (delete-directory dir t)))
    (setq rounds (nreverse rounds) errors (delete-dups (nreverse errors)) phases (nreverse phases))
    (when-let* ((file (getenv "DRGNX_PERF_RESULTS")))
      (unless (string-empty-p file)
        (make-directory (file-name-directory (expand-file-name file)) t)
        (write-region (concat (json-serialize
                               (list :synthetic t :composition (plist-get comp :sha) :label label :minutes minutes
                                     :phases (vconcat (mapcar (lambda (p) (drgnx-perf-run--json-ready p)) phases))
                                     :build_up (vconcat (mapcar #'drgnx-perf-run--json-ready steps))
                                     :watchdog (list :on (if (eq (plist-get wd-info :on) t) t :false)
                                                     :native (or (plist-get wd-info :native) :false)
                                                     :version_dir (or (plist-get wd-info :version-dir) "")
                                                     :drgnx_mode (or (plist-get wd-info :drgnx-mode) :false))
                                     :rounds (vconcat (mapcar #'drgnx-perf-run--json-ready rounds))
                                     :errors (vconcat errors)))
                              "\n")
                      nil file nil 'silent)))
    (unless rounds (error "The day finished no steady round"))
    (let ((fails (drgnx-perf-day-verdict rounds errors)))
      (princ (format "day: %d steady rounds in %d min; RSS %d → %d MB, heap %.0f → %.0f MB %s\n"
                     (length rounds) minutes (/ (plist-get (car rounds) :rss_kb) 1024) (/ (plist-get (car (last rounds)) :rss_kb) 1024)
                     (plist-get (car rounds) :heap_mb) (plist-get (car (last rounds)) :heap_mb) label))
      (unless (cdr rounds) (princ "day: one steady round, RSS growth not judged\n"))
      (princ (format "day: watchdog: %s%s\n"
                     (if (eq (plist-get wd-info :on) t)
                         (format "on, drgnx-watchdog-mode %s, preloaded Lisp %s (%s); steady phase: %s"
                                 (if (eq (plist-get wd-info :drgnx-mode) t) "on" "off")
                                 (if (eq (plist-get wd-info :native) t) "native yes" "native no") (plist-get wd-info :version-dir)
                                 (if steady-iv (drgnx-perf-day--watchdog-line steady-iv (plist-get steady-iv :wall-s) (append (plist-get steady-iv :stall-list) nil)) "nothing read"))
                       (format "off, drgnx-watchdog-mode %s" (if (eq (plist-get wd-info :drgnx-mode) t) "on" "off")))
                     label))
      (dolist (f fails) (princ (format "FAIL %s\n" f)))
      (if fails 1 (princ "day: the leak rule holds, no workload failed\n") 0))))

;;;; Paired A/B: `drgnx test --perf --ab REF'

(defun drgnx-perf-ab--shell (cmd)
  "Run the shell command CMD; its exit code (the output is shown)."
  (call-process-shell-command cmd nil t))

(defun drgnx-perf-ab--export (ref dest)
  "REF's files as they are in git, into DEST: an archive, not a worktree (no branch, no .git, nothing to remove)."
  (make-directory dest t)
  (let ((code (drgnx-perf-ab--shell (format "git -C %s archive %s | tar -x -C %s" (shell-quote-argument (directory-file-name drgnx-ui-repo-dir))
                                            (shell-quote-argument ref) (shell-quote-argument dest)))))
    (unless (eql code 0) (error "perf: cannot export %s (git archive failed)" ref))))

(defun drgnx-perf-ab--build (tree)
  "`bin/drgnx build' in TREE (its .elc files; the native-compilation cache is warmed by `drgnx-perf-ab--settle-form')."
  (unless (eql 0 (drgnx-perf-ab--shell (format "%s build" (shell-quote-argument (expand-file-name "bin/drgnx" tree)))))
    (error "perf: bin/drgnx build failed in %s" tree)))

(defun drgnx-perf-ab--start (tree &optional env)
  "A session whose init, core, wb and modules come from TREE (nil: the controller's own); the harness is ours.
ENV (\"K=V\" strings, `drgnx-ui-session-extra-env-names' only) is added to its environment."
  (let ((drgnx-ui-session-repo tree) (drgnx-ui-session-extra-env env))
    (drgnx-ui-start "drgnx" (drgnx-perf-run--session-size) 60)))

(defun drgnx-perf-ab-env-parse (spec)
  "SPEC, \"VAR=JUDGED,REF\", as (VAR JUDGED REF); an error unless it has a name and exactly two non-empty values."
  (if (string-match "\\`\\([A-Z_][A-Z0-9_]*\\)=\\([^,=]+\\),\\([^,=]+\\)\\'" spec)
      (list (match-string 1 spec) (match-string 2 spec) (match-string 3 spec))
    (error "usage: drgnx test --perf --ab-env VAR=JUDGED,REF (two values, comma-separated)")))

(defun drgnx-perf-ab--one (sess spec)
  "One repeat of the input workload SPEC in SESS: (:samples (ms per command…) :run RESULT)."
  (when (plist-get spec :each) (drgnx-perf-run--call sess (plist-get spec :each) 120) (drgnx-ui-measure sess nil))
  (drgnx-perf-run--call sess (drgnx-perf-run--begin-form spec))
  (drgnx-ui-measure sess (plist-get spec :actions))
  (let* ((run (append (drgnx-perf-run--call sess "(drgnx-perf-end)")
                      (drgnx-perf-run--extras sess spec)
                      (and (plist-get spec :measure) (drgnx-perf-run--call sess (plist-get spec :measure) 120))))
         (samples (append (drgnx-perf-run--call sess "(vconcat drgnx-perf--latencies)") nil)))
    (when (and (plist-get spec :check) (not (eq t (drgnx-perf-run--call sess (plist-get spec :check)))))
      (error "The workload did not do what it measures (%s)" (plist-get spec :check)))
    (list :samples samples :run run)))

(defconst drgnx-perf-ab-min-rounds 8
  "The fewest rounds (a run of each side) an A/B is judged on: the interval is over the rounds, not the samples.")

(defun drgnx-perf-ab-rounds (n run)
  "Call RUN with a side (its wall samples come back) until both sides have at least N samples and
`drgnx-perf-ab-min-rounds' rounds, an even number.  The order alternates, ABBA: round 1 runs a then b, round 2
b then a…, so a fixed order bias (the side that runs second pays for the first's allocation) falls on both sides alike.
(:a SAMPLES :b SAMPLES :rounds ((:a S :b S)…) :order (SIDE…) in the order they ran)."
  (let (rounds order (guard 0))
    (while (or (< (length rounds) drgnx-perf-ab-min-rounds) (cl-oddp (length rounds))
               (< (apply #'+ (mapcar (lambda (r) (length (plist-get r :a))) rounds)) n)
               (< (apply #'+ (mapcar (lambda (r) (length (plist-get r :b))) rounds)) n))
      (when (> (cl-incf guard) 2000) (error "perf: no wall samples after 2000 rounds"))
      (let* ((sides (if (cl-evenp (length rounds)) '(a b) '(b a)))
             (first (funcall run (car sides))) (second (funcall run (cadr sides))))
        (push (if (eq (car sides) 'a) (list :a first :b second) (list :a second :b first)) rounds)
        (setq order (append order sides))))
    (setq rounds (nreverse rounds))
    (list :a (apply #'append (mapcar (lambda (r) (plist-get r :a)) rounds))
          :b (apply #'append (mapcar (lambda (r) (plist-get r :b)) rounds))
          :rounds rounds :order order)))

(defun drgnx-perf-ab--budget-fails (workload stats budgets &optional run compose-n others)
  "The work tree's absolute wall-clock BUDGETS for WORKLOAD against STATS (of its samples), judged at n >= 100.
`:compose' rows are read from RUN (the work tree's run, median-reduced over its rounds) and judged at COMPOSE-N
(`(:compose :count)' summed over its rounds) >= 100.  A `:compose' row whose plist has `:known ID :fails-above
CEILING' (a known failure, e.g. GL-POPUP-CHURN-FULL-1) is reported as (:known LINE) while its value is above LIMIT
but at most CEILING, and fails only above CEILING.  With `:known ID :fails-above-row (ROW PATH) :by B' instead the
ceiling is ROW's value at PATH in this A/B plus B: OTHERS is an alist (WORKLOAD . RUN) of the work tree's runs of the
workloads judged before this one (e.g. scroll-under-popup against scrolling); a ROW not among them fails the row."
  (let (out)
    (dolist (b budgets)
      (pcase-let ((`(,w ,path ,limit . ,plist) b))
        (cond
         ((not (eq w workload)))
         ((and (eq (car path) :input) (not (cdr (cdr path))))
          (let ((v (plist-get stats (cadr path))))
            (when (and (>= (plist-get stats :n) 100) (numberp v) (> v limit))
              (push (format "%s input %s %s > %s" w (substring (symbol-name (cadr path)) 1) (drgnx-perf--round v) limit) out))))
         ((eq (car path) :compose)
          (let* ((v (drgnx-perf--path-value run path))
                 (known (plist-get plist :known)) (row (plist-get plist :fails-above-row))
                 (ref (and row (drgnx-perf--path-value (cdr (assq (car row) others)) (cadr row))))
                 (ceiling (if row (and (numberp ref) (+ ref (plist-get plist :by)))
                            (plist-get plist :fails-above)))
                 (what (if row
                           (if (numberp ref)
                               (format "%s %s %s + %s" (car row) (drgnx-perf--path-name (cadr row))
                                       (drgnx-perf--round2 ref) (plist-get plist :by))
                             (format "%s %s + %s, not measured in this run" (car row)
                                     (drgnx-perf--path-name (cadr row)) (plist-get plist :by)))
                         ceiling)))
            (when (and (>= (or compose-n 0) 100) (numberp v) (> v limit))
              (let ((line (format "%s %s %s > %s" w (drgnx-perf--path-name path) (drgnx-perf--round v) limit)))
                (push (cond ((not known) line)
                            ((and (numberp ceiling) (<= v ceiling))
                             (list :known (format "%s (%s; fails above %s)" line known what)))
                            (t (format "%s (%s) and > %s" line known what)))
                      out))))))))
    (nreverse out)))

(defconst drgnx-perf-ab--quiet-form
  "(if (and (fboundp 'drgnx-perf--running-p) (boundp 'drgnx-perf--hub) (process-live-p drgnx-perf--hub))
     (drgnx-perf--wait 60 (lambda ()
       (not (or (and (boundp 'drgnx-perf--stream) drgnx-perf--stream (drgnx-perf--running-p drgnx-perf--stream))
                (and (boundp 'drgnx-perf--agent) drgnx-perf--agent (drgnx-perf--running-p drgnx-perf--agent))
                (and (boundp 'drgnx-perf--agents) (seq-some #'drgnx-perf--running-p drgnx-perf--agents))))))
   t)"
  "Waits (at most 60 s) until the session's agent workloads have no turn running: a stream that outlives its run is the
session's own background work, and a calibration taken beside it reads loaded.")

(defun drgnx-perf-ab--calibrate (call s &rest others)
  "The calibration of session S through CALL (session, form), taken once S and every session in OTHERS are quiet
(`drgnx-perf-ab--quiet-form'): the other side's stream, still running from its last run, shares the host's cores."
  (dolist (x (cons s others)) (funcall call x drgnx-perf-ab--quiet-form))
  (funcall call s "(drgnx-perf-calibrate)"))

(defun drgnx-perf-ab--workload (name spec sa sb n &optional others)
  "A/B workload NAME between sessions SA (the REF) and SB (the work tree): an entry plist, :status one of
judged, not-comparable, error, not-judged.  OTHERS: the work tree's runs of the workloads judged before it, an alist
(WORKLOAD . RUN), for budget rows judged against another row (`drgnx-perf-ab--budget-fails')."
  (let ((call (lambda (s f) (drgnx-perf-run--call s f 120))))
    (cond
     ((or (plist-get spec :daemon) (null (plist-get spec :actions)))
      (list :name name :status 'not-comparable :why "no per-command wall samples"))
     (t
      (condition-case err
          (let (runs-a runs-b cal-a cal-b warm)
            (unwind-protect
                (progn
                  (when (plist-get spec :setup)
                    (condition-case e (funcall call sa (plist-get spec :setup))
                      (error (signal 'drgnx-perf-ab-ref-error (list (error-message-string e)))))
                    (funcall call sb (plist-get spec :setup)))
                  (setq cal-a (list (drgnx-perf-ab--calibrate call sa sb)) cal-b (list (drgnx-perf-ab--calibrate call sb sa)))
                  ;; one run each, discarded: the same warm-up for both (the first run pays for lazy loading and eln)
                  (setq warm (list (plist-get (drgnx-perf-stats (plist-get (condition-case e (drgnx-perf-ab--one sa spec)
                                                                             (error (signal 'drgnx-perf-ab-ref-error (list (error-message-string e)))))
                                                                           :samples)) :p50)
                                   (plist-get (drgnx-perf-stats (plist-get (drgnx-perf-ab--one sb spec) :samples)) :p50)))
                  (let* ((r (drgnx-perf-ab-rounds n (lambda (side)
                                                      (let ((one (drgnx-perf-ab--one (if (eq side 'a) sa sb) spec)))
                                                        (push (plist-get one :run) (if (eq side 'a) runs-a runs-b))
                                                        (plist-get one :samples)))))
                         (a (plist-get r :a)) (b (plist-get r :b)))
                    (push (drgnx-perf-ab--calibrate call sa sb) cal-a)
                    (push (drgnx-perf-ab--calibrate call sb sa) cal-b)
                    (let* ((loaded (seq-some (lambda (c) (plist-get c :loaded)) (append cal-a cal-b)))
                           (sa-stats (drgnx-perf-stats a)) (sb-stats (drgnx-perf-stats b)))
                      (append (list :name name :status (if loaded 'not-judged 'judged) :a sa-stats :b sb-stats
                                    :warm warm :calibration (list :a cal-a :b cal-b)
                                    :a-run (drgnx-perf-run--medians runs-a) :b-run (drgnx-perf-run--medians runs-b)
                                    :runs (/ (length (plist-get r :order)) 2) :order (plist-get r :order)
                                    :wall-rounds (plist-get r :rounds)
                                    :run-rounds (cl-mapcar (lambda (x y) (list :a x :b y)) (reverse runs-a) (reverse runs-b))
                                    :phase-sum (drgnx-perf-ab-phase-sum (drgnx-perf-run--medians runs-a) (drgnx-perf-run--medians runs-b)))
                              (and (not loaded)
                                   (list :verdict (drgnx-perf-ab-verdict a b (plist-get r :rounds))
                                         :p95-verdict (drgnx-perf-ab-verdict a b (plist-get r :rounds) :stat 'p95 :threshold 1.0)
                                         :probe-verdict (drgnx-perf-ab-probe-verdict
                                                         (cl-mapcar (lambda (x y) (list :a x :b y)) (reverse runs-a) (reverse runs-b))
                                                         '(:compose :draw-ms :p95))
                                         :metric-verdicts (drgnx-perf-ab-metric-verdicts
                                                           (cl-mapcar (lambda (x y) (list :a x :b y)) (reverse runs-a) (reverse runs-b)))
                                         :digest-verdict (drgnx-perf-ab-digest-verdict
                                                          (cl-mapcar (lambda (x y) (list :a x :b y)) (reverse runs-a) (reverse runs-b)))))
                              (list :budget-fails
                                    (drgnx-perf-ab--budget-fails
                                     name sb-stats (drgnx-perf-run--budgets) (drgnx-perf-run--medians runs-b)
                                     (apply #'+ (mapcar (lambda (x) (or (drgnx-perf--path-value x '(:compose :count)) 0)) runs-b))
                                     others)))))
                  )
              (when (plist-get spec :teardown)
                (ignore-errors (funcall call sa (plist-get spec :teardown)))
                (ignore-errors (funcall call sb (plist-get spec :teardown))))))
        (drgnx-perf-ab-ref-error (list :name name :status 'not-comparable :why (format "errors on REF: %s" (cadr err))))
        (error (list :name name :status 'error :why (error-message-string err))))))))

(define-error 'drgnx-perf-ab-ref-error "The workload failed on REF")

(defun drgnx-perf-ab--per-round (e key path)
  "One value per round for each arm of entry E: the value at PATH in every round's run, null where a run has none.
The :a-run and :b-run medians keep one run's digest and a median blank count; this keeps them all."
  (cl-flet ((arm (side) (vconcat (mapcar (lambda (r) (let ((v (plist-get r side)))
                                                       (dolist (k path) (setq v (plist-get v k)))
                                                       v))
                                         (plist-get e :run-rounds)))))
    (and (plist-get e :run-rounds) (list key (list :a (arm :a) :b (arm :b))))))

(defun drgnx-perf-ab--round-data (e)
  "A vector, one element per round of entry E: (:a ARM :b ARM), each arm's input p95/p99/max and stall counts in that
round's run (null where the run has none)."
  (when (plist-get e :run-rounds)
    (cl-flet ((arm (run)
                (let ((in (plist-get run :input)))
                  (list :input_p95 (plist-get in :p95) :input_p99 (plist-get in :p99) :input_max (plist-get in :max)
                        :stalls_ge16 (plist-get run :stalls-ge16) :stalls_ge100 (plist-get run :stalls-ge100)))))
      (vconcat (mapcar (lambda (r) (list :a (arm (plist-get r :a)) :b (arm (plist-get r :b))))
                       (plist-get e :run-rounds))))))

(defun drgnx-perf-ab--result-entry (e)
  "The results-file record of entry E: (NAME . PLIST)."
  (let ((v (plist-get e :verdict)))
    (cons (plist-get e :name)
          (append
           (list :status (symbol-name (plist-get e :status))
                 :verdict (and v (symbol-name (plist-get v :verdict)))
                 :diff (and v (list :diff (plist-get v :diff) :lo (plist-get v :lo) :hi (plist-get v :hi)))
                 :p95_verdict (and (plist-get e :p95-verdict) (symbol-name (plist-get (plist-get e :p95-verdict) :verdict)))
                 :probe_verdict (and (plist-get e :probe-verdict) (symbol-name (plist-get (plist-get e :probe-verdict) :verdict)))
                 :digest_verdict (and (plist-get e :digest-verdict) (symbol-name (plist-get (plist-get e :digest-verdict) :verdict)))
                 :metric_verdicts (mapcan (lambda (m) (list (intern (concat ":" (drgnx-perf--path-name (car m))))
                                                            (symbol-name (plist-get (cdr m) :verdict))))
                                          (plist-get e :metric-verdicts))
                 :a (plist-get e :a) :b (plist-get e :b)
                 :a_run (plist-get e :a-run) :b_run (plist-get e :b-run) :order (mapcar (function symbol-name) (plist-get e :order)) :why (plist-get e :why))
           (and (plist-get e :run-rounds) (list :run_rounds (drgnx-perf-ab--round-data e)))
           (drgnx-perf-ab--per-round e :digests '(:digest))
           (drgnx-perf-ab--per-round e :blanks '(:live :blank))))))

(defun drgnx-perf-ab--line (e)
  (let* ((st (plist-get e :status)) (v (plist-get e :verdict)) (a (plist-get e :a)) (b (plist-get e :b))
         (side (lambda (x) (format "n=%s p50 %s p90 %s p95 %s" (plist-get x :n) (drgnx-perf--round (plist-get x :p50)) (drgnx-perf--round (plist-get x :p90))
                                   (or (drgnx-perf--round (plist-get x :p95)) "-")))))
    (pcase st
      ('not-comparable (format "%-13s not comparable: %s" (plist-get e :name) (plist-get e :why)))
      ('error (format "%-13s ERROR: %s" (plist-get e :name) (plist-get e :why)))
      ('aa-failed (format "%-13s A/A failed: %s (the A/B was not run: the lab, not the change, differs between the sides)%s"
                          (plist-get e :name) (plist-get e :why)
                          (mapconcat (lambda (n) (format "\n%-13s %s" "" n)) (plist-get e :notes) "")))
      (_ (format "%-13s %s\n%-13s REF  %s\n%-13s tree %s\n%-13s diff %s ms [%s, %s] threshold %s; warm-up p50 REF %s tree %s; alloc p50 %s/%s, cpu p90 %s/%s, rows %s/%s"
                 (plist-get e :name)
                 (if (eq st 'not-judged) "not judged: loaded calibration (wall clock is the machine's)" (symbol-name (plist-get v :verdict)))
                 "" (funcall side a) "" (funcall side b)
                 "" (drgnx-perf--round2 (plist-get v :diff)) (drgnx-perf--round2 (plist-get v :lo)) (drgnx-perf--round2 (plist-get v :hi))
                 (drgnx-perf--round2 (plist-get v :threshold)) (drgnx-perf--round (nth 0 (plist-get e :warm))) (drgnx-perf--round (nth 1 (plist-get e :warm)))
                 (plist-get (plist-get (plist-get e :a-run) :alloc) :p50) (plist-get (plist-get (plist-get e :b-run) :alloc) :p50)
                 (plist-get (plist-get (plist-get e :a-run) :cpu_ms) :p90) (plist-get (plist-get (plist-get e :b-run) :cpu_ms) :p90)
                 (plist-get (plist-get e :a-run) :rows) (plist-get (plist-get e :b-run) :rows))))))

(defun drgnx-perf-ab--verdict-line (label v)
  "One report line for the verdict plist V named LABEL."
  (format "%-13s %s %s (diff %s ms [%s, %s] threshold %s)" "" label (symbol-name (plist-get v :verdict))
          (drgnx-perf--round2 (plist-get v :diff)) (drgnx-perf--round2 (plist-get v :lo)) (drgnx-perf--round2 (plist-get v :hi))
          (drgnx-perf--round2 (plist-get v :threshold))))

(defun drgnx-perf-ab--extra-lines (e)
  "The p95 verdict and, when the runs carry it, the probe verdict of the judged entry E, each on a line of its own."
  (let ((p95 (plist-get e :p95-verdict)) (probe (plist-get e :probe-verdict))
        (digest (plist-get e :digest-verdict))
        (pa (plist-get (plist-get e :a-run) :present)) (pb (plist-get (plist-get e :b-run) :present)))
    (concat (and p95 (concat "\n" (drgnx-perf-ab--verdict-line "p95" p95)))
            (mapconcat (lambda (m) (concat "\n" (drgnx-perf-ab--verdict-line (drgnx-perf--path-name (car m)) (cdr m))))
                       (plist-get e :metric-verdicts) "")
            (and digest (not (eq (plist-get digest :verdict) 'not-comparable))
                 (format "\n%-13s digest %s" "" (if (plist-get digest :why) "regressed (digest)" "same")))
            (and (plist-member e :aa) (format "\n%-13s A/A %s" "" (plist-get e :aa)))
            (mapconcat (lambda (n) (format "\n%-13s %s" "" n)) (plist-get e :aa-notes) "")
            (let ((d (drgnx-perf-ab-phase-delta-line (plist-get e :a-run) (plist-get e :b-run))))
              (and d (format "\n%-13s explain %s" "" d)))
            (and (plist-member e :phase-sum)
                 (format "\n%-13s phase-sum %s" "" (if-let* ((m (plist-get e :phase-sum)))
                                                       (format "MISMATCH: %s" (plist-get (cdr m) :why))
                                                     "ok")))
            ;; the phases explain a verdict, they do not make one
            (let ((ex (drgnx-perf-ab-phase-explain (plist-get e :a-run) (plist-get e :b-run))))
              (and ex (concat "\n" (format "%-13s explain (worker phases, ms: REF / tree; not judged)" "")
                              (mapconcat (lambda (p) (format "\n%-13s   %s %s / %s" "" (nth 0 p) (or (nth 1 p) "-") (or (nth 2 p) "-")))
                                         ex ""))))
            (and probe (not (eq (plist-get probe :verdict) 'not-comparable))
                 (concat "\n" (drgnx-perf-ab--verdict-line "probe compose draw-ms p95" probe)))
            (and pa pb (format "\n%-13s key to present (ms, REF/tree): p50 %s/%s p90 %s/%s" ""
                               (plist-get pa :p50) (plist-get pb :p50) (plist-get pa :p90) (plist-get pb :p90))))))

(defconst drgnx-perf-ab-session-runtime (* 4 3600)
  "Seconds an A/B's two sessions may live ($DRGNX_UI_MAX_RUNTIME for them unless it is set): they serve every
workload of the run, and a full tier at 2880x1800 took over 30 min, the default cap, which ended both sessions
mid-run (\"can't find socket\").  The run stops them when it ends.")

(defun drgnx-perf-ab--deciding (a b wall-rounds run-rounds)
  "((LABEL . VERDICT-SYMBOL)…): the verdicts an `--ab-env' A/B counts, for the wall samples A and B (WALL-ROUNDS) and
the runs RUN-ROUNDS: median, p95, the compose probe and the probe metrics."
  (append (list (cons "median" (plist-get (drgnx-perf-ab-verdict a b wall-rounds) :verdict))
                (cons "p95" (plist-get (drgnx-perf-ab-verdict a b wall-rounds :stat 'p95 :threshold 1.0) :verdict))
                (cons "compose draw-ms p95" (plist-get (drgnx-perf-ab-probe-verdict run-rounds '(:compose :draw-ms :p95)) :verdict)))
          (mapcar (lambda (m) (cons (drgnx-perf--path-name (car m)) (plist-get (cdr m) :verdict)))
                  (drgnx-perf-ab-metric-verdicts run-rounds))))

(defun drgnx-perf-ab--swap (rounds)
  "ROUNDS with the sides exchanged."
  (mapcar (lambda (r) (list :a (plist-get r :b) :b (plist-get r :a))) rounds))

(defun drgnx-perf-ab--aa-labelled (e)
  "((LABEL VERDICT DIRECTION)…): the deciding verdicts of the A/A entry E, read forward and reverse."
  (let* ((rounds (plist-get e :wall-rounds)) (runs (plist-get e :run-rounds))
         (a (apply #'append (mapcar (lambda (r) (plist-get r :a)) rounds)))
         (b (apply #'append (mapcar (lambda (r) (plist-get r :b)) rounds))) out)
    (cl-loop for (dir . vs) in (list (cons "forward" (drgnx-perf-ab--deciding a b rounds runs))
                                     (cons "reverse" (drgnx-perf-ab--deciding b a (drgnx-perf-ab--swap rounds)
                                                                              (drgnx-perf-ab--swap runs))))
             do (dolist (v vs) (push (list (car v) (cdr v) dir) out)))
    (nreverse out)))

(defun drgnx-perf-ab-aa-problems (e &optional labelled)
  "Why the A/A entry E (a workload run against itself) refuses the A/B, a list of strings, nil when it passes: a
deciding verdict of `regressed' in either direction (the build reads worse than itself: the lab is broken), a digest
that differs, or a per-arm phase-sum mismatch.  `inconclusive' does not refuse (`drgnx-perf-ab-aa-notes').  LABELLED
is `drgnx-perf-ab--aa-labelled' of E when the caller has it."
  (let ((runs (plist-get e :run-rounds)) out)
    (dolist (v (or labelled (drgnx-perf-ab--aa-labelled e)))
      (when (eq (nth 1 v) 'regressed) (push (format "%s regressed (%s)" (nth 0 v) (nth 2 v)) out)))
    (when (eq (plist-get (drgnx-perf-ab-digest-verdict runs) :verdict) 'regressed) (push "digest differs" out))
    (when-let* ((m (plist-get e :phase-sum))) (push (format "phase-sum: %s" (plist-get (cdr m) :why)) out))
    (nreverse out)))

(defun drgnx-perf-ab-aa-notes (e &optional labelled)
  "The A/A entry E's `inconclusive' deciding verdicts as lines to print, e.g. \"A/A: p95 inconclusive (forward)\"."
  (cl-loop for v in (or labelled (drgnx-perf-ab--aa-labelled e))
           when (eq (nth 1 v) 'inconclusive) collect (format "A/A: %s inconclusive (%s)" (nth 0 v) (nth 2 v))))

(defun drgnx-perf-ab--aa (name spec s n)
  "The A/A before an A/B: workload NAME run against itself on the session S (the same build, the same setting; the
rounds alternate as in an A/B).  An entry with `:status' `aa-passed' or, when `drgnx-perf-ab-aa-problems' finds
any, `aa-failed' and `:why' naming them.  An A/A that was not judged (a loaded calibration, an error, not comparable)
proves nothing about the lab, so it is `aa-failed' too, with the status and its reason."
  (let ((e (drgnx-perf-ab--workload name spec s s n)))
    (if (not (eq (plist-get e :status) 'judged))
        (list :name name :status 'aa-failed
              :why (format "the A/A was %s%s" (plist-get e :status)
                           (cond ((plist-get e :why) (format " (%s)" (plist-get e :why)))
                                 ((eq (plist-get e :status) 'not-judged) " (loaded calibration)")
                                 (t "")))
              :notes nil)
      (let* ((labelled (drgnx-perf-ab--aa-labelled e))
             (problems (drgnx-perf-ab-aa-problems e labelled)))
        (list :name name :status (if problems 'aa-failed 'aa-passed)
              :why (and problems (string-join problems "; "))
              :notes (drgnx-perf-ab-aa-notes e labelled))))))

(cl-defun drgnx-perf-ab (ref &key (n 100) env (aa t))
  "`drgnx test --perf --ab REF': wall clock judged by interleaving two trees.  REF is exported with `git archive'
and both trees are built; one session each; per workload one discarded warm-up run per side, then runs
A, B, A, B… until each side has at least N per-command samples (and `drgnx-perf-ab-min-rounds' rounds), with the
calibration before and after.  Per workload: both sides' stats, the bootstrap verdict (`drgnx-perf-ab-verdict'),
both sides' allocation, CPU and rows, and the work tree's wall budgets (judged at n >= 100).  Exit: 0 judged
and clean, 1 regressed or a budget fails, 3 not judged (a loaded calibration, a busy host, an inconclusive
interval).  Results go to $DRGNX_PERF_RESULTS.  With DRGNX_LEASE_BUSY set it runs plain `--perf' on the work
tree instead.
Each judged workload also prints the p95 verdict (T = 1 ms) and, when the runs carry it, the verdict on
`(:compose :draw-ms :p95)'; with ENV they count in the exit code as well, and `:compose' budget rows are judged.
ENV, (VAR JUDGED REF) from `drgnx-perf-ab-env-parse', makes it an A/B on one tree (REF is nil, nothing is exported):
the work-tree side (the judged one) runs with VAR=JUDGED, the REF side with VAR=REF.
With ENV and AA (the default; `--no-aa' clears it) the first selected workload runs against itself once, on the REF
side's session (`drgnx-perf-ab--aa'), before any A/B round: the A/A proves the lab is quiet now, whatever the
workload.  With a `regressed' deciding verdict either way, a differing digest or a failing per-arm phase-sum check no
workload gets an A/B round, and the exit code is 4 (\"A/A failed\", printed under that workload's name); else every
workload gets its A/B.  `inconclusive' verdicts are printed once as \"A/A (WORKLOAD): …\" lines and do not block.
The results file records the A/A once, as `aa', with the workload it ran on."
  (if (getenv "DRGNX_LEASE_BUSY")
      (let ((code (drgnx-perf-run)))
        (princ "wall clock not judged: host busy\n")
        (if (eql code 0) 3 code))
    (let* ((own-tmp (unless (getenv "DRGNX_RUN_TMP") (make-temp-file "drgnx-ab" t)))
           (tmp (or (getenv "DRGNX_RUN_TMP") own-tmp)) (ref-tree (expand-file-name "ab-ref" tmp))
           (drgnx-perf-run--fixture (drgnx-perf-run--make-fixture))
           (workloads (drgnx-perf-run--select (drgnx-perf-run--workloads)))
           ;; the two sessions serve every workload: a full tier outlives a session's default 30 min cap
           (process-environment (if (getenv "DRGNX_UI_MAX_RUNTIME") process-environment
                                  (cons (format "DRGNX_UI_MAX_RUNTIME=%d" drgnx-perf-ab-session-runtime)
                                        process-environment)))
           sa-name sb-name entries aa-entry)
      (unwind-protect
          (progn
            (unless env
              (drgnx-perf-ab--export ref ref-tree)
              (drgnx-perf-ab--build ref-tree))
            (drgnx-perf-ab--build drgnx-ui-repo-dir)
            (if env     ; one tree, two sessions: the REF side gets the second value, the judged side the first
                (setq sa-name (plist-get (drgnx-perf-ab--start nil (list (format "%s=%s" (nth 0 env) (nth 2 env)))) :name)
                      sb-name (plist-get (drgnx-perf-ab--start nil (list (format "%s=%s" (nth 0 env) (nth 1 env)))) :name))
              (setq sa-name (plist-get (drgnx-perf-ab--start ref-tree) :name) sb-name (plist-get (drgnx-perf-ab--start nil) :name)))
            (let ((sa (drgnx-ui-own-session sa-name)) (sb (drgnx-ui-own-session sb-name)))
              (drgnx-perf-run--call sa drgnx-perf-ab--settle-form 200)
              (drgnx-perf-run--call sb drgnx-perf-ab--settle-form 200)
              ;; one A/A per invocation, on the first selected workload: it proves the lab is quiet now
              (when (and env aa workloads)
                (message "perf ab: %s: A/A first…" (car (car workloads)))
                (setq aa-entry (drgnx-perf-ab--aa (car (car workloads)) (cdr (car workloads)) sa n)))
              (if (eq (plist-get aa-entry :status) 'aa-failed)
                  (push aa-entry entries)       ; refused: no A/B round for any workload
                (dolist (w workloads)
                  (message "perf ab: %s…" (car w))
                  (push (drgnx-perf-ab--workload
                         (car w) (cdr w) sa sb n
                         (mapcar (lambda (e) (cons (plist-get e :name) (plist-get e :b-run))) entries))
                        entries)))))
        (when sa-name (ignore-errors (drgnx-ui-stop sa-name)))
        (when sb-name (ignore-errors (drgnx-ui-stop sb-name)))
        ;; the runner deletes its DRGNX_RUN_TMP; a directory made here is removed here
        (when own-tmp (ignore-errors (delete-directory own-tmp t)))
        (delete-file drgnx-perf-run--fixture))
      (setq entries (nreverse entries))
      (when (eq (plist-get aa-entry :status) 'aa-passed) ; a failed one is an entry, printed under its workload
        (princ (format "A/A (%s): passed\n" (plist-get aa-entry :name)))
        (dolist (note (plist-get aa-entry :notes))
          (princ (concat (string-replace "A/A: " (format "A/A (%s): " (plist-get aa-entry :name)) note) "\n"))))
      (dolist (e entries) (princ (concat (drgnx-perf-ab--line e) (drgnx-perf-ab--extra-lines e) "\n")))
      (when-let* ((file (getenv "DRGNX_PERF_RESULTS")))
        (unless (string-empty-p file)
          (drgnx-perf-run--write-results
           file (append
                 (mapcar #'drgnx-perf-ab--result-entry entries)
                 ;; the A/A once, with the workload it ran on
                 (and aa-entry (list (cons 'aa (list :status (symbol-name (plist-get aa-entry :status))
                                                     :workload (symbol-name (plist-get aa-entry :name))
                                                     :why (plist-get aa-entry :why)
                                                     :notes (plist-get aa-entry :notes)))))))))
      (let* ((verdicts (append (mapcar (lambda (e) (plist-get (plist-get e :verdict) :verdict)) entries)
                               ;; --ab-env also judges the p95 and the probe verdicts; --ab only prints the p95 one
                               (and env (mapcar (lambda (e) (plist-get (plist-get e :p95-verdict) :verdict)) entries))
                               (and env (mapcar (lambda (e) (plist-get (plist-get e :probe-verdict) :verdict)) entries))
                               ;; items 2-4 of §17.6 (metrics, completion, digest): judged with --ab-env, printed by --ab
                               (and env (seq-mapcat (lambda (e) (mapcar (lambda (m) (plist-get (cdr m) :verdict)) (plist-get e :metric-verdicts)))
                                                    entries))
                               (and env (mapcar (lambda (e) (plist-get (plist-get e :digest-verdict) :verdict)) entries))))
             (rows (seq-mapcat (lambda (e) (plist-get e :budget-fails)) entries))
             (known (seq-filter (lambda (f) (eq (car-safe f) :known)) rows))
             (fails (append (seq-remove (lambda (f) (eq (car-safe f) :known)) rows)
                            (seq-filter (lambda (e) (eq (plist-get e :status) 'error)) entries))))
        (dolist (k known) (princ (format "KNOWN %s\n" (cadr k))))
        (dolist (f (seq-filter #'stringp fails)) (princ (format "FAIL %s\n" f)))
        (cond ((seq-some (lambda (e) (eq (plist-get e :status) 'aa-failed)) entries)
               (princ "perf ab: A/A failed, the A/B is refused\n") 4)
              ((or (memq 'regressed verdicts) fails) 1)
              ((or (memq 'inconclusive verdicts) (seq-some (lambda (e) (eq (plist-get e :status) 'not-judged)) entries)
                   (null (seq-filter (lambda (e) (eq (plist-get e :status) 'judged)) entries)))
               (princ "wall clock not judged: loaded calibration, inconclusive interval or nothing comparable\n") 3)
              (t (princ "perf ab: no regression, wall budgets hold\n") 0))))))

(cl-defun drgnx-perf-ab-env (spec &key (n 100) (aa t))
  "`drgnx test --perf --ab-env VAR=JUDGED,REF' (SPEC): `drgnx-perf-ab' between two sessions of this tree whose
environments differ in VAR.  The first value is the judged side (the A/B tool's work tree), the second the reference,
so \"regressed\" means the judged value is slower.  N is the minimum per-command samples per side (default 100,
what makes p95 non-null; gate runs do not pass it).  AA nil skips the A/A that runs first."
  (drgnx-perf-ab nil :n n :env (drgnx-perf-ab-env-parse spec) :aa aa))

(provide 'drgnx-perf-run)
;;; drgnx-perf-run.el ends here
