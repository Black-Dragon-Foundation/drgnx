;;; core-palette-test.el --- batch tests: the command palette -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'drgnx-palette)

(defvar drgnx-test--palette-ran nil)
(defun drgnx-test--palette-cmd () (interactive) (setq drgnx-test--palette-ran t))

(ert-deftest drgnx-palette/candidates-and-run ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (drgnx-test--palette-ran nil))
    (drgnx-command-define 'p :title "Do It" :category "Test" :command #'drgnx-test--palette-cmd)
    (drgnx-command-define 'gone :title "Gone" :category "Test" :command 'drgnx-test--missing)
    (should (equal (mapcar #'car (drgnx-palette-candidates)) '("Test: Do It")))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Test: Do It")))
      (drgnx-palette))
    (should drgnx-test--palette-ran)))

;; The answer is resolved here, not by the completion UI: `require-match' is nil, so a `#question' that no
;; completion style would offer (orderless filters candidates itself) still reaches the command.
(defun drgnx-test--palette-with-search (answer styles &rest opts)
  "Run the palette with ANSWER typed, under completion STYLES; return (SEARCH-ARGS REQUIRE-MATCH RAN)."
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (asked nil) (require-match 'unset) (drgnx-test--palette-ran nil)
        (completion-styles styles))
    (drgnx-command-define 'p :title "Do It" :category "Test" :command #'drgnx-test--palette-cmd)
    (when (plist-get opts :extra)
      (drgnx-command-define 'p2 :title "Do That" :category "Test" :command #'drgnx-test--palette-cmd))
    (drgnx-command-define 'search-semantic :title "Semantic Search" :category "Search"
                          :command (lambda (&optional q) (interactive (list "prompted")) (push q asked)))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _tbl _pred rm &rest _) (setq require-match rm) answer)))
      (drgnx-palette))
    (list asked require-match drgnx-test--palette-ran)))

