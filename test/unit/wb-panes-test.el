;;; wb-panes-test.el --- batch tests: pane kinds, forwarded to the docks before the grid -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-panes)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)

(defmacro drgnx-panes-test--with (&rest body)
  "BODY with fresh pane, section, area and rule tables, one editor window and the docks hidden."
  `(let ((drgnx-pane--kinds nil) (drgnx-pane-backend 'areas) (drgnx-wb--sections nil)
         (drgnx-wb--areas (copy-tree drgnx-wb--areas)) (drgnx-rules--table (copy-sequence drgnx-rules--table))
         (drgnx-wb-unrouted nil)
         (display-buffer-alist nil) (display-buffer-overriding-action '(nil)))
     (delete-other-windows)
     (set-frame-parameter nil 'drgnx-wb-areas nil)
     (set-frame-parameter nil 'drgnx-wb-view nil)
     (set-frame-parameter nil 'drgnx-intent-by nil)
     (drgnx-rules-mode 1)
     (unwind-protect (progn ,@body)
       (drgnx-rules-mode -1)
       (drgnx-wb-area-hide 'panel)
       (drgnx-wb-area-hide 'right)
       (drgnx-wb-hide-sidebar)
       (delete-other-windows)
       (dolist (b (buffer-list)) (when (string-prefix-p " *drgnx pane-" (buffer-name b)) (kill-buffer b)))
       (dolist (b '("*pane-notes*")) (when (get-buffer b) (kill-buffer b))))))

(defun drgnx-panes-test--buffer (name)
  (lambda () (with-current-buffer (get-buffer-create name t) (special-mode) (current-buffer))))

(ert-deftest drgnx-panes/define-and-read-back ()
  (drgnx-panes-test--with
   (should (eq 'pane-a (drgnx-pane-define-kind 'pane-a :title "A" :home 'bottom :size 9 :stack 'pane-b)))
   (drgnx-pane-define-kind 'pane-b :title "B" :home 'right)
   (drgnx-pane-define-kind 'pane-c :title "C" :home 'left :slot 3 :view 'search :height 0.4)
   (let ((spec (drgnx-pane-kind 'pane-a)))
     (should (equal "A" (plist-get spec :title)))
     (should (eq 'bottom (plist-get spec :home)))
     (should (= 9 (plist-get spec :size)))
     (should (eq 'pane-b (plist-get spec :stack))))
   (should-not (drgnx-pane-kind 'pane-none))
   (should (equal '(pane-a pane-b pane-c) (drgnx-pane-kinds)))
   (should (equal '(pane-b) (drgnx-pane-kinds 'right)))
   (should (equal '(pane-c) (drgnx-pane-kinds 'left)))
   (should-not (drgnx-pane-kinds 'editor))
   (should-error (drgnx-pane-define-kind 'pane-x :home 'nowhere) :type 'user-error)
   (should-error (drgnx-pane-show 'pane-none) :type 'user-error)))

(ert-deftest drgnx-panes/homes-forward-to-areas ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-term :title "Term" :home 'bottom
                           :placeholder (drgnx-panes-test--buffer " *drgnx pane-term*"))
   (drgnx-pane-define-kind 'pane-chat :title "Chat" :home 'right)
   (drgnx-pane-define-kind 'pane-notes :home 'editor :buffer "*pane-notes*")
   (should (assq 'pane-term (plist-get (alist-get 'panel drgnx-wb--areas) :tabs)))
   (should-not (assq 'pane-term (plist-get (alist-get 'right drgnx-wb--areas) :tabs)))
   (should (assq 'pane-chat (plist-get (alist-get 'right drgnx-wb--areas) :tabs)))
   (should (equal "Term" (plist-get (alist-get 'pane-term (plist-get (alist-get 'panel drgnx-wb--areas) :tabs)) :title)))
   ;; the editor kind became a rule sending its buffer to the editor
   (should (eq 'editor (car (drgnx-wb-rule-for "*pane-notes*"))))
   (should-not (eq 'editor (car (drgnx-wb-rule-for "*pane-notes-other*"))))))

(ert-deftest drgnx-panes/left-forwards-to-a-section ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-tree :title "TREE" :home 'left :slot 2 :height 0.5 :view 'search
                           :buffer (drgnx-panes-test--buffer " *drgnx pane-tree*"))
   (let ((section (alist-get 'pane-tree drgnx-wb--sections)))
     (should (= 2 (plist-get section :slot)))
     (should (equal "TREE" (plist-get section :title)))
     (should (= 0.5 (plist-get section :height)))
     (should (eq 'search (plist-get section :view)))
     (should (buffer-live-p (funcall (plist-get section :buffer)))))
   (let ((editor (selected-window)) (w (drgnx-pane-show 'pane-tree)))
     (should (eq w (drgnx-wb-section-window 'pane-tree)))
     (should (eq w (drgnx-pane-window 'pane-tree)))
     (should (eq (window-buffer w) (get-buffer " *drgnx pane-tree*")))
     (should (eq (selected-window) editor)))))

(ert-deftest drgnx-panes/show-forwards-and-never-selects ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-term :home 'bottom :placeholder (drgnx-panes-test--buffer " *drgnx pane-term*"))
   (drgnx-pane-define-kind 'pane-chat :home 'right :placeholder (drgnx-panes-test--buffer " *drgnx pane-chat*"))
   (drgnx-pane-define-kind 'pane-tree :home 'left :buffer (drgnx-panes-test--buffer " *drgnx pane-tree*"))
   (drgnx-pane-define-kind 'pane-notes :home 'editor :buffer "*pane-notes*")
   (let ((editor (selected-window)) (notes (get-buffer-create "*pane-notes*")))
     (dolist (kind '(pane-term pane-chat pane-tree))
       (let ((w (drgnx-pane-show kind)))
         (should (window-live-p w))
         (should (eq w (drgnx-pane-window kind)))
         (should (eq (selected-window) editor))))
     (should (eq (window-buffer (drgnx-pane-window 'pane-term)) (get-buffer " *drgnx pane-term*")))
     (should (eq (drgnx-wb-area-window 'right) (drgnx-pane-window 'pane-chat)))
     ;; a given buffer goes into the pane; an editor kind shows in the editor window
     (let ((b (get-buffer-create "*pane-notes*")))
       (drgnx-pane-show 'pane-term :buffer b)
       (should (eq (window-buffer (drgnx-pane-window 'pane-term)) b))
       (should (eq (selected-window) editor)))
     (with-current-buffer notes (erase-buffer))
     (should (eq editor (drgnx-pane-show 'pane-notes :buffer notes)))
     (should (eq (window-buffer editor) notes))
     (should (eq (selected-window) editor)))))

(ert-deftest drgnx-panes/show-keeps-the-selected-window-in-a-pane ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-term :home 'bottom :placeholder (drgnx-panes-test--buffer " *drgnx pane-term*"))
   (drgnx-pane-define-kind 'pane-chat :home 'right :placeholder (drgnx-panes-test--buffer " *drgnx pane-chat*"))
   (let ((term (drgnx-pane-show 'pane-term)))
     (select-window term)
     (drgnx-pane-show 'pane-chat)
     (should (eq (selected-window) term)))))

(ert-deftest drgnx-panes/focus-selects ()
  (drgnx-panes-test--with
   (let (focused)
     (drgnx-pane-define-kind 'pane-term :home 'bottom :placeholder (drgnx-panes-test--buffer " *drgnx pane-term*")
                             :on-focus (lambda (w) (push w focused)))
     (drgnx-pane-define-kind 'pane-tree :home 'left :buffer (drgnx-panes-test--buffer " *drgnx pane-tree*"))
     (drgnx-pane-define-kind 'pane-notes :home 'editor :buffer "*pane-notes*")
     (let ((w (drgnx-pane-focus 'pane-term)))
       (should (eq (selected-window) w))
       (should (eq w (drgnx-pane-window 'pane-term)))
       (should (equal (list w) focused)))
     (let ((w (drgnx-pane-focus 'pane-tree)))
       (should (eq (selected-window) w))
       (should (eq w (drgnx-wb-section-window 'pane-tree))))
     (let ((editor (drgnx-wb-editor-window)))
       (drgnx-pane-focus 'pane-notes)
       (should (eq (selected-window) editor)))
     (let ((editor (drgnx-wb-editor-window)))
       (drgnx-pane-show 'pane-term :select t)
       (should (eq (selected-window) (drgnx-pane-window 'pane-term)))
       (select-window editor)
       (drgnx-pane-show 'pane-tree :select t)
       (should (eq (selected-window) (drgnx-pane-window 'pane-tree)))))))

(ert-deftest drgnx-panes/hide-and-toggle ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-term :home 'bottom :placeholder (drgnx-panes-test--buffer " *drgnx pane-term*"))
   (drgnx-pane-define-kind 'pane-chat :home 'bottom :placeholder (drgnx-panes-test--buffer " *drgnx pane-chat*"))
   (let ((editor (selected-window)))
     (drgnx-pane-show 'pane-term)
     (should-not (drgnx-pane-window 'pane-chat))          ; the area shows another tab
     (drgnx-pane-hide 'pane-chat)
     (should (drgnx-pane-window 'pane-term))              ; hiding a tab that is not shown changes nothing
     (drgnx-pane-toggle 'pane-term)
     (should-not (drgnx-pane-window 'pane-term))
     (should-not (drgnx-wb-area-window 'panel))
     (drgnx-pane-toggle 'pane-term)
     (should (drgnx-pane-window 'pane-term))
     (should (eq (selected-window) editor)))))

(ert-deftest drgnx-panes/redefining-replaces ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-term :title "One" :home 'bottom :size 5)
   (drgnx-pane-define-kind 'pane-chat :home 'bottom)
   (drgnx-pane-define-kind 'pane-term :title "Two" :home 'bottom)
   (let ((spec (drgnx-pane-kind 'pane-term)))
     (should (equal "Two" (plist-get spec :title)))
     (should-not (plist-get spec :size)))
   (should (equal '(pane-term pane-chat) (drgnx-pane-kinds)))             ; same place in the order
   (let ((tabs (plist-get (alist-get 'panel drgnx-wb--areas) :tabs)))
     (should (= 1 (seq-count (lambda (c) (eq (car c) 'pane-term)) tabs)))
     (should (equal "Two" (plist-get (alist-get 'pane-term tabs) :title))))
   ;; moving a kind to another home leaves it in one kind list
   (drgnx-pane-define-kind 'pane-term :title "Two" :home 'right)
   (should (equal '(pane-term) (drgnx-pane-kinds 'right)))
   (should-not (drgnx-pane-kinds 'editor))
   (should-not (assq 'pane-term (plist-get (alist-get 'panel drgnx-wb--areas) :tabs)))
   (should (assq 'pane-term (plist-get (alist-get 'right drgnx-wb--areas) :tabs)))
   ;; a left kind moves to another home: its section goes
   (drgnx-pane-define-kind 'pane-tree :home 'left :buffer (drgnx-panes-test--buffer " *drgnx pane-tree*"))
   (should (assq 'pane-tree drgnx-wb--sections))
   (drgnx-pane-define-kind 'pane-tree :home 'bottom)
   (should-not (assq 'pane-tree drgnx-wb--sections))
   (should (assq 'pane-tree (plist-get (alist-get 'panel drgnx-wb--areas) :tabs)))
   (drgnx-pane-define-kind 'pane-tree :home 'left :buffer (drgnx-panes-test--buffer " *drgnx pane-tree*"))
   (should (assq 'pane-tree drgnx-wb--sections))
   (should-not (assq 'pane-tree (plist-get (alist-get 'panel drgnx-wb--areas) :tabs)))))

(ert-deftest drgnx-panes/an-editor-kind-shows-its-named-buffer ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-notes :home 'editor :buffer "*pane-notes*")
   (let* ((editor (selected-window)) (w (drgnx-pane-show 'pane-notes)))
     (should (eq w editor))
     (should (equal "*pane-notes*" (buffer-name (window-buffer w))))
     (should (eq w (drgnx-pane-window 'pane-notes))))
   ;; a buffer object works the same
   (let ((b (get-buffer-create "*pane-notes-b*")))
     (unwind-protect
         (progn (drgnx-pane-define-kind 'pane-obj :home 'editor :buffer b)
                (should (eq b (window-buffer (drgnx-pane-show 'pane-obj)))))
       (kill-buffer b)))))

(ert-deftest drgnx-panes/an-editor-kind-window-follows-the-last-buffer-shown ()
  (drgnx-panes-test--with
   (let ((made (lambda () (get-buffer-create "*pane-notes*"))) (other (generate-new-buffer "*pane-other*")))
     (unwind-protect
         (progn
           (drgnx-pane-define-kind 'pane-fn :home 'editor :buffer made)
           (should-not (drgnx-pane-window 'pane-fn))
           (let ((w (drgnx-pane-show 'pane-fn)))
             (should (eq w (drgnx-pane-window 'pane-fn)))
             (should (eq w (drgnx-pane-window 'pane-fn (selected-frame)))))
           (let ((w (drgnx-pane-show 'pane-fn :buffer other)))     ; a buffer passed to show
             (should (eq (window-buffer w) other))
             (should (eq w (drgnx-pane-window 'pane-fn))))
           (switch-to-buffer "*scratch*")
           (should-not (drgnx-pane-window 'pane-fn))
           (drgnx-pane-focus 'pane-fn)
           (should (eq (selected-window) (drgnx-pane-window 'pane-fn)))
           (drgnx-pane-toggle 'pane-fn)                            ; an editor kind has no hide
           (should (drgnx-pane-window 'pane-fn)))
       (kill-buffer other)))))

(ert-deftest drgnx-panes/redefining-an-editor-kind-drops-its-place-rule ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-notes :home 'editor :buffer "*pane-notes*")
   (should (eq 'editor (car (drgnx-wb-rule-for "*pane-notes*"))))
   (drgnx-pane-define-kind 'pane-notes :home 'editor :buffer "*pane-notes-2*")
   (should-not (eq 'editor (car (drgnx-wb-rule-for "*pane-notes*"))))
   (should (eq 'editor (car (drgnx-wb-rule-for "*pane-notes-2*"))))
   (drgnx-pane-define-kind 'pane-notes :home 'bottom)
   (should-not (eq 'editor (car (drgnx-wb-rule-for "*pane-notes-2*"))))))

(ert-deftest drgnx-panes/frame-parameters-stay-readable-after-an-editor-show ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-notes :home 'editor :buffer "*pane-notes*")
   (drgnx-pane-show 'pane-notes)
   (should (drgnx-pane-window 'pane-notes))
   (let* ((drgnx-params (seq-filter (lambda (p) (string-prefix-p "drgnx" (symbol-name (car p))))
                                    (frame-parameters)))
          (text (prin1-to-string drgnx-params)))
     (should-not (string-match-p "#<" text))
     (should (equal drgnx-params (read text))))
   (should-not (string-match-p "pane-notes" (prin1-to-string (frame-parameters))))))

(ert-deftest drgnx-panes/a-shared-place-rule-stays-while-another-editor-kind-uses-it ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-one :home 'editor :buffer "*pane-notes*")
   (drgnx-pane-define-kind 'pane-two :home 'editor :buffer "*pane-notes*")
   (drgnx-pane-define-kind 'pane-one :home 'editor :buffer "*pane-other*")
   (should (eq 'editor (car (drgnx-wb-rule-for "*pane-notes*"))))      ; pane-two still has it
   (should (eq 'editor (car (drgnx-wb-rule-for "*pane-other*"))))
   (drgnx-pane-define-kind 'pane-two :home 'bottom)
   (should-not (eq 'editor (car (drgnx-wb-rule-for "*pane-notes*"))))))

(ert-deftest drgnx-panes/showing-in-the-same-view-from-the-dock-selects-nothing ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-tree :home 'left :slot 0 :buffer (drgnx-panes-test--buffer " *drgnx pane-tree*"))
   (drgnx-pane-define-kind 'pane-tabs :home 'left :slot 1 :buffer (drgnx-panes-test--buffer " *drgnx pane-tabs*"))
   (let ((editor (selected-window)))
     (select-window (drgnx-pane-show 'pane-tree))
     (let ((dock (selected-window)) (order (buffer-list)))
       (drgnx-pane-show 'pane-tabs)
       (should (eq (selected-window) dock))
       (should (equal order (buffer-list)))
       (should-not (eq dock editor))))))

(ert-deftest drgnx-panes/hiding-a-left-kind-of-another-view-does-nothing ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-tree :home 'left :slot 0 :buffer (drgnx-panes-test--buffer " *drgnx pane-tree*"))
   (drgnx-pane-define-kind 'pane-find :home 'left :view 'search :slot 0
                           :buffer (drgnx-panes-test--buffer " *drgnx pane-find*"))
   (let ((w (drgnx-pane-show 'pane-tree)))
     (drgnx-pane-hide 'pane-find)              ; not in the shown view
     (should (eq w (drgnx-pane-window 'pane-tree)))
     (should-not (drgnx-pane-window 'pane-find))
     (drgnx-pane-hide 'pane-tree)
     (should-not (drgnx-pane-window 'pane-tree))
     (should-not (drgnx-wb-sidebar-showing-p))
     (drgnx-pane-hide 'pane-tree))))           ; hidden already: nothing

(ert-deftest drgnx-panes/a-view-swap-from-inside-the-dock-keeps-focus-out-of-it ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-tree :home 'left :slot 0 :buffer (drgnx-panes-test--buffer " *drgnx pane-tree*"))
   (drgnx-pane-define-kind 'pane-find :home 'left :view 'search :slot 0
                           :buffer (drgnx-panes-test--buffer " *drgnx pane-find*"))
   (let ((editor (selected-window)))
     (select-window (drgnx-pane-show 'pane-tree))
     (let ((w (drgnx-pane-show 'pane-find)))             ; the view changes, the old dock window dies
       (should (eq w (drgnx-pane-window 'pane-find)))
       (should-not (eq (selected-window) w))
       (should (eq (selected-window) editor)))
     ;; the same view: the dock window stays selected
     (select-window (drgnx-pane-window 'pane-find))
     (let ((dock (selected-window)))
       (drgnx-pane-show 'pane-find)
       (should (eq (selected-window) dock)))
     ;; with :select it does move
     (select-window editor)
     (drgnx-pane-show 'pane-tree :select t)
     (should (eq (selected-window) (drgnx-pane-window 'pane-tree))))))

(ert-deftest drgnx-panes/a-left-kind-s-on-show-runs-on-every-show ()
  (drgnx-panes-test--with
   (let (shown)
     (drgnx-pane-define-kind 'pane-tree :home 'left :slot 0 :on-show (lambda (w) (push w shown))
                             :buffer (drgnx-panes-test--buffer " *drgnx pane-tree*"))
     (drgnx-pane-show 'pane-tree)                        ; the dock appears: once
     (should (= 1 (length shown)))
     (drgnx-pane-show 'pane-tree)                        ; already shown: once more
     (should (= 2 (length shown)))
     (should (eq (car shown) (drgnx-pane-window 'pane-tree))))))

(ert-deftest drgnx-panes/the-minibuffer-window-stays-selected ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-term :home 'bottom :placeholder (drgnx-panes-test--buffer " *drgnx pane-term*"))
   (drgnx-pane-define-kind 'pane-tree :home 'left :buffer (drgnx-panes-test--buffer " *drgnx pane-tree*"))
   (let ((editor (selected-window)) (mini (minibuffer-window)))
     (unwind-protect
         (progn
           (select-window mini)
           (drgnx-pane-show 'pane-term)
           (drgnx-pane-show 'pane-tree)
           (should (eq (selected-window) mini)))
       (select-window editor)))))

(ert-deftest drgnx-panes/show-from-a-timer-or-another-buffer-keeps-focus ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-term :home 'bottom :placeholder (drgnx-panes-test--buffer " *drgnx pane-term*"))
   (let ((editor (selected-window)) (ran nil))
     (with-temp-buffer
       (drgnx-pane-show 'pane-term)
       (should (eq (selected-window) editor)))
     (drgnx-pane-hide 'pane-term)
     (run-with-timer 0 nil (lambda () (drgnx-pane-show 'pane-term) (setq ran t)))
     (sleep-for 0.2)
     (should ran)
     (should (drgnx-pane-window 'pane-term))
     (should (eq (selected-window) editor)))))

(ert-deftest drgnx-panes/showing-again-moves-no-window ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-term :home 'bottom :placeholder (drgnx-panes-test--buffer " *drgnx pane-term*"))
   (drgnx-pane-define-kind 'pane-chat :home 'right :placeholder (drgnx-panes-test--buffer " *drgnx pane-chat*"))
   (drgnx-pane-define-kind 'pane-tree :home 'left :buffer (drgnx-panes-test--buffer " *drgnx pane-tree*"))
   (let ((kinds '(pane-term pane-chat pane-tree)))
     (dolist (k kinds) (drgnx-pane-show k))
     (let ((edges (mapcar (lambda (w) (cons w (window-pixel-edges w))) (window-list nil 'nomini))))
       (dolist (k kinds) (drgnx-pane-show k))
       (should (equal edges (mapcar (lambda (w) (cons w (window-pixel-edges w))) (window-list nil 'nomini))))))))

(ert-deftest drgnx-panes/a-failing-define-leaves-the-kinds-alone ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-term :home 'bottom :title "One")
   (let ((drgnx-pane-backend 'nope))
     (should-error (drgnx-pane-define-kind 'pane-term :home 'bottom :title "Two"))
     (should-error (drgnx-pane-define-kind 'pane-new :home 'bottom)))
   (should (equal "One" (plist-get (drgnx-pane-kind 'pane-term) :title)))
   (should-not (drgnx-pane-kind 'pane-new))))

(ert-deftest drgnx-panes/an-unknown-backend-is-an-error ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-term :home 'bottom)
   (let ((drgnx-pane-backend 'nope))
     (should-error (drgnx-pane-show 'pane-term)))))

;;;; Writes: who asked, resize, move and stack

(defun drgnx-panes-test--no-sizes ()
  (dolist (p '(drgnx-wb-dock-px drgnx-wb-panel-px drgnx-wb-right-px)) (set-frame-parameter nil p nil)))

(ert-deftest drgnx-panes/resize-dock-and-areas-pixelwise ()
  (drgnx-panes-test--with
   (drgnx-panes-test--no-sizes)
   (drgnx-pane-define-kind 'pane-term :home 'bottom :placeholder (drgnx-panes-test--buffer " *drgnx pane-term*"))
   (drgnx-pane-define-kind 'pane-chat :home 'right :placeholder (drgnx-panes-test--buffer " *drgnx pane-chat*"))
   (drgnx-pane-define-kind 'pane-tree :home 'left :slot 0 :buffer (drgnx-panes-test--buffer " *drgnx pane-tree*"))
   (drgnx-pane-define-kind 'pane-list :home 'left :slot 1 :buffer (drgnx-panes-test--buffer " *drgnx pane-list*"))
   (drgnx-pane-define-kind 'pane-notes :home 'editor :buffer "*pane-notes*")
   (dolist (k '(pane-term pane-chat pane-tree)) (drgnx-pane-show k))
   (let ((w (drgnx-pane-resize 'pane-tree 21 :by 'user)))
     (should (eq w (drgnx-pane-window 'pane-tree)))
     (should (= 21 (window-pixel-width w)))
     (should (= 21 (window-pixel-width (drgnx-pane-window 'pane-list)))) ; the dock is one column
     (should (equal '(:px 21 :by user) (drgnx-state-intent nil :sizes 'left))))
   (let ((w (drgnx-pane-resize 'pane-term 7 :by 'user)))
     (should (eq w (drgnx-pane-window 'pane-term)))
     (should (= 7 (window-pixel-height w)))
     (should (equal '(:px 7 :by user) (drgnx-state-intent nil :sizes 'bottom))))
   (let ((w (drgnx-pane-resize 'pane-chat 23 :by 'user)))
     (should (= 23 (window-pixel-width w)))
     (should (equal '(:px 23 :by user) (drgnx-state-intent nil :sizes 'right))))
   (should (= 21 (window-pixel-width (drgnx-pane-window 'pane-tree))))
   ;; the size stays across hiding and showing
   (drgnx-pane-hide 'pane-term)
   (should (= 7 (window-pixel-height (drgnx-pane-show 'pane-term))))
   ;; a hidden pane: the size it comes back at
   (drgnx-pane-hide 'pane-chat)
   (should-not (drgnx-pane-resize 'pane-chat 26 :by 'user))
   (should (= 26 (window-pixel-width (drgnx-pane-show 'pane-chat))))
   ;; an editor kind has no size of its own
   (should-not (drgnx-pane-resize 'pane-notes 30))
   (should-error (drgnx-pane-resize 'pane-term 0))))

(ert-deftest drgnx-panes/by-defaults-to-user-in-a-command-auto-outside ()
  (drgnx-test-with-state
    (drgnx-panes-test--with
     (drgnx-panes-test--no-sizes)
     (let (seen)
       (drgnx-pane-define-kind 'pane-term :home 'bottom :placeholder (drgnx-panes-test--buffer " *drgnx pane-term*")
                               :on-show (lambda (_) (push (plist-get drgnx-state--writing :by) seen)))
       (drgnx-pane-show 'pane-term)
       (drgnx-pane-resize 'pane-term 6)
       (should (equal '(:px 6 :by auto) (drgnx-state-intent nil :sizes 'bottom)))
       (drgnx-state--pre-command)                         ; a command runs
       (drgnx-pane-show 'pane-term)
       (drgnx-pane-resize 'pane-term 8)
       (drgnx-state--post-command)
       (should (equal '(:px 8 :by user) (drgnx-state-intent nil :sizes 'bottom)))
       (should (equal '(user auto) seen))
       ;; outside a command again: `auto', which leaves the size you chose
       (drgnx-pane-resize 'pane-term 5)
       (should (equal '(:px 8 :by user) (drgnx-state-intent nil :sizes 'bottom)))))))

