;;; drgnx-perf-work.el --- the perf lab's Work space workloads: 30 streaming mock agents, the map shown or hidden -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Controller side of the Work space's budget rows (docs/develop/perf.md, "The Work space's workloads").  Each spec is
;; one `drgnx-perf-run--workloads' entry.  The session side is test/fixtures/work-space-thirty-fixture.el: a hub of the
;; workload's own (`$DRGNX_RATATOSKR_BIN', a test-hooks build with `ratatoskr-mock' beside it) with 30 mock agents in
;; three repositories, all streaming.  A workload's setup, `:each' and `:check' call the fixture's premise, which
;; signals when 30 sessions are not streaming or the map is not shown (hidden) as the workload says: a workload that
;; did not get its situation fails.  The mock agents only; nothing here reaches a subscription.

;;; Code:
(require 'cl-lib)
(require 'drgnx-ui)

(defun drgnx-perf-work--fixture-file ()
  (expand-file-name "test/fixtures/work-space-thirty-fixture" drgnx-ui-repo-dir))

(defun drgnx-perf-work--lib-form ()
  "The session side shared by every workload, as a form string: the fixture, and the functions that start the 30
agents with the map shown or hidden, say whether the premise holds and take it all down."
  (concat
   "(progn (defvar drgnx-perf--hub-bin nil) (setq drgnx-perf--hub-bin " (prin1-to-string (getenv "DRGNX_RATATOSKR_BIN")) ") "
   (prin1-to-string
    `(progn
       (load ,(drgnx-perf-work--fixture-file) nil t)
       (require 'memory-report)
       (defvar drgnx-perf--work-buf nil "The map's buffer.")
       (defvar drgnx-perf--work-shown nil "Whether the workload's map is shown.")
       (defun drgnx-perf--work-up (shown)
         "30 agents streaming and the map of their workspace, SHOWN or hidden; an error when that does not hold."
         (drgnx-work-thirty-start drgnx-perf--hub-bin)
         (setq drgnx-perf--work-shown shown drgnx-perf--work-buf (drgnx-work-thirty-map shown))
         (drgnx-work-thirty-premise drgnx-perf--work-buf shown))
       (defun drgnx-perf--work-premise ()
         (drgnx-work-thirty-premise drgnx-perf--work-buf drgnx-perf--work-shown))
       (defun drgnx-perf--work-down ()
         (when (buffer-live-p drgnx-perf--work-buf) (kill-buffer drgnx-perf--work-buf))
         (setq drgnx-perf--work-buf nil)
         (advice-remove 'drgnx-view--draw-buffer #'drgnx-perf--wl-slice)
         (ignore-errors (delete-other-windows))
         (drgnx-work-thirty-stop))
       (defun drgnx-perf--work-select-map ()
         "The map's window selected, with an agent selected in it."
         (select-window (or (get-buffer-window drgnx-perf--work-buf) (error "The map is not shown")))
         (with-current-buffer drgnx-perf--work-buf
           (unless drgnx-work-map--selection (drgnx-work-map-next-agent))
           (unless drgnx-work-map--selection (error "No agent could be selected"))))
       (defun drgnx-perf--work-view () (buffer-local-value 'drgnx-view drgnx-perf--work-buf))
       (defun drgnx-perf--work-state ()
         (drgnx-work-client-view-state (buffer-local-value 'drgnx-work-space--view drgnx-perf--work-buf)))
       (defun drgnx-perf--work-transcript ()
         "A transcript of the first agent in a window below the editor (the Agents view open on one), the editor selected."
         (let* ((editor (selected-window)) (s (car drgnx-work-thirty--mirrors)) (b (drgnx-agents-ui-transcript-buffer s)))
           (unless (get-buffer-window b) (set-window-buffer (split-window editor nil 'below) b))
           (select-window editor)
           (drgnx-agents-mirror-show (drgnx-agent-session-remote s))))
       t))
   ")"))

(defun drgnx-perf-work--nav-keys ()
  "300 keys on the map: 60 of each of Tab, right, left, down and up."
  (cl-loop for k in '("TAB" "<right>" "<left>" "<down>" "<up>") append (make-list 60 (list :keys k))))

(defun drgnx-perf-work--relayout-keys ()
  "320 layout commands: f, o and the layers 1 to 6, 40 times.  About one in six makes the hub send a frame with a
layout, and the lab's p95 needs 100 samples; each command waits up to a second for the layout before it."
  (cl-loop repeat 40 append (mapcar (lambda (k) (list :keys k)) '("f" "o" "1" "2" "3" "4" "5" "6"))))

(defconst drgnx-perf-work--relayout-form
  (prin1-to-string
   '(progn
      (defvar drgnx-perf--rl-t0 nil "When the layout the user asked for was asked, until its frame is drawn.")
      (defvar drgnx-perf--rl-ms nil "Per layout: ms from the command to the frame drawn.")
      (defvar drgnx-perf--rl-frame-ms nil "Per layout: ms from the command to its frame's arrival.")
      (defvar drgnx-perf--rl-timer nil "Non-nil from the layout's frame until its draw is done.")
      (defvar drgnx-perf--rl-bt nil "The backtrace of the first nil-argument arithmetic error (diagnosis).")
      (defun drgnx-perf--rl-debugger (&rest args)
        (when (and (not drgnx-perf--rl-bt) (eq (car args) 'error)
                   (equal (cadr args) '(wrong-type-argument number-or-marker-p nil)))
          (setq drgnx-perf--rl-bt (backtrace-to-string))))
      (setq debug-on-signal t debugger #'drgnx-perf--rl-debugger)
      (defun drgnx-perf--rl-begin (&rest _)
        "A layout is asked for: the one before is drawn first, so no sample is lost to the next key."
        (drgnx-perf--rl-note 'begin (and drgnx-perf--rl-t0 t) unread-command-events)
        (drgnx-perf--rl-idle 1)
        (drgnx-perf--rl-note 'waited (and drgnx-perf--rl-t0 t) unread-command-events)
        (when drgnx-perf--rl-t0 ; no frame with a layout came for the one before: a command that draws nothing
          (let ((c (assq drgnx-perf--rl-cmd drgnx-perf--rl-lost)))
            (if c (cl-incf (cdr c)) (push (cons drgnx-perf--rl-cmd 1) drgnx-perf--rl-lost))))
        (let ((c (assq this-command drgnx-perf--rl-asked)))
          (if c (cl-incf (cdr c)) (push (cons this-command 1) drgnx-perf--rl-asked)))
        (setq drgnx-perf--rl-cmd this-command drgnx-perf--rl-t0 (float-time)))
      (defvar drgnx-perf--rl-frames nil "Per change the client reported: (t0 set, has layout, timer set), newest first.")
      (defvar drgnx-perf--rl-cmd nil "The command whose layout is asked for.")
      (defvar drgnx-perf--rl-asked nil "Per command: how many layouts it asked for.")
      (defvar drgnx-perf--rl-lost nil "Per command: how many asked for a layout and got no frame with one.")
      (defun drgnx-perf--rl-poll ()
        (when (or (null drgnx-perf--rl-t0) (not (buffer-live-p drgnx-perf--work-buf))
                  (not (drgnx-view-pending-p (drgnx-perf--work-view))))
          (when drgnx-perf--rl-t0
            (push (* 1000 (- (float-time) drgnx-perf--rl-t0)) drgnx-perf--rl-ms)
            (setq drgnx-perf--rl-t0 nil))
          (setq drgnx-perf--rl-timer nil)))
      (defun drgnx-perf--rl-changed (_view marks)
        "A frame with a layout came: the view draws it; poll until it has."
        (when (plist-get marks :layout) (drgnx-perf--rl-note 'layout-frame))
        (push (list (and drgnx-perf--rl-t0 t) (and (plist-get marks :layout) t) (and drgnx-perf--rl-timer t)) drgnx-perf--rl-frames)
        (when (and drgnx-perf--rl-t0 (plist-get marks :layout) (not drgnx-perf--rl-timer))
          (push (* 1000 (- (float-time) drgnx-perf--rl-t0)) drgnx-perf--rl-frame-ms)
          (setq drgnx-perf--rl-timer t)))
      (defun drgnx-perf--rl-drawn (&rest _)
        "After each draw of the map's view (no timer of the lab's own to wake every millisecond): the layout is drawn
when the view has nothing pending."
        (when drgnx-perf--rl-timer (drgnx-perf--rl-poll)))
      (defun drgnx-perf--rl-idle (&optional secs)
        "Wait (SECS, default 10 s, at most) until the last layout asked for is drawn."
        (drgnx-work-thirty--wait (or secs 10) (lambda () (null drgnx-perf--rl-t0))))
      (defun drgnx-perf--rl-arm ()
        "No filters, every layer open, the hub's answer drawn; the samples start over."
        (with-current-buffer drgnx-perf--work-buf
          (setq drgnx-work-map--filters nil drgnx-work-map--collapsed nil)
          (drgnx-work-map--send-filters))
        (drgnx-perf--rl-idle)
        (setq drgnx-perf--rl-ms nil drgnx-perf--rl-frame-ms nil drgnx-perf--rl-trace nil))
      (defvar drgnx-perf--rl-set nil "Per `work/map/set' answer, newest first: (MS ERR VERSION).")
      (defvar drgnx-perf--rl-subs 0 "How many times the map subscribed again during the workload.")
      (defvar drgnx-perf--rl-trace nil "Diagnosis, newest first: (MS WHAT ...), the first 120 things that happened.")
      (defun drgnx-perf--rl-note (&rest what)
        (when (< (length drgnx-perf--rl-trace) 120)
          (push (cons (mod (round (* 1000 (float-time))) 1000000) what) drgnx-perf--rl-trace)))
      (defun drgnx-perf--rl-pre ()
        (drgnx-perf--rl-note 'cmd (key-description (this-command-keys)) (if (symbolp this-command) this-command 'closure)))
      (defun drgnx-perf--rl-answer (t0 callback result err)
        (drgnx-perf--rl-note 'answer (plist-get result :version) (and err t))
        (push (list (round (* 1000 (- (float-time) t0))) (and err t) (plist-get result :version)) drgnx-perf--rl-set)
        (funcall callback result err))
      (defun drgnx-perf--rl-call (orig method params callback)
        "Diagnosis: time each `work/map/set' answer and count the subscriptions."
        (if (equal method "work/map/set")
            (progn (drgnx-perf--rl-note 'set (plist-get params :collapsed) (plist-get (plist-get params :filters) :overlaps))
                   (funcall orig method params (apply-partially #'drgnx-perf--rl-answer (float-time) callback)))
          (when (equal method "work/map/subscribe") (cl-incf drgnx-perf--rl-subs))
          (funcall orig method params callback)))
      (defun drgnx-perf--rl-diag ()
        "What the premise reports besides its counts: per command asked and lost, the subscriptions, the answers."
        (let ((ms (mapcar #'car drgnx-perf--rl-set)))
          (list :asked drgnx-perf--rl-asked :lost drgnx-perf--rl-lost :subscribes drgnx-perf--rl-subs
                :set-answers (length drgnx-perf--rl-set) :set-errors (seq-count #'cadr drgnx-perf--rl-set)
                :set-ms-max (and ms (apply #'max ms)) :set-versions (seq-take (mapcar #'caddr drgnx-perf--rl-set) 12)
                :trace (reverse drgnx-perf--rl-trace)
                :counters (drgnx-work-client--view-counters
                           (drgnx-work-client--get (buffer-local-value 'drgnx-work-space--view drgnx-perf--work-buf))))))
      (advice-add 'drgnx-work-client--call :around #'drgnx-perf--rl-call)
      (add-hook 'pre-command-hook #'drgnx-perf--rl-pre)
      (advice-add 'drgnx-work-map--send-filters :before #'drgnx-perf--rl-begin)
      (add-hook 'drgnx-work-client-change-functions #'drgnx-perf--rl-changed)
      (advice-add 'drgnx-view--draw-buffer :after #'drgnx-perf--rl-drawn)
      (defun drgnx-perf--rl-measure ()
        (drgnx-perf--rl-idle)
        (unless drgnx-perf--rl-ms (error "Premise: no layout was drawn (t0 %S, timer %S)" drgnx-perf--rl-t0 drgnx-perf--rl-timer))
        (list :relayout (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--rl-ms))
              :to_frame (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--rl-frame-ms))))
      (defun drgnx-perf--rl-guard (fn)
        "FN's value; an error it signals is raised again with the backtrace of the first nil-argument error."
        (condition-case e (funcall fn)
          (error (error "%s; BT %s" (error-message-string e)
                        (and drgnx-perf--rl-bt (substring drgnx-perf--rl-bt 0 (min 2500 (length drgnx-perf--rl-bt))))))))
      (defun drgnx-perf--rl-teardown ()
        (advice-remove 'drgnx-work-map--send-filters #'drgnx-perf--rl-begin)
        (advice-remove 'drgnx-work-client--call #'drgnx-perf--rl-call)
        (remove-hook 'pre-command-hook #'drgnx-perf--rl-pre)
        (remove-hook 'drgnx-work-client-change-functions #'drgnx-perf--rl-changed)
        (advice-remove 'drgnx-view--draw-buffer #'drgnx-perf--rl-drawn)
        (setq drgnx-perf--rl-timer nil drgnx-perf--rl-t0 nil)
        (when drgnx-perf--rl-bt (error "BT %s" (substring drgnx-perf--rl-bt 0 (min 3000 (length drgnx-perf--rl-bt))))))
      t))
  "The relayout workload's session side: the time from a layout command (`drgnx-work-map--send-filters') to the frame it
asked for drawn (the view has nothing pending).")

(defconst drgnx-perf-work--raster-form
  (prin1-to-string
   '(progn
      (defun drgnx-perf--raster-band-ms (state band chain)
        "The ms each tile of BAND (with CHAIN's edges drawn as the selection's) took to rasterise at scale 2:
`image-flush' and `image-size' of a fresh image, as the first draw of a tile does."
        (let ((geometry (drgnx-work-edges-geometry state chain 2 168)) (colours (drgnx-work-edges-colours)) ms)
          (dotimes (i (drgnx-work-edges--tile-count band geometry))
            (when-let* ((svg (drgnx-work-edges-tile-svg band i geometry colours)))
              (let ((image (list 'image :type 'svg :data svg :ascent 100 :scale 1)) (t0 (float-time)))
                (image-flush image)
                (image-size image t)
                (push (* 1000 (- (float-time) t0)) ms))))
          ms))
      (defun drgnx-perf--raster-measure ()
        "(:raster_ms STATS :chain_ms STATS): every tile of every band, passes repeated to 100 tiles; and, for twelve
agents in turn, the tiles of the bands that carry that agent's chain, summed."
        (with-current-buffer drgnx-perf--work-buf
          (let* ((state (drgnx-work-map--state))
                 (bands (delq nil (mapcar (lambda (b) (drgnx-work-map--band-of state (plist-get b :row)))
                                          (plist-get (drgnx-work-client-layout state) :bands))))
                 (agents (seq-take (seq-filter (lambda (id) (string-prefix-p "agent:" id)) (drgnx-work-client-ids state)) 12))
                 tiles chains (passes 0))
            (unless bands (error "The map has no band to rasterise"))
            (while (and (< (length tiles) 100) (< passes 40))
              (dolist (b bands) (setq tiles (append (drgnx-perf--raster-band-ms state b nil) tiles)))
              (cl-incf passes))
            (dolist (id agents)
              (let* ((chain (nth 2 (drgnx-work-nav-chain state (drgnx-work-nav-sel state id))))
                     (keys (mapcar #'drgnx-work-edges-key chain)) (sum 0.0))
                (dolist (b bands)
                  (when (seq-some (lambda (s) (member (drgnx-work-edges-key s) keys)) (plist-get b :segs))
                    (setq sum (+ sum (apply #'+ 0.0 (drgnx-perf--raster-band-ms state b chain))))))
                (push sum chains)))
            (list :raster_ms (mapcar #'drgnx-perf--round2 (drgnx-perf-stats tiles))
                  :chain_ms (mapcar #'drgnx-perf--round2 (drgnx-perf-stats chains))
                  :bands (length bands)))))
      t))
  "The raster workload's session side.")

(defconst drgnx-perf-work--live-form
  (prin1-to-string
   '(progn
      (defvar drgnx-perf--wl-slices nil "Wall ms of each draw of the map's view since the arm.")
      (defvar drgnx-perf--wl-start nil "(DRAW-MS DELTAS) when the arm was done.")
      (defvar drgnx-perf--wl-long nil "The draws over 4 ms: (MS TOUCHED ROWS GC-MS), newest first.")
      (defvar drgnx-perf--wl-consed nil "Per draw of the map's view: kB allocated (`drgnx-gc--consed').")
      (defvar drgnx-perf--wl-idle 0 "Draws that ran while Emacs was idle (`current-idle-time' non-nil).")
      (defvar drgnx-perf--wl-gcs nil "Collections in the window, by origin: ((ORIGIN . N) ...).")
      (defun drgnx-perf--wl-gc ()
        (let* ((o (or (bound-and-true-p nidhogg-watchdog-gc-origin) 'auto)) (c (assq o drgnx-perf--wl-gcs)))
          (if c (cl-incf (cdr c)) (push (cons o 1) drgnx-perf--wl-gcs))))
      (defun drgnx-perf--wl-slice (orig buffer)
        (let* ((t0 (float-time)) (v (and (eq buffer drgnx-perf--work-buf) (buffer-local-value 'drgnx-view buffer)))
               (gc0 gc-elapsed) (c0 (drgnx-gc--consed))
               (touched (and v (drgnx-view--touched v))) (rows (and v (plist-get (drgnx-view-stats v) :rows-drawn))))
          (prog1 (funcall orig buffer)
            (when v
              (let ((ms (* 1000 (- (float-time) t0))))
                (push (/ (- (drgnx-gc--consed) c0) 1024.0) drgnx-perf--wl-consed)
                (when (current-idle-time) (cl-incf drgnx-perf--wl-idle))
                (push ms drgnx-perf--wl-slices)
                (when (> ms 4)
                  (push (list (drgnx-perf--round ms) (and touched t) (- (plist-get (drgnx-view-stats v) :rows-drawn) rows)
                              (drgnx-perf--round (* 1000 (- gc-elapsed gc0))))
                        drgnx-perf--wl-long)))))))
      (defun drgnx-perf--wl-arm ()
        (setq drgnx-perf--wl-slices nil drgnx-perf--wl-long nil drgnx-perf--wl-consed nil drgnx-perf--wl-idle 0
              drgnx-perf--wl-gcs nil
              drgnx-perf--wl-start (list (plist-get (drgnx-view-stats (drgnx-perf--work-view)) :draw-ms)
                                         (drgnx-work-client-counter (buffer-local-value 'drgnx-work-space--view drgnx-perf--work-buf)
                                                                    :deltas)))
        (advice-add 'drgnx-view--draw-buffer :around #'drgnx-perf--wl-slice))
      (defun drgnx-perf--wl-wait (secs)
        "Let the session run for SECS: one wait to the deadline, waking only for process output."
        (let ((deadline (+ (float-time) secs)))
          (while (< (float-time) deadline) (accept-process-output nil (- deadline (float-time))))))
      (defun drgnx-perf--wl-measure ()
        "30 s with the map shown and the agents streaming: the view's draw ms per second, each draw's ms and the stalls."
        (let ((t0 (float-time)) (id (buffer-local-value 'drgnx-work-space--view drgnx-perf--work-buf)))
          (drgnx-perf-begin)
          (add-hook 'post-gc-hook #'drgnx-perf--wl-gc)
          (drgnx-perf--wl-wait 30)
          (remove-hook 'post-gc-hook #'drgnx-perf--wl-gc)
          (let* ((secs (- (float-time) t0)) (end (drgnx-perf-end))
                 (draw (- (plist-get (drgnx-view-stats (drgnx-perf--work-view)) :draw-ms) (car drgnx-perf--wl-start)))
                 (deltas (- (drgnx-work-client-counter id :deltas) (cadr drgnx-perf--wl-start))))
            (advice-remove 'drgnx-view--draw-buffer #'drgnx-perf--wl-slice)
            (when (< deltas 30) (error "Premise: the map got %d deltas in %.0f s" deltas secs))
            (append (list :draw_ms_s (drgnx-perf--round2 (/ draw secs)) :deltas deltas
                          :long (vconcat (mapcar (lambda (l) (format "%S" l)) (seq-take drgnx-perf--wl-long 12)))
                          :slice_ms (mapcar #'drgnx-perf--round2 (drgnx-perf-stats drgnx-perf--wl-slices))
                          :draw_kb (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--wl-consed))
                          :draw_mb_s (drgnx-perf--round2 (/ (apply #'+ 0.0 drgnx-perf--wl-consed) 1024 secs))
                          :draws (length drgnx-perf--wl-slices) :draws_idle drgnx-perf--wl-idle
                          :gcs (format "%S" drgnx-perf--wl-gcs)
                          :gc_env (format "%S" (list :threshold gc-cons-threshold :daemon (and (daemonp) t)
                                                     :clients (and (boundp 'server-clients) (length server-clients))
                                                     :waits (and (fboundp 'drgnx-gc--someone-waits-p) (drgnx-gc--someone-waits-p))
                                                     :idle-timer (and (fboundp 'drgnx-timer-active-p)
                                                                      (drgnx-timer-active-p 'gc-idle)))))
                    (list :stalls (plist-get end :stalls))))))
      t))
  "The live workload's session side.")

(defconst drgnx-perf-work--trail-form
  (prin1-to-string
   '(progn
      (defvar drgnx-perf--trail-session nil "The mirror of the 10,000-step session.")
      (defvar drgnx-perf--trail-n 10000 "The steps of the turn.")
      (defun drgnx-perf--trail-steps ()
        "The program of a turn of 10,000 read steps."
        ;; the offset differs each time: the supervisor's `repeat' rule pauses an agent that makes the same call
        ;; three times in a turn, and the turn must not be cut short
        (concat "say start\\n" (mapconcat (lambda (i) (format "provider:read README.md %d 1" i)) (number-sequence 1 drgnx-perf--trail-n) "\\n")))
      (defun drgnx-perf--trail-newest ()
        (plist-get (car (plist-get (drgnx-hub-call-sync "timeline/get" (list :scope "session"
                                                                             :id (drgnx-agent-session-remote drgnx-perf--trail-session)
                                                                             :limit 1)
                                                        15)
                                   :steps))
                   :seq))
      (defun drgnx-perf--trail-up ()
        "A hub with one mock session whose turn took 10,000 steps; an error when it did not."
        (drgnx-perf--hub-start (list (drgnx-perf--trail-steps)))
        (setq drgnx-perf--trail-session (drgnx-agents-mirror-start "mock" temporary-file-directory))
        (drgnx-perf--wait 10 (lambda () (eq (drgnx-agent-session-status drgnx-perf--trail-session) 'idle)))
        (setq drgnx-perf--trail-t0 (float-time) drgnx-perf--trail-trace nil)
        (drgnx-perf--send drgnx-perf--trail-session "go")
        (drgnx-perf--trail-settle 100)
        t)
      (defvar drgnx-perf--trail-err nil "What the last newest-step question to the hub said.")
      (defvar drgnx-perf--trail-t0 nil "When the turn was sent.")
      (defvar drgnx-perf--trail-trace nil "Per question, newest first: (S STEP HUB-CPU-S EMACS-CPU-S ENTRIES).")
      (defun drgnx-perf--trail-cpu (pid)
        (let ((a (and pid (process-attributes pid))))
          (if a (drgnx-perf--round (float-time (time-add (alist-get 'utime a 0) (alist-get 'stime a 0)))) -1)))
      (defun drgnx-perf--trail-settle (secs)
        "Wait up to SECS s for the hub to hold the 10,000 steps (its newest step 10,000 or more); whether it does.  The hub
takes a 10,000-step turn in for minutes, and answers a question meanwhile only now and then: ask every 2 s, 15 s a call."
        (let ((end (+ (float-time) secs)) (n nil))
          (while (and (not (and (numberp n) (>= n drgnx-perf--trail-n))) (< (float-time) end))
            (setq n (condition-case e (drgnx-perf--trail-newest) (error (setq drgnx-perf--trail-err e) nil)))
            (push (list (round (- (float-time) (or drgnx-perf--trail-t0 (float-time)))) n
                        (drgnx-perf--trail-cpu (and (process-live-p drgnx-perf--hub) (process-id drgnx-perf--hub)))
                        (drgnx-perf--trail-cpu (emacs-pid))
                        (length (drgnx-agent-session-entries drgnx-perf--trail-session)))
                  drgnx-perf--trail-trace)
            (unless (and (numberp n) (>= n drgnx-perf--trail-n)) (drgnx-perf--wait 2 #'ignore)))
          (and (numberp n) (>= n drgnx-perf--trail-n))))
      (defun drgnx-perf--trail-premise ()
        "The turn took 10,000 steps (each call waits up to 100 s, the lab's calls allow 120, and the setup waited before)."
        (unless (drgnx-perf--trail-settle 100)
          (error "Premise: the hub does not hold the 10,000 steps (status %S, last answer %S; (s step hub-cpu emacs-cpu entries) %S)"
                 (drgnx-agent-session-status drgnx-perf--trail-session) drgnx-perf--trail-err
                 (seq-take drgnx-perf--trail-trace 40)))
        t)
      (defun drgnx-perf--trail-measure ()
        "(:draw_ms MS :append_ms STATS): the trail opened on the session until its first rows are drawn; then 20 steps
appended (each with its draw)."
        (when-let* ((old (get-buffer (format "*drgnx work trail: %s*" (drgnx-agent-session-remote drgnx-perf--trail-session)))))
          (kill-buffer old))
        (let* ((t0 (float-time))
               (buf (drgnx-work-trail-open nil (drgnx-agent-session-remote drgnx-perf--trail-session))))
          (set-window-buffer (selected-window) buf)
          (unless (drgnx-perf--wait 30 (lambda () (and (buffer-local-value 'drgnx-work-trail--loaded buf)
                                                       (>= (length (buffer-local-value 'drgnx-work-trail--steps buf)) 60))))
            (error "The trail did not load its first page"))
          (with-current-buffer buf
            (drgnx-perf--trail-await drgnx-view)
            (redisplay t))
          (let ((draw (* 1000 (- (float-time) t0))) (appends nil) (merges nil) (to-draw nil) (draws nil))
            (advice-add 'drgnx-view--draw-buffer :around #'drgnx-perf--trail-draw-ad)
            (with-current-buffer buf
              (dotimes (_ 20)
                (let* ((last (car (last drgnx-work-trail--steps)))
                       (step (plist-put (plist-put (copy-sequence last) :id (1+ (plist-get last :id)))
                                        :seq (1+ (plist-get last :seq))))
                       (a (float-time)))
                  (setq drgnx-perf--trail-draws nil)
                  (drgnx-work-trail--merge (list step))
                  (push (* 1000 (- (float-time) a)) merges)
                  (drgnx-perf--trail-await drgnx-view)
                  (push (* 1000 (- (float-time) a)) appends)
                  (when drgnx-perf--trail-draws
                    (push (* 1000 (- (cdar drgnx-perf--trail-draws) a)) to-draw)
                    (dolist (d drgnx-perf--trail-draws) (push (* 1000 (- (cdr d) (car d))) draws))))))
            (advice-remove 'drgnx-view--draw-buffer #'drgnx-perf--trail-draw-ad)
            (unless (= (length to-draw) (length appends))
              (error "Premise: %d of %d appended steps were drawn" (length to-draw) (length appends)))
            ;; an append ends when the view's draw of it ends: the draw throws out of the lab's wait
            (list :settled_s (car (car drgnx-perf--trail-trace))
                  :draw_ms (drgnx-perf--round draw)
                  :append_ms (mapcar #'drgnx-perf--round2 (drgnx-perf-stats to-draw))
                  :append_merge_ms (mapcar #'drgnx-perf--round2 (drgnx-perf-stats merges))
                  :append_draw_ms (mapcar #'drgnx-perf--round2 (drgnx-perf-stats draws))
                  :append_poll_ms (mapcar #'drgnx-perf--round2 (drgnx-perf-stats appends))
                  :steps_loaded (length (buffer-local-value 'drgnx-work-trail--steps buf))))))
      (defun drgnx-perf--trail-await (view)
        "One bounded wait (30 s) until VIEW has nothing pending: the draw that ends its work throws out of the wait."
        (let ((ad (lambda (&rest _) (unless (drgnx-view-pending-p view) (throw 'drgnx-perf--drawn t))))
              (deadline (+ (float-time) 30)))
          (advice-add 'drgnx-view--draw-buffer :after ad)
          (unwind-protect
              (catch 'drgnx-perf--drawn
                (while (and (drgnx-view-pending-p view) (< (float-time) deadline))
                  (accept-process-output nil (max 0.001 (- deadline (float-time))))))
            (advice-remove 'drgnx-view--draw-buffer ad))))
      (defvar drgnx-perf--trail-draws nil "The trail view's draws since the last append: (START . END), newest first.")
      (defun drgnx-perf--trail-draw-ad (orig buffer)
        (let ((t0 (float-time)))
          (prog1 (funcall orig buffer)
            (when (and (buffer-live-p buffer) (eq (buffer-local-value 'major-mode buffer) 'drgnx-work-trail-mode))
              (push (cons t0 (float-time)) drgnx-perf--trail-draws)))))
      (defun drgnx-perf--trail-teardown ()
        (dolist (b (buffer-list)) (when (string-prefix-p "*drgnx work trail: " (buffer-name b)) (kill-buffer b)))
        (ignore-errors (drgnx-agents-kill drgnx-perf--trail-session))
        (drgnx-perf--hub-stop))
      t))
  "The trail workload's session side.")

(defun drgnx-perf-work-workloads (visit kill-fixture)
  "The Work space's workloads (specs like `drgnx-perf-run--workloads'): VISIT is the form that visits the typing
fixture, KILL-FIXTURE the form that kills its buffer.  `work-nav', `work-raster', `work-relayout', `work-live',
`work-typing-shown', `work-typing-hidden', `work-typing-mirror' and `work-trail'."
  (let* ((lib (drgnx-perf-work--lib-form))
         (type (lambda (s) (list :type s)))
         (typing (make-list 6 (funcall type "(let ((x 1)) (message \"%s\" x)) ")))
         (up (lambda (shown extra)
               (concat "(progn " lib " (drgnx-perf--work-up " (if shown "t" "nil") ") " extra " t)")))
         (down (concat "(progn (drgnx-perf--work-down) " kill-fixture " t)"))
         (typing-each (lambda (&optional extra)
                        (concat "(progn " visit " (drgnx-perf--work-premise) " extra " t)")))
         (typing-check "(and (drgnx-perf--work-premise) t)"))
    `((work-nav :setup ,(funcall up t "")
                :each "(progn (drgnx-perf--work-premise) (drgnx-perf--work-select-map) t)"
                :actions ,(drgnx-perf-work--nav-keys)
                :measure "(list :frame_kb (round (/ (memory-report-object-size (drgnx-perf--work-state)) 1024.0)))"
                :check "(and (drgnx-perf--work-premise) (buffer-local-value 'drgnx-work-map--selection drgnx-perf--work-buf) t)"
                :teardown ,down)
      (work-raster :setup ,(funcall up t drgnx-perf-work--raster-form)
                   :each "(progn (drgnx-perf--work-premise) t)"
                   :measure "(drgnx-perf--raster-measure)"
                   :teardown ,down)
      (work-relayout :setup ,(funcall up t drgnx-perf-work--relayout-form)
                     :each "(drgnx-perf--rl-guard (lambda () (drgnx-perf--rl-arm) (drgnx-perf--work-premise) (drgnx-perf--work-select-map) t))"
                     :actions ,(drgnx-perf-work--relayout-keys)
                     :measure "(drgnx-perf--rl-guard #'drgnx-perf--rl-measure)"
                     :check "(and (drgnx-work-thirty-premise) (or (>= (length drgnx-perf--rl-ms) 100) (error \"Premise: %d layouts drawn; %d lost; changes (t0 layout timer) %S; %S\" (length drgnx-perf--rl-ms) (apply #'+ (mapcar #'cdr drgnx-perf--rl-lost)) (let (r) (dolist (f drgnx-perf--rl-frames r) (let ((c (assoc f r))) (if c (cl-incf (cdr c)) (push (cons f 1) r))))) (drgnx-perf--rl-diag))))"
                     :teardown ,(concat "(progn (drgnx-perf--rl-teardown) " down ")"))
      (work-live :setup ,(funcall up t drgnx-perf-work--live-form)
                 :each "(progn (drgnx-perf--work-premise) (drgnx-perf--wl-arm) t)"
                 :measure "(drgnx-perf--wl-measure)"
                 :check ,typing-check
                 :teardown ,down)
      (work-typing-shown :setup ,(funcall up t "")
                         :each ,(funcall typing-each)
                         :actions ,typing :check ,typing-check :teardown ,down)
      (work-typing-hidden :setup ,(funcall up nil "")
                          :each ,(funcall typing-each)
                          :actions ,typing :check ,typing-check :teardown ,down)
      (work-typing-mirror :setup ,(funcall up t "(drgnx-perf--work-transcript)")
                          :each ,(funcall typing-each)
                          :actions ,typing :check ,typing-check :teardown ,down)
      (work-trail :setup ,(concat "(progn " (drgnx-perf-run--hub-form) " " drgnx-perf-work--trail-form " (drgnx-perf--trail-up) t)")
                  :each "(progn (drgnx-perf--trail-premise) t)"
                  :measure "(drgnx-perf--trail-measure)"
                  :teardown ,(concat "(progn (drgnx-perf--trail-teardown) " kill-fixture " t)")))))

(declare-function drgnx-perf-run--hub-form "drgnx-perf-run")

(provide 'drgnx-perf-work)
;;; drgnx-perf-work.el ends here
