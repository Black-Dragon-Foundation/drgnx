;;; mod-tty-keys-test.el --- batch tests: terminal keys — modifyOtherKeys (ui/terminal), kkp (ui/terminal-keys), C-g -*- lexical-binding: t -*-
;; Batch Emacs has no terminal: terminals, their parameters and tmux are stubbed; the tty tier
;; (test/tty/keys-test.el) sends the real bytes.  kkp is a fake here unless a test says otherwise.
(require 'ert)
(require 'drgnx)
(require 'drgnx-tty-session)
(load (expand-file-name "modules/ui/drgnx-tty-frames" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-tty-keys" drgnx-dir) nil t)

(defun drgnx-tty-keys-test--pinned ()
  "The kkp entry of the shipped lock (etc/drgnx.lock.eld): (VERSION . SHA256)."
  (let ((e (alist-get 'kkp (plist-get (with-temp-buffer
                                        (insert-file-contents (expand-file-name "etc/drgnx.lock.eld" drgnx-dir))
                                        (read (current-buffer)))
                                      :packages))))
    (cons (plist-get e :version) (plist-get e :sha256))))

(defun drgnx-tty-keys-test--kkp-dir ()
  "The pinned kkp's directory in DRGNX_USER_ELPA (read-only), or nil."
  (let ((dir (expand-file-name (concat "kkp-" (car (drgnx-tty-keys-test--pinned))) (or (getenv "DRGNX_USER_ELPA") "/nonexistent"))))
    (and (file-directory-p dir) dir)))

(defun drgnx-tty-keys-test--need-kkp ()
  "Skip, saying how to supply it, unless the pinned kkp is in DRGNX_USER_ELPA."
  (unless (drgnx-tty-keys-test--kkp-dir)
    (let ((pin (drgnx-tty-keys-test--pinned)))
      (ert-skip (format "kkp %s not in DRGNX_USER_ELPA: unpack https://melpa.org/packages/kkp-%s.tar (sha256 %s) \
into a directory and set DRGNX_USER_ELPA to it, or point DRGNX_USER_ELPA at an elpa drgnx sync filled"
                        (car pin) (car pin) (cdr pin))))))

(defun drgnx-tty-keys-test--unload-kkp ()
  "Turn kkp's mode off and unload it (the fake or the real one), so the next test loads its own."
  (when (featurep 'kkp)
    (when (fboundp 'global-kkp-mode) (funcall 'global-kkp-mode -1))
    (unload-feature 'kkp t))
  (advice-remove 'kkp-enable-in-terminal #'drgnx-tty-keys--enable-guard)
  (advice-remove 'kkp--terminal-setup #'drgnx-tty-keys--kkp-setup-guard))

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

(defmacro drgnx-tty-keys-test--without-kkp (&rest body)
  "BODY where the kkp package cannot be found."
  `(let ((load-path (seq-remove (lambda (d) (string-match-p "/kkp-[0-9]" d)) load-path))
         (orig (symbol-function 'featurep))
         (orig-locate (symbol-function 'locate-library)))
     (cl-letf (((symbol-function 'locate-library)
                (lambda (lib &rest r) (unless (equal lib "kkp") (apply orig-locate lib r))))
               ((symbol-function 'featurep) (lambda (f &rest r) (and (not (eq f 'kkp)) (apply orig f r)))))
       ,@body)))

(defun drgnx-tty-keys-test--status (module)
  (plist-get (alist-get module (drgnx-modules-report)) :status))

;;;; A fake terminal

(defvar drgnx-tty-keys-test--params nil "The fake terminal's parameters (an alist).")

(defmacro drgnx-tty-keys-test--terminal (params env tmux-out &rest body)
  "BODY with a fake terminal holding PARAMS (an alist), the selected frame's client environment ENV (\"K=V\"),
a fake `tmux' printing TMUX-OUT on PATH (the display line, then NAME VALUE option lines), and no terminal to ask.  `sent' collects what was sent to the terminal,
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
                   ((symbol-function 'frames-on-display-list) (lambda (&optional _) (list (selected-frame))))
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

(defconst drgnx-tty-keys-test--asked '((tty-mode-set-strings . ("\e[>4;1m")) (tty-mode-reset-strings . ("\e[>4m")))
  "A terminal for which Emacs's xterm.el asked for modifyOtherKeys.")

(defconst drgnx-tty-keys-test--chords '("C-S-p" "C-S-f" "C-S-e" "C-`" "C-." "C-S-`" "C-S-SPC" "C-S-<return>"
                                        "C-<tab>" "C-," "C-;" "C-=" "C-M-S-k")
  "Chords only an extended key protocol sends (the VS Code profile binds most of them).")

(defun drgnx-tty-keys-test--decodes ()
  "Every chord of `drgnx-tty-keys-test--chords', as modifyOtherKeys sends it, decodes to that key."
  (dolist (key drgnx-tty-keys-test--chords)
    (should (equal (list key (lookup-key input-decode-map (drgnx-tty-session-encode key 'mok)))
                   (list key (kbd key))))))

;;;; The module and kkp

(ert-deftest drgnx-tty-keys/the-module-waits-without-kkp ()
  (drgnx-tty-keys-test--without-kkp
   (drgnx-tty-keys-test--modules
    (drgnx-modules-run 'startup)
    (should (eq (drgnx-tty-keys-test--status 'ui/terminal) 'ok))
    (should (eq (drgnx-tty-keys-test--status 'ui/terminal-keys) 'missing-packages))
    (should (equal (plist-get (alist-get 'ui/terminal-keys (drgnx-modules-report)) :missing) '(kkp)))
    (should (memq #'drgnx-tty-frames-setup tty-setup-hook)))))

(ert-deftest drgnx-tty-keys/modify-other-keys-without-kkp ()
  ;; modifyOtherKeys is ui/terminal's: an xterm works with kkp missing.  Before drgnx decodes it, the terminal is
  ;; legacy even though Emacs asked for it (C-S-p would type text); after, it is mok and C-S-p arrives
  (drgnx-tty-keys-test--without-kkp
   (drgnx-tty-keys-test--modules
    (drgnx-modules-run 'startup)
    (should (eq (drgnx-tty-keys-test--status 'ui/terminal-keys) 'missing-packages))
    (drgnx-tty-keys-test--terminal drgnx-tty-keys-test--asked '("TERM=xterm-256color" "XTERM_VERSION=XTerm(397)") ""
      (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'legacy))
      (drgnx-tty-frames--keys-setup (selected-frame))
      (let ((caps (drgnx-tty-frame-caps)))
        (should (eq (plist-get caps :id) 'xterm))
        (should (eq (plist-get caps :keys) 'mok))
        (should (eq (plist-get caps :c-g) 'always)))
      (should-not sent)
      (drgnx-tty-keys-test--decodes)))))

(defconst drgnx-tty-keys-test--fake-kkp
  "(defvar kkp-restore-legacy-keys-around-subprocesses nil)
(defvar kkp-terminal-query-timeout 2)
(defvar kkp-terminal-setup-complete-hook nil)
(defvar kkp-terminal-teardown-complete-hook nil)
(defvar kx-kkp-saw nil)
(defun kkp-enable-in-terminal (&optional _terminal) nil)
(defun kkp--terminal-setup () nil)
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
           ;; kkp asks only where it is wanted, and a setup it cannot finish is undone
           (should (advice-member-p #'drgnx-tty-keys--enable-guard 'kkp-enable-in-terminal))
           (should (advice-member-p #'drgnx-tty-keys--kkp-setup-guard 'kkp--terminal-setup))))
      (drgnx-tty-keys-test--unload-kkp)
      (delete-directory dir t))))

(ert-deftest drgnx-tty-keys/the-pinned-kkp-has-the-subprocess-option ()
  ;; the real kkp: its option advises `call-process' (`process-file' runs it for local files), and the advice
  ;; switches a terminal to legacy keys only where kkp is active
  (drgnx-tty-keys-test--need-kkp)
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

(ert-deftest drgnx-tty-keys/modify-other-keys-is-preferred-to-kkp ()
  ;; kkp is asked for only in a terminal without modifyOtherKeys (kitty); with modifyOtherKeys C-g stays a plain
  ;; byte and interrupts busy Lisp too.  `drgnx-tty-use-kkp' nil: never
  (let ((asked nil))
    (cl-flet ((try (params env)
                (setq asked nil)
                (drgnx-tty-keys-test--terminal params env ""
                  (drgnx-tty-keys--enable-guard (lambda (&rest _) (setq asked t)))
                  (list asked (plist-get (drgnx-tty-frame-caps) :keys)))))
      (let ((drgnx-tty-use-kkp t))
        (should (equal (try nil '("TERM=xterm-kitty")) '(t legacy)))                         ; kitty: kkp asked
        (should (equal (try nil '("TERM=xterm-256color" "TERM_PROGRAM=WezTerm")) '(nil legacy))) ; its row: mok
        (should (equal (car (try drgnx-tty-keys-test--asked '("TERM=xterm-256color" "XTERM_VERSION=XTerm(397)")))
                       nil))                                                                 ; Emacs asked for mok
        (should (equal (car (try nil '("TERM=tmux-256color"))) nil)))                        ; tmux passes no kkp
      (let ((drgnx-tty-use-kkp nil))
        ;; kkp off: kitty is asked nothing and stays legacy (C-S-p is listed as a key it cannot send)
        (should (equal (try nil '("TERM=xterm-kitty")) '(nil legacy)))))))

(ert-deftest drgnx-tty-keys/a-kkp-setup-that-cannot-finish-is-undone ()
  ;; a link slower than the 0.2 s wait: the terminal answered kkp's question, kkp pushed its flags, then its
  ;; confirmation (CSI ? u) did not come.  kkp 20260706.858 signals there, before it decodes anything: drgnx pops
  ;; the flags again, the keys stay plain, the problem is recorded
  (drgnx-tty-keys-test--need-kkp)
  (drgnx-tty-keys-test--unload-kkp)
  (let ((load-path (cons (drgnx-tty-keys-test--kkp-dir) load-path))
        (drgnx-hooks-problems nil))
    (unwind-protect
        (drgnx-tty-keys-test--modules
         (drgnx-modules-run 'startup)
         (drgnx-tty-keys-test--terminal nil '("TERM=xterm-kitty") ""
           (let ((input (append "5u\e[?62c" nil)))
             (cl-letf (((symbol-function 'read-event) (lambda (&rest _) (pop input)))
                       ((symbol-function 'kkp--query-terminal-sync) (lambda (&rest _) nil)))
               (funcall 'kkp--terminal-setup)))
           (should (equal sent (list (format "\e[>%du" (funcall 'kkp--calculate-flags-integer)) "\e[<u")))
           (should-not (funcall 'kkp--active-p 'kx-a))
           (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'legacy))
           (should (string-match-p "ui/terminal-keys: kkp did not finish" (car drgnx-hooks-problems)))))
      (drgnx-tty-keys-test--unload-kkp))))

;;;; modifyOtherKeys under tmux

(ert-deftest drgnx-tty-keys/tmux-gets-modify-other-keys ()
  ;; TERM=xterm-256color inside tmux: Emacs asked tmux (DA2: version 0) and did not turn modifyOtherKeys on;
  ;; extended-keys is on, so drgnx asks for it, and decodes what tmux then sends
  (drgnx-tty-keys-test--terminal nil '("TERM=xterm-256color" "TMUX=/tmp/kx-sock,1,0") "3.4|xterm-kitty|256|\nset-clipboard external\nextended-keys on\n"
    (drgnx-tty-frames--keys-setup (selected-frame))
    (should (member "\e[>4;1m" (terminal-parameter nil 'tty-mode-set-strings)))
    (should (member "\e[>4m" (terminal-parameter nil 'tty-mode-reset-strings)))
    (should (equal sent '("\e[>4;1m")))
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'mok))
    (drgnx-tty-keys-test--decodes)
    ;; Emacs's own decodings stay (xterm.el's C-tab and friends come first), and a second setup adds nothing
    (drgnx-tty-frames--keys-setup (selected-frame))
    (should (equal sent '("\e[>4;1m")))
    (should (= (seq-count (lambda (s) (equal s "\e[>4;1m")) (terminal-parameter nil 'tty-mode-set-strings)) 1)))
  ;; always: the same
  (drgnx-tty-keys-test--terminal nil '("TERM=xterm-256color" "TMUX=/tmp/kx-sock,1,0") "3.4|xterm-kitty|256|\nset-clipboard on\nextended-keys always\n"
    (drgnx-tty-frames--keys-setup (selected-frame))
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'mok)))
  ;; TERM=tmux-256color: Emacs's term/tmux.el already asked; nothing is sent twice
  (drgnx-tty-keys-test--terminal drgnx-tty-keys-test--asked '("TERM=tmux-256color" "TMUX=/tmp/kx-sock,1,0") "3.4|xterm-kitty|256|\nset-clipboard on\nextended-keys on\n"
    (drgnx-tty-frames--keys-setup (selected-frame))
    (should-not sent)
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'mok)))
  ;; a tmux on the other side of SSH (TERM=tmux-*, no TMUX): its options are unknown, Emacs's request stays
  (drgnx-tty-keys-test--terminal drgnx-tty-keys-test--asked '("TERM=tmux-256color") "3.4|xterm-kitty|256|\nset-clipboard on\nextended-keys off\n"
    (drgnx-tty-frames--keys-setup (selected-frame))
    (should-not sent)
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'mok))))

(ert-deftest drgnx-tty-keys/tmux-without-extended-keys-is-legacy ()
  ;; tmux's default: extended-keys off.  tmux sends no modifyOtherKeys then, so the request Emacs's
  ;; term/tmux.el made is withdrawn and the terminal is legacy: the report lists C-S-p as unsendable
  (drgnx-tty-keys-test--terminal '((tty-mode-set-strings . ("\e[?2004h" "\e[>4;1m"))
                                   (tty-mode-reset-strings . ("\e[>4m" "\e[?2004l")))
      '("TERM=tmux-256color" "TMUX=/tmp/kx-sock,1,0") "3.4|xterm-kitty|256|\nset-clipboard on\nextended-keys off\n"
    (drgnx-tty-frames--keys-setup (selected-frame))
    (should (equal sent '("\e[>4m")))
    (should (equal (terminal-parameter nil 'tty-mode-set-strings) '("\e[?2004h")))
    (should (equal (terminal-parameter nil 'tty-mode-reset-strings) '("\e[?2004l")))
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'legacy))
    (should (member "C-S-p" (drgnx-tty-unsendable '("C-S-p" "C-p") (plist-get (drgnx-tty-frame-caps) :keys)))))
  ;; a tmux whose extended-keys cannot be read (older than 3.2: the option does not exist; or no answer): it is
  ;; not known to pass modifyOtherKeys, so legacy too
  (dolist (out '("3.4|xterm-kitty|256|\nset-clipboard on\n" ""))
    (drgnx-tty-keys-test--terminal drgnx-tty-keys-test--asked '("TERM=tmux-256color" "TMUX=/tmp/kx-sock,1,0") out
      (drgnx-tty-frames--keys-setup (selected-frame))
      (should (equal sent '("\e[>4m")))
      (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'legacy)))))

(ert-deftest drgnx-tty-keys/kkp-marks-the-terminal ()
  ;; kkp's setup hook (a frame of the terminal selected): the terminal is kkp, its report written again, and C-g
  ;; there interrupts only waits for programs; kkp's teardown (suspend, the last frame closed) takes it away
  (drgnx-tty-keys-test--terminal nil '("TERM=xterm-kitty") ""
    (drgnx-tty-keys--kkp-on)
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'kkp))
    (should (eq (plist-get (drgnx-tty-frame-caps) :c-g) 'waits))
    (should (= reports 1))
    (drgnx-tty-keys--kkp-off)
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'legacy))
    (should (eq (plist-get (drgnx-tty-frame-caps) :c-g) 'always))))

;;;; A known terminal's row decides (re-review of the fix round)

(ert-deftest drgnx-tty-keys/a-known-terminals-row-decides-between-mok-and-kkp ()
  ;; Alacritty: Emacs's DA2 test turned modifyOtherKeys on, but the row says it has none (kkp only): the request is
  ;; withdrawn, the terminal is not mok, and kkp is wanted.  Ghostty: its row's :mok is unconfirmed (and probably
  ;; level 2 only), its kkp is confirmed: kkp too.  WezTerm and xterm: confirmed mok, asked for
  (let ((drgnx-tty-use-kkp t))
    (dolist (case '(("TERM=alacritty" "ALACRITTY_SOCKET=/tmp/a") ("TERM=xterm-ghostty")))
      (drgnx-tty-keys-test--terminal drgnx-tty-keys-test--asked case ""
        (drgnx-tty-frames--keys-setup (selected-frame))
        (should (equal sent '("\e[>4m")))
        (should-not (drgnx-tty-frames-mok-asked-p 'kx-a))
        (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'legacy))
        (let (asked)
          (drgnx-tty-keys--enable-guard (lambda (&rest _) (setq asked t)))
          (should asked)))
      ;; Emacs did not ask: drgnx does not either
      (drgnx-tty-keys-test--terminal nil case ""
        (drgnx-tty-frames--keys-setup (selected-frame))
        (should-not sent)
        (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'legacy))))
    ;; even with the request standing (a stale one), the caps never say mok for such a row
    (drgnx-tty-keys-test--terminal (cons '(drgnx-tty-mok-decoded . t) drgnx-tty-keys-test--asked) '("TERM=alacritty") ""
      (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'legacy)))
    (drgnx-tty-keys-test--terminal nil '("TERM=xterm-256color" "TERM_PROGRAM=WezTerm") ""
      (drgnx-tty-frames--keys-setup (selected-frame))
      (should (equal sent '("\e[>4;1m")))
      (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'mok)))))

(ert-deftest drgnx-tty-keys/kkp-setup-guard-needs-kkp-s-private-functions ()
  ;; kkp--terminal-setup is private: advised only where it exists, else a problem says so; a failed setup pops the
  ;; flags unless kkp is known to be active
  (let ((dir (make-temp-file "drgnx-fake-kkp" t))
        (load-path nil) (drgnx-hooks-problems nil))
    (setq load-path (cons dir load-path))
    (drgnx-tty-keys-test--unload-kkp)
    (unwind-protect
        (progn
          (write-region (replace-regexp-in-string "(defun kkp--terminal-setup () nil)\n" "" drgnx-tty-keys-test--fake-kkp)
                        nil (expand-file-name "kkp.el" dir) nil 'silent)
          (drgnx-tty-keys-test--modules
           (drgnx-modules-run 'startup)
           (should-not (advice-member-p #'drgnx-tty-keys--kkp-setup-guard 'kkp--terminal-setup))
           (should (seq-some (lambda (p) (string-match-p "kkp--terminal-setup" p)) drgnx-hooks-problems))))
      (drgnx-tty-keys-test--unload-kkp)
      (delete-directory dir t)))
  ;; the failure path with kkp's `kkp--active-p' missing: the flags are popped all the same
  (drgnx-tty-keys-test--terminal nil '("TERM=xterm-kitty") ""
    (let ((drgnx-hooks-problems nil))
      (should-not (fboundp 'kkp--active-p))
      (drgnx-tty-keys--kkp-setup-guard (lambda (&rest _) (error "boom")))
      (should (equal sent '("\e[<u")))
      (should (string-match-p "kkp did not finish" (car drgnx-hooks-problems))))))

(ert-deftest drgnx-tty-keys/a-failed-report-does-not-undo-kkp ()
  ;; kkp is on; writing the report fails (a full disk, say): kkp stays on and the problem is recorded
  (drgnx-tty-keys-test--terminal nil '("TERM=xterm-kitty") ""
    (let ((drgnx-hooks-problems nil))
      (cl-letf (((symbol-function 'drgnx-tty-frames-refresh-report) (lambda (_f) (error "disk full"))))
        (drgnx-tty-keys--kkp-on))
      (should (terminal-parameter nil 'drgnx-tty-kkp))
      (should (string-match-p "disk full" (car drgnx-hooks-problems))))))

(ert-deftest drgnx-tty-keys/a-declined-terminal-stays-declined ()
  ;; kkp re-checks on every focus-in; a terminal drgnx declined once (use-kkp nil at that time) is not asked later,
  ;; so the setting applies to terminal windows opened afterwards, as documented
  (let (asked)
    (drgnx-tty-keys-test--terminal nil '("TERM=xterm-kitty") ""
      (let ((drgnx-tty-use-kkp nil))
        (drgnx-tty-keys--enable-guard (lambda (&rest _) (setq asked t))))
      (should-not asked)
      (let ((drgnx-tty-use-kkp t))
        (drgnx-tty-keys--enable-guard (lambda (&rest _) (setq asked t))))
      (should-not asked))
    ;; a terminal opened after the setting changed is asked
    (drgnx-tty-keys-test--terminal nil '("TERM=xterm-kitty") ""
      (let ((drgnx-tty-use-kkp t))
        (drgnx-tty-keys--enable-guard (lambda (&rest _) (setq asked t))))
      (should asked))))

(ert-deftest drgnx-tty-keys/a-late-kkp-reply-after-the-pop-is-swallowed ()
  ;; the confirmation (CSI ? N u) of a setup drgnx popped may still arrive: it must not type M-[ ? 5 u.  kkp's
  ;; reply handler unregisters itself with an explicit nil on "ESC [ ?" before it calls the setup: the swallowing
  ;; entries have to live in the map itself, not in a parent the nil hides
  (let ((input-decode-map (copy-keymap input-decode-map)))
    (drgnx-tty-keys-test--terminal nil '("TERM=xterm-kitty") ""
      (let ((drgnx-hooks-problems nil))
        (define-key input-decode-map "\e[?" #'ignore)     ; kkp's handler
        (define-key input-decode-map "\e[?" nil)          ; …unregistered before the setup, as kkp does
        (drgnx-tty-keys--kkp-setup-guard (lambda (&rest _) (error "boom")))
        (dolist (n '(0 5 31))
          (let ((def (lookup-key input-decode-map (format "\e[?%du" n))))
            (should (functionp def))
            (should (equal (funcall def nil) []))))
        ;; other replies are left alone
        (should (numberp (lookup-key input-decode-map "\e[?32u")))))))

(ert-deftest drgnx-tty-keys/only-use-kkp-nil-declines-for-good ()
  ;; a terminal declined on transient facts (tmux here; an unknown terminal whose late XTVERSION names Alacritty)
  ;; is checked again at the next focus-in
  (let (asked)
    (drgnx-tty-keys-test--terminal nil '("TERM=tmux-256color") ""
      (let ((drgnx-tty-use-kkp t))
        (drgnx-tty-keys--enable-guard (lambda (&rest _) (setq asked t))))
      (should-not asked)
      (should-not (terminal-parameter nil 'drgnx-tty-kkp-declined)))))

(provide 'mod-tty-keys-test)
;;; mod-tty-keys-test.el ends here