(ert-deftest drgnx-panes/move-and-stack-need-the-grid ()
  (drgnx-panes-test--with
   (drgnx-pane-define-kind 'pane-term :home 'bottom)
   (drgnx-pane-define-kind 'pane-chat :home 'right)
   (should (equal '(user-error "Moving panes needs the grid")
                  (should-error (drgnx-pane-move 'pane-term 'pane-chat 'left) :type 'user-error)))
   (should (equal '(user-error "Moving panes needs the grid")
                  (should-error (drgnx-pane-stack 'pane-term 'pane-chat) :type 'user-error)))
   (should-error (drgnx-pane-move 'pane-none 'pane-chat 'left) :type 'user-error)
   ;; a backend that has them is called, inside a write
   (let ((drgnx-pane--backends
          (cons (list 'st-fake
                      :move (lambda (kind target zone) (list kind target zone (plist-get drgnx-state--writing :by)))
                      :stack (lambda (kind onto) (list kind onto (plist-get drgnx-state--writing :by))))
                drgnx-pane--backends))
         (drgnx-pane-backend 'st-fake))
     (should (equal '(pane-term pane-chat left layout) (drgnx-pane-move 'pane-term 'pane-chat 'left :by 'layout)))
     (should (equal '(pane-term pane-chat user) (drgnx-pane-stack 'pane-term 'pane-chat :by 'user))))))

(ert-deftest drgnx-panes/show-hide-focus-toggle-take-by ()
  (drgnx-panes-test--with
   (drgnx-panes-test--no-sizes)
   (let ((seen nil) (hide (symbol-function 'drgnx-wb-area-hide)))
     (drgnx-pane-define-kind 'pane-term :home 'bottom :placeholder (drgnx-panes-test--buffer " *drgnx pane-term*")
                             :on-show (lambda (_) (push (list 'show (plist-get drgnx-state--writing :by)) seen)))
     (cl-letf (((symbol-function 'drgnx-wb-area-hide)
                (lambda (area) (push (list 'hide (plist-get drgnx-state--writing :by)) seen) (funcall hide area))))
       (drgnx-pane-show 'pane-term :by 'layout)
       (drgnx-pane-hide 'pane-term :by 'teardown)
       (drgnx-pane-focus 'pane-term :by 'restore)
       (drgnx-pane-toggle 'pane-term :by 'other)          ; shown: hides
       (drgnx-pane-toggle 'pane-term :by 'user))          ; hidden: shows
     (should (equal '((show layout) (hide teardown) (show restore) (hide other) (show user)) (reverse seen)))
     ;; the front tab is intent, with who asked; a hide noted the size as `auto', whoever asked for it
     (should (eq 'pane-term (drgnx-state-intent nil :front 'panel)))
     (should (eq 'user (cdr (assoc '(:front . panel) (frame-parameter nil 'drgnx-intent-by)))))
     (should (eq 'auto (plist-get (drgnx-state-intent nil :sizes 'bottom) :by))))))

(provide 'wb-panes-test)
;;; wb-panes-test.el ends here
