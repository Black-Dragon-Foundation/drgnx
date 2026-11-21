;;; color-test.el --- batch tests: the colour library and quick help on it -*- lexical-binding: t -*-
;; test-class: det
;; Pattern [D]: pure arithmetic on colour strings; no process, timer or frame state is involved.
(require 'ert)
(require 'drgnx)
(require 'drgnx-color)
(load (expand-file-name "modules/ui/drgnx-quickhelp" drgnx-dir) nil t)

(defun drgnx-color-test--ratio (a b)
  "The contrast of A on B rounded to one decimal."
  (/ (round (* 10 (drgnx-color-contrast a b))) 10.0))

(ert-deftest drgnx-color/contrast-black-white-is-21 ()
  (should (= 21.0 (drgnx-color-contrast "#000000" "#ffffff"))))

(ert-deftest drgnx-color/contrast-matches-the-design-table ()
  (should (= 10.2 (drgnx-color-test--ratio "#e4e5ea" "#243150")))
  (should (= 13.2 (drgnx-color-test--ratio "#1c1e23" "#dbe5fb")))
  (should (= 10.8 (drgnx-color-test--ratio "#ffffff" "#1f3a7a")))
  (should (= 4.9 (drgnx-color-test--ratio "#858996" "#1a1b20")))
  ;; this pair sits on a half (7.45): the design prints 7.5, exact rounding gives 7.4, so it is checked within 0.06
  (should (< (abs (- 7.5 (drgnx-color-contrast "#7aa5ff" "#15161a"))) 0.06))
  (should (>= (drgnx-color-contrast "#878b98" "#23252c") 4.5)))

(ert-deftest drgnx-color/srgb-mix-rounds-half-to-even ()
  (should (equal "#2c3039" (drgnx-color-mix "#282c34" "#bbc2cf" 0.03 'srgb)))
  (should (equal "#f7f7f7" (drgnx-color-mix "#ffffff" "#000000" 0.03 'srgb))))

(ert-deftest drgnx-color/oklab-mix-endpoints ()
  (dolist (pair '(("#282c34" . "#bbc2cf") ("#ff0000" . "#00ff00") ("#123456" . "#fedcba")))
    (should (equal (car pair) (drgnx-color-mix (car pair) (cdr pair) 0)))
    (should (equal (cdr pair) (drgnx-color-mix (car pair) (cdr pair) 1)))))

(ert-deftest drgnx-color/solve-is-the-smallest-step ()
  (let* ((start "#757987") (toward "#e4e5ea") (bg "#1a1b20")
         (got (drgnx-color-solve start toward bg 4.5))
         (rgb (mapcar (lambda (c) (round (* 255 c))) (drgnx-color-rgb got)))
         (start-rgb (mapcar (lambda (c) (round (* 255 c))) (drgnx-color-rgb start)))
         ;; one 8-bit step back toward the start, on every channel that moved
         (back (apply #'format "#%02x%02x%02x"
                      (cl-mapcar (lambda (g s) (cond ((> g s) (1- g)) ((< g s) (1+ g)) (t g))) rgb start-rgb))))
    (should (>= (drgnx-color-contrast got bg) 4.5))
    (should (< (drgnx-color-contrast back bg) 4.5))))

(ert-deftest drgnx-color/solve-gives-toward-when-unreachable ()
  (should (equal "#202020" (drgnx-color-solve "#101010" "#202020" "#000000" 21))))

(ert-deftest drgnx-color/hue-distance-wraps ()
  ;; two colours whose OKLCH hues are 350 and 10 degrees apart round the wheel: 20, not 340
  (let* ((a (drgnx-color--from-lch 0.7 0.15 350)) (b (drgnx-color--from-lch 0.7 0.15 10)))
    (should (< (abs (- 20.0 (drgnx-color-hue-distance a b))) 2.0))))

(ert-deftest drgnx-color/unspecified-is-nil ()
  (should-not (drgnx-color-rgb "unspecified-bg"))
  (should-not (drgnx-color-rgb nil))
  (should-not (drgnx-color-contrast nil "#ffffff"))
  (should-not (drgnx-color-contrast "#ffffff" "unspecified-fg")))

(defun drgnx-color-test--colors (default-bg default-fg card-bg)
  "`drgnx-quickhelp-colors' on a theme with these colours (batch has no colour display, so the face lookup is
stubbed: a dark theme, a light theme and a card face that already stands out)."
  (cl-letf (((symbol-function 'face-attribute)
             (lambda (face attr &rest _)
               (pcase (cons face attr)
                 (`(default . :background) default-bg)
                 (`(default . :foreground) default-fg)
                 (`(drgnx-quickhelp . :background) card-bg)
                 (_ 'unspecified)))))
    (drgnx-quickhelp-colors)))

(ert-deftest drgnx-quickhelp/colors-unchanged-on-the-library ()
  ;; the strings are what the code before the library returned (captured from it, unchanged).  That code cut a
  ;; channel off (63.52 became 63), the library rounds it (64): the card is the same to within one 8-bit step.
  (let ((base '(("#3f444c" . "#7d838d") ("#dadbdc" . "#898a8f") ("#3f444f" . "#7d838f")))
        (now (list (drgnx-color-test--colors "#282c34" "#bbc2cf" 'unspecified)
                   (drgnx-color-test--colors "#fafafa" "#383a42" 'unspecified)
                   (drgnx-color-test--colors "#282c34" "#bbc2cf" "#3f444f"))))
    (cl-mapc (lambda (was is)
               (dolist (pair (list (cons (car was) (car is)) (cons (cdr was) (cdr is))))
                 (should (cl-every (lambda (p q) (<= (abs (- (round (* 255 p)) (round (* 255 q)))) 1))
                                   (drgnx-color-rgb (car pair)) (drgnx-color-rgb (cdr pair))))))
             base now)
    (should (equal (nth 2 base) (nth 2 now)))))     ; the card's own background is kept as it was

(provide 'color-test)
;;; color-test.el ends here
