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

(defun drgnx-tty-agent-panel-test--head-re (above)
  "A regexp for the first line of the header part ABOVE as the terminal shows it: its first two words of three or more
characters, any spaces between (the rows' aligned spacing is not one space a column)."
  (let ((words (seq-filter (lambda (w) (>= (length w) 3))
                           (split-string (car (split-string (plist-get above :text) "\n")) "[ \t]+" t))))
    (mapconcat #'regexp-quote (seq-take words 2) " +")))

(ert-deftest drgnx-tty-agent-panel/the-header-holds-the-strip ()
  "The header window shows the hub's top rows from their first line, and that line is on the terminal's screen above
the transcript's."
  (drgnx-tty-agent-panel-test--with (s)
    (let* ((above (drgnx-tty-session-eval s '(drgnx-tty-ap--part (selected-frame) 'above)))
           (main (drgnx-tty-session-eval s '(drgnx-tty-ap--part (selected-frame) 'main))))
      (should above)
      (should (= (plist-get above :start) (plist-get above :min)))
      (should (> (length (plist-get above :text)) 0))
      (let ((head (drgnx-tty-session-wait-screen s (drgnx-tty-agent-panel-test--head-re above)
                                                 10)))
        (should (< (cdr head) (1+ (plist-get main :top))))))))

(ert-deftest drgnx-tty-agent-panel/the-composer-sends-with-ret ()
  "`s' in the transcript puts point in the composer; typed text and RET go to the agent, and the field empties."
  (drgnx-tty-agent-panel-test--with (s)
    ;; the fixture's up ends with the module's keys applied, as turning a module on does
    (should (eq 'drgnx-agent-panel-compose
                (drgnx-tty-session-eval s '(with-current-buffer drgnx-tty-ap--panel (key-binding "s")))))
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
           (head (and above (drgnx-tty-session-find s (drgnx-tty-agent-panel-test--head-re above))))
           (start (plist-get (drgnx-tty-session-eval s '(drgnx-tty-ap--part (selected-frame) 'main)) :start)))
      (should above)
      (should head)
      (drgnx-tty-session-key s "<prior>" 'legacy)
      (let ((back (plist-get (drgnx-tty-session-wait
                              s `(let ((m (drgnx-tty-ap--part (selected-frame) 'main))) (and (< (plist-get m :start) ,start) m))
                              10)
                             :start)))
        (should (equal above (drgnx-tty-session-eval s '(drgnx-tty-ap--part (selected-frame) 'above))))
        (should (equal head (drgnx-tty-session-find s (drgnx-tty-agent-panel-test--head-re above))))
        (drgnx-tty-session-key s "<next>" 'legacy)
        (drgnx-tty-session-wait
         s `(let ((m (drgnx-tty-ap--part (selected-frame) 'main))) (> (plist-get m :start) ,back)) 10)
        (should (equal above (drgnx-tty-session-eval s '(drgnx-tty-ap--part (selected-frame) 'above))))))))

(ert-deftest drgnx-tty-agent-panel/a-gui-and-a-terminal-frame-each-get-their-class ()
  "One daemon, a graphical frame and an `emacsclient -t' frame, the panel open in both: each frame's header and
transcript are views of the hub in its own class, neither stale, and each header is the one of its transcript's class
(`drgnx-agent-panel-header--for'); both show the one composer, so a draft typed in one is in the other."
  (skip-unless (executable-find "mutter"))
  (let ((bin (getenv "DRGNX_RATATOSKR_BIN")))
    (skip-unless (and bin (file-executable-p bin)))
    ;; a short state directory: under the runner's, the hub's socket path in the session's TMPDIR is over 103 bytes
    (let* ((root (make-temp-file "/tmp/dgap" t))
           (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
           (gui (drgnx-ui-start "drgnx" nil 60 t)) (tty nil)
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
            ;; each frame's header window holds the header of its transcript's class (`drgnx-agent-panel-header--for'):
            ;; the terminal's the header's twin of its class, the graphical frame's its own
            (dolist (f (list gui-frame tty-frame))
              (should (equal
                       '(t t)
                       (drgnx-tty-session-eval
                        gui `(let* ((parts (drgnx-tty-ap--area ,f))
                                    (above (get-buffer (plist-get (nth 0 parts) :buffer)))
                                    (main (get-buffer (plist-get (nth 1 parts) :buffer))))
                               (list (eq above (drgnx-agent-panel-header--for
                                                (drgnx-agent-panel--header-of drgnx-tty-ap--panel) main))
                                     (equal (drgnx-view-patch-class (buffer-local-value 'drgnx-view-patch above))
                                            (drgnx-view-patch-class (buffer-local-value 'drgnx-view-patch main)))))))))
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
        (drgnx-ui-stop (plist-get gui :name))
        (delete-directory root t)))))

;; The header's pin in a terminal frame beside a graphical one: there the transcript is the panel's twin of the
;; terminal's class, and the pin goes to the panel itself (the twin takes the panel's state at its next command, so a
;; pin left on the twin alone is lost).

(ert-deftest drgnx-tty-agent-panel/the-headers-pin-in-a-terminal-frame-reaches-the-panel ()
  "In an `emacsclient -t' frame beside a graphical frame, the header's pin pins the step at the twin transcript's
point on the panel's own state, and it stays pinned through a command in the twin."
  (skip-unless (executable-find "mutter"))
  (let ((bin (getenv "DRGNX_RATATOSKR_BIN")))
    (skip-unless (and bin (file-executable-p bin)))
    (let* ((root (make-temp-file "/tmp/dgap" t))
           (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
           (gui (drgnx-ui-start "drgnx" nil 60 t)) (tty nil)
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
            (drgnx-tty-session-wait gui `(drgnx-tty-ap--ready ,gui-frame) 60)
            (drgnx-tty-session-wait gui `(drgnx-tty-ap--ready ,tty-frame) 60)
            ;; in the terminal frame: the transcript is a twin; its window's point on its second step, then the
            ;; header's pin
            (let ((key (drgnx-tty-session-eval
                        gui `(let* ((parts (drgnx-tty-ap--area ,tty-frame))
                                    (hw (get-buffer-window (plist-get (nth 0 parts) :buffer) ,tty-frame))
                                    (tw (get-buffer-window (plist-get (nth 1 parts) :buffer) ,tty-frame))
                                    (twin (window-buffer tw)) (pos nil) (seen nil))
                               (unless (eq twin drgnx-tty-ap--panel)
                                 (with-current-buffer twin
                                   (setq pos (point-min))
                                   (while (and pos (< pos (point-max)) (< (length seen) 2))
                                     (let ((e (get-text-property pos 'drgnx-agent-panel-entry)))
                                       (when (and e (not (memq e seen))) (push e seen)))
                                     (when (< (length seen) 2)
                                       (setq pos (next-single-property-change pos 'drgnx-agent-panel-entry nil (point-max))))))
                                 (when (= 2 (length seen))
                                   ;; the panel holds its own pins (as after a pin and an unpin in the graphical
                                   ;; frame): the value the twin takes before its next command
                                   (with-current-buffer drgnx-tty-ap--panel (setq drgnx-agent-panel--pins nil))
                                   (set-window-point tw pos)
                                   (drgnx-agent-panel--pin-from hw)
                                   (list :e (car seen))))))))
              (should key)
              ;; the pin is the panel's at once, not the twin's alone
              (should (drgnx-tty-session-eval
                       gui `(and (member ',key (mapcar #'car (buffer-local-value 'drgnx-agent-panel--pins
                                                                                 drgnx-tty-ap--panel)))
                                 t)))
              ;; a command in the twin's window (the twin takes the panel's state again)
              (should (drgnx-tty-session-eval
                       gui `(with-selected-frame ,tty-frame
                              (let ((w (get-buffer-window (plist-get (nth 1 (drgnx-tty-ap--area ,tty-frame)) :buffer)
                                                          ,tty-frame)))
                                (and w (select-window w) t)))))
              (drgnx-tty-session-key tty "C-l" 'legacy)
              (drgnx-tty-session-wait
               gui `(let ((twin (get-buffer (plist-get (nth 1 (drgnx-tty-ap--area ,tty-frame)) :buffer))))
                      (and (member ',key (mapcar #'car (buffer-local-value 'drgnx-agent-panel--pins drgnx-tty-ap--panel)))
                           (member ',key (mapcar #'car (buffer-local-value 'drgnx-agent-panel--pins twin)))))
               10)))
        (ignore-errors (drgnx-tty-session-eval gui '(progn (drgnx-panel-replay-down) t) 30))
        (when tty (drgnx-tty-session-stop tty))
        (drgnx-ui-stop (plist-get gui :name))
        (delete-directory root t)))))

(ert-deftest drgnx-tty-agent-panel/the-pin-key-in-the-terminal-twin-stays-pinned ()
  "In an `emacsclient -t' frame beside a graphical frame, the pin key pressed in the twin transcript's window (a real
command, through the terminal) pins the step at point on the panel, and the twin's hand-back after the command does
not undo it: it is still pinned after one more command."
  (skip-unless (executable-find "mutter"))
  (let ((bin (getenv "DRGNX_RATATOSKR_BIN")))
    (skip-unless (and bin (file-executable-p bin)))
    (let* ((root (make-temp-file "/tmp/dgap" t))
           (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
           (gui (drgnx-ui-start "drgnx" nil 60 t)) (tty nil)
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
            (drgnx-tty-session-wait gui `(drgnx-tty-ap--ready ,gui-frame) 60)
            (drgnx-tty-session-wait gui `(drgnx-tty-ap--ready ,tty-frame) 60)
            ;; in the terminal frame: the twin transcript's window selected, its point on its second step; the panel
            ;; holds its own pins (as after a pin and an unpin in the graphical frame)
            (let* ((key-desc (drgnx-tty-session-eval
                              ;; the key a profile gives the pin (no session key of its own: the profile's, put back
                              ;; after)
                              gui '(progn
                                     (drgnx-keys-use '((vscode app editing window)))
                                     (let ((k (where-is-internal 'drgnx-agent-panel-pin (list drgnx-agent-panel-mode-map)
                                                                 t)))
                                       (and k (key-description k))))))
                   (key (drgnx-tty-session-eval
                         gui `(with-selected-frame ,tty-frame
                                (let* ((tw (get-buffer-window (plist-get (nth 1 (drgnx-tty-ap--area ,tty-frame)) :buffer)
                                                              ,tty-frame))
                                       (twin (window-buffer tw)) (pos nil) (seen nil))
                                  (unless (eq twin drgnx-tty-ap--panel)
                                    (with-current-buffer twin
                                      (setq pos (point-min))
                                      (while (and pos (< pos (point-max)) (< (length seen) 2))
                                        (let ((e (get-text-property pos 'drgnx-agent-panel-entry)))
                                          (when (and e (not (memq e seen))) (push e seen)))
                                        (when (< (length seen) 2)
                                          (setq pos (next-single-property-change pos 'drgnx-agent-panel-entry nil
                                                                                 (point-max))))))
                                    (when (= 2 (length seen))
                                      (with-current-buffer drgnx-tty-ap--panel (setq drgnx-agent-panel--pins nil))
                                      (select-window tw)
                                      (set-window-point tw pos)
                                      (list :e (car seen)))))))))
              (should key-desc)
              (should key)
              (drgnx-tty-session-key tty key-desc 'legacy)
              ;; (`drgnx-test-wait' around the eval: `drgnx-tty-session-wait' reads the screen of the session it is
              ;; given when it times out, and the graphical session has none)
              (drgnx-test-wait
               (lambda ()
                 (drgnx-tty-session-eval
                  gui `(member ',key (mapcar #'car (buffer-local-value 'drgnx-agent-panel--pins drgnx-tty-ap--panel)))))
               :secs 10 :what (list "the panel's pins after the pin key" key))
              ;; one more command in the twin: the pin stays the panel's
              (drgnx-tty-session-key tty "C-l" 'legacy)
              (drgnx-test-wait
               (lambda ()
                 (drgnx-tty-session-eval
                  gui `(let ((twin (get-buffer (plist-get (nth 1 (drgnx-tty-ap--area ,tty-frame)) :buffer))))
                         (member ',key (mapcar #'car (buffer-local-value 'drgnx-agent-panel--pins twin))))))
               :secs 10 :what (list "the twin's pins after one more command" key))
              (should (drgnx-tty-session-eval
                       gui `(and (member ',key (mapcar #'car (buffer-local-value 'drgnx-agent-panel--pins
                                                                                 drgnx-tty-ap--panel)))
                                 t)))))
        (ignore-errors (drgnx-tty-session-eval gui '(progn (drgnx-keys--restore) t) 30))
        (ignore-errors (drgnx-tty-session-eval gui '(progn (drgnx-panel-replay-down) t) 30))
        (when tty (drgnx-tty-session-stop tty))
        (drgnx-ui-stop (plist-get gui :name))
        (delete-directory root t)))))


;;; agent-panel-tty-test.el ends here
