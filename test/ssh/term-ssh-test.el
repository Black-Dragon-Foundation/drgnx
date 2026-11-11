;;; term-ssh-test.el --- the terminal in a remote folder, over a real sshd on loopback -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The ssh row only (test/container/ssh-row.sh): root in a container whose image has sshd, ssh, tcsh, sudo and tic.
;; The first test starts an sshd on 127.0.0.1:2222 with a host key, users (fishy: fish, sudo; cshy: tcsh; pwuser:
;; bash, a password) and a client key all made here, in a temporary folder; the terminals' ssh reads its config from
;; there (an `ssh' on PATH adds -F), never from a home folder.  The hub, its worker and the waits are term-test.el's.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'tramp)
(require 'drgnx)
(load (expand-file-name "test/unit/term-test" drgnx-dir) nil t)   ; the gated hub, the worker and the waits

(defvar drgnx-term-ssh-test--dir nil "The run's folder of keys, configs and the ssh wrapper, once sshd is up.")

(defconst drgnx-term-ssh-test--folder "/tmp/it's a dir/" "A folder with a space and a quote in its name.")

(defun drgnx-term-ssh-test--sh (script)
  "Run SCRIPT with /bin/sh as root; it must succeed."
  (with-temp-buffer
    (let ((rc (call-process "/bin/sh" nil t nil "-ec" script)))
      (unless (eql rc 0) (error "Setup failed (%s): %s" rc (buffer-string))))))

(defun drgnx-term-ssh-test--setup ()
  "The sshd of this run, started once: its folder."
  (or drgnx-term-ssh-test--dir
      (let ((d (make-temp-file "drgnx-ssh" t)))
        ;; the row's image and user, or a loud failure: never a skip
        (should (file-executable-p "/usr/sbin/sshd"))
        (should (eql 0 (user-uid)))
        (drgnx-term-ssh-test--sh
         (format "cd %s
ssh-keygen -q -t ed25519 -N '' -f host
ssh-keygen -q -t ed25519 -N '' -f id
for u in fishy:/usr/bin/fish cshy:/bin/tcsh pwuser:/bin/bash; do
  n=${u%%%%:*}; id \"$n\" >/dev/null 2>&1 || useradd -m -s \"${u#*:}\" \"$n\"
done
for n in fishy cshy; do
  install -d -m 700 -o $n -g $n /home/$n/.ssh
  install -m 600 -o $n -g $n id.pub /home/$n/.ssh/authorized_keys
  usermod -p '*' $n   # no password, yet not locked: without PAM, sshd refuses even a key to a locked account
done
echo 'pwuser:drgnx-pw-1' | chpasswd
echo 'fishy ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/drgnx-test
mkdir -p %s && chmod 777 %s
cat > sshd_config <<END
ListenAddress 127.0.0.1
Port 2222
HostKey $PWD/host
PidFile $PWD/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
UsePAM no
LogLevel VERBOSE
END
printf '[127.0.0.1]:2222 %%s\\n' \"$(cut -d' ' -f1,2 host.pub)\" > known_hosts
cat > ssh_config <<END
Host box
  HostName 127.0.0.1
  Port 2222
  User fishy
  IdentityFile $PWD/id
  IdentitiesOnly yes
  UserKnownHostsFile $PWD/known_hosts
  StrictHostKeyChecking yes
Host pwbox
  HostName 127.0.0.1
  Port 2222
  User pwuser
  PubkeyAuthentication no
  PreferredAuthentications password
  UserKnownHostsFile $PWD/known_hosts
  StrictHostKeyChecking yes
END
mkdir bin
printf '#!/bin/sh\\nexec /usr/bin/ssh -F %%s \"$@\"\\n' \"$PWD/ssh_config\" > bin/ssh
chmod +x bin/ssh
/usr/sbin/sshd -f sshd_config -E sshd.log"
                 (shell-quote-argument d) (shell-quote-argument drgnx-term-ssh-test--folder)
                 (shell-quote-argument drgnx-term-ssh-test--folder)))
        (drgnx-term-test--settle
         (lambda () (ignore-errors (delete-process (make-network-process :name "sshd-probe" :host "127.0.0.1"
                                                                         :service 2222))
                                   t))
         "sshd listening")
        (setq drgnx-term-ssh-test--dir d))))

(defmacro drgnx-term-ssh-test--with (&rest body)
  "BODY with the gated hub (`drgnx-term-test--with'), this run's sshd, its ssh first on PATH and no proxies."
  (declare (indent 0))
  `(drgnx-term-test--with
     (let* ((d (drgnx-term-ssh-test--setup))
            (process-environment (append (list (concat "PATH=" d "/bin:" (getenv "PATH"))
                                               (concat "XDG_STATE_HOME=" d "/state"))
                                         process-environment))
            (tramp-default-proxies-alist nil) (tramp-save-ad-hoc-proxies nil))
       ,@body)))

(defun drgnx-term-ssh-test--open (dir)
  "A new terminal in remote DIR: its buffer."
  (let ((b (drgnx-terminal-new dir)))
    (should (eq (buffer-local-value 'major-mode b) 'drgnx-term-mode))
    (should (equal (buffer-local-value 'drgnx-term--remote b) (file-remote-p dir)))
    b))

(defun drgnx-term-ssh-test--who (buffer user folder)
  "Ask BUFFER's shell who and where it is; wait for USER and FOLDER."
  (drgnx-term-test--run buffer "id -un; pwd")
  (condition-case err
      (progn (drgnx-term-test--until-line buffer user (format "the user %s" user))
             (drgnx-term-test--until-line buffer folder (format "the folder %s" folder)))
    (ert-test-failed
     ;; what the terminal showed instead: the login's own words (a refused key, a shell's question)
     (message "%s showed:\n%s" (buffer-name buffer) (string-join (drgnx-term-test--lines buffer) "\n"))
     (let ((log (expand-file-name "sshd.log" drgnx-term-ssh-test--dir)))
       (when (file-readable-p log)
         (message "sshd said:\n%s" (with-temp-buffer (insert-file-contents log) (buffer-string)))))
     (signal (car err) (cdr err)))))

(defun drgnx-term-ssh-test--close (buffer)
  "Close BUFFER's terminal, if it is open."
  (when (buffer-live-p buffer)
    (let ((kill-buffer-query-functions nil)) (kill-buffer buffer))))

(ert-deftest drgnx-term-ssh/fish-and-csh-users-reach-the-folder ()
  ;; their login shells parse the command line; the folder's quote and space reach the host's sh as they are
  (drgnx-term-ssh-test--with
    (let ((fish (drgnx-term-ssh-test--open (concat "/ssh:box:" drgnx-term-ssh-test--folder)))
          (csh (drgnx-term-ssh-test--open (concat "/ssh:cshy@box:" drgnx-term-ssh-test--folder))))
      (unwind-protect
          (progn
            (drgnx-term-ssh-test--who fish "fishy" (directory-file-name drgnx-term-ssh-test--folder))
            (drgnx-term-ssh-test--who csh "cshy" (directory-file-name drgnx-term-ssh-test--folder))
            (should (string-prefix-p "*terminal: box" (buffer-name fish))))
        (mapc #'drgnx-term-ssh-test--close (list fish csh))))))

(ert-deftest drgnx-term-ssh/a-sudo-hop-reaches-root ()
  (drgnx-term-ssh-test--with
    (let ((b (drgnx-term-ssh-test--open "/ssh:box|sudo:root@box:/root/")))
      (unwind-protect (drgnx-term-ssh-test--who b "root" "/root")
        (drgnx-term-ssh-test--close b)))))

(ert-deftest drgnx-term-ssh/the-folder-follows-the-host-not-a-foreign-one ()
  (drgnx-term-ssh-test--with
    (let ((b (drgnx-term-ssh-test--open "/ssh:box:/tmp/")))
      (unwind-protect
          (progn
            (drgnx-term-ssh-test--who b "fishy" "/tmp")
            (drgnx-term-test--run b "cd /etc; /bin/sh -c 'printf \"\\033]7;file://$(uname -n)/etc\\007\"'")
            (drgnx-term-test--settle (lambda () (equal (buffer-local-value 'default-directory b) "/ssh:box:/etc/"))
                                     "the folder on the host")
            (drgnx-term-test--run b "/bin/sh -c 'printf \"\\033]7;file://elsewhere/usr\\007\"'; echo fo''reign-sent")
            (drgnx-term-test--until-line b "foreign-sent" "the foreign folder sent")
            (should (equal (buffer-local-value 'default-directory b) "/ssh:box:/etc/")))
        (drgnx-term-ssh-test--close b)))))

(ert-deftest drgnx-term-ssh/a-remote-clipboard-write-asks ()
  (drgnx-term-ssh-test--with
    (let ((b (drgnx-term-ssh-test--open "/ssh:box:/tmp/")) (kill-ring nil) (drgnx-term-remote-clipboard-write 'ask))
      (unwind-protect
          (progn
            (drgnx-term-ssh-test--who b "fishy" "/tmp")
            (drgnx-term-test--run b "/bin/sh -c 'printf \"\\033]52;c;aGk=\\007\"'")
            (drgnx-term-test--settle
             (lambda () (seq-find (lambda (n) (string-suffix-p "wants to set the clipboard" (plist-get n :text)))
                                  (drgnx-notices :source 'term)))
             "the question")
            (should-not kill-ring)
            (drgnx-term--clipboard-answered b 'allow)
            (should (equal kill-ring '("hi"))))
        (drgnx-term-ssh-test--close b)))))

(ert-deftest drgnx-term-ssh/a-dropped-connection-shows-reconnect ()
  (drgnx-term-ssh-test--with
    (let ((b (drgnx-term-ssh-test--open "/ssh:box:/tmp/")))
      (unwind-protect
          (progn
            (drgnx-term-ssh-test--who b "fishy" "/tmp")
            (drgnx-term-ssh-test--sh "pkill -f 'sshd-session: fishy|sshd: fishy'")
            (drgnx-term-test--settle (lambda () (eq (buffer-local-value 'drgnx-term--state b) 'exited)) "ssh's end")
            (should (buffer-live-p b))
            (should (string-search "Connection lost (exit 255)"
                                   (car (buffer-local-value 'header-line-format b))))
            (with-current-buffer b (drgnx-term-reconnect))
            (drgnx-term-test--settle (lambda () (eq (buffer-local-value 'drgnx-term--state b) 'open)) "the new terminal")
            (drgnx-term-test--run b "echo a''gain-$USER")
            (drgnx-term-test--until-line b "again-fishy" "the new shell"))
        (drgnx-term-ssh-test--close b)))))

(ert-deftest drgnx-term-ssh/install-sends-terminfo-after-a-password-in-the-terminal ()
  ;; both ssh's password prompts show in the terminal; the host's tic gets the entry, the record says so, TERM follows
  (drgnx-term-ssh-test--with
    (let* ((d drgnx-term-ssh-test--dir) (ti (expand-file-name "terminfo" d))
           (drgnx-term-ssh-terminfo 'install) (drgnx-term-term "xterm-ghostty") b)
      (drgnx-term-ssh-test--sh
       (format "tic -x -o %s %s" (shell-quote-argument ti)
               (shell-quote-argument (expand-file-name "etc/shell/ghostty/terminfo/xterm-ghostty.terminfo" drgnx-dir))))
      (cl-letf (((symbol-function 'drgnx-term--terminfo) (lambda () ti)))
        (unwind-protect
            (cl-flet ((prompts () (cl-count-if (lambda (l) (string-match-p "password: *\\'" l))
                                               (drgnx-term-test--lines b))))
              (setq b (drgnx-term-ssh-test--open "/ssh:pwbox:/tmp/"))
              (drgnx-term-test--settle (lambda () (>= (prompts) 1)) "tic's ssh asks")
              (drgnx-term-test--run b "drgnx-pw-1")
              (drgnx-term-test--settle (lambda () (>= (prompts) 2)) "the shell's ssh asks")
              (drgnx-term-test--run b "drgnx-pw-1")
              ;; ssh flushes what was typed ahead when it leaves the password (TCSAFLUSH): type once bash's prompt shows
              (drgnx-term-test--settle
               (lambda () (seq-some (lambda (l) (string-match-p "pwuser@.*\\$ *\\'" l)) (drgnx-term-test--lines b)))
               "the host's prompt")
              (drgnx-term-test--run b "echo term-$TERM")
              (drgnx-term-test--until-line b "term-xterm-ghostty" "TERM on the host")
              (should (file-exists-p (expand-file-name ".terminfo/x/xterm-ghostty" "~pwuser")))
              (should (string-search "pwuser@127.0.0.1:2222 xterm-ghostty"
                                     (with-temp-buffer
                                       (insert-file-contents (expand-file-name "state/drgnx/terminal-ssh-hosts" d))
                                       (buffer-string)))))
          (drgnx-term-ssh-test--close b))))))

(ert-deftest drgnx-term-ssh/kept-at-quit-the-next-emacs-reattaches-the-same-remote-shell ()
  (drgnx-term-ssh-test--with
    (let* ((b (drgnx-term-ssh-test--open "/ssh:box:/tmp/")) (id (buffer-local-value 'drgnx-term--id b)))
      (unwind-protect
          (progn
            (drgnx-term-test--settle (lambda () (buffer-local-value 'drgnx-term--id b)) "the terminal's id")
            (setq id (buffer-local-value 'drgnx-term--id b))
            (drgnx-term-test--run b "echo kept-''remote-1")
            (drgnx-term-test--until-line b "kept-remote-1" "the echo")
            (let ((pid (plist-get (drgnx-term-test--row id) :pid)))
              (let ((drgnx-term-on-quit 'ask) (drgnx-session-quit-keep 'keep) (drgnx-term--quit-keep (list id)))
                (drgnx-term--session-end))
              (drgnx-term-test--settle (lambda () (plist-get (drgnx-term-test--row id) :detached_at)) "detached")
              (drgnx-term-test--drop b)
              (drgnx-term-test--as-new-emacs
                (let* ((row (drgnx-term-test--offered id)) (nb (drgnx-term-reattach-one row t)))
                  (should (equal (plist-get row :remote) "/ssh:box:"))
                  (drgnx-term-test--settle (lambda () (eq (buffer-local-value 'drgnx-term--state nb) 'open)) "the attach")
                  (should (equal (buffer-local-value 'drgnx-term--remote nb) "/ssh:box:"))
                  (should (file-remote-p (buffer-local-value 'default-directory nb)))
                  (drgnx-term-test--until-line nb "kept-remote-1" "the scrollback, back")
                  (should (eql (plist-get (drgnx-term-test--row id) :pid) pid))
                  (drgnx-term-test--run nb "echo a''gain-$USER")
                  (drgnx-term-test--until-line nb "again-fishy" "the same remote shell answers")))))
        (when id (ignore-errors (drgnx-term-test--ask "term/close" (list :id id))))))))

(provide 'term-ssh-test)
;;; term-ssh-test.el ends here
