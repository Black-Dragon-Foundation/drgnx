;;; work-filter-test.el --- the Work map's Active · Completed · All switch -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; No hub: the map client's calls are caught at `drgnx-work-client--call'.  The filter itself is the hub's
;; (vegvisir's `shown'); this file is what the editor sends and keeps.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-work-client)
(require 'drgnx-hub-client)
(require 'drgnx-ai)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(defvar drgnx-work-space--view)
(defvar drgnx-work-map--show-by-project)
(defvar drgnx-persist-state-functions)
(declare-function drgnx-work-map-cycle-filter "drgnx-work-map")
(declare-function drgnx-work-map--persist-state "drgnx-work-map")
(declare-function drgnx-work-map--adopt-show "drgnx-work-map")
(declare-function drgnx-work-map--show-for "drgnx-work-map")
(declare-function drgnx-persist--extra "drgnx-persist")

(defmacro drgnx-work-filter-test--in-map (id &rest body)
  "BODY in a map buffer on view ID, the hub's calls pushed on `calls' (newest first)."
  (declare (indent 1))
  `(with-temp-buffer
     (drgnx-work-map-mode)
     (setq drgnx-work-space--view ,id)
     (drgnx-work-client-open ,id (list :id ,id :roots nil))
     (setq calls nil)
     ,@body))

(ert-deftest drgnx-work-filter/dot-cycles-three-states-and-sends-show ()
  (let (calls (drgnx-work-map--show-by-project nil))
    (cl-letf (((symbol-function 'drgnx-work-client--call)
               (lambda (method params &rest _) (push (cons method params) calls) t)))
      (drgnx-work-filter-test--in-map "workspace:filter-cycle"
        (let (sent)
          (dotimes (_ 3)
            (drgnx-work-map-cycle-filter)
            (let ((f (plist-get (cdr (car calls)) :filters)))
              (push (list (plist-get f :show) (plist-get f :recent_days)) sent)))
          ;; active is where a map starts: the dot goes completed, all, active
          (should (equal (nreverse sent) '(("completed" 7) ("all" 7) ("active" 7)))))))))

(ert-deftest drgnx-work-filter/choice-is-remembered-per-project ()
  (let* ((calls nil) (drgnx-work-map--show-by-project nil)
         (home (make-temp-file "work-filter-home" t))
         (process-environment (cons (concat "HOME=" home) process-environment)))
    (cl-letf (((symbol-function 'drgnx-work-client--call)
               (lambda (method params &rest _) (push (cons method params) calls) t)))
      (drgnx-work-filter-test--in-map "workspace:aaaaaaaaaaaa" (drgnx-work-map-cycle-filter))
      (drgnx-work-filter-test--in-map "workspace:bbbbbbbbbbbb"
        (drgnx-work-map-cycle-filter) (drgnx-work-map-cycle-filter))
      ;; the saved workbench carries the choices; after a restart they come back
      (let* ((drgnx-persist-state-functions '(drgnx-work-map--persist-state))
             (extra (drgnx-persist--extra)))
        (should extra)
        (setq drgnx-work-map--show-by-project nil)
        (should (eq 'active (drgnx-work-map--show-for "workspace:aaaaaaaaaaaa")))
        (set-frame-parameter nil 'drgnx-persist-extra extra)
        (drgnx-work-map--adopt-show (selected-frame))
        (set-frame-parameter nil 'drgnx-persist-extra nil))
      (should (eq 'completed (drgnx-work-map--show-for "workspace:aaaaaaaaaaaa")))
      (should (eq 'all (drgnx-work-map--show-for "workspace:bbbbbbbbbbbb")))
      (should (eq 'active (drgnx-work-map--show-for "workspace:cccccccccccc"))))))
