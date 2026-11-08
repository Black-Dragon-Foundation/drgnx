;;; drgnx-look-fonts.el --- ui/look: every font role is a setting -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The eight font roles of the look (code, UI, heading, caption, title, small code, agent prose, terminal) are
;; settings (`drgnx-look-font-*'), each a plist of family, size (a ratio to the code size), weight, line height and
;; ligatures.  Where a role's value comes from, first match wins (docs/guide/look.md, "Fonts"):
;;   your Lisp and Customize > the setting > the theme > the desktop (opt-in, `follow-desktop') > the defaults.
;; (A per-mode override sits between Customize and the setting: it is a buffer-local remap, see below.)
;; The mechanism per source: your Lisp and Customize are left alone (a theme load wipes `set-face-attribute', so
;; the attributes found when init ended are put back); a setting is the face's `face-override-spec' (above every
;; theme spec, untouched by a theme load), written for the attributes the user set only; the desktop's answer and
;; drgnx's defaults are the face's defface spec, and also its override spec while a theme styles the face (Emacs
;; skips the defface spec of a themed face, and drgnx's themes style `default'), for the attributes the theme does
;; not name.  `default's attributes are your Lisp's when they changed between ui/look's setup and the end of init
;; (config.el runs in between).  A spec holds `:family', `:height' and `:weight' only, never `:font'.  `:height' is
;; relative, except in the first face of the chrome's roles (`drgnx-look-fonts--absolute-roles'): there it is the
;; absolute height the size gives on `default', written again when the code size, a theme or a zoom changes it, and
;; carried into text-scaled buffers by a remap (`drgnx-look-fonts--text-scaled').
;; `drgnx-look-fonts-resolve-in' is the pure core: layers in, one resolution out.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-setting)
(require 'drgnx-type-faces)
(require 'drgnx-timer)
(require 'face-remap)

(declare-function drgnx-module-running-p "drgnx-modules" (module))
(declare-function drgnx-user-dir "drgnx-paths" ())
(declare-function drgnx-state-dir "drgnx-paths" ())
(declare-function drgnx-file-write "drgnx-file")

;;;; The roles

(defconst drgnx-look-fonts-roles
  '((code drgnx-look-font-code default fixed-pitch)
    (ui drgnx-look-font-ui drgnx-ui-text variable-pitch)
    (ui-heading drgnx-look-font-ui-heading drgnx-ui-heading)
    (ui-caption drgnx-look-font-ui-caption drgnx-ui-caption)
    (title drgnx-look-font-title drgnx-ui-title)
    (code-small drgnx-look-font-code-small drgnx-code-small)
    (agent drgnx-look-font-agent drgnx-agent-prose)
    (terminal drgnx-look-font-terminal drgnx-terminal))
  "The font roles: (ROLE SETTING FACE...).  The first face carries the role's size; the others only the family and
weight.")

(defconst drgnx-look-fonts--absolute-roles '(ui ui-heading ui-caption title code-small)
  "The chrome's roles: their first face gets an absolute `:height' (its size times the height of `default'), written
again whenever that changes.  Emacs copies a font spec at every face run whose face has a float `:height'; the bars
and the dock rows are many runs, drawn at every redisplay.  The agent's prose and the terminal keep a relative height:
they are their buffer's text.")

(defconst drgnx-look-fonts-sources '(lisp customize setting theme desktop default)
  "Where a value comes from, highest first.")

(defconst drgnx-look-fonts--attrs '(:family :size :weight)
  "The attributes a layer holds: family, size (a ratio to the code size) and weight.")

(defconst drgnx-look-fonts--type
  '(choice (const :tag "Follow the desktop's font" follow-desktop)
           (plist :tag "Font" :key-type symbol :value-type sexp))
  "The widget type of a font role setting.")

(defconst drgnx-look-fonts--schema
  '(or (enum follow-desktop)
       (plist (:family (or string (enum ui code)) "A family name, or ui / code for the same as that role")
              (:fallback (list-of string) "Families to try when the family is not installed")
              (:size number "A ratio to the code size (1.0 is the code size)")
              (:weight symbol "regular, semibold, bold, ...")
              (:line-height integer "Pixels per line (logical)")
              (:ligatures boolean "Ligatures on")))
  "The schema of a font role setting.")

(defmacro drgnx-look-fonts--default (role)
  "A copy of ROLE's default value, from `drgnx-type-defaults'."
  `(copy-tree (cdr (assq ',role drgnx-type-defaults))))

(drgnx-defsetting drgnx-look-font-code (drgnx-look-fonts--default code)
  "The code font: family, fallback list, size (a ratio to the code size, 13.5 px), weight, line height in pixels and
ligatures.  A change applies at once.  `(:mode MODE ...)' sections give one mode another font."
  :type drgnx-look-fonts--type :group 'drgnx-look
  :scope 'buffer :agents 'never :apply #'drgnx-look-fonts--settings-apply :schema drgnx-look-fonts--schema)

(drgnx-defsetting drgnx-look-font-ui (drgnx-look-fonts--default ui)
  "The user interface font (tabs, status bar, lists, palette, notices): family, fallback list, size (a ratio to the
code size) and weight.  A change applies at once."
  :type drgnx-look-fonts--type :group 'drgnx-look
  :scope 'buffer :agents 'never :apply #'drgnx-look-fonts--settings-apply :schema drgnx-look-fonts--schema)

