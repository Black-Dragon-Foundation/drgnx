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
(require 'drgnx-ui)
(require 'drgnx-perf)

(defvar drgnx-perf-run--fixture nil "The typing fixture of this run (one file, reused, deleted at the end).")

(defun drgnx-perf-run--make-fixture ()
  "A large Emacs Lisp file — drgnx's own core three times (~12k lines) — written once per run."
  (let ((f (make-temp-file "drgnx-perf-" nil ".el")))
    (with-temp-file f
      (dotimes (_ 3)
        (dolist (x (directory-files (expand-file-name "core" drgnx-ui-repo-dir) t "\\.el\\'"))
          (insert-file-contents x) (goto-char (point-max)))))
    f))

(defun drgnx-perf-run--visit-fixture-form ()
  (format "(let ((f %S)) (when-let* ((b (find-buffer-visiting f))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))
                         (find-file f) (goto-char (/ (point-max) 2)) (forward-line 0) t)"
          drgnx-perf-run--fixture))

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
      (defvar drgnx-perf--replace-typed 0 "Keys typed while the view streamed.")
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
        (setq drgnx-perf--replace-started nil drgnx-perf--replace-typed 0)
        (add-hook 'post-command-hook #'drgnx-perf--replace-key))
      (defun drgnx-perf--replace-key ()
        "After a key: the first starts the search (from a timer, as the view's own typing pause does); the next
ones are counted while the view streams."
        (if (not drgnx-perf--replace-started)
            (progn (setq drgnx-perf--replace-started t) (run-with-timer 0 nil #'drgnx-perf--replace-search))
          (when (with-current-buffer (drgnx-perf--replace-view) (drgnx-replace--busy-p))
            (setq drgnx-perf--replace-typed (1+ drgnx-perf--replace-typed)))))
      (defun drgnx-perf--replace-search ()
        (with-current-buffer (drgnx-perf--replace-view)
          (drgnx-replace--fill 'find "needle")
          (drgnx-replace--search-now)))
      (defun drgnx-perf--replace-check ()
        "Keys were typed while it streamed, and it listed all 10k matches."
        (remove-hook 'post-command-hook #'drgnx-perf--replace-key)
        (let ((d (+ (float-time) 20)))
          (while (and (with-current-buffer (drgnx-perf--replace-view) (drgnx-replace--busy-p)) (< (float-time) d))
            (accept-process-output nil 0.05)))
        (and (>= drgnx-perf--replace-typed 5)
             (= 10000 (with-current-buffer (drgnx-perf--replace-view) (length drgnx-replace--matches)))
             t))
      (defun drgnx-perf--replace-teardown ()
        (remove-hook 'post-command-hook #'drgnx-perf--replace-key)
        (when-let* ((v (drgnx-perf--replace-view)))
          (with-current-buffer v (drgnx-replace-cancel drgnx-replace--handle)))
        (ignore-errors (drgnx-wb-show-view 'explorer))
        (when-let* ((v (drgnx-perf--replace-view))) (kill-buffer v))
        (dolist (b (buffer-list))
          (when (and (buffer-file-name b) (string-prefix-p drgnx-perf--needles (buffer-file-name b))) (kill-buffer b)))
        (delete-directory drgnx-perf--needles t))
      ;; replace-retype: the 10k rows listed and drawn, then the replacement typed; each view draw is timed
      (defvar drgnx-perf--slices nil "Wall milliseconds of each `drgnx-view--draw-buffer' call since the arm.")
      (defun drgnx-perf--slice-timed (orig buffer)
        (let ((t0 (float-time)))
          (prog1 (funcall orig buffer) (push (* 1000 (- (float-time) t0)) drgnx-perf--slices))))
      (defun drgnx-perf--replace-idle ()
        (let ((d (+ (float-time) 30)))
          (while (and (with-current-buffer (drgnx-perf--replace-view) (drgnx-replace--busy-p)) (< (float-time) d))
            (accept-process-output nil 0.05))))
      (defun drgnx-perf--retype-arm ()
        "The Search view lists the 10k matches, drawn and settled, its Replace field empty; point in that field."
        (drgnx-replace--open :text "needle" :replace ""
                             :origin (with-current-buffer (find-file-noselect (expand-file-name "f000.txt" drgnx-perf--needles))
                                       (point-min-marker)))
        (drgnx-perf--replace-idle)
        (redisplay t)
        (select-window (drgnx-wb-section-window 'search))
        (goto-char (widget-field-start (drgnx-replace--widget 'replace)))
        (setq drgnx-perf--slices nil)
        (advice-add 'drgnx-view--draw-buffer :around #'drgnx-perf--slice-timed))
      (defun drgnx-perf--retype-measure ()
        "The redraw finished: each view draw's wall time since the arm."
        (drgnx-perf--replace-idle)
        (advice-remove 'drgnx-view--draw-buffer #'drgnx-perf--slice-timed)
        (list :slice_ms (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--slices))))
      (defun drgnx-perf--retype-check ()
        "No full draw, and the rows are what a fresh render of the view's keys gives."
        (with-current-buffer (drgnx-perf--replace-view)
          (let ((v drgnx-view) (parts nil))
            (dotimes (i (drgnx-view-row-count v)) (push (drgnx-replace--render-row (aref (drgnx-view--keys v) i)) parts))
            (and (= 10100 (drgnx-view-row-count v)) (zerop (plist-get (drgnx-view-stats v) :full-draws))
                 (not (drgnx-view--check v))
                 (equal (buffer-substring-no-properties (drgnx-view--start v) (point-max)) (apply #'concat (nreverse parts)))
                 t))))
      (defun drgnx-perf--retype-teardown ()
        (advice-remove 'drgnx-view--draw-buffer #'drgnx-perf--slice-timed)
        (drgnx-perf--replace-teardown))
      t)))

(defun drgnx-perf-run--live-setup-form ()
  "The live-view workload's setup: websocket (from the user's packages if need be), the mock browser as the browser
for agents, the Live view open, and the session functions it uses."
  (prin1-to-string
   `(progn
      (unless (require 'websocket nil t)
        (let* ((elpa (expand-file-name (or (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa")))
               (dir (car (last (and (file-directory-p elpa) (directory-files elpa t "\\`websocket-[0-9]"))))))
          (unless dir (error "The Live view needs the websocket package"))
          (add-to-list 'load-path dir)
          (require 'websocket)))
      (load ,(expand-file-name "test/fixtures/mock-cdp" drgnx-ui-repo-dir) nil t)
      (require 'drgnx-live)
      (require 'drgnx-jobs)
      (defvar drgnx-perf--live-jpeg nil "The frames' bytes, base64.")
      (defvar drgnx-perf--live-timer nil "Sends the frames.")
      (defvar drgnx-perf--live-message nil "A frame's message, as the browser sends it: an encoded websocket frame.")
      (setq drgnx-perf--live-message nil)
      (defvar drgnx-perf--live-width nil "The frames' width.")
      (setq drgnx-perf--live-width nil)
      (defvar drgnx-perf--live-sent 0 "How many messages the mock had received when it sent the last frame.")
      (setq drgnx-perf--live-sent 0)
      (defvar drgnx-perf--live-drawn 0 "Frames drawn when the typing began.")
      (defvar drgnx-perf--jobs-get nil "The real `drgnx-jobs-get'.")
      (defun drgnx-perf--live-make-jpeg (width)
        "A real JPEG WIDTH pixels wide, as Chrome sends at the view's maxWidth (ImageMagick's built-in logo, a
1280×800 page scaled); without ImageMagick nil: the frames are then a few bytes no decoder accepts, cheaper to draw."
        (when-let* ((magick (or (executable-find "magick") (executable-find "convert"))))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (and (eq 0 (call-process magick nil t nil "logo:" "-resize" (format "%dx%d!" width (round (* width 0.625))) "jpeg:-"))
                 (base64-encode-string (buffer-string) t)))))
      (setq drgnx-perf--live-jpeg nil)
      (setq drgnx-perf--jobs-get (symbol-function 'drgnx-jobs-get))
      (fset 'drgnx-jobs-get (lambda (id) (if (equal id "job-perf-live") (list :id id :status 'running) (funcall drgnx-perf--jobs-get id))))
      (let ((port (drgnx-mock-cdp-start)))
        (setq drgnx-live--browser (list :port port :ws (format "ws://127.0.0.1:%d/devtools/browser/mock" port) :job "job-perf-live")))
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
            (setq drgnx-perf--live-jpeg (drgnx-perf--live-make-jpeg drgnx-perf--live-width))
            (setq drgnx-perf--live-message
                  (websocket-encode-frame
                   (make-websocket-frame
                    :opcode 'text :completep t
                    :payload (encode-coding-string
                              (json-serialize
                               (list :method "Page.screencastFrame" :sessionId "S-T1"
                                     :params (list :data (or drgnx-perf--live-jpeg (base64-encode-string "frame")) :sessionId 1
                                                   :metadata (list :deviceWidth 1280 :deviceHeight 800 :offsetTop 0 :pageScaleFactor 1
                                                                   :scrollOffsetX 0 :scrollOffsetY 0 :timestamp (float-time)))))
                              'raw-text))
                   nil)))
          (dolist (ws (drgnx-mock-cdp-clients)) (process-send-string (websocket-conn ws) drgnx-perf--live-message))))
      (defun drgnx-perf--live-arm ()
        "The Live view beside the file, frames arriving."
        (let* ((editor (selected-window)) (file (window-buffer editor)))
          (unless (drgnx-perf--live-view)
            (drgnx-live-view)
            (drgnx-mock-cdp-wait (lambda () (drgnx-mock-cdp-received "Page.startScreencast")) 10))
          (set-window-buffer editor file)               ; the view may have taken the file's window
          (unless (get-buffer-window (drgnx-perf--live-view))
            (set-window-buffer (split-window editor nil 'right) (drgnx-perf--live-view)))
          (select-window editor))
        (unless drgnx-perf--live-timer (setq drgnx-perf--live-timer (run-with-timer 0 (/ 1.0 30) #'drgnx-perf--live-frame)))
        (setq drgnx-perf--live-drawn (buffer-local-value 'drgnx-live--drawn (drgnx-perf--live-view))))
      (defun drgnx-perf--live-check ()
        "Frames were drawn while the keys were typed."
        (and (>= (- (buffer-local-value 'drgnx-live--drawn (drgnx-perf--live-view)) drgnx-perf--live-drawn) 5) t))
      (defun drgnx-perf--live-teardown ()
        (when (timerp drgnx-perf--live-timer) (cancel-timer drgnx-perf--live-timer))
        (setq drgnx-perf--live-timer nil)
        (when-let* ((v (drgnx-perf--live-view)))
          (when-let* ((w (get-buffer-window v))) (ignore-errors (delete-window w)))
          (kill-buffer v))
        (drgnx-mock-cdp-stop)
        (setq drgnx-live--browser nil)
        (fset 'drgnx-jobs-get drgnx-perf--jobs-get))
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
  "The typing-with-index workload's setup: the drgnx repo indexed into the session's own state dir by a stub
embedder (384 numbers per chunk, no provider, no network), the index read into memory by one query, and the
session functions the check and the teardown use."
  (prin1-to-string
   `(progn
      (require 'drgnx-search)
      (require 'drgnx-search-index)
      (require 'drgnx-search-query)
      (unless (sqlite-available-p) (error "This Emacs has no SQLite: no index to load"))
      (unless (memq 'drgnx-search--after-save after-save-hook) (error "The search module (tools/search) is not on"))
      (defvar drgnx-perf--index-root nil "The indexed project.")
      (defun drgnx-perf--index-embed (inputs &rest _)
        "Unit vectors of 384 numbers from the text's hashes."
        (setq drgnx-ai-embed-last-info (list :provider 'perf-stub :model "perf-stub"))
        (vconcat
         (mapcar (lambda (text)
                   (let* ((bytes (apply #'append (mapcar (lambda (i) (append (secure-hash 'sha256 (format "%d%s" i text) nil nil t) nil))
                                                         (number-sequence 1 12))))
                          (v (mapcar (lambda (b) (/ (- b 127.5) 127.5)) bytes))
                          (norm (sqrt (apply #'+ (mapcar (lambda (x) (* x x)) v)))))
                     (vconcat (mapcar (lambda (x) (/ x norm)) v))))
                 inputs)))
      (setq drgnx-perf--index-root ,(file-name-as-directory drgnx-ui-repo-dir))
      (let ((r (drgnx-search-index drgnx-perf--index-root :embed #'drgnx-perf--index-embed)))
        (when (plist-get r :error) (error "Indexing the repo: %s" (plist-get r :error)))
        (when (< (plist-get r :chunks) 100) (error "Only %s chunks indexed" (plist-get r :chunks))))
      (drgnx-search drgnx-perf--index-root "where does the program start" :embed #'drgnx-perf--index-embed)
      (defun drgnx-perf--index-check ()
        "The index is in memory: the query cache holds its fingerprints."
        (and (> (length (nth 1 (car (hash-table-values drgnx-search--cache)))) 0) t))
      (defun drgnx-perf--index-teardown ()
        (clrhash drgnx-search--cache)
        (ignore-errors (delete-file (drgnx-search-store-file drgnx-perf--index-root))))
      t)))

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

(defun drgnx-perf-run--terminal-setup-form (command &rest switches)
  "The terminal workloads' setup: eat (from the user's packages if need be) and the session functions they use.
The eat terminal runs COMMAND with SWITCHES directly: no shell, so no shell configuration is involved."
  (prin1-to-string
   `(progn
      (unless (require 'eat nil t)
        (let* ((elpa (expand-file-name (or (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa")))
               (dir (car (last (and (file-directory-p elpa) (directory-files elpa t "\\`eat-[0-9.]+\\'"))))))
          (unless dir (error "The terminal workloads need the eat package"))
          (add-to-list 'load-path dir)
          (require 'eat)))
      ;; the session started without eat's package, so the module was skipped (missing-packages): run it now, as it runs
      ;; for a user who has eat installed (its key split, its GC timing)
      (let ((spec (cdr (assq 'tools/terminal-eat drgnx-modules--table))))
        (when (and spec (not (eq (plist-get (cdr (assq 'tools/terminal-eat (drgnx-modules-report))) :status) 'ok)))
          (drgnx-modules--run-one 'tools/terminal-eat spec 'startup)))
      ;; never measure a terminal without the module (its key split, its GC timing) and not know it
      (unless (eq (plist-get (cdr (assq 'tools/terminal-eat (drgnx-modules-report))) :status) 'ok)
        (error "The terminal workloads need the tools/terminal-eat module to run (status %S)"
               (plist-get (cdr (assq 'tools/terminal-eat (drgnx-modules-report))) :status)))
      (defvar drgnx-perf--term nil "The terminal's buffer.")
      (defvar drgnx-perf--term-tick 0 "The terminal buffer's modification tick when the keys began.")
      (defun drgnx-perf--term-open ()
        (let ((buf (generate-new-buffer "*eat-perf*")))
          (with-current-buffer buf (eat-mode))
          (eat-exec buf "perf" (executable-find ,command) nil ',switches)
          (set-process-query-on-exit-flag (get-buffer-process buf) nil)
          (setq drgnx-perf--term buf)))
      (defun drgnx-perf--term-show ()
        "The terminal in the panel (the display rules choose where), the editor window selected."
        (let ((win (selected-window)))
          (display-buffer drgnx-perf--term)
          (select-window win)))
      (defun drgnx-perf--term-teardown ()
        (when (buffer-live-p drgnx-perf--term)
          (let ((proc (get-buffer-process drgnx-perf--term)) (kill-buffer-query-functions nil))
            (kill-buffer drgnx-perf--term)
            (let ((d (+ (float-time) 3)))   ; wait for the process to be gone
              (while (and proc (process-live-p proc) (< (float-time) d)) (accept-process-output nil 0.05)))))
        (setq drgnx-perf--term nil)
        t)
      (drgnx-perf--term-open)
      t)))

(defun drgnx-perf-run--workloads ()
  "The workloads: (NAME :setup FORM :each FORM :actions ACTIONS :check FORM :measure FORM :teardown FORM :repeat N).
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
      (agent-typing :setup ,(format "(progn (setq drgnx-agents-profiles (list (list \"mock\" :command (list (expand-file-name invocation-name invocation-directory) \"--batch\" \"-Q\" \"-l\" %S))))
                                          (setq drgnx-perf--agent (drgnx-agents-start \"mock\" temporary-file-directory))
                                          (let ((d (+ (float-time) 10))) (while (and (not (eq (drgnx-agent-session-status drgnx-perf--agent) 'idle)) (< (float-time) d)) (accept-process-output nil 0.05)))
                                          (drgnx-agents-ui-view) t)"
                                    (expand-file-name "test/fixtures/mock-acp.el" drgnx-ui-repo-dir))
                    :each ,(concat "(progn " (drgnx-perf-run--visit-fixture-form)
                                   " (let ((d (+ (float-time) 5))) (while (and (eq (drgnx-agent-session-status drgnx-perf--agent) 'busy) (< (float-time) d)) (accept-process-output nil 0.05)))"
                                   " (drgnx-agents-send drgnx-perf--agent \"slow\") t)")
                    :actions ,(make-list 2 (funcall type "(setq y 2) "))
                    :check "(eq (drgnx-agent-session-status drgnx-perf--agent) 'busy)"   ; typed while it streamed
                    :teardown ,(concat "(progn (ignore-errors (drgnx-agents-kill drgnx-perf--agent)) " kill-fixture ")"))
      ;; typing while the editor's other window shows a transcript whose running answer is 400 kB long and grows by
      ;; 100-character chunks, 50 a second: a chunk costs the chunk (model) and only the new text is drawn (view)
      (agent-stream :setup ,(format "(progn (setq drgnx-agents-profiles (list (list \"mock\" :command (list (expand-file-name invocation-name invocation-directory) \"--batch\" \"-Q\" \"-l\" %S))))
                                          (setq drgnx-perf--stream (drgnx-agents-start \"mock\" temporary-file-directory))
                                          (let ((d (+ (float-time) 10))) (while (and (not (eq (drgnx-agent-session-status drgnx-perf--stream) 'idle)) (< (float-time) d)) (accept-process-output nil 0.05)))
                                          t)"
                                    (expand-file-name "test/fixtures/mock-acp.el" drgnx-ui-repo-dir))
                    :each ,(concat "(progn " (drgnx-perf-run--visit-fixture-form)
                                   " (let ((d (+ (float-time) 30))) (while (and (eq (drgnx-agent-session-status drgnx-perf--stream) 'busy) (< (float-time) d)) (accept-process-output nil 0.05)))"
                                   " (let ((editor (selected-window)) (b (drgnx-agents-ui-transcript-buffer drgnx-perf--stream)))"
                                   "   (unless (get-buffer-window b) (set-window-buffer (split-window editor nil 'right) b))"
                                   "   (select-window editor))"
                                   " (drgnx-agents-send drgnx-perf--stream \"stream 500\")"
                                   ;; the turn's answer starts 400 kB long (not done): the chunks are appended to it
                                   " (drgnx-agents--append-text drgnx-perf--stream 'agent (make-string 409600 ?a))"
                                   " (drgnx-agents--changed drgnx-perf--stream) t)")
                    :actions ,(make-list 6 (funcall type "(let ((x 1)) (message \"%s\" x)) "))
                    :check "(eq (drgnx-agent-session-status drgnx-perf--stream) 'busy)"   ; typed while it streamed
                    :teardown ,(concat "(progn (ignore-errors (drgnx-agents-kill drgnx-perf--stream))"
                                       " (when-let* ((b (get-buffer (format \"*agent: %s*\" (drgnx-agent-session-name drgnx-perf--stream)))))"
                                       "   (when-let* ((w (get-buffer-window b))) (ignore-errors (delete-window w)))"
                                       "   (kill-buffer b)) "
                                       kill-fixture ")"))
      ;; the Work cockpit filtered to a job (Show Job in Work: the graph, what needs you), following three agents that
      ;; stream (as it follows the hub's events)
      (cockpit-cards
       :setup ,(format "(progn (setq drgnx-agents-profiles (list (list \"mock\" :command (list (expand-file-name invocation-name invocation-directory) \"--batch\" \"-Q\" \"-l\" %S))))
                              (setq drgnx-perf--agents (mapcar (lambda (n) (drgnx-agents-start \"mock\" temporary-file-directory (format \"perf#%%d\" n) \"perf\")) '(1 2 3)))
                              (let ((d (+ (float-time) 10))) (while (and (seq-some (lambda (s) (not (eq (drgnx-agent-session-status s) 'idle))) drgnx-perf--agents) (< (float-time) d)) (accept-process-output nil 0.05)))
                              (defun drgnx-perf--job-follow (_s) (drgnx-cockpit-cards--hub-event \"agent\" nil))
                              (setq drgnx-perf--spent 0.0)
                              (defun drgnx-perf--job-summary ()   ; what the hub would answer: spend and agents change
                                (list :id \"perf\" :title \"Perf\" :status \"running\" :repo temporary-file-directory :budget 5.0 :spent drgnx-perf--spent
                                      :tasks (mapcar (lambda (n) (list :n n :title (format \"task %%d\" n) :role \"implement\" :profile \"mock\" :status \"running\" :agent :null :deps :null)) '(1 2 3))
                                      :agents (mapcar (lambda (s) (list :id (drgnx-agent-session-id s) :profile \"mock\" :task (drgnx-agent-session-task s) :status (symbol-name (drgnx-agent-session-status s)) :review :false)) drgnx-perf--agents)
                                      :cards (mapcar (lambda (n) (list :id n :kind \"stalled\" :task (format \"perf#%%d\" n) :title \"waiting\" :actions '((\"retry\" \"Retry\") (\"drop\" \"Drop the task\")) :data :null)) '(1 2 3 4))
                                      :messages :null
                                      :decisions (mapcar (lambda (n) (list :n n :kind \"build\" :subject (format \"part %%d\" n) :author \"user\" :status \"current\")) (number-sequence 20 1 -1))))
                              (require 'drgnx-hub)                ; loaded first: the stub below stays
                              (setq drgnx-perf--hub-call (symbol-function 'drgnx-hub-call))
                              (fset 'drgnx-hub-call (lambda (method _params &optional cb)
                                                      (when (and cb (equal method \"job/status\"))
                                                        (setq drgnx-perf--spent (+ drgnx-perf--spent 0.01))
                                                        (funcall cb (drgnx-perf--job-summary) nil))))
                              (add-hook 'drgnx-agents-changed-functions #'drgnx-perf--job-follow)
                              (setq drgnx-perf--dock (cons (and (drgnx-wb--dock-windows) t) (drgnx-wb-sidebar-view)))
                              (let ((editor (selected-window)))
                                (drgnx-cockpit-show-job \"perf\")
                                (drgnx-cockpit-cards--draw \"perf\" (drgnx-perf--job-summary))
                                (select-window editor))
                              t)"
                       (expand-file-name "test/fixtures/mock-acp.el" drgnx-ui-repo-dir))
       :each ,(concat "(progn " (drgnx-perf-run--visit-fixture-form)
                      " (let ((d (+ (float-time) 5))) (while (and (seq-some (lambda (s) (eq (drgnx-agent-session-status s) 'busy)) drgnx-perf--agents) (< (float-time) d)) (accept-process-output nil 0.05)))"
                      " (dolist (s drgnx-perf--agents) (drgnx-agents-send s \"slow\")) t)")
       :actions ,(make-list 2 (funcall type "(setq y 2) "))
       :check "(seq-some (lambda (s) (eq (drgnx-agent-session-status s) 'busy)) drgnx-perf--agents)"   ; typed while they streamed
       :teardown ,(concat "(progn (remove-hook 'drgnx-agents-changed-functions #'drgnx-perf--job-follow)"
                          " (fset 'drgnx-hub-call drgnx-perf--hub-call)"
                          " (dolist (s drgnx-perf--agents) (ignore-errors (drgnx-agents-kill s)))"
                          " (ignore-errors (drgnx-pane-hide 'needs-you))"
                          " (if (car drgnx-perf--dock) (drgnx-wb-show-view (or (cdr drgnx-perf--dock) 'explorer)) (drgnx-wb-hide-sidebar))"
                          " (dolist (n '(\"*Needs You*\" \"*Decisions*\")) (when (get-buffer n) (kill-buffer n)))"
                          " (setq drgnx-cockpit-graph-current-filter nil) " kill-fixture ")"))
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
                         (when (file-exists-p (drgnx-ai-file)) (error \"An ai.eld exists (%%s): never overwritten\" (drgnx-ai-file)))
                         (let* ((port (+ 20000 (random 20000))) (dir (make-temp-file \"drgnx-perf-llm\" t))
                                (script (expand-file-name \"llm.eld\" dir)) (log (expand-file-name \"llm.log\" dir)))
                           ;; /api/tags: the probe (drgnx runs one once idle) finds it running
                           (with-temp-file script (prin1 '((:path \"/api/tags\" :body \"{\\\"models\\\":[{\\\"name\\\":\\\"coder\\\"}]}\")
                                                           (:path \"/api/generate\" :body \"{\\\"response\\\":\\\"(message \\\\\\\"%%s\\\\\\\" x)\\\"}\"))
                                                         (current-buffer)))
                           (make-directory (file-name-directory (drgnx-ai-file)) t)
                           (with-temp-file (drgnx-ai-file)
                             (prin1 (list :version 1 :providers (list (list 'perf-llm :name \"Perf\" :kind 'ollama :url (format \"http://127.0.0.1:%%d\" port) :caps '(fim)))
                                          :roles '((complete (perf-llm . \"coder\"))))
                                    (current-buffer)))
                           (setq drgnx-perf--llm (list :proc (drgnx-ai-test-mock-llm port script log) :dir dir :log log :delay drgnx-ai-ghost-delay)
                                 drgnx-ai-ghost-delay 0.01)
                           (push '(perf-llm :up t) drgnx-ai-detected))
                         t)"
                       (expand-file-name "test/fixtures/mock-llm.el" drgnx-ui-repo-dir))
       :each ,(drgnx-perf-run--visit-fixture-form)
       :actions ,(make-list 6 (funcall type "(let ((x 1)) (message \"%s\" x)) "))
       :check "(with-temp-buffer (insert-file-contents (plist-get drgnx-perf--llm :log)) (> (how-many \"POST /api/generate\") 0))"   ; it asked
       :teardown ,(concat "(progn (ignore-errors (delete-process (plist-get drgnx-perf--llm :proc)))
                                  (ignore-errors (delete-directory (plist-get drgnx-perf--llm :dir) t))
                                  (when drgnx-perf--llm (ignore-errors (delete-file (drgnx-ai-file))))   ; the one setup wrote
                                  (setq drgnx-ai-ghost-delay (plist-get drgnx-perf--llm :delay)
                                        drgnx-ai-detected (assq-delete-all 'perf-llm drgnx-ai-detected)) "
                          kill-fixture ")"))
      ;; typing while the Search view lists 10k matches (100 files): the search starts on the first key
      (replace-typing
       :setup ,(drgnx-perf-run--replace-setup-form)
       :each ,(concat "(progn " (drgnx-perf-run--visit-fixture-form) " (drgnx-perf--replace-arm) t)")
       :actions ,(make-list 2 (funcall type "(setq y 2) "))
       :check "(drgnx-perf--replace-check)"
       :teardown ,(concat "(progn (drgnx-perf--replace-teardown) " kill-fixture ")"))
      ;; retyping the replacement over 10k listed matches: the rows are patched in place, in slices
      (replace-retype
       :setup ,(drgnx-perf-run--replace-setup-form)
       :each "(progn (drgnx-perf--retype-arm) t)"
       :actions ,(make-list 5 (funcall type "pi"))
       :measure "(drgnx-perf--retype-measure)"
       :check "(drgnx-perf--retype-check)"
       :teardown "(progn (drgnx-perf--retype-teardown) t)")
      ;; typing while the Live view shows frames from a mock browser (30 a second, each once the last was acked)
      (live-view
       :setup ,(drgnx-perf-run--live-setup-form)
       :each ,(concat "(progn " (drgnx-perf-run--visit-fixture-form) " (drgnx-perf--live-arm) t)")
       :actions ,(make-list 6 (funcall type "(let ((x 1)) (message \"%s\" x)) "))
       :check "(drgnx-perf--live-check)"
       :teardown ,(concat "(progn (drgnx-perf--live-teardown) " kill-fixture ")"))
      ;; opening the Claude Code settings page on a 5 MB .claude.json, 50 MCP servers and 200 skills: drawn, no process
      (agent-settings-open
       :setup ,(drgnx-perf-run--agent-settings-setup-form)
       :each "(progn (dolist (b (buffer-list)) (when (string-prefix-p \"*agent settings: \" (buffer-name b)) (kill-buffer b))) t)"
       :measure ,drgnx-perf-run--agent-settings-measure-form
       :teardown ,drgnx-perf-run--agent-settings-teardown-form)
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
      ;; typing in an eat terminal (cat: the tty echoes every key, eat draws it)
      (terminal-typing
       :setup ,(drgnx-perf-run--terminal-setup-form "cat")
       :each "(progn (pop-to-buffer drgnx-perf--term) (select-window (get-buffer-window drgnx-perf--term)) t)"
       :actions ,(make-list 6 (funcall type "echo hello world 123"))
       :check "(and (process-live-p (get-buffer-process drgnx-perf--term)) t)"
       :teardown "(drgnx-perf--term-teardown)")
      ;; typing in the fixture while a terminal in the panel streams output (seq 1 2000, in a loop)
      (terminal-output
       :setup ,(drgnx-perf-run--terminal-setup-form "sh" "-c" "while :; do seq 1 2000; done")
       :each ,(concat "(progn (drgnx-wb-focus-editor) " (drgnx-perf-run--visit-fixture-form)
                      " (drgnx-perf--term-show) (setq drgnx-perf--term-tick (buffer-chars-modified-tick drgnx-perf--term)) t)")
       :actions ,(make-list 6 (funcall type "echo hello world 123"))
       :check "(and (process-live-p (get-buffer-process drgnx-perf--term)) (get-buffer-window drgnx-perf--term)
                    (> (buffer-chars-modified-tick drgnx-perf--term) drgnx-perf--term-tick) t)"   ; output streamed while typing
       :teardown ,(concat "(progn (drgnx-perf--term-teardown) " kill-fixture ")"))
      (frames :measure "(list :frame (drgnx-perf-frame-ms 5))")
      (redisplay :each ,(drgnx-perf-run--visit-fixture-form) :measure "(list :redisplay (drgnx-perf-redisplay-ms 30))" :teardown ,kill-fixture)
      (startup :daemon t)
      (memory :measure "(progn (garbage-collect) (list :rss_kb (drgnx-perf-rss-kb)))")
      ;; last: evil cannot be unloaded from the session, so the workloads above stay as they were without it
      ,@(drgnx-perf-run--modal-workloads))))

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
  "Failure lines: `typing-evil' input p95 more than 1 ms over `typing' in the same RESULTS (both measured)."
  (let ((plain (drgnx-perf--get results 'typing '(:input :p95)))
        (evil (drgnx-perf--get results 'typing-evil '(:input :p95))))
    (when (and (numberp plain) (numberp evil) (> (- evil plain) 1.0))
      (list (format "typing-evil input p95 %s ms is %s ms over typing's %s ms (evil may add at most 1 ms)"
                    (drgnx-perf--round evil) (drgnx-perf--round (- evil plain)) (drgnx-perf--round plain))))))

(defun drgnx-perf-run--relative-note (results)
  "A line saying the 1 ms rule was not judged, when `typing-evil' was measured without `typing' in RESULTS; else nil."
  (when (and (numberp (drgnx-perf--get results 'typing-evil '(:input :p95)))
             (not (numberp (drgnx-perf--get results 'typing '(:input :p95)))))
    "perf: typing-evil's 1 ms rule not judged: typing was not measured in this run (add it to DRGNX_PERF_ONLY)"))

(defun drgnx-perf-run--only-regexp ()
  "The regexp $DRGNX_PERF_ONLY (workload names to run), or nil when it is unset or empty.  An invalid one is an error."
  (let ((re (getenv "DRGNX_PERF_ONLY")))
    (when (and re (not (string-empty-p re)))
      (condition-case nil (string-match-p re "")
        (invalid-regexp (error "perf: DRGNX_PERF_ONLY %S is not a valid regexp (an Emacs regexp: \\| for alternation)" re)))
      re)))

(defun drgnx-perf-run--budgets-judged (results)
  "The budgets to judge RESULTS against: all of them, but with $DRGNX_PERF_ONLY set those of workloads that did
not run, and without $DRGNX_MODAL_ELPA those of the evil workloads.  Any other budget of a missing workload stays,
so the verdict says \"not measured\" (a renamed or misspelled workload is not lost)."
  (let ((only (drgnx-perf-run--only-regexp)) (no-evil (not (drgnx-perf-run--modal-elpa))))
    (seq-remove (lambda (b)
                  (and (not (assq (car b) results))
                       (or only (and no-evil (memq (car b) '(typing-evil motions-evil explorer-evil))))))
                (drgnx-perf-run--budgets))))

(defun drgnx-perf-run--only (workloads)
  "WORKLOADS whose name matches $DRGNX_PERF_ONLY (all of them when it is unset)."
  (if-let* ((re (drgnx-perf-run--only-regexp)))
      (seq-filter (lambda (w) (string-match-p re (symbol-name (car w)))) workloads)
    workloads))

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
  (drgnx-ui-call sess (format "(progn (require 'drgnx-perf) (drgnx-uitest--json %s))" form) (or timeout 60)))

(defun drgnx-perf-run--median (runs path)
  (plist-get (drgnx-perf-stats (delq nil (mapcar (lambda (r) (let ((v r)) (dolist (k path) (setq v (plist-get v k))) (and (numberp v) v))) runs)))
             :p50))

(defun drgnx-perf-run--medians (runs)
  "One result from RUNS: every numeric value (also inside stats plists) the median over the runs."
  (let ((first (car runs)) out)
    (cl-loop for (k v) on first by #'cddr
             do (setq out (plist-put out k
                                     (cond ((numberp v) (drgnx-perf-run--median runs (list k)))
                                           ((and (consp v) (keywordp (car v)))
                                            (let (inner)
                                              (cl-loop for (k2 v2) on v by #'cddr
                                                       do (setq inner (plist-put inner k2 (if (numberp v2) (drgnx-perf-run--median runs (list k k2)) v2))))
                                              inner))
                                           (t v)))))
    out))

(defun drgnx-perf-run-workload (sess spec &optional audit)
  "Run workload SPEC in SESS: its setup, then :repeat (3) runs, the medians of their numbers.  AUDIT:
the hook audit on (its rows under :audit).  The probes, the audit and the teardown are undone even
when a step fails."
  (let ((actions (plist-get spec :actions)) (measure (plist-get spec :measure)))
    (if (plist-get spec :daemon) (drgnx-perf-run-daemon-startup)
      (unwind-protect
          (progn
            (when (plist-get spec :setup) (drgnx-perf-run--call sess (plist-get spec :setup) 120) (drgnx-ui-measure sess nil))
            (let (runs audit-rows)
              (dotimes (_ (or (plist-get spec :repeat) 3))
                (when (plist-get spec :each) (drgnx-perf-run--call sess (plist-get spec :each) 120) (drgnx-ui-measure sess nil))
                (if (not actions)
                    (push (drgnx-perf-run--call sess measure 120) runs)
                  (drgnx-perf-run--call sess (format "(progn %s (drgnx-perf-begin) t)" (if audit "(drgnx-perf-audit-begin)" "")))
                  (drgnx-ui-measure sess actions)
                  (push (append (drgnx-perf-run--call sess "(drgnx-perf-end)")
                                (and measure (drgnx-perf-run--call sess measure 120)))   ; what input cannot show
                        runs)
                  (when audit
                    (setq audit-rows (append audit-rows (append (drgnx-perf-run--call sess "(vconcat (seq-take (drgnx-perf-audit-end) 30))") nil)))))
                (when (plist-get spec :check)
                  (unless (eq t (drgnx-perf-run--call sess (plist-get spec :check)))
                    (error "The workload did not do what it measures (%s)" (plist-get spec :check)))))
              (let ((r (drgnx-perf-run--medians runs)))
                (if audit (plist-put r :audit (vconcat audit-rows)) r))))
        ;; never leave the probes or the audit on, nor what the workload made
        (ignore-errors (drgnx-perf-run--call sess "(progn (when drgnx-perf--audit (drgnx-perf-audit-end)) (drgnx-perf-end) t)"))
        (when (plist-get spec :teardown) (ignore-errors (drgnx-perf-run--call sess (plist-get spec :teardown))))))))

(defun drgnx-perf-run--budgets ()
  (with-temp-buffer (insert-file-contents (expand-file-name "test/perf/budgets.eld" drgnx-ui-repo-dir)) (read (current-buffer))))

(defun drgnx-perf-run--commit ()
  (with-temp-buffer
    (if (eql 0 (call-process "git" nil t nil "-C" drgnx-ui-repo-dir "rev-parse" "--short" "HEAD")) (string-trim (buffer-string)) "unknown")))

(defun drgnx-perf-run--table (results)
  (mapconcat (lambda (r)
               (let ((p (cdr r)))
                 (format "%-13s %s" (car r)
                         (string-join
                          (delq nil (list (when-let* ((i (plist-get p :input))) (format "input p50 %s p95 %s max %s ms (n=%s)" (plist-get i :p50) (plist-get i :p95) (plist-get i :max) (plist-get i :n)))
                                          (when (plist-get p :gc_count) (format "gc %s/%s ms (pause p95 %s)" (plist-get p :gc_count) (plist-get p :gc_ms)
                                                                                (or (plist-get (plist-get p :gc_pause) :p95) "-")))
                                          (when (plist-get p :draw_ms) (format "drawn in %s ms, %s processes started" (plist-get p :draw_ms) (plist-get p :processes)))
                                          (when-let* ((f (plist-get p :frame))) (format "frame p50 %s p95 %s ms" (plist-get f :p50) (plist-get f :p95)))
                                          (when-let* ((d (plist-get p :redisplay))) (format "redisplay p50 %s p95 %s ms" (plist-get d :p50) (plist-get d :p95)))
                                          (when-let* ((sv (plist-get p :server_ms))) (format "daemon server ready p50 %s max %s ms, modules %s ms" (plist-get sv :p50) (plist-get sv :max) (plist-get p :modules_ms)))
                                          (when (and (plist-get p :rss_kb) (not (plist-get p :input))) (format "rss %d MB" (/ (plist-get p :rss_kb) 1024)))))
                          ", "))))
             results "\n"))

(defconst drgnx-perf-run-hook-budget 2 "ms: any hook function's p95 (the spec), judged in the --audit pass.")

(defun drgnx-perf-run--wait-for-quiet (limit)
  "Wait up to $DRGNX_PERF_WAIT seconds (180) for the load average to fall to LIMIT.  The load then."
  (let* ((env (getenv "DRGNX_PERF_WAIT"))
         (deadline (+ (float-time) (if (and env (string-match-p "\\`[0-9]+\\'" env)) (string-to-number env) 180)))
         (load (drgnx-perf-load)))
    (while (and load (> load limit) (< (float-time) deadline))
      (message "perf: the machine is busy (load %.1f > %.1f), waiting…" load limit)
      (sleep-for 10)
      (setq load (drgnx-perf-load)))
    load))

(defun drgnx-perf-run (&optional audit)
  "`drgnx test --perf': every workload in one session; print, judge (budgets, regressions against the
history), keep the history.  An exit code: 0 all hold, 1 a failure, 3 not judged — the load average
passed `drgnx-perf-max-load' before or during the run (other processes took the CPU, so the timings
say nothing about drgnx; the history is not written).  AUDIT (`--audit'): the hook audit on — judged on
the hook budget only (the audit adds its own cost to the other numbers)."
  (unless (drgnx-perf-run--modal-elpa) (princ (concat drgnx-perf-run-modal-skipped "\n")))
  (if (null (drgnx-perf-run--only (drgnx-perf-run--workloads)))
      (progn (princ (format "perf: DRGNX_PERF_ONLY %S matches no workload\n" (drgnx-perf-run--only-regexp))) 1)
    (let* ((limit (drgnx-perf-max-load)) (start (drgnx-perf-run--wait-for-quiet limit)))
      (if (drgnx-perf-busy (list start) limit)
          (progn (princ (format "perf: not run — the machine stayed busy (load %.1f > %.1f); rerun when it is quiet (no other test runs or agents), or set DRGNX_PERF_MAX_LOAD.\n"
                                start limit))
                 3)
        (drgnx-perf-run--judged audit limit start)))))

(defun drgnx-perf-run--judged (audit limit start)
  "The run of `drgnx-perf-run' on a quiet machine: LIMIT the load allowed, START the load before it."
  (let* ((loads (list start))
         (drgnx-perf-run--fixture (drgnx-perf-run--make-fixture))
         (all (drgnx-perf-run--workloads)) (selected (drgnx-perf-run--select all))
         (s (drgnx-ui-start "drgnx" "1400x800" 60)) (sess (drgnx-ui-own-session (plist-get s :name))) results)
    (unwind-protect
        (dolist (w (drgnx-perf-run--only selected))
          (message "perf: %s…" (car w))
          (push (cons (car w) (condition-case err (drgnx-perf-run-workload sess (cdr w) audit)
                                (error (list :error (error-message-string err)))))
                results)
          (push (drgnx-perf-load) loads))
      (drgnx-ui-stop (plist-get s :name))
      (delete-file drgnx-perf-run--fixture))
    (setq results (nreverse results))
    (princ (concat (drgnx-perf-run--table results) "\n"))
    (let ((errors (seq-filter (lambda (r) (plist-get (cdr r) :error)) results))
          (busy (drgnx-perf-busy loads limit)))
      (pcase-dolist (`(,w . ,p) errors) (princ (format "ERROR %s: %s\n" w (plist-get p :error))))
      (cond
       ((and busy (not errors))
        (princ (format "perf: not judged — the machine was busy (load %.1f > %.1f): other processes took the CPU, so these timings say nothing about drgnx; the history is not written.  Rerun when the machine is quiet (no other test runs or agents), or set DRGNX_PERF_MAX_LOAD.\n"
                       busy limit))
        3)
       (audit
        (let ((rows (seq-mapcat (lambda (r) (append (plist-get (cdr r) :audit) nil)) results)))
          (dolist (row (seq-take (sort (copy-sequence rows) (lambda (a b) (> (plist-get a :ms) (plist-get b :ms)))) 40))
            (princ (format "audit %-40s %-34s %6s calls  p95 %6s  max %6s  total %8s ms\n" (plist-get row :fn) (plist-get row :hooks)
                           (plist-get row :calls) (plist-get row :p95) (plist-get row :max) (plist-get row :ms))))
          (let ((fails (drgnx-perf-audit-verdict rows drgnx-perf-run-hook-budget)))
            (dolist (f fails) (princ (format "FAIL %s\n" f)))
            (if (or fails errors) 1 (princ "perf audit: every hook function within its budget\n") 0))))
       (t
        (let* ((history (expand-file-name "perf-history.jsonl" (drgnx-ui-state-root)))
               (only (drgnx-perf-run--only-regexp))
               (partial (/= (length selected) (length all)))   ; DRGNX_PERF_WORKLOADS: judge those, keep no history
               (judged (drgnx-perf-run--budgets-judged results))
               (fails (append (drgnx-perf-verdict results (if partial (seq-filter (lambda (b) (assq (car b) results)) judged) judged))
                              (drgnx-perf-run--relative-fails results)))
               (worse (drgnx-perf-regressions history results)))
          (dolist (f fails) (princ (format "FAIL %s\n" f)))
          (dolist (r worse) (princ (format "FAIL regression: %s\n" r)))
          (when-let* ((note (drgnx-perf-run--relative-note results))) (princ (concat note "\n")))
          (unless (or errors only partial) (drgnx-perf-history-append history (drgnx-perf-run--commit) results (seq-max (cons 0 (delq nil loads)))))
          (princ (format "history: %s%s\n" history (cond (errors " (not written: a workload failed)")
                                                         (only " (not written: DRGNX_PERF_ONLY ran some of the workloads)")
                                                         (partial " (not written: only some workloads ran)")
                                                         (t ""))))
          (if (or fails worse errors) 1
            (princ "perf: every budget holds\n") 0)))))))

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
         (s (drgnx-ui-start "drgnx" "1400x800" 60)) (sess (drgnx-ui-own-session (plist-get s :name)))
         (loads (seq-filter (lambda (w) (plist-get (cdr w) :actions)) (drgnx-perf-run--workloads)))
         samples over)
    (unwind-protect
        (while (< (float-time) deadline)
          (dolist (w loads) (ignore-errors (drgnx-perf-run-workload sess (cdr w))))   ; each cleans up after itself
          (let* ((r (drgnx-perf-run--call sess (format "(progn (garbage-collect) (list :rss_kb (drgnx-perf-rss-kb) :census %s))"
                                                       drgnx-perf-run--census-form)))
                 (census (drgnx-perf-run--census-lines (plist-get r :census))))
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
      (dolist (o (delete-dups over)) (princ (format "FAIL soak: %s\n" o)))
      (cond ((or (> growth 20) (> last (* 400 1024)))
             (princ "FAIL soak: memory grew more than 20% or passed 400 MB\n") 1)
            (over 1)
            (t (princ "soak: memory holds\n") 0)))))

(provide 'drgnx-perf-run)
;;; drgnx-perf-run.el ends here
