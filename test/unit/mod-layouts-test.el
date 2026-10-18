;;; mod-layouts-test.el --- batch tests: layouts (Agent, Editor, Zen, Browser and your own) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(require 'drgnx-wb)
(require 'drgnx-area)
(require 'drgnx-groups)
(load (expand-file-name "modules/tools/drgnx-agents-ui" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-layouts" drgnx-dir) nil t)

(defconst drgnx-layouts-test--buffers
  '("*drgnx-layouts-explorer*" "*drgnx-layouts-code*" "*drgnx-layouts-a*" "*drgnx-layouts-b*" "*drgnx-layouts-proc*"
    "*drgnx Agents*" "*agent: alpha*" "*agent: beta*" "*drgnx: no agent*" "*drgnx-layouts-output*"))

(defmacro drgnx-layouts-test--with (&rest body)
  "BODY in a 200×60 frame with one editor window on *drgnx-layouts-code*, an Explorer section, the right dock's
Agents tab, no agent session, no layout state and a temp config dir (layouts.eld goes there)."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "drgnx-layouts" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" dir) process-environment))
          (drgnx-config--defs (copy-hash-table drgnx-config--defs))      ; layouts.eld's definition is this test's own
          (drgnx-config--state (copy-hash-table drgnx-config--state))
          (drgnx-config--notified (copy-hash-table drgnx-config--notified))
          (drgnx-wb--sections nil) (drgnx-signal--editor-window nil)
          (drgnx-wb--areas (copy-tree drgnx-wb--areas))
          (drgnx-agents--sessions nil)
          (drgnx-agents-ui--last (make-hash-table :test #'eq :weakness 'key))
          (drgnx-agents-ui--jobs-cache (cons 1.0e+INF nil))     ; no job directory is read
          (display-buffer-alist nil) (display-buffer-overriding-action '(nil))
          (size (cons (frame-width) (frame-height))))
     (drgnx-layouts--define-config)
     (set-frame-size nil 200 60)
     (delete-other-windows)
     (dolist (p '(drgnx-wb-view drgnx-wb-areas drgnx-wb-panel-px drgnx-wb-right-px drgnx-wb-dock-px
                                drgnx-layouts-state drgnx-layouts-current drgnx-layouts-previous drgnx-layouts-zen-return))
       (set-frame-parameter nil p nil))
     (drgnx-wb-define-section 'files :slot 0 :title "EXPLORER"
                              :buffer (lambda () (get-buffer-create "*drgnx-layouts-explorer*")))
     (drgnx-wb-define-tab 'right 'agents :title "Agents" :placeholder #'drgnx-agents-ui-list-buffer)
     (drgnx-rules-mode 1)
     (switch-to-buffer (get-buffer-create "*drgnx-layouts-code*"))
     (set-window-parameter nil 'drgnx-tabs nil)
     (unwind-protect (progn ,@body)
       (remove-hook 'window-size-change-functions #'drgnx-layouts--zen-resize)
       (drgnx-rules-mode -1)
       (drgnx-wb-hide-sidebar)
       (drgnx-wb-area-hide 'panel)
       (drgnx-wb-area-hide 'right)
       (delete-other-windows)
       (set-window-margins nil 0 0)
       (set-window-parameter nil 'drgnx-tabs nil)
       (set-window-parameter nil 'drgnx-layouts-pane nil)
       (dolist (p '(drgnx-wb-view drgnx-wb-areas drgnx-wb-panel-px drgnx-wb-right-px drgnx-wb-dock-px
                                  drgnx-layouts-state drgnx-layouts-current drgnx-layouts-previous drgnx-layouts-zen-return))
         (set-frame-parameter nil p nil))
       (set-frame-size nil (car size) (cdr size))
       (switch-to-buffer "*scratch*")
       (dolist (b drgnx-layouts-test--buffers)
         (when-let* ((buf (get-buffer b)))
           (when (get-buffer-process buf) (delete-process (get-buffer-process buf)))
           (kill-buffer buf)))
       (delete-directory dir t))))

(defun drgnx-layouts-test--code () (get-buffer "*drgnx-layouts-code*"))

(defun drgnx-layouts-test--margins (w)
  (let ((m (window-margins w))) (list (or (car m) 0) (or (cdr m) 0))))

(defun drgnx-layouts-test--output ()
  (with-current-buffer (get-buffer-create "*drgnx-layouts-output*")
    (special-mode)
    (current-buffer)))

(ert-deftest drgnx-layouts/agent-arranges-like-zed ()
  (drgnx-layouts-test--with
    (let ((alpha (drgnx-agents--make :id "a1" :name "alpha" :status 'idle))
          (beta (drgnx-agents--make :id "b1" :name "beta" :status 'idle)))
      (setq drgnx-agents--sessions (list beta alpha))           ; beta is newer, alpha acted last
      (puthash alpha (float-time) drgnx-agents-ui--last)
      (puthash beta (- (float-time) 600) drgnx-agents-ui--last)
      (drgnx-wb-area-show 'panel 'output (drgnx-layouts-test--output))
      (drgnx-layouts-apply 'agent)
      (should (eq (drgnx-layouts-current) 'agent))
      ;; the file tree on the left
      (should (drgnx-wb-sidebar-showing-p))
      (should (eq (drgnx-wb-sidebar-view) 'explorer))
      ;; one editor and the agent's chat side by side
      (let ((groups (drgnx-groups-list)))
        (should (= 2 (length groups)))
        (should (eq (window-buffer (car groups)) (drgnx-layouts-test--code)))
        (should (equal (buffer-name (window-buffer (cadr groups))) "*agent: alpha*"))
        (should (eq (buffer-local-value 'major-mode (window-buffer (cadr groups))) 'drgnx-agents-transcript-mode))
        (should (< (window-left-column (car groups)) (window-left-column (cadr groups))))
        (should (= (window-top-line (car groups)) (window-top-line (cadr groups))))
        (should (eq (selected-window) (car groups))))             ; focus stays in the editor
      ;; the agents list, narrow, on the right; no bottom panel until asked
      (let ((right (drgnx-wb-area-window 'right)))
        (should (window-live-p right))
        (should (eq (drgnx-wb-area-tab 'right) 'agents))
        (should (eq (window-buffer right) (get-buffer "*drgnx Agents*")))
        (should (< (window-total-width right) (window-total-width (car (drgnx-groups-list))))))
      (should-not (drgnx-wb-area-window 'panel)))))

(ert-deftest drgnx-layouts/agent-without-an-agent-says-so ()
  (drgnx-layouts-test--with
    (setq drgnx-agents--sessions (list (drgnx-agents--make :id "x" :name "gone" :status 'exited)))
    (drgnx-layouts-apply 'agent)
    (let ((pane (cadr (drgnx-groups-list))))
      (should (window-live-p pane))
      (with-current-buffer (window-buffer pane)
        (should (string-search "No agent yet — Agents: New" (buffer-string)))))))

(ert-deftest drgnx-layouts/switching-back-restores ()
  (drgnx-layouts-test--with
    (setq drgnx-agents--sessions (list (drgnx-agents--make :id "a1" :name "alpha" :status 'idle)))
    (drgnx-layouts-apply 'agent)
    ;; the user changes the Agent arrangement: a wider right dock, the panel on Output
    (let ((window-resize-pixelwise t))
      (window-resize (drgnx-wb-area-window 'right) 7 t nil t))
    (let ((right-px (window-pixel-width (drgnx-wb-area-window 'right))))
      (drgnx-wb-area-show 'panel 'output (drgnx-layouts-test--output))
      (drgnx-layouts-apply 'editor)
      ;; Editor: the tree, one group (the chat pane gone), no right dock, the panel as it was
      (should (drgnx-wb-sidebar-showing-p))
      (should (= 1 (length (drgnx-groups-list))))
      (should (eq (window-buffer (car (drgnx-groups-list))) (drgnx-layouts-test--code)))
      (should-not (drgnx-wb-area-window 'right))
      (should (eq (drgnx-wb-area-tab 'panel) 'output))
      (should (window-live-p (drgnx-wb-area-window 'panel)))
      ;; …and changes it: no panel, the sidebar hidden
      (drgnx-wb-area-hide 'panel)
      (drgnx-wb-hide-sidebar)
      (drgnx-layouts-apply 'agent)
      ;; Agent comes back as it was left, not fresh
      (should (= right-px (window-pixel-width (drgnx-wb-area-window 'right))))
      (should (window-live-p (drgnx-wb-area-window 'panel)))
      (should (drgnx-wb-sidebar-showing-p))
      (should (= 2 (length (drgnx-groups-list))))
      (should (equal (buffer-name (window-buffer (cadr (drgnx-groups-list)))) "*agent: alpha*"))
      (should (drgnx-signal-editor-window-p (selected-window)))
      (drgnx-layouts-apply 'editor)
      (should-not (drgnx-wb-sidebar-showing-p))
      (should-not (drgnx-wb-area-window 'panel))
      (should (= 1 (length (drgnx-groups-list)))))))

(ert-deftest drgnx-layouts/switching-loses-nothing ()
  (drgnx-layouts-test--with
    (setq drgnx-agents--sessions (list (drgnx-agents--make :id "a1" :name "alpha" :status 'idle)))
    (let* ((a (get-buffer-create "*drgnx-layouts-a*")) (b (get-buffer-create "*drgnx-layouts-b*"))
           (code (drgnx-layouts-test--code))
           (proc (make-process :name "drgnx-layouts-sleep" :buffer (get-buffer-create "*drgnx-layouts-proc*")
                               :command '("sleep" "60") :noquery t)))
      (with-current-buffer code (erase-buffer) (dotimes (i 200) (insert (format "line %d\n" i))))
      (drgnx-layouts-apply 'agent)
      (let ((editor (car (drgnx-groups-list))))
        (set-window-parameter editor 'drgnx-tabs (list a code b))
        (set-window-point editor (with-current-buffer code (goto-char (point-min)) (forward-line 120) (point))))
      (drgnx-wb-area-show 'panel 'terminal (process-buffer proc))
      (let ((pt (window-point (car (drgnx-groups-list))))
            (buffers (buffer-list)))
        (dolist (name '(editor zen browser agent editor zen agent))
          (drgnx-layouts-apply name)
          (should (eq (drgnx-layouts-current) name))
          (should (seq-every-p #'buffer-live-p buffers))
          (should (process-live-p proc)))
        (let ((groups (drgnx-groups-list)))
          (should (= 2 (length groups)))
          (should (equal (window-parameter (car groups) 'drgnx-tabs) (list a code b)))
          (should (eq (window-buffer (car groups)) code))
          (should (= pt (window-point (car groups))))
          (should (equal (buffer-name (window-buffer (cadr groups))) "*agent: alpha*")))
        (should (eq (window-buffer (drgnx-wb-area-window 'panel)) (process-buffer proc)))
        ;; one key cycles every layout and comes back
        (let ((names (drgnx-layouts-names)) (seen nil))
          (dotimes (_ (length names))
            (drgnx-layouts-next)
            (push (drgnx-layouts-current) seen))
          (should (eq (drgnx-layouts-current) 'agent))
          (should (equal (sort (mapcar #'symbol-name seen) #'string<) (sort (mapcar #'symbol-name names) #'string<))))))))

(ert-deftest drgnx-layouts/zen-centres-and-leaves ()
  (drgnx-layouts-test--with
    (drgnx-layouts-apply 'editor)
    (drgnx-wb-area-show 'panel 'output (drgnx-layouts-test--output))
    (drgnx-groups-split-right)
    (should (= 2 (length (drgnx-groups-list))))
    (drgnx-layouts-zen)
    (should (eq (drgnx-layouts-current) 'zen))
    (should (= 1 (length (window-list nil 'nomini))))
    (should-not (drgnx-wb-sidebar-showing-p))
    (should-not (drgnx-wb-area-window 'panel))
    (should-not (drgnx-wb-area-window 'right))
    (should (equal (drgnx-layouts-test--margins (selected-window)) '(50 50)))   ; 100 columns in 200
    (should (memq #'drgnx-layouts--zen-resize window-size-change-functions))
    (set-frame-size nil 160 60)
    (drgnx-layouts--zen-resize (selected-frame))
    (should (equal (drgnx-layouts-test--margins (selected-window)) '(30 30)))
    ;; the same key leaves: Editor as it was, no margins, no resize hook
    (drgnx-layouts-zen)
    (should (eq (drgnx-layouts-current) 'editor))
    (should (= 2 (length (drgnx-groups-list))))
    (should (drgnx-wb-sidebar-showing-p))
    (should (window-live-p (drgnx-wb-area-window 'panel)))
    (dolist (w (drgnx-groups-list)) (should (equal (drgnx-layouts-test--margins w) '(0 0))))
    (should-not (memq #'drgnx-layouts--zen-resize window-size-change-functions))))

(ert-deftest drgnx-layouts/zen-from-no-layout-gives-everything-back ()
  ;; No layout applied yet: Zen and back brings the groups, their tabs and the panel back as they were.
  (drgnx-layouts-test--with
    (let ((a (get-buffer-create "*drgnx-layouts-a*")) (b (get-buffer-create "*drgnx-layouts-b*"))
          (code (drgnx-layouts-test--code)))
      (drgnx-groups-split-right)
      (let ((groups (drgnx-groups-list)))
        (set-window-parameter (car groups) 'drgnx-tabs (list a code))
        (set-window-parameter (cadr groups) 'drgnx-tabs (list b code))
        (set-window-buffer (cadr groups) b))
      (drgnx-wb-area-show 'panel 'output (drgnx-layouts-test--output))
      (should-not (drgnx-layouts-current))
      (drgnx-layouts-zen)
      (should (eq (drgnx-layouts-current) 'zen))
      (should (= 1 (length (window-list nil 'nomini))))
      (drgnx-layouts-zen)
      (should-not (drgnx-layouts-current))
      (let ((groups (drgnx-groups-list)))
        (should (= 2 (length groups)))
        (should (equal (window-parameter (car groups) 'drgnx-tabs) (list a code)))
        (should (equal (window-parameter (cadr groups) 'drgnx-tabs) (list b code)))
        (should (eq (window-buffer (cadr groups)) b))
        (dolist (w groups) (should (equal (drgnx-layouts-test--margins w) '(0 0)))))
      (should (window-live-p (drgnx-wb-area-window 'panel)))
      (should (eq (drgnx-wb-area-tab 'panel) 'output))
      (should-not (drgnx-wb-sidebar-showing-p))
      (should-not (memq #'drgnx-layouts--zen-resize window-size-change-functions)))))

(ert-deftest drgnx-layouts/agent-zen-editor-builds-editor-from-before-zen ()
  ;; Editor's first visit, just out of Zen: built from the arrangement Zen was entered from, not Zen's one window.
  (drgnx-layouts-test--with
    (setq drgnx-agents--sessions (list (drgnx-agents--make :id "a1" :name "alpha" :status 'idle)))
    (let ((a (get-buffer-create "*drgnx-layouts-a*")) (code (drgnx-layouts-test--code)))
      (drgnx-layouts-apply 'agent)
      (set-window-parameter (car (drgnx-groups-list)) 'drgnx-tabs (list a code))
      (drgnx-groups-split-right)                              ; a group of the user's, besides the chat
      (select-window (car (drgnx-groups-list)))
      (should (= 3 (length (drgnx-groups-list))))
      (drgnx-wb-area-show 'panel 'output (drgnx-layouts-test--output))
      (drgnx-layouts-zen)
      (drgnx-layouts-apply 'editor)
      (let ((groups (drgnx-groups-list)))
        (should (= 2 (length groups)))                        ; the chat pane gone, the user's group kept
        (should (equal (window-parameter (car groups) 'drgnx-tabs) (list a code)))
        (should-not (seq-some (lambda (w) (window-parameter w 'drgnx-layouts-pane)) groups)))
      (should (window-live-p (drgnx-wb-area-window 'panel)))  ; Editor keeps the panel as it was before Zen
      (should (drgnx-wb-sidebar-showing-p)))))

(ert-deftest drgnx-layouts/user-layout-saved-and-applied ()
  (drgnx-layouts-test--with
    (drgnx-layouts-apply 'editor)
    (drgnx-wb-hide-sidebar)
    (drgnx-wb-area-show 'panel 'output (drgnx-layouts-test--output))
    (drgnx-groups-split-right)
    (drgnx-layouts-save "review")
    (should (eq (drgnx-layouts-current) 'review))
    (should (memq 'review (drgnx-layouts-names)))
    (let ((saved (alist-get 'review (with-temp-buffer
                                      (insert-file-contents (expand-file-name "layouts.eld" (drgnx-user-dir)))
                                      (read (current-buffer))))))
      (should (null (plist-get saved :left)))
      (should (eq (plist-get saved :panel) 'output))
      (should (null (plist-get saved :right))))
    (drgnx-layouts-apply 'agent)
    (drgnx-layouts-apply 'review)
    (should-not (drgnx-wb-sidebar-showing-p))
    (should (eq (drgnx-wb-area-tab 'panel) 'output))
    (should (window-live-p (drgnx-wb-area-window 'panel)))
    (should-not (drgnx-wb-area-window 'right))
    (should (= 2 (length (drgnx-groups-list))))
    ;; a new session: no remembered arrangement, the file builds it
    (drgnx-wb-area-hide 'panel)
    (delete-other-windows)
    (set-frame-parameter nil 'drgnx-layouts-state nil)
    (set-frame-parameter nil 'drgnx-layouts-current nil)
    (drgnx-layouts-apply 'review)
    (should-not (drgnx-wb-sidebar-showing-p))
    (should (window-live-p (drgnx-wb-area-window 'panel)))
    (should (= 2 (length (drgnx-groups-list))))
    ;; built-in names are taken
    (should-error (drgnx-layouts-save "zen") :type 'user-error)))

(ert-deftest drgnx-layouts/browser-falls-back-to-one-editor ()
  (drgnx-layouts-test--with
    (drgnx-groups-split-right)
    (drgnx-layouts-apply 'browser)
    (should (eq (drgnx-layouts-current) 'browser))
    (should-not (drgnx-wb-sidebar-showing-p))
    (should-not (drgnx-wb-area-window 'right))
    (should (= 2 (length (drgnx-groups-list))))))       ; until Task 6's shape: the groups as they are

;;;; Shapes and pane fillers: defined through the API, removed by the module's undo

(defmacro drgnx-layouts-shape-test--as-module (&rest body)
  "BODY as the setup of module `test/shape' (its registrations record their undos), then the undone stack's
problems.  The shape and filler registries are restored afterwards."
  (declare (indent 0))
  `(let ((drgnx-layouts-shapes (copy-sequence drgnx-layouts-shapes))
         (drgnx-layouts-pane-fillers (copy-sequence drgnx-layouts-pane-fillers))
         (drgnx-modules--stacks nil))
     (let ((drgnx-modules--current 'test/shape) (drgnx-modules--setup-load load-file-name))
       ,@body)))

(defun drgnx-layouts-shape-test--teardown ()
  "Undo what module `test/shape' registered; return the problems."
  (drgnx-modules--unwind 'test/shape))

(ert-deftest drgnx-layouts-shape/define-and-undefine-shape ()
  (drgnx-layouts-shape-test--as-module
    (should (eq (drgnx-layouts-define-shape 'test-shape #'ignore) 'test-shape))
    (should (eq (alist-get 'test-shape drgnx-layouts-shapes) #'ignore))
    (should (alist-get 'one drgnx-layouts-shapes))
    (should (= 1 (length (alist-get 'test/shape drgnx-modules--stacks))))
    ;; the public undefine removes it and leaves the built-ins
    (drgnx-layouts-undefine-shape 'test-shape)
    (should-not (assq 'test-shape drgnx-layouts-shapes))
    (should (alist-get 'one drgnx-layouts-shapes))
    ;; a second define; the module's undo removes it
    (drgnx-layouts-define-shape 'test-shape #'ignore)
    (should-not (drgnx-layouts-shape-test--teardown))
    (should-not (assq 'test-shape drgnx-layouts-shapes))
    (should (alist-get 'one drgnx-layouts-shapes))
    ;; a define that replaces an entry puts the previous one back
    (drgnx-layouts-define-shape 'one #'identity)
    (should (eq (alist-get 'one drgnx-layouts-shapes) #'identity))
    (drgnx-layouts-shape-test--teardown)
    (should (eq (alist-get 'one drgnx-layouts-shapes) 'drgnx-layouts--one))
    ;; the undo leaves an entry someone else has set since
    (drgnx-layouts-define-shape 'test-shape #'ignore)
    (drgnx-layouts-define-shape 'test-shape #'identity)
    (setf (alist-get 'test-shape drgnx-layouts-shapes) #'car)
    (drgnx-layouts-shape-test--teardown)
    (should (eq (alist-get 'test-shape drgnx-layouts-shapes) #'car))))

(ert-deftest drgnx-layouts-shape/an-undefined-shape-arranges-as-one ()
  (drgnx-layouts-test--with
    (drgnx-layouts-shape-test--as-module
      (let ((calls 0))
        (drgnx-layouts-define-shape 'editor+browser (lambda (_editor) (cl-incf calls)))
        (drgnx-layouts-apply 'browser)
        (should (= calls 1))
        (drgnx-layouts-shape-test--teardown)
        (drgnx-layouts-apply 'browser)
        (should (= calls 1))                        ; the shape is gone: the groups as they are
        (should (eq (drgnx-layouts-current) 'browser))))))   ; the layout, its intent, stays

(ert-deftest drgnx-layouts-shape/undefine-pane-keeps-shown-windows ()
  (drgnx-layouts-test--with
    (drgnx-layouts-shape-test--as-module
      (let* ((editor (selected-window)) (pane (drgnx-groups--split 'right)) (filled nil))
        (drgnx-layouts--mark-pane (cons pane 'test-kind))
        (drgnx-layouts-define-pane 'test-kind (lambda (w) (push w filled)))
        (should (equal filled (list pane)))         ; a pane already shown is filled when the kind is defined
        (should (alist-get 'test-kind drgnx-layouts-pane-fillers))
        (drgnx-layouts-undefine-pane 'test-kind)
        (should-not (assq 'test-kind drgnx-layouts-pane-fillers))
        (should (alist-get 'agent drgnx-layouts-pane-fillers))
        (should (window-live-p pane))                ; the window and its mark stay until the next layout
        (should (eq (window-parameter pane 'drgnx-layouts-pane) 'test-kind))
        (should (window-live-p editor))
        ;; the module's undo does the same
        (drgnx-layouts-define-pane 'test-kind #'ignore)
        (should-not (drgnx-layouts-shape-test--teardown))
        (should-not (assq 'test-kind drgnx-layouts-pane-fillers))
        (should (window-live-p pane))
        ;; turned on again: the pane that was shown is filled again
        (setq filled nil)
        (drgnx-layouts-define-pane 'test-kind (lambda (w) (push w filled)))
        (should (equal filled (list pane)))
        ;; the next layout removes the pane, whatever its kind
        (drgnx-layouts-apply 'editor)
        (should-not (window-live-p pane))))))

(ert-deftest drgnx-layouts-shape/a-pane-define-puts-the-previous-filler-back ()
  (drgnx-layouts-shape-test--as-module
    (let ((agent (alist-get 'agent drgnx-layouts-pane-fillers)))
      (drgnx-layouts-define-pane 'agent #'ignore)
      (should (eq (alist-get 'agent drgnx-layouts-pane-fillers) #'ignore))
      (drgnx-layouts-shape-test--teardown)
      (should (eq (alist-get 'agent drgnx-layouts-pane-fillers) agent))
      ;; an entry someone else set since stays
      (drgnx-layouts-define-pane 'agent #'ignore)
      (setf (alist-get 'agent drgnx-layouts-pane-fillers) #'identity)
      (drgnx-layouts-shape-test--teardown)
      (should (eq (alist-get 'agent drgnx-layouts-pane-fillers) #'identity)))))

(ert-deftest drgnx-layouts-shape/browser-registers-through-the-api ()
  ;; no module writes the shape registry itself
  (let ((hits nil))
    (dolist (f (directory-files-recursively (expand-file-name "modules" drgnx-dir) "\\.el\\'"))
      (with-temp-buffer
        (insert-file-contents f)
        (goto-char (point-min))
        (while (re-search-forward "(setf (alist-get [^\n]*drgnx-layouts-shapes" nil t)
          (unless (save-excursion (beginning-of-line) (looking-at-p "[ \t]*;")) (push f hits)))))
    (should-not hits))
  ;; and the browser's registration is undone with the module
  (drgnx-layouts-shape-test--as-module
    (load (expand-file-name "modules/tools/drgnx-browser" drgnx-dir) nil t)
    (drgnx-browser--register-shape)
    (should (eq (alist-get 'editor+browser drgnx-layouts-shapes) 'drgnx-browser--shape))
    (should (eq (alist-get 'browser drgnx-layouts-pane-fillers) 'drgnx-browser--fill))
    (should-not (drgnx-layouts-shape-test--teardown))
    (should-not (assq 'editor+browser drgnx-layouts-shapes))
    (should-not (assq 'browser drgnx-layouts-pane-fillers))))

;;; mod-layouts-test.el ends here

(ert-deftest drgnx-layouts/the-fixture-keeps-the-frame-size ()
  ;; The fixture gives the frame back its size: a frame one line shorter after each test left later docks no room.
  (let ((size (cons (frame-width) (frame-height))))
    (drgnx-layouts-test--with (ignore))
    (read-event nil nil 0.01)                           ; a terminal frame takes its new size at the next wait
    (should (equal (cons (frame-width) (frame-height)) size))))
