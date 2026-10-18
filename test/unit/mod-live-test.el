;;; mod-live-test.el --- batch tests: the Live view of the agents' browser, against a mock CDP server -*- lexical-binding: t -*-
;; The mock (test/fixtures/mock-cdp.el) needs the `websocket' package: it is read from the user's ELPA
;; (DRGNX_USER_ELPA, read-only, as the runner allows); without it these tests are skipped.  No real Chrome
;; runs: the browser's job is stubbed, its profile directory is under a temp state dir.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-agents)
(require 'drgnx-jobs)

(defconst drgnx-live-test--websocket
  (or (locate-library "websocket")
      (when-let* ((elpa (getenv "DRGNX_USER_ELPA"))
                  (dir (car (last (and (file-directory-p elpa) (directory-files elpa t "\\`websocket-[0-9]"))))))
        (locate-file "websocket.el" (list dir))))
  "websocket.el, when this Emacs can load it.")

(when drgnx-live-test--websocket
  (let ((load-path (cons (file-name-directory drgnx-live-test--websocket) load-path)))
    (require 'websocket))
  (load (expand-file-name "test/fixtures/mock-cdp" drgnx-dir) nil t))
(load (expand-file-name "modules/tools/drgnx-browser" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-live" drgnx-dir) nil t)

(defmacro drgnx-live-test--with (&rest body)
  "BODY with a temp state dir, the mock browser serving on PORT as the running live browser (job \"job-live\"),
no agents, and everything closed afterwards."
  (declare (indent 0))
  `(let* ((root (make-temp-file "drgnx-live" t))
          (process-environment (cons (concat "XDG_STATE_HOME=" root) process-environment))
          (drgnx-agents--sessions nil) (drgnx-live--given nil) (drgnx-agents-env-functions (list #'drgnx-live--agent-env))
          (port (drgnx-mock-cdp-start))
          (drgnx-live--browser (list :port port :ws (format "ws://127.0.0.1:%d/devtools/browser/mock" port) :job "job-live")))
     (cl-letf (((symbol-function 'drgnx-jobs-get)
                (lambda (id) (and (equal id "job-live") (list :id id :status 'running)))))
       (unwind-protect (progn ,@body)
         (when (get-buffer "*drgnx live*") (kill-buffer "*drgnx live*"))
         (drgnx-mock-cdp-stop)
         (delete-directory root t)))))

(defun drgnx-live-test--shown ()
  "The bytes of the frame the Live view shows, or nil."
  (with-current-buffer "*drgnx live*"
    (let ((img (get-text-property (point-min) 'display)))
      (and (eq (car-safe img) 'image) (plist-get (cdr img) :data)))))

(defun drgnx-live-test--acks ()
  "The frame numbers the view acknowledged, on which flat session: ((SESSION . N)…)."
  (mapcar (lambda (m) (cons (plist-get m :sessionId) (plist-get (plist-get m :params) :sessionId)))
          (drgnx-mock-cdp-received "Page.screencastFrameAck")))

(defun drgnx-live-test--open ()
  "Open the Live view on the mock and wait until it screencasts."
  (drgnx-live-view)
  (should (drgnx-mock-cdp-wait (lambda () (drgnx-mock-cdp-received "Page.startScreencast")))))

(defun drgnx-live-test--event (type x y w h)
  "A mouse event TYPE at X,Y on the Live view's image, shown W×H pixels."
  (let ((win (get-buffer-window "*drgnx live*")))
    (list type (list win 1 (cons x y) 0 nil 1 '(0 . 0) (with-current-buffer "*drgnx live*" (get-text-property 1 'display))
                     (cons x y) (cons w h)))))

(defun drgnx-live-test--input (method)
  (mapcar (lambda (m) (plist-get m :params)) (drgnx-mock-cdp-received method)))

(ert-deftest drgnx-live/frames-are-shown-and-acked ()
  (skip-unless drgnx-live-test--websocket)
  (drgnx-live-test--with
    (drgnx-live-test--open)
    ;; the first page target is watched: jpeg, quality 60, as wide as the window
    (let* ((start (car (drgnx-mock-cdp-received "Page.startScreencast"))) (params (plist-get start :params)))
      (should (equal (plist-get start :sessionId) "S-T1"))
      (should (equal (plist-get params :format) "jpeg"))
      (should (= 60 (plist-get params :quality)))
      (should (= (plist-get params :maxWidth) (window-body-width (get-buffer-window "*drgnx live*") t))))
    (drgnx-mock-cdp-frame 1)
    (should (drgnx-mock-cdp-wait (lambda () (equal (drgnx-live-test--shown) "frame-1"))))
    (drgnx-mock-cdp-frame 2)
    (should (drgnx-mock-cdp-wait (lambda () (equal (drgnx-live-test--shown) "frame-2"))))
    (should (equal (drgnx-live-test--acks) '(("S-T1" . 1) ("S-T1" . 2))))
    ;; the header: the tabs (pages only) and the watched page's URL
    (with-current-buffer "*drgnx live*"
      (let ((h (substring-no-properties (drgnx-live--header))))
        (dolist (want '("Example" "Docs" "https://example.org/")) (should (string-search want h)))
        (should-not (string-search "sw.js" h))))
    ;; a new tab is followed, its URL shown; an old frame's session stops counting
    (drgnx-mock-cdp-event "Target.targetCreated" '(:targetInfo (:targetId "T3" :type "page" :title "New" :url "https://new.example/")))
    (should (drgnx-mock-cdp-wait (lambda () (seq-some (lambda (m) (equal (plist-get m :sessionId) "S-T3"))
                                                      (drgnx-mock-cdp-received "Page.startScreencast")))))
    (with-current-buffer "*drgnx live*"
      (should (string-search "https://new.example/" (substring-no-properties (drgnx-live--header)))))))

(ert-deftest drgnx-live/busy-drops-frames ()
  (skip-unless drgnx-live-test--websocket)
  (drgnx-live-test--with
    (let ((drgnx-live-frame-interval 0.5))
      (drgnx-live-test--open)
      (drgnx-mock-cdp-frame 1)
      (should (drgnx-mock-cdp-wait (lambda () (equal (drgnx-live-test--shown) "frame-1"))))
      ;; five frames while the next draw is pending: every one is acknowledged, only the last is drawn
      (dotimes (i 5) (drgnx-mock-cdp-frame (+ 2 i)))
      (should (drgnx-mock-cdp-wait (lambda () (= 6 (length (drgnx-live-test--acks))))))
      (should (drgnx-mock-cdp-wait (lambda () (equal (drgnx-live-test--shown) "frame-6"))))
      (should (equal (mapcar #'cdr (drgnx-live-test--acks)) '(1 2 3 4 5 6)))
      (with-current-buffer "*drgnx live*"
        (should (= 2 drgnx-live--drawn))
        (should (= 4 drgnx-live--dropped))))))

(ert-deftest drgnx-live/take-over-sends-input-scaled ()
  (skip-unless drgnx-live-test--websocket)
  (drgnx-live-test--with
    (let* ((busy (drgnx-agents--make :name "busy" :profile "claude" :status 'busy))
           (idle (drgnx-agents--make :name "idle" :profile "claude" :status 'idle))
           (steered nil))
      (setq drgnx-agents--sessions (list busy idle))
      (drgnx-agents--env busy) (drgnx-agents--env idle)  ; both get the endpoint
      (cl-letf (((symbol-function 'drgnx-agents-steer)
                 (lambda (s text) (push (list (drgnx-agent-session-name s) text) steered))))
        (drgnx-live-test--open)
        (drgnx-mock-cdp-frame 1 :width 1280 :height 800)
        (should (drgnx-mock-cdp-wait (lambda () (drgnx-live-test--shown))))
        (with-current-buffer "*drgnx live*"
          ;; not driving: the page gets nothing
          (drgnx-live-mouse (drgnx-live-test--event 'down-mouse-1 100 50 640 400))
          (should-not (drgnx-mock-cdp-received "Input.dispatchMouseEvent"))
          (should-not (eq (key-binding "a") #'drgnx-live-key))
          (drgnx-live-take-over)
          (should (equal steered '(("busy" "the user is driving the browser; wait"))))
          (should (string-search "DRIVING" (substring-no-properties (drgnx-live--header))))
          (should (eq (key-binding "a") #'drgnx-live-key))
          (should (eq (key-binding [down-mouse-1]) #'drgnx-live-mouse))
          ;; a click on the image shown at half size lands at twice the coordinates
          (drgnx-live-mouse (drgnx-live-test--event 'down-mouse-1 100 50 640 400))
          (drgnx-live-mouse (drgnx-live-test--event 'mouse-1 100 50 640 400))
          (drgnx-live-mouse (drgnx-live-test--event 'wheel-down 100 50 640 400))
          (let ((last-command-event ?a)) (drgnx-live-key))
          (let ((last-command-event 13)) (drgnx-live-key)))
        (should (drgnx-mock-cdp-wait (lambda () (= 4 (length (drgnx-mock-cdp-received "Input.dispatchKeyEvent"))))))
        (should (drgnx-mock-cdp-wait (lambda () (= 3 (length (drgnx-mock-cdp-received "Input.dispatchMouseEvent"))))))
        (let ((mouse (drgnx-live-test--input "Input.dispatchMouseEvent")))
          (should (equal (mapcar (lambda (p) (list (plist-get p :type) (plist-get p :x) (plist-get p :y))) mouse)
                         '(("mousePressed" 200 100) ("mouseReleased" 200 100) ("mouseWheel" 200 100))))
          (should (equal (plist-get (car mouse) :button) "left"))
          (should (= 1 (plist-get (car mouse) :clickCount)))
          (should (> (plist-get (nth 2 mouse) :deltaY) 0)))
        (let ((keys (drgnx-live-test--input "Input.dispatchKeyEvent")))
          (should (equal (mapcar (lambda (p) (list (plist-get p :type) (plist-get p :key))) keys)
                         '(("keyDown" "a") ("keyUp" "a") ("keyDown" "Enter") ("keyUp" "Enter"))))
          (should (equal (plist-get (car keys) :text) "a"))
          (should (= 13 (plist-get (nth 2 keys) :windowsVirtualKeyCode))))
        ;; handing back: the agent is told, the keys are Emacs's again, input stops
        (with-current-buffer "*drgnx live*"
          (drgnx-live-take-over)
          (should (equal (car steered) '("busy" "the user handed the browser back")))
          (should-not (string-search "DRIVING" (substring-no-properties (drgnx-live--header))))
          (should-not (eq (key-binding "a") #'drgnx-live-key))
          (drgnx-live-mouse (drgnx-live-test--event 'down-mouse-1 10 10 640 400)))
        (accept-process-output nil 0.1)
        (should (= 3 (length (drgnx-mock-cdp-received "Input.dispatchMouseEvent"))))
        (should (= 2 (length steered)))))))

(ert-deftest drgnx-live/agents-get-the-endpoint ()
  (let* ((root (make-temp-file "drgnx-live" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" root) process-environment))
         (drgnx-live--browser nil) (drgnx-live--given nil) (drgnx-live-chrome-programs '("sh"))
         (dir (expand-file-name (format "drgnx/live-profile-%d" (emacs-pid)) root))
         (starts nil) (stopped nil) (status 'running)
         ;; the "browser": a child process its lock names, which stopping the job ends
         (chrome (make-process :name "drgnx-live-test-chrome" :command '("sleep" "60") :noquery t))
         (s (drgnx-agents--make :name "a" :profile "claude")))
    (cl-letf (((symbol-function 'drgnx-jobs-start)
               (lambda (name command &rest keys)
                 (push (list name command keys) starts)
                 ;; the browser writes its port where its profile is
                 (let ((d (substring (seq-find (lambda (a) (string-prefix-p "--user-data-dir=" a)) command) 16)))
                   (write-region "9555\n/devtools/browser/abc\n" nil (expand-file-name "DevToolsActivePort" d) nil 'silent))
                 "job-1"))
              ((symbol-function 'drgnx-jobs-get) (lambda (id) (and (equal id "job-1") (list :id id :status status))))
              ((symbol-function 'drgnx-jobs-stop) (lambda (id) (push id stopped) (setq status 'stopped) (delete-process chrome))))
      (unwind-protect
          (let ((drgnx-agents-env-functions nil)
                (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
            (drgnx-live--setup)
            (should (memq #'drgnx-live--agent-env drgnx-agents-env-functions))
            (dolist (c '(live-start-browser live-stop-browser live-view live-take-over)) (should (drgnx-commands-get c)))
            ;; no browser yet: nothing extra
            (should-not (seq-find (lambda (e) (string-prefix-p "PLAYWRIGHT_MCP_CDP_ENDPOINT=" e)) (drgnx-agents--env s)))
            ;; Live: Start Browser for Agents starts Chrome once, headless, on 127.0.0.1, a throwaway profile, capped
            (drgnx-live-start-browser)
            (should (equal (drgnx-live-browser) '(:port 9555 :ws "ws://127.0.0.1:9555/devtools/browser/abc")))
            (should (= 1 (length starts)))
            (pcase-let ((`(,name ,command ,keys) (car starts)))
              (should (equal name "live-browser"))
              (should (equal (car command) (executable-find "sh")))
              (dolist (flag (list "--headless=new" "--remote-debugging-address=127.0.0.1" "--remote-debugging-port=0"
                                  (concat "--user-data-dir=" dir) "--no-first-run"))
                (should (member flag command)))
              (should (equal (plist-get keys :memory-max) "1G")))
            (should (member "PLAYWRIGHT_MCP_CDP_ENDPOINT=http://127.0.0.1:9555" (drgnx-agents--env s)))
            (should (memq s drgnx-live--given))
            ;; a job that reads as gone (systemd's) runs as long as the browser's own lock names a live process
            (setq status 'gone)
            (should-not (drgnx-live-running))
            (make-symbolic-link (format "testhost-%d" (process-id chrome)) (expand-file-name "SingletonLock" dir))
            (should (equal (plist-get (drgnx-live-running) :port) 9555))
            (should (member "PLAYWRIGHT_MCP_CDP_ENDPOINT=http://127.0.0.1:9555" (drgnx-agents--env s)))
            (should (= 1 (length starts)))
            ;; stopping it: the job ends, the profile goes once the browser has exited (not after the 3 s cap),
            ;; agents started now get no endpoint
            (let ((t0 (float-time)))
              (drgnx-live-stop-browser)
              (should (< (- (float-time) t0) 1)))
            (should-not (process-live-p chrome))
            (should (equal stopped '("job-1")))
            (should-not (file-exists-p dir))
            (should-not (seq-find (lambda (e) (string-prefix-p "PLAYWRIGHT_MCP_CDP_ENDPOINT=" e)) (drgnx-agents--env s))))
        (remove-hook 'kill-emacs-hook #'drgnx-live--cleanup)
        (delete-process chrome)
        (delete-directory root t)))))

(ert-deftest drgnx-live/failures-say-why ()
  ;; no Chrome: a user error that names it, and nothing is started
  (let ((drgnx-live--browser nil) (drgnx-live-chrome-programs '("drgnx-no-such-chrome")) (started nil))
    (cl-letf (((symbol-function 'drgnx-jobs-start) (lambda (&rest _) (setq started t) "x")))
      (let ((err (should-error (drgnx-live-browser) :type 'user-error)))
        (should (string-match-p "no Chrome or Chromium" (cadr err))))
      (should-not started)))
  ;; Chrome that exits at once: its log says why, without waiting out the timeout
  (let* ((root (make-temp-file "drgnx-live" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" root) process-environment))
         (drgnx-live--browser nil) (drgnx-live-chrome-programs '("sh")) (drgnx-live-start-timeout 5) (t0 (float-time)))
    (cl-letf (((symbol-function 'drgnx-jobs-start) (lambda (&rest _) "job-2"))
              ((symbol-function 'drgnx-jobs-get) (lambda (id) (list :id id :status 'exited :exit 1)))
              ((symbol-function 'drgnx-jobs-log) (lambda (&rest _) "Missing X server or $DISPLAY\n")))
      (unwind-protect
          (let ((err (should-error (drgnx-live-browser) :type 'user-error)))
            (should (string-match-p "exited" (cadr err)))
            (should (string-match-p "Missing X server" (cadr err)))
            (should (< (- (float-time) t0) 2)))
        (delete-directory root t))))
  (skip-unless drgnx-live-test--websocket)
  ;; a refused port: the view says so at once, never hangs
  (drgnx-live-test--with
    (let ((port (drgnx-mock-cdp-start)) (t0 (float-time)))
      (drgnx-mock-cdp-stop)                           ; nothing listens there now
      (setq drgnx-live--browser (list :port port :ws (format "ws://127.0.0.1:%d/devtools/browser/x" port) :job "job-live"))
      (drgnx-live-view)
      (should (< (- (float-time) t0) 2))
      (with-current-buffer "*drgnx live*"
        (should (string-match-p (format "127\\.0\\.0\\.1:%d refused" port) (buffer-string))))))
  ;; agents that do not use the browser: started before it, or their Playwright went elsewhere
  (drgnx-live-test--with
    (let ((early (drgnx-agents--make :name "early" :profile "claude" :status 'idle))
          (late (drgnx-agents--make :name "late" :profile "claude" :status 'idle))
          (fine (drgnx-agents--make :name "fine" :profile "claude" :status 'idle)))
      (setq drgnx-agents--sessions (list early late fine))
      (drgnx-agents--env late) (drgnx-agents--env fine)
      (setf (drgnx-agent-session-entries late)
            (list (list :type 'tool :title "browser_navigate" :url "https://elsewhere.test/")))
      (setf (drgnx-agent-session-entries fine)
            (list (list :type 'tool :title "browser_navigate" :url "https://example.org")))
      (drgnx-live-test--open)
      (with-current-buffer "*drgnx live*"
        (should (drgnx-mock-cdp-wait (lambda () (string-search "early" (buffer-string)))))
        (let ((text (buffer-string)))
          (should (string-match-p "early[^\n]*started before" text))
          (should (string-match-p "late[^\n]*https://elsewhere\\.test/" text))
          (should-not (string-search "fine" text)))))))

;;;; Fix round 1

(defun drgnx-live-test--posn (x y w h)
  "A position X,Y on the Live view's image, shown W×H pixels."
  (list (get-buffer-window "*drgnx live*") 1 (cons x y) 0 nil 1 '(0 . 0)
        (with-current-buffer "*drgnx live*" (get-text-property 1 'display)) (cons x y) (cons w h)))

(defmacro drgnx-live-test--driving (steered &rest body)
  "BODY in the Live view on the mock, a frame of 1280×800 shown, with a busy agent using the browser; agent steers
are pushed to STEERED as (NAME TEXT)."
  (declare (indent 1))
  `(let ((busy (drgnx-agents--make :name "busy" :profile "claude" :status 'busy)))
     (setq drgnx-agents--sessions (list busy))
     (drgnx-agents--env busy)
     (cl-letf (((symbol-function 'drgnx-agents-steer)
                (lambda (s text) (push (list (drgnx-agent-session-name s) text) ,steered))))
       (drgnx-live-test--open)
       (drgnx-mock-cdp-frame 1 :width 1280 :height 800)
       (should (drgnx-mock-cdp-wait (lambda () (drgnx-live-test--shown))))
       ,@body)))

(ert-deftest drgnx-live/attaches-once ()
  ;; Chrome announces every existing page (targetCreated) when discovery starts: the view still attaches once
  (skip-unless drgnx-live-test--websocket)
  (drgnx-live-test--with
    (drgnx-live-test--open)
    (drgnx-mock-cdp-wait #'ignore 0.3)
    (should (equal (mapcar (lambda (m) (plist-get (plist-get m :params) :targetId)) (drgnx-mock-cdp-received "Target.attachToTarget"))
                   '("T1")))
    (should (= 1 (length (drgnx-mock-cdp-received "Page.startScreencast"))))
    (with-current-buffer "*drgnx live*"
      (should (equal (mapcar (lambda (tg) (plist-get tg :targetId)) drgnx-live--targets) '("T1" "T2"))))))

(ert-deftest drgnx-live/drag-moves-then-releases-at-the-end ()
  (skip-unless drgnx-live-test--websocket)
  (drgnx-live-test--with
    (let (steered)
      (drgnx-live-test--driving steered
        (with-current-buffer "*drgnx live*"
          (drgnx-live-take-over)
          (drgnx-live-mouse (list 'down-mouse-1 (drgnx-live-test--posn 100 50 640 400)))
          (drgnx-live-mouse (list 'drag-mouse-1 (drgnx-live-test--posn 100 50 640 400) (drgnx-live-test--posn 300 150 640 400))))
        (should (drgnx-mock-cdp-wait (lambda () (= 3 (length (drgnx-mock-cdp-received "Input.dispatchMouseEvent"))))))
        (should (equal (mapcar (lambda (p) (list (plist-get p :type) (plist-get p :x) (plist-get p :y)))
                               (drgnx-live-test--input "Input.dispatchMouseEvent"))
                       '(("mousePressed" 200 100) ("mouseMoved" 600 300) ("mouseReleased" 600 300))))
        (should (equal (plist-get (nth 1 (drgnx-live-test--input "Input.dispatchMouseEvent")) :button) "left"))))))

(ert-deftest drgnx-live/hand-back-is-always-said ()
  ;; driving ends by closing the view, or by stopping the browser: the agent hears it either way
  (skip-unless drgnx-live-test--websocket)
  (drgnx-live-test--with
    (let (steered)
      (drgnx-live-test--driving steered
        (with-current-buffer "*drgnx live*" (drgnx-live-take-over))
        (kill-buffer "*drgnx live*")
        (should (equal (car steered) '("busy" "the user handed the browser back")))
        (setq steered nil)
        (drgnx-live-test--open)
        (with-current-buffer "*drgnx live*" (drgnx-live-take-over))
        (cl-letf (((symbol-function 'drgnx-jobs-stop) #'ignore))
          (drgnx-live-stop-browser))
        (should (equal steered '(("busy" "the user handed the browser back") ("busy" "the user is driving the browser; wait"))))
        (with-current-buffer "*drgnx live*" (should-not drgnx-live-driving-mode))))))

(ert-deftest drgnx-live/quit-while-starting-leaks-nothing ()
  ;; C-g during the wait for the port: the browser is stopped and its profile goes, then the quit goes on
  (let* ((root (make-temp-file "drgnx-live" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" root) process-environment))
         (drgnx-live--browser nil) (drgnx-live-chrome-programs '("sh")) (stopped nil)
         (dir (expand-file-name (format "drgnx/live-profile-%d" (emacs-pid)) root)))
    (cl-letf (((symbol-function 'drgnx-jobs-start) (lambda (&rest _) "job-q"))
              ((symbol-function 'drgnx-jobs-get) (lambda (id) (list :id id :status (if (member id stopped) 'stopped 'running))))
              ((symbol-function 'drgnx-jobs-stop) (lambda (id) (push id stopped)))
              ((symbol-function 'sleep-for) (lambda (&rest _) (signal 'quit nil))))
      (unwind-protect
          (progn
            (should (eq 'quit (condition-case nil (progn (drgnx-live-browser) 'returned) (quit 'quit))))
            (should (equal stopped '("job-q")))
            (should-not (file-exists-p dir))
            (should-not drgnx-live--browser))
        (delete-directory root t)))))

(ert-deftest drgnx-live/stopping-never-waits-on-systemd ()
  ;; the unit is asked to stop without waiting for it (an exit never sits out systemd's stop timeout)
  (let (calls)
    (cl-letf (((symbol-function 'drgnx-jobs-get) (lambda (id) (list :id id :status 'gone :unit "drgnx-job-x")))
              ((symbol-function 'drgnx-jobs-stop) #'ignore)
              ((symbol-function 'call-process) (lambda (prog &rest args) (push (cons prog args) calls) 0)))
      (drgnx-live--stop-job "x"))
    (should (equal calls '(("systemctl" nil nil nil "--user" "--no-block" "stop" "drgnx-job-x"))))))

(ert-deftest drgnx-live/watch-needs-websocket-before-chrome ()
  (let ((drgnx-live--browser nil) (drgnx-live-chrome-programs '("sh")) (started nil) (orig (symbol-function 'require)))
    (cl-letf (((symbol-function 'drgnx-jobs-start) (lambda (&rest _) (setq started t) "x"))
              ((symbol-function 'require)
               (lambda (feature &rest args)
                 (if (eq feature 'websocket) (signal 'file-missing '("Cannot open load file" "No such file or directory" "websocket"))
                   (apply orig feature args)))))
      (let ((err (should-error (drgnx-live-view) :type 'user-error)))
        (should (string-match-p "websocket" (cadr err))))
      (should-not started))))

(ert-deftest drgnx-live/hidden-view-stops-the-screencast ()
  ;; a view nobody sees costs nothing: the screencast stops, and starts again when the view is shown
  (skip-unless drgnx-live-test--websocket)
  (drgnx-live-test--with
    (drgnx-live-test--open)
    (drgnx-mock-cdp-frame 1)
    (should (drgnx-mock-cdp-wait (lambda () (drgnx-live-test--shown))))
    (let ((win (get-buffer-window "*drgnx live*")))
      (set-window-buffer win (get-buffer-create "*scratch*"))
      (drgnx-mock-cdp-frame 2)
      (should (drgnx-mock-cdp-wait (lambda () (drgnx-mock-cdp-received "Page.stopScreencast"))))
      (should (equal (drgnx-live-test--shown) "frame-1"))
      (set-window-buffer win "*drgnx live*")
      (with-current-buffer "*drgnx live*" (run-hook-with-args 'window-buffer-change-functions win))
      (should (drgnx-mock-cdp-wait (lambda () (= 2 (length (drgnx-mock-cdp-received "Page.startScreencast")))))))))

;;; mod-live-test.el ends here
