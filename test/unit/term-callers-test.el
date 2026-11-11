;;; term-callers-test.el --- batch tests: drgnx's callers of the terminal (quit, key sheet, panel, input modes) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-terminal" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-term" drgnx-dir) nil t)

(defvar drgnx-modal-input-modes)
(defvar drgnx-close-input-modes)
(defvar drgnx-surfaces-cheatsheet-sections)
(defvar drgnx-session-quit-keep)
(defvar drgnx-session-keepable-functions)
(defvar drgnx-session-running-functions)

(ert-deftest drgnx-term-callers/quit-question-times-out-as-running ()
  ;; the hub does not answer `term/list' in time: every open terminal counts as running, so nothing stops unasked;
  ;; answered, a shell at its prompt is not named (`close': the terminals are asked about as running programs)
  (let ((drgnx-term--buffers (make-hash-table :test #'equal)) (b (generate-new-buffer "*terminal*"))
        (drgnx-term-on-quit 'close))
    (unwind-protect
        (progn
          (with-current-buffer b (drgnx-term-mode) (setq drgnx-term--id "t1" drgnx-term--state 'open))
          (puthash "t1" b drgnx-term--buffers)
          (cl-letf (((symbol-function 'drgnx-hub-call-sync)
                     (lambda (method _params timeout)
                       (should (equal method "term/list"))
                       (should (equal timeout drgnx-term-list-wait))
                       (error "The drgnx hub did not answer term/list"))))
            (should (equal (drgnx-term-running) (list (buffer-name b)))))
          (cl-letf (((symbol-function 'drgnx-hub-call-sync) (lambda (&rest _) (list (list :id "t1" :running nil)))))
            (should-not (drgnx-term-running)))
          ;; a terminal that is not open (its command ended) is never asked about
          (with-current-buffer b (setq drgnx-term--state 'exited))
          (cl-letf (((symbol-function 'drgnx-hub-call-sync) (lambda (&rest _) (error "Not asked"))))
            (should-not (drgnx-term-running))))
      (kill-buffer b))))

(ert-deftest drgnx-term-callers/quit-keeps-what-runs ()
  ;; `ask': the terminals whose program runs are offered to keep, not named as running; Keep Running keeps them, Close
  ;; Them none, a quit that did not ask the running ones; `keep' keeps every open one, `close' none
  (let ((drgnx-term--buffers (make-hash-table :test #'equal)) (drgnx-session-quit-keep nil) (drgnx-term--quit-keep nil)
        (busy (generate-new-buffer "*terminal*")) (idle (generate-new-buffer "*terminal*")))
    (unwind-protect
        (progn
          (with-current-buffer busy (drgnx-term-mode) (setq drgnx-term--id "t1" drgnx-term--state 'open))
          (with-current-buffer idle (drgnx-term-mode) (setq drgnx-term--id "t2" drgnx-term--state 'open))
          (puthash "t1" busy drgnx-term--buffers)
          (puthash "t2" idle drgnx-term--buffers)
          (cl-letf (((symbol-function 'drgnx-hub-call-sync)
                     (lambda (&rest _) (list (list :id "t1" :running t) (list :id "t2" :running :false)))))
            (let ((drgnx-term-on-quit 'ask))
              (should-not (drgnx-term-running))
              (should (equal (drgnx-term-keepable) (list (buffer-name busy))))
              (should (equal (drgnx-term--kept-at-quit) '("t1")))
              (setq drgnx-session-quit-keep 'keep)
              (should (equal (drgnx-term--kept-at-quit) '("t1")))
              (setq drgnx-session-quit-keep 'close)
              (should-not (drgnx-term--kept-at-quit)))
            (let ((drgnx-term-on-quit 'keep))
              (should-not (drgnx-term-running))
              (should-not (drgnx-term-keepable))
              (should (equal (sort (drgnx-term--kept-at-quit) #'string<) '("t1" "t2"))))
            (let ((drgnx-term-on-quit 'close))
              (should (equal (drgnx-term-running) (list (buffer-name busy))))
              (should-not (drgnx-term--kept-at-quit)))))
      (dolist (b (list busy idle))
        (with-current-buffer b (setq drgnx-term--state 'exited))
        (kill-buffer b)))))

(ert-deftest drgnx-term-callers/quit-question-offers-keep-running ()
  ;; with programs that can keep running the question is Keep Running, Close Them or Cancel, and says which it was
  (let ((drgnx-session-keepable-functions (list (lambda () '("*terminal: vim*"))))
        (drgnx-session-running-functions nil) (drgnx-session-quit-keep nil) (asked nil) (answer ?k))
    (cl-letf (((symbol-function 'save-some-buffers) #'ignore)
              ((symbol-function 'drgnx-session--unsaved-buffers) #'ignore)
              ((symbol-function 'drgnx-session--running-programs) #'ignore)
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Not this question")))
              ((symbol-function 'read-multiple-choice)
               (lambda (prompt choices &rest _) (push prompt asked) (assq answer choices))))
      (should (drgnx-session-quit-confirm))
      (should (eq drgnx-session-quit-keep 'keep))
      (should (string-search "*terminal: vim*" (car asked)))
      (setq answer ?c)
      (should (drgnx-session-quit-confirm))
      (should (eq drgnx-session-quit-keep 'close))
      (setq answer ?q)
      (should-not (drgnx-session-quit-confirm))
      (should-not drgnx-session-quit-keep))))

(ert-deftest drgnx-term-callers/reattach-offers-only-what-no-emacs-shows ()
  ;; orphaned or detached, and neither this session's nor shown here; another live Emacs's terminal is never offered
  (let ((drgnx-term--buffers (make-hash-table :test #'equal)) (b (generate-new-buffer " shown")))
    (unwind-protect
        (progn
          (puthash "here" b drgnx-term--buffers)
          (should (equal (mapcar (lambda (r) (plist-get r :id))
                                 (drgnx-term--offered-rows
                                  (list (list :id "mine" :mine t :orphaned :false)
                                        (list :id "theirs" :mine :false :orphaned :false)
                                        (list :id "crashed" :mine :false :orphaned t)
                                        (list :id "kept" :mine :false :orphaned :false :detached_at 1700000000000)
                                        (list :id "here" :mine :false :orphaned t))))
                         '("crashed" "kept"))))
      (kill-buffer b))))

(ert-deftest drgnx-term-callers/reattach-asks-or-opens-at-once ()
  ;; `ask': one notice that runs Reattach Terminal; `always': each opens at once, but one from before an update
  ;; (Close only); `never': nothing
  (let ((drgnx-term--buffers (make-hash-table :test #'equal)) (drgnx-term--notices nil) (drgnx-term--offered nil)
        (posted nil) (opened nil)
        (rows (list (list :id "a" :orphaned t) (list :id "b" :detached_at 1 :old t))))
    (cl-letf (((symbol-function 'drgnx-notice-set) (lambda (_source items &rest _) (setq posted items)))
              ((symbol-function 'drgnx-term-reattach-one) (lambda (r &rest _) (push (plist-get r :id) opened))))
      (let ((drgnx-term-reattach 'ask))
        (drgnx-term--offer rows)
        (should (equal (mapcar (lambda (i) (plist-get i :text)) posted)
                       '("2 terminals kept running from your last session")))
        (should (eq (plist-get (car posted) :command) 'terminal-reattach))
        (should-not opened))
      (let ((drgnx-term-reattach 'always))
        (drgnx-term--offer rows)
        (should (equal opened '("a")))
        (should-not posted))
      (setq opened nil)
      (let ((drgnx-term-reattach 'never))
        (drgnx-term--offer rows)
        (should-not posted)
        (should-not opened)))))

(ert-deftest drgnx-term-callers/key-sheet-has-terminal-section-without-advice ()
  ;; the "In the terminal" section comes through core's sheet hook: the module advises nothing of the sheet's
  (drgnx-test-with-modules '(tools/terminal tools/term) :strict t
                           (should (memq 'drgnx-terminal-cheatsheet-section drgnx-surfaces-cheatsheet-sections))
                           (should-not (advice--p (advice--symbol-function 'drgnx-surfaces-cheatsheet)))
                           ;; no key profile is applied in batch: the split is given, the hook is what is tested
                           (cl-letf (((symbol-function 'drgnx-terminal-key-split)
                                      (lambda (&rest _) (list :to-drgnx '("C-S-p") :to-shell '("C-w")))))
                             (should (assoc "In the terminal" (drgnx-surfaces--sections)))))
  (should-not (memq 'drgnx-terminal-cheatsheet-section drgnx-surfaces-cheatsheet-sections)))

(ert-deftest drgnx-term-callers/terminal-buffer-goes-to-the-panel ()
  ;; by its mode, whatever its name (a temp buffer's name is internal, which only name rules take)
  (drgnx-test-with-modules '(core/workbench)
    (let ((b (generate-new-buffer "drgnx-term-callers")))
      (unwind-protect
          (with-current-buffer b
            (drgnx-term-mode)
            (let ((rule (drgnx-wb-rule-for b)))
              (should (eq (car rule) 'panel))
              (should (eq (plist-get (cdr rule) :tab) 'terminal))))
        (kill-buffer b)))))

(ert-deftest drgnx-term-callers/a-terminal-takes-typed-input ()
  ;; the modal engines start it in insert state, and Esc and q are the program's, never Close Pane
  (require 'drgnx-close (expand-file-name "modules/ui/drgnx-close" drgnx-dir))
  (should (memq 'drgnx-term-mode drgnx-modal-input-modes))
  (should (memq 'drgnx-term-mode drgnx-close-input-modes)))

(provide 'term-callers-test)
;;; term-callers-test.el ends here
