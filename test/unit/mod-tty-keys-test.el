;;; mod-tty-keys-test.el --- batch tests: ui/terminal-keys — kkp, modifyOtherKeys, C-g -*- lexical-binding: t -*-
;; Batch Emacs has no terminal: terminals, their parameters and tmux are stubbed; the tty tier
;; (test/tty/keys-test.el) sends the real bytes.  kkp is a fake here unless a test says otherwise.
(require 'ert)
(require 'drgnx)
(require 'drgnx-tty-session)
(load (expand-file-name "modules/ui/drgnx-tty-frames" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-tty-keys" drgnx-dir) nil t)

(defun drgnx-tty-keys-test--kkp-dir ()
  "The directory of the pinned kkp in the user's ELPA (DRGNX_USER_ELPA, read-only), or nil."
  (let ((elpa (getenv "DRGNX_USER_ELPA")))
    (and elpa (file-directory-p elpa) (car (last (directory-files elpa t "\\`kkp-[0-9]"))))))

(defun drgnx-tty-keys-test--unload-kkp ()
  "Turn kkp's mode off and unload it (the fake or the real one), so the next test loads its own."
  (when (featurep 'kkp)
    (when (fboundp 'global-kkp-mode) (funcall 'global-kkp-mode -1))
    (unload-feature 'kkp t)))

(defmacro drgnx-tty-keys-test--modules (&rest body)
  "BODY with only ui/terminal and ui/terminal-keys defined, fresh tables, the hooks they touch restored after."
  `(let ((drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
         (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (drgnx-modules-after-stage-functions nil)
         (tty-setup-hook nil) (server-visit-hook nil) (server-after-make-frame-hook nil)
         (cfg (make-temp-file "drgnx-cfg" t)))
     (let ((process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment)))
       (unwind-protect
           (progn (load (expand-file-name "modules/ui/drgnx-tty-frames" drgnx-dir) nil t)
                  (load (expand-file-name "modules/ui/drgnx-tty-keys" drgnx-dir) nil t)
                  ,@body)
         (advice-remove 'drgnx-chrome-close-tab #'drgnx-tty-frames--close-tab)
         (advice-remove 'drgnx-chrome--close-clicked #'drgnx-tty-frames--close-clicked)
         (delete-directory cfg t)))))

(defun drgnx-tty-keys-test--status (module)
  (plist-get (alist-get module (drgnx-modules-report)) :status))

(ert-deftest drgnx-tty-keys/the-module-waits-without-kkp ()
  (let ((load-path (seq-remove (lambda (d) (string-match-p "/kkp-[0-9]" d)) load-path))
        (orig (symbol-function 'featurep))
        (orig-locate (symbol-function 'locate-library)))
    (cl-letf (((symbol-function 'locate-library)
               (lambda (lib &rest r) (unless (equal lib "kkp") (apply orig-locate lib r))))
              ((symbol-function 'featurep) (lambda (f &rest r) (and (not (eq f 'kkp)) (apply orig f r)))))
      (drgnx-tty-keys-test--modules
       (drgnx-modules-run 'startup)
       (should (eq (drgnx-tty-keys-test--status 'ui/terminal) 'ok))
       (should (eq (drgnx-tty-keys-test--status 'ui/terminal-keys) 'missing-packages))
       (should (equal (plist-get (alist-get 'ui/terminal-keys (drgnx-modules-report)) :missing) '(kkp)))
       ;; the terminal windows' own setup is there; the keys' is not
       (should (memq #'drgnx-tty-frames-setup tty-setup-hook))
       (should-not (memq #'drgnx-tty-keys-setup tty-setup-hook))))))

(defconst drgnx-tty-keys-test--fake-kkp
  "(defvar kkp-restore-legacy-keys-around-subprocesses nil)
(defvar kkp-terminal-query-timeout 2)
(defvar kkp-terminal-setup-complete-hook nil)
(defvar kkp-terminal-teardown-complete-hook nil)
(defvar kx-kkp-saw nil)
(define-minor-mode global-kkp-mode \"A fake.\" :global t
  (push (list global-kkp-mode kkp-restore-legacy-keys-around-subprocesses kkp-terminal-query-timeout) kx-kkp-saw))
(provide 'kkp)
"
  "A kkp that records what its options were when its mode changed.")

(ert-deftest drgnx-tty-keys/kkp-is-on-with-c-g-covered ()
  (let* ((dir (make-temp-file "drgnx-fake-kkp" t))
         (load-path (cons dir load-path)))
    (drgnx-tty-keys-test--unload-kkp)
    (unwind-protect
        (progn
          (write-region drgnx-tty-keys-test--fake-kkp nil (expand-file-name "kkp.el" dir) nil 'silent)
          (drgnx-tty-keys-test--modules
           (drgnx-modules-run 'startup)
           (should (eq (drgnx-tty-keys-test--status 'ui/terminal-keys) 'ok))
           ;; the mode went on with kkp's subprocess option already set (it is read when the mode turns on), and
           ;; drgnx's query bound: kkp's wait for the terminal's answer is drgnx's 0.2 s, not kkp's 2
           (should (equal (symbol-value 'kx-kkp-saw) (list (list t t drgnx-tty-frames-query-timeout))))
           (should (memq #'drgnx-tty-keys--kkp-on (symbol-value 'kkp-terminal-setup-complete-hook)))
           (should (memq #'drgnx-tty-keys-setup tty-setup-hook))))
      (drgnx-tty-keys-test--unload-kkp)
      (delete-directory dir t))))

(ert-deftest drgnx-tty-keys/the-pinned-kkp-has-the-subprocess-option ()
  ;; the real kkp: its option advises `call-process' (`process-file' runs it for local files), and the advice
  ;; switches a terminal to legacy keys only where kkp is active
  (skip-unless (drgnx-tty-keys-test--kkp-dir))
  (drgnx-tty-keys-test--unload-kkp)
  (let ((load-path (cons (drgnx-tty-keys-test--kkp-dir) load-path))
        (sent nil))
    (unwind-protect
        (drgnx-tty-keys-test--modules
         (drgnx-modules-run 'startup)
         (should (eq (drgnx-tty-keys-test--status 'ui/terminal-keys) 'ok))
         (should (symbol-value 'global-kkp-mode))
         (should (advice-member-p 'kkp-restore-legacy-keys 'call-process))
         (cl-letf (((symbol-function 'send-string-to-terminal) (lambda (s &rest _) (push s sent))))
           (should (eq (call-process "true") 0))
           (should-not sent)))
      (drgnx-tty-keys-test--unload-kkp))))

;;;; modifyOtherKeys

(defvar drgnx-tty-keys-test--params nil "The fake terminal's parameters (an alist).")

(defmacro drgnx-tty-keys-test--terminal (params env tmux-out &rest body)
  "BODY with a fake terminal holding PARAMS (an alist), the selected frame's client environment ENV (\"K=V\"),
a fake `tmux' printing TMUX-OUT on PATH, and no terminal to ask.  `sent' collects what was sent to the terminal,
`reports' the report refreshes."
  (declare (indent 3))
  `(let* ((drgnx-tty-keys-test--params (copy-alist ,params))
          (drgnx-tty-frames--cache (make-hash-table :test #'equal))
          (bin (make-temp-file "drgnx-fake-tmux" t))
          (exec-path (cons bin exec-path))
          (real-frame-parameter (symbol-function 'frame-parameter))
          (sent nil) (reports 0))
     (write-region (format "#!/bin/sh\nprintf '%%s' '%s'\n" ,tmux-out) nil (expand-file-name "tmux" bin) nil 'silent)
     (set-file-modes (expand-file-name "tmux" bin) #o755)
     (unwind-protect
         (cl-letf (((symbol-function 'frame-parameter)
                    (lambda (f p) (if (eq p 'environment) ,env (funcall real-frame-parameter f p))))
                   ((symbol-function 'frame-terminal) (lambda (&optional _) 'kx-a))
                   ((symbol-function 'terminal-name) (lambda (&optional _) "kx-a"))
                   ((symbol-function 'terminal-live-p) (lambda (_term) t))
                   ((symbol-function 'terminal-parameter)
                    (lambda (_term p) (alist-get p drgnx-tty-keys-test--params)))
                   ((symbol-function 'set-terminal-parameter)
                    (lambda (_term p v) (setf (alist-get p drgnx-tty-keys-test--params) v)))
                   ((symbol-function 'send-string-to-terminal) (lambda (s &rest _) (setq sent (append sent (list s)))))
                   ((symbol-function 'drgnx-tty-frames--ask) (lambda (_frame) nil))
                   ((symbol-function 'drgnx-tty-frames-refresh-report) (lambda (_frame) (setq reports (1+ reports))))
                   ((symbol-function 'display-color-cells) (lambda (&optional _) 256)))
           (let ((parent (keymap-parent input-decode-map)))
             (unwind-protect (progn ,@body)
               (set-keymap-parent input-decode-map parent))))
       (delete-directory bin t))))

(defconst drgnx-tty-keys-test--chords '("C-S-p" "C-S-f" "C-S-e" "C-`" "C-." "C-S-`" "C-S-SPC" "C-S-<return>"
                                        "C-<tab>" "C-," "C-;" "C-=" "C-M-S-k")
  "Chords only an extended key protocol sends (the VS Code profile binds most of them).")

(ert-deftest drgnx-tty-keys/tmux-gets-modify-other-keys ()
  ;; TERM=xterm-256color inside tmux: Emacs asked tmux (DA2: version 0) and did not turn modifyOtherKeys on;
  ;; extended-keys is on, so drgnx asks for it, and decodes what tmux then sends
  (drgnx-tty-keys-test--terminal nil '("TERM=xterm-256color" "TMUX=/tmp/kx-sock,1,0") "external\non\n"
    (drgnx-tty-keys-setup (selected-frame))
    (should (member "\e[>4;1m" (terminal-parameter nil 'tty-mode-set-strings)))
    (should (member "\e[>4m" (terminal-parameter nil 'tty-mode-reset-strings)))
    (should (equal sent '("\e[>4;1m")))
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'mok))
    (should (= reports 1))
    (dolist (key drgnx-tty-keys-test--chords)
      (should (equal (list key (lookup-key input-decode-map (drgnx-tty-session-encode key 'mok)))
                     (list key (kbd key)))))
    ;; Emacs's own decodings stay (xterm.el's C-tab and friends come first), and a second setup adds nothing
    (drgnx-tty-keys-setup (selected-frame))
    (should (equal sent '("\e[>4;1m")))
    (should (= (seq-count (lambda (s) (equal s "\e[>4;1m")) (terminal-parameter nil 'tty-mode-set-strings)) 1)))
  ;; always: the same
  (drgnx-tty-keys-test--terminal nil '("TERM=xterm-256color" "TMUX=/tmp/kx-sock,1,0") "on\nalways\n"
    (drgnx-tty-keys-setup (selected-frame))
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'mok)))
  ;; TERM=tmux-256color: Emacs's term/tmux.el already asked; nothing is sent twice
  (drgnx-tty-keys-test--terminal '((tty-mode-set-strings . ("\e[>4;1m")) (tty-mode-reset-strings . ("\e[>4m")))
      '("TERM=tmux-256color" "TMUX=/tmp/kx-sock,1,0") "on\non\n"
    (drgnx-tty-keys-setup (selected-frame))
    (should-not sent)
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'mok)))
  ;; a tmux on the other side of SSH (TERM=tmux-*, no TMUX): its options are unknown, Emacs's request stays
  (drgnx-tty-keys-test--terminal '((tty-mode-set-strings . ("\e[>4;1m")) (tty-mode-reset-strings . ("\e[>4m")))
      '("TERM=tmux-256color") "on\noff\n"
    (drgnx-tty-keys-setup (selected-frame))
    (should-not sent)
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'mok))))

(ert-deftest drgnx-tty-keys/tmux-without-extended-keys-is-legacy ()
  ;; tmux's default: extended-keys off.  tmux sends no modifyOtherKeys then, so the request Emacs's
  ;; term/tmux.el made is withdrawn and the terminal is legacy: the report lists C-S-p as unsendable
  (drgnx-tty-keys-test--terminal '((tty-mode-set-strings . ("\e[?2004h" "\e[>4;1m"))
                                   (tty-mode-reset-strings . ("\e[>4m" "\e[?2004l")))
      '("TERM=tmux-256color" "TMUX=/tmp/kx-sock,1,0") "on\noff\n"
    (drgnx-tty-keys-setup (selected-frame))
    (should (equal sent '("\e[>4m")))
    (should (equal (terminal-parameter nil 'tty-mode-set-strings) '("\e[?2004h")))
    (should (equal (terminal-parameter nil 'tty-mode-reset-strings) '("\e[?2004l")))
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'legacy))
    (should (= reports 1))
    (should (member "C-S-p" (drgnx-tty-unsendable '("C-S-p" "C-p") (plist-get (drgnx-tty-frame-caps) :keys)))))
  ;; a tmux that does not answer (no extended-keys before 3.2, or no server): nothing changes
  (drgnx-tty-keys-test--terminal '((tty-mode-set-strings . ("\e[>4;1m")) (tty-mode-reset-strings . ("\e[>4m")))
      '("TERM=tmux-256color" "TMUX=/tmp/kx-sock,1,0") ""
    (drgnx-tty-keys-setup (selected-frame))
    (should-not sent)
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'mok))))

(ert-deftest drgnx-tty-keys/kkp-marks-the-terminal ()
  ;; kkp's setup hook (a frame of the terminal selected): the terminal is kkp, its report written again; kkp's
  ;; teardown (suspend, the last frame closed) takes the mark away
  (drgnx-tty-keys-test--terminal nil '("TERM=xterm-kitty") ""
    (drgnx-tty-keys--kkp-on)
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'kkp))
    (should (= reports 1))
    (drgnx-tty-keys--kkp-off)
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'legacy))))

(provide 'mod-tty-keys-test)
;;; mod-tty-keys-test.el ends here
