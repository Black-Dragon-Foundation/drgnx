;;; prelude.el --- Init for drgnx harness sessions: isolation, determinism, server -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Loaded first by the generated early-init.el of every harness session (see
;; docs/harness.md).  The session's `user-emacs-directory' is RUN/init (via
;; --init-directory), so everything it writes stays in the run directory; an external
;; configuration (DRGNX_UI_CONFIG) is only read.  No network, no package installs, no
;; secrets, no blinking cursor, treemacs drag-to-move off, its own server socket.

;;; Code:
(require 'json)
(require 'server)

(defvar drgnx-ui-run (file-name-as-directory (getenv "DRGNX_UI_RUN")))
(defvar drgnx-ui-harness (file-name-as-directory (getenv "DRGNX_UI_HARNESS")))
(defvar drgnx-ui-config
  (let ((c (getenv "DRGNX_UI_CONFIG")))
    (and c (not (string-empty-p c)) (file-name-as-directory c))))

;;;; State: written only inside the run directory
(when (fboundp 'startup-redirect-eln-cache)
  ;; One cache for every session of this state root (still never the user's): native code and
  ;; advice trampolines are compiled once, not by every session (that cost ~150 ms per start).
  (startup-redirect-eln-cache (expand-file-name "eln-cache" (file-name-directory (directory-file-name drgnx-ui-run)))))
(when (and drgnx-ui-config (boundp 'native-comp-eln-load-path))
  ;; Reuse the config's compiled code; the last entry must stay the system directory.
  (setq native-comp-eln-load-path
        (append (butlast native-comp-eln-load-path)
                (list (expand-file-name "eln-cache" drgnx-ui-config))
                (last native-comp-eln-load-path))))
(setq package-user-dir (expand-file-name "elpa" (or drgnx-ui-config drgnx-ui-run))
      package-quickstart nil
      package-enable-at-startup (and drgnx-ui-config t))

;;;; No network, no installs
(defun drgnx-ui--refuse (&rest _)
  "Signal: harness sessions never use the network or install anything."
  (error "drgnx harness: network access and package installs are disabled in test sessions"))
(dolist (fn '(url-retrieve url-retrieve-synchronously package-refresh-contents package-install
              package-vc-install package-upgrade package-upgrade-all treesit-install-language-grammar))
  (advice-add fn :override #'drgnx-ui--refuse))

;;;; No secrets (the launcher also passes an allowlisted environment)
(setq auth-sources nil)
(with-eval-after-load 'auth-source (setq auth-sources nil))

;;;; Look and safety
(setq inhibit-startup-screen t
      ring-bell-function #'ignore
      use-dialog-box nil
      treemacs-move-files-by-mouse-dragging nil)
(with-eval-after-load 'treemacs (setq treemacs-move-files-by-mouse-dragging nil))

;;;; Server: set before the config runs, so any `server-start' in it uses our socket
(setq server-socket-dir (getenv "DRGNX_UI_SOCKET_DIR")
      server-name (getenv "DRGNX_UI_NAME")
      server-use-tcp nil)

(defun drgnx-ui-load-config (file)
  "Load FILE (early-init.el or init.el) of the session's configuration.
Without an external configuration, init.el is the harness's minimal one."
  (cond (drgnx-ui-config (load (expand-file-name file drgnx-ui-config) t t t))
        ((equal file "init.el") (load (expand-file-name "init/minimal.el" drgnx-ui-harness) nil t))))

;;;; After init: harness agent, guard, server, ready file, test mode
(defvar drgnx-ui--ready-timer nil)
(defvar drgnx-guard--timer-fn)          ; drgnx's no-prompt guard, when loaded
(defvar drgnx-ui--server-error nil "Why the session's server did not start, or nil.")

(defun drgnx-ui--start-server ()
  "Start the session's server unless one runs; record why it failed, never signal."
  (setq drgnx-ui--server-error
        (condition-case err
            (progn (unless (and (boundp 'server-process) (process-live-p server-process))
                     (server-start))
                   (unless (and (boundp 'server-process) (process-live-p server-process))
                     (error "server-start created no server (socket dir %s)" server-socket-dir))
                   nil)
          (error (error-message-string err)))))

(defun drgnx-ui--quiet-server (orig &rest args)
  "Evaluate harness requests without running the session's change hooks.
Code under test hangs followers and debounces on them (gryphn re-arms its Explorer follow
on `first-change-hook'), and every emacsclient reply is printed through a temp buffer — so
harness polling would re-arm them and hide exactly what it measures.  Binding
`inhibit-modification-hooks' (not the hook variables) keeps hooks a request installs."
  (let ((inhibit-modification-hooks t))
    (apply orig args)))

(defun drgnx-ui-early-server ()
  "Called by the generated init.el before the configuration's: load the harness agent and
start the session's server, so a configuration that prompts or hangs can still be seen
and driven (the initial frame exists by now)."
  (add-to-list 'load-path drgnx-ui-harness)
  (require 'drgnx-uitest)
  (require 'drgnx-jank-guard)
  (drgnx-jank-guard-enable)
  (advice-add 'server-process-filter :around #'drgnx-ui--quiet-server)
  (drgnx-ui--start-server))

(defun drgnx-ui--late ()
  "Finish session setup after the configuration has run."
  (blink-cursor-mode -1)
  (setq treemacs-move-files-by-mouse-dragging nil)
  (drgnx-ui--start-server)              ; again, in case the configuration stopped it
  (setq drgnx-ui--ready-timer (run-with-timer 0 0.05 #'drgnx-ui--when-visible)))

(defun drgnx-ui--when-visible ()
  "Once the root frame is mapped: write ready.json; in test mode, run the suite."
  (when (or (daemonp) (frame-visible-p (drgnx-uitest-root-frame)))   ; a daemon has no frame yet
    (cancel-timer drgnx-ui--ready-timer)
    (let ((tmp (expand-file-name "ready.json.tmp" drgnx-ui-run)))
      (with-temp-file tmp
        (insert (json-serialize
                 (list :pid (emacs-pid)
                       ;; Where the server actually is: a configuration may have moved it.
                       :socket (expand-file-name server-name server-socket-dir)
                       :emacs emacs-version
                       :init_error (if init-file-had-error t :false)
                       :server_error (or drgnx-ui--server-error :false)))))
      (rename-file tmp (expand-file-name "ready.json" drgnx-ui-run) t))
    (when (getenv "DRGNX_UI_TEST")
      (run-with-timer 0.2 nil #'drgnx-ui--run-tests))))

(defun drgnx-ui--run-tests ()
  "Run the GUI suite in DRGNX_UI_TEST and exit 0 (all passed) or 1."
  (load (expand-file-name "run-ert.el" drgnx-ui-harness) nil t)
  ;; Started from a timer, but the tests are not timer code: neither the jank guard nor
  ;; drgnx's no-prompt guard may count them as such.
  (let ((drgnx-jank-guard--timer-fn nil) (drgnx-guard--timer-fn nil))
    (kill-emacs (if (drgnx-run-ert (getenv "DRGNX_UI_TEST") (getenv "DRGNX_UI_RESULTS")) 0 1))))

(add-hook 'window-setup-hook #'drgnx-ui--late 90)

;;; prelude.el ends here
