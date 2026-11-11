;;; drgnx-icons.el --- Lucide line icons in the text colour, with the glyphs as the fallback -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-look-icon' returns a string that shows the icon NAME: an SVG image of etc/icons (Lucide, ISC; a few are
;; Feather's, MIT: both notices are in that folder) on a graphical frame, else the glyph of the same name from
;; `drgnx-face-glyphs' (the table of core/drgnx-ui-kit.el).  The SVGs draw with `currentColor', which Emacs takes
;; from the face of the text around the image, so an icon in a `shadow' run is `shadow' in any theme: no colour
;; is named here or in the files.  The setting `drgnx-look-icons' (`svg' or `glyphs') chooses.  Images are kept per
;; (NAME SIZE SCALE); the icon set is finite (about 60 names, two sizes, a few scales), so the cache needs no bound.
;; `drgnx-look-file-icon' picks the file-kind icon by the name's extension from etc/icons/files.eld, the table the
;; hub's Explorer rows read too, so both name the same icon.  See docs/guide/look.md ("Icons").

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-setting)
(require 'drgnx-paths)
(require 'drgnx-ui-kit)
(require 'drgnx-file)                   ; the file-kind table

(drgnx-defsetting drgnx-look-icons 'svg
  "How the look draws its icons: `svg' (Lucide line icons in the text colour, on graphical frames) or `glyphs' (the
characters of `drgnx-face-glyphs').  Terminal frames always show glyphs.  A change applies to the icons drawn from
then on."
  :type '(choice (const :tag "Line icons" svg) (const :tag "Glyphs" glyphs)) :group 'drgnx
  :scope 'global :agents 'never :apply #'drgnx-icons-clear :schema '(enum svg glyphs))

(defconst drgnx-icons-dir (expand-file-name "etc/icons" drgnx-dir) "The folder of the icon files.")

(defconst drgnx-icons-size 16 "An icon's size in logical pixels; dense rows pass 14.")

(defconst drgnx-icons-stroke 1.6
  "The stroke width in the icon's 24-unit box at any size, as the design's (look.css `svg.i'): about 1.07 logical
pixels at 16 px, 0.93 at 14.")

(defvar drgnx-icons--cache (make-hash-table :test 'equal)
  "(NAME SIZE SCALE) → the image, or `none' for a name with no file.  A finite set (see the commentary).")

(defun drgnx-icons-clear ()
  "Forget the images: the next icon is read and sized again."
  (clrhash drgnx-icons--cache))

(defun drgnx-icons--scale ()
  "The selected frame's scale (1.0 without one)."
  (if (fboundp 'frame-scale-factor) (float (frame-scale-factor)) 1.0))

(defun drgnx-icons--make (name size scale)
  "The image of icon NAME at SIZE logical pixels, or nil when there is no such file.  The file's 24-unit box is
sized to SIZE and its stroke to `drgnx-icons-stroke' of the box's units."
  (let ((file (expand-file-name (format "%s.svg" name) drgnx-icons-dir)))
    (when (file-readable-p file)
      (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
        (setq text (replace-regexp-in-string "width=\"24\" height=\"24\""
                                             (format "width=\"%d\" height=\"%d\"" size size) text t t))
        (setq text (replace-regexp-in-string "stroke-width=\"2\""
                                             (format "stroke-width=\"%s\"" drgnx-icons-stroke)
                                             text t t))
        ;; the frame's scale, in the spec (Emacs's image cache draws it again when the scale changes); without
        ;; it Emacs takes `image-scaling-factor', a guess from the font (1.6 at scale 2)
        (create-image text 'svg t :ascent 'center :scale scale)))))

(defun drgnx-icons--image (name size)
  "The cached image of NAME at SIZE on the selected frame's scale, or nil."
  (let* ((scale (drgnx-icons--scale)) (key (list name size scale))
         (hit (gethash key drgnx-icons--cache 'miss)))
    (when (eq hit 'miss)
      (setq hit (or (drgnx-icons--make name size scale) 'none))
      (puthash key hit drgnx-icons--cache))
    (and (not (eq hit 'none)) hit)))

(defun drgnx-look-icon (name &optional face size)
  "A string that shows the icon NAME (a symbol): an SVG image, 16 px (SIZE: 14 in dense rows), coloured by FACE
through the text around it, on a graphical frame with SVG and `drgnx-look-icons' `svg'; else the glyph NAME of
`drgnx-face-glyphs' in FACE.  A name with no file is its glyph."
  (let ((img (and (eq drgnx-look-icons 'svg) (display-graphic-p) (image-type-available-p 'svg)
                  (drgnx-icons--image name (or size drgnx-icons-size)))))
    (if img
        (apply #'propertize " " 'display img 'rear-nonsticky t (and face (list 'face face)))
      (let ((glyph (or (drgnx-face-glyph name) "")))
        (if face (propertize glyph 'face face) glyph)))))

;;;; File kinds

(defconst drgnx-icons--file-kinds
  (let ((kinds (make-hash-table :test #'equal))
        (r (drgnx-file-read (expand-file-name "files.eld" drgnx-icons-dir))))
    (unless (eq (plist-get r :status) 'ok)
      (error "etc/icons/files.eld: %s" (or (plist-get r :problem) (plist-get r :status))))
    (dolist (line (plist-get r :data))
      (dolist (ext (cdr line)) (unless (gethash ext kinds) (puthash ext (car line) kinds))))
    kinds)
  "Lowercase extension → its file-kind icon name, from etc/icons/files.eld (the first line naming it), read once.
The hub reads the same table for the Explorer's rows (runtime/crates/drgnx-ratatoskr/src/view/icons.rs).")

(defun drgnx-look-file-icon-name (file &optional open)
  "The icon name for FILE: a folder (OPEN: an open one), or the file kind from its name."
  (if (or (directory-name-p file) (file-directory-p file))
      (if open 'folder-open 'folder)
    (drgnx-look-file-name-icon-name file)))

(defun drgnx-look-file-name-icon-name (name)
  "The icon name for the file called NAME (a path or a bare name; nothing is read from disk): the kind of the text
after its last dot in `drgnx-icons--file-kinds' (any case; `.editorconfig' counts), else `file'.  The major mode is
not asked: the hub names the same icon without one."
  (let ((base (file-name-nondirectory name)))
    (or (and (string-match "\\.\\([^.]+\\)\\'" base)
             (gethash (downcase (match-string 1 base)) drgnx-icons--file-kinds))
        'file)))

(defun drgnx-look-file-icon (file &optional face size open)
  "The icon of FILE's kind (`drgnx-look-file-icon-name') as `drgnx-look-icon' draws it."
  (drgnx-look-icon (drgnx-look-file-icon-name file open) face size))

(provide 'drgnx-icons)
;;; drgnx-icons.el ends here
