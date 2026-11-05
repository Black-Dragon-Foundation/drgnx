;;; fleet-image-test.el --- batch tests: the fake fleet builds its runner image once per content -*- lexical-binding: t -*-
;; test-class: det
;; fleet.sh runs with a fake `podman' and `ssh-keygen' on PATH (no runners, no containers): the state files in the temp
;; directory say whether the image is in the store.  Nothing touches a real runtime.
(require 'ert)
(require 'seq)

(defconst fleet-image-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun fleet-image-test--run (image-exists)
  "Run `fleet.sh up --runners 0' with fake tools; IMAGE-EXISTS: the store has the image.  Return the podman calls."
  (let* ((dir (make-temp-file "fleet-image" t))
         (bin (expand-file-name "bin" dir))
         (log (expand-file-name "calls.log" dir))
         (script (lambda (name body)
                   (let ((f (expand-file-name name bin)))
                     (write-region (concat "#!/bin/sh\n" body "\n") nil f nil 'silent)
                     (set-file-modes f #o755)))))
    (unwind-protect
        (progn
          (make-directory bin)
          (funcall script "podman" (format "echo \"$*\" >> %s\ncase \"$1 $2\" in \"image exists\") %s ;; esac"
                                           log (if image-exists "exit 0" "exit 1")))
          ;; key files: `-f FILE' makes FILE and FILE.pub; `-s CA … KEY.pub' makes KEY-cert.pub
          (funcall script "ssh-keygen"
                   (concat "f= s=\nwhile [ $# -gt 0 ]; do case \"$1\" in -f) f=$2; shift;; -s) s=1;; esac; last=$1; shift; done\n"
                           "if [ -n \"$f\" ]; then : > \"$f\"; : > \"$f.pub\"; fi\n"
                           "if [ -n \"$s\" ]; then : > \"${last%.pub}-cert.pub\"; fi"))
          (let ((process-environment
                 (append (list (concat "PATH=" bin ":/usr/bin:/bin") (concat "DRGNX_FLEET_DIR=" dir "/state")
                               "DRGNX_FLEET_RUN=t" "DRGNX_FLEET_PREFIX=fleet-image-test")
                         process-environment)))
            (should (eql 0 (with-temp-buffer
                             (call-process "bash" nil t nil (expand-file-name "test/runners/fleet.sh" fleet-image-test--root)
                                           "up" "--runners" "0")))))
          (split-string (with-temp-buffer (insert-file-contents log) (buffer-string)) "\n" t))
      (delete-directory dir t))))

(ert-deftest drgnx-fleet/the-runner-image-is-tagged-by-its-context-and-built-once ()
  (let ((calls (fleet-image-test--run nil))
        (tag (with-temp-buffer
               (call-process "bash" nil t nil (expand-file-name "test/container/image-tag.sh" fleet-image-test--root)
                             (expand-file-name "test/runners/fake-runner/Containerfile" fleet-image-test--root))
               (string-trim (buffer-string)))))
    ;; the image is not in the store: built, under a tag that hashes the Containerfile and what it copies
    (should (string-match-p "\\`[0-9a-f]\\{16\\}\\'" tag))
    (should (seq-find (lambda (c) (and (string-prefix-p "build " c)
                                       (string-search (concat " -t localhost/drgnx-fake-runner:" tag " ") c)))
                      calls))
    ;; it is: no build
    (should-not (seq-find (lambda (c) (string-prefix-p "build " c)) (fleet-image-test--run t)))))

;;; fleet-image-test.el ends here
