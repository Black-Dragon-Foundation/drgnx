;;; mermaid-live-test.el --- live test: the Markdown module draws a Mermaid diagram with a real mmdc -*- lexical-binding: t -*-
;; The unit tests check the job's command line and the cache; this runs mmdc (mermaid-cli with headless Chromium) once.
;; It skips without mmdc: test/container/Containerfile.tools has it (docs/develop/harness.md, "Real-tool tests").
(require 'ert)
(require 'cl-lib)

(defconst mermaid-live-test--repo
  (file-name-as-directory (expand-file-name "../.." (file-name-directory (or load-file-name buffer-file-name)))))

(defun mermaid-live-test--wait-job (id secs)
  "Wait up to SECS for job ID to end; return its job."
  (let ((deadline (+ (float-time) secs)) job)
    (while (and (< (float-time) deadline)
                (eq (plist-get (setq job (drgnx-jobs-get id)) :status) 'running))
      (accept-process-output nil 0.2))
    job))

(defun mermaid-live-test--bytes (file)
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(ert-deftest drgnx-mermaid-live/the-module-job-draws-a-two-node-diagram ()
  (skip-unless (executable-find "mmdc"))
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-mermaid" t)))
         (process-environment (append (list (concat "XDG_CACHE_HOME=" tmp "cache")
                                            (concat "XDG_STATE_HOME=" tmp "state") "DRGNX_JOBS_LAUNCHER=detached")
                                      process-environment))
         (code "graph TD; A-->B\n"))
    (add-to-list 'load-path (expand-file-name "core" mermaid-live-test--repo))
    (load (expand-file-name "modules/lang/drgnx-markdown" mermaid-live-test--repo) nil t)
    (clrhash drgnx-markdown--drawing) (clrhash drgnx-markdown--failed)
    (unwind-protect
        (let* ((hash (secure-hash 'sha1 code))
               (png (expand-file-name (concat hash ".png") (drgnx-markdown--diagram-dir)))
               (svg (expand-file-name "two-nodes.svg" tmp))
               ;; the module's own job: `drgnx-markdown--draw' starts it; its picture is the cached PNG
               (_ (cl-letf (((symbol-function 'drgnx-markdown--watch) #'ignore))
                    (drgnx-markdown--draw code hash)))
               (draw-id (car (last (mapcar (lambda (j) (plist-get j :id)) (drgnx-jobs-list)))))
               (job (mermaid-live-test--wait-job draw-id 120)))
          (should (eql (plist-get job :exit) 0))
          (should (file-exists-p png))
          (should (> (file-attribute-size (file-attributes png)) 0))
          (should (string-prefix-p "\x89PNG" (mermaid-live-test--bytes png)))
          ;; the same command shape (flags, theme) into an SVG: two nodes, A and B
          (let ((mmd (expand-file-name (concat hash ".mmd") (drgnx-markdown--diagram-dir))))
            (let ((job2 (mermaid-live-test--wait-job
                         (drgnx-jobs-start "mermaid" (list "mmdc" "-i" mmd "-o" svg "-b" "transparent" "-t" (drgnx-markdown--theme)))
                         120)))
              (should (eql (plist-get job2 :exit) 0))
              (should (> (file-attribute-size (file-attributes svg)) 0))
              (let ((text (with-temp-buffer (insert-file-contents svg) (buffer-string))))
                (should (string-search "<svg" text))
                (should (string-search "A" text))
                (should (string-search "B" text))))))
      (ignore-errors (dolist (j (drgnx-jobs-list)) (when (eq (plist-get j :status) 'running) (drgnx-jobs-stop (plist-get j :id)))))
      (delete-directory tmp t))))
