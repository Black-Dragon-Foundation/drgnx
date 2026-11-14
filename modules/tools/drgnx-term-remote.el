;;; drgnx-term-remote.el --- The terminal in a remote folder: the command that reaches it -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; New Terminal in a remote folder (a TRAMP file name) runs the user's login shell on that host, in that folder: the
;; terminal's PTY stays local and its program is one command (`drgnx-term-remote-command'): `ssh -t' for the ssh-like
;; methods (earlier ssh hops become -J, a last sudo/doas/su hop runs on the host), `docker'/`podman exec -it' and the
;; like for a container.  Its own connection, never TRAMP's (whose master ends with Emacs): the user's ssh config
;; decides.  The script on the host is POSIX sh, whatever the login shell (fish, csh) parses it: no quote, `!',
;; backslash or newline reaches that shell, the folder goes as octal escapes for printf.  Pure: nothing here connects
;; or runs anything.  docs/develop/terminal.md, "Remote terminals".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(eval-when-compile (require 'tramp))   ; its file-name struct's accessors; loaded for a remote folder only
(declare-function tramp-compute-multi-hops "tramp" (vec))
(declare-function tramp-dissect-file-name "tramp" (name &optional nodefault))

(declare-function tramp-kubernetes--container "tramp-container" (vec))
(declare-function tramp-kubernetes--pod "tramp-container" (vec))
(declare-function tramp-kubernetes--namespace "tramp-container" (vec))
(defvar tramp-kubernetes-context)

(defconst drgnx-term-remote-ssh-methods '("ssh" "sshx" "scp" "scpx" "rsync")
  "TRAMP methods whose host a terminal reaches with `ssh -t'.")

(defconst drgnx-term-remote-user-methods '("sudo" "doas" "su")
  "TRAMP methods a terminal takes as the last hop, on the host before them.")

(defconst drgnx-term-remote-container-methods '("docker" "podman" "kubernetes" "toolbox" "distrobox" "flatpak")
  "TRAMP methods whose container a terminal enters as the only hop.")

(defun drgnx-term-remote--octal (s)
  "S for printf's %b inside double quotes, safe for every shell's single quotes: bytes past the safe set (letters,
digits and `/._-+,:@%=~ ') as \\0NNN."
  (mapconcat (lambda (b)
               (if (or (<= ?a b ?z) (<= ?A b ?Z) (<= ?0 b ?9) (memq b '(?/ ?. ?_ ?- ?+ ?, ?: ?@ ?% ?= ?~ ?\s)))
                   (string b)
                 (format "\\0%03o" b)))
             (encode-coding-string s 'utf-8) ""))

(defun drgnx-term-remote-script (dir)
  "The POSIX sh script that goes to DIR (a folder on the host; nothing when it is not there) and becomes the user's
login shell: the passwd entry's shell, else $SHELL, else /bin/sh.  It holds no single quote, `!', newline or a
backslash other than DIR's escapes."
  (concat "d=\"$(printf %b \"" (drgnx-term-remote--octal dir) "x\")\"; d=\"${d%x}\"; cd -- \"$d\" 2>/dev/null; "
          "s=\"$(getent passwd \"$(id -un)\" 2>/dev/null | cut -d: -f7)\"; "
          "[ -x \"$s\" ] || s=\"$SHELL\"; [ -x \"$s\" ] || s=/bin/sh; exec \"$s\" -l"))

(defun drgnx-term-remote--sh (script)
  "The words that run SCRIPT with /bin/sh, as a login shell's command line: SCRIPT single-quoted (it has no quote)."
  (concat "/bin/sh -c '" script "'"))

(defun drgnx-term-remote--user-hop (vec script)
  "The command line on the host that becomes VEC's user (a sudo, doas or su hop) and runs SCRIPT."
  (let ((user (or (tramp-file-name-user vec) "root")))
    (pcase (tramp-file-name-method vec)
      ("sudo" (format "exec sudo -u %s -H -- %s" user (drgnx-term-remote--sh script)))
      ("doas" (format "exec doas -u %s %s" user (drgnx-term-remote--sh script)))
      ("su" (format "exec su -l %s -s /bin/sh -c '%s'" user script)))))

(defun drgnx-term-remote--jump (vec)
  "VEC's ssh hop as an -J destination: [USER@]HOST[:PORT]."
  (concat (if-let* ((u (tramp-file-name-user vec))) (concat u "@") "")
          (tramp-file-name-host vec)
          (if-let* ((p (tramp-file-name-port vec))) (concat ":" p) "")))

