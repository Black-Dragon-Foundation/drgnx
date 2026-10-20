;;; tty-test.el --- batch tests: what a terminal is and can do -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-tty)
(require 'drgnx-paths)

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

;; docs/guide/terminal.md's table says "verified" for the rows a tier ran and "reported" for the rest: the data decides
(ert-deftest drgnx-tty/the-guide-table-says-what-ran ()
  (let* ((doc (with-temp-buffer (insert-file-contents (expand-file-name "docs/guide/terminal.md" drgnx-dir)) (buffer-string)))
         (section (substring doc (string-search "## What each terminal can do" doc) (string-search "\n## The fixes" doc)))
         (seen nil))
    (dolist (row drgnx-tty-terminals)
      (let* ((name (plist-get row :name))
             (line (seq-find (lambda (l) (string-prefix-p (format "| [%s](%s) |" name (plist-get row :source)) l))
                             (split-string section "\n"))))
        (ert-info ((format "%s" name))
          (should line)
          (push (plist-get row :id) seen)
          ;; the last cell: "verified" followed by what ran, or "reported"
          (should (string-match-p (if (plist-get row :verified) "| verified[^|]* |\\'" "| reported |\\'") line)))))
    (should (= (length seen) (length drgnx-tty-terminals)))
    (should (= (length drgnx-tty-terminals) (with-temp-buffer (insert section) (how-many "^| \\[" (point-min) (point-max)))))))

(ert-deftest drgnx-tty/the-table-covers-every-terminal ()
  (should (equal (sort (mapcar (lambda (row) (plist-get row :id)) drgnx-tty-terminals) #'string<)
                 (sort (list 'kitty 'wezterm 'foot 'ghostty 'alacritty 'iterm2 'vte 'apple-terminal 'xterm 'linux 'tmux)
                       #'string<)))
  (dolist (row drgnx-tty-terminals)
    (dolist (key '(:id :name :kkp :mok :osc52 :truecolor :mouse :takes :fixes :verified :source :unconfirmed))
      (should (plist-member row key)))
    ;; cells the linked documentation does not back are named, and only cells can be named
    (dolist (cell (plist-get row :unconfirmed))
      (should (memq cell '(:kkp :mok :osc52 :truecolor :mouse :takes))))
    (should (stringp (plist-get row :name)))
    (should (string-prefix-p "https://" (plist-get row :source)))
    ;; "reported" but the three a tier ran: kitty (the exit test, test/tty/kitty-test.el; its true colour is no
    ;; longer unconfirmed), tmux and an xterm-like terminal (the tty tier under tmux): what ran
    (if (memq (plist-get row :id) '(kitty tmux xterm))
        (should (stringp (plist-get row :verified)))
      (should-not (plist-get row :verified)))
    (when (eq (plist-get row :id) 'kitty)
      (should (equal (plist-get row :unconfirmed) '(:mok :mouse))))
    (dolist (key (plist-get row :takes)) (should (key-valid-p key)))
    (dolist (cap '(kkp mok osc52 truecolor mouse))
      (unless (plist-get row (intern (format ":%s" cap)))
        (let ((fix (alist-get cap (plist-get row :fixes))))
          (ert-info ((format "%s lacks %s" (plist-get row :id) cap))
            (should (stringp fix))
            ;; "none" alone is not enough: it says why
            (should (> (length (string-trim (string-remove-prefix "none" fix))) 10)))))))
  ;; "yes" means "with its default settings": iTerm2 needs a setting for kkp, so it is no, with the fix
  (let ((iterm (drgnx-tty-terminal 'iterm2)))
    (should-not (plist-get iterm :kkp))
    (should (string-match-p "Apps can change how keys are reported" (alist-get 'kkp (plist-get iterm :fixes)))))
  ;; xterm's OSC 52 fix drops SetSelection from its documented default list
  (should (equal (alist-get 'osc52 (plist-get (drgnx-tty-terminal 'xterm) :fixes))
                 "XTerm*disallowedWindowOps: GetChecksum,GetIconTitle,GetSelection,GetWinTitle,SetXprop   (in ~/.Xresources: xterm's default list without SetSelection)")))

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
  ;; a TERM is a file name, never a path: nothing outside the terminfo dirs, and directories do not count
  (let* ((tmp (drgnx-tty-test--tmp))
         (dir (expand-file-name "ti/" tmp))
         (process-environment (append (list (concat "TERMINFO=" dir) (concat "HOME=" tmp) "TERMINFO_DIRS")
                                      process-environment))
         (drgnx-tty-terminfo-system-dirs nil))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "x/xdir" dir) t)
          (make-directory (expand-file-name "2e" dir) t)
          (write-region "" nil (expand-file-name "evil" tmp) nil 'silent)       ; TI/./../evil and TI/2e/../../evil
          (write-region "" nil (expand-file-name "x/xterm" dir) nil 'silent)
          (should (drgnx-tty-terminfo-p "xterm"))
          (should-not (drgnx-tty-terminfo-p "../evil"))
          (should-not (drgnx-tty-terminfo-p ".hidden"))
          (should-not (drgnx-tty-terminfo-p "x/../x/xterm"))
          (should-not (drgnx-tty-terminfo-p "xterm\0"))
          (should-not (drgnx-tty-terminfo-p "xdir")))
      (delete-directory tmp t)))
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

;; What the real tmux prints for the one command `drgnx-tty-tmux-options' sends: the `display -p' line
;; (version|client_termname|client_termfeatures|client_termtype), then the `show -q' lines (NAME VALUE) of the
;; options this tmux has.
(defconst drgnx-tty-test--tmux-default-answer
  "3.4|xterm-kitty|256,RGB|kitty(0.39.1)\nset-clipboard on\nextended-keys off\nfocus-events off\nallow-passthrough off\n")

(defun drgnx-tty-test--fake-tmux (dir ran &optional answer)
  "A fake tmux in DIR: it writes its TMUX, its working directory and its arguments to RAN and prints ANSWER
\(default `drgnx-tty-test--tmux-default-answer')."
  (write-region (or answer drgnx-tty-test--tmux-default-answer) nil (expand-file-name "tmux-answer" dir) nil 'silent)
  (write-region (format "#!/bin/sh
{ echo \"TMUX=$TMUX\"; echo \"PWD=$(pwd)\"; echo \"ARGS=$*\"; } > %s
cat %s\n"
                        (shell-quote-argument ran) (shell-quote-argument (expand-file-name "tmux-answer" dir)))
                nil (expand-file-name "tmux" dir) nil 'silent)
  (set-file-modes (expand-file-name "tmux" dir) #o755))

(defun drgnx-tty-test--options-from (answer)
  "`drgnx-tty-tmux-options' against a fake tmux that prints ANSWER."
  (let* ((tmp (drgnx-tty-test--tmp))
         (exec-path (list tmp))
         (process-environment (append (list (format "PATH=%s:%s" tmp (getenv "PATH")) "TMUX=/tmp/fake,1,0")
                                      process-environment)))
    (unwind-protect
        (progn (drgnx-tty-test--fake-tmux tmp (expand-file-name "ran" tmp) answer)
               (drgnx-tty-tmux-options))
      (delete-directory tmp t))))

(ert-deftest drgnx-tty/tmux-options-with-a-fake-tmux ()
  (let* ((tmp (drgnx-tty-test--tmp))
         (ran (expand-file-name "ran" tmp))
         ;; drgnx finds tmux through exec-path: only the fake; the fake itself keeps the system's PATH
         (exec-path (list tmp))
         (process-environment (cons (format "PATH=%s:%s" tmp (getenv "PATH")) process-environment)))
    (unwind-protect
        (progn
          (drgnx-tty-test--fake-tmux tmp ran)
          (let ((process-environment (cons "TMUX" process-environment)))
            (should-not (drgnx-tty-tmux-options))
            (should-not (file-exists-p ran)))
          (let ((process-environment (cons "TMUX=/tmp/fake,1,0" process-environment)))
            (should (equal (drgnx-tty-tmux-options)
                           '(:version "3.4" :set-clipboard "on" :allow-passthrough "off" :extended-keys "off"
                                      :extended-keys-format nil :focus-events "off" :rgb t :outer-term "xterm-kitty"
                                      :client-termtype "kitty(0.39.1)")))
            (should (file-exists-p ran))
            ;; one tmux call asks for everything
            (let ((args (with-temp-buffer (insert-file-contents ran) (buffer-string))))
              (dolist (want '("display -p" "#{version}" "#{client_termname}" "#{client_termfeatures}" "show -sq set-clipboard"
                              "show -sq extended-keys" "show -sq extended-keys-format" "show -sq focus-events"
                              "show -gq allow-passthrough"))
                (should (string-match-p (regexp-quote want) args))))))
      (delete-directory tmp t))))

(ert-deftest drgnx-tty/tmux-options-and-the-conf-lines ()
  (let ((lines (lambda (answer) (drgnx-tty-tmux-conf-lines (drgnx-tty-test--options-from answer)))))
    ;; everything off, tmux 3.2 (no allow-passthrough option, no extended-keys-format): what is missing, in order
    (should (equal (funcall lines "3.2|xterm-256color|256|\nset-clipboard external\nextended-keys off\nfocus-events off\n")
                   '("set -s set-clipboard on" "set -s extended-keys on" "set -g focus-events on"
                     "set -as terminal-features ',xterm-256color:RGB'")))
    ;; 3.4: passthrough exists too (the spelling of the version does not matter: 3.3a, next-3.5)
    (dolist (version '("3.4" "3.3a" "next-3.5"))
      (should (equal (funcall lines (format "%s|xterm-kitty|256|\nset-clipboard off\nextended-keys off\nfocus-events off\nallow-passthrough off\n" version))
                     '("set -s set-clipboard on" "set -s extended-keys on" "set -g allow-passthrough on"
                       "set -g focus-events on" "set -as terminal-features ',xterm-kitty:RGB'"))))
    ;; everything on: nothing to add (extended-keys always is on too)
    (should-not (funcall lines "3.7c|xterm-kitty|256,RGB,clipboard|\nset-clipboard on\nextended-keys always\nextended-keys-format xterm\nfocus-events on\nallow-passthrough on\n"))
    ;; set-clipboard on makes passthrough unnecessary, whatever its value
    (should-not (member "set -g allow-passthrough on"
                        (funcall lines "3.7c|xterm-kitty|256,RGB|\nset-clipboard on\nextended-keys off\nfocus-events off\nallow-passthrough off\n")))
    ;; a client with no terminal name has nothing to add RGB to
    (should-not (seq-some (lambda (l) (string-match-p "terminal-features" l))
                          (funcall lines "3.4||256|\nset-clipboard on\nextended-keys on\nfocus-events on\nallow-passthrough on\n")))
    ;; extended-keys-format csi-u is never suggested: Emacs does not decode tmux's csi-u output (docs/guide/terminal.md)
    (should-not (seq-some (lambda (l) (string-match-p "extended-keys-format" l))
                          (funcall lines "3.7c|xterm-kitty|256|\nset-clipboard off\nextended-keys off\nextended-keys-format xterm\nfocus-events off\nallow-passthrough off\n")))
    ;; no tmux options: no lines
    (should-not (drgnx-tty-tmux-conf-lines nil))))

(ert-deftest drgnx-tty/tmux-options-give-up-after-a-second ()
  :tags '(:timing)
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

(ert-deftest drgnx-tty/the-report-is-read-through-the-file-layer ()
  ;; a plist is the report; a file with a mistake, one that is not a plist and a missing one are nil
  (let* ((tmp (drgnx-tty-test--tmp))
         (process-environment (cons (concat "XDG_STATE_HOME=" tmp) process-environment))
         (file (expand-file-name "drgnx/terminal-report.eld" tmp)))
    (unwind-protect
        (progn
          (should-not (drgnx-tty--read-report))
          (make-directory (file-name-directory file))
          (dolist (text '("(:kkp t" "(:kkp t) (:more)" "(1 2 3)" "#1=(:kkp . #1#)" "[:kkp t]"))
            (write-region text nil file nil 'silent)
            (should-not (drgnx-tty--read-report))
            (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) text)))
          (write-region ";; a note\n(:kkp t :terminals ((\"/dev/pts/1\" . (:caps nil))))\n" nil file nil 'silent)
          (should (equal (drgnx-tty--read-report) '(:kkp t :terminals (("/dev/pts/1" :caps nil))))))
      (delete-directory tmp t))))

(ert-deftest drgnx-tty/the-client-environment-wins ()
  ;; in a daemon, process-environment is the daemon's own: the client's ENV (or its FRAME) decides
  (let* ((tmp (drgnx-tty-test--tmp))
         (ran (expand-file-name "ran" tmp))
         (daemon-ti (expand-file-name "daemon-ti/" tmp))
         (client-ti (expand-file-name "client-ti/" tmp))
         (exec-path (list tmp))
         (drgnx-tty-terminfo-system-dirs nil)
         (process-environment (append (list (format "PATH=%s:%s" tmp (getenv "PATH")) "TMUX=/tmp/daemon-sock,1,0"
                                            "TERM=xterm-daemon" (concat "TERMINFO=" daemon-ti) (concat "HOME=" tmp)
                                            "TERMINFO_DIRS" (concat "XDG_STATE_HOME=" tmp))
                                      process-environment))
         (env `(("TERM" . "xterm-kitty") ("TMUX" . "/tmp/client-sock,2,0") ("TERMINFO" . ,client-ti)
                ("HOME" . ,tmp) ("KITTY_WINDOW_ID" . "1")))
         (frame (selected-frame))
         (saved (frame-parameter frame 'environment)))
    (unwind-protect
        (progn
          (drgnx-tty-test--fake-tmux tmp ran)
          (make-directory (expand-file-name "x" daemon-ti) t)
          (make-directory (expand-file-name "x" client-ti) t)
          (write-region "" nil (expand-file-name "x/xterm-daemon" daemon-ti) nil 'silent)
          (write-region "" nil (expand-file-name "x/xterm-kitty" client-ti) nil 'silent)
          ;; terminfo: the client's TERMINFO (the one the daemon's ncurses reads for this client's frame)
          (should (drgnx-tty-terminfo-p "xterm-kitty" env))
          (should-not (drgnx-tty-terminfo-p "xterm-daemon" env))
          (should-not (drgnx-tty-terminfo-p "xterm-kitty"))
          ;; tmux: the client's server, through its socket and its TMUX; run from a local directory
          (should (equal (plist-get (drgnx-tty-tmux-options env) :set-clipboard) "on"))
          (let ((log (with-temp-buffer (insert-file-contents ran) (buffer-string))))
            (should (string-match-p "^TMUX=/tmp/client-sock,2,0$" log))
            (should (string-match-p "^ARGS=-S /tmp/client-sock display" log))
            (should (string-match-p "^PWD=/$" log)))
          ;; a client outside tmux is outside tmux, even when the daemon was started in one
          (delete-file ran)
          (should-not (drgnx-tty-tmux-options '(("TERM" . "xterm-kitty"))))
          (should-not (file-exists-p ran))
          ;; facts for a FRAME read that frame's environment
          (set-frame-parameter frame 'environment
                               (mapcar (lambda (pair) (format "%s=%s" (car pair) (cdr pair))) env))
          (let ((facts (drgnx-tty-facts frame)))
            (should (equal (plist-get facts :term) "xterm-kitty"))
            (should (plist-get facts :terminfo))
            (should (equal (plist-get facts :identity) '(:id tmux :outer kitty :version nil)))
            (should (equal (plist-get (plist-get facts :tmux) :extended-keys) "off"))))
      (set-frame-parameter frame 'environment saved)
      (delete-directory tmp t))))

(ert-deftest drgnx-tty/tmux-names-the-outer-terminal ()
  ;; tmux 3.4+ knows its client's terminal (#{client_termtype}): better than a variable inherited by the server
  (let* ((tmp (drgnx-tty-test--tmp))
         (exec-path (list tmp))
         (process-environment (append (list (format "PATH=%s:%s" tmp (getenv "PATH")) (concat "XDG_STATE_HOME=" tmp))
                                      process-environment))
         (frame (selected-frame))
         (saved (frame-parameter frame 'environment)))
    (unwind-protect
        (progn
          (drgnx-tty-test--fake-tmux tmp (expand-file-name "ran" tmp))
          ;; a stale WEZTERM_PANE from the server's first client; tmux says kitty
          (set-frame-parameter frame 'environment '("TERM=tmux-256color" "TMUX=/tmp/s,1,0" "WEZTERM_PANE=3"))
          (should (eq (plist-get (plist-get (drgnx-tty-facts frame) :identity) :outer) 'kitty)))
      (set-frame-parameter frame 'environment saved)
      (delete-directory tmp t))))

(ert-deftest drgnx-tty/env-is-the-frame-s-then-its-client-s-then-this-emacs-s ()
  ;; a frame made later on a client's terminal has the client but no environment of its own
  (let ((client (make-pipe-process :name "kx-client" :noquery t))
        (process-environment (cons "TERM=xterm-own" process-environment))
        params)
    (unwind-protect
        (cl-letf (((symbol-function 'frame-parameter) (lambda (_f p) (alist-get p params))))
          (process-put client 'env '("TERM=xterm-kitty" "KITTY_WINDOW_ID=1"))
          (setq params `((environment . ("TERM=foot")) (client . ,client)))
          (should (equal (cdr (assoc "TERM" (drgnx-tty-env (selected-frame)))) "foot"))
          (setq params `((environment . nil) (client . ,client)))
          (should (equal (cdr (assoc "TERM" (drgnx-tty-env (selected-frame)))) "xterm-kitty"))
          (should (equal (cdr (assoc "KITTY_WINDOW_ID" (drgnx-tty-env (selected-frame)))) "1"))
          (setq params '((environment . nil)))
          (should (equal (cdr (assoc "TERM" (drgnx-tty-env (selected-frame)))) "xterm-own"))
          (should (equal (cdr (assoc "TERM" (drgnx-tty-env))) "xterm-own")))
      (delete-process client))))

(ert-deftest drgnx-tty/the-report-is-read-safely ()
  (let* ((tmp (drgnx-tty-test--tmp))
         (marker (expand-file-name "evaluated" tmp))
         (report (expand-file-name "drgnx/terminal-report.eld" tmp))
         (process-environment (append (list (concat "XDG_STATE_HOME=" tmp) "TERM") process-environment)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory report) t)
          (write-region "(:kkp t" nil report nil 'silent)          ; garbled: cut short
          (should-not (plist-get (drgnx-tty-facts) :report))
          ;; Emacs's reader has no read-time evaluation (no `read-eval', unlike Common Lisp): `#.' is an error
          (write-region (format "#.(progn (write-region \"\" nil %S) '(:kkp t))" marker) nil report nil 'silent)
          (should-not (plist-get (drgnx-tty-facts) :report))
          (should-not (file-exists-p marker))
          ;; a report that is not a plist is no report
          (write-region "\"just a string\"" nil report nil 'silent)
          (should-not (plist-get (drgnx-tty-facts) :report)))
      (delete-directory tmp t))))

(ert-deftest drgnx-tty/the-onboarding-note ()
  (let ((note (drgnx-tty-onboard-note)))
    (dolist (name '("kitty" "WezTerm" "foot" "Ghostty"))
      (should (string-match-p (regexp-quote name) note)))
    ;; WezTerm needs no setting (modifyOtherKeys); every one of them keeps some chords for itself
    (should-not (string-match-p "kitty_keyboard" note))
    (should-not (string-match-p "kitty_keyboard" (drgnx-tty-onboard-note 'wezterm)))
    ;; the list comes from the table and the recommender's order: key protocol and OSC 52, modifyOtherKeys first
    (let ((names (mapcar (lambda (id) (plist-get (drgnx-tty-terminal id) :name))
                         (seq-filter (lambda (id)
                                       (let ((row (drgnx-tty-terminal id)))
                                         (and (or (plist-get row :kkp) (plist-get row :mok)) (plist-get row :osc52))))
                                     drgnx-tty-best-order))))
      (should (equal names '("WezTerm" "Ghostty" "foot" "kitty" "Alacritty")))
      (should (string-match-p (regexp-quote "works best in WezTerm, Ghostty, foot, kitty, or Alacritty") note)))
    ;; the kitty keyboard protocol terminals are named with the C-g limit; the others are not
    (should (string-match-p "In Ghostty, foot, kitty and Alacritty, C-g cannot stop busy Lisp" note))
    (should (string-match-p "keeps some" note))
    (should-not (string-match-p "\n\n" note)))
  (should (string-match-p "keeps 62 shortcuts for itself" (drgnx-tty-onboard-note 'kitty)))
  ;; a claim the documentation does not back says so
  (should (string-match-p "the mouse (unconfirmed)" (drgnx-tty-onboard-note 'tmux)))
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

(ert-deftest drgnx-tty/folded-chords-are-unsendable-though-the-keys-allow-them ()
  ;; tmux at modifyOtherKeys level 1 sends C-S-p as C-p: mok could send it, tmux does not
  (should (drgnx-tty-key-sendable-p "C-S-p" 'mok))
  (should (equal (drgnx-tty-unsendable '("C-S-p" "C-p" "C-." "C-M-S-k" "C-S-SPC" "C-`" "C-S-`" "C-S-<tab>") 'mok
                                       drgnx-tty-tmux-folded-chords)
                 '("C-S-p" "C-M-S-k" "C-S-SPC" "C-`" "C-S-`")))
  ;; without the list, as before
  (should-not (drgnx-tty-unsendable '("C-S-p") 'mok))
  (should (equal (drgnx-tty-unsendable '("C-S-p") 'legacy drgnx-tty-tmux-folded-chords) '("C-S-p"))))

(ert-deftest drgnx-tty/a-folded-chord-in-a-key-sequence-is-unsendable ()
  ;; "C-k C-S-p" needs C-S-p as its second key: tmux at level 1 sends C-p there
  (should (equal (drgnx-tty-unsendable '("C-k C-S-p" "C-k C-p" "C-S-p C-k" "C-x C-f") 'mok drgnx-tty-tmux-folded-chords)
                 '("C-k C-S-p" "C-S-p C-k"))))
