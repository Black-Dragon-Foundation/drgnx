;;; perf-workers-process-test.el --- batch tests: the replay server as a child process (lsp-burst's write times, the corpora) -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The child is `test/fixtures/lsp-replay.el', which says where it is: it sends each answer's last-write time next
;; (`LSP_REPLAY_STAMP', a `$/replaySent' notification), and its output is counted frame by frame.  The tests wait
;; (`drgnx-test-wait') for those announcements, never for a deadline of their own or a timed read.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-perf)
(require 'drgnx-perf-run)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)

(defun perf-workers-process-test--session ()
  (load (expand-file-name "test/fixtures/workers/perf-session.el" drgnx-dir) nil t))

(ert-deftest drgnx-perf-workers/lsp-burst-measures-from-the-servers-write ()
  "lsp-burst puts no advice on jsonrpc's reader (it would keep Nidhogg's framing off, so the A/B's two sides would run
the same path): each handler is measured from the time the replay server wrote its answer's last byte, which the
server sends after the answer, and the A/B judges the slowest one."
  (skip-unless (eq system-type 'gnu/linux))   ; the stub reads its stdin through /proc
  (perf-workers-process-test--session)
  (let ((conn (drgnx-perf-w--lsp-start "rust" '("LSP_REPLAY_STAMP=1"))))
    (unwind-protect
        (progn
          (setq drgnx-perf-w--lsps (list conn) drgnx-perf-w--lsp-handled nil)
          (clrhash drgnx-perf-w--lsp-sent)
          (drgnx-perf-w--lsp-request conn :textDocument/documentSymbol '(:textDocument (:uri "file:///perf.c")))
          ;; the answer, then the server's announcement of when it wrote it
          (drgnx-test-wait (lambda () (and drgnx-perf-w--lsp-handled (drgnx-perf-w--lsp-stamped-p)))
                           :secs 30 :what "the replay server's answer and its write time")
          (should-not (advice--p (advice--symbol-function 'jsonrpc--process-filter)))
          (should-not (advice--p (advice--symbol-function 'jsonrpc--json-read)))
          (should (= (length drgnx-perf-w--lsp-handled) 1))
          (should (drgnx-perf-w--lsp-stamped-p))
          (should-not drgnx-perf-w--lsp-notes)                  ; the write times are not the server's messages
          (let ((lsp (plist-get (drgnx-perf-w-lsp-burst-measure) :lsp)))
            (should (= (plist-get lsp :answers) 1))
            (should (<= 0 (plist-get (plist-get lsp :handler_ms) :max) 30000))))
      (drgnx-perf-w-lsp-teardown)))
  (let* ((run (lambda (ms) (list :lsp (list :handler_ms (list :max ms)))))
         (vs (drgnx-perf-ab-metric-verdicts (cl-loop for i below 10 collect (list :a (funcall run (+ 5.0 (* 0.1 (% i 3))))
                                                                                  :b (funcall run (+ 40.0 (* 0.1 (% i 3)))))))))
    (should (eq (plist-get (cdr (assoc '(:lsp :handler_ms :max) vs)) :verdict) 'regressed))))

(ert-deftest drgnx-perf-workers/lsp-burst-records-a-timed-out-request-as-handled ()
  "A server that answers after the request's timeout (here: never) leaves no workload hanging: jsonrpc drops a late
answer silently, so each request carries the workload's own deadline and a timeout is a handled failure that the
row reports (`:timeouts', `:timeout_ids'), so `lsp-burst-done' holds."
  (skip-unless (eq system-type 'gnu/linux))
  (perf-workers-process-test--session)
  (let* ((drgnx-perf-w--lsp-timeout 0.2)
         (conn (make-instance 'jsonrpc-process-connection :name "perf-lsp-mute" :events-buffer-config '(:size 0)
                              :notification-dispatcher #'ignore :request-dispatcher #'ignore
                              :process (lambda () (make-process :name "perf-lsp-mute" :noquery t :connection-type 'pipe
                                                                :command '("sleep" "3600"))))))
    (unwind-protect
        (progn
          (setq drgnx-perf-w--lsps (list conn) drgnx-perf-w--lsp-handled nil)
          (clrhash drgnx-perf-w--lsp-sent)
          (drgnx-perf-w--lsp-request conn :textDocument/documentSymbol nil)
          (drgnx-test-wait (lambda () drgnx-perf-w--lsp-handled) :secs 5 :what "the request's timeout")
          (let ((lsp (plist-get (drgnx-perf-w-lsp-burst-measure) :lsp)))
            (should (= (plist-get lsp :timeouts) 1))
            (should (= (length (plist-get lsp :timeout_ids)) 1))))
      (drgnx-perf-w-lsp-teardown))))

(defun perf-workers-process-test--frames (bytes)
  "The payload sizes of the framed messages in the unibyte string BYTES: a reply counts its result text only."
  (let ((pos 0) sizes)
    (while (string-match "Content-Length: \\([0-9]+\\)\r\n\r\n" bytes pos)
      (let* ((len (string-to-number (match-string 1 bytes))) (start (match-end 0)) (end (+ start len)))
        (when (> end (length bytes)) (setq pos (length bytes)) (setq len nil))
        (when len
          (let ((body (substring bytes start end)))
            (push (if (string-match "\\`{\"jsonrpc\":\"2.0\",\"id\":[0-9]+,\"result\":" body)
                      (- len (match-end 0) 1)
                    len)
                  sizes))
          (setq pos end))))
    (nreverse sizes)))

