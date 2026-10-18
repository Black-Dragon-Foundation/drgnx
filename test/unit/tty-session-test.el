;;; tty-session-test.el --- batch tests: the tty harness's key, mouse and screen helpers -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-tty-session)

(ert-deftest drgnx-tty-session/encodes-keys ()
  (should (equal (drgnx-tty-session-encode "C-S-p" 'kkp) "\e[112;6u"))
  (should (equal (drgnx-tty-session-encode "C-S-p" 'mok) "\e[27;6;80~"))
  (should (equal (drgnx-tty-session-encode "C-`" 'kkp) "\e[96;5u"))
  (should (equal (drgnx-tty-session-encode "C-`" 'mok) "\e[27;5;96~"))
  ;; Shift with punctuation: modifyOtherKeys reports the shifted character (US layout), kkp the key
  (should (equal (drgnx-tty-session-encode "C-S-`" 'mok) "\e[27;6;126~"))
  (should (equal (drgnx-tty-session-encode "C-S-`" 'kkp) "\e[96;6u"))
  (should (equal (drgnx-tty-session-encode "C-." 'kkp) "\e[46;5u"))
  (should (equal (drgnx-tty-session-encode "C-g" 'kkp) "\e[103;5u"))
  (should (equal (drgnx-tty-session-encode "C-g" 'legacy) "\a"))
  (should-error (drgnx-tty-session-encode "C-S-p" 'legacy))
  ;; what every terminal sends alike
  (dolist (caps '(legacy mok kkp))
    (should (equal (drgnx-tty-session-encode "a" caps) "a"))
    (should (equal (drgnx-tty-session-encode "RET" caps) "\r")))
  (should (equal (drgnx-tty-session-encode "C-p" 'mok) "\C-p"))
  (should (equal (drgnx-tty-session-encode "M-x" 'legacy) "\ex"))
  (should (equal (drgnx-tty-session-encode "C-x C-s" 'legacy) "\C-x\C-s"))
  (should (equal (drgnx-tty-session-encode "C-<return>" 'mok) "\e[27;5;13~"))
  (should (equal (drgnx-tty-session-encode "C-<return>" 'kkp) "\e[13;5u"))
  (should-error (drgnx-tty-session-encode "C-<return>" 'legacy))
  (should-error (drgnx-tty-session-encode "s-p" 'mok))
  (should (equal (drgnx-tty-session-encode "s-p" 'kkp) "\e[112;9u"))
  (should (equal (drgnx-tty-session-encode "é" 'legacy) (encode-coding-string "é" 'utf-8)))
  (should-not (multibyte-string-p (drgnx-tty-session-encode "é" 'kkp))))

(ert-deftest drgnx-tty-session/encodes-mouse ()
  (should (equal (drgnx-tty-session--click-bytes 10 5) "\e[<0;10;5M\e[<0;10;5m"))
  (should (equal (drgnx-tty-session--click-bytes 10 5 :mods '(control)) "\e[<16;10;5M\e[<16;10;5m"))
  (should (equal (drgnx-tty-session--click-bytes 10 5 :button 3) "\e[<2;10;5M\e[<2;10;5m"))
  (should (equal (drgnx-tty-session--click-bytes 10 5 :double t)
                 "\e[<0;10;5M\e[<0;10;5m\e[<0;10;5M\e[<0;10;5m"))
  (should (equal (drgnx-tty-session--wheel-bytes 10 5 'down) "\e[<65;10;5M"))
  (should (equal (drgnx-tty-session--wheel-bytes 10 5 'up) "\e[<64;10;5M"))
  (should (equal (drgnx-tty-session--drag-bytes '(10 . 5) '(14 . 5))
                 "\e[<0;10;5M\e[<32;14;5M\e[<0;14;5m")))

(ert-deftest drgnx-tty-session/finds-text-on-the-screen ()
  (let ((screen "line one\n  *scratch*   (Lisp Interaction)\nlast"))
    (should (equal (drgnx-tty-session--find-in screen "\\*scratch\\*") '(3 . 2)))
    (should (equal (drgnx-tty-session--find-in screen "\\`line") '(1 . 1)))
    (should (equal (drgnx-tty-session--find-in screen "Lisp") '(16 . 2)))
    (should-not (drgnx-tty-session--find-in screen "absent")))
  ;; columns are cells: a wide character before the match takes two
  (should (equal (drgnx-tty-session--find-in "漢x" "x") '(3 . 1))))

(ert-deftest drgnx-tty-session/a-process-of-another-pid-namespace-is-not-ours ()
  ;; a container's tmux server is named after the container's PIDs; a host sweep must not take it for a dead runner's
  (cl-letf (((symbol-function 'file-symlink-p)
             (lambda (f) (pcase f ("/proc/self/ns/pid" "pid:[1]") ("/proc/42/ns/pid" "pid:[1]")
                                ("/proc/43/ns/pid" "pid:[9]") (_ nil)))))
    (should (drgnx-tty-session--same-pid-namespace-p 42))
    (should-not (drgnx-tty-session--same-pid-namespace-p 43)))
  ;; where /proc has no namespaces (macOS, an old kernel) every process is ours, as before
  (cl-letf (((symbol-function 'file-symlink-p) (lambda (_) nil)))
    (should (drgnx-tty-session--same-pid-namespace-p 43))))

(ert-deftest drgnx-tty-session/the-sweep-leaves-another-pid-namespace-alone ()
  (let (removed)
    (cl-letf (((symbol-function 'drgnx-ui--run)
               (lambda (&rest _) (cons 0 "43 tmux -L drgnx-tty-2-1 -f /dev/null -D\n")))
              ((symbol-function 'drgnx-tty-session--owner-alive-p) (lambda (_) nil))
              ((symbol-function 'drgnx-tty-session--run-of) (lambda (_) "/run/x"))
              ((symbol-function 'drgnx-tty-session--remove-stale) (lambda (name run) (push (cons name run) removed))))
      ;; its own namespace: a dead runner's session, removed
      (cl-letf (((symbol-function 'drgnx-tty-session--same-pid-namespace-p) (lambda (_) t)))
        (drgnx-tty-session--sweep "/nonexistent-root"))
      (should (equal removed '(("drgnx-tty-2-1" . "/run/x"))))
      ;; another one (a container's): not ours to kill
      (setq removed nil)
      (cl-letf (((symbol-function 'drgnx-tty-session--same-pid-namespace-p) (lambda (_) nil)))
        (drgnx-tty-session--sweep "/nonexistent-root"))
      (should-not removed))))

(ert-deftest drgnx-tty-session/the-default-state-root-is-short-and-private ()
  ;; TTY-SOCK-1: the tmux socket is RUN/tmux-UID/NAME, with a 7-digit PID twice in NAME; a long state root passed ~107 bytes
  (let* ((tmp (make-temp-file "drgnx-ttyroot" t))
         (temporary-file-directory (file-name-as-directory tmp))
         (process-environment (cons "DRGNX_UI_STATE" process-environment)))
    (unwind-protect
        (let ((root (drgnx-tty-session-state-root)))
          (should (equal root (expand-file-name (format "t%d" (user-uid)) tmp)))
          (should (equal (file-attribute-modes (file-attributes root)) "drwx------"))
          (should (equal (drgnx-tty-session-state-root) root))            ; again: the same directory, no error
          ;; a directory of that name that is not private is refused, not used
          (set-file-modes root #o755)
          (should-error (drgnx-tty-session-state-root) :type 'drgnx-ui-error)
          ;; a root of the caller's choice wins
          (let ((process-environment (cons "DRGNX_UI_STATE=/some/root" process-environment)))
            (should (equal (drgnx-tty-session-state-root) "/some/root"))))
      (delete-directory tmp t))))

(ert-deftest drgnx-tty-session/a-private-tmp-dir-that-is-a-symlink-is-refused ()
  ;; /tmp is shared: someone may have made the name first, as a link to a directory of their own
  (let* ((tmp (make-temp-file "drgnx-ttylink" t))
         (elsewhere (make-temp-file "drgnx-ttylink-target" t))
         (temporary-file-directory (file-name-as-directory tmp)))
    (unwind-protect
        (progn
          (set-file-modes elsewhere #o700)
          (make-symbolic-link elsewhere (expand-file-name "t-link" tmp))
          (should-error (drgnx-ui-private-tmp-dir "t-link" "it holds nothing") :type 'drgnx-ui-error)
          ;; a plain file of that name is no directory either
          (write-region "" nil (expand-file-name "t-file" tmp))
          (should-error (drgnx-ui-private-tmp-dir "t-file" "it holds nothing") :type 'file-error))
      (delete-directory tmp t)
      (delete-directory elsewhere t))))

;;; tty-session-test.el ends here

(ert-deftest drgnx-tty-session/encodes-named-keys ()
  ;; as xterm sends them, in every terminal alike: CSI, the modifier as 1 + shift 1, meta 2, control 4
  (dolist (caps '(legacy mok kkp))
    (should (equal (drgnx-tty-session-encode "<up>" caps) "\e[A"))
    (should (equal (drgnx-tty-session-encode "<down>" caps) "\e[B"))
    (should (equal (drgnx-tty-session-encode "<right>" caps) "\e[C"))
    (should (equal (drgnx-tty-session-encode "<left>" caps) "\e[D"))
    (should (equal (drgnx-tty-session-encode "C-<up>" caps) "\e[1;5A"))
    (should (equal (drgnx-tty-session-encode "<home>" caps) "\e[H"))
    (should (equal (drgnx-tty-session-encode "S-<end>" caps) "\e[1;2F"))
    (should (equal (drgnx-tty-session-encode "<prior>" caps) "\e[5~"))
    (should (equal (drgnx-tty-session-encode "C-<next>" caps) "\e[6;5~"))
    (should (equal (drgnx-tty-session-encode "<f1>" caps) "\eOP"))
    (should (equal (drgnx-tty-session-encode "<f4>" caps) "\eOS"))
    (should (equal (drgnx-tty-session-encode "S-<f1>" caps) "\e[1;2P"))
    (should (equal (drgnx-tty-session-encode "<f5>" caps) "\e[15~"))
    (should (equal (drgnx-tty-session-encode "<f10>" caps) "\e[21~"))
    (should (equal (drgnx-tty-session-encode "<f12>" caps) "\e[24~"))
    (should (equal (drgnx-tty-session-encode "M-<f12>" caps) "\e[24;3~")))
  (should-error (drgnx-tty-session-encode "s-<up>" 'mok))
  (should (equal (drgnx-tty-session-encode "s-<up>" 'kkp) "\e[1;9A"))
  (should-error (drgnx-tty-session-encode "<f13>" 'kkp)))

(ert-deftest drgnx-tty-session/sends-text-as-utf-8 ()
  (let (calls)
    (cl-letf (((symbol-function 'drgnx-tty-session-tmux) (lambda (_sess &rest args) (push args calls) '(0 . ""))))
      (drgnx-tty-session-send '(:name "drgnx-tty-1-1" :target "%0") "é")
      (drgnx-tty-session-send '(:name "drgnx-tty-1-1" :target "%0") (encode-coding-string "é" 'utf-8))
      (drgnx-tty-session-send '(:name "drgnx-tty-1-1" :target "%0") "漢"))
    (should (equal (nreverse calls)
                   '(("send-keys" "-t" "%0" "-H" "c3" "a9")
                     ("send-keys" "-t" "%0" "-H" "c3" "a9")
                     ("send-keys" "-t" "%0" "-H" "e6" "bc" "a2"))))))

(ert-deftest drgnx-tty-session/a-key-profile-is-a-keys-file ()
  (let ((dir (make-temp-file "drgnx-tty-keys" t)))
    (unwind-protect
        (progn
          (drgnx-tty-session--write-keys dir 'emacs)
          (should (equal (with-temp-buffer (insert-file-contents (expand-file-name "keys.eld" dir))
                                           (read (current-buffer)))
                         '(:layers ((emacs app editing window)))))
          (drgnx-tty-session--write-keys dir "vim")
          (should (equal (with-temp-buffer (insert-file-contents (expand-file-name "keys.eld" dir))
                                           (read (current-buffer)))
                         '(:layers ((vim app editing window)))))
          (should-error (drgnx-tty-session--write-keys dir 'nano)))
      (delete-directory dir t))))

(ert-deftest drgnx-tty-session/package-dirs-prefer-the-pinned-version ()
  (let* ((elpa (make-temp-file "drgnx-elpa" t))
         (lock (make-temp-file "drgnx-lock")))
    (unwind-protect
        (progn
          (dolist (d '("corfu-2.9" "corfu-2.16" "corfu-20261014.1751" "compat-31.1.0.0" "corfu-terminal-0.7" "corfu-2.16.signed"))
            (make-directory (expand-file-name d elpa)))
          (with-temp-file lock (insert "(:version 1 :packages ((corfu :version \"2.16\") (compat :version \"30.0.0.0\")))"))
          ;; the pinned one; compat's pin is not installed, so its newest; corfu-terminal is another package
          (should (equal (drgnx-tty-session-user-package-dirs '(corfu compat) elpa lock)
                         (list (expand-file-name "corfu-2.16" elpa) (expand-file-name "compat-31.1.0.0" elpa))))
          ;; no pin: the newest
          (with-temp-file lock (insert "(:version 1 :packages nil)"))
          (should (equal (car (drgnx-tty-session-user-package-dirs '(corfu) elpa lock))
                         (expand-file-name "corfu-20261014.1751" elpa)))
          ;; a package that is not there, or no directory: nil
          (should-not (drgnx-tty-session-user-package-dirs '(corfu vertico) elpa lock))
          (should-not (drgnx-tty-session-user-package-dirs '(corfu) (expand-file-name "none" elpa) lock))
          (should (string-match-p "DRGNX_USER_ELPA" (drgnx-tty-session-packages-hint '(corfu compat)))))
      (delete-directory elpa t)
      (delete-file lock))))

(ert-deftest drgnx-tty-session/a-kitty-session-s-bus-is-its-own ()
  ;; the bus kitty and the keyboard's Emacs get is the session's (dbus-run-session's): never none, never the caller's
  (let ((process-environment (cons "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1/bus" process-environment)))
    (should (equal (drgnx-tty-session--session-bus "unix:path=/tmp/dbus-x" "drgnx-ui-1") "unix:path=/tmp/dbus-x"))
    (should-error (drgnx-tty-session--session-bus nil "drgnx-ui-1") :type 'drgnx-ui-error)
    (should-error (drgnx-tty-session--session-bus "unix:path=/run/user/1/bus" "drgnx-ui-1") :type 'drgnx-ui-error)))
