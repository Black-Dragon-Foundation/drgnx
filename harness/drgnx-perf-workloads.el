;;; drgnx-perf-workloads.el --- the perf lab's workloads for off-the-main-thread work (§17.6) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Controller side of the workloads that measure what the Nidhogg workers take off the main thread: language-server
;; traffic, tree-sitter, a compile flood, images, listings and auto-save.  Each is a spec for `drgnx-perf-run-workload'
;; (setup, each, actions, `:complete-when', `:digest', `:measure', teardown); the code they run in the session is
;; test/fixtures/workers/perf-session.el, loaded by every setup, and their data comes from generators there or from the
;; recorded corpora (capture-lsp.sh).  Their budget rows are in test/perf/budgets.eld, `:report-only' until the step that
;; moves the work lands; docs/develop/perf.md ("The workers' workloads") lists them.

;;; Code:
(require 'cl-lib)
(require 'drgnx-ui)

(defvar drgnx-perf-run--fixture)
(declare-function drgnx-perf-run--visit-fixture-form "drgnx-perf-run")
(declare-function drgnx-perf-run--hub-form "drgnx-perf-run")

(defconst drgnx-perf-workers-names
  '(lsp-burst lsp-typing ts-open ts-paste ts-typing ts-typing-unclosed compile-flood image-open
              explorer-expand explorer-git quick-open-large quick-open-typing quick-open-typing-old
              agents-line-motion agents-line-motion-old autosave-typing)
  "The new workloads, in the order they run.")

(defconst drgnx-perf-workers-lsp-sizes "500000,1000000,3000000"
  "Bytes of the completion answers lsp-burst's servers send, in turn (0.5, 1 and 3 MB).")

(defun drgnx-perf-workers--lib ()
  "The form that loads the session side."
  (format "(load %S nil t)" (expand-file-name "test/fixtures/workers/perf-session.el" drgnx-ui-repo-dir)))

(defun drgnx-perf-workers--form (&rest forms)
  "A `progn' of the session library's load and FORMS (strings), ending in t."
  (concat "(progn " (drgnx-perf-workers--lib) " " (string-join forms " ") " t)"))

(defun drgnx-perf-workers--checked (specs)
  "SPECS with every `:check' form wrapped so that it yields t (the lab wants exactly t, the library's predicates yield
whatever they found)."
  (mapcar (lambda (spec)
            (let ((plist (copy-sequence (cdr spec))))
              (when (plist-get plist :check)
                (setq plist (plist-put plist :check (format "(and %s t)" (plist-get plist :check)))))
              (cons (car spec) plist)))
          specs))

