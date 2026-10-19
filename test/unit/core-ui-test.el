;;; core-ui-test.el --- batch tests: the UI kit in core — glyphs by meaning, status faces -*- lexical-binding: t -*-
;; The batch terminal is not UTF-8, so each test says which kind of frame it draws on.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-ui-kit)
(require 'drgnx-modules)
(require 'drgnx-onboard)

(defmacro drgnx-ui-test--unicode (&rest body)
  "BODY on a frame that writes UTF-8."
  `(cl-letf (((symbol-function 'drgnx-ui-ascii-frame-p) (lambda (&optional _f) nil))) ,@body))

(defmacro drgnx-ui-test--ascii (&rest body)
  "BODY on a terminal frame that does not write UTF-8."
  `(cl-letf (((symbol-function 'drgnx-ui-ascii-frame-p) (lambda (&optional _f) t))) ,@body))

(ert-deftest drgnx-ui-kit/face-glyph-is-core-and-always-defined ()
  ;; ui/face is a module, not part of core: nothing here loads it
  (should (fboundp 'drgnx-face-glyph))
  (should (boundp 'drgnx-face-glyphs))
  (should-not (featurep 'drgnx-face))
  (drgnx-ui-test--unicode (should (equal (drgnx-face-glyph 'close) "×")))
  (should-not (drgnx-face-glyph 'no-such-glyph)))

(ert-deftest drgnx-ui-kit/meanings-are-separate ()
  (dolist (n '(fail stopped dismiss unqueue info warn))
    (let ((g (alist-get n (default-value 'drgnx-face-glyphs))))
      (should (and (stringp (car g)) (stringp (cdr g))))
      (should (string-match-p "\\`[[:ascii:]]+\\'" (cdr g)))))
  (let ((drgnx-face-glyphs (cons '(close "C" . "c") drgnx-face-glyphs)))
    (drgnx-ui-test--unicode
     (should (equal (drgnx-face-glyph 'close) "C"))
     (should (equal (drgnx-face-glyph 'fail) "✕"))
     (should (equal (drgnx-face-glyph 'dismiss) "×")))))

(ert-deftest drgnx-ui-kit/ascii-glyphs-on-a-non-utf8-terminal ()
  (let ((tty (make-symbol "tty")))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional f) (not (eq f tty))))
              ((symbol-function 'frame-terminal) (lambda (&optional _f) 'term))
              ((symbol-function 'terminal-coding-system) (lambda (&optional _t) 'iso-latin-1)))
      (should (drgnx-ui-ascii-frame-p tty))
      (should-not (drgnx-ui-ascii-frame-p 'gui))
      (should (equal (drgnx-face-glyph 'fail tty) "X"))
      (should (equal (drgnx-face-glyph 'fail 'gui) "✕")))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _f) nil))
              ((symbol-function 'frame-terminal) (lambda (&optional _f) 'term))
              ((symbol-function 'terminal-coding-system) (lambda (&optional _t) 'utf-8-unix)))
      (should-not (drgnx-ui-ascii-frame-p tty))
      (should (equal (drgnx-face-glyph 'fail tty) "✕")))))

(ert-deftest drgnx-ui-kit/tty-popups-ascii-is-the-same-test ()
  (load (expand-file-name "modules/ui/drgnx-tty-popups" drgnx-dir) nil t)
  (should (eq (indirect-function 'drgnx-tty-popups-ascii-p) (indirect-function 'drgnx-ui-ascii-frame-p))))

(ert-deftest drgnx-ui-kit/status-faces-inherit ()
  (pcase-dolist (`(,face . ,parent) '((drgnx-status-ok . success) (drgnx-status-info . shadow) (drgnx-status-warn . warning)
                                      (drgnx-status-fail . error) (drgnx-status-needs-you . error)))
    (should (facep face))
    (should (equal (face-attribute face :inherit nil nil) parent))
    (should-not (cl-some (lambda (a) (stringp (face-attribute face a nil nil))) '(:foreground :background)))))

(ert-deftest drgnx-ui-kit/status-gives-glyph-and-text-in-its-face ()
  (drgnx-ui-test--unicode
   (pcase-dolist (`(,sev ,glyph ,face) '((ok "✓" drgnx-status-ok) (info "ℹ" drgnx-status-info) (warn "⚠" drgnx-status-warn)
                                         (fail "✕" drgnx-status-fail) (needs-you "◐" drgnx-status-needs-you)))
     (let ((s (drgnx-ui-status sev "text")))
       (should (equal (substring-no-properties s) (concat glyph " text")))
       (should (eq (get-text-property 0 'face s) face))
       (should (eq (get-text-property (1- (length s)) 'face s) face)))
     (should (equal (substring-no-properties (drgnx-ui-status sev)) glyph)))))

(ert-deftest drgnx-ui-kit/a-saved-glyph-option-still-applies ()
  ;; the option keeps its name: a value saved by customize before the move (the old 18 entries, with ok and
  ;; waiting restyled, and no fail, stopped, dismiss, unqueue, info or warn) is read by the kit; a name it lacks
  ;; falls back to the default entry
  (let ((drgnx-face-glyphs
         '((handle "⠿" . "::") (close "×" . "x") (branch "⑂" . "Y") (warning "⚠" . "!") (ok "OK" . "ok")
           (busy "◎" . "@") (waiting "W" . "w") (paused "⏸" . "||") (ahead "↑" . "^") (behind "↓" . "v")
           (dot "●" . "*") (circle "○" . "o") (sep " · " . " | ") (flag "⚑" . "#")
           (diamond "◆" . "<>") (search "⌕" . "/") (minimize "–" . "-") (maximize "▢" . "[]"))))
    (should (= (length drgnx-face-glyphs) 18))
    (drgnx-ui-test--unicode
     (should (equal (substring-no-properties (drgnx-ui-status 'ok "fine")) "OK fine"))
     (should (equal (substring-no-properties (drgnx-ui-status 'needs-you)) "W"))
     (should (equal (substring-no-properties (drgnx-ui-status 'fail "failed: x")) "✕ failed: x"))
     (should (equal (substring-no-properties (drgnx-ui-status 'info)) "ℹ"))
     (should (equal (drgnx-face-glyph 'dismiss) "×"))
     (should (equal (drgnx-face-glyph 'bullet) "•")))
    (drgnx-ui-test--ascii
     (should (equal (substring-no-properties (drgnx-ui-status 'ok "fine")) "ok fine"))
     (should (equal (substring-no-properties (drgnx-ui-status 'fail "bad")) "X bad"))
     (should (equal (substring-no-properties (drgnx-ui-status 'warn)) "!")))
    (should-not (drgnx-face-glyph 'no-such-glyph))))

(ert-deftest drgnx-modules/list-statuses-use-the-kit ()
  (let ((drgnx-modules--table '((t/a :stage load) (t/b :stage load) (t/c :stage load) (t/d :stage load)
                                (t/e :stage load)))
        (drgnx-modules--report '((t/a :status ok) (t/b :status failed :error "kaputt") (t/c :status missing-packages :missing (magit))
                                 (t/e :status off))))
    (let ((st (lambda (n) (aref (cadr (assq n (drgnx-modules--entries))) 1))))
      (drgnx-ui-test--unicode
       (should (equal (substring-no-properties (funcall st 't/a)) "✓ ok"))
       (should (eq (get-text-property 0 'face (funcall st 't/a)) 'drgnx-status-ok))
       (should (equal (substring-no-properties (funcall st 't/b)) "✕ failed: kaputt"))
       (should (eq (get-text-property 0 'face (funcall st 't/b)) 'drgnx-status-fail))
       (should (equal (substring-no-properties (funcall st 't/c)) "⚠ needs magit"))
       (should (eq (get-text-property 0 'face (funcall st 't/c)) 'drgnx-status-warn))
       (should (equal (funcall st 't/d) "not run yet"))
       (should (equal (substring-no-properties (funcall st 't/e)) "ℹ off"))       ; turned off in this session
       (should (eq (get-text-property 0 'face (funcall st 't/e)) 'drgnx-status-info)))
      (drgnx-ui-test--ascii
       (should (equal (substring-no-properties (funcall st 't/b)) "X failed: kaputt"))))))

(ert-deftest drgnx-onboard/steps-use-the-kit ()
  (let ((drgnx-onboard--steps '((a :title "A" :order 1) (b :title "B" :order 2) (c :title "C" :order 3) (d :title "D" :order 4)))
        (drgnx-onboard--progress nil))
    (cl-letf (((symbol-function 'drgnx-onboard-state)
               (lambda () '((a :status ok :message "m") (b :status fail :message "m") (c :status info :message "m"))))
              ((symbol-function 'drgnx-onboard--next-button) (lambda (&rest _) nil)))
      (let ((st (lambda (id) (aref (cadr (assq id (drgnx-onboard--entries))) 1))))
        (drgnx-ui-test--unicode
         (should (equal (substring-no-properties (funcall st 'a)) "✓ ok"))
         (should (eq (get-text-property 0 'face (funcall st 'a)) 'drgnx-status-ok))
         (should (equal (substring-no-properties (funcall st 'b)) "✕ fail"))
         (should (eq (get-text-property 0 'face (funcall st 'b)) 'drgnx-status-fail))
         (should (equal (substring-no-properties (funcall st 'c)) "ℹ info"))
         (should (equal (funcall st 'd) "—")))
        (drgnx-ui-test--ascii
         (should (equal (substring-no-properties (funcall st 'b)) "X fail")))))))
