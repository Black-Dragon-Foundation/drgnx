;;; hub-client-front-test.el --- batch tests: the Lisp backend's blocking calls to the front -*- lexical-binding: t -*-
;; `drgnx-hub-call-front' waits with JUST-THIS-ONE an integer, which starves every other filter and timer of the
;; waiting Emacs: a fake hub served in this Emacs could never answer.  So the fake hub (test/fixtures/fake-hub.el) runs
;; in a child process (test/fixtures/fake-hub-main.el), and logs each method it reads; the recording filter and timer
;; stay here.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)

(defmacro drgnx-hub-client-front-test--with (env &rest body)
  "BODY with drgnx's dirs under ROOT and a fake hub serving `drgnx-hub-socket' in a child Emacs with ENV (a list of
\"DRGNX_FAKE_HUB_…=…\" strings), LOG the file of the methods it read; this Emacs is the backend behind the front,
its front connection fresh."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-hf" t)))
          (log (concat root "methods.log"))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") (concat "XDG_RUNTIME_DIR=" root "run")
                                             (concat "HOME=" root "home") "DRGNX_NO_HUB_START")
                                       process-environment))
          (drgnx-hub--behind-front t) (drgnx-hub--front-conn nil) (drgnx-hub--front-waiting nil)
          (hub nil))
     (ignore log)
     (dolist (d '("run" "home" "config" "data")) (with-file-modes #o700 (make-directory (concat root d) t)))
     (unwind-protect
         (progn
           (setq hub (let ((process-environment (append (list (concat "DRGNX_FAKE_HUB_SOCKET=" (drgnx-hub-socket))
                                                              (concat "DRGNX_FAKE_HUB_LOG=" log)
                                                              (format "DRGNX_FAKE_HUB_PARENT=%d" (emacs-pid)))
                                                        ,env process-environment)))
                       (make-process :name "fake-hub" :noquery t :buffer nil :connection-type 'pipe
                                     :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                                    "-L" (expand-file-name "core" drgnx-dir)
                                                    "-l" (expand-file-name "test/fixtures/fake-hub-main.el" drgnx-dir)
                                                    "-f" "drgnx-fake-hub-main"))))
           (drgnx-test-wait (lambda () (file-exists-p (drgnx-hub-cap-file))) :secs 30 :what "the fake hub serves")
           ,@body)
       (when (processp drgnx-hub--front-conn) (delete-process drgnx-hub--front-conn))
       (when (process-live-p hub) (delete-process hub))
       (delete-directory root t))))

(defun drgnx-hub-client-front-test--methods (log)
  "The methods the fake hub read, oldest first (LOG: its file; none when it read nothing)."
  (and (file-exists-p log) (split-string (with-temp-buffer (insert-file-contents log) (buffer-string)) "\n" t)))

(defun drgnx-hub-client-front-test--failure (thunk)
  "The data of the `drgnx-hub-front-error' THUNK signals, (:code :message :path); fails the test when it signals none."
  (condition-case err (progn (funcall thunk) (ert-fail "no drgnx-hub-front-error"))
    (drgnx-hub-front-error (cdr err))))

