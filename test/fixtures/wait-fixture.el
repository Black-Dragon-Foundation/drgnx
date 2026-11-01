;;; wait-fixture.el --- one wait for real async work in tests -*- lexical-binding: t -*-
;; `drgnx-test-wait' is the only way a test waits for a process, a sentinel or a filter.  The deadline only
;; bounds a failure, so it is generous (and scaled on a loaded machine); a pass costs what the work costs.
;; `drgnx-test-wait-presented' is the wait of a GUI test for what the frame shows.
;; `drgnx-test-pause' is the short window of a test that asserts something does not happen.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)                 ; `drgnx-uitest-settle-scale': definitions only, no window or frame work

(defun drgnx-test-wait-now ()
  "Real seconds, even inside the clock fixture (which fakes `float-time')."
  (if (fboundp 'drgnx-test-real-time) (drgnx-test-real-time) (float-time)))

(defun drgnx-test-wait--due-p ()
  "Non-nil when a wall timer is due now.  One `accept-process-output' runs one link of a chain of zero-delay
timers however long it waits, so with a timer due the wait polls without a timeout: the chain runs back to back."
  (and timer-list (not (time-less-p nil (timer--time (car timer-list))))))

(defun drgnx-test-wait--auto-p ()
  "Non-nil inside `drgnx-test-with-clock' on Nidhogg's test clock with `:auto' t."
  (eq (bound-and-true-p drgnx-test--core) 'auto))

(defun drgnx-test-wait--auto-step ()
  "One wait on the auto clock: to the next wall timer, else a virtual second at most.
A wait moves the clock past its timers, so PRED gets a look at each.  Return the clock's state when nothing can run
and nothing is left to wait for, else nil.  (`accept-process-output' with no process and no time returns at once, so
the clock's own deadlock signal, which only a wait without a deadline raises, cannot say that here.)"
  (let ((next (cl-find-if-not #'timer--triggered timer-list)))
    (if next
        (ignore (accept-process-output nil (max 1e-6 (float-time (time-subtract (timer--time next) nil)))))
      (accept-process-output nil 0)
      (let ((state (nidhogg-test-clock-state)))
        (if (and (nidhogg-test-clock--quiet-p) (zerop (plist-get state :deadlines)))
            state
          (ignore (accept-process-output nil 1)))))))

(cl-defun drgnx-test-wait (pred &key (secs 30) what)
  "Call PRED until it returns non-nil, letting processes run between calls; return that value.
The deadline is SECS times `drgnx-uitest-settle-scale' of real time.  While a timer is due the wait polls without a
timeout, so a chain of timers (a view drawing in slices) runs back to back.  On the auto clock it waits for PRED or
for idleness: nothing can run and nothing is left to wait for.  On timeout or idleness signal `ert-test-failed' with
\(:waited-for WHAT :secs S :last-value V :processes ((NAME STATUS)…) :timers (FUNCTION…)), and after idleness
`:clock' with `nidhogg-test-clock-state's plist.
Wait on the sentinel's done flag, never on `process-live-p': it turns nil before the sentinel has run."
  (let* ((limit (* secs (drgnx-uitest-settle-scale)))
         (deadline (+ (drgnx-test-wait-now) limit))
         (value (funcall pred))
         idle)
    (while (and (not value) (not idle) (< (drgnx-test-wait-now) deadline))
      (if (drgnx-test-wait--auto-p)
          (setq idle (drgnx-test-wait--auto-step))
        (accept-process-output nil (if (drgnx-test-wait--due-p) 0 0.02)))
      (setq value (funcall pred)))
    (or value
        (signal 'ert-test-failed
                (append (list :waited-for what :secs limit :last-value value
                              :processes (mapcar (lambda (p) (list (process-name p) (process-status p))) (process-list))
                              :timers (mapcar #'timer--function (append timer-list timer-idle-list)))
                        (and idle (list :clock idle)))))))

(defun drgnx-test--sentinel-ran-p (proc)
  "Non-nil once PROC's sentinel has run (see `drgnx-test-wait-ended')."
  (process-get proc :drgnx-test-ended))

(cl-defun drgnx-test-wait-ended (procs &key (secs 30) what)
  "Wait until the sentinel of every process in PROCS (a process or a list) has run: `process-live-p' turns nil before it.
A done flag is set by a sentinel added after the process's own, so call this before the process can end unobserved
\(right after it starts); a process already dead has its pending sentinel delivered first, and one whose sentinel ran
long before counts as ended."
  (let ((procs (if (processp procs) (list procs) procs)))
    (dolist (p procs)
      (unless (process-get p :drgnx-test-hooked)
        (process-put p :drgnx-test-hooked t)
        (add-function :after (process-sentinel p)
                      (lambda (pr _event) (unless (process-live-p pr) (process-put pr :drgnx-test-ended t))))))
    (when (cl-some (lambda (p) (not (process-live-p p))) procs)
      (accept-process-output nil 0.01)        ; delivers a sentinel still pending
      (dolist (p procs) (unless (process-live-p p) (process-put p :drgnx-test-ended t))))
    (drgnx-test-wait (lambda () (cl-every #'drgnx-test--sentinel-ran-p procs)) :secs secs :what what)))

(declare-function nhwl-presenter-stats "nhwlterm.c")

(defvar drgnx-test--settled-counts nil
  "`drgnx-test--presenter-counts' at the end of the last `drgnx-test-wait-presented'.")

(defun drgnx-test--presenter-counts (frame)
  "(OWED . SENT) of FRAME's display on the native shell: the packets that need a commit of their own (published, less
those merged into one still waiting) and the commits sent.  Nil where there is no presenter."
  (when-let* (((fboundp 'nhwl-presenter-stats))
              (s (ignore-errors (nhwl-presenter-stats frame))))
    (cons (- (plist-get s :packets) (plist-get s :superseded))
          (+ (plist-get s :commits) (plist-get s :bare-commits)))))

(defun drgnx-test--presented-p (frame)
  "Non-nil when every packet of FRAME's display published since the last presented wait has gone out as a commit.
A packet makes at least one commit, and a tree with child frames makes more.  With no presenter (pgtk) it is t: there
`glitnir-snapshot' itself returns after a paint."
  (let ((now (drgnx-test--presenter-counts frame)) (then drgnx-test--settled-counts))
    (or (null now) (null then)
        (>= (- (cdr now) (cdr then)) (- (car now) (car then))))))

(cl-defun drgnx-test-wait-presented (&key frame value (frames 2) (secs 30))
  "Wait until FRAME's root frame (default the session's) shows what was changed; return the last sample.
Each sample is `drgnx-uitest-snapshot' after a redisplay: under Glitnir that presents what was drawn, forces a paint,
and returns the picture the paint committed, so every sample is one trip through the compositor.  The wait ends when
FRAMES samples in a row are the same and no commit is owed.  A sample is the picture, or VALUE's result (a function of
no arguments, called after the paint) for a state the picture does not show, such as a frame's size.  A size or a map
is answered by the compositor in order with those paints, so what is still on its way shows up in a later sample.
The deadline (SECS as in `drgnx-test-wait') only bounds a failure: a timeout fails the test.
A test with a popup that has no parent passes FRAME: `drgnx-uitest-root-frame' can find that popup."
  (let* ((root (or frame (drgnx-uitest-root-frame))) (last nil) (seen 0) (err (list nil)))
    (drgnx-test-wait
     (lambda ()
       (when-let* ((snap (condition-case e (drgnx-uitest-snapshot root) ; no paint in its 1 s: the next try
                           (error (setcar err e) nil))))
         (let ((v (if value (funcall value) snap)))
           (setq seen (if (and (> seen 0) (equal v last)) (1+ seen) 1) last v))
         (and (>= seen frames) (drgnx-test--presented-p root))))
     :secs secs :what (list "a presented frame" root :last-error err))
    (setq drgnx-test--settled-counts (drgnx-test--presenter-counts root))
    last))

(defun drgnx-test-pause (secs &optional _why)
  "Let processes and timers run for SECS of real time; nil.  Only for a test that asserts something does NOT happen
in a short window (a second answer, a tick that starts nothing): a wait for something uses `drgnx-test-wait', and a
wait for a frame `drgnx-test-wait-presented'.  WHY says what may not happen: the GUI tier's lint wants it.
Unlike `sleep-for', which runs one link of a chain of timers, it runs the chain back to back.  On the auto clock it
is SECS of virtual time: a wait returns at once there, and polling real time would spin."
  (if (drgnx-test-wait--auto-p)
      (ignore (sleep-for secs))
    (let ((end (+ (drgnx-test-wait-now) secs)))
      (while (< (drgnx-test-wait-now) end)
        (accept-process-output nil (if (drgnx-test-wait--due-p) 0 0.02))))))

;; Emacs itself creates these buffers when native compilation runs mid-test (a cold eln cache, as in a fresh CI
;; container); a before/after comparison of the buffer list must not see them.
(defconst drgnx-test-native-comp-buffer-names
  '("*Native-compile-Log*" "*Async-native-compile-log*" "*Warnings*" "*Compile-Log*")
  "Buffers Emacs's native compiler creates on its own.")

(defun drgnx-test-buffer-list ()
  "`buffer-list' without the buffers native compilation creates (`drgnx-test-native-comp-buffer-names')."
  (cl-remove-if (lambda (b) (member (buffer-name b) drgnx-test-native-comp-buffer-names)) (buffer-list)))

(provide 'drgnx-wait-fixture)
