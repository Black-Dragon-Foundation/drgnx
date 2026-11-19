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
(dolist (d '("core" "wb" "modules/ui"))
  (add-to-list 'load-path (expand-file-name d drgnx-work-graph-gui--repo)))
(require 'drgnx)
(require 'drgnx-view)
(defvar drgnx-work-lens-map)
(defvar drgnx-work-item-map)
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
               (drgnx-test-wait (lambda () (redisplay t) (> (buffer-size buf) 0)) :secs 30 :what "the graph's rows")
               ,@body)
           (when (buffer-live-p buf) (kill-buffer buf))
           (drgnx-work-thirty-stop))))))

(defun drgnx-work-graph-gui--text (buffer) (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest drgnx-work-graph/tasks-layer-between-plans-and-agents ()
  "The layers' labels run You asked, Specs, Plans, Tasks, …, Agents: Tasks sits after Plans and before Agents."
  (drgnx-work-graph-gui--with
    (let* ((text (drgnx-work-graph-gui--text buf))
           (plans (string-match "Plans" text)) (tasks (string-match "Tasks" text)) (agents (string-match "Agents" text)))
      (should (and plans tasks agents))
      (should (< plans tasks agents)))))

(ert-deftest drgnx-work-graph/runs-on-shows-job-chips-linked-to-agents ()
  "A machine's card in Runs on has a job chip, and the chip's `drgnx-work-link' is the id of an agent of the map."
  (drgnx-work-graph-gui--with
    (let (links)
      (with-current-buffer buf
        (let ((pos (point-min)))
          (while (setq pos (next-single-property-change pos 'drgnx-work-link))
            (when-let* ((l (get-text-property pos 'drgnx-work-link))) (push l links)))))
      (should links)
      (should (cl-every (lambda (l) (string-prefix-p "agent:" l)) links)))))

(ert-deftest drgnx-work-graph/m-still-switches-to-map ()
  "`m' is the map lens and `M' moves a task to another machine: two commands, two keys."
  (drgnx-work-graph-gui--with
    (should (eq (lookup-key drgnx-work-lens-map "m") #'drgnx-work-lens-show-map))
    (should (eq (lookup-key drgnx-work-item-map "M") #'drgnx-work-move-machine))
    (should-not (eq (lookup-key drgnx-work-lens-map "m") (lookup-key drgnx-work-item-map "M")))))

(provide 'work-graph-gui-test)
;;; work-graph-gui-test.el ends here
