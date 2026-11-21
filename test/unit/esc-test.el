;;; esc-test.el --- batch tests: the Esc double tap opens Switch Tile -*- lexical-binding: t -*-
;; test-class: det
;; Module ui/tiles is set up (it turns `drgnx-esc-mode' on); keys go through the active maps as the command loop runs
;; them (`drgnx-esc-test--press': pre-command-hook, the command, post-command-hook); time is the virtual clock.  The
;; decode filter's waits are the clock's too.  The rows that need a terminal's bytes (F6, Alt+Esc, escape sequences,
;; `Esc x', the Vim profile's evil) are in test/tty/esc-tty-test.el.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-dir) nil t)
(require 'drgnx-switcher)
(require 'drgnx-esc)
(load (expand-file-name "modules/ui/drgnx-close" drgnx-dir) nil t)

(defvar drgnx-term--queue)
(defvar drgnx-term-scroll-to-bottom)
(declare-function drgnx-term-mode "drgnx-term")

(defvar drgnx-esc-test--ran nil "The commands the rows' own Esc bindings ran, newest first.")
(defvar drgnx-esc-test--errors nil "Errors the pressed keys' commands signalled, newest first: (EVENT COMMAND ERROR).")

(defun drgnx-esc-test--cancel () "A cancel." (interactive) (push 'cancel drgnx-esc-test--ran))
(defun drgnx-esc-test--other () "Not a cancel." (interactive) (push 'other drgnx-esc-test--ran))

(defun drgnx-esc-test--press (event)
  "EVENT as the command loop runs it: its binding in the active maps, with the hooks around it."
  (let* ((keys (vector event)) (cmd (key-binding keys t)))
    (setq last-command-event event this-command cmd)
    (run-hooks 'pre-command-hook)
    (when (commandp cmd)
      (condition-case err (call-interactively cmd nil keys)
        (error (push (list event cmd err) drgnx-esc-test--errors))))
    (run-hooks 'post-command-hook)
    (setq last-command this-command)))

(defun drgnx-esc-test--meta-z-map ()
  "A local map where Esc is only the Meta prefix: ESC z (M-z) is the rows' non-cancel."
  (list 'keymap (list ?\e 'keymap (cons ?z #'drgnx-esc-test--other))))

(defmacro drgnx-esc-test--with (esc-command &rest body)
  "BODY in a buffer whose `<escape>' runs ESC-COMMAND (nil: unbound), module ui/tiles on, the virtual clock."
  (declare (indent 1))
  `(drgnx-test-with-modules '(core/workbench ui/tiles)
     (drgnx-grid-test--with
       (drgnx-test-with-clock (:allow-pending t)
         (let ((drgnx-esc-test--ran nil) (drgnx-esc--last nil)
               (drgnx-esc-cancel-commands (cons 'drgnx-esc-test--cancel drgnx-esc-cancel-commands))
               (buf (get-buffer-create "*esc-test*")))
           (unwind-protect
               (progn
                 (set-window-buffer (selected-window) buf)
                 (set-buffer buf)
                 (use-local-map (if ,esc-command (list 'keymap (cons 'escape ,esc-command)) nil))
                 ,@body)
             (drgnx-switcher-close)
             (kill-buffer buf)))))))

(ert-deftest drgnx-esc/bound-esc-acts-at-once ()
  (drgnx-esc-test--with #'drgnx-esc-test--other
    (should drgnx-esc-mode)
    (let ((t0 (drgnx-timer-now)))
      (drgnx-esc-test--press 'escape)
      (should (equal drgnx-esc-test--ran '(other)))
      ;; a terminal's ESC, through the batch terminal's decode map: where `<escape>' is bound it is `<escape>' at once
      (execute-kbd-macro [?\e])
      (should (equal drgnx-esc-test--ran '(other other)))
      (should (= (drgnx-timer-now) t0)))))

