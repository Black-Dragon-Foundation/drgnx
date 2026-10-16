;;; drgnx-env.el --- Where is drgnx running: host or container, and which container runtime -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Inside a container (podman, docker, Kubernetes, containerd/nerdctl — e.g. Rancher
;; Desktop) there is usually no systemd user session, so harness sessions run as a
;; detached process group instead of a transient unit.  On the host, container test runs
;; use podman, else docker, else nerdctl; DRGNX_CONTAINER overrides.  Every check goes
;; through a PROBE function so tests can describe any environment.

;;; Code:
(require 'subr-x)

(defun drgnx-env--probe (kind arg)
  "Ask the real system: KIND is `file' (exists), `env' (value), `read' (contents) or `exec' (on PATH)."
  (pcase kind
    ('file (file-exists-p arg))
    ('env (getenv arg))
    ('read (and (file-readable-p arg)
                (with-temp-buffer (insert-file-contents arg) (buffer-string))))
    ('exec (executable-find arg))))

(defun drgnx-env-container (&optional probe)
  "The kind of container drgnx runs in (\"kubernetes\", \"podman\", \"docker\", …), or nil on a host."
  (let ((p (or probe #'drgnx-env--probe)))
    (cond
     ((funcall p 'env "KUBERNETES_SERVICE_HOST") "kubernetes")
     ((funcall p 'file "/run/.containerenv") "podman")
     ((funcall p 'file "/.dockerenv") "docker")
     ((let ((c (funcall p 'env "container"))) (and c (not (string-empty-p c)) c)))
     ((let ((cgroup (funcall p 'read "/proc/1/cgroup")))
        (and cgroup
             (cond ((string-match-p "kubepods" cgroup) "kubernetes")
                   ((string-match-p "libpod" cgroup) "podman")
                   ((string-match-p "docker" cgroup) "docker")
                   ((string-match-p "containerd\\|nerdctl" cgroup) "containerd"))))))))

(defun drgnx-env-container-runtime (&optional probe)
  "The container runtime for test runs: $DRGNX_CONTAINER, else podman, docker or nerdctl; nil if none."
  (let* ((p (or probe #'drgnx-env--probe))
         (override (funcall p 'env "DRGNX_CONTAINER")))
    (if (and override (not (string-empty-p override)))
        override
      (seq-find (lambda (r) (funcall p 'exec r)) '("podman" "docker" "nerdctl")))))

(defun drgnx-env-systemd-user-p ()
  "Non-nil when a systemd user manager answers (needed for transient units)."
  (and (executable-find "systemctl")
       (eq 0 (call-process "systemctl" nil nil nil "--user" "show-environment"))))

(provide 'drgnx-env)
;;; drgnx-env.el ends here
