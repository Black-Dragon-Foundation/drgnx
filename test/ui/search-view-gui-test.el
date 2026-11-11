;;; search-view-gui-test.el --- GUI tests: the Search view's modes, a git scope and its lists, drawn (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; One walk through the Search view's `.6' additions on a graphical frame, a screenshot of each for the look (their
;; paths are printed): Text with context labels, Symbol (definition rows, uses grouped, the "by name" line), Meaning
;; (score bars), a git scope, and the empty view's saved and recent searches.  The view is hub-fed (Sjá); no hub runs:
;; its calls are recorded and its rows are handed in as `view-patch' events, shaped as the hub's tests check them
;; (`view/search/tests.rs').  Needs a Nidhogg with Sjá (`nidhogg-view-push'); skipped elsewhere.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-search-ui-test--repo                        ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-search-ui-test--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-search-ui-test--repo))
(require 'drgnx)
(require 'drgnx-wb)
(require 'drgnx-area)
(require 'drgnx-view)
(require 'drgnx-popup)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-search-ui-test--repo) nil t)
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-search-ui-test--repo) nil t)

(defvar drgnx-hub--events)
(defvar drgnx-search-ui-test--calls nil "The hub calls the view made, newest first: (METHOD . PARAMS).")
(defvar drgnx-search-ui-test--version 0 "The last version handed to the view.")

(defun drgnx-search-ui-test--shot (dir name)
  "Capture the root frame into DIR and keep it as NAME in the evidence folder (DRGNX_UI_EVIDENCE), else the session's
temp dir; print where."
  (redisplay t)
  (let ((shot (plist-get (drgnx-uitest-capture dir) :root))
        (out (expand-file-name name (or (getenv "DRGNX_UI_EVIDENCE") temporary-file-directory))))
    (should (file-exists-p shot))
    (copy-file shot out t)
    (message "search-view screenshot: %s" out)
    out))

(defun drgnx-search-ui-test--row (key text &optional runs file)
  "The hub's row KEY: TEXT with RUNS ((START END FACE) ...); a match's (FILE) or a header's properties and its id."
  (list :key key :text text :runs runs
        :props (append (when file
                         (list (list 0 (length text) (if (string-prefix-p "f:" key) "drgnx-replace-file" "drgnx-replace-match")
                                     (if (string-prefix-p "f:" key) file (list :file file :line 1 :col 0)))))
                       (unless (string-prefix-p "c:" key) (list (list 0 (length text) "drgnx-work-id" key))))))

(defun drgnx-search-ui-test--show (rows)
  "Hand the view a new search's ROWS as the hub would: a reset, then the rows; draw them."
  (let* ((st drgnx-view-patch) (v drgnx-search-ui-test--version)
         (patch (lambda (base version ops)
                  (list :view (drgnx-view-patch-view st) :class (drgnx-view-patch-class st) :hub 7 :base base
                        :version version :env_epoch (drgnx-view-patch-epoch st) :ops ops))))
    (should (eq 'apply (drgnx-view-apply-patch (funcall patch v (1+ v) (list (list :reset nil))))))
    (should (eq 'apply (drgnx-view-apply-patch (funcall patch (1+ v) (+ v 2) (list (list :insert (list :after nil :rows rows)))))))
    (setq drgnx-search-ui-test--version (+ v 2))
    (drgnx-view-draw-now drgnx-view)))

(defun drgnx-search-ui-test--status ()
  "The view's status line."
  (buffer-substring-no-properties drgnx-replace--status-beg drgnx-replace--status-end))

(ert-deftest drgnx-ui-search-view/modes-scope-and-lists ()
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
  (drgnx-test-with-state
    (let* ((root (drgnx-uitest-root-frame)) (shots (make-temp-file "drgnx-search-shot" t))
           (dir (make-temp-file "drgnx-search-repo" t)) (file (expand-file-name "src/parse.rs" dir))
           (drgnx-wb--sections nil) (drgnx-wb--areas (copy-tree drgnx-wb--areas))
           (drgnx-view-patch--buffers (make-hash-table :test #'equal))
           (drgnx-view-model--views (make-hash-table :test #'equal))
           (drgnx-view-patch--hooked nil) (drgnx-view-old-path nil)
           (drgnx-view-patch-send-function #'ignore) (drgnx-view-env-send-function #'ignore)
           (drgnx-hub--events nil) (drgnx-search-ui-test--calls nil) (drgnx-search-ui-test--version 0)
           (drgnx-replace-view "search-ui-test") (drgnx-search-context t)
           (display-buffer-alist nil) (display-buffer-overriding-action '(nil)))
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert "fn parse(s: &str) -> Tree {\n    parse_all(s)\n}\n"))
      (cl-letf (((symbol-function 'drgnx-replace--hub-ready-p) (lambda () t))
                ((symbol-function 'drgnx-hub--call-on)
                 (lambda (_conn method params &optional _cb &rest _) (push (cons method params) drgnx-search-ui-test--calls) nil)))
        (unwind-protect
            (with-selected-frame root
              (delete-other-windows)
              (dolist (p '(drgnx-wb-view drgnx-wb-areas drgnx-wb-panel-px drgnx-wb-right-px drgnx-wb-dock-px))
                (set-frame-parameter nil p nil))
              (drgnx-replace--define-section)
              (drgnx-replace--define-commands)
              (find-file file)
              (drgnx-test-use-editor (selected-window))
              (goto-char (point-min)) (search-forward "parse")
              (drgnx-wb-show-sidebar)
              (drgnx-replace-in-files)
              (should (eq (drgnx-wb-sidebar-view) 'search))
              (with-current-buffer (get-buffer drgnx-replace-buffer-name)
                (setq drgnx-replace--root (file-name-as-directory dir))
                (drgnx-replace--hub-attach)
                (should drgnx-view-patch)
                (let ((view drgnx-replace-view))
                  ;; 1. Text, with a context label above the matches of one definition
                  (drgnx-search-ui-test--show
                   (list (drgnx-search-ui-test--row "f:src/parse.rs" "[x] parse.rs  src/" '((14 18 "drgnx-replace-dim")) file)
                         (drgnx-search-ui-test--row "c:1:0" "  ƒ parse" '((0 9 "drgnx-replace-ctx")))
                         (drgnx-search-ui-test--row "m:1:0" "  [x] fn parse(s: &str) -> Tree {" '((9 14 "drgnx-replace-match")) file)
                         (drgnx-search-ui-test--row "m:1:1" "  [x] parse_all(s)" '((6 11 "drgnx-replace-match")) file)))
                  (drgnx-replace--hub-event "search-run-done" (list :view view :run 1 :files 1 :matches 2))
                  (goto-char drgnx-replace--results)
                  (should (search-forward "ƒ parse" nil t))
                  (should (eq 'drgnx-replace-ctx (get-text-property (match-beginning 0) 'face)))
                  (drgnx-search-ui-test--shot shots "search-view-text.png")
                  ;; 2. Symbol: the definition's kind icon and signature, its uses under it, "by name"
                  (drgnx-replace-search-mode-symbol)
                  (should (equal "symbol" (plist-get (plist-get (plist-get (cdar drgnx-search-ui-test--calls) :search) :query) :mode)))
                  (drgnx-search-ui-test--show
                   (list (drgnx-search-ui-test--row "f:src/parse.rs" "[x] parse.rs  src/" '((14 18 "drgnx-replace-dim")) file)
                         (drgnx-search-ui-test--row "m:2:0" "  [x] ƒ fn parse(s: &str) -> Tree"
                                                    '((6 7 "drgnx-replace-kind") (11 16 "drgnx-replace-match")) file)
                         (drgnx-search-ui-test--row "c:2:1" "  ƒ parse" '((0 9 "drgnx-replace-ctx")))
                         (drgnx-search-ui-test--row "m:2:1" "  [x] parse_all(s)" '((6 11 "drgnx-replace-match")) file)))
                  (drgnx-replace--hub-event "search-run-done" (list :view view :run 2 :files 1 :matches 2))
                  (should (string-match-p "by name" (drgnx-search-ui-test--status)))
                  (goto-char drgnx-replace--results)
                  (should (search-forward "ƒ fn parse" nil t))
                  (should (eq 'drgnx-replace-kind (get-text-property (match-beginning 0) 'face)))
                  (drgnx-search-ui-test--shot shots "search-view-symbol.png")
                  ;; 3. Meaning: score bars before the hits' names
                  (drgnx-replace-search-mode-meaning)
                  (drgnx-search-ui-test--show
                   (list (drgnx-search-ui-test--row "f:src/parse.rs" "[x] parse.rs  src/" '((14 18 "drgnx-replace-dim")) file)
                         (drgnx-search-ui-test--row "m:3:0" "  [x] ████ parse  fn parse(s: &str) -> Tree {"
                                                    '((6 10 "drgnx-replace-score") (11 16 "drgnx-replace-kind")) file)
                         (drgnx-search-ui-test--row "m:3:1" "  [x] ██▌  parse_all  parse_all(s)  (moved)"
                                                    '((6 9 "drgnx-replace-score") (11 20 "drgnx-replace-kind")
                                                      (34 43 "drgnx-replace-dim"))
                                                    file)))
                  (drgnx-replace--hub-event "search-run-done" (list :view view :run 3 :files 1 :matches 2))
                  (goto-char drgnx-replace--results)
                  (should (search-forward "████" nil t))
                  (should (eq 'drgnx-replace-score (get-text-property (match-beginning 0) 'face)))
                  (should-not (string-match-p "by name" (drgnx-search-ui-test--status)))
                  (drgnx-search-ui-test--shot shots "search-view-meaning.png")
                  ;; 4. Text in a git scope: its chip on, what it searched on the status line
                  (drgnx-replace-search-mode-text)
                  (drgnx-replace-search-scope-changed)
                  (should (equal "changed" (plist-get (plist-get (plist-get (cdar drgnx-search-ui-test--calls) :search) :scope) :kind)))
                  (drgnx-search-ui-test--show
                   (list (drgnx-search-ui-test--row "f:src/parse.rs" "[x] parse.rs  src/" '((14 18 "drgnx-replace-dim")) file)
                         (drgnx-search-ui-test--row "m:4:0" "  [x] fn parse(s: &str) -> Tree {" '((9 14 "drgnx-replace-match")) file)))
                  (drgnx-replace--hub-event "search-run-done"
                                            (list :view view :run 4 :files 1 :matches 1
                                                  :scope (list :files 1 :submodules 0 :deleted 1)))
                  (should (string-match-p "1 result in 1 file" (drgnx-search-ui-test--status)))
                  (drgnx-search-ui-test--shot shots "search-view-changed.png")
                  ;; 5. Find empty: the saved searches (one pinned, with its count) and the recent ones
                  (drgnx-replace--fill 'find "")
                  (setq drgnx-replace--saved
                        (list (list :name "TODOs on this branch" :pinned t :project :false
                                    :search (list :query (list :mode "text" :text "TODO") :scope (list :kind "branch")))
                              (list :name "where we parse keys.eld" :pinned :false :project :false
                                    :search (list :query (list :mode "meaning" :question "where we parse keys.eld"))))
                        drgnx-replace--pin-counts (list (cons 0 3))
                        drgnx-replace--recent
                        (list (list :query (list :mode "text" :text "needle-check") :scope (list :kind "changed"))
                              (list :query (list :mode "symbol" :name "drgnx-view-apply-patch"))))
                  (drgnx-replace--lists-draw)
                  (goto-char drgnx-replace--lists-beg)
                  (should (search-forward "TODOs on this branch · 3" drgnx-replace--lists-end t))
                  (should (search-forward "☆ where we parse keys.eld" drgnx-replace--lists-end t))
                  (should (search-forward "Recent" drgnx-replace--lists-end t))
                  (drgnx-search-ui-test--shot shots "search-view-lists.png")
                  ;; 6. A file's preview tile: its diff, a hunk's tick box, a regexp's groups line (∅ for a group
                  ;; that matched nothing); the hub's `search/preview' answer as its tests check it
                  (let* ((answer (list :path file :plus 2 :minus 2
                                       :diff (concat "--- " file "\n+++ " file "\n@@ -1,3 +1,3 @@\n"
                                                     "-fn parse(s: &str) -> Tree {\n-    parse_all(s)\n"
                                                     "+fn read(s: &str) -> Tree {\n+    read_all(s)\n }\n")
                                       :hunks (vector (list :old_start 1 :old_lines 3 :new_start 1 :new_lines 3
                                                            :ids ["m:4:0" "m:4:1"]
                                                            :captures (vector (list :id "m:4:0" :groups ["pars" nil]))))))
                         (tile (drgnx-replace--preview-buffer file)))
                    (with-current-buffer tile (drgnx-replace--preview-draw answer))
                    (drgnx-wb-show-in-editor tile)
                    (with-current-buffer tile
                      (goto-char (point-min))
                      (should (search-forward "\\2 = ∅" nil t))
                      (should (eq 'drgnx-replace-preview-empty (get-text-property (1- (point)) 'face))))
                    (drgnx-search-ui-test--shot shots "search-view-preview.png")
                    ;; 7. The Replace All sheet: every file's +/−, the selected file's first hunk, the skipped, the
                    ;; buttons
                    (cl-letf (((symbol-function 'drgnx-hub--call-on)
                               (lambda (_conn method _params &optional cb &rest _)
                                 (when (and cb (equal method "search/preview")) (funcall cb answer nil))))
                              ;; the module's rule sends the sheet to the popup lane (`drgnx-wb-place'); this test
                              ;; runs without the rules
                              ((symbol-function 'pop-to-buffer)
                               (lambda (b &rest _) (select-window (drgnx-popup--show b nil nil)))))
                      (drgnx-replace--sheet-show
                       (list :change 3
                             :files (vector (list :path file :source "disk"
                                                  :edits (vector (list :id "m:4:0" :line 1) (list :id "m:4:1" :line 2)))
                                            (list :path (expand-file-name "src/lib.rs" dir) :source "disk"
                                                  :edits (vector (list :id "m:4:2" :line 9))))
                             :skipped (vector (list :id "m:4:3" :path (expand-file-name "src/old.rs" dir)
                                                    :why "changed on disk since the search")))))
                    (with-current-buffer drgnx-replace-sheet-buffer-name
                      (goto-char (point-min))
                      (should (search-forward "Replace All  3 matches in 2 files" nil t))
                      (should (search-forward "@@ -1,3 +1,3 @@" nil t))
                      (should (search-forward "1 skipped: changed on disk since the search" nil t)))
                    (drgnx-search-ui-test--shot shots "search-view-sheet.png")
                    (when-let* ((b (get-buffer drgnx-replace-sheet-buffer-name)))
                      (quit-window t (get-buffer-window b t)))
                    (kill-buffer tile)))))
          (drgnx-wb-hide-sidebar)
          (with-selected-frame root
            (delete-other-windows)
            (dolist (p '(drgnx-wb-view drgnx-wb-areas drgnx-wb-panel-px drgnx-wb-right-px drgnx-wb-dock-px))
              (set-frame-parameter nil p nil))
            (switch-to-buffer "*scratch*"))
          (when-let* ((buf (get-buffer drgnx-replace-buffer-name)))
            (with-current-buffer buf (drgnx-view-patch-teardown))
            (drgnx-timer-cancel (cons 'drgnx-view buf))
            (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))
          (drgnx-timer-cancel (cons 'drgnx-view-model "search-ui-test"))
          (remove-hook 'drgnx-hub-event-functions #'drgnx-replace--hub-event)
          (when-let* ((b (find-buffer-visiting file))) (kill-buffer b))
          (delete-directory shots t)
          (delete-directory dir t))))))

;;; search-view-gui-test.el ends here