(ert-deftest drgnx-esc/a-non-cancel-first-esc-never-counts ()
  (drgnx-esc-test--with #'drgnx-esc-test--other
    (drgnx-esc-test--press 'escape)
    (drgnx-test-advance 0.1)
    (drgnx-esc-test--press 'escape)
    (should (equal drgnx-esc-test--ran '(other other)))
    (should-not (drgnx-switcher-open-p))))

(ert-deftest drgnx-esc/a-cancel-then-esc-opens ()
  (drgnx-esc-test--with #'drgnx-esc-test--cancel
    (drgnx-esc-test--press 'escape)
    (drgnx-test-advance 0.1)
    (drgnx-esc-test--press 'escape)
    (should (drgnx-switcher-open-p))
    ;; the second Esc opened the switcher and ran nothing else
    (should (equal drgnx-esc-test--ran '(cancel)))
    (drgnx-switcher-close)
    ;; past the window: the second Esc is a cancel again
    (drgnx-esc-test--press 'escape)
    (drgnx-test-advance 0.4)
    (drgnx-esc-test--press 'escape)
    (should-not (drgnx-switcher-open-p))
    (should (equal drgnx-esc-test--ran '(cancel cancel cancel)))))

(ert-deftest drgnx-esc/an-esc-a-keyboard-macro-replays-is-no-double-tap ()
  ;; Vim's `q a A ! Esc j q @ a': the replayed Esc follows the recorded one within the window and must cancel again
  (drgnx-esc-test--with #'drgnx-esc-test--cancel
    (drgnx-esc-test--press 'escape)
    (drgnx-test-advance 0.1)
    (execute-kbd-macro [escape])
    (should-not (drgnx-switcher-open-p))
    (should (equal drgnx-esc-test--ran '(cancel cancel)))))

(ert-deftest drgnx-esc/a-cancel-from-a-front-map-counts ()
  ;; Close Pane's map is in front of the detector; with nothing to close its Esc is a cancel all the same
  (drgnx-esc-test--with nil
    (let ((drgnx-close--here t))
      (setq buffer-read-only t)
      ;; the key profiles bind Close Pane's Esc; here the row binds it itself, and takes it out after
      (define-key drgnx-close-mode-map [escape] #'drgnx-close-pane)
      (drgnx-close-mode 1)
      (unwind-protect
          (progn
            (setq drgnx-close--here t)
            (should (eq (key-binding [escape] t) #'drgnx-close-pane))
            (drgnx-esc-test--press 'escape)
            (should-not drgnx-close--closed)
            (should (eq (cdr drgnx-esc--last) 'drgnx-close-pane))
            (drgnx-test-advance 0.1)
            (drgnx-esc-test--press 'escape)
            (should (drgnx-switcher-open-p)))
        (drgnx-close-mode -1)
        (define-key drgnx-close-mode-map [escape] nil t)))))

(ert-deftest drgnx-esc/triple-esc-closes-and-quits ()
  (drgnx-esc-test--with #'drgnx-esc-test--cancel
    (drgnx-esc-test--press 'escape)
    (drgnx-test-advance 0.1)
    (drgnx-esc-test--press 'escape)
    (should (drgnx-switcher-open-p))
    (drgnx-test-advance 0.1)
    (should (eq (drgnx-switcher-handle 'escape) 'quit))
    (should-not (drgnx-switcher-open-p))
    ;; a third Esc after the window only closes
    (drgnx-esc-test--press 'escape)
    (drgnx-test-advance 0.1)
    (drgnx-esc-test--press 'escape)
    (should (drgnx-switcher-open-p))
    (drgnx-test-advance 0.4)
    (should (eq (drgnx-switcher-handle 'escape) 'closed))))

(ert-deftest drgnx-esc/off-when-nil ()
  (drgnx-esc-test--with #'drgnx-esc-test--cancel
    (let ((drgnx-esc-double-tap nil))
      (drgnx-esc-test--press 'escape)
      (drgnx-test-advance 0.1)
      (drgnx-esc-test--press 'escape)
      (should-not (drgnx-switcher-open-p))
      (should (equal drgnx-esc-test--ran '(cancel cancel)))
      ;; the decode filter leaves a terminal's ESC alone and waits for nothing: ESC z is M-z
      (use-local-map (drgnx-esc-test--meta-z-map))
      (let ((t0 (drgnx-timer-now)))
        (execute-kbd-macro [?\e ?z])
        (should (equal drgnx-esc-test--ran '(other cancel cancel)))
        (should (= (drgnx-timer-now) t0))))))

(ert-deftest drgnx-esc/emacs-a-lone-esc-waits-only-where-unbound ()
  ;; Esc is the bare Meta prefix here: the filter waits the window, and with no key in it the Esc stays ESC
  (drgnx-esc-test--with nil
    (use-local-map (drgnx-esc-test--meta-z-map))
    (let ((t0 (drgnx-timer-now)))
      (execute-kbd-macro [?\e ?z])
      (should (equal drgnx-esc-test--ran '(other)))
      (should (>= (- (drgnx-timer-now) t0) (- drgnx-esc-double-tap 0.001))))))

(defmacro drgnx-esc-test--profile (layers &rest body)
  "BODY with LAYERS (evaluated) applied and the startup modules (the terminal and ui/tiles among them) set up."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "drgnx-esc" t))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir) (concat "XDG_STATE_HOME=" dir "/state"))
                                       process-environment))
          (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
          (drgnx-keys--session-layers nil) (drgnx-keys-profiles nil)
          (drgnx-keys-problems nil))
     (unwind-protect
         (progn
           (drgnx--core-commands)
           (drgnx-test-with-modules nil :stages '(startup)
                                    (drgnx-keys-use ,layers)
                                    ,@body))
       (drgnx-keys--restore)
       (delete-directory dir t))))

(ert-deftest drgnx-esc/esc-esc-in-a-terminal-tile-reaches-the-program ()
  (dolist (profile '(vscode emacs vim))
    (drgnx-esc-test--profile `((,profile app editing window))
      (drgnx-test-with-clock (:allow-pending t)
        (with-temp-buffer
          (drgnx-term-mode)
          (set-window-buffer (selected-window) (current-buffer))
          ;; no terminal view in batch: a key does not go back to the cursor
          (setq-local drgnx-term-scroll-to-bottom nil)
          (setq drgnx-esc-test--errors nil)
          (should drgnx-esc-mode)
          ;; even right after a cancel elsewhere
          (setq drgnx-esc--last (cons (drgnx-timer-now) 'keyboard-escape-quit))
          (drgnx-esc-test--press 'escape)
          (drgnx-test-advance 0.1)
          (drgnx-esc-test--press 'escape)
          (should-not (drgnx-switcher-open-p))
          (should-not drgnx-esc-test--errors)
          (should (equal (list (length drgnx-term--queue) (key-binding [escape] t)) '(2 drgnx-esc))))))))

(ert-deftest drgnx-esc/c-escape-in-a-terminal-tile-opens-the-switcher ()
  (dolist (profile '(vscode emacs vim))
    (drgnx-esc-test--profile `((,profile app editing window))
      (drgnx-test-with-clock (:allow-pending t)
        (with-temp-buffer
          (drgnx-term-mode)
          (set-window-buffer (selected-window) (current-buffer))
          (unwind-protect
              (progn
                (should (equal (list profile (key-binding [C-escape] t)) (list profile #'drgnx-switcher-open)))
                (drgnx-esc-test--press 'C-escape)
                (should (drgnx-switcher-open-p))
                (should-not drgnx-term--queue))
            (drgnx-switcher-close)))))))

(provide 'esc-test)
;;; esc-test.el ends here
