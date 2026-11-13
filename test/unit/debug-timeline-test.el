;;; debug-timeline-test.el --- batch tests: probes, the stop timeline, past stops -*- lexical-binding: t -*-
;; test-class: det
;; The hub's answers are scripted (`drgnx-hub-call' replaced): what is tested is what the editor asks, sends and draws.
;; The records themselves have Rust tests (debug::tests_record, tests_probes: the strip's rows, the sparkline).
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug-timeline" drgnx-dir) nil t)

(defvar debug-timeline-test--calls nil "Every (METHOD . PARAMS) the test's hub was asked, in order.")
(defvar debug-timeline-test--probes nil "The scripted hub's probes.")

(defun debug-timeline-test--answer (method params dir)
  "The scripted hub's answer to METHOD with PARAMS, for the project DIR."
  (pcase method
    ("debug/probe/op"
     (let ((op (plist-get params :op)))
       (pcase (plist-get op :op)
         ("add" (push (list :id (format "p%d" (1+ (length debug-timeline-test--probes))) :path (plist-get op :path)
                            :line (plist-get op :line) :expr (plist-get op :expr) :enabled t)
                      debug-timeline-test--probes))
         ;; the hub places it: the next line that runs (here: the next one)
         ("result" (push (list :id (format "p%d" (1+ (length debug-timeline-test--probes))) :path (plist-get op :path)
                               :line (1+ (plist-get op :line)) :expr (plist-get op :expr) :enabled t)
                         debug-timeline-test--probes))
         ("remove" (setq debug-timeline-test--probes
                         (seq-remove (lambda (p) (equal (plist-get p :id) (plist-get op :id))) debug-timeline-test--probes))))
       (list :root dir :probes (vconcat (reverse debug-timeline-test--probes)))))
    ("debug/run/get"
     (list :run (list :id "r1" :n 4) :total 3
           :stops (vector (list :index 3 :reason "breakpoint" :path "/p/a.py" :line 2)
                          (list :index 4 :reason "step" :path "/p/a.py" :line 3)
                          (list :index 9 :reason "exception" :path "/p/a.py" :line 4))
           :lanes [] :more nil
           :strip (vector (list :key "head" :text "Run 4 · 3 stops" :runs (vector (vector 0 5 "drgnx-debug-timeline-head")))
                          (list :key "stops" :text "●1 ·2 ▲3"
                                :runs (vector (vector 0 1 "drgnx-debug-breakpoint") (vector 0 1 "no-such-face-at-all"))
                                :props (vector (vector 0 2 "drgnx-debug-stop" 3) (vector 3 5 "drgnx-debug-stop" 4)
                                               (vector 6 8 "drgnx-debug-stop" 9))))))
    ("debug/run/stop"
     (let ((i (plist-get params :stop)))
       (list :run "r1" :stop (list :index i :reason "step" :line (pcase i (3 2) (4 3) (_ 4)))
             :capture (list :frames (vector (list :name "restock" :line 3 :source (list :path "/p/a.py")))
                            :scopes (vector (list :scope (list :name "Locals")
                                                  :variables (vector (list :name "shortfall" :value "16")))))
             :snapshot "abc"
             :source (list :path "/p/a.py" :text "def restock():\n    x = 1\n    y = 2\n    return y\n"
                           :not_what_ran t))))
    (_ t)))

(defmacro debug-timeline-test--with (&rest body)
  "BODY in a file buffer of five lines, shown in the selected window, with the hub scripted."
  (declare (indent 0))
  `(let* ((dir (directory-file-name (make-temp-file "dt" t))) (file (expand-file-name "a.py" dir))
          (debug-timeline-test--calls nil) (debug-timeline-test--probes nil) (was (window-buffer (selected-window))))
     (with-temp-file file (dotimes (i 5) (insert (format "line_%d = %d\n" (1+ i) (1+ i)))))
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params cb &rest _)
                  (setq debug-timeline-test--calls (append debug-timeline-test--calls (list (cons method params))))
                  (funcall cb (debug-timeline-test--answer method params dir) nil)
                  1))
               ((symbol-function 'drgnx-hub-call-sync)
                (lambda (method params &rest _) (debug-timeline-test--answer method params dir)))
               ((symbol-function 'drgnx-debug-launch-root) (lambda () dir)))
       (let ((buf (find-file-noselect file)))
         (unwind-protect
             (progn (set-window-buffer (selected-window) buf)
                    (with-current-buffer buf (drgnx-debug-timeline-mode 1) ,@body))
           (drgnx-debug-timeline-mode -1)
           (set-window-buffer (selected-window) was)
           (with-current-buffer buf (set-buffer-modified-p nil))
           (kill-buffer buf)
           (delete-directory dir t))))))

(defun debug-timeline-test--last (method)
  "The params of the last METHOD call."
  (cdr (car (last (seq-filter (lambda (c) (equal (car c) method)) debug-timeline-test--calls)))))

(defun debug-timeline-test--glyphs ()
  "The lines this buffer's probe glyphs sit on."
  (sort (mapcar (lambda (o) (line-number-at-pos (overlay-start o)))
                (seq-filter (lambda (o) (overlay-get o 'drgnx-debug-probe)) (overlays-in (point-min) (point-max))))
        #'<))

(defun debug-timeline-test--values (id)
  "The text at the end of probe ID's line."
  (when-let* ((o (seq-find (lambda (o) (equal (overlay-get o 'drgnx-debug-probe-values) id))
                           (overlays-in (point-min) (point-max)))))
    (substring-no-properties (or (overlay-get o 'after-string) ""))))

(ert-deftest drgnx-debug-timeline/the-sparkline-is-the-hubs ()
  ;; the same answers as debug::strip::sparkline's test
  (should (equal (drgnx-debug-timeline-spark '("1" "5" "9")) "▁▅█"))
  (should (equal (drgnx-debug-timeline-spark '("3" "'x'" "3")) "▄▄"))
  (should (equal (drgnx-debug-timeline-spark '("'a'" "None")) ""))
  (should (= (length (drgnx-debug-timeline-spark (mapcar #'number-to-string (number-sequence 1 100))))
             drgnx-debug-timeline-spark-max)))

(ert-deftest drgnx-debug-timeline/a-probe-gets-its-glyph-column-and-values ()
  (debug-timeline-test--with
    (should-not (debug-timeline-test--glyphs))
    (should-not (drgnx-margins-offset 'debug-probe))
    (goto-char (point-min)) (forward-line 1)
    (drgnx-debug-probe-add "line_2")
    (should (equal (plist-get (debug-timeline-test--last "debug/probe/op") :op)
                   (list :op "add" :path (expand-file-name buffer-file-name) :line 2 :expr "line_2")))
    (should (equal (debug-timeline-test--glyphs) '(2)))
    ;; the column is claimed while the file has a probe
    (should (drgnx-margins-offset 'debug-probe))
    ;; Probe the Result: what line 3 assigns, placed by the hub; the buffer's text and language go with it
    (goto-char (point-min)) (forward-line 2)
    (should (equal (drgnx-debug-timeline--assigned) "line_3"))
    (drgnx-debug-probe-result "line_3")
    (let ((op (plist-get (debug-timeline-test--last "debug/probe/op") :op)))
      (should (equal (plist-get op :op) "result"))
      (should (string-prefix-p "line_1 = 1\n" (plist-get op :text))))
    (should (equal (debug-timeline-test--glyphs) '(2 4)))
    ;; hits come: after the throttle, the line ends show the sparkline and the newest value
    (drgnx-debug-timeline--event "debug-run" (list :run "r1" :n 1 :root (drgnx-debug-launch-root) :state "recording"))
    (drgnx-debug-timeline--event "debug-probe-hits"
                                 (list :run "r1" :hits (vector (list :probe "p1" :value "1") (list :probe "p1" :value "9"))))
    (should (drgnx-timer-active-p (cons 'debug-probe-values (drgnx-debug-launch-root))))
    (drgnx-debug-timeline--values-changed (drgnx-debug-launch-root))
    (should (equal (debug-timeline-test--values "p1") "  ▁█ 9"))
    (should (equal (debug-timeline-test--values "p2") ""))
    ;; removed: its values are forgotten, and with the last probe the column goes
    (goto-char (point-min)) (forward-line 1)
    (drgnx-debug-probe-remove)
    (should (equal (debug-timeline-test--glyphs) '(4)))
    (should-not (gethash (concat (drgnx-debug-launch-root) "\0p1") drgnx-debug-timeline--values))
    (goto-char (point-min)) (forward-line 3)
    (drgnx-debug-probe-remove)
    (should-not (debug-timeline-test--glyphs))
    (should-not (drgnx-margins-offset 'debug-probe))))

(ert-deftest drgnx-debug-timeline/the-strip-inserts-the-hubs-rows ()
  (debug-timeline-test--with
    (drgnx-debug-timeline-show "r1")
    (with-current-buffer drgnx-debug-timeline-buffer
      (should (equal (buffer-string) "Run 4 · 3 stops\n●1 ·2 ▲3\n"))
      (should (eq (get-text-property (point-min) 'face) 'drgnx-debug-timeline-head))
      (goto-char (point-min)) (forward-line 1)
      ;; a face the editor does not know is dropped, never interned
      (should (equal (get-text-property (point) 'face) 'drgnx-debug-breakpoint))
      (should-not (intern-soft "no-such-face-at-all"))
      (should (eql (get-text-property (+ (point) 6) 'drgnx-debug-stop) 9))
      (should drgnx-debug-past-mode))))

(ert-deftest drgnx-debug-timeline/past-stops-open-as-they-ran-and-live-returns ()
  (debug-timeline-test--with
    (drgnx-debug-timeline-show "r1")
    ;; Alt ← from live: the newest stop
    (drgnx-debug-timeline-back)
    (should (equal (debug-timeline-test--last "debug/run/stop") '(:run "r1" :stop 9)))
    (with-current-buffer drgnx-debug-timeline-past-buffer
      (should buffer-read-only)
      (should drgnx-debug-past-mode)
      ;; the file as it ran (the snapshot's text, not the editor's), the stop's line marked
      (should (string-prefix-p "def restock():" (buffer-string)))
      (let ((head (substring-no-properties header-line-format)))
        (should (string-match-p "Stop 3 of 3" head))
        (should (string-match-p "not what ran" head))
        (should (string-match-p "Back to Live" head)))
      (let ((o (seq-find (lambda (o) (overlay-get o 'drgnx-debug-past-stop)) (overlays-in (point-min) (point-max)))))
        (should (= (line-number-at-pos (overlay-start o)) 4))))
    (with-current-buffer drgnx-debug-timeline-vars-buffer
      (should (string-match-p "shortfall = 16" (buffer-string)))
      (should (string-match-p "restock  a.py:3" (buffer-string))))
    ;; Alt ← again: the stop before; Alt → twice: the newest, then live
    (drgnx-debug-timeline-back)
    (should (equal (debug-timeline-test--last "debug/run/stop") '(:run "r1" :stop 4)))
    ;; the strip rings the stop shown
    (should (eql (plist-get (debug-timeline-test--last "debug/run/get") :current) 4))
    (drgnx-debug-timeline-forward)
    (should (eql drgnx-debug-timeline--current 9))
    (drgnx-debug-timeline-forward)
    (should-not drgnx-debug-timeline--current)
    (should-not (get-buffer drgnx-debug-timeline-past-buffer))
    (should-not (get-buffer drgnx-debug-timeline-vars-buffer))
    ;; a click on the strip opens that stop
    (with-current-buffer drgnx-debug-timeline-buffer
      (goto-char (point-min)) (forward-line 1) (forward-char 3)
      (drgnx-debug-timeline-open-at-point))
    (should (eql drgnx-debug-timeline--current 4))))

(ert-deftest drgnx-debug-timeline/a-file-opens-when-no-hub-runs ()
  "The timeline's `find-file-hook' asks the hub for the file's probes: with no hub (its socket's directory is not
there) the file still opens, without probes; a hook never signals (the GUI rows' find-file failed \"no hub\")."
  (let* ((run (make-temp-file "dt-run" t)) (dir (make-temp-file "dt" t)) (file (expand-file-name "a.py" dir))
         (process-environment (cons (concat "XDG_RUNTIME_DIR=" run) process-environment))
         buf)
    (write-region "x = 1\n" nil file nil 'silent)
    (unwind-protect
        (progn (drgnx-debug-timeline-mode 1)
               (setq buf (find-file-noselect file))
               (should (buffer-live-p buf))
               (should (buffer-local-value 'drgnx-debug-probes-mode buf)))
      (drgnx-debug-timeline-mode -1)
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory dir t) (delete-directory run t))))

(ert-deftest drgnx-debug-timeline/an-unrecorded-session-says-why-once ()
  "A session the hub could not record (its keyring locked or absent: `debug-recording-off') is said in the echo area,
once for the same reason; nothing asks."
  (let ((said nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (when fmt (push (apply #'format-message fmt args) said)))))
      (unwind-protect
          (progn
            (drgnx-debug-timeline--event "debug-recording-off"
                                         (list :session "d1" :root "/p" :short "keyring locked"
                                               :why "the keyring is locked; it unlocks when you log in"))
            (drgnx-debug-timeline--event "debug-recording-off"
                                         (list :session "d2" :root "/p" :short "keyring locked"
                                               :why "the keyring is locked; it unlocks when you log in"))
            ;; a few words; the whole reason (a keyring's raw error) is the status segment's tooltip
            (should (equal said '("Debug: not recorded: keyring locked")))
            (should (equal (drgnx-debug-timeline-unrecorded "d2") "the keyring is locked; it unlocks when you log in"))
            (drgnx-debug-timeline--event "debug-recording-off"
                                         (list :session "d3" :root "/p" :short "no keyring"
                                               :why "org.freedesktop.DBus.Error.ServiceUnknown: The name is not activatable"))
            (should (equal (car said) "Debug: not recorded: no keyring"))
            (should (string-match-p "ServiceUnknown" (drgnx-debug-timeline-unrecorded "d3"))))
        (setq drgnx-debug-timeline--off-said nil drgnx-debug-timeline--unrecorded nil)))))

(ert-deftest drgnx-debug-timeline/off-leaves-nothing ()
  (debug-timeline-test--with
    (drgnx-debug-probe-add "x")
    (drgnx-debug-timeline-show "r1")
    (drgnx-debug-timeline-back)
    (drgnx-debug-timeline-mode -1)
    (should-not drgnx-debug-probes-mode)
    (should-not (debug-timeline-test--glyphs))
    (should-not (memq #'drgnx-debug-timeline--event drgnx-hub-event-functions))
    (should-not (memq #'drgnx-debug-timeline--probes-on find-file-hook))
    (should-not (get-buffer drgnx-debug-timeline-buffer))
    (should-not (get-buffer drgnx-debug-timeline-past-buffer))
    (should (zerop (hash-table-count drgnx-debug-timeline--probes)))))

;; regression: a buffer killed (or its major mode changed) with the mode on left the margins hook behind
(ert-deftest drgnx-debug-timeline/a-probed-buffer-killed-or-remoded-takes-its-hook-along ()
  "Killing a buffer with `drgnx-debug-probes-mode' on, or changing its major mode, turns the mode off, so the
margins hook goes with the last such buffer."
  (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) (error "No hub"))))
    (let ((a (generate-new-buffer "probed-a")) (b (generate-new-buffer "probed-b")))
      (unwind-protect
          (progn
            (with-current-buffer a (drgnx-debug-probes-mode 1))
            (with-current-buffer b (drgnx-debug-probes-mode 1))
            (should (memq #'drgnx-debug-timeline--restring drgnx-margins-changed-functions))
            (kill-buffer a)
            (should (memq #'drgnx-debug-timeline--restring drgnx-margins-changed-functions))
            (with-current-buffer b (fundamental-mode))
            (should-not (buffer-local-value 'drgnx-debug-probes-mode b))
            (should-not (memq #'drgnx-debug-timeline--restring drgnx-margins-changed-functions)))
        (when (buffer-live-p a) (kill-buffer a))
        (when (buffer-live-p b) (kill-buffer b))))))

(provide 'debug-timeline-test)
;;; debug-timeline-test.el ends here
