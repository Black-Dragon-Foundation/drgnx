;;; inbox-gui-test.el --- GUI tests: the needs-you inbox under the title row's pill (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; Design docs/specs/drgnx/2026-11-16-title-bar-inbox-design.md (the org folder), "The inbox" (mockup option C).  A mock
;; agent session asks permission (its hub call is recorded: the hub is an outside service); a real pointer
;; (`drgnx-uitest-pointer-click') presses the pill, then Allow once, then Pin as side bar, then the pill again.

(require 'ert)
(load (expand-file-name "../fixtures/grid-on-fixture" (file-name-directory (macroexp-file-name))) nil t)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-inbox--repo               ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-inbox--repo)))
(require 'drgnx)
(require 'drgnx-state)
(require 'drgnx-agents)
(require 'drgnx-wb)
(require 'drgnx-panes)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-inbox--repo) nil t)
(dolist (m '("ui/drgnx-face" "ui/drgnx-statusbar" "ui/drgnx-menubar" "ui/drgnx-topline" "ui/drgnx-inbox"))
  (load (expand-file-name (concat "modules/" m) drgnx-ui-inbox--repo) nil t))

(defvar drgnx-ui-inbox--hub nil "The hub calls the mock agent session made, newest first: (METHOD . PARAMS).")

(defun drgnx-ui-inbox--ask ()
  "A mock agent session `s1' that asks permission to run a command: the hub's attention event names it."
  (let ((s (drgnx-agents--make :name "fix-explorer" :id "s1" :remote "r1"
                               :permissions (list (list :id 7 :title "run a command"
                                                        :options (vector (list :optionId "o-once" :kind "allow_once" :name "Allow once")
                                                                         (list :optionId "o-always" :kind "allow_always" :name "Always")
                                                                         (list :optionId "o-no" :kind "reject_once" :name "Deny")))))))
    (push s drgnx-agents--sessions)
    (drgnx-agents--take-attention
     (list :at_work 1 :items (vector (list :session "s1" :id 7 :text "claude · fix-explorer wants to run a command"))))
    s))

