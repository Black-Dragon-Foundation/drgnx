;;; wb-undefine-test.el --- batch tests: sections, tabs, rules, places and bus subscriptions undo themselves -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-modules)
(require 'drgnx-wb)
(require 'drgnx-area)
(require 'drgnx-buffers)
(require 'drgnx-explorer)

(defmacro drgnx-wb-undefine-test--with (&rest body)
  "BODY with fresh registries (copies of the real ones), one editor window and no cleanup stacks."
  `(let ((drgnx-wb--sections nil) (drgnx-wb--areas (copy-tree drgnx-wb--areas))
         (drgnx-rules--table (copy-sequence drgnx-rules--table)) (drgnx-rules--places (copy-sequence drgnx-rules--places))
         (drgnx-signal--subscribers nil) (drgnx-signal--editor-window nil)
         (drgnx-modules--stacks nil) (drgnx-modules--current nil))
     (delete-other-windows)
     (set-frame-parameter nil 'drgnx-wb-areas nil)
     (set-frame-parameter nil 'drgnx-wb-right-px nil)
     (unwind-protect (progn ,@body)
       (drgnx-wb-hide-sidebar)
       (drgnx-wb-area-hide 'right)
       (delete-other-windows)
       (dolist (b '("*drgnx-test-top*" "*drgnx-test-bottom*" "*drgnx-test-mine*" "*drgnx-test-notes*"))
         (when (get-buffer b) (kill-buffer b))))))

(defmacro drgnx-wb-undefine-test--setup (module &rest body)
  "Run BODY as MODULE's setup would: the undos it pushes are recorded."
  (declare (indent 1))
  `(let ((drgnx-modules--current ,module) (drgnx-modules--setup-load load-file-name)) ,@body))

(defun drgnx-wb-undefine-test--teardown (module)
  "Run MODULE's recorded undos; the problems."
  (drgnx-modules--unwind module))

(defun drgnx-wb-undefine-test--buffer (name) (lambda () (get-buffer-create name)))

(defun drgnx-wb-undefine-test--sections ()
  (drgnx-wb-define-section 'top :slot -1 :title "TOP" :buffer (drgnx-wb-undefine-test--buffer "*drgnx-test-top*"))
  (drgnx-wb-define-section 'bottom :slot 0 :title "BOTTOM" :buffer (drgnx-wb-undefine-test--buffer "*drgnx-test-bottom*")))

;;;; Sections

(ert-deftest drgnx-wb-undefine/section-goes-and-its-window-closes ()
  (drgnx-wb-undefine-test--with
   (drgnx-wb-undefine-test--sections)
   (drgnx-wb-undefine-test--setup 'test/s
     (drgnx-wb-define-section 'mine :slot 1 :title "MINE" :buffer (drgnx-wb-undefine-test--buffer "*drgnx-test-mine*")))
   (drgnx-wb-show-sidebar)
   (should (window-live-p (drgnx-wb-section-window 'mine)))
   (select-window (drgnx-wb-section-window 'mine))   ; selected: focus must leave first
   (should-not (drgnx-wb-undefine-test--teardown 'test/s))
   (should-not (assq 'mine drgnx-wb--sections))
   (should-not (drgnx-wb-section-window 'mine))
   (should (window-live-p (drgnx-wb-section-window 'top)))      ; the dock keeps its other sections
   (should (window-live-p (drgnx-wb-section-window 'bottom)))
   (should (drgnx-signal-editor-window-p (selected-window)))
   (should (drgnx-wb-sidebar-showing-p))
   ;; Idempotent, and a section that is not defined is no error.
   (should-not (drgnx-wb-undefine-section 'mine))))

(ert-deftest drgnx-wb-undefine/redefined-section-is-restored ()
  (drgnx-wb-undefine-test--with
   (drgnx-wb-undefine-test--sections)
   (let ((before (alist-get 'top drgnx-wb--sections)))
     ;; A module redefines the user's section: teardown puts the previous one back.
     (drgnx-wb-undefine-test--setup 'test/s
       (drgnx-wb-define-section 'top :slot 5 :title "OTHER" :buffer (drgnx-wb-undefine-test--buffer "*drgnx-test-top*")))
     (should (equal (plist-get (alist-get 'top drgnx-wb--sections) :title) "OTHER"))
     (drgnx-wb-undefine-test--teardown 'test/s)
     (should (eq (alist-get 'top drgnx-wb--sections) before))
     ;; Something else redefined it after the module did: teardown leaves that alone.
     (drgnx-wb-undefine-test--setup 'test/s
       (drgnx-wb-define-section 'top :slot 5 :title "OTHER" :buffer (drgnx-wb-undefine-test--buffer "*drgnx-test-top*")))
     (drgnx-wb-define-section 'top :slot 7 :title "THIRD" :buffer (drgnx-wb-undefine-test--buffer "*drgnx-test-top*"))
     (drgnx-wb-undefine-test--teardown 'test/s)
     (should (equal (plist-get (alist-get 'top drgnx-wb--sections) :title) "THIRD")))))

;;;; Tabs

(defun drgnx-wb-undefine-test--tab-names (area) (mapcar #'car (plist-get (alist-get area drgnx-wb--areas) :tabs)))

(ert-deftest drgnx-wb-undefine/tab-goes-and-the-area-shows-the-next ()
  (drgnx-wb-undefine-test--with
   (drgnx-wb-define-area 'right :side 'right :size 30)
   (drgnx-wb-define-tab 'right 'first :title "First")
   (drgnx-wb-undefine-test--setup 'test/t
     (drgnx-wb-define-tab 'right 'mine :title "Mine" :placeholder (drgnx-wb-undefine-test--buffer "*drgnx-test-mine*")))
   (drgnx-wb-define-tab 'right 'last :title "Last")
   (let ((w (drgnx-wb-area-show 'right 'mine)))
     (should (eq (drgnx-wb-area-tab 'right) 'mine))
     (should-not (drgnx-wb-undefine-test--teardown 'test/t))
     (should (equal (drgnx-wb-undefine-test--tab-names 'right) '(first last)))
     (should (eq (drgnx-wb-area-window 'right) w))              ; the same window, now on the next tab
     (should (eq (drgnx-wb-area-tab 'right) 'last))
     (should-not (alist-get 'mine (plist-get (drgnx-area--state 'right) :tabs)))
     (should-not (string-match-p "Mine" (format "%s" (window-parameter w 'header-line-format))))
     (should (string-match-p "Last" (format "%s" (window-parameter w 'header-line-format)))))))

(ert-deftest drgnx-wb-undefine/tab-that-is-not-shown-leaves-the-view ()
  (drgnx-wb-undefine-test--with
   (drgnx-wb-define-area 'right :side 'right :size 30)
   (drgnx-wb-define-tab 'right 'first :title "First")
   (drgnx-wb-undefine-test--setup 'test/t (drgnx-wb-define-tab 'right 'mine :title "Mine"))
   (let ((w (drgnx-wb-area-show 'right 'first)))
     (drgnx-wb-undefine-test--teardown 'test/t)
     (should (eq (drgnx-wb-area-tab 'right) 'first))
     (should (eq (drgnx-wb-area-window 'right) w))
     (should-not (string-match-p "Mine" (format "%s" (window-parameter w 'header-line-format)))))))

(ert-deftest drgnx-wb-undefine/last-tab-hides-the-area ()
  (drgnx-wb-undefine-test--with
   (drgnx-wb-define-area 'right :side 'right :size 30)
   (drgnx-wb-undefine-test--setup 'test/t
     (drgnx-wb-define-tab 'right 'mine :title "Mine" :placeholder (drgnx-wb-undefine-test--buffer "*drgnx-test-mine*")))
   (drgnx-wb-area-show 'right 'mine)
   (should (drgnx-wb-area-window 'right))
   (drgnx-wb-undefine-test--teardown 'test/t)
   (should-not (drgnx-wb-undefine-test--tab-names 'right))
   (should-not (drgnx-wb-area-window 'right))
   (should (= 1 (length (window-list nil 'nomini))))))

(ert-deftest drgnx-wb-undefine/redefined-tab-is-restored ()
  (drgnx-wb-undefine-test--with
   (drgnx-wb-define-area 'right :side 'right :size 30)
   (drgnx-wb-define-tab 'right 'mine :title "Theirs")
   (drgnx-wb-define-tab 'right 'other :title "Other")
   (drgnx-wb-undefine-test--setup 'test/t (drgnx-wb-define-tab 'right 'mine :title "Mine"))
   (drgnx-wb-undefine-test--teardown 'test/t)
   (should (equal (drgnx-wb-undefine-test--tab-names 'right) '(mine other)))   ; same place in the row
   (should (equal (plist-get (alist-get 'mine (plist-get (alist-get 'right drgnx-wb--areas) :tabs)) :title) "Theirs"))
   ;; Redefined by someone else meanwhile: left alone.
   (drgnx-wb-undefine-test--setup 'test/t (drgnx-wb-define-tab 'right 'mine :title "Mine"))
   (drgnx-wb-define-tab 'right 'mine :title "Later")
   (drgnx-wb-undefine-test--teardown 'test/t)
   (should (equal (plist-get (alist-get 'mine (plist-get (alist-get 'right drgnx-wb--areas) :tabs)) :title) "Later"))))

;;;; Rules and places

(ert-deftest drgnx-wb-undefine/unplace-removes-only-that-rule ()
  (drgnx-wb-undefine-test--with
   (let ((n (length drgnx-rules--table)))
     (drgnx-wb-place "\\`\\*theirs\\*\\'" 'panel :tab 'output)
     (drgnx-wb-undefine-test--setup 'test/r
       (drgnx-wb-place "\\`\\*mine\\*\\'" 'panel :tab 'output)
       (drgnx-wb-place '(foo-mode) 'panel :tab 'help))
     (drgnx-wb-place "\\`\\*later\\*\\'" 'panel :tab 'output)    ; added by someone else after
     (should (= (+ n 4) (length drgnx-rules--table)))
     (should (drgnx-wb-unplace '(foo-mode)))
     (should-not (drgnx-wb-unplace '(foo-mode)))                   ; no longer there
     (should (= (+ n 3) (length drgnx-rules--table)))
     (should (equal (drgnx-wb-rule-for "*mine*") '(panel :tab output)))
     (drgnx-wb-undefine-test--teardown 'test/r)
     (should-not (drgnx-wb-rule-for "*mine*"))
     (should (drgnx-wb-rule-for "*theirs*"))
     (should (drgnx-wb-rule-for "*later*"))
     (should (= (+ n 2) (length drgnx-rules--table))))))

(ert-deftest drgnx-wb-undefine/replaced-rule-comes-back ()
  (drgnx-wb-undefine-test--with
   (drgnx-wb-place "\\`\\*r\\*\\'" 'panel :tab 'help)
   (drgnx-wb-undefine-test--setup 'test/r (drgnx-wb-place "\\`\\*r\\*\\'" 'right :tab 'work))
   (should (equal (drgnx-wb-rule-for "*r*") '(right :tab work)))
   (drgnx-wb-undefine-test--teardown 'test/r)
   (should (equal (drgnx-wb-rule-for "*r*") '(panel :tab help)))
   ;; Replaced by someone else after the module: left alone.
   (drgnx-wb-undefine-test--setup 'test/r (drgnx-wb-place "\\`\\*r\\*\\'" 'right :tab 'work))
   (drgnx-wb-place "\\`\\*r\\*\\'" 'panel :tab 'output)
   (drgnx-wb-undefine-test--teardown 'test/r)
   (should (equal (drgnx-wb-rule-for "*r*") '(panel :tab output)))))

(ert-deftest drgnx-wb-undefine/place-goes-and-the-previous-one-comes-back ()
  (drgnx-wb-undefine-test--with
   (let ((theirs (lambda (&rest _) nil)) (mine (lambda (&rest _) nil)))
     (drgnx-wb-define-place 'theirs theirs)
     (drgnx-wb-undefine-test--setup 'test/p
       (drgnx-wb-define-place 'theirs mine)
       (drgnx-wb-define-place 'mine mine))
     (drgnx-wb-undefine-test--teardown 'test/p)
     (should (eq (alist-get 'theirs drgnx-rules--places) theirs))
     (should-not (assq 'mine drgnx-rules--places))
     (should (drgnx-wb-undefine-place 'theirs))
     (should-not (drgnx-wb-undefine-place 'theirs))
     (should-not (assq 'theirs drgnx-rules--places)))))

;;;; The change bus and the focus function

(ert-deftest drgnx-wb-undefine/subscription-is-recorded-once ()
  (drgnx-wb-undefine-test--with
   (let ((f (lambda (_) nil)) (g (lambda (_) nil)))
     (drgnx-signal-subscribe 'editor-changed g)                    ; subscribed before the module: not its own
     (drgnx-wb-undefine-test--setup 'test/b
       (drgnx-signal-subscribe 'editor-changed f)
       (drgnx-signal-subscribe 'editor-changed f)
       (drgnx-signal-subscribe 'editor-changed g)
       (drgnx-signal-subscribe 'buffer-set-changed f))
     (should (= 2 (length (alist-get 'test/b drgnx-modules--stacks))))
     (should (equal (alist-get 'editor-changed drgnx-signal--subscribers) (list g f)))
     (should-not (drgnx-wb-undefine-test--teardown 'test/b))
     (should (equal (alist-get 'editor-changed drgnx-signal--subscribers) (list g)))
     (should-not (alist-get 'buffer-set-changed drgnx-signal--subscribers))
     ;; Outside a setup nothing is recorded.
     (drgnx-signal-subscribe 'editor-changed f)
     (should-not (alist-get 'test/b drgnx-modules--stacks)))))

(ert-deftest drgnx-wb-undefine/focus-function-is-recorded ()
  (drgnx-wb-undefine-test--with
   (let ((after-focus-change-function after-focus-change-function)
         (drgnx-git-changed-functions nil))
     (cl-letf (((symbol-function 'drgnx-buffers--current-title) #'ignore))
       (drgnx-wb-undefine-test--setup 'test/f (drgnx-explorer-setup))
       (drgnx-wb-undefine-test--setup 'test/g (drgnx-buffers-setup)))
     (should (advice-function-member-p 'drgnx-explorer after-focus-change-function))
     (should (advice-function-member-p 'drgnx-buffers after-focus-change-function))
     (should-not (drgnx-wb-undefine-test--teardown 'test/f))
     (should-not (advice-function-member-p 'drgnx-explorer after-focus-change-function))
     (should (advice-function-member-p 'drgnx-buffers after-focus-change-function))     ; the other module's stays
     (should-not (alist-get 'explorer drgnx-wb--sections))
     (should-not (drgnx-wb-undefine-test--teardown 'test/g))
     (should-not (advice-function-member-p 'drgnx-buffers after-focus-change-function))
     (should-not drgnx-wb--sections)
     (should-not (apply #'append (mapcar #'cdr drgnx-signal--subscribers))))))

(provide 'wb-undefine-test)
;;; wb-undefine-test.el ends here
