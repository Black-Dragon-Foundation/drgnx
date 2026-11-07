;;; work-map-test.el --- tty tier: the Work map on the hub's rows in a terminal -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.  The inner Emacs
;; starts the 30-agent fixture (test/fixtures/work-space-thirty-fixture.el) on the hub of DRGNX_RATATOSKR_BIN (a
;; test-hooks build with ratatoskr-mock beside it) and opens the map: a terminal is a display class of its own, which
;; the hub fills with its own reset while the agents stream.
(require 'ert)
(require 'drgnx-tty-session)

(defconst drgnx-tty-work-map-test--state
  '(let* ((b drgnx-tty-work-map--buf) (s (and (buffer-live-p b) (buffer-local-value 'drgnx-view-patch b))))
     (list drgnx-tty-work-map--err
           (and s (drgnx-view-patch-class s)) (and s (drgnx-view-patch-version s)) (and s (drgnx-view-patch-stale s))
           (and (buffer-live-p b) (with-current-buffer b
                                    (string-trim (buffer-substring-no-properties
                                                  (point-min) (min (point-max) (line-end-position 2))))))))
  "A form, in the inner Emacs: (ERROR CLASS VERSION STALE FIRST-LINES) of the map.")

(ert-deftest drgnx-tty-work-map/the-map-takes-the-hubs-rows-in-a-terminal ()
  "The map in `emacs -nw', its agents streaming: on the hub's rows (with Sjá), in a terminal class, not stale, and
what its buffer holds is on the screen."
  (let ((bin (getenv "DRGNX_RATATOSKR_BIN")))
    (skip-unless (and bin (file-executable-p bin)))
    (drgnx-tty-session-with (s :size "160x48" :env (list (concat "DRGNX_RATATOSKR_BIN=" bin)))
      (drgnx-tty-session-wait-screen s "\\*scratch\\*" 20)
      (skip-unless (drgnx-tty-session-eval s '(fboundp 'nidhogg-view--call)))
      (drgnx-tty-session-eval
       s `(progn
            (defvar drgnx-tty-work-map--buf nil)
            (defvar drgnx-tty-work-map--err nil)
            (load (expand-file-name "test/fixtures/work-space-thirty-fixture" drgnx-dir) nil t)
            (condition-case e
                (progn (drgnx-work-thirty-start ,bin)
                       (let ((b (drgnx-work-thirty-map t)))
                         (delete-other-windows)
                         (switch-to-buffer b)
                         (setq drgnx-tty-work-map--buf b)))
              (error (setq drgnx-tty-work-map--err (format "%S" e))))
            t)
       ;; the fixture waits for its 30 agents inside this one call
       180)
      (unwind-protect
          (progn
            (drgnx-tty-session-wait s `(let ((st ,drgnx-tty-work-map-test--state))
                                         (or (car st) (and (nth 2 st) (not (nth 3 st)) (nth 4 st)
                                                           (> (length (nth 4 st)) 0))))
                                    180)
            (pcase-let ((`(,err ,class ,_version ,stale ,first)
                         (drgnx-tty-session-eval s drgnx-tty-work-map-test--state)))
              (should-not err)
              (should (string-prefix-p "tty" class))
              (should-not stale)
              (let ((line (car (split-string first "\n" t "[ \t]+"))))
                (drgnx-tty-session-wait-screen s (regexp-quote (substring line 0 (min 20 (length line)))) 20))))
        (ignore-errors (drgnx-tty-session-eval s '(drgnx-work-thirty-stop) 30))))))

;;; work-map-test.el ends here
