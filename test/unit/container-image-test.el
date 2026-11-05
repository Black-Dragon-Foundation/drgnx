;;; container-image-test.el --- batch tests: which image `bin/drgnx test --container' runs -*- lexical-binding: t -*-
;; test-class: det
;; A fake `podman' records every call; the state files in the temp directory say whether the image is in the local
;; store (`local') and whether a pull from GHCR works (`pull-ok').  Nothing touches a real runtime or the network.
(require 'ert)
(require 'seq)

(defconst container-image-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun container-image-test--slurp (file)
  (if (file-exists-p file)
      (with-temp-buffer (insert-file-contents file) (buffer-string))
    ""))

(defun container-image-test--run (state &rest env)
  "Run `bin/drgnx test --container' with a fake podman in a temp dir holding the STATE files (names);
ENV is more \"K=V\" strings.  Return (EXIT OUTPUT CALLS): the calls are the fake's log lines."
  (let* ((dir (make-temp-file "container-image" t))
         (log (expand-file-name "calls.log" dir))
         (rt (expand-file-name "podman" dir)))
    (unwind-protect
        (progn
          (dolist (s state) (write-region "" nil (expand-file-name s dir) nil 'silent))
          (write-region (format (concat "#!/bin/sh\necho \"$*\" >> %s\n"
                                        "case \"$1\" in\n"
                                        "  image) [ -e %s/local ] ;;\n"
                                        "  pull) [ -e %s/pull-ok ] ;;\n"
                                        "  *) exit 0 ;;\nesac\n")
                                log dir dir)
                        nil rt nil 'silent)
          (set-file-modes rt #o755)
          (let* ((process-environment
                  (append (list (concat "HOME=" dir) (concat "DRGNX_CONFIG_DIR=" dir "/config")
                                (concat "DRGNX_CONTAINER=" rt))
                          env
                          '("DRGNX_EMACS" "DRGNX_TEST_IMAGE" "DRGNX_TEST_GUI_IMAGE" "DRGNX_TEST_TTY_IMAGE"
                            "DRGNX_TEST_WM_IMAGE" "DRGNX_UI_COMPOSITOR" "DRGNX_TEST_SELECTOR" "DRGNX_CONTAINER_NIDHOGG")
                          process-environment))
                 (default-directory (file-name-as-directory dir))
                 (exit 0)
                 (out (with-temp-buffer
                        (setq exit (call-process (expand-file-name "bin/drgnx" container-image-test--root)
                                                 nil t nil "test" "--container"))
                        (buffer-string))))
            (list exit out (split-string (container-image-test--slurp log) "\n" t))))
      (delete-directory dir t))))

(defun container-image-test--calls (calls verb)
  (seq-filter (lambda (c) (string-prefix-p (concat verb " ") c)) calls))

(ert-deftest drgnx-image/a-local-image-is-used-without-a-build-or-a-pull ()
  (let ((r (container-image-test--run '("local"))))
    (should (eql 0 (car r)))
    (should-not (container-image-test--calls (nth 2 r) "build"))
    (should-not (container-image-test--calls (nth 2 r) "pull"))
    (should (string-match "image: drgnx-test:[0-9a-f]\\{16\\} (local)" (nth 1 r)))
    (should (container-image-test--calls (nth 2 r) "run"))))

(ert-deftest drgnx-image/a-missing-image-is-pulled-from-ghcr-and-tagged-locally ()
  (let* ((r (container-image-test--run '("pull-ok"))) (calls (nth 2 r)))
    (should (eql 0 (car r)))
    (should-not (container-image-test--calls calls "build"))
    (should (seq-find (lambda (c) (string-match-p "\\`pull .*ghcr\\.io/black-dragon-foundation/drgnx-test:[0-9a-f]\\{16\\}\\'" c))
                      calls))
    (should (seq-find (lambda (c) (string-match-p "\\`tag ghcr\\.io/black-dragon-foundation/drgnx-test:\\([0-9a-f]\\{16\\}\\) drgnx-test:\\1\\'" c))
                      calls))
    (should (string-match "image: drgnx-test:[0-9a-f]\\{16\\} (pulled)" (nth 1 r)))))

(ert-deftest drgnx-image/an-image-neither-local-nor-on-ghcr-is-built ()
  (let* ((r (container-image-test--run nil)) (calls (nth 2 r)))
    (should (eql 0 (car r)))
    (should (container-image-test--calls calls "pull"))
    (should (container-image-test--calls calls "build"))
    (should (string-match "image: drgnx-test:[0-9a-f]\\{16\\} (built)" (nth 1 r)))))

(ert-deftest drgnx-image/the-pull-can-be-switched-off-for-an-offline-machine ()
  (let* ((r (container-image-test--run '("pull-ok") "DRGNX_TEST_IMAGE_PULL=0")) (calls (nth 2 r)))
    (should (eql 0 (car r)))
    (should-not (container-image-test--calls calls "pull"))
    (should (container-image-test--calls calls "build"))
    (should (string-match "(built)" (nth 1 r)))))

(ert-deftest drgnx-image/a-prebuilt-override-is-used-as-it-is ()
  (let* ((r (container-image-test--run nil "DRGNX_TEST_IMAGE=an-image")) (calls (nth 2 r)))
    (should (eql 0 (car r)))
    (should-not (container-image-test--calls calls "build"))
    (should-not (container-image-test--calls calls "pull"))
    (should (string-match "image: an-image (prebuilt)" (nth 1 r)))))

;;; container-image-test.el ends here
