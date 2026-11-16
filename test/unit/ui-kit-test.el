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
  ;; a theme that knows nothing of drgnx still gives every kit face a fill or a ring, through the standard faces it
  ;; inherits: checked on the real faces, and on the fixture's specs (the real file may have few faces yet)
  (dolist (theme '(modus-vivendi doom-one-fixture))
    (unwind-protect
        (progn
          (mapc #'disable-theme custom-enabled-themes)
          (if (get theme 'theme-settings) (enable-theme theme) (load-theme theme t))
          (dolist (f (append (drgnx-ui-kit-face-bindings) (drgnx-ui-kit-face-bindings ui-kit-test--fixture)))
            (let ((inherit (plist-get (nth 2 f) :inherit)))
              (should inherit)
              (should (cl-some (lambda (parent)
                                 (or (drgnx-face-color parent :background 'gui)
                                     (plist-get (drgnx-faces--clause-plist parent 'gui) :box)))
                               inherit))
              (when (facep (car f))
                (should (or (drgnx-face-color (car f) :background 'gui)
                            (plist-get (drgnx-faces--clause-plist (car f) 'gui) :box)))))))
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
        (let* ((w (aref want i))
               (comp (plist-get c :comp))
               (got (drgnx-ui-kit-expand (intern (plist-get comp :c)) comp (float (plist-get e :scale))
                                         (and (eq (plist-get e :tty) t) (if (eq (plist-get e :ascii) t) 'ascii t)))))
          (should (equal (plist-get w :name) (format "%s/%s" (plist-get e :name) (plist-get c :name))))
          (dolist (k '(:text :runs :props :spaces))
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

(provide 'ui-kit-test)
;;; ui-kit-test.el ends here
