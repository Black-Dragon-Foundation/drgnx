;;; editor-m11c1-test.el --- GUI tests: the Replace view, the find bar, layouts, the browser fallback, the Live view, the Shortcuts editor (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; One walk through M11c-1's surfaces on a graphical frame, a screenshot of each (their paths are printed).  Config,
;; state and the git repository are temp dirs; the Live view watches a mock browser (test/fixtures/mock-cdp.el), never
;; Chrome; the key profile applied for the Shortcuts editor is undone at the end.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-m11c1-ui-test--repo                         ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-m11c1-ui-test--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-m11c1-ui-test--repo))
(require 'drgnx)
(require 'drgnx-wb)
(require 'drgnx-area)
(require 'drgnx-groups)
(require 'drgnx-rules)
(require 'drgnx-agents)
(require 'drgnx-jobs)
(require 'drgnx-keys-edit)
(load (expand-file-name "test/fixtures/git-fixture" drgnx-m11c1-ui-test--repo) nil t)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-m11c1-ui-test--repo) nil t)
(dolist (m '("tools/drgnx-replace" "tools/drgnx-agents-ui" "tools/drgnx-layouts" "tools/drgnx-browser" "tools/drgnx-live"
             "tools/drgnx-shortcuts"))
  (load (expand-file-name (concat "modules/" m) drgnx-m11c1-ui-test--repo) nil t))

(defconst drgnx-m11c1-ui-test--websocket
  (let ((elpa (expand-file-name (or (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa"))))
    (or (locate-library "websocket")
        (when-let* ((dir (car (last (and (file-directory-p elpa) (directory-files elpa t "\\`websocket-[0-9]"))))))
          (locate-file "websocket.el" (list dir)))))
  "websocket.el, when this Emacs can load it (the Live view needs it).")
(when drgnx-m11c1-ui-test--websocket
  (add-to-list 'load-path (file-name-directory drgnx-m11c1-ui-test--websocket))
  (require 'websocket)
  (load (expand-file-name "test/fixtures/mock-cdp" drgnx-m11c1-ui-test--repo) nil t))

(defun drgnx-m11c1-ui-test--wait (pred &optional secs)
  "Wait (SECS, default 10) until PRED holds, reading process output; PRED's last value."
  (let ((deadline (+ (float-time) (or secs 10))))
    (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.05)))
  (funcall pred))

(defun drgnx-m11c1-ui-test--shot (dir name)
  "Capture the root frame into DIR and keep it as NAME in the session's temp dir; print where."
  (let ((shot (plist-get (drgnx-uitest-capture dir) :root)) (out (expand-file-name name temporary-file-directory)))
    (should (file-exists-p shot))
    (copy-file shot out t)
    (message "m11c-1 screenshot: %s" out)
    out))

(defun drgnx-m11c1-ui-test--jpeg ()
  "A real JPEG for a screencast frame (ImageMagick's built-in logo), or nil without ImageMagick."
  (when-let* ((magick (or (executable-find "magick") (executable-find "convert"))))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (and (eq 0 (call-process magick nil t nil "logo:" "-resize" "1280x800!" "jpeg:-"))
           (> (buffer-size) 1000)
           (buffer-string)))))

(defconst drgnx-m11c1-ui-test--buffers
  '("*drgnx-m11c1-output*" "*drgnx Agents*" "*agent: alpha*" "*agent: beta*" "*drgnx live*" "*drgnx keyboard shortcuts*"
    "*drgnx: browser*")
  "Buffers the walk makes, killed after it.")

(ert-deftest drgnx-ui-m11c1/replace-layouts-shortcuts ()
  (drgnx-test-with-state
    (let* ((root (drgnx-uitest-root-frame)) (shots (make-temp-file "drgnx-m11c1-shot" t))
           (state (make-temp-file "drgnx-m11c1-state" t))
           (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" state "/config") (concat "XDG_STATE_HOME=" state "/state"))
                                        process-environment))
           (drgnx-wb--sections nil)
           (drgnx-wb--areas (copy-tree drgnx-wb--areas))
           (drgnx-layouts-shapes (copy-sequence drgnx-layouts-shapes))
           (drgnx-agents--sessions nil)
           (drgnx-agents-ui--last (make-hash-table :test #'eq :weakness 'key))
           (drgnx-agents-ui--jobs-cache (cons 1.0e+INF nil))
           (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
           (drgnx-keys--applied nil) (drgnx-keys--session-layers nil) (drgnx-keys-last nil)
           (drgnx-surfaces--usage nil) (drgnx-surfaces--usage-dirty nil)
           (drgnx-shortcuts-chord-wait 3.0)
           (display-buffer-alist nil) (display-buffer-overriding-action '(nil))
           (dired nil))
      (make-directory (concat state "/config") t)
      (unwind-protect
          (drgnx-git-test-with-repo
            (drgnx-git-test-write repo "src/parser.el"
                                  (mapconcat (lambda (i) (format "(defun parse-step-%d (input)\n  \"Step %d.\"\n  (needle-check input %d))\n\n" i i i))
                                             (number-sequence 1 12) ""))
            (drgnx-git-test-write repo "src/needle.el" "(defun needle-check (input n)\n  \"The needle.\"\n  (> (length input) n))\n")
            (drgnx-git-test-write repo "README.md" "# Parser\n\nEvery step calls needle-check.\n")
            (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "Start")
            (with-selected-frame root
              (delete-other-windows)
              (dolist (p '(drgnx-wb-view drgnx-wb-areas drgnx-wb-panel-px drgnx-wb-right-px drgnx-wb-dock-px drgnx-layouts-state
                                         drgnx-layouts-current drgnx-layouts-previous drgnx-layouts-zen-return))
                (set-frame-parameter nil p nil))
              ;; the workbench: a file list as the Explorer, the Search view, the Agents tab on the right
              (setq dired (dired-noselect repo))
              (with-current-buffer dired (dired-hide-details-mode 1))
              (drgnx-wb-define-section 'explorer :slot 0 :title " EXPLORER" :buffer (lambda () dired))
              (drgnx-replace--define-section)
              (drgnx-replace--define-commands)
              (drgnx-layouts--define-commands)
              (drgnx-browser--register-shape)
              (drgnx-browser--define-commands)
              (drgnx-shortcuts--define-commands)
              (drgnx-wb-define-tab 'right 'agents :title "Agents" :placeholder #'drgnx-agents-ui-list-buffer)
              (drgnx-rules-mode 1)
              (find-file (expand-file-name "src/parser.el" repo))
              (drgnx-test-use-editor (selected-window))
              (goto-char (point-min)) (search-forward "needle-check") (backward-char 2)
              (drgnx-wb-show-sidebar)

              ;; 1. the Replace view in the sidebar, with results
              (drgnx-replace-in-files)
              (should (eq (drgnx-wb-sidebar-view) 'search))
              (let ((view (get-buffer drgnx-replace-buffer-name)))
                (should (drgnx-m11c1-ui-test--wait (lambda () (with-current-buffer view (not (drgnx-replace--busy-p))))))
                (with-current-buffer view
                  (should (equal (widget-value (drgnx-replace--widget 'find)) "needle-check"))
                  (should (= 14 (length drgnx-replace--matches))))   ; 12 steps, its definition, the README
                (with-current-buffer view (widget-value-set (drgnx-replace--widget 'replace) "needle-ok"))
                (should (drgnx-m11c1-ui-test--wait (lambda () (with-current-buffer view (not (drgnx-replace--busy-p))))))
                (redisplay t)
                (should (window-live-p (drgnx-wb-section-window 'search)))
                (drgnx-m11c1-ui-test--shot shots "m11c1-replace-view.png"))

              ;; 2. the find bar above the editor
              (select-window (drgnx-wb-editor-window))
              (drgnx-replace-in-file)
              (let ((bar (get-buffer drgnx-replace-bar-buffer-name)))
                (should (get-buffer-window bar))
                (with-current-buffer bar (should (= 12 (length drgnx-replace--bar-overlays))))   ; parser.el's own
                (redisplay t)
                (drgnx-m11c1-ui-test--shot shots "m11c1-find-bar.png"))
              (drgnx-replace-bar-close)

              ;; 3. the Agent layout (an agent with a short chat) and Zen
              (let ((alpha (drgnx-agents--make :id "a1" :name "alpha" :status 'idle :conn 'fake :cwd repo))
                    (beta (drgnx-agents--make :id "b1" :name "beta" :status 'idle :conn 'fake :cwd repo)))
                (setf (drgnx-agent-session-entries alpha)
                      (list (list :type 'user :text "Rename needle-check to needle-ok everywhere.")
                            (list :type 'agent :text "Done: 14 places in 3 files, the tests pass." :done t)
                            (list :type 'stop :stop "end_turn" :done t)))
                (setq drgnx-agents--sessions (list beta alpha))
                (puthash alpha (float-time) drgnx-agents-ui--last)
                (puthash beta (- (float-time) 600) drgnx-agents-ui--last))
              (drgnx-layouts-apply 'agent)
              (should (eq (drgnx-layouts-current) 'agent))
              (should (= 2 (length (drgnx-groups-list))))
              (should (equal (buffer-name (window-buffer (cadr (drgnx-groups-list)))) "*agent: alpha*"))
              (should (window-live-p (drgnx-wb-area-window 'right)))
              (redisplay t)
              (drgnx-m11c1-ui-test--shot shots "m11c1-layout-agent.png")
              (drgnx-layouts-zen)
              (should (eq (drgnx-layouts-current) 'zen))
              (should (= 1 (length (window-list nil 'nomini))))
              (should (> (or (car (window-margins)) 0) 0))
              (redisplay t)
              (drgnx-m11c1-ui-test--shot shots "m11c1-layout-zen.png")
              (drgnx-layouts-zen)                         ; back to Agent
              (should (eq (drgnx-layouts-current) 'agent))

              ;; 4. the Browser layout without WebKit: the pane says why and how to open a page
              (cl-letf (((symbol-function 'drgnx-browser-webkit-p) (lambda () nil)))
                (drgnx-layouts-apply 'browser)
                (let ((pane (seq-find (lambda (w) (eq (window-parameter w 'drgnx-layouts-pane) 'browser)) (window-list nil 'nomini))))
                  (should (window-live-p pane))
                  (with-current-buffer (window-buffer pane) (should (string-search "no WebKit" (buffer-string)))))
                (redisplay t)
                (drgnx-m11c1-ui-test--shot shots "m11c1-browser-fallback.png"))
              (drgnx-layouts-apply 'editor)

              ;; 5. the Live view, watching the mock browser
              (if (not drgnx-m11c1-ui-test--websocket)
                  (message "m11c-1: no websocket package, the Live view is not shown")
                (let* ((port (drgnx-mock-cdp-start))
                       (drgnx-live--browser (list :port port :ws (format "ws://127.0.0.1:%d/devtools/browser/mock" port) :job "job-live"))
                       (jpeg (drgnx-m11c1-ui-test--jpeg)))
                  (unwind-protect
                      (cl-letf (((symbol-function 'drgnx-jobs-get)
                                 (lambda (id) (and (equal id "job-live") (list :id id :status 'running)))))
                        (drgnx-live-view)
                        (should (drgnx-mock-cdp-wait (lambda () (drgnx-mock-cdp-received "Page.startScreencast"))))
                        (if jpeg
                            (drgnx-mock-cdp-event "Page.screencastFrame"
                                                  (list :data (base64-encode-string jpeg t) :sessionId 1
                                                        :metadata (list :deviceWidth 1280 :deviceHeight 800 :offsetTop 0 :pageScaleFactor 1
                                                                        :scrollOffsetX 0 :scrollOffsetY 0 :timestamp (float-time)))
                                                  "S-T1")
                          (drgnx-mock-cdp-frame 1))
                        (should (drgnx-mock-cdp-wait (lambda () (drgnx-mock-cdp-received "Page.screencastFrameAck"))))
                        (should (get-buffer-window "*drgnx live*" root))
                        (redisplay t)
                        (drgnx-m11c1-ui-test--shot shots "m11c1-live-view.png"))
                    (when (get-buffer "*drgnx live*") (kill-buffer "*drgnx live*"))
                    (drgnx-mock-cdp-stop))))

              ;; 6. the Keyboard Shortcuts editor recording a chord: VS Code keys, Layout Agent (no key) gets C-k C-9
              (drgnx-keys-use '((vscode app editing window)))
              (drgnx-shortcuts)
              (switch-to-buffer "*drgnx keyboard shortcuts*")
              (goto-char (point-min))
              (let ((m (text-property-search-forward 'drgnx-shortcuts-id 'layout-agent (lambda (v x) (eq v x)))))
                (should m)
                (goto-char (prop-match-beginning m)))
              (let ((mid nil))
                ;; the first key now; the screenshot while the editor waits for the second; then the second
                (setq unread-command-events (list ?\C-k))
                (run-with-timer 0.5 nil (lambda ()
                                          (setq mid (drgnx-m11c1-ui-test--shot shots "m11c1-shortcuts-recording.png"))
                                          (setq unread-command-events (append unread-command-events (list ?\C-9)))))
                ;; a question nobody expects fails the test instead of waiting forever
                (cl-letf (((symbol-function 'read-multiple-choice) (lambda (prompt &rest _) (error "Unexpected question: %s" prompt)))
                          ((symbol-function 'yes-or-no-p) (lambda (prompt) (error "Unexpected question: %s" prompt))))
                  (drgnx-shortcuts-change))
                (should mid))
              (should (equal (mapcar #'car (plist-get (drgnx-shortcuts--row 'layout-agent) :keys)) '("C-k C-9")))
              (should (eq (keymap-lookup global-map "C-k C-9") #'drgnx-layouts-agent))
              (redisplay t)
              (drgnx-m11c1-ui-test--shot shots "m11c1-shortcuts-recorded.png")))
        (drgnx-keys--restore)
        (drgnx-replace-bar-close)
        (drgnx-wb-hide-sidebar)
        (ignore-errors (drgnx-wb-area-hide 'panel))
        (ignore-errors (drgnx-wb-area-hide 'right))
        (drgnx-rules-mode -1)
        (remove-hook 'window-size-change-functions #'drgnx-layouts--zen-resize)
        (with-selected-frame root
          (delete-other-windows)
          (set-window-margins nil 0 0)
          ;; the layouts put the editor chrome (tab line, breadcrumbs, mode line) on the window: later tests count lines
          (dolist (p '(drgnx-tabs drgnx-layouts-pane tab-line-format header-line-format mode-line-format))
            (set-window-parameter nil p nil))
          (dolist (p '(drgnx-wb-view drgnx-wb-areas drgnx-wb-panel-px drgnx-wb-right-px drgnx-wb-dock-px drgnx-layouts-state
                                     drgnx-layouts-current drgnx-layouts-previous drgnx-layouts-zen-return))
            (set-frame-parameter nil p nil))
          (switch-to-buffer "*scratch*"))
        (dolist (b (append drgnx-m11c1-ui-test--buffers (list drgnx-replace-buffer-name drgnx-replace-bar-buffer-name)))
          (when-let* ((buf (get-buffer b))) (kill-buffer buf)))
        (when (buffer-live-p dired) (kill-buffer dired))
        (drgnx-timer-cancel 'surfaces-usage)
        (delete-directory shots t)
        (delete-directory state t)))))

;;; editor-m11c1-test.el ends here
