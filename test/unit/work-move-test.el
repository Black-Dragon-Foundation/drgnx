;;; work-move-test.el --- batch tests: Move to Another Machine sends the selected item -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; No hub: `drgnx-hub-call' is caught and the machine choice answered.  What the hub does with a move is tested in
;; Rust (runners::queue) and in conformance (work/machines-move-*).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-map" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-trail" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-detail" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(defvar drgnx-work-space-command-ids)
(defvar drgnx-work-map--selection)

(ert-deftest drgnx-work-move/M-sends-the-selected-item ()
  "On a queue's job row the job moves; elsewhere the selected agent's next jobs do (from a Detail, the map's
selection).  The machine is the one chosen from this machine and the hub's runners.  `M' is the command in every
profile, and `m' still switches to the map."
  (let (sent asked)
    (cl-letf (((symbol-function 'drgnx-hub-call)
               (lambda (method params &rest _) (push (cons method params) sent)))
              ((symbol-function 'drgnx-hub-call-sync)
               (lambda (method _params &rest _)
                 (should (equal method "runners/list"))
                 (list :runners (vector (list :name "desk") (list :name "laptop")))))
              ((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _) (push choices asked) "laptop")))
      (with-temp-buffer
        (insert (propertize "  make check · running" 'drgnx-work-job "x7") "\n" "  l live log\n")
        (goto-char (point-min))
        (call-interactively #'drgnx-work-move-machine)
        (let ((map (current-buffer)))
          (with-temp-buffer
            (drgnx-work-map-mode)
            (setq drgnx-work-map--selection '(agent . "agent:s4"))
            (call-interactively #'drgnx-work-move-machine)
            (let ((sel (current-buffer)))
              (with-current-buffer map
                (forward-line 1)                ; the line with no job: the Detail's map selection
                (drgnx-work-detail-mode)
                (setq drgnx-work-detail--map sel)
                (call-interactively #'drgnx-work-move-machine)))))))
    (should (equal (car asked) '("local" "desk" "laptop")))
    (should (equal (nreverse sent)
                   '(("machines/move" :target "job:x7" :machine "laptop")
                     ("machines/move" :target "session:s4" :machine "laptop")
                     ("machines/move" :target "session:s4" :machine "laptop")))))
  (should (memq 'work-move-machine drgnx-work-space-command-ids))
  (dolist (profile '("vscode" "emacs" "vim"))
    (let ((rows (plist-get (with-temp-buffer
                             (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
                             (read (current-buffer)))
                           :bind)))
      (should (equal (cadr (assq 'work-move-machine rows)) "M"))
      (should (equal (cadr (assq 'work-view-map rows)) "m")))))

;;; work-move-test.el ends here
