;;; mock-cdp.el --- for Live view tests: a Chrome DevTools Protocol stand-in on a local websocket server -*- lexical-binding: t -*-
;; Served in the test's own Emacs (`websocket-server', 127.0.0.1, a random port): it records every message a
;; client sends, answers Target.getTargets with `drgnx-mock-cdp-targets', Target.attachToTarget with a session
;; per target and everything else with {} (Target.setDiscoverTargets first announces every target with
;; Target.targetCreated, as Chrome does), and sends screencast frames when a test asks.  Needs `websocket'.
(require 'cl-lib)
(require 'seq)
(require 'websocket)

(defvar drgnx-mock-cdp-targets
  '((:targetId "T1" :type "page" :title "Example" :url "https://example.org/")
    (:targetId "T2" :type "page" :title "Docs" :url "https://docs.example.org/start")
    (:targetId "W1" :type "service_worker" :title "sw" :url "https://example.org/sw.js"))
  "The targets the mock browser has.")

(defvar drgnx-mock-cdp--server nil "The listening server process.")
(defvar drgnx-mock-cdp--received nil "Every message a client sent (parsed plists), newest first.")

(defun drgnx-mock-cdp--send (ws msg)
  (websocket-send-text ws (json-serialize msg)))

(defun drgnx-mock-cdp--answer (ws msg)
  (push msg drgnx-mock-cdp--received)
  (let* ((method (plist-get msg :method)) (params (plist-get msg :params))
         ;; as Chrome does: discovering targets first announces every existing one, then answers
         (_ (when (and (equal method "Target.setDiscoverTargets") (eq (plist-get params :discover) t))
              (dolist (tg drgnx-mock-cdp-targets)
                (drgnx-mock-cdp--send ws (list :method "Target.targetCreated" :params (list :targetInfo tg))))))
         (result (pcase method
                   ("Target.getTargets" (list :targetInfos (vconcat drgnx-mock-cdp-targets)))
                   ("Target.attachToTarget" (list :sessionId (concat "S-" (plist-get params :targetId))))
                   (_ (make-hash-table)))))
    (drgnx-mock-cdp--send ws (append (list :id (plist-get msg :id) :result result)
                                     (and (plist-get msg :sessionId) (list :sessionId (plist-get msg :sessionId)))))))

(defun drgnx-mock-cdp-start ()
  "Start the mock browser; its port."
  (drgnx-mock-cdp-stop)
  (setq drgnx-mock-cdp--received nil
        drgnx-mock-cdp--server
        (websocket-server t :host 'local
                          :on-message (lambda (ws frame)
                                        (drgnx-mock-cdp--answer
                                         ws (json-parse-string (websocket-frame-text frame) :object-type 'plist)))))
  (process-contact drgnx-mock-cdp--server :service))

(defun drgnx-mock-cdp-stop ()
  "Close the server and every connection to it (a client may have gone already)."
  (when drgnx-mock-cdp--server
    (dolist (ws (seq-filter (lambda (ws) (eq (websocket-server-conn ws) drgnx-mock-cdp--server)) websocket-server-websockets))
      (ignore-errors (websocket-close ws))
      (ignore-errors (delete-process (websocket-conn ws)))
      (setq websocket-server-websockets (delq ws websocket-server-websockets)))
    (delete-process drgnx-mock-cdp--server))
  (setq drgnx-mock-cdp--server nil))

(defun drgnx-mock-cdp-clients ()
  "The open connections to the mock."
  (seq-filter (lambda (ws) (and (eq (websocket-server-conn ws) drgnx-mock-cdp--server) (websocket-openp ws)))
              websocket-server-websockets))

(defun drgnx-mock-cdp-received (&optional method)
  "The messages clients sent, oldest first; only METHOD's when given."
  (seq-filter (lambda (m) (or (null method) (equal (plist-get m :method) method))) (reverse drgnx-mock-cdp--received)))

(defun drgnx-mock-cdp-event (method params &optional session)
  "Send the event METHOD with PARAMS (on flat SESSION) to every client."
  (dolist (ws (drgnx-mock-cdp-clients))
    (drgnx-mock-cdp--send ws (append (list :method method :params params) (and session (list :sessionId session))))))

(cl-defun drgnx-mock-cdp-frame (n &key (session "S-T1") (width 1280) (height 800))
  "Send screencast frame N on SESSION: its data is the bytes \"frame-N\", its page WIDTH×HEIGHT CSS pixels."
  (drgnx-mock-cdp-event "Page.screencastFrame"
                        (list :data (base64-encode-string (format "frame-%d" n)) :sessionId n
                              :metadata (list :deviceWidth width :deviceHeight height :offsetTop 0 :pageScaleFactor 1
                                              :scrollOffsetX 0 :scrollOffsetY 0 :timestamp (float-time)))
                        session))

(defun drgnx-mock-cdp-wait (pred &optional secs)
  "Wait (SECS, default 5) until PRED holds, reading process output; PRED's last value."
  (let ((deadline (+ (float-time) (or secs 5))))
    (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.02)))
  (funcall pred))

(provide 'mock-cdp)
;;; mock-cdp.el ends here