(defun drgnx-perf-workers-workloads ()
  "The off-the-main-thread workloads (specs, like `drgnx-perf-run--workloads')."
  (let* ((type (lambda (s) (list :type s)))
         (code (make-list 6 (funcall type "(let ((x 1)) (message \"%s\" x)) ")))
         (visit (drgnx-perf-run--visit-fixture-form))
         (kill-fixture (format "(when-let* ((b (find-buffer-visiting %S))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))"
                               (or drgnx-perf-run--fixture "")))
         (c-typing (list (funcall type "int f(int a, int b) { return (a + b) * [")
                         (funcall type "2] ; if (a < b) { f(a, ")
                         (funcall type "b); } else { g(\"x\", ")
                         (funcall type "'y') ; } ")
                         (funcall type "static const char *s = \"abc\"; /* c */ ")
                         (funcall type "struct s { int a; char *b; } v = { 1, \"b\" }; ")))
         (c-unclosed (list (funcall type "int f(int a, int b { if (a < b ( ")
                           (funcall type "return g(a, [b, ")
                           (funcall type "for (int i = 0; i < 10; i++ { ")
                           (funcall type "h(\"unterminated, ( ")
                           (funcall type "while (1 { ")
                           (funcall type "x = [1, 2, (3 ")))
         ;; ts-typing's completion: every typed character's command has run, then the colour settled
         (edit-done (lambda (acts)
                      (format "(drgnx-perf-w-ts-edit-done %d)"
                              (apply #'+ (mapcar (lambda (a) (length (plist-get a :type))) acts))))))
    (drgnx-perf-workers--checked
     `(;; recorded rust-analyzer, clangd and tsserver traffic through jsonrpc: completion answers of 0.5, 1 and 3 MB
       (lsp-burst
        :setup ,(drgnx-perf-workers--form
                 (format "(drgnx-perf-w-lsp-setup '(\"LSP_REPLAY_COMPLETION_SIZES=%s\" \"LSP_REPLAY_STAMP=1\"))"
                         drgnx-perf-workers-lsp-sizes))
        :each ,(concat "(progn " visit " (drgnx-perf-w-lsp-burst-each) t)")
        :timers t
        :actions ,code
        :complete-when "(drgnx-perf-w-lsp-burst-done)"
        :digest "(drgnx-perf-w-lsp-burst-digest)"
        :measure "(drgnx-perf-w-lsp-burst-measure)"
        :check "(drgnx-perf-w-lsp-burst-done)"
        :teardown ,(concat "(progn (drgnx-perf-w-lsp-teardown) " kill-fixture " t)"))
       ;; the servers flood 300 recorded diagnostics and progress messages a second (100 each) while the harness types
       (lsp-typing
        :setup ,(drgnx-perf-workers--form "(drgnx-perf-w-lsp-setup '(\"LSP_REPLAY_FLOOD=100\"))")
        :each ,(concat "(progn " visit " (drgnx-perf-w-lsp-typing-each) t)")
        :timers t
        :actions ,code
        :complete-when "(drgnx-perf-w-lsp-typing-done)"
        :digest "(drgnx-perf-w-lsp-typing-digest)"
        :measure "(drgnx-perf-w-lsp-typing-measure)"
        :check "(drgnx-perf-w-lsp-typing-done)"
        :teardown ,(concat "(progn (drgnx-perf-w-lsp-teardown) " kill-fixture " t)"))
       ;; 1 and 2 MB files in c-ts-mode, typescript-ts-mode and python-ts-mode, visited in a second window one after the other
       (ts-open
        :setup ,(drgnx-perf-workers--form "(drgnx-perf-w-ts-setup)")
        :each ,(concat "(progn " visit " (drgnx-perf-w-ts-open-each))")
        :actions ,code
        :complete-when "(drgnx-perf-w-ts-open-done)"
        :digest "(drgnx-perf-w-ts-open-digest)"
        :measure "(drgnx-perf-w-ts-open-measure)"
        :check "(drgnx-perf-w-ts-open-done)"
        :teardown ,(concat "(progn (drgnx-perf-w-ts-open-teardown) " kill-fixture " t)"))
       ;; yanking 500 kB into a 1 MB C file, with electric-pair, show-paren and which-function on
       (ts-paste
        :setup ,(drgnx-perf-workers--form "(drgnx-perf-w-ts-setup '(1))")
        :each "(drgnx-perf-w-ts-edit-each t)"
        ;; the yank, then typing into the grown buffer: ~90 commands a repeat, so the three repeats give the p95 its 100
        :actions ,(cons '(:keys "C-y") (seq-take c-typing 3))
        :complete-when "(drgnx-perf-w-ts-paste-done)"
        :digest "(drgnx-perf-w-ts-edit-digest)"
        :check "(drgnx-perf-w-ts-paste-done)"
        :teardown "(drgnx-perf-w-ts-edit-teardown)")
       (ts-typing
        :setup ,(drgnx-perf-workers--form "(drgnx-perf-w-ts-setup '(1))")
        :each "(drgnx-perf-w-ts-edit-each)"
        :actions ,c-typing
        :complete-when ,(funcall edit-done c-typing)
        :digest "(drgnx-perf-w-ts-edit-digest)"
        :check ,(funcall edit-done c-typing)
        :teardown "(drgnx-perf-w-ts-edit-teardown)")
       ;; the same with openers typed and nothing closed: a tree full of errors
       (ts-typing-unclosed
        :setup ,(drgnx-perf-workers--form "(drgnx-perf-w-ts-setup '(1))")
        :each "(drgnx-perf-w-ts-edit-each)"
        :actions ,c-unclosed
        :complete-when ,(funcall edit-done c-unclosed)
        :digest "(drgnx-perf-w-ts-edit-digest)"
        :check ,(funcall edit-done c-unclosed)
        :teardown "(drgnx-perf-w-ts-edit-teardown)")
       ;; a 200k-line log through a pty (compile in comint mode) while the harness types
       (compile-flood
        :setup ,(drgnx-perf-workers--form "(drgnx-perf-w-compile-setup)")
        :each ,(concat "(progn " visit " (drgnx-perf-w-compile-each))")
        :timers t
        :actions ,code
        :complete-when "(drgnx-perf-w-compile-done)"
        :digest "(drgnx-perf-w-compile-digest)"
        :check "(and (drgnx-perf-w-compile-done) (equal (drgnx-perf-w-compile-digest) (drgnx-perf-w-compile-expected)))"
        :teardown ,(concat "(progn (drgnx-perf-w-compile-teardown) " kill-fixture " t)"))
       ;; GUI: a 4K PNG screenshot, then a 20-image Markdown preview, in a second window
       (image-open
        :setup ,(drgnx-perf-workers--form)
        :each ,(concat "(progn " visit " (drgnx-perf-w-image-each))")
        :actions ,code
        :complete-when "(drgnx-perf-w-image-done)"
        :digest "(drgnx-perf-w-image-digest)"
        :measure "(drgnx-perf-w-image-measure)"
        :check "(drgnx-perf-w-image-done)"
        :teardown ,(concat "(progn (drgnx-perf-w-image-teardown) " kill-fixture " t)"))
       ;; the existing bench's operations as perf rows: a 5,000-file folder expanded; the status of a 25k-file repository
       (explorer-expand
        :setup ,(drgnx-perf-workers--form "(drgnx-perf-w-explorer-expand-setup)")
        :each ,(concat "(progn " visit " (drgnx-perf-w-explorer-expand-each))")
        :actions ,code
        :complete-when "(drgnx-perf-w-explorer-expand-done)"
        :digest "(drgnx-perf-w-explorer-expand-digest)"
        :measure "(drgnx-perf-w-explorer-expand-measure)"
        :check "(drgnx-perf-w-explorer-expand-done)"
        :teardown ,(concat "(progn (drgnx-perf-w-explorer-expand-teardown) " kill-fixture " t)"))
       (explorer-git
        :setup ,(drgnx-perf-workers--form "(drgnx-perf-w-explorer-git-setup)")
        :each ,(concat "(progn " visit " (drgnx-perf-w-explorer-git-each))")
        :actions ,code
        :complete-when "(drgnx-perf-w-explorer-git-done)"
        :digest "(drgnx-perf-w-explorer-git-digest)"
        :check "(drgnx-perf-w-explorer-git-done)"
        :teardown ,(concat "(progn (drgnx-perf-w-explorer-git-teardown) " kill-fixture " t)"))
       ;; Quick Open's listing of a 200,000-file repository while the harness types
       (quick-open-large
        :setup ,(drgnx-perf-workers--form "(drgnx-perf-w-quick-open-setup)")
        :each ,(concat "(progn " visit " (drgnx-perf-w-quick-open-each))")
        :actions ,code
        :complete-when "(drgnx-perf-w-quick-open-done)"
        :digest "(drgnx-perf-w-quick-open-digest)"
        :measure "(drgnx-perf-w-quick-open-measure)"
        :check "(drgnx-perf-w-quick-open-done)"
        :teardown ,(concat "(progn (drgnx-perf-w-quick-open-teardown) " kill-fixture " t)"))
       ;; Quick Open (its key queued by :each), then thirteen keys typed into it over the same repository: what each key
       ;; allocates, on the hub's rows (a hub of the workload's own, `drgnx-perf-run--hub-form') and on the old path
       ;; (the streamed listing)
       ,@(mapcar (lambda (old)
                   `(,(if old 'quick-open-typing-old 'quick-open-typing)
                     :setup ,(if old (drgnx-perf-workers--form "(drgnx-perf-w-quick-open-setup)")
                               (concat "(progn " (drgnx-perf-run--hub-form) " (drgnx-perf--hub-start nil) "
                                       (drgnx-perf-workers--form "(drgnx-perf-w-quick-open-setup)") ")"))
                     :each ,(if old "(drgnx-perf-w-quick-open-typing-old-each)" "(drgnx-perf-w-quick-open-typing-each)")
                     :actions ,(append (mapcar (lambda (c) (funcall type (string c))) "d012/f001.txt") (list (list :keys "C-g")))
                     :complete-when "(drgnx-perf-w-quick-open-typing-done)"
                     :digest "(drgnx-perf-w-quick-open-typing-digest)"
                     :check "(drgnx-perf-w-quick-open-typing-check)"
                     :teardown ,(if old "(drgnx-perf-w-quick-open-typing-teardown)"
                                  "(progn (drgnx-perf-w-quick-open-typing-teardown) (drgnx-perf--hub-stop))")))
                 '(nil t))
       ;; twenty point motions in a Lisp file with three agents, an agent frame per command: what the agent line's
       ;; name costs, kept per line, and on the old path (named every frame)
       ,@(mapcar (lambda (old)
                   `(,(if old 'agents-line-motion-old 'agents-line-motion)
                     :setup ,(drgnx-perf-workers--form "(drgnx-perf-w-agents-line-setup)")
                     :each ,(if old "(drgnx-perf-w-agents-line-old-each)" "(drgnx-perf-w-agents-line-each)")
                     :actions ,(make-list 20 (list :keys "<down>"))
                     :complete-when "(drgnx-perf-w-agents-line-done)"
                     :digest "(drgnx-perf-w-agents-line-digest)"
                     :check "(drgnx-perf-w-agents-line-done)"
                     :teardown "(drgnx-perf-w-agents-line-teardown)"))
                 '(nil t))
       ;; typing in a 50 MB buffer across an auto-save
       (autosave-typing
        :setup ,(drgnx-perf-workers--form)
        :each "(drgnx-perf-w-autosave-each)"
        :actions ,code
        :complete-when "(drgnx-perf-w-autosave-done)"
        :digest "(drgnx-perf-w-autosave-digest)"
        :check "(drgnx-perf-w-autosave-done)"
        :teardown "(drgnx-perf-w-autosave-teardown)")))))

;;;; The calibration rows (report-only, never failing)

(defconst drgnx-perf-cal-rows
  '((cal-costs :workloads (ts-open ts-typing ts-paste image-open) :keys (:costs :decisions :policy))
    (cal-pressure :workloads (ts-typing live-view) :keys (:pressure))
    (cal-pty :workloads (terminal-output) :keys (:ahead)))
  "The calibration rows: (ROW :workloads W… :keys K…).  A row reads the `:cal' record of each of its workloads in a
run (`drgnx-perf-cal-lines'): `cal-costs' the costs and the decisions against `nidhogg-workers--policy' (ts open,
typing and paste, image open), `cal-pressure' the pressure on the tree-sitter and live-view workloads (starts/s, mean
and max frames), `cal-pty' the pty read-ahead (`:ahead' p50 and max) under terminal-output's `seq'.  They report the
numbers the thresholds are calibrated from; nothing here fails a run.")

(defun drgnx-perf-cal-lines (results)
  "Report lines for `drgnx-perf-cal-rows' over RESULTS ((WORKLOAD . PLIST)…): one per row and workload that ran, each
key as the probe's value, or `n/a (Task 55/57)' for a key the Nidhogg build does not have."
  (let (out)
    (pcase-dolist (`(,row . ,spec) drgnx-perf-cal-rows)
      (dolist (w (plist-get spec :workloads))
        (when-let* ((r (assq w results)) ((not (plist-get (cdr r) :error))))
          (let ((cal (plist-get (cdr r) :cal)))
            (push (format "%s %s: %s" row w
                          (mapconcat (lambda (k)
                                       (format "%s %s" (substring (symbol-name k) 1)
                                               (if (plist-member cal k) (format "%S" (plist-get cal k)) "n/a (Task 55/57)")))
                                     (plist-get spec :keys) ", "))
                  out)))))
    (nreverse out)))

(provide 'drgnx-perf-workloads)
;;; drgnx-perf-workloads.el ends here
