;;; work-flow-tty-test.el --- tty tier: the Work List, Timeline, Detail, Budgets page and Changes in a terminal -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.  The inner Emacs
;; starts three agents of the 30-agent fixture (test/fixtures/work-space-thirty-fixture.el) on the hub of
;; DRGNX_RATATOSKR_BIN (a test-hooks build with ratatoskr-mock beside it) and opens one of the flow's places: a terminal
;; is a display class of its own, so the hub draws the place's terminal form (characters for bars and meters, column
;; stops, no pixel widths) and what the buffer holds is on the screen.
(require 'ert)
(require 'drgnx-tty-session)

(defconst drgnx-tty-work-flow-test--state
  '(let* ((b drgnx-tty-work-flow--buf) (s (and (buffer-live-p b) (buffer-local-value 'drgnx-view-patch b))))
     (list drgnx-tty-work-flow--err
           (and s (drgnx-view-patch-class s)) (and s (drgnx-view-patch-version s)) (and s (drgnx-view-patch-stale s))
           (and (buffer-live-p b)
                (with-current-buffer b
                  (save-excursion
                    (goto-char (point-min))
                    (skip-chars-forward " \t\n")
                    (string-trim (buffer-substring-no-properties (point) (min (point-max) (line-end-position)))))))
           ;; a pixel width or stop (`(space :width (N))', `:align-to (N)') is a graphical form
           (and (buffer-live-p b)
                (with-current-buffer b
                  (let ((pos (point-min)) found)
                    (while (and (not found) (< pos (point-max)))
                      (let ((d (get-text-property pos 'display)))
                        (when (and (consp d) (eq (car d) 'space)
                                   (or (consp (plist-get (cdr d) :width)) (consp (plist-get (cdr d) :align-to))))
                          (setq found pos)))
                      (setq pos (next-single-property-change pos 'display nil (point-max))))
                    found)))))
  "A form, in the inner Emacs: (ERROR CLASS VERSION STALE FIRST-LINE PIXEL-AT) of the place's buffer.")

(defun drgnx-tty-work-flow-test--open (place)
  "A form, in the inner Emacs, opening PLACE on the fixture's map and showing it alone."
  `(progn
     (defvar drgnx-tty-work-flow--buf nil)
     (defvar drgnx-tty-work-flow--err nil)
     (load (expand-file-name "test/fixtures/work-space-thirty-fixture" drgnx-dir) nil t)
     (condition-case e
         (let* ((list-p ,(eq place 'work-list))
                (map (progn (drgnx-work-thirty-start (getenv "DRGNX_RATATOSKR_BIN") 3)
                            (drgnx-work-thirty-map t (if list-p 'list 'graph))))
                (b (pcase ',place
                     ('work-list map)
                     ('work-timeline (drgnx-work-timeline-open map 'schedule))
                     ('work-activity (drgnx-work-timeline-open map 'activity))
                     ('work-detail (drgnx-work-detail-buffer map))
                     ('budgets-page (drgnx-budgets--buffer))
                     ('changes (drgnx-changes--buffer)))))
           (drgnx-work-thirty-only-window)
           (switch-to-buffer b)
           (setq drgnx-tty-work-flow--buf b))
       (error (setq drgnx-tty-work-flow--err (format "%S" e))))
     t))

(defun drgnx-tty-work-flow-test--run (place)
  "PLACE in `emacs -nw', three agents streaming: on the hub's rows in a terminal class, not stale, no pixel form, and
its first line on the screen."
  (let ((bin (getenv "DRGNX_RATATOSKR_BIN")))
    (skip-unless (and bin (file-executable-p bin)))
    (drgnx-tty-session-with (s :size "160x48" :env (list (concat "DRGNX_RATATOSKR_BIN=" bin)))
      (drgnx-tty-session-wait-tab s nil 20)
      (skip-unless (drgnx-tty-session-eval s '(fboundp 'nidhogg-view--call)))
      ;; the fixture waits for its agents inside this one call
      (drgnx-tty-session-eval s (drgnx-tty-work-flow-test--open place) 180)
      (unwind-protect
          (progn
            (drgnx-tty-session-wait s `(let ((st ,drgnx-tty-work-flow-test--state))
                                         (or (car st) (and (nth 2 st) (not (nth 3 st)) (nth 4 st)
                                                           (> (length (nth 4 st)) 0))))
                                    120)
            (pcase-let ((`(,err ,class ,_version ,stale ,first ,pixel)
                         (drgnx-tty-session-eval s drgnx-tty-work-flow-test--state)))
              (should-not err)
              (should (string-prefix-p "tty" class))
              (should-not stale)
              (should-not pixel)
              (drgnx-tty-session-wait-screen s (regexp-quote (substring first 0 (min 20 (length first)))) 20)))
        (ignore-errors (drgnx-tty-session-eval s '(drgnx-work-thirty-stop) 30))))))

(ert-deftest drgnx-tty-work-flow/work-list-in-a-terminal ()
  "The Work List (the outline form) in a terminal."
  (drgnx-tty-work-flow-test--run 'work-list))

(ert-deftest drgnx-tty-work-flow/work-timeline-schedule-in-a-terminal ()
  "The Timeline's Schedule in a terminal: its bars are cells of characters."
  (drgnx-tty-work-flow-test--run 'work-timeline))

(ert-deftest drgnx-tty-work-flow/work-timeline-activity-in-a-terminal ()
  "The Timeline's Activity in a terminal: a lane per agent, its segments cells of characters."
  (drgnx-tty-work-flow-test--run 'work-activity))

(ert-deftest drgnx-tty-work-flow/work-detail-in-a-terminal ()
  "The Work Detail beside the map in a terminal: its meters are text."
  (drgnx-tty-work-flow-test--run 'work-detail))

(ert-deftest drgnx-tty-work-flow/budgets-page-in-a-terminal ()
  "The Budgets page in a terminal: its meters are eighth-block bars."
  (drgnx-tty-work-flow-test--run 'budgets-page))

(ert-deftest drgnx-tty-work-flow/changes-in-a-terminal ()
  "The Changes place (by task) in a terminal."
  (drgnx-tty-work-flow-test--run 'changes))

(provide 'tty-work-flow-test)
;;; work-flow-tty-test.el ends here
