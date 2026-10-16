;;; drgnx-env-test.el --- batch tests: container environment detection -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-env)

(defun drgnx-env-test--probe (&rest facts)
  "A probe answering from FACTS: (file PATH), (env NAME VALUE), (read PATH TEXT), (exec NAME)."
  (lambda (kind arg)
    (let ((fact (seq-find (lambda (f) (and (eq (car f) kind) (equal (cadr f) arg))) facts)))
      (pcase kind
        ((or 'file 'exec) (and fact t))
        ((or 'env 'read) (nth 2 fact))))))

(ert-deftest drgnx-env/host-has-no-container ()
  (should-not (drgnx-env-container (drgnx-env-test--probe))))

(ert-deftest drgnx-env/markers ()
  (should (equal (drgnx-env-container (drgnx-env-test--probe '(file "/run/.containerenv"))) "podman"))
  (should (equal (drgnx-env-container (drgnx-env-test--probe '(file "/.dockerenv"))) "docker"))
  (should (equal (drgnx-env-container (drgnx-env-test--probe '(env "KUBERNETES_SERVICE_HOST" "10.0.0.1")
                                                             '(file "/.dockerenv")))
                 "kubernetes"))
  (should (equal (drgnx-env-container (drgnx-env-test--probe '(env "container" "lxc"))) "lxc")))

(ert-deftest drgnx-env/cgroup-fallback ()
  (dolist (case '(("0::/kubepods/besteffort/pod1/abc" "kubernetes")
                  ("0::/system.slice/docker-abc.scope" "docker")
                  ("0::/machine.slice/libpod-abc.scope" "podman")
                  ("0::/default/nerdctl-abc" "containerd")
                  ("0::/user.slice/user-1000.slice" nil)))
    (should (equal (drgnx-env-container (drgnx-env-test--probe (list 'read "/proc/1/cgroup" (car case))))
                   (cadr case)))))

(ert-deftest drgnx-env/runtime-order-and-override ()
  (should (equal (drgnx-env-container-runtime (drgnx-env-test--probe '(exec "docker") '(exec "podman"))) "podman"))
  (should (equal (drgnx-env-container-runtime (drgnx-env-test--probe '(exec "docker") '(exec "nerdctl"))) "docker"))
  (should (equal (drgnx-env-container-runtime (drgnx-env-test--probe '(exec "nerdctl"))) "nerdctl"))
  (should-not (drgnx-env-container-runtime (drgnx-env-test--probe)))
  (should (equal (drgnx-env-container-runtime (drgnx-env-test--probe '(exec "podman") '(env "DRGNX_CONTAINER" "docker")))
                 "docker")))
