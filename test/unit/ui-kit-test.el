;;; ui-kit-test.el --- batch tests: the UI kit's components (etc/ui/components.eld) -*- lexical-binding: t -*-
;; test-class: det
;; Pattern [D]: pure.  The components file is read and checked against the token table, the glyph table and the faces
;; the tree defines (read statically); themes are enabled only to read realised colours, and disabled again.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx)
(require 'drgnx-paths)
(require 'drgnx-faces)
(require 'drgnx-ui-kit)
(require 'drgnx-color)
(unless (featurep 'drgnx-theme-gen)
  (load (expand-file-name "themes/drgnx-theme-gen" drgnx-dir) nil t))
(add-to-list 'custom-theme-load-path (expand-file-name "test/fixtures/themes" drgnx-dir))

(defconst ui-kit-test--keys '(:variants :defaults :geometry :tty :label :bind :replaces :helpers :lint)
  "The keys every component entry has.")

(defun ui-kit-test--tree-faces ()
  "Every face a `defface' form in core/, wb/ or modules/ names (read as text, nothing loaded)."
  (let (faces)
    (dolist (dir '("core" "wb" "modules") faces)
      (dolist (file (directory-files-recursively (expand-file-name dir drgnx-dir) "\\.el\\'"))
        (with-temp-buffer
          (insert-file-contents file)
          (while (re-search-forward "^[ \t]*(defface[ \t\n]+\\([^ \t\n()]+\\)" nil t)
            (push (intern (match-string 1)) faces)))))))

(defun ui-kit-test--tokens (value)
  "The token names VALUE (a binding, a state or a geometry value) names."
  (cond ((and value (symbolp value) (not (keywordp value))) (list value))
        ((consp value) (append (ui-kit-test--tokens (car value)) (ui-kit-test--tokens (cdr value))))))

(ert-deftest drgnx-ui-kit/schema-is-valid ()
  (let ((table (drgnx-ui-kit-components)) (faces (ui-kit-test--tree-faces)) (fails nil))
    (should (assq 'state-table table))
    (should (assq 'components table))
    (should (assq 'row (alist-get 'components table)))
    (dolist (entry (alist-get 'components table))
      (let ((id (car entry)) (plist (cdr entry)))
        (dolist (key ui-kit-test--keys)
          (unless (plist-member plist key) (push (format "%s: no %s" id key) fails)))
        ;; every default is a value of its axis
        (let ((d (plist-get plist :defaults)))
          (while d
            (unless (memq (cadr d) (cdr (assq (car d) (plist-get plist :variants))))
              (push (format "%s: default %s %s is no variant" id (car d) (cadr d)) fails))
            (setq d (cddr d))))
        ;; every token a binding names exists in all three variants
        (dolist (b (plist-get plist :bind))
          (dolist (key '(:bg :fg :edge))
            (when-let* ((token (plist-get (cdr b) key)))
              (dolist (variant '(dark light hc))
                (unless (assq token (alist-get variant (drgnx-theme--read)))
                  (push (format "%s: token %s not in %s" id token variant) fails))))))
        ;; every glyph exists
        (let ((tty (plist-get plist :tty)))
          (dolist (glyph (append (ensure-list (plist-get tty :glyph)) (plist-get tty :twisty)))
            (unless (assq glyph drgnx-ui--default-glyphs) (push (format "%s: no glyph %s" id glyph) fails))))
        ;; every face it replaces is defined in the tree
        (dolist (r (plist-get plist :replaces))
          (unless (memq (car r) faces) (push (format "%s: replaces %s, which no defface defines" id (car r)) fails)))))
    ;; the states' tokens exist too
    (dolist (state (alist-get 'state-table table))
      (dolist (key '(:fill :fg))
        (when-let* ((token (plist-get (cdr state) key)))
          (dolist (variant '(dark light hc))
            (unless (assq token (alist-get variant (drgnx-theme--read)))
              (push (format "state %s: token %s not in %s" (car state) token variant) fails))))))
    (when fails (ert-fail (string-join (nreverse fails) "\n")))))

(ert-deftest drgnx-ui-kit/state-table-matches-the-spec ()
  ;; spec §7.3, verbatim
  (should (equal drgnx-ui-kit-states '(rest hover pressed selected selected-inactive focus-visible disabled)))
  (should (equal drgnx-ui-kit-states (mapcar #'car (alist-get 'state-table (drgnx-ui-kit-components)))))
  (pcase-dolist (`(,state . ,want)
                 '((rest)
                   (hover :fill hover :face drgnx-hover :tty none)
                   (pressed :fill sel-quiet :face drgnx-selected-quiet)
                   (selected :fill sel :radius 6 :face drgnx-selected :tty inverse)
                   (selected-inactive :fill sel-inactive :radius 6 :face drgnx-selected-inactive :tty underline)
                   (focus-visible :ring (focus . 2) :face drgnx-focus :tty inverse)
                   (disabled :fg disabled :face drgnx-text-disabled :tty dim)))
    (let ((got (drgnx-ui-kit-state state)))
      (dolist (key '(:fill :radius :ring :fg :face :tty))
        (should (equal (list state key (plist-get want key)) (list state key (plist-get got key)))))))
  ;; rows have no box edges in hover or selection: no state but focus-visible draws an edge
  (dolist (state drgnx-ui-kit-states)
    (unless (eq state 'focus-visible) (should-not (plist-get (drgnx-ui-kit-state state) :ring)))))

(ert-deftest drgnx-ui-kit/the-row-geometry ()
  (should (equal '(6 . 6) (plist-get (drgnx-ui-kit-geometry 'row '(tree)) :pad)))
  (should (= 6 (plist-get (drgnx-ui-kit-geometry 'row '(list)) :radius)))
  (should-not (plist-get (drgnx-ui-kit-geometry 'row nil) :box))
  (should (= 0 (plist-get (drgnx-ui-kit-geometry 'row '(list)) :indent)))
  ;; the tree's indent and the row's height are the density's
  (require 'drgnx-look-density (expand-file-name "modules/ui/drgnx-look-density" drgnx-dir))
  (let ((drgnx-look-density 'roomy))
    (should (= (drgnx-look-density-value 'tree-indent) (plist-get (drgnx-ui-kit-geometry 'row '(tree)) :indent)))
    (should (= 30 (plist-get (drgnx-ui-kit-geometry 'row '(tree)) :height)))))

(defconst ui-kit-test--fixture
  '((state-table (rest))
    (components
     (zz-probe :variants ((tone quiet loud same)) :defaults (tone quiet)
               :geometry (:pad (4 . 4)) :tty nil :label "probe" :replaces nil :helpers nil :lint nil
               :bind ((() :bg panel :fg fg :inherit (highlight))
                      ((loud) :bg accent-fill :fg on-accent :inherit (highlight))
                      ((same) :bg panel :fg fg :inherit (highlight))))))
  "A component with a variant whose colours differ from its own and one whose colours do not.")

(defface ui-kit-test-old-face '((t :weight bold)) "A face a test component replaces." :group 'drgnx)

(ert-deftest drgnx-ui-kit/replaced-faces-inherit-the-kit-face ()
  ;; the old face's default spec inherits the kit face; the user's own spec on the old name still applies; drgnx's
  ;; themes stop styling it once its component has landed (:lint t)
  (let ((table '((state-table) (components (row :lint t :replaces ((ui-kit-test-old-face . drgnx-hover))))))
        (saved (get 'ui-kit-test-old-face 'face-defface-spec)))
    (unwind-protect
        (progn
          (should (equal (drgnx-ui-kit-define-aliases table) '(ui-kit-test-old-face)))
          (should (equal (get 'ui-kit-test-old-face 'face-defface-spec) '((t :inherit drgnx-hover))))
          (custom-set-faces '(ui-kit-test-old-face ((t :underline t))))
          (should (eq (face-attribute 'ui-kit-test-old-face :underline nil t) t))
          (should (equal (drgnx-ui-kit-replaced-faces table) '(ui-kit-test-old-face)))
          (should-not (drgnx-ui-kit-replaced-faces '((components (row :lint nil :replaces ((a . b))))))))
      (dolist (p '(theme-face saved-face customized-face face-modified)) (put 'ui-kit-test-old-face p nil))
      (face-spec-set 'ui-kit-test-old-face saved 'face-defface-spec))))

(ert-deftest drgnx-ui-kit/kit-faces-only-where-colours-differ ()
  (let ((made (mapcar #'car (drgnx-ui-kit-face-bindings ui-kit-test--fixture))))
    (should (equal made '(drgnx-kit-zz-probe drgnx-kit-zz-probe-loud))))
  ;; the real file: no two faces of one component share their colours
  (let ((specs (drgnx-ui-kit-face-bindings)))
    (dolist (f specs)
      (should (facep (car f)))
      (should-not (cl-find-if (lambda (g) (and (not (eq (car g) (car f))) (eq (nth 1 g) (nth 1 f))
                                               (equal (drgnx-ui-kit--colours (cons nil (nth 2 g)))
                                                      (drgnx-ui-kit--colours (cons nil (nth 2 f))))))
                              specs))))
  ;; drgnx's themes colour them from the bindings' tokens
  (should (equal (assq 'drgnx-kit-zz-probe-loud
                       (drgnx-ui-kit-theme-specs (lambda (token) (symbol-name token)) ui-kit-test--fixture))
                 '(drgnx-kit-zz-probe-loud :background "accent-fill" :foreground "on-accent"))))

(ert-deftest drgnx-ui-kit/third-party-theme-styles-every-kit-face ()
  ;; a theme that knows nothing of drgnx still gives every kit face that has colours a fill or a ring (one that has only
  ;; a text colour, a progress ring's: a text colour), through the standard faces it inherits: checked on the real
  ;; faces, and on the fixture's specs (the real file may have few faces yet).  A binding with no colours (the row's: the
  ;; UI font, on the surface's own fill) is exempt.
  (dolist (theme '(modus-vivendi doom-one-fixture))
    (unwind-protect
        (progn
          (mapc #'disable-theme custom-enabled-themes)
          (if (get theme 'theme-settings) (enable-theme theme) (load-theme theme t))
          (dolist (f (append (drgnx-ui-kit-face-bindings) (drgnx-ui-kit-face-bindings ui-kit-test--fixture)))
            (when-let* ((inherit (plist-get (nth 2 f) :inherit))
                        ((seq-some (lambda (k) (plist-get (nth 2 f) k)) '(:bg :fg :edge))))
              (if (seq-some (lambda (k) (plist-get (nth 2 f) k)) '(:bg :edge))
                  (progn
                    (should (cl-some (lambda (parent)
                                       (or (drgnx-face-color parent :background 'gui)
                                           (plist-get (drgnx-faces--clause-plist parent 'gui) :box)))
                                     inherit))
                    (when (facep (car f))
                      (should (or (drgnx-face-color (car f) :background 'gui)
                                  (plist-get (drgnx-faces--clause-plist (car f) 'gui) :box)))))
                (should (cl-some (lambda (parent) (drgnx-face-color parent :foreground 'gui)) inherit))))))
      (mapc #'disable-theme custom-enabled-themes))))

;;;; The expansion: one with the hub's (test/fixtures/kit, runtime/crates/drgnx-rows/tests/kit_conformance.rs)

(require 'ert-x)
(require 'drgnx-view)
(require 'drgnx-view-sja)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defun ui-kit-test--json (name type)
  "The fixture test/fixtures/kit/NAME, arrays read as TYPE (`list' or `array')."
  (with-temp-buffer
    (insert-file-contents (expand-file-name (concat "test/fixtures/kit/" name) drgnx-dir))
    (json-parse-buffer :object-type 'plist :array-type type :null-object nil :false-object :false)))

(ert-deftest drgnx-ui-kit/conformance ()
  ;; each case through `drgnx-ui-kit-expand' equals the hub's expansion of it, as expected.json holds it (the hub's at
  ;; the comfortable density, its default)
  (require 'drgnx-look-density (expand-file-name "modules/ui/drgnx-look-density" drgnx-dir))
  (let* ((drgnx-look-density 'comfortable)
         (cases (ui-kit-test--json "cases.json" 'list))
         (want (ui-kit-test--json "expected.json" 'array))
         (drgnx-face-glyphs drgnx-ui--default-glyphs) (i 0) (fails nil))
    (dolist (e (plist-get cases :envs))
      (dolist (c (plist-get cases :comps))
        (let* ((drgnx-look-density (intern (or (plist-get e :density) "comfortable")))
               (w (aref want i))
               (comp (plist-get c :comp))
               (got (drgnx-ui-kit-expand (intern (plist-get comp :c)) comp (float (plist-get e :scale))
                                         (and (eq (plist-get e :tty) t) (if (eq (plist-get e :ascii) t) 'ascii t)))))
          (should (equal (plist-get w :name) (format "%s/%s" (plist-get e :name) (plist-get c :name))))
          (dolist (k '(:text :runs :props :spaces :height))
            (unless (equal (plist-get got k) (plist-get w k))
              (push (list (plist-get w :name) k (plist-get got k) (plist-get w k)) fails)))
          (setq i (1+ i)))))
    (should (= i (length want)))
    (should-not (nreverse fails))))

(ert-deftest drgnx-ui-kit/buffer-text-uses-canonical-widths ()
  ;; in buffer text a pad is a width in canonical characters, so one buffer is right at two scales
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
            ((symbol-function 'drgnx-pixels-scale) (lambda (&optional _) 1.25))
            ((symbol-function 'frame-char-width) (lambda (&optional _) 10)))
    (let* ((s (drgnx-ui-kit-string 'row '(:c "row" :kind "list" :text "a") 'text nil))
           (pad (get-text-property 0 'display s)))
      (should (equal pad '(space :width 0.8)))           ; 6 px at 1.25 = 8 device px = 0.8 of a 10 px column
      (should (equal (substring-no-properties s) " a ")))))

(ert-deftest drgnx-ui-kit/line-pads-follow-the-frame-scale ()
  ;; on a line a pad is device px at the frame's scale, its spec made once per width
  (let ((scale 1))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'drgnx-pixels-scale) (lambda (&optional _) scale)))
      (clrhash drgnx-ui-kit--pads)
      (let ((a (drgnx-ui-kit-string 'row '(:c "row" :kind "list" :text "a") 'header-line nil)))
        (setq scale 1.25)
        (let ((b (drgnx-ui-kit-string 'row '(:c "row" :kind "list" :text "a") 'header-line nil)))
          (should (equal (get-text-property 0 'display a) '(space :width (6))))
          (should (equal (get-text-property 0 'display b) '(space :width (8))))
          ;; the same spec object for the same width, from the cache
          (should (eq (get-text-property 0 'display b) (get-text-property 2 'display b)))
          (should (= (hash-table-count drgnx-ui-kit--pads) 2)))))))

(ert-deftest drgnx-ui-kit/action-prop-gets-its-kind-map ()
  ;; a hub row's `drgnx-action' gets its kind's keymap from both dress functions, and RET runs the kind's function
  (let ((got nil))
    (unwind-protect
        (progn
          (drgnx-ui-kit-define-action 'kit-test (lambda (args) (setq got args)) nil)
          (let* ((map (drgnx-ui-kit-action-map "kit-test"))
                 (state (drgnx-view-patch--make :view "v" :class "c" :epoch 1))
                 (a (drgnx-view-patch--dress state "k" (list :text "ab" :props '((0 2 "drgnx-action" ("kit-test" 1))))
                                             (copy-sequence "ab\n")))
                 (b (drgnx-view-sja--dress state (copy-sequence "ab\n") [] (vector 0 2 "drgnx-action" '("[\"kit-test\",1]")) [])))
            (should (keymapp map))
            (should-not (eq map (drgnx-ui-kit-action-map "kit-other")))
            (should (eq (get-text-property 0 'keymap a) map))
            (should (eq (get-text-property 1 'keymap b) map))
            (should-not (get-text-property 2 'keymap a))
            ;; a click runs `kit-activate' (RET is the profiles' key for it, in the map this one inherits)
            (should (eq (lookup-key map [mouse-1]) #'drgnx-ui-kit-activate))
            (should (eq (keymap-parent map) drgnx-ui-kit-action-base-map))
            (with-temp-buffer
              (insert a)
              (goto-char 1)
              (let ((last-input-event ?\r))
                (call-interactively #'drgnx-ui-kit-activate))
              (should (equal got '(1))))))
      (drgnx-ui-kit-undefine-action 'kit-test))))

(ert-deftest drgnx-ui-kit/unknown-action-kind-says-so ()
  (with-temp-buffer
    (insert (propertize "x" 'drgnx-action '("kit-no-such-kind" 1)))
    (goto-char 1)
    (let* ((last-input-event ?\r)
           (err (should-error (drgnx-ui-kit-activate) :type 'user-error)))
      (should (string-match-p "kit-no-such-kind" (cadr err))))))

(ert-deftest drgnx-ui-kit/action-kinds-undefined-on-teardown ()
  ;; a module's setup defines a kind; turning the module off undefines it
  (ert-with-temp-directory dir
                           (let ((file (expand-file-name "fake-kit-actions.el" dir)))
                             (with-temp-file file
                               (insert ";;; fake-kit-actions.el --- a fake module -*- lexical-binding: t -*-\n"
                                       "(drgnx-module-define 'test/kit-actions :doc \"an action kind\"\n"
                                       "  :setup (lambda () (drgnx-ui-kit-define-action 'kit-fake #'ignore nil)))\n"))
                             (drgnx-test-with-modules (list file) :strict t
                                                      (should (gethash 'kit-fake drgnx-ui-kit--actions)))
                             (should-not (gethash 'kit-fake drgnx-ui-kit--actions)))))

(ert-deftest drgnx-ui-kit/focus-visible-follows-keys-not-the-mouse ()
  (let ((drgnx-ui-kit--focus-visible nil))
    (let ((last-input-event ?a)) (drgnx-ui-kit--note-input))
    (should (drgnx-ui-kit-focus-visible-p))
    (let ((last-input-event `(mouse-1 ,(posn-at-point (point-min))))) (drgnx-ui-kit--note-input))
    (should-not (drgnx-ui-kit-focus-visible-p))
    (let ((last-input-event 'tab)) (drgnx-ui-kit--note-input))
    (should (drgnx-ui-kit-focus-visible-p))
    ;; the mode puts the named function on `pre-command-hook' and takes it off
    (unwind-protect
        (progn (drgnx-ui-kit-focus-mode 1)
               (should (memq #'drgnx-ui-kit--note-input (default-value 'pre-command-hook))))
      (drgnx-ui-kit-focus-mode -1))
    (should-not (memq #'drgnx-ui-kit--note-input (default-value 'pre-command-hook)))))

(ert-deftest drgnx-ui-kit/row-call-allocates-no-closure ()
  ;; a header-line pad, drawn per redisplay: after a warm-up, 1000 calls make no vector (no closure, no table)
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
            ((symbol-function 'drgnx-pixels-scale) (lambda (&optional _) 1.25)))
    (let ((props '(:c "row" :kind "list" :text "a")))
      (drgnx-ui-kit-string 'row props 'header-line nil)
      (let ((before (nth 2 (memory-use-counts))))
        (dotimes (_ 1000) (drgnx-ui-kit-string 'row props 'header-line nil))
        (should (= (- (nth 2 (memory-use-counts)) before) 0))))))

;; The catalogue (Design: Component Catalogue): a cell per variant and state, each a drawn component
(defun ui-kit-test--catalogue ()
  (unless (featurep 'drgnx-kit-catalogue)
    (load (expand-file-name "modules/ui/drgnx-kit-catalogue" drgnx-dir) nil t)))

(ert-deftest drgnx-ui-kit/catalogue-lists-every-cell ()
  (ui-kit-test--catalogue)
  (let ((buf (drgnx-kit-catalogue-open 'row)))
    (unwind-protect
        (with-current-buffer buf
          (let ((cells (drgnx-kit-catalogue-cells)))
            ;; row: 3 kinds x 7 states, in order
            (should (= 21 (length cells)))
            (should (equal (mapcar (lambda (c) (list (nth 0 c) (nth 1 c) (nth 2 c))) cells)
                           (cl-loop for k in '(list tree map)
                                    append (mapcar (lambda (st) (list 'row (list k) st)) drgnx-ui-kit-states))))
            (pcase-dolist (`(,_ ,variants ,state ,beg ,end) cells)
              ;; each cell is the kit's expansion, dressed as the hub's rows are: the state's face on its text
              (let ((e (drgnx-ui-kit-expand 'row (drgnx-kit-catalogue--props 'row (list (cons 'kind (car variants))) state)
                                            (drgnx-pixels-scale (selected-frame))
                                            (cond ((display-graphic-p) nil) ((drgnx-ui-ascii-frame-p) 'ascii) (t t)))))
                (should (equal (plist-get e :text) (buffer-substring-no-properties beg end)))
                (when-let* ((face (plist-get (drgnx-ui-kit-state state) :face)))
                  (let ((at (get-text-property (1- end) 'face)))
                    (should (memq face (ensure-list at)))))))))
      (kill-buffer buf))))

;;;; Buttons and key hints (Task 12)

(defmacro ui-kit-test--gui (scale &rest body)
  "BODY as on a graphical frame at SCALE with a 10 px column."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
             ((symbol-function 'drgnx-pixels-scale) (lambda (&optional _) ,scale))
             ((symbol-function 'frame-char-width) (lambda (&optional _) 10)))
     ,@body))

(ert-deftest drgnx-ui-kit/button-geometry ()
  ;; md is 26 px with 12 px each side, sm 22 with 8; a key hint sits one gap (6) after the label inside the button; each
  ;; style has its own kit face and the state's face is above it
  (let ((go (lambda (style size &rest more)
              (drgnx-ui-kit-expand 'button (append (list :c "button" :label "Go" :style style :size size) more) 1.0 nil))))
    (let ((e (funcall go "primary" "md")))
      (should (equal (plist-get e :spaces) [[0 12 0] [3 12 0]]))
      (should (equal (plist-get e :height) '(:lines 1 :unit 26)))
      (should (equal (plist-get e :runs) [[0 4 "drgnx-kit-button-primary"]])))
    (let ((e (funcall go "quiet" "sm")))
      (should (equal (plist-get e :spaces) [[0 8 0] [3 8 0]]))
      (should (equal (plist-get e :height) '(:lines 1 :unit 22)))
      (should (equal (plist-get e :runs) [[0 4 "drgnx-kit-button-quiet"]])))
    (should (equal (plist-get (funcall go "danger" "md") :runs) [[0 4 "drgnx-kit-button-danger"]]))
    (should (equal (plist-get (funcall go "secondary" "md") :runs) [[0 4 "drgnx-kit-button-secondary"]]))
    ;; 12 px at 1.25 is 15, 26 is 33 (half up)
    (let ((e (drgnx-ui-kit-expand 'button '(:c "button" :label "Go" :style "primary") 1.25 nil)))
      (should (equal (plist-get e :spaces) [[0 15 0] [3 15 0]]))
      (should (equal (plist-get e :height) '(:lines 1 :unit 33))))
    ;; the key hint: a gap, the keys in their 5 px box, then the end pad; the button's fill runs under the key's box
    (let ((e (funcall go "secondary" "md" :key "⏎")))
      (should (equal (plist-get e :text) " Go  ⏎  "))
      (should (equal (plist-get e :spaces) [[0 12 0] [3 6 0] [4 5 0] [6 5 0] [7 12 0]]))
      (should (equal (plist-get e :runs)
                     [[0 4 "drgnx-kit-button-secondary"] [4 7 "drgnx-kit-key-hint-cap"] [7 8 "drgnx-kit-button-secondary"]
                      [4 7 "drgnx-kit-button-secondary"]])))
    ;; a state is above the style's own colours
    (should (equal (aref (plist-get (funcall go "primary" "md" :state "disabled") :runs) 0)
                   [0 4 "drgnx-text-disabled"]))
    ;; on a terminal: a space each side, the key as [KEY]
    (let ((e (drgnx-ui-kit-expand 'button '(:c "button" :label "Go" :key "C-c") 1.0 t)))
      (should (equal (plist-get e :text) " Go [C-c] "))
      (should-not (plist-get e :height)))))

(ert-deftest drgnx-ui-kit/key-hint-forms ()
  (let ((e (drgnx-ui-kit-expand 'key-hint '(:c "key-hint" :keys "C-x") 1.0 nil)))
    (should (equal (plist-get e :text) " C-x "))
    (should (equal (plist-get e :spaces) [[0 5 0] [4 5 0]]))
    (should (equal (plist-get e :runs) [[0 5 "drgnx-kit-key-hint-cap"]])))
  ;; the menu variant is the text alone, in its own face
  (let ((e (drgnx-ui-kit-expand 'key-hint '(:c "key-hint" :keys "C-x" :variant "menu") 1.0 nil)))
    (should (equal (plist-get e :text) "C-x"))
    (should (equal (plist-get e :spaces) []))
    (should (equal (plist-get e :runs) [[0 3 "drgnx-kit-key-hint-menu"]])))
  (should (equal (plist-get (drgnx-ui-kit-expand 'key-hint '(:c "key-hint" :keys "C-x") 1.0 t) :text) "[C-x]"))
  (should (equal (plist-get (drgnx-ui-kit-expand 'key-hint '(:c "key-hint" :keys "C-x" :variant "menu") 1.0 'ascii) :text) "C-x"))
  ;; a state is above the ring
  (should (equal (aref (plist-get (drgnx-ui-kit-expand 'key-hint '(:c "key-hint" :keys "C-x" :state "hover") 1.0 nil) :runs) 0)
                 [0 5 "drgnx-hover"]))
  (should (equal (plist-get (drgnx-ui-kit-component 'key-hint) :label) "key")))

(ert-deftest drgnx-ui-kit/button-hit-area-carries-the-action ()
  ;; the padding at both ends carries the action and the kind's keymap: a click or RET on the padding runs it
  (let ((ran nil))
    (ui-kit-test--gui 1.0
      (let ((s (drgnx-ui-kit-button "Go" (lambda () (push 'ran ran)) 'primary 'md 'rest nil 'text)))
        (should (equal (substring-no-properties s) "  Go  "))
        (should (equal (get-text-property 0 'display s) '(space :width 0.4)))      ; 4 px of a 10 px column
        (dolist (at (list 0 1 3 (1- (length s))))
          (should (get-text-property at 'drgnx-action s))
          (should (keymapp (get-text-property at 'keymap s))))
        (should (equal (get-text-property 0 'mouse-face s) 'drgnx-hover))
        (with-temp-buffer
          (insert s)
          (goto-char 1)
          (let ((last-input-event ?\r)) (call-interactively #'drgnx-ui-kit-activate))
          (goto-char (1- (point-max)))
          (let ((last-input-event ?\r)) (call-interactively #'drgnx-ui-kit-activate)))
        (should (equal ran '(ran ran)))))
    ;; a kit action (KIND . ARGS) and a registry-less command are taken as they are
    (let ((got nil))
      (unwind-protect
          (progn
            (drgnx-ui-kit-define-action 'kit-btn (lambda (args) (setq got args)) nil)
            (ui-kit-test--gui 1.0
              (with-temp-buffer
                (insert (drgnx-ui-kit-button "Go" '(kit-btn 7) 'secondary 'sm 'rest nil 'text))
                (goto-char 3)
                (let ((last-input-event ?\r)) (call-interactively #'drgnx-ui-kit-activate))
                (should (equal got '(7))))))
        (drgnx-ui-kit-undefine-action 'kit-btn)))))

(ert-deftest drgnx-ui-kit/button-focus-ring-only-after-keys ()
  ;; the ring (the `focus-visible' state's face) shows after a key event, not after a mouse event
  (ui-kit-test--gui 1.0
    (let ((drgnx-ui-kit--focus-visible nil))
      (let ((s (drgnx-ui-kit-button "Go" #'ignore 'primary 'md 'focus-visible nil 'header-line)))
        (should-not (memq 'drgnx-focus (ensure-list (get-text-property 3 'face s)))))
      (setq drgnx-ui-kit--focus-visible t)
      (let ((s (drgnx-ui-kit-button "Go" #'ignore 'primary 'md 'focus-visible nil 'header-line)))
        (should (eq 'drgnx-focus (car (ensure-list (get-text-property 3 'face s)))))))))

(ert-deftest drgnx-ui-kit/text-button-is-a-button-el-button ()
  ;; a kit button in text that `push-button' and `forward-button' reach, the helpers' sites rely on it
  (let ((ran nil))
    (ui-kit-test--gui 1.0
      (with-temp-buffer
        (insert "a " (drgnx-ui-kit-text-button "[Go]" (lambda () (setq ran t)) "Run it" 'secondary 'sm) " b")
        (goto-char (point-min))
        (search-forward "[Go]")
        (should (button-at (1- (point))))
        (should (equal (get-text-property (1- (point)) 'help-echo) "Run it"))
        (should (eq (get-text-property (1- (point)) 'face) 'drgnx-kit-button-secondary))
        (push-button (1- (point)))
        (should ran)))))

;;;; Section headers and cards (Task 18)

(ert-deftest drgnx-ui-kit/section-header-forms ()
  ;; 26 px, 6 px each side; collapsible: the twisty glyph and a space (open: down, collapsed: right); a count in the
  ;; subtle role after a 4 px gap; a terminal has its characters
  (let ((e (drgnx-ui-kit-expand 'section-header '(:c "section-header" :title "Files") 1.0 nil)))
    (should (equal (plist-get e :text) " Files "))
    (should (equal (plist-get e :spaces) [[0 6 0] [6 6 0]]))
    (should (equal (plist-get e :height) '(:lines 1 :unit 26)))
    (should (equal (plist-get e :runs) [[0 7 "drgnx-kit-section-header"]])))
  (let ((e (drgnx-ui-kit-expand 'section-header '(:c "section-header" :title "Changes" :collapsible t :count 12) 1.0 nil)))
    (should (equal (plist-get e :text) " ⌄ Changes 12 "))
    (should (equal (plist-get e :spaces) [[0 6 0] [10 4 0] [13 6 0]])))
  (should (equal (plist-get (drgnx-ui-kit-expand 'section-header '(:c "section-header" :title "Staged" :collapsible t :collapsed t)
                                                 1.0 'ascii)
                            :text)
                 " > Staged "))
  ;; the accessible text of the constructor
  (ui-kit-test--gui 1.0
    (should (equal (get-text-property 0 'help-echo (drgnx-ui-kit-section-header "Staged" t t nil 'header-line)) "Staged, collapsed"))
    (should (equal (get-text-property 0 'help-echo (drgnx-ui-kit-section-header "Staged" t nil nil 'header-line)) "Staged, expanded"))))

(ert-deftest drgnx-ui-kit/card-lines-have-no-gaps ()
  ;; a 3-line card: top, mid, bottom shapes, each row's text, its closing stretch and nothing else in the row's face; the
  ;; newline is unfaced (a box run must not span lines); a one-line card is single; a kind has its own faces
  (let* ((s (drgnx-ui-kit-card-lines '("one" "two" "three") 'plain 8)) (rows (split-string s "\n" t)) (want '(drgnx-kit-card-plain-top drgnx-kit-card-plain-mid drgnx-kit-card-plain-bottom)) (pos 0))
    (should (= (length rows) 3))
    (dolist (w want)
      (let ((row-end (+ pos (length (pop rows)))))
        (dotimes (i (- row-end pos)) (should (eq w (get-text-property (+ pos i) 'face s))))
        (should-not (get-text-property row-end 'face s))
        (setq pos (1+ row-end)))))
  (should (eq 'drgnx-kit-card-selected-single (get-text-property 0 'face (drgnx-ui-kit-card-lines '("x") 'selected 4))))
  (should (eq 'drgnx-kit-card-needs-you-top (get-text-property 0 'face (drgnx-ui-kit-card-lines '("x" "y") 'needs-you 4))))
  ;; each row is filled to the width and closed by a stretch to the column after it
  (let ((s (drgnx-ui-kit-card-lines '("ab") 'plain 5)))
    (should (equal (substring-no-properties s) "ab    \n"))
    (should (equal (get-text-property 5 'display s) '(space :align-to 6)))))

(ert-deftest drgnx-ui-kit/card-line-forms ()
  (let ((e (drgnx-ui-kit-expand 'card '(:c "card" :kind "selected" :shape "mid" :text "Go") 1.0 nil)))
    (should (equal (plist-get e :text) " Go "))
    (should (equal (plist-get e :spaces) [[0 8 0] [3 8 0]]))
    (should (equal (plist-get e :runs) [[0 4 "drgnx-kit-card-selected-mid"]]))))

;; The unknown-face counter (test mode): a row naming a face that is none, and is not in etc/ui/faces.eld, is counted
(defvar drgnx-test-strict-faces)
(defvar drgnx-view-unknown-faces)
(declare-function drgnx-view-patch--face "drgnx-view" (name))

(ert-deftest drgnx-ui-kit/unknown-face-is-counted-in-test-mode ()
  (require 'drgnx-view)
  (let ((drgnx-test-strict-faces t) (drgnx-view-unknown-faces (make-hash-table :test #'equal)))
    (should-not (drgnx-view-patch--face "drgnx-no-such-face"))
    (should (equal 1 (gethash "drgnx-no-such-face" drgnx-view-unknown-faces)))
    ;; a known face of a module that is off (extra/hunks, not loaded here) is no stale name
    (should-not (facep 'drgnx-hunk-added))
    (should-not (drgnx-view-patch--face "drgnx-hunk-added"))
    (should-not (gethash "drgnx-hunk-added" drgnx-view-unknown-faces))
    ;; out of test mode nothing is counted
    (let ((drgnx-test-strict-faces nil))
      (drgnx-view-patch--face "drgnx-no-such-face"))
    (should (equal 1 (gethash "drgnx-no-such-face" drgnx-view-unknown-faces)))))

(ert-deftest drgnx-ui-kit/unknown-face-fails-the-file ()
  ;; a nested run of a fixture file whose one test passes but draws a row naming an unknown face: the file is an
  ;; unexpected result naming the face
  (let* ((tmp (make-temp-file "drgnx-faces" t)) (results (expand-file-name "results.json" tmp))
         (file (expand-file-name "faces-test.el" tmp)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert ";;; faces-test.el -*- lexical-binding: t -*-\n(require 'ert)\n"
                    (format "(dolist (d '(\"core\" \"wb\")) (add-to-list 'load-path (expand-file-name d %S)))\n" drgnx-dir)
                    "(require 'drgnx-view)\n"
                    "(ert-deftest faces-fixture/draws-a-stale-face () (drgnx-view-patch--face \"drgnx-no-such-face\") (should t))\n"))
          (let ((process-environment (append (list (concat "DRGNX_TEST_RESULTS=" results) "DRGNX_TEST_STRICT_FACES=1"
                                                   "DRGNX_TEST_SELECTOR" "DRGNX_TEST_LEAKS" "DRGNX_TEST_SHUFFLE")
                                             process-environment)))
            (should (eql 1 (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                                         "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                                         "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" tmp))))
          (let* ((r (json-parse-string (with-temp-buffer (insert-file-contents results) (buffer-string)) :object-type 'plist))
                 (names (mapcar (lambda (f) (plist-get f :name)) (plist-get r :failures))))
            (should (seq-some (lambda (n) (string-match-p "faces-test\\.el: unknown faces: drgnx-no-such-face (1)" n)) names))))
      (delete-directory tmp t))))

;; The state table everywhere (Task 9): every row selection reads `drgnx-row-selected', which follows the focus
(declare-function drgnx-ui-kit-focus-remap "drgnx-ui-kit" (window))
(declare-function drgnx-ui-kit-focus-remap-enable "drgnx-ui-kit")
(declare-function drgnx-ui-kit-state-face "drgnx-ui-kit" (state))

(ert-deftest drgnx-ui-kit/every-selected-face-reads-the-state-table ()
  (require 'drgnx-view)
  (require 'drgnx-explorer)
  (dolist (f '("modules/tools/drgnx-work-space" "modules/lang/drgnx-notebook"))
    (load (expand-file-name f drgnx-dir) nil t))
  (let ((replaces (plist-get (drgnx-ui-kit-component 'row) :replaces)))
    (should (assq 'drgnx-view-selected replaces))
    (should (plist-get (drgnx-ui-kit-component 'row) :lint))
    (should (eq (drgnx-ui-kit-state-face 'selected) 'drgnx-selected))
    (should (eq (drgnx-ui-kit-state-face 'selected-inactive) 'drgnx-selected-inactive))
    (unwind-protect
        (progn
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme 'drgnx-dark t)
          (should (eq 'drgnx-selected-inactive (face-attribute 'drgnx-row-selected :inherit)))
          (pcase-dolist (`(,old . ,kit) replaces)
            (should (facep old))
            ;; the old face inherits its kit face and the theme leaves it alone
            (should (equal (list old kit) (list old (car (ensure-list (face-attribute old :inherit))))))
            (should (equal (list old (face-attribute kit :background nil t))
                           (list old (face-attribute old :background nil t))))))
      (mapc #'disable-theme custom-enabled-themes))))

(ert-deftest drgnx-ui-kit/unfocused-list-shows-sel-inactive ()
  ;; a list's selection is the full selection while its window is the selected one and the inactive one otherwise
  ;; (the remap follows `window-selection-change-functions'); the inactive one is >= 1.25:1 on the panel
  (let ((list (get-buffer-create " *kit-list*")) (other (get-buffer-create " *kit-other*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer list)
          (drgnx-ui-kit-focus-remap-enable)
          (let ((lw (selected-window)) (ow (split-window)))
            (set-window-buffer ow other)
            (drgnx-ui-kit-focus-remap lw)
            (with-current-buffer list
              (should (memq 'drgnx-selected (ensure-list (alist-get 'drgnx-row-selected face-remapping-alist)))))
            (select-window ow)
            (drgnx-ui-kit-focus-remap lw)
            (with-current-buffer list
              (should-not (alist-get 'drgnx-row-selected face-remapping-alist)))
            (select-window lw)
            (drgnx-ui-kit-focus-remap lw)
            (with-current-buffer list
              (should (memq 'drgnx-selected (ensure-list (alist-get 'drgnx-row-selected face-remapping-alist)))))))
      (kill-buffer list) (kill-buffer other)))
  (dolist (v '(dark light hc))
    (should (<= 1.25 (drgnx-color-contrast (drgnx-look-token 'sel-inactive v) (drgnx-look-token 'panel v))))))

(ert-deftest drgnx-ui-kit/rows-are-in-the-ui-font ()
  ;; a row's text and pads are in its kit face, which is the UI font (the mockups' Explorer and lists), on a graphical
  ;; display and a terminal alike
  (should (memq 'drgnx-ui-text (ensure-list (face-attribute 'drgnx-kit-row :inherit))))
  ;; and drgnx's themes keep it (a theme's spec replaces the defface's)
  (unwind-protect
      (progn (mapc #'disable-theme custom-enabled-themes)
             (load-theme 'drgnx-dark t)
             (should (memq 'drgnx-ui-text (ensure-list (face-attribute 'drgnx-kit-row :inherit nil t)))))
    (mapc #'disable-theme custom-enabled-themes))
  ;; every character of the row is in a `drgnx-kit-row' run (the twisty's subtle run lies over its own)
  (dolist (tty '(nil t))
    (let* ((e (drgnx-ui-kit-expand 'row '(:kind "tree" :depth 1 :twisty t :text "src") 1.0 tty))
           (len (length (plist-get e :text)))
           (bare (cl-loop for i below len
                          unless (cl-some (lambda (r) (and (equal (aref r 2) "drgnx-kit-row") (<= (aref r 0) i)
                                                           (< i (aref r 1))))
                                          (plist-get e :runs))
                          collect i)))
      (should (equal (list tty :outside-the-row-face nil) (list tty :outside-the-row-face bare))))))

(ert-deftest drgnx-ui-kit/row-icons-are-images-with-the-gap ()
  ;; the hub's twisty_and_icon_are_images_where_the_env_draws_icons, in Lisp: where icons are drawn, the chevron and
  ;; the icon are images (a `display' prop each), each with the row's gap (6 at 1.25: 8) after it; else glyphs
  (let* ((props '(:kind "tree" :twisty t :icon "folder" :text "src"))
         (e (let ((drgnx-ui-kit--icons (lambda (name px) (list 'image :type 'svg :data (format "%s %s" name px)))))
              (drgnx-ui-kit-expand 'row props 1.25 nil))))
    (should (equal (plist-get e :text) "     src "))
    (should (equal (plist-get e :spaces) [[0 8 0] [2 8 0] [4 8 0] [8 8 0]]))
    (should (equal (mapcar (lambda (p) (list (aref p 0) (aref p 2) (plist-get (cdr (append (aref p 3) nil)) :data)))
                           (plist-get e :props))
                   '((1 "display" "chevron-down 16") (3 "display" "folder 16"))))
    (let ((plain (drgnx-ui-kit-expand 'row props 1.25 nil))
          (subtle (lambda (e) (delq nil (mapcar (lambda (r) (and (equal (aref r 2) "drgnx-text-subtle")
                                                                 (list (aref r 0) (aref r 1))))
                                                (plist-get e :runs))))))
      (should (string-prefix-p " ⌄ " (plist-get plain :text)))
      (should (equal (plist-get plain :props) []))
      ;; the twisty (image or glyph) in the subtle role, the icon in the row's colours (the mockups' chevrons)
      (should (equal (funcall subtle e) '((1 2))))
      (should (equal (funcall subtle plain) '((1 2)))))))

;; Agent marks and progress (Task 15)
(ert-deftest drgnx-ui-kit/progress-has-its-percent-label ()
  ;; a bar's and a ring's label is "N percent" (rounded half up), on their whole text; a bar is its fill, then the
  ;; track, and on a terminal its cells between edges
  (pcase-dolist (`(,kind ,value ,word) '((bar 0.425 "43 percent") (ring 0.6 "60 percent") (bar 0 "0 percent")))
    (let ((e (drgnx-ui-kit-expand 'progress (list :c "progress" :kind (symbol-name kind) :value value :width 80) 1.0 nil)))
      (should (equal (list kind word) (list kind (aref (aref (plist-get e :props) 0) 3))))
      (should (equal "help-echo" (aref (aref (plist-get e :props) 0) 2)))))
  (let ((e (drgnx-ui-kit-expand 'progress '(:c "progress" :kind "bar" :value 0.25 :width 80) 1.0 nil)))
    (should (equal [[0 20 4] [1 60 4]] (plist-get e :spaces)))
    (should (equal [[0 1 "drgnx-kit-progress-fill"] [1 2 "drgnx-kit-progress"]] (plist-get e :runs))))
  (let ((drgnx-face-glyphs drgnx-ui--default-glyphs))
    ;; ten cells: three full; 0.35 is three and a half (a half block), on ASCII rounded to four
    (should (equal "███░░░░░░░" (plist-get (drgnx-ui-kit-expand 'progress '(:c "progress" :value 0.3 :width 80) 1.0 t) :text)))
    (should (equal "███▌░░░░░░"
                   (plist-get (drgnx-ui-kit-expand 'progress '(:c "progress" :value 0.35 :width 80) 1.0 t) :text)))
    (should (equal "[####------]"
                   (plist-get (drgnx-ui-kit-expand 'progress '(:c "progress" :value 0.35 :width 80) 1.0 'ascii) :text)))
    (should (equal "2" (plist-get (drgnx-ui-kit-expand 'progress '(:c "progress" :kind "ring" :value 0.5) 1.0 'ascii) :text)))))

(ert-deftest drgnx-ui-kit/bar-parts-are-images ()
  ;; a progress bar's parts (spaces of a height in the bar's faces) are drawn as images in `currentColor', the fill's
  ;; start and the track's end rounded, the joint square; a space of a height in another face stays a space
  (skip-unless (image-type-available-p 'svg))
  (let* ((d (drgnx-ui-kit-bar-display '((0 72 4) (1 48 4) (3 10 16))
                                      '((0 1 "drgnx-kit-progress-fill") (1 2 drgnx-kit-progress) (3 4 "drgnx-explorer-guide"))
                                      1.0))
         (fill (cdr (assq 0 d))) (track (cdr (assq 1 d))))
    (should (equal '(0 1) (sort (mapcar #'car d) #'<)))
    (should (eq 'image (car fill)))
    (should (eq 'center (plist-get (cdr fill) :ascent)))
    (should (string-search "width=\"72\" height=\"4\"" (plist-get (cdr fill) :data)))
    (should (string-search "fill=\"currentColor\"" (plist-get (cdr fill) :data)))
    (should (string-search "rx=\"2\"" (plist-get (cdr fill) :data)))
    ;; the fill's end and the track's start are joined: square there
    (should (string-search "<rect x=\"36.0\"" (plist-get (cdr fill) :data)))
    (should-not (string-search "<rect width=\"36.0\"" (plist-get (cdr fill) :data)))
    (should (string-search "<rect width=\"24.0\"" (plist-get (cdr track) :data)))))

(ert-deftest drgnx-ui-kit/agent-mark-is-its-agents-colour ()
  ;; the handle on its agent's colour: the kit face (inverse video) over the agent's face, pads either side; "[H]" in
  ;; the colour on a terminal; its label "agent H"
  (let ((e (drgnx-ui-kit-expand 'agent-mark '(:c "agent-mark" :slot 3 :handle "Q") 1.0 nil)))
    (should (equal " Q " (plist-get e :text)))
    (should (equal [[0 3 "drgnx-kit-agent-mark"] [0 3 "drgnx-agent-3"]] (plist-get e :runs)))
    (should (equal [[0 5 0] [2 5 0]] (plist-get e :spaces)))
    (should (equal [[0 3 "help-echo" "agent Q"]] (plist-get e :props))))
  (should (face-attribute 'drgnx-kit-agent-mark :inverse-video nil t))
  (let ((e (drgnx-ui-kit-expand 'agent-mark '(:c "agent-mark" :slot 12 :handle "Qx") 1.0 t)))
    (should (equal "[Qx]" (plist-get e :text)))
    (should (equal [[0 4 "drgnx-agent-12"]] (plist-get e :runs)))))

(ert-deftest drgnx-ui-kit/agent-cursors-still-move ()
  ;; the agent cursors live in their own file now (decor keeps the chips, buttons and cards): put, moved at once and
  ;; batched, removed
  (load (expand-file-name "modules/ui/drgnx-decor" drgnx-dir) nil t)
  (load (expand-file-name "modules/ui/drgnx-agent-cursors" drgnx-dir) nil t)
  (should (featurep 'drgnx-agent-cursors))
  (should-not (fboundp 'drgnx-decor-cursor-put))
  (with-temp-buffer
    (insert (make-string 20 ?x))
    (let ((ov (drgnx-agent-cursor-put (current-buffer) 'a 2 "#123456" "A")))
      (unwind-protect
          (progn
            (drgnx-agent-cursor-move-now (current-buffer) 'a 9)
            (should (= 9 (overlay-start ov)))
            (should (eq ov (drgnx-agent-cursor-overlay (current-buffer) 'a))))
        (drgnx-agent-cursor-remove (current-buffer) 'a)))
    (should-not (drgnx-agent-cursor-overlay (current-buffer) 'a))))

(provide 'ui-kit-test)
;;; ui-kit-test.el ends here
