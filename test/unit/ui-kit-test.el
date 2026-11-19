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
          (dolist (glyph (append (drgnx-ui-kit--glyphs-in (plist-get tty :glyph)) (drgnx-ui-kit--glyphs-in (plist-get tty :twisty))))
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

(ert-deftest drgnx-ui-kit/ascii-terminal-status-dot-has-its-word ()
  ;; a terminal has no colour to carry the status alone: its dot always has the word, in ASCII where the glyphs are
  (let ((drgnx-face-glyphs drgnx-ui--default-glyphs))
    (dolist (s '((done "+ done") (running "@ running") (needs-you "* needs you") (idle "o not started") (error "X error")))
      (should (equal (plist-get (drgnx-ui-kit-expand 'status-dot (list :c "status-dot" :status (symbol-name (car s))) 1.0 'ascii)
                                :text)
                     (cadr s))))
    ;; on a graphical frame the word is asked for
    (should (equal (plist-get (drgnx-ui-kit-expand 'status-dot '(:c "status-dot" :status "needs-you") 1.0 nil) :text)
                   (car (alist-get 'dot drgnx-ui--default-glyphs))))
    (should (equal (plist-get (drgnx-ui-kit-expand 'status-dot '(:c "status-dot" :status "needs-you" :word t) 1.0 nil) :text)
                   (concat (car (alist-get 'dot drgnx-ui--default-glyphs)) " needs you")))))

(ert-deftest drgnx-ui-kit/chip-hc-is-ringed ()
  ;; high contrast has no tints: a soft chip has a 1 px ring in its text colour instead; a solid one keeps its fill
  (let* ((tok (lambda (token) (symbol-name token)))
         (soft (assq 'drgnx-kit-chip-ok-soft (drgnx-ui-kit-theme-specs tok nil t)))
         (solid (assq 'drgnx-kit-chip-ok-solid (drgnx-ui-kit-theme-specs tok nil t)))
         (normal (assq 'drgnx-kit-chip-ok-soft (drgnx-ui-kit-theme-specs tok nil nil))))
    (should (equal (plist-get (cdr soft) :box) '(:line-width (-1 . -1) :color "ok")))
    (should-not (plist-get (cdr soft) :background))
    (should (equal (plist-get (cdr solid) :background) "ok"))
    (should (equal (plist-get (cdr normal) :background) "ok-tint"))
    (should-not (plist-get (cdr normal) :box))))

(ert-deftest drgnx-ui-kit/buttons-are-rounded-under-glitnir ()
  ;; the button's geometry names radius 6: a ringed button face (secondary, primary and danger: the filled ones ring in
  ;; their own fill) carries it as its box's corner radius where Glitnir draws it, none otherwise
  (let ((tok (lambda (token) (symbol-name token))))
    (dolist (style '(primary secondary danger))
      (let* ((name (intern (format "drgnx-kit-button-%s" style)))
             (round (plist-get (cdr (assq name (drgnx-ui-kit-theme-specs tok nil nil t))) :box))
             (plain (plist-get (cdr (assq name (drgnx-ui-kit-theme-specs tok nil nil nil))) :box)))
        (should (eql (plist-get round :corner-radius) 6))
        (should-not (plist-get plain :corner-radius))))))

(ert-deftest drgnx-ui-kit/chip-geometry ()
  (should (equal (plist-get (drgnx-ui-kit-geometry 'chip '(ok soft)) :height) 20))
  (should (equal (plist-get (drgnx-ui-kit-geometry 'chip '(ok soft)) :pad) '(7 . 7)))
  (should (equal (plist-get (drgnx-ui-kit-geometry 'chip '(ok soft)) :radius) 4)))

(ert-deftest drgnx-ui-kit/range-bar-states-carry-words ()
  ;; a terminal has no colour to say a bar is late: the cap and the word do (ASCII `!' and the word)
  (let ((drgnx-face-glyphs drgnx-ui--default-glyphs)
        (props '(:c "range-bar" :variant "schedule" :from 0 :to 100 :width 80 :state "late"
                    :spans (:done_to 30 :p50 50 :p90 100))))
    (should (equal (plist-get (drgnx-ui-kit-expand 'range-bar props 1.0 t) :text) "███▓▓░░░░░▌ late"))
    (should (equal (plist-get (drgnx-ui-kit-expand 'range-bar props 1.0 'ascii) :text) "###==-----! late"))
    (should (equal (plist-get (drgnx-ui-kit-expand 'range-bar (plist-put (copy-sequence props) :state "on-track") 1.0 t)
                              :text)
                   "███▓▓░░░░░"))))

(ert-deftest drgnx-ui-kit/segment-letters-in-hc-and-tty ()
  (let ((drgnx-face-glyphs drgnx-ui--default-glyphs))
    (dolist (c '(("wait-you" 32 "Y███") ("read" 32 "R███") ("stalled" 32 "!███") ("think" 16 "·█")))
      (should (equal (plist-get (drgnx-ui-kit-expand 'range-bar
                                                     (list :c "range-bar" :variant (list :segment (car c)) :from 0 :to 10
                                                           :width (cadr c) :state "on-track")
                                                     1.0 t)
                                :text)
                     (nth 2 c))))
    ;; thinking's letter is a dot in ASCII
    (should (equal (plist-get (drgnx-ui-kit-expand 'range-bar '(:c "range-bar" :variant (:segment "think") :from 0 :to 10
                                                                   :width 16 :state "on-track")
                                                   1.0 'ascii)
                              :text)
                   ".#"))))

(ert-deftest drgnx-ui-kit/seg-faces-are-aliases ()
  ;; the Timeline's segment faces inherit the kit's (kept until their callers move)
  (dolist (pair '((drgnx-work-seg-read . drgnx-kit-range-bar-seg-read) (drgnx-work-seg-edit . drgnx-kit-range-bar-seg-edit)
                  (drgnx-work-seg-tool . drgnx-kit-range-bar-seg-test) (drgnx-work-seg-think . drgnx-kit-range-bar-seg-think)
                  (drgnx-work-seg-job . drgnx-kit-range-bar-seg-job) (drgnx-work-seg-wait . drgnx-kit-range-bar-seg-wait)))
    (should (assq (car pair) (plist-get (drgnx-ui-kit-component 'range-bar) :replaces)))
    (should (eq (cdr pair) (cdr (assq (car pair) (plist-get (drgnx-ui-kit-component 'range-bar) :replaces)))))))

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

(defun ui-kit-test--answers (kind labels width)
  "A question card of KIND with LABELS' answers: (CARD-TEXT . ANSWERS), ANSWERS the indexes the card's handlers got."
  (let* ((got (list nil))
         (lines (drgnx-ui-kit-question-card
                 kind "Run cargo test?" "The agent wants to run a command in the project folder, and waits for you."
                 (mapcar (lambda (l) (list l nil (lambda (i) (push i (car got))))) labels) width)))
    (cons (apply #'concat lines) got)))

(ert-deftest drgnx-ui-kit/question-card-keys-answer ()
  ;; a bare key on the card answers (y/a/n a permission's Allow once, Always, Deny; 1..9 a question's; y/n a sign-off's),
  ;; through the card's action kind map; a click on its text answers nothing
  (dolist (case '((permission ("Allow once" "Always" "Deny") (("y" . 0) ("a" . 1) ("n" . 2)))
                  (question ("A" "B" "C") (("1" . 0) ("3" . 2)))
                  (sign-off ("Approve" "Request changes") (("y" . 0) ("n" . 1)))))
    (pcase-let* ((`(,kind ,labels ,keys) case) (c (ui-kit-test--answers kind labels 60)))
      (with-temp-buffer
        (insert (car c)) (goto-char (point-min))
        (dolist (k keys)
          (setcar (cdr c) nil)
          (cl-letf (((symbol-function 'this-command-keys-vector) (lambda () (kbd (car k)))))
            (drgnx-ui-kit-activate))
          (should (equal (list kind (car k) (cadr c)) (list kind (car k) (list (cdr k))))))
        (setcar (cdr c) nil)
        (cl-letf (((symbol-function 'this-command-keys-vector) (lambda () [mouse-1])))
          (drgnx-ui-kit-activate))
        (should-not (cadr c))))))

(ert-deftest drgnx-ui-kit/question-card-has-a-primary-first-button-and-the-head-tint ()
  (let* ((c (car (ui-kit-test--answers 'permission '("Allow once" "Deny") 60)))
         (lines (split-string c "\n" t)))
    (should (= (length lines) 5))
    (should (memq 'drgnx-kit-question-card-head
                  (ensure-list (get-text-property (string-match "Run cargo" (nth 0 lines)) 'face (nth 0 lines)))))
    (let* ((row (nth (- (length lines) 2) lines))
           (a (string-match "Allow once" row)) (d (string-match "Deny" row)))
      (should (memq 'drgnx-kit-button-primary (ensure-list (get-text-property a 'face row))))
      (should (memq 'drgnx-kit-button-secondary (ensure-list (get-text-property d 'face row)))))))

(defun ui-kit-test--merged-height (faces base &optional attr)
  "The ATTR (default `:height') Emacs gives text in FACES (a `face' property value) over the line face BASE: a probe face inheriting
FACES then BASE (an anonymous face in FACES becomes a face of its own), on `default'."
  (let ((inherit nil) (k 0))
    (dolist (f (if (and (consp faces) (not (keywordp (car faces)))) faces (list faces)))
      (cond ((and f (symbolp f)) (push f inherit))
            ((consp f) (let ((anon (intern (format "ui-kit-test--anon-%d" (setq k (1+ k))))))
                         (make-face anon)
                         (face-spec-set anon `((t ,@f)))
                         (push anon inherit)))))
    (make-face 'ui-kit-test--probe)
    (face-spec-set 'ui-kit-test--probe `((t :inherit ,(nreverse (cons base inherit)))))
    (face-attribute 'ui-kit-test--probe (or attr :height) nil 'default)))

(defun ui-kit-test--font-of (face)
  "The type face kit FACE takes its size from, read from the components file: its binding's `:font', else the first
type face in its `:inherit'; nil for a face that only colours."
  (let ((b (nth 2 (assq face (drgnx-ui-kit-face-bindings)))))
    (cl-find-if (lambda (x) (memq x '(drgnx-ui-text drgnx-ui-heading drgnx-ui-caption drgnx-ui-title drgnx-code-small)))
                (or (plist-get b :font) (plist-get b :inherit)))))

(ert-deftest drgnx-ui-kit/line-text-scales-once ()
  ;; a mode, header or tab line's face is under the kit's text; drgnx's themes give the header line the UI font's
  ;; relative size, and a kit face inheriting the UI font's relative size scaled it again (the panel tab's text 25 px
  ;; for 26 at scale 2); so would a kit face inheriting a standard face with a size (`tab-line', 0.9).  Every fixture
  ;; component on each line, over that line's face, with and without drgnx's theme: each character a kit face sizes
  ;; is its type face's size on `default', once, as Emacs merges the faces.  Red first: 0.963 twice.
  (require 'drgnx-look-density (expand-file-name "modules/ui/drgnx-look-density" drgnx-dir))
  (require 'tab-line)                   ; the tab's faces inherit its faces: undefined, the merge gives up
  (let ((drgnx-look-density 'comfortable) (drgnx-face-glyphs drgnx-ui--default-glyphs)
        (cases (plist-get (ui-kit-test--json "cases.json" 'list) :comps))
        (code (face-attribute 'default :height nil t)) (checked 0) (fails nil))
    (unwind-protect
        (dolist (theme '(nil drgnx-dark))
          (mapc #'disable-theme custom-enabled-themes)
          (when theme (load-theme theme t))
          (set-face-attribute 'default nil :height 135)
          ;; drgnx's header line scales: the case the check is for
          (when theme (should (/= 135 (face-attribute 'header-line :height nil 'default))))
          (dolist (where '(header-line tab-line mode-line))
            (dolist (c cases)
              (let* ((comp (plist-get c :comp))
                     ;; as on a graphical frame at scale 2 (the theme is loaded outside: it reads real colours)
                     (s (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                                  ((symbol-function 'drgnx-pixels-scale) (lambda (&optional _) 2.0)))
                          (drgnx-ui-kit-string (intern (plist-get comp :c)) comp where nil))))
                (dotimes (i (length s))
                  (let* ((faces (get-text-property i 'face s))
                         (font (cl-some (lambda (f) (and f (symbolp f) (ui-kit-test--font-of f)))
                                        (if (and (consp faces) (not (keywordp (car faces)))) faces (list faces)))))
                    (when font
                      (setq checked (1+ checked))
                      (let ((want (face-attribute font :height nil 'default))
                            (got (ui-kit-test--merged-height faces where)))
                        (unless (equal want got)
                          (push (list theme where (plist-get c :name) i font want got) fails))))))))))
      (mapc #'disable-theme custom-enabled-themes)
      (when (integerp code) (set-face-attribute 'default nil :height code)))
    (should (> checked 0))
    (should-not (seq-take (nreverse fails) 12))))

(ert-deftest drgnx-ui-kit/state-faces-carry-no-type ()
  ;; a state or surface face is a colour: under a theme that knows nothing of drgnx it must not bring `default's family
  ;; or code size over a kit face's text (a pressed or selected-inactive button took the code font).  Kit text of every
  ;; fixture component, on a line and in the buffer, merged over its base: the family and size are its type face's.
  ;; Red first: `drgnx-selected-quiet' -> `drgnx-surface-raised' -> `default'.
  (require 'drgnx-look-density (expand-file-name "modules/ui/drgnx-look-density" drgnx-dir))
  (require 'tab-line)
  (let ((drgnx-look-density 'comfortable) (drgnx-face-glyphs drgnx-ui--default-glyphs)
        (cases (plist-get (ui-kit-test--json "cases.json" 'list) :comps))
        (code (face-attribute 'default :height nil t)) (fam (face-attribute 'default :family nil t))
        (checked 0) (fails nil))
    (unwind-protect
        (progn
          (mapc #'disable-theme custom-enabled-themes)
          (set-face-attribute 'default nil :family "Adwaita Mono" :height 135)
          (dolist (where '(text header-line tab-line mode-line))
            (let ((base (if (eq where 'text) 'default where)))
              (dolist (c cases)
                (let* ((comp (plist-get c :comp))
                       (s (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                                    ((symbol-function 'drgnx-pixels-scale) (lambda (&optional _) 2.0)))
                            (drgnx-ui-kit-string (intern (plist-get comp :c)) comp where nil))))
                  (dotimes (i (length s))
                    (let* ((faces (get-text-property i 'face s))
                           (font (cl-some (lambda (f) (and f (symbolp f) (ui-kit-test--font-of f)))
                                          (if (and faces (consp faces) (not (keywordp (car faces)))) faces (list faces)))))
                      (when (and font (not (eq font 'drgnx-code-small)))
                        (setq checked (1+ checked))
                        (dolist (attr '(:family))
                          (let ((want (face-attribute font attr nil 'default))
                                (got (ui-kit-test--merged-height faces base attr)))
                            (unless (equal want got)
                              (push (list where (plist-get c :name) i attr font want got) fails)))))))))))
          (should (> checked 0))
          (should-not (seq-take (nreverse fails) 12))
          ;; and the colour faces themselves bring no family or size (the buffer's merge puts them over the text)
          (make-face 'ui-kit-test--blank)
          (dolist (f '(drgnx-surface-gap drgnx-surface-panel drgnx-surface-raised drgnx-surface-overlay drgnx-hover
                                         drgnx-selected drgnx-selected-quiet drgnx-selected-inactive drgnx-row-selected
                                         drgnx-selected-secondary drgnx-chip-attention drgnx-tint-warn drgnx-control))
            (dolist (attr '(:family :height))
              (should (eq 'unspecified (face-attribute f attr nil 'ui-kit-test--blank))))))
      (mapc #'disable-theme custom-enabled-themes)
      (set-face-attribute 'default nil :family fam)
      (when (integerp code) (set-face-attribute 'default nil :height code)))))

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
  ;; 26 px, 6 px each side; collapsible: the twisty glyph and a space (open: down, collapsed: right); a count is a
  ;; chip (the next test); a terminal has its characters
  (let ((e (drgnx-ui-kit-expand 'section-header '(:c "section-header" :title "Files") 1.0 nil)))
    (should (equal (plist-get e :text) " Files "))
    (should (equal (plist-get e :spaces) [[0 6 0] [6 6 0]]))
    (should (equal (plist-get e :height) '(:lines 1 :unit 26)))
    (should (equal (plist-get e :runs) [[0 7 "drgnx-kit-section-header"]])))
  (should (equal (plist-get (drgnx-ui-kit-expand 'section-header '(:c "section-header" :title "Staged" :collapsible t :collapsed t)
                                                 1.0 'ascii)
                            :text)
                 " > Staged "))
  ;; the accessible text of the constructor
  (ui-kit-test--gui 1.0
    (should (equal (get-text-property 0 'help-echo (drgnx-ui-kit-section-header "Staged" t t nil 'header-line)) "Staged, collapsed"))
    (should (equal (get-text-property 0 'help-echo (drgnx-ui-kit-section-header "Staged" t nil nil 'header-line)) "Staged, expanded"))))

(ert-deftest drgnx-ui-kit/section-header-count-is-a-chip ()
  ;; the count after the title is a neutral soft chip (its pads and its digits in the chip's face), not subtle text
  (dolist (tty '(nil t ascii))
    (let* ((e (drgnx-ui-kit-expand 'section-header '(:c "section-header" :title "Changes" :collapsible t :count 12)
                                   1.0 tty))
           (text (plist-get e :text)) (at (string-search "12" text))
           (runs (append (plist-get e :runs) nil)))
      (should at)
      (should (cl-some (lambda (r) (and (<= (aref r 0) at) (>= (aref r 1) (+ at 2))
                                        (equal (aref r 2) "drgnx-kit-chip-neutral-soft")))
                       runs))
      (should-not (cl-some (lambda (r) (equal (aref r 2) "drgnx-text-subtle")) runs)))))

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

(ert-deftest drgnx-ui-kit/diff-block-rows-carry-their-part-and-the-ring ()
  "A diff block: the head row, the hunk's @@ row and its lines, each in its part's kit face, the ring open between
rows; the head carries the counts and the buttons; its help-echo says the file and the counts."
  (let* ((fired nil)
         (s (drgnx-ui-kit-diff-block "a.rs" 1 1 '(("@@ -1 +1 @@" (del 1 "old") (add 1 "new") (ctx 2 "same"))) 40
                                     (list (list "Accept" "keep it" (lambda () (setq fired t))))))
         (rows (split-string s "\n" t)) (face-of (lambda (row regex) (car (ensure-list (get-text-property (string-match regex row) 'face row))))))
    (should (= 5 (length rows)))
    (should (eq 'drgnx-kit-diff-block-head (funcall face-of (nth 0 rows) "a.rs")))
    (should (eq 'drgnx-kit-diff-block-add (funcall face-of (nth 0 rows) "\\+1")))
    (should (eq 'drgnx-kit-diff-block-hunk (funcall face-of (nth 1 rows) "@@")))
    (should (eq 'drgnx-kit-diff-block-del (funcall face-of (nth 2 rows) "old")))
    (should (eq 'drgnx-kit-diff-block-add (funcall face-of (nth 3 rows) "new")))
    (should (eq 'drgnx-kit-diff-block-ctx (funcall face-of (nth 4 rows) "same")))
    (should (equal '(drgnx-kit-diff-block-del drgnx-kit-card-plain-mid)
                   (get-text-property (1- (length (nth 2 rows))) 'face (nth 2 rows))))
    (should (equal '(drgnx-kit-diff-block-ctx drgnx-kit-card-plain-bottom)
                   (get-text-property 0 'face (nth 4 rows))))
    (should (equal "a.rs, 1 added, 1 removed" (get-text-property 0 'help-echo s)))
    (let ((pos (string-match "Accept" s)))
      (should (get-text-property pos 'button s))
      (funcall (get-text-property pos 'action s) nil)
      (should fired))))

(ert-deftest drgnx-ui-kit/diff-block-head-fits-its-name-to-the-room ()
  "With a :width the head's file name gives way (an ellipsis, or nothing) to the counts and the buttons; without one it
is whole.  Every character is 8 px wide here."
  (cl-letf (((symbol-function 'drgnx-ui-kit--text-width) (lambda (text _face) (* 8 (length text)))))
    (let* ((name "core/a-long-directory/drgnx-gateway.el")
           (head (lambda (width)
                   (plist-get (drgnx-ui-kit-expand
                               'diff-block (list :c "diff-block" :file name :added 2 :removed 1 :icon "file-unknown"
                                                 :width width
                                                 :buttons (vector (vector "Reject" '(:kind "kit-test" :args nil)) (vector "Accept" '(:kind "kit-test" :args nil))))
                               1 nil) :text))))
      (should (string-match-p (regexp-quote name) (funcall head 600)))
      (should (string-match-p "\u25a4" (funcall head 600)))
      (let ((narrow (funcall head 300)))
        (should-not (string-match-p (regexp-quote name) narrow))
        (should (string-match-p "\u2026" narrow))
        (should (string-match-p "Reject" narrow)) (should (string-match-p "Accept" narrow)))
      (let ((none (funcall head 100)))
        (should-not (string-match-p "core" none)) (should (string-match-p "Accept" none)))
      (should (string-match-p (regexp-quote name) (plist-get (drgnx-ui-kit-expand 'diff-block (list :c "diff-block" :file name :added 2 :removed 1) 1 nil) :text))))))

(ert-deftest drgnx-ui-kit/empty-state-is-inert-and-labelled ()
  "An empty state is its text in the kit's face, inert (no row selects it), its help text the text itself; with a button
the button is after the text and a `button.el' button."
  (let* ((fired nil) (s (drgnx-ui-kit-empty-state "No agents yet" (list "Start one" "start an agent" (lambda () (setq fired t))) 'text)))
    (should (string-prefix-p "No agents yet" s))
    (should (get-text-property 0 'drgnx-row-inert s))
    (should (equal "No agents yet" (get-text-property 0 'help-echo s)))
    (should (eq 'drgnx-kit-empty-state (car (ensure-list (get-text-property 0 'face s)))))
    (let ((pos (string-match "Start one" s)))
      (should (get-text-property pos 'button s))
      (funcall (get-text-property pos 'action s) nil)
      (should fired))))

(ert-deftest drgnx-ui-kit/toast-buttons-are-kit-buttons ()
  "A toast is its tone's status dot, the text in the toast's face and kit buttons that run their action."
  (let* ((fired nil)
         (s (drgnx-ui-kit-toast 'warn "Disk is nearly full" (list (list "Show" "show it" (lambda () (setq fired t)))) 'text)))
    (should (string-match-p "Disk is nearly full" s))
    (should (eq 'drgnx-kit-toast (car (ensure-list (get-text-property (string-match "Disk" s) 'face s)))))
    (let ((pos (string-match "Show" s)))
      (should (get-text-property pos 'button s))
      (should (cl-some (lambda (f) (string-match-p "drgnx-kit-button" (symbol-name f)))
                       (ensure-list (get-text-property pos 'face s))))
      (funcall (get-text-property pos 'action s) nil)
      (should fired))
    (should (equal "warning: Disk is nearly full" (get-text-property 0 'help-echo s)))))

(ert-deftest drgnx-ui-kit/tooltip-parameters-follow-the-kit ()
  "The tooltip's frame parameters come from the kit's tooltip binding (pad 8 px, UI font) and the standard `tooltip'
face inherits the kit's, so a theme that knows nothing of drgnx styles it too."
  (let ((params (drgnx-ui-kit-tooltip-parameters (selected-frame))))
    (should (= (drgnx-px 8 (selected-frame)) (alist-get 'internal-border-width params)))
    (should (facep 'drgnx-kit-tooltip))
    (unwind-protect
        (progn (load-theme 'drgnx-dark t)
               (should (memq 'drgnx-kit-tooltip (ensure-list (face-attribute 'tooltip :inherit nil t)))))
      (mapc #'disable-theme custom-enabled-themes))))

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

(defun ui-kit-test--meter (state &rest props)
  "The expansion of a card meter, 120 px, in STATE at scale 1, PROPS over its defaults ($31 of $40, \"$31 / $40\")."
  (drgnx-ui-kit-expand 'meter (append props (list :c "meter" :spent 31 :limit 40 :unit "usd" :state state
                                                  :size "card" :width 120 :text "$31 / $40"))
                       1.0 nil))

(ert-deftest drgnx-ui-kit/meter-every-state-has-its-word ()
  ;; the text, then the state's word in its colour; the label speaks the amounts, the unit and the state
  (dolist (c '(("ok" nil nil) ("nearing" "78 %" drgnx-kit-progress-meter-near)
               ("reached" "at limit" drgnx-kit-progress-meter-reached) ("over" "over" drgnx-kit-progress-meter-reached)
               ("forecast-over" "p90 over" drgnx-kit-progress-meter-near) ("none" "no limit" drgnx-ui-caption)
               ("inherited" nil nil) ("unpriced" "unpriced" drgnx-ui-caption)))
    (let* ((e (ui-kit-test--meter (car c)))
           (text (plist-get e :text)))
      (if (nth 1 c)
          (progn
            (should (string-suffix-p (concat "$31 / $40 · " (nth 1 c)) text))
            ;; the word's own run, unless it is the caption's (then it joins the text's)
            (unless (eq (nth 2 c) 'drgnx-ui-caption)
              (should (equal (vector (- (length text) (length (nth 1 c))) (length text) (symbol-name (nth 2 c)))
                             (aref (plist-get e :runs) (1- (length (plist-get e :runs))))))))
        (should (string-suffix-p "$31 / $40" text)))
      (should (string-match-p (format "\\`\\(31 of 40\\|31\\) dollars, %s\\'"
                                      (alist-get (intern (car c)) drgnx-ui-kit--meter-states))
                              (aref (aref (plist-get e :props) 0) 3)))))
  (should (equal "10.5 of 40 dollars, ok, estimate, forecast 20.25 to 31"
                 (aref (aref (plist-get (ui-kit-test--meter "ok" :spent 10.5 :unit "usd-est" :forecast [20.25 31]) :props)
                             0)
                       3))))

(ert-deftest drgnx-ui-kit/meter-none-draws-no-bar ()
  ;; no limit, or no price: the text and the word alone, no part of a bar
  (dolist (state '("none" "unpriced"))
    (let ((e (ui-kit-test--meter state :limit nil :text "$12")))
      (should (equal (format "$12 · %s" (if (equal state "none") "no limit" "unpriced")) (plist-get e :text)))
      (should (equal [] (plist-get e :spaces)))))
  ;; with a limit: the fill (31 of 40 of 120 px: 93), then the track, 3 px high
  (should (equal [[0 93 3] [1 27 3] [2 6 0]] (plist-get (ui-kit-test--meter "ok") :spaces))))

(ert-deftest drgnx-ui-kit/meter-hc-span-is-an-outline ()
  ;; a wide meter's forecast: the tick's slot, then the span to p90; high contrast outlines the span (its four edges,
  ;; no fill) and fills the tick's slot, where other themes fill the span and draw the tick as a line in the middle
  (skip-unless (image-type-available-p 'svg))
  (let* ((e (ui-kit-test--meter "ok" :size "wide" :width 200 :forecast [35 38]))
         (runs (append (plist-get e :runs) nil)) (spaces (append (plist-get e :spaces) nil))
         (face-at (lambda (pos) (seq-some (lambda (r) (and (<= (aref r 0) pos) (< pos (aref r 1)) (aref r 2))) runs))))
    ;; 200 px: the fill 155, the tick's slot from 174 (p50 at 175), the span to 190 (p90), the track
    (should (equal '(("drgnx-kit-progress-meter-fill" 155) ("drgnx-kit-progress" 19)
                     ("drgnx-kit-progress-meter-tick" 2) ("drgnx-kit-progress-meter-span" 14) ("drgnx-kit-progress" 10))
                   (cl-loop for sp in spaces when (> (aref sp 2) 0)
                            collect (list (funcall face-at (aref sp 0)) (aref sp 1)))))
    (let ((spaces (mapcar (lambda (v) (append v nil)) spaces))
          (runs (mapcar (lambda (v) (append v nil)) runs)))
      (cl-flet ((svg (hc pos)
                  (cl-letf (((symbol-function 'drgnx-look-variant) (lambda (&rest _) (if hc 'hc 'dark))))
                    (plist-get (cdr (cdr (assq pos (drgnx-ui-kit-bar-display spaces runs 1.0)))) :data))))
        (let ((tick (nth 0 (seq-find (lambda (sp) (equal (funcall face-at (car sp)) "drgnx-kit-progress-meter-tick"))
                                     spaces)))
              (span (nth 0 (seq-find (lambda (sp) (equal (funcall face-at (car sp)) "drgnx-kit-progress-meter-span"))
                                     spaces))))
          ;; dark: the span one filled rectangle, the tick a 1 px line in its 2 px slot
          (should (string-search "rx=" (svg nil span)))
          (should (string-search "<rect x=\"0\" y=\"0\" width=\"1\" height=\"6\"" (svg nil tick)))
          ;; high contrast: the span's four 1 px edges and no fill, the tick's whole slot
          (let ((d (svg t span)))
            (should-not (string-search "rx=" d))
            (should (= 4 (cl-count-if (lambda (_) t) (split-string d "<rect" t) :start 1)))
            (should (string-search "<rect x=\"0\" y=\"0\" width=\"14\" height=\"1\"" d))
            (should (string-search "<rect x=\"13\" y=\"0\" width=\"1\" height=\"6\"" d)))
          (should (string-search "<rect x=\"0\" y=\"0\" width=\"2\" height=\"6\"" (svg t tick))))))))

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
    (should (string-search "<rect x=\"36.0\" y=\"0\" width=\"36.0\"" (plist-get (cdr fill) :data)))
    (should-not (string-search "<rect x=\"0\" y=\"0\" width=\"36.0\"" (plist-get (cdr fill) :data)))
    (should (string-search "<rect x=\"0\" y=\"0\" width=\"24.0\"" (plist-get (cdr track) :data)))))

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

;;; Nidhogg's menus fed by the kit (modules/ui/drgnx-menu-look.el)

(defvar nhwl-menu-min-width)
(defvar nhwl-menu-row-height)
(defvar nhwl-menu-row-padding)
(defvar nhwl-menu-separator-height)
(defvar nhwl-menu-selection-inset)
(defvar nhwl-menu-selection-radius)
(defvar nhwl-menu-frame-parameters)
(defvar drgnx-look-density-changed-hook)

(ert-deftest drgnx-ui-kit/menu-feed-undone-by-teardown ()
  "ui/face's part for Nidhogg's menus sets their options from `drgnx-ui-kit-menu-values' (220 px, the density's row,
12 px either end, radius 8) and their faces, and follows a change of density or theme; its teardown puts every option,
face spec and hook back as Nidhogg had them."
  (skip-unless (and (require 'nhwl-menu nil t) (boundp 'nhwl-menu-selection-inset)))
  (require 'drgnx-menu-look (expand-file-name "modules/ui/drgnx-menu-look" drgnx-dir))
  (let* ((vars '(nhwl-menu-min-width nhwl-menu-row-height nhwl-menu-row-padding nhwl-menu-separator-height
                                     nhwl-menu-selection-inset nhwl-menu-selection-radius nhwl-menu-frame-parameters))
         (faces '(nhwl-menu nhwl-menu-selected nhwl-menu-key))
         (before (mapcar #'default-value vars))
         (specs (mapcar (lambda (f) (get f 'face-defface-spec)) faces))
         (drgnx-modules--setup-load load-file-name)
         (drgnx-modules--stacks nil)
         (drgnx-module--claims (make-hash-table :test 'equal))
         (drgnx-module--releasers (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (let ((drgnx-modules--current 'test/menu-look)) (drgnx-menu-look-setup))
          (should (= nhwl-menu-min-width 220))
          (should (equal nhwl-menu-row-height (plist-get (drgnx-ui-kit-menu-values) :row-height)))
          (should (equal nhwl-menu-row-padding '(12 . 12)))
          (should (eql nhwl-menu-separator-height 9))
          (should (eql nhwl-menu-selection-inset 4))
          (should (eql nhwl-menu-selection-radius 6))
          (should (eql (alist-get 'corner-radius nhwl-menu-frame-parameters) 8))
          (should (alist-get 'drgnx-minimap-exclude nhwl-menu-frame-parameters))   ; no scroll bar strip
          (should (equal (get 'nhwl-menu-key 'face-defface-spec) '((t :inherit (drgnx-text-subtle drgnx-code-small)))))
          (should (memq #'drgnx-menu-look--refeed enable-theme-functions))
          (should (memq #'drgnx-menu-look--refeed (default-value 'drgnx-look-density-changed-hook)))
          ;; a change the feed follows (here a row height the density gives): set again, as the module
          (cl-letf (((symbol-function 'drgnx-ui-kit-menu-values)
                     (lambda (&optional _) (list :min-width 220 :row-height 30 :row-padding '(12 . 12) :separator-height 9 :selection-inset 4
                                                 :selection-radius 6 :radius 8 :shadow t))))
            (drgnx-menu-look--refeed))
          (should (eql nhwl-menu-row-height 30)))
      (should-not (drgnx-modules--unwind 'test/menu-look)))
    (should (equal (mapcar #'default-value vars) before))
    (should (equal (mapcar (lambda (f) (get f 'face-defface-spec)) faces) specs))
    (should-not (memq #'drgnx-menu-look--refeed enable-theme-functions))
    (should-not (memq #'drgnx-menu-look--refeed (default-value 'drgnx-look-density-changed-hook)))
    (should-not drgnx-menu-look--door)))

(ert-deftest drgnx-ui-kit/tab-line-is-the-kit ()
  "Every tab row draws the kit's tab (design §4 tabs): the shown editor tab is on the editor's surface in the body text's
colour and never bold, a panel's shown tab on the quiet selection; the Work lens bar is the kit's tab and segmented
switch."
  (let* ((tok (lambda (token) (symbol-name token)))
         (specs (drgnx-ui-kit-theme-specs tok nil nil))
         (cur (cdr (assq 'drgnx-kit-tab-current specs)))
         (panel (cdr (assq 'drgnx-kit-tab-panel-current specs))))
    (should (equal '("editor" "fg" nil) (list (plist-get cur :background) (plist-get cur :foreground) (plist-get cur :weight))))
    (should (equal "sel-quiet" (plist-get panel :background))))
  ;; the expansion of a shown tab names no bold face and no weight
  (dolist (size '("editor" "panel"))
    (let* ((e (drgnx-ui-kit-expand 'tab (list :c "tab" :title "a.el" :size size :state "selected" :close t) 1.0 nil))
           (faces (mapcar (lambda (r) (aref r 2)) (plist-get e :runs))))
      (should (member (if (equal size "editor") "drgnx-kit-tab-current" "drgnx-kit-tab-panel-current") faces))
      (should-not (seq-some (lambda (f) (string-match-p "bold" f)) faces))))
  ;; the callers: the editor's tab line, an area's tab row and the Work lens bar
  (require 'drgnx-work-map (expand-file-name "modules/tools/drgnx-work-map" drgnx-dir))
  (let ((s (drgnx-work-lens-string 'map "x")))
    (should (eq 'drgnx-kit-tab-current (get-text-property (string-search "Work" s) 'face s)))
    (should (memq 'drgnx-kit-segmented (ensure-list (get-text-property (string-search "Board" s) 'face s)))))
  (let ((s (drgnx-ui-kit-tab "a.el" 'editor 'selected nil t 'tab-line)))
    (should (eq 'drgnx-kit-tab-current (get-text-property (string-search "a.el" s) 'face s)))
    (should-not (memq 'bold (ensure-list (get-text-property (string-search "a.el" s) 'face s)))))
  ;; a tool tile's tab row (its stack): the kit's panel tabs, the shown one selected and never bold
  (require 'drgnx-grid)
  (let ((w (selected-window)) (old (window-parameter (selected-window) 'drgnx-pane-stack)))
    (unwind-protect
        (progn
          (set-window-parameter w 'drgnx-pane-stack '(kit-test-shown kit-test-other))
          (let ((row (drgnx-grid--tab-row w))
                (kit (lambda (title state) (let ((s (drgnx-ui-kit-tab title 'panel state nil nil 'tab-line)))
                                             (get-text-property (string-search title s) 'face s)))))
            (dolist (c '(("Kit-Test-Shown" selected) ("Kit-Test-Other" rest)))
              (let ((face (get-text-property (string-search (car c) row) 'face row)))
                (should (equal face (funcall kit (car c) (cadr c))))
                (should-not (memq 'bold (ensure-list face)))))))
      (set-window-parameter w 'drgnx-pane-stack old))))

(provide 'ui-kit-test)
;;; ui-kit-test.el ends here

;;;; Text input (flow Task 22a)

(ert-deftest drgnx-ui-kit/text-input-geometry ()
  ;; single: 28 px; multi: the text's lines (two at least), its rows in a card's shapes; 8 px each side, radius 6
  (should (= (plist-get (drgnx-ui-kit-geometry 'text-input '(single)) :height) 28))
  (should (= (plist-get (drgnx-ui-kit-geometry 'text-input '(multi top)) :height) 0))
  (should (equal (plist-get (drgnx-ui-kit-geometry 'text-input '(single)) :pad) '(8 . 8)))
  (should (= (plist-get (drgnx-ui-kit-geometry 'text-input '(single)) :radius) 6))
  ;; at 1.25 each pad rounds on its own (8 px: 10 device px) and the row is 35
  (let ((e (drgnx-ui-kit-expand 'text-input '(:c "text-input" :placeholder "Ask") 1.25 nil)))
    (should (equal (plist-get e :text) " Ask "))
    (should (equal (plist-get e :spaces) [[0 10 0] [4 10 0]]))
    (should (equal (plist-get e :height) '(:lines 1 :unit 35)))
    ;; the placeholder is muted, over the field's face
    (should (equal (plist-get e :runs) [[1 4 "drgnx-text-muted"] [0 5 "drgnx-kit-text-input"]])))
  ;; a multi-line field's first row is the top of its shape and has the line height of its text
  (let ((e (drgnx-ui-kit-expand 'text-input '(:c "text-input" :lines "multi" :text "a\nb") 1.0 nil)))
    (should (equal (plist-get e :runs) [[0 3 "drgnx-kit-text-input-multi-top"]]))
    (should-not (plist-get e :height)))
  (should (equal (plist-get (drgnx-ui-kit-expand 'text-input '(:c "text-input" :placeholder "Ask") 1.0 t) :text) "[ Ask ]"))
  (should (equal (plist-get (drgnx-ui-kit-component 'text-input) :label) "text field")))

(ert-deftest drgnx-ui-kit/text-input-chip-remove-action ()
  ;; a click on a chip's close mark and RET on it both remove that chip, and nothing else carries its action
  (let ((items (list "a.rs" "b.rs")) (drgnx-face-glyphs drgnx-ui--default-glyphs))
    (unwind-protect
        (progn
          (drgnx-ui-kit-define-action 'composer-chip-remove (lambda (args) (setq items (delete (car args) items)))
                                      '(("RET" . identity)))
          (ui-kit-test--gui 1.0
            (let* ((field (drgnx-ui-kit-text-input
                           "Ask" 'single
                           '(("a.rs" neutral (composer-chip-remove "a.rs")) ("b.rs" accent (composer-chip-remove "b.rs")))
                           40 'text))
                   (head (car (car field)))
                   (first (next-single-property-change 0 'drgnx-action head))
                   (second (next-single-property-change (next-single-property-change first 'drgnx-action head)
                                                        'drgnx-action head)))
              ;; the close mark is one character (the glyph, or the x's image where icons are drawn)
              (should (= (- (next-single-property-change first 'drgnx-action head) first) 1))
              (should-not (get-text-property 2 'drgnx-action head))     ; the label has none
              (should (equal (get-text-property first 'help-echo head) "remove a.rs"))
              (let ((last-input-event (list 'mouse-1 (list (selected-window) first '(0 . 0) 0 (cons head first)))))
                (drgnx-ui-kit-activate))
              (should (equal items '("b.rs")))
              (with-temp-buffer
                (insert head)
                (goto-char (1+ second))
                (let ((last-input-event ?\r)) (call-interactively #'drgnx-ui-kit-activate)))
              (should (null items)))))
      (drgnx-ui-kit-undefine-action 'composer-chip-remove))))

(ert-deftest drgnx-ui-kit/text-input-focus-ring-only-after-keys ()
  ;; the ring (the `focus-visible' state's face) shows after a key event, not after a mouse event
  (ui-kit-test--gui 1.0
    (let ((drgnx-ui-kit--focus-visible nil))
      (let ((head (car (car (drgnx-ui-kit-text-input "Ask" 'single nil 40 'text t)))))
        (should-not (memq 'drgnx-focus (ensure-list (get-text-property 0 'face head)))))
      (setq drgnx-ui-kit--focus-visible t)
      (let ((head (car (car (drgnx-ui-kit-text-input "Ask" 'single nil 40 'text t)))))
        (should (eq 'drgnx-focus (car (ensure-list (get-text-property 0 'face head))))))
      ;; not focused: no ring after a key either
      (let ((head (car (car (drgnx-ui-kit-text-input "Ask" 'single nil 40 'text nil)))))
        (should-not (memq 'drgnx-focus (ensure-list (get-text-property 0 'face head))))))))

(ert-deftest drgnx-ui-kit/text-input-buffer-text-uses-canonical-widths ()
  ;; in buffer text a pad is a width in canonical characters, so one buffer is right at two scales; the tail stretches to
  ;; the column, and a multi-line field has a head and a tail per line
  (dolist (case '((1.0 0.8) (1.25 1.0)))
    (ui-kit-test--gui (car case)
      (let* ((field (drgnx-ui-kit-text-input "Ask" 'multi nil 30 'text)) (head (car (car field))) (tail (cdr (car field))))
        (should (= (length field) 2))
        (should (equal (substring-no-properties head) " "))
        (should (equal (get-text-property 0 'display head) `(space :width ,(cadr case))))
        (should (equal (get-text-property 0 'display tail) '(space :align-to 30)))
        (should (equal (get-text-property 1 'display tail) `(space :width ,(cadr case))))
        (should (eq (get-text-property 0 'face tail) 'drgnx-kit-text-input-multi-top))
        (should (eq (get-text-property 0 'face (cdr (cadr field))) 'drgnx-kit-text-input-multi-bottom))
        ;; the placeholder travels with the first head, muted, and is its spoken label
        (should (equal (substring-no-properties (get-text-property 0 'drgnx-placeholder head)) "Ask"))
        (should (equal (get-text-property 0 'help-echo head) "Ask")))))
  ;; a terminal: [ ... ]
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil)))
    (let ((f (car (drgnx-ui-kit-text-input "Ask" 'single nil 30 'text))))
      (should (equal (substring-no-properties (car f)) "[ "))
      (should (equal (substring-no-properties (cdr f)) "  ]")))))