(ert-deftest drgnx-palette/hash-runs-semantic-search ()
  (dolist (styles (append '((basic)) (and (locate-library "orderless") '((orderless basic)))))
    (pcase-let ((`(,asked ,rm ,_) (drgnx-test--palette-with-search "#  where do we parse json " styles)))
      (should (equal asked '("where do we parse json")))       ; the text after #, trimmed
      (should-not rm))                                         ; the UI never refuses the input
    ;; a bare # prompts (the command's own prompt)
    (should (equal (car (drgnx-test--palette-with-search "#" styles)) '("prompted")))
    ;; a label runs; empty does nothing; anything else is a clear error
    (should (nth 2 (drgnx-test--palette-with-search "Test: Do It" styles)))
    (should-not (car (drgnx-test--palette-with-search "" styles)))
    (should-not (nth 2 (drgnx-test--palette-with-search "  " styles)))
    (let ((err (should-error (drgnx-test--palette-with-search "nonsense" styles) :type 'user-error)))
      (should (string-match-p "No command: nonsense" (cadr err))))
    ;; a partial label resolves the way completion would (require-match t used to): unique runs it
    (should (nth 2 (drgnx-test--palette-with-search "Test: Do" styles)))
    (should (equal (car (drgnx-test--palette-with-search "Search: Sem" styles)) '("prompted")))
    ;; ambiguous: the names
    (let ((err (should-error (drgnx-test--palette-with-search "Test:" styles :extra t) :type 'user-error)))
      (should (string-match-p "Ambiguous: .*Test: Do It.*Test: Do That" (cadr err))))))

(ert-deftest drgnx-palette/a-label-starting-with-hash-wins ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (drgnx-test--palette-ran nil) (asked nil))
    (drgnx-command-define 'h :title "tag" :category "#" :command #'drgnx-test--palette-cmd)
    (drgnx-command-define 'search-semantic :title "Semantic Search" :category "Search"
                          :command (lambda (&optional q) (interactive) (push q asked)))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "#: tag")))
      (drgnx-palette))
    (should drgnx-test--palette-ran)
    (should-not asked)))

(ert-deftest drgnx-palette/preferences-opens-it-on-the-preferences ()
  ;; Cmd+, (VS Code's Settings): the palette with "Preferences: " typed, one Preferences command away.
  (let (initial)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _table &optional _pred _req init &rest _) (setq initial init) "")))
      (drgnx-palette-preferences))
    (should (equal initial "Preferences: "))))

;; From the old UI list ("palette prefix legend", "? palette mode erroring on empty input"): gryphn's palette had
;; seven prefix modes and a `?' legend of them, whose Enter on an empty box was a Lisp error.  drgnx's palette
;; has one prefix, `#', and says so in its prompt; anything else it cannot resolve is a plain user error.
(ert-deftest drgnx-palette/the-prompt-names-the-prefix ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        prompt)
    (cl-letf (((symbol-function 'completing-read) (lambda (p &rest _) (setq prompt p) "")))
      (drgnx-palette))
    (should (string-match-p "#" prompt))))

(ert-deftest drgnx-palette/a-question-mark-is-no-command-never-a-lisp-error ()
  (dolist (styles (append '((basic)) (and (locate-library "orderless") '((orderless basic)))))
    (dolist (typed '("?" "? "))
      (let ((err (condition-case e (drgnx-test--palette-with-search typed styles) (error e))))
        (should (eq (car err) 'user-error))
        (should (string-match-p "No command: \\?" (cadr err)))))
    ;; the legend's own empty case: nothing typed, nothing happens, no error
    (should-not (nth 2 (drgnx-test--palette-with-search "" styles)))))

;; The floating palette (core/drgnx-palette-frame.el): Glitnir decides, nothing else does.
(require 'drgnx-palette-frame)
(defvar vertico-count)

(defun drgnx-test--palette-placed (parent-width)
  "The (WIDTH HEIGHT) `drgnx-palette-frame--place' gives a parent PARENT-WIDTH frame pixels wide, for 20 px lines."
  (let ((vertico-count 10) (drgnx-palette-frame-width 640) sized)
    (cl-letf (((symbol-function 'frame-pixel-width) (lambda (f) (if (eq f 'parent) parent-width (car sized))))
              ((symbol-function 'frame-pixel-height) (lambda (_) 2000))
              ((symbol-function 'frame-scale-factor) (lambda (_) 2.0))
              ((symbol-function 'drgnx-pixels-ui-scale) (lambda (&optional _f) 1.0))
              ((symbol-function 'set-frame-size) (lambda (_f w h _pixelwise) (setq sized (list w h))))
              ((symbol-function 'set-frame-position) #'ignore))
      (drgnx-palette-frame--place 'child 'parent 20))
    sized))

(ert-deftest core-palette-float-sizes-are-logical-pixels ()
  ;; a frame of a native shell counts device pixels (the seam `drgnx-pixels-device-p'): 640 logical at scale 2 are
  ;; 1280 of them
  (cl-letf (((symbol-function 'drgnx-pixels-device-p) (lambda () t))
            ((symbol-function 'drgnx-pixels-ui-scale) (lambda (&optional _f) 1.0)))
    ;; the input row and 10 rows of 20 px, then 6 + 30 logical pixels of gap and footer
    (should (equal (drgnx-test--palette-placed 3000) '(1280 292)))
    (should (equal (drgnx-test--palette-placed 1000) '(936 292)))
    (cl-letf (((symbol-function 'frame-scale-factor) (lambda (_) 2.0)))
      (should (= 16 (alist-get 'internal-border-width (drgnx-palette-frame--params 'parent))))))
  ;; elsewhere a frame counts logical pixels already
  (cl-letf (((symbol-function 'drgnx-pixels-device-p) #'ignore)
            ((symbol-function 'drgnx-pixels-ui-scale) (lambda (&optional _f) 1.0)))
    (should (equal (drgnx-test--palette-placed 3000) '(640 256)))
    (should (= 8 (alist-get 'internal-border-width (drgnx-palette-frame--params 'parent))))))

(ert-deftest core-palette-float-sizes-go-through-the-pixel-rule ()
  "The palette's sizes in the parent's own pixels by the pixel rule (`drgnx-pixels-scale': the display scale times the
UI scale), half up; its ring by the line rule (1 device px at 1.5, not `round''s 2); its rows' spacing too."
  (let ((f (selected-frame)))
    (dolist (case '((1.0 8 1 2 0) (1.25 10 1 3 8) (1.3333333333333333 11 1 3 11) (1.5 12 1 3 16) (2.0 16 2 4 32)
                    (1.375 11 1 3 12)))
      (cl-letf (((symbol-function 'drgnx-pixels-scale) (lambda (&optional _f) (nth 0 case)))
                ((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                ((symbol-function 'drgnx-wb--natural-row-height) (lambda () 32)))
        (should (= (drgnx-palette-frame--px f 8) (nth 1 case)))
        (dolist (ring '((1 . 2) (2 . 3)))
          (cl-letf (((symbol-function 'drgnx-palette-frame--look)
                     (lambda () `((child-frame-border-width . ,(car ring))))))
            (let ((params (drgnx-palette-frame--params f)))
              (should (= (alist-get 'internal-border-width params) (nth 1 case)))
              (should (= (alist-get 'child-frame-border-width params) (nth (cdr ring) case))))))
        ;; a 32 px palette row over a 32 px natural row: the extra is the scaled row's
        (let ((sp (drgnx-palette-frame--spacing 32)))
          (should (= (+ (car sp) (cdr sp)) (nth 4 case))))))))

(ert-deftest core-palette-float-stays-for-a-minibuffer-on-top ()
  ;; a question on top of the open palette ends: the palette's own minibuffer still reads, so its box stays
  (let ((root (frame-root-window)) (drgnx-palette-frame--frame (selected-frame)) hidden)
    (unwind-protect
        (save-window-excursion
          (with-temp-buffer
            (set-window-buffer root (current-buffer))
            (cl-letf (((symbol-function 'frame-visible-p) (lambda (_) t))
                      ((symbol-function 'make-frame-invisible) (lambda (_) (setq hidden t)))
                      ((symbol-function 'active-minibuffer-window) (lambda () (minibuffer-window))))
              (drgnx-palette-frame-hide)
              (should-not hidden)
              (should (eq (window-buffer root) (current-buffer)))
              ;; the palette's own minibuffer ends
              (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () root)))
                (drgnx-palette-frame-hide))
              (should hidden)
              (should (equal (buffer-name (window-buffer root)) drgnx-palette-frame--buffer)))))
      (when-let* ((b (get-buffer drgnx-palette-frame--buffer))) (kill-buffer b)))))


(ert-deftest core-palette-float-off-without-glitnir ()
  (let (modes)
    (cl-letf (((symbol-function 'vertico-buffer-mode) (lambda (arg) (push arg modes))))
      ;; no Glitnir (or no graphical frame): the palette stays in the minibuffer, as before
      (should-not (drgnx-palette-frame-wanted-p))
      (drgnx-palette-frame-buffer 1)
      (should-not modes)
      ;; Glitnir on a graphical frame: `vertico-buffer-mode' on; off is always passed on
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'glitnir-active-p) (lambda (&optional _frame) t)))
        (should (drgnx-palette-frame-wanted-p))
        (drgnx-palette-frame-buffer 1))
      (should (equal modes '(1)))
      (drgnx-palette-frame-buffer -1)
      (should (equal modes '(-1 1))))))

;;;; Files and Agents (palette.html): a project's files in the Files group, a row that asks an agent in Agents

(defmacro drgnx-test--palette-in-project (&rest body)
  "BODY in a temp git-less project (a `.project' file marks it) holding test/unit/gateway-test.el and README.md,
with an empty registry; `dir' is its root."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "palette-files" t)))
          (default-directory dir)
          (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
          (project-vc-extra-root-markers '(".project")))
     (unwind-protect
         (progn (make-directory (expand-file-name "test/unit" dir) t)
                (dolist (f '(".project" "README.md" "test/unit/gateway-test.el"))
                  (write-region "" nil (expand-file-name f dir) nil 'silent))
                ,@body)
       (delete-directory dir t))))

(ert-deftest drgnx-palette/the-files-group-lists-the-projects-files ()
  "Each file of the project is a row of the Files group: the file's name, its folder beside it."
  (drgnx-test--palette-in-project
    (let ((files (drgnx-palette-files)))
      (should (assoc "File: test/unit/gateway-test.el" files))
      (should (equal (cdr (assoc "File: test/unit/gateway-test.el" files))
                     (expand-file-name "test/unit/gateway-test.el" dir)))
      (let ((drgnx-palette--file-rows (drgnx-palette--file-table files)))
        (should (equal (drgnx-palette-group "File: test/unit/gateway-test.el") "Files"))
        (should (string-match-p "gateway-test\\.el\\'"
                                (substring-no-properties (drgnx-palette--shown "File: test/unit/gateway-test.el"))))
        (should (string-match-p "test/unit"
                                (substring-no-properties (drgnx-palette--file-annotation "File: test/unit/gateway-test.el"))))))))

(ert-deftest drgnx-palette/choosing-a-file-row-visits-it ()
  (drgnx-test--palette-in-project
    (let (visited)
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "File: test/unit/gateway-test.el"))
                ((symbol-function 'find-file) (lambda (f &rest _) (setq visited f))))
        (drgnx-palette))
      (should (equal visited (expand-file-name "test/unit/gateway-test.el" dir))))))

(ert-deftest drgnx-palette/the-agents-row-asks-with-what-is-typed ()
  "With an `agents-ask' command, the typed text is a row of the Agents group; choosing it, Ctrl+Return, or `@' first
asks an agent with that text."
  (drgnx-test--palette-in-project
    (let (asked)
      (drgnx-command-define 'agents-ask :title "Ask an Agent…" :category "Agents"
                            :command (lambda (text) (interactive (list "prompted")) (push text asked)))
      (should (equal (drgnx-palette-ask-label "run te") "Agents: Ask an agent: \"run te\""))
      (should (equal (drgnx-palette-group (drgnx-palette-ask-label "run te")) "Agents"))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Agents: Ask an agent: \"run te\"")))
        (drgnx-palette))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "@ fix the flaky test ")))
        (drgnx-palette))
      (should (equal asked '("fix the flaky test" "run te"))))))

(ert-deftest drgnx-palette/no-agents-row-without-the-command ()
  (drgnx-test--palette-in-project
    (should-not (drgnx-palette-ask-label "run te"))))

(ert-deftest drgnx-palette/groups-in-the-mockups-order ()
  "palette.html's groups: Commands, then Files, then Agents.  The ask row is the fallback: last, never first while a
command or a file matches; recent commands still lead their group."
  (drgnx-test--palette-in-project
    (drgnx-command-define 'agents-ask :title "Ask an Agent…" :category "Agents" :command #'ignore)
    (drgnx-command-define 'run-file :title "Run Tests in This File" :category "Tests" :command #'ignore)
    (drgnx-command-define 'rerun :title "Rerun Last Tests" :category "Tests" :command #'ignore)
    (let* ((cands (drgnx-palette-candidates))
           (files (drgnx-palette-files))
           (drgnx-palette--file-rows (drgnx-palette--file-table files))
           (drgnx-palette--history (list (list 'rerun (floor (float-time)))))
           (ask (drgnx-palette-ask-label "run te"))
           (labels (list ask "File: test/unit/gateway-test.el" "Tests: Run Tests in This File"
                         "Tests: Rerun Last Tests"))
           (sorted (drgnx-palette-sort labels cands)))
      (should (equal (mapcar #'drgnx-palette-group sorted) '("Commands" "Commands" "Files" "Agents")))
      (should (equal (car sorted) "Tests: Rerun Last Tests"))
      (should (equal (car (last sorted)) ask)))))

(require 'drgnx-palette-frame)

;; The coordinator's ruling: once the user types, match quality first, recency for near-ties
(ert-deftest drgnx-palette/typed-text-ranks-by-match-then-recency ()
  "With text typed, how well a row matches ranks first (word starts, the words in order) and a recent run only
breaks near-ties, as in VS Code: \"run te\" gives palette.html's order with Rerun run 2 minutes ago.  With nothing
typed, recent first."
  (drgnx-test--palette-in-project
    (pcase-dolist (`(,id ,title ,cat) '((run-file "Run Tests in This File" "Tests") (run-point "Run Test at Point" "Tests")
                                        (rerun "Rerun Last Tests" "Tests") (run-term "Run in Terminal…" "Terminal")
                                        (rotate "Rotate Cloud CA" "Runners")))
      (drgnx-command-define id :title title :category cat :command #'ignore))
    (let* ((cands (drgnx-palette-candidates))
           (drgnx-palette--history (list (list 'rerun (- (floor (float-time)) 125))))
           (labels (list "Runners: Rotate Cloud CA" "Terminal: Run in Terminal…" "Tests: Rerun Last Tests"
                         "Tests: Run Tests in This File" "Tests: Run Test at Point")))
      (should (equal (drgnx-palette-sort labels cands nil "run te")
                     '("Tests: Run Tests in This File" "Tests: Run Test at Point" "Tests: Rerun Last Tests"
                       "Terminal: Run in Terminal…" "Runners: Rotate Cloud CA")))
      (should (equal (car (drgnx-palette-sort labels cands nil "")) "Tests: Rerun Last Tests"))
      ;; a recent row that matches clearly worse stays below the better matches
      (let ((in (drgnx-palette-sort labels cands nil "run in")))
        (should (equal (car in) "Terminal: Run in Terminal…"))
        (should (< (seq-position in "Tests: Run Tests in This File") (seq-position in "Tests: Rerun Last Tests")))))))

(ert-deftest drgnx-palette/the-hint-and-the-footer-name-every-key ()
  "palette.html's input row ends \"Commands · # code · @ agents\" (the last when an agent can be asked); its footer
names move, run, preview and close."
  (drgnx-test--palette-in-project
    (with-temp-buffer
      (should-not (string-search "agents" (substring-no-properties (drgnx-palette-frame--hint))))
      (drgnx-command-define 'agents-ask :title "Ask an Agent…" :category "Agents" :command #'ignore)
      (let ((hint (substring-no-properties (drgnx-palette-frame--hint))))
        (should (string-search "code" hint))
        (should (string-search "agents" hint)))
      (let ((foot (substring-no-properties (drgnx-palette-frame--footer))))
        (dolist (w '("move" "run" "preview" "close")) (should (string-search w foot)))))))
