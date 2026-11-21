;;; work-graph-gui-test.el --- GUI rows: the Work map's Graph on the kit (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The 30-agent workspace as a Graph on the hub's rows (test/fixtures/work-space-thirty-fixture.el): the Tasks layer sits
;; between the Plans and the Agents, a machine's job chips link to the agents that started them, and `m' (the map) is not
;; `M' (move a task to another machine).  Needs Sjá.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-uitest)

(defconst drgnx-work-graph-gui--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "modules/ui" "modules/tools"))
  (add-to-list 'load-path (expand-file-name d drgnx-work-graph-gui--repo)))
(require 'drgnx)
(require 'drgnx-view)
(require 'drgnx-work-board)
(load (expand-file-name "test/fixtures/work-space-thirty-fixture" drgnx-work-graph-gui--repo) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-work-graph-gui--repo) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-work-graph-gui--repo) nil t)

(declare-function drgnx-work-thirty-start "work-space-thirty-fixture")
(declare-function drgnx-work-thirty-stop "work-space-thirty-fixture")
(declare-function drgnx-work-thirty-map "work-space-thirty-fixture")
(declare-function drgnx-work-thirty-only-window "work-space-thirty-fixture")

(defmacro drgnx-work-graph-gui--with (&rest body)
  "BODY with the 30-agent map as a Graph on the hub's rows alone in the root frame's selected window; `buf' is bound."
  (declare (indent 0))
  `(progn
     (skip-unless (and (display-graphic-p) (fboundp 'nidhogg-view--call)))
     (drgnx-test-with-modules '(tools/work-space)
       (let ((root (drgnx-uitest-root-frame)) (buf nil))
         (unwind-protect
             (with-selected-frame root
               (drgnx-work-thirty-only-window)
               (drgnx-work-thirty-start (or (getenv "DRGNX_RATATOSKR_BIN")
                                            (expand-file-name "runtime/target/debug/ratatoskr" drgnx-work-graph-gui--repo)))
               (setq buf (drgnx-work-thirty-map t 'graph))
               (set-window-buffer (selected-window) buf)
               (drgnx-test-wait (lambda ()
                                  (redisplay t)
                                  (let ((s (buffer-local-value 'drgnx-view-patch buf)))
                                    (and (drgnx-view-patch-version s) (not (drgnx-view-patch-stale s))
                                         (not (drgnx-view-patch-resync s)) (> (buffer-size buf) 0))))
                                :secs 30 :what "the graph's rows drawn")
               (with-current-buffer buf (drgnx-view-draw-now drgnx-view))
               ,@body)
           (when (buffer-live-p buf) (kill-buffer buf))
           (drgnx-work-thirty-stop))))))

(defun drgnx-work-graph-gui--text (buffer) (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(defun drgnx-work-graph-gui--links (buffer)
  "The `drgnx-work-link' values of BUFFER's text."
  (let (links)
    (with-current-buffer buffer
      (let ((pos (point-min)))
        (while (setq pos (next-single-property-change pos 'drgnx-work-link))
          (when-let* ((l (get-text-property pos 'drgnx-work-link))) (push l links)))))
    links))

(defun drgnx-work-graph-gui--settle (buffer pred)
  "Draw BUFFER's rows again until PRED holds of it (the plans' and jobs' facts reach the map after the agents'); 30 s."
  (drgnx-test-wait (lambda ()
                     (redisplay t)
                     (with-current-buffer buffer (drgnx-view-draw-now drgnx-view))
                     (funcall pred buffer))
                   :secs 30 :what "the graph's layers and job chips"))

(ert-deftest drgnx-work-graph/tasks-layer-between-plans-and-agents ()
  "The layers' labels run You asked, Specs, Plans, Tasks, …, Agents: Tasks sits after Plans and before Agents."
  (drgnx-work-graph-gui--with
    ;; a layer's label starts the line of its first row.  The layers' rows reach the map one after another (the agents'
    ;; first, the plans' and tasks' after), so draw again until the three labels are there, then they are in order
    (let (plans tasks agents)
      (drgnx-work-graph-gui--settle
       buf (lambda (b) (let ((text (drgnx-work-graph-gui--text b)))
                         (setq plans (string-match "^Plans" text) tasks (string-match "^Tasks" text)
                               agents (string-match "^Agents" text))
                         (and plans tasks agents (< plans tasks agents)))))
      (should (< plans tasks agents)))))

(ert-deftest drgnx-work-graph/runs-on-shows-job-chips-linked-to-agents ()
  "A machine's card in Runs on has a job chip, and the chip's `drgnx-work-link' is the id of an agent of the map."
  (drgnx-work-graph-gui--with
    (drgnx-work-graph-gui--settle buf (lambda (b) (drgnx-work-graph-gui--links b)))
    (let ((links (drgnx-work-graph-gui--links buf)))
      (should links)
      (should (cl-every (lambda (l) (string-prefix-p "agent:" l)) links)))))

(ert-deftest drgnx-work-graph/M-on-a-job-chip-targets-its-agent-and-m-still-switches-to-map ()
  "Task 21: on a machine card's job chip (the chip links to the agent that started it) `M' moves that agent's jobs, not the
selected item; `m' is still the map lens (`work-view-map'), never the move."
  (require 'drgnx-work-detail)
  (with-temp-buffer
    (insert (propertize "desktop  cargo test\n" 'drgnx-work-id "machine:desktop" 'drgnx-work-link "agent:a1"))
    (goto-char (point-min))
    (should (equal "session:a1" (drgnx-work-move--target))))
  (let (lens)
    (cl-letf (((symbol-function 'drgnx-work-lens-switch) (lambda (l) (setq lens l)))
              ((symbol-function 'drgnx-work-move-machine) (lambda (&rest _) (error "m must not move"))))
      (with-temp-buffer (drgnx-work-lens-show-map))
      (should (eq lens 'map)))))

(provide 'work-graph-gui-test)
;;; work-graph-gui-test.el ends here
