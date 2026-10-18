;;; keys-test.el --- tty tier: C-S- chords through kkp or modifyOtherKeys; C-g still interrupts -*- lexical-binding: t -*-
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.  The keys are
;; the bytes a terminal sends (`drgnx-tty-session-key'), fed to the pane unchanged.  tmux does not speak the kitty
;; keyboard protocol: the test answers kkp's question ("yes") and names the terminal (its XTVERSION answer, which
;; tmux would give as tmux); kitty proves it for real (the exit test).  kkp comes from DRGNX_USER_ELPA (read-only,
;; the version etc/drgnx.lock.eld pins); without it the kkp tests skip and say how to supply it.
(require 'ert)
(require 'drgnx-tty-session)
(unless (featurep 'tty-keys-helpers)
  (load (expand-file-name "tty-keys-helpers" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(defun drgnx-tty-keys-test--five (s c caps)
  "The five chords, sent to client C as a terminal with CAPS sends them, reach their commands (VS Code keys)."
  (let ((frame (drgnx-tty-keys-test--frame c))
        (quit (lambda () (drgnx-tty-keys-test--quit s c caps))))
    (drgnx-tty-session-wait-screen c "\\*scratch\\*" 20)
    (drgnx-tty-session-eval s drgnx-tty-keys-test--record)
    ;; C-S-p: the palette's prompt
    (drgnx-tty-session-key c "C-S-p" caps)
    (drgnx-tty-keys-test--ran s 'drgnx-palette "C-S-p")
    (should (equal (drgnx-tty-session-wait s '(minibuffer-prompt)) "Command (# for a code question): "))
    (drgnx-tty-session-wait-screen c "Command (# for a code question)")
    (funcall quit)
    ;; C-S-f: Search in Project
    (drgnx-tty-session-key c "C-S-f" caps)
    (drgnx-tty-keys-test--ran s 'drgnx-wb-view-search "C-S-f")
    (drgnx-tty-session-wait-screen c "SEARCH")
    (funcall quit)
    ;; C-S-e: the Explorer is selected
    (drgnx-tty-session-key c "C-S-e" caps)
    (drgnx-tty-keys-test--ran s 'drgnx-wb-view-explorer "C-S-e")
    (drgnx-tty-session-wait s `(with-current-buffer (window-buffer (frame-selected-window ,frame))
                                 (derived-mode-p 'drgnx-explorer-mode)))
    ;; C-`: the panel, its tab row with the Terminal tab
    (should-not (drgnx-tty-session-eval s `(drgnx-wb-area-window 'panel ,frame)))
    (drgnx-tty-session-key c "C-`" caps)
    (drgnx-tty-keys-test--ran s 'drgnx-wb-toggle-panel "C-`")
    (drgnx-tty-session-wait s `(drgnx-wb-area-window 'panel ,frame))
    (drgnx-tty-session-wait-screen c "Problems +Output +Results +Terminal" 10)
    ;; C-.: the code actions (Quick Fix)
    (drgnx-tty-session-key c "C-." caps)
    (drgnx-tty-keys-test--ran s 'drgnx-lang-quick-fix "C-.")))

(ert-deftest drgnx-tty-keys/c-s-chords-under-modify-other-keys ()
  ;; no kkp in this session: modifyOtherKeys is ui/terminal's and needs no package.  28 lines: the layout
  ;; (ui/terminal-layout) shows the panel from 30 lines, and the chords below open it
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :size "120x28")
    (should (eq (drgnx-tty-session-eval s '(plist-get (alist-get 'ui/terminal-keys (drgnx-modules-report)) :status))
                'missing-packages))
    ;; a client inside tmux, its TMUX naming the session's own server, whose extended-keys is on
    (let ((c (drgnx-tty-session-client s :env (list (format "TMUX=%s,1,0" (plist-get s :tmux))))))
      (drgnx-tty-session-wait-screen c "\\*scratch\\*" 20)
      (should (eq (plist-get (drgnx-tty-keys-test--caps s c) :id) 'tmux))
      (should (eq (plist-get (drgnx-tty-keys-test--caps s c) :keys) 'mok))
      ;; tmux was asked for modifyOtherKeys (its pane is in extended-keys mode)
      (should (equal (plist-get (drgnx-tty-session-pane-flags c) :key-mode) "Ext 1"))
      (drgnx-tty-keys-test--five s c 'mok))))

(defun drgnx-tty-keys-test--busy (s run)
  "A form, in the inner daemon: F12 runs `kx-busy', 30 s of busy Lisp that writes RUN/busy-started first and
sets `kx-returned' when it ends (C-g ends it early)."
  `(progn
     (defvar kx-returned nil)
     (defun kx-busy ()
       (interactive)
       (write-region "" nil ,(expand-file-name "busy-started" run) nil 'silent)
       (let ((t0 (float-time)))
         (unwind-protect (while (< (- (float-time) t0) 30))
           (setq kx-returned (float-time)))))
     (push (list (cons t (let ((m (make-sparse-keymap))) (define-key m [f12] #'kx-busy) m))) emulation-mode-map-alists)
     t))

(ert-deftest drgnx-tty-keys/a-terminal-with-both-gets-modify-other-keys ()
  ;; a terminal that speaks both (WezTerm here) would answer kkp's question with yes, but kkp is never asked:
  ;; modifyOtherKeys is preferred, the chords arrive, and C-g stays a plain byte that stops busy Lisp
  (drgnx-tty-keys-test--need-kkp)
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :env (drgnx-tty-keys-test--env))
    (should (eq (drgnx-tty-session-eval s '(plist-get (alist-get 'ui/terminal-keys (drgnx-modules-report)) :status)) 'ok))
    (drgnx-tty-session-eval s (drgnx-tty-keys-test--kkp-yes "WezTerm 20240203-110809-5046fc22"))
    (drgnx-tty-session-eval s (drgnx-tty-keys-test--busy s (plist-get s :run)))
    (let ((c (drgnx-tty-session-client s :env '("TERM=xterm-256color"))))
      (drgnx-tty-session-wait-screen c "\\*scratch\\*" 20)
      (let ((caps (drgnx-tty-keys-test--caps s c)))
        (should (eq (plist-get caps :id) 'wezterm))
        (should (eq (plist-get caps :keys) 'mok))
        (should (eq (plist-get caps :c-g) 'always)))
      (should (eq (drgnx-tty-session-eval s 'kx-kkp-asked) 0))
      (should (equal (plist-get (drgnx-tty-session-pane-flags c) :key-mode) "Ext 1"))
      (drgnx-tty-session-eval s drgnx-tty-keys-test--record)
      (drgnx-tty-session-key c "C-S-p" 'mok)
      (drgnx-tty-keys-test--ran s 'drgnx-palette "C-S-p")
      (drgnx-tty-keys-test--quit s c 'mok)
      ;; busy Lisp, and C-g as this terminal sends it: the raw byte
      (let ((started (expand-file-name "busy-started" (plist-get s :run))))
        (drgnx-tty-session-key c "<f12>" 'mok)
        (let ((deadline (+ (float-time) 10)))
          (while (and (not (file-exists-p started)) (< (float-time) deadline)) (sleep-for 0.05)))
        (should (file-exists-p started))
        (should (equal (drgnx-tty-session-encode "C-g" 'mok) "\a"))
        (let ((sent (float-time)))
          (drgnx-tty-session-key c "C-g" 'mok)
          (should (< (- (drgnx-tty-session-wait s 'kx-returned 10) sent) 2)))))))

(ert-deftest drgnx-tty-keys/kkp-off-leaves-kitty-legacy ()
  ;; `drgnx-tty-use-kkp' nil: a kitty is asked nothing and reports legacy, its C-S- chords listed as unsendable
  (drgnx-tty-keys-test--need-kkp)
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :env (drgnx-tty-keys-test--env))
    (drgnx-tty-session-eval s (drgnx-tty-keys-test--kkp-yes drgnx-tty-keys-test--kitty))
    (drgnx-tty-session-eval s '(setq drgnx-tty-use-kkp nil))
    (let ((c (drgnx-tty-session-client s :env '("TERM=xterm-256color"))))
      (drgnx-tty-session-wait-screen c "\\*scratch\\*" 20)
      (let ((caps (drgnx-tty-keys-test--caps s c)))
        (should (eq (plist-get caps :id) 'kitty))
        (should (eq (plist-get caps :keys) 'legacy)))
      (should (eq (drgnx-tty-session-eval s 'kx-kkp-asked) 0))
      (let ((tty (drgnx-tty-session-eval s `(terminal-name (frame-terminal ,(drgnx-tty-keys-test--frame c))))))
        (should (member "C-S-p" (drgnx-tty-session-eval
                                 s `(plist-get (cdr (assoc ,tty (plist-get (with-temp-buffer
                                                                             (insert-file-contents
                                                                              (expand-file-name "terminal-report.eld"
                                                                                                (drgnx-state-dir)))
                                                                             (read (current-buffer)))
                                                                           :terminals)))
                                               :unsendable))))))))

(ert-deftest drgnx-tty-keys/c-s-chords-under-kkp ()
  (drgnx-tty-keys-test--need-kkp)
  ;; 28 lines: the layout (ui/terminal-layout) shows the panel from 30 lines, and the chords below open it
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :size "120x28" :env (drgnx-tty-keys-test--env))
    (should (eq (drgnx-tty-session-eval s '(plist-get (alist-get 'ui/terminal-keys (drgnx-modules-report)) :status)) 'ok))
    (drgnx-tty-session-eval s (drgnx-tty-keys-test--kkp-yes drgnx-tty-keys-test--kitty))
    (let ((c (drgnx-tty-session-client s :env '("TERM=xterm-256color"))))
      (drgnx-tty-keys-test--answer-kkp s c)
      (let ((caps (drgnx-tty-keys-test--caps s c)))
        (should (eq (plist-get caps :id) 'kitty))
        (should (eq (plist-get caps :keys) 'kkp))
        ;; recorded for the doctor: C-g there stops programs Emacs waits for, not busy Lisp
        (should (eq (plist-get caps :c-g) 'waits)))
      (drgnx-tty-keys-test--five s c 'kkp))))

(ert-deftest drgnx-tty-keys/c-g-interrupts-a-blocking-git-call ()
  (drgnx-tty-keys-test--need-kkp)
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :env (drgnx-tty-keys-test--env))
    (let* ((run (plist-get s :run))
           (bin (expand-file-name "bin" run))
           (started (expand-file-name "git-started" run))
           (log (expand-file-name "terminal-out.log" run)))
      ;; a git that hangs for 30 s
      (make-directory bin t)
      (drgnx-ui--write (expand-file-name "git" bin) (format "#!/bin/sh\ntouch '%s'\nexec sleep 30\n" started))
      (set-file-modes (expand-file-name "git" bin) #o755)
      (drgnx-tty-session-eval s (drgnx-tty-keys-test--kkp-yes drgnx-tty-keys-test--kitty))
      (drgnx-tty-session-eval
       s `(progn
            ;; what Emacs tells the terminals goes to a file: the test is the terminal and follows it, also
            ;; while Emacs is blocked in the call
            (advice-add 'send-string-to-terminal :before
                        (lambda (string &rest _) (write-region string nil ,log t 'silent))
                        '((name . kx-terminal-out)))
            (setq exec-path (cons ,bin exec-path))
            (defvar kx-returned nil)
            (defun kx-git-status ()
              (interactive)
              (unwind-protect (call-process "git" nil nil nil "status")
                (setq kx-returned (float-time))))
            ;; F12 runs it, ahead of every other keymap
            (push (list (cons t (let ((m (make-sparse-keymap))) (define-key m [f12] #'kx-git-status) m)))
                  emulation-mode-map-alists)
            t))
      (let ((c (drgnx-tty-session-client s :env '("TERM=xterm-256color"))))
        (drgnx-tty-keys-test--answer-kkp s c)
        (drgnx-tty-session-key c "<f12>" 'kkp)
        (let ((deadline (+ (float-time) 10)))
          (while (and (not (file-exists-p started)) (< (float-time) deadline)) (sleep-for 0.05)))
        (should (file-exists-p started))
        ;; a kkp terminal sends C-g as a raw byte only once the program set its flags to 0 (CSI = 0 ; 1 u);
        ;; with kkp's flags still on, it is an escape sequence that a blocked Emacs never reads
        (let* ((out (with-temp-buffer (insert-file-contents log) (buffer-string)))
               (legacy (string-search "\e[=0;1u" out))
               (sent (float-time)))
          (drgnx-tty-session-key c "C-g" (if legacy 'legacy 'kkp))
          (let ((returned (drgnx-tty-session-wait s 'kx-returned 10)))
            (should (< (- returned sent) 2))))
        ;; after the call, the terminal has kkp's flags again
        (should (string-match-p "\e\\[=0;1u.*\e\\[=[1-9][0-9]*;1u"
                                (with-temp-buffer (insert-file-contents log) (buffer-string))))))))

(ert-deftest drgnx-tty-keys/two-terminals-keep-their-own-keys ()
  (drgnx-tty-keys-test--need-kkp)
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :env (drgnx-tty-keys-test--env))
    ;; client B is legacy, like Ptyxis: TERM=xterm-256color, VTE_VERSION, and a VTE's version answer; it has
    ;; neither protocol
    (drgnx-tty-session-eval s (drgnx-tty-keys-test--kkp-yes "VTE(7800)"))
    (let* ((b (drgnx-tty-session-client s :env '("TERM=xterm-256color" "VTE_VERSION=7800")))
           (problems (drgnx-tty-session-eval s 'drgnx-hooks-problems))
           (report '(plist-get (with-temp-buffer
                                 (insert-file-contents (expand-file-name "terminal-report.eld" (drgnx-state-dir)))
                                 (read (current-buffer)))
                               :terminals)))
      (drgnx-tty-session-wait-screen b "\\*scratch\\*" 20)
      (should (eq (plist-get (drgnx-tty-keys-test--caps s b) :id) 'vte))
      ;; client A: a kitty (kkp; its terminal says yes)
      (drgnx-tty-session-eval s (drgnx-tty-keys-test--kkp-yes drgnx-tty-keys-test--kitty))
      (let* ((a (drgnx-tty-session-client s :env '("TERM=xterm-256color")))
             (tty-a (drgnx-tty-session-eval s `(terminal-name (frame-terminal ,(drgnx-tty-keys-test--frame a)))))
             (tty-b (drgnx-tty-session-eval s `(terminal-name (frame-terminal ,(drgnx-tty-keys-test--frame b))))))
        (drgnx-tty-keys-test--answer-kkp s a)
        (should (eq (plist-get (drgnx-tty-keys-test--caps s a) :keys) 'kkp))
        (should (eq (plist-get (drgnx-tty-keys-test--caps s b) :keys) 'legacy))
        (should-not (drgnx-tty-session-eval s `(kkp--active-p (frame-terminal ,(drgnx-tty-keys-test--frame b)))))
        ;; each terminal's report: B lists C-S-p as a key it cannot send, A does not
        (let ((entries (drgnx-tty-session-eval s report)))
          (should (member "C-S-p" (plist-get (cdr (assoc tty-b entries)) :unsendable)))
          (should-not (member "C-S-p" (plist-get (cdr (assoc tty-a entries)) :unsendable)))
          (should (eq (plist-get (plist-get (cdr (assoc tty-a entries)) :caps) :keys) 'kkp)))
        (drgnx-tty-session-eval s drgnx-tty-keys-test--record)
        ;; A's C-S-p bytes open the palette in A
        (drgnx-tty-session-wait-screen a "\\*scratch\\*")
        (drgnx-tty-session-key a "C-S-p" 'kkp)
        (drgnx-tty-keys-test--ran s 'drgnx-palette "C-S-p")
        (drgnx-tty-session-wait-screen a "Command (# for a code question)")
        (drgnx-tty-keys-test--quit s a 'kkp)
        ;; B keeps its legacy keys: F1 opens the palette, C-p (Go to File in VS Code keys) runs, <up> moves up
        (drgnx-tty-session-key b "<f1>" 'legacy)
        (drgnx-tty-keys-test--ran s 'drgnx-palette "<f1>")
        (drgnx-tty-session-wait-screen b "Command (# for a code question)")
        (drgnx-tty-keys-test--quit s b 'legacy)
        (drgnx-tty-session-key b "C-p" 'legacy)
        (drgnx-tty-keys-test--ran s 'project-find-file "C-p")
        (drgnx-tty-session-wait s '(minibuffer-prompt))            ; it asks which project
        (drgnx-tty-keys-test--quit s b 'legacy)
        (let ((line `(with-selected-window (frame-selected-window ,(drgnx-tty-keys-test--frame b)) (line-number-at-pos))))
          (should (> (drgnx-tty-session-eval s line) 1))
          (let ((before (drgnx-tty-session-eval s line)))
            (drgnx-tty-session-key b "<up>" 'legacy)
            (drgnx-tty-session-wait s `(= ,line ,(1- before)))))
        ;; nothing went wrong on the way (no errors from either terminal's setup)
        (should (equal (drgnx-tty-session-eval s 'drgnx-hooks-problems) problems))))))

(provide 'keys-test)
;;; keys-test.el ends here
