;;; ci-nidhogg-test.el --- drgnx's CI images and macOS job run Nidhogg's release tarballs -*- lexical-binding: t -*-
(require 'ert)

(defconst drgnx-ci-test--nidhogg-root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-ci-test--path (rel)
  (expand-file-name rel drgnx-ci-test--nidhogg-root))

(defun drgnx-ci-test--slurp (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun drgnx-ci-test--var (rel name)
  "The value of the line NAME=value in the checkout's file REL."
  (let ((s (drgnx-ci-test--slurp (drgnx-ci-test--path rel))))
    (when (string-match (concat "^" (regexp-quote name) "=\\([^ \n]+\\)") s)
      (match-string 1 s))))

(ert-deftest drgnx-ci/test-images-run-nidhogg ()
  (let ((files (directory-files (drgnx-ci-test--path "test/container") t "\\`Containerfile")))
    (should (= 5 (length files)))
    (dolist (f files)
      (let ((s (drgnx-ci-test--slurp f)))
        (should-not (string-match-p "dnf[^\n]*install[^\n]*emacs-pgtk" s))
        (should (string-search "nidhogg.sh" s))
        (should (string-search "ENV DRGNX_EMACS=/opt/nidhogg/" s))))))

(ert-deftest drgnx-ci/nidhogg-pin-matches-install-sh ()
  (should (drgnx-ci-test--var "test/container/nidhogg.sh" "NIDHOGG_VERSION"))
  (should (equal (drgnx-ci-test--var "test/container/nidhogg.sh" "NIDHOGG_VERSION")
                 (drgnx-ci-test--var "install.sh" "NIDHOGG_VERSION"))))

(ert-deftest drgnx-ci/containerfiles-name-the-pinned-version ()
  ;; the image tag is the Containerfile's hash: a pin bump must change every Containerfile
  (let ((v (drgnx-ci-test--var "test/container/nidhogg.sh" "NIDHOGG_VERSION")))
    (dolist (f (directory-files (drgnx-ci-test--path "test/container") t "\\`Containerfile"))
      (should (string-search (concat "/opt/nidhogg/" v "/bin/nidhogg") (drgnx-ci-test--slurp f))))))

(ert-deftest drgnx-ci/nidhogg-tarballs-are-pinned ()
  (let ((s (drgnx-ci-test--slurp (drgnx-ci-test--path "test/container/nidhogg.sh"))))
    (dolist (d '("fedora-44" "fedora-45" "ubuntu-26.04" "macos"))
      (should (string-match-p (concat d "[^\n]*[0-9a-f]\\{64\\}") s)))))

(ert-deftest drgnx-ci/macos-unit-job-uses-nidhogg ()
  (let ((s (drgnx-ci-test--slurp (drgnx-ci-test--path ".github/workflows/macos.yml"))))
    (should-not (string-match-p "brew install emacs" s))
    (should (string-search "test/container/nidhogg.sh macos" s))
    (should (string-search "timeout-minutes: 180" s))))
