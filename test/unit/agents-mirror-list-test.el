;;; agents-mirror-list-test.el --- batch tests: one odd session in `agents/list' never hides the others -*- lexical-binding: t -*-
;; test-class: det
;; The hub builds its snapshots typed and in-process (docs/develop/hub.md), so an `agents/list' answer holds none that
;; the registry refuses; this holds the editor's side of the same promise: a list with one session the mirror cannot
;; read (an unknown key, a wrong type, not a record at all) still shows every other session, and nothing signals.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-agents)
(require 'drgnx-agents-mirror)
(require 'drgnx-records)
(require 'drgnx-hub-client)

(defun drgnx-agents-mirror-list-test--snap (id &rest extra)
  (append (list :id id :name id :profile "mock" :cwd "/w" :status "idle") extra))

(defun drgnx-agents-mirror-list-test--sync (sessions)
  "The ids mirrored after the hub answered `agents/list' with SESSIONS (a list of JSON objects as plists)."
  (let ((drgnx-agents--sessions nil) (drgnx-agents-profiles nil) callback)
    (cl-letf (((symbol-function 'drgnx-hub-connect) #'ignore)
              ((symbol-function 'drgnx-hub-call)
               (lambda (method _params cb) (when (equal method "agents/list") (setq callback cb)) 1))
              ((symbol-function 'drgnx-agents-mirror--fetch) #'ignore)
              ((symbol-function 'drgnx-notify) #'ignore))
      (unwind-protect
          (progn
            (drgnx-agents-mirror-sync)
            (funcall callback (list :sessions sessions) nil)
            (sort (mapcar #'drgnx-agent-session-remote drgnx-agents--sessions) #'string<))
        (drgnx-agents-mirror-stop)))))

(ert-deftest drgnx-agents-mirror-list/every-good-session-shows-whatever-the-odd-one-is ()
  (let ((good-a (drgnx-agents-mirror-list-test--snap "a"))
        (good-b (drgnx-agents-mirror-list-test--snap "b")))
    ;; all good: both show
    (should (equal (drgnx-agents-mirror-list-test--sync (list good-a good-b)) '("a" "b")))
    ;; one odd item in the middle: an unknown key, a wrong type, a bare string, a list with no id
    (dolist (odd (list (drgnx-agents-mirror-list-test--snap "odd" :bogus 1)
                       (drgnx-agents-mirror-list-test--snap "odd" :status 42)
                       "not a record"
                       (list :name "no id")))
      (let ((shown (drgnx-agents-mirror-list-test--sync (list good-a odd good-b))))
        (should (member "a" shown))
        (should (member "b" shown))))))

;;; agents-mirror-list-test.el ends here
