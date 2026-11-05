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

(declare-function drgnx-work-space-open "drgnx-work-space")
(declare-function drgnx-work-space-sync-shown "drgnx-work-space")
(defvar drgnx-work-space-command-ids)

(defmacro drgnx-work-space-test--with (&rest body)
  "BODY with the module `tools/work-space' set up, a gated hub serving the test's dirs (profile \"mock\"), and
`workspace' the workspace of the test's home folder.  The modules come first so the hub and this Emacs share their
directories."
  (declare (indent 0))
  `(drgnx-test-with-modules '(tools/work-space)
     (drgnx-agents-mirror-test--with '()
       ;; the hub fixture binds the client's event and disconnect hooks to nil: the module's functions go on again
       (add-hook 'drgnx-hub-event-functions #'drgnx-work-client-event)
       (add-hook 'drgnx-hub-disconnect-functions #'drgnx-work-client-disconnected)
       (let ((workspace (list :id "workspace:000000000001" :roots (list (getenv "HOME")))))
         ,@body))))

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
      (with-current-buffer buf (drgnx-view-draw-now drgnx-view))
      (let ((text (with-current-buffer buf (buffer-string))))
        (should (string-search "Agents" text))
        (should (string-search "mock" text))
        (should (string-search "Files and machines" text)))
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
    (cl-letf (((symbol-function 'drgnx-hub-call)
               (lambda (method params &rest _) (push (cons method params) calls) 1)))
      (drgnx-test-with-modules '(tools/work-space) :strict t
                               (setq name (buffer-name (drgnx-work-space-open (list :id "workspace:000000000002" :roots (list temporary-file-directory)))))
                               (should (get-buffer name))
                               (should (assoc "work/map/subscribe" calls))))
    (should-not (get-buffer name))
    (should (assoc "work/map/close" calls))
    (should-not (drgnx-work-client-views))))

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
