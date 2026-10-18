;;; drgnx-sandbox-macos.el --- Job agents in a sandbox on macOS: the Seatbelt (SBPL) profile -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The macOS back end of drgnx-sandbox.el: the same spec becomes a Seatbelt profile (SBPL, the policy language of
;; `sandbox-exec'), which `drgnx-sandbox-wrap' writes to the spec's `:profile-file' and runs as
;; `sandbox-exec -f FILE COMMAND…'.  macOS has no mount namespace: nothing is bound anywhere, every path is seen at its
;; own place, and what the agent may touch is the profile's allow list.  Deny by default; SBPL's last matching rule
;; decides, so the order of the rules is the policy.  This file builds text and runs nothing.  Verified on a Mac only
;; (the MAC-SB rows).  See docs/develop/sandbox.md, "macOS: Seatbelt".

;;; Code:
(require 'cl-lib)
(require 'drgnx-sandbox)

;; The base below is Codex's published Seatbelt base policy, unchanged: openai/codex,
;; codex-rs/sandboxing/src/seatbelt_base_policy.sbpl at commit 8c076942cb70fba8e5c4732c23f1faabc4aed484,
;; https://github.com/openai/codex — Copyright 2025 OpenAI, licensed under the Apache License, Version 2.0
;; (https://www.apache.org/licenses/LICENSE-2.0).  drgnx adds its own rules after it (`drgnx-sandbox-sbpl').
(defconst drgnx-sandbox-macos-base
  "(version 1)

; inspired by Chrome's sandbox policy:
; https://source.chromium.org/chromium/chromium/src/+/main:sandbox/policy/mac/common.sb;l=273-319;drc=7b3962fe2e5fc9e2ee58000dc8fbf3429d84d3bd
; https://source.chromium.org/chromium/chromium/src/+/main:sandbox/policy/mac/renderer.sb;l=64;drc=7b3962fe2e5fc9e2ee58000dc8fbf3429d84d3bd

; start with closed-by-default
\(deny default)

; child processes inherit the policy of their parent
\(allow process-exec)
\(allow process-fork)
\(allow signal (target same-sandbox))

; process-info
\(allow process-info* (target same-sandbox))

\(allow file-write-data
  (require-all
    (path \"/dev/null\")
    (vnode-type CHARACTER-DEVICE)))

; sysctls permitted.
\(allow sysctl-read
  (sysctl-name \"hw.activecpu\")
  (sysctl-name \"hw.busfrequency_compat\")
  (sysctl-name \"hw.byteorder\")
  (sysctl-name \"hw.cacheconfig\")
  (sysctl-name \"hw.cachelinesize_compat\")
  (sysctl-name \"hw.cpufamily\")
  (sysctl-name \"hw.cpufrequency_compat\")
  (sysctl-name \"hw.cputype\")
  (sysctl-name \"hw.l1dcachesize_compat\")
  (sysctl-name \"hw.l1icachesize_compat\")
  (sysctl-name \"hw.l2cachesize_compat\")
  (sysctl-name \"hw.l3cachesize_compat\")
  (sysctl-name \"hw.logicalcpu_max\")
  (sysctl-name \"hw.machine\")
  (sysctl-name \"hw.model\")
  (sysctl-name \"hw.memsize\")
  (sysctl-name \"hw.ncpu\")
  (sysctl-name \"hw.nperflevels\")
  ; Chrome locks these CPU feature detection down a bit more tightly,
  ; but mostly for fingerprinting concerns which isn't an issue for codex.
  (sysctl-name-prefix \"hw.optional.arm.\")
  (sysctl-name-prefix \"hw.optional.armv8_\")
  (sysctl-name \"hw.packages\")
  (sysctl-name \"hw.pagesize_compat\")
  (sysctl-name \"hw.pagesize\")
  (sysctl-name \"hw.physicalcpu\")
  (sysctl-name \"hw.physicalcpu_max\")
  (sysctl-name \"hw.logicalcpu\")
  (sysctl-name \"hw.cpufrequency\")
  (sysctl-name \"hw.tbfrequency_compat\")
  (sysctl-name \"hw.vectorunit\")
  (sysctl-name \"machdep.cpu.brand_string\")
  (sysctl-name \"kern.argmax\")
  (sysctl-name \"kern.hostname\")
  (sysctl-name \"kern.maxfilesperproc\")
  (sysctl-name \"kern.maxproc\")
  (sysctl-name \"kern.osproductversion\")
  (sysctl-name \"kern.osrelease\")
  (sysctl-name \"kern.ostype\")
  (sysctl-name \"kern.osvariant_status\")
  (sysctl-name \"kern.osversion\")
  (sysctl-name \"kern.secure_kernel\")
  ; Python's ProcessPoolExecutor queries this through sysconf(_SC_SEM_NSEMS_MAX).
  (sysctl-name \"kern.sysv.semmns\")
  (sysctl-name \"kern.usrstack64\")
  (sysctl-name \"kern.version\")
  (sysctl-name \"sysctl.proc_cputype\")
  (sysctl-name \"vm.loadavg\")
  (sysctl-name-prefix \"hw.perflevel\")
  (sysctl-name-prefix \"kern.proc.pgrp.\")
  (sysctl-name-prefix \"kern.proc.pid.\")
  (sysctl-name-prefix \"net.routetable.\")
)

; Allow Java to read some CPU info. This is misclassified as a \"write\" because
; userspace passes a memory buffer to the sysctl, but conceptually it is a read.
\(allow sysctl-write
  (sysctl-name \"kern.grade_cputype\"))

; IOKit
\(allow iokit-open
  (iokit-registry-entry-class \"RootDomainUserClient\")
)

; needed to look up user info, see https://crbug.com/792228
\(allow mach-lookup
  (global-name \"com.apple.system.opendirectoryd.libinfo\")
)

; Needed for python multiprocessing on MacOS for the SemLock
\(allow ipc-posix-sem)

; Needed for PyTorch/libomp on macOS to register OpenMP runtimes.
\(allow ipc-posix-shm-read-data
  ipc-posix-shm-write-create
  ipc-posix-shm-write-unlink
  (ipc-posix-name-regex #\"^/__KMP_REGISTERED_LIB_[0-9]+$\"))

\(allow mach-lookup
  (global-name \"com.apple.PowerManagement.control\")
)

; allow openpty()
\(allow pseudo-tty)
\(allow file-read* file-write* file-ioctl (literal \"/dev/ptmx\"))
\(allow file-read* file-write*
  (require-all
    (regex #\"^/dev/ttys[0-9]+\")
    (extension \"com.apple.sandbox.pty\")))
; PTYs created before entering seatbelt may lack the extension; allow ioctl
; on those slave ttys so interactive shells detect a TTY and remain functional.
\(allow file-ioctl (regex #\"^/dev/ttys[0-9]+\"))
"
  "The rules every profile starts with: `(version 1)', `(deny default)', process exec and fork, the sysctls, the
mach services a Node CLI needs (user lookup, power management), POSIX IPC and pseudo-terminals.  Codex's base policy,
unchanged (Apache-2.0; the source is cited above).  No AppleEvents, no `lsopen', no LaunchServices and no Keychain
\(com.apple.SecurityServer): jobs on macOS use the gateway profiles.")

(defconst drgnx-sandbox-macos-system-read
  '("/usr" "/bin" "/sbin" "/System" "/Library" "/opt/homebrew" "/private/etc" "/dev" "/private/var/select"
    "/private/var/db/timezone" "/private/var/db/xcode_select_link")
  "What every profile reads, as true names: the system's roots, /bin and /sbin (real directories on macOS),
/private/var/select (the link /bin/sh and xcrun follow), the time zones (/etc/localtime leads there) and the
selected developer dir (the git of the Command Line Tools).")

(defconst drgnx-sandbox-macos-links '("/tmp" "/var" "/etc")
  "The top-level links into /private: their own metadata only, so a path through one resolves.  What they lead to is
allowed or not by its true name (/private/tmp, /private/var/…, /private/etc).")

(defconst drgnx-sandbox-macos-users "/Users"
  "Where the users' homes are: denied before every allow, so only what the spec allows there is readable.")

(defconst drgnx-sandbox-macos-dns-socket "/private/var/run/mDNSResponder"
  "The system resolver's socket: every host name lookup goes through it.  Allowed with `:net shared' only.")

(defconst drgnx-sandbox-macos-dns-files '("/private/var/run/resolv.conf")
  "The resolver's configuration, read by resolvers that do not ask mDNSResponder (Go's).  `:net shared' only.")

(defconst drgnx-sandbox-macos-net-services
  '("com.apple.bsd.dirhelper" "com.apple.system.opendirectoryd.membership" "com.apple.networkd" "com.apple.ocspd"
    "com.apple.trustd.agent" "com.apple.SystemConfiguration.DNSConfiguration" "com.apple.SystemConfiguration.configd")
  "The mach services a networked CLI needs (TLS trust, the network's configuration, user dirs): Codex's network
policy (seatbelt_network_policy.sbpl, same commit and licence as the base) without com.apple.SecurityServer.")

(defconst drgnx-sandbox-macos--max-literal 1024
  "The most bytes an SBPL string literal may have: sandbox-exec refuses a longer one (\"Error reading string\").")

;;;; Quoting

(defun drgnx-sandbox-macos--refuse (fmt &rest args)
  "Signal `drgnx-sandbox-refused' with the reason (`format' FMT ARGS)."
  (signal 'drgnx-sandbox-refused (list (apply #'format fmt args))))

(defun drgnx-sandbox-macos--quote (string)
  "STRING as an SBPL string literal: in double quotes, with `\"' and `\\' escaped by a backslash.  Signals
`drgnx-sandbox-refused' for anything else than a string, for a control character (a newline, a tab, NUL, DEL: SBPL's
reader would take some of them as escapes, and no path drgnx binds has one) and for a literal sandbox-exec would
refuse as too long."
  (unless (stringp string) (drgnx-sandbox-macos--refuse "%S is not a string for a Seatbelt profile" string))
  (when (string-match-p "[[:cntrl:]\177]" string)
    (drgnx-sandbox-macos--refuse "%S holds a control character: refused in a Seatbelt profile" string))
  (let ((body (replace-regexp-in-string "[\"\\]" (lambda (c) (concat "\\" c)) string t t)))
    (when (> (length (encode-coding-string body 'utf-8-unix)) drgnx-sandbox-macos--max-literal)
      (drgnx-sandbox-macos--refuse "%s… is longer than a Seatbelt profile allows (%d bytes)" (substring string 0 40)
                                   drgnx-sandbox-macos--max-literal))
    (concat "\"" body "\"")))

;;;; The profile

(defun drgnx-sandbox-macos--rule (action ops filter paths)
  "One SBPL rule: (ACTION OPS (FILTER PATH)…), one PATH a line; nil when there are no PATHS."
  (and paths
       (concat "(" action " " ops
               (mapconcat (lambda (p) (format "\n  (%s %s)" filter (drgnx-sandbox-macos--quote p))) paths "")
               ")")))

(defun drgnx-sandbox-macos--ancestors (paths)
  "Every directory above PATHS (canonical absolute names), but /, without duplicates, in order."
  (let ((file-name-handler-alist nil) dirs)
    (dolist (p paths)
      (let ((d (directory-file-name (file-name-directory p))))
        (while (not (string= d "/"))
          (unless (member d dirs) (push d dirs))
          (setq d (directory-file-name (file-name-directory d))))))
    (nreverse dirs)))

(defun drgnx-sandbox-macos--port (spec key)
  "SPEC's KEY (`:proxy', `:gateway'): a TCP port, or nil; refused when out of range."
  (let ((port (plist-get spec key)))
    (when (and port (not (and (natnump port) (<= 1 port 65535))))
      (drgnx-sandbox-macos--refuse "%s %S is not a TCP port" key port))
    port))

(defun drgnx-sandbox-sbpl (spec)
  "SPEC's Seatbelt profile, as text.  In order (SBPL: the last matching rule decides):
- `drgnx-sandbox-macos-base': `(version 1)', `(deny default)', processes, sysctls, the base's mach services;
- AF_UNIX sockets may be made (pipes to child processes); connecting to one is decided at the end;
- `(deny file-read* (subpath \"/Users\"))', before every allow;
- reads: / itself, the metadata of every directory above an allowed path and of /tmp, /var and /etc (links), the
  system's roots (`drgnx-sandbox-macos-system-read'), `:read', `:write', `:home' (its OUTSIDE: no mounts here, so the
  session's HOME must name it), `:run' and `:tmp';
- writes: `:write', `:home', `:tmp';
- `:binds', in order: each readable, and writable for rw, not writable for ro (the git pins);
- `:hide': neither readable nor writable, a file or a whole directory;
- network: `:net shared' allows outbound IP anywhere, the services of `drgnx-sandbox-macos-net-services' and the
  resolver; `:net isolated' denies all network, then allows outbound to localhost's `:proxy' and `:gateway' ports;
- Unix sockets: all denied, then the spec's `:sockets' allowed one by one (and, shared, the resolver's).
Every path is a quoted string (`drgnx-sandbox-macos--quote').  Signals `drgnx-sandbox-refused' with
`drgnx-sandbox-validate''s reason, for a bind whose INSIDE is not its OUTSIDE, a port out of range or a path SBPL
cannot hold."
  (when-let* ((why (drgnx-sandbox-validate spec))) (signal 'drgnx-sandbox-refused (list why)))
  (pcase-dolist (`(,_ ,outside ,inside) (plist-get spec :binds))
    (unless (string= outside inside)
      (drgnx-sandbox-macos--refuse ":binds: %s cannot be seen at %s: macOS has no mounts" outside inside)))
  (let* ((shared (not (eq (plist-get spec :net) 'isolated)))
         (proxy (drgnx-sandbox-macos--port spec :proxy)) (gateway (drgnx-sandbox-macos--port spec :gateway))
         (home (car (plist-get spec :home))) (run (plist-get spec :run)) (tmp (plist-get spec :tmp))
         (binds (plist-get spec :binds))
         (reads (delete-dups (append drgnx-sandbox-macos-system-read (and shared drgnx-sandbox-macos-dns-files)
                                     (plist-get spec :read) (plist-get spec :write) (and home (list home))
                                     (and run (list run)) (and tmp (list tmp)))))
         (writes (append (plist-get spec :write) (and home (list home)) (and tmp (list tmp))))
         (sockets (append (plist-get spec :sockets) (and shared (list drgnx-sandbox-macos-dns-socket)))))
    (mapconcat
     #'identity
     (delq nil
           `(,drgnx-sandbox-macos-base
             "; drgnx: the rules from the session's spec (drgnx-sandbox-sbpl)"
             "(allow system-socket (socket-domain AF_UNIX))"
             ,(drgnx-sandbox-macos--rule "deny" "file-read*" "subpath" (list drgnx-sandbox-macos-users))
             ,(drgnx-sandbox-macos--rule "allow" "file-read*" "literal" '("/"))
             ,(drgnx-sandbox-macos--rule "allow" "file-read-metadata" "literal"
                                         (delete-dups
                                          (append drgnx-sandbox-macos-links
                                                  (drgnx-sandbox-macos--ancestors
                                                   (append reads (mapcar #'cadr binds) (plist-get spec :sockets))))))
             ,(drgnx-sandbox-macos--rule "allow" "file-read*" "subpath" reads)
             ,(drgnx-sandbox-macos--rule "allow" "file-write*" "subpath" writes)
             ,@(cl-loop for (mode path) in binds
                        collect (drgnx-sandbox-macos--rule "allow" "file-read*" "subpath" (list path))
                        collect (drgnx-sandbox-macos--rule (if (eq mode 'rw) "allow" "deny") "file-write*" "subpath"
                                                           (list path)))
             ,(drgnx-sandbox-macos--rule "deny" "file-read* file-write*" "subpath" (plist-get spec :hide))
             ,@(if shared
                   (list "(allow network-outbound (remote ip \"*:*\"))")
                 (cons "(deny network*)"
                       (cl-loop for port in (list proxy gateway) when port
                                collect (format "(allow network-outbound (remote ip \"localhost:%d\"))" port))))
             "(allow system-socket (require-all (socket-domain AF_SYSTEM) (socket-protocol 2)))"
             ,(drgnx-sandbox-macos--rule "allow" "mach-lookup" "global-name" drgnx-sandbox-macos-net-services)
             "(deny network-outbound (remote unix-socket))"
             ,@(mapcar (lambda (s) (format "(allow network-outbound (remote unix-socket (path-literal %s)))"
                                           (drgnx-sandbox-macos--quote s)))
                       sockets)))
     "\n")))

;;;; The session's TMPDIR

(defun drgnx-sandbox-macos-tmpdir (sid)
  "A new directory for session SID's TMPDIR, mode 0700, under `temporary-file-directory' (on macOS the user's own
/private/var/folders/…/T/), as its true name.  Made with a random suffix and refused if it exists, so nothing planted
there before is used.  SID must be a plain name (letters, digits, `.', `_', `-'; not starting with `.' or `-')."
  (let ((name (format "%s" sid)) (file-name-handler-alist nil))
    (unless (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9._-]*\\'" name)
      (drgnx-sandbox-macos--refuse "%S is not a session id for a directory name" sid))
    (let ((dir (with-file-modes #o700 (make-temp-file (format "drgnx-sb-%s-" name) t))))
      (set-file-modes dir #o700 'nofollow)
      (directory-file-name (file-truename dir)))))

(provide 'drgnx-sandbox-macos)
;;; drgnx-sandbox-macos.el ends here
