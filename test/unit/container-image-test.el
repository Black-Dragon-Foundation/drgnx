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
                                        ;; `image inspect NAME': `local' = every image is there, `local-base' = only the bases
                                        "  image) [ -e %s/local ] || { [ -e %s/local-base ] && case \"$3\" in drgnx-base-*) true ;; *) false ;; esac; } ;;\n"
                                        ;; `pull -q REF': `pull-ok' = every image, `pull-base-ok' = only the bases
                                        "  pull) case \"$3\" in *drgnx-base-*) [ -e %s/pull-base-ok ] || [ -e %s/pull-ok ] ;; *) [ -e %s/pull-ok ] ;; esac ;;\n"
                                        "  *) exit 0 ;;\nesac\n")
                                log dir dir dir dir dir)
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

(defun container-image-test--builds (calls)
  "The build calls as (TAG . BASE-ARG-or-nil), in order."
  (mapcar (lambda (c)
            (cons (and (string-match " -t \\([^ ]+\\) " c) (match-string 1 c))
                  (and (string-match "--build-arg BASE=\\([^ ]+\\)" c) (match-string 1 c))))
          (container-image-test--calls calls "build")))

(ert-deftest drgnx-image/a-test-image-is-built-on-its-base-and-the-base-first ()
  (let* ((r (container-image-test--run nil)) (builds (container-image-test--builds (nth 2 r))))
    (should (eql 0 (car r)))
    (should (= 2 (length builds)))
    (should (string-match-p "\\`drgnx-base-test:[0-9a-f]\\{16\\}\\'" (car (nth 0 builds))))
    (should-not (cdr (nth 0 builds)))
    (should (string-match-p "\\`drgnx-test:[0-9a-f]\\{16\\}\\'" (car (nth 1 builds))))
    (should (equal (car (nth 0 builds)) (cdr (nth 1 builds))))
    (should (string-match-p "image: drgnx-base-test:[0-9a-f]\\{16\\} (built)" (nth 1 r)))))

(ert-deftest drgnx-image/a-local-base-is-reused-and-only-the-top-is-built ()
  (let* ((r (container-image-test--run '("local-base"))) (builds (container-image-test--builds (nth 2 r))))
    (should (eql 0 (car r)))
    (should (= 1 (length builds)))
    (should (string-match-p "\\`drgnx-test:" (car (car builds))))
    (should (string-match-p "\\`drgnx-base-test:[0-9a-f]\\{16\\}\\'" (cdr (car builds))))
    (should (string-match-p "image: drgnx-base-test:[0-9a-f]\\{16\\} (local)" (nth 1 r)))))

(ert-deftest drgnx-image/a-pulled-base-is-reused-and-only-the-top-is-built ()
  (let* ((r (container-image-test--run '("pull-base-ok"))) (builds (container-image-test--builds (nth 2 r))))
    (should (eql 0 (car r)))
    (should (= 1 (length builds)))
    (should (string-match-p "image: drgnx-base-test:[0-9a-f]\\{16\\} (pulled)" (nth 1 r)))
    (should (string-match-p "image: drgnx-test:[0-9a-f]\\{16\\} (built)" (nth 1 r)))))

(ert-deftest drgnx-image/the-top-tag-includes-the-bases-tag ()
  ;; a base change re-tags the images on it; the base's own tag does not depend on them
  (let* ((tmp (make-temp-file "container-image-tag" t)) (script (expand-file-name "test/container/image-tag.sh" container-image-test--root))
         (tag (lambda (f) (with-temp-buffer (list (call-process "bash" nil t nil script (expand-file-name f tmp))
                                                  (string-trim (buffer-string))))))
         (put (lambda (rel text) (with-temp-file (expand-file-name rel tmp) (insert text)))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "base" tmp))
          (funcall put "base/Containerfile" "FROM x\nRUN a\n")
          (funcall put "Containerfile" "# base: drgnx-base-x base/Containerfile\nARG BASE\nFROM ${BASE}\n")
          (let ((top (funcall tag "Containerfile")) (base (funcall tag "base/Containerfile")))
            (should (eql 0 (car top)))
            (funcall put "base/Containerfile" "FROM x\nRUN b\n")
            (should-not (equal top (funcall tag "Containerfile")))
            (should-not (equal base (funcall tag "base/Containerfile"))))
          ;; a base that is not there is an error, never a tag
          (delete-file (expand-file-name "base/Containerfile" tmp))
          (should (eql 1 (car (funcall tag "Containerfile")))))
      (delete-directory tmp t))))

(ert-deftest drgnx-image/a-prebuilt-override-is-used-as-it-is ()
  (let* ((r (container-image-test--run nil "DRGNX_TEST_IMAGE=an-image")) (calls (nth 2 r)))
    (should (eql 0 (car r)))
    (should-not (container-image-test--calls calls "build"))
    (should-not (container-image-test--calls calls "pull"))
    (should (string-match "image: an-image (prebuilt)" (nth 1 r)))))

;;; container-image-test.el ends here
