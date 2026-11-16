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

(provide 'ui-kit-test)
;;; ui-kit-test.el ends here
