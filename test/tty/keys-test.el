;;; keys-test.el --- tty tier: C-S- chords through kkp or modifyOtherKeys; C-g still interrupts -*- lexical-binding: t -*-
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.  The keys are
;; the bytes a terminal sends (`drgnx-tty-session-key'), fed to the pane unchanged.  tmux does not speak the kitty
;; keyboard protocol: kkp's question to the terminal is answered by the test ("yes"); kitty proves it for real
;; (the exit test).  kkp comes from the user's ELPA (DRGNX_USER_ELPA, read-only); without it these tests skip.
(require 'ert)
(require 'drgnx-tty-session)

(defun drgnx-tty-keys-test--kkp-dir ()
  "The directory of the pinned kkp in the user's ELPA (DRGNX_USER_ELPA, read-only), or nil."
  (let ((elpa (getenv "DRGNX_USER_ELPA")))
    (and elpa (file-directory-p elpa) (car (last (directory-files elpa t "\\`kkp-[0-9]"))))))

(defun drgnx-tty-keys-test--env ()
  "The inner Emacs's extra environment: kkp on its load path (read-only, nothing installed)."
  (list (concat "EMACSLOADPATH=" (drgnx-tty-keys-test--kkp-dir) ":")))

(defun drgnx-tty-keys-test--frame (c)
  "A form, in the inner daemon: the frame of client C (the frame on C's pane's tty)."
  (let ((tty (string-trim (drgnx-tty-keys-test--tmux c "display" "-p" "-t" (plist-get c :target) "#{pane_tty}"))))
    `(seq-find (lambda (f) (equal (terminal-name (frame-terminal f)) ,tty)) (frame-list))))

(defun drgnx-tty-keys-test--tmux (sess &rest args)
  "tmux ARGS on SESS's server; its output (the test fails on an error)."
  (let ((r (apply #'drgnx-tty-session-tmux sess args)))
    (should (eq (car r) 0))
    (cdr r)))

(defun drgnx-tty-keys-test--caps (s c)
  "Client C's terminal's capabilities (its terminal parameter `drgnx-tty-caps')."
  (drgnx-tty-session-eval s `(terminal-parameter (frame-terminal ,(drgnx-tty-keys-test--frame c)) 'drgnx-tty-caps)))

(defconst drgnx-tty-keys-test--record
  '(progn
     (defvar kx-seen nil)
     (setq kx-seen nil)
     (add-hook 'pre-command-hook (lambda () (push (cons this-command (key-description (this-command-keys-vector))) kx-seen)))
     t)
  "A form, in the inner daemon: record each command and the key that ran it in `kx-seen', newest first.")

(defconst drgnx-tty-keys-test--kkp-yes
  '(progn
     ;; the question is not sent (tmux would answer its device-attributes half and so say no): the test answers
     (advice-add 'kkp--query-terminal-async :around
                 (lambda (orig &rest args)
                   (cl-letf (((symbol-function 'send-string-to-terminal) #'ignore)) (apply orig args)))
                 '((name . kx-kkp-yes)))
     ;; …and the flags the terminal took are the ones asked for
     (advice-add 'kkp--query-terminal-sync :override
                 (lambda (&rest _) (append (format "\e[?%du" (kkp--calculate-flags-integer)) nil))
                 '((name . kx-kkp-yes)))
     t)
  "A form, in the inner daemon: terminals made from now on answer kkp's question with yes once the test sends
the answer (`drgnx-tty-keys-test--answer-kkp').")

(defun drgnx-tty-keys-test--answer-kkp (s c)
  "Answer kkp's question in client C's terminal as a kkp terminal does (flags, then device attributes); wait
until kkp is on there and drgnx marked it."
  (drgnx-tty-session-send c "\e[?0u\e[?62;22c")
  (drgnx-tty-session-wait s `(let ((term (frame-terminal ,(drgnx-tty-keys-test--frame c))))
                               (and (terminal-parameter term 'drgnx-tty-kkp) (kkp--active-p term)))
                          10))

(defun drgnx-tty-keys-test--ran (s command key)
  "Wait until COMMAND ran from KEY (as `drgnx-tty-keys-test--record' saw it)."
  (drgnx-tty-session-wait s `(and (member (cons ',command ,key) kx-seen) t) 10))

(defun drgnx-tty-keys-test--quit (s c caps)
  "C-g in client C (CAPS) until the minibuffer is gone: a C-g that lands while the palette still fills its list
quits only that (\"[Quit]\"), as it would for a person, who presses it again."
  (let ((tries 0))
    (while (and (drgnx-tty-session-eval s '(and (active-minibuffer-window) t)) (< tries 5))
      (drgnx-tty-session-key c "C-g" caps)
      (setq tries (1+ tries))
      (let ((deadline (+ (float-time) 1)))
        (while (and (drgnx-tty-session-eval s '(and (active-minibuffer-window) t)) (< (float-time) deadline))
          (sleep-for 0.05))))
    (should-not (drgnx-tty-session-eval s '(active-minibuffer-window)))))

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
    (drgnx-tty-keys-test--ran s 'drgnx-search-project "C-S-f")
    (drgnx-tty-session-wait-screen c "Search in project")
    (funcall quit)
    ;; C-S-e: the Explorer is selected
    (drgnx-tty-session-key c "C-S-e" caps)
    (drgnx-tty-keys-test--ran s 'drgnx-explorer-focus "C-S-e")
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
  (skip-unless (drgnx-tty-keys-test--kkp-dir))
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :env (drgnx-tty-keys-test--env))
    ;; a client inside tmux, its TMUX naming the session's own server, whose extended-keys is on
    (let ((c (drgnx-tty-session-client s :env (list (format "TMUX=%s,1,0" (plist-get s :tmux))))))
      (drgnx-tty-session-wait-screen c "\\*scratch\\*" 20)
      (should (eq (plist-get (drgnx-tty-keys-test--caps s c) :id) 'tmux))
      (should (eq (plist-get (drgnx-tty-keys-test--caps s c) :keys) 'mok))
      ;; tmux was asked for modifyOtherKeys (its pane is in extended-keys mode)
      (should (equal (plist-get (drgnx-tty-session-pane-flags c) :key-mode) "Ext 1"))
      (drgnx-tty-keys-test--five s c 'mok))))

(ert-deftest drgnx-tty-keys/c-s-chords-under-kkp ()
  (skip-unless (drgnx-tty-keys-test--kkp-dir))
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :env (drgnx-tty-keys-test--env))
    (should (eq (drgnx-tty-session-eval s '(plist-get (alist-get 'ui/terminal-keys (drgnx-modules-report)) :status)) 'ok))
    (drgnx-tty-session-eval s drgnx-tty-keys-test--kkp-yes)
    (let ((c (drgnx-tty-session-client s)))
      (drgnx-tty-keys-test--answer-kkp s c)
      (should (eq (plist-get (drgnx-tty-keys-test--caps s c) :keys) 'kkp))
      (drgnx-tty-keys-test--five s c 'kkp))))

(ert-deftest drgnx-tty-keys/c-g-interrupts-a-blocking-git-call ()
  (skip-unless (drgnx-tty-keys-test--kkp-dir))
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :env (drgnx-tty-keys-test--env))
    (let* ((run (plist-get s :run))
           (bin (expand-file-name "bin" run))
           (started (expand-file-name "git-started" run))
           (log (expand-file-name "terminal-out.log" run)))
      ;; a git that hangs for 30 s
      (make-directory bin t)
      (drgnx-ui--write (expand-file-name "git" bin) (format "#!/bin/sh\ntouch '%s'\nexec sleep 30\n" started))
      (set-file-modes (expand-file-name "git" bin) #o755)
      (drgnx-tty-session-eval s drgnx-tty-keys-test--kkp-yes)
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
      (let ((c (drgnx-tty-session-client s)))
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
  (skip-unless (drgnx-tty-keys-test--kkp-dir))
  ;; client B (the session's first) is legacy, like Ptyxis: TERM=xterm-256color, VTE_VERSION; kkp's question goes
  ;; out to it and gets no for an answer
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :term "xterm-256color"
                             :env (cons "VTE_VERSION=7800" (drgnx-tty-keys-test--env)))
    (let* ((b s)
           (problems (drgnx-tty-session-eval s 'drgnx-hooks-problems))
           (report '(plist-get (with-temp-buffer
                                 (insert-file-contents (expand-file-name "terminal-report.eld" (drgnx-state-dir)))
                                 (read (current-buffer)))
                               :terminals)))
      (drgnx-tty-session-wait-screen b "\\*scratch\\*" 20)
      (should (eq (plist-get (drgnx-tty-keys-test--caps s b) :id) 'vte))
      ;; client A: kkp (its terminal says yes)
      (drgnx-tty-session-eval s drgnx-tty-keys-test--kkp-yes)
      (let* ((a (drgnx-tty-session-client s :env '("TERM=tmux-256color" "VTE_VERSION=")))
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
