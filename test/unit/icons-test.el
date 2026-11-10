;;; icons-test.el --- Lucide icons: the files, the glyph fallback, the file kinds -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): the icon files are data, the string `drgnx-look-icon' returns is a function of the frame, the
;; setting and the name.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx)
(require 'drgnx-paths)
(require 'drgnx-ui-kit)
(require 'drgnx-icons)

(defun drgnx-icons-test--names ()
  "The icon names: the files of etc/icons, without the extension."
  (mapcar #'file-name-base (directory-files (expand-file-name "etc/icons" drgnx-dir) nil "\\.svg\\'")))

(ert-deftest drgnx-icons/every-svg-is-current-color ()
  "Pattern D: each file draws with `stroke=\"currentColor\"' and `fill=\"none\"' (or `fill=\"currentcolor\"'), and
names no other colour: the text's face colours it."
  (let ((names (drgnx-icons-test--names)))
    (should (>= (length names) 55))
    (dolist (n names)
      (let ((text (with-temp-buffer
                    (insert-file-contents (expand-file-name (concat "etc/icons/" n ".svg") drgnx-dir))
                    (buffer-string))))
        (should (string-match-p "stroke=\"currentColor\"" text))
        (should (or (string-match-p "fill=\"none\"" text) (string-match-p "fill=\"currentcolor\"" text)))
        (should-not (string-match-p "#[0-9a-fA-F]\\{3,8\\}\\b\\|rgb(\\|hsl(" text))
        (let ((start 0))
          (while (string-match "\\<\\(fill\\|stroke\\|color\\|stop-color\\)=\"\\([^\"]*\\)\"" text start)
            (should (member (match-string 2 text) '("none" "currentColor" "currentcolor")))
            (setq start (match-end 0))))))))

(ert-deftest drgnx-icons/the-stroke-is-the-mockups ()
  "The design's icons (look.css `svg.i'): Lucide's stroke 1.6 in its 24-unit box at every size, about 1.07 px at
16 px and 0.93 px at 14 px; the file's own 2 never shows."
  (dolist (size '(16 14))
    (let ((data (plist-get (cdr (drgnx-icons--make 'x size 1.0)) :data)))
      (should (string-match-p "stroke-width=\"1.6\"" data))
      (should-not (string-match-p "stroke-width=\"2\"" data)))))

(ert-deftest drgnx-icons/every-icon-has-a-glyph ()
  "Pattern D: every icon file has a glyph of the same name in the table, for a terminal and for the setting
`glyphs'."
  (dolist (n (drgnx-icons-test--names))
    (should (stringp (drgnx-face-glyph (intern n))))))

(ert-deftest drgnx-icons/terminal-and-glyphs-setting-give-glyphs ()
  "Pattern D: a terminal frame and the setting `glyphs' give the glyph; a graphic frame with SVG gives an image
that the face colours, and the same icon twice is the same image."
  (drgnx-icons-clear)
  (let ((glyph (drgnx-face-glyph 'x)))
    ;; the batch frame is a terminal
    (should (equal glyph (substring-no-properties (drgnx-look-icon 'x))))
    (should-not (get-text-property 0 'display (drgnx-look-icon 'x)))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'image-type-available-p) (lambda (_) t)))
      (let ((s (drgnx-look-icon 'x 'shadow)) (size 16))
        (should (eq 'svg (plist-get (cdr (get-text-property 0 'display s)) :type)))
        (should (eq 'shadow (get-text-property 0 'face s)))
        (should (string-match-p "stroke=\"currentColor\"" (plist-get (cdr (get-text-property 0 'display s)) :data)))
        (should (string-match-p (format "width=\"%d\"" size) (plist-get (cdr (get-text-property 0 'display s)) :data)))
        (should (eq (get-text-property 0 'display s) (get-text-property 0 'display (drgnx-look-icon 'x 'shadow))))
        (should (string-match-p "height=\"14\"" (plist-get (cdr (get-text-property 0 'display (drgnx-look-icon 'x nil 14))) :data))))
      (let ((drgnx-look-icons 'glyphs) (glyph (drgnx-face-glyph 'x))) ; a graphic frame: the Unicode form
        (should (equal glyph (substring-no-properties (drgnx-look-icon 'x))))
        (should-not (get-text-property 0 'display (drgnx-look-icon 'x))))
      ;; an icon that has no file is its glyph, not an error
      (should (equal (drgnx-face-glyph 'ok) (substring-no-properties (drgnx-look-icon 'ok)))))))

(ert-deftest drgnx-icons/both-licences-ship ()
  "Pattern D: Lucide's ISC text and Feather's MIT text sit beside the icons: both require their notice."
  (let ((isc (expand-file-name "etc/icons/LICENSE-lucide" drgnx-dir))
        (mit (expand-file-name "etc/icons/LICENSE-feather" drgnx-dir)))
    (should (file-exists-p isc))
    (should (file-exists-p mit))
    (should (string-match-p "ISC License" (with-temp-buffer (insert-file-contents isc) (buffer-string))))
    (should (string-match-p "MIT License" (with-temp-buffer (insert-file-contents mit) (buffer-string))))
    (should (string-match-p "Lucide Icons and Contributors" (with-temp-buffer (insert-file-contents isc) (buffer-string))))
    (should (string-match-p "Cole Bemis" (with-temp-buffer (insert-file-contents mit) (buffer-string))))))

(ert-deftest drgnx-icons/file-kinds ()
  "Pattern D: the file-kind icon follows the file's major mode class: code, text, config, image, archive, folder;
anything else is a plain file."
  (should (eq 'file-code (drgnx-look-file-icon-name "init.el")))
  (should (eq 'file-code (drgnx-look-file-icon-name "main.rs")))
  (should (eq 'file-text (drgnx-look-file-icon-name "README.md")))
  (should (eq 'file-text (drgnx-look-file-icon-name "notes.org")))
  (should (eq 'file-text (drgnx-look-file-icon-name "notes.txt")))
  (should (eq 'file-cog (drgnx-look-file-icon-name "config.toml")))
  (should (eq 'file-cog (drgnx-look-file-icon-name "settings.json")))
  (should (eq 'file-cog (drgnx-look-file-icon-name "ci.yaml")))
  (should (eq 'file-image (drgnx-look-file-icon-name "shot.png")))
  (should (eq 'file-archive (drgnx-look-file-icon-name "dump.zip")))
  (should (eq 'file-archive (drgnx-look-file-icon-name "dump.tar.gz")))
  (should (eq 'file (drgnx-look-file-icon-name "blob.bin")))
  (should (eq 'folder (drgnx-look-file-icon-name "src/")))
  (should (eq 'folder-open (drgnx-look-file-icon-name "src/" t))))

(ert-deftest drgnx-icons/file-kinds-are-kept-by-extension ()
  "Pattern D: a file kind is worked out once per extension (per name for a name without one): asked again, neither
the kind table nor `auto-mode-alist' is matched (an Explorer row asks on every fontification).  The kept kinds are
bounded, and another `auto-mode-alist' works them out again."
  (let ((calls 0) (orig (symbol-function 'drgnx-icons--mode-class)))
    (cl-letf (((symbol-function 'drgnx-icons--mode-class) (lambda (f) (cl-incf calls) (funcall orig f))))
      (drgnx-icons-clear)
      (dolist (n '("Makefile" "LICENSE" "gen-0001" "a.md" "x.weird")) (drgnx-look-file-name-icon-name n))
      (setq calls 0)
      (let ((drgnx-icons--extensions nil))      ; not read again either
        (should (eq 'file-text (drgnx-look-file-name-icon-name "other.md")))
        (should (eq 'file-text (drgnx-look-file-name-icon-name "dir/OTHER.MD")))
        (dolist (n '("Makefile" "LICENSE" "gen-0001" "y.weird")) (drgnx-look-file-name-icon-name n)))
      (should (= 0 calls))
      (let ((auto-mode-alist (cons '("\\.weird\\'" . text-mode) auto-mode-alist)))
        (should (eq 'file-text (drgnx-look-file-name-icon-name "x.weird"))))
      (dotimes (i 1000) (drgnx-look-file-name-icon-name (format "generated-%d" i)))
      (should (<= (drgnx-cache-size 'icons-file-kinds) drgnx-icons-file-kinds-cap)))))

(provide 'icons-test)
;;; icons-test.el ends here
