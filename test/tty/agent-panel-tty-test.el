;;; agent-panel-tty-test.el --- tty tier: the agent panel's three windows in a terminal -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.  The inner Emacs
;; starts a hub of DRGNX_RATATOSKR_BIN (a test-hooks build with ratatoskr-mock beside it) and one mock agent
;; (test/fixtures/panel-replay-fixture.el, a short first turn) and opens the agent panel: in a terminal frame it is the
;; right area's three windows, the header (the hub's `agent-panel-top/SID' rows), the transcript (`agent-panel/SID')
;; and the composer, each Sjá view in the terminal's display class.  The last row adds a graphical frame of the same
;; daemon (a GUI harness session; skipped without mutter): each frame gets its own class's twins.
(require 'ert)
(require 'seq)
(require 'drgnx-ui)
(require 'drgnx-tty-session)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-ui-repo-dir) nil t)

(defconst drgnx-tty-agent-panel-test--prefix 30
  "Answers and reads the mock's first turn makes: a transcript longer than a terminal's right area.")

(defconst drgnx-tty-agent-panel-test--helpers
  '(progn
     (defvar drgnx-tty-ap--panel nil "The panel's buffer.")
     (defvar drgnx-tty-ap--err nil "What the fixture signalled, printed.")
     (defun drgnx-tty-ap--area (frame)
       "The right area's windows of the panel on FRAME, top to bottom: plists (:part :buffer :start :min :class :view
:stale :top :sja :text)."
       (let* ((main (seq-find (lambda (w) (let ((b (window-buffer w)))
                                            (or (eq b drgnx-tty-ap--panel)
                                                (eq drgnx-tty-ap--panel (buffer-local-value 'drgnx-view-patch-twin-of b)))))
                              (window-list frame 'nomini)))
              (role (and main (window-parameter main 'drgnx-role))))
         (and role
              (mapcar (lambda (w)
                        (let* ((b (window-buffer w)) (s (buffer-local-value 'drgnx-view-patch b)))
                          (list :part (or (window-parameter w 'drgnx-area-part) 'main) :buffer (buffer-name b)
                                :start (window-start w) :min (with-current-buffer b (point-min))
                                :view (and s (drgnx-view-patch-view s)) :class (and s (drgnx-view-patch-class s))
                                :stale (and s (drgnx-view-patch-stale s)) :top (nth 1 (window-edges w))
                                :text (with-current-buffer b
                                        (string-trim (buffer-substring-no-properties
                                                      (window-start w) (min (point-max) (save-excursion
                                                                                          (goto-char (window-start w))
                                                                                          (line-end-position)))))))))
                      (seq-filter (lambda (w) (eq role (window-parameter w 'drgnx-role)))
                                  (window-list frame 'nomini (frame-first-window frame)))))))
     (defun drgnx-tty-ap--ready (frame)
       "FRAME's area as `drgnx-tty-ap--area' once each Sjá window holds rows and none is stale, else nil."
       (let ((area (drgnx-tty-ap--area frame)))
         (and area (seq-every-p (lambda (p) (or (null (plist-get p :view))
                                                (and (plist-get p :class) (not (plist-get p :stale))
                                                     (> (length (plist-get p :text)) 0))))
                                area)
              area)))
     (defun drgnx-tty-ap--part (frame part)
       (seq-find (lambda (p) (eq part (plist-get p :part))) (drgnx-tty-ap--area frame)))
     t)
  "Helpers defined in the inner Emacs.")

(defun drgnx-tty-agent-panel-test--up (s bin)
  "In tty session S: the helpers, then a hub of BIN, the mock agent and its panel, open in the selected frame."
  (drgnx-tty-session-eval s drgnx-tty-agent-panel-test--helpers)
  (drgnx-tty-session-eval
   s `(progn
        (load (expand-file-name "test/fixtures/panel-replay-fixture" drgnx-dir) nil t)
        (setq drgnx-panel-replay-prefix ,drgnx-tty-agent-panel-test--prefix)
        (condition-case e (setq drgnx-tty-ap--panel (drgnx-panel-replay-up ,bin))
          (error (setq drgnx-tty-ap--err (format "%S" e))))
        t)
   180)
  (should-not (drgnx-tty-session-eval s 'drgnx-tty-ap--err)))

(defmacro drgnx-tty-agent-panel-test--with (spec &rest body)
  "BODY with (car SPEC) a terminal session (`emacs -nw', 120x40) whose panel is open and drawn, `bin' the hub."
  (declare (indent 1))
  `(let ((bin (getenv "DRGNX_RATATOSKR_BIN")))
     (skip-unless (and bin (file-executable-p bin)))
     (drgnx-tty-session-with (,(car spec) :size "120x40" :env (list (concat "DRGNX_RATATOSKR_BIN=" bin)))
       (drgnx-tty-session-wait-screen ,(car spec) "\\*scratch\\*" 20)
       (skip-unless (drgnx-tty-session-eval ,(car spec) '(fboundp 'nidhogg-view--call)))
       (unwind-protect
           (progn (drgnx-tty-agent-panel-test--up ,(car spec) bin)
                  (drgnx-tty-session-wait ,(car spec) '(drgnx-tty-ap--ready (selected-frame)) 60)
                  ,@body)
         (ignore-errors (drgnx-tty-session-eval ,(car spec) '(progn (drgnx-panel-replay-down) t) 30))))))

(ert-deftest drgnx-tty-agent-panel/three-windows-in-a-terminal ()
  "The panel in `emacs -nw': the right area holds the header, the transcript and the composer, top to bottom; the
header and the transcript are the hub's two views in a terminal class."
  (drgnx-tty-agent-panel-test--with (s)
    (let ((area (drgnx-tty-session-eval s '(drgnx-tty-ap--area (selected-frame)))))
      (should (equal '(above main below) (mapcar (lambda (p) (plist-get p :part)) area)))
      (let ((above (nth 0 area)) (main (nth 1 area)) (below (nth 2 area)))
        (should (string-prefix-p "agent-panel-top/" (plist-get above :view)))
        (should (string-prefix-p "agent-panel/" (plist-get main :view)))
        (dolist (p (list above main)) (should (string-prefix-p "tty" (plist-get p :class))))
        (should-not (plist-get below :view))          ; the composer is text, not a view
        (should (< (plist-get above :top) (plist-get main :top) (plist-get below :top)))))))

(ert-deftest drgnx-tty-agent-panel/the-header-holds-the-strip ()
  "The header window shows the hub's top rows from their first line, and that line is on the terminal's screen above
the transcript's."
  (drgnx-tty-agent-panel-test--with (s)
    (let* ((above (drgnx-tty-session-eval s '(drgnx-tty-ap--part (selected-frame) 'above)))
           (main (drgnx-tty-session-eval s '(drgnx-tty-ap--part (selected-frame) 'main))))
      (should above)
      (should (= (plist-get above :start) (plist-get above :min)))
      (should (> (length (plist-get above :text)) 0))
      (let ((head (drgnx-tty-session-wait-screen s (regexp-quote (substring (plist-get above :text) 0
                                                                            (min 16 (length (plist-get above :text)))))
                                                 10)))
        (should (< (cdr head) (1+ (plist-get main :top))))))))

(ert-deftest drgnx-tty-agent-panel/the-composer-sends-with-ret ()
  "`s' in the transcript puts point in the composer; typed text and RET go to the agent, and the field empties."
  (drgnx-tty-agent-panel-test--with (s)
    (should (drgnx-tty-session-eval
             s '(let ((w (get-buffer-window drgnx-tty-ap--panel))) (and w (select-window w) t))))
    (drgnx-tty-session-key s "s" 'legacy)
    (drgnx-tty-session-wait s '(eq (window-buffer (selected-window)) (drgnx-agent-panel--composer-of drgnx-tty-ap--panel)) 10)
    (drgnx-tty-session-send s "hello from the terminal")
    (drgnx-tty-session-wait s '(with-current-buffer (drgnx-agent-panel--composer-of drgnx-tty-ap--panel)
                                 (equal "hello from the terminal" (drgnx-agent-panel-composer--field-text)))
                            10)
    (drgnx-tty-session-key s "RET" 'legacy)
    (drgnx-tty-session-wait s '(with-current-buffer (drgnx-agent-panel--composer-of drgnx-tty-ap--panel)
                                 (equal "" (drgnx-agent-panel-composer--field-text)))
                            10)
    (drgnx-tty-session-wait
     s '(let ((r (drgnx-hub-call-sync "agents/get" (list :id (buffer-local-value 'drgnx-agent-panel--session
                                                                                 drgnx-tty-ap--panel)))))
          (seq-some (lambda (e) (equal (plist-get e :text) "hello from the terminal")) (append (plist-get r :entries) nil)))
     30)))

(ert-deftest drgnx-tty-agent-panel/the-transcript-scrolls-and-the-header-stays ()
  "PageUp in the transcript moves it back, PageDown forward again; the header window's start and its line on the
screen do not move."
  (drgnx-tty-agent-panel-test--with (s)
    (should (drgnx-tty-session-eval
             s '(let ((w (get-buffer-window drgnx-tty-ap--panel)))
                  (and w (select-window w) (set-window-point w (with-current-buffer (window-buffer w) (point-max))) t))))
    (let* ((above (drgnx-tty-session-eval s '(drgnx-tty-ap--part (selected-frame) 'above)))
           (head (and above (drgnx-tty-session-find s (regexp-quote (substring (plist-get above :text) 0
                                                                               (min 16 (length (plist-get above :text))))))))
           (start (plist-get (drgnx-tty-session-eval s '(drgnx-tty-ap--part (selected-frame) 'main)) :start)))
      (should above)
      (should head)
      (drgnx-tty-session-key s "<prior>" 'legacy)
      (let ((back (plist-get (drgnx-tty-session-wait
                              s `(let ((m (drgnx-tty-ap--part (selected-frame) 'main))) (and (< (plist-get m :start) ,start) m))
                              10)
                             :start)))
        (should (equal above (drgnx-tty-session-eval s '(drgnx-tty-ap--part (selected-frame) 'above))))
        (should (equal head (drgnx-tty-session-find s (regexp-quote (substring (plist-get above :text) 0
                                                                               (min 16 (length (plist-get above :text))))))))
        (drgnx-tty-session-key s "<next>" 'legacy)
        (drgnx-tty-session-wait
         s `(let ((m (drgnx-tty-ap--part (selected-frame) 'main))) (> (plist-get m :start) ,back)) 10)
        (should (equal above (drgnx-tty-session-eval s '(drgnx-tty-ap--part (selected-frame) 'above))))))))

(ert-deftest drgnx-tty-agent-panel/a-gui-and-a-terminal-frame-each-get-their-class ()
  "One daemon, a graphical frame and an `emacsclient -t' frame, the panel open in both: each frame's header and
transcript are views of the hub in its own class, neither stale; both show the one composer, so a draft typed in one
is in the other."
  (skip-unless (executable-find "mutter"))
  (let ((bin (getenv "DRGNX_RATATOSKR_BIN")))
    (skip-unless (and bin (file-executable-p bin)))
    ;; the runner's own DRGNX_UI_STATE: a deeper one puts the hub's socket path over 103 bytes
    (let* ((gui (drgnx-ui-start "drgnx" nil 60 t)) (tty nil)
           (gui-frame '(seq-find (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list)))
           (tty-frame '(seq-find (lambda (f) (and (not (display-graphic-p f)) (not (frame-parent f))
                                                  (frame-parameter f 'client)))
                                 (frame-list))))
      (unwind-protect
          (progn
            (should (eql 0 (plist-get (drgnx-ui-new-frame gui) :exit)))
            (setq tty (drgnx-tty-session-start
                       :size "120x40"
                       :command (format "%s -a false -t -s %s; echo \"[emacsclient exited $?]\"; sh"
                                        (drgnx-ui--emacsclient) (shell-quote-argument (plist-get gui :socket)))))
            (drgnx-tty-session-wait gui `(and ,tty-frame t) 30)
            (should (drgnx-tty-session-eval gui `(with-selected-frame ,gui-frame ,drgnx-tty-agent-panel-test--helpers)))
            (drgnx-tty-session-eval
             gui `(with-selected-frame ,gui-frame
                    (load (expand-file-name "test/fixtures/panel-replay-fixture" drgnx-dir) nil t)
                    (setq drgnx-panel-replay-prefix 3)
                    (condition-case e (setq drgnx-tty-ap--panel (drgnx-panel-replay-up ,bin))
                      (error (setq drgnx-tty-ap--err (format "%S" e))))
                    t)
             180)
            (should-not (drgnx-tty-session-eval gui 'drgnx-tty-ap--err))
            (drgnx-tty-session-eval
             gui `(with-selected-frame ,tty-frame
                    (drgnx-agent-panel-open (buffer-local-value 'drgnx-agent-panel--session drgnx-tty-ap--panel))
                    (drgnx-view-env-update (drgnx-view-patch-view (buffer-local-value 'drgnx-view-patch drgnx-tty-ap--panel)))
                    t))
            (let ((g (drgnx-tty-session-wait gui `(drgnx-tty-ap--ready ,gui-frame) 60))
                  (tt (drgnx-tty-session-wait gui `(drgnx-tty-ap--ready ,tty-frame) 60)))
              (should (equal '(above main below) (mapcar (lambda (p) (plist-get p :part)) g)))
              (should (equal '(above main below) (mapcar (lambda (p) (plist-get p :part)) tt)))
              (cl-loop for a in g for b in tt
                       do (if (plist-get a :view)
                              (progn (should (equal (plist-get a :view) (plist-get b :view)))
                                     (should-not (equal (plist-get a :class) (plist-get b :class)))
                                     (should (string-prefix-p "tty" (plist-get b :class)))
                                     (should-not (equal (plist-get a :buffer) (plist-get b :buffer))))
                            (should (equal (plist-get a :buffer) (plist-get b :buffer))))))   ; the one composer
            ;; a draft typed in the terminal's composer is in the graphical frame's
            (should (drgnx-tty-session-eval
                     gui `(with-selected-frame ,tty-frame
                            (let ((w (get-buffer-window (drgnx-agent-panel--composer-of drgnx-tty-ap--panel) ,tty-frame)))
                              (and w (select-window w) t)))))
            (drgnx-tty-session-send tty "both frames")
            (drgnx-tty-session-wait
             gui `(with-current-buffer (window-buffer (get-buffer-window (drgnx-agent-panel--composer-of drgnx-tty-ap--panel)
                                                                         ,gui-frame))
                    (equal "both frames" (drgnx-agent-panel-composer--field-text)))
             10))
        (ignore-errors (drgnx-tty-session-eval gui '(progn (drgnx-panel-replay-down) t) 30))
        (when tty (drgnx-tty-session-stop tty))
        (drgnx-ui-stop (plist-get gui :name))))))

;;; agent-panel-tty-test.el ends here
