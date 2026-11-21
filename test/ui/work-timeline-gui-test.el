;;; work-timeline-gui-test.el --- GUI tests: the Timeline's Schedule and Activity forms, zoom and crumbs (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; The hub builds the Timeline's rows (work/trail.rs, work/schedule.rs); these rows drive the editor's half on a graphical
;; frame with the hub stubbed at `drgnx-work-client--call' and the attach stubbed at `drgnx-work-trail--rows-attach': what
;; each key asks of the hub (the subscription's method and window, `work/schedule/set', `work/trail/set' with the window,
;; follow and filter) and which buffer it shows.  The words of the states and the bars are the hub's rows' (vegvisir's
;; schedule tests).

(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-ui-work-timeline--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "modules/tools"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-work-timeline--repo)))
(require 'drgnx)
(require 'drgnx-view)
(require 'drgnx-work-board)
(require 'drgnx-work-trail)

(defmacro drgnx-ui-work-timeline--with (calls attached &rest body)
  "BODY with a map buffer, the hub's calls pushed on CALLS (method . params) and each attach pushed on ATTACHED
\(view method params).  The Timeline buffers BODY makes are killed after."
  (declare (indent 2))
  `(let ((,calls nil) (,attached nil) (map (get-buffer-create "*drgnx work: test*")))
     (skip-unless (display-graphic-p))
     (cl-letf (((symbol-function 'drgnx-work-client--call) (lambda (m p &optional _cb) (push (cons m p) ,calls)))
               ((symbol-function 'drgnx-work-trail--map-rows-p) (lambda (_b) t))
               ((symbol-function 'drgnx-work-timeline--view) (lambda () (format "%s/test" (if (eq drgnx-work-timeline--form 'schedule) "schedule" "timeline"))))
               ((symbol-function 'drgnx-work-timeline-rows-attached) #'ignore)
               ((symbol-function 'drgnx-work-timeline--model-lanes) (lambda (_m) (list (list :session "s1" :label "one"))))
               ((symbol-function 'drgnx-work-timeline--map-view) (lambda (_b) "map"))
               ((symbol-function 'drgnx-work-lens-name) (lambda (&rest _) "test"))
               ((symbol-function 'drgnx-work-lens-string) (lambda (&rest _) ""))
               ((symbol-function 'drgnx-work-trail--rows-attach)
                (lambda (view params)
                  (push (list view drgnx-work-trail--hub-method params) ,attached)
                  (setq drgnx-view-patch nil))))
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (string-match-p "\\`\\*drgnx work \\(schedule\\|timeline\\):" (buffer-name b)) (kill-buffer b)))
         (kill-buffer map)))))

(defun drgnx-ui-work-timeline--methods (calls) (mapcar #'car (reverse calls)))

(ert-deftest drgnx-ui-work-timeline/schedule-is-the-default-with-target-marks ()
  "The Timeline opens as the Schedule: `work/schedule/subscribe' over a window ending now, grouped by plan."
  (drgnx-ui-work-timeline--with calls attached
    (with-current-buffer (drgnx-work-timeline-open map)
      (should (eq drgnx-work-timeline--form 'schedule))
      (should (equal "work/schedule/subscribe" (nth 1 (car attached))))
      (let ((p (nth 2 (car attached))))
        (should (equal "plan" (plist-get p :group)))
        (should (= 86400 (round (- (plist-get (plist-get p :window) :to) (plist-get (plist-get p :window) :from)))))))))

(ert-deftest drgnx-ui-work-timeline/t-toggles-schedule-and-activity ()
  (drgnx-ui-work-timeline--with calls attached
    (with-current-buffer (drgnx-work-timeline-open map)
      (setq-local drgnx-work-lens--map map)
      (save-window-excursion
        (drgnx-work-timeline-toggle)
        (should (eq drgnx-work-timeline--form 'activity))
        (should (equal "work/trail/subscribe" (nth 1 (car attached))))
        (should (equal "timeline/test" (drgnx-work-timeline--view)))
        (setq-local drgnx-work-lens--map map)
        (drgnx-work-timeline-toggle)
        (should (eq drgnx-work-timeline--form 'schedule))))))

(ert-deftest drgnx-ui-work-timeline/ret-on-a-bar-zooms-to-activity-and-backspace-returns ()
  (drgnx-ui-work-timeline--with calls attached
    (with-current-buffer (drgnx-work-timeline-open map)
      (setq-local drgnx-work-lens--map map)
      (let ((schedule (current-buffer)))
        (let ((inhibit-read-only t)) (insert (propertize "  the task\n" 'drgnx-work-id "task:T1")))
        (goto-char (point-min))
        (cl-letf (((symbol-function 'drgnx-work-timeline--agents-of) (lambda (id) (should (equal "task:T1" id)) (list (list :session "s1" :label "one")))))
          (save-window-excursion
            (drgnx-work-timeline--nav 'open)
            (should (eq drgnx-work-timeline--form 'activity))
            (should (equal "Schedule" (car (car drgnx-work-timeline--crumbs))))
            (should (= 3600 drgnx-work-timeline--span))
            (setq-local drgnx-work-lens--map map)
            (drgnx-work-timeline-zoom-back)
            (should (eq drgnx-work-timeline--form 'schedule))
            (should (eq (current-buffer) schedule))
            (should (null drgnx-work-timeline--crumbs))))))))

(ert-deftest drgnx-ui-work-timeline/ret-on-a-segment-opens-the-trail-at-the-step ()
  (drgnx-ui-work-timeline--with calls attached
    (let (opened)
      (with-current-buffer (drgnx-work-timeline-open map 'activity)
        (setq-local drgnx-work-lens--map map)
        (let ((inhibit-read-only t)) (insert (propertize "  ▇▇▇\n" 'drgnx-work-step ["s1" 7])))
        (goto-char (point-min))
        (cl-letf (((symbol-function 'drgnx-work-trail-open)
                   (lambda (_m session) (push session opened) (get-buffer-create "*drgnx work trail: s1*"))))
          (save-window-excursion
            (should (drgnx-work-timeline--nav 'open))
            (should (equal '("s1") opened))))
        (kill-buffer "*drgnx work trail: s1*")))))

(ert-deftest drgnx-ui-work-timeline/edits-filter-isolates-edits ()
  (drgnx-ui-work-timeline--with calls attached
    (with-current-buffer (drgnx-work-timeline-open map 'activity)
      (drgnx-work-timeline-filter)
      (should (equal "work/trail/set" (car (car calls))))
      (should (equal "edits" (plist-get (cdr (car calls)) :filter)))
      (drgnx-work-timeline-filter)
      (should (equal "waits" (plist-get (cdr (car calls)) :filter))))))

(ert-deftest drgnx-ui-work-timeline/by-machine-groups-rows ()
  (drgnx-ui-work-timeline--with calls attached
    (with-current-buffer (drgnx-work-timeline-open map)
      (drgnx-work-timeline-group)
      (should (equal "work/schedule/set" (car (car calls))))
      (should (equal "machine" (plist-get (cdr (car calls)) :group))))))

(ert-deftest drgnx-ui-work-timeline/now-follows-with-T ()
  (drgnx-ui-work-timeline--with calls attached
    (with-current-buffer (drgnx-work-timeline-open map 'activity)
      (drgnx-work-timeline-pan-earlier)
      (should drgnx-work-timeline--to)
      (should-not (plist-member (cdr (car calls)) :follow))   ; a window alone stops following
      (drgnx-work-timeline-go-now)
      (should-not drgnx-work-timeline--to)
      (should (eq t (plist-get (cdr (car calls)) :follow))))))

(ert-deftest drgnx-ui-work-timeline/zoom-walks-the-spans-and-stops-at-the-ends ()
  (drgnx-ui-work-timeline--with calls attached
    (with-current-buffer (drgnx-work-timeline-open map 'activity)
      (should (= 3600 drgnx-work-timeline--span))
      (drgnx-work-timeline-zoom-in)
      (should (= 600 drgnx-work-timeline--span))
      (let ((n (length calls))) (drgnx-work-timeline-zoom-in) (should (= n (length calls))))   ; no call at the end
      (dotimes (_ 3) (drgnx-work-timeline-zoom-out))
      (should (= 86400 drgnx-work-timeline--span))
      (let ((n (length calls))) (drgnx-work-timeline-zoom-out) (should (= n (length calls)))))))   ; Activity stops at the day

(provide 'work-timeline-gui-test)
;;; work-timeline-gui-test.el ends here
