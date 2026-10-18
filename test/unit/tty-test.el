;;; tty-test.el --- batch tests: what a terminal is and can do -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-tty)

(defun drgnx-tty-test--id (env &optional answer)
  (plist-get (drgnx-tty-identify env answer) :id))

(ert-deftest drgnx-tty/identify-from-the-environment ()
  (should (eq (drgnx-tty-test--id '(("TERM" . "xterm-kitty") ("KITTY_WINDOW_ID" . "1"))) 'kitty))
  (should (eq (drgnx-tty-test--id '(("TERM" . "xterm-256color") ("KITTY_WINDOW_ID" . "3"))) 'kitty))
  (should (eq (drgnx-tty-test--id '(("TERM" . "xterm-256color") ("TERM_PROGRAM" . "WezTerm"))) 'wezterm))
  (should (eq (drgnx-tty-test--id '(("TERM" . "xterm-256color") ("VTE_VERSION" . "7800"))) 'vte))
  (should (eq (drgnx-tty-test--id '(("TERM" . "xterm-256color") ("TERM_PROGRAM" . "Apple_Terminal"))) 'apple-terminal))
  (should (eq (drgnx-tty-test--id '(("TERM" . "linux"))) 'linux))
  (should (eq (drgnx-tty-test--id '(("TERM" . "foot"))) 'foot))
  (should (eq (drgnx-tty-test--id '(("TERM" . "xterm-ghostty"))) 'ghostty))
  ;; the version comes with the environment when the terminal says it
  (should (equal (plist-get (drgnx-tty-identify '(("TERM_PROGRAM" . "WezTerm") ("TERM_PROGRAM_VERSION" . "20240203")))
                            :version)
                 "20240203"))
  ;; nothing that names a terminal: unknown, not a guess from TERM=xterm-256color
  (should (eq (drgnx-tty-test--id '(("TERM" . "xterm-256color"))) 'unknown))
  (should (eq (drgnx-tty-test--id nil) 'unknown)))

(ert-deftest drgnx-tty/identify-from-the-version-answer ()
  (should (equal (drgnx-tty-identify nil "\eP>|kitty(0.39.1)\e\\") '(:id kitty :outer nil :version "0.39.1")))
  (should (eq (drgnx-tty-test--id nil "\eP>|WezTerm 20240203\e\\") 'wezterm))
  (should (equal (plist-get (drgnx-tty-identify nil "\eP>|WezTerm 20240203\e\\") :version) "20240203"))
  (should (eq (drgnx-tty-test--id nil "\e[>65;7800;1c") 'vte))
  (should (equal (plist-get (drgnx-tty-identify nil "\e[>65;7800;1c") :version) "7800"))
  ;; the answer is the terminal itself: it wins over a variable inherited from another one
  (should (eq (drgnx-tty-test--id '(("KITTY_WINDOW_ID" . "1")) "\eP>|foot(1.21.0)\e\\") 'foot))
  ;; an answer naming nothing known leaves the environment to decide
  (should (eq (drgnx-tty-test--id '(("TERM" . "foot")) "\e[>1;2;0c") 'foot)))

(ert-deftest drgnx-tty/identify-nested-tmux-over-ssh ()
  ;; tmux inside SSH inside kitty (Review Focus 1): the terminal drgnx talks to is tmux
  (let ((env '(("TMUX" . "/tmp/tmux-1000/default,1234,0") ("TERM" . "tmux-256color")
               ("SSH_CONNECTION" . "10.0.0.2 51000 10.0.0.1 22") ("TERM_PROGRAM" . "tmux")
               ("TERM_PROGRAM_VERSION" . "3.7c"))))
    (should (equal (drgnx-tty-identify env) '(:id tmux :outer nil :version "3.7c")))
    (should (equal (drgnx-tty-identify (cons '("KITTY_WINDOW_ID" . "1") env)) '(:id tmux :outer kitty :version "3.7c")))
    ;; tmux's own answer agrees
    (should (eq (drgnx-tty-test--id env "\eP>|tmux 3.7c\e\\") 'tmux)))
  ;; TERM=tmux-* without TMUX: a tmux on the other side of SSH, still tmux (Task 10)
  (should (eq (drgnx-tty-test--id '(("TERM" . "tmux-256color") ("SSH_TTY" . "/dev/pts/3"))) 'tmux))
  ;; screen-* is tmux only with TMUX set
  (should (eq (drgnx-tty-test--id '(("TERM" . "screen-256color") ("TMUX" . "/tmp/t,1,0"))) 'tmux))
  (should (eq (drgnx-tty-test--id '(("TERM" . "screen-256color"))) 'unknown)))

(ert-deftest drgnx-tty/sendable-keys-by-capability ()
  (dolist (key '("C-p" "M-x" "<f1>" "C-x C-s" "C-M-a" "C-<up>" "S-<tab>" "C-_" "C-]" "C-@"))
    (should (drgnx-tty-key-sendable-p key 'legacy)))
  (dolist (key '("C-S-p" "C-`" "C-." "C-<return>" "s-p" "C-<tab>" "C-S-<tab>" "H-a" "C-x C-S-p" "C-1"))
    (should-not (drgnx-tty-key-sendable-p key 'legacy)))
  (dolist (key '("C-S-p" "C-`" "C-." "C-<return>" "C-<tab>" "C-S-<tab>" "C-p"))
    (should (drgnx-tty-key-sendable-p key 'mok)))
  (dolist (key '("s-p" "H-a" "C-x s-s"))
    (should-not (drgnx-tty-key-sendable-p key 'mok)))
  (dolist (key '("C-p" "M-x" "<f1>" "C-x C-s" "C-S-p" "C-`" "C-." "C-<return>" "s-p" "H-a"))
    (should (drgnx-tty-key-sendable-p key 'kkp)))
  (should (equal (drgnx-tty-unsendable '("C-p" "C-S-p" "<f1>" "C-.") 'legacy) '("C-S-p" "C-.")))
  (should-not (drgnx-tty-unsendable '("C-S-p" "C-.") 'kkp)))

(ert-deftest drgnx-tty/the-table-covers-every-terminal ()
  (should (equal (sort (mapcar (lambda (row) (plist-get row :id)) drgnx-tty-terminals) #'string<)
                 (sort (list 'kitty 'wezterm 'foot 'ghostty 'alacritty 'iterm2 'vte 'apple-terminal 'xterm 'linux 'tmux)
                       #'string<)))
  (dolist (row drgnx-tty-terminals)
    (dolist (key '(:id :name :kkp :mok :osc52 :truecolor :mouse :takes :fixes :verified :source))
      (should (plist-member row key)))
    (should (stringp (plist-get row :name)))
    (should (string-prefix-p "https://" (plist-get row :source)))
    (should-not (plist-get row :verified))     ; first version: every row "reported"
    (dolist (key (plist-get row :takes)) (should (key-valid-p key)))
    (dolist (cap '(kkp mok osc52 truecolor mouse))
      (unless (plist-get row (intern (format ":%s" cap)))
        (let ((fix (alist-get cap (plist-get row :fixes))))
          (ert-info ((format "%s lacks %s" (plist-get row :id) cap))
            (should (stringp fix))
            ;; "none" alone is not enough: it says why
            (should (> (length (string-trim (string-remove-prefix "none" fix))) 10))))))))

(defun drgnx-tty-test--tmp ()
  (file-name-as-directory (make-temp-file "drgnx-tty" t)))

(ert-deftest drgnx-tty/terminfo-lookup ()
  (dolist (sub '("x" "78"))
    (let* ((tmp (drgnx-tty-test--tmp))
           (process-environment (append (list (concat "TERMINFO=" tmp) (concat "HOME=" tmp) "TERMINFO_DIRS")
                                        process-environment))
           (drgnx-tty-terminfo-system-dirs nil))
      (unwind-protect
          (progn
            (should-not (drgnx-tty-terminfo-p "xterm-kitty"))
            (make-directory (expand-file-name sub tmp))
            (write-region "" nil (expand-file-name (concat sub "/xterm-kitty") tmp) nil 'silent)
            (should (drgnx-tty-terminfo-p "xterm-kitty"))
            (should-not (drgnx-tty-terminfo-p "xterm-ghostty"))
            (should-not (drgnx-tty-terminfo-p nil))
            (should-not (drgnx-tty-terminfo-p "")))
        (delete-directory tmp t))))
  ;; TERMINFO_DIRS, colon-separated, is searched too
  (let* ((tmp (drgnx-tty-test--tmp))
         (process-environment (append (list "TERMINFO" (concat "HOME=" tmp)
                                            (format "TERMINFO_DIRS=%snone:%sdirs" tmp tmp))
                                      process-environment))
         (drgnx-tty-terminfo-system-dirs nil))
    (unwind-protect
        (progn (make-directory (expand-file-name "dirs/f" tmp) t)
               (write-region "" nil (expand-file-name "dirs/f/foot" tmp) nil 'silent)
               (should (drgnx-tty-terminfo-p "foot")))
      (delete-directory tmp t))))

(ert-deftest drgnx-tty/tmux-options-with-a-fake-tmux ()
  (let* ((tmp (drgnx-tty-test--tmp))
         (ran (expand-file-name "ran" tmp))
         ;; drgnx finds tmux through exec-path: only the fake; the fake itself keeps the system's PATH
         (exec-path (list tmp))
         (process-environment (cons (format "PATH=%s:%s" tmp (getenv "PATH")) process-environment)))
    (unwind-protect
        (progn
          (write-region (format "#!/bin/sh\ntouch %s\nfor a in \"$@\"; do case \"$a\" in set-clipboard) echo on;; extended-keys) echo off;; esac; done\n"
                                (shell-quote-argument ran))
                        nil (expand-file-name "tmux" tmp) nil 'silent)
          (set-file-modes (expand-file-name "tmux" tmp) #o755)
          (let ((process-environment (cons "TMUX" process-environment)))
            (should-not (drgnx-tty-tmux-options))
            (should-not (file-exists-p ran)))
          (let ((process-environment (cons "TMUX=/tmp/fake,1,0" process-environment)))
            (should (equal (drgnx-tty-tmux-options) '(:set-clipboard "on" :extended-keys "off")))
            (should (file-exists-p ran))))
      (delete-directory tmp t))))

(ert-deftest drgnx-tty/tmux-options-give-up-after-a-second ()
  (let* ((tmp (drgnx-tty-test--tmp))
         (exec-path (list tmp))
         (process-environment (append (list (format "PATH=%s:%s" tmp (getenv "PATH")) "TMUX=/tmp/fake,1,0")
                                      process-environment)))
    (unwind-protect
        (progn
          (write-region "#!/bin/sh\nexec sleep 5\n" nil (expand-file-name "tmux" tmp) nil 'silent)
          (set-file-modes (expand-file-name "tmux" tmp) #o755)
          (let ((start (float-time)))
            (should-not (drgnx-tty-tmux-options))
            (should (< (- (float-time) start) 2))))
      (delete-directory tmp t))))

(ert-deftest drgnx-tty/facts-outside-a-terminal ()
  (let* ((tmp (drgnx-tty-test--tmp))
         (base (append (list (concat "XDG_STATE_HOME=" tmp) "TMUX" "SSH_CONNECTION" "SSH_TTY") process-environment)))
    (unwind-protect
        (progn
          (let ((process-environment (cons "TERM" base)))
            (should-not (plist-get (drgnx-tty-facts) :in-terminal))
            (should (plist-member (drgnx-tty-facts) :report)))
          (let ((process-environment (cons "TERM=dumb" base)))
            (should-not (plist-get (drgnx-tty-facts) :in-terminal)))
          ;; in a terminal: who it is, and the report Task 3 leaves in the state dir
          (make-directory (expand-file-name "drgnx" tmp))
          (write-region "(:kkp t)" nil (expand-file-name "drgnx/terminal-report.eld" tmp) nil 'silent)
          (let* ((process-environment (append '("TERM=xterm-kitty" "KITTY_WINDOW_ID=1" "COLORTERM=truecolor"
                                                "SSH_TTY=/dev/pts/1")
                                              base))
                 (facts (drgnx-tty-facts)))
            (should (plist-get facts :in-terminal))
            (should (equal (plist-get facts :term) "xterm-kitty"))
            (should (eq (plist-get (plist-get facts :identity) :id) 'kitty))
            (should (equal (plist-get facts :colorterm) "truecolor"))
            (should (plist-get facts :ssh))
            (should-not (plist-get facts :tmux))
            (should (equal (plist-get facts :report) '(:kkp t)))))
      (delete-directory tmp t))))

(ert-deftest drgnx-tty/the-onboarding-note ()
  (let ((note (drgnx-tty-onboard-note)))
    (dolist (name '("kitty" "WezTerm" "foot" "Ghostty"))
      (should (string-match-p (regexp-quote name) note)))
    (should-not (string-match-p "\n\n" note)))
  (let ((note (drgnx-tty-onboard-note 'vte)))
    (should (string-match-p "no C-S- chords" note))
    (should (string-match-p "no OSC 52" note))
    (should (string-match-p "F1" note))
    (should (string-match-p "palette" note))
    (should-not (string-match-p "\n\n" note)))
  ;; a terminal with a fix line shows it
  (should (string-match-p (regexp-quote "set -s set-clipboard on") (drgnx-tty-onboard-note 'tmux)))
  (should (stringp (drgnx-tty-onboard-note 'unknown))))

;;; tty-test.el ends here
