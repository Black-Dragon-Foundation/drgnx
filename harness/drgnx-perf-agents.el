;;; drgnx-perf-agents.el --- the perf lab's agents-in-the-editor workloads: five mock agents, a 3,000-line file -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Controller side of the agents-in-the-editor, panel and pair budget rows (docs/develop/perf.md, "The agents-in-the-editor
;; workloads").  Each spec is one `drgnx-perf-run--workloads' entry.  The session side is
;; test/fixtures/agents-editor-five-fixture.el: a hub of the workload's own with five mock agents editing a 3,000-line file
;; while the keys are typed into it.  A workload's setup, `:each' and `:check' call the fixture's premise, which signals
;; when the five agents are not streaming: a workload that did not get its situation fails.  The mock agents only.

;;; Code:
(require 'cl-lib)
(require 'drgnx-ui)

(defun drgnx-perf-agents--lib-form ()
  "The session side shared by every workload, as a form string: the fixture and the module switch."
  (concat
   "(progn (defvar drgnx-perf--hub-bin nil) (setq drgnx-perf--hub-bin " (prin1-to-string (getenv "DRGNX_RATATOSKR_BIN")) ") "
   (prin1-to-string
    `(progn
       (load ,(expand-file-name "test/fixtures/agents-editor-five-fixture" drgnx-ui-repo-dir) nil t)
       (require 'drgnx-modules)
       (defvar drgnx-perf--agents-module t "Whether tools/agents-in-editor ran when the workload began.")
       (defun drgnx-perf--agents-up (module pair extra)
         "Five agents streaming; the editor's module on or off as MODULE says; PAIR makes the fifth a paired chat; EXTRA is
a function called once the agents run (a follow window, a panel)."
         (setq drgnx-perf--agents-module
               (eq 'ok (plist-get (cdr (assq 'tools/agents-in-editor (drgnx-modules-report))) :status)))
         (drgnx-modules-set-enabled 'tools/agents-in-editor module)
         ;; the module is an idle-stage one: its setup must have run before the agents start, not at the first idle
         ;; moment of the typing (the premise's timeline put the followed agent's turn ending there)
         (when module
           (drgnx-modules-run 'idle)
           (unless (eq 'ok (plist-get (cdr (assq 'tools/agents-in-editor (drgnx-modules-report))) :status))
             (error "The module tools/agents-in-editor is not running")))
         (drgnx-agents-five-start drgnx-perf--hub-bin pair)
         (drgnx-agents-five-visit)
         (when extra (funcall extra))
         (drgnx-agents-five-premise))
       (defun drgnx-perf--agents-down ()
         (drgnx-agents-five-stop)
         (ignore-errors (delete-other-windows))
         (drgnx-modules-set-enabled 'tools/agents-in-editor drgnx-perf--agents-module)
         t)))
   ")"))

(defun drgnx-perf-agents-workloads ()
  "The agents-in-the-editor workloads (specs like `drgnx-perf-run--workloads'): `agents-typing' (the module on, a
follow window), `agents-typing-none' (the same agents, the module off: the paired baseline), `agents-follow' (a follow
window moving with the first agent), `agent-panel-stream' (the first agent's panel open, streaming) and `pair-typing'
\(the fifth a paired chat)."
  (let* ((lib (drgnx-perf-agents--lib-form))
         (type (lambda (s) (list :type s)))
         (typing (make-list 6 (funcall type "(let ((x 1)) (message \"%s\" x)) ")))
         (each "(progn (drgnx-agents-five-visit) (drgnx-agents-five-premise) t)")
         (check "(and (drgnx-agents-five-premise) t)")
         (down "(drgnx-perf--agents-down)")
         (up (lambda (module pair extra)
               (concat "(progn " lib " (drgnx-perf--agents-up " module " " pair " " extra ") t)"))))
    `((agents-typing :setup ,(funcall up "t" "nil" "#'drgnx-agents-five-follow")
                     :each ,each :actions ,typing :check ,check :teardown ,down)
      (agents-typing-none :setup ,(funcall up "nil" "nil" "nil")
                          :each ,each :actions ,typing :check ,check :teardown ,down)
      (agents-follow :setup ,(funcall up "t" "nil" "#'drgnx-agents-five-follow")
                     :each ,each :actions ,(append typing (make-list 20 (list :keys "<down>")))
                     :check ,check :teardown ,down)
      (agent-panel-stream :setup ,(funcall up "t" "nil"
                                           "(lambda () (require 'drgnx-agent-panel) (drgnx-agent-panel-open (drgnx-agent-session-remote (car drgnx-agents-five--mirrors))))")
                          :each ,each :actions ,typing :check ,check :teardown ,down)
      (pair-typing :setup ,(funcall up "t" "t" "nil")
                   :each ,each :actions ,typing
                   :measure "(list :pair_applied_ratio (drgnx-agents-five-pair-applied-ratio))"
                   :check ,check :teardown ,down))))

(provide 'drgnx-perf-agents)
;;; drgnx-perf-agents.el ends here
