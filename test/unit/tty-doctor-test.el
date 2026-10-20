;;; tty-doctor-test.el --- batch tests: the doctor's Terminal group -*- lexical-binding: t -*-
;; The facts are injected: nothing here asks a terminal or runs tmux.  PATH is a temp dir of fake executables
;; that log their calls, so "the doctor never installs" is checked by an empty log.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-doctor)
(require 'drgnx-tty-recommend)
(load (expand-file-name "modules/ui/drgnx-tty-frames" drgnx-dir) nil t)

(defconst drgnx-tty-doctor-test--fedora '(:system linux :ostree nil :ids ("fedora")))

(defun drgnx-tty-doctor-test--tf (&rest kv)
  "Terminal facts for a plain terminal (kitty, everything on), with KV on top."
  (append kv (list :in-terminal t :term "xterm-kitty" :identity '(:id kitty :outer nil :version nil)
                   :colorterm "truecolor" :terminfo t :tmux nil :ssh nil :report nil
                   :caps '(:id kitty :keys kkp :c-g waits :folded nil :osc52 t :colors 16777216 :mouse t)
                   :os drgnx-tty-doctor-test--fedora)))

(defun drgnx-tty-doctor-test--facts (tf &rest kv)
  (append kv (list :version "31.1" :native-available t :native-compiles t :treesit t :gui 'pgtk :git t :sqlite t
                   :terminal tf)))

(defun drgnx-tty-doctor-test--results (facts)
  "The results of the Terminal checks on FACTS, an alist NAME → plist."
  (cl-loop for r in (drgnx-doctor-run facts)
           when (string-prefix-p "terminal" (symbol-name (plist-get r :name)))
           collect (cons (plist-get r :name) r)))

(defun drgnx-tty-doctor-test--get (results name key)
  (plist-get (cdr (assq name results)) key))

(defmacro drgnx-tty-doctor-test--with-path (names &rest body)
  "BODY with only the fake executables NAMES on PATH; each appends its name to the log that `calls' returns."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "drgnx-doctor-bin" t))
          (log (expand-file-name "calls" dir))
          (exec-path (list dir))
          (process-environment (cons (concat "PATH=" dir) process-environment))
          (drgnx-tty-mac-app-dirs nil))
     (unwind-protect
         (progn
           (dolist (n ,names)
             (let ((f (expand-file-name n dir)))
               (with-temp-file f (insert "#!/bin/sh\necho \"" n " $*\" >> '" log "'\n"))
               (set-file-modes f #o755)))
           (cl-flet ((calls () (if (file-exists-p log)
                                   (with-temp-buffer (insert-file-contents log) (buffer-string))
                                 "")))
             ,@body))
       (delete-directory dir t))))

(defconst drgnx-tty-doctor-test--ptyxis
  (list :term "xterm-256color" :identity '(:id vte :outer nil :version "7600") :colorterm "truecolor"
        :caps '(:id vte :keys legacy :c-g always :folded nil :osc52 nil :colors 256 :mouse t)
        :fallbacks '(("C-S-p" nil "M-P" "<f6> p") ("C-." nil nil "<f6> .") ("C-S-n" nil "M-N" "<f6> n")))
  "Terminal facts for Ptyxis (VTE): no kkp, no modifyOtherKeys, no OSC 52; the report's fallback rows.")

(ert-deftest drgnx-tty-doctor/a-terminal-only-build-passes-with-a-note ()
  (let ((r (drgnx-doctor-check 'gui (drgnx-tty-doctor-test--facts nil :gui nil))))
    (should (eq (car r) 'ok))
    (should (equal (nth 1 r) "terminal-only Emacs: drgnx runs in terminals (no images, one font size)"))
    (should-not (nth 2 r)))
  (should (eq (car (drgnx-doctor-check 'gui (drgnx-tty-doctor-test--facts nil :gui 'pgtk))) 'ok)))

(ert-deftest drgnx-tty-doctor/outside-a-terminal-one-info-line ()
  (let ((results (drgnx-tty-doctor-test--results (drgnx-tty-doctor-test--facts '(:in-terminal nil)))))
    (should (equal (mapcar #'car results) '(terminal)))
    (should (eq (drgnx-tty-doctor-test--get results 'terminal :status) 'info))
    (should (equal (drgnx-tty-doctor-test--get results 'terminal :detail) "not run from a terminal"))))

(ert-deftest drgnx-tty-doctor/vte-says-what-is-missing-and-what-to-use ()
  (drgnx-tty-doctor-test--with-path nil
    (let* ((results (drgnx-tty-doctor-test--results
                     (drgnx-tty-doctor-test--facts (apply #'drgnx-tty-doctor-test--tf drgnx-tty-doctor-test--ptyxis))))
           (keys (cdr (assq 'terminal-keys results)))
           (lines (split-string (plist-get keys :detail) "\n")))
      (should (eq (plist-get keys :status) 'warn))
      ;; the table: chord, native, fallback, prefix
      (should (seq-find (lambda (l) (string-match-p "\\`C-S-p +no +Alt\\+Shift\\+P +F6 p *\\'" l)) lines))
      (should (seq-find (lambda (l) (string-match-p "\\`C-\\. +no +— +F6 \\. *\\'" l)) lines))
      (should (string-match-p "native" (nth 1 lines)))
      (should (eq (drgnx-tty-doctor-test--get results 'terminal-clipboard :status) 'warn))
      (should (string-prefix-p "none: VTE does not take OSC 52" (drgnx-tty-doctor-test--get results 'terminal-clipboard :fix)))
      (should (eq (drgnx-tty-doctor-test--get results 'terminal :status) 'ok))
      (should-not (seq-find (lambda (r) (eq (plist-get (cdr r) :status) 'fail)) results)))))

(ert-deftest drgnx-tty-doctor/keys-without-a-report-say-to-open-drgnx-once ()
  (drgnx-tty-doctor-test--with-path nil
    (let* ((tf (apply #'drgnx-tty-doctor-test--tf :caps nil :fallbacks nil drgnx-tty-doctor-test--ptyxis))   ; the first value of a key wins
           (keys (cdr (assq 'terminal-keys (drgnx-tty-doctor-test--results (drgnx-tty-doctor-test--facts tf))))))
      ;; VTE can send neither kkp nor modifyOtherKeys by its row alone: warn, and say how to list the keys
      (should (eq (plist-get keys :status) 'warn))
      (should (string-search "open drgnx in this terminal once to list them" (plist-get keys :detail))))))

(ert-deftest drgnx-tty-doctor/a-limited-terminal-gets-capable-terminals-and-install-commands ()
  (drgnx-tty-doctor-test--with-path nil
    (let* ((facts (drgnx-tty-doctor-test--facts (apply #'drgnx-tty-doctor-test--tf drgnx-tty-doctor-test--ptyxis)))
           (fix (drgnx-tty-doctor-test--get (drgnx-tty-doctor-test--results facts) 'terminal-keys :fix))
           (text (plist-get (drgnx-tty-recommendation '(:keys legacy) drgnx-tty-doctor-test--fedora) :text)))
      (should (string-search text fix))
      (should (string-search "sudo dnf install " fix))
      (should-not (string-search "is installed" fix))))
  ;; foot is installed: it comes first, no install command
  (drgnx-tty-doctor-test--with-path '("foot")
    (let* ((facts (drgnx-tty-doctor-test--facts (apply #'drgnx-tty-doctor-test--tf drgnx-tty-doctor-test--ptyxis)))
           (fix (drgnx-tty-doctor-test--get (drgnx-tty-doctor-test--results facts) 'terminal-keys :fix)))
      (should (string-search "foot is installed" fix))
      (should-not (string-search "dnf install" fix)))))

(ert-deftest drgnx-tty-doctor/the-doctor-never-installs ()
  (drgnx-tty-doctor-test--with-path '("sudo" "dnf" "rpm-ostree" "brew" "apt" "pacman" "tmux" "infocmp")
    (let ((facts (drgnx-tty-doctor-test--facts (apply #'drgnx-tty-doctor-test--tf drgnx-tty-doctor-test--ptyxis))))
      (drgnx-doctor-format (drgnx-doctor-run facts))
      (drgnx-doctor-format (drgnx-tty-doctor-test--results facts))
      (should (equal (calls) ""))
      ;; the fix names the command; it does not run it
      (should (string-search "sudo dnf install"
                             (drgnx-tty-doctor-test--get (drgnx-tty-doctor-test--results facts) 'terminal-keys :fix))))))

(ert-deftest drgnx-tty-doctor/a-multi-line-detail-prints-indented ()
  (let* ((text (drgnx-doctor-format (list (list :name 'x :group "g" :status 'warn :detail "first\nsecond\nthird" :fix "f"))))
         (lines (split-string text "\n")))
    (should (equal lines '("WARN  x                    first" "      second" "      third" "      fix: f"))))
  (let ((text (drgnx-doctor-format (list (list :name 'x :group "g" :status 'ok :detail "one line" :fix nil)))))
    (should (equal text "OK    x                    one line"))))

(defconst drgnx-tty-doctor-test--tmux-bad
  '(:version "3.4" :set-clipboard "external" :allow-passthrough "off" :extended-keys "off" :extended-keys-format nil
             :focus-events "off" :rgb nil :outer-term "xterm-kitty" :client-termtype nil))

(defconst drgnx-tty-doctor-test--tmux-good
  '(:version "3.4" :set-clipboard "on" :allow-passthrough "off" :extended-keys "on" :extended-keys-format nil
             :focus-events "on" :rgb t :outer-term "xterm-kitty" :client-termtype nil))

(ert-deftest drgnx-tty-doctor/tmux-gives-the-lines-for-tmux-conf ()
  (let* ((tf (drgnx-tty-doctor-test--tf :identity '(:id tmux :outer kitty :version "3.4") :term "tmux-256color"
                                        :colorterm nil :tmux drgnx-tty-doctor-test--tmux-bad
                                        :caps '(:id tmux :keys legacy :c-g always :folded nil :osc52 nil :colors 256 :mouse t)))
         (r (cdr (assq 'terminal-tmux (drgnx-tty-doctor-test--results (drgnx-tty-doctor-test--facts tf))))))
    (should (eq (plist-get r :status) 'warn))
    (dolist (what '("copy" "keys" "focus" "true colour"))
      (should (string-search what (plist-get r :detail))))
    (should (equal (plist-get r :fix)
                   (concat "add to ~/.tmux.conf: set -s set-clipboard on; set -s extended-keys on; "
                           "set -g allow-passthrough on; set -g focus-events on; "
                           "set -as terminal-features ',xterm-kitty:RGB', then run tmux source ~/.tmux.conf"))))
  (let* ((tf (drgnx-tty-doctor-test--tf :identity '(:id tmux :outer kitty :version "3.4") :term "tmux-256color"
                                        :tmux drgnx-tty-doctor-test--tmux-good
                                        :caps '(:id tmux :keys mok :c-g always :folded nil :osc52 t :colors 16777216 :mouse t)))
         (results (drgnx-tty-doctor-test--results (drgnx-tty-doctor-test--facts tf))))
    (should (eq (drgnx-tty-doctor-test--get results 'terminal-tmux :status) 'ok))
    (should (eq (drgnx-tty-doctor-test--get results 'terminal-keys :status) 'ok))))

(defun drgnx-tty-doctor-test--tmux-keys (extended-keys keys &rest caps)
  "The terminal-keys result in tmux with EXTENDED-KEYS set, the caps KEYS (and CAPS on top), on Ptyxis."
  (let* ((tmux (plist-put (copy-sequence drgnx-tty-doctor-test--tmux-good) :extended-keys extended-keys))
         (tf (drgnx-tty-doctor-test--tf :identity '(:id tmux :outer vte :version "3.4") :term "tmux-256color" :tmux tmux
                                        :caps (append (list :id 'tmux :keys keys) caps '(:c-g always :osc52 t :colors 256 :mouse t))
                                        :fallbacks nil)))
    (cdr (assq 'terminal-keys (drgnx-tty-doctor-test--results (drgnx-tty-doctor-test--facts tf))))))

(ert-deftest drgnx-tty-doctor/tmux-with-extended-keys-off-gets-the-tmux-line ()
  (drgnx-tty-doctor-test--with-path nil
    (let ((r (drgnx-tty-doctor-test--tmux-keys "off" 'legacy)))
      (should (eq (plist-get r :status) 'warn))
      (should (string-prefix-p "set -s extended-keys on" (plist-get r :fix)))
      (should-not (string-search "install a terminal" (plist-get r :fix))))))

(ert-deftest drgnx-tty-doctor/tmux-with-extended-keys-on-blames-the-terminal-around-it ()
  ;; the line is already set: the terminal around tmux cannot send the keys, so the fix is a better terminal
  (drgnx-tty-doctor-test--with-path nil
    (let ((r (drgnx-tty-doctor-test--tmux-keys "on" 'legacy)))
      (should (eq (plist-get r :status) 'warn))
      (should-not (string-search "extended-keys" (plist-get r :fix)))
      (should (string-search "sudo dnf install " (plist-get r :fix))))))

(ert-deftest drgnx-tty-doctor/folded-chords-say-what-to-do ()
  (let ((r (drgnx-tty-doctor-test--tmux-keys "on" 'mok :folded '("C-S-p" "C-S-n"))))
    (should (eq (plist-get r :status) 'info))
    (should (string-search "Alt+Shift or F6" (plist-get r :fix)))
    (should (string-search "drgnx-tty-tmux-mok-level" (plist-get r :fix)))))

(ert-deftest drgnx-tty-doctor/tmux-across-ssh-lists-what-to-check-there ()
  (let* ((tf (drgnx-tty-doctor-test--tf :identity '(:id tmux :outer nil :version nil) :term "tmux-256color" :ssh t
                                        :colorterm nil :tmux nil :caps nil))
         (r (cdr (assq 'terminal-tmux (drgnx-tty-doctor-test--results (drgnx-tty-doctor-test--facts tf))))))
    (should (eq (plist-get r :status) 'info))
    (should (string-search "other side of SSH" (plist-get r :detail)))
    (dolist (line '("set -s set-clipboard on" "set -s extended-keys on" "set -g focus-events on" "terminal-features"))
      (should (string-search line (plist-get r :fix))))
    (should (string-search "tmux source ~/.tmux.conf" (plist-get r :fix)))))

(ert-deftest drgnx-tty-doctor/a-missing-remote-terminfo-gives-the-fixes ()
  (let* ((tf (drgnx-tty-doctor-test--tf :ssh t :terminfo nil :caps nil))
         (r (cdr (assq 'terminal-ssh (drgnx-tty-doctor-test--results (drgnx-tty-doctor-test--facts tf))))))
    (should (eq (plist-get r :status) 'warn))
    (dolist (fix '("infocmp -x | ssh" "kitten ssh" "ssh-terminfo" "TERM=xterm-256color"))
      (should (string-search fix (plist-get r :fix)))))
  ;; another TERM: the first and the last fix only
  (let* ((tf (drgnx-tty-doctor-test--tf :ssh t :terminfo nil :caps nil :term "foot"))
         (fix (plist-get (cdr (assq 'terminal-ssh (drgnx-tty-doctor-test--results (drgnx-tty-doctor-test--facts tf)))) :fix)))
    (should (string-search "infocmp -x | ssh" fix))
    (should-not (string-search "kitten" fix)))
  ;; the entry is there: nothing to fix; no SSH: the check is absent
  (let ((results (drgnx-tty-doctor-test--results (drgnx-tty-doctor-test--facts (drgnx-tty-doctor-test--tf :ssh t)))))
    (should (eq (drgnx-tty-doctor-test--get results 'terminal-ssh :status) 'ok)))
  (should-not (assq 'terminal-ssh (drgnx-tty-doctor-test--results (drgnx-tty-doctor-test--facts (drgnx-tty-doctor-test--tf))))))

(ert-deftest drgnx-tty-doctor/kitty-with-everything-is-ok ()
  (let ((results (drgnx-tty-doctor-test--results (drgnx-tty-doctor-test--facts (drgnx-tty-doctor-test--tf)))))
    (should (equal (mapcar #'car results) '(terminal terminal-colours terminal-mouse terminal-keys terminal-clipboard)))
    (dolist (r results)
      (should (eq (plist-get (cdr r) :status) 'ok)))
    (should (string-search "kitty" (drgnx-tty-doctor-test--get results 'terminal :detail)))))

(ert-deftest drgnx-tty-doctor/colours-and-mouse-warn-with-the-terminals-fix ()
  (let* ((tf (drgnx-tty-doctor-test--tf :identity '(:id linux :outer nil :version nil) :term "linux" :colorterm nil
                                        :caps '(:id linux :keys legacy :c-g always :folded nil :osc52 nil :colors 16 :mouse nil)))
         (results (drgnx-tty-doctor-test--results (drgnx-tty-doctor-test--facts tf))))
    (should (eq (drgnx-tty-doctor-test--get results 'terminal-mouse :status) 'warn))
    (should (string-search "gpm-mouse-mode" (drgnx-tty-doctor-test--get results 'terminal-mouse :fix)))
    (should (eq (drgnx-tty-doctor-test--get results 'terminal-colours :status) 'warn))
    (should (string-search "16 colours" (drgnx-tty-doctor-test--get results 'terminal-colours :detail))))
  ;; a terminal that has true colour but runs at 256 is told how to ask for it
  (let* ((tf (drgnx-tty-doctor-test--tf :colorterm nil :caps '(:id kitty :keys kkp :c-g waits :folded nil :osc52 t :colors 256 :mouse t)))
         (r (cdr (assq 'terminal-colours (drgnx-tty-doctor-test--results (drgnx-tty-doctor-test--facts tf))))))
    (should (eq (plist-get r :status) 'warn))
    (should (string-search "COLORTERM=truecolor" (plist-get r :fix)))))

(ert-deftest drgnx-tty-doctor/a-missing-terminfo-is-a-warning ()
  (let* ((tf (drgnx-tty-doctor-test--tf :terminfo nil))
         (r (cdr (assq 'terminal (drgnx-tty-doctor-test--results (drgnx-tty-doctor-test--facts tf))))))
    (should (eq (plist-get r :status) 'warn))
    (should (string-search "xterm-kitty" (plist-get r :detail)))))

(ert-deftest drgnx-tty-doctor/facts-take-the-caps-and-rows-of-this-terminals-report ()
  (let* ((state (make-temp-file "drgnx-doctor-state" t))
         (process-environment (append (list (concat "XDG_STATE_HOME=" state) "TERM=xterm-256color" "VTE_VERSION=7600"
                                            "TMUX=" "TERM_PROGRAM=" "KITTY_WINDOW_ID=" "SSH_CONNECTION=" "SSH_TTY=")
                                      process-environment)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "drgnx" state))
          (with-temp-file (expand-file-name "drgnx/terminal-report.eld" state)
            (prin1 '(:terminals (("/dev/pts/9" . (:caps (:id kitty :keys kkp) :fallbacks nil))
                                 ("/dev/pts/8" . (:caps (:id vte :keys legacy :osc52 nil) :fallbacks (("C-S-p" nil "M-P" "<f6> p"))))))
                   (current-buffer)))
          (let ((tf (drgnx-doctor-terminal-facts)))
            (should (plist-get tf :in-terminal))
            (should (eq (plist-get (plist-get tf :caps) :id) 'vte))
            (should (equal (plist-get tf :fallbacks) '(("C-S-p" nil "M-P" "<f6> p"))))
            (should (plist-get tf :os)))
          ;; no entry for this terminal: no caps, no rows
          (let ((process-environment (cons "VTE_VERSION=" (cons "KITTY_WINDOW_ID=3" process-environment))))
            (let ((tf (drgnx-doctor-terminal-facts)))
              (should (eq (plist-get (plist-get tf :identity) :id) 'kitty))
              (should (eq (plist-get (plist-get tf :caps) :id) 'kitty))))
          (let ((process-environment (cons "VTE_VERSION=" (cons "WEZTERM_PANE=3" process-environment))))
            (let ((tf (drgnx-doctor-terminal-facts)))
              (should (eq (plist-get (plist-get tf :identity) :id) 'wezterm))
              (should-not (plist-get tf :caps))
              (should-not (plist-member tf :fallbacks)))))
      (delete-directory state t))))

(ert-deftest drgnx-tty-doctor/a-tmux-report-entry-with-the-same-outer-terminal-wins ()
  (let* ((state (make-temp-file "drgnx-doctor-state" t))
         (process-environment (append (list (concat "XDG_STATE_HOME=" state) "TERM=tmux-256color" "TMUX=" "TERM_PROGRAM="
                                            "VTE_VERSION=" "KITTY_WINDOW_ID=3" "SSH_CONNECTION=" "SSH_TTY=")
                                      process-environment)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "drgnx" state))
          (with-temp-file (expand-file-name "drgnx/terminal-report.eld" state)
            ;; newest first: tmux in Ptyxis, then tmux in kitty
            (prin1 '(:terminals (("/dev/pts/9" . (:caps (:id tmux :outer vte :keys legacy) :fallbacks (("C-S-p" nil nil nil))))
                                 ("/dev/pts/8" . (:caps (:id tmux :outer kitty :keys mok) :fallbacks nil))))
                   (current-buffer)))
          (let ((tf (drgnx-doctor-terminal-facts)))
            (should (eq (plist-get (plist-get tf :identity) :outer) 'kitty))
            (should (eq (plist-get (plist-get tf :caps) :outer) 'kitty)))
          ;; no entry with this outer terminal: the newest tmux one
          (let ((process-environment (cons "KITTY_WINDOW_ID=" (cons "WEZTERM_PANE=3" process-environment))))
            (should (eq (plist-get (plist-get (drgnx-doctor-terminal-facts) :caps) :outer) 'vte))))
      (delete-directory state t))))

(ert-deftest drgnx-tty-doctor/terminal-check-in-a-graphical-window ()
  (let (said (buffers (buffer-list)))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'message) (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
      (drgnx-tty-frames-terminal-check))
    (should (string-search "terminal window" said))
    (should (string-search "drgnx doctor" said))
    (should-not (get-buffer "*drgnx terminal*"))
    (should (equal buffers (buffer-list)))))

(ert-deftest drgnx-tty-doctor/terminal-check-in-a-terminal-window-shows-the-group ()
  (let ((caps '(:id vte :keys legacy :c-g always :folded nil :osc52 nil :colors 256 :mouse t)))
    (unwind-protect
        (drgnx-tty-doctor-test--with-path nil
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil))
                    ((symbol-function 'drgnx-tty-frame-caps) (lambda (&rest _) caps))
                    ((symbol-function 'drgnx-tty-facts)
                     (lambda (&rest _) (list :in-terminal t :term "xterm-256color" :identity '(:id vte :outer nil :version nil)
                                             :colorterm "truecolor" :terminfo t :tmux nil :ssh nil :report nil)))
                    ((symbol-function 'drgnx-tty-fallback-active-table) (lambda () '(("C-S-p" :alt "M-P" :prefix "<f6> p"))))
                    ((symbol-function 'pop-to-buffer) (lambda (buf &rest _) (set-buffer buf))))
            (drgnx-tty-frames-terminal-check)
            (with-current-buffer "*drgnx terminal*"
              (let ((text (buffer-string)))
                (should (string-match-p "^OK +terminal " text))
                (should (string-match-p "^WARN +terminal-keys" text))
                (should (string-search "Alt+Shift+P" text))
                (should-not (string-match-p "terminal-ssh" text))))))
      (when (get-buffer "*drgnx terminal*") (kill-buffer "*drgnx terminal*")))))

(ert-deftest drgnx-tty-doctor/the-command-is-in-every-profile ()
  (dolist (profile '("vscode" "emacs" "vim"))
    (with-temp-buffer
      (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
      (should (re-search-forward "(terminal-check :none \"the palette\")" nil t)))))

(provide 'tty-doctor-test)
;;; tty-doctor-test.el ends here