(defmacro drgnx-ui-inbox--with (&rest body)
  "BODY in a bare frame whose title row is drawn by drgnx with the inbox set up and one mock permission ask waiting;
the state file in a temporary folder; everything undone after."
  (declare (indent 0))
  `(progn
     (drgnx-uitest-bare-frame)
     (let* ((buf (get-buffer-create "*inbox-test*")) (frame (selected-frame)) (was drgnx-face-title-bar)
            (dir (make-temp-file "inbox-state" t)) (sessions drgnx-agents--sessions) (drgnx-ui-inbox--hub nil)
            (drgnx-inbox--pinned nil))
       (switch-to-buffer buf)
       (unwind-protect
           (cl-letf (((symbol-function 'drgnx-face--drawn-wanted-p) (lambda (_f) (eq drgnx-face-title-bar 'drgnx)))
                     ((symbol-function 'drgnx-inbox--state-file) (lambda () (expand-file-name "inbox.eld" dir)))
                     ((symbol-function 'drgnx-agents--remote)
                      (lambda (_s method params &optional _r) (push (cons method params) drgnx-ui-inbox--hub))))
             (setq drgnx-face-title-bar 'drgnx)
             (drgnx-face--apply-title frame)
             (unless (drgnx-commands-get 'go-quick-open)
               (drgnx-command-define 'go-quick-open :title "Quick Open" :category "Go" :command #'ignore))
             (drgnx-menubar-setup)
             (drgnx-topline-setup)
             (drgnx-inbox-setup)
             (drgnx-ui-inbox--ask)
             (drgnx-memo-forget 'topline)
             (force-mode-line-update t)
             (drgnx-test-wait-presented)
             (drgnx-test-with-grid-on ,@body))
         (drgnx-signal--flush)
         (drgnx-inbox-off)
         (drgnx-ui-inbox--tidy)
         (drgnx-command-undefine 'go-quick-open)
         (drgnx-topline--off)
         (drgnx-menubar-off)
         (setq drgnx-agents--sessions sessions)
         (drgnx-agents--take-attention (list :at_work 0 :items (vector)))
         (setq drgnx-face-title-bar was)
         (cl-letf (((symbol-function 'drgnx-face--drawn-wanted-p) #'ignore)) (drgnx-face--apply-title frame))
         (delete-directory dir t)
         (kill-buffer buf)))))

;; The harness runs a click's commands outside the command loop, so a transient map one of them set (Emacs's own, on a
;; click: `mouse-drag-region' on the card) is never cleared by the next command: put it away.
(defun drgnx-ui-inbox--tidy ()
  (remove-hook 'pre-command-hook #'clear-transient-map)
  (remove-hook 'pre-command-hook #'clear-transient-map t)
  (setq overriding-terminal-local-map nil))

(defun drgnx-ui-inbox--click-item (key until)
  "A real click in the middle of the title row's item KEY, until UNTIL (a function) holds."
  (let ((span (drgnx-topline-item-span key)))
    (should span)
    (prog1 (drgnx-uitest-pointer-click (/ (+ (car span) (cdr span)) 2) (/ (tab-bar-height (selected-frame) t) 2) until)
      (drgnx-ui-inbox--tidy))))

(defun drgnx-ui-inbox--click-text (text until)
  "A real click on TEXT in the inbox's card; non-nil when UNTIL held."
  (let* ((card drgnx-inbox--frame) (win (frame-root-window card))
         (pos (with-current-buffer (window-buffer win)
                (save-excursion (goto-char (point-min)) (and (search-forward text nil t) (1- (point))))))
         (xy (and pos (drgnx-uitest-pos-xy win pos))))
    (should xy)
    (prog1 (drgnx-uitest-pointer-click (car xy) (cdr xy) until nil card)
      (drgnx-ui-inbox--tidy))))

(defvar drgnx-ui-inbox--parent nil)
(drgnx-look-gui-deftest drgnx-ui-inbox/the-pill-opens-the-drop-down-with-the-asks-buttons ()
  "A real press on the `1 needs you' pill opens a card under it: the header, the row of the mock agent's ask and its
three buttons, the footer."
  (skip-unless (display-graphic-p))
  (skip-unless (drgnx-uitest-pointer-available-p))
  (drgnx-ui-inbox--with
    (should (assq 'drgnx-topline-attention (drgnx-topline--line)))
    (setq drgnx-ui-inbox--parent (selected-frame))
    (drgnx-ui-inbox--click-item 'drgnx-topline-attention (lambda () (frame-live-p drgnx-inbox--frame)))
    (let ((text (with-current-buffer drgnx-inbox-buffer-name (buffer-substring-no-properties (point-min) (point-max))))
          (span (with-selected-frame drgnx-ui-inbox--parent (drgnx-topline-item-span 'drgnx-topline-attention))))
      (dolist (s '("Needs you" "Mark all read" "Pin as side bar" "fix-explorer wants to run a command"
                   "Allow once" "Always for this session" "Deny" "All notices"))
        (should (string-match-p (regexp-quote s) text)))
      ;; under the pill: its right edge is the pill's, its top below the title row
      ;; every row and the footer are whole in the card: nothing is cut at its bottom edge
      (let ((win (frame-root-window drgnx-inbox--frame)))
        (with-current-buffer drgnx-inbox-buffer-name
          (goto-char (point-min)) (search-forward "All notices")
          (let ((v (pos-visible-in-window-p (point) win t)))   ; t or (X Y): whole; (X Y RTOP RBOT …): cut off
            (should (or (eq t v) (= 2 (length v)))))))
      ;; the card's right edge is the pill's (or the frame's, when the pill is nearer the edge than the card is wide)
      (let ((at (frame-position drgnx-inbox--frame)))
        (should (<= (+ (car at) (frame-pixel-width drgnx-inbox--frame))
                    (min (+ (cdr span) 2) (frame-pixel-width drgnx-ui-inbox--parent))))
        (should (>= (cdr at) (tab-bar-height drgnx-ui-inbox--parent t)))))
    (drgnx-inbox-close)))

(drgnx-look-gui-deftest drgnx-ui-inbox/allow-once-answers-the-mock-agents-ask-and-the-row-goes ()
  "A real press on Allow once sends the agent's request the allow-once option (the call the agent panel's card makes),
the row leaves the card at once and the pill's count follows."
  (skip-unless (display-graphic-p))
  (skip-unless (drgnx-uitest-pointer-available-p))
  (drgnx-ui-inbox--with
    (drgnx-inbox-open)
    (drgnx-test-wait (lambda () (frame-live-p drgnx-inbox--frame)) :secs 5 :what "the inbox card")
    (should (= 1 (drgnx-needs-you-count)))
    (should (drgnx-ui-inbox--click-text "Allow once" (lambda () drgnx-ui-inbox--hub)))
    (should (equal (car drgnx-ui-inbox--hub) '("agents/permission" :request 7 :option "o-once")))
    (should (= 0 (drgnx-needs-you-count)))
    (should (string-match-p "Nothing needs you"
                            (with-current-buffer drgnx-inbox-buffer-name (buffer-substring-no-properties (point-min) (point-max)))))
    (drgnx-inbox-close)))

(drgnx-look-gui-deftest drgnx-ui-inbox/pin-moves-it-to-the-right-side-bar-and-the-pill-then-opens-the-tab ()
  "A real press on Pin as side bar closes the card and opens the Inbox tab in the right side bar; the choice is kept
\(the state file), so a real press on the pill then shows the tab and no card."
  (skip-unless (display-graphic-p))
  (skip-unless (drgnx-uitest-pointer-available-p))
  (drgnx-ui-inbox--with
    (drgnx-inbox-open)
    (drgnx-test-wait (lambda () (frame-live-p drgnx-inbox--frame)) :secs 5 :what "the inbox card")
    (should (drgnx-ui-inbox--click-text "Pin as side bar" (lambda () (drgnx-pane-window 'inbox))))
    (should-not (frame-live-p drgnx-inbox--frame))
    (should (eq (window-buffer (drgnx-pane-window 'inbox)) (get-buffer drgnx-inbox-buffer-name)))
    (should (equal (plist-get (plist-get (drgnx-file-read (drgnx-inbox--state-file)) :data) :pinned) t))
    ;; the tab is shown: hide it, then the pill brings the tab back (not the card)
    (drgnx-pane-hide 'inbox)
    (should-not (drgnx-pane-window 'inbox))
    (drgnx-ui-inbox--click-item 'drgnx-topline-attention (lambda () (drgnx-pane-window 'inbox)))
    (should-not (frame-live-p drgnx-inbox--frame))
    (drgnx-pane-hide 'inbox)))

(provide 'inbox-gui-test)
;;; inbox-gui-test.el ends here
