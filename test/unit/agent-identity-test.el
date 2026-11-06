;;; agent-identity-test.el --- agents: one identity rule (colour, mark, glyph) and ring 2 of the colours -*- lexical-binding: t -*-
;; test-class: det
;; Pattern [D]: pure.  The mapping is fed rings and session lists; ring 2 is read back from themes enabled alone
;; (the realised specs through `drgnx-face-color', no frame, process or timer); every theme enabled is disabled again.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx)
(require 'drgnx-paths)
(require 'drgnx-color)
(require 'drgnx-faces)
(require 'drgnx-agent-identity)
(load (expand-file-name "modules/ui/drgnx-look-derive" drgnx-dir) nil t)
(add-to-list 'custom-theme-load-path (expand-file-name "test/fixtures/themes" drgnx-dir))

(deftheme drgnx-identity-test-cursor "A dark theme whose first agent colour is the cursor's.")

(defconst agent-identity-test--themes
  '(drgnx-dark drgnx-light drgnx-high-contrast modus-vivendi leuven)
  "The three drgnx themes and two third-party ones.")

(defmacro agent-identity-test--on (theme &rest body)
  "Enable THEME alone with derive on, run BODY, and put everything back."
  (declare (indent 1))
  `(unwind-protect
       (progn (mapc #'disable-theme custom-enabled-themes)
              (if (get ,theme 'theme-settings) (enable-theme ,theme) (load-theme ,theme t))
              (drgnx-look-derive-on)
              ,@body)
     (drgnx-look-derive-off)
     (mapc #'disable-theme custom-enabled-themes)
     (put 'drgnx-identity-test-cursor 'theme-settings nil)
     (dolist (f '(default cursor drgnx-agent-1))
       (put f 'theme-face (assq-delete-all 'drgnx-identity-test-cursor (copy-sequence (get f 'theme-face)))))))

(defmacro agent-identity-test--with-ring (n &rest body)
  "Run BODY with every display giving N colours (faces `drgnx-agent-1' on), and the cache clear."
  (declare (indent 1))
  `(let* ((faces (cl-loop for i from 1 to ,n collect (intern (format "drgnx-agent-%d" i))))
          (drgnx-agent-identity-rings (list (cons 'gui faces) (cons 'tty256 faces)))
          (drgnx-agent-identity-sessions-function nil)
          (drgnx-agent-identity-watched-function nil)
          (drgnx-agents-identity-walk 'diagonal))
     (drgnx-agent-identity-clear)
     (unwind-protect (progn ,@body) (drgnx-agent-identity-clear))))

(defun agent-identity-test--pair (ordinal)
  (let ((id (drgnx-agent-identity ordinal))) (cons (plist-get id :face) (plist-get id :mark))))

(ert-deftest drgnx-agent-identity/first-six-have-six-marks ()
  "Pattern D: with the look's six colours alone the diagonal walk gives agents 1 to 6 their own colour and their own
mark, and every one of the 36 pairs is distinct."
  (agent-identity-test--with-ring 6
    (should (equal '(circle square triangle diamond hexagon star)
                   (mapcar (lambda (k) (cdr (agent-identity-test--pair k))) '(1 2 3 4 5 6))))
    (should (equal '(drgnx-agent-1 drgnx-agent-2 drgnx-agent-3 drgnx-agent-4 drgnx-agent-5 drgnx-agent-6)
                   (mapcar (lambda (k) (car (agent-identity-test--pair k))) '(1 2 3 4 5 6))))
    (should (= 36 (drgnx-agent-identity-capacity)))))

(ert-deftest drgnx-agent-identity/colour-first-keeps-the-looks-six-as-circles ()
  "Pattern D: `colour-first' gives agents 1 to 6 the look's six colours all as circles, and agent 7 the first colour
again with the next mark."
  (agent-identity-test--with-ring 6
    (let ((drgnx-agents-identity-walk 'colour-first))
      (drgnx-agent-identity-clear)
      (should (equal (make-list 6 'circle) (mapcar (lambda (k) (cdr (agent-identity-test--pair k))) '(1 2 3 4 5 6))))
      (should (equal '(drgnx-agent-1 . square) (agent-identity-test--pair 7))))))

(ert-deftest drgnx-agent-identity/pairs-are-unique-up-to-capacity ()
  "Pattern D: for 6, 9 and 12 colours and both walks, every ordinal up to the capacity (36 to 72) has its own pair of
colour and mark, and the capacity is six times the colours."
  (dolist (walk '(diagonal colour-first))
    (dolist (n '(6 9 12))
      (agent-identity-test--with-ring n
        (let ((drgnx-agents-identity-walk walk) (seen (make-hash-table :test 'equal)))
          (drgnx-agent-identity-clear)
          (should (= (* 6 n) (drgnx-agent-identity-capacity)))
          (dotimes (i (* 6 n))
            (let ((pair (agent-identity-test--pair (1+ i))))
              (should-not (gethash pair seen))
              (puthash pair t seen)))
          (should (= (* 6 n) (hash-table-count seen))))))))

(ert-deftest drgnx-agent-identity/past-capacity-reuses-the-least-recent ()
  "Pattern D: agent 37 takes the pair of the least recently active session no watched buffer shows; with no session
data it takes the pair its place in the cycle gives; an agent's identity is kept once given."
  (agent-identity-test--with-ring 6
    (setq drgnx-agent-identity-sessions-function (lambda () '((1 . 90) (2 . 10) (3 . 5) (4 . 70) (37 . 1)))
          drgnx-agent-identity-watched-function (lambda () '(3)))
    (should (equal (agent-identity-test--pair 2) (agent-identity-test--pair 37)))
    ;; the answer is kept while the cache is
    (setq drgnx-agent-identity-sessions-function nil)
    (should (equal (agent-identity-test--pair 2) (agent-identity-test--pair 37)))
    (drgnx-agent-identity-clear)
    (should (equal (agent-identity-test--pair 1) (agent-identity-test--pair 37)))))

(ert-deftest drgnx-agent-identity/ring-two-on-dark-light-high-contrast-and-two-third-party-themes ()
  "Pattern D: under drgnx Dark, Light and High Contrast, modus-vivendi and leuven, the display gives 6 to 12 colours;
every variant in the ring is 3:1 on the editor and 12 delta E from the other colours and the cursor.  The counts are
recorded."
  (let (counts)
    (dolist (theme agent-identity-test--themes)
      (agent-identity-test--on theme
        (let* ((ring (cdr (assq 'gui drgnx-agent-identity-rings)))
               (bg (drgnx-face-color 'default :background 'gui))
               (cursor (drgnx-face-color 'cursor :background 'gui))
               (colour (lambda (f) (drgnx-face-color f :foreground 'gui))))
          (push (cons theme (length ring)) counts)
          (should (<= 6 (length ring) 12))
          (should (= (length ring) (length (delete-dups (copy-sequence ring)))))
          (dolist (face (cl-remove-if (lambda (f) (memq f drgnx-agent-identity--ring-one)) ring))
            (let ((c (funcall colour face)))
              (should (>= (drgnx-color-contrast c bg) 3.0))
              (when cursor (should (>= (drgnx-color-delta-e c cursor) 12.0)))
              (dolist (other (remq face ring))
                (should (>= (drgnx-color-delta-e c (funcall colour other)) 12.0)))))
          (should (= (length ring) (drgnx-agent-identity-colour-count (selected-frame)))))))
    (message "agent colours per theme: %S" (reverse counts))
    (should (= 5 (length counts)))))

(ert-deftest drgnx-agent-identity/the-cursor-colour-is-taken ()
  "Pattern D: a ring-1 colour that sits on the cursor's colour is replaced in its slot by its variant, which stands 12
delta E from the cursor."
  (custom-theme-set-faces
   'drgnx-identity-test-cursor
   '(default ((t :background "#1b1d23" :foreground "#d8dae0")))
   '(cursor ((t :background "#4477ee")))
   '(drgnx-agent-1 ((t :foreground "#4477ee"))))
  (agent-identity-test--on 'drgnx-identity-test-cursor
    (let ((ring (cdr (assq 'gui drgnx-agent-identity-rings))))
      (should (eq 'drgnx-agent-7 (car ring)))
      (should (>= (drgnx-color-delta-e (drgnx-face-color 'drgnx-agent-7 :foreground 'gui) "#4477ee") 12.0))
      (should-not (memq 'drgnx-agent-1 ring)))))

(ert-deftest drgnx-agent-identity/derivation-is-timed ()
  "Pattern D: derive records the milliseconds ring 2 took, for the `identity-derive' probe."
  (agent-identity-test--on 'drgnx-dark
    (should (and (numberp drgnx-look-derive-identity-ms) (>= drgnx-look-derive-identity-ms 0.0)))))

(ert-deftest drgnx-look-derive/pill-text-is-4.5-to-1 ()
  "Pattern D: text on a pill of any of the twelve agent colours, in every theme, reaches 4.5:1."
  (dolist (theme agent-identity-test--themes)
    (agent-identity-test--on theme
      (dotimes (i 12)
        (let* ((pill (drgnx-face-color (intern (format "drgnx-agent-%d" (1+ i))) :foreground 'gui))
               (text (drgnx-look-pill-text pill (drgnx-face-color 'default :foreground 'gui))))
          (should (>= (drgnx-color-contrast text pill) 4.5)))))))

(ert-deftest drgnx-agent-identity/colour-lch-round-trips ()
  "Pattern D: `drgnx-color-lch' undoes `drgnx-color-oklch' to within one 8-bit step."
  (dolist (c '("#4477ee" "#ee4444" "#2a8a2a" "#808080"))
    (should (< (drgnx-color-delta-e c (apply #'drgnx-color-lch (drgnx-color-oklch c))) 0.5))))

(ert-deftest drgnx-agent-identity/glyph-falls-back-to-ascii-when-wide ()
  "Pattern D: a mark whose Unicode shape is not displayable or not one column wide on the frame is its ASCII stand-in,
and the choice is kept per frame until the cache is cleared."
  (agent-identity-test--with-ring 6
    (cl-letf (((symbol-function 'char-displayable-p) (lambda (_) t))
              ((symbol-function 'char-width) (lambda (_) 1)))
      (drgnx-agent-identity-clear)
      (should (equal '("●" "■" "▲" "◆" "⬢" "★") (mapcar #'drgnx-agent-identity-text '(1 2 3 4 5 6)))))
    (cl-letf (((symbol-function 'char-displayable-p) (lambda (_) t))
              ((symbol-function 'char-width) (lambda (_) 2)))
      (drgnx-agent-identity-clear)
      (should (equal '("o" "#" "^" "<" "H" "*") (mapcar #'drgnx-agent-identity-text '(1 2 3 4 5 6)))))
    (cl-letf (((symbol-function 'char-displayable-p) (lambda (_) nil))
              ((symbol-function 'char-width) (lambda (_) 1)))
      (drgnx-agent-identity-clear)
      (should (equal "o" (drgnx-agent-identity-text 1))))))

(ert-deftest drgnx-agent-identity/fringe-uses-four-shapes ()
  "Pattern D: the gutter has circle, square, triangle and diamond bitmaps, all defined; hexagon uses the circle's and star
the diamond's."
  (agent-identity-test--with-ring 6
    (let ((bitmaps (mapcar #'drgnx-agent-identity-fringe '(1 2 3 4 5 6))))
      (should (equal '(drgnx-agent-fringe-circle drgnx-agent-fringe-square drgnx-agent-fringe-triangle
                                                 drgnx-agent-fringe-diamond drgnx-agent-fringe-circle
                                                 drgnx-agent-fringe-diamond)
                     bitmaps))
      (should (= 4 (length (delete-dups (copy-sequence bitmaps)))))
      (dolist (b bitmaps) (should (fringe-bitmap-p b))))))

(ert-deftest drgnx-agent-identity/image-colour-comes-from-the-face ()
  "Pattern D: the mark's image is a Lucide icon drawn with `currentColor' under the agent's own face, so its colour is
the face's in any theme and no colour is written in the string."
  (agent-identity-test--with-ring 6
    (drgnx-icons-clear)
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'image-type-available-p) (lambda (_) t)))
      (drgnx-agent-identity-clear)
      (let* ((s (drgnx-agent-identity-image 3 16))
             (data (plist-get (cdr (get-text-property 0 'display s)) :data)))
        (should (eq 'drgnx-agent-3 (get-text-property 0 'face s)))
        (should (string-match-p "stroke=\"currentColor\"" data))
        (should (string-match-p "M13.73 4" data))     ; the triangle
        (should-not (string-match-p "#[0-9a-fA-F]\\{3,8\\}\\b" data))
        (should-not (equal data (plist-get (cdr (get-text-property 0 'display (drgnx-agent-identity-image 4 16))) :data)))))))

(provide 'agent-identity-test)
;;; agent-identity-test.el ends here
