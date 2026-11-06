;;; work-space-test.el --- the Work space module against a real hub: subscribe, deltas, hidden maps, keys -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The hub runs as its own process; this Emacs plays the editor inside the delivery gate (`drgnx-test-gated').  The
;; agents behind the map are real children (mock-acp): what they did is a condition the test settles on after each
;; release of the hub's lines (the helpers of agents-mirror-test.el), never a deadline.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-keys)
(require 'drgnx-hub-client)
(require 'drgnx-work-client)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/unit/agents-mirror-test" drgnx-dir) nil t)   ; its helpers and the hub fixtures
(load (expand-file-name "test/fixtures/work-space-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(declare-function drgnx-work-space-open "drgnx-work-space")
(declare-function drgnx-work-space-sync-shown "drgnx-work-space")
(defvar drgnx-work-space-command-ids)
(defvar drgnx-work-map--outline)

(defmacro drgnx-work-space-test--with (&rest body)
  "BODY with the module `tools/work-space' set up, a gated hub serving the test's dirs (profile \"mock\"), and
`workspace' the workspace of the test's home folder.  The modules come first so the hub and this Emacs share their
directories."
  (declare (indent 0))
  ;; the clock is entered first, so the timers the modules' setups arm (the bus's idle flush) are on its lists and the
  ;; clock's end drops them; entered after them, the gate's clock would leave them in the real list
  `(drgnx-test-with-clock (:allow-pending t)
     (drgnx-test-with-modules '(tools/work-space)
       (drgnx-agents-mirror-test--with '()
         ;; the hub fixture binds the client's event and disconnect hooks to nil: the module's functions go on again
         (add-hook 'drgnx-hub-event-functions #'drgnx-work-client-event)
         (add-hook 'drgnx-hub-disconnect-functions #'drgnx-work-client-disconnected)
         ;; the map's events come back on the subscribed connection: this Emacs has one before a map opens
         (drgnx-hub-connect)
         (drgnx-agents-mirror-test--settle (lambda () (process-live-p drgnx-hub--events)) "the subscribed connection")
         (let ((workspace (list :id "workspace:000000000001" :roots (list (getenv "HOME")))))
           ,@body)))))

(defun drgnx-work-space-test--start-agent ()
  "A session of the mock profile in the workspace's folder; its id."
  (plist-get (drgnx-agents-mirror-test--ask "agents/start" (list :profile "mock" :cwd (getenv "HOME"))) :id))

(defun drgnx-work-space-test--state (buffer)
  (drgnx-work-client-view-state (buffer-local-value 'drgnx-work-space--view buffer)))

(ert-deftest drgnx-work-space/subscribes-and-draws-a-frame ()
  (drgnx-work-space-test--with
    (let* ((id (drgnx-work-space-test--start-agent)) (buf (drgnx-work-space-open workspace)))
      (drgnx-agents-mirror-test--settle
       (lambda () (let ((s (drgnx-work-space-test--state buf)))
                    (and (drgnx-work-client-live-p s) (drgnx-work-client-item s (concat "agent:" id)))))
       "the map's frame holds the agent")
      ;; a batch Emacs has no graphic frame, so the map shows its outline; the rows are asked for
      (with-current-buffer buf (setq drgnx-work-map--outline 'off) (drgnx-view-touch drgnx-view) (drgnx-view-draw-now drgnx-view))
      (let ((text (with-current-buffer buf (buffer-string))))
        (should (string-search "Agents" text))
        (should (string-search "mock" text))
        (should (string-search "Files" text)))
      (should (eq 'drgnx-work-map-mode (buffer-local-value 'major-mode buf))))))

(ert-deftest drgnx-work-space/hidden-map-draws-and-receives-nothing ()
  ;; a map no window shows draws no row and gets no delta (the hidden-cost budget row)
  (drgnx-work-space-test--with
    (let* ((buf (drgnx-work-space-open workspace t)) (view (buffer-local-value 'drgnx-work-space--view buf)))
      (drgnx-agents-mirror-test--settle (lambda () (drgnx-work-client-live-p (drgnx-work-space-test--state buf)))
                                        "the map's first frame")
      (with-current-buffer buf (drgnx-view-draw-now drgnx-view))
      (let ((window (get-buffer-window buf t)))
        (should-not window))                              ; no window ever showed it: it is hidden
      (drgnx-work-space-sync-shown)                     ; what the store's window events call
      (drgnx-agents-mirror-test--settle (lambda () (not (drgnx-work-client-shown-p view))) "the hub told: hidden")
      (let ((rows (plist-get (drgnx-view-stats (buffer-local-value 'drgnx-view buf)) :rows-drawn))
            (events (drgnx-work-client-counter view :events)))
        (drgnx-work-space-test--start-agent)
        (drgnx-agents-mirror-test--settle (lambda () (drgnx-agents-mirror-test--ask "ping" nil) t) "the hub took the start")
        (drgnx-test-hub-advance 200)
        (should (= rows (plist-get (drgnx-view-stats (buffer-local-value 'drgnx-view buf)) :rows-drawn)))
        (should (= 0 (drgnx-work-client-counter view :deltas)))
        ;; one stale mark may arrive; no frame, no delta
        (should (<= (- (drgnx-work-client-counter view :events) events) 1))))))

(ert-deftest drgnx-work-space/resubscribes-after-a-hub-restart ()
  ;; the hub client core's `connected' effect re-subscribes every view; the view shows "reconnecting" meanwhile and
  ;; keeps its frame
  (drgnx-work-space-test--with
    (let* ((buf (drgnx-work-space-open workspace)) (view (buffer-local-value 'drgnx-work-space--view buf)))
      (drgnx-agents-mirror-test--settle (lambda () (drgnx-work-client-live-p (drgnx-work-space-test--state buf))) "the first frame")
      (let ((id (drgnx-work-space-test--start-agent)) (version (drgnx-work-client-version (drgnx-work-space-test--state buf))))
        (run-hooks 'drgnx-hub-disconnect-functions)
        (should-not (drgnx-work-client-live-p (drgnx-work-space-test--state buf)))
        (should (equal "reconnecting" (drgnx-work-client-status view)))
        (should (drgnx-work-client-version (drgnx-work-space-test--state buf)))   ; the frame is kept
        (run-hooks 'drgnx-hub-connected-functions)
        (drgnx-agents-mirror-test--settle
         (lambda () (let ((s (drgnx-work-space-test--state buf)))
                      (and (drgnx-work-client-live-p s) (drgnx-work-client-item s (concat "agent:" id)))))
         "the frame of the new subscription, holding what happened meanwhile")
        (should (integerp version))))))

(ert-deftest drgnx-work-space/module-off-closes-views-and-kills-buffers ()
  (let (calls name)
    (cl-letf (((symbol-function 'drgnx-work-client--call)
               (lambda (method params &rest _) (push (cons method params) calls) t)))
      (drgnx-test-with-modules '(tools/work-space) :strict t
                               (setq name (buffer-name (drgnx-work-space-open (list :id "workspace:000000000002" :roots (list temporary-file-directory)))))
                               (should (get-buffer name))
                               (should (assoc "work/map/subscribe" calls))))
    (should-not (get-buffer name))
    (should (assoc "work/map/close" calls))
    (should-not (drgnx-work-client-views))))

;;;; Selection, filters, search and Esc against a real hub

(defvar drgnx-work-space-test--calls nil "The hub methods (and params) called since the last reset, newest first.")

(defun drgnx-work-space-test--record (method params &rest _)
  (push (cons method params) drgnx-work-space-test--calls))

(defmacro drgnx-work-space-test--recording (&rest body)
  "BODY with every call the map client makes of the hub recorded in `drgnx-work-space-test--calls'."
  (declare (indent 0))
  `(progn (setq drgnx-work-space-test--calls nil)
          (advice-add 'drgnx-work-client--call :before #'drgnx-work-space-test--record)
          (unwind-protect (progn ,@body) (advice-remove 'drgnx-work-client--call #'drgnx-work-space-test--record))))

(defun drgnx-work-space-test--map-ready (buf n)
  "Settle until BUF's map holds N agents in a live frame."
  (drgnx-agents-mirror-test--settle
   (lambda () (let ((s (drgnx-work-space-test--state buf)))
                (and (drgnx-work-client-live-p s)
                     (>= (cl-count-if (lambda (id) (string-prefix-p "agent:" id)) (drgnx-work-client-ids s)) n))))
   (format "the map holds %d agents" n)))

(ert-deftest drgnx-work-space/jumping-never-settles-a-card ()
  ;; a card about a real agent in the map's frame is a needs-you chip; its jump key selects the agent and decides
  ;; nothing: the editor makes no call that answers, allows or denies, and the card stays
  (drgnx-work-space-test--with
    (let* ((buf (drgnx-work-space-open workspace t)) (id (drgnx-work-space-test--start-agent))
           (item-id (concat "agent:" id)))
      (drgnx-work-space-test--map-ready buf 1)
      (let* ((state (drgnx-work-space-test--state buf)) (v (drgnx-work-client-version state))
             (view (buffer-local-value 'drgnx-work-space--view buf)))
        ;; the hub's next delta, as it sends one when a permission is asked: the agent needs you, and a card says so
        (drgnx-work-client-event
         "work-map"
         (list :view view :version (1+ v) :base v
               :changed (list (plist-put (copy-sequence (drgnx-work-client-item state item-id)) :needs_you t))
               :needs_you (list (list :card "card:1" :kind "permission" :text "Mock asks to edit" :about (list item-id)))))
        (should (equal 1 (length (drgnx-work-client-needs-you (drgnx-work-space-test--state buf)))))
        (drgnx-work-space-test--recording
          (with-current-buffer buf (drgnx-work-map-needs-you 1))
          (should (equal (cons 'agent item-id) (buffer-local-value 'drgnx-work-map--selection buf)))
          (drgnx-test-hub-advance 200)
          (should-not (seq-some (lambda (c) (string-match-p "permission\\|answer\\|allow\\|deny\\|card" (car c)))
                                drgnx-work-space-test--calls))
          (should (equal 1 (length (drgnx-work-client-needs-you (drgnx-work-space-test--state buf))))))))))

(ert-deftest drgnx-work-space/enter-on-a-runner-opens-its-queue ()
  ;; pattern B: a machine of the frame that is a runner, with an agent whose job runs on it; Enter on the machine opens
  ;; the side panel, and the panel holds the queue: the job's runner, state, the keys sent and its time
  (drgnx-work-space-test--with
    (let* ((buf (drgnx-work-space-open workspace t)) (id (drgnx-work-space-test--start-agent))
           (item-id (concat "agent:" id)) (machine "machine:local"))
      (drgnx-work-space-test--map-ready buf 1)
      (let* ((state (drgnx-work-space-test--state buf)) (v (drgnx-work-client-version state))
             (view (buffer-local-value 'drgnx-work-space--view buf))
             (agent (copy-sequence (drgnx-work-client-item state item-id)))
             (box (copy-sequence (drgnx-work-client-item state machine))))
        (drgnx-work-client-event
         "work-map"
         (list :view view :version (1+ v) :base v
               :changed (list (plist-put box :fields (list :slots '(1 4) :runner (list :trust "mine" :state "ready" :jobs 1
                                                                                       :icon "server")))
                              (plist-put agent :fields
                                         (plist-put (copy-sequence (plist-get agent :fields)) :job
                                                    (list :id "x1" :name "suite" :runner "local" :state "running"
                                                          :started 100.0 :limit_min 6 :keys (list "token")))))))
        (with-current-buffer buf (drgnx-work-map-select (cons 'machine machine)))
        (let ((shown nil))
          (cl-letf (((symbol-function 'drgnx-pane-show) (lambda (kind &rest _) (push kind shown))))
            (with-current-buffer buf (drgnx-work-map-open-selection)))
          (should (equal '(work-detail) shown)))
        (let ((queue (cdr (assq :queue (drgnx-work-detail-sections (drgnx-work-space-test--state buf)
                                                                   (cons 'machine machine))))))
          (should (string-search "suite" queue))
          (should (string-search "local" queue))
          (should (string-search "running" queue))
          (should (string-search "keys: token" queue))
          (should (string-search "l live log" queue)))))))

(ert-deftest drgnx-work-space/focus-arrows-send-no-relayout ()
  (drgnx-work-space-test--with
    (let* ((buf (drgnx-work-space-open workspace t)) (a (drgnx-work-space-test--start-agent)))
      (drgnx-work-space-test--start-agent)
      (drgnx-work-space-test--map-ready buf 2)
      (with-current-buffer buf
        (drgnx-work-map-select (cons 'agent (concat "agent:" a)))
        (drgnx-work-map-focus))
      (let ((view (buffer-local-value 'drgnx-work-space--view buf)))
        (drgnx-agents-mirror-test--settle
         (lambda () (< (cl-count-if (lambda (id) (string-prefix-p "agent:" id))
                                    (drgnx-work-client-ids (drgnx-work-space-test--state buf)))
                       2))
         "the focused frame holds only the chain")
        (let ((frames (drgnx-work-client-counter view :frames)))
          (drgnx-work-space-test--recording
            (with-current-buffer buf
              (dolist (move '(drgnx-work-map-touches drgnx-work-map-why drgnx-work-map-right drgnx-work-map-left
                                                     drgnx-work-map-touches drgnx-work-map-why))
                (funcall move)))
            (drgnx-test-hub-advance 300)
            (should-not (seq-some (lambda (c) (and (equal (car c) "work/map/set")
                                                   (or (plist-member (cdr c) :filters) (plist-member (cdr c) :collapsed)
                                                       (plist-member (cdr c) :width_units))))
                                  drgnx-work-space-test--calls))
            (should (= frames (drgnx-work-client-counter view :frames)))))))))

(ert-deftest drgnx-work-space/collapse-and-expand ()
  (drgnx-work-space-test--with
    (let ((buf (drgnx-work-space-open workspace t)))
      (drgnx-work-space-test--start-agent)
      (drgnx-work-space-test--map-ready buf 1)
      (let ((collapsed-p (lambda (layer)
                           (seq-some (lambda (r) (and (eql layer (plist-get r :layer)) (plist-get r :collapsed)))
                                     (plist-get (drgnx-work-client-layout (drgnx-work-space-test--state buf)) :rows)))))
        (should-not (funcall collapsed-p 4))
        (with-current-buffer buf (drgnx-work-map-collapse-layer 4))
        (drgnx-agents-mirror-test--settle (lambda () (funcall collapsed-p 4)) "layer 4 is one thin row")
        (with-current-buffer buf (drgnx-work-map-expand-layers))
        (drgnx-agents-mirror-test--settle (lambda () (not (funcall collapsed-p 4))) "layer 4 is back")))))

(ert-deftest drgnx-work-space/escape-clears-search-then-filters ()
  (drgnx-work-space-test--with
    (let ((buf (drgnx-work-space-open workspace t)) (closed 0))
      (drgnx-work-space-test--start-agent)
      (drgnx-work-space-test--map-ready buf 1)
      (cl-letf (((symbol-function 'drgnx-close-pane) (lambda () (cl-incf closed))))
        (with-current-buffer buf
          (drgnx-work-map-overlaps)
          (drgnx-work-map--set-search "mock")
          (should (plist-get drgnx-work-map--filters :overlaps))
          (drgnx-work-map-escape)                                   ; the search first
          (should-not drgnx-work-map--search)
          (should (plist-get drgnx-work-map--filters :overlaps))
          (drgnx-work-map-escape)                                   ; then the filters
          (should-not (plist-get drgnx-work-map--filters :overlaps))
          (should (= 0 closed))
          (drgnx-work-map-escape)                                   ; then the pane
          (should (= 1 closed)))))))

(defun drgnx-work-space-test--bound-ids (profile)
  "The command ids PROFILE (an alist entry of the loaded profiles) has a row for."
  (mapcar #'car (plist-get (cdr profile) :bind)))

(ert-deftest drgnx-work-space/keys-in-every-profile ()
  ;; every command of the module has a row in each shipped profile, and none of its keys meets another command's
  (let ((profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))))
    (should (equal '(emacs vim vscode) (sort (mapcar #'car profiles) (lambda (a b) (string< (symbol-name a) (symbol-name b))))))
    (drgnx-test-with-modules '(tools/work-space)
      (dolist (p profiles)
        (dolist (id drgnx-work-space-command-ids)
          (should (equal (list (car p) id t) (list (car p) id (and (memq id (drgnx-work-space-test--bound-ids p)) t)))))
        (let* ((r (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles profiles
                                      :layers (list (list (car p) 'app 'editing 'window))
                                      :defaults (copy-keymap global-map)))
               ;; two commands on one key (a prefix clash of C-k t is the profile's own, older than this module)
               (mine (seq-filter (lambda (c)
                                   (and (eq (plist-get c :kind) 'same-key)
                                        (seq-some (lambda (b) (memq (plist-get b :id) drgnx-work-space-command-ids))
                                                  (cons (plist-get c :winner) (plist-get c :losers)))))
                                 (plist-get r :conflicts))))
          (should-not mine))))))

(provide 'work-space-test)
;;; work-space-test.el ends here
