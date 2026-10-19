;;; fallback-test.el --- tty tier: the fallback layer — Alt+Shift where it is free, F6 then the key always -*- lexical-binding: t -*-
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.  A legacy client
;; is a VTE (Ptyxis, GNOME Terminal): TERM=xterm-256color, VTE_VERSION, and VTE's answer to XTVERSION (the test
;; gives it: tmux would answer as tmux).  Keys are the bytes such a terminal sends: Alt+Shift+F is ESC F, F6 is
;; ESC [ 1 7 ~.  The helpers for recording commands, kkp and the clients' frames are tty-keys-helpers.el's.
(require 'ert)
(require 'drgnx-tty-session)
(unless (featurep 'tty-keys-helpers)
  (load (expand-file-name "tty-keys-helpers" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(defun drgnx-tty-fallback-test--says (name)
  "A form, in the inner daemon: terminals made from now on answer XTVERSION as NAME (\"VTE(7800)\")."
  `(progn
     (advice-add 'drgnx-tty-frames--ask :override
                 (lambda (frame)
                   (let ((answer ,(concat "\eP>|" name "\e\\")))
                     (set-terminal-parameter (frame-terminal frame) 'drgnx-tty-xtversion answer)
                     answer))
                 '((name . kx-says)))
     t))

(defconst drgnx-tty-fallback-test--vte '("TERM=xterm-256color" "VTE_VERSION=7800") "A VTE client's environment.")

(defun drgnx-tty-fallback-test--legacy (s)
  "A new VTE client of S, once its frame shows; it has the fallback layer."
  (drgnx-tty-session-eval s (drgnx-tty-fallback-test--says "VTE(7800)"))
  (let ((c (drgnx-tty-session-client s :env drgnx-tty-fallback-test--vte)))
    (drgnx-tty-session-wait-screen c "\\*scratch\\*" 20)
    (should (equal (mapcar (lambda (k) (plist-get (drgnx-tty-keys-test--caps s c) k)) '(:id :keys)) '(vte legacy)))
    (should (drgnx-tty-session-eval s `(terminal-parameter (frame-terminal ,(drgnx-tty-keys-test--frame c)) 'drgnx-tty-fallback)))
    c))

(defun drgnx-tty-fallback-test--decodes-p (s c bytes)
  "A form's value: whether client C's terminal decodes BYTES through the layer (a function in its own map)."
  (drgnx-tty-session-eval s `(with-selected-frame ,(drgnx-tty-keys-test--frame c)
                               (functionp (lookup-key input-decode-map ,bytes)))))

(defun drgnx-tty-fallback-test--ran (s command)
  "Wait until COMMAND ran (whatever the key looked like)."
  (drgnx-tty-session-wait s `(and (assq ',command kx-seen) t) 10))

(defun drgnx-tty-fallback-test--not-run (s command bytes c)
  "Send BYTES to C; once some command ran from them, COMMAND was not it."
  (drgnx-tty-session-eval s '(setq kx-seen nil))
  (drgnx-tty-session-send c bytes)
  (drgnx-tty-session-wait s 'kx-seen 10)
  (sleep-for 0.3)
  (should-not (drgnx-tty-session-eval s `(assq ',command kx-seen))))

(ert-deftest drgnx-tty-fallback/alt-shift-p-is-not-the-palette ()
  ;; ESC P starts a terminal's reply (DCS): Ctrl+Shift+P has no Alt+Shift key, F6 p is its way in
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :size "120x28" :options '(("set" "-s" "extended-keys" "off")))
    (let ((c (drgnx-tty-fallback-test--legacy s)))
      (should-not (drgnx-tty-fallback-test--decodes-p s c "\eP"))
      (drgnx-tty-session-eval s drgnx-tty-keys-test--record)
      (drgnx-tty-fallback-test--not-run s 'drgnx-palette "\eP" c)
      (should-not (drgnx-tty-session-eval s '(active-minibuffer-window)))
      ;; the report says how each chord is typed here
      (let ((entry (drgnx-tty-session-eval
                    s `(cdr (assoc (terminal-name (frame-terminal ,(drgnx-tty-keys-test--frame c)))
                                   (plist-get (drgnx-tty--read-report) :terminals))))))
        (should (eq (plist-get entry :fallback) t))
        (should (member '("C-S-p" nil nil "<f6> p") (plist-get entry :fallbacks)))
        (should (member '("C-S-f" nil "M-F" "<f6> f") (plist-get entry :fallbacks)))))))

(ert-deftest drgnx-tty-fallback/alt-shift-f-shows-search ()
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :size "120x28" :options '(("set" "-s" "extended-keys" "off")))
    (drgnx-tty-session-eval s '(with-current-buffer "*Messages*" (let ((inhibit-read-only t)) (erase-buffer)) t))
    (let ((c (drgnx-tty-fallback-test--legacy s)))
      (should (drgnx-tty-fallback-test--decodes-p s c "\eF"))
      (drgnx-tty-session-eval s drgnx-tty-keys-test--record)
      (drgnx-tty-session-send c "\eF")
      (drgnx-tty-keys-test--ran s 'drgnx-wb-view-search "C-S-f")
      (drgnx-tty-session-wait-screen c "SEARCH")
      (drgnx-tty-keys-test--quit s c 'legacy)
      ;; the one hint, once: a second VTE client gets none (the session's first client, a tmux, may have had its
      ;; own: the count is compared, not assumed)
      (let* ((count '(with-current-buffer "*Messages*"
                       (how-many "This terminal can't send Ctrl\\+Shift keys: use Alt\\+Shift (or F6 then the key)\\. drgnx doctor has details\\."
                                 (point-min) (point-max))))
             (before (progn (drgnx-tty-session-wait s `(> ,count 0))
                            (sleep-for 1.5)       ; every hint already on its way has arrived
                            (drgnx-tty-session-eval s count))))
        (drgnx-tty-fallback-test--legacy s)
        (sleep-for 1.5)
        (should (= before (drgnx-tty-session-eval s count))))
      (should (= 1 (seq-count (lambda (id) (eq id 'vte)) (drgnx-tty-session-eval s '(plist-get (drgnx-tty--read-report) :hinted))))))))

(ert-deftest drgnx-tty-fallback/the-shared-surfaces-show-the-keys-this-terminal-sends ()
  ;; the key sheet and a command's key, asked in a VTE client's frame
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :size "120x28" :options '(("set" "-s" "extended-keys" "off")))
    (let* ((c (drgnx-tty-fallback-test--legacy s))
           (frame (drgnx-tty-keys-test--frame c))
           (key '(let ((cmd (drgnx-commands-get 'view-search)))
                   (drgnx-surfaces-key cmd))))
      (should (equal (drgnx-tty-session-eval s `(with-selected-frame ,frame ,key)) "M-F"))
      (let ((sheet (drgnx-tty-session-eval
                    s `(with-selected-frame ,frame
                         (drgnx-surfaces-cheatsheet)
                         (prog1 (with-current-buffer "*drgnx keys*" (buffer-string)) (kill-buffer "*drgnx keys*"))))))
        (should (string-match-p "Keys this terminal cannot send, and what to press here" sheet))
        (should (string-match-p "C-S-p +Command Palette +F6 p" sheet))
        (should (string-match-p "C-S-f +[^\n]*Alt\\+Shift\\+F, or F6 f" sheet))))))

(ert-deftest drgnx-tty-fallback/alt-shift-e-focuses-the-explorer ()
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :size "120x28" :options '(("set" "-s" "extended-keys" "off")))
    (let* ((c (drgnx-tty-fallback-test--legacy s))
           (frame (drgnx-tty-keys-test--frame c)))
      (drgnx-tty-session-eval s drgnx-tty-keys-test--record)
      (drgnx-tty-session-send c "\eE")
      (drgnx-tty-keys-test--ran s 'drgnx-wb-view-explorer "C-S-e")
      (drgnx-tty-session-wait s `(with-current-buffer (window-buffer (frame-selected-window ,frame))
                                   (derived-mode-p 'drgnx-explorer-mode))))))

(ert-deftest drgnx-tty-fallback/f6-then-the-key ()
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :size "120x28" :options '(("set" "-s" "extended-keys" "off")))
    (let* ((c (drgnx-tty-fallback-test--legacy s))
           (frame (drgnx-tty-keys-test--frame c))
           (f6 (drgnx-tty-session-encode "<f6>" 'legacy)))
      (should (equal f6 "\e[17~"))
      (drgnx-tty-session-eval s drgnx-tty-keys-test--record)
      ;; F6 waits, saying so
      (drgnx-tty-session-send c f6)
      (drgnx-tty-session-wait-screen c "Ctrl\\+Shift\\+…")
      ;; …then . : the code actions
      (drgnx-tty-session-send c ".")
      (drgnx-tty-keys-test--ran s 'drgnx-lang-quick-fix "C-.")
      (drgnx-tty-keys-test--quit s c 'legacy)
      ;; F6 ` : the panel
      (should-not (drgnx-tty-session-eval s `(drgnx-wb-area-window 'panel ,frame)))
      (drgnx-tty-session-send c (concat f6 "`"))
      (drgnx-tty-keys-test--ran s 'drgnx-wb-toggle-panel "C-`")
      (drgnx-tty-session-wait s `(drgnx-wb-area-window 'panel ,frame))
      ;; F6 p : the palette
      (drgnx-tty-session-send c (concat f6 "p"))
      (drgnx-tty-keys-test--ran s 'drgnx-palette "C-S-p")
      (drgnx-tty-session-wait-screen c "Command (# for a code question)")
      (drgnx-tty-keys-test--quit s c 'legacy)
      ;; C-g while F6 waits is C-g: it quits, a pending prefix too (C-x F6 C-g is C-x C-g, which ends C-x and runs
      ;; no command), and nothing else runs.  (Typed in
      ;; the same instant as F6, C-g would be Emacs's interrupt, handled before the F6 before it, as for any key.)
      (drgnx-tty-session-eval s '(setq kx-seen nil))
      (drgnx-tty-session-send c (concat "\C-x" f6))
      (drgnx-tty-session-wait-screen c "Ctrl\\+Shift\\+…")
      (drgnx-tty-session-send c "\a")
      (sleep-for 0.5)
      (should-not (drgnx-tty-session-eval s '(seq-remove (lambda (c) (memq (car c) '(keyboard-quit nil))) kx-seen)))
      ;; a click after F6 is a click: F6 is dropped, nothing of the mouse report is typed
      (let ((text `(with-current-buffer "*scratch*" (buffer-string))))
        (let ((before (drgnx-tty-session-eval s text)))
          (drgnx-tty-session-send c f6)
          (drgnx-tty-session-wait-screen c "Ctrl\\+Shift\\+…")
          (drgnx-tty-session-send c "\e[<0;60;6M\e[<0;60;6m")
          (sleep-for 0.5)
          (should (equal (drgnx-tty-session-eval s text) before))
          (should-not (drgnx-tty-session-find c "60;6\\|\\[<0"))
          (should-not (drgnx-tty-session-find c "Ctrl\\+Shift\\+…"))))
      ;; F6 twice is F6 itself (unbound here: Emacs says so, nothing waits; no C-x was left pending)
      (drgnx-tty-session-send c (concat f6 f6))
      (drgnx-tty-session-wait s '(member '(nil . "<f6>") kx-seen))
      ;; and the next F6 p is the palette again
      (drgnx-tty-session-send c (concat f6 "p"))
      (drgnx-tty-keys-test--ran s 'drgnx-palette "C-S-p")
      (drgnx-tty-keys-test--quit s c 'legacy))))

(ert-deftest drgnx-tty-fallback/a-mode-that-binds-alt-shift-f-keeps-it ()
  ;; Alt+Shift+P is reserved (ESC P), so the mode here binds M-F: in its buffer, Alt+Shift+F is the mode's;
  ;; elsewhere it is Search; F6 f is Search everywhere
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :size "120x28" :options '(("set" "-s" "extended-keys" "off")))
    (let* ((c (drgnx-tty-fallback-test--legacy s))
           (frame (drgnx-tty-keys-test--frame c))
           ;; a buffer is shown by a command (F7 here), as a person switches buffers: the buffer a key is looked up
           ;; in is the current one, which the command loop takes from the selected window before each command.
           ;; It waits for the new buffer's mode line: kx-a has a plain one (frame name, buffer name), an ordinary
           ;; buffer's is the status bar, which names no buffer, so it is told by its line and column
           (show (lambda (buffer)
                   (drgnx-tty-session-eval s `(setq kx-next ,buffer))
                   (drgnx-tty-session-key c "<f7>" 'legacy)
                   (drgnx-tty-session-wait-screen
                    c (if (equal buffer "kx-a") "- +F[0-9]+ +kx-a " "Ln [0-9]+, Col [0-9]+ .*Emacs Lisp"))
                   (drgnx-tty-session-wait s `(equal (buffer-name (window-buffer (frame-selected-window ,frame))) ,buffer)))))
      (should (drgnx-tty-session-eval
               s '(progn (defvar kx-mode-ran nil)
                         (defvar kx-next nil)
                         (defun kx-mode-command () (interactive) (setq kx-mode-ran (buffer-name)))
                         (defun kx-show () (interactive) (drgnx-wb-show-in-editor (get-buffer-create kx-next) t))
                         (push (list (cons t (let ((m (make-sparse-keymap))) (define-key m [f7] #'kx-show) m)))
                               emulation-mode-map-alists)
                         (defvar kx-alt-mode-map (let ((m (make-sparse-keymap))) (define-key m (kbd "M-F") #'kx-mode-command) m))
                         (define-minor-mode kx-alt-mode "Binds M-F." :keymap kx-alt-mode-map)
                         (with-current-buffer (get-buffer-create "kx-a") (kx-alt-mode 1))
                         t)))
      (drgnx-tty-session-eval s drgnx-tty-keys-test--record)
      ;; buffer A, the mode's: Alt+Shift+F runs the mode's command
      (should (funcall show "kx-a"))
      (drgnx-tty-session-send c "\eF")
      (should (equal (drgnx-tty-session-wait s 'kx-mode-ran) "kx-a"))
      (should-not (drgnx-tty-session-eval s '(assq 'drgnx-wb-view-search kx-seen)))
      ;; buffer B: Search
      (should (funcall show "*scratch*"))
      (drgnx-tty-session-send c "\eF")
      (drgnx-tty-keys-test--ran s 'drgnx-wb-view-search "C-S-f")
      (drgnx-tty-keys-test--quit s c 'legacy)
      ;; back in A, F6 f: Search, the mode's key untouched
      (drgnx-tty-session-eval s '(setq kx-seen nil kx-mode-ran nil))
      (should (funcall show "kx-a"))
      (drgnx-tty-session-send c (concat (drgnx-tty-session-encode "<f6>" 'legacy) "f"))
      (drgnx-tty-keys-test--ran s 'drgnx-wb-view-search "C-S-f")
      (should-not (drgnx-tty-session-eval s 'kx-mode-ran))
      (drgnx-tty-keys-test--quit s c 'legacy))))

(ert-deftest drgnx-tty-fallback/tmux-at-level-1-gets-it-for-the-folded-chords ()
  ;; tmux with extended-keys on, modifyOtherKeys level 1: C-S-f arrives folded into C-f, so it gets the layer;
  ;; C-. arrives (modifyOtherKeys) and is not in it
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :size "120x28")
    (let* ((c (drgnx-tty-session-client s :env (list (format "TMUX=%s,1,0" (plist-get s :tmux)))))
           (frame (drgnx-tty-keys-test--frame c)))
      (drgnx-tty-session-wait-screen c "\\*scratch\\*" 20)
      (let ((caps (drgnx-tty-keys-test--caps s c)))
        (should (equal (list (plist-get caps :id) (plist-get caps :keys)) '(tmux mok)))
        (should (member "C-S-f" (plist-get caps :folded))))
      (let ((rows (drgnx-tty-session-eval s `(terminal-parameter (frame-terminal ,frame) 'drgnx-tty-fallback-table))))
        (should (assoc "C-S-f" rows))
        (should-not (assoc "C-." rows)))
      (should (drgnx-tty-fallback-test--decodes-p s c "\eF"))
      (drgnx-tty-session-eval s drgnx-tty-keys-test--record)
      (drgnx-tty-session-send c "\eF")
      (drgnx-tty-keys-test--ran s 'drgnx-wb-view-search "C-S-f")
      (drgnx-tty-keys-test--quit s c 'mok)
      (drgnx-tty-session-key c "C-." 'mok)
      (drgnx-tty-keys-test--ran s 'drgnx-lang-quick-fix "C-."))))

(ert-deftest drgnx-tty-fallback/a-kkp-or-mok-client-is-untouched ()
  ;; one daemon: a VTE client with the layer, a WezTerm client (modifyOtherKeys) without it
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :size "120x28")
    (let* ((l (drgnx-tty-fallback-test--legacy s))
           (m (progn (drgnx-tty-session-eval s (drgnx-tty-fallback-test--says "WezTerm 20240203-110809-5046fc22"))
                     (drgnx-tty-session-client s :env '("TERM=xterm-256color")))))
      (drgnx-tty-session-wait-screen m "\\*scratch\\*" 20)
      (should (equal (mapcar (lambda (k) (plist-get (drgnx-tty-keys-test--caps s m) k)) '(:id :keys :folded))
                     '(wezterm mok nil)))
      (should-not (drgnx-tty-session-eval s `(terminal-parameter (frame-terminal ,(drgnx-tty-keys-test--frame m)) 'drgnx-tty-fallback)))
      (should-not (drgnx-tty-fallback-test--decodes-p s m "\eF"))
      (should (drgnx-tty-fallback-test--decodes-p s l "\eF"))
      ;; ESC F there is M-F, Emacs's: no Search; its C-S-f bytes are Search
      (drgnx-tty-session-eval s drgnx-tty-keys-test--record)
      (drgnx-tty-fallback-test--not-run s 'drgnx-wb-view-search "\eF" m)
      (drgnx-tty-session-key m "C-S-f" 'mok)
      (drgnx-tty-keys-test--ran s 'drgnx-wb-view-search "C-S-f")
      (drgnx-tty-keys-test--quit s m 'mok))))

(ert-deftest drgnx-tty-fallback/two-clients-legacy-and-kkp-at-once ()
  (drgnx-tty-keys-test--need-kkp)
  (drgnx-tty-session-with (s :daemon t :keys 'vscode :size "120x28" :env (drgnx-tty-keys-test--env))
    (let ((l (drgnx-tty-fallback-test--legacy s)))
      (drgnx-tty-session-eval s (drgnx-tty-keys-test--kkp-yes drgnx-tty-keys-test--kitty))
      (let ((k (drgnx-tty-session-client s :env '("TERM=xterm-256color"))))
        (drgnx-tty-keys-test--answer-kkp s k)
        (should (eq (plist-get (drgnx-tty-keys-test--caps s k) :keys) 'kkp))
        (should-not (drgnx-tty-fallback-test--decodes-p s k "\eF"))
        (drgnx-tty-session-eval s drgnx-tty-keys-test--record)
        ;; L's Alt+Shift+F: Search
        (drgnx-tty-session-send l "\eF")
        (drgnx-tty-keys-test--ran s 'drgnx-wb-view-search "C-S-f")
        (drgnx-tty-session-wait-screen l "SEARCH")
        (drgnx-tty-keys-test--quit s l 'legacy)
        ;; K's ESC F: not Search; K's kkp C-S-f: Search
        (drgnx-tty-session-wait-screen k "\\*scratch\\*")
        (drgnx-tty-fallback-test--not-run s 'drgnx-wb-view-search "\eF" k)
        (drgnx-tty-session-key k "C-S-f" 'kkp)
        (drgnx-tty-keys-test--ran s 'drgnx-wb-view-search "C-S-f")
        (drgnx-tty-keys-test--quit s k 'kkp)))))

(ert-deftest drgnx-tty-fallback/a-graphical-frame-is-untouched ()
  ;; one daemon with a graphical frame and a terminal client: the terminal has the layer, the graphical frame
  ;; sends every key and F6 stays F6 there
  (skip-unless (executable-find "mutter"))
  (let* ((root (make-temp-file "drgnx-mixed" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (gui (drgnx-ui-start "drgnx" nil 60 t))
         (tty nil))
    (unwind-protect
        (progn
          (should (eql 0 (plist-get (drgnx-ui-new-frame gui) :exit)))
          (drgnx-tty-session-eval gui (drgnx-tty-fallback-test--says "VTE(7800)"))
          (setq tty (drgnx-tty-session-start
                     :size "100x30"
                     :command (format "env TERM=xterm-256color VTE_VERSION=7800 %s -a false -t -s %s; sh"
                                      (drgnx-ui--emacsclient) (shell-quote-argument (plist-get gui :socket)))))
          (drgnx-tty-session-wait-screen tty "\\*scratch\\*" 30)
          (let ((g '(seq-find (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list)))
                (tf '(seq-find (lambda (f) (and (not (display-graphic-p f)) (frame-parameter f 'client))) (frame-list))))
            (drgnx-tty-session-wait gui `(terminal-parameter (frame-terminal ,tf) 'drgnx-tty-fallback) 20)
            (should (equal (drgnx-tty-session-eval gui `(drgnx-tty-sendable-key ,tf "C-S-f")) "M-F"))
            (should (equal (drgnx-tty-session-eval gui `(drgnx-tty-sendable-key ,g "C-S-f")) "C-S-f"))
            (should-not (drgnx-tty-session-eval gui `(terminal-parameter (frame-terminal ,g) 'drgnx-tty-fallback)))
            (should-not (drgnx-tty-session-eval gui `(with-selected-frame ,g (lookup-key input-decode-map "\eF"))))
            (should (equal (drgnx-tty-session-eval gui `(with-selected-frame ,g (drgnx-tty-fallback--prefix nil))) [f6]))))
      (when tty (drgnx-tty-session-stop tty))
      (drgnx-ui-stop (plist-get gui :name))
      (delete-directory root t))))

(provide 'fallback-test)
;;; fallback-test.el ends here
