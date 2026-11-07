;;; drgnx-color.el --- The one colour library: OKLab mixing, WCAG contrast, solving for contrast -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Every colour computation drgnx does goes through this file: the derived panel colours at theme load
;; (`drgnx-look-derive'), quick help's card, the adapters' roles and the contrast lint.  It runs at theme change and is
;; a few hundred arithmetic operations, so it is Lisp.  Inputs are colour strings Emacs knows ("#rrggbb" is read as
;; written, never snapped to a terminal's palette); results are "#rrggbb".  A colour a frame does not give
;; (`unspecified-bg', nil, an unknown name) is nil, and every function that takes one answers nil: nothing here signals
;; on a theme that leaves a face unspecified.  See docs/develop/core.md ("Colour library").

;;; Code:
(require 'cl-lib)
(require 'color)

(defconst drgnx-color-black '(0.0 0.0 0.0)
  "Black as (R G B): where a colour goes to get darker.  Named once here, as the colour rule asks.")

(defconst drgnx-color-white '(1.0 1.0 1.0)
  "White as (R G B): where a colour goes to get lighter.  Named once here, as the colour rule asks.")

(defun drgnx-color-rgb (color &optional frame)
  "COLOR as (R G B), floats in 0..1, or nil for nil, `unspecified-bg/-fg' or a name Emacs does not know.
FRAME is the frame whose display resolves a colour name."
  (and (stringp color)
       (not (string-prefix-p "unspecified" color))
       (if-let* ((v (color-values-from-color-spec color)))
           (mapcar (lambda (c) (/ c 65535.0)) v)
         (ignore-errors (color-name-to-rgb color frame)))))

(defun drgnx-color--byte (v)
  "V (0..1, clamped) as an integer 0..255, half to even."
  (round (* 255.0 (max 0.0 (min 1.0 v)))))

(defun drgnx-color-hex (rgb)
  "RGB, (R G B) floats in 0..1, as \"#rrggbb\"."
  (apply #'format "#%02x%02x%02x" (mapcar #'drgnx-color--byte rgb)))

;;;; OKLab (Ottosson's matrices)

(defun drgnx-color--linear (v)
  (if (<= v 0.04045) (/ v 12.92) (expt (/ (+ v 0.055) 1.055) 2.4)))

(defun drgnx-color--gamma (v)
  (if (<= v 0.0031308) (* v 12.92) (- (* 1.055 (expt v (/ 1.0 2.4))) 0.055)))

(defun drgnx-color--cbrt (x)
  (if (< x 0.0) (- (expt (- x) (/ 1.0 3.0))) (expt x (/ 1.0 3.0))))

(defun drgnx-color--to-oklab (rgb)
  "RGB (sRGB floats) as (L A B)."
  (pcase-let* ((`(,r ,g ,b) (mapcar #'drgnx-color--linear rgb))
               (l (drgnx-color--cbrt (+ (* 0.4122214708 r) (* 0.5363325363 g) (* 0.0514459929 b))))
               (m (drgnx-color--cbrt (+ (* 0.2119034982 r) (* 0.6806995451 g) (* 0.1073969566 b))))
               (s (drgnx-color--cbrt (+ (* 0.0883024619 r) (* 0.2817188376 g) (* 0.6299787005 b)))))
    (list (+ (* 0.2104542553 l) (* 0.7936177850 m) (* -0.0040720468 s))
          (+ (* 1.9779984951 l) (* -2.4285922050 m) (* 0.4505937099 s))
          (+ (* 0.0259040371 l) (* 0.7827717662 m) (* -0.8086757660 s)))))

(defun drgnx-color--from-oklab (lab)
  "LAB (L A B) as sRGB floats, clamped to 0..1."
  (pcase-let* ((`(,ll ,a ,b) lab)
               (l (expt (+ ll (* 0.3963377774 a) (* 0.2158037573 b)) 3))
               (m (expt (+ ll (* -0.1055613458 a) (* -0.0638541728 b)) 3))
               (s (expt (+ ll (* -0.0894841775 a) (* -1.2914855480 b)) 3)))
    (mapcar (lambda (v) (max 0.0 (min 1.0 (drgnx-color--gamma (max 0.0 v)))))
            (list (+ (* 4.0767416621 l) (* -3.3077115913 m) (* 0.2309699292 s))
                  (+ (* -1.2684380046 l) (* 2.6097574011 m) (* -0.3413193965 s))
                  (+ (* -0.0041960863 l) (* -0.7034186147 m) (* 1.7076147010 s))))))

(defun drgnx-color--from-lch (l c h)
  "OKLCH (L, chroma C, hue H in degrees) as \"#rrggbb\"."
  (let ((rad (degrees-to-radians h)))
    (drgnx-color-hex (drgnx-color--from-oklab (list l (* c (cos rad)) (* c (sin rad)))))))

(defun drgnx-color-lch (l c h)
  "OKLCH (lightness L 0..1, chroma C, hue H in degrees) as \"#rrggbb\", clamped to the sRGB gamut."
  (drgnx-color--from-lch l c h))

(defun drgnx-color-oklch (color)
  "COLOR's OKLCH as (L C H), H in degrees 0..360; nil when COLOR is no colour."
  (when-let* ((rgb (drgnx-color-rgb color)))
    (pcase-let ((`(,l ,a ,b) (drgnx-color--to-oklab rgb)))
      (list l (sqrt (+ (* a a) (* b b))) (mod (radians-to-degrees (atan b a)) 360.0)))))

;;;; Mixing

(defun drgnx-color-mix (a b amount &optional space)
  "The colour AMOUNT (0..1) of the way from A to B, as \"#rrggbb\"; nil when either is no colour.
SPACE is `oklab' (the default) or `srgb' (each channel in 0..255, rounded half to even)."
  (let ((ra (drgnx-color-rgb a)) (rb (drgnx-color-rgb b)))
    (when (and ra rb)
      (if (eq space 'srgb)
          (apply #'format "#%02x%02x%02x"
                 (cl-mapcar (lambda (p q)
                              (let ((p (drgnx-color--byte p)) (q (drgnx-color--byte q)))
                                (round (+ p (* amount (- q p))))))
                            ra rb))
        (drgnx-color-hex
         (drgnx-color--from-oklab
          (cl-mapcar (lambda (p q) (+ p (* amount (- q p)))) (drgnx-color--to-oklab ra) (drgnx-color--to-oklab rb))))))))

(defun drgnx-color-over (fg bg alpha)
  "FG at ALPHA (0..1) over BG, in sRGB, as \"#rrggbb\"; nil when either is no colour."
  (drgnx-color-mix bg fg alpha 'srgb))

;;;; Contrast

(defun drgnx-color--luminance (rgb)
  (pcase-let ((`(,r ,g ,b) (mapcar #'drgnx-color--linear rgb)))
    (+ (* 0.2126 r) (* 0.7152 g) (* 0.0722 b))))

(defun drgnx-color-contrast (a b)
  "The WCAG 2.x contrast ratio of colours A and B (1..21), or nil when either is no colour.
Rounded to nine decimals, so black on white is exactly 21.0."
  (let ((ra (drgnx-color-rgb a)) (rb (drgnx-color-rgb b)))
    (when (and ra rb)
      (let ((la (drgnx-color--luminance ra)) (lb (drgnx-color--luminance rb)))
        (/ (round (* 1e9 (/ (+ 0.05 (max la lb)) (+ 0.05 (min la lb))))) 1e9)))))

(defun drgnx-color-solve (color toward bg ratio &optional space)
  "The smallest move of COLOR toward TOWARD whose contrast with BG is at least RATIO, as \"#rrggbb\".
COLOR itself when it already meets RATIO; TOWARD itself when no move reaches it.  A bisection of the mix amount
(SPACE as in `drgnx-color-mix') down to one 8-bit step.  Nil when a colour is no colour."
  (let ((c0 (drgnx-color-contrast color bg)) (c1 (drgnx-color-contrast toward bg)))
    (cond ((not (and c0 c1 (drgnx-color-rgb color) (drgnx-color-rgb toward))) nil)
          ((>= c0 ratio) (drgnx-color-hex (drgnx-color-rgb color)))
          ((< c1 ratio) (drgnx-color-hex (drgnx-color-rgb toward)))
          (t (let ((lo 0.0) (hi 1.0))
               (dotimes (_ 24)
                 (let ((mid (/ (+ lo hi) 2.0)))
                   (if (>= (drgnx-color-contrast (drgnx-color-mix color toward mid space) bg) ratio)
                       (setq hi mid)
                     (setq lo mid))))
               (drgnx-color-mix color toward hi space))))))

;;;; Distances

(defun drgnx-color--lch-hue (color)
  "COLOR's OKLCH hue in degrees, 0..360, or nil."
  (when-let* ((rgb (drgnx-color-rgb color)))
    (pcase-let ((`(,_ ,a ,b) (drgnx-color--to-oklab rgb)))
      (mod (radians-to-degrees (atan b a)) 360.0))))

(defun drgnx-color-hue-distance (a b)
  "The distance between the OKLCH hues of A and B in degrees, 0..180; nil when either is no colour."
  (let ((ha (drgnx-color--lch-hue a)) (hb (drgnx-color--lch-hue b)))
    (when (and ha hb)
      (let ((d (abs (- ha hb)))) (min d (- 360.0 d))))))

(defun drgnx-color-delta-e (a b)
  "The OKLab distance of A and B times 100; nil when either is no colour."
  (let ((ra (drgnx-color-rgb a)) (rb (drgnx-color-rgb b)))
    (when (and ra rb)
      (* 100.0 (sqrt (apply #'+ (cl-mapcar (lambda (p q) (expt (- p q) 2))
                                           (drgnx-color--to-oklab ra) (drgnx-color--to-oklab rb))))))))

(provide 'drgnx-color)
;;; drgnx-color.el ends here
