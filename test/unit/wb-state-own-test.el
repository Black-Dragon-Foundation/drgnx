;;; wb-state-own-test.el --- batch tests: pane kinds, roles and subscriptions belong to the module that made them -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-modules-fingerprint)
(require 'drgnx-panes)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)

;; Fake modules are set up with `drgnx-modules--run-setup' and turned off with `drgnx-module-teardown'.

(defmacro drgnx-state-own-test--with (&rest body)
  "BODY with fresh pane, area, rule, module and claim tables, the store's state saved, and the docks hidden."
  (declare (indent 0) (debug t))
  `(drgnx-test-with-state
     (let* ((cfg (make-temp-file "drgnx-cfg" t))
            (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
            (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
            (drgnx-modules--stacks nil) (drgnx-modules--runs nil)
            (drgnx-module--claims (make-hash-table :test 'equal))
            (drgnx-pane--kinds nil) (drgnx-state--kind-owners nil) (drgnx-pane-backend 'areas)
            (drgnx-wb--sections nil) (drgnx-wb--areas (copy-tree drgnx-wb--areas))
            (drgnx-rules--table (copy-sequence drgnx-rules--table))
            (drgnx-wb-unrouted nil)
            (display-buffer-alist nil) (display-buffer-overriding-action '(nil)))
       (delete-other-windows)
       (dolist (p '(drgnx-wb-areas drgnx-wb-view drgnx-intent-by drgnx-wb-dock-px drgnx-wb-panel-px drgnx-wb-right-px))
         (set-frame-parameter nil p nil))
       (drgnx-rules-mode 1)
       (unwind-protect (progn ,@body)
         (drgnx-rules-mode -1)
         (drgnx-wb-area-hide 'panel)
         (drgnx-wb-area-hide 'right)
         (drgnx-wb-hide-sidebar)
         (delete-other-windows)
         (dolist (b (buffer-list)) (when (string-prefix-p " *drgnx own-" (buffer-name b)) (kill-buffer b)))
         (delete-directory cfg t)))))

(defun drgnx-state-own-test--setup (name setup)
  "Run SETUP as fake module NAME's, through the recorder, and mark it running."
  (setf (alist-get name drgnx-modules--table) (list :doc "test" :stage 'startup :setup setup))
  (should-not (drgnx-modules--run-setup name setup))
  (drgnx-modules--record name 'startup 0 'ok))

(defun drgnx-state-own-test--buffer (name)
  (lambda () (with-current-buffer (get-buffer-create name t) (special-mode) (current-buffer))))

(defvar drgnx-state-own-test--shown nil "Who asked, for each show of the test kind.")

(defun drgnx-state-own-test--on-pane-shown (&rest _) nil)
(defun drgnx-state-own-test--on-pane-hidden (&rest _) nil)

(defun drgnx-state-own-test--define (kind home &optional title)
  (drgnx-pane-define-kind kind :title (or title "T") :home home
                          :placeholder (drgnx-state-own-test--buffer (format " *drgnx own-%s*" kind))
                          :on-show (lambda (_) (push (plist-get drgnx-state--writing :by) drgnx-state-own-test--shown))))

(defun drgnx-state-own-test--setup-all ()
  "A module's setup: a now and an idle subscription, a role and a bottom pane kind."
  (drgnx-state-subscribe 'pane-shown #'drgnx-state-own-test--on-pane-shown :lane 'now)
  (drgnx-state-subscribe 'pane-hidden #'drgnx-state-own-test--on-pane-hidden)
  (drgnx-state-define-role 'own-role :chrome 'lane)
  (drgnx-state-own-test--define 'own-term 'bottom))

(ert-deftest drgnx-state-own/off-on-brings-the-pane-back-as-it-was ()
  (drgnx-state-own-test--with
    (let ((drgnx-state-own-test--shown nil) hidden-by
          (hide (symbol-function 'drgnx-wb-area-hide)))
      (drgnx-state-own-test--setup 'test/own-a #'drgnx-state-own-test--setup-all)
      (should (eq 'test/own-a (drgnx-state-kind-owner 'own-term)))
      (drgnx-pane-show 'own-term :by 'user)
      (drgnx-pane-resize 'own-term 9 :by 'user)
      (should (= 9 (window-pixel-height (drgnx-pane-window 'own-term))))
      (cl-letf (((symbol-function 'drgnx-wb-area-hide)
                 (lambda (area) (push (plist-get drgnx-state--writing :by) hidden-by) (funcall hide area))))
        (should-not (drgnx-module-teardown 'test/own-a)))
      ;; hidden by the teardown, nothing of the module left, its intent kept
      (should (equal '(teardown) hidden-by))
      (should-not (drgnx-wb-area-window 'panel))
      (should-not (drgnx-pane-kind 'own-term))
      (should-not (drgnx-state-kind-owner 'own-term))
      (should-not (assq 'own-term (plist-get (alist-get 'panel drgnx-wb--areas) :tabs)))
      (should-not (assq 'own-role drgnx-state--roles))
      (should-not (or drgnx-state--now drgnx-state--idle))
      (should (eq 'own-term (drgnx-state-intent nil :front 'panel)))
      (should (equal '(:px 9 :by user) (drgnx-state-intent nil :sizes 'bottom)))
      ;; on again: the pane is back at the size you chose
      (drgnx-state-own-test--setup 'test/own-a #'drgnx-state-own-test--setup-all)
      (should (eq 'test/own-a (drgnx-state-kind-owner 'own-term)))
      (should (= 9 (window-pixel-height (drgnx-pane-show 'own-term)))))))

(ert-deftest drgnx-state-own/defining-a-kind-shows-it-again-when-its-area-shows ()
  (drgnx-state-own-test--with
    (let ((drgnx-state-own-test--shown nil))
      (drgnx-state-own-test--setup 'test/own-a #'drgnx-state-own-test--setup-all)
      (drgnx-pane-show 'own-term :by 'user)
      (should-not (drgnx-module-teardown 'test/own-a))
      ;; the area comes up again while the module is off: it shows what was in front
      (drgnx-wb-area-show 'panel)
      (should (drgnx-wb-area-window 'panel))
      (setq drgnx-state-own-test--shown nil)
      (drgnx-state-own-test--setup 'test/own-a #'drgnx-state-own-test--setup-all)
      (should (drgnx-pane-window 'own-term))
      (should (equal '(teardown) drgnx-state-own-test--shown))
      ;; an area that does not show stays hidden
      (drgnx-wb-area-hide 'panel)
      (should-not (drgnx-module-teardown 'test/own-a))
      (setq drgnx-state-own-test--shown nil)
      (drgnx-state-own-test--setup 'test/own-a #'drgnx-state-own-test--setup-all)
      (should-not (drgnx-wb-area-window 'panel))
      (should-not drgnx-state-own-test--shown))))

(ert-deftest drgnx-state-own/a-module-off-leaves-no-subscriber-and-no-role ()
  (drgnx-state-own-test--with
    (let ((now drgnx-state--now) (idle drgnx-state--idle) (roles (copy-sequence drgnx-state--roles)))
      (drgnx-state-own-test--setup 'test/own-a #'drgnx-state-own-test--setup-all)
      (drgnx-state-own-test--define 'own-nowhere 'editor)        ; outside a setup: core's, never undone
      (should (assq 'pane-shown drgnx-state--now))
      (should (assq 'own-role drgnx-state--roles))
      (should-not (drgnx-module-teardown 'test/own-a))
      (should (equal now drgnx-state--now))
      (should (equal idle drgnx-state--idle))
      (should (equal roles drgnx-state--roles))
      (should (equal '(own-nowhere) (mapcar #'car drgnx-pane--kinds))))))

(ert-deftest drgnx-state-own/the-census-sees-a-leaked-subscription ()
  (drgnx-state-own-test--with
    (let ((before (drgnx-modules-fingerprint)))
      ;; outside any module's setup nothing is recorded: the leak a census must name
      (drgnx-state-subscribe 'pane-shown #'drgnx-state-own-test--on-pane-shown :lane 'now)
      (drgnx-state-subscribe 'pane-hidden #'drgnx-state-own-test--on-pane-hidden)
      (drgnx-state-define-role 'own-role :chrome nil)
      (drgnx-state-own-test--define 'own-leak 'bottom)
      (let ((whats (mapcar (lambda (d) (plist-get d :what))
                           (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint)))))
        (dolist (re '("drgnx-state--now.*pane-shown" "drgnx-state--idle.*pane-hidden"
                      "drgnx-state--roles.*own-role" "drgnx-pane--kinds.*own-leak"))
          (should (seq-some (lambda (s) (string-match-p re s)) whats))))
      (drgnx-state-unsubscribe 'pane-shown #'drgnx-state-own-test--on-pane-shown)
      (drgnx-state-unsubscribe 'pane-hidden #'drgnx-state-own-test--on-pane-hidden)
      (drgnx-state-undefine-role 'own-role)
      (drgnx-pane-undefine-kind 'own-leak)
      (should-not (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint)))
      ;; and a module turned off leaves nothing for the census
      (drgnx-state-own-test--setup 'test/own-a #'drgnx-state-own-test--setup-all)
      (drgnx-pane-show 'own-term :by 'user)
      (should-not (drgnx-module-teardown 'test/own-a))
      (let ((diff (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint))))
        (should-not (seq-some (lambda (d) (string-match-p "registry drgnx-\\(state\\|pane\\)--" (plist-get d :what))) diff))))))

(ert-deftest drgnx-state-own/undefine-kind-restores-only-its-own ()
  (drgnx-state-own-test--with
    (let ((title (lambda () (plist-get (drgnx-pane-kind 'own-k) :title))))
      (drgnx-state-own-test--setup 'test/own-a (lambda () (drgnx-state-own-test--define 'own-k 'bottom "A")))
      (drgnx-state-own-test--setup 'test/own-b (lambda () (drgnx-state-own-test--define 'own-k 'bottom "B")))
      (should (equal "B" (funcall title)))
      (should (eq 'test/own-b (drgnx-state-kind-owner 'own-k)))
      ;; the older module off first: B's definition stays
      (should-not (drgnx-module-teardown 'test/own-a))
      (should (equal "B" (funcall title)))
      (should (eq 'test/own-b (drgnx-state-kind-owner 'own-k)))
      (should-not (drgnx-module-teardown 'test/own-b))
      (should-not (drgnx-pane-kind 'own-k))
      (should-not (assq 'own-k (plist-get (alist-get 'panel drgnx-wb--areas) :tabs)))
      ;; the newer one off first: A's definition comes back, and A's off removes it
      (drgnx-state-own-test--setup 'test/own-a (lambda () (drgnx-state-own-test--define 'own-k 'bottom "A")))
      (drgnx-state-own-test--setup 'test/own-b (lambda () (drgnx-state-own-test--define 'own-k 'bottom "B")))
      (should-not (drgnx-module-teardown 'test/own-b))
      (should (equal "A" (funcall title)))
      (should (eq 'test/own-a (drgnx-state-kind-owner 'own-k)))
      (should (equal "A" (plist-get (alist-get 'own-k (plist-get (alist-get 'panel drgnx-wb--areas) :tabs)) :title)))
      (should-not (drgnx-module-teardown 'test/own-a))
      (should-not (drgnx-pane-kind 'own-k))
      ;; the function itself: left, right and editor kinds go from their dock, area or rule
      (drgnx-pane-define-kind 'own-l :home 'left :buffer (drgnx-state-own-test--buffer " *drgnx own-l*"))
      (drgnx-pane-define-kind 'own-r :home 'right)
      (drgnx-pane-define-kind 'own-e :home 'editor :buffer "*own-e*")
      (should (assq 'own-l drgnx-wb--sections))
      (should (drgnx-wb-rule-for "*own-e*"))
      (dolist (k '(own-l own-r own-e)) (should (drgnx-pane-undefine-kind k)))
      (should-not drgnx-pane--kinds)
      (should-not (assq 'own-l drgnx-wb--sections))
      (should-not (assq 'own-r (plist-get (alist-get 'right drgnx-wb--areas) :tabs)))
      (should-not (drgnx-wb-rule-for "*own-e*"))
      (should-not (drgnx-pane-undefine-kind 'own-l)))))

(ert-deftest drgnx-state-own/teardown-never-prompts ()
  (drgnx-state-own-test--with
    (drgnx-state-own-test--setup 'test/own-a #'drgnx-state-own-test--setup-all)
    (drgnx-pane-show 'own-term :by 'user)
    (let ((asked nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (push 'y-or-n-p asked) t))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) (push 'yes-or-no-p asked) t))
                ((symbol-function 'read-string) (lambda (&rest _) (push 'read-string asked) ""))
                ((symbol-function 'completing-read) (lambda (&rest _) (push 'completing-read asked) ""))
                ((symbol-function 'read-from-minibuffer) (lambda (&rest _) (push 'read-from-minibuffer asked) "")))
        (should-not (drgnx-module-teardown 'test/own-a)))
      (should-not asked)
      (should-not (drgnx-wb-area-window 'panel)))))

(provide 'wb-state-own-test)
;;; wb-state-own-test.el ends here