(drgnx-defsetting drgnx-look-font-ui-heading (drgnx-look-fonts--default ui-heading)
  "The font of panel titles and section heads.  `:family ui' is the UI font.  A change applies at once."
  :type drgnx-look-fonts--type :group 'drgnx-look
  :scope 'buffer :agents 'never :apply #'drgnx-look-fonts--settings-apply :schema drgnx-look-fonts--schema)

(drgnx-defsetting drgnx-look-font-ui-caption (drgnx-look-fonts--default ui-caption)
  "The font of the status bar, meta text and the tree's end column.  A change applies at once."
  :type drgnx-look-fonts--type :group 'drgnx-look
  :scope 'buffer :agents 'never :apply #'drgnx-look-fonts--settings-apply :schema drgnx-look-fonts--schema)

(drgnx-defsetting drgnx-look-font-title (drgnx-look-fonts--default title)
  "The font of the start page's and the reviews' headings.  A change applies at once."
  :type drgnx-look-fonts--type :group 'drgnx-look
  :scope 'buffer :agents 'never :apply #'drgnx-look-fonts--settings-apply :schema drgnx-look-fonts--schema)

(drgnx-defsetting drgnx-look-font-code-small (drgnx-look-fonts--default code-small)
  "The font of diffs and output inside cards.  `:family code' is the code font.  A change applies at once."
  :type drgnx-look-fonts--type :group 'drgnx-look
  :scope 'buffer :agents 'never :apply #'drgnx-look-fonts--settings-apply :schema drgnx-look-fonts--schema)

(drgnx-defsetting drgnx-look-font-agent (drgnx-look-fonts--default agent)
  "The font of the agent panel's prose.  `:family ui' is the UI font.  A change applies at once."
  :type drgnx-look-fonts--type :group 'drgnx-look
  :scope 'buffer :agents 'never :apply #'drgnx-look-fonts--settings-apply :schema drgnx-look-fonts--schema)

(drgnx-defsetting drgnx-look-font-terminal (drgnx-look-fonts--default terminal)
  "The font of the terminal's text.  `:family code' is the code font.  A change applies at once."
  :type drgnx-look-fonts--type :group 'drgnx-look
  :scope 'buffer :agents 'never :apply #'drgnx-look-fonts--settings-apply :schema drgnx-look-fonts--schema)

;;;; Sizes

(defun drgnx-look-fonts--points-p ()
  "Non-nil on Naglfar, where Emacs counts 72 points to a logical inch: a logical pixel is a point there."
  (featurep 'naglfar))

(defun drgnx-look-fonts-px-to-height (px)
  "PX logical pixels as a face `:height' (tenths of a point): at 1 pt = 4/3 px (13.5 px is 101), and on Naglfar at
1 pt = 1 px (13.5 px is 135), so the text is the same size on the screen on both."
  (round (* px (if (drgnx-look-fonts--points-p) 10 7.5))))

(defun drgnx-look-fonts-px-to-ratio (px)
  "PX logical pixels as a ratio to the code size, to three places: 13 px is 0.963."
  (/ (round (* 1000 (/ px (float drgnx-type-code-px)))) 1000.0))

;;;; The pure core

(defun drgnx-look-fonts--layer-attr (layers attr)
  "The first layer of LAYERS, an alist (SOURCE . PLIST), that gives ATTR."
  (cl-find-if (lambda (l) (plist-get (cdr l) attr)) layers))

(defun drgnx-look-fonts-resolve-in (role layers-of)
  "The resolution of ROLE: (:family :size :height :weight :source :where :sources).
LAYERS-OF maps a role to its layers, an alist (SOURCE . PLIST) highest source first, PLIST of `:family', `:size',
`:weight' and `:where'.  A `:family' that is `ui' or `code' means that role's: the family (and what the role leaves
out) is then the other role's resolution, and `:source' is the other role's source.  `:sources' holds the source
of each attribute; `:source' and `:where' are the family's."
  (let* ((layers (funcall layers-of role))
         (fam (drgnx-look-fonts--layer-attr layers :family))
         (ref-layer (cl-find-if (lambda (l) (memq (plist-get (cdr l) :family) '(ui code))) (reverse layers)))
         (ref (and ref-layer (not (eq (plist-get (cdr ref-layer) :family) role))
                   (plist-get (cdr ref-layer) :family)))
         (target (and ref (drgnx-look-fonts-resolve-in ref layers-of)))
         (res nil) (sources nil))
    (dolist (attr drgnx-look-fonts--attrs)
      (let* ((hit (drgnx-look-fonts--layer-attr layers attr))
             (v (and hit (plist-get (cdr hit) attr)))
             (src (and hit (car hit))))
        (when (and (eq attr :family) (memq v '(ui code)) target)
          (setq v (plist-get target :family) src (plist-get target :source)))
        (when (and (null v) target)
          (setq v (plist-get target attr) src (plist-get (plist-get target :sources) attr)))
        (setq res (plist-put res attr v) sources (plist-put sources attr src))))
    (setq res (plist-put res :height
                         (and (plist-get res :size)
                              (if (eq role 'code)
                                  (drgnx-look-fonts-px-to-height (* drgnx-type-code-px (plist-get res :size)))
                                (plist-get res :size)))))
    (setq res (plist-put res :source (plist-get sources :family)))
    (setq res (plist-put res :where (if (and fam (memq (plist-get (cdr fam) :family) '(ui code)) target)
                                        (plist-get target :where)
                                      (plist-get (cdr fam) :where))))
    (plist-put res :sources sources)))

;;;; The layers

(defvar drgnx-look-fonts--lisp-layer nil
  "The attributes your Lisp set on the role faces when init ended: an alist (FACE . PLIST), PLIST of `:family',
`:height', `:weight' and `:where' (\"config.el:31\").  Put back after every theme load.")

(defvar drgnx-look-fonts--custom-file nil "The file Customize writes, as the snapshot found it.")

(defvar drgnx-look-fonts--desktop nil
  "The desktop's fonts, from `drgnx-look-fonts-desktop-answer': (:ui (FAMILY . PX) :code (FAMILY . PX)).")

(defun drgnx-look-fonts--faces (role) "ROLE's faces." (nthcdr 2 (assq role drgnx-look-fonts-roles)))

(defun drgnx-look-fonts--role-of (face)
  "The role whose primary face is FACE."
  (car (cl-find face drgnx-look-fonts-roles :key #'caddr)))

(defun drgnx-look-fonts--find-line (file face)
  "FILE's name and the line of the first mention of FACE in it, as \"config.el:31\"; just the name when it has none."
  (let ((name (file-name-nondirectory file)))
    (or (ignore-errors
          (with-temp-buffer
            (insert-file-contents file)
            (when (search-forward (symbol-name face) nil t)
              (format "%s:%d" name (line-number-at-pos)))))
        name)))

(defun drgnx-look-fonts--size-of-height (height)
  "A face `:height' (a ratio, or tenths of a point) as a ratio to the code size."
  (if (integerp height) (/ height (float (drgnx-look-fonts-px-to-height drgnx-type-code-px))) height))

(defun drgnx-look-fonts--spec-attrs (spec)
  "SPEC's family, height and weight (those that are set) as a plist."
  (let ((attrs (face-spec-choose spec)) out)
    (dolist (a '(:family :height :weight))
      (let ((v (plist-get attrs a)))
        (when (and v (not (eq v 'unspecified))) (setq out (plist-put out a v)))))
    out))

(defun drgnx-look-fonts--face-layer (role face-attrs)
  "The layer plist of ROLE from FACE-ATTRS, an alist (FACE . PLIST of face attributes): the first face's
size and family and weight, the others' family and weight, whichever face names them first."
  (let (out (primary (car (drgnx-look-fonts--faces role))))
    (pcase-dolist (`(,face . ,plist) face-attrs)
      (dolist (a '(:family :weight))
        (when (and (plist-get plist a) (not (plist-get out a)))
          (setq out (plist-put out a (plist-get plist a)))
          (when (eq a :family) (setq out (plist-put out :where (plist-get plist :where))))))
      (when (and (eq face primary) (plist-get plist :height) (not (plist-get out :size)))
        (setq out (plist-put out :size (drgnx-look-fonts--size-of-height (plist-get plist :height))))))
    out))

(defun drgnx-look-fonts--lisp-attrs (role)
  "ROLE's layer from what your Lisp set."
  (drgnx-look-fonts--face-layer
   role (delq nil (mapcar (lambda (f) (assq f drgnx-look-fonts--lisp-layer)) (drgnx-look-fonts--faces role)))))

(defun drgnx-look-fonts--customize-spec (face)
  "FACE's Customize entry (a face spec), or nil."
  (or (cadr (assq 'user (get face 'theme-face))) (get face 'customized-face) (get face 'saved-face)))

(defun drgnx-look-fonts--customize-attrs (role)
  "ROLE's layer from Customize."
  (drgnx-look-fonts--face-layer
   role (delq nil (mapcar (lambda (f)
                            (when-let* ((spec (drgnx-look-fonts--customize-spec f)))
                              (let ((a (drgnx-look-fonts--spec-attrs spec)))
                                (and a (cons f (plist-put a :where
                                                          (drgnx-look-fonts--find-line
                                                           (or drgnx-look-fonts--custom-file
                                                               (bound-and-true-p custom-file)
                                                               (expand-file-name "custom.el" (drgnx-user-dir)))
                                                           f)))))))
                          (drgnx-look-fonts--faces role)))))

(defun drgnx-look-fonts--theme-attrs (role)
  "ROLE's layer from the enabled themes (the newest theme first; Customize's own `user' theme is not one)."
  (let (out)
    (dolist (face (drgnx-look-fonts--faces role))
      (let ((attrs nil))
        (dolist (theme custom-enabled-themes)
          (unless (eq theme 'user)
            (when-let* ((entry (assq theme (get face 'theme-face))))
              (let ((a (drgnx-look-fonts--spec-attrs (cadr entry))))
                (dolist (k '(:family :height :weight))
                  (when (and (plist-get a k) (not (plist-get attrs k)))
                    (setq attrs (plist-put attrs k (plist-get a k)))
                    (when (eq k :family) (setq attrs (plist-put attrs :where (format "theme %s" theme))))))))))
        (when attrs (push (cons face attrs) out))))
    (drgnx-look-fonts--face-layer role (nreverse out))))

(defun drgnx-look-fonts--value (role)
  "ROLE's setting value, the global one: a buffer's own value is a per-mode override, read by the remaps."
  (default-value (nth 1 (assq role drgnx-look-fonts-roles))))

(defun drgnx-look-fonts--setting-attrs (role value)
  "The attributes VALUE, a role plist, sets that differ from ROLE's default."
  (let ((default (cdr (assq role drgnx-type-defaults))) out)
    (when (and (consp value) (not (eq value 'follow-desktop)))
      (dolist (a drgnx-look-fonts--attrs)
        (when (and (plist-member value a) (not (equal (plist-get value a) (plist-get default a))))
          (setq out (plist-put out a (plist-get value a))))))
    out))

(defun drgnx-look-fonts--desktop-attrs (role)
  "ROLE's layer from the desktop's answer, when the role's value is `follow-desktop'."
  (when (eq (drgnx-look-fonts--value role) 'follow-desktop)
    (when-let* ((ans (plist-get drgnx-look-fonts--desktop (if (memq role '(code code-small terminal)) :code :ui))))
      (list :family (car ans) :size (drgnx-look-fonts-px-to-ratio (cdr ans)) :where "the desktop"))))

(defun drgnx-look-fonts--layers (role)
  "ROLE's layers, an alist (SOURCE . PLIST), highest source first; the sources with nothing to say are left out."
  (let ((default (cdr (assq role drgnx-type-defaults))))
    (delq nil
          (list (when-let* ((l (drgnx-look-fonts--lisp-attrs role))) (cons 'lisp l))
                (when-let* ((l (drgnx-look-fonts--customize-attrs role))) (cons 'customize l))
                (when-let* ((l (drgnx-look-fonts--setting-attrs role (drgnx-look-fonts--value role))))
                  (cons 'setting (plist-put l :where "settings.el")))
                (when-let* ((l (drgnx-look-fonts--theme-attrs role))) (cons 'theme l))
                (when-let* ((l (drgnx-look-fonts--desktop-attrs role))) (cons 'desktop l))
                (cons 'default (list :family (plist-get default :family) :size (plist-get default :size)
                                     :weight (plist-get default :weight) :where "drgnx"))))))

(defun drgnx-look-fonts-resolve (role)
  "ROLE's font now: (:family :size :height :weight :source :where :sources).
:source is one of `lisp', `customize', `setting', `theme', `desktop', `default' (the family's); :where names the
file and line of your Lisp or Customize entry, the theme, or the place."
  (drgnx-look-fonts-resolve-in role #'drgnx-look-fonts--layers))

;;;; Snapshot: your Lisp

(defvar drgnx-look-fonts--default-before nil
  "`default's family, height and weight for new frames when ui/look's setup ran, before config.el loaded: a plist,
or nil when the module came on after init.  What differs from it when init ends is your Lisp's.")

(defun drgnx-look-fonts--default-attrs ()
  "`default's family, height and weight for new frames (what a `set-face-attribute' with no frame sets), a plist."
  (let (plist)
    (dolist (a '(:family :height :weight) plist)
      (setq plist (plist-put plist a (face-attribute 'default a t))))))

(defun drgnx-look-fonts--note-default ()
  "Note `default's attributes before your Lisp runs: ui/look's setup comes before config.el."
  (setq drgnx-look-fonts--default-before (drgnx-look-fonts--default-attrs)))

(defun drgnx-look-fonts--face-snapshot (face)
  "What your Lisp set on FACE, a plist of `:family', `:height' and `:weight': the attributes of the faces' default
frame; for `default', whose attributes Emacs sets from the frame, only those that changed since
`drgnx-look-fonts--note-default' (nothing when it was not called)."
  (let (plist)
    (if (eq face 'default)
        (when drgnx-look-fonts--default-before
          (let ((now (drgnx-look-fonts--default-attrs)))
            (dolist (a '(:family :height :weight))
              (let ((v (plist-get now a)))
                (unless (or (eq v 'unspecified) (equal v (plist-get drgnx-look-fonts--default-before a)))
                  (setq plist (plist-put plist a v)))))))
      (dolist (a '(:family :height :weight))
        (let ((v (face-attribute face a t)))
          (unless (eq v 'unspecified) (setq plist (plist-put plist a v))))))
    plist))

(defun drgnx-look-fonts-snapshot (&optional config custom)
  "Record what your Lisp set on the role faces (a `set-face-attribute' in CONFIG, default config.el): see
`drgnx-look-fonts--face-snapshot'.  CUSTOM is the file Customize writes."
  (setq drgnx-look-fonts--lisp-layer nil
        drgnx-look-fonts--custom-file custom)
  (let ((file (or config (expand-file-name "config.el" (drgnx-user-dir)))))
    (dolist (spec drgnx-look-fonts-roles)
      (dolist (face (cddr spec))
        (when-let* ((plist (drgnx-look-fonts--face-snapshot face)))
          (push (cons face (plist-put plist :where (drgnx-look-fonts--find-line file face)))
                drgnx-look-fonts--lisp-layer))))
    (setq drgnx-look-fonts--lisp-layer (nreverse drgnx-look-fonts--lisp-layer))))

(defun drgnx-look-fonts--put-back-lisp ()
  "Give the role faces the attributes your Lisp set, where a theme load or a spec write wiped them."
  (pcase-dolist (`(,face . ,plist) drgnx-look-fonts--lisp-layer)
    (dolist (a '(:family :height :weight))
      (when-let* ((v (plist-get plist a)))
        (unless (equal v (face-attribute face a nil))
          (set-face-attribute face nil a v))))))

;;;; Writing the specs

(defvar drgnx-look-fonts--written nil "The faces whose override spec this module wrote.")
(defvar drgnx-look-fonts--orig nil
  "An alist (FACE . (SPEC)): the defface spec of a face before this module rewrote it.")
(defvar drgnx-look-fonts--alternatives nil
  "The entries this module added to `face-font-family-alternatives'.")

(defun drgnx-look-fonts--owned-p (face)
  "Non-nil when your Lisp or Customize set FACE: this module writes no override to it."
  (or (assq face drgnx-look-fonts--lisp-layer) (drgnx-look-fonts--customize-spec face)))

(defun drgnx-look-fonts--own-face-p (face)
  "Non-nil for a face this module's library defines."
  (string-prefix-p "drgnx-" (symbol-name face)))

(defun drgnx-look-fonts--plist-for (role face res kinds)
  "The face attributes of RES for FACE whose source is in KINDS: `:family', `:weight', and `:height' for the
role's first face."
  (let (out (sources (plist-get res :sources)))
    (dolist (a '(:family :height :weight))
      (when (and (memq (plist-get sources (if (eq a :height) :size a)) kinds)
                 (plist-get res a)
                 (or (not (eq a :height)) (eq face (car (drgnx-look-fonts--faces role)))))
        (setq out (plist-put out a (plist-get res a)))))
    out))

(defun drgnx-look-fonts--set-override (face plist)
  "FACE's override spec: PLIST for all frames (nil: none).  Only when it changes."
  (let ((spec (and plist (list (cons t plist)))))
    (unless (equal spec (get face 'face-override-spec))
      (face-spec-set face spec)
      (if spec (cl-pushnew face drgnx-look-fonts--written)
        (setq drgnx-look-fonts--written (delq face drgnx-look-fonts--written))))))

(defun drgnx-look-fonts--set-defface (face plist)
  "FACE's defface spec with PLIST's attributes put over the one it had; nil gives the old spec back."
  (let* ((orig (assq face drgnx-look-fonts--orig))
         (base (if orig (cadr orig) (get face 'face-defface-spec)))
         (spec (and plist (list (cons t (let ((attrs (copy-sequence (drgnx-look-fonts--spec-attrs base))))
                                          (dolist (a '(:family :height :weight))
                                            (when (plist-member plist a) (setq attrs (plist-put attrs a (plist-get plist a)))))
                                          attrs))))))
    (cond ((and spec (not (equal spec (get face 'face-defface-spec))))
           (unless orig (push (list face base) drgnx-look-fonts--orig))
           (face-spec-set face spec 'face-defface-spec))
          ((and (not spec) orig)
           (face-spec-set face (cadr orig) 'face-defface-spec)
           (setq drgnx-look-fonts--orig (assq-delete-all face drgnx-look-fonts--orig))))))

(defun drgnx-look-fonts--set-alternatives (entries)
  "Make ENTRIES, (FAMILY FALLBACK...) lists, this module's part of `face-font-family-alternatives', and give the
font lookup the result: it reads only what `internal-set-alternative-font-family-alist' was given (the variable's
own setter calls it), never the variable.  Nothing happens when ENTRIES are the ones there already."
  (unless (equal entries drgnx-look-fonts--alternatives)
    (dolist (e drgnx-look-fonts--alternatives)
      (setq face-font-family-alternatives (delq e face-font-family-alternatives)))
    (setq drgnx-look-fonts--alternatives entries)
    (dolist (e (reverse entries)) (push e face-font-family-alternatives))
    (internal-set-alternative-font-family-alist face-font-family-alternatives)))

(defun drgnx-look-fonts--apply-alternatives ()
  "Each family of the code and UI roles falls back down its list, natively (`face-font-family-alternatives')."
  (let (entries)
    (dolist (role '(code ui))
      (let* ((family (plist-get (drgnx-look-fonts-resolve role) :family))
             (value (drgnx-look-fonts--value role))
             (fallback (or (and (consp value) (plist-get value :fallback))
                           (plist-get (cdr (assq role drgnx-type-defaults)) :fallback))))
        (when (and (stringp family) fallback)
          (push (cons family fallback) entries))))
    (drgnx-look-fonts--set-alternatives (nreverse entries))))

(defun drgnx-look-fonts--themed-p (face)
  "Non-nil when an enabled theme (not Customize's own) has a spec for FACE: Emacs then skips FACE's defface spec."
  (cl-some (lambda (entry) (and (not (eq (car entry) 'user)) (custom-theme-enabled-p (car entry))))
           (get face 'theme-face)))

(defvar drgnx-look-fonts--absolute nil
  "The chrome's faces that have an absolute `:height' now: an alist (FACE RATIO . HEIGHT), RATIO the role's size.")
(defvar drgnx-look-fonts--absolute-code nil "The height of `default' the heights of `drgnx-look-fonts--absolute' are of.")

(defun drgnx-look-fonts--code-height ()
  "The height of `default' in tenths of a point that the chrome's sizes are ratios of: on the selected frame when it
is graphical, else on the first graphical frame (a zoom and your Lisp's `default' are there); with none (a daemon
before its first frame, batch), the code role's."
  (let* ((frame (if (display-graphic-p) (selected-frame) (cl-find-if #'display-graphic-p (frame-list))))
         (h (and frame (face-attribute 'default :height frame))))
    (if (integerp h) h (plist-get (drgnx-look-fonts-resolve 'code) :height))))

(defun drgnx-look-fonts--write-absolute (later)
  "Write the specs of the chrome's first faces, LATER a list (FACE RES OVERRIDE DEFFACE) of the plists `apply' made,
with the absolute `:height' of the role's size on `default' now (`drgnx-look-fonts--code-height'), the one Emacs
merged the relative height to: in the override spec when that holds the height, else in the defface spec when the
size is the desktop's or drgnx's default.  A size your Lisp, Customize or a theme gave stays as they gave it."
  (let ((code (drgnx-look-fonts--code-height))
        (absolute (cl-remove-if (lambda (e) (assq (car e) later)) drgnx-look-fonts--absolute)))   ; the roles not written now
    (pcase-dolist (`(,face ,res ,override ,defface) later)
      (let* ((ratio (plist-get res :height))
             (h (and (numberp ratio) (merge-face-attribute :height ratio code))))
        (when (integerp h)
          (cond ((plist-get override :height) (setq override (plist-put override :height h)) (push (cons face (cons ratio h)) absolute))
                ((memq (plist-get (plist-get res :sources) :size) '(default desktop))
                 (setq defface (plist-put defface :height h)) (push (cons face (cons ratio h)) absolute))))
        (drgnx-look-fonts--set-override face override)
        (drgnx-look-fonts--set-defface face defface)))
    (unless (and (equal absolute drgnx-look-fonts--absolute) (eql code drgnx-look-fonts--absolute-code))
      (setq drgnx-look-fonts--absolute absolute drgnx-look-fonts--absolute-code code)
      (drgnx-look-fonts--rescale-buffers))))

(defun drgnx-look-fonts-apply (&optional roles)
  "Write the faces of ROLES (default all) from the settings, at once on every frame: an override spec for what the
setting set, the defface spec for the desktop's fonts and drgnx's defaults, nothing from the setting for a face your
Lisp or Customize set.  A face an enabled theme styles (drgnx's themes style `default') never shows its defface
spec, so its desktop and default attributes go in the override spec too: only those the theme does not name, as
the resolution says.  The chrome's first faces (`drgnx-look-fonts--absolute-roles') are written last, with an
absolute height, once your Lisp's attributes are back on `default' (`drgnx-look-fonts--write-absolute').  Runs
again whenever a theme is enabled or disabled, and after a zoom."
  (let (later)
    (dolist (role (or roles (mapcar #'car drgnx-look-fonts-roles)))
      (let ((res (drgnx-look-fonts-resolve role)))
        (dolist (face (drgnx-look-fonts--faces role))
          (let* ((base (if (drgnx-look-fonts--own-face-p face) '(desktop) '(default desktop)))
                 (override (drgnx-look-fonts--plist-for role face res
                                                        (append (unless (drgnx-look-fonts--owned-p face) '(setting))
                                                                (when (drgnx-look-fonts--themed-p face) base))))
                 (defface (drgnx-look-fonts--plist-for role face res base)))
            (if (and (memq role drgnx-look-fonts--absolute-roles) (eq face (car (drgnx-look-fonts--faces role))))
                (push (list face res override defface) later)
              (drgnx-look-fonts--set-override face override)
              (drgnx-look-fonts--set-defface face defface))))))
    (drgnx-look-fonts--apply-alternatives)
    (drgnx-look-fonts--ligatures-sync)
    (drgnx-look-fonts--put-back-lisp)
    (when later
      (drgnx-look-fonts--write-absolute (nreverse later))
      (drgnx-look-fonts--put-back-lisp)))   ; a spec write wipes your Lisp's attributes of those faces
  (drgnx-look-fonts--remap-all)
  (run-hooks 'drgnx-look-fonts-applied-hook))

(defvar drgnx-look-fonts-applied-hook nil
  "Run after the role faces were written: what depends on the code font's size (the code line) follows.")

(defun drgnx-look-fonts--preview ()
  "Write the faces, if ui/look still runs (the debounced end of a setting change)."
  (when (drgnx-module-running-p 'ui/look) (drgnx-look-fonts-apply)))

(defun drgnx-look-fonts--settings-apply ()
  "The `:apply' of every role setting: write the faces while ui/look runs.  A change redraws every frame, so the
settings page's size slider and typed digits are debounced: 300 ms after the last change, once."
  (when (drgnx-module-running-p 'ui/look)
    (drgnx-timer-debounce 'look-fonts-preview 0.3 #'drgnx-look-fonts--preview :owner :core)))

;;;; Per-mode overrides: buffer-local remaps

(defvar-local drgnx-look-fonts--remap nil
  "(SPECS . COOKIES) of the remaps this module installed in the buffer: SPECS is an alist (FACE . PLIST).")

(defun drgnx-look-fonts--mode-specs ()
  "The remaps the current buffer's own role values ask for: an alist (FACE . PLIST of family, relative height and
weight), only the attributes that differ from the global value."
  (let (out)
    (pcase-dolist (`(,role ,var . ,faces) drgnx-look-fonts-roles)
      (when (local-variable-p var)
        (let ((local (symbol-value var)) (global (default-value var)))
          (when (consp local)
            (let* ((global (if (consp global) global (cdr (assq role drgnx-type-defaults))))
                   (res (drgnx-look-fonts-resolve role))
                   (f (plist-get local :family)) (s (plist-get local :size)) (w (plist-get local :weight))
                   (fam (and f (not (equal f (plist-get global :family)))
                             (if (memq f '(ui code)) (plist-get (drgnx-look-fonts-resolve f) :family) f)))
                   (rel (and s (not (equal s (plist-get global :size)))
                             (/ (round (* 1000 (/ s (float (or (plist-get res :size) 1.0))))) 1000.0)))
                   (wt (and w (not (equal w (plist-get global :weight))) w)))
              (dolist (face faces)
                (let (plist)
                  (when fam (setq plist (plist-put plist :family fam)))
                  (when (and rel (eq face (car faces))) (setq plist (plist-put plist :height rel)))
                  (when wt (setq plist (plist-put plist :weight wt)))
                  (when plist (push (cons face plist) out)))))))))
    (nreverse out)))

(defun drgnx-look-fonts-remap-buffer ()
  "Install the current buffer's per-mode font remaps, or take them away when its own values are gone.  Only a buffer
that has an override gets a remap: a non-nil `face-remapping-alist' takes a buffer off the default-face fast paths."
  (let ((specs (drgnx-look-fonts--mode-specs)))
    (unless (equal specs (car drgnx-look-fonts--remap))
      (dolist (c (cdr drgnx-look-fonts--remap)) (face-remap-remove-relative c))
      (setq drgnx-look-fonts--remap
            (and specs (cons specs (mapcar (lambda (s) (apply #'face-remap-add-relative (car s) (cdr s))) specs)))))))

(defun drgnx-look-fonts--mode-hook ()
  "`after-change-major-mode-hook': a mode section of settings.el has set the buffer's values by now."
  (drgnx-look-fonts-remap-buffer))

(defun drgnx-look-fonts--remap-all ()
  "Every buffer that has an override or a remap: install, rewrite or remove its remaps."
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when (or drgnx-look-fonts--remap
                (cl-some (lambda (spec) (local-variable-p (nth 1 spec))) drgnx-look-fonts-roles))
        (drgnx-look-fonts-remap-buffer)))))

;;;; Zooms: the absolute heights follow `default'

(defvar text-scale-mode-remapping)
(defvar text-scale-mode-amount)
(defvar text-scale-mode-step)

(defun drgnx-look-fonts--zoomed (&rest _)
  "After `global-text-scale-adjust' (View: Zoom In and the keys after it): `default' has another height on every
frame, and the chrome's absolute heights follow it."
  (drgnx-look-fonts-apply))

(defun drgnx-look-fonts--text-scaled ()
  "`text-scale-mode-hook': the mode remaps only `default', which the chrome's absolute heights do not follow.  In a
scaled buffer each of those faces is remapped to the height its size gives on the scaled `default' (what the
relative height merged to), among the mode's own remaps, which it takes away at its next change."
  (when (and text-scale-mode drgnx-look-fonts--absolute)
    (let ((code (merge-face-attribute :height (expt text-scale-mode-step text-scale-mode-amount)
                                      drgnx-look-fonts--absolute-code)))
      (pcase-dolist (`(,face ,ratio . ,height) drgnx-look-fonts--absolute)
        ;; a factor whose product with HEIGHT truncates to the wanted height
        (push (face-remap-add-relative face :height (/ (+ (merge-face-attribute :height ratio code) 0.5) height))
              text-scale-mode-remapping)))))

(defun drgnx-look-fonts--rescale-buffers ()
  "Every buffer `text-scale-mode' scales gets its remaps again, the chrome's at the heights they have now."
  (dolist (b (buffer-list))
    (when (buffer-local-value 'text-scale-mode b)
      (with-current-buffer b (text-scale-mode 1)))))

;;;; Ligatures: composition rules, a switch

(defconst drgnx-look-fonts--ligatures
  '("<=>" "<==" "==>" "===" "!==" "=/=" "<->" "<--" "-->" "..." "<$>" "<*>" "<|>" "|>" "<|" "->" "<-" "=>" "==" "!="
    "<=" ">=" "&&" "||" "::" ".." "++" "--" "//" "/*" "*/" "<<" ">>" "?." "??")
  "The sequences the ligature rules compose when the code role has `:ligatures t'.")

(defvar drgnx-look-fonts--ligatures-saved 'none
  "The composition rules the ligature characters had before this module added its own: an alist (CHAR . RULES), or
`none' while the rules are off.")

(defun drgnx-look-fonts--ligatures-sync ()
  "Rules on when the code role has `:ligatures t', off when it does not.  A font without the ligatures shapes
the sequences as they are.  The default prefers the `-nl' build, which has none."
  (let* ((value (default-value 'drgnx-look-font-code))
         (want (and (consp value) (plist-get value :ligatures)))
         (on (not (eq drgnx-look-fonts--ligatures-saved 'none))))
    (cond ((and want (not on))
           (let* ((sorted (sort (copy-sequence drgnx-look-fonts--ligatures)
                                (lambda (a b) (> (length a) (length b)))))
                  (rule (vector (mapconcat #'regexp-quote sorted "\\|") 0 #'font-shape-gstring))
                  saved)
             (dolist (c (delete-dups (mapcar (lambda (s) (aref s 0)) sorted)))
               (let ((old (char-table-range composition-function-table c)))
                 (push (cons c old) saved)
                 (set-char-table-range composition-function-table c
                                       (cons rule (and (listp old) old)))))
             (setq drgnx-look-fonts--ligatures-saved saved)))
          ((and on (not want)) (drgnx-look-fonts--ligatures-off)))))

(defun drgnx-look-fonts--ligatures-off ()
  "Give the composition rules of the ligature characters back."
  (unless (eq drgnx-look-fonts--ligatures-saved 'none)
    (pcase-dolist (`(,c . ,old) drgnx-look-fonts--ligatures-saved)
      (set-char-table-range composition-function-table c old))
    (setq drgnx-look-fonts--ligatures-saved 'none)))

;;;; Fallbacks: what the doctor says

(defconst drgnx-look-fonts-packages
  '(("Adwaita Sans" :fedora "adwaita-sans-fonts" :arch "adwaita-fonts" :ubuntu "fonts-adwaita-sans"
     :homebrew "font-adwaita")
    ("JetBrains Mono" :fedora "jetbrains-mono-nl-fonts" :arch "ttf-jetbrains-mono" :ubuntu "fonts-jetbrains-mono"
     :homebrew "font-jetbrains-mono")
    ("Inter" :fedora "rsms-inter-fonts" :arch "inter-font" :ubuntu "fonts-inter" :homebrew "font-inter"))
  "The packages that carry the default families: (FAMILY :fedora P :arch P :ubuntu P :homebrew P).  Arch and Ubuntu
\(26.04) names were read from their package indexes; Inter is the fallback where Adwaita Sans is not packaged.")

(defvar drgnx-look-fonts--fallback-report nil
  "An alist (TERMINAL . ENTRIES): what each graphical display's last check found, ENTRIES as `drgnx-look-fonts-fallbacks'.")

(defun drgnx-look-fonts--fallback-list (role)
  "The families ROLE falls back to: its own list, else its defaults', else its class's (UI or code)."
  (let ((class (if (memq role '(code code-small terminal)) 'code 'ui)))
    (cl-some (lambda (r)
               (let ((v (drgnx-look-fonts--value r)))
                 (or (and (consp v) (plist-get v :fallback))
                     (plist-get (cdr (assq r drgnx-type-defaults)) :fallback))))
             (list role class))))

(defun drgnx-look-fonts-fallbacks (frame)
  "The roles on FRAME's display whose family is not installed: ((ROLE WANTED GOT) ...), GOT the first fallback that
is (nil: none).  A role whose family an earlier role named is not repeated.  nil on a terminal frame.
Checked per display, with a graphical frame: `find-font' in a daemon with no such frame says nothing."
  (when (display-graphic-p frame)
    (let (seen out)
      (dolist (spec drgnx-look-fonts-roles)
        (let* ((role (car spec)) (family (plist-get (drgnx-look-fonts-resolve role) :family)))
          (when (and (stringp family) (not (member family seen)))
            (push family seen)
            (unless (find-font (font-spec :family family) frame)
              (push (list role family
                          (cl-find-if (lambda (f) (find-font (font-spec :family f) frame))
                                      (drgnx-look-fonts--fallback-list role)))
                    out)))))
      (nreverse out))))

(defun drgnx-look-fonts--check-frame ()
  "`server-after-make-frame-hook': check the new frame's display, and write what the checks found to fonts-report.eld
in the state dir for `drgnx doctor' (a batch Emacs with no frame of its own to check).  Never signals: a report that
cannot be written leaves the last one, which the session's own doctor does not need."
  (let ((frame (selected-frame)))
    (when (display-graphic-p frame)
      (setf (alist-get (terminal-name frame) drgnx-look-fonts--fallback-report nil nil #'equal)
            (list (drgnx-look-fonts-fallbacks frame)))
      (ignore-errors
        (drgnx-file-write (expand-file-name "fonts-report.eld" (drgnx-state-dir)) (drgnx-look-fonts-fallback-report)
                          :fsync nil)))))

(defun drgnx-look-fonts--distro ()
  "`fedora', `arch', `ubuntu' (or Debian-like), `homebrew' on a Mac, else nil; and whether Fedora is image-based."
  (cond ((eq system-type 'darwin) 'homebrew)
        (t (let ((id (ignore-errors
                       (with-temp-buffer
                         (insert-file-contents "/etc/os-release")
                         (string-join (delq nil (list (and (re-search-forward "^ID=\"?\\([^\"\n]+\\)" nil t) (match-string 1))
                                                      (progn (goto-char (point-min))
                                                             (and (re-search-forward "^ID_LIKE=\"?\\([^\"\n]+\\)" nil t)
                                                                  (match-string 1)))))
                                      " ")))))
             (cond ((null id) nil)
                   ((string-match-p "\\<fedora\\>" id) 'fedora)
                   ((string-match-p "\\<arch\\>" id) 'arch)
                   ((string-match-p "\\<\\(ubuntu\\|debian\\)\\>" id) 'ubuntu))))))

(defun drgnx-look-fonts--install-hint (families)
  "How to install FAMILIES (those with a known package) on this machine, or nil."
  (let* ((distro (drgnx-look-fonts--distro))
         (pkgs (and distro (delq nil (mapcar (lambda (f) (plist-get (cdr (assoc f drgnx-look-fonts-packages)) (intern (format ":%s" distro))))
                                             families)))))
    (when pkgs
      (let ((list (string-join pkgs " ")))
        (pcase distro
          ('fedora (if (file-exists-p "/run/ostree-booted")
                       (format "image-based Fedora: in the toolbox, sudo dnf install %s" list)
                     (format "sudo dnf install %s" list)))
          ('arch (format "sudo pacman -S %s" list))
          ('ubuntu (format "sudo apt install %s" list))
          ('homebrew (format "brew install --cask %s" list)))))))

(defun drgnx-look-fonts-fallback-report ()
  "What the doctor says about fonts: nil before any graphical display was checked, else (:fallbacks ENTRIES :fix TEXT),
ENTRIES (ROLE WANTED GOT) of every checked display, TEXT how to install the families (nil: none known)."
  (when drgnx-look-fonts--fallback-report
    (let ((entries (delete-dups (apply #'append (mapcar #'cadr drgnx-look-fonts--fallback-report)))))
      (list :fallbacks entries
            :fix (drgnx-look-fonts--install-hint (delete-dups (mapcar #'cadr entries)))))))

(defun drgnx-look-fonts-desktop-answer (answer)
  "The desktop's fonts arrived: ANSWER is (:ui (FAMILY . PX) :code (FAMILY . PX)).  The roles set to
`follow-desktop' take them, at once."
  (setq drgnx-look-fonts--desktop answer)
  (drgnx-look-fonts-apply))

;;;; On and off

(defun drgnx-look-fonts--after-theme (_theme)
  "A theme was enabled or disabled: it changed which faces it styles and recalculated them, so write the faces
again (which gives your Lisp's attributes back)."
  (drgnx-look-fonts-apply))

(defun drgnx-look-fonts--after-init ()
  "Init ended: record your Lisp's attributes, then write the faces."
  (drgnx-look-fonts-snapshot)
  (drgnx-look-fonts-apply))

(defun drgnx-look-fonts-reset ()
  "Forget what was recorded (your Lisp's attributes, the desktop's answer); the specs stay."
  (setq drgnx-look-fonts--lisp-layer nil drgnx-look-fonts--custom-file nil drgnx-look-fonts--desktop nil
        drgnx-look-fonts--default-before nil))

(defun drgnx-look-fonts-on ()
  "The role faces follow the settings: snapshot your Lisp's attributes (when init has ended, else at its end;
`default' is noted now, before config.el), write the specs, write them again after every theme change."
  (unless after-init-time (drgnx-look-fonts--note-default))
  (add-hook 'enable-theme-functions #'drgnx-look-fonts--after-theme)
  (add-hook 'disable-theme-functions #'drgnx-look-fonts--after-theme)
  (add-hook 'after-change-major-mode-hook #'drgnx-look-fonts--mode-hook)
  (add-hook 'server-after-make-frame-hook #'drgnx-look-fonts--check-frame)
  (add-hook 'text-scale-mode-hook #'drgnx-look-fonts--text-scaled)
  (advice-add 'global-text-scale-adjust :after #'drgnx-look-fonts--zoomed)
  (when (display-graphic-p) (drgnx-look-fonts--check-frame))
  (if after-init-time
      (drgnx-look-fonts--after-init)
    (add-hook 'after-init-hook #'drgnx-look-fonts--after-init 90)))

(defun drgnx-look-fonts-off ()
  "Undo `drgnx-look-fonts-on': no override spec, the defface specs as they were, the family alternatives gone.
Your Lisp's attributes and Customize entries stay."
  (remove-hook 'enable-theme-functions #'drgnx-look-fonts--after-theme)
  (remove-hook 'disable-theme-functions #'drgnx-look-fonts--after-theme)
  (remove-hook 'after-init-hook #'drgnx-look-fonts--after-init)
  (remove-hook 'after-change-major-mode-hook #'drgnx-look-fonts--mode-hook)
  (remove-hook 'server-after-make-frame-hook #'drgnx-look-fonts--check-frame)
  (remove-hook 'text-scale-mode-hook #'drgnx-look-fonts--text-scaled)
  (advice-remove 'global-text-scale-adjust #'drgnx-look-fonts--zoomed)
  (setq drgnx-look-fonts--fallback-report nil)
  (drgnx-look-fonts--ligatures-off)
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when drgnx-look-fonts--remap
        (dolist (c (cdr drgnx-look-fonts--remap)) (face-remap-remove-relative c))
        (setq drgnx-look-fonts--remap nil))))
  (dolist (face (copy-sequence drgnx-look-fonts--written))
    (face-spec-set face nil))
  (setq drgnx-look-fonts--written nil)
  (dolist (o (copy-sequence drgnx-look-fonts--orig))
    (face-spec-set (car o) (cadr o) 'face-defface-spec))
  (setq drgnx-look-fonts--orig nil)
  (drgnx-look-fonts--set-alternatives nil)
  (when drgnx-look-fonts--absolute         ; the faces are relative again: the scaled buffers' remaps without them
    (setq drgnx-look-fonts--absolute nil drgnx-look-fonts--absolute-code nil)
    (drgnx-look-fonts--rescale-buffers)))

(provide 'drgnx-look-fonts)
;;; drgnx-look-fonts.el ends here
