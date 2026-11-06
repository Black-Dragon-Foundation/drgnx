;;; work-space-runners-ui-test.el --- a runner on the Work map: screenshots and a jank report -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The fixture map with its machine made a runner that runs a job for the first agent: the map is drawn and captured,
;; then Enter on the machine opens its queue in the side panel (measured: the jank report is written next to the PNGs
;; as JSON) and the panel is captured.  The evidence folder (DRGNX_UI_EVIDENCE) keeps the files; run once per display
;; scale (DRGNX_UI_SCALE).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-work-runners-ui--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-work-runners-ui--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-work-runners-ui--repo))
(add-to-list 'load-path (expand-file-name "modules/ui" drgnx-work-runners-ui--repo))
(require 'drgnx)
(require 'drgnx-work-client)
(load (expand-file-name "test/fixtures/work-space-fixture" drgnx-work-runners-ui--repo) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-work-runners-ui--repo) nil t)

(defvar drgnx-work-space--view)
(defvar drgnx-work-map--outline)
(defvar drgnx-view)
(declare-function drgnx-work-map-mode "drgnx-work-map")
(declare-function drgnx-work-map-select "drgnx-work-map")
(declare-function drgnx-work-map-open-selection "drgnx-work-map")
(declare-function drgnx-view-attach "drgnx-view")
(declare-function drgnx-view-touch "drgnx-view")
(declare-function drgnx-view-draw-now "drgnx-view")

(defun drgnx-work-runners-ui--frame ()
  "The fixture frame with its machine a runner and the first agent's job on it."
  (let ((frame (drgnx-work-fixture-frame)))
    (plist-put frame :items
               (mapcar (lambda (it)
                         (pcase (plist-get it :id)
                           ("machine:desktop"
                            (drgnx-work-fixture-changed frame "machine:desktop" :slots '(3 16)
                                                        :runner '(:trust "mine" :state "ready" :jobs 3 :icon "server")))
                           ("agent:a1"
                            (drgnx-work-fixture-changed frame "agent:a1" :job
                                                        (list :id "x1" :name "suite" :runner "desktop" :state "running"
                                                              :started (- (float-time) 190) :limit_min 6
                                                              :keys '("token"))))
                           (_ it)))
                       (plist-get frame :items)))))

(defun drgnx-work-runners-ui--shot (name)
  "Capture the root frame and keep it as NAME."
  (redisplay t)
  (let* ((dir (make-temp-file "work-runners" t))
         (shot (plist-get (drgnx-uitest-capture dir) :root))
         (out (expand-file-name (format "work-runners-%s.png" name) temporary-file-directory)))
    (should (file-exists-p shot))
    (copy-file shot out t)
    (drgnx-uitest--evidence out)))

(ert-deftest drgnx-work-runners-ui/the-map-and-the-queue ()
  (require 'drgnx-modules)
  (drgnx-test-with-modules '(tools/work-space)
    (let* ((scale (round (frame-scale-factor))) (id "work-runners-ui")
           (drgnx-work-client--views (make-hash-table :test #'equal))
           (drgnx-work-client-change-functions '(drgnx-work-map--changed))
           (buf (generate-new-buffer " *work-runners*")))
      (puthash id (drgnx-work-client--make-view :id id :state (drgnx-work-client-init (drgnx-work-runners-ui--frame))
                                                :status 'live)
               drgnx-work-client--views)
      (unwind-protect
          (with-current-buffer buf
            (drgnx-work-map-mode)
            (setq drgnx-work-space--view id drgnx-work-map--outline 'off)
            (drgnx-view-attach 'work-map)
            (drgnx-view-touch drgnx-view)
            (switch-to-buffer buf)
            (delete-other-windows)
            (drgnx-view-draw-now drgnx-view)
            (drgnx-work-runners-ui--shot (format "map-s%d" scale))
            (drgnx-uitest-measure-begin)
            (drgnx-work-map-select '(machine . "machine:desktop"))
            (drgnx-work-map-open-selection)
            (redisplay t)
            (let ((report (drgnx-uitest-measure-end)) (dir (getenv "DRGNX_UI_EVIDENCE")))
              (message "work-runners jank report (scale %d): %S" scale report)
              (when (and dir (file-directory-p dir))
                (with-temp-file (expand-file-name (format "jank-s%d.eld" scale) dir)
                  (let ((print-length nil) (print-level nil)) (prin1 report (current-buffer))))))
            (drgnx-work-runners-ui--shot (format "queue-s%d" scale)))
        (kill-buffer buf)))))

(provide 'work-space-runners-ui-test)
;;; work-space-runners-ui-test.el ends here
