;;; monitors-fixture.el --- GUI tests: a second frame on a second monitor at another scale -*- lexical-binding: t -*-
;; A session with two monitors at two scales under sway (`DRGNX_UI_COMPOSITOR=sway DRGNX_UI_MONITORS=2
;; DRGNX_UI_SCALES="1.25 2"') can show a frame on the second one: `swaymsg' moves its window to HEADLESS-2.

(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "wait-fixture" (file-name-directory (macroexp-file-name))))

(defun drgnx-test-monitor-scales ()
  "The session's monitor scales (one per monitor), from DRGNX_UI_SESSION_SCALES; nil at scale 1."
  (mapcar #'string-to-number (split-string (or (getenv "DRGNX_UI_SESSION_SCALES") "") " " t)))

(defun drgnx-test-second-monitor-p ()
  "Non-nil when the session has two monitors at two scales under sway, so a frame can be moved to the second."
  (let ((scales (drgnx-test-monitor-scales)))
    (and (= 2 (length scales)) (/= (nth 0 scales) (nth 1 scales))
         (getenv "SWAYSOCK") (executable-find "swaymsg") t)))

(defun drgnx-test-frame-on-second-monitor (title)
  "A new frame titled TITLE, moved to sway's second monitor and holding its scale (`frame-scale-factor' other than the
selected frame's); the selected frame keeps the focus.  Only when `drgnx-test-second-monitor-p'.  A frame becomes a
compositor window only once drawn and presented, so each try waits for its paint first."
  (let* ((root (selected-frame))
         (frame (make-frame `((width . 60) (height . 10) (title . ,title)))))
    (drgnx-test-wait
     (lambda ()
       (drgnx-test-wait-presented :frame frame)
       (zerop (call-process "swaymsg" nil nil nil (format "[title=\"%s\"] move to output HEADLESS-2" title))))
     :secs 10 :what "the frame on the second monitor")
    (drgnx-test-wait (lambda () (drgnx-test-wait-presented :frame frame)
                       (/= (frame-scale-factor frame) (frame-scale-factor root)))
                     :secs 10 :what "the second monitor's scale on the frame")
    (select-frame-set-input-focus root)
    frame))

(provide 'drgnx-monitors-fixture)
;;; monitors-fixture.el ends here
