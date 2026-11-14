;;; peer-fixture.el --- scripted peers for tests: a process whose input the test writes -*- lexical-binding: t -*-
;; A test that needs "a process wrote something" should not ask the OS for the order or chunking of reads.
;; `drgnx-test-peer-make' returns a process whose filter is called once per `drgnx-test-peer-write', after the write
;; has fully arrived; no child process, no sleep, no timer.  It is Nidhogg's `nidhogg-test-peer', shipped with Nidhogg 31.1-nidhogg.5 and later.
(require 'cl-lib)
(require 'nidhogg-test-peer)

(cl-defun drgnx-test-peer-make (&key name filter sentinel (coding 'utf-8))
  "A scripted peer: FILTER is called as (FILTER PEER STRING), once per `drgnx-test-peer-write'."
  (nidhogg-test-peer-make :name name :filter filter :sentinel sentinel :coding coding))

(defun drgnx-test-peer-write (peer string)
  "Deliver STRING to PEER's filter as one call; return after it ran."
  (nidhogg-test-peer-write peer string))

(defun drgnx-test-peer-send (peer string)
  "Write STRING to PEER and return at once.  For a peer whose input Nidhogg's reader frames: the reader delivers
batches to a batch function, and the peer's own filter (which `drgnx-test-peer-write' waits for) never runs.  The
test waits on what the batch function did (`drgnx-test-wait')."
  (process-send-string (nidhogg-test-peer--state-client (process-get peer 'nidhogg-test-peer))
                       (encode-coding-string string 'utf-8))
  nil)

(defun drgnx-test-peer-eof (peer)
  "End PEER's input as a remote end closing does: what was sent arrives first, then PEER sees the end."
  (delete-process (nidhogg-test-peer--state-client (process-get peer 'nidhogg-test-peer))))

(defun drgnx-test-peer-calls (peer)
  "How many times PEER's filter ran."
  (nidhogg-test-peer-calls peer))

(defun drgnx-test-peer-close (peer)
  "Close PEER and its socket."
  (nidhogg-test-peer-close peer))

(provide 'drgnx-peer-fixture)

;;; peer-fixture.el ends here