(ert-deftest drgnx-perf-workers/capture-is-replayable ()
  "Each recorded corpus replays through the stub: the messages and bytes it sends equal the capture's manifest."
  (skip-unless (eq system-type 'gnu/linux))   ; the stub reads its stdin through /proc
  (let* ((dir (expand-file-name "test/fixtures/workers" drgnx-dir))
         (manifest (with-temp-buffer (insert-file-contents (expand-file-name "manifest.eld" dir)) (read (current-buffer))))
         (stub (expand-file-name "test/fixtures/lsp-replay.el" drgnx-dir))
         (emacs (expand-file-name invocation-name invocation-directory)))
    (should (= (length manifest) 3))
    (let ((process-environment (cons "LSP_REPLAY_LIBRARY=1" process-environment)))
      (load stub nil t))
    (dolist (entry manifest)
      (let* ((file (expand-file-name (format "corpus-%s.eld.gz" (car entry)) dir))
             (corpus (lsp-replay-corpus-read file))
             (want (list :messages (plist-get (cdr entry) :messages) :bytes (plist-get (cdr entry) :bytes))))
        (should (equal (lsp-replay-corpus-totals corpus) want))   ; the manifest describes the corpus
        ;; and the stub, as a process, sends exactly that
        (let* ((out "") (id 0)
               (process-environment (append (list (concat "LSP_REPLAY_CORPUS=" file)) process-environment))
               (proc (make-process :name "perf-workers-test-stub" :noquery t :connection-type 'pipe :coding 'binary
                                   :command (list emacs "--batch" "-Q" "-l" stub)
                                   :filter (lambda (_p s) (setq out (concat out s))))))
          (unwind-protect
              (cl-flet ((send (json) (process-send-string proc (format "Content-Length: %d\r\n\r\n%s" (string-bytes json) json))))
                (send "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{}}")
                (send "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}")
                (dolist (r (plist-get corpus :replies))
                  (send (format "{\"jsonrpc\":\"2.0\",\"id\":%d,\"method\":%S,\"params\":{}}" (cl-incf id) (car r))))
                ;; the stub's frames are its announcements: the last of the manifest's count is the last it sends
                (drgnx-test-wait (lambda () (>= (length (perf-workers-process-test--frames out)) (plist-get want :messages)))
                                 :secs 60 :what "the stub's frames"))
            (delete-process proc))
          (let ((sizes (perf-workers-process-test--frames out)))
            (should (= (length sizes) (plist-get want :messages)))
            (should (= (apply #'+ sizes) (plist-get want :bytes)))))))))

;;; perf-workers-process-test.el ends here