(ert-deftest drgnx-hub-client/front-call-runs-no-other-filter-or-timer ()
  ;; the fake hub answers after 200 ms; meanwhile another connection has a line waiting and a timer is due
  (drgnx-hub-client-front-test--with '("DRGNX_FAKE_HUB_DELAY=0.2")
    (let* ((seen nil) (timer-ran nil)
           (other (concat root "other.sock"))
           (server (make-network-process :name "recorder" :family 'local :server t :service other :noquery t
                                         :filter (lambda (_p s) (push s seen))))
           (client (make-network-process :name "recorder-client" :family 'local :service other :noquery t))
           (timer nil))
      (unwind-protect
          (progn
            (process-send-string client "x\n")
            (setq timer (run-at-time 0 nil (lambda () (setq timer-ran t))))
            (should (eq (drgnx-hub-call-front "coord/held" (list :agent "a1" :held t)) t))
            (should-not timer-ran)
            (should-not seen)
            ;; both run afterwards, at the next wait that runs everything
            (should (drgnx-test-wait (lambda () (and timer-ran seen)) :secs 10 :what "the filter and the timer, afterwards")))
        (cancel-timer timer)
        (delete-process client)
        (delete-process server)))))

(ert-deftest drgnx-hub-client/front-call-reentry-is-refused ()
  (drgnx-hub-client-front-test--with nil
    (let ((drgnx-hub--front-waiting t))           ; a call waits below (a filter that somehow ran)
      (should (equal (plist-get (drgnx-hub-client-front-test--failure (lambda () (drgnx-hub-call-front "coord/prune" nil)))
                                :message)
                     "a front call is already waiting")))
    (should-not drgnx-hub--front-conn)
    (should-not (drgnx-hub-client-front-test--methods log))))

(ert-deftest drgnx-hub-client/front-call-fails-once-at-its-deadline ()
  (drgnx-hub-client-front-test--with '("DRGNX_FAKE_HUB_SILENT=coord/job-set")
    (should (eq (drgnx-hub-call-front "coord/held" (list :agent "a1" :held t)) t))   ; proven: the deadline is the call's
    (let* ((failures 0) (data nil))
      (condition-case err (drgnx-hub-call-front "coord/job-set" (list :id "j1" :status "stopped") 0.5)
        (drgnx-hub-front-error (cl-incf failures) (setq data (cdr err))))
      (should (= failures 1))
      (should (equal data '(:code nil :message "the drgnx hub did not answer coord/job-set in time" :path nil)))
      ;; dropped: a late answer is never taken for the next call's, which connects again
      (should-not drgnx-hub--front-conn)
      (should (equal (cl-count "coord/job-set" (drgnx-hub-client-front-test--methods log) :test #'equal) 1)))))

(ert-deftest drgnx-hub-client/front-call-ends-at-its-deadline ()
  :tags '(:timing)    ; a wall-clock bound: a shared runner's clock judges nothing (docs/develop/ci.md)
  (drgnx-hub-client-front-test--with '("DRGNX_FAKE_HUB_SILENT=coord/job-set")
    (should (eq (drgnx-hub-call-front "coord/held" (list :agent "a1" :held t)) t))   ; proven: the deadline is the call's
    (let ((t0 (float-time)))
      (should-error (drgnx-hub-call-front "coord/job-set" (list :id "j1" :status "stopped") 0.5)
                    :type 'drgnx-hub-front-error)
      (should (< (- (float-time) t0) 0.6)))))

(ert-deftest drgnx-hub-client/a-front-wait-never-runs-past-its-deadline ()
  ;; each wait takes 1/32 s of a 1/8 s deadline (binary fractions: exact): the last one is cut to what is left
  (let* ((now 0.0) (waits nil)
         (conn (make-pipe-process :name "drgnx-hub-front-wait-test" :noquery t)))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-hub--front-now) (lambda () now))
                  ((symbol-function 'accept-process-output)
                   (lambda (_p secs &rest _) (push secs waits) (setq now (+ now (min secs 0.03125))) nil)))
          (should-not (drgnx-hub--front-take conn #'identity 0.125))
          (should (equal (mapcar (lambda (s) (round (* 1000 s))) (nreverse waits)) '(50 50 50 31)))
          (should (= now 0.125)))
      (delete-process conn))))

(ert-deftest drgnx-hub-client/front-call-decodes-an-error-with-its-path ()
  (drgnx-hub-client-front-test--with
      '("DRGNX_FAKE_HUB_ERRORS={\"messages/send\": {\"code\": \"not-allowed\", \"message\": \"only the backend names a message's sender\", \"path\": \"sender\"}}")
    (should (equal (drgnx-hub-client-front-test--failure
                    (lambda () (drgnx-hub-call-front "messages/send" (list :recipient "a1" :text "hi" :sender "a2"))))
                   '(:code "not-allowed" :message "only the backend names a message's sender" :path "sender")))
    ;; the front's own refusal leaves the connection as it is
    (should (process-live-p drgnx-hub--front-conn))))

(ert-deftest drgnx-hub-client/front-call-is-refused-outside-the-backend ()
  (drgnx-hub-client-front-test--with nil
    (let ((drgnx-hub--behind-front nil))
      (should (equal (drgnx-hub-client-front-test--failure (lambda () (drgnx-hub-call-front "coord/prune" nil)))
                     '(:code nil :message "only the Lisp backend calls the front and waits" :path nil))))
    (should-not drgnx-hub--front-conn)
    (should-not (drgnx-hub-client-front-test--methods log))))

(ert-deftest drgnx-hub-client/front-call-proves-and-reuses-one-connection ()
  (drgnx-hub-client-front-test--with nil
    (should (eq (drgnx-hub-call-front "coord/held" (list :agent "a1" :held :false)) t))
    (let ((conn drgnx-hub--front-conn))
      (should (process-live-p conn))
      (should (eq (drgnx-hub-call-front "coord/prune" nil) t))
      (should (eq (drgnx-hub-call-front "coord/job-set" (list :id "j1" :status "running")) t))
      (should (eq drgnx-hub--front-conn conn)))
    ;; one hello, no subscribe, no ping: only answers ever arrive on it
    (should (equal (drgnx-hub-client-front-test--methods log) '("hello" "coord/held" "coord/prune" "coord/job-set")))))

(ert-deftest drgnx-hub-client/front-call-gives-no-keys ()
  (drgnx-hub-client-front-test--with nil
    (dotimes (_ 3) (should (eq (drgnx-hub-call-front "coord/prune" nil) t)))
    (dolist (m '("gateway/keys" "gateway/register" "subscribe"))
      (should (string-search m (plist-get (drgnx-hub-client-front-test--failure
                                           (lambda () (drgnx-hub-call-front m (list :keys (list :openrouter "k")))))
                                          :message))))
    (let ((methods (drgnx-hub-client-front-test--methods log)))
      (should (equal methods '("hello" "coord/prune" "coord/prune" "coord/prune")))
      (should-not (member "gateway/keys" methods)))))

(ert-deftest drgnx-hub-client/front-call-refuses-a-hub-that-does-not-prove-itself ()
  (drgnx-hub-client-front-test--with '("DRGNX_FAKE_HUB_MODE=wrong-proof")
    (should (string-search "did not prove it read"
                           (plist-get (drgnx-hub-client-front-test--failure (lambda () (drgnx-hub-call-front "coord/prune" nil)))
                                      :message)))
    ;; nothing is kept, and the method never went
    (should-not drgnx-hub--front-conn)
    (should (equal (drgnx-hub-client-front-test--methods log) '("hello")))))

;;; hub-client-front-test.el ends here
