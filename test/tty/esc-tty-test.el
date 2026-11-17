;;; esc-tty-test.el --- tty tier: the Esc double tap in a terminal window -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.  A terminal sends Esc as
;; byte 27; the decode filter (wb/drgnx-esc.el) tells a lone Esc, Esc Esc, Alt+Esc, `Esc x', F6 then Esc and the
;; terminal's escape sequences apart.  No fixed pause: a second byte is sent once the inner Emacs says where it is
;; (`drgnx-esc--waiting' while the filter waits for it; nil again once the window has passed).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-tty-session)
(unless (featurep 'tty-keys-helpers)
  (load (expand-file-name "tty-keys-helpers" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(defconst drgnx-tty-esc--where
  '(list :buffer (buffer-name (window-buffer (selected-window))) :frames (length (frame-list))
         :esc-mode (bound-and-true-p drgnx-esc-mode) :last drgnx-esc--last :waiting drgnx-esc--waiting
         :f6-esc (key-binding (kbd "<f6> <escape>")) :c-esc (key-binding (kbd "C-<escape>"))
         :decode (let ((b (lookup-key input-decode-map [?\e]))) (if (keymapp b) 'keymap b))
         :evil (list (featurep 'evil) (bound-and-true-p evil-mode) (bound-and-true-p evil-local-mode)
                     (bound-and-true-p drgnx-modal-running) (bound-and-true-p drgnx-modal-state))
         :open (drgnx-switcher-open-p) :layers (bound-and-true-p drgnx-keys--session-layers))
  "A form, in the inner Emacs: what a failed row prints.")

(defun drgnx-tty-esc--wait (s form what)
  "Wait for FORM in SESS's Emacs (10 s); on a timeout fail with WHAT and where the inner Emacs is."
  (condition-case err (drgnx-tty-session-wait s form 10)
    (error (ert-fail (list what (error-message-string err)
                           (format "%S" (ignore-errors (drgnx-tty-session-eval s drgnx-tty-esc--where))))))))

(defun drgnx-tty-esc--plain (s)
  "Wait for SESS's workbench and the double tap, then show a plain writable buffer in the selected window."
  (drgnx-tty-session-wait-tab s "×" 20)
  (drgnx-tty-session-wait s '(bound-and-true-p drgnx-esc-mode) 20)
  (drgnx-tty-session-eval s '(let ((b (get-buffer-create "*esc-tty*")))
                               (with-current-buffer b (fundamental-mode) (erase-buffer) (insert "one\ntwo\nthree"))
                               (set-window-buffer (selected-window) b)
                               (set-window-point (selected-window) (with-current-buffer b (point-max)))
                               t))
  (drgnx-tty-session-key-barrier s)
  (should (equal (drgnx-tty-session-eval s '(buffer-name (window-buffer (selected-window)))) "*esc-tty*")))

(defun drgnx-tty-esc--second-esc (s)
  "Send Esc to SESS, then a second one while the filter waits for it."
  (drgnx-tty-session-send s "\e")
  (drgnx-tty-esc--wait s 'drgnx-esc--waiting "the filter waits after the first Esc")
  (drgnx-tty-session-send s "\e"))

(defun drgnx-tty-esc--opened (s)
  (drgnx-tty-esc--wait s '(drgnx-switcher-open-p) "the switcher opened")
  (drgnx-tty-session-eval s '(progn (drgnx-switcher-close) t)))

(ert-deftest drgnx-tty-esc/emacs-esc-esc-opens ()
  (drgnx-tty-session-with (s :size "120x40" :keys 'emacs)
    (drgnx-tty-esc--plain s)
    (drgnx-tty-esc--second-esc s)
    (drgnx-tty-esc--opened s)))

(ert-deftest drgnx-tty-esc/alt-esc-counts-as-double ()
  (drgnx-tty-session-with (s :size "120x40" :keys 'emacs)
    (drgnx-tty-esc--plain s)
    (drgnx-tty-session-send s "\e\e")
    (drgnx-tty-esc--opened s)))

(defun drgnx-tty-esc--legacy (s)
  "A new client of S that is a VTE (Ptyxis, GNOME Terminal: no modifyOtherKeys), once its frame shows; it has the
fallback layer, whose F6 prefix types `C-<escape>' as F6 then Esc (as test/tty/fallback-test.el's clients)."
  (drgnx-tty-session-eval s '(progn (advice-add 'drgnx-tty-frames--ask :override
                                                (lambda (frame)
                                                  (let ((answer "\eP>|VTE(7800)\e\\"))
                                                    (set-terminal-parameter (frame-terminal frame) 'drgnx-tty-xtversion answer)
                                                    answer))
                                                '((name . kx-says)))
                                    t))
  (let ((c (drgnx-tty-session-client s :env '("TERM=xterm-256color" "VTE_VERSION=7800"))))
    (drgnx-tty-session-wait-tab c nil 20)
    (should (drgnx-tty-session-eval s `(terminal-parameter (frame-terminal ,(drgnx-tty-keys-test--frame c)) 'drgnx-tty-fallback)))
    c))

(ert-deftest drgnx-tty-esc/f6-escape-opens-the-switcher ()
  (dolist (profile '(vscode emacs vim))
    (drgnx-tty-session-with (s :daemon t :keys profile :size "120x28" :options '(("set" "-s" "extended-keys" "off")))
      (drgnx-tty-session-wait s '(bound-and-true-p drgnx-esc-mode) 20)
      (let ((c (drgnx-tty-esc--legacy s)))
        (drgnx-tty-session-send c "\e[17~\e")
        (ert-info ((format "profile %s" profile))
          (drgnx-tty-esc--opened s))))))

(ert-deftest drgnx-tty-esc/escape-sequences-still-decode ()
  (dolist (profile '(vscode emacs))
    (drgnx-tty-session-with (s :size "120x40" :keys profile)
      (drgnx-tty-esc--plain s)
      ;; the up arrow (ESC [ A) moves point; the barrier's F7 (ESC [ 1 8 ~) runs its command
      (drgnx-tty-session-send s "\e[A")
      (drgnx-tty-session-key-barrier s)
      (should (equal (drgnx-tty-session-eval s '(list (with-current-buffer (window-buffer (selected-window))
                                                        (line-number-at-pos (window-point (selected-window))))
                                                      (drgnx-switcher-open-p)))
                     '(2 nil))))))

(ert-deftest drgnx-tty-esc/emacs-esc-x-is-still-m-x ()
  (drgnx-tty-session-with (s :size "120x40" :keys 'emacs)
    (drgnx-tty-esc--plain s)
    (drgnx-tty-session-send s "\e")
    (drgnx-tty-esc--wait s 'drgnx-esc--waiting "the filter waits after Esc")
    (drgnx-tty-session-send s "x")
    (drgnx-tty-esc--wait s '(and (active-minibuffer-window)
                                 (string-match-p "M-x" (with-selected-window (active-minibuffer-window)
                                                         (minibuffer-prompt))))
                         "M-x reads a command")
    (should-not (drgnx-tty-session-eval s '(drgnx-switcher-open-p)))
    (drgnx-tty-session-send s "\a")
    (drgnx-tty-esc--wait s '(not (active-minibuffer-window)) "C-g left M-x")))

(ert-deftest drgnx-tty-esc/emacs-slow-esc-esc-esc-quits ()
  (drgnx-tty-session-with (s :size "120x40" :keys 'emacs)
    (drgnx-tty-esc--plain s)
    (should (drgnx-tty-session-eval s '(with-selected-window (selected-window)
                                         (transient-mark-mode 1) (goto-char (point-min)) (push-mark (point-max) t t)
                                         (region-active-p))))
    ;; each Esc after the window of the one before (the filter has waited and given up)
    (dotimes (i 3)
      (drgnx-tty-session-send s "\e")
      (when (< i 2)
        (drgnx-tty-esc--wait s 'drgnx-esc--waiting "the filter waits")
        (drgnx-tty-esc--wait s '(not drgnx-esc--waiting) "the window passed")))
    ;; ESC ESC ESC is `keyboard-escape-quit': the region goes, and no switcher opened on the way
    (drgnx-tty-esc--wait s '(not (with-selected-window (selected-window) (region-active-p))) "the region gone")
    (should-not (drgnx-tty-session-eval s '(drgnx-switcher-open-p)))))

(ert-deftest drgnx-tty-esc/vim-insert-esc-then-esc-opens ()
  (let ((dirs (drgnx-tty-session-require-packages '(evil goto-chg))))
    (drgnx-tty-session-with (s :size "120x40" :keys 'vim)
      (drgnx-tty-session-wait-tab s "×" 20)
      ;; evil itself, not the module editor/evil (which also needs evil-collection): its Esc handling is evil's own
      (should (equal (drgnx-tty-session-eval s `(condition-case err
                                                    (progn (dolist (d ',dirs) (add-to-list 'load-path d))
                                                           (require 'evil) (evil-mode 1)
                                                           (list (featurep 'evil) evil-mode))
                                                  (error (list 'error err)))
                                             30)
                     '(t t)))
      ;; the buffer is made after the engine runs, so evil is on in it
      (drgnx-tty-esc--plain s)
      (drgnx-tty-esc--wait s '(with-current-buffer (window-buffer (selected-window)) (bound-and-true-p evil-local-mode))
                           "evil on in the buffer")
      (drgnx-tty-session-eval s '(with-current-buffer (window-buffer (selected-window)) (evil-insert-state) t))
      (drgnx-tty-session-key-barrier s)
      ;; Esc leaves insert state (a cancel); a second Esc right after it opens the switcher
      (drgnx-tty-session-send s "\e")
      (drgnx-tty-esc--wait s '(memq (cdr drgnx-esc--last) '(evil-normal-state evil-force-normal-state))
                           "the first Esc left insert state")
      (drgnx-tty-session-send s "\e")
      (drgnx-tty-esc--opened s))))

(provide 'esc-tty-test)
;;; esc-tty-test.el ends here
