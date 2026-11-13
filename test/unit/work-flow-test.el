;;; work-flow-test.el --- batch tests: the Flow lens's Lisp side on fixture feeds -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; No hub and no Sjá: the lens's words, what the Flow asks the hub, a task's evidence (as `orch/evidence' answers it)
;; drawn as lines, and its keys in every profile.  The rows themselves are the hub's (work::trail::flow, tested there).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-map" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-flow" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(ert-deftest drgnx-work-flow/the-lens-names-the-flow ()
  "The lens bar is the Work space's tab (Work · its name), then Map · Board · Timeline · Flow with the current one
marked, then the lens's own keys as chips with their key badges."
  (let ((s (drgnx-work-lens-string 'flow "drgnx" '(("evidence" . "e") ("rules" . "R")))))
    (should (string-match-p "Work · drgnx.*Map.*Board.*Timeline.*Flow.*evidence.*e.*rules.*R" s))
    (should (eq (get-text-property (string-match "Work · drgnx" s) 'face s) 'drgnx-work-lens-title))
    (should (eq (get-text-property (string-match "Flow" s) 'face s) 'drgnx-work-lens-current))
    (should (eq (get-text-property (string-match "Map" s) 'face s) 'drgnx-work-label))
    (should (eq (get-text-property (string-match "evidence" s) 'face s) 'drgnx-work-chip))
    (should (eq (get-text-property (string-search "R" s (string-search "rules" s)) 'face s) 'drgnx-work-lens-key)))
  ;; no name: the tab says Work alone; no keys: no chips
  (let ((s (drgnx-work-lens-string 'map)))
    (should (string-match-p "Work .*Map" s))
    (should-not (string-match-p "evidence" s))))

(ert-deftest drgnx-work-flow/its-window-shows-the-lens-bar ()
  "The Flow's window shows the lens bar as its tab line (the chrome keeps a buffer's own) and no header: its strip
(what needs you, the machines' load) is the hub's, in its rows."
  (with-temp-buffer
    (drgnx-work-flow-mode)
    (should (local-variable-p 'drgnx-chrome-own-tab-line))
    (should drgnx-chrome-own-tab-line)
    (should (equal tab-line-format '("" drgnx-work-map--lens)))
    (should-not header-line-format)
    ;; a mode line drops the faces of a variable's string unless the variable is risky
    (should (get 'drgnx-work-map--lens 'risky-local-variable))))

(ert-deftest drgnx-work-flow/it-asks-the-hub-for-the-job-s-flow ()
  "The Flow asks `work/flow/subscribe' with its view, its map's view and the job (none: the hub picks the newest
running job)."
  (let (asked)
    (cl-letf (((symbol-function 'drgnx-work-client--call)
               (lambda (method params _cb) (push (cons method params) asked) t)))
      (drgnx-work-flow--ask "flow-1" "map-1" nil)
      (drgnx-work-flow--ask "flow-1" "map-1" "J7"))
    (should (equal (nreverse asked)
                   '(("work/flow/subscribe" :view "flow-1" :map "map-1")
                     ("work/flow/subscribe" :view "flow-1" :map "map-1" :job "J7"))))))

(defconst drgnx-work-flow-test--evidence
  [(:kind "red" :task "task:J#5" :job "4411"
          :facts (:tree_key "a90e3f1c" :env_stamp "e" :platform "linux-x86_64/local" :selector "runtime\ncargo test -p x")
          :rows [(:name "x::a" :verdict "fail" :class "assert") (:name "x::b" :verdict "pass")]
          :truncated :false :at 10.0)
   (:kind "green" :task "task:J#5" :job "4412"
          :facts (:tree_key "7d21c0e9" :env_stamp "e" :platform "linux-x86_64/local" :selector "runtime\ncargo test -p x")
          :rows [(:name "x::a" :verdict "pass") (:name "x::b" :verdict "pass")]
          :truncated :false :at 20.0)
   (:kind "waiver" :task "task:J#5" :job ""
          :facts (:tree_key "7d21c0e9" :env_stamp "" :platform "" :selector "")
          :rows [] :truncated :false :at 30.0 :note "a docs change")]
  "A task's evidence as `orch/evidence' answers it (parsed as plists): a red, a green, the user's waiver.")

(ert-deftest drgnx-work-flow/a-task-s-evidence-is-a-line-per-record ()
  "Each record is a line: its kind, job, tree and selector's command, then its failing rows or its pass count; a waiver
says its reason."
  (let ((lines (drgnx-work-flow--evidence-lines drgnx-work-flow-test--evidence)))
    (should (= (length lines) 3))
    (should (string-match-p "\\`red +job 4411 +a90e3f1 +cargo test -p x +1 failed: x::a\\'" (nth 0 lines)))
    (should (string-match-p "\\`green +job 4412 +7d21c0e +cargo test -p x +2 pass\\'" (nth 1 lines)))
    (should (string-match-p "\\`waiver +7d21c0e +by you: a docs change\\'" (nth 2 lines)))
    (should (equal (drgnx-work-flow--evidence-lines []) '("No evidence yet.")))))

(ert-deftest drgnx-work-flow/a-held-task-s-card-is-on-its-row ()
  "The hub puts a held task's `gate' card on its row (`drgnx-work-card'); a needs-you chip names the task alone."
  (with-temp-buffer
    (insert (propertize " ⚑ T5 held: no red " 'drgnx-work-id "J#5") "\n"
            (propertize "T1 search/run" 'drgnx-work-id "J#1") "\n"
            (propertize "T5 Git scopes" 'drgnx-work-id "J#5" 'drgnx-work-card 42) "\n")
    (should (eql (drgnx-work-flow--card-of "J#5") 42))
    (should-not (drgnx-work-flow--card-of "J#1"))
    (should-not (drgnx-work-flow--card-of "J#9"))))

(ert-deftest drgnx-work-flow/the-tile-asks-for-the-selected-task ()
  "The detail tile is the Flow's subscription with `detail': its own view, the map's view, the job and the task."
  (should (equal (drgnx-work-flow--detail-params "flow-1/detail" "map-1" nil "J#5")
                 '(:view "flow-1/detail" :map "map-1" :detail "J#5")))
  (should (equal (drgnx-work-flow--detail-params "flow-1/detail" "map-1" "J" "J#5")
                 '(:view "flow-1/detail" :map "map-1" :detail "J#5" :job "J"))))

(ert-deftest drgnx-work-flow/the-rules-tile-asks-for-the-pack ()
  "The Rules tile is the Flow's subscription with `rules': its own view, the map's view and the job."
  (should (equal (drgnx-work-flow--rules-params "flow-1/rules" "map-1" nil)
                 '(:view "flow-1/rules" :map "map-1" :rules t)))
  (should (equal (drgnx-work-flow--rules-params "flow-1/rules" "map-1" "J")
                 '(:view "flow-1/rules" :map "map-1" :rules t :job "J")))
  ;; with the Flow's selected task: the tile's Evidence tab names it
  (should (equal (drgnx-work-flow--rules-params "flow-1/rules" "map-1" "J" "J#5")
                 '(:view "flow-1/rules" :map "map-1" :rules t :job "J" :detail "J#5"))))

(ert-deftest drgnx-work-flow/r-shows-the-rules-tile-in-the-panel ()
  "`R' shows the Flow's own Rules tile in the bottom panel, even where the panel already shows the pane's placeholder
(layout Work opened it before the Flow had a tile)."
  (let ((tile (get-buffer-create " work-flow-test rules")) shown)
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-work-flow-rules-buffer) (lambda (_flow) tile))
                  ((symbol-function 'drgnx-pane-show)
                   (lambda (kind &rest args) (push (cons kind args) shown) (selected-window))))
          (with-temp-buffer
            (drgnx-work-flow-rules))
          (should (equal shown `((work-rules :buffer ,tile)))))
      (kill-buffer tile))))

;; the tiles draw their own title rows (hub-orchestration.html's `.tile-h'): the docks draw no tab row over them
(ert-deftest drgnx-work-flow/its-tiles-have-their-own-titles ()
  (with-temp-buffer
    (drgnx-work-flow-rules-mode)
    (should drgnx-area-own-title))
  (with-temp-buffer
    (drgnx-work-flow-detail-mode)
    (should drgnx-area-own-title)))

(ert-deftest drgnx-work-flow/its-faces-are-the-ui-font-s-and-the-theme-s ()
  "The faces the hub's Flow rows name: the UI font (proportional), colours from the theme's chips and text, no
literal colour."
  (dolist (f '(drgnx-work-flow-text drgnx-work-flow-label drgnx-work-flow-heading drgnx-work-flow-chip-ok
                                    drgnx-work-flow-chip-run drgnx-work-flow-chip-held drgnx-work-flow-chip-err
                                    drgnx-work-flow-chip-wait drgnx-work-flow-key drgnx-work-flow-detail-text
                                    drgnx-work-flow-section drgnx-work-flow-agent))
    (should (facep f))
    (let ((spec (face-default-spec f)))
      (should-not (string-match-p "#[0-9a-fA-F]\\{3\\}" (format "%S" spec)))
      (should (string-match-p "drgnx-ui-" (format "%S" spec))))))

;; hub-orchestration.html: the table 12 px (`.flow`), the pills 11 px (`.g`), the detail 12.5 px with 12 px semibold
;; muted heads (`.detail`, `.detail h5`)
(ert-deftest drgnx-work-flow/its-sizes-are-the-mockup-s ()
  "The table's text is the caption role (12 px), a chip a twelfth smaller (11 px); the detail tile's text the UI
text role and its section heads the caption role, semibold and muted; the agent's name on its head the heading role."
  (should (eq (face-attribute 'drgnx-work-flow-text :inherit) 'drgnx-ui-caption))
  (dolist (f '(drgnx-work-flow-chip-ok drgnx-work-flow-chip-run drgnx-work-flow-chip-held drgnx-work-flow-chip-err
                                       drgnx-work-flow-chip-wait))
    (should (< (abs (- (face-attribute f :height) (/ 11.0 12))) 0.001)))
  (should (eq (face-attribute 'drgnx-work-flow-detail-text :inherit) 'drgnx-ui-text))
  (should (equal (face-attribute 'drgnx-work-flow-section :inherit) '(drgnx-ui-caption drgnx-text-muted)))
  (should (eq (face-attribute 'drgnx-work-flow-section :weight) 'semibold))
  (should (eq (face-attribute 'drgnx-work-flow-agent :inherit) 'drgnx-ui-heading))
  (should (eq (face-attribute 'drgnx-work-flow-agent :weight) 'bold))      ; `<b>' on the head
  ;; the cards' names (`.bcard .bl .code', 11.5 px in the code font, the text colour)
  (should (eq (face-attribute 'drgnx-work-flow-code :inherit) 'drgnx-code-small)))

(ert-deftest drgnx-work-flow/g-n-selects-the-nth-held-task ()
  "In the Flow, `g N' (the strip's badges) selects the Nth task a gate holds; on the map it stays the map's Nth thing
that needs you; elsewhere it says where it works."
  (let (moved)
    (cl-letf (((symbol-function 'drgnx-work-flow--rows-p) (lambda () t))
              ((symbol-function 'drgnx-view-nav) (lambda (&rest args) (push args moved)))
              ((symbol-function 'drgnx-work-map-needs-you) (lambda (n) (push (list 'map n) moved))))
      (with-temp-buffer
        (drgnx-work-flow-mode)
        (drgnx-work-needs-you 2))
      (with-temp-buffer
        (drgnx-work-map-mode)
        (drgnx-work-needs-you 3))
      (with-temp-buffer
        (fundamental-mode)
        (should-error (drgnx-work-needs-you 1) :type 'user-error)))
    (should (equal (nreverse moved) '((walk-to "held" 1) (map 3))))))

(ert-deftest drgnx-work-flow/the-actions-answer-the-gate-card ()
  "Run the red, Tell the agent and Waive once answer the held task's `gate' card (`job/card': merge, retry, waive with
the reason); a waiver without a reason, or a task no gate holds, sends nothing."
  (let (sent (card 42))
    (cl-letf (((symbol-function 'drgnx-work-flow--held-card) (lambda () (or card (user-error "not held"))))
              ((symbol-function 'drgnx-hub-call)
               (lambda (method params _cb &rest _) (push (cons method params) sent))))
      (drgnx-work-flow-run-red)
      (drgnx-work-flow-tell-agent)
      (drgnx-work-flow-waive "a docs change")
      (should-error (drgnx-work-flow-waive "  ") :type 'user-error)
      (setq card nil)
      (should-error (drgnx-work-flow-waive "x") :type 'user-error))
    (should (equal (nreverse sent)
                   '(("job/card" :card 42 :action "merge")
                     ("job/card" :card 42 :action "retry")
                     ("job/card" :card 42 :action "waive" :arg "a docs change"))))))

(ert-deftest drgnx-work-flow/its-keys-are-in-every-profile ()
  "`F' shows the Flow from any view of the lens; `e', `R' and the held task's actions (`r', `s', `w') work in the Flow
only; every profile names them."
  (dolist (id '(work-view-flow work-flow-evidence work-flow-rules work-flow-run-red work-flow-tell-agent
                               work-flow-waive))
    (should (memq id drgnx-work-space-command-ids))
    (dolist (profile '("vscode" "emacs" "vim"))
      (let ((rows (plist-get (with-temp-buffer
                               (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
                               (read (current-buffer)))
                             :bind)))
        (should (assq id rows))))))

(ert-deftest drgnx-work-flow/its-cards-and-rules-are-glitnir-blocks ()
  "Pattern D: the hub's block marks on the rows become `glitnir-blocks' on the window showing the Flow: a card's ring
from its first row to the end of its last, a rule per marked row, colours as faces (Glitnir resolves them again on a
theme change).  The parameter is set when the blocks change, not per patch; a killed Flow leaves no blocks behind."
  (let ((buffer (generate-new-buffer "*flow-blocks*")) (sets 0)
        (setp (symbol-function 'set-window-parameter)))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (add-hook 'kill-buffer-hook #'drgnx-work-flow--unblock nil t)
          (let ((inhibit-read-only t))
            (insert (propertize "T1 row" 'drgnx-work-flow-block ["rule" "task:1" 0 600]) "\n"
                    (propertize "Merge batch" 'drgnx-work-flow-block ["ring" "batch" 0 290])
                    (propertize " Line gate" 'drgnx-work-flow-block ["ring" "line" 300 598]) "\n"
                    (propertize "T2 tip" 'drgnx-work-flow-block ["ring" "batch" 0 290]) "\n"))
          (cl-letf (((symbol-function 'set-window-parameter)
                     (lambda (w p v) (when (eq p 'glitnir-blocks) (cl-incf sets)) (funcall setp w p v))))
            (drgnx-work-flow--patched nil nil)
            (let* ((blocks (window-parameter (selected-window) 'glitnir-blocks))
                   (kinds (mapcar #'car blocks)))
              (should (equal kinds '(rule ring ring)))
              (let ((batch (nth 1 blocks)))
                ;; the batch's ring spans its two rows: from "Merge batch" to the end of "T2 tip"
                (should (= (marker-position (nth 1 batch)) 8))
                (should (= (marker-position (nth 2 batch)) (1- (point-max))))
                (should (equal (plist-get (nthcdr 3 batch) :x1) 290))
                (should (eq (plist-get (nthcdr 3 batch) :ring) 'drgnx-border))
                (should (eq (plist-get (nthcdr 3 batch) :beneath) 'default)))
              (should (eq (plist-get (nthcdr 3 (car blocks)) :ring) 'drgnx-border-subtle))
              (should (equal (plist-get (nthcdr 3 (nth 2 blocks)) :x0) 300))
              ;; the same rows again: the same object, not set again
              (drgnx-work-flow--patched nil nil)
              (should (eq (window-parameter (selected-window) 'glitnir-blocks) blocks))
              (should (= sets 1))))
          (kill-buffer buffer)
          (should-not (window-parameter (selected-window) 'glitnir-blocks)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

;; the mockup's selected task row (hub-orchestration.html `.sel.t`): `inset 2px 0 0 var(--focus)`
(ert-deftest drgnx-work-flow/the-selected-task-has-the-focus-bar ()
  "Pattern D: the selected task's row gets the mockup's accent, a 2 px bar at its left edge in the focus colour (a
Glitnir `bar' block in `drgnx-focus-line'), from its row's start to its end: the task row, not the strip's chip that
carries the same id.  A new selection moves it, and no selection draws none."
  (let ((drgnx-view-patch--buffers (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
        (drgnx-view-patch-send-function #'ignore)
        (buffer (generate-new-buffer "*flow-bar*")))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (drgnx-view-patch-attach "v" "c" :epoch 1)
          (drgnx-view-apply-patch
           (list :view "v" :class "c" :hub 7 :base 0 :version 1 :env_epoch 1 :images nil
                 :ops (list (list :reset (list (list :key "needs" :text "T2 held g1"
                                                     :props '((0 10 "drgnx-work-id" "task:2")))
                                               (list :key "task:task:1" :text "T1 row"
                                                     :props '((0 6 "drgnx-work-id" "task:1")))
                                               (list :key "task:task:2" :text "T2 row"
                                                     :props '((0 6 "drgnx-work-id" "task:2"))))))))
          (drgnx-view-draw-now drgnx-view)
          (let ((bar (lambda () (seq-find (lambda (b) (eq (car b) 'bar))
                                          (window-parameter (selected-window) 'glitnir-blocks))))
                (t2 (drgnx-view-row-start drgnx-view "task:task:2")))
            (drgnx-work-flow--patched nil nil)
            (should-not (funcall bar))
            (setq drgnx-work-flow--selected "task:2")
            (drgnx-work-flow--patched nil nil)
            (let ((b (funcall bar)))
              (should b)
              (should (= (marker-position (nth 1 b)) t2))
              (should (= (marker-position (nth 2 b)) (+ t2 6)))
              (should (equal (plist-get (nthcdr 3 b) :x0) 0))
              (should (equal (plist-get (nthcdr 3 b) :x1) (drgnx-px 2)))
              (should (eq (plist-get (nthcdr 3 b) :ring) 'drgnx-focus-line)))
            ;; a key moves the selection: the bar follows at once, before any patch
            (setq major-mode 'drgnx-work-flow-mode)
            (cl-letf (((symbol-function 'drgnx-work-flow--ask-detail) #'ignore))
              (drgnx-work-flow--selected-moved buffer "task:1"))
            (should (= (marker-position (nth 1 (funcall bar))) (drgnx-view-row-start drgnx-view "task:task:1")))))
      (with-current-buffer buffer (drgnx-view-patch-teardown) (drgnx-timer-cancel (cons 'drgnx-view buffer)))
      (kill-buffer buffer))))

(ert-deftest drgnx-work-flow/a-button-s-key-is-a-keycap-inside-one-ring ()
  "hub-orchestration.html `.btn .k': the button's ring runs around its key.  A key with its own face box broke the
ring in two (a tail after the key), so on a graphical frame the detail tile draws each key as a keycap image in the
key's ring colour while its text takes the button's face: one box run.  Elsewhere the keys keep their faces."
  (declare-function drgnx-work-flow--keycaps "drgnx-work-flow")
  (defvar drgnx-view-patch-patched-functions)
  (require 'drgnx-palette)                            ; loaded first, so its keycap stays stubbed
  (let ((inhibit-read-only t)                         ; the tile is a special-mode buffer
        (fill (lambda ()
                (erase-buffer)
                (insert (propertize " Run the red " 'face 'drgnx-work-flow-button-primary)
                        (propertize " r " 'face 'drgnx-work-flow-key-primary)
                        (propertize " " 'face 'drgnx-work-flow-button-primary) " "
                        (propertize " Evidence " 'face 'drgnx-work-flow-button)
                        (propertize " e " 'face 'drgnx-work-flow-button-key)
                        (propertize " " 'face 'drgnx-work-flow-button) "\n"))))
    (with-temp-buffer
      (drgnx-work-flow-detail-mode)
      (should (memq #'drgnx-work-flow--keycaps drgnx-view-patch-patched-functions))
      (cl-letf (((symbol-function 'display-graphic-p) #'always)
                ((symbol-function 'image-type-available-p) #'always)
                ((symbol-function 'drgnx-palette--keycap-image)
                 (lambda (name face) (list 'image :type 'svg :name name :face face))))
        (funcall fill)
        (drgnx-work-flow--keycaps nil nil)
        (pcase-dolist (`(,key ,button ,key-face) '(("r" drgnx-work-flow-button-primary drgnx-work-flow-key-primary)
                                                   ("e" drgnx-work-flow-button drgnx-work-flow-button-key)))
          (let ((at (1- (string-search (format " %s " key) (buffer-string)))))
            ;; the key and the spaces round it in the button's face, the key itself the keycap image
            (dotimes (i 3) (should (eq button (get-text-property (+ (point-min) at 1 i) 'face))))
            (should (equal (list 'image :type 'svg :name key :face key-face)
                           (get-text-property (+ (point-min) at 2) 'display)))))
        (should-not (text-property-any (point-min) (point-max) 'face 'drgnx-work-flow-button-key)))
      ;; a terminal: the keys as they came
      (cl-letf (((symbol-function 'display-graphic-p) #'ignore))
        (funcall fill)
        (drgnx-work-flow--keycaps nil nil)
        (should (text-property-any (point-min) (point-max) 'face 'drgnx-work-flow-key-primary))
        (should-not (text-property-not-all (point-min) (point-max) 'display nil))))))

;;; work-flow-test.el ends here