(defun drgnx-term-remote--ssh (hops last script)
  "`ssh -t' through HOPS (earlier ssh hops, as -J) to LAST (an ssh hop), running SCRIPT there."
  (append (list "ssh" "-t")
          (when-let* ((p (tramp-file-name-port last))) (list "-p" p))
          (when-let* ((u (tramp-file-name-user last))) (list "-l" u))
          (when hops (list "-J" (mapconcat #'drgnx-term-remote--jump hops ",")))
          (list (tramp-file-name-host last) script)))

(defun drgnx-term-remote--container (vec dir)
  "The local command entering container VEC (a container method's only hop) in DIR, or nil."
  (let ((sh (list "/bin/sh" "-c" (drgnx-term-remote-script dir)))
        (host (tramp-file-name-host vec))
        (user (tramp-file-name-user vec)))
    (pcase (tramp-file-name-method vec)
      ((and (or "docker" "podman") m)
       (append (list m "exec" "-it" "-w" dir) (and user (list "-u" user)) (list host) sh))
      ("kubernetes"
       (require 'tramp-container)
       (let ((container (tramp-kubernetes--container vec)) (ns (tramp-kubernetes--namespace vec)))
         (append (list "kubectl")
                 (and (bound-and-true-p tramp-kubernetes-context) (list "--context" tramp-kubernetes-context))
                 (and ns (list "-n" ns))
                 (list "exec" "-it")
                 (and (not (string-empty-p container)) (list "-c" container))
                 (list (tramp-kubernetes--pod vec) "--")
                 sh)))
      ("toolbox" (append (list "toolbox" "run") (and host (not (string-empty-p host)) (list "-c" host)) sh))
      ("distrobox" (append (list "distrobox" "enter" "-n" host "--") sh))
      ("flatpak" (append (list "flatpak-spawn" "--app" host) sh)))))

(defun drgnx-term-remote-hops (dir)
  "The hops TRAMP takes to remote DIR, the first first (`tramp-compute-multi-hops', so the proxies of
`tramp-default-proxies-alist' count), or nil for a local DIR or one TRAMP refuses."
  (when (file-remote-p dir)
    (require 'tramp)
    (ignore-errors (tramp-compute-multi-hops (tramp-dissect-file-name dir)))))

(defun drgnx-term-remote-command (dir)
  "The local command (a program and its arguments) that opens the user's login shell in remote DIR, or nil when its
method has none (eshell then).  ssh-like hops: `ssh -t', earlier ones as -J, a last sudo/doas/su hop run by the
host's ssh; a container method as the only hop: its exec.  No control options from TRAMP: the user's ssh config
decides."
  (let* ((hops (drgnx-term-remote-hops dir))
         (path (and hops (tramp-file-name-localname (car (last hops)))))
         (methods (mapcar #'tramp-file-name-method hops)))
    (cond
     ((null hops) nil)
     ((and (null (cdr hops)) (member (car methods) drgnx-term-remote-container-methods))
      (drgnx-term-remote--container (car hops) path))
     (t
      (let* ((user (and (member (car (last methods)) drgnx-term-remote-user-methods) (car (last hops))))
             (ssh (if user (butlast hops) hops)))
        (when (and ssh (cl-every (lambda (m) (member m drgnx-term-remote-ssh-methods))
                                 (mapcar #'tramp-file-name-method ssh)))
          (let ((script (drgnx-term-remote-script path)))
            (drgnx-term-remote--ssh (butlast ssh) (car (last ssh))
                                    (if user (drgnx-term-remote--user-hop user script)
                                      (concat "exec " (drgnx-term-remote--sh script)))))))))))

(defun drgnx-term-remote-host (dir)
  "The host a terminal in remote DIR runs on, for its title: the last hop with a host's name."
  (when-let* ((hops (drgnx-term-remote-hops dir)))
    (let ((h (cl-find-if (lambda (v) (let ((h (tramp-file-name-host v))) (and h (not (string-empty-p h)))))
                         (reverse (if (member (tramp-file-name-method (car (last hops))) drgnx-term-remote-user-methods)
                                      (butlast hops) hops)))))
      (and h (tramp-file-name-host h)))))

(provide 'drgnx-term-remote)
;;; drgnx-term-remote.el ends here
